"""Regression tests for portable SDK call shapes, using synthetic host data only."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


SDK = Path(__file__).resolve().parents[2] / "Python"
sys.path.insert(0, str(SDK))

import ayu_bridge as bridge
import hook_utils
from base_plugin import MethodHook as BaseMethodHook
from log_utils import _split_for_logcat
import test_bridge as fixtures


class PortableExpansionTests(unittest.TestCase):
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown
    load = fixtures.BridgeTests.load

    def test_hook_utils_exports_the_existing_method_hook_contract(self):
        self.assertIs(hook_utils.MethodHook, BaseMethodHook)

        class SyntheticHook(hook_utils.MethodHook):
            def before_hooked_method(self, param):
                return ("before", param)

            def after_hooked_method(self, param):
                return ("after", param)

        hook, param = SyntheticHook(), object()
        self.assertEqual(hook.before_hooked_method(param), ("before", param))
        self.assertEqual(hook.after_hooked_method(param), ("after", param))

    def test_set_field_forwards_to_an_explicit_writable_field_adapter(self):
        scope = self.load()
        writes = []

        def perform(request):
            if request["operation"] == "java.set_private_field":
                writes.append(request["arguments"])
                return None
            return self.host.perform(request)

        with bridge.runtime.context(scope):
            target = hook_utils.find_class("example.Native")()
            with patch.object(self.host, "perform", side_effect=perform):
                self.assertTrue(hook_utils.set_field(target, "declaredValue", 17))

        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0]["target"]["$class"], "example.Native")
        self.assertEqual((writes[0]["name"], writes[0]["value"]), ("declaredValue", 17))

    def test_set_field_does_not_hide_native_adapter_rejections(self):
        scope = self.load()

        def perform(request):
            if request["operation"] == "java.set_private_field":
                raise bridge.UnsupportedAPI("Synthetic field is read-only")
            return self.host.perform(request)

        with bridge.runtime.context(scope):
            target = hook_utils.find_class("example.Native")()
            with patch.object(self.host, "perform", side_effect=perform):
                with self.assertRaises(bridge.BridgeError) as caught:
                    hook_utils.set_field(target, "readOnlyValue", 17)
        self.assertEqual(caught.exception.code, "UNSUPPORTED_API")

    def test_get_field_reads_only_an_explicit_host_field(self):
        scope = self.load()
        reads = []

        def perform(request):
            if request["operation"] == "java.get_private_field":
                reads.append(request["arguments"])
                return "synthetic value"
            return self.host.perform(request)

        with bridge.runtime.context(scope):
            target = hook_utils.find_class("example.Native")()
            with patch.object(self.host, "perform", side_effect=perform):
                self.assertEqual(hook_utils.get_field(target, "currentMessageObject"), "synthetic value")
        self.assertEqual(len(reads), 1)
        self.assertEqual(reads[0]["target"]["$class"], "example.Native")
        self.assertEqual(reads[0]["name"], "currentMessageObject")

    def test_log_chunks_respect_utf8_boundaries_at_small_limits(self):
        text = "A😀e\u0301B"
        for limit in (4, 5, 7):
            with self.subTest(limit=limit):
                chunks = _split_for_logcat(text, limit)
                self.assertEqual("".join(chunks), text)
                self.assertTrue(all(len(chunk.encode("utf-8")) <= limit for chunk in chunks))


if __name__ == "__main__":
    unittest.main()
