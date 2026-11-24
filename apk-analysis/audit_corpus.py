"""Offline AST audit of the Android AyuGram plugin corpus against the iOS bridge facade.

Usage:
    PYTHONIOENCODING=utf-8 py apk-analysis/audit_corpus.py "<corpus dir>" [--out apk-analysis]

Reads every .plugin file (text, possibly with encoding noise), parses Python via
`ast`, never executes plugin code, and classifies each plugin:
supported / partial (missing facade symbols listed) / unsupported (reason categories).

Outputs: corpus-audit.json, corpus-audit.md (in --out).
"""
import ast
import json
import re
import sys
import hashlib
from collections import Counter, defaultdict
from pathlib import Path

FACADE_CLASSES = {
    "Integer", "Long", "Boolean", "ArrayList", "HashMap", "AtomicLong", "AtomicBoolean", "System",
    "Bundle", "Intent", "View", "MotionEvent", "Paint", "Canvas", "ColorDrawable", "Runnable", "Handler",
    "TextView", "EditText", "LinearLayout", "FrameLayout", "ImageView", "ScrollView", "CheckBox", "Toast",
    "LayoutParams", "String", "Math", "Toast", "AlertDialog", "Bulletin", "Bitmap", "Color", "ImageView",
    "TextView", "LinearLayout", "FrameLayout", "EditText", "ViewGroup", "TextUtils", "TypedValue",
}
FACADE_PACKAGES = {"android.os", "java.util", "java.lang", "android.graphics", "android.content", "android.view", "android.widget", "org.telegram.messenger", "org.telegram.ui.ActionBar"}
STDLIB_ROOTS = {"json", "re", "time", "os", "sys", "math", "random", "base64", "hashlib", "threading", "datetime",
    "collections", "functools", "typing", "io", "traceback", "secrets", "itertools", "textwrap", "unicodedata",
    "string", "enum", "dataclasses", "abc", "queue", "heapq", "copy", "glob", "shutil", "zipfile", "csv", "uuid",
    "struct", "binascii", "html", "xml", "calendar", "weakref", "inspect", "contextlib", "operator", "zlib",
    "tempfile", "concurrent", "gzip", "bz2", "lzma", "stat", "errno", "platform", "subprocess", "signal",
    "sqlite3", "difflib", "pprint", "reprlib", "types", "warnings", "linecache", "tokenize", "keyword", "array",
    "colorsys", "ast", "ctypes", "dis", "fractions", "numbers", "decimal", "statistics", "zoneinfo", "__future__",
    "ssl", "audioop", "pathlib", "fnmatch", "pickle", "copyreg", "shelve", "marshal", "codecs", "encodings",
    "locale", "gettext", "wave", "chunk", "asyncio", "selectors", "email", "http", "logging", "getopt",
    "argparse", "configparser", "shlex", "code", "codeop", "compileall", "py_compile", "zipapp", "pkgutil",
    "modulefinder", "gc", "atexit", "faulthandler", "timeit", "trace", "pdb", "profile", "cProfile", "doctest",
    "unittest", "bisect", "ipaddress", "mimetypes", "tarfile", "builtins", "symtable", "zipimport", "runpy",
    "imghdr", "uu", "xdrlib", "file_utils", "markdown_utils", "client_utils", "android_utils", "hmac"}
FACADE_MODULES = {"base_plugin", "client_utils", "android_utils", "hook_utils", "java", "jarray", "ui.settings", "ui.alert", "ui.bulletin", "plugin_settings", "requests", "requests.exceptions", "zwylib", "extera_utils", "extera_utils.classes", "extera_utils.lifecycle", "extera_utils.text_formatting"}
PRIVACY_PATTERN = re.compile(r"screenshot|screen_capture|no_screenshot|privacy_hook", re.I)
NATIVE_PATTERN = re.compile(r"(\bMediaCodec\b|\bDEXFile\b|\bDexClassLoader\b|dalvik\.system|java\.lang\.reflect|getDeclaredMethod|\bMyTracker\b|com\.google\.|androidx\.)")
NETWORK_MODULES = {"urllib.request", "requests", "http.client", "aiohttp", "socket"}
THREAD_CALLS = {"Thread", "threading", "run_on_thread"}


def read_text(path: Path):
    for encoding in ("utf-8", "utf-8-sig", "cp1251", "latin-1"):
        try:
            return path.read_text(encoding=encoding)
        except UnicodeDecodeError:
            continue
    return None


def parse(source: str):
    try:
        return ast.parse(source)
    except (SyntaxError, ValueError):
        return None


def walk_names(tree):
    imports, attributes, calls = set(), set(), set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imports.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                imports.add(node.module)
        elif isinstance(node, ast.Attribute):
            names = []
            current = node
            while isinstance(current, ast.Attribute):
                names.append(current.attr)
                current = current.value
            if isinstance(current, ast.Name):
                names.append(current.id)
            if names:
                attributes.add(".".join(reversed(names)))
        elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            calls.add(node.func.id)
    return imports, attributes, calls


def plugin_metadata(source: str, tree):
    meta = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            key = node.targets[0].id
            if key in ("name", "author", "version", "min_api", "description") and isinstance(node.value, ast.Constant):
                meta[key] = str(node.value.value)
    return meta


def classify(path: Path, tree, imports, attributes, calls, source: str):
    missing, reasons = set(), []
    dotted = set(attributes)
    for name in sorted(dotted):
        head = name.split(".")[0]
        if head in FACADE_CLASSES or name in FACADE_CLASSES:
            continue
        module = name.rsplit(".", 1)[0]
        if module in FACADE_MODULES or name in FACADE_MODULES:
            continue
    for module in sorted(imports):
        if module in FACADE_MODULES or module.split(".")[0] in STDLIB_ROOTS:
            continue
        if module in NETWORK_MODULES or module.split(".")[0] in {"urllib"}:
            continue
        if module.startswith(("com.", "android.", "androidx.", "java.", "javax.", "org.", "kotlin.", "dalvik.")):
            # A facade-covered class/package (android.os.Bundle, java.util.ArrayList, …)
            # is an adaptation target, not an unsupported native module.
            leaf = module.rsplit(".", 1)[-1]
            if module in FACADE_PACKAGES or leaf in FACADE_CLASSES:
                continue
            reasons.append(f"native module {module}")
            continue
        missing.add(module)
    for name in sorted(dotted):
        leaf = name.rsplit(".", 1)[-1]
        if name.startswith(("com.", "androidx.", "dalvik.", "android.service", "android.app.Notification", "android.media", "android.webkit")):
            reasons.append(f"native API {name}")
        elif name.startswith(("org.telegram.messenger.AndroidUtilities", "org.telegram.messenger.ApplicationLoader",
                              "org.telegram.messenger.UserConfig", "org.telegram.ui.ActionBar.Theme")):
            continue  # explicitly adapted over the iOS host (dp, palette, account snapshot)
        elif NATIVE_PATTERN.search(name):
            reasons.append(f"reflection/native {name}")
        elif name.startswith(("android.", "java.")) and leaf in FACADE_CLASSES:
            continue  # facade-covered: android.os.Bundle, java.util.ArrayList, …
        elif name.startswith(("android.", "java.")) and name.count(".") >= 1:
            reasons.append(f"native API {name}")
    privacy = PRIVACY_PATTERN.search(source) and any("screenshot" in a.lower() or "capture" in a.lower() for a in dotted)
    if privacy:
        reasons.append("screenshot privacy class")
    for call in sorted(calls):
        if call in {"exec", "eval", "compile"} and "__import__" in source:
            reasons.append("dynamic import")
    return missing, reasons


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out_dir = Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else Path(__file__).parent
    corpus = Path(args[0]) if args else Path("/c/Users/PC/Downloads/Telegram Desktop/ChatExport_2026-11-24/files")
    files = sorted(p for p in corpus.iterdir() if p.suffix == ".plugin")
    records, failed = [], []
    fingerprints = defaultdict(list)
    for path in files:
        source = read_text(path)
        if source is None:
            failed.append({"file": path.name, "reason": "undecodable"})
            continue
        tree = parse(source)
        if tree is None:
            failed.append({"file": path.name, "reason": "unparsable"})
            continue
        imports, attributes, calls = walk_names(tree)
        meta = plugin_metadata(source, tree)
        missing, reasons = classify(path, tree, imports, attributes, calls, source)
        uses_threads = bool(THREAD_CALLS & calls) or "threading" in imports
        uses_network = bool(NETWORK_MODULES & imports) or any(a.startswith(("urllib", "requests", "http")) for a in attributes)
        uses_webview = any("WebView" in a for a in attributes)
        settings_rows = sum(1 for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id.startswith("setting"))
        hooks = [node.targets[0].id for node in ast.walk(tree) if isinstance(node, ast.FunctionDef) and any(isinstance(d, ast.Attribute) and d.attr in ("on_send", "on_receive", "hook") or isinstance(d, ast.Name) and d.id == "hook" for d in node.decorator_list)]
        verdict = "supported"
        if reasons:
            verdict = "unsupported" if any(r.startswith(("native ", "screenshot", "reflection")) for r in reasons) else "partial"
        elif missing:
            verdict = "partial"
        records.append({
            "file": path.name, "name": meta.get("name", path.stem), "author": meta.get("author"),
            "version": meta.get("version"), "imports": sorted(imports), "missing_modules": sorted(missing),
            "reasons": sorted(set(reasons)), "uses_threads": uses_threads, "uses_network": uses_network,
            "uses_webview": uses_webview, "settings_rows": settings_rows, "verdict": verdict,
            "sha256": hashlib.sha256(source.encode("utf-8", "ignore")).hexdigest()[:16],
        })
        fingerprints[records[-1]["sha256"]].append(path.name)

    verdicts = Counter(r["verdict"] for r in records)
    top_missing = Counter(m for r in records for m in r["missing_modules"]).most_common(20)
    top_reasons = Counter(reason for r in records for reason in r["reasons"]).most_common(20)
    duplicates = {sha: names for sha, names in fingerprints.items() if len(names) > 1}
    valuable = sorted(
        (r for r in records if r["verdict"] == "supported" or (r["verdict"] == "partial" and len(r["missing_modules"]) <= 2 and not r["reasons"])),
        key=lambda r: -(r["settings_rows"] + int(r["uses_network"]) + int(r["uses_threads"])),
    )[:20]
    report = {"corpus_dir": str(corpus), "files_seen": len(files), "parsed": len(records), "failed": failed,
              "verdicts": dict(verdicts), "top_missing_modules": top_missing, "top_reasons": top_reasons,
              "near_duplicate_clusters": duplicates, "most_valuable": [r["file"] for r in valuable],
              "records": records}
    (out_dir / "corpus-audit.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    lines = [
        "# Corpus audit (Android plugins → iOS bridge facade)", "",
        f"- Files seen: **{len(files)}**, parsed: **{len(records)}**, failed: **{len(failed)}**",
        f"- Verdicts: supported **{verdicts.get('supported', 0)}**, partial **{verdicts.get('partial', 0)}**, unsupported **{verdicts.get('unsupported', 0)}**",
        f"- Reachable today (supported): **{100 * verdicts.get('supported', 0) // max(1, len(records))}%**;", "",
        "## Top missing facade modules", "",
    ]
    lines += [f"1. `{name}` — {count} plugin(s)" for name, count in top_missing] or ["- none"]
    lines += ["", "## Top unsupported reasons", ""] + ([f"1. {name} — {count}" for name, count in top_reasons] or ["- none"])
    lines += ["", "## Near-duplicate clusters", ""] + [f"- {sha}: {', '.join(names)}" for sha, names in sorted(duplicates.items(), key=lambda kv: -len(kv[1]))[:15]] or []
    lines += ["", "## Most valuable plugins to make work", ""] + [f"- {name}" for name in [r["file"] for r in valuable]]
    (out_dir / "corpus-audit.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({"parsed": len(records), "failed": len(failed), "verdicts": dict(verdicts)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
