"""Offline hash/catalog/source-wiring tests, NOT Swift or device execution.

Only bundled bridge files are read. Supplied reference plugins are never read
or executed by this suite; their hashes/AST inventory are pre-generated data.
"""
import hashlib
import json
from pathlib import Path
import unittest

BRIDGE = Path(__file__).resolve().parents[2]


class CommonBridgeCatalogTests(unittest.TestCase):
    def setUp(self):
        self.catalog = json.loads((BRIDGE / "Resources/CommonBridge/compatibility.json").read_text())

    def test_catalog_pins_19_sources_and_no_unverified_runtime_success(self):
        self.assertEqual(self.catalog["source_commit"], "a4b6bb472fd657e0f659531dae090e12c02a0aaa")
        self.assertEqual(len(self.catalog["plugins"]), 19)
        self.assertEqual(len({item["file"] for item in self.catalog["plugins"]}), 19)
        self.assertEqual(sum(item["lines"] for item in self.catalog["plugins"]), 40950)
        self.assertEqual(self.catalog["plugins_runtime_verified"], [])
        self.assertFalse(self.catalog["device_launch_verified"])
        self.assertFalse(self.catalog["native_tests_executed"])
        for plugin in self.catalog["plugins"]:
            self.assertRegex(plugin["sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(plugin["blob"], r"^[0-9a-f]{40}$")
            self.assertEqual(plugin["python_path"], "blocked")
            if not plugin["native_adapter"]:
                self.assertEqual(plugin["status"], "blocked_not_runtime_compatible")

    def test_snow_is_the_single_exact_source_native_route(self):
        native = [item for item in self.catalog["plugins"] if item["native_adapter"]]
        self.assertEqual(len(native), 1)
        self.assertEqual(native[0]["file"], "atmospheric_snow.plugin")
        self.assertEqual(native[0]["sha256"], "bbda8727d253e02542c1c1f51dca1d39d235e2a310b4ba096e5e6305472a6763")
        self.assertEqual(native[0]["lines"], 4237)

    def test_catalog_sdk_hashes_match_current_sources(self):
        for name, digest in self.catalog["sdk_sha256"].items():
            path = BRIDGE / name
            self.assertTrue(path.resolve().is_relative_to(BRIDGE))
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest, name)

    def test_java_facade_functions_are_not_invented_classes(self):
        forbidden = {"java.jclass", "java.jint", "java.jlong", "java.dynamic_proxy", "java.cast", "java.jarray"}
        for plugin in self.catalog["plugins"]:
            self.assertTrue(set(plugin["java_classes"]).isdisjoint(forbidden))

    def test_swift_source_wires_schema_validation_on_each_state_path(self):
        text = (BRIDGE / "Sources/AyuPluginNativeHost.swift").read_text()
        for anchor in ["validateAdapterState(fields, className: name, owner: owner)",
                       "validateAdapterState(fields, className: remote.className, owner: owner, replacing: target)",
                       "validateAdapterState(fields, className: remote.className, owner: owner, replacing: handle)",
                       "validateAdapterState(fields, className: className, owner: owner)",
                       "try adapter.validateState(fields)", "catch { self.objects = snapshot; throw error }",
                       "Adapter cannot create callback tokens", "validateAdapterResponse(value)"]:
            self.assertIn(anchor, text)
        registry = (BRIDGE / "Sources/AyuBridgeClassRegistry.swift").read_text()
        self.assertIn("!AyuPluginNativeHost.reservedClassNames.contains(adapter.name)", registry)
        self.assertIn("adapter.writableFields.isSubset(of: adapter.readableFields)", registry)
        self.assertIn("Constants cannot contain handles or callbacks", registry)


if __name__ == "__main__":
    unittest.main()
