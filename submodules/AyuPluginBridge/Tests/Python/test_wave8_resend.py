"""Re-sending the parameters delivered to the send-message hook: a new message when the host described all of it."""
from __future__ import annotations

import ast

from pymembers_fixtures import HostCase
import _ayu_inspection
import _ayu_operations
import ayu_bridge as bridge
import java

IMPORTS = ("from base_plugin import HookResult, HookStrategy\n"
           "from client_utils import run_on_queue, run_on_ui_thread, get_send_messages_helper\n"
           "from org.telegram.messenger import SendMessagesHelper\n")
LOAD = "    def on_plugin_load(self):\n        self.add_on_send_message_hook()\n\n"
DETAIL = "sendMessage(on_send_message_hook params)"
BLOCKER = ("OPERATION", f"sdk.unprovided_member ({DETAIL})")
# The Android pattern: cancel the send, change the delivered object on a queue, send it again.
DEFERRED = LOAD + """    def on_send_message_hook(self, account, params):
        if not isinstance(params.message, str):
            return HookResult()
        run_on_queue(lambda: self._later(account, params, params.message))
        return HookResult(strategy=HookStrategy.CANCEL)

    def _later(self, account, delivered, text):
        helper = get_send_messages_helper()
        delivered.caption = text
        delivered.message = None
        run_on_ui_thread(lambda: helper.sendMessage(delivered))
"""
DIRECT = LOAD + """    def on_send_message_hook(self, account, params):
        again = params
        SendMessagesHelper.getInstance(account).sendMessage(again)
        return HookResult(strategy=HookStrategy.CANCEL)
"""
FRESH = LOAD + """    def on_send_message_hook(self, account, params):
        fresh = SendMessagesHelper.SendMessageParams.of(params.message, params.peer)
        SendMessagesHelper.getInstance(account).sendMessage(fresh)
        return HookResult(strategy=HookStrategy.CANCEL)
"""
ELSEWHERE = LOAD + """    def on_send_message_hook(self, account, params):
        self._note(params.message)
        return HookResult()

    def _note(self, params):
        SendMessagesHelper.getInstance(0).sendMessage(SendMessagesHelper.SendMessageParams.of(params, 1))
"""


def resend(body):
    return _ayu_inspection.send_hook_resend(ast.parse("class Plugin:\n" + body))


class ResendOfHookParametersTests(HostCase):
    def setUp(self):
        super().setUp()
        self.operations("telegram.send_message", "telegram.hooks.send_message")

    def test_the_delivered_object_is_followed_to_sendMessage(self):
        self.assertTrue(resend(DEFERRED))
        self.assertTrue(resend(DIRECT))
        self.assertTrue(resend(DIRECT.replace("sendMessage(again)", "sendMessage(params=again)")))

    def test_a_new_object_or_a_field_value_is_not_a_resend(self):
        self.assertFalse(resend(FRESH))
        self.assertFalse(resend(ELSEWHERE))
        self.assertFalse(resend(LOAD))

    def test_the_requirement_is_the_typed_hook_and_the_send_route(self):
        found = _ayu_operations.requirements((), (), send_hook_resend=True)
        self.assertEqual(found, {DETAIL: [["telegram.hooks.send_message", "telegram.send_message"]]})
        self.assertEqual(_ayu_operations.requirements((), ()), {})

    def test_preflight_passes_the_resend_only_with_both_operations(self):
        for body in (DEFERRED, DIRECT, FRESH, ELSEWHERE):
            with self.subTest(body=body):
                self.assertEqual(self.blockers(IMPORTS, body), [])
        # The three-field fallback hook delivers an object that cannot be sent at all.
        self.operations("hooks.register", remove=("telegram.hooks.send_message",))
        self.assertIn(("OPERATION", f"telegram.hooks.send_message ({DETAIL})"), self.blockers(IMPORTS, DEFERRED))
        self.assertNotIn(DETAIL, " ".join(detail for _, detail in self.blockers(IMPORTS, FRESH)))

    def sent(self):
        """Records what reaches ``telegram.send_message``."""
        calls, perform = [], self.host.perform

        def recording(request):
            if request["operation"] == "telegram.send_message":
                calls.append(request["arguments"])
                return None
            return perform(request)

        self.host.perform = recording
        return calls

    def test_a_completely_described_message_is_sent_again_with_the_plugins_changes(self):
        calls = self.sent()
        scope = self.load(imports=IMPORTS)
        with bridge.runtime.context(scope):
            helper = java.jclass("org.telegram.messenger.SendMessagesHelper")
            delivered = helper.SendMessageParams._ayu_from_wire(
                {"peer": 7, "message": ".wiki cats", "notify": False, "scheduleDate": 90, "complete": True}, 0)
            # Fields the host does not list have their Java defaults, as on Android.
            self.assertIsNone(delivered.webPage)
            self.assertIsNone(delivered.replyMarkup)
            self.assertEqual(delivered.ttl, 0)
            delivered.message = "Wikipedia: Cat"
            helper.getInstance(0).sendMessage(delivered)
            self.assertEqual(calls, [{"account": 0, "params": {"peer": 7, "message": "Wikipedia: Cat", "notify": False,
                                                                "scheduleDate": 90}}])
            # The qrcode shape: the text becomes the caption of a picture.
            delivered.message, delivered.caption, delivered.path = None, "cats", "/tmp/qr.jpg"
            helper.getInstance(0).sendMessage(delivered)
            self.assertEqual(calls[1]["params"], {"peer": 7, "caption": "cats", "path": "/tmp/qr.jpg", "notify": False,
                                                  "scheduleDate": 90})

    def test_a_partly_described_message_is_refused(self):
        calls = self.sent()
        scope = self.load(imports=IMPORTS)
        with bridge.runtime.context(scope):
            helper = java.jclass("org.telegram.messenger.SendMessagesHelper")
            for wire in ({"peer": 7, "message": "text"}, {"peer": 7, "caption": "text", "path": "/tmp/a.jpg", "complete": False}):
                delivered = helper.SendMessageParams._ayu_from_wire(wire, 0)
                with self.assertRaises(bridge.UnsupportedAPI):
                    helper.getInstance(0).sendMessage(delivered)
                with self.assertRaises(bridge.UnsupportedAPI):
                    delivered.webPage
            with self.assertRaises(RuntimeError):
                helper.SendMessageParams._ayu_from_wire({"peer": 7, "message": "text", "complete": 1}, 0)
        self.assertEqual(calls, [])
