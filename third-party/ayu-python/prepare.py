#!/usr/bin/env python3
"""Prepare BeeWare's Python 3.15 iOS support archive for Bazel.

This runs only on a macOS build host from the Bazel repository rule.  It does
not download anything itself.  Native extension modules are moved into signed
framework-shaped XCFrameworks; the app-bundled Python resource tree contains
only text/data/bytecode-safe standard-library files and .fwork markers.
"""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
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


def _copy_certifi(certifi_root: Path, resources_root: Path) -> None:
    """Bundle certifi's Mozilla roots and the upstream license for HTTPS clients."""
    certifi_root = certifi_root.resolve(strict=True)
    package = certifi_root / "certifi"
    package = contained_path(certifi_root, package)
    if not package.is_dir() or not (package / "cacert.pem").is_file():
        raise PrepareError("certifi archive must contain certifi/cacert.pem")
    destination = resources_root / "python" / "lib" / f"python{PYTHON_VERSION}" / "certifi"
    copy_resource_tree(package, destination, certifi_root)

    licenses = []
    for candidate in certifi_root.rglob("LICENSE"):
        try:
            licenses.append(contained_path(certifi_root, candidate))
        except (OSError, RuntimeError) as error:
            raise PrepareError(f"unsafe certifi license path: {candidate}: {error}") from error
    if not licenses:
        raise PrepareError("certifi archive has no LICENSE file")
    license_source = sorted(licenses, key=lambda item: len(item.parts))[0]
    license_target = resources_root / "licenses" / "certifi-LICENSE"
    _safe_copy_file(license_source, license_target, certifi_root)


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


def prepare(archive_root: Path, repository_root: Path, certifi_root: Path) -> dict:
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
    _copy_certifi(certifi_root, repository_root / "PythonResources")
    (repository_root / "PythonResources" / "PYTHON_VERSION.txt").write_text(PYTHON_RELEASE + "\n")
    metadata = {
        "python_release": PYTHON_RELEASE,
        "python_version": PYTHON_VERSION,
        "device_slice": DEVICE_SLICE,
        "simulator_slice": SIMULATOR_SLICE,
        "extension_modules": extension_targets,
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
    if len(args) != 3:
        print("usage: prepare.py <extracted-archive-root> <generated-repository-root> <certifi-root>", file=sys.stderr)
        return 2
    if sys.platform != "darwin":
        print("error: this prepare step must run on macOS (xcrun/lipo is required)", file=sys.stderr)
        return 2
    try:
        result = prepare(Path(args[0]), Path(args[1]), Path(args[2]))
    except (PrepareError, OSError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"Prepared BeeWare Python {result['python_release']} with {len(result['extension_modules'])} extension frameworks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
