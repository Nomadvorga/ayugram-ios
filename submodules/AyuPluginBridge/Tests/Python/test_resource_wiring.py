"""Offline source-wiring checks, not Swift execution or device startup tests."""
from pathlib import Path
import unittest

BRIDGE = Path(__file__).resolve().parents[2]
REPO = BRIDGE.parents[1]


class ResourceWiringTests(unittest.TestCase):
    def test_bundles_are_declared_as_runtime_data_not_link_inputs(self):
        build = (BRIDGE / "BUILD.bazel").read_text()
        library = build.split('name = "AyuPluginBridge",', 1)[1].split('visibility =', 1)[0]
        self.assertIn('data = [":AyuPluginSDK", "@ayu_python//:PythonResources"]', library)
        deps = library.split("deps = [", 1)[1]
        self.assertNotIn('":AyuPluginSDK"', deps)
        self.assertNotIn('"@ayu_python//:PythonResources"', deps)

    def test_resource_failure_is_not_cached_as_native_startup(self):
        text = (BRIDGE / "Integration/AyuPluginService.swift").read_text()
        prepare = text.split("private func prepareRuntime()", 1)[1].split("public func importPlugin", 1)[0]
        self.assertLess(prepare.index("Self.resource(.pythonHome)"), prepare.index("let task = Task"))
        self.assertLess(prepare.index("Self.resource(.sdk)"), prepare.index("let task = Task"))
        self.assertIn("self.runtimePreparation = task", prepare)
        self.assertNotIn("self.runtimePreparation = nil", prepare)

    def test_lookup_uses_explicit_owner_roots_and_not_bundle_metadata(self):
        text = (BRIDGE / "Integration/AyuPluginService.swift").read_text()
        self.assertIn("Bundle(for: AyuPluginResourceAnchor.self)", text)
        self.assertIn("Bundle(for: APBPythonRuntime.self)", text)
        self.assertNotIn("Bundle(url:", text)
        locator = (BRIDGE / "Integration/AyuPluginResourceLocator.swift").read_text()
        self.assertIn("candidate.pathComponents.starts(with: bundle.pathComponents)", locator)
        self.assertIn("file.pathComponents.starts(with: candidate.pathComponents)", locator)
        for name in ["encodings/__init__.py", "ayu_bridge.py", "_ayu_inspection.py", "base_plugin.py"]:
            self.assertIn(name, locator)
        self.assertNotIn("Bundle.allBundles", locator)
        self.assertNotIn("contentsOfDirectory", locator)

    def test_atmospheric_still_bypasses_python_preparation(self):
        text = (BRIDGE / "Integration/AyuPluginService.swift").read_text()
        inspect = text.split("private func inspect(_ source:", 1)[1]
        self.assertLess(inspect.index("AyuAtmosphericPluginAdapter.record"), inspect.index("try await self.prepareRuntime()"))
        packager = (REPO / "third-party/ayu-python/prepare.py").read_text()
        self.assertIn("bundle_only = True", packager)

    def test_diagnostics_only_use_numeric_native_codes(self):
        text = (BRIDGE / "Integration/AyuPluginService.swift").read_text()
        diagnostics = text.split("nonisolated static func runtimeFailure", 1)[1].split("private func detach", 1)[0]
        self.assertIn('error.domain == "AyuPluginPython"', diagnostics)
        self.assertNotIn("localizedDescription", diagnostics)
        self.assertNotIn("userInfo", diagnostics)
        self.assertIn(".sdkStartup", diagnostics)
        self.assertIn(".runtimeQueue", diagnostics)


if __name__ == "__main__":
    unittest.main()
