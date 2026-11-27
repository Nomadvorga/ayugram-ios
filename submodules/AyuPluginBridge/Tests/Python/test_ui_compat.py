"""Basic UI contracts use only synthetic source and an injected fake host."""
import json
import sys
import unittest

import test_bridge as fixtures
import ayu_bridge as bridge
from ui.alert import AlertDialogBuilder
from ui.bulletin import BulletinHelper


class PresentationHost(fixtures.FakeHost):
    def __init__(self):
        super().__init__()
        self.capabilities["classes"].append("org.telegram.ui.ActionBar.AlertDialog")

    def perform(self, request):
        if request["operation"] == "ui.present":
            if request["arguments"]["kind"] == "bulletin":
                return None
            handle = "dialog-" + str(len(self.requests))
            self.handles[handle] = (request["plugin_id"], [])
            return {"$handle": handle, "$class": "org.telegram.ui.ActionBar.AlertDialog"}
        if request["operation"] == "java.member" and request["arguments"]["name"] in ("dismiss", "isShowing"):
            return {"kind": "method"}
        if request["operation"] == "java.invoke" and request["arguments"]["name"] == "dismiss":
            return None
        if request["operation"] == "java.invoke" and request["arguments"]["name"] == "isShowing":
            return True
        return super().perform(request)


class UICompatibilityTests(unittest.TestCase):
    tearDown = fixtures.BridgeTests.tearDown
    load = fixtures.BridgeTests.load

    def setUp(self):
        fixtures.BridgeTests.setUp(self)
        self.host = PresentationHost()
        sys.modules["_ayu_host"].dispatch = self.host.dispatch

    def test_show_returns_builder_and_dispatches_once(self):
        scope = self.load("uialert")
        with bridge.runtime.context(scope):
            builder = AlertDialogBuilder(None, progress_style=0, resources_provider=None)
            self.assertIs(builder.set_title("Synthetic").set_positive_button("OK").show(), builder)
            self.assertIs(builder.show(), builder)
            self.assertIsNotNone(builder.get_dialog())
            self.assertIsNone(builder.get_context())
            self.assertEqual(sum(r["operation"] == "ui.present" for r in self.host.requests), 1)
            builder.dismiss()
            self.assertFalse(builder.get_dialog().isShowing())
            # A dismissed dialog is presented again; it is never silently left off screen.
            self.assertIs(builder.show(), builder)
            self.assertTrue(builder.get_dialog().isShowing())
            self.assertEqual(sum(r["operation"] == "ui.present" for r in self.host.requests), 2)

    def test_button_callback_receives_builder_and_android_button_tag(self):
        scope = self.load("uiclick")
        calls = []
        with bridge.runtime.context(scope):
            builder = AlertDialogBuilder(None).set_title("Synthetic")
            builder.set_positive_button("OK", listener=lambda dialog, which: calls.append((dialog, which))).show()
            callback = next(r for r in self.host.requests if r["operation"] == "ui.present")["arguments"]["config"]["positive_button"]["on_click"]["$callback"]
        bridge.invoke_callback_json(json.dumps({"version": 1, "plugin_id": "uiclick", "callback_id": callback, "arguments": [None, -1]}))
        self.assertEqual(calls, [(builder, AlertDialogBuilder.BUTTON_POSITIVE)])
        with bridge.runtime.context(scope):
            # The click closed the dialog and released its callbacks.
            self.assertFalse(builder.get_dialog().isShowing())
            self.assertEqual(scope.callbacks, {})
            self.assertEqual(sum(r["operation"] == "ui.present" for r in self.host.requests), 1)

    def test_items_optional_listener_and_unsupported_native_options(self):
        scope = self.load("uiitems")
        with bridge.runtime.context(scope):
            builder = AlertDialogBuilder(None).set_items(["One", "Two"])
            builder.show()
            request = next(r for r in self.host.requests if r["operation"] == "ui.present")
            # A click is always reported so the builder knows the dialog closed.
            self.assertIn("$callback", request["arguments"]["config"]["items"]["on_click"])
            for call in (lambda: AlertDialogBuilder(None, 2),
                         lambda: AlertDialogBuilder(None).set_items(["One"], icons=[1]),
                         lambda: AlertDialogBuilder(None).set_view(object())):
                with self.assertRaises(bridge.UnsupportedAPI):
                    call()

    def test_bulletin_signatures_and_fragment_are_preserved(self):
        scope = self.load("uibulletin")
        with bridge.runtime.context(scope):
            BulletinHelper.show_info(message="Synthetic")
            BulletinHelper.show_success("Success", fragment=None)
            BulletinHelper.show_error("Error")
            BulletinHelper.show_simple("Simple", icon_res_id=0)
            with self.assertRaises(bridge.UnsupportedAPI):
                BulletinHelper.show_simple("Unsupported icon", 123)
        configs = [r["arguments"]["config"] for r in self.host.requests if r["operation"] == "ui.present"]
        self.assertEqual([c["style"] for c in configs], ["simple", "success", "error", "simple"])

    def test_copied_feedback_does_not_claim_to_write_the_clipboard(self):
        scope = self.load("uicopied")
        with bridge.runtime.context(scope):
            BulletinHelper.show_copied_to_clipboard()
            BulletinHelper.show_copied_to_clipboard("Synthetic copy message")

        requests = [r for r in self.host.requests if r["operation"] == "ui.present"]
        self.assertEqual([r["arguments"]["config"] for r in requests], [
            {"style": "simple", "text": "Copied to clipboard"},
            {"style": "simple", "text": "Synthetic copy message"},
        ])
        self.assertFalse(any(r["operation"] == "clipboard.write" for r in self.host.requests))

    def test_bulletin_button_is_once_only_and_preserves_duration(self):
        scope = self.load("uiaction")
        calls = []
        with bridge.runtime.context(scope):
            BulletinHelper.show_with_button("Synthetic", 0, "Action", lambda: calls.append("clicked"), duration=1500)
            config = next(r for r in self.host.requests if r["operation"] == "ui.present")["arguments"]["config"]
            self.assertEqual(config["duration_ms"], 1500)
            self.assertEqual(config["button"]["text"], "Action")
            callback = config["button"]["on_click"]["$callback"]
        event = json.dumps({"version": 1, "plugin_id": "uiaction", "callback_id": callback, "arguments": []})
        bridge.invoke_callback_json(event)
        self.assertEqual(calls, ["clicked"])
        with self.assertRaises(bridge.BridgeError):
            bridge.invoke_callback_json(event)

    def test_failed_bulletin_drops_one_shot_callback(self):
        scope = self.load("uirollback")
        with bridge.runtime.context(scope):
            before = set(scope.callbacks)
            from unittest.mock import patch
            with patch.object(bridge.runtime, "call", side_effect=bridge.UnsupportedAPI("unavailable")):
                with self.assertRaises(bridge.UnsupportedAPI):
                    BulletinHelper.show_with_button("Synthetic", 0, "Action", lambda: None)
            self.assertEqual(set(scope.callbacks), before)


if __name__ == "__main__":
    unittest.main()
