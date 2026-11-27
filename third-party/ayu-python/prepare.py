#!/usr/bin/env python3
"""Prepare BeeWare's Python 3.15 iOS support archive for Bazel.

This runs only on a macOS build host from the Bazel repository rule.  It does
not download anything itself.  Native extension modules are moved into signed
framework-shaped XCFrameworks; the app-bundled Python resource tree contains
only text/data/bytecode-safe standard-library files and .fwork markers.

Third-party distributions come only from the checksum-pinned artifacts listed
in packages.lock.json.  They must be pure Python; their archives are read as
data and nothing in them is executed.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import zipfile
import zlib
from pathlib import Path, PurePosixPath
from typing import Iterable

PYTHON_VERSION = "3.15"
PYTHON_RELEASE = "3.15-b3"
DEVICE_SLICE = "ios-arm64"
SIMULATOR_SLICE = "ios-arm64_x86_64-simulator"
DEVICE_ARCH = "arm64"
SIMULATOR_ARCHES = ("arm64", "x86_64")
MINIMUM_IOS = "13.0"
RESOURCE_BUNDLE_NAME = "AyuPythonResources"
RESOURCE_BUNDLE_ID = "org.ayugram.python.resources"

PACKAGES_LOCK = Path(__file__).with_name("packages.lock.json")
PACKAGES_MANIFEST = "PYTHON_PACKAGES.json"
_ARTIFACT_URL = re.compile(
    r"https://files\.pythonhosted\.org/packages/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{60}/([A-Za-z0-9_.+-]+)\Z")
MAX_PACKAGES = 64
MAX_PACKAGE_FILES = 4096
MAX_PACKAGE_BYTES = 16 * 1024 * 1024
# The SDK's requests module verifies TLS against these roots.
REQUIRED_PACKAGE_FILES = ("certifi/cacert.pem",)
_DISTRIBUTION = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*\Z")
_PACKAGE_VERSION = re.compile(r"[0-9][0-9A-Za-z.]*\Z")
_MODULE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
# Stricter than a safe relative path: these names become Bazel resource labels.
_PACKAGE_COMPONENT = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.+-]*\Z")
_LOCK_KEYS = frozenset({
    "name", "version", "kind", "filename", "url", "sha256", "modules", "license", "license_files", "requires",
})
_SDIST_KEYS = frozenset({"source_root", "metadata"})

NATIVE_SUFFIXES = (
    ".so", ".dylib", ".a", ".o", ".pyc", ".pyo", ".fwork",
    ".dll", ".exe", ".framework", ".xcframework",
)
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


class PrepareError(RuntimeError):
    """An archive-layout or packaging error with an actionable message."""


def validate_relative_path(path: str | PurePosixPath) -> PurePosixPath:
    """Reject absolute, empty, and traversal paths before joining a root."""
    rel = PurePosixPath(path)
    if rel.is_absolute() or not rel.parts or any(part in ("", ".", "..") for part in rel.parts):
        raise PrepareError(f"unsafe relative path: {path!s}")
    if "\\" in str(path):
        raise PrepareError(f"backslash is not valid in archive paths: {path!s}")
    return rel


def contained_path(root: Path, candidate: Path, *, strict: bool = True) -> Path:
    """Resolve a path and require it to remain under root (including symlinks)."""
    root_real = root.resolve(strict=True)
    resolved = candidate.resolve(strict=strict)
    try:
        resolved.relative_to(root_real)
    except ValueError as error:
        raise PrepareError(f"path escapes archive root: {candidate}") from error
    return resolved


def looks_like_native_binary(path: Path, data: bytes | None = None) -> bool:
    """Identify native/object/bytecode payloads which must not be app resources."""
    lower = path.name.lower()
    if lower.endswith(NATIVE_SUFFIXES):
        return True
    if data is None:
        try:
            with path.open("rb") as stream:
                data = stream.read(8)
        except OSError as error:
            raise PrepareError(f"cannot inspect {path}: {error}") from error
    return data.startswith((b"\x7fELF", b"!<arch>")) or data[:4] in MACHO_MAGICS


def module_for_extension(relative_path: str | PurePosixPath) -> tuple[str, str]:
    """Return (Python module name, same relative filename with .fwork suffix)."""
    rel = validate_relative_path(relative_path)
    if rel.suffix != ".so":
        raise PrepareError(f"expected .so extension module, got {rel}")
    leaf_module = rel.name.split(".", 1)[0]
    parts = list(rel.parent.parts) + [leaf_module]
    if not all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", part) for part in parts):
        raise PrepareError(f"unsupported extension module path: {rel}")
    module = ".".join(parts)
    return module, rel.as_posix()[:-3] + ".fwork"


def bazel_name_for_module(module: str) -> str:
    """Produce a stable, valid and collision-resistant Bazel target suffix."""
    readable = re.sub(r"[^A-Za-z0-9_]+", "_", module).strip("_") or "module"
    digest = hashlib.sha256(module.encode("utf-8")).hexdigest()[:10]
    return f"pyext_{readable}_{digest}"


def framework_name_for_module(module: str) -> str:
    """Return a short stable framework basename for an extension module."""
    digest = hashlib.sha256(module.encode("utf-8")).hexdigest()[:16]
    return f"AyuPyExt_{digest}"


def _archive_path(root: Path, rel: str) -> Path:
    relative = validate_relative_path(rel)
    return contained_path(root, root.joinpath(*relative.parts))


def _archive_file(root: Path, rel: str) -> Path:
    resolved = _archive_path(root, rel)
    if not resolved.is_file():
        raise PrepareError(f"required file is missing: {rel}")
    return resolved


def _safe_copy_file(source: Path, destination: Path, archive_root: Path) -> None:
    source = contained_path(archive_root, source)
    if not source.is_file():
        raise PrepareError(f"expected a regular file: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    shutil.copystat(source, destination, follow_symlinks=True)


def copy_resource_tree(
    source: Path,
    destination: Path,
    archive_root: Path,
    *,
    ancestry: frozenset[Path] = frozenset(),
) -> None:
    """Copy pure stdlib/data, dereferencing only safe in-archive symlinks.

    `lib-dynload` is packaged separately below as signed frameworks. Bytecode
    and native objects are omitted; Python source remains the import fallback.
    """
    real_dir = contained_path(archive_root, source)
    if not real_dir.is_dir():
        raise PrepareError(f"expected a directory: {source}")
    if real_dir in ancestry:
        raise PrepareError(f"symlink directory cycle at {source}")
    next_ancestry = ancestry | {real_dir}
    destination.mkdir(parents=True, exist_ok=True)
    try:
        children = sorted(source.iterdir(), key=lambda item: item.name)
    except OSError as error:
        raise PrepareError(f"cannot enumerate {source}: {error}") from error

    for child in children:
        if child.name in ("__pycache__", "lib-dynload"):
            continue
        # Keep sysconfig data per target under the helper metadata directory,
        # not in the generic stdlib copy. It is installed in a later step.
        if child.name.startswith(("_sysconfigdata", "_sysconfig_vars")) or child.name == "build-details.json":
            continue
        target = destination / child.name
        try:
            resolved = contained_path(archive_root, child)
        except (OSError, RuntimeError) as error:
            raise PrepareError(f"unsafe or broken symlink in stdlib: {child}: {error}") from error
        if resolved.is_dir():
            copy_resource_tree(resolved, target, archive_root, ancestry=next_ancestry)
        elif resolved.is_file():
            if resolved.suffix in (".pyc", ".pyo") or looks_like_native_binary(resolved):
                continue
            _safe_copy_file(resolved, target, archive_root)
        else:
            raise PrepareError(f"unsupported stdlib entry: {child}")


def _run_lipo(args: list[str]) -> str:
    command = ["xcrun", "lipo", *args]
    try:
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
    except FileNotFoundError as error:
        raise PrepareError("xcrun is required to package simulator extension frameworks on macOS") from error
    except subprocess.CalledProcessError as error:
        raise PrepareError(
            f"command failed ({' '.join(command)}):\n{error.stderr or error.stdout}"
        ) from error
    return completed.stdout.strip()


def _architectures(binary: Path) -> set[str]:
    output = _run_lipo(["-archs", str(binary)])
    arches = set(output.split())
    if not arches:
        raise PrepareError(f"lipo found no architectures in {binary}")
    return arches


DYLIB_LOAD_COMMANDS = frozenset({
    "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
    "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB",
})


def _run_macho_tool(tool: str, args: list[str]) -> str:
    command = ["xcrun", tool, *args]
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True)
    except (FileNotFoundError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", None) or str(error)
        raise PrepareError(f"{tool} failed while relocating Python frameworks: {detail}") from error
    return result.stdout


def _parse_dylib_commands(output: str) -> list[tuple[str, str]]:
    """Read install IDs and dependencies for every architecture in otool -l."""
    commands = []
    current = None
    for line in output.splitlines():
        match = re.fullmatch(r"\s*cmd (LC_[A-Z_]+)\s*", line)
        if match:
            current = match[1]
        elif current == "LC_ID_DYLIB" or current in DYLIB_LOAD_COMMANDS:
            name = re.fullmatch(r"\s*name (.+) \(offset [0-9]+\)\s*", line)
            if name:
                commands.append((current, name[1]))
                current = None
    return commands


def _is_system_dylib(name: str) -> bool:
    return name.startswith(("/usr/lib/", "/System/Library/"))


def _relocate_python_frameworks(
    repository_root: Path,
    extension_targets: dict[str, dict[str, str]],
    module_maps: tuple[dict[str, tuple[Path, str]], ...],
) -> None:
    """Rewrite copied Mach-O IDs/edges before Bazel links or signs the frameworks.

    Renaming a .so file does not change LC_ID_DYLIB. Without this step, the app
    links against BeeWare's Modules/foo.so ID and dyld aborts before main runs.
    Never mutate the checksum-verified source archive or ship loose .so files.
    """
    for slice_name, maps in (
        (DEVICE_SLICE, module_maps[:1]),
        (SIMULATOR_SLICE, module_maps[1:]),
    ):
        binaries = {"Python": repository_root / "PythonRuntime.xcframework" / slice_name / "Python.framework" / "Python"}
        for entry in extension_targets.values():
            framework = entry["framework"]
            binaries[framework] = repository_root / "PythonExtensions" / f"{framework}.xcframework" / slice_name / f"{framework}.framework" / framework
        expected_ids = {framework: f"@rpath/{framework}.framework/{framework}" for framework in binaries}
        allowed_ids = set(expected_ids.values())
        aliases: dict[str, str] = {}

        def register(alias: str, expected: str) -> None:
            previous = aliases.get(alias)
            if previous is not None and previous != expected:
                raise PrepareError(f"ambiguous Python library install name: {alias}")
            aliases[alias] = expected

        commands_by_framework = {}
        for framework, binary in binaries.items():
            commands = _parse_dylib_commands(_run_macho_tool("otool", ["-l", str(binary)]))
            ids = [name for kind, name in commands if kind == "LC_ID_DYLIB"]
            if not ids:
                raise PrepareError(f"Python framework has no LC_ID_DYLIB: {binary}")
            commands_by_framework[framework] = commands
            for name in ids:
                register(name, expected_ids[framework])
        register("Python", expected_ids["Python"])
        for module_map in maps:
            for module, (source, _) in module_map.items():
                register(source.name, expected_ids[extension_targets[module]["framework"]])

        for framework, binary in binaries.items():
            expected = expected_ids[framework]
            changes = {}
            for kind, name in commands_by_framework[framework]:
                if kind == "LC_ID_DYLIB" or _is_system_dylib(name) or name in allowed_ids:
                    continue
                replacement = aliases.get(name) or aliases.get(PurePosixPath(name).name)
                if replacement is None:
                    raise PrepareError(f"unbundled Python framework dependency in {framework}: {name}")
                changes[name] = replacement
            args = ["-id", expected]
            for old, new in sorted(changes.items()):
                args.extend(["-change", old, new])
            _run_macho_tool("install_name_tool", [*args, str(binary)])
            verified = _parse_dylib_commands(_run_macho_tool("otool", ["-l", str(binary)]))
            ids = [name for kind, name in verified if kind == "LC_ID_DYLIB"]
            original_id_count = sum(kind == "LC_ID_DYLIB" for kind, _ in commands_by_framework[framework])
            if len(ids) != original_id_count or any(name != expected for name in ids):
                raise PrepareError(f"failed to relocate every architecture of {framework}")
            for kind, name in verified:
                if kind in DYLIB_LOAD_COMMANDS and not (_is_system_dylib(name) or name in allowed_ids):
                    raise PrepareError(f"unresolved dependency after relocation in {framework}: {name}")


def _extension_map(root: Path, relative_dynload: str) -> dict[str, tuple[Path, str]]:
    dynload = root / validate_relative_path(relative_dynload)
    dynload = contained_path(root, dynload)
    if not dynload.is_dir():
        raise PrepareError(f"extension directory is missing: {relative_dynload}")
    result: dict[str, tuple[Path, str]] = {}
    for entry in sorted(dynload.rglob("*.so")):
        resolved = contained_path(root, entry)
        if not resolved.is_file():
            raise PrepareError(f"extension is not a regular file: {entry}")
        relative = entry.relative_to(dynload).as_posix()
        module, marker = module_for_extension(relative)
        if module in result:
            raise PrepareError(f"duplicate extension module {module} in {relative_dynload}")
        result[module] = (resolved, marker)
    if not result:
        raise PrepareError(f"no extension modules found in {relative_dynload}")
    return result


def _copy_framework(source: Path, destination: Path, archive_root: Path) -> None:
    """Copy a framework tree while validating and dereferencing symlinks."""
    source_real = contained_path(archive_root, source)
    if not source_real.is_dir():
        raise PrepareError(f"framework directory is missing: {source}")

    def copy_dir(current: Path, out: Path, ancestors: frozenset[Path]) -> None:
        real_dir = contained_path(archive_root, current)
        try:
            real_dir.relative_to(source_real)
        except ValueError as error:
            raise PrepareError(f"framework symlink escapes framework: {current}") from error
        if real_dir in ancestors:
            raise PrepareError(f"framework symlink directory cycle at {current}")
        out.mkdir(parents=True, exist_ok=True)
        for child in sorted(current.iterdir(), key=lambda item: item.name):
            resolved = contained_path(archive_root, child)
            try:
                resolved.relative_to(source_real)
            except ValueError as error:
                raise PrepareError(f"framework entry escapes framework: {child}") from error
            target = out / child.name
            if resolved.is_dir():
                copy_dir(resolved, target, ancestors | {real_dir})
            elif resolved.is_file():
                _safe_copy_file(resolved, target, archive_root)
            else:
                raise PrepareError(f"unsupported framework entry: {child}")

    destination.mkdir(parents=True, exist_ok=False)
    copy_dir(source_real, destination, frozenset())


def _write_plist(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as stream:
        plistlib.dump(value, stream, fmt=plistlib.FMT_XML, sort_keys=True)


def _copy_runtime_xcframework(archive_root: Path, destination: Path) -> None:
    source_xcf = archive_root / "Python.xcframework"
    source_xcf = contained_path(archive_root, source_xcf)
    if not source_xcf.is_dir():
        raise PrepareError("Python.xcframework directory is missing")
    root_info = source_xcf / "Info.plist"
    if not root_info.is_file():
        raise PrepareError("Python.xcframework/Info.plist is missing")
    try:
        info = plistlib.loads(root_info.read_bytes())
    except Exception as error:
        raise PrepareError(f"invalid Python.xcframework/Info.plist: {error}") from error
    available = info.get("AvailableLibraries", [])
    requested = {DEVICE_SLICE, SIMULATOR_SLICE}
    actual = {item.get("LibraryIdentifier") for item in available}
    if not requested.issubset(actual):
        raise PrepareError(f"BeeWare xcframework slices differ: expected {sorted(requested)}, got {sorted(actual)}")

    destination.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(root_info, destination / "Info.plist")
    for slice_name in (DEVICE_SLICE, SIMULATOR_SLICE):
        source_slice = source_xcf / slice_name
        source_framework = source_slice / "Python.framework"
        if not source_framework.is_dir():
            raise PrepareError(f"Python.framework missing from {slice_name}")
        # XCFramework slice metadata is in the root AvailableLibraries array;
        # Xcode does not emit a separate Info.plist at each slice's root.
        _copy_framework(source_framework, destination / slice_name / "Python.framework", archive_root)
        _archive_file(archive_root, f"Python.xcframework/{slice_name}/Python.framework/Headers/Python.h")
        _archive_file(archive_root, f"Python.xcframework/{slice_name}/Python.framework/Python")


def _write_extension_xcframework(
    module: str,
    module_files: dict[str, tuple[Path, str]],
    simulator_files: dict[str, tuple[Path, str]],
    x86_files: dict[str, tuple[Path, str]],
    archive_root: Path,
    extension_root: Path,
) -> tuple[str, str]:
    """Create one device+simulator framework XCFramework for one Python module."""
    framework = framework_name_for_module(module)
    target = bazel_name_for_module(module)
    xcf = extension_root / f"{framework}.xcframework"
    if xcf.exists():
        raise PrepareError(f"refusing to overwrite generated extension bundle: {xcf}")

    available_libraries = []
    for slice_name, platform, variant, arches, files in (
        (DEVICE_SLICE, "ios", None, (DEVICE_ARCH,), module_files),
        (SIMULATOR_SLICE, "ios", "simulator", SIMULATOR_ARCHES, simulator_files),
    ):
        identifier = slice_name
        fw_dir = xcf / identifier / f"{framework}.framework"
        fw_dir.mkdir(parents=True, exist_ok=False)
        binary_dest = fw_dir / framework
        if slice_name == DEVICE_SLICE:
            source, _ = files[module]
            source = contained_path(archive_root, source)
            found = _architectures(source)
            if found != {DEVICE_ARCH}:
                raise PrepareError(f"{module} device extension architectures are {sorted(found)}, expected ['arm64']")
            shutil.copyfile(source, binary_dest)
            shutil.copystat(source, binary_dest)
        else:
            arm_source, _ = files[module]
            x86_source, _ = x86_files[module]
            if _architectures(arm_source) != {"arm64"}:
                raise PrepareError(f"{module} simulator arm64 extension is not a thin arm64 binary")
            if _architectures(x86_source) != {"x86_64"}:
                raise PrepareError(f"{module} simulator x86_64 extension is not a thin x86_64 binary")
            _run_lipo(["-create", str(arm_source), str(x86_source), "-output", str(binary_dest)])
            if _architectures(binary_dest) != set(SIMULATOR_ARCHES):
                raise PrepareError(f"lipo did not create universal simulator binary for {module}")
            binary_dest.chmod(0o755)

        platform_name = "iPhoneOS" if variant is None else "iPhoneSimulator"
        bundle_id = f"org.ayugram.python.{hashlib.sha256(module.encode()).hexdigest()[:20]}"
        framework_info = {
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": framework,
            "CFBundleIdentifier": bundle_id,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "3.15.2",
            "CFBundleVersion": "1",
            "CFBundleSupportedPlatforms": [platform_name],
            "MinimumOSVersion": MINIMUM_IOS,
        }
        _write_plist(fw_dir / "Info.plist", framework_info)

        privacy = []
        for files_for_arch in ((module_files,) if slice_name == DEVICE_SLICE else (simulator_files, x86_files)):
            binary, marker = files_for_arch[module]
            sidecar = binary.with_name(binary.name.split(".", 1)[0] + ".xcprivacy")
            if sidecar.is_file():
                privacy.append(contained_path(archive_root, sidecar).read_bytes())
        if privacy:
            if any(item != privacy[0] for item in privacy[1:]):
                raise PrepareError(f"conflicting privacy manifests for {module} in {slice_name}")
            (fw_dir / "PrivacyInfo.xcprivacy").write_bytes(privacy[0])

        library = {
            "LibraryIdentifier": identifier,
            "LibraryPath": f"{framework}.framework",
            "SupportedArchitectures": list(arches),
            "SupportedPlatform": platform,
        }
        if variant:
            library["SupportedPlatformVariant"] = variant
        available_libraries.append(library)

    _write_plist(xcf / "Info.plist", {
        "AvailableLibraries": available_libraries,
        "CFBundlePackageType": "XFWK",
        "XCFrameworkFormatVersion": "1.0",
        "Name": framework,
    })
    return target, framework


def _copy_sysconfig(archive_root: Path, resource_stdlib: Path) -> None:
    """Keep all target sysconfig data; CPython selects by its runtime multiarch."""
    config_dir = resource_stdlib / "_ayu_platform_config"
    config_dir.mkdir(parents=True, exist_ok=False)
    entries = (
        (DEVICE_SLICE, "arm64", f"Python.xcframework/{DEVICE_SLICE}/lib-arm64/python{PYTHON_VERSION}"),
        (SIMULATOR_SLICE, "arm64", f"Python.xcframework/{SIMULATOR_SLICE}/lib-arm64/python{PYTHON_VERSION}"),
        (SIMULATOR_SLICE, "x86_64", f"Python.xcframework/{SIMULATOR_SLICE}/lib-x86_64/python{PYTHON_VERSION}"),
    )
    copied: dict[str, bytes] = {}
    for slice_name, arch, rel_dir in entries:
        path = archive_root / validate_relative_path(rel_dir)
        path = contained_path(archive_root, path)
        if not path.is_dir():
            raise PrepareError(f"sysconfig directory missing: {rel_dir}")
        for pattern in ("_sysconfigdata_*.py", "_sysconfig_vars_*.json"):
            for source in sorted(path.glob(pattern)):
                source = contained_path(archive_root, source)
                rel = source.relative_to(path).as_posix()
                data = source.read_bytes()
                previous = copied.get(rel)
                if previous is not None and previous != data:
                    raise PrepareError(f"conflicting architecture sysconfig module {rel}; refusing to choose one")
                copied[rel] = data
                target = resource_stdlib / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
        build_details = path / "build-details.json"
        if build_details.is_file():
            destination = config_dir / slice_name / arch / "build-details.json"
            destination.parent.mkdir(parents=True, exist_ok=True)
            _safe_copy_file(build_details, destination, archive_root)

    if not any(name.startswith("_sysconfigdata_") for name in copied):
        raise PrepareError("no _sysconfigdata_*.py files found in BeeWare slices")


def normalize_distribution(name: str) -> str:
    """The PyPI normal form of a distribution name."""
    return re.sub(r"[-_.]+", "-", name).lower()


def _package_path(name: str) -> PurePosixPath:
    rel = validate_relative_path(name)
    if not all(_PACKAGE_COMPONENT.match(part) for part in rel.parts):
        raise PrepareError(f"unsupported package file name: {name}")
    return rel


def _validate_lock_entry(package: object) -> None:
    kind = package.get("kind") if isinstance(package, dict) else None
    label = package.get("name") if isinstance(package, dict) else package
    if kind not in ("wheel", "sdist") or set(package) != _LOCK_KEYS | (_SDIST_KEYS if kind == "sdist" else frozenset()):
        raise PrepareError(f"package lock entry has unexpected fields: {label!r}")
    texts = ["name", "version", "filename", "url", "sha256", "license"] + (sorted(_SDIST_KEYS) if kind == "sdist" else [])
    lists = ["modules", "license_files", "requires"]
    if not all(isinstance(package[key], str) and package[key] for key in texts) or not all(
            isinstance(package[key], list) and all(isinstance(item, str) and item for item in package[key])
            and len(set(package[key])) == len(package[key]) for key in lists):
        raise PrepareError(f"package lock entry has invalid values: {label!r}")
    name, version, filename = package["name"], package["version"], package["filename"]
    if not _DISTRIBUTION.match(name) or not _PACKAGE_VERSION.match(version) or not _SHA256.match(package["sha256"]):
        raise PrepareError(f"package lock entry has an invalid name, version or checksum: {label!r}")
    url = _ARTIFACT_URL.match(package["url"])
    if url is None or url.group(1) != filename:
        raise PrepareError(f"{name} must be fetched from files.pythonhosted.org under its pinned file name")
    if kind == "wheel":
        # name-version[-build]-python-abi-platform.whl; only universal pure-Python wheels are accepted.
        fields = filename[:-len(".whl")].split("-") if filename.endswith(".whl") else []
        if len(fields) not in (5, 6) or normalize_distribution(fields[0]) != name or fields[1] != version \
                or "py3" not in fields[-3].split(".") or fields[-2:] != ["none", "any"]:
            raise PrepareError(f"{name} is not pinned to a py3-none-any wheel of {version}: {filename}")
    else:
        if not filename.endswith(".tar.gz"):
            raise PrepareError(f"{name} source distribution must be a .tar.gz: {filename}")
        _package_path(package["source_root"])
        _package_path(package["metadata"])
    if not package["modules"] or not all(_MODULE.match(module) for module in package["modules"]):
        raise PrepareError(f"{name} must list the top-level modules it installs")
    if not package["license_files"]:
        raise PrepareError(f"{name} must pin its license files")
    for item in package["license_files"]:
        _package_path(item)


def load_packages_lock(path: Path) -> list[dict]:
    """Read and strictly validate the pinned third-party distribution list."""
    try:
        lock = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise PrepareError(f"cannot read package lock {path}: {error}") from error
    if not isinstance(lock, dict) or set(lock) != {"schema", "packages"} or lock["schema"] != 1 \
            or not isinstance(lock["packages"], list) or len(lock["packages"]) > MAX_PACKAGES:
        raise PrepareError("package lock must be {\"schema\": 1, \"packages\": [...]} within its entry limit")
    packages = lock["packages"]
    names: set[str] = set()
    modules: set[str] = set()
    for package in packages:
        _validate_lock_entry(package)
        if package["name"] in names or modules.intersection(package["modules"]):
            raise PrepareError(f"package lock pins {package['name']} or one of its modules twice")
        names.add(package["name"])
        modules.update(package["modules"])
    for package in packages:
        missing = sorted(set(package["requires"]) - names)
        if missing:
            raise PrepareError(f"{package['name']} requires distributions the lock does not pin: {missing}")
    return packages


def _read_artifact(packages_root: Path, package: dict) -> bytes:
    """The downloaded artifact, only if it is byte-for-byte the pinned one."""
    try:
        path = contained_path(packages_root, packages_root / package["filename"])
        if not path.is_file() or path.stat().st_size > MAX_PACKAGE_BYTES:
            raise PrepareError(f"pinned artifact is not a regular file within the size limit: {package['filename']}")
        data = path.read_bytes()
    except OSError as error:
        raise PrepareError(f"pinned artifact is unavailable: {package['filename']}: {error}") from error
    if hashlib.sha256(data).hexdigest() != package["sha256"]:
        raise PrepareError(f"checksum mismatch for {package['filename']}")
    return data


def _check_metadata(package: dict, text: str) -> None:
    """The artifact must be the pinned distribution and need nothing unpinned."""
    fields: dict[str, str] = {}
    requirements = []
    for line in text.splitlines():
        if not line.strip():
            break  # the long description follows the header block
        key, separator, value = line.partition(":")
        if separator and key == "Requires-Dist":
            requirements.append(value.strip())
        elif separator and key in ("Name", "Version"):
            fields.setdefault(key, value.strip())
    if normalize_distribution(fields.get("Name", "")) != package["name"] or fields.get("Version") != package["version"]:
        raise PrepareError(f"{package['filename']} is not {package['name']} {package['version']}")
    for requirement in requirements:
        specifier, _, marker = requirement.partition(";")
        if "extra" in marker:
            continue  # optional features are not installed
        match = re.match(r"[A-Za-z0-9][A-Za-z0-9._-]*", specifier.strip())
        if match is None or normalize_distribution(match.group(0)) not in package["requires"]:
            raise PrepareError(f"{package['name']} depends on a distribution its lock entry does not list: {requirement}")


def _pure_python(package: dict, rel: PurePosixPath, content: bytes) -> None:
    if looks_like_native_binary(Path(rel.name), content[:8]):
        raise PrepareError(f"{package['name']} is not pure Python: {rel}")


def _wheel_files(data: bytes, package: dict) -> tuple[dict[str, bytes], dict[str, bytes]]:
    """Installable files and license texts of a pure-Python wheel."""
    fields = package["filename"][:-len(".whl")].split("-")
    dist_info = f"{fields[0]}-{fields[1]}.dist-info"
    files: dict[str, bytes] = {}
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            infos = archive.infolist()
            if len(infos) > MAX_PACKAGE_FILES or sum(info.file_size for info in infos) > MAX_PACKAGE_BYTES:
                raise PrepareError(f"{package['name']} exceeds the package size limits")
            for info in infos:
                if info.is_dir():
                    continue
                rel = _package_path(info.filename)
                if (info.external_attr >> 16) & 0o170000 not in (0, stat.S_IFREG):
                    raise PrepareError(f"{package['name']} contains an entry that is not a regular file: {rel}")
                top = rel.parts[0]
                if top.endswith(".data"):
                    # Scripts, headers and shared data are not importable; relocated code is not supported.
                    if len(rel.parts) > 1 and rel.parts[1] in ("purelib", "platlib"):
                        raise PrepareError(f"{package['name']} uses an unsupported wheel layout: {rel}")
                    continue
                if top.endswith(".dist-info") and top != dist_info:
                    raise PrepareError(f"{package['name']} carries metadata of another distribution: {rel}")
                if rel.as_posix() in files:
                    raise PrepareError(f"{package['name']} lists a file twice: {rel}")
                content = archive.read(info)
                _pure_python(package, rel, content)
                files[rel.as_posix()] = content
    except PrepareError:
        raise
    except (zipfile.BadZipFile, zlib.error, EOFError, NotImplementedError, RuntimeError) as error:
        raise PrepareError(f"{package['filename']} is not a readable wheel: {error}") from error
    # RECORD describes the complete wheel; nothing here consumes it.
    for name in [name for name in files if name.startswith(dist_info + "/RECORD")]:
        del files[name]
    wheel = files.get(f"{dist_info}/WHEEL", b"").decode("utf-8", "replace").splitlines()
    tags = [line[len("Tag:"):].strip() for line in wheel if line.startswith("Tag:")]
    if "Root-Is-Purelib: true" not in wheel or not tags or not all(tag.endswith("-none-any") for tag in tags):
        raise PrepareError(f"{package['filename']} does not declare a pure-Python wheel")
    if f"{dist_info}/METADATA" not in files:
        raise PrepareError(f"{package['filename']} has no {dist_info}/METADATA")
    _check_metadata(package, files[f"{dist_info}/METADATA"].decode("utf-8", "replace"))
    licenses: dict[str, bytes] = {}
    for item in package["license_files"]:
        if item not in files or PurePosixPath(item).name in licenses:
            raise PrepareError(f"{package['name']} license file is missing or ambiguous: {item}")
        licenses[PurePosixPath(item).name] = files[item]
    return files, licenses


def _sdist_files(data: bytes, package: dict) -> tuple[dict[str, bytes], dict[str, bytes]]:
    """Listed module sources, metadata and license texts of a source distribution.

    Only the pinned paths are read; setup.py and every other member stay unread.
    """
    root = package["source_root"]
    dist_info = f"{package['name'].replace('-', '_')}-{package['version']}.dist-info"
    files: dict[str, bytes] = {}
    licenses: dict[str, bytes] = {}
    total = 0
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            for index, member in enumerate(archive):
                if index >= MAX_PACKAGE_FILES:
                    raise PrepareError(f"{package['name']} exceeds the package size limits")
                name = member.name
                if name == package["metadata"]:
                    target = f"{dist_info}/METADATA"
                elif name in package["license_files"]:
                    target = f"{dist_info}/licenses/{PurePosixPath(name).name}"
                elif any(name == f"{root}/{module}.py" or name.startswith(f"{root}/{module}/") for module in package["modules"]):
                    target = name[len(root) + 1:]
                else:
                    continue
                if member.isdir():
                    continue
                rel = _package_path(target)
                total += member.size
                if not member.isfile() or total > MAX_PACKAGE_BYTES or rel.as_posix() in files:
                    raise PrepareError(f"{package['name']} has an unusable source member: {name}")
                stream = archive.extractfile(member)
                content = stream.read() if stream is not None else b""
                _pure_python(package, rel, content)
                files[rel.as_posix()] = content
                if name in package["license_files"]:
                    licenses[rel.name] = content
    except (tarfile.TarError, zlib.error, EOFError, OSError) as error:
        raise PrepareError(f"{package['filename']} is not a readable source distribution: {error}") from error
    if f"{dist_info}/METADATA" not in files or len(licenses) != len(package["license_files"]):
        raise PrepareError(f"{package['filename']} lacks its pinned metadata or license files")
    _check_metadata(package, files[f"{dist_info}/METADATA"].decode("utf-8", "replace"))
    return files, licenses


def install_packages(packages_root: Path, lock_path: Path, resources_root: Path) -> list[dict]:
    """Unpack the pinned pure-Python distributions beside the standard library.

    The embedded interpreter searches only its library directory and the plugin
    SDK, so a distribution is importable exactly when its modules are in that
    directory. Nothing may replace a standard-library or earlier package file.
    """
    packages = load_packages_lock(lock_path)
    try:
        packages_root = packages_root.resolve(strict=True)
    except OSError as error:
        raise PrepareError(f"pinned package directory is unavailable: {error}") from error
    library = resources_root / "python" / "lib" / f"python{PYTHON_VERSION}"
    library.mkdir(parents=True, exist_ok=True)
    # Compared case-insensitively: the build host's file system may fold case.
    occupied = {entry.name.casefold() for entry in library.iterdir()}
    manifest = []
    for package in packages:
        data = _read_artifact(packages_root, package)
        files, licenses = (_wheel_files if package["kind"] == "wheel" else _sdist_files)(data, package)
        tops = {name.split("/", 1)[0] for name in files}
        modules = set()
        for module in package["modules"]:
            top = module if f"{module}/__init__.py" in files else f"{module}.py"
            if top not in tops or {module.casefold(), f"{module}.py".casefold()} & occupied:
                raise PrepareError(f"{package['name']} does not provide module {module} or it is already present")
            modules.add(top)
        if {top for top in tops if not top.endswith(".dist-info")} != modules:
            raise PrepareError(f"{package['name']} installs other top-level names than its pinned modules: {sorted(tops)}")
        if len({name.casefold() for name in files}) != len(files) or occupied.intersection(top.casefold() for top in tops):
            raise PrepareError(f"{package['name']} would overwrite files in the Python library")
        occupied.update(top.casefold() for top in tops)
        for name, content in sorted(files.items()):
            target = library.joinpath(*PurePosixPath(name).parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        for name, content in sorted(licenses.items()):
            target = resources_root / "licenses" / f"{package['name']}-{name}"
            if target.exists():
                raise PrepareError(f"refusing to overwrite license file: {target.name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        manifest.append({
            "name": package["name"], "version": package["version"], "sha256": package["sha256"],
            "license": package["license"], "modules": sorted(package["modules"]),
            "files": {name: hashlib.sha256(content).hexdigest() for name, content in sorted(files.items())},
        })
    document = {"schema": 1, "library": f"python/lib/python{PYTHON_VERSION}", "packages": manifest}
    (resources_root / PACKAGES_MANIFEST).write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    return manifest


def _write_build_file(modules: Iterable[str]) -> tuple[str, str]:
    """Emit the external repository BUILD and a helper returning all labels."""
    sorted_modules = sorted(modules)
    lines = [
        'load("@build_bazel_rules_apple//apple:apple.bzl", "apple_dynamic_xcframework_import")',
        'load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")',
        'load("@rules_cc//cc:objc_library.bzl", "objc_library")',
        "",
        'package(default_visibility = ["//visibility:public"])',
        "",
        "apple_dynamic_xcframework_import(",
        '    name = "python_runtime",',
        '    xcframework_imports = glob(["PythonRuntime.xcframework/**"], allow_empty = False),',
        ")",
        "",
    ]
    extension_targets = []
    for module in sorted_modules:
        target = bazel_name_for_module(module)
        framework = framework_name_for_module(module)
        extension_targets.append(f":{target}")
        lines.extend([
            "apple_dynamic_xcframework_import(",
            f'    name = "{target}",',
            f'    xcframework_imports = glob(["PythonExtensions/{framework}.xcframework/**"], allow_empty = False),',
            # Keep extensions embedded/signed through AppleFrameworkImportInfo,
            # but omit link inputs: CPython loads their .fwork targets on import.
            # Eager OpenSSL extensions can interpose the app's crypto at launch.
            '    bundle_only = True,',
            ")",
            "",
        ])
    lines.extend([
        "objc_library(",
        '    name = "Python",',
        f"    deps = {json.dumps([':python_runtime'] + extension_targets, indent=4)},",
        '    data = [":PythonResources"],',
        ")",
        "",
        "apple_resource_bundle(",
        '    name = "PythonResources",',
        f'    bundle_name = "{RESOURCE_BUNDLE_NAME}",',
        f'    bundle_id = "{RESOURCE_BUNDLE_ID}",',
        '    structured_resources = glob(["PythonResources/**"], allow_empty = False),',
        '    strip_structured_resources_prefixes = ["PythonResources"],',
        ")",
        "",
        'exports_files(["VERSIONS", "python_layout.json", "python_deps.bzl"])',
        "",
    ])
    deps_bzl = "\n".join([
        "# Generated by third-party/ayu-python/prepare.py; do not edit by hand.",
        "def ayu_python_runtime_deps():",
        '    return ["@ayu_python//:Python"]',
        "",
        "def ayu_python_resource_deps():",
        '    return ["@ayu_python//:PythonResources"]',
        "",
    ])
    return "\n".join(lines), deps_bzl


def prepare(archive_root: Path, repository_root: Path, packages_root: Path, lock_path: Path = PACKAGES_LOCK) -> dict:
    """Validate and prepare the archives; outputs are created without deleting."""
    archive_root = archive_root.resolve(strict=True)
    repository_root = repository_root.resolve(strict=True)
    _archive_path(archive_root, "Python.xcframework")
    _archive_file(archive_root, "VERSIONS")
    if (repository_root / "BUILD.bazel").exists():
        raise PrepareError("refusing to overwrite existing BUILD.bazel")
    for output in ("PythonRuntime.xcframework", "PythonResources", "PythonExtensions"):
        if (repository_root / output).exists():
            raise PrepareError(f"refusing to overwrite existing generated path: {output}")

    versions = _archive_file(archive_root, "VERSIONS").read_text(errors="replace")
    if "Python version:" not in versions or "3.15" not in versions:
        raise PrepareError(f"unexpected BeeWare VERSIONS content for {PYTHON_RELEASE}")

    _copy_runtime_xcframework(archive_root, repository_root / "PythonRuntime.xcframework")
    resource_stdlib = repository_root / "PythonResources" / "python" / "lib" / f"python{PYTHON_VERSION}"
    common_stdlib = _archive_path(archive_root, f"Python.xcframework/lib/python{PYTHON_VERSION}")
    if not common_stdlib.is_dir():
        raise PrepareError("common Python standard-library directory is missing")
    copy_resource_tree(common_stdlib, resource_stdlib, archive_root)

    device_rel = f"Python.xcframework/{DEVICE_SLICE}/lib-arm64/python{PYTHON_VERSION}/lib-dynload"
    simulator_arm_rel = f"Python.xcframework/{SIMULATOR_SLICE}/lib-arm64/python{PYTHON_VERSION}/lib-dynload"
    simulator_x86_rel = f"Python.xcframework/{SIMULATOR_SLICE}/lib-x86_64/python{PYTHON_VERSION}/lib-dynload"
    device_modules = _extension_map(archive_root, device_rel)
    sim_arm_modules = _extension_map(archive_root, simulator_arm_rel)
    sim_x86_modules = _extension_map(archive_root, simulator_x86_rel)
    sets = [set(device_modules), set(sim_arm_modules), set(sim_x86_modules)]
    if not (sets[0] == sets[1] == sets[2]):
        details = {
            "device_only": sorted(sets[0] - sets[1] - sets[2]),
            "sim_arm64_only": sorted(sets[1] - sets[0] - sets[2]),
            "sim_x86_64_only": sorted(sets[2] - sets[0] - sets[1]),
        }
        raise PrepareError(f"lib-dynload module inventories do not match across slices: {details}")

    extension_root = repository_root / "PythonExtensions"
    extension_root.mkdir(parents=True, exist_ok=False)
    marker_root = resource_stdlib / "lib-dynload"
    marker_root.mkdir(parents=True, exist_ok=False)
    extension_targets = {}
    for module in sorted(device_modules):
        target, framework = _write_extension_xcframework(
            module,
            device_modules,
            sim_arm_modules,
            sim_x86_modules,
            archive_root,
            extension_root,
        )
        extension_targets[module] = {"target": target, "framework": framework}
        marker_rels = {
            files[module][1]
            for files in (device_modules, sim_arm_modules, sim_x86_modules)
        }
        framework_binary = f"Frameworks/{framework}.framework/{framework}"
        origin_rel = sorted(marker_rels)[0]
        for marker in sorted(marker_rels):
            marker_path = marker_root / validate_relative_path(marker)
            marker_path.parent.mkdir(parents=True, exist_ok=True)
            marker_path.write_text(framework_binary + "\n")
        origin = (
            f"{RESOURCE_BUNDLE_NAME}.bundle/python/lib/python{PYTHON_VERSION}/"
            f"lib-dynload/{origin_rel}"
        )
        for slice_name, files in ((DEVICE_SLICE, device_modules), (SIMULATOR_SLICE, sim_arm_modules)):
            fw_path = extension_root / f"{framework}.xcframework" / slice_name / f"{framework}.framework"
            (fw_path / f"{framework}.origin").write_text(origin + "\n")

    _relocate_python_frameworks(
        repository_root, extension_targets, (device_modules, sim_arm_modules, sim_x86_modules),
    )
    _copy_sysconfig(archive_root, resource_stdlib)
    packages = install_packages(packages_root, lock_path, repository_root / "PythonResources")
    shipped = {name for package in packages for name in package["files"]}
    for required in REQUIRED_PACKAGE_FILES:
        if required not in shipped:
            raise PrepareError(f"pinned packages must provide {required}")
    (repository_root / "PythonResources" / "PYTHON_VERSION.txt").write_text(PYTHON_RELEASE + "\n")
    metadata = {
        "python_release": PYTHON_RELEASE,
        "python_version": PYTHON_VERSION,
        "device_slice": DEVICE_SLICE,
        "simulator_slice": SIMULATOR_SLICE,
        "extension_modules": extension_targets,
        "python_packages": {package["name"]: package["version"] for package in packages},
        "python_home_relative_to_main_bundle": f"{RESOURCE_BUNDLE_NAME}.bundle/python",
        "frameworks_relative_to_main_bundle": "Frameworks",
    }
    (repository_root / "python_layout.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    build_file, deps_bzl = _write_build_file(device_modules)
    (repository_root / "BUILD.bazel").write_text(build_file)
    (repository_root / "python_deps.bzl").write_text(deps_bzl)
    return metadata


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 4:
        print("usage: prepare.py <extracted-archive-root> <generated-repository-root> <pinned-packages-dir> <packages.lock.json>",
              file=sys.stderr)
        return 2
    if sys.platform != "darwin":
        print("error: this prepare step must run on macOS (xcrun/lipo is required)", file=sys.stderr)
        return 2
    try:
        result = prepare(Path(args[0]), Path(args[1]), Path(args[2]), Path(args[3]))
    except (PrepareError, OSError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"Prepared BeeWare Python {result['python_release']} with {len(result['extension_modules'])} extension frameworks "
          f"and {len(result['python_packages'])} pinned packages")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
