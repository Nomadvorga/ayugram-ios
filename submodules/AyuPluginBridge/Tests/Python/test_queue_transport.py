"""Transport bounds and the worker-thread wake, with synthetic plugins and a fake host only."""
from __future__ import annotations

import itertools
import json
from pathlib import Path
import re
import sys
import threading
import types
import unittest

import test_bridge as fixtures
import test_threads_model as model
import _ayu_threads as threads
import ayu_bridge as bridge
from _ayu_javalib import telegram_tl

BRIDGE = Path(__file__).resolve().parents[2]
MIB = 1024 * 1024


def base64_length(size):
    return (size + 2) // 3 * 4


class TransportBoundTests(unittest.TestCase):
    def setUp(self):
        self.host = fixtures.FakeHost()
        self.host.response_override = lambda request: json.dumps({"version": 1, "id": request["id"], "result": None})
        self.old_host = sys.modules.get("_ayu_host")
        sys.modules["_ayu_host"] = types.SimpleNamespace(dispatch=self.host.dispatch)
        bridge.runtime.scopes.clear()
        bridge.runtime.capabilities = None
        bridge.runtime.thread_id = None
        self.old_ids = bridge.runtime.request_ids
        # Four-digit ids for the whole test, so every envelope has the same overhead.
        bridge.runtime.request_ids = itertools.count(1000)

    def tearDown(self):
        bridge.runtime.request_ids = self.old_ids
        bridge.runtime.scopes.clear()
        if self.old_host is None:
            sys.modules.pop("_ayu_host", None)
        else:
            sys.modules["_ayu_host"] = self.old_host

    def sent_bytes(self):
        return len(json.dumps(self.host.requests[-1], separators=(",", ":")))

    def assert_request_bound(self, operation, limit):
        bridge.runtime._dispatch("sample", operation, {"filler": ""})
        overhead = self.sent_bytes()
        bridge.runtime._dispatch("sample", operation, {"filler": "f" * (limit - overhead)})
        self.assertEqual(self.sent_bytes(), limit)
        received = len(self.host.requests)
        with self.assertRaises(bridge.BridgeError) as raised:
            bridge.runtime._dispatch("sample", operation, {"filler": "f" * (limit - overhead + 1)})
        self.assertEqual(raised.exception.code, "RESOURCE_LIMIT")
        self.assertEqual(len(self.host.requests), received, "an oversized request never reaches the host")

    def test_request_envelope_is_bounded_by_operation(self):
        self.assert_request_bound("state.set", 262_144)
        self.assert_request_bound("client.call", 262_144)
        self.assert_request_bound("telegram.request", 1_572_864)
        self.assert_request_bound("telegram.send_message", 1_572_864)

    def test_largest_tl_value_fits_one_request_and_a_larger_one_is_refused_before_dispatch(self):
        function = telegram_tl.TLRPC.TL_messages_getEmojiKeywords()
        function.lang_code = "x" * (MIB - 8)
        wire = function.to_bridge()
        self.assertEqual(len(telegram_tl.encode(function)), telegram_tl.MAX_SEND_BYTES)
        self.assertEqual(len(wire["tl"]), base64_length(MIB))
        bridge.runtime._dispatch("sample", "telegram.request", {
            "account": 0, "request": wire, "flags": 2**31 - 1, "callback": {"$callback": "0" * 32 + ":" + "9" * 20}})
        self.assertLess(self.sent_bytes(), bridge.MAX_TL_REQUEST_BYTES - 65_536, "64 KiB remain for the rest of the call")

        function.lang_code = "x" * (MIB - 4)
        with self.assertRaisesRegex(ValueError, "exceeds the size the host accepts"):
            function.to_bridge()

    def test_json_input_is_bounded_at_six_million_characters(self):
        text = '"' + "a" * (bridge.MAX_JSON_CHARS - 2) + '"'
        self.assertEqual(len(bridge.parse_json(text)), 5_999_998)
        with self.assertRaises(bridge.ProtocolError):
            bridge.parse_json('"' + "a" * (bridge.MAX_JSON_CHARS - 1) + '"')

    def load(self, body):
        self.host.response_override = None
        bridge.load_plugin(fixtures.source("sample", body), expected_id="sample")
        return bridge.runtime.scopes["sample"]

    def callback_event(self, callback_id, arguments):
        return json.dumps({"version": 1, "plugin_id": "sample", "callback_id": callback_id, "arguments": arguments},
                          separators=(",", ":"))

    def test_largest_tl_response_crosses_a_callback_and_a_larger_one_is_a_protocol_error(self):
        scope = self.load('''
    def on_plugin_load(self):
        from ayu_bridge import runtime
        self.got = []
        self.reference = runtime.callback(lambda response, error: self.got.append(response))
''')
        callback_id = scope.instance.reference.callback_id
        request = telegram_tl.TLRPC.TL_help_getNearestDc()
        response = telegram_tl.TLRPC.TL_dataJSON()
        response.data = "/" * (4 * MIB - 8)
        data = telegram_tl.encode(response)
        self.assertEqual(len(data), telegram_tl.MAX_OBJECT_BYTES)
        import base64
        event = self.callback_event(callback_id, [{"tl": base64.b64encode(data).decode("ascii")}, None])
        self.assertLess(len(event), 5_900_000 + 256)
        self.assertLess(len(event), bridge.MAX_JSON_CHARS)
        bridge.invoke_callback_json(event)
        decoded = telegram_tl.response_from_bridge(request, scope.instance.got[0])
        self.assertEqual(len(decoded.data), 4 * MIB - 8)

        with self.assertRaises(bridge.ProtocolError):
            telegram_tl.response_from_bridge(request, {"tl": base64.b64encode(data + b"\0\0\0\0").decode("ascii")})

    def test_callback_result_is_bounded_at_one_mebibyte_of_json(self):
        scope = self.load('''
    def on_plugin_load(self):
        from ayu_bridge import runtime
        self.reference = runtime.callback(lambda size: "r" * size)
''')
        callback_id = scope.instance.reference.callback_id
        result = bridge.invoke_callback_json(self.callback_event(callback_id, [bridge.MAX_RESULT_BYTES - 2]))
        self.assertEqual(len(result), 1_048_576)
        with self.assertRaises(bridge.BridgeError) as raised:
            bridge.invoke_callback_json(self.callback_event(callback_id, [bridge.MAX_RESULT_BYTES - 1]))
        self.assertEqual(raised.exception.code, "RESOURCE_LIMIT")

    def test_released_callback_or_generation_is_an_expired_delivery_not_a_handler_failure(self):
        scope = self.load('''
    def on_plugin_load(self):
        from ayu_bridge import Registration, runtime
        self.ran = []
        self.timer = runtime.callback(lambda: self.ran.append("timer"), once=True)
        self.registration = Registration(runtime, runtime.require(), "schedule", "token", [self.timer.callback_id])
        self.failing = runtime.callback(self.fail)

    def fail(self):
        from ayu_bridge import BridgeError
        raise BridgeError("CALLBACK_EXPIRED", "raised by the handler")
''')
        timer = self.callback_event(scope.instance.timer.callback_id, [])
        failing = self.callback_event(scope.instance.failing.callback_id, [])
        ran = scope.instance.ran
        # The plugin cancels a timer whose delivery is already on its way.
        with bridge.runtime.context(scope):
            scope.instance.registration.cancel()
        self.assertEqual(self.host.requests[-1]["operation"], "scheduler.cancel")
        with self.assertRaises(bridge.DeliveryExpired) as raised:
            bridge.invoke_callback_json(timer)
        self.assertEqual(raised.exception.code, "CALLBACK_EXPIRED")
        self.assertEqual(ran, [], "a cancelled task that has not started never runs")

        # The same code raised by the handler is the handler's failure.
        with self.assertRaises(bridge.BridgeError) as raised:
            bridge.invoke_callback_json(failing)
        self.assertIs(type(raised.exception), bridge.BridgeError)

        with self.assertRaises(bridge.DeliveryExpired) as raised:
            bridge.emit_event_json(json.dumps({"version": 1, "plugin_id": "sample", "generation": "stale", "name": "app", "arguments": ["RESUME"]}))
        self.assertEqual(raised.exception.code, "NOT_LOADED")
        bridge.unload_plugin("sample")
        with self.assertRaises(bridge.DeliveryExpired):
            bridge.invoke_callback_json(failing)

        # The runtime tells exactly this class apart, and the delivery queue does not report it.
        runtime = (BRIDGE / "ObjC/APBPythonRuntime.m").read_text(encoding="utf-8")
        self.assertIn('PyObject_GetAttrString(sdk, "DeliveryExpired")', runtime)
        self.assertIn("if (APBTakeDeliveryExpired()) return APBError(7,", runtime)
        queue = (BRIDGE / "Integration/AyuPluginDeliveryQueue.swift").read_text(encoding="utf-8")
        self.assertIn("static let expiredCode = 7", queue)
        self.assertIn("!AyuPluginDeliveryQueue.isCancelled(error), !AyuPluginDeliveryQueue.isExpired(error) else { return }", queue)

    def test_both_sides_declare_the_same_bounds(self):
        header = (BRIDGE / "ObjC/APBPythonRuntimeQueueBudget.h").read_text(encoding="utf-8")
        limits = (BRIDGE / "Sources/AyuBridgeProtocol.swift").read_text(encoding="utf-8")
        telegram = (BRIDGE / "Integration/AyuPluginTelegramBridge.swift").read_text(encoding="utf-8")
        queue = (BRIDGE / "Integration/AyuPluginDeliveryQueue.swift").read_text(encoding="utf-8")

        def swift(source, name):
            return int(re.search(rf"var {name} = ([0-9_]+)\n", source).group(1).replace("_", ""))

        def macro(name):
            return int(re.search(rf"#define {name} \(\(size_t\)([0-9]+)\)", header).group(1))

        self.assertEqual(swift(limits, "requestBytes"), bridge.MAX_REQUEST_BYTES)
        self.assertEqual(swift(limits, "telegramRequestBytes"), bridge.MAX_TL_REQUEST_BYTES)
        self.assertEqual(macro("APB_DISPATCH_MAXIMUM_REQUEST_UTF8_BYTES"), bridge.MAX_TL_REQUEST_BYTES)
        self.assertEqual(swift(limits, "telegramResponseBytes"), bridge.MAX_RESULT_BYTES)
        self.assertIn("APB_QUEUE_MAXIMUM_RESULT_UTF8_BYTES ((size_t)1024 * 1024)", header)
        self.assertEqual(swift(telegram, "inboundTLBytes"), telegram_tl.MAX_SEND_BYTES)
        self.assertEqual(swift(telegram, "outboundTLBytes"), telegram_tl.MAX_OBJECT_BYTES)
        self.assertEqual(swift(queue, "itemBytes"), bridge.MAX_JSON_CHARS)

        callback = swift(limits, "guaranteedCallbackBytes")
        self.assertEqual(swift(telegram, "hookPayloadBytes"), callback)
        self.assertIn("callbackPayloadBytes = AyuPluginBridgeLimits().guaranteedCallbackBytes", telegram)
        # One outbound value and 256 bytes of envelope fit a callback; one inbound value and 64 KiB a request.
        self.assertLessEqual(base64_length(telegram_tl.MAX_OBJECT_BYTES) + 256, callback)
        self.assertLessEqual(callback + 256, bridge.MAX_JSON_CHARS)
        self.assertLessEqual(base64_length(telegram_tl.MAX_SEND_BYTES) + 65_536, bridge.MAX_TL_REQUEST_BYTES)
        # The largest callback the SDK reads is admitted by an otherwise idle interpreter queue:
        # four bytes per UTF-16 unit and 64 per string, for the function name, the owner and the JSON.
        cost = 256 + 3 * 64 + 4 * (len("invoke_callback_json") + 64 + bridge.MAX_JSON_CHARS)
        self.assertLessEqual(cost, 32 * MIB - (7 * MIB + 512))


WAITING_WORKER = '''
    def on_plugin_load(self):
        self.go = threading.Event()
        self.done = threading.Event()
        threading.Thread(target=self.work, name="synthetic-waiter", daemon=True).start()

    def work(self):
        self.go.wait(10)
        self.set_setting("answer", 42)
        self.done.set()
'''


class WorkerWakeTests(model.ThreadCase):
    def install_wake(self, wake):
        sys.modules["_ayu_host"] = types.SimpleNamespace(dispatch=self.host.dispatch, wake=wake)

    def settings_requests(self):
        return [request for request in self.host.requests if request["operation"] == "settings.set"]

    def test_worker_call_requests_a_native_entry_and_is_served_by_it_without_the_pump(self):
        scope = self.load(WAITING_WORKER)
        wakes, woken = [], threading.Event()

        def wake(plugin_id):
            wakes.append((plugin_id, threading.get_ident()))
            woken.set()
            return True

        self.install_wake(wake)
        scope.instance.go.set()
        self.wait(woken, "the worker's wake")
        self.assertEqual([plugin_id for plugin_id, _ in wakes], ["sample"])
        self.assertNotEqual(wakes[0][1], self.queue, "the wake is called on the worker thread")
        # Nothing ran yet: only the queue can dispatch, and no scheduled pump was delivered.
        self.assertEqual(self.settings_requests(), [])
        self.assertFalse(scope.instance.done.is_set())

        self.assertIs(bridge.service_workers("sample"), True)
        self.wait(scope.instance.done, "the worker")
        self.assertEqual([request["arguments"]["value"] for request in self.settings_requests()], [42])
        self.assertEqual(self.host.dispatch_threads, {self.queue})

    def test_wake_entry_is_queue_only_and_ignores_plugins_that_are_not_active(self):
        self.load(WAITING_WORKER)
        self.assertIs(bridge.service_workers("missing"), False)
        errors = []

        def off_queue():
            try:
                bridge.service_workers("sample")
            except bridge.BridgeError as error:
                errors.append(error.code)

        thread = threading.Thread(target=off_queue)
        thread.start()
        thread.join(model.TIMEOUT)
        self.assertEqual(errors, ["WRONG_QUEUE"])
        scope = bridge.runtime.scopes["sample"]
        scope.instance.go.set()
        self.pump(scope.instance.done.is_set, "the worker")

    def test_refused_or_failing_wake_leaves_the_pump_as_the_fallback(self):
        for wake in (lambda plugin_id: False, lambda plugin_id: (_ for _ in ()).throw(RuntimeError("synthetic"))):
            with self.subTest(wake=wake):
                scope = self.load(WAITING_WORKER)
                self.install_wake(wake)
                scope.instance.go.set()
                self.pump(scope.instance.done.is_set, "the worker")
                self.assertEqual([request["arguments"]["value"] for request in self.settings_requests()][-1], 42)
                bridge.unload_plugin("sample")


if __name__ == "__main__":
    unittest.main()
