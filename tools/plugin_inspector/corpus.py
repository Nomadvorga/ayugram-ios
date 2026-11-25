"""Bounded static corpus inventory; ZIP members are never extracted or loaded."""
from __future__ import annotations

import argparse
import ast
from collections import Counter, defaultdict
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import warnings
from typing import Any
import zipfile
import zlib

from .inspector import (
    JAVA_PREFIXES, MAX_NODES, MAX_SOURCE_BYTES, SDK_ROOTS, ManifestError,
    inspect_source, load_manifest, safe_symbol,
)

MAX_FILES = 2048
MAX_DIRECTORY_ENTRIES = 8192
MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 4096
MAX_ARCHIVE_EXPANDED_BYTES = 64 * 1024 * 1024
MAX_CORPUS_BYTES = 256 * 1024 * 1024
MAX_REQUIREMENTS = 20_000
MAX_SOURCE_UNITS = 8192
MAX_RANK = 200
EXTENSIONS = {".plugin", ".elyx", ".eaf"}
MEMBER_KINDS = {
    ".py": "python_source", ".plugin": "plugin_source", ".pyc": "python_bytecode",
    ".pyo": "python_bytecode", ".so": "native_binary", ".dylib": "native_binary",
    ".dll": "native_binary", ".dex": "android_bytecode", ".jar": "nested_archive",
    ".zip": "nested_archive", ".json": "json_data", ".xml": "xml_data",
    ".png": "image", ".jpg": "image", ".jpeg": "image", ".webp": "image",
    ".svg": "image", ".ttf": "font", ".otf": "font", ".md": "text",
    ".txt": "text", ".html": "web_content", ".js": "web_content",
    ".css": "web_content", ".wasm": "wasm_binary",
}


class CorpusError(ValueError):
    """Fixed, non-sensitive inventory failure."""


def is_link(path: Path) -> bool:
    return path.is_symlink() or getattr(path, "is_junction", lambda: False)()


def bounded_read(path: Path, limit: int) -> bytes:
    if is_link(path) or not path.is_file():
        raise CorpusError("Input must be a regular file.")
    with path.open("rb") as stream:
        raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise CorpusError("Input exceeds size limit.")
    return raw


def parse_tree(raw: bytes) -> ast.Module | None:
    if len(raw) > MAX_SOURCE_BYTES:
        return None
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", SyntaxWarning)
            tree = ast.parse(raw, filename="<static-input>")
        if sum(1 for _ in ast.walk(tree)) > MAX_NODES:
            return None
        return tree
    except (SyntaxError, UnicodeError, ValueError, RecursionError, MemoryError):
        return None


def declarations(tree: ast.Module) -> set[str]:
    """Declared/re-exported public module/class names, never implementation claims."""
    result: set[str] = set()

    def visit(body: list[ast.stmt], prefix: str = "", depth: int = 0) -> None:
        if depth > 16:
            raise CorpusError("SDK declaration nesting exceeds limit.")
        for node in body:
            names: list[str] = []
            if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                names = [node.name]
            elif isinstance(node, (ast.Assign, ast.AnnAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                names = [target.id for target in targets if isinstance(target, ast.Name)]
            elif isinstance(node, (ast.Import, ast.ImportFrom)):
                names = [alias.asname or alias.name.split(".")[0] for alias in node.names if alias.name != "*"]
            for name in names:
                if not name.startswith("_") and safe_symbol(name) == name:
                    result.add(prefix + name)
            if isinstance(node, ast.ClassDef) and not node.name.startswith("_"):
                visit(node.body, prefix + node.name + ".", depth + 1)
            if isinstance(node, ast.If):
                visit(node.body, prefix, depth + 1)
                visit(node.orelse, prefix, depth + 1)
            elif isinstance(node, ast.Try):
                for body in [node.body, node.orelse, node.finalbody] + [h.body for h in node.handlers]:
                    visit(body, prefix, depth + 1)

    visit(tree.body)
    return result


def sdk_inventory(directory: Path | None) -> dict[str, Any]:
    """Traverse only an explicit SDK tree, with bounds and without symlink following."""
    if directory is None:
        return {"available": False, "modules": {}, "fingerprint": None, "files": 0}
    if is_link(directory) or not directory.is_dir():
        raise CorpusError("SDK directory unavailable.")
    modules: dict[str, set[str]] = {}
    star_exports: dict[str, set[str]] = defaultdict(set)
    hashes = []
    pending = [(directory, 0)]
    entries = 0
    total_bytes = 0
    while pending:
        current, depth = pending.pop()
        if depth > 8:
            raise CorpusError("SDK directory nesting exceeds limit.")
        for path in current.iterdir():
            entries += 1
            if entries > MAX_DIRECTORY_ENTRIES or is_link(path):
                raise CorpusError("SDK directory exceeds limits or contains symlinks.")
            if path.is_dir():
                if path.name != "__pycache__":
                    pending.append((path, depth + 1))
                continue
            if path.suffix != ".py":
                continue
            if len(hashes) >= MAX_FILES:
                raise CorpusError("SDK file count exceeds limit.")
            parts = list(path.relative_to(directory).with_suffix("").parts)
            if parts[-1] == "__init__":
                parts.pop()
            module = ".".join(parts)
            if not module or safe_symbol(module) != module:
                continue
            raw = bounded_read(path, MAX_SOURCE_BYTES)
            total_bytes += len(raw)
            if total_bytes > MAX_CORPUS_BYTES:
                raise CorpusError("SDK exceeds total read limit.")
            tree = parse_tree(raw)
            if tree is None:
                raise CorpusError("SDK source cannot be parsed within limits.")
            modules[module] = declarations(tree)
            for node in tree.body:
                if isinstance(node, ast.ImportFrom) and any(alias.name == "*" for alias in node.names):
                    target = node.module or ""
                    if node.level:
                        package = module.split(".") if path.name == "__init__.py" else module.split(".")[:-1]
                        if node.level > len(package):
                            raise CorpusError("SDK relative export escapes package.")
                        target = ".".join(package[:len(package) - node.level + 1] + ([target] if target else []))
                    star_exports[module].add(target)
            hashes.append([module, hashlib.sha256(raw).hexdigest()])
    if not hashes:
        raise CorpusError("SDK contains no Python source.")
    # Resolve only declarations from files already inspected in the explicit SDK
    # tree. This is a conservative public-name union; __all__ is not evaluated.
    for _ in range(16):
        changed = False
        for module in sorted(star_exports):
            for target in sorted(star_exports[module]):
                before = len(modules[module])
                modules[module].update(modules.get(target, set()))
                changed |= len(modules[module]) != before
        if not changed:
            break
    else:
        raise CorpusError("SDK wildcard export nesting exceeds limit.")
    digest = hashlib.sha256(json.dumps(sorted(hashes), separators=(",", ":")).encode()).hexdigest()
    return {"available": True, "modules": modules, "fingerprint": digest, "files": len(hashes)}


class Rankings:
    def __init__(self) -> None:
        self.occurrences: dict[str, Counter[str]] = defaultdict(Counter)
        self.files: dict[str, dict[str, set[int]]] = defaultdict(lambda: defaultdict(set))
        self.sources: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
        self.target_count = 0

    def add(self, kind: str, target: str, file_index: int, digest: str) -> None:
        if safe_symbol(target) != target:
            return
        if target not in self.occurrences[kind]:
            self.target_count += 1
            if self.target_count > MAX_REQUIREMENTS:
                raise CorpusError("Requirement inventory exceeds limit.")
        self.occurrences[kind][target] += 1
        self.files[kind][target].add(file_index)
        self.sources[kind][target].add(digest)

    def rows(self, kind: str, limit: int) -> dict[str, Any]:
        targets = sorted(self.occurrences[kind], key=lambda target: (
            -len(self.files[kind][target]), -len(self.sources[kind][target]), target,
        ))
        return {"distinct_targets": len(targets), "omitted_targets": max(0, len(targets) - limit), "ranked": [
            {"api": target, "files": len(self.files[kind][target]),
             "unique_sources": len(self.sources[kind][target]), "occurrences": self.occurrences[kind][target]}
            for target in targets[:limit]
        ]}


def declaration_state(target: str, sdk: dict[str, Any]) -> str:
    if not sdk["available"]:
        return "not_compared"
    modules = sdk["modules"]
    if target in modules:
        return "declared"
    parts = target.split(".")
    for index in range(len(parts) - 1, 0, -1):
        module = ".".join(parts[:index])
        if module in modules:
            return "declared" if ".".join(parts[index:]) in modules[module] else "absent"
    return "absent"


def inventory_corpus(directory: Path, *, android_sdk: Path | None = None,
                     bridge_sdk: Path | None = None, manifest: dict[str, Any] | None = None,
                     rank_limit: int = 100) -> dict[str, Any]:
    if not 1 <= rank_limit <= MAX_RANK:
        raise CorpusError("Invalid rank limit.")
    if is_link(directory) or not directory.is_dir():
        raise CorpusError("Corpus directory unavailable.")
    paths = []
    for index, path in enumerate(directory.iterdir()):
        if index >= MAX_DIRECTORY_ENTRIES:
            raise CorpusError("Corpus directory exceeds entry limit.")
        if path.suffix.lower() in EXTENSIONS:
            if is_link(path) or not path.is_file():
                raise CorpusError("Attachment must be a regular file.")
            paths.append(path)
            if len(paths) > MAX_FILES:
                raise CorpusError("Attachment count exceeds limit.")
    android = sdk_inventory(android_sdk)
    bridge = sdk_inventory(bridge_sdk)
    manifest = load_manifest() if manifest is None else manifest
    rankings = Rankings()
    counts: dict[str, Counter[str]] = defaultdict(Counter)
    parsed_attachments: set[int] = set()
    archive_payload_attachments: dict[str, set[int]] = defaultdict(set)
    source_hashes: set[str] = set()
    plugin_hashes: set[str] = set()
    fingerprints = []
    total_bytes = 0
    source_count = 0
    parsed_count = 0
    total_lines = 0

    def feature(target: str, file_index: int, digest: str) -> None:
        rankings.add("features", target, file_index, digest)

    def source(raw: bytes, file_index: int, attachment_kind: str) -> None:
        nonlocal source_count, parsed_count, total_lines
        source_count += 1
        if source_count > MAX_SOURCE_UNITS:
            raise CorpusError("Source unit count exceeds limit.")
        counts["source_units_by_attachment_type"][attachment_kind] += 1
        digest = hashlib.sha256(raw).hexdigest()
        source_hashes.add(digest)
        if attachment_kind == ".plugin":
            plugin_hashes.add(digest)
        report = inspect_source(raw, manifest)
        if "error" in report:
            counts["source_errors"][report["error"]["code"]] += 1
            return
        tree = parse_tree(raw)
        if tree is None:
            counts["source_errors"]["parse_or_ast_limit"] += 1
            return
        parsed_count += 1
        parsed_attachments.add(file_index)
        total_lines += len(raw.splitlines())
        counts["parsed_lines_by_attachment_type"][attachment_kind] += len(raw.splitlines())
        counts["static_status"][report["status"]] += 1
        for item in report["findings"]:
            category, target = item["category"], item["target"]
            counts["finding_categories"][category] += 1
            if category == "feature":
                feature(target, file_index, digest)
            elif category in {"java_class_lookup", "java_class_import"}:
                rankings.add("java_classes", target, file_index, digest)
                for prefix, family in (
                    ("android.graphics.", "android_graphics"), ("android.view.", "android_views"),
                    ("android.widget.", "android_views"), ("android.hardware.", "android_hardware"),
                    ("android.media.", "android_media"), ("org.telegram.ui.", "telegram_android_ui"),
                    ("org.telegram.tgnet.", "telegram_tl_objects"),
                    ("org.telegram.messenger.", "telegram_controllers"),
                ):
                    if target.startswith(prefix):
                        feature(family, file_index, digest)
            elif category in {"java_member", "reflection_target", "hook_target"}:
                rankings.add("java_members", target, file_index, digest)
            elif category == "bridge_call":
                if target.startswith(JAVA_PREFIXES) and not (target.startswith("java.") and target.count(".") == 1):
                    rankings.add("unresolved_java_calls", target, file_index, digest)
                else:
                    rankings.add("sdk_calls", target, file_index, digest)
            elif category in {"declared_dependency", "native_dependency", "platform_restriction"}:
                rankings.add(category, target, file_index, digest)
        # Import syntax is inventoried independently of support declarations.
        for node in ast.walk(tree):
            imports: list[str] = []
            symbols: list[str] = []
            if isinstance(node, ast.Import):
                imports = [alias.name for alias in node.names]
            elif isinstance(node, ast.ImportFrom):
                if node.level:
                    feature("relative_import", file_index, digest)
                    continue
                imports = [node.module or ""]
                symbols = [(node.module + "." + alias.name) for alias in node.names
                           if node.module and alias.name != "*"]
            for module in imports:
                rankings.add("imports", module, file_index, digest)
                root = module.split(".")[0]
                kind = ("java_namespaces" if module.startswith(JAVA_PREFIXES) else "sdk_imports"
                        if root in SDK_ROOTS else "stdlib_imports"
                        if root in sys.stdlib_module_names else "external_imports")
                rankings.add(kind, module, file_index, digest)
                if root in {"threading", "_thread", "concurrent"}:
                    feature("plugin_threads", file_index, digest)
                if root in {"elyxcore", "elyx"}:
                    feature("elyx_package_runtime", file_index, digest)
            for symbol in symbols:
                if symbol.split(".")[0] in SDK_ROOTS:
                    rankings.add("sdk_symbols", symbol, file_index, digest)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in {
                "on_plugin_load", "on_plugin_unload", "on_app_event", "on_send_message_hook",
                "pre_request_hook", "post_request_hook", "on_update_hook", "on_updates_hook",
                "create_settings", "create_menu_items",
            }:
                rankings.add("lifecycle_overrides", node.name, file_index, digest)

    for file_index, path in enumerate(sorted(paths, key=lambda item: item.name)):
        extension = path.suffix.lower()
        counts["attachments"][extension] += 1
        raw = bounded_read(path, MAX_SOURCE_BYTES if extension == ".plugin" else MAX_ARCHIVE_BYTES)
        total_bytes += len(raw)
        if total_bytes > MAX_CORPUS_BYTES:
            raise CorpusError("Corpus exceeds total read limit.")
        fingerprints.append([extension, hashlib.sha256(raw).hexdigest(), len(raw)])
        if extension == ".plugin":
            source(raw, file_index, extension)
            continue
        try:
            # Reject excessive central-directory counts before ZipFile allocates
            # one ZipInfo per entry. ZIP64 is intentionally outside these bounds.
            end = raw.rfind(b"PK\x05\x06", max(0, len(raw) - 65_557))
            if end >= 0 and end + 22 <= len(raw):
                declared_count = int.from_bytes(raw[end + 10:end + 12], "little")
                if declared_count > MAX_ARCHIVE_MEMBERS:
                    raise CorpusError("Archive member count exceeds limit.")
            with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                infos = archive.infolist()
                if len(infos) > MAX_ARCHIVE_MEMBERS or sum(i.file_size for i in infos) > MAX_ARCHIVE_EXPANDED_BYTES:
                    raise CorpusError("Archive exceeds member or expansion limit.")
                counts["archive_formats"][extension + ".zip"] += 1
                for info in infos:
                    if info.is_dir():
                        continue
                    name = PurePosixPath(info.filename.replace("\\", "/"))
                    unsafe = (name.is_absolute() or ".." in name.parts or ":" in info.filename
                              or stat.S_ISLNK(info.external_attr >> 16) or bool(info.flag_bits & 1))
                    if unsafe:
                        counts["archive_issues"]["unsafe_or_encrypted_member"] += 1
                        continue
                    kind = MEMBER_KINDS.get(name.suffix.lower(), "other_data")
                    counts["archive_member_kinds"][kind] += 1
                    archive_payload_attachments[kind].add(file_index)
                    if kind in {"python_source", "plugin_source"}:
                        if info.file_size > MAX_SOURCE_BYTES:
                            counts["source_errors"]["archive_source_too_large"] += 1
                            continue
                        with archive.open(info) as stream:
                            member = stream.read(MAX_SOURCE_BYTES + 1)
                        if len(member) > MAX_SOURCE_BYTES:
                            raise CorpusError("Archive source exceeds limit.")
                        total_bytes += len(member)
                        if total_bytes > MAX_CORPUS_BYTES:
                            raise CorpusError("Corpus exceeds total read limit.")
                        source(member, file_index, extension)
        except (zipfile.BadZipFile, NotImplementedError, RuntimeError, OSError, EOFError, ValueError, zlib.error) as error:
            if isinstance(error, CorpusError):
                raise
            counts["archive_issues"]["unreadable_archive"] += 1

    ranked = {kind: rankings.rows(kind, rank_limit) for kind in sorted(rankings.occurrences)}
    for kind in ("sdk_imports", "sdk_symbols", "sdk_calls"):
        for row in ranked.get(kind, {}).get("ranked", []):
            row["android_declaration"] = declaration_state(row["api"], android)
            row["bridge_declaration"] = declaration_state(row["api"], bridge)
    gaps = []
    for target in set(rankings.occurrences["sdk_symbols"]) | set(rankings.occurrences["sdk_calls"]):
        if declaration_state(target, android) == "declared" and declaration_state(target, bridge) == "absent":
            gaps.append({"api": target,
                         "files": len(rankings.files["sdk_symbols"][target] | rankings.files["sdk_calls"][target]),
                         "unique_sources": len(rankings.sources["sdk_symbols"][target] | rankings.sources["sdk_calls"][target])})
    gaps.sort(key=lambda row: (-row["files"], -row["unique_sources"], row["api"]))
    ranked["android_declared_bridge_absent"] = {
        "distinct_targets": len(gaps), "omitted_targets": max(0, len(gaps) - rank_limit), "ranked": gaps[:rank_limit]}
    fingerprint = hashlib.sha256(json.dumps(sorted(fingerprints), separators=(",", ":")).encode()).hexdigest()
    return {
        "schema_version": 1, "inspection": "bounded_static_ast_and_archive_metadata_only",
        "inventory_python_version": ".".join(str(part) for part in sys.version_info[:3]),
        "execution_verified": False, "runtime_validation_required": True,
        "corpus_sha256": fingerprint,
        "statistics": {
            "attachments": len(paths), "attachment_types": dict(sorted(counts["attachments"].items())),
            "source_units": source_count, "parsed_source_units": parsed_count,
            "attachments_with_parsed_source": len(parsed_attachments),
            "unique_source_units": len(source_hashes), "unique_plugin_sources": len(plugin_hashes),
            "parsed_source_lines": total_lines, "bytes_read": total_bytes,
            "archive_payload_attachments": {kind: len(files) for kind, files in sorted(archive_payload_attachments.items())},
            **{name: dict(sorted(counts[name].items())) for name in (
                "source_errors", "static_status", "finding_categories", "archive_formats",
                "archive_member_kinds", "archive_issues", "source_units_by_attachment_type",
                "parsed_lines_by_attachment_type")},
        },
        "sdk_comparison": {
            label: {"available": sdk["available"], "source_files": sdk["files"],
                    "declaration_sha256": sdk["fingerprint"]}
            for label, sdk in (("android", android), ("bridge", bridge))
        },
        "rank_limit": rank_limit, "requirements": ranked,
        "limitations": [
            "Counts describe attachment reach, not compatible plugins or complete feature coverage.",
            "Duplicate source bytes count in files; unique_sources deduplicates bytes, not plugin identities or versions.",
            "Archive source is parsed in memory; assets are classified by extension without extraction or validation.",
            "SDK declaration presence is not implementation, semantic parity, runtime support or a positive support manifest.",
            "Standard-library grouping uses the inventory interpreter's module-name list, not embedded iOS availability.",
            "All branches and function bodies contribute; dynamic names, inherited members and external modules are not resolved.",
            "Reported targets are bounded API identifiers; source, arbitrary literals, member paths and input paths are omitted.",
        ],
    }


def render_markdown(report: dict[str, Any]) -> str:
    stats = report["statistics"]
    lines = ["# Supplied plugin corpus: static compatibility inventory", "",
             "`execution_verified: false`; `runtime_validation_required: true`.", "",
             f"Corpus fingerprint: `{report['corpus_sha256']}`.", "",
             f"{stats['attachments']} attachments; {stats['parsed_source_units']}/{stats['source_units']} source units parsed; "
             f"{stats['unique_plugin_sources']} unique standalone plugin sources; {stats['parsed_source_lines']:,} parsed source lines.", "",
             "SDK declarations and API reach are inventory evidence only. No supplied code was imported or executed.", ""]
    for kind, value in sorted(report["requirements"].items()):
        lines += ["## " + kind.replace("_", " "), "",
                  "| API | Attachments | Unique sources | Android declaration | Bridge declaration |",
                  "| --- | ---: | ---: | --- | --- |"]
        for row in value["ranked"]:
            lines.append(f"| `{row['api']}` | {row['files']} | {row['unique_sources']} | "
                         f"{row.get('android_declaration', '')} | {row.get('bridge_declaration', '')} |")
        lines += ["", f"{value['omitted_targets']} further targets omitted by the report bound.", ""]
    lines += ["## Limitations", ""] + ["- " + value for value in report["limitations"]] + [""]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--android-sdk", type=Path)
    parser.add_argument("--bridge-sdk", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--rank-limit", type=int, default=100)
    parser.add_argument("--format", choices=("json", "markdown"), default="json")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.output:
            resolved = args.output.resolve()
            for protected in (args.directory, args.android_sdk, args.bridge_sdk):
                if protected and resolved.is_relative_to(protected.resolve()):
                    raise CorpusError("Output must be outside input directories.")
            manifest_path = args.manifest or Path(__file__).with_name("support-manifest.json")
            if (resolved == manifest_path.resolve() or
                    (args.output.exists() and manifest_path.exists() and args.output.samefile(manifest_path))):
                raise CorpusError("Output must not overwrite manifest.")
            if args.output.exists():
                if args.output.stat().st_nlink > 1:
                    raise CorpusError("Output must not be a hard-link alias.")
                for path in args.directory.iterdir():
                    if path.is_file() and args.output.samefile(path):
                        raise CorpusError("Output must not alias an input.")
        report = inventory_corpus(args.directory, android_sdk=args.android_sdk,
                                  bridge_sdk=args.bridge_sdk, manifest=load_manifest(args.manifest),
                                  rank_limit=args.rank_limit)
        text = (json.dumps(report, ensure_ascii=True, indent=2) + "\n"
                if args.format == "json" else render_markdown(report))
        if args.output:
            args.output.write_text(text, encoding="utf-8", newline="\n")
        else:
            sys.stdout.write(text)
        return 2 if report["statistics"]["source_errors"] or report["statistics"]["archive_issues"] else 0
    except (OSError, CorpusError, ManifestError, RecursionError, MemoryError):
        sys.stderr.write("Corpus inspection failed: input, output, SDK declarations or bounds invalid.\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
