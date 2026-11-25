"""Offline hash/catalog/source-wiring tests, NOT Swift or device execution.

Only bundled bridge files are read. Supplied reference plugins are never read
or executed by this suite; their hashes/AST inventory are pre-generated data.
"""
import hashlib
import json
from pathlib import Path
import unittest
import runpy

BRIDGE = Path(__file__).resolve().parents[2]


class CommonBridgeCatalogTests(unittest.TestCase):
    def setUp(self):
        self.catalog = json.loads((BRIDGE / "Resources/CommonBridge/compatibility.json").read_text())

    def test_catalog_pins_20_sources_and_no_unverified_runtime_success(self):
        self.assertEqual(self.catalog["source_commit"], "a4b6bb472fd657e0f659531dae090e12c02a0aaa")
        self.assertEqual(len(self.catalog["plugins"]), 20)
        self.assertEqual(len({item["file"] for item in self.catalog["plugins"]}), 20)
        self.assertEqual(sum(item["lines"] for item in self.catalog["plugins"]), 42600)
        self.assertEqual(self.catalog["plugins_runtime_verified"], [])
        self.assertFalse(self.catalog["device_launch_verified"])
        self.assertFalse(self.catalog["native_tests_executed"])
        for plugin in self.catalog["plugins"]:
            self.assertRegex(plugin["sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(plugin["blob"], r"^[0-9a-f]{40}$")
            if plugin["file"] == "group_mentions.plugin":
                self.assertEqual(plugin["python_path"], "source_bridge_device_unverified")
                self.assertIsNone(plugin["native_adapter"])
                self.assertEqual(plugin["status"], "python_bridge_source_device_unverified")
            else:
                self.assertEqual(plugin["python_path"], "blocked")
                if not plugin["native_adapter"]:
                    self.assertEqual(plugin["status"], "blocked_not_runtime_compatible")

    def test_six_exact_source_native_routes_keep_snow_untouched(self):
        native = {item["file"]: item for item in self.catalog["plugins"] if item["native_adapter"]}
        self.assertEqual(set(native), {
            "atmospheric_snow.plugin", "sand_box.plugin", "ball.plugin",
            "screenshot_privacy.plugin", "pull_next_chat.plugin",
            "premium_dialog_cards.plugin",
        })
        snow = native["atmospheric_snow.plugin"]
        self.assertEqual(snow["sha256"], "bbda8727d253e02542c1c1f51dca1d39d235e2a310b4ba096e5e6305472a6763")
        self.assertEqual(snow["lines"], 4237)
        self.assertEqual(snow["native_adapter"], "Integration/AyuAtmosphericPluginAdapter.swift")
        expected = {
            "sand_box.plugin": ("9bd2c5ffa93e6a866212a4e0fd263b6216dc10080bbd55c79f40625e8942f8e5", "Integration/AyuSandBoxAdapter.swift"),
            "ball.plugin": ("89f079f2a055ba851b6efec90a2c57d233b1f7204102363b2a637fa06579ea8f", "Integration/AyuBallAdapter.swift"),
            "screenshot_privacy.plugin": ("ce11a973f667623b84aadd1fc68d50fedf410e605759c251789383641cbef23e", "Integration/AyuScreenshotPrivacyAdapter.swift"),
            "pull_next_chat.plugin": ("69975fd768369d2a46d28dbe87f8c580f772d0f974ce8434fca58f65babed709", "Integration/AyuPullNextChatAdapter.swift"),
            "premium_dialog_cards.plugin": ("0bb3f720881d6921101c17691127ed4833ebcde0a10ac8ee1dd8fecb55ef4180", "Integration/AyuPremiumDialogCardsAdapter.swift"),
        }
        for name, (digest, adapter) in expected.items():
            self.assertEqual(native[name]["sha256"], digest)
            self.assertEqual(native[name]["native_adapter"], adapter)
            self.assertEqual(native[name]["status"], "source_pinned_native_adapter_device_unverified")
            self.assertTrue(native[name]["ios_limitations"])

    def test_group_mentions_is_a_bridge_route_not_native(self):
        plugin = next(item for item in self.catalog["plugins"] if item["file"] == "group_mentions.plugin")
        self.assertEqual(plugin["sha256"], "25ae71486b29481d57cc36eaf40e931522a655227d2870dfc898174b8d96f28e")
        self.assertIsNone(plugin["native_adapter"])
        self.assertEqual(plugin["ios_native_route_kind"], "python_bridge_source")
        self.assertEqual(plugin["python_path"], "source_bridge_device_unverified")
        self.assertIn("Original .plugin source", " ".join(plugin["ios_limitations"]))
        catalog = (BRIDGE / "Integration/AyuNativePluginAdapter.swift").read_text()
        self.assertNotIn('id: "group_mentions"', catalog)

    def test_clipboard_write_is_no_longer_a_missing_sdk_symbol(self):
        for plugin in self.catalog["plugins"]:
            symbols = plugin.get("unsupported_sdk_symbols", {})
            self.assertNotIn("copy_to_clipboard", symbols.get("android_utils", []), plugin["file"])
        fish = next(item for item in self.catalog["plugins"] if item["file"] == "fish_audio_integration.plugin")
        self.assertIn("clipboard_write", fish["partially_wired_features"])

    def test_catalog_sdk_hashes_match_current_sources(self):
        for name, digest in self.catalog["sdk_sha256"].items():
            path = BRIDGE / name
            self.assertTrue(path.resolve().is_relative_to(BRIDGE))
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest, name)

    def test_catalog_hash_inventory_covers_all_bundled_python_and_native_sources(self):
        # The audit script is trusted tooling; it never imports the SDK or plugins.
        audit = runpy.run_path(str(BRIDGE / "Build/audit-plugin-requirements.py"))
        self.assertEqual(set(self.catalog["sdk_sha256"]), set(audit["implementation_hashes"](BRIDGE)))

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
