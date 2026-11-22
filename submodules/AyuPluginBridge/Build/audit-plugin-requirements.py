"""Hash-pinned AST audit. NEVER import, compile or execute supplied plugin code.

Reads only files named by the source manifest and publishes API identifiers,
line counts and hashes, not source text or plugin configuration/credentials.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import sys

BRIDGE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BRIDGE / "Python"))
from _ayu_inspection import import_inventory

SOURCE_COMMIT = "a4b6bb472fd657e0f659531dae090e12c02a0aaa"
SNOW_SHA256 = "bbda8727d253e02542c1c1f51dca1d39d235e2a310b4ba096e5e6305472a6763"
SDK_MODULES = {"ayu_bridge", "base_plugin", "client_utils", "android_utils", "hook_utils",
               "plugin_settings", "java", "ui", "ui.settings", "ui.alert", "ui.bulletin"}
VALUE_CLASSES = {"java.lang.Integer", "java.lang.Long", "java.lang.Boolean", "java.lang.System",
                 "java.util.ArrayList", "java.util.HashMap", "java.util.concurrent.atomic.AtomicLong",
                 "java.util.concurrent.atomic.AtomicBoolean", "int", "long", "boolean", "byte",
                 "short", "char", "float", "double", "void"}
HOST_CLASSES = {"android.view.View", "android.widget.FrameLayout", "android.widget.LinearLayout",
                "android.widget.TextView", "android.widget.ImageView", "android.widget.FrameLayout$LayoutParams",
                "android.widget.LinearLayout$LayoutParams", "java.lang.reflect.Method", "[B", "[S", "[C", "[I", "[J", "[F", "[D", "[Z",
                 "java.lang.Runnable", "android.view.View$OnClickListener", "android.view.View$OnTouchListener"}
APPLICATION_CLASSES = {"org.telegram.messenger.UserConfig", "org.telegram.tgnet.TLRPC$User",
                       "org.telegram.ui.ActionBar.BaseFragment", "android.content.Context", "org.telegram.ui.ActionBar.AlertDialog"}
NATIVE_PREFIXES = ("android.", "androidx.", "java.", "javax.", "org.telegram.", "com.")
HOOKS = {"hook_method", "hook_all_methods", "hook_all_constructors", "add_hook", "add_on_send_message_hook",
         "add_on_request_hook", "add_on_response_hook", "hook_request", "hook_response"}
EVENTS = {"on_app_event", "on_send_message_hook", "on_request_hook", "on_response_hook"}


def audit(path, record):
    data = path.read_bytes()
    assert hashlib.sha256(data).hexdigest() == record["sha256"], "Source hash mismatch"
    assert len(data) == record["bytes"], "Source size mismatch"
    tree = ast.parse(data.decode("utf-8"), filename=record["path"])
    inventory = import_inventory(tree, SDK_MODULES)
    imports, features, hooks, events = set(), set(), set(), set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imports.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imports.add(node.module)
        elif isinstance(node, ast.Call):
            name = node.func.id if isinstance(node.func, ast.Name) else node.func.attr if isinstance(node.func, ast.Attribute) else ""
            if name in HOOKS:
                hooks.add(name)
            if name in ("java_subclass", "joverride", "joverload"):
                features.add("java_subclassing")
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in EVENTS:
            events.add(node.name)
    classes = set(inventory["classes"])
    if any(name.split(".")[0] in {"threading", "_thread", "concurrent"} for name in imports):
        features.add("plugin_threads")
    if any(name.startswith("extera_utils.classes") for name in imports):
        features.add("java_subclassing")
    if any(name.startswith("android.graphics.") for name in classes):
        features.add("android_graphics")
    if any(name.startswith(("android.hardware.", "android.media.")) for name in classes):
        features.add("android_camera_or_media")
    if any(name.startswith(("org.telegram.messenger.", "org.telegram.tgnet.")) for name in classes):
        features.add("telegram_objects_and_requests")
    if any(name.startswith("org.telegram.ui.") for name in classes):
        features.add("telegram_android_ui")
    if hooks:
        features.add("method_or_request_hooks")
    if events:
        features.add("application_or_message_events")
    if any("MenuItemData" in symbols for symbols in inventory["imported_symbols"].values()):
        features.add("context_menus")
    if any("get_last_fragment" in symbols for symbols in inventory["imported_symbols"].values()):
        features.add("client_fragment_adapter")
    if any(name.startswith("ui.alert") or name.startswith("ui.bulletin") for name in imports):
        features.add("native_alert_or_bulletin_presentation")
    external = sorted(name for name in imports if name not in SDK_MODULES
                      and name.split(".")[0] not in getattr(sys, "stdlib_module_names", ())
                      and not name.startswith(NATIVE_PREFIXES))
    native = record["path"] == "atmospheric_snow.plugin" and record["sha256"] == SNOW_SHA256
    partial_features = {"account_identity_and_own_profile"} if classes & APPLICATION_CLASSES else set()
    if "client_fragment_adapter" in features:
        partial_features.add("visible_screen_context")
    if "native_alert_or_bulletin_presentation" in features:
        partial_features.add("basic_alerts_and_bulletins")
    if "on_app_event" in events:
        partial_features.add("generation_bound_app_lifecycle")
    return {"file": record["path"], "blob": record["blob"], "sha256": record["sha256"], "bytes": len(data),
            "lines": len(data.decode("utf-8").splitlines()),
            "status": "source_pinned_native_adapter_device_unverified" if native else "blocked_not_runtime_compatible",
            "python_path": "blocked" if classes - (VALUE_CLASSES | HOST_CLASSES) or features or external or inventory["unsupported_sdk_symbols"] else "requires_runtime_validation",
            "native_adapter": "Integration/AyuAtmosphericPluginAdapter.swift" if native else None,
            "implemented_value_subsets": sorted(classes & VALUE_CLASSES),
             "declared_ui_or_reference_subsets": sorted(classes & HOST_CLASSES),
             "declared_application_subsets": sorted(classes & APPLICATION_CLASSES),
             "partially_wired_features": sorted(partial_features),
             "unadapted_classes": sorted(classes - (VALUE_CLASSES | HOST_CLASSES | APPLICATION_CLASSES)),
            "unsupported_sdk_symbols": inventory["unsupported_sdk_symbols"],
            "external_imports_not_default_enabled": external, "required_unwired_features": sorted(features),
            "hook_forms": sorted(hooks), "event_forms": sorted(events),
            "dynamic_class_lookup_lines": inventory["dynamic_class_lookup_lines"],
            "imports": sorted(imports), "java_classes": sorted(classes)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-manifest", type=Path, required=True)
    parser.add_argument("--plugin-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--replace-generated", action="store_true", help="Regenerate the two audit outputs for exactly the same pinned sources")
    args = parser.parse_args()
    manifest = json.loads(args.source_manifest.read_text())
    assert manifest["repo"] == "Nomadvorga/ayugram-src" and manifest["commit"] == SOURCE_COMMIT
    assert len(manifest["files"]) == 19 and len({item["path"] for item in manifest["files"]}) == 19
    for item in manifest["files"]:
        assert re.fullmatch(r"[a-z][a-z0-9_]*\.plugin", item["path"]), "Only pinned flat plugin filenames are accepted"
        assert (args.plugin_dir / item["path"]).resolve().is_relative_to(args.plugin_dir.resolve())
    plugins = [audit(args.plugin_dir / item["path"], item) for item in sorted(manifest["files"], key=lambda item: item["path"])]
    assert sum(item["lines"] for item in plugins) == 40_950
    files = ["Sources/AyuBridgeClassRegistry.swift", "Sources/AyuBridgeJavaValues.swift", "Sources/AyuBridgeProtocol.swift", "Sources/AyuPluginNativeHost.swift",
              "Integration/AyuPluginApplicationBridge.swift", "Integration/AyuPluginService.swift",
              "Python/_ayu_inspection.py", "Python/ayu_bridge.py", "Python/android_utils.py", "Python/client_utils.py", "Python/hook_utils.py"]
    result = {"schema_version": 1, "source_repo": manifest["repo"], "source_commit": SOURCE_COMMIT,
              "inspection": "AST-only; supplied plugin code was not imported, compiled or executed",
              "device_launch_verified": False, "native_tests_executed": False, "plugins_runtime_verified": [],
              "source_total_lines": 40_950, "sdk_sha256": {name: hashlib.sha256((BRIDGE / name).read_bytes()).hexdigest() for name in files},
              "limitations": ["Declared classes are subsets, not Android runtime parity", "Dynamic names and members require further runtime/API audit",
                               "Application provider supplies only narrow account, visible-context, alert/bulletin and app-lifecycle subsets",
                               "Requests/messages, account notifications, hooks, menus, media, subclassing and graphics remain unsupported",
                               "Required unwired feature families may have partial subsets; consult partially_wired_features, not import success",
                              "AST alias inspection is conservative, not a scope-aware Python resolver"], "plugins": plugins}
    args.output_dir.mkdir(parents=True, exist_ok=True)
    json_text = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    rows = ["# Common bridge: pinned 19-plugin compatibility audit", "",
            f"Source: `Nomadvorga/ayugram-src@{SOURCE_COMMIT}`. **Not a claim that all 19 work.**", "",
            "40,950 lines inspected as AST only. No supplied plugin execution; no device/native-test verification.", "",
             "| Plugin | Path status | Value subsets | Application subsets | Unadapted classes | Missing SDK symbols |", "|---|---|---:|---:|---:|---:|"]
    for item in plugins:
        status = "Pinned native adapter; device unverified" if item["native_adapter"] else "Blocked (Python path)"
        rows.append(f"| `{item['file']}` | {status} | {len(item['implemented_value_subsets'])} | {len(item['declared_application_subsets'])} | {len(item['unadapted_classes'])} | {sum(len(v) for v in item['unsupported_sdk_symbols'].values())} |")
    rows += ["", "See `compatibility.json` for each source hash, required API, hook/event form and missing class/symbol.", "",
             "Atmospheric Snow bypasses Python only for the exact pinned SHA-256; its Android/Python path remains blocked.",
              "The other 18 remain blocked. Narrow app adapters are not a substitute for their remaining Telegram/iOS services.",
              "See `APPLICATION-BRIDGES.md` for exact implemented members, per-plugin work packages and device checks.", ""]
    for name, text in [("compatibility.json", json_text), ("README.md", "\n".join(rows))]:
        target = args.output_dir / name
        if target.exists():
            if target.read_text() != text:
                assert args.replace_generated, "Output already exists with different contents; choose a new directory"
                previous = json.loads((args.output_dir / "compatibility.json").read_text())
                assert previous["source_commit"] == SOURCE_COMMIT
                assert {(p["file"], p["sha256"]) for p in previous["plugins"]} == {(p["file"], p["sha256"]) for p in plugins}
                target.write_text(text)
        else:
            with target.open("x") as output:
                output.write(text)
    print(json.dumps({"plugins": len(plugins), "lines": 40_950, "runtime_verified": 0,
                      "native_source_pinned": sum(bool(item["native_adapter"]) for item in plugins), "output": str(args.output_dir)}))


if __name__ == "__main__":
    main()
