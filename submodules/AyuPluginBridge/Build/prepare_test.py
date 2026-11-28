"""Offline unit tests for Python packaging helpers (no archive/download needed).

Run from the repository root on any Python 3.11+ host:
    python3 -m unittest submodules.AyuPluginBridge.Build.prepare_test -v
"""

from __future__ import annotations

import ast
import hashlib
import importlib.util
import io
import json
import plistlib
import tarfile
import tempfile
import unittest
import zipfile
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


def wheel_bytes(files, *, mode=0o100644, compression=zipfile.ZIP_STORED):
    """A synthetic wheel: only data, never installed by pip."""
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        for name, content in files.items():
            info = zipfile.ZipInfo(name)
            info.compress_type = compression
            info.external_attr = mode << 16
            archive.writestr(info, content)
    return stream.getvalue()


def wheel_fixture(name="demo", version="1.2", module="demo", *, extra=None, requires=(), tag="py3-none-any", mode=0o100644):
    """Files of a minimal pure-Python wheel plus the lock entry that pins it."""
    dist_info = f"{name}-{version}.dist-info"
    metadata = f"Metadata-Version: 2.4\nName: {name}\nVersion: {version}\n" + "".join(
        f"Requires-Dist: {item}\n" for item in requires) + "\nRequires-Dist: not-a-header\n"
    files = {
        f"{module}/__init__.py": f"VERSION = {version!r}\n",
        f"{dist_info}/METADATA": metadata,
        f"{dist_info}/WHEEL": f"Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: {tag}\n",
        f"{dist_info}/RECORD": "ignored\n",
        f"{dist_info}/licenses/LICENSE": f"{name} license\n",
        f"{name}-{version}.data/scripts/{name}-tool": "#!python\n",
    }
    files.update(extra or {})
    data = wheel_bytes(files, mode=mode)
    filename = f"{name}-{version}-py3-none-any.whl"
    return data, lock_entry(name, version, filename, data, [module], [f"{dist_info}/licenses/LICENSE"])


def lock_entry(name, version, filename, data, modules, license_files, **extra):
    entry = {
        "name": prepare.normalize_distribution(name), "version": version, "kind": "wheel", "filename": filename,
        "url": f"https://files.pythonhosted.org/packages/ab/cd/{'e' * 60}/{filename}",
        "sha256": hashlib.sha256(data).hexdigest(), "modules": modules, "license": "MIT",
        "license_files": license_files, "requires": [],
    }
    entry.update(extra)
    return entry


def sdist_fixture(members=None):
    """A synthetic source distribution whose setup.py must never be read."""
    members = members or {
        "demo-2.0/PKG-INFO": "Metadata-Version: 2.4\nName: Demo_Src\nVersion: 2.0\n",
        "demo-2.0/LICENSE": "source license\n",
        "demo-2.0/setup.py": "raise SystemExit('setup code must not run')\n",
        "demo-2.0/lib/srcmod/__init__.py": "VALUE = 2\n",
        "demo-2.0/lib/srcmod/data.txt": "data\n",
        "demo-2.0/lib/other/__init__.py": "# not pinned\n",
    }
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        for name, content in members.items():
            info = tarfile.TarInfo(name)
            if content is None:
                info.type, info.linkname = tarfile.SYMTYPE, "/etc/hosts"
                archive.addfile(info)
            else:
                data = content.encode()
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
    data = stream.getvalue()
    entry = lock_entry("demo-src", "2.0", "demo_src-2.0.tar.gz", data, ["srcmod"], ["demo-2.0/LICENSE"],
                       kind="sdist", source_root="demo-2.0/lib", metadata="demo-2.0/PKG-INFO")
    return data, entry


def write_packages(root, *fixtures):
    """Lay out downloaded artifacts and their lock as the repository rule does."""
    packages = root / "_packages"
    packages.mkdir(parents=True, exist_ok=True)
    for data, entry in fixtures:
        if isinstance(entry, dict) and isinstance(entry.get("filename"), str):
            (packages / Path(entry["filename"]).name).write_bytes(data)
    lock = root / "packages.lock.json"
    lock.write_text(json.dumps({"schema": 1, "packages": [entry for _, entry in fixtures]}))
    return packages, lock


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
            try:
                (source / "escape.txt").symlink_to(outside)
            except OSError as error:
                if getattr(error, "winerror", None) == 1314:
                    self.skipTest("Windows symlink privilege is unavailable; fixture runs in Linux CI")
                raise
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
            packages, lock = write_packages(root, wheel_fixture(
                "certifi", "2026.1.1", "certifi", extra={"certifi/cacert.pem": "fixture certificate data"}))
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
                metadata = prepare.prepare(archive, output, packages, lock)
            self.assertEqual(len(relocation_calls), 4)
            self.assertEqual((xcf / prepare.DEVICE_SLICE / "lib-arm64/python3.15/lib-dynload/_ssl.cpython-315-ios.so").read_bytes(), b"\xcf\xfa\xed\xfearm64")
            self.assertEqual(set(metadata["extension_modules"]), {"_ssl"})
            resource = output / "PythonResources" / "python" / "lib" / "python3.15"
            self.assertTrue((resource / "encodings" / "__init__.py").is_file())
            self.assertTrue((resource / "certifi" / "cacert.pem").is_file())
            self.assertEqual(metadata["python_packages"], {"certifi": "2026.1.1"})
            self.assertEqual((output / "PythonResources" / "licenses" / "certifi-LICENSE").read_text(), "certifi license\n")
            self.assertTrue((output / "PythonResources" / prepare.PACKAGES_MANIFEST).is_file())
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
                prepare.prepare(archive, output, packages, lock)

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


# SPDX expressions that may be combined with the GPL-2 application.
GPL2_COMPATIBLE_LICENSES = frozenset({
    "MIT", "BSD-2-Clause", "BSD-3-Clause", "PSF-2.0", "MPL-2.0", "GPL-2.0-or-later", "Unlicense", "ISC",
    "Apache-2.0 OR BSD-2-Clause",
})


class PinnedPackageTests(unittest.TestCase):
    """Synthetic archives only: nothing is downloaded and no package code runs."""

    def install(self, *fixtures, stdlib=("encodings/__init__.py",)):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        packages, lock = write_packages(root, *fixtures)
        resources = root / "PythonResources"
        self.library = resources / "python" / "lib" / "python3.15"
        for name in stdlib:
            (self.library / name).parent.mkdir(parents=True, exist_ok=True)
            (self.library / name).write_text("# standard library fixture\n")
        self.resources = resources
        return prepare.install_packages(packages, lock, resources)

    def rejected(self, pattern, *fixtures, **options):
        with self.assertRaisesRegex(prepare.PrepareError, pattern):
            self.install(*fixtures, **options)

    def test_checked_in_lock_pins_only_pure_python_artifacts_with_compatible_licenses(self) -> None:
        packages = prepare.load_packages_lock(prepare.PACKAGES_LOCK)
        self.assertEqual(json.loads(prepare.PACKAGES_LOCK.read_text())["packages"], packages)
        self.assertEqual([package["name"] for package in packages], sorted(package["name"] for package in packages))
        for package in packages:
            with self.subTest(package=package["name"]):
                self.assertIn(package["license"], GPL2_COMPATIBLE_LICENSES)
                self.assertTrue(package["filename"].endswith("-py3-none-any.whl") or package["kind"] == "sdist")
        # The only source distribution: PyYAML publishes no universal wheel; its lib/yaml is pure Python.
        self.assertEqual([package["name"] for package in packages if package["kind"] == "sdist"], ["pyyaml"])
        self.assertIn("certifi", {package["name"] for package in packages})

    def test_wheel_is_unpacked_beside_the_standard_library_with_license_and_manifest(self) -> None:
        data, entry = wheel_fixture(extra={"demo/sub/data.json": "{}"})
        manifest = self.install((data, entry))
        self.assertEqual((self.library / "demo" / "__init__.py").read_text(), "VERSION = '1.2'\n")
        self.assertTrue((self.library / "demo" / "sub" / "data.json").is_file())
        self.assertTrue((self.library / "demo-1.2.dist-info" / "METADATA").is_file())
        self.assertTrue((self.library / "encodings" / "__init__.py").is_file())
        # RECORD describes the whole wheel and .data holds scripts: neither is installed.
        self.assertFalse((self.library / "demo-1.2.dist-info" / "RECORD").exists())
        self.assertFalse(list(self.library.glob("*.data")))
        self.assertEqual((self.resources / "licenses" / "demo-LICENSE").read_text(), "demo license\n")
        self.assertEqual(len(manifest), 1)
        self.assertEqual((manifest[0]["name"], manifest[0]["version"], manifest[0]["sha256"], manifest[0]["modules"]),
                         ("demo", "1.2", entry["sha256"], ["demo"]))
        written = json.loads((self.resources / prepare.PACKAGES_MANIFEST).read_text())
        self.assertEqual(written, {"schema": 1, "library": "python/lib/python3.15", "packages": manifest})
        for name, digest in manifest[0]["files"].items():
            self.assertEqual(hashlib.sha256((self.library / name).read_bytes()).hexdigest(), digest)
        self.assertEqual(set(manifest[0]["files"]), {
            "demo/__init__.py", "demo/sub/data.json", "demo-1.2.dist-info/METADATA", "demo-1.2.dist-info/WHEEL",
            "demo-1.2.dist-info/licenses/LICENSE"})

    def test_single_file_module_and_pinned_dependency(self) -> None:
        data, entry = wheel_fixture("typing_extensions", "4.0", "typing_extensions", extra={"typing_extensions.py": "X = 1\n"})
        files = {name: content for name, content in self.wheel_files(data).items() if not name.startswith("typing_extensions/")}
        single = wheel_bytes(files)
        entry.update(sha256=hashlib.sha256(single).hexdigest())
        user, user_entry = wheel_fixture("user", "1.0", "user", requires=("typing-extensions>=4.0.0", 'lxml; extra == "lxml"'))
        user_entry["requires"] = ["typing-extensions"]
        manifest = self.install((single, entry), (user, user_entry))
        self.assertEqual([package["name"] for package in manifest], ["typing-extensions", "user"])
        self.assertTrue((self.library / "typing_extensions.py").is_file())
        self.assertTrue((self.resources / "licenses" / "typing-extensions-LICENSE").is_file())

    @staticmethod
    def wheel_files(data):
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            return {name: archive.read(name) for name in archive.namelist()}

    def test_source_distribution_contributes_only_its_pinned_module_without_running_setup(self) -> None:
        manifest = self.install(sdist_fixture())
        self.assertEqual((self.library / "srcmod" / "__init__.py").read_text(), "VALUE = 2\n")
        self.assertTrue((self.library / "srcmod" / "data.txt").is_file())
        self.assertFalse((self.library / "other").exists())
        self.assertFalse(list(self.library.rglob("setup.py")))
        self.assertEqual((self.library / "demo_src-2.0.dist-info" / "METADATA").read_text().splitlines()[1], "Name: Demo_Src")
        self.assertEqual((self.library / "demo_src-2.0.dist-info" / "licenses" / "LICENSE").read_text(), "source license\n")
        self.assertEqual((self.resources / "licenses" / "demo-src-LICENSE").read_text(), "source license\n")
        self.assertEqual(manifest[0]["modules"], ["srcmod"])

    def test_source_distribution_link_or_missing_metadata_is_rejected(self) -> None:
        members = {"demo-2.0/PKG-INFO": "Name: demo-src\nVersion: 2.0\n", "demo-2.0/LICENSE": "license\n",
                   "demo-2.0/lib/srcmod/__init__.py": "", "demo-2.0/lib/srcmod/link.py": None}
        self.rejected("unusable source member", sdist_fixture(members))
        del members["demo-2.0/lib/srcmod/link.py"], members["demo-2.0/PKG-INFO"]
        self.rejected("lacks its pinned metadata", sdist_fixture(members))
        self.rejected("not a readable source distribution", (b"not a tarball", sdist_fixture()[1] | {
            "sha256": hashlib.sha256(b"not a tarball").hexdigest()}))

    def test_artifact_must_match_its_pinned_checksum_and_exist(self) -> None:
        data, entry = wheel_fixture()
        self.rejected("checksum mismatch", (data + b"tampered", entry))
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        packages, lock = write_packages(root, (data, entry))
        (packages / entry["filename"]).unlink()
        with self.assertRaisesRegex(prepare.PrepareError, "unavailable"):
            prepare.install_packages(packages, lock, root / "PythonResources")
        with self.assertRaisesRegex(prepare.PrepareError, "unavailable"):
            prepare.install_packages(root / "missing", lock, root / "PythonResources")

    def test_native_code_bytecode_and_links_are_rejected_not_skipped(self) -> None:
        for name, content in (("demo/_speed.so", "x"), ("demo/_speed.cpython-315-darwin.so", "x"),
                              ("demo/__pycache__/x.cpython-315.pyc", "x"), ("demo/lib.dylib", "x"),
                              ("demo/blob.bin", b"\xcf\xfa\xed\xfe" + b"\0" * 8), ("demo/elf", b"\x7fELF\0\0\0\0")):
            with self.subTest(name=name):
                self.rejected("not pure Python", wheel_fixture(extra={name: content}))
        self.rejected("demo contains an entry that is not a regular file", wheel_fixture(mode=0o120777))
        self.rejected("not a readable wheel", (b"PK\x03\x04 broken", wheel_fixture()[1] | {
            "sha256": hashlib.sha256(b"PK\x03\x04 broken").hexdigest()}))

    def test_unsafe_or_unusual_member_names_are_rejected(self) -> None:
        for name in ("../escape.py", "/absolute.py", "demo/../../escape.py", "demo\\evil.py"):
            with self.subTest(name=name):
                self.assertRaisesRegex(prepare.PrepareError, "^(unsafe relative path|backslash is not valid)",
                                       prepare._package_path, name)
                # ZipInfo rewrites backslashes into separators on Windows, so that
                # spelling cannot be represented in this archive fixture there.
                if zipfile.ZipInfo(name).filename != name:
                    continue
                self.rejected("^(unsafe relative path|backslash is not valid)", wheel_fixture(extra={name: "x"}))
        for name in ("demo/has space.py", "demo/.hidden", "demo/semi;colon.py"):
            with self.subTest(name=name):
                self.rejected("unsupported package file name", wheel_fixture(extra={name: "x"}))
        self.rejected("unsupported wheel layout", wheel_fixture(extra={"demo-1.2.data/purelib/hidden.py": "x"}))
        self.rejected("metadata of another distribution", wheel_fixture(extra={"other-9.dist-info/METADATA": "Name: other\n"}))

    def test_wheel_must_declare_itself_pure_and_be_the_pinned_distribution(self) -> None:
        self.rejected("does not declare a pure-Python wheel", wheel_fixture(tag="cp315-cp315-ios_13_0_arm64_iphoneos"))
        self.rejected("does not declare a pure-Python wheel", wheel_fixture(extra={
            "demo-1.2.dist-info/WHEEL": "Wheel-Version: 1.0\nRoot-Is-Purelib: false\nTag: py3-none-any\n"}))
        self.rejected("is not demo 1.2", wheel_fixture(extra={"demo-1.2.dist-info/METADATA": "Name: demo\nVersion: 1.3\n"}))
        self.rejected("is not demo 1.2", wheel_fixture(extra={"demo-1.2.dist-info/METADATA": "Name: other\nVersion: 1.2\n"}))
        data, entry = wheel_fixture()
        files = self.wheel_files(data)
        del files["demo-1.2.dist-info/METADATA"]
        broken = wheel_bytes(files)
        self.rejected("has no demo-1.2.dist-info/METADATA", (broken, entry | {"sha256": hashlib.sha256(broken).hexdigest()}))
        del files["demo-1.2.dist-info/licenses/LICENSE"]
        files["demo-1.2.dist-info/METADATA"] = "Name: demo\nVersion: 1.2\n"
        broken = wheel_bytes(files)
        self.rejected("license file is missing", (broken, entry | {"sha256": hashlib.sha256(broken).hexdigest()}))

    def test_unpinned_runtime_dependency_is_rejected_but_extras_are_not_installed(self) -> None:
        self.rejected("depends on a distribution its lock entry does not list", wheel_fixture(requires=("requests>=2",)))
        self.rejected("depends on a distribution", wheel_fixture(requires=('tzdata; sys_platform == "win32"',)))
        self.install(wheel_fixture(requires=('lxml>=4; extra == "lxml"', 'pytest ; python_version < "4" and extra == "tests"')))
        data, entry = wheel_fixture(requires=("Soup_Sieve>=1.6",))
        self.rejected("requires distributions the lock does not pin", (data, entry | {"requires": ["soup-sieve"]}))

    def test_nothing_may_replace_the_standard_library_or_another_package(self) -> None:
        self.rejected("already present", wheel_fixture(module="json"), stdlib=("json/__init__.py",))
        self.rejected("already present", wheel_fixture(module="json"), stdlib=("json.py",))
        self.rejected("already present", wheel_fixture(module="JSON"), stdlib=("json/__init__.py",))
        self.rejected("would overwrite", wheel_fixture(), stdlib=("demo-1.2.dist-info/METADATA",))
        self.rejected("would overwrite", wheel_fixture(extra={"demo/a.py": "", "demo/A.py": ""}))
        first, second = wheel_fixture(), wheel_fixture("second", "1.0", "demo")
        self.rejected("pins second or one of its modules twice", first, second)
        self.rejected("pins demo or one of its modules twice", first, first)

    def test_installed_top_level_names_are_exactly_the_pinned_modules(self) -> None:
        self.rejected("installs other top-level names", wheel_fixture(extra={"stowaway/__init__.py": ""}))
        self.rejected("installs other top-level names", wheel_fixture(extra={"stowaway.py": ""}))
        data, entry = wheel_fixture()
        self.rejected("does not provide module absent", (data, entry | {"modules": ["demo", "absent"]}))

    def test_package_size_and_count_limits(self) -> None:
        with patch.object(prepare, "MAX_PACKAGE_FILES", 3):
            self.rejected("exceeds the package size limits", wheel_fixture())
        data, entry = wheel_fixture(extra={"demo/big.txt": "x" * 4096})
        with patch.object(prepare, "MAX_PACKAGE_BYTES", 2048):
            self.rejected("within the size limit", (data, entry))
        # A small archive must not expand past the limit either.
        packed = wheel_bytes(self.wheel_files(data) | {"demo/big.txt": b"x" * 400_000}, compression=zipfile.ZIP_DEFLATED)
        self.assertLess(len(packed), 100_000)
        with patch.object(prepare, "MAX_PACKAGE_BYTES", 100_000):
            self.rejected("exceeds the package size limits", (packed, entry | {"sha256": hashlib.sha256(packed).hexdigest()}))

    def test_lock_entries_are_validated_strictly(self) -> None:
        data, entry = wheel_fixture()
        good_url = entry["url"]
        cases = {
            "unexpected fields": [entry | {"install_script": "x"}, {key: value for key, value in entry.items() if key != "license"},
                                   entry | {"kind": "egg"}, entry | {"source_root": "x"}, "demo"],
            "invalid values": [entry | {"modules": "demo"}, entry | {"license": ""}, entry | {"requires": [1]},
                               entry | {"modules": ["demo", "demo"]}],
            "invalid name, version or checksum": [entry | {"name": "Demo"}, entry | {"name": "de_mo"}, entry | {"version": "latest"},
                                                   entry | {"sha256": "abc"}, entry | {"sha256": entry["sha256"].upper()}],
            "files.pythonhosted.org": [entry | {"url": good_url.replace("https://", "http://")},
                                       entry | {"url": good_url.replace("files.pythonhosted.org", "example.org")},
                                       entry | {"url": good_url.replace("demo-1.2", "demo-9.9")},
                                       entry | {"url": good_url + "?x=1"}, entry | {"filename": "../" + entry["filename"]}],
            "py3-none-any wheel": [
                self.renamed(entry, "demo-1.2-cp315-cp315-ios_13_0_arm64_iphoneos.whl"),
                self.renamed(entry, "demo-1.2-py3-abi3-any.whl"), self.renamed(entry, "demo-1.2-py2-none-any.whl"),
                self.renamed(entry, "demo-1.3-py3-none-any.whl"), self.renamed(entry, "other-1.2-py3-none-any.whl"),
                self.renamed(entry, "demo-1.2.tar.gz")],
            "must list the top-level modules": [entry | {"modules": []}, entry | {"modules": ["demo.sub"]},
                                                 entry | {"modules": ["../demo"]}],
            "must pin its license files": [entry | {"license_files": []}],
            "unsafe relative path": [entry | {"license_files": ["../LICENSE"]}],
        }
        for pattern, entries in cases.items():
            for index, broken in enumerate(entries):
                with self.subTest(pattern=pattern, index=index):
                    self.rejected(pattern, (data, broken))
        self.install((data, self.renamed(entry, "demo-1.2-py2.py3-none-any.whl")))
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        lock = Path(temporary.name) / "lock.json"
        for document in ("{}", "[]", '{"schema": 2, "packages": []}', '{"schema": 1, "packages": {}}', "not json",
                         json.dumps({"schema": 1, "packages": [entry] * (prepare.MAX_PACKAGES + 1)})):
            lock.write_text(document)
            with self.subTest(document=document[:40]), self.assertRaises(prepare.PrepareError):
                prepare.load_packages_lock(lock)
        with self.assertRaisesRegex(prepare.PrepareError, "cannot read package lock"):
            prepare.load_packages_lock(Path(temporary.name) / "absent.json")

    @staticmethod
    def renamed(entry, filename):
        return entry | {"filename": filename, "url": entry["url"].rsplit("/", 1)[0] + "/" + filename}

    def test_preparation_requires_the_certificate_roots_the_sdk_uses(self) -> None:
        self.assertEqual(prepare.REQUIRED_PACKAGE_FILES, ("certifi/cacert.pem",))
        source = Path(prepare.__file__).read_text()
        self.assertIn("for required in REQUIRED_PACKAGE_FILES:", source.split("def prepare(", 1)[1])

    def test_repository_rule_downloads_exactly_the_locked_artifacts(self) -> None:
        rule = (_REPO / "third-party" / "ayu-python" / "repository.bzl").read_text()
        self.assertIn('json.decode(ctx.read(packages_lock))["packages"]', rule)
        self.assertIn('sha256 = package["sha256"]', rule)
        self.assertIn('url = package["url"]', rule)
        # Archives are never extracted or executed by the rule; prepare.py reads them as data.
        self.assertEqual(rule.count("ctx.download_and_extract("), 1)
        self.assertNotIn("pip", rule)
        self.assertIn('"packages.lock.json"', (_REPO / "third-party" / "ayu-python" / "BUILD.bazel").read_text())


if __name__ == "__main__":
    unittest.main()
