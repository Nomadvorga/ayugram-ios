"""Android settings rows, BasePlugin attributes and lifecycle; synthetic plugins and a fake host only."""
from __future__ import annotations

import dataclasses
import json
import unittest

import test_bridge as fixtures

import ayu_bridge as bridge
import _sdk_version
import _ayu_policy
from base_plugin import PluginsConstants
from extera_utils import lifecycle
from ui import settings as rows
from ui.settings import Custom, Divider, EditText, Header, Input, Selector, Switch, Text


def invoke(plugin_id, callback, arguments=()):
    return bridge.invoke_callback_json(json.dumps({
        "version": 1, "plugin_id": plugin_id, "callback_id": callback, "arguments": list(arguments)}))


class Case(unittest.TestCase):
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown
    load = fixtures.BridgeTests.load


class SettingsRowTests(Case):
    def test_rows_are_the_android_dataclasses(self):
        expected = {
            Switch: ["key", "text", "default", "subtext", "icon", "on_change", "type", "on_long_click", "link_alias"],
            Selector: ["key", "text", "default", "items", "icon", "on_change", "type", "on_long_click", "link_alias"],
            Input: ["key", "text", "default", "subtext", "icon", "on_change", "type", "on_long_click", "link_alias"],
            Text: ["text", "subtext", "icon", "accent", "red", "on_click", "create_sub_fragment", "type",
                   "on_long_click", "link_alias"],
            Header: ["text", "type"], Divider: ["text", "type"],
            EditText: ["key", "hint", "default", "multiline", "max_length", "mask", "on_change", "type"],
            Custom: ["type", "item", "view", "factory", "factory_args", "on_click", "on_long_click",
                     "create_sub_fragment", "link_alias"],
        }
        for row, names in expected.items():
            with self.subTest(row=row.__name__):
                self.assertEqual([item.name for item in dataclasses.fields(row)], names)
        types = {row.__name__: next(item.default for item in dataclasses.fields(row) if item.name == "type")
                 for row in expected}
        self.assertEqual(types, {"Switch": "switch", "Selector": "selector", "Input": "input", "Text": "text",
                                 "Header": "header", "Divider": "divider", "EditText": "edit_text",
                                 "Custom": "custom"})
        self.assertEqual(PluginsConstants.Settings.TYPE_EDIT_TEXT, "edit_text")
        self.assertEqual(PluginsConstants.MenuItemTypes.MESSAGE_CONTEXT_MENU, "message_context_menu")

    def test_rows_compare_like_android_and_reject_unknown_options(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            self.assertEqual(Switch("k", "T", True, on_change=print), Switch("k", "T", True))
            self.assertNotIn("on_change", repr(Switch("k", "T", True, on_change=print)))
            for make in (lambda: Selector("k", "T", 0, ["A"], subtext="no such field"),
                         lambda: Input("k", "T", enabled=False), lambda: Header()):
                with self.subTest(make=make), self.assertRaises(TypeError):
                    make()

    def test_serialized_page_drops_what_android_drops_and_keeps_native_types(self):
        class Duck:
            type, key, text, default = "switch", "duck", 7, "yes"

        class Untyped:
            key, text = "k", "T"

        scope = self.load()
        with bridge.runtime.context(scope):
            page = rows.android_rows([
                Header("General"), Text(None), Switch("a", "A", None), Switch(None, "A", True),
                Selector("s", "S", 0, []), Selector("s", "S", 0, ["A", 1]), Selector("s", "S", True, ("A", "B")),
                Input("i", "I", 5, icon="msg_edit", link_alias="alias"), Divider(), Duck(), Untyped(),
                {"type": "header", "text": "a mapping has no attributes"}])
            self.assertEqual(bridge.runtime.encode(page), [
                {"type": "Header", "text": "General"},
                {"type": "Selector", "key": "s", "text": "S", "default": 1, "items": ["A", "B"]},
                {"type": "Input", "key": "i", "text": "I", "default": "5", "icon": "msg_edit", "link_alias": "alias"},
                {"type": "Divider"},
                {"type": "Switch", "key": "duck", "text": "7", "default": True},
            ])
            self.assertEqual(rows.android_rows(None), [])
            self.assertEqual(rows.android_rows(()), [])
            for invalid in ("rows", {"type": "header"}, 3):
                with self.subTest(invalid=invalid), self.assertRaises(TypeError):
                    rows.android_rows(invalid)
            with self.assertRaises(ValueError):
                rows.android_rows([Header("x")] * 257)

    def test_create_settings_may_return_none_or_a_tuple(self):
        scope = self.load(body='''    def create_settings(self):
        from ui.settings import Header
        return None if self.get_setting("empty", True) else (Header("One"),)
''')
        self.assertEqual(json.loads(bridge.serialize_settings("sample")), [])
        with bridge.runtime.context(scope):
            scope.instance.set_setting("empty", False)
        self.assertEqual(json.loads(bridge.serialize_settings("sample")), [{"type": "Header", "text": "One"}])

    def test_edit_text_uses_the_native_input_row_and_reports_a_multiline_editor(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            wire = bridge.runtime.encode(EditText("note", "Hint", "x", True, on_change=lambda value: None))
            self.assertEqual({name: wire[name] for name in wire if name != "on_change"}, {
                "type": "Input", "key": "note", "text": "Hint", "hint": "Hint", "default": "x",
                "multiline": True, "max_length": 256})
            self.assertIn("$callback", wire["on_change"])
            self.assertNotIn("icon", wire)
            before = dict(scope.callbacks)
            for row in (EditText("note", "Hint", "x", True, 40), EditText("note", "Hint", mask="##")):
                with self.subTest(row=row), self.assertRaises(bridge.UnsupportedAPI):
                    bridge.runtime.encode(row)
            # A row Android drops (no key) is dropped before its options are looked at.
            self.assertEqual(rows.android_rows([EditText(None, "Hint", mask="##")]), [])
            self.assertEqual(scope.callbacks, before)

    def test_long_click_callback_reaches_the_host_and_invokes_the_plugin(self):
        scope = self.load(body='''    def create_settings(self):
        from ui.settings import Switch
        return [Switch("a", "A", False, on_long_click=lambda view: self.set_setting("long", True))]
''')
        row = json.loads(bridge.serialize_settings("sample"))[0]
        invoke("sample", row["on_long_click"]["$callback"], [None])
        self.assertTrue(self.host.settings["sample"]["long"])

    def test_sub_fragment_rows_are_read_like_a_page_and_old_pages_expire(self):
        scope = self.load(body='''    def create_settings(self):
        from ui.settings import Text
        return [Text("More", create_sub_fragment=self.page)]
    def page(self):
        from ui.settings import Header, Switch, Text
        return [Header("Sub"), Switch("x", "X", None), Text("Tap", on_click=lambda view: self.set_setting("tapped", True))]
''')
        root = json.loads(bridge.serialize_settings("sample"))[0]
        opener = root["create_sub_fragment"]["$callback"]
        first = json.loads(invoke("sample", opener))
        self.assertEqual([row["type"] for row in first], ["Header", "Text"])
        invoke("sample", first[1]["on_click"]["$callback"], [None])
        self.assertTrue(self.host.settings["sample"]["tapped"])
        for _ in range(rows.MAX_OPEN_PAGES):
            newest = json.loads(invoke("sample", opener))
        with self.assertRaisesRegex(bridge.BridgeError, "CALLBACK_EXPIRED"):
            invoke("sample", first[1]["on_click"]["$callback"], [None])
        invoke("sample", newest[1]["on_click"]["$callback"], [None])
        # One opener, and one click callback per page that is still open.
        self.assertEqual(len(scope.callbacks), 1 + rows.MAX_OPEN_PAGES)

    def test_custom_rows_keep_android_validation_and_stay_unsupported(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            with self.assertRaisesRegex(ValueError, "item or view or factory"):
                Custom()
            with self.assertRaises(bridge.UnsupportedAPI):
                Custom(view=object())

            class Handmade:
                type, view = "custom", object()

            with self.assertRaises(bridge.UnsupportedAPI):
                rows.android_rows([Handmade()])


class BasePluginTests(Case):
    def test_sdk_version_matches_the_version_policy(self):
        self.assertEqual(_sdk_version.__version__, _ayu_policy.SDK_VERSION)
        self.assertEqual(_sdk_version.version, (1, 4, 6, 5))
        self.assertEqual(_sdk_version.version_str, _sdk_version.__version__)
        self.assertIs(_sdk_version.beta, False)
        self.assertIsNone(_sdk_version.Z.c())
        report = json.loads(bridge.preflight_plugin_json(fixtures.source(
            imports="import _sdk_version\nVERSION = _sdk_version.__version__\n")))
        self.assertEqual(report["blockers"], [])

    def test_metadata_attributes_are_assignable_but_the_id_is_native(self):
        scope = self.load(body='''    def on_plugin_load(self):
        self.name = "Renamed"
        self.enabled = False
        self.id = self.id
''')
        plugin = scope.instance
        with bridge.runtime.context(scope):
            self.assertEqual((plugin.name, plugin.enabled, plugin.id), ("Renamed", False, "sample"))
            self.assertEqual(plugin.version, "1.0")
            self.assertEqual(plugin.requirements, [])
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                plugin.id = "other"

    def test_plugin_that_never_calls_super_init_is_still_usable(self):
        scope = self.load(body='''    def __init__(self):
        self.marker = "own init"
    def on_plugin_load(self):
        self.set_setting("marker", self.marker)
        self.register_cleanup(lambda: None)
''')
        with bridge.runtime.context(scope):
            self.assertEqual((scope.instance.id, scope.instance.get_setting("marker")), ("sample", "own init"))

    def test_logger_is_the_sdk_logger_and_can_be_replaced(self):
        scope = self.load()
        plugin = scope.instance
        with bridge.runtime.context(scope):
            plugin.logger.error("failed %s of %s", 1, 2)
            plugin.logger.exception("no active exception")
            self.assertEqual(plugin.logger.tag, "plugin.sample")
            plugin.log("hello")
            plugin.logger = custom = object()
            self.assertIs(plugin.logger, custom)
        messages = [r["arguments"]["message"] for r in self.host.requests if r["operation"] == "log.write"]
        self.assertTrue(any("failed 1 of 2" in message for message in messages))
        self.assertIn("[sample] hello", messages)

    def test_settings_follow_android_for_empty_keys_and_errors(self):
        scope = self.load()
        plugin = scope.instance
        with bridge.runtime.context(scope):
            before = len(self.host.requests)
            self.assertEqual(plugin.get_setting("", 5), 5)
            self.assertIsNone(plugin.set_setting("", 1))
            plugin.error_message = "broken"
            self.assertEqual(plugin.get_setting("key", 6), 6)
            self.assertEqual(plugin.export_settings(), {})
            self.assertEqual(len(self.host.requests), before)

    def test_file_and_intent_hooks_validate_then_fail_explicitly(self):
        from base_plugin import IntentHookType
        from file_utils import FilesController
        from intents import IntentsManager
        scope = self.load()
        plugin = scope.instance
        with bridge.runtime.context(scope):
            for call in (lambda: plugin.add_file_hook("txt"), lambda: plugin.remove_file_hook("", ""),
                         lambda: plugin.add_intent_hook(None, IntentHookType.BEFORE),
                         lambda: plugin.add_intent_hook(IntentsManager.HandlerInfo(print), 0),
                         lambda: plugin.remove_intent_hook(None)):
                with self.subTest(call=call), self.assertRaises(ValueError):
                    call()
            for call in (lambda: plugin.add_file_hook(FilesController.FileInfo("txt", print)),
                         lambda: plugin.remove_file_hook("txt", "secret"),
                         lambda: plugin.add_intent_hook(IntentsManager.HandlerInfo(print), IntentHookType.AFTER),
                         lambda: plugin.remove_intent_hook("handler")):
                with self.subTest(call=call), self.assertRaises(bridge.UnsupportedAPI):
                    call()


class LifecycleTests(Case):
    def test_scope_is_shared_per_generation_and_exposes_the_stop_event(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            captured = lifecycle.capture_scope()
            self.assertIs(captured, scope.instance._lifecycle)
            self.assertIsInstance(captured, lifecycle.PluginScope)
            self.assertEqual(captured.plugin_id, "sample")
            self.assertIs(captured.stop_event, scope.instance.stop_event)
            self.assertFalse(captured.stop_event.is_set())
        bridge.unload_plugin("sample")
        self.assertTrue(captured.stop_event.is_set())

    def test_binding_does_not_consume_bridge_callbacks(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            bound = [lifecycle.bind(lambda: None) for _ in range(5000)]
            self.assertEqual(scope.callbacks, {})
            self.assertFalse(bound[0].cancelled)

    def test_cleanup_callbacks_run_once_on_cancel_and_tasks_survive_into_cleanup(self):
        scope = self.load()
        order = []
        with bridge.runtime.context(scope):
            plugin_scope = lifecycle.capture_scope()
            handle = plugin_scope.register_cleanup(lambda: order.append("early"))
            handle.cancel()
            handle.cancel()
            self.assertEqual(order, ["early"])

            def cleanup():
                task = lifecycle.bind_task(lambda: order.append("task"))
                order.append(task.cancelled)
                task()
                order.append(lifecycle.bind(lambda: None).cancelled)

            plugin_scope.register_cleanup(cleanup)
            ordinary = lifecycle.bind_task(lambda: order.append("ordinary"))
        bridge.unload_plugin("sample")
        self.assertEqual(order, ["early", False, "task", True])
        self.assertTrue(ordinary.cancelled)
        self.assertIsNone(ordinary())

    def test_cancel_actions_that_fail_do_not_stop_the_others(self):
        scope = self.load()
        order = []
        with bridge.runtime.context(scope):
            first = lifecycle.bind(lambda: None)
            first.set_cancel(lambda: order.append("first"))
            failing = lifecycle.bind(lambda: None)
            failing.set_cancel(lambda: 1 / 0)
            lifecycle.capture_scope().close()
            self.assertEqual(order, ["first"])
            late = lifecycle.bind(lambda: order.append("never"))
            self.assertTrue(late.cancelled)
            late.set_cancel(lambda: order.append("late"))
            self.assertIsNone(late())
        self.assertEqual(order, ["first", "late"])
        self.assertTrue(any(r["operation"] == "log.write" and "ZeroDivisionError" in r["arguments"]["message"]
                            for r in self.host.requests))

    def test_lifecycle_transitions_stay_with_the_calling_plugin(self):
        left, right = self.load("left"), self.load("right")
        with bridge.runtime.context(left):
            with lifecycle.plugin_context("left"):
                pass
            for call in (lambda: lifecycle.stop("right"), lambda: lifecycle.plugin_context("right").__enter__(),
                         lambda: lifecycle.ManagedCallback(print, lifecycle._plugin_scope(right))):
                with self.subTest(call=call), self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                    call()
            for call in (lambda: lifecycle.begin("left"), lifecycle.stop_all):
                with self.subTest(call=call), self.assertRaises(bridge.UnsupportedAPI):
                    call()
            lifecycle.stop("left")
            self.assertTrue(lifecycle.capture_scope().stop_event.is_set())


if __name__ == "__main__":
    unittest.main()
