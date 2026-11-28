"""Re-sending the parameters delivered to the send-message hook: refused by the SDK, so reported by preflight."""
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

    def test_the_requirement_is_the_reserved_unprovided_member(self):
        found = _ayu_operations.requirements((), (), send_hook_resend=True)
        self.assertEqual(found, {DETAIL: [["sdk.unprovided_member"]]})
        self.assertEqual(_ayu_operations.requirements((), ()), {})

    def test_preflight_blocks_the_resend_and_only_the_resend(self):
        for body in (DEFERRED, DIRECT):
            with self.subTest(body=body):
                self.assertIn(BLOCKER, self.blockers(IMPORTS, body))
        self.assertEqual(self.blockers(IMPORTS, FRESH), [])
        self.assertEqual(self.blockers(IMPORTS, ELSEWHERE), [])

    def test_the_sdk_refuses_the_resend_the_rule_reports(self):
        scope = self.load(imports=IMPORTS)
        with bridge.runtime.context(scope):
            helper = java.jclass("org.telegram.messenger.SendMessagesHelper")
            delivered = helper.SendMessageParams._ayu_from_wire({"peer": 7, "message": "text"}, 0)
            with self.assertRaises(bridge.UnsupportedAPI):
                helper.getInstance(0).sendMessage(delivered)
