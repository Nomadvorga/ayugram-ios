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


def macho(*, install_id=None, loads=(), rpaths=(), platform=2, subtype=0):
    """Construct just synthetic headers/load commands, with no executable code."""
    commands = []
    for kind, name in ([(0xD, install_id)] if install_id is not None else []) + [(0xC, name) for name in loads] + [(0x8000001C, name) for name in rpaths]:
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
        f"{APP}/Swiftgram": macho(loads=(PYTHON_ID, EXT_ID), rpaths=("@executable_path/Frameworks",)),
        MARKER: f"Frameworks/{EXT}.framework/{EXT}\n".encode(),
    }
    for framework, install_id in (("Python", PYTHON_ID), (EXT, EXT_ID)):
        base = f"{APP}/Frameworks/{framework}.framework"
        entries[base + "/Info.plist"] = plistlib.dumps({"CFBundleExecutable": framework})
        entries[base + "/" + framework] = macho(install_id=install_id, loads=("/usr/lib/libSystem.B.dylib",) + ((PYTHON_ID,) if framework == EXT else ()))
    return entries


class VerifyIPAHelperTests(unittest.TestCase):
    def verify_entries(self, entries):
        with tempfile.TemporaryDirectory() as temporary:
            ipa = Path(temporary) / "fixture.ipa"
            with zipfile.ZipFile(ipa, "w") as archive:
                for name, data in entries.items():
                    archive.writestr(name, data)
            return verify.verify_ipa(ipa)

    def test_complete_python_graph_and_fwork_inventory(self):
        result = self.verify_entries(fixture())
        self.assertEqual(result["python_frameworks"], 2)
        self.assertEqual(result["extension_markers"], 1)
        self.assertEqual(result["device_launch"], "not tested")

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
        entries[name] = fat_macho([entries[name], macho(loads=(PYTHON_ID, EXT_ID), subtype=2)])
        with self.assertRaisesRegex(verify.VerificationError, "LC_RPATH"):
            self.verify_entries(entries)

    def test_incompatible_dependency_subtype_is_rejected(self):
        entries = fixture()
        name = f"{APP}/Frameworks/{EXT}.framework/{EXT}"
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
        entries[f"{APP}/Swiftgram"] = macho(loads=(PYTHON_ID, EXT_ID))
        with self.assertRaisesRegex(verify.VerificationError, "LC_RPATH"):
            self.verify_entries(entries)

    def test_python_imports_in_other_app_framework_are_checked(self):
        entries = fixture()
        base = f"{APP}/Frameworks/TelegramUIFramework.framework"
        entries[base + "/Info.plist"] = plistlib.dumps({"CFBundleExecutable": "TelegramUIFramework"})
        entries[base + "/TelegramUIFramework"] = macho(install_id="@rpath/TelegramUIFramework.framework/TelegramUIFramework", loads=(EXT_ID,))
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
