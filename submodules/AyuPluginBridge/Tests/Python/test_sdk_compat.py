"""Android SDK compatibility tests using only test-authored source and a fake host."""
from __future__ import annotations

import inspect
import json
import unittest
from unittest.mock import patch

import test_bridge as fixtures

import ayu_bridge as bridge
import plugin_settings
from base_plugin import (AppEvent, BaseHook, BasePlugin, HookFilter, HookFilterData, HookResult, HookStrategy,
                         IntentHookType, MenuItemData, MenuItemType, MethodHook,
                         MethodReplacement, PluginError, PluginMetadata, XposedHook, hook_filters)
from ui.settings import Custom, Divider, EditText, Header, Input, Selector, SimpleSettingFactory, Switch, Text


class SDKCompatTests(unittest.TestCase):
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown
    load = fixtures.BridgeTests.load

    def test_android_settings_positional_order_and_attributes(self):
        scope = self.load()
        changed = lambda value: value
        clicked = lambda view: None
        with bridge.runtime.context(scope):
            selector = Selector("mode", "Mode", 1, ["A", "B"], None, changed)
            toggle = Switch("enabled", "Enabled", False, None, None, changed)
            text = Text("Label", "Description", "icon", True, True, clicked)
            self.assertEqual(selector.items, ["A", "B"])
            self.assertIs(selector.on_change, changed)
            self.assertEqual(toggle.default, False)
            self.assertEqual(text.subtext, "Description")
            self.assertIs(text.on_click, clicked)
            self.assertEqual(text.type, "text")
            self.assertTrue(text.to_bridge()["destructive"])
            self.assertNotIn("red", text.to_bridge())
            self.assertEqual(selector.to_bridge()["type"], "Selector")

    def test_optional_row_values_and_input_defaults(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            self.assertEqual(Divider(None).to_bridge(), {"type": "Divider"})
            self.assertEqual(Input("name", "Name").default, "")
            self.assertEqual(Text("Text", subtext=None, icon=None).subtext, None)
            self.assertEqual(Header("Header").text, "Header")

    def test_mutating_android_row_attributes_updates_serialization(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            row = Text("Before")
            row.text = "After"
            row.red = True
            self.assertEqual(row.to_bridge()["text"], "After")
            self.assertTrue(row.to_bridge()["destructive"])
            row.text = None
            with self.assertRaises(TypeError):
                row.to_bridge()

    def test_row_subclass_retains_the_parent_native_type(self):
        scope = self.load()
        class CustomSwitch(Switch):
            pass
        with bridge.runtime.context(scope):
            row = CustomSwitch("enabled", "Enabled", False)
            self.assertEqual(row.type, "switch")
            self.assertEqual(row.to_bridge()["type"], "Switch")

    def test_invalid_row_callbacks_defaults_and_duplicate_arguments(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            for make in (
                lambda: Text("A", text="B"),
                lambda: Switch("enabled", "Enabled", 1),
                lambda: Input("name", "Name", None),
                lambda: Selector("mode", "Mode", 2, ["A"]),
                lambda: Text("Text", on_long_click=True),
                lambda: Switch("é" * 129, "Too long", False),
            ):
                with self.subTest(make=make), self.assertRaises((TypeError, ValueError)):
                    make()

    def test_unsupported_android_custom_rows_fail_explicitly(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            row = EditText("key", "Hint")
            self.assertEqual(row.type, "edit_text")
            with self.assertRaises(bridge.UnsupportedAPI):
                bridge.runtime.encode(row)
            for make in (lambda: Custom(view=object()),
                         lambda: SimpleSettingFactory(lambda: None, lambda: None)):
                with self.assertRaises(bridge.UnsupportedAPI):
                    make()

    def test_android_row_callbacks_replace_and_expire_by_generation(self):
        scope = self.load(body='''    def create_settings(self):
        from ui.settings import Text, Selector
        return [Text("Tap", None, None, False, False,
                     lambda view: self.set_setting("clicked", view)),
                Selector("mode", "Mode", 0, ["A", "B"], None,
                         lambda value: self.set_setting("mode", value))]
''')
        first = json.loads(bridge.serialize_settings("sample"))
        second = json.loads(bridge.serialize_settings("sample"))
        def invoke(callback, arguments):
            return bridge.invoke_callback_json(json.dumps({"version": 1, "plugin_id": "sample",
                "callback_id": callback, "arguments": arguments}))
        with self.assertRaises(bridge.BridgeError):
            invoke(first[0]["on_click"]["$callback"], [None])
        invoke(second[1]["on_change"]["$callback"], [1])
        self.assertEqual(self.host.settings["sample"]["mode"], 1)
        bridge.unload_plugin("sample")
        with self.assertRaises(bridge.BridgeError):
            invoke(second[1]["on_change"]["$callback"], [0])
        self.assertEqual(scope.callbacks, {})

    def test_module_settings_android_scoped_and_keyword_signatures(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            plugin_settings.set_setting("sample", "one", {"value": [1]})
            plugin_settings.set_setting("two", False)
            plugin_settings.set_setting("sample", "three", value="three")
            plugin_settings.set_setting(plugin_id="sample", key="four", value=4)
            self.assertEqual(plugin_settings.get_setting("sample", "one", {}), {"value": [1]})
            self.assertEqual(plugin_settings.get_setting("two", True), False)
            self.assertEqual(plugin_settings.get_setting("sample", "absent", default=12), 12)
            self.assertEqual(plugin_settings.get_setting("sample", key="four", default=0), 4)
            self.assertEqual(plugin_settings.get_all_settings("sample")["three"], "three")

    def test_module_settings_cannot_address_another_plugin(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            before = len(self.host.requests)
            for action in (
                lambda: plugin_settings.get_setting("other", "key", None),
                lambda: plugin_settings.set_setting("other", "key", "secret"),
                lambda: plugin_settings.get_all_settings("other"),
                lambda: plugin_settings.set_all_settings("other", {"key": True}),
                lambda: plugin_settings.clear_settings("other"),
            ):
                with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                    action()
            self.assertEqual(len(self.host.requests), before)

    def test_settings_import_validates_all_before_writing_or_registering_callbacks(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            for values in ({"valid": True, "": False},
                           {"valid": True, "bad": float("nan")},
                           {"valid": True, "bad": lambda: None},
                           {"valid": True, "bad": {"$callback": "forged"}},
                           {"valid": True, "bad": 2 ** 63}):
                before = len(self.host.requests)
                with self.subTest(values=values), self.assertRaises((ValueError, TypeError)):
                    scope.instance.import_settings(values)
                self.assertEqual(len(self.host.requests), before)
                self.assertEqual(scope.callbacks, {})
            self.assertNotIn("sample", self.host.settings)

    def test_import_reload_flag_only_on_final_write(self):
        self.host.capabilities["operations"] = [op for op in self.host.capabilities["operations"]
                                                if op != "settings.replace"]
        scope = self.load()
        with bridge.runtime.context(scope):
            scope.instance.import_settings({"one": 1, "two": 2})
            writes = [request["arguments"] for request in self.host.requests
                      if request["operation"] == "settings.set"]
            self.assertEqual([write["reload_settings"] for write in writes], [False, True])
            scope.instance.import_settings({"one": 3, "two": 4}, reload_settings=False)
            self.assertFalse(self.host.requests[-1]["arguments"]["reload_settings"])

    def test_namespace_replacement_never_silently_merges(self):
        self.host.capabilities["operations"] = [op for op in self.host.capabilities["operations"]
                                                if op != "settings.replace"]
        scope = self.load()
        with bridge.runtime.context(scope):
            plugin_settings.set_all_settings("sample", {"old": True})
            before = len([q for q in self.host.requests if q["operation"] == "settings.set"])
            with self.assertRaises(bridge.UnsupportedAPI):
                plugin_settings.set_all_settings("sample", {"new": True})
            with self.assertRaises(bridge.UnsupportedAPI):
                plugin_settings.clear_settings("sample")
            self.assertEqual(plugin_settings.get_all_settings(), {"old": True})
            self.assertEqual(len([q for q in self.host.requests if q["operation"] == "settings.set"]), before)

    def replacement_host(self, *, reject=False):
        """Install a local fixture; never mutate the shared FakeHost definition."""
        if "settings.replace" not in self.host.capabilities["operations"]:
            self.host.capabilities["operations"].append("settings.replace")
        original_perform = self.host.perform
        def perform(request):
            if request["operation"] != "settings.replace":
                return original_perform(request)
            owner, arguments = request["plugin_id"], request["arguments"]
            if owner not in self.host.active:
                raise bridge.BridgeError("OWNERSHIP", "No active native generation")
            if reject:
                raise bridge.BridgeError("RESOURCE_LIMIT", "Synthetic namespace quota rejection")
            self.host.settings[owner] = arguments["values"]
            return None
        self.host.perform = perform

    def test_atomic_replace_deletes_old_keys_with_one_request_and_reload(self):
        self.replacement_host()
        scope = self.load()
        with bridge.runtime.context(scope):
            scope.instance.set_setting("old", True)
            before = len(self.host.requests)
            scope.instance.import_settings({"new": {"nested": [1, 2]}})
            requests = self.host.requests[before:]
            self.assertEqual(len(requests), 1)
            self.assertEqual(requests[0]["operation"], "settings.replace")
            self.assertEqual(requests[0]["arguments"], {
                "values": {"new": {"nested": [1, 2]}}, "reload_settings": True})
            self.assertEqual(plugin_settings.get_all_settings(), {"new": {"nested": [1, 2]}})

    def test_atomic_replace_failure_preserves_namespace_without_fallback(self):
        self.replacement_host(reject=True)
        scope = self.load()
        with bridge.runtime.context(scope):
            scope.instance.set_setting("old", {"nested": [7]})
            before = len(self.host.requests)
            # Include the old key: a retry through the legacy fallback would
            # otherwise be possible and would violate atomic failure semantics.
            with self.assertRaisesRegex(bridge.BridgeError, "RESOURCE_LIMIT"):
                scope.instance.import_settings({"old": False, "new": True})
            self.assertEqual([q["operation"] for q in self.host.requests[before:]], ["settings.replace"])
            self.assertEqual(plugin_settings.get_all_settings(), {"old": {"nested": [7]}})
            self.assertEqual(scope.callbacks, {})

    def test_atomic_replace_validates_complete_payload_before_host_request(self):
        self.replacement_host()
        scope = self.load()
        with bridge.runtime.context(scope):
            scope.instance.set_setting("old", True)
            for values in ({"first": True, "bad": lambda: None},
                           {"first": True, "$reserved": False},
                           {"first": True, "bad": float("inf")},
                           {"first": True, "": False}):
                before = len(self.host.requests)
                with self.subTest(values=values), self.assertRaises((ValueError, TypeError)):
                    scope.instance.import_settings(values)
                self.assertEqual(len(self.host.requests), before)
                self.assertEqual(self.host.settings["sample"], {"old": True})
                self.assertEqual(scope.callbacks, {})

    def test_atomic_clear_and_empty_import_preserve_other_owner(self):
        self.replacement_host()
        left, right = self.load("left"), self.load("right")
        with bridge.runtime.context(left):
            left.instance.set_setting("private", "left")
        with bridge.runtime.context(right):
            right.instance.set_setting("private", "right")
        with bridge.runtime.context(left):
            plugin_settings.clear_settings("left", reload_settings=True)
            self.assertEqual(self.host.requests[-1]["arguments"], {"values": {}, "reload_settings": True})
            self.assertEqual(plugin_settings.get_all_settings(), {})
            left.instance.set_setting("restored", True)
            left.instance.import_settings({}, reload_settings=False)
            self.assertEqual(self.host.requests[-1]["arguments"], {"values": {}, "reload_settings": False})
            self.assertEqual(plugin_settings.get_all_settings(), {})
        self.assertEqual(self.host.settings["right"], {"private": "right"})

    def test_atomic_clear_failure_preserves_existing_settings(self):
        self.replacement_host(reject=True)
        scope = self.load()
        with bridge.runtime.context(scope):
            scope.instance.set_setting("old", True)
            before = len(self.host.requests)
            with self.assertRaisesRegex(bridge.BridgeError, "RESOURCE_LIMIT"):
                plugin_settings.clear_settings()
            self.assertEqual([q["operation"] for q in self.host.requests[before:]], ["settings.replace"])
            self.assertEqual(self.host.settings["sample"], {"old": True})

    def test_legacy_empty_clear_is_noop_but_cannot_request_reload(self):
        self.host.capabilities["operations"] = [op for op in self.host.capabilities["operations"]
                                                if op != "settings.replace"]
        scope = self.load()
        with bridge.runtime.context(scope):
            plugin_settings.clear_settings()
            self.assertEqual(plugin_settings.get_all_settings(), {})
            before = len(self.host.requests)
            with self.assertRaises(bridge.UnsupportedAPI):
                scope.instance.import_settings({})
            self.assertEqual([q["operation"] for q in self.host.requests[before:]], ["settings.all"])

    def test_settings_values_do_not_alias_persisted_data(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            value = {"nested": [1]}
            plugin_settings.set_setting("sample", "value", value)
            value["nested"].append(2)
            received = plugin_settings.get_setting("sample", "value", None)
            received["nested"].append(3)
            self.assertEqual(plugin_settings.get_setting("sample", "value", None), {"nested": [1]})

    def test_client_is_callable_and_checks_its_owner(self):
        left, right = self.load("left"), self.load("right")
        with bridge.runtime.context(left):
            client = left.instance.client(account=2)
            self.assertEqual(client.account, 2)
        with bridge.runtime.context(right):
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                left.instance.client()

    def test_send_hook_client_and_scheduled_callback_keep_the_hook_account(self):
        scope = self.load(body='''    def on_send_message_hook(self, account, params):
        from client_utils import get_client, get_hook_account, run_on_queue
        self.observed = [account, get_hook_account(), get_client().account, self.client().account]
        run_on_queue(lambda: self.set_setting("delayed_account", self.client().account))
        return HookResult()
''', imports="from base_plugin import HookResult\n")
        with bridge.runtime.context(scope):
            registration = scope.instance.add_on_send_message_hook()
        callback_id = self.host.tokens[registration.token][1]["callback"]["$callback"]
        original_perform = self.host.perform
        selected_requests = []
        def perform(request):
            if request["operation"] == "client.call" and request["arguments"]["name"] == "get_selected_account":
                selected_requests.append(request)
                return 9
            return original_perform(request)
        with patch.object(self.host, "perform", side_effect=perform):
            bridge.invoke_callback_json(json.dumps({"version": 1, "plugin_id": "sample",
                "callback_id": callback_id, "arguments": [2, {"message": "synthetic"}]}))
            self.assertEqual(scope.instance.observed, [2, 2, 2, 2])
            scheduled = next(q for q in reversed(self.host.requests) if q["operation"] == "scheduler.schedule")
            bridge.invoke_callback_json(json.dumps({"version": 1, "plugin_id": "sample",
                "callback_id": scheduled["arguments"]["callback"]["$callback"], "arguments": []}))
            self.assertEqual(self.host.settings["sample"]["delayed_account"], 2)
            self.assertEqual(selected_requests, [])
        from client_utils import get_hook_account
        with bridge.runtime.context(scope):
            self.assertIsNone(get_hook_account())

    def test_request_hook_binds_account_after_request_name(self):
        scope = self.load(body='''    def pre_request_hook(self, request_name, account, request):
        self.observed = [request_name, self.client().account]
        return HookResult()
''', imports="from base_plugin import HookResult\n")
        with bridge.runtime.context(scope):
            registration = scope.instance.add_hook("messages.getHistory")
        callback_id = self.host.tokens[registration.token][1]["pre"]["$callback"]
        bridge.invoke_callback_json(json.dumps({"version": 1, "plugin_id": "sample",
            "callback_id": callback_id, "arguments": ["messages.getHistory", 3, {}]}))
        self.assertEqual(scope.instance.observed, ["messages.getHistory", 3])

    def test_hook_result_android_positional_fields_preserve_all_payloads(self):
        result = HookResult(HookStrategy.MODIFY, "request", "response", "update", "updates", "error", "params")
        self.assertEqual(result.to_bridge(), {"strategy": 2, "request": "request", "response": "response",
            "update": "update", "updates": "updates", "error": "error", "params": "params"})
        self.assertEqual(HookResult("CANCEL").strategy, HookStrategy.CANCEL)

    def test_hook_callback_signatures_include_sdk_names_and_error(self):
        self.assertEqual(list(inspect.signature(BasePlugin.pre_request_hook).parameters),
                         ["self", "request_name", "account", "request"])
        self.assertEqual(list(inspect.signature(BasePlugin.post_request_hook).parameters),
                         ["self", "request_name", "account", "response", "error"])
        self.assertEqual(list(inspect.signature(BasePlugin.on_update_hook).parameters),
                         ["self", "update_name", "account", "update"])
        self.assertEqual(list(inspect.signature(BasePlugin.on_updates_hook).parameters),
                         ["self", "container_name", "account", "updates"])

    def test_request_hook_android_positional_priority_and_name_removal(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            registration = scope.instance.add_hook("messages.", True, 10)
            arguments = self.host.tokens[registration.token][1]
            self.assertEqual(arguments["priority"], 10)
            self.assertTrue(arguments["match_substring"])
            callbacks = set(registration.callback_ids)
            scope.instance.remove_hook("messages.")
            self.assertTrue(registration.closed)
            self.assertFalse(callbacks & set(scope.callbacks))
            self.assertNotIn(registration.token, self.host.tokens)

    def test_keyword_method_hooks_and_replacements(self):
        scope = self.load()
        class Replacement(MethodReplacement):
            def replace_hooked_method(self, param):
                return "replaced"
        with bridge.runtime.context(scope):
            before = lambda param: None
            registration = scope.instance.hook_method("synthetic-method", before=before, priority=12)
            arguments = self.host.tokens[registration.token][1]
            self.assertIn("before", arguments)
            self.assertNotIn("replace", arguments)
            replacement = scope.instance.hook_method("synthetic-method", Replacement())
            self.assertIn("replace", self.host.tokens[replacement.token][1])
            self.assertTrue(issubclass(MethodHook, XposedHook))

    def test_method_filters_are_not_silently_ignored(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            before = len(self.host.requests)
            with self.assertRaises(bridge.UnsupportedAPI):
                scope.instance.hook_method("synthetic", before=lambda param: None,
                                           before_filters=["unimplemented-filter"])
            self.assertEqual(len(self.host.requests), before)
            self.assertEqual(scope.callbacks, {})

    def test_filter_descriptors_and_decorators_preserve_android_data(self):
        data = HookFilter.ArgumentEqual(2, "expected")
        self.assertEqual(data.filter_type, "argument_equal")
        self.assertEqual(data.arg_index, 2)
        self.assertEqual(data.object, "expected")
        combined = HookFilter.Or(HookFilter.RESULT_IS_NULL, data)
        self.assertEqual(combined.filter_type, "or")
        self.assertIsInstance(combined.or_filters[0], HookFilterData)
        self.assertIs(combined.or_filters[1], data)
        scope = self.load()
        class Filtered(MethodHook):
            @hook_filters(HookFilter.RESULT_IS_NULL)
            def after_hooked_method(self, param):
                raise AssertionError("Synthetic filtered callback must not run")
        with bridge.runtime.context(scope):
            before = len(self.host.requests)
            with self.assertRaises(bridge.UnsupportedAPI):
                scope.instance.hook_method("synthetic", Filtered())
            with self.assertRaises(bridge.UnsupportedAPI):
                data.to_java_filter()
            self.assertEqual(len(self.host.requests), before)
            self.assertEqual(scope.callbacks, {})

    def test_unavailable_native_hook_operation_still_fails(self):
        self.host.capabilities["operations"].remove("hooks.register")
        scope = self.load()
        with bridge.runtime.context(scope):
            with self.assertRaises(bridge.UnsupportedAPI):
                scope.instance.hook_method("synthetic", before=lambda param: None)
            self.assertEqual(scope.callbacks, {})

    def test_registered_cleanup_runs_after_unload_override_without_super(self):
        scope = self.load(body='''    def on_plugin_load(self):
        self.order = []
        self.register_cleanup(lambda: self.order.append("first"))
        self.register_cleanup(lambda: self.order.append("second"))
    def on_plugin_unload(self):
        self.order.append("unload")
''')
        plugin = scope.instance
        bridge.unload_plugin("sample")
        self.assertEqual(plugin.order, ["unload", "second", "first"])
        self.assertEqual(plugin._ayu_cleanup, [])

    def test_cleanup_finishes_when_unload_and_one_cleanup_raise(self):
        scope = self.load(body='''    def on_plugin_load(self):
        self.order = []
        self.register_cleanup(lambda: self.order.append("last"))
        self.register_cleanup(self.failing_cleanup)
    def failing_cleanup(self):
        self.order.append("failed")
        raise ValueError("synthetic cleanup failure")
    def on_plugin_unload(self):
        raise RuntimeError("synthetic unload failure")
''')
        plugin = scope.instance
        with self.assertRaises((ValueError, RuntimeError)):
            bridge.unload_plugin("sample")
        self.assertEqual(plugin.order, ["failed", "last"])
        self.assertNotIn("sample", bridge.runtime.scopes)
        self.assertNotIn("sample", self.host.active)

    def test_cleanup_cannot_register_new_work_during_unload(self):
        scope = self.load(body='''    def on_plugin_load(self):
        self.register_cleanup(lambda: self.register_cleanup(lambda: None))
''')
        with self.assertRaisesRegex(bridge.BridgeError, "PLUGIN_UNLOADING"):
            bridge.unload_plugin("sample")
        self.assertEqual(scope.callbacks, {})

    def test_menu_sdk_positional_arguments_and_mutable_attributes(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            item = MenuItemData("main_menu", "Item", lambda context: None, "identifier", "icon", "Detail")
            self.assertEqual(item.menu_type, MenuItemType.MAIN_MENU)
            item.text = "Updated"
            registration = scope.instance.add_menu_item(item)
            arguments = self.host.tokens[registration.token][1]
            self.assertEqual(arguments["text"], "Updated")
            self.assertEqual(arguments["item_id"], "identifier")
            self.assertEqual(arguments["subtext"], "Detail")
            self.assertTrue(scope.instance.remove_menu_item(registration.token))
            self.assertFalse(scope.instance.remove_menu_item(registration.token))

    def test_public_sdk_data_types_and_event_aliases(self):
        metadata = PluginMetadata("id", "Name", "Description", "Author", "1", "icon", "1", [])
        self.assertEqual(metadata.description, "Description")
        self.assertEqual(PluginError("failure", "id").plugin_id, "id")
        self.assertEqual(IntentHookType.BEFORE.value, 0)
        self.assertIs(AppEvent("app_resume"), AppEvent.RESUME)
        hook = BaseHook(before=lambda param: param + 1)
        self.assertEqual(hook.before_hooked_method(2), 3)


if __name__ == "__main__":
    unittest.main()
