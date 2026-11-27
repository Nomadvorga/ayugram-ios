"""Python semantics of host object references (``str()``, ``==``, hashing) and the single send-message hook.

Synthetic host only; no attached/user plugin is read or executed.
"""
from __future__ import annotations

from pathlib import Path
import sys
import types
import unittest

SDK = Path(__file__).resolve().parents[2] / "Python"
sys.path.insert(0, str(SDK))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import ayu_bridge as bridge
from test_bridge import FakeHost, source


class TextHost(FakeHost):
    """``example.Native`` objects answer ``toString`` with ``text:<first constructor argument>``."""

    def perform(self, request):
        operation, arguments = request["operation"], request["arguments"]
        if operation == "java.construct":
            reference = super().perform(request)
            self.handles[reference["$handle"]] = (request["plugin_id"], arguments["args"])
            return reference
        if operation in ("java.member", "java.invoke") and arguments["name"] in ("toString", "same"):
            target = arguments["target"]
            if arguments["name"] == "toString" and not self.handles[target["$handle"]][1]:
                raise bridge.UnsupportedAPI("example.Native.toString")
            if operation == "java.member":
                return {"kind": "method"}
            return "text:" + self.handles[target["$handle"]][1][0] if arguments["name"] == "toString" else target
        return super().perform(request)


class RemoteObjectSemanticsTests(unittest.TestCase):
    def setUp(self):
        self.host = TextHost()
        self.old_host = sys.modules.get("_ayu_host")
        sys.modules["_ayu_host"] = types.SimpleNamespace(dispatch=self.host.dispatch)
        bridge.runtime.scopes.clear()
        bridge.runtime.capabilities = None
        bridge.runtime.thread_id = None
        bridge.load_plugin(source("sample"), expected_id="sample")
        self.scope = bridge.runtime.scopes["sample"]

    def tearDown(self):
        for plugin_id in list(bridge.runtime.scopes):
            try:
                bridge.unload_plugin(plugin_id)
            except Exception:
                pass
        if self.old_host is None:
            sys.modules.pop("_ayu_host", None)
        else:
            sys.modules["_ayu_host"] = self.old_host

    def construct(self, *arguments):
        with bridge.runtime.context(self.scope):
            return bridge.runtime.jclass("example.Native")(*arguments)

    def test_str_is_the_host_to_string(self):
        value = self.construct("abc")
        with bridge.runtime.context(self.scope):
            self.assertEqual(str(value), "text:abc")
            self.assertEqual(f"{value}|{value!r}", "text:abc|<native example.Native>")

    def test_str_of_a_class_without_to_string_stays_the_repr(self):
        value = self.construct()
        with bridge.runtime.context(self.scope):
            self.assertEqual(str(value), "<native example.Native>")

    def test_str_outside_the_plugin_context_never_raises(self):
        value = self.construct("abc")
        self.assertEqual(str(value), "<native example.Native>")
        bridge.unload_plugin("sample")
        self.assertEqual(str(value), "<native example.Native>")

    def test_references_to_one_host_object_are_equal_and_hash_alike(self):
        first, other = self.construct("a"), self.construct("a")
        with bridge.runtime.context(self.scope):
            again = first.same()
        self.assertIs(again, first)
        self.assertEqual(again, first)
        self.assertEqual(hash(again), hash(first))
        self.assertIn(again, [other, first])
        self.assertEqual({first: "kept"}[again], "kept")
        self.assertNotEqual(first, other)
        self.assertNotEqual(first, "a")
        self.assertIsNotNone(first)

    def test_a_reference_received_again_is_the_same_python_object(self):
        first = self.construct("a")
        with bridge.runtime.context(self.scope):
            self.assertIs(first.same(), first.same())
            self.assertIs({id(first): first}[id(first.same())], first)
        handle = first._handle
        del first
        with bridge.runtime.context(self.scope):
            fresh = bridge.runtime.decode({"$handle": handle, "$class": "example.Native"})
        self.assertEqual(fresh._handle, handle)

    def test_integral_floats_keep_their_type_on_the_wire(self):
        with bridge.runtime.context(self.scope):
            self.assertEqual(bridge.json.dumps(bridge.runtime.encode([2.0, 2, -0.0, 1e16])), "[2.0, 2, -0.0, 1e+16]")
            decoded = bridge.runtime.decode(bridge.parse_json("[2.0, 2, 9007199254740993]"))
        self.assertEqual([type(item) for item in decoded], [float, int, int])
        self.assertEqual(decoded[2], 9007199254740993)

    def test_a_handle_of_another_generation_is_another_object(self):
        first = self.construct("a")
        bridge.unload_plugin("sample")
        bridge.load_plugin(source("sample"), expected_id="sample")
        stale = bridge.RemoteObject(bridge.runtime, bridge.runtime.scopes["sample"], first._handle, first._class_name)
        self.assertNotEqual(first, stale)


class SendHookRegistrationTests(unittest.TestCase):
    setUp = RemoteObjectSemanticsTests.setUp
    tearDown = RemoteObjectSemanticsTests.tearDown

    def hooks(self):
        return [item for item in self.host.tokens.values() if item[1].get("kind") == "send_message"]

    def test_the_send_message_hook_is_registered_once_per_plugin(self):
        plugin = self.scope.instance
        with bridge.runtime.context(self.scope):
            first = plugin.add_on_send_message_hook(priority=3)
            again = plugin.add_on_send_message_hook(priority=9)
            by_name = plugin.add_hook("send_message_hook")
        self.assertIs(again, first)
        self.assertIs(by_name, first)
        self.assertEqual([item[1]["priority"] for item in self.hooks()], [3])

    def test_a_removed_send_message_hook_can_be_registered_again(self):
        plugin = self.scope.instance
        with bridge.runtime.context(self.scope):
            first = plugin.add_on_send_message_hook()
            plugin.remove_hook(first)
            self.assertEqual(self.hooks(), [])
            second = plugin.add_on_send_message_hook(priority=2)
        self.assertIsNot(second, first)
        self.assertEqual([item[1]["priority"] for item in self.hooks()], [2])


if __name__ == "__main__":
    unittest.main()
