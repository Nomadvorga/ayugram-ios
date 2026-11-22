#!/usr/bin/env python3
"""Read-only Python dyld/marker checks on the final IPA, without loading its code."""
from __future__ import annotations

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


def read_macho(stream: BinaryIO) -> dict:
    """Read only the header/load commands of an arm64 binary; never execute it."""
    header = stream.read(32)
    if len(header) != 32:
        raise VerificationError("truncated Mach-O header")
    magic, cpu, _, _, count, size, _, _ = struct.unpack("<8I", header)
    if magic != 0xFEEDFACF or cpu != 0x0100000C:
        raise VerificationError("debug_arm64 IPA requires a thin arm64 Mach-O binary")
    if size > 16 * 1024 * 1024 or count > size // 8:
        raise VerificationError("invalid Mach-O load-command bounds")
    data = stream.read(size)
    if len(data) != size:
        raise VerificationError("truncated Mach-O load commands")
    result = {"ids": [], "loads": [], "rpaths": [], "platforms": []}
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


def _python_dependency(name: str) -> bool:
    return "Python.framework/" in name or "AyuPyExt_" in name or ".cpython-" in name or name.startswith(("Modules/", "/Modules/"))


def _expand_rpath(path: str, loader: str, executable: str) -> str | None:
    for token, root in (("@executable_path", posixpath.dirname(executable)),
                        ("@loader_path", posixpath.dirname(loader))):
        if path == token or path.startswith(token + "/"):
            return posixpath.normpath(root + path[len(token):])
    return None


def verify_ipa(path: Path) -> dict:
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

        def read_binary(name: str) -> dict:
            if name not in names:
                raise VerificationError(f"missing embedded binary: {name}")
            with ipa.open(name) as stream:
                return read_macho(stream)

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
        for framework, (binary, metadata) in python_frameworks.items():
            install_id = f"@rpath/{framework}.framework/{framework}"
            if metadata["ids"] != [install_id] or not binary.endswith("/" + framework):
                raise VerificationError(f"incorrect Python framework install ID: {framework}: {metadata['ids']}")
            expected[install_id] = binary

        # Validate Python edges from the executable and other app frameworks too:
        # Bazel may place the bridge's imports in TelegramUIFramework instead.
        importers = [(executable, main, False)] + [
            (binary, metadata, framework in python_frameworks)
            for framework, (binary, metadata) in frameworks.items()
        ]
        for binary, metadata, is_python in importers:
            for dependency in metadata["loads"]:
                if dependency.startswith(("/usr/lib/", "/System/Library/")):
                    continue
                if not is_python and not _python_dependency(dependency):
                    continue
                target = expected.get(dependency)
                if target is None:
                    raise VerificationError(f"unresolved Python dylib in {binary}: {dependency}")
                suffix = dependency[len("@rpath/"):]
                candidates = {
                    posixpath.normpath(f"{root}/{suffix}")
                    for loader, paths in ((binary, metadata["rpaths"]), (executable, main["rpaths"]))
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
        return {"python_frameworks": len(python_frameworks), "extension_markers": marker_count,
                "python_dyld_edges": "verified", "device_launch": "not tested"}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: verify_ipa.py <debug_arm64.ipa>", file=sys.stderr)
        return 2
    try:
        result = verify_ipa(Path(sys.argv[1]))
    except (VerificationError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"Python IPA verification failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
