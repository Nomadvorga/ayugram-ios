"""SDK callback contracts using authored fixtures and a synthetic native host."""
import inspect
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
import client_utils as client
import test_bridge as harness
from test_client_compat import ClientHost


REQUEST = "org.telegram.tgnet.RequestDelegate"
NOTIFICATION = "org.telegram.messenger.NotificationCenter$NotificationCenterDelegate"
PAYLOAD = "example.NotificationPayload"


class CallbackHost(ClientHost):
    def __init__(self):
        super().__init__()
        self.capabilities["classes"].extend([REQUEST, NOTIFICATION, PAYLOAD])
        self.capabilities["proxy_interfaces"].update({REQUEST: ["run"], NOTIFICATION: ["didReceivedNotification"]})
        self.reject_proxy = False
        self.malformed_proxy = False

    def perform(self, request):
        if request["operation"] == "java.proxy":
            if self.reject_proxy:
                raise bridge.UnsupportedAPI("Synthetic unavailable proxy")
            if self.malformed_proxy:
                return []
            args = request["arguments"]
            interface, = args["interfaces"]
            handle = "callback-proxy-" + str(len(self.requests))
            self.handles[handle] = (request["plugin_id"], args)
            return {"$handle": handle, "$class": interface}
        return super().perform(request)


class ClientCallbackTests(unittest.TestCase):
    load = harness.BridgeTests.load
    tearDown = harness.BridgeTests.tearDown

    def setUp(self):
        harness.BridgeTests.setUp(self)
        self.host = CallbackHost()
        sys.modules["_ayu_host"].dispatch = self.host.dispatch
        self.scope = self.load()

    def export(self, value):
        wire = bridge.runtime.encode(value)
        self.assertIsInstance(wire, dict)
        self.assertEqual(set(wire), {"$handle", "$class"})
        proxy = self.host.handles[wire["$handle"]][1]
        method, = proxy["callbacks"]
        return wire, proxy["callbacks"][method]["$callback"]

    def event(self, callback_id, arguments, owner=None):
        return json.dumps({"version": 1, "plugin_id": owner or self.scope.plugin_id,
                           "callback_id": callback_id, "arguments": arguments})

    def test_android_signatures_and_static_sdk_inspection(self):
        self.assertEqual(list(inspect.signature(client.RequestCallback).parameters), ["fn", "account"])
        self.assertIsNone(inspect.signature(client.RequestCallback).parameters["account"].default)
        self.assertEqual(list(inspect.signature(client.RequestCallback.run).parameters), ["self", "response", "error"])
        self.assertEqual(list(inspect.signature(client.NotificationCenterDelegate).parameters), [])
        self.assertEqual(list(inspect.signature(client.NotificationCenterDelegate.didReceivedNotification).parameters),
                         ["self", "id", "account", "args"])
        report = json.loads(bridge.preflight_plugin_json(harness.source("inspection", imports=(
            "from client_utils import RequestCallback, NotificationCenterDelegate\n"))))
        self.assertEqual(report["blockers"], [])

    def test_request_proxy_native_signature_account_and_once(self):
        seen = []
        account = 2**53 + 123
        with bridge.runtime.context(self.scope), client.account_scope(8):
            callback = client.RequestCallback(lambda response, error: seen.append(
                (response, error, client.get_hook_account(), client.get_client().account)), account)
            self.assertIsInstance(callback, bridge.DynamicProxy)
            wire, callback_id = self.export(callback)
            self.assertEqual(wire["$class"], REQUEST)
            self.assertTrue(callback_id.startswith(self.scope.generation + ":"))
            self.assertEqual(self.export(callback)[0], wire)
            self.assertEqual(client.get_hook_account(), 8)
        event = self.event(callback_id, [{"synthetic": 2**63 - 1}, None])
        self.assertEqual(bridge.invoke_callback_json(event), "null")
        self.assertEqual(seen, [({"synthetic": 2**63 - 1}, None, account, account)])
        self.assertNotIn(callback_id, self.scope.callbacks)
        self.assertFalse(self.scope.callbacks)
        with self.assertRaisesRegex(bridge.BridgeError, "CALLBACK_EXPIRED"):
            bridge.invoke_callback_json(event)

    def test_request_none_account_resets_ambient_account_and_restores_it(self):
        seen = []
        with bridge.runtime.context(self.scope), client.account_scope(9):
            callback = client.RequestCallback(lambda response, error: seen.append(
                (client.get_hook_account(), client.get_client().account)))
            callback.run(None, {"code": 400})
            callback.run("must not run again", None)
            self.assertEqual(client.get_hook_account(), 9)
        self.assertEqual(seen, [(None, self.host.selected_account)])

    def test_request_callbacks_preserve_native_response_and_error(self):
        seen = []
        with bridge.runtime.context(self.scope):
            callback = client.RequestCallback(lambda response, error: seen.append((response, error)))
            _, callback_id = self.export(callback)
        bridge.invoke_callback_json(self.event(callback_id, [
            {"$handle": "response", "$class": PAYLOAD}, {"$handle": "error", "$class": PAYLOAD}]))
        self.assertTrue(all(isinstance(value, bridge.RemoteObject) for value in seen[0]))
        self.assertEqual((seen[0][0]._handle, seen[0][1]._handle), ("response", "error"))
        self.assertTrue(all(value._scope is self.scope for value in seen[0]))

    def test_request_exception_logs_once_and_restores_account(self):
        def failing(response, error):
            self.assertEqual(client.get_hook_account(), 7)
            raise ValueError("synthetic exception details")

        with bridge.runtime.context(self.scope), client.account_scope(9):
            callback = client.RequestCallback(failing, 7)
            callback.run(None, None)
            self.assertEqual(client.get_hook_account(), 9)
            callback.run(None, None)
        logs = [item["arguments"] for item in self.host.requests if item["operation"] == "log.write"]
        self.assertEqual(logs, [{"level": "info", "message": "RequestDelegate callback failed"}])

    def test_request_bridge_failure_is_explicit(self):
        def failing(response, error):
            raise bridge.UnsupportedAPI("Synthetic unavailable request processing")

        with bridge.runtime.context(self.scope):
            callback = client.RequestCallback(failing, 1)
            with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                callback.run(None, None)

    def test_request_managed_cancellation_prevents_user_callback(self):
        seen = []
        with bridge.runtime.context(self.scope):
            callback = client.RequestCallback(lambda response, error: seen.append(response), 7)
            _, callback_id = self.export(callback)
            callback._fn.cancel()
        self.assertEqual(bridge.invoke_callback_json(self.event(callback_id, ["cancelled", None])), "null")
        self.assertFalse(seen)
        self.assertFalse(self.scope.callbacks)

    def test_request_input_and_capabilities_fail_before_callback_registration(self):
        with bridge.runtime.context(self.scope):
            for fn, account, error in ((None, None, TypeError), (lambda *args: None, True, ValueError),
                                        (lambda *args: None, -1, ValueError), (lambda *args: None, 2**63, ValueError)):
                with self.subTest(account=account), self.assertRaises(error):
                    client.RequestCallback(fn, account)
            self.assertFalse(self.scope.callbacks)
            bridge.runtime.capabilities["proxy_interfaces"].pop(REQUEST)
            with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                client.RequestCallback(lambda response, error: None)
            self.assertFalse(self.scope.callbacks)

    def test_request_unknown_interface_never_becomes_a_callback_token(self):
        bridge.runtime.capabilities["classes"].remove(REQUEST)
        with bridge.runtime.context(self.scope), self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
            client.RequestCallback(lambda response, error: None)
        self.assertFalse(self.scope.callbacks)
        self.assertFalse(any(item["operation"] == "java.proxy" for item in self.host.requests))

    def test_interface_signature_mismatch_is_rejected(self):
        with bridge.runtime.context(self.scope):
            bridge.runtime.capabilities["proxy_interfaces"][REQUEST] = ["run", "unsupportedMethod"]
            with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                client.RequestCallback(lambda response, error: None)
            self.assertFalse(self.scope.callbacks)

    def test_notification_subclass_is_repeatable_account_scoped_and_preserves_payload(self):
        seen = []

        class Delegate(client.NotificationCenterDelegate):
            def didReceivedNotification(self, id, account, args):
                seen.append((id, account, args, client.get_client().account))

        with bridge.runtime.context(self.scope):
            delegate = Delegate()
            wire, callback_id = self.export(delegate)
            self.assertEqual(wire["$class"], NOTIFICATION)
        payload = [{"peer": -(2**63)}, 2**63 - 1]
        bridge.invoke_callback_json(self.event(callback_id, [1, 6, payload]))
        bridge.invoke_callback_json(self.event(callback_id, [2, 7, []]))
        self.assertEqual(seen, [(1, 6, payload, 6), (2, 7, [], 7)])
        self.assertIs(type(seen[0][2]), list)
        self.assertIn(callback_id, self.scope.callbacks)
        with bridge.runtime.context(self.scope):
            self.assertIsNone(client.get_hook_account())

    def test_notification_global_account_and_owned_native_array_preserved(self):
        seen = []

        class Delegate(client.NotificationCenterDelegate):
            def didReceivedNotification(self, id, account, args):
                seen.append((account, args, client.get_hook_account(), client.get_client().account))

        with bridge.runtime.context(self.scope):
            _, callback_id = self.export(Delegate())
        bridge.invoke_callback_json(self.event(callback_id, [1, -1, {"$handle": "native-array", "$class": PAYLOAD}]))
        self.assertEqual((seen[0][0], seen[0][2], seen[0][3]), (-1, None, self.host.selected_account))
        self.assertIsInstance(seen[0][1], bridge.RemoteObject)
        self.assertEqual(seen[0][1]._handle, "native-array")

    def test_notification_base_does_not_export_a_noop_handler(self):
        with bridge.runtime.context(self.scope):
            delegate = client.NotificationCenterDelegate()
            with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                bridge.runtime.encode(delegate)
            self.assertFalse(self.scope.callbacks)

    def test_notification_errors_restore_account_and_remain_explicit(self):
        class Delegate(client.NotificationCenterDelegate):
            def didReceivedNotification(self, id, account, args):
                raise bridge.UnsupportedAPI("Synthetic unavailable notification operation")

        with bridge.runtime.context(self.scope), client.account_scope(9):
            delegate = Delegate()
            with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                delegate._dispatch_notification(1, 7, [])
            self.assertEqual(client.get_hook_account(), 9)

    def test_notification_requires_declared_native_interface(self):
        with bridge.runtime.context(self.scope):
            bridge.runtime.capabilities["proxy_interfaces"].pop(NOTIFICATION)
            with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                client.NotificationCenterDelegate()
            self.assertFalse(self.scope.callbacks)

    def test_callback_exports_fail_transactionally_without_fake_native_values(self):
        class Delegate(client.NotificationCenterDelegate):
            def didReceivedNotification(self, id, account, args):
                raise AssertionError("must not be called")

        with bridge.runtime.context(self.scope):
            for malformed in (False, True):
                self.host.reject_proxy = not malformed
                self.host.malformed_proxy = malformed
                delegate = Delegate()
                before = dict(self.scope.callbacks)
                with self.subTest(malformed=malformed), self.assertRaises(bridge.BridgeError):
                    bridge.runtime.encode(delegate)
                self.assertEqual(self.scope.callbacks, before)
                self.assertIsNone(delegate._ayu_native)

    def test_request_failed_export_keeps_only_its_original_binding_and_can_retry(self):
        seen = []
        with bridge.runtime.context(self.scope):
            callback = client.RequestCallback(lambda response, error: seen.append(response), 5)
            before = dict(self.scope.callbacks)
            self.host.reject_proxy = True
            with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                bridge.runtime.encode(callback)
            self.assertEqual(self.scope.callbacks, before)
            self.host.reject_proxy = False
            _, callback_id = self.export(callback)
        bridge.invoke_callback_json(self.event(callback_id, ["retried", None]))
        self.assertEqual(seen, ["retried"])
        self.assertFalse(self.scope.callbacks)

    def test_callback_exports_and_delivery_reject_other_owners_and_reload(self):
        seen = []

        class Delegate(client.NotificationCenterDelegate):
            def didReceivedNotification(self, id, account, args):
                seen.append(args)

        with bridge.runtime.context(self.scope):
            request = client.RequestCallback(lambda response, error: seen.append(response))
            delegate = Delegate()
            _, request_id = self.export(request)
            _, notification_id = self.export(delegate)
        other = self.load("other")
        with bridge.runtime.context(other):
            for value in (request, delegate):
                with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                    bridge.runtime.encode(value)
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                request.run(None, None)
        for callback_id in (request_id, notification_id):
            with self.assertRaisesRegex(bridge.BridgeError, "CALLBACK_EXPIRED"):
                bridge.invoke_callback_json(self.event(callback_id, [], owner=other.plugin_id))
        bridge.unload_plugin(self.scope.plugin_id)
        fresh = self.load()
        for callback_id in (request_id, notification_id):
            with self.assertRaisesRegex(bridge.BridgeError, "CALLBACK_EXPIRED"):
                bridge.invoke_callback_json(self.event(callback_id, []))
        with bridge.runtime.context(fresh):
            for value in (request, delegate):
                with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                    bridge.runtime.encode(value)
        self.assertFalse(seen)


if __name__ == "__main__":
    unittest.main()
