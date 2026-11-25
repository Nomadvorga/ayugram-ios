"""Synthetic metadata, import limits and explicit TL facade regressions."""
import json
import unittest
from unittest.mock import patch

import test_bridge as fixtures
import ayu_bridge as bridge


class PreflightRegressionTests(unittest.TestCase):
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown
    load = fixtures.BridgeTests.load

    def test_nonmetadata_dunder_is_not_evaluated_during_inspection(self):
        text = fixtures.source("metacheck", imports='__annotations__ = dict()\n')
        report = json.loads(bridge.inspect_plugin_json(text))
        self.assertNotIn("__annotations__", report["metadata"])
        self.assertEqual(report["metadata"]["__id__"], "metacheck")

    def test_source_byte_limit_accepts_large_assets_and_rejects_overflow(self):
        prefix = fixtures.source("largesource")
        source = prefix + "#" + "a" * (4_194_304 - len(prefix.encode("utf-8")) - 1)
        self.assertEqual(len(source.encode("utf-8")), 4_194_304)
        self.assertEqual(json.loads(bridge.inspect_plugin_json(source))["metadata"]["__id__"], "largesource")
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.inspect_plugin_json(source + "a")
        self.assertEqual(caught.exception.code, "LOAD_REJECTED")
        self.assertEqual(self.host.requests, [])

    def test_inventory_failures_become_fixed_load_rejections(self):
        with patch.object(bridge, "import_inventory", side_effect=ValueError("private input must not leak")):
            with self.assertRaises(bridge.BridgeError) as caught:
                bridge.inspect_plugin_json(fixtures.source("limits"))
        self.assertEqual(caught.exception.code, "LOAD_REJECTED")
        self.assertNotIn("private", caught.exception.message)
        self.assertEqual(self.host.requests, [])

    def test_optional_imports_keep_unsupported_member_blockers(self):
        text = fixtures.source("optional", imports=(
            'try:\n    from ui.settings import ImaginaryWidget\n'
            'except ImportError:\n    ImaginaryWidget = None\n'))
        report = json.loads(bridge.preflight_plugin_json(text))
        self.assertTrue(report["optional_imports"])
        self.assertIn({"code": "SDK_MEMBER", "detail": "ui.settings.ImaginaryWidget"}, report["blockers"])

    def test_nested_sdk_module_typo_is_rejected_before_authorization(self):
        text = fixtures.source("badmodule", imports='import extera_utils.not_bundled\n')
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.load_plugin(text)
        self.assertEqual(caught.exception.code, "LOAD_REJECTED")
        self.assertFalse(any(r["operation"] == "plugin.authorize" for r in self.host.requests))

    def test_tl_namespace_never_fabricates_unregistered_constructors(self):
        from tlrpc import TLRPC
        scope = self.load("tlcheck")
        with bridge.runtime.context(scope):
            with self.assertRaises(bridge.UnsupportedAPI):
                TLRPC.TL_messages_deleteHistory()
            with self.assertRaises(bridge.UnsupportedAPI):
                TLRPC.TL["TL_not_a_registered_type"]()

    def test_declared_tl_constructor_returns_an_owned_reference(self):
        from tlrpc import TLRPC
        self.host.capabilities["classes"].append("org.telegram.tgnet.TLRPC$TL_peerUser")
        scope = self.load("tlowned")
        with bridge.runtime.context(scope):
            result = TLRPC.TL["TL_peerUser"]()
            self.assertIsInstance(result, bridge.RemoteObject)
            self.assertEqual(result._class_name, "org.telegram.tgnet.TLRPC$TL_peerUser")


if __name__ == "__main__":
    unittest.main()
