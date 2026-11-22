"""Offline unit tests for Python packaging helpers (no archive/download needed).

Run from the repository root on any Python 3.11+ host:
    python3 -m unittest submodules.AyuPluginBridge.Build.prepare_test -v
"""

from __future__ import annotations

import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

_REPO = Path(__file__).resolve().parents[3]
_PREPARE = _REPO / "third-party" / "ayu-python" / "prepare.py"
_SPEC = importlib.util.spec_from_file_location("ayu_python_prepare", _PREPARE)
assert _SPEC is not None and _SPEC.loader is not None
prepare = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(prepare)


class PrepareHelperTests(unittest.TestCase):
    def test_relative_path_rejects_traversal(self) -> None:
        for unsafe in ("../escape", "/absolute", "a/../../escape", "a\\..\\escape"):
            with self.subTest(unsafe=unsafe), self.assertRaises(prepare.PrepareError):
                prepare.validate_relative_path(unsafe)

    def test_extension_module_and_fwork_marker_keep_package_path(self) -> None:
        module, marker = prepare.module_for_extension("_ssl.cpython-315-ios.so")
        self.assertEqual(module, "_ssl")
        self.assertEqual(marker, "_ssl.cpython-315-ios.fwork")

        module, marker = prepare.module_for_extension("encodings/foo.abi3.so")
        self.assertEqual(module, "encodings.foo")
        self.assertEqual(marker, "encodings/foo.abi3.fwork")

    def test_target_names_are_stable_and_distinct(self) -> None:
        first = prepare.bazel_name_for_module("pkg.foo")
        self.assertEqual(first, prepare.bazel_name_for_module("pkg.foo"))
        self.assertNotEqual(first, prepare.bazel_name_for_module("pkg_foo"))
        self.assertTrue(first.startswith("pyext_"))

    def test_resource_copy_excludes_native_modules_and_cache_dirs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "archive" / "stdlib"
            source.mkdir(parents=True)
            (source / "module.py").write_text("value = 1\n")
            (source / "unsafe.so").write_bytes(b"not copied")
            (source / "__pycache__").mkdir()
            (source / "__pycache__" / "module.pyc").write_bytes(b"not copied")
            (source / "lib-dynload").mkdir()
            (source / "lib-dynload" / "_ssl.so").write_bytes(b"native")
            destination = root / "resources" / "python" / "lib"

            prepare.copy_resource_tree(source, destination, root)

            self.assertEqual((destination / "module.py").read_text(), "value = 1\n")
            self.assertFalse((destination / "unsafe.so").exists())
            self.assertFalse((destination / "__pycache__").exists())
            self.assertFalse((destination / "lib-dynload").exists())

    def test_resource_copy_rejects_symlink_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "archive" / "stdlib"
            source.mkdir(parents=True)
            outside = root / "outside.txt"
            outside.write_text("outside")
            (source / "escape.txt").symlink_to(outside)
            with self.assertRaises(prepare.PrepareError):
                prepare.copy_resource_tree(source, root / "out", root / "archive")

    def test_generated_bazel_labels_include_core_extensions_and_resource_bundle(self) -> None:
        build, helper = prepare._write_build_file(["_ssl", "encodings.foo"])
        self.assertIn('name = "python_runtime"', build)
        self.assertIn('name = "Python"', build)
        self.assertIn('name = "PythonResources"', build)
        self.assertIn("PythonExtensions/AyuPyExt_", build)
        self.assertIn('"@ayu_python//:Python"', helper)
        self.assertIn('"@ayu_python//:PythonResources"', helper)
        self.assertIn("python_resource_deps", helper)

    def test_complete_archive_preparation_without_native_tools(self) -> None:
        """Exercise the actual preparation path, not only isolated formatting helpers."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "archive"
            archive.mkdir()
            output = root / "repository"
            output.mkdir()
            certifi = root / "certifi-source"
            (certifi / "certifi").mkdir(parents=True)
            (certifi / "certifi" / "cacert.pem").write_text("fixture certificate data")
            (certifi / "certifi" / "__init__.py").write_text("# fixture")
            (certifi / "LICENSE").write_text("fixture license")
            (archive / "VERSIONS").write_text("Python version: 3.15.2\nBuild: b3\n")
            xcf = archive / "Python.xcframework"
            xcf.mkdir()
            libraries = []
            for identifier, arches in ((prepare.DEVICE_SLICE, ["arm64"]),
                                        (prepare.SIMULATOR_SLICE, ["arm64", "x86_64"])):
                library = {"LibraryIdentifier": identifier, "LibraryPath": "Python.framework",
                           "SupportedArchitectures": arches, "SupportedPlatform": "ios"}
                if "simulator" in identifier:
                    library["SupportedPlatformVariant"] = "simulator"
                libraries.append(library)
                framework = xcf / identifier / "Python.framework"
                (framework / "Headers").mkdir(parents=True)
                (framework / "Headers" / "Python.h").write_text("/* fixture */")
                (framework / "Python").write_bytes(b"\xcf\xfa\xed\xfe" + b"runtime")
                prepare._write_plist(framework / "Info.plist", {"CFBundleExecutable": "Python"})
                for arch in arches:
                    lib = xcf / identifier / ("lib-" + arch) / "python3.15"
                    (lib / "lib-dynload").mkdir(parents=True)
                    (lib / "lib-dynload" / "_ssl.cpython-315-ios.so").write_bytes(b"\xcf\xfa\xed\xfe" + arch.encode())
                    config = "_sysconfigdata_" + identifier.replace("-", "_") + "_" + arch + ".py"
                    (lib / config).write_text("build_time_vars = {}")
            prepare._write_plist(xcf / "Info.plist", {"AvailableLibraries": libraries,
                                  "CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0"})
            common = xcf / "lib" / "python3.15"
            (common / "encodings").mkdir(parents=True)
            (common / "encodings" / "__init__.py").write_text("# fixture")

            def fake_lipo(arguments):
                Path(arguments[-1]).write_bytes(b"\xca\xfe\xba\xbe" + b"universal")
                return ""

            with patch.object(prepare, "_architectures", side_effect=[{"arm64"}, {"arm64"}, {"x86_64"}, {"arm64", "x86_64"}]), \
                 patch.object(prepare, "_run_lipo", side_effect=fake_lipo):
                metadata = prepare.prepare(archive, output, certifi)
            self.assertEqual(set(metadata["extension_modules"]), {"_ssl"})
            resource = output / "PythonResources" / "python" / "lib" / "python3.15"
            self.assertTrue((resource / "encodings" / "__init__.py").is_file())
            self.assertTrue((resource / "certifi" / "cacert.pem").is_file())
            marker = resource / "lib-dynload" / "_ssl.cpython-315-ios.fwork"
            self.assertTrue(marker.read_text().startswith("Frameworks/AyuPyExt_"))
            self.assertFalse(list((output / "PythonResources").rglob("*.so")))
            build = (output / "BUILD.bazel").read_text()
            self.assertIn('load("@rules_cc//cc:objc_library.bzl", "objc_library")', build)
            self.assertIn("@build_bazel_rules_apple", build)
            self.assertIn('name = "PythonResources"', build)
            with self.assertRaises(prepare.PrepareError):
                prepare.prepare(archive, output, certifi)

    def test_xcframework_plist_serializer_writes_xml_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "Info.plist"
            expected = {
                "AvailableLibraries": [
                    {
                        "LibraryIdentifier": "ios-arm64",
                        "LibraryPath": "AyuPyExt.framework",
                        "SupportedArchitectures": ["arm64"],
                        "SupportedPlatform": "ios",
                    },
                ],
                "CFBundlePackageType": "XFWK",
                "XCFrameworkFormatVersion": "1.0",
            }
            prepare._write_plist(path, expected)
            self.assertEqual(plistlib.loads(path.read_bytes()), expected)


if __name__ == "__main__":
    unittest.main()
