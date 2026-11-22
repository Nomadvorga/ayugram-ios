"""Synthetic contract tests. No attached/user plugin is read or executed.

On a cool development machine:
  python3 -m unittest discover -s submodules/AyuPluginBridge/Tests/Python -v
"""
from __future__ import annotations

import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

SDK = Path(__file__).resolve().parents[2] / "Python"
sys.path.insert(0, str(SDK))

import ayu_bridge as bridge
from base_plugin import BasePlugin, HookResult, HookStrategy
from java import jarray, jclass, jint, jlong
from ui.settings import Header, Input, Selector, Switch, Text


OPERATIONS = [
    "plugin.activate", "settings.get", "settings.set", "settings.all", "state.get", "state.set",
    "log.write", "hooks.register", "hooks.unregister", "menus.register", "menus.unregister",
    "scheduler.schedule", "scheduler.cancel", "java.member", "java.construct", "java.invoke",
    "java.set_field", "java.length", "java.get_item", "java.set_item", "java.array", "java.cast",
    "java.proxy", "java.get_private_field", "java.set_private_field", "client.call", "ui.present",
]


class FakeHost:
    def __init__(self):
        self.requests = []
        self.settings, self.state, self.active, self.tokens = {}, {}, {}, {}
        self.handles = {}
        self.reject_authorization = False
        self.response_override = None
        self.capabilities = {"operations": list(OPERATIONS),
                             "classes": ["example.Native", "example.Array", "example.Listener", "android.view.View"],
                             "modules": [], "proxy_interfaces": {"example.Listener": ["onClick"]}}

    def dispatch(self, text):
        request = json.loads(text)
        self.requests.append(request)
        if self.response_override is not None:
            return self.response_override(request)
        try:
            result = self.perform(request)
            return json.dumps({"version": 1, "id": request["id"], "result": result})
        except bridge.BridgeError as error:
            return json.dumps({"version": 1, "id": request["id"], "error": {
                "code": error.code, "message": error.message}})

    def perform(self, request):
        owner, op, args = request["plugin_id"], request["operation"], request["arguments"]
        if op == "runtime.capabilities":
            return self.capabilities
        if op == "plugin.authorize":
            if self.reject_authorization:
                raise bridge.BridgeError("LOAD_REJECTED", "Synthetic policy rejection")
            return True
        if op == "plugin.activate":
            self.active[owner] = args["generation"]
            return None
        if op == "plugin.deactivate":
            self.active.pop(owner, None)
            self.tokens = {token: item for token, item in self.tokens.items() if item[0] != owner}
            self.handles = {handle: item for handle, item in self.handles.items() if item[0] != owner}
            self.state.pop(owner, None)
            return None
        if owner not in self.active:
            raise bridge.BridgeError("OWNERSHIP", "No active native generation")
        if op in ("settings.get", "state.get"):
            store = self.settings if op.startswith("settings") else self.state
            return store.get(owner, {}).get(args["key"], args["default"])
        if op in ("settings.set", "state.set"):
            store = self.settings if op.startswith("settings") else self.state
            store.setdefault(owner, {})[args["key"]] = args["value"]
            return None
        if op == "settings.all":
            return self.settings.get(owner, {})
        if op in ("scheduler.schedule", "hooks.register", "menus.register"):
            token = "token-" + str(len(self.requests))
            self.tokens[token] = (owner, args)
            return token
        if op in ("scheduler.cancel", "hooks.unregister", "menus.unregister"):
            record = self.tokens.get(args["token"])
            if record is not None and record[0] != owner:
                raise bridge.BridgeError("OWNERSHIP", "Wrong token owner")
            self.tokens.pop(args["token"], None)
            return None
        if op in ("java.construct", "java.array", "java.proxy"):
            handle = "handle-" + str(len(self.requests))
            class_name = args.get("class_name", "example.Array" if op == "java.array" else "example.Listener")
            self.handles[handle] = (owner, args.get("values", []))
            return {"$handle": handle, "$class": class_name}
        if op == "java.member":
            if args["name"] == "echo":
                return {"kind": "method"}
            if args["name"] == "answer":
                return {"kind": "field", "value": 42}
            raise bridge.UnsupportedAPI("Undeclared member")
        if op == "java.invoke":
            if args["name"] == "echo":
                return args["args"][0]
            raise bridge.UnsupportedAPI("Undeclared method")
        if op in ("java.length", "java.get_item", "java.set_item"):
            handle = args["target"]["$handle"]
            record = self.handles.get(handle)
            if record is None or record[0] != owner:
                raise bridge.BridgeError("OWNERSHIP", "Wrong handle owner")
            if op == "java.length":
                return len(record[1])
            if op == "java.get_item":
                return record[1][args["index"]]
            record[1][args["index"]] = args["value"]
            return None
        if op == "java.cast":
            return args["value"]
        if op == "log.write":
            return None
        raise bridge.UnsupportedAPI("Unimplemented fake host operation")


def source(plugin_id="sample", body="    pass\n", imports=""):
    return (f'__id__ = {plugin_id!r}\n__name__ = "Synthetic Plugin"\n'
            'from base_plugin import BasePlugin\n' + imports + '\nclass Plugin(BasePlugin):\n' + body)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.host = FakeHost()
        self.old_host = sys.modules.get("_ayu_host")
        sys.modules["_ayu_host"] = types.SimpleNamespace(dispatch=self.host.dispatch)
        bridge.runtime.scopes.clear()
        bridge.runtime.capabilities = None
        bridge.runtime.thread_id = None

    def tearDown(self):
        self.host.response_override = None
        for plugin_id in list(bridge.runtime.scopes):
            try:
                bridge.unload_plugin(plugin_id)
            except Exception:
                pass
        if self.old_host is None:
            sys.modules.pop("_ayu_host", None)
        else:
            sys.modules["_ayu_host"] = self.old_host

    def load(self, plugin_id="sample", body="    pass\n", imports=""):
        bridge.load_plugin(source(plugin_id, body, imports), expected_id=plugin_id)
        return bridge.runtime.scopes[plugin_id]

    def test_settings_and_transient_state_are_owned(self):
        left, right = self.load("left"), self.load("right")
        with bridge.runtime.context(left):
            left.instance.set_setting("enabled", True)
            left.instance.set_state("pending", "left")
        with bridge.runtime.context(right):
            self.assertFalse(right.instance.get_setting("enabled", False))
            self.assertIsNone(right.instance.get_state("pending"))
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                left.instance.get_setting("enabled")
        bridge.unload_plugin("left")
        left = self.load("left")
        with bridge.runtime.context(left):
            self.assertTrue(left.instance.get_setting("enabled"))
            self.assertIsNone(left.instance.get_state("pending"))

    def test_aliased_qualified_and_starred_class_inspection_without_execution(self):
        imports = ('from java import jclass as lookup, jint, dynamic_proxy\n'
                   'import java as j\nimport hook_utils as hooks\n'
                   'from hook_utils import find_class as find\n'
                   'lookup("example.A")\nj.jclass(name="example.B")\n'
                   'hooks.find_class("example.C")\nfind("example.D")\n'
                   'lookup(computed_name)\nraise AssertionError("must not execute")\n')
        report = json.loads(bridge.inspect_plugin_json(source(imports=imports)))
        self.assertEqual(report["classes"], ["example.A", "example.B", "example.C", "example.D"])
        self.assertEqual(len(report["dynamic_class_lookup_lines"]), 1)
        self.assertEqual(report["unsupported_sdk_symbols"], {})
        self.assertEqual(self.host.requests, [])
        starred = json.loads(bridge.inspect_plugin_json(source(imports='from java import *\njclass("example.Native")\n')))
        self.assertEqual(starred["classes"], ["example.Native"])

    def test_missing_sdk_import_and_qualified_member_reject_before_execution(self):
        for imports in ('from android_utils import absent_helper as helper\n',
                        'import client_utils as client\nclient.absent_helper()\n'):
            text = source(imports=imports + 'raise AssertionError("must not execute")\n')
            report = json.loads(bridge.inspect_plugin_json(text))
            self.assertTrue(report["unsupported_sdk_symbols"])
            with self.assertRaisesRegex(bridge.BridgeError, "SDK member is not implemented"):
                bridge.load_plugin(text)
            self.assertEqual(self.host.requests, [])

    def test_local_find_class_function_is_not_misreported_as_java_lookup(self):
        report = json.loads(bridge.inspect_plugin_json(source(imports='def find_class(name): return name\nfind_class("local.value")\n')))
        self.assertEqual(report["classes"], [])

    def test_sdk_export_inspection_confined_to_bundled_paths(self):
        from _ayu_inspection import sdk_symbols
        for name in ("../secret", "java/other", "", ".java"):
            with self.assertRaises(ValueError):
                sdk_symbols(name)
        self.assertIn("settings", sdk_symbols("ui"))
        self.assertIn("OnClickListener", sdk_symbols("android_utils"))
        self.assertIn("get_client", sdk_symbols("client_utils"))

    def test_click_listener_is_declared_owned_and_revoked(self):
        from android_utils import OnClickListener
        self.host.capabilities["classes"].append("android.view.View$OnClickListener")
        self.host.capabilities["proxy_interfaces"]["android.view.View$OnClickListener"] = ["onClick"]
        left, right = self.load("left"), self.load("right")
        seen = []
        with bridge.runtime.context(left):
            with self.assertRaises(TypeError):
                OnClickListener(None)
            listener = OnClickListener(lambda view: seen.append(view))
            payload = bridge.runtime.encode(listener)
            request = self.host.requests[-1]
            self.assertEqual(request["arguments"]["interfaces"], ["android.view.View$OnClickListener"])
            callback_id = request["arguments"]["callbacks"]["onClick"]["$callback"]
        event = json.dumps({"version": 1, "plugin_id": "left", "callback_id": callback_id, "arguments": [None]})
        bridge.invoke_callback_json(event)
        self.assertEqual(seen, [None])
        with bridge.runtime.context(right):
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                bridge.runtime.encode(listener)
        self.assertIn("$handle", payload)
        bridge.unload_plugin("left")
        with self.assertRaises(bridge.BridgeError):
            bridge.invoke_callback_json(event)

    def test_static_field_helper_uses_class_target_and_preserves_scope(self):
        from hook_utils import get_static_private_field
        left, right = self.load("left"), self.load("right")
        with bridge.runtime.context(left):
            clazz = jclass("example.Native")
            with patch.object(bridge.runtime, "call", return_value=42) as dispatch:
                self.assertEqual(get_static_private_field(clazz, "answer"), 42)
                operation, arguments = dispatch.call_args.args
                self.assertEqual(operation, "java.get_private_field")
                self.assertEqual(bridge.runtime.encode(arguments["target"]), {"class_name": "example.Native"})
            with self.assertRaises(TypeError):
                get_static_private_field("example.Native", "answer")
        with bridge.runtime.context(right):
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                get_static_private_field(clazz, "answer")

    def test_account_client_forwards_account_without_faking_native_support(self):
        from client_utils import get_client
        left, right = self.load("left"), self.load("right")
        with bridge.runtime.context(left):
            client = get_client(account=2)
            with patch.object(bridge.runtime, "call", return_value=None) as dispatch:
                client.send_message(text="synthetic")
                self.assertEqual(dispatch.call_args.args, ("client.call", {
                    "name": "send_message", "args": [], "kwargs": {"text": "synthetic", "account": 2}}))
            with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                client.get_user_config()
        with bridge.runtime.context(right):
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                client.get_user_config()

    def test_expected_id_rejects_before_host_or_source_execution(self):
        text = source("sample", imports='raise AssertionError("must not execute")\n')
        with self.assertRaisesRegex(bridge.BridgeError, "expected ID"):
            bridge.load_plugin(text, expected_id="other")
        self.assertEqual(self.host.requests, [])

    def test_undeclared_dependency_and_class_reject_before_execution(self):
        for imports in ('import absent_dependency\n', 'from android.view import Missing\n'):
            text = source(imports=imports + 'raise AssertionError("must not execute")\n')
            with self.assertRaisesRegex(bridge.BridgeError, "LOAD_REJECTED"):
                bridge.load_plugin(text)
        self.assertFalse(any(item["operation"] == "plugin.activate" for item in self.host.requests))

    def test_host_authorization_rejects_before_execution(self):
        self.host.reject_authorization = True
        text = source(imports='raise AssertionError("must not execute")\n')
        with self.assertRaisesRegex(bridge.BridgeError, "Synthetic policy rejection"):
            bridge.load_plugin(text)
        self.assertEqual(bridge.runtime.scopes, {})

    def test_threading_is_inspected_and_rejected(self):
        text = source(imports="import threading\n")
        report = json.loads(bridge.inspect_plugin_json(text))
        self.assertIn("threading", report["imports"])
        self.assertTrue(report["warnings"])
        self.assertEqual(self.host.requests, [])
        with self.assertRaisesRegex(bridge.BridgeError, "threads are unsupported"):
            bridge.load_plugin(text)

    def test_inspector_inventory_is_not_support_proof(self):
        report = json.loads(bridge.inspect_plugin_json(source(imports="import subprocess\nimport requests\n")))
        self.assertIn("json", report["python_stdlib_candidates"])
        self.assertIn("base_plugin", report["sdk_modules"])
        self.assertNotIn("requests", report["sdk_modules"])
        self.assertIn("subprocess", report["unsupported_imports"])
        self.assertEqual(self.host.requests, [])
        with self.assertRaisesRegex(bridge.BridgeError, "Launching native processes"):
            bridge.load_plugin(source(imports='import subprocess\nraise AssertionError("must not execute")\n'))

    def test_requests_requires_host_opt_in_before_source_execution(self):
        with self.assertRaisesRegex(bridge.BridgeError, "Undeclared dependency: requests"):
            bridge.load_plugin(source(imports='import requests\nraise AssertionError("must not execute")\n'))
        self.host.capabilities["modules"].append("requests")
        bridge.load_plugin(source(imports="import requests\n"))
        self.assertIn("sample", bridge.runtime.scopes)

    def test_load_failure_deactivates_native_generation(self):
        text = source(body='    def on_plugin_load(self):\n        raise ValueError("synthetic failure")\n')
        with self.assertRaisesRegex(ValueError, "synthetic failure"):
            bridge.load_plugin(text)
        self.assertEqual(bridge.runtime.scopes, {})
        self.assertEqual(self.host.active, {})
        self.assertEqual(self.host.requests[-1]["operation"], "plugin.deactivate")

    def test_metadata_name_does_not_leak_unique_module(self):
        before = set(sys.modules)
        scope = self.load()
        self.assertIn(scope.module_key, sys.modules)
        with bridge.runtime.context(scope):
            self.assertEqual(scope.instance.name, "Synthetic Plugin")
        bridge.unload_plugin("sample")
        self.assertFalse(any(name.startswith("_ayu_plugin_") for name in set(sys.modules) - before))

    def test_dataclass_module_identity_with_duplicate_display_names(self):
        before = set(sys.modules)
        imports = ('from dataclasses import dataclass\n'
                   '@dataclass\nclass Record:\n    value: int\n')
        scopes = []
        for plugin_id in ("left", "right"):
            text = 'from __future__ import annotations\n' + source(plugin_id, imports=imports)
            report = bridge.load_plugin(text, expected_id=plugin_id)
            scope = bridge.runtime.scopes[plugin_id]
            scopes.append(scope)
            self.assertEqual(report["metadata"]["__name__"], "Synthetic Plugin")
            self.assertEqual(scope.module.__name__, scope.module_key)
            self.assertIs(sys.modules[scope.module_key], scope.module)
            self.assertEqual(scope.module.Record.__module__, scope.module_key)
            self.assertEqual(scope.module.Plugin.__module__, scope.module_key)
            self.assertEqual(scope.module.Record(7).value, 7)
        left, right = scopes
        self.assertNotEqual(left.module_key, right.module_key)
        self.assertIsNot(left.module.Record, right.module.Record)
        left_key, right_key = left.module_key, right.module_key
        bridge.unload_plugin("left")
        self.assertNotIn(left_key, sys.modules)
        self.assertIn(right_key, sys.modules)
        self.assertEqual(right.module.Record(9).value, 9)
        bridge.unload_plugin("right")
        self.assertNotIn(right_key, sys.modules)
        self.assertNotIn("Synthetic Plugin", set(sys.modules) - before)

    def test_annotated_display_metadata_preserves_python_module_name(self):
        text = source().replace('__name__ = "Synthetic Plugin"', '__name__: str = "Annotated Display"')
        bridge.load_plugin(text)
        scope = bridge.runtime.scopes["sample"]
        self.assertEqual(scope.module.__name__, scope.module_key)
        self.assertEqual(scope.module.__ayu_display_name__, "Annotated Display")
        with bridge.runtime.context(scope):
            self.assertEqual(scope.instance.name, "Annotated Display")

    def test_response_validation_and_explicit_host_error(self):
        scope = self.load()
        bad_responses = [
            lambda q: '{"version":1,"id":"wrong","result":null}',
            lambda q: json.dumps({"version": 1, "id": q["id"], "result": None, "error": {}}),
            lambda q: '{"version":1,"id":"x","result":NaN}',
            lambda q: '{"version":1,"version":1,"id":"x","result":null}',
        ]
        with bridge.runtime.context(scope):
            for response in bad_responses:
                self.host.response_override = response
                with self.assertRaises(bridge.ProtocolError):
                    scope.instance.get_setting("key")
            self.host.response_override = None
            with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                bridge.runtime.call("ui.present", {"kind": "alert", "config": {}})

    def test_remote_reference_round_trip_member_and_ownership(self):
        left, right = self.load("left"), self.load("right")
        with bridge.runtime.context(left):
            obj = jclass("example.Native")()
            self.assertEqual(obj.answer, 42)
            returned = obj.echo(obj)
            self.assertIsInstance(returned, bridge.RemoteObject)
            self.assertEqual(returned._handle, obj._handle)
            self.assertEqual(self.host.requests[-1]["arguments"]["args"][0]["$handle"], obj._handle)
            with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                obj.notImplemented()
            with self.assertRaises(bridge.ProtocolError):
                bridge.runtime.encode({"$handle": "forged", "$class": "example.Native"})
        with bridge.runtime.context(right):
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                bridge.runtime.encode(obj)
        bridge.unload_plugin("left")
        left2 = self.load("left")
        with bridge.runtime.context(left2):
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                obj.echo(1)

    def test_unsupported_class_fails_without_native_construct(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            with self.assertRaisesRegex(bridge.UnsupportedAPI, "not declared"):
                jclass("android.unimplemented.Unknown")
        self.assertFalse(any(item["operation"] == "java.construct" for item in self.host.requests))

    def test_native_arrays_and_primitive_bounds(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            arr = jarray(jint)([1, 2, 3])
            self.assertEqual(list(arr), [1, 2, 3])
            arr[1] = 7
            self.assertEqual(arr[-2], 7)
            with self.assertRaises(OverflowError):
                jint(2 ** 31)
            self.assertEqual(jlong(2 ** 40), 2 ** 40)

    def test_hook_enums_and_serialization(self):
        self.assertEqual(int(HookStrategy.DEFAULT), 0)
        self.assertEqual(int(HookStrategy.CANCEL), 1)
        self.assertEqual(int(HookStrategy.MODIFY), 2)
        scope = self.load()
        with bridge.runtime.context(scope):
            payload = bridge.runtime.encode(HookResult(HookStrategy.MODIFY, params={"text": "changed"}))
            self.assertEqual(payload["strategy"], 2)
            self.assertEqual(payload["params"], {"text": "changed"})

    def test_callback_one_shot_cancellation_and_unload(self):
        scope = self.load()
        seen = []
        with bridge.runtime.context(scope):
            job = bridge.runtime.schedule(lambda: seen.append("once"))
        callback_id = self.host.tokens[job.token][1]["callback"]["$callback"]
        event = json.dumps({"version": 1, "plugin_id": "sample", "callback_id": callback_id, "arguments": []})
        self.assertEqual(json.loads(bridge.invoke_callback_json(event)), None)
        self.assertEqual(seen, ["once"])
        with self.assertRaisesRegex(bridge.BridgeError, "CALLBACK_EXPIRED"):
            bridge.invoke_callback_json(event)
        with bridge.runtime.context(scope):
            job2 = bridge.runtime.schedule(lambda: seen.append("cancelled"))
            callback2 = self.host.tokens[job2.token][1]["callback"]["$callback"]
            job2.cancel()
        event2 = json.dumps({"version": 1, "plugin_id": "sample", "callback_id": callback2, "arguments": []})
        with self.assertRaisesRegex(bridge.BridgeError, "CALLBACK_EXPIRED"):
            bridge.invoke_callback_json(event2)
        with bridge.runtime.context(scope):
            bridge.runtime.schedule(lambda: seen.append("after unload"))
        bridge.unload_plugin("sample")
        self.assertEqual(self.host.tokens, {})
        self.assertEqual(scope.callbacks, {})
        self.assertEqual(seen, ["once"])

    def test_settings_callbacks_replaced_and_unload_expired(self):
        scope = self.load(body='    def create_settings(self):\n        from ui.settings import Text\n        return [Text(text="Tap", on_click=lambda: self.set_setting("clicked", True))]\n')
        first = json.loads(bridge.serialize_settings("sample"))[0]["on_click"]["$callback"]
        second = json.loads(bridge.serialize_settings("sample"))[0]["on_click"]["$callback"]
        self.assertNotEqual(first, second)
        event = lambda callback_id: json.dumps({"version": 1, "plugin_id": "sample", "callback_id": callback_id, "arguments": []})
        with self.assertRaisesRegex(bridge.BridgeError, "CALLBACK_EXPIRED"):
            bridge.invoke_callback_json(event(first))
        bridge.invoke_callback_json(event(second))
        self.assertTrue(self.host.settings["sample"]["clicked"])
        bridge.unload_plugin("sample")
        with self.assertRaisesRegex(bridge.BridgeError, "CALLBACK_EXPIRED"):
            bridge.invoke_callback_json(event(second))

    def test_cpu_budget_ignores_elapsed_wall_time(self):
        scope = self.load()
        with patch.object(bridge.time, "thread_time", side_effect=[3.0, 3.01]) as cpu, \
                patch.object(bridge.time, "monotonic", side_effect=AssertionError("Wall clock must not drive CPU budget")):
            with bridge.runtime.context(scope), bridge.runtime.budget(scope, "callback"):
                pass  # Synthetic blocked-I/O interval: elapsed wall time is irrelevant.
            self.assertEqual(cpu.call_count, 2)

    def test_cooperative_source_loop_timeout_cleans_up(self):
        previous = bridge.runtime.execution_limits["load"]
        bridge.runtime.execution_limits["load"] = 0.02
        try:
            with self.assertRaisesRegex(bridge.BridgeError, "EXECUTION_TIMEOUT"):
                bridge.load_plugin(source(body='    def on_plugin_load(self):\n        while True:\n            pass\n'))
        finally:
            bridge.runtime.execution_limits["load"] = previous
        self.assertEqual(bridge.runtime.scopes, {})
        self.assertEqual(self.host.active, {})

    def test_component_validation_and_no_cross_plugin_rows(self):
        left, right = self.load("left"), self.load("right")
        with bridge.runtime.context(left):
            rows = [Header("General"), Switch(key="enabled", text="Enabled", default=False),
                    Input(key="key", text="API key", default=""),
                    Selector(key="mode", text="Mode", items=["A", "B"], default=1)]
            self.assertEqual(bridge.runtime.encode(rows)[1]["type"], "Switch")
            with self.assertRaises(TypeError):
                Text(text="Unsupported", made_up_option=True)
        with bridge.runtime.context(right):
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                bridge.runtime.encode(rows)


if __name__ == "__main__":
    unittest.main()
