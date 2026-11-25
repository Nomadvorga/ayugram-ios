"""Client SDK contract tests using only a synthetic host and authored fixtures."""
import inspect
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
import client_utils as client
import test_bridge as harness


ACCOUNT_HELPERS = (
    "get_account_instance", "get_messages_controller", "get_contacts_controller",
    "get_media_data_controller", "get_connections_manager", "get_location_controller",
    "get_notifications_controller", "get_messages_storage", "get_send_messages_helper",
    "get_file_loader", "get_secret_chat_helper", "get_download_controller",
    "get_notifications_settings", "get_user_config",
)


class ClientHost(harness.FakeHost):
    """Implements the current native subset; requests/sends opt in per test."""
    def __init__(self):
        super().__init__()
        self.selected_account = 3
        self.client_requests = []
        self.synthetic_messages = False
        self.synthetic_requests = False

    def perform(self, request):
        if request["operation"] != "client.call":
            return super().perform(request)
        if request["plugin_id"] not in self.active:
            raise bridge.BridgeError("OWNERSHIP", "Inactive owner")
        args = request["arguments"]
        self.client_requests.append(args)
        name, positional, keywords = args["name"], args["args"], args["kwargs"]
        if name == "get_selected_account" and not positional and not keywords:
            return self.selected_account
        if name in ("get_user_config", "get_messages_controller") and not positional:
            if set(keywords) != {"account"}:
                raise bridge.ProtocolError("Unexpected account helper arguments")
            return {"account": keywords["account"] if keywords["account"] is not None else self.selected_account}
        if name == "get_notification_center" and not positional and not keywords:
            return {"global": True}
        if name == "send_message" and self.synthetic_messages:
            return args
        if name == "send_request" and self.synthetic_requests:
            return 2**63 - 1
        raise bridge.UnsupportedAPI("Unimplemented synthetic client operation")


class ClientCompatTests(unittest.TestCase):
    load = harness.BridgeTests.load
    tearDown = harness.BridgeTests.tearDown

    def setUp(self):
        harness.BridgeTests.setUp(self)
        self.host = ClientHost()
        sys.modules["_ayu_host"].dispatch = self.host.dispatch
        self.scope = self.load()

    def event(self, callback_id, arguments):
        return json.dumps({"version": 1, "plugin_id": self.scope.plugin_id,
                           "callback_id": callback_id, "arguments": arguments})

    def test_android_send_and_request_signatures(self):
        params = inspect.signature(client.send_message).parameters
        self.assertEqual(list(params), ["params", "parse_mode", "account"])
        self.assertEqual(params["account"].kind, inspect.Parameter.KEYWORD_ONLY)
        params = inspect.signature(client.send_request).parameters
        self.assertEqual(list(params), ["request", "fn", "account"])
        self.assertEqual(params["fn"].default, inspect.Parameter.empty)
        self.assertEqual(params["account"].kind, inspect.Parameter.KEYWORD_ONLY)
        self.assertEqual(list(inspect.signature(client.run_on_queue).parameters), ["fn", "queue_name", "delay"])

    def test_client_resolves_selected_account_once(self):
        with bridge.runtime.context(self.scope):
            account_client = client.get_client()
            self.host.selected_account = 5
            self.assertEqual(account_client.account, 3)
            self.assertEqual(account_client.get_user_config(), {"account": 3})
            self.assertEqual(client.get_user_config(), {"account": 5})
            self.assertEqual(repr(account_client), "AccountClient(account=3)")

    def test_hook_account_nested_scope_and_explicit_precedence(self):
        with bridge.runtime.context(self.scope):
            self.assertIsNone(client.get_hook_account())
            with client.account_scope(7):
                self.assertEqual(client.get_client().account, 7)
                self.assertEqual(client.get_client(8).account, 8)
                self.assertEqual(client.get_user_config(), {"account": 3})
                with self.assertRaisesRegex(RuntimeError, "synthetic"):
                    with client.account_scope(9):
                        self.assertEqual(client.get_hook_account(), 9)
                        raise RuntimeError("synthetic")
                self.assertEqual(client.get_hook_account(), 7)
            self.assertIsNone(client.get_hook_account())

    def test_hook_account_does_not_cross_plugin_context(self):
        other = self.load("other")
        with bridge.runtime.context(self.scope), client.account_scope(7):
            with bridge.runtime.context(other):
                self.assertIsNone(client.get_hook_account())
                self.assertEqual(client.get_client().account, 3)
            self.assertEqual(client.get_hook_account(), 7)

    def test_client_generation_and_owner_checks(self):
        with bridge.runtime.context(self.scope):
            account_client = client.get_client(4)
            self.assertEqual(account_client, client.get_client(4))
            self.assertEqual(hash(account_client), hash(client.get_client(4)))
        other = self.load("other")
        with bridge.runtime.context(other):
            for function in (lambda: account_client.account, account_client.get_user_config,
                             lambda: account_client.send_message({"peer": 9, "message": "test"})):
                with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                    function()
        bridge.unload_plugin(self.scope.plugin_id)
        fresh = self.load()
        with bridge.runtime.context(fresh):
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                account_client.get_user_config()
            self.assertNotEqual(account_client, client.get_client(4))

    def test_account_ids_are_exact_and_never_coerced(self):
        with bridge.runtime.context(self.scope):
            for account in (0, 2**53 + 123, 2**63 - 1):
                self.assertEqual(client.get_client(account).get_user_config(), {"account": account})
            for account in (True, 1.0, "1", -1, 2**63):
                with self.subTest(account=account), self.assertRaises(ValueError):
                    client.get_client(account)
            with self.assertRaises(ValueError):
                client.AccountClient(None)
            with self.assertRaises(AttributeError):
                client.get_client(1).account = 2

    def test_selected_account_response_requires_exact_integer(self):
        with bridge.runtime.context(self.scope):
            for value in (True, "1", 1.0, -1, None):
                self.host.selected_account = value
                with self.subTest(value=value), self.assertRaises(bridge.ProtocolError):
                    client.get_client()

    def test_account_helpers_forward_or_explicitly_fail(self):
        with bridge.runtime.context(self.scope):
            account_client = client.get_client(6)
            for name in ACCOUNT_HELPERS:
                for function in (lambda name=name: getattr(client, name)(6),
                                 lambda name=name: getattr(account_client, name)()):
                    if name in ("get_user_config", "get_messages_controller"):
                        self.assertEqual(function(), {"account": 6})
                    else:
                        with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                            function()
                    self.assertEqual(self.host.client_requests[-1], {"name": name, "args": [], "kwargs": {"account": 6}})

    def test_global_notification_center_uses_existing_native_signature(self):
        with bridge.runtime.context(self.scope):
            self.assertEqual(client.get_notification_center(), {"global": True})
            before = len(self.host.client_requests)
            for function in (lambda: client.get_notification_center(3), client.get_client(3).get_notification_center):
                with self.assertRaises(bridge.UnsupportedAPI):
                    function()
            self.assertEqual(len(self.host.client_requests), before)

    def test_send_preserves_all_fields_and_int64_ids(self):
        self.host.synthetic_messages = True
        params = {"peer": -(2**63), "message": "synthetic", "replyToMsg": 2**63 - 1,
                  "replyToTopMsg": 2**53 + 11, "scheduleDate": 123,
                  "unknown_option": "must reach rejecting native schema"}
        with bridge.runtime.context(self.scope):
            response = client.get_client(2**53 + 17).send_message(params)
            self.assertEqual(response, {"name": "send_message", "args": [params],
                                        "kwargs": {"account": 2**53 + 17}})
            self.assertEqual(params["replyToMsg"], 2**63 - 1)
            client.send_text(2**63 - 1, "text", account=4, notify=False, scheduleDate=7)
            self.assertEqual(self.host.client_requests[-1]["args"], [
                {"peer": 2**63 - 1, "message": "text", "notify": False, "scheduleDate": 7}])

    def test_send_options_fail_without_silent_changes(self):
        with bridge.runtime.context(self.scope):
            with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                client.send_message({"peer": 1, "message": "test"})
            before = len(self.host.client_requests)
            for mode in ("html", "markdown", "", "other"):
                with self.assertRaises(bridge.UnsupportedAPI):
                    client.send_message({"peer": 1, "message": "<b>text</b>"}, mode)
            with self.assertRaises(TypeError):
                client.send_message("not a dictionary")
            with self.assertRaises(TypeError):
                client.get_client(1).send_message(text="not Android API")
            self.assertEqual(len(self.host.client_requests), before)

    def test_media_and_edit_options_explicitly_rejected(self):
        with bridge.runtime.context(self.scope):
            account_client = client.get_client(1)
            before = len(self.host.client_requests)
            for name in ("send_photo", "send_document", "send_video", "send_audio"):
                for function in (getattr(client, name), getattr(account_client, name)):
                    with self.assertRaises(bridge.UnsupportedAPI):
                        function(1, "synthetic-path")
            for options in ({"parse_mode": "html"}, {"file_path": "synthetic"},
                            {"with_spoiler": True}, {"unknown": 1}):
                with self.assertRaises(bridge.UnsupportedAPI):
                    client.edit_message(None, "text", **options)
            self.assertEqual(len(self.host.client_requests), before)

    def test_request_callback_is_once_owned_and_restores_account(self):
        self.host.synthetic_requests = True
        seen = []
        with bridge.runtime.context(self.scope):
            def response(result, error):
                seen.append((result, error, client.get_client().account))
            self.assertEqual(client.get_client(8).send_request({"synthetic": True}, response), 2**63 - 1)
            callback_id = self.host.client_requests[-1]["args"][1]["$callback"]
            self.assertTrue(callback_id.startswith(self.scope.generation + ":"))
            self.assertEqual(self.host.client_requests[-1]["kwargs"], {"account": 8})
            self.assertIsNone(client.get_hook_account())
        event = self.event(callback_id, [{"ok": True}, None])
        bridge.invoke_callback_json(event)
        self.assertEqual(seen, [({"ok": True}, None, 8)])
        with self.assertRaisesRegex(bridge.BridgeError, "CALLBACK_EXPIRED"):
            bridge.invoke_callback_json(event)
        self.assertNotIn(callback_id, self.scope.callbacks)

    def test_request_failure_does_not_leak_callbacks(self):
        with bridge.runtime.context(self.scope):
            before = dict(self.scope.callbacks)
            with self.assertRaisesRegex(bridge.BridgeError, "UNSUPPORTED_API"):
                client.send_request({}, lambda result, error: None, account=1)
            self.assertEqual(self.scope.callbacks, before)
            with self.assertRaises(TypeError):
                client.send_request({}, None, account=1)
            self.assertEqual(self.scope.callbacks, before)

    def test_request_callback_unload_and_wrong_owner(self):
        self.host.synthetic_requests = True
        with bridge.runtime.context(self.scope):
            client.send_request({}, lambda result, error: None, account=1)
            callback_id = self.host.client_requests[-1]["args"][1]["$callback"]
        other = self.load("other")
        event = json.loads(self.event(callback_id, [None, None]))
        event["plugin_id"] = other.plugin_id
        with self.assertRaisesRegex(bridge.BridgeError, "CALLBACK_EXPIRED"):
            bridge.invoke_callback_json(json.dumps(event))
        bridge.unload_plugin(self.scope.plugin_id)
        self.load()
        with self.assertRaisesRegex(bridge.BridgeError, "CALLBACK_EXPIRED"):
            bridge.invoke_callback_json(self.event(callback_id, [None, None]))

    def test_scheduled_callback_captures_hook_account(self):
        seen = []
        with bridge.runtime.context(self.scope), client.account_scope(12):
            client.run_on_queue(lambda: seen.append(client.get_client().account), queue_name=client.STAGE_QUEUE, delay=9)
            scheduled = self.host.requests[-1]["arguments"]
            self.assertEqual(scheduled["queue"], client.STAGE_QUEUE)
            self.assertEqual(scheduled["delay_ms"], 9)
        bridge.invoke_callback_json(self.event(scheduled["callback"]["$callback"], []))
        self.assertEqual(seen, [12])
        with bridge.runtime.context(self.scope):
            self.assertIsNone(client.get_hook_account())


if __name__ == "__main__":
    unittest.main()
