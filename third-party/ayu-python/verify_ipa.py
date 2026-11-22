#!/usr/bin/env python3
"""Read-only Python dyld/marker checks on the final IPA, without loading its code."""
from __future__ import annotations

import hashlib
import json
import plistlib
import posixpath
import re
import struct
import sys
import zipfile
from pathlib import Path, PurePosixPath
from typing import BinaryIO


class VerificationError(RuntimeError):
    pass


LOAD_COMMANDS = {0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20}

SDK_FILES = (
    "_ayu_inspection.py", "android_utils.py", "ayu_bridge.py", "base_plugin.py",
    "client_utils.py", "hook_utils.py", "java.py", "plugin_settings.py",
    "requests.py", "ui/__init__.py", "ui/alert.py", "ui/bulletin.py", "ui/settings.py",
)


def verify_resources(ipa: zipfile.ZipFile, app: str, sdk_sources: Path | None) -> dict:
    """Match the exact paths used by Swift/CPython; bundle Info.plist is optional."""
    prefix = f"{app}/AyuPluginSDK.bundle/Python/"
    required = [prefix + name for name in SDK_FILES] + [
        f"{app}/AyuPluginSDK.bundle/Resources/bridge_smoke.plugin",
        f"{app}/AyuPythonResources.bundle/python/lib/python3.15/encodings/__init__.py",
    ]
    for name in required:
        try:
            info = ipa.getinfo(name)
        except KeyError as error:
            raise VerificationError(f"missing plugin runtime resource: {name}") from error
        mode = (info.external_attr >> 16) & 0o170000
        if info.is_dir() or mode not in (0, 0o100000) or not 0 < info.file_size <= 1_048_576:
            raise VerificationError(f"invalid plugin runtime resource: {name}")
    if sdk_sources is not None:
        expected_files = {file.relative_to(sdk_sources).as_posix(): file for file in sdk_sources.rglob("*.py")
                          if "__pycache__" not in file.parts}
        if not set(SDK_FILES).issubset(expected_files):
            raise VerificationError("checked-out SDK source inventory is incomplete")
        packaged = {name[len(prefix):] for name in ipa.namelist() if name.startswith(prefix) and name.endswith(".py")}
        if packaged != set(expected_files):
            raise VerificationError("packaged SDK source inventory differs from the checkout")
        for name, file in expected_files.items():
            if file.is_symlink() or hashlib.sha256(ipa.read(prefix + name)).digest() != hashlib.sha256(file.read_bytes()).digest():
                raise VerificationError(f"packaged SDK source hash differs from checkout: {name}")
    return {"plugin_sdk_files": len(SDK_FILES), "plugin_runtime_resources": "verified",
            "plugin_sdk_source_hashes": "verified" if sdk_sources is not None else "not checked"}


def _read_thin_macho(stream: BinaryIO, start: int, slice_size: int | None) -> dict:
    stream.seek(start)
    header = stream.read(32)
    if len(header) != 32:
        raise VerificationError("truncated Mach-O header")
    magic, cpu, subtype, _, count, size, _, _ = struct.unpack("<8I", header)
    if magic != 0xFEEDFACF or cpu != 0x0100000C:
        raise VerificationError(f"expected an arm64 Mach-O slice, found magic={header[:4].hex()}, cpu={cpu:#x}")
    if size > 16 * 1024 * 1024 or count > size // 8:
        raise VerificationError("invalid Mach-O load-command bounds")
    if slice_size is not None and 32 + size > slice_size:
        raise VerificationError("Mach-O load commands exceed slice bounds")
    data = stream.read(size)
    if len(data) != size:
        raise VerificationError("truncated Mach-O load commands")
    result = {"ids": [], "loads": [], "rpaths": [], "platforms": [],
              "architecture": (cpu, subtype & 0x00FFFFFF), "raw_subtype": subtype}
    offset = 0
    for _ in range(count):
        if offset + 8 > size:
            raise VerificationError("truncated Mach-O load command")
        kind, length = struct.unpack_from("<2I", data, offset)
        if length < 8 or length % 8 or offset + length > size:
            raise VerificationError("invalid Mach-O load-command length")
        if kind in LOAD_COMMANDS or kind in {0xD, 0x8000001C}:
            minimum = 12 if kind == 0x8000001C else 24
            if length < minimum:
                raise VerificationError("truncated dylib/rpath command")
            start = struct.unpack_from("<I", data, offset + 8)[0]
            if not minimum <= start < length:
                raise VerificationError("invalid dylib/rpath string offset")
            raw = data[offset + start:offset + length]
            end = raw.find(b"\0")
            if end < 0:
                raise VerificationError("unterminated dylib/rpath string")
            try:
                name = raw[:end].decode("utf-8")
            except UnicodeDecodeError as error:
                raise VerificationError("invalid UTF-8 dylib/rpath string") from error
            if not name or "\n" in name:
                raise VerificationError("empty or multiline dylib/rpath string")
            key = "ids" if kind == 0xD else "rpaths" if kind == 0x8000001C else "loads"
            result[key].append(name)
        elif kind == 0x32:
            if length < 24:
                raise VerificationError("truncated LC_BUILD_VERSION")
            result["platforms"].append(struct.unpack_from("<I", data, offset + 8)[0])
        elif kind == 0x25:
            result["platforms"].append(2)  # LC_VERSION_MIN_IPHONEOS
        offset += length
    if offset != size:
        raise VerificationError("Mach-O load-command count/size mismatch")
    if any(platform != 2 for platform in result["platforms"]):
        raise VerificationError("non-device platform in an iOS device IPA")
    return result


def read_macho(stream: BinaryIO, file_size: int | None = None) -> list[dict]:
    """Read thin or FAT arm64 load commands without loading executable code.

    A FAT wrapper can contain just one architecture. Keep slice metadata
    separate: a good slice must not hide another slice's stale ID or rpath.
    ZIP streams are seekable; do not read/decompress whole framework binaries.
    """
    stream.seek(0)
    magic = stream.read(4)
    formats = {
        b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
        b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True),
    }
    if magic not in formats:
        return [_read_thin_macho(stream, 0, file_size)]
    endian, wide = formats[magic]
    raw_count = stream.read(4)
    if len(raw_count) != 4:
        raise VerificationError("truncated FAT header")
    count = struct.unpack(endian + "I", raw_count)[0]
    if not 1 <= count <= 64:
        raise VerificationError("invalid FAT architecture count")
    entry_size = 32 if wide else 20
    table_end = 8 + count * entry_size
    table = stream.read(count * entry_size)
    if len(table) != count * entry_size:
        raise VerificationError("truncated FAT architecture table")
    architectures = set()
    ranges = []
    slices = []
    for index in range(count):
        fields = struct.unpack_from(endian + ("IIQQII" if wide else "5I"), table, index * entry_size)
        cpu, subtype, start, size, alignment = fields[:5]
        if cpu != 0x0100000C:
            raise VerificationError(f"non-arm64 architecture in device FAT binary: cpu={cpu:#x}")
        if (cpu, subtype) in architectures:
            raise VerificationError("duplicate FAT architecture")
        architectures.add((cpu, subtype))
        if alignment > 63 or start < table_end or size < 32 or start % (1 << alignment):
            raise VerificationError("invalid FAT slice bounds/alignment")
        if file_size is not None and start + size > file_size:
            raise VerificationError("FAT slice exceeds binary bounds")
        if wide and fields[5] != 0:
            raise VerificationError("invalid FAT64 reserved field")
        ranges.append((start, start + size))
        slices.append((cpu, subtype, start, size))
    ordered = sorted(ranges)
    if any(previous[1] > following[0] for previous, following in zip(ordered, ordered[1:])):
        raise VerificationError("overlapping FAT slices")
    metadata = []
    for cpu, subtype, start, size in sorted(slices, key=lambda entry: entry[2]):
        item = _read_thin_macho(stream, start, size)
        if item["architecture"][0] != cpu or item["raw_subtype"] != subtype:
            raise VerificationError("FAT table/header architecture mismatch")
        metadata.append(item)
    return metadata


def _matching_slices(slices: list[dict], requester: dict) -> list[dict]:
    cpu, subtype = requester["architecture"]
    exact = [item for item in slices if item["architecture"] == (cpu, subtype)]
    return exact or [item for item in slices if item["architecture"] == (cpu, 0)]


def _python_dependency(name: str) -> bool:
    return "Python.framework/" in name or "AyuPyExt_" in name or ".cpython-" in name or name.startswith(("Modules/", "/Modules/"))


def _expand_rpath(path: str, loader: str, executable: str) -> str | None:
    for token, root in (("@executable_path", posixpath.dirname(executable)),
                        ("@loader_path", posixpath.dirname(loader))):
        if path == token or path.startswith(token + "/"):
            return posixpath.normpath(root + path[len(token):])
    return None


def verify_ipa(path: Path, *, sdk_sources: Path | None = None) -> dict:
    with zipfile.ZipFile(path) as ipa:
        entries = ipa.namelist()
        names = set(entries)
        if len(names) != len(entries) or any(".." in PurePosixPath(name).parts or name.startswith("/") for name in names):
            raise VerificationError("duplicate or unsafe IPA entry")
        infos = [name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(infos) != 1:
            raise VerificationError("expected one main application bundle")
        app = posixpath.dirname(infos[0])
        info = plistlib.loads(ipa.read(infos[0]))
        executable_name = info.get("CFBundleExecutable", "")
        if not executable_name or PurePosixPath(executable_name).name != executable_name:
            raise VerificationError("invalid main CFBundleExecutable")
        executable = f"{app}/{executable_name}"

        def read_binary(name: str) -> list[dict]:
            if name not in names:
                raise VerificationError(f"missing embedded binary: {name}")
            with ipa.open(name) as stream:
                try:
                    return read_macho(stream, ipa.getinfo(name).file_size)
                except VerificationError as error:
                    raise VerificationError(f"{name}: {error}") from error

        main = read_binary(executable)
        framework_prefix = f"{app}/Frameworks/"
        frameworks = {}
        for name in sorted(names):
            if not name.startswith(framework_prefix) or not name.endswith(".framework/Info.plist"):
                continue
            relative = name[len(framework_prefix):]
            if relative.count("/") != 1:
                continue
            framework = relative.split(".framework/", 1)[0]
            framework_info = plistlib.loads(ipa.read(name))
            binary_name = framework_info.get("CFBundleExecutable", "")
            if not binary_name or PurePosixPath(binary_name).name != binary_name:
                raise VerificationError(f"invalid framework executable: {framework}")
            binary = f"{framework_prefix}{framework}.framework/{binary_name}"
            frameworks[framework] = (binary, read_binary(binary))

        python_frameworks = {name: item for name, item in frameworks.items() if name == "Python" or name.startswith("AyuPyExt_")}
        if "Python" not in python_frameworks or len(python_frameworks) < 2:
            raise VerificationError("Python runtime or extension frameworks are missing")
        expected = {}
        for framework, (binary, slices) in python_frameworks.items():
            install_id = f"@rpath/{framework}.framework/{framework}"
            for metadata in slices:
                if metadata["ids"] != [install_id] or not binary.endswith("/" + framework):
                    raise VerificationError(f"incorrect Python framework install ID: {framework}: {metadata['ids']}")
            expected[install_id] = binary

        # Extensions must be embedded for lazy .fwork imports, not startup-linked.
        # Reject edges from every ordinary app framework and the core runtime,
        # not just the executable: Bazel can move imports into TelegramUIFramework.
        # Extension-to-extension edges remain valid and are fully checked below.
        extension_ids = {install_id for install_id, binary in expected.items()
                         if binary != python_frameworks["Python"][0]}
        extension_binaries = {expected[install_id] for install_id in extension_ids}
        importers = [(executable, main, False)] + [
            (binary, metadata, framework in python_frameworks)
            for framework, (binary, metadata) in frameworks.items()
        ]
        target_slices = {binary: slices for binary, slices in python_frameworks.values()}
        for binary, slices, is_python in importers:
            for metadata in slices:
                for dependency in metadata["loads"]:
                    if dependency.startswith(("/usr/lib/", "/System/Library/")):
                        continue
                    if not is_python and not _python_dependency(dependency):
                        continue
                    target = expected.get(dependency)
                    if target is None:
                        raise VerificationError(f"unresolved Python dylib in {binary}: {dependency}")
                    if dependency in extension_ids and binary not in extension_binaries:
                        raise VerificationError(f"startup-linked Python extension in {binary}: {dependency}; embed for lazy import only")
                    if not _matching_slices(target_slices[target], metadata):
                        raise VerificationError(f"Python dylib lacks a compatible arm64 slice in {binary}: {dependency}")
                    inherited_paths = [path for item in _matching_slices(main, metadata) for path in item["rpaths"]]
                    suffix = dependency[len("@rpath/"):]
                    candidates = {
                        posixpath.normpath(f"{root}/{suffix}")
                        for loader, paths in ((binary, metadata["rpaths"]), (executable, inherited_paths))
                        for rpath in paths
                        if (root := _expand_rpath(rpath, loader, executable)) is not None
                    }
                    if target not in candidates:
                        raise VerificationError(f"Python dylib cannot resolve through LC_RPATH in {binary}: {dependency}")

        marker_targets = set()
        marker_count = 0
        marker_prefix = f"{app}/AyuPythonResources.bundle/python/lib/python3.15/lib-dynload/"
        for name in sorted(names):
            if name.startswith(f"{app}/AyuPythonResources.bundle/") and name.endswith((".so", ".dylib", ".a", ".o")):
                raise VerificationError(f"loose native object in Python resources: {name}")
            if not name.startswith(marker_prefix) or not name.endswith(".fwork"):
                continue
            target = ipa.read(name).decode("utf-8").strip()
            if not re.fullmatch(r"Frameworks/(AyuPyExt_[0-9a-f]{16})\.framework/\1", target):
                raise VerificationError(f"unsafe or unexpected .fwork marker: {name}")
            full_target = f"{app}/{target}"
            if full_target not in expected.values() or full_target not in names:
                raise VerificationError(f".fwork points to missing extension: {name}")
            marker_targets.add(full_target)
            marker_count += 1
        extensions = {binary for framework, (binary, _) in python_frameworks.items() if framework != "Python"}
        if marker_targets != extensions:
            raise VerificationError("Python .fwork inventory does not match embedded extension frameworks")
        resources = verify_resources(ipa, app, sdk_sources)
        return {"python_frameworks": len(python_frameworks), "extension_markers": marker_count,
                 "python_dyld_edges": "verified", "python_extensions": "embedded, not startup-linked",
                 "device_launch": "not tested", **resources}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_ipa.py <debug_arm64.ipa>", file=sys.stderr)
        return 2
    try:
        sdk_sources = Path(__file__).resolve().parents[2] / "submodules/AyuPluginBridge/Python"
        result = verify_ipa(Path(sys.argv[1]), sdk_sources=sdk_sources)
    except (VerificationError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"Python IPA verification failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
