"""Corpus preflight meter: the bridge's own static preflight over a plugin directory.

Unlike the corpus inventory this imports the bridge SDK (repository code) and
asks ``Runtime.preflight_plugin_json`` for the blockers of every immediate
``.plugin`` file. Plugin source is only parsed by that preflight; it is never
imported or executed. Host capabilities are answered by a stand-in
``_ayu_host`` that serves ``runtime.capabilities`` alone, so the SDK validates
them and resolves Python-local classes exactly as it does on a device.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import contextlib
import json
from pathlib import Path
import re
import sys
import types
from typing import Any, Iterator
import warnings

from .corpus import MAX_CORPUS_BYTES, MAX_DIRECTORY_ENTRIES, MAX_FILES, CorpusError, bounded_read, is_link
from .inspector import MAX_SOURCE_BYTES
from .swift_members import scrape_members

DEFAULT_BRIDGE = Path(__file__).resolve().parents[2] / "submodules/AyuPluginBridge"
MAX_SWIFT_BYTES = 4 * 1024 * 1024
MAX_SWIFT_FILES = 256
MAX_CAPABILITY_BYTES = 4 * 1024 * 1024
MAX_TOP = 200
METADATA_KEYS = ("__min_version__", "__app_version__", "__sdk_version__", "__requirements__")
PACKAGE_SUFFIXES = (".elyx", ".eaf")
_STRING = r'"((?:[^"\\\n]|\\.)*)"'
_JAVA_CLASS = re.compile(
    r'"((?:android|androidx|org|java|javax|com|dalvik|kotlin|de)\.(?:[A-Za-z_][A-Za-z0-9_]*\.)*'
    r'[A-Z][A-Za-z0-9_]*(?:\$[A-Za-z_][A-Za-z0-9_]*)*)"')
_OPERATION_LISTS = re.compile(r"\blet\s+(?:operations|capabilities)\s*=\s*\[([^\]]*)\]")
_MODULE_LIST = re.compile(r"\bstatic\s+let\s+modules\s*=\s*\[([^\]]*)\]")
_PROXY_TABLE = re.compile(r"\bstatic\s+let\s+proxyInterfaces\s*:\s*\[String:\s*\[String\]\]\s*=\s*\[(.*)\]\s*$", re.M)
_PROXY_ENTRY = re.compile(_STRING + r"\s*:\s*\[([^\]]*)\]")
# Report text is limited to API-like identifiers; other literals are never echoed.
_PRINTABLE = re.compile(r"[A-Za-z0-9_.$:\- <>=!~,;*+\[\]()]{1,160}\Z")
UNPRINTABLE = "<unprintable>"


class PreflightError(ValueError):
    """Meter failure whose text never derives from a plugin or an input path."""


def _sdk_failure(stage: str, error: BaseException) -> PreflightError:
    # Raised before any plugin is read, so the text is repository SDK text only.
    detail = " ".join(str(error).split())[:300]
    return PreflightError(f"Bridge SDK {stage}: {type(error).__name__}" + (f": {detail}" if detail else ""))


def _strings(text: str) -> list[str]:
    return [value for value in re.findall(_STRING, text) if "\\" not in value]


def scrape_capabilities(bridge: Path) -> dict[str, Any]:
    """Host capabilities read from Swift literals, without compiling Swift.

    Operations, modules and proxy interfaces come from their declaration
    literals. Classes are every Java-class-shaped string literal in the host
    sources, less the adapters a file's ``enabled`` filter leaves unregistered:
    an upper bound of the registered adapters. ``members`` lists the classes
    whose adapter literals ``swift_members`` resolves; the others have unknown
    members.
    """
    return scrape_host(bridge)[0]


def scrape_host(bridge: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    """``scrape_capabilities`` and how the member table was obtained."""
    operations, modules, classes, proxies = set(), set(), set(), {}
    sources = {}
    paths = []
    for folder in ("Sources", "Integration"):
        directory = bridge / folder
        if is_link(directory) or not directory.is_dir():
            raise PreflightError("Bridge host sources are unavailable.")
        paths += sorted(path for path in directory.iterdir() if path.suffix == ".swift")
    if not paths or len(paths) > MAX_SWIFT_FILES:
        raise PreflightError("Bridge host sources are unavailable.")
    for path in paths:
        try:
            text = bounded_read(path, MAX_SWIFT_BYTES).decode("utf-8")
        except (CorpusError, OSError, UnicodeError) as error:
            raise PreflightError("Bridge host sources are unavailable.") from error
        sources[path.parent.name + "/" + path.name] = text
        text = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))
        for body in _OPERATION_LISTS.findall(text):
            operations.update(_strings(body))
        for body in _MODULE_LIST.findall(text):
            modules.update(_strings(body))
        for body in _PROXY_TABLE.findall(text):
            for name, methods in _PROXY_ENTRY.findall(body):
                proxies[name] = _strings(methods)
        classes.update(_JAVA_CLASS.findall(text))
    classes.update(proxies)
    if not operations or not classes:
        raise PreflightError("Bridge host sources declare no capabilities.")
    members = scrape_members(sources)
    classes.difference_update(members["disabled"])
    classes.update(proxies)
    capabilities = {"operations": sorted(operations), "classes": sorted(classes), "modules": sorted(modules),
                    "proxy_interfaces": {name: proxies[name] for name in sorted(proxies)}}
    table = {name: entry for name, entry in members["table"]["classes"].items() if name in classes}
    if table:
        capabilities["members"] = {"version": members["table"]["version"], "classes": table}
    return capabilities, {"classes_with_members": len(table),
                          "upper_bound_classes": len(set(members["upper_bound"]).intersection(table)),
                          "classes_without_members": len(classes) - len(table)}


def load_capabilities(path: Path) -> dict[str, Any]:
    """An explicit ``runtime.capabilities`` result, e.g. captured from a device."""
    try:
        value = json.loads(bounded_read(path, MAX_CAPABILITY_BYTES).decode("utf-8"))
    except (CorpusError, OSError, UnicodeError, ValueError, RecursionError) as error:
        raise PreflightError("Capability file is unavailable or invalid.") from error
    if not isinstance(value, dict):
        raise PreflightError("Capability file is unavailable or invalid.")
    return value


@contextlib.contextmanager
def bridge_runtime(sdk: Path, capabilities: dict[str, Any]) -> Iterator[Any]:
    """A bridge ``Runtime`` whose only host answer is the given capability set."""
    sdk = sdk.resolve()
    if not (sdk / "ayu_bridge.py").is_file():
        raise PreflightError("Bridge SDK is unavailable.")
    payload = json.dumps(capabilities, allow_nan=False)

    def dispatch(text):
        request = json.loads(text)
        answer = {"version": request["version"], "id": request["id"]}
        if request["operation"] == "runtime.capabilities":
            answer["result"] = json.loads(payload)
        else:
            answer["error"] = {"code": "UNSUPPORTED_API", "message": "The preflight meter has no host"}
        return json.dumps(answer)

    host = types.ModuleType("_ayu_host")
    host.dispatch = dispatch
    missing = object()
    saved_path, saved_host, saved_flag = list(sys.path), sys.modules.get("_ayu_host", missing), sys.dont_write_bytecode
    sys.path.insert(0, str(sdk))
    sys.modules["_ayu_host"] = host
    sys.dont_write_bytecode = True
    try:
        try:
            import ayu_bridge
        except Exception as error:
            raise _sdk_failure("failed to import", error) from error
        if Path(ayu_bridge.__file__).resolve().parent != sdk:
            raise PreflightError("Another bridge SDK is already imported.")
        yield ayu_bridge.Runtime()
    finally:
        sys.path[:] = saved_path
        sys.dont_write_bytecode = saved_flag
        if saved_host is missing:
            sys.modules.pop("_ayu_host", None)
        else:
            sys.modules["_ayu_host"] = saved_host


def _printable(text: Any) -> str:
    return text if isinstance(text, str) and _PRINTABLE.match(text) and "://" not in text else UNPRINTABLE


def _plugin_paths(directory: Path) -> list[Path]:
    if is_link(directory) or not directory.is_dir():
        raise PreflightError("Plugin directory is unavailable.")
    paths = []
    for index, path in enumerate(directory.iterdir()):
        if index >= MAX_DIRECTORY_ENTRIES:
            raise PreflightError("Plugin directory exceeds entry limit.")
        if path.suffix.lower() == ".plugin" and not is_link(path) and path.is_file():
            paths.append(path)
            if len(paths) > MAX_FILES:
                raise PreflightError("Plugin directory exceeds file limit.")
    return sorted(paths)


def _package_paths(directory: Path) -> list[Path]:
    """Immediate ``.elyx`` / ``.eaf`` package archives; the directory was validated by ``_plugin_paths``."""
    paths = []
    for index, path in enumerate(directory.iterdir()):
        if index >= MAX_DIRECTORY_ENTRIES:
            raise PreflightError("Plugin directory exceeds entry limit.")
        if path.suffix.lower() in PACKAGE_SUFFIXES and not is_link(path) and path.is_file():
            paths.append(path)
            if len(paths) > MAX_FILES:
                raise PreflightError("Plugin directory exceeds file limit.")
    return sorted(paths)


def preflight_packages(paths: list[Path], runtime: Any, top: int) -> dict[str, Any]:
    """The bridge's static package preflight of every archive; no package code is imported or executed."""
    import _ayu_packages

    passing, rejections = 0, Counter()
    kinds, details = Counter(), defaultdict(Counter)
    for path in paths:
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                report = json.loads(_ayu_packages.preflight_package_json(runtime, str(path), "package.elyx"))
        except Exception as error:
            code = getattr(error, "code", None)
            rejections[code if isinstance(code, str) and _printable(code) == code
                       else "INTERNAL: " + type(error).__name__] += 1
            continue
        found = defaultdict(set)
        for blocker in report["blockers"]:
            found[_printable(blocker.get("code"))].add(_printable(blocker.get("detail")))
        for kind, names in found.items():
            kinds[kind] += 1
            details[kind].update(names)
        if not found:
            passing += 1

    def ranked(counter):
        rows = sorted(counter.items(), key=lambda item: (-item[1], item[0]))
        return {"distinct": len(rows), "omitted": max(0, len(rows) - top),
                "ranked": [{"detail": name, "packages": count} for name, count in rows[:top]]}

    rejected = sum(rejections.values())
    return {
        "packages": len(paths), "inspectable": len(paths) - rejected, "passing": passing, "rejected": rejected,
        "blocked": len(paths) - passing - rejected,
        "rejections": [{"reason": reason, "packages": count}
                       for reason, count in sorted(rejections.items(), key=lambda item: (-item[1], item[0]))],
        "blocked_by_kind": dict(sorted(kinds.items(), key=lambda item: (-item[1], item[0]))),
        "blockers": {kind: ranked(details[kind]) for kind in sorted(details, key=lambda kind: (-kinds[kind], kind))},
    }


def preflight_corpus(directory: Path, *, bridge: Path = DEFAULT_BRIDGE,
                     capabilities: dict[str, Any] | None = None, top: int = 25,
                     include_ids: bool = False) -> dict[str, Any]:
    """Aggregate the bridge preflight of every immediate ``.plugin`` file."""
    if not 1 <= top <= MAX_TOP:
        raise PreflightError("Top limit is out of range.")
    source_kind = "file" if capabilities is not None else "swift_literals"
    notes = None
    if capabilities is None:
        capabilities, notes = scrape_host(bridge)
    paths = _plugin_paths(directory)
    passing, rejections, declares = [], Counter(), Counter()
    accesses, member_only = Counter(), 0
    kinds, sole, details = Counter(), Counter(), defaultdict(Counter)
    histogram = Counter()
    total_bytes = 0
    with bridge_runtime(bridge / "Python", capabilities) as runtime:
        try:
            resolved = runtime._capabilities()
        except Exception as error:
            raise _sdk_failure("rejected the host capabilities or a class provider", error) from error
        for path in paths:
            try:
                raw = bounded_read(path, MAX_SOURCE_BYTES)
                total_bytes += len(raw)
                if total_bytes > MAX_CORPUS_BYTES:
                    raise PreflightError("Corpus exceeds total read limit.")
                source = raw.decode("utf-8")
            except (CorpusError, OSError, UnicodeError):
                rejections["UNREADABLE: source is not bounded UTF-8 text"] += 1
                continue
            try:
                # Parser warnings quote source text and file names.
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")
                    report = json.loads(runtime.preflight_plugin_json(source, "plugin.plugin"))
            except Exception as error:
                code = getattr(error, "code", None)
                message = _printable(getattr(error, "message", None))
                rejections[f"{code}: {message}" if isinstance(code, str) and _printable(code) == code
                           else "INTERNAL: " + type(error).__name__] += 1
                continue
            for key in METADATA_KEYS:
                if report["metadata"].get(key) not in (None, "", []):
                    declares[key] += 1
            for key, count in report.get("member_accesses", {}).items():
                if type(count) is int:
                    accesses[key] += count
            found = defaultdict(set)
            for blocker in report["blockers"]:
                found[_printable(blocker.get("code"))].add(_printable(blocker.get("detail")))
            for kind, names in found.items():
                kinds[kind] += 1
                details[kind].update(names)
            count = sum(len(names) for names in found.values())
            histogram["0" if not count else "1" if count == 1 else "2-5" if count <= 5
                      else "6-15" if count <= 15 else "16+"] += 1
            if not found:
                passing.append(_printable(report["metadata"].get("__id__")))
            elif len(found) == 1:
                sole[next(iter(found))] += 1
        packages = preflight_packages(_package_paths(directory), runtime, top)
    if notes is None:
        published = resolved.get("members") or {}
        notes = {"classes_with_members": len(published), "upper_bound_classes": 0,
                 "classes_without_members": len(resolved["classes"]) - len(published)}

    def ranked(counter):
        rows = sorted(counter.items(), key=lambda item: (-item[1], item[0]))
        return {"distinct": len(rows), "omitted": max(0, len(rows) - top),
                "ranked": [{"detail": name, "plugins": count} for name, count in rows[:top]]}

    rejected = sum(rejections.values())
    report = {
        "schema_version": 1, "inspection": "bridge_static_preflight_only",
        "execution_verified": False, "runtime_validation_required": True,
        "capabilities": {
            "source": source_kind, "operations": len(resolved["operations"]),
            "host_classes": len(resolved["classes"]), "local_classes": len(resolved["local_classes"]),
            "modules": len(resolved["modules"]), "proxy_interfaces": len(resolved["proxy_interfaces"]),
            "member_tables": notes,
        },
        # Java member accesses over all plugins: on a receiver whose class is certain and whose
        # members are known (verified, or missing behind a probe), and on any other receiver.
        "member_accesses": {key: accesses[key] for key in ("verified", "guarded", "missing_accesses", "unknown",
                                                           "unknown_java_style")},
        "plugins": len(paths), "passing": len(passing), "rejected": rejected,
        "blocked": len(paths) - len(passing) - rejected,
        "rejections": [{"reason": reason, "plugins": count}
                       for reason, count in sorted(rejections.items(), key=lambda item: (-item[1], item[0]))],
        "blocked_by_kind": dict(sorted(kinds.items(), key=lambda item: (-item[1], item[0]))),
        "blocked_by_single_kind": dict(sorted(sole.items(), key=lambda item: (-item[1], item[0]))),
        "distinct_blockers_per_plugin": {key: histogram[key] for key in ("0", "1", "2-5", "6-15", "16+")},
        "declared_metadata": {key: declares[key] for key in METADATA_KEYS},
        "top": top,
        "blockers": {kind: ranked(details[kind]) for kind in sorted(details, key=lambda kind: (-kinds[kind], kind))},
    }
    if include_ids:
        report["passing_ids"] = sorted(passing)
    report["packages"] = packages
    return report


def render_text(report: dict[str, Any]) -> str:
    caps = report["capabilities"]
    lines = [
        f"Corpus preflight (static; nothing imported or executed): {report['plugins']} plugins",
        f"  pass {report['passing']}   blocked {report['blocked']}   rejected {report['rejected']}",
        f"Host capabilities ({caps['source']}): {caps['operations']} operations, {caps['host_classes']} host classes, "
        f"{caps['local_classes']} Python-local classes, {caps['modules']} modules",
    ]
    tables, accesses = caps.get("member_tables"), report.get("member_accesses")
    if tables and accesses:
        checked = accesses["verified"] + accesses["guarded"] + accesses["missing_accesses"]
        lines.append(f"Host member tables: {tables['classes_with_members']} classes "
                     f"({tables['upper_bound_classes']} as an upper bound), {tables['classes_without_members']} unknown")
        lines.append(f"Member accesses: {checked} on a known receiver class ({accesses['missing_accesses']} missing, "
                     f"{accesses['guarded']} more missing behind a probe), "
                     f"{accesses['unknown']} with an unknown receiver or class "
                     f"({accesses['unknown_java_style']} of them named like Java members)")
    if report["rejections"]:
        lines.append("Rejected before preflight:")
        lines += [f"  {row['plugins']:5d}  {row['reason']}" for row in report["rejections"]]
    lines.append("Plugins blocked per blocker kind (a plugin counts once per kind):")
    lines += [f"  {count:5d}  {kind} ({report['blockers'][kind]['distinct']} distinct)"
              for kind, count in report["blocked_by_kind"].items()]
    if report["blocked_by_single_kind"]:
        lines.append("Plugins whose blockers are all of one kind: " + ", ".join(
            f"{kind} {count}" for kind, count in report["blocked_by_single_kind"].items()))
    lines.append("Distinct blockers per plugin: " + ", ".join(
        f"{key}: {count}" for key, count in report["distinct_blockers_per_plugin"].items()))
    lines.append("Plugins declaring: " + ", ".join(
        f"{key} {count}" for key, count in report["declared_metadata"].items()))
    for kind, value in report["blockers"].items():
        lines.append(f"Top {min(report['top'], value['distinct'])} {kind} blockers by plugins:")
        lines += [f"  {row['plugins']:5d}  {row['detail']}" for row in value["ranked"]]
        if value["omitted"]:
            lines.append(f"         ... {value['omitted']} more")
    if "passing_ids" in report:
        lines.append("Passing plugin ids: " + ", ".join(report["passing_ids"]))
    packages = report.get("packages")
    if packages and packages["packages"]:
        lines.append(f"Packages (.elyx/.eaf, static; nothing imported or executed): {packages['packages']}")
        lines.append(f"  inspectable {packages['inspectable']}   pass {packages['passing']}   "
                     f"blocked {packages['blocked']}   rejected {packages['rejected']}")
        lines += [f"  {row['packages']:5d}  rejected: {row['reason']}" for row in packages["rejections"]]
        lines += [f"  {count:5d}  {kind} ({packages['blockers'][kind]['distinct']} distinct)"
                  for kind, count in packages["blocked_by_kind"].items()]
        for kind in ("PACKAGE", "OPERATION", "SDK_MEMBER", "DEPENDENCY", "IMPORT"):
            if kind in packages["blockers"]:
                lines.append(f"Package {kind} blockers by packages:")
                lines += [f"  {row['packages']:5d}  {row['detail']}" for row in packages["blockers"][kind]["ranked"]]
    lines.append("A pass is the absence of static blockers, not evidence that the plugin runs.")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python3 -m tools.plugin_inspector preflight-corpus", description=__doc__)
    parser.add_argument("--plugin-dir", type=Path, required=True, help="Directory whose immediate .plugin files are checked.")
    parser.add_argument("--bridge", type=Path, default=DEFAULT_BRIDGE, help="AyuPluginBridge checkout (SDK and host sources).")
    parser.add_argument("--capabilities", type=Path,
                        help="JSON runtime.capabilities result to use instead of scraping the Swift sources.")
    parser.add_argument("--top", type=int, default=25, help="Blockers listed per kind (1-200).")
    parser.add_argument("--ids", action="store_true", help="Also list the __id__ of every passing plugin.")
    parser.add_argument("--json", action="store_true", help="Print the JSON report instead of text.")
    parser.add_argument("--output", type=Path, help="Write the report to this file instead of stdout.")
    args = parser.parse_args(argv)
    try:
        if args.output:
            resolved = args.output.resolve()
            for protected in (args.plugin_dir, args.bridge):
                if resolved.is_relative_to(protected.resolve()):
                    raise PreflightError("Output must be outside input directories.")
            if args.capabilities and (resolved == args.capabilities.resolve() or args.output.exists()
                                      and args.capabilities.exists() and args.output.samefile(args.capabilities)):
                raise PreflightError("Output must not overwrite the capability file.")
        report = preflight_corpus(
            args.plugin_dir, bridge=args.bridge, top=args.top, include_ids=args.ids,
            capabilities=load_capabilities(args.capabilities) if args.capabilities else None)
        text = json.dumps(report, ensure_ascii=True, indent=2) + "\n" if args.json else render_text(report)
        if args.output:
            args.output.write_text(text, encoding="utf-8", newline="\n")
        else:
            sys.stdout.write(text)
        return 0
    except PreflightError as error:
        sys.stderr.write(f"Corpus preflight failed: {error}\n")
        return 2
    except (OSError, CorpusError, RecursionError, MemoryError):
        sys.stderr.write("Corpus preflight failed: plugin directory, bridge, capabilities, bounds or output invalid.\n")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
