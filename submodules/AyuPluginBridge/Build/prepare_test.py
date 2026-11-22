"""Offline unit tests for Python packaging helpers (no archive/download needed).

Run from the repository root on any Python 3.11+ host:
    python3 -m unittest submodules.AyuPluginBridge.Build.prepare_test -v
"""

from __future__ import annotations

import ast
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


def fake_macho_tools(records=None):
    """Stateful otool/install_name_tool fixture; never runs a native tool."""
    records = {} if records is None else records
    calls = []

    def run(tool, arguments):
        path = arguments[-1]
        if path not in records:
            legacy = "@rpath/Python.framework/Python" if Path(path).name == "Python" else "Modules/_ssl.cpython-315-ios.so"
            records[path] = {"ids": [legacy], "loads": ["@rpath/Python.framework/Python", "/usr/lib/libSystem.B.dylib"]}
        record = records[path]
        if tool == "otool":
            commands = [("LC_ID_DYLIB", name) for name in record["ids"]]
            commands += [("LC_LOAD_DYLIB", name) for name in record["loads"]]
            return "\n".join(f"Load command {index}\n          cmd {kind}\n      cmdsize 104\n         name {name} (offset 24)" for index, (kind, name) in enumerate(commands))
        if tool != "install_name_tool":
            raise AssertionError(tool)
        calls.append(arguments)
        record["ids"] = [arguments[1]] * len(record["ids"])
        offset = 2
        while arguments[offset] == "-change":
            old, new = arguments[offset + 1:offset + 3]
            record["loads"] = [new if name == old else name for name in record["loads"]]
            offset += 3
        return ""

    return run, calls


def build_targets(build, rule):
    """Inspect generated declarations without executing Starlark or Bazel."""
    result = {}
    for statement in ast.parse(build).body:
        call = statement.value if isinstance(statement, ast.Expr) else None
        if isinstance(call, ast.Call) and isinstance(call.func, ast.Name) and call.func.id == rule:
            attributes = {keyword.arg: keyword.value for keyword in call.keywords}
            result[ast.literal_eval(attributes["name"])] = attributes
    return result


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

    def test_all_extensions_are_bundle_only_but_core_runtime_stays_linked(self) -> None:
        modules = ["_bisect", "_hashlib", "_ssl", "encodings.foo"]
        build, _ = prepare._write_build_file(modules)
        imports = build_targets(build, "apple_dynamic_xcframework_import")
        self.assertNotIn("bundle_only", imports["python_runtime"])
        extension_targets = {prepare.bazel_name_for_module(module) for module in modules}
        self.assertEqual(set(imports), {"python_runtime"} | extension_targets)
        for target in extension_targets:
            self.assertIs(ast.literal_eval(imports[target]["bundle_only"]), True)
        library = build_targets(build, "objc_library")["Python"]
        # Keep the dependencies: their bundling providers carry the frameworks.
        self.assertEqual(set(ast.literal_eval(library["deps"])), {":python_runtime"} | {":" + target for target in extension_targets})
        self.assertEqual(ast.literal_eval(library["data"]), [":PythonResources"])

    def test_relocation_updates_bisect_ids_and_cross_module_edges_in_both_slices(self) -> None:
        root = Path("/fixture/generated")
        targets = {module: {"framework": prepare.framework_name_for_module(module)} for module in ("_bisect", "_ssl")}
        maps = tuple({module: (Path("/fixture/archive") / f"{module}.cpython-315-{platform}.so", "unused.fwork") for module in targets}
                     for platform in ("iphoneos", "iphonesimulator", "iphonesimulator"))
        records = {}
        for slice_name in (prepare.DEVICE_SLICE, prepare.SIMULATOR_SLICE):
            for module, entry in targets.items():
                framework = entry["framework"]
                binary = root / "PythonExtensions" / f"{framework}.xcframework" / slice_name / f"{framework}.framework" / framework
                platform = "iphoneos" if slice_name == prepare.DEVICE_SLICE else "iphonesimulator"
                records[str(binary)] = {
                    "ids": [f"Modules/{module}.cpython-315-{platform}.so"] * (1 if platform == "iphoneos" else 2),
                    "loads": ["Python", "Modules/_bisect.cpython-315-" + platform + ".so"],
                }
        run, calls = fake_macho_tools(records)
        with patch.object(prepare, "_run_macho_tool", side_effect=run):
            prepare._relocate_python_frameworks(root, targets, maps)
        self.assertEqual(len(calls), 6)  # Python + both modules, device + simulator.
        for binary, metadata in records.items():
            framework = Path(binary).name
            self.assertEqual(set(metadata["ids"]), {f"@rpath/{framework}.framework/{framework}"})
            self.assertFalse(any(name.startswith("Modules/") for name in metadata["loads"]))
        self.assertTrue(any("-change" in call for call in calls))

    def test_relocation_rejects_unbundled_dylib(self) -> None:
        root = Path("/fixture/generated")
        runtime = root / "PythonRuntime.xcframework" / prepare.DEVICE_SLICE / "Python.framework" / "Python"
        run, _ = fake_macho_tools({str(runtime): {"ids": ["Python"], "loads": ["/build/missing/libffi.dylib"]}})
        with patch.object(prepare, "_run_macho_tool", side_effect=run), self.assertRaisesRegex(prepare.PrepareError, "unbundled"):
            prepare._relocate_python_frameworks(root, {}, ({}, {}, {}))

    def test_relocation_detects_tool_that_did_not_update_ids(self) -> None:
        def unchanged(tool, args):
            return "cmd LC_ID_DYLIB\nname Modules/_bisect.so (offset 24)\n" if tool == "otool" else ""
        with patch.object(prepare, "_run_macho_tool", side_effect=unchanged), self.assertRaisesRegex(prepare.PrepareError, "failed to relocate"):
            prepare._relocate_python_frameworks(Path("/fixture/generated"), {}, ({}, {}, {}))

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

            macho_tool, relocation_calls = fake_macho_tools()
            with patch.object(prepare, "_architectures", side_effect=[{"arm64"}, {"arm64"}, {"x86_64"}, {"arm64", "x86_64"}]), \
                 patch.object(prepare, "_run_lipo", side_effect=fake_lipo), \
                 patch.object(prepare, "_run_macho_tool", side_effect=macho_tool):
                metadata = prepare.prepare(archive, output, certifi)
            self.assertEqual(len(relocation_calls), 4)
            self.assertEqual((xcf / prepare.DEVICE_SLICE / "lib-arm64/python3.15/lib-dynload/_ssl.cpython-315-ios.so").read_bytes(), b"\xcf\xfa\xed\xfearm64")
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
            imports = build_targets(build, "apple_dynamic_xcframework_import")
            self.assertIs(ast.literal_eval(imports[prepare.bazel_name_for_module("_ssl")]["bundle_only"]), True)
            self.assertNotIn("bundle_only", imports["python_runtime"])
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
