"""Hash-pinned AST audit. NEVER import, compile or execute supplied plugin code.

Pinned mode reads only files named by the source manifest. Corpus mode accepts
--corpus-dir DIR --android-sdk DIR --bridge-sdk DIR --output FILE and delegates
to the bounded, redacted aggregate inspector. Neither mode executes attachments.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
from pathlib import Path
import re
import sys
import subprocess
import warnings

BRIDGE = Path(__file__).resolve().parents[1]

SOURCE_COMMIT = "a4b6bb472fd657e0f659531dae090e12c02a0aaa"
SNOW_SHA256 = "bbda8727d253e02542c1c1f51dca1d39d235e2a310b4ba096e5e6305472a6763"
VALUE_CLASSES = {"java.lang.Byte", "java.lang.Short", "java.lang.Integer", "java.lang.Long", "java.lang.Boolean", "java.lang.System",
                  "java.util.ArrayList", "java.util.HashMap", "java.util.concurrent.atomic.AtomicLong",
                  "java.util.concurrent.atomic.AtomicBoolean", "java.net.URL", "java.net.URLEncoder",
                  "java.util.Scanner", "java.io.ByteArrayOutputStream", "java.util.Collections",
                  "java.lang.String", "java.lang.Float", "java.lang.Object", "java.lang.CharSequence", "java.lang.ref.WeakReference",
                  "android.content.res.ColorStateList", "android.text.Spanned", "android.text.SpannableString",
                  "android.text.SpannableStringBuilder", "android.text.style.StyleSpan", "android.text.style.UnderlineSpan",
                  "android.text.style.StrikethroughSpan", "android.text.style.TypefaceSpan",
                  "android.text.style.ForegroundColorSpan", "android.text.style.CharacterStyle",
                  "android.text.style.MetricAffectingSpan", "android.text.style.UpdateAppearance",
                  "android.text.style.UpdateLayout", "int", "long", "boolean", "byte",
                 "short", "char", "float", "double", "void"}
HOST_CLASSES = {"android.os.SystemClock", "android.view.View", "android.view.View$MeasureSpec", "android.view.ViewGroup", "android.view.Gravity", "android.view.HapticFeedbackConstants", "android.view.ViewConfiguration", "android.widget.FrameLayout", "android.widget.LinearLayout", "android.widget.ScrollView", "android.widget.HorizontalScrollView", "android.widget.ProgressBar", "android.widget.CheckBox", "android.widget.CompoundButton$OnCheckedChangeListener",
                 "android.widget.TextView", "android.widget.EditText", "android.widget.ImageView", "android.widget.ImageButton", "android.widget.ImageView$ScaleType",
                 "android.view.ViewOutlineProvider", "android.graphics.PorterDuff$Mode", "android.graphics.PorterDuffColorFilter",
                 "android.widget.FrameLayout$LayoutParams",
                  "android.widget.LinearLayout$LayoutParams", "java.lang.reflect.Method", "java.lang.reflect.Array", "[B", "[S", "[C", "[I", "[J", "[F", "[D", "[Z",
                  "android.os.Bundle", "android.content.Intent", "android.net.Uri", "android.view.MotionEvent", "android.os.Handler",
                  "android.graphics.Color", "android.graphics.Typeface", "android.graphics.drawable.ColorDrawable",
                 "android.graphics.Rect", "android.graphics.RectF", "android.graphics.drawable.GradientDrawable",
                 "android.graphics.Paint", "android.graphics.Paint$Cap", "android.graphics.Paint$Join", "android.graphics.Paint$Style",
                  "android.graphics.Path",
                  "android.graphics.Matrix",
                  "android.view.animation.LinearInterpolator", "android.view.animation.DecelerateInterpolator",
                  "android.view.animation.OvershootInterpolator", "android.animation.ValueAnimator",
                  "android.view.ViewPropertyAnimator",
                  "android.text.TextUtils", "android.text.TextUtils$TruncateAt", "android.text.TextWatcher", "android.text.InputType", "java.util.Locale",
                  "java.nio.ByteBuffer", "java.lang.Runnable", "java.lang.Class",
                  "android.view.View$OnClickListener", "android.view.View$OnTouchListener"}
APPLICATION_CLASSES = {"org.telegram.messenger.UserConfig", "org.telegram.tgnet.TLRPC$User",
                        "org.telegram.ui.ActionBar.BaseFragment", "android.content.Context", "org.telegram.ui.ActionBar.AlertDialog",
                        "org.telegram.messenger.AccountInstance", "org.telegram.messenger.MessagesController",
                        "org.telegram.tgnet.TLRPC$Chat", "org.telegram.messenger.NotificationCenter",
                        "org.telegram.messenger.NotificationCenter$NotificationCenterDelegate",
                         "android.content.res.Resources", "android.content.res.Configuration",
                         "android.util.DisplayMetrics", "android.util.TypedValue",
                         "org.telegram.ui.ActionBar.Theme",
                         "org.telegram.ui.Components.BulletinFactory", "org.telegram.ui.Components.Bulletin",
                         "org.telegram.ui.PhotoViewer", "android.widget.Toast",
                          "org.telegram.messenger.LocaleController", "org.telegram.messenger.LocaleController$LocaleInfo",
                          "org.telegram.messenger.browser.Browser",
                         "org.telegram.messenger.ApplicationLoader", "org.telegram.messenger.AndroidUtilities"}
NATIVE_PREFIXES = ("android.", "androidx.", "java.", "javax.", "org.telegram.", "com.")
HOOKS = {"hook_method", "hook_all_methods", "hook_all_constructors", "add_hook", "add_on_send_message_hook",
         "add_on_request_hook", "add_on_response_hook", "hook_request", "hook_response"}
EVENTS = {"on_app_event", "on_send_message_hook", "on_request_hook", "on_response_hook"}
MAX_BYTES = 4 * 1024 * 1024
MAX_FILES = 4096
CATALOG_RELATIVE = "submodules/AyuPluginBridge/Resources/CommonBridge/compatibility.json"


class AuditError(ValueError):
    """Fixed errors only: never disclose inspected source or exception text."""


def read_bytes(path, limit=MAX_BYTES):
    if path.is_symlink() or getattr(path, "is_junction", lambda: False)() or not path.is_file():
        raise AuditError("Expected a regular bounded input file")
    with path.open("rb") as stream:
        raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise AuditError("Input exceeds size bound")
    return raw


def parse_ast(raw):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", SyntaxWarning)
        tree = ast.parse(raw, filename="<static-input>")
    if sum(1 for _ in ast.walk(tree)) > 100_000:
        raise AuditError("AST exceeds node bound")
    return tree


def sdk_modules(bridge=None):
    """Read the exact SDK_MODULES literal without importing any SDK module."""
    bridge = BRIDGE if bridge is None else Path(bridge)
    tree = parse_ast(read_bytes(bridge / "Python/ayu_bridge.py"))
    values = []
    for node in tree.body:
        targets = node.targets if isinstance(node, ast.Assign) else [node.target] if isinstance(node, ast.AnnAssign) else []
        if not any(isinstance(target, ast.Name) and target.id == "SDK_MODULES" for target in targets):
            continue
        value = node.value
        if isinstance(value, ast.Call):
            if not (isinstance(value.func, ast.Name) and value.func.id in {"frozenset", "set"}
                    and len(value.args) == 1 and not value.keywords):
                raise AuditError("SDK module inventory must be a literal collection")
            value = value.args[0]
        if not isinstance(value, (ast.Set, ast.List, ast.Tuple)) or not value.elts:
            raise AuditError("SDK module inventory must be a literal collection")
        modules = []
        for item in value.elts:
            if not isinstance(item, ast.Constant) or not isinstance(item.value, str) or not re.fullmatch(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*", item.value, re.ASCII):
                raise AuditError("Invalid SDK module identifier")
            modules.append(item.value)
        if len(modules) > 256 or len(set(modules)) != len(modules):
            raise AuditError("SDK module inventory exceeds bounds or contains duplicates")
        values.append(frozenset(modules))
    if len(values) != 1:
        raise AuditError("SDK module inventory must have exactly one declaration")
    return values[0]


def implementation_hashes(bridge=None):
    """Hash the entire bundled Python and native implementation, never reports/tests."""
    bridge = BRIDGE if bridge is None else Path(bridge)
    paths = []
    entries = 0
    total_bytes = 0
    for folder, suffixes in (
        ("Python", {".py"}), ("Sources", {".swift"}), ("Integration", {".swift"}),
        ("ObjC", {".m", ".mm", ".c", ".h"}), ("PublicHeaders", {".h"}),
    ):
        directory = bridge / folder
        if not directory.is_dir():
            raise AuditError("Implementation source directory missing")
        pending = [(directory, 0)]
        while pending:
            current, depth = pending.pop()
            if depth > 8:
                raise AuditError("Implementation nesting exceeds bound")
            for path in current.iterdir():
                entries += 1
                if entries > 16_384 or path.is_symlink() or getattr(path, "is_junction", lambda: False)():
                    raise AuditError("Implementation tree exceeds bounds or contains links")
                if path.is_dir():
                    if path.name != "__pycache__":
                        pending.append((path, depth + 1))
                elif path.suffix in suffixes:
                    paths.append(path)
                    if len(paths) > MAX_FILES:
                        raise AuditError("Implementation file count exceeds bound")
    result = {}
    for path in sorted(paths):
        raw = read_bytes(path)
        total_bytes += len(raw)
        if total_bytes > 64 * 1024 * 1024:
            raise AuditError("Implementation total bytes exceed bound")
        result[path.relative_to(bridge).as_posix()] = hashlib.sha256(raw).hexdigest()
    return result


def source_provenance(catalog):
    """Immutable source identity only; never treat route/support fields as provenance."""
    if catalog.get("source_repo") != "Nomadvorga/ayugram-src" or catalog.get("source_commit") != SOURCE_COMMIT:
        raise AuditError("Catalog source repository or revision changed")
    plugins = catalog.get("plugins")
    if not isinstance(plugins, list) or not 19 <= len(plugins) <= 256:
        raise AuditError("Catalog source count is invalid")
    records = []
    for plugin in plugins:
        if not isinstance(plugin, dict) or not re.fullmatch(r"[a-z][a-z0-9_]*\.plugin", plugin.get("file", "")):
            raise AuditError("Invalid pinned source name")
        if not re.fullmatch(r"[0-9a-f]{64}", plugin.get("sha256", "")) or not re.fullmatch(r"[0-9a-f]{40}", plugin.get("blob", "")):
            raise AuditError("Invalid pinned source digest")
        if any(type(plugin.get(key)) is not int or plugin[key] <= 0 for key in ("bytes", "lines")):
            raise AuditError("Invalid pinned source size")
        records.append(tuple(plugin[key] for key in ("file", "blob", "sha256", "bytes", "lines")) + (plugin.get("provenance"),))
    if len({record[0] for record in records}) != len(records) or sum(record[4] for record in records) != catalog.get("source_total_lines"):
        raise AuditError("Catalog source names or line total changed")
    return sorted(records)


def committed_catalog():
    completed = subprocess.run(["git", "show", "HEAD:" + CATALOG_RELATIVE], cwd=BRIDGE.parents[1],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=False)
    if completed.returncode or len(completed.stdout) > MAX_BYTES:
        raise AuditError("Committed catalog provenance unavailable")
    return json.loads(completed.stdout)


def refresh_implementation_hashes(catalog_path, plugin_dir, *, provenance=None, bridge=None, write=True):
    """Verify catalog identity and exact original bytes, then change only sdk_sha256."""
    bridge = BRIDGE if bridge is None else Path(bridge)
    catalog = json.loads(read_bytes(Path(catalog_path)))
    anchor = committed_catalog() if provenance is None else provenance
    if source_provenance(catalog) != source_provenance(anchor):
        raise AuditError("Catalog source provenance differs from trusted baseline")
    if catalog.get("plugins_runtime_verified") != [] or catalog.get("device_launch_verified") is not False or catalog.get("native_tests_executed") is not False:
        raise AuditError("Catalog must retain unverified runtime state")
    if catalog.get("execution_verified", False) is not False or catalog.get("runtime_validation_required", True) is not True:
        raise AuditError("Catalog cannot claim execution verification")
    root = Path(plugin_dir).resolve()
    for plugin in catalog["plugins"]:
        path = Path(plugin_dir) / plugin["file"]
        if not path.resolve().is_relative_to(root):
            raise AuditError("Pinned source escapes source directory")
        raw = read_bytes(path)
        blob = hashlib.sha1(b"blob " + str(len(raw)).encode("ascii") + b"\0" + raw).hexdigest()
        if (len(raw), hashlib.sha256(raw).hexdigest(), blob, len(raw.splitlines())) != (
                plugin["bytes"], plugin["sha256"], plugin["blob"], plugin["lines"]):
            raise AuditError("Pinned source bytes do not match catalog provenance")
    sdk_modules(bridge)  # Validate the current module declaration statically.
    catalog["sdk_sha256"] = implementation_hashes(bridge)
    if write:
        Path(catalog_path).write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")
    return catalog


def pinned_import_inventory(raw, tree, modules):
    # These are inspector modules, not the SDK: the SDK is read only as AST.
    sys.path.insert(0, str(BRIDGE.parents[1]))
    from tools.plugin_inspector.corpus import declaration_state, sdk_inventory
    from tools.plugin_inspector.inspector import inspect_source

    report = inspect_source(raw, {"schema_version": 1, "modules": {name: {"status": "unknown"} for name in modules}})
    if "error" in report:
        raise AuditError("Pinned source cannot be inspected within limits")
    sdk = sdk_inventory(BRIDGE / "Python")
    classes = {item["target"] for item in report["findings"]
               if item["category"] in {"java_class_lookup", "java_class_import"} and not item["target"].startswith("<")}
    imported, unsupported = {}, {}
    roots = {name.split(".")[0] for name in modules}
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module and not node.level:
            imported.setdefault(node.module, set()).update(alias.name for alias in node.names)
            if node.module.split(".")[0] in roots and not node.module.startswith(NATIVE_PREFIXES):
                for alias in node.names:
                    if alias.name != "*" and declaration_state(node.module + "." + alias.name, sdk) == "absent":
                        unsupported.setdefault(node.module, set()).add(alias.name)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.split(".")[0] in roots and not alias.name.startswith(NATIVE_PREFIXES) and alias.name not in sdk["modules"]:
                    unsupported.setdefault(alias.name, set()).add("module_unavailable")
    return {"classes": sorted(classes), "imported_symbols": {name: sorted(values) for name, values in sorted(imported.items())},
            "unsupported_sdk_symbols": {name: sorted(values) for name, values in sorted(unsupported.items())},
            "dynamic_class_lookup_lines": sorted({item["line"] for item in report["findings"]
                if item["category"] == "java_class_lookup" and item["target"].startswith("<")})}


def audit(path, record):
    modules = sdk_modules()
    data = read_bytes(path)
    if hashlib.sha256(data).hexdigest() != record["sha256"] or len(data) != record["bytes"]:
        raise AuditError("Pinned source hash or size mismatch")
    tree = parse_ast(data)
    inventory = pinned_import_inventory(data, tree, modules)
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
    external = sorted(name for name in imports if name not in modules
                      and name.split(".")[0] not in getattr(sys, "stdlib_module_names", ())
                      and not name.startswith(NATIVE_PREFIXES))
    native = record["path"] == "atmospheric_snow.plugin" and record["sha256"] == SNOW_SHA256
    partial_features = {"account_identity_and_own_profile"} if classes & {"org.telegram.messenger.UserConfig", "org.telegram.tgnet.TLRPC$User"} else set()
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
    if any(value == "--corpus-dir" or value.startswith("--corpus-dir=") for value in sys.argv[1:]):
        sys.path.insert(0, str(BRIDGE.parents[1]))
        from tools.plugin_inspector.corpus import main as corpus_main

        forwarded = [value.removeprefix("--corpus-dir=") for value in sys.argv[1:] if value != "--corpus-dir"]
        return corpus_main(forwarded)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-manifest", type=Path)
    parser.add_argument("--plugin-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--replace-generated", action="store_true", help="Regenerate the two audit outputs for exactly the same pinned sources")
    parser.add_argument("--refresh-implementation-hashes", action="store_true", help="Verify catalog/committed source provenance and exact source bytes; update sdk_sha256 only")
    parser.add_argument("--catalog", type=Path, default=BRIDGE / "Resources/CommonBridge/compatibility.json")
    parser.add_argument("--check-refresh", action="store_true", help="Validate a requested hash refresh and print counts without writing")
    args = parser.parse_args()
    if args.refresh_implementation_hashes:
        if args.source_manifest or args.output_dir or args.replace_generated:
            parser.error("Hash refresh does not regenerate requirements or the README")
        refreshed = refresh_implementation_hashes(args.catalog, args.plugin_dir, write=not args.check_refresh)
        print(json.dumps({"mode": "implementation_hashes_only", "written": not args.check_refresh,
                          "verified_source_count": len(refreshed["plugins"]),
                          "implementation_files": len(refreshed["sdk_sha256"]),
                          "execution_verified": False, "runtime_validation_required": True}))
        return 0
    if args.check_refresh or not args.source_manifest or not args.output_dir:
        parser.error("Pinned regeneration requires --source-manifest and --output-dir; use --refresh-implementation-hashes for an existing extended catalog")
    manifest = json.loads(read_bytes(args.source_manifest))
    if manifest["repo"] != "Nomadvorga/ayugram-src" or manifest["commit"] != SOURCE_COMMIT:
        raise AuditError("Invalid original-19 source provenance")
    if len(manifest["files"]) != 19 or len({item["path"] for item in manifest["files"]}) != 19:
        raise AuditError("Expected exactly 19 distinct upstream sources")
    for item in manifest["files"]:
        if not re.fullmatch(r"[a-z][a-z0-9_]*\.plugin", item["path"]) or not (args.plugin_dir / item["path"]).resolve().is_relative_to(args.plugin_dir.resolve()):
            raise AuditError("Expected flat pinned plugin filenames within source directory")
    plugins = [audit(args.plugin_dir / item["path"], item) for item in sorted(manifest["files"], key=lambda item: item["path"])]
    if sum(item["lines"] for item in plugins) != 40_950:
        raise AuditError("Original-19 source line count changed")
    result = {"schema_version": 1, "source_repo": manifest["repo"], "source_commit": SOURCE_COMMIT,
               "inspection": "AST-only; supplied plugin code was not imported, compiled or executed",
               "execution_verified": False, "runtime_validation_required": True,
              "device_launch_verified": False, "native_tests_executed": False, "plugins_runtime_verified": [],
               "source_total_lines": 40_950, "sdk_sha256": implementation_hashes(),
              "limitations": ["Declared classes are subsets, not Android runtime parity", "Dynamic names and members require further runtime/API audit",
                               "Application provider supplies only narrow account, visible-context, alert/bulletin and app-lifecycle subsets",
                               "Requests/messages, account notifications, hooks, menus, media, subclassing and graphics remain unsupported",
                               "Required unwired feature families may have partial subsets; consult partially_wired_features, not import success",
                               "Static AST aliases and SDK public declarations do not establish runtime or semantic compatibility"], "plugins": plugins}
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
                if not args.replace_generated:
                    raise AuditError("Different output exists; explicit replacement is required")
                previous = json.loads(read_bytes(args.output_dir / "compatibility.json"))
                if previous["source_commit"] != SOURCE_COMMIT or {(p["file"], p["sha256"]) for p in previous["plugins"]} != {(p["file"], p["sha256"]) for p in plugins}:
                    raise AuditError("Full regeneration cannot replace a different pinned source set")
                target.write_text(text)
        else:
            with target.open("x") as output:
                output.write(text)
    print(json.dumps({"plugins": len(plugins), "lines": 40_950, "runtime_verified": 0,
                      "native_source_pinned": sum(bool(item["native_adapter"]) for item in plugins), "output": str(args.output_dir)}))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuditError, OSError, ValueError, TypeError, KeyError, SyntaxError, RecursionError, MemoryError, subprocess.SubprocessError):
        sys.stderr.write("Audit failed: invalid provenance, source, SDK inventory, implementation files or bounds.\n")
        raise SystemExit(2)
