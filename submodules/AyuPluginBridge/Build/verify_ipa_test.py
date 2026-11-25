"""Synthetic Mach-O/IPA fixtures only: no downloads, compiler, or app execution."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

_REPO = Path(__file__).resolve().parents[3]
_SPEC = importlib.util.spec_from_file_location("ayu_python_verify_ipa", _REPO / "third-party/ayu-python/verify_ipa.py")
assert _SPEC is not None and _SPEC.loader is not None
verify = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(verify)

EXT = "AyuPyExt_" + hashlib.sha256(b"_bisect").hexdigest()[:16]
PYTHON_ID = "@rpath/Python.framework/Python"
EXT_ID = f"@rpath/{EXT}.framework/{EXT}"
APP = "Payload/Swiftgram.app"
MARKER = f"{APP}/AyuPythonResources.bundle/python/lib/python3.15/lib-dynload/_bisect.cpython-315-iphoneos.fwork"
SDK_PREFIX = f"{APP}/AyuPluginSDK.bundle/Python/"
ENCODINGS = f"{APP}/AyuPythonResources.bundle/python/lib/python3.15/encodings/__init__.py"
SMOKE = f"{APP}/AyuPluginSDK.bundle/Resources/bridge_smoke.plugin"


def macho(*, install_id=None, loads=(), rpaths=(), platform=2, subtype=0, load_kind=0xC):
    """Construct just synthetic headers/load commands, with no executable code."""
    commands = []
    for kind, name in ([(0xD, install_id)] if install_id is not None else []) + [(load_kind, name) for name in loads] + [(0x8000001C, name) for name in rpaths]:
        start = 12 if kind == 0x8000001C else 24
        text = name.encode() + b"\0"
        length = (start + len(text) + 7) // 8 * 8
        command = struct.pack("<3I", kind, length, start) + bytes(start - 12) + text
        commands.append(command.ljust(length, b"\0"))
    commands.append(struct.pack("<6I", 0x32, 24, platform, 0, 0, 0))
    data = b"".join(commands)
    return struct.pack("<8I", 0xFEEDFACF, 0x0100000C, subtype, 6 if install_id else 2, len(commands), len(data), 0, 0) + data


def fat_macho(slices, *, wide=False, endian=">"):
    """Synthetic FAT32/FAT64 wrappers, including a legitimate single-slice FAT."""
    header = struct.pack(endian + "2I", 0xCAFEBABF if wide else 0xCAFEBABE, len(slices))
    offset = (8 + len(slices) * (32 if wide else 20) + 7) // 8 * 8
    table = []
    payload = []
    for binary in slices:
        cpu, subtype = struct.unpack_from("<2I", binary, 4)
        fields = (cpu, subtype, offset, len(binary), 3)
        table.append(struct.pack(endian + ("IIQQII" if wide else "5I"), *(fields + (0,) if wide else fields)))
        payload.append((offset, binary))
        offset = (offset + len(binary) + 7) // 8 * 8
    result = header + b"".join(table)
    for offset, binary in payload:
        result = result.ljust(offset, b"\0") + binary
    return result


def with_subtype(binary, subtype):
    return binary[:8] + struct.pack("<I", subtype) + binary[12:]


def fixture():
    entries = {
        f"{APP}/Info.plist": plistlib.dumps({"CFBundleExecutable": "Swiftgram"}),
        f"{APP}/Swiftgram": macho(loads=(PYTHON_ID,), rpaths=("@executable_path/Frameworks",)),
        MARKER: f"Frameworks/{EXT}.framework/{EXT}\n".encode(),
        ENCODINGS: b"# synthetic encodings fixture\n",
        SMOKE: b"# synthetic smoke source\n",
    }
    entries.update({SDK_PREFIX + name: b"# synthetic SDK source\n" for name in verify.SDK_FILES})
    for framework, install_id in (("Python", PYTHON_ID), (EXT, EXT_ID)):
        base = f"{APP}/Frameworks/{framework}.framework"
        entries[base + "/Info.plist"] = plistlib.dumps({"CFBundleExecutable": framework})
        entries[base + "/" + framework] = macho(install_id=install_id, loads=("/usr/lib/libSystem.B.dylib",) + ((PYTHON_ID,) if framework == EXT else ()))
    return entries


def add_extension(entries, module, *, loads=(PYTHON_ID,), subtype=0):
    framework = "AyuPyExt_" + hashlib.sha256(module.encode()).hexdigest()[:16]
    install_id = f"@rpath/{framework}.framework/{framework}"
    base = f"{APP}/Frameworks/{framework}.framework"
    binary = base + "/" + framework
    entries[base + "/Info.plist"] = plistlib.dumps({"CFBundleExecutable": framework})
    entries[binary] = macho(install_id=install_id, loads=loads, subtype=subtype)
    marker = f"{APP}/AyuPythonResources.bundle/python/lib/python3.15/lib-dynload/{module}.cpython-315-iphoneos.fwork"
    entries[marker] = f"Frameworks/{framework}.framework/{framework}\n".encode()
    return binary, install_id


class VerifyIPAHelperTests(unittest.TestCase):
    def verify_entries(self, entries, *, sdk_sources=None):
        with tempfile.TemporaryDirectory() as temporary:
            ipa = Path(temporary) / "fixture.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                for name, data in entries.items():
                    archive.writestr(name, data)
            return verify.verify_ipa(ipa, sdk_sources=sdk_sources)

    def test_complete_python_graph_and_fwork_inventory(self):
        result = self.verify_entries(fixture())
        self.assertEqual(result["python_frameworks"], 2)
        self.assertEqual(result["extension_markers"], 1)
        self.assertEqual(result["python_extensions"], "embedded, not startup-linked")
        self.assertEqual(result["device_launch"], "not tested")
        self.assertEqual(result["plugin_runtime_resources"], "verified")
        self.assertEqual(result["plugin_sdk_files"], len(verify.SDK_FILES))

    def test_resource_bundles_can_be_data_only_without_info_plist(self):
        entries = fixture()
        self.assertFalse(any(".bundle/Info.plist" in name for name in entries))
        self.verify_entries(entries)

    def test_missing_bootstrap_stdlib_smoke_or_sdk_file_is_rejected(self):
        for missing in [ENCODINGS, SMOKE] + [SDK_PREFIX + name for name in verify.SDK_FILES]:
            with self.subTest(missing=missing):
                entries = fixture()
                del entries[missing]
                with self.assertRaisesRegex(verify.VerificationError, "missing plugin runtime resource"):
                    self.verify_entries(entries)

    def test_wrong_sdk_directory_does_not_count_as_runtime_support(self):
        for wrong in ["ayu_bridge.py", "python/ayu_bridge.py", "Python/Python/ayu_bridge.py"]:
            entries = fixture()
            data = entries.pop(SDK_PREFIX + "ayu_bridge.py")
            entries[f"{APP}/AyuPluginSDK.bundle/" + wrong] = data
            with self.subTest(wrong=wrong), self.assertRaisesRegex(verify.VerificationError, "missing plugin runtime resource"):
                self.verify_entries(entries)

    def test_empty_directory_or_symlink_cannot_replace_a_runtime_file(self):
        entries = fixture()
        entries[ENCODINGS] = b""
        with self.assertRaisesRegex(verify.VerificationError, "invalid plugin runtime resource"):
            self.verify_entries(entries)
        for mode in [0o040755, 0o120777]:
            with tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "fixture.ipa"
                with zipfile.ZipFile(path, "w") as archive:
                    for name, data in fixture().items():
                        info = zipfile.ZipInfo(name)
                        info.external_attr = ((mode if name == ENCODINGS else 0o100644) << 16)
                        archive.writestr(info, data)
                with self.subTest(mode=mode), self.assertRaisesRegex(verify.VerificationError, "invalid plugin runtime resource"):
                    verify.verify_ipa(path)

    def test_packaged_sdk_inventory_and_hashes_match_the_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            entries = fixture()
            for name in verify.SDK_FILES:
                file = source / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(entries[SDK_PREFIX + name])
            result = self.verify_entries(entries, sdk_sources=source)
            self.assertEqual(result["plugin_sdk_source_hashes"], "verified")
            entries[SDK_PREFIX + "ayu_bridge.py"] = b"# stale SDK\n"
            with self.assertRaisesRegex(verify.VerificationError, "source hash differs"):
                self.verify_entries(entries, sdk_sources=source)
            entries = fixture()
            entries[SDK_PREFIX + "obsolete.py"] = b"# untracked SDK\n"
            with self.assertRaisesRegex(verify.VerificationError, "inventory differs"):
                self.verify_entries(entries, sdk_sources=source)

    def test_crypto_extensions_can_be_embedded_without_startup_loads(self):
        entries = fixture()
        for module in ("_hashlib", "_ssl"):
            add_extension(entries, module)
        result = self.verify_entries(entries)
        self.assertEqual(result["python_frameworks"], 4)
        self.assertEqual(result["extension_markers"], 3)

    def test_startup_crypto_extension_edges_are_rejected_from_all_importers(self):
        for module in ("_hashlib", "_ssl"):
            for importer in ("executable", "app_framework", "python_runtime"):
                for kind in sorted(verify.LOAD_COMMANDS):
                    for wrapper in ("thin", "fat32", "fat64", "fat64_little"):
                        with self.subTest(module=module, importer=importer, kind=hex(kind), wrapper=wrapper):
                            entries = fixture()
                            _, install_id = add_extension(entries, module)
                            if importer == "executable":
                                binary, own_id = f"{APP}/Swiftgram", None
                            elif importer == "python_runtime":
                                binary, own_id = f"{APP}/Frameworks/Python.framework/Python", PYTHON_ID
                            else:
                                base = f"{APP}/Frameworks/TelegramUIFramework.framework"
                                binary = base + "/TelegramUIFramework"
                                own_id = "@rpath/TelegramUIFramework.framework/TelegramUIFramework"
                                entries[base + "/Info.plist"] = plistlib.dumps({"CFBundleExecutable": "TelegramUIFramework"})
                                entries[binary] = macho(install_id=own_id)
                            bad = macho(install_id=own_id, loads=(install_id,), load_kind=kind,
                                        rpaths=("@executable_path/Frameworks",), subtype=0 if wrapper == "thin" else 2)
                            entries[binary] = bad if wrapper == "thin" else fat_macho(
                                [entries[binary], bad], wide=wrapper.startswith("fat64"),
                                endian="<" if wrapper.endswith("little") else ">")
                            with self.assertRaisesRegex(verify.VerificationError, "startup-linked Python extension in " + binary):
                                self.verify_entries(entries)

    def test_non_crypto_extension_startup_edge_is_also_rejected(self):
        entries = fixture()
        entries[f"{APP}/Swiftgram"] = macho(loads=(PYTHON_ID, EXT_ID), rpaths=("@executable_path/Frameworks",))
        with self.assertRaisesRegex(verify.VerificationError, "startup-linked Python extension"):
            self.verify_entries(entries)

    def test_lazy_cross_extension_dependencies_are_still_validated(self):
        entries = fixture()
        _, crypto_id = add_extension(entries, "_hashlib")
        binary, ssl_id = add_extension(entries, "_ssl", loads=(PYTHON_ID, crypto_id))
        self.verify_entries(entries)
        entries[binary] = macho(install_id=ssl_id, loads=("Modules/_hashlib.cpython-315-iphoneos.so",))
        with self.assertRaisesRegex(verify.VerificationError, "unresolved Python dylib"):
            self.verify_entries(entries)

    def test_lazy_cross_extension_rpaths_cannot_hide_in_another_slice(self):
        entries = fixture()
        entries[f"{APP}/Swiftgram"] = fat_macho([entries[f"{APP}/Swiftgram"], macho(subtype=2)])
        _, crypto_id = add_extension(entries, "_hashlib")
        binary, ssl_id = add_extension(entries, "_ssl", loads=(PYTHON_ID, crypto_id))
        entries[binary] = fat_macho([
            entries[binary],
            macho(install_id=ssl_id, loads=(crypto_id,), subtype=2),
        ])
        # The exact arm64e main slice has no rpaths; do not borrow the other slice's.
        with self.assertRaisesRegex(verify.VerificationError, "LC_RPATH"):
            self.verify_entries(entries)

    def test_lazy_cross_extension_requires_compatible_slice(self):
        entries = fixture()
        _, crypto_id = add_extension(entries, "_hashlib", subtype=2)
        add_extension(entries, "_ssl", loads=(PYTHON_ID, crypto_id))
        with self.assertRaisesRegex(verify.VerificationError, "compatible arm64 slice"):
            self.verify_entries(entries)

    def test_single_arm64_slice_fat_wrappers_are_valid(self):
        for wide in (False, True):
            for endian in (">", "<"):
                entries = {name: fat_macho([data], wide=wide, endian=endian) if data.startswith(b"\xcf\xfa\xed\xfe") else data
                           for name, data in fixture().items()}
                with self.subTest(wide=wide, endian=endian):
                    self.verify_entries(entries)

    def test_multiple_arm64_subtypes_are_checked_separately(self):
        entries = {name: fat_macho([data, with_subtype(data, 2)], wide=True) if data.startswith(b"\xcf\xfa\xed\xfe") else data
                   for name, data in fixture().items()}
        self.verify_entries(entries)

    def test_one_bad_install_id_cannot_hide_behind_good_fat_slice(self):
        entries = fixture()
        name = f"{APP}/Frameworks/{EXT}.framework/{EXT}"
        entries[name] = fat_macho([entries[name], macho(install_id="Modules/_bisect.cpython-315-iphoneos.so", subtype=2)])
        with self.assertRaisesRegex(verify.VerificationError, "incorrect Python framework install ID"):
            self.verify_entries(entries)

    def test_one_bad_load_cannot_hide_behind_good_fat_slice(self):
        entries = fixture()
        name = f"{APP}/Swiftgram"
        entries[name] = fat_macho([entries[name], macho(loads=("Modules/_bisect.cpython-315-iphoneos.so",), subtype=2)])
        with self.assertRaisesRegex(verify.VerificationError, "unresolved Python dylib"):
            self.verify_entries(entries)

    def test_rpaths_are_not_combined_across_fat_slices(self):
        entries = fixture()
        name = f"{APP}/Swiftgram"
        entries[name] = fat_macho([entries[name], macho(loads=(PYTHON_ID,), subtype=2)])
        with self.assertRaisesRegex(verify.VerificationError, "LC_RPATH"):
            self.verify_entries(entries)

    def test_incompatible_dependency_subtype_is_rejected(self):
        entries = fixture()
        name = f"{APP}/Frameworks/Python.framework/Python"
        entries[name] = fat_macho([with_subtype(entries[name], 2)])
        with self.assertRaisesRegex(verify.VerificationError, "compatible arm64 slice"):
            self.verify_entries(entries)

    def test_fat_simulator_and_non_arm64_slices_are_rejected(self):
        for binary in (macho(platform=7), macho()[:4] + struct.pack("<I", 0x01000007) + macho()[8:]):
            with self.subTest(header=binary[:12]), self.assertRaises(verify.VerificationError):
                verify.read_macho(io.BytesIO(fat_macho([binary])))

    def test_invalid_fat_tables_and_bounds_are_rejected(self):
        valid = fat_macho([macho()])
        outside = bytearray(valid)
        struct.pack_into(">I", outside, 16, len(valid) + 8)
        mismatch = bytearray(valid)
        struct.pack_into(">I", mismatch, 12, 2)
        overlap = bytearray(fat_macho([macho(), macho(subtype=2)]))
        struct.pack_into(">I", overlap, 36, struct.unpack_from(">I", overlap, 16)[0])
        for binary in (valid[:10], bytes(outside), bytes(mismatch), bytes(overlap), fat_macho([macho(), macho()])):
            with self.subTest(header=binary[:48]), self.assertRaises(verify.VerificationError):
                verify.read_macho(io.BytesIO(binary), len(binary))

    def test_binary_error_includes_archive_path(self):
        entries = fixture()
        name = f"{APP}/Frameworks/{EXT}.framework/{EXT}"
        entries[name] = b"not a Mach-O binary".ljust(32, b"\0")
        with self.assertRaisesRegex(verify.VerificationError, name):
            self.verify_entries(entries)

    def test_fat_parser_reads_headers_not_entire_binary_payload(self):
        class HeaderOnlyStream(io.BytesIO):
            def read(self, size=-1):
                if not 0 <= size <= 4096:
                    raise AssertionError("parser attempted to read executable payload")
                return super().read(size)
        binary = fat_macho([macho() + b"fixture padding" * 100_000])
        self.assertEqual(len(verify.read_macho(HeaderOnlyStream(binary), len(binary))), 1)

    def test_original_crash_legacy_bisect_load_is_rejected(self):
        for legacy in ("Modules/_bisect.cpython-315-iphoneos.so", "/_bisect.cpython-315-iphoneos.so"):
            entries = fixture()
            entries[f"{APP}/Swiftgram"] = macho(loads=(PYTHON_ID, legacy), rpaths=("@executable_path/Frameworks",))
            with self.subTest(legacy=legacy), self.assertRaisesRegex(verify.VerificationError, "unresolved Python dylib"):
                self.verify_entries(entries)

    def test_renamed_file_with_old_install_id_is_rejected(self):
        entries = fixture()
        entries[f"{APP}/Frameworks/{EXT}.framework/{EXT}"] = macho(install_id="Modules/_bisect.cpython-315-iphoneos.so")
        with self.assertRaisesRegex(verify.VerificationError, "incorrect Python framework install ID"):
            self.verify_entries(entries)

    def test_missing_embedded_extension_is_rejected(self):
        entries = fixture()
        del entries[f"{APP}/Frameworks/{EXT}.framework/{EXT}"]
        with self.assertRaisesRegex(verify.VerificationError, "missing embedded binary"):
            self.verify_entries(entries)

    def test_missing_runtime_dependency_is_rejected(self):
        entries = fixture()
        entries[f"{APP}/Frameworks/{EXT}.framework/{EXT}"] = macho(install_id=EXT_ID, loads=("@rpath/libffi.dylib",))
        with self.assertRaisesRegex(verify.VerificationError, "unresolved Python dylib"):
            self.verify_entries(entries)

    def test_missing_executable_rpath_is_rejected(self):
        entries = fixture()
        entries[f"{APP}/Swiftgram"] = macho(loads=(PYTHON_ID,))
        with self.assertRaisesRegex(verify.VerificationError, "LC_RPATH"):
            self.verify_entries(entries)

    def test_python_imports_in_other_app_framework_are_checked(self):
        entries = fixture()
        base = f"{APP}/Frameworks/TelegramUIFramework.framework"
        entries[base + "/Info.plist"] = plistlib.dumps({"CFBundleExecutable": "TelegramUIFramework"})
        entries[base + "/TelegramUIFramework"] = macho(install_id="@rpath/TelegramUIFramework.framework/TelegramUIFramework", loads=(PYTHON_ID,))
        self.verify_entries(entries)
        entries[base + "/TelegramUIFramework"] = macho(loads=("Modules/_bisect.cpython-315-iphoneos.so",))
        with self.assertRaisesRegex(verify.VerificationError, "unresolved Python dylib"):
            self.verify_entries(entries)

    def test_unsafe_marker_and_unmarked_extension_are_rejected(self):
        entries = fixture()
        entries[MARKER] = b"../outside.so\n"
        with self.assertRaisesRegex(verify.VerificationError, "unsafe or unexpected"):
            self.verify_entries(entries)
        entries = fixture()
        del entries[MARKER]
        with self.assertRaisesRegex(verify.VerificationError, "inventory"):
            self.verify_entries(entries)

    def test_loose_native_resources_are_rejected(self):
        entries = fixture()
        entries[MARKER.replace(".fwork", ".so")] = b"fixture, not executable"
        with self.assertRaisesRegex(verify.VerificationError, "loose native object"):
            self.verify_entries(entries)

    def test_simulator_binary_in_device_ipa_is_rejected(self):
        entries = fixture()
        entries[f"{APP}/Frameworks/{EXT}.framework/{EXT}"] = macho(install_id=EXT_ID, platform=7)
        with self.assertRaisesRegex(verify.VerificationError, "non-device platform"):
            self.verify_entries(entries)

    def test_malformed_macho_command_bounds_are_rejected(self):
        binary = bytearray(macho(loads=(PYTHON_ID,)))
        struct.pack_into("<I", binary, 36, 0xFFFFFFF8)
        with self.assertRaisesRegex(verify.VerificationError, "length"):
            verify.read_macho(io.BytesIO(binary))
        with self.assertRaisesRegex(verify.VerificationError, "truncated"):
            verify.read_macho(io.BytesIO(b"fixture"))


if __name__ == "__main__":
    unittest.main()
