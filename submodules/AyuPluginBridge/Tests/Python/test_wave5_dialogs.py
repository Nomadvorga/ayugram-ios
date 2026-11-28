"""Progress dialogs (``ALERT_TYPE_SPINNER``/``ALERT_TYPE_LOADING``) and cancel listeners; fake host only."""
from __future__ import annotations

import sys

import test_sdkport_ui as ui

import ayu_bridge as bridge
from ui.alert import AlertDialogBuilder


class Host(ui.UIHost):
    def __init__(self):
        super().__init__()
        self.calls = []

    def perform(self, request):
        operation, arguments = request["operation"], request["arguments"]
        if operation == "java.member" and arguments["name"] in ("setProgress", "setCancelable"):
            return {"kind": "method"}
        if operation == "java.invoke" and arguments["name"] in ("setProgress", "setCancelable"):
            self.calls.append((arguments["name"], arguments["args"]))
            return None
        return super().perform(request)


class ProgressDialogTests(ui.Case):
    def setUp(self):
        super().setUp()
        self.host = Host()
        sys.modules["_ayu_host"].dispatch = self.host.dispatch

    def user_closed(self):
        del self.host.showing[:]

    def test_spinner_presents_only_the_spinner_and_dismisses(self):
        scope = self.load()
        events = []
        with bridge.runtime.context(scope):
            builder = AlertDialogBuilder(None, AlertDialogBuilder.ALERT_TYPE_SPINNER)
            builder.set_title("ignored by Android").set_on_dismiss_listener(lambda dialog: events.append("dismiss"))
            self.assertIs(builder.show(), builder)
            self.assertTrue(builder.get_dialog().isShowing())
            # Android keeps the texts of a spinner dialog undrawn, so changing them on screen is harmless.
            builder.set_message("still loading")
            builder.set_cancelable(False)
            builder.set_canceled_on_touch_outside(False)
            self.assertIsNone(builder.set_progress(40))
            builder.dismiss()
            self.assertFalse(builder.get_dialog().isShowing())
        config = self.host.presented()[0]
        self.assertEqual(sorted(config), ["context", "on_cancel", "progress"])
        self.assertEqual(config["progress"], "spinner")
        self.assertEqual((events, len(self.host.dismissed), self.host.calls, scope.callbacks), (["dismiss"], 1, [], {}))

    def test_stop_in_the_spinner_prompt_runs_cancel_then_dismiss(self):
        scope = self.load()
        events = []
        with bridge.runtime.context(scope):
            builder = AlertDialogBuilder(None, AlertDialogBuilder.ALERT_TYPE_SPINNER).create()
            builder.get_dialog().setCanCancel(True)
            builder.set_on_cancel_listener(lambda dialog: events.append(("cancel", dialog, dialog.get_dialog().isShowing())))
            builder.set_on_dismiss_listener(lambda dialog: events.append("dismiss"))
            builder.show()
        self.user_closed()
        ui.invoke("sample", self.host.presented()[0]["on_cancel"], [None])
        self.assertEqual(events, [("cancel", builder, True), "dismiss"])
        self.assertEqual(scope.callbacks, {})
        with bridge.runtime.context(scope):
            self.assertFalse(builder.get_dialog().isShowing())
            locked = AlertDialogBuilder(None, 3).create()
            locked.get_dialog().setCanCancel(False)
            locked.show()
            with self.assertRaises(bridge.UnsupportedAPI):
                locked.get_dialog().setCanCancel(True)
        self.assertIs(self.host.presented()[1]["can_cancel"], False)

    def test_loading_carries_texts_buttons_progress_and_live_updates(self):
        scope = self.load()
        events = []
        with bridge.runtime.context(scope):
            builder = AlertDialogBuilder(None, AlertDialogBuilder.ALERT_TYPE_LOADING)
            builder.set_title("Download").set_message("file.bin").set_negative_button("Stop", lambda d, w: events.append(w))
            builder.set_progress(10)
            builder.create().set_progress(25)
            builder.show()
            builder.set_progress(60)
            builder.get_dialog().setProgress(100)
            builder.set_cancelable(False)
            builder.set_cancelable(False)
            for invalid in (1.5, "7", 2 ** 31):
                with self.subTest(invalid=invalid), self.assertRaises(TypeError):
                    builder.set_progress(invalid)
            with self.assertRaises(bridge.UnsupportedAPI):
                builder.set_title("changed on screen")
        config = self.host.presented()[0]
        self.assertEqual(sorted(config), ["context", "message", "negative_button", "on_cancel", "progress", "title", "value"])
        self.assertEqual((config["progress"], config["value"], config["title"]), ("loading", 25, "Download"))
        self.assertEqual(self.host.calls, [("setProgress", [60]), ("setProgress", [100]), ("setCancelable", [False])])
        self.assertEqual(sum("set_progress called before dialog is created" in line for line in self.host.logged()), 1)
        self.user_closed()
        ui.invoke("sample", config["negative_button"]["on_click"], [None, -2])
        self.assertEqual(events, [-2])
        with bridge.runtime.context(scope):
            with self.assertRaises(bridge.UnsupportedAPI):
                AlertDialogBuilder(None, 2).set_items(["a"]).show()
            fixed = AlertDialogBuilder(None, 2).create()
            fixed.set_canceled_on_touch_outside(False)
            fixed.show()
        self.assertIs(self.host.presented()[1]["cancelable"], False)

    def test_an_alert_reports_cancel_through_the_host_cancel_button(self):
        scope = self.load()
        events = []
        with bridge.runtime.context(scope):
            builder = AlertDialogBuilder(None).set_title("T").set_positive_button("OK")
            builder.set_on_cancel_listener(lambda dialog: events.append("cancel"))
            builder.set_on_dismiss_listener(lambda dialog: events.append("dismiss")).show()
            view = bridge.runtime.jclass("android.view.View")()
            with self.assertRaises(bridge.UnsupportedAPI):
                AlertDialogBuilder(None).set_view(view).set_on_cancel_listener(lambda dialog: None).show()
        self.user_closed()
        ui.invoke("sample", self.host.presented()[0]["on_cancel"], [None, -2])
        self.assertEqual(events, ["cancel", "dismiss"])
        with bridge.runtime.context(scope):
            again = AlertDialogBuilder(None).set_title("T").set_positive_button("OK")
            again.set_on_cancel_listener(lambda dialog: events.append("cancelled by code")).show()
            again.get_dialog().cancel()
            self.assertFalse(again.get_dialog().isShowing())
        self.assertEqual(events, ["cancel", "dismiss", "cancelled by code"])
        self.assertEqual(len(self.host.dismissed), 1)

    def test_the_java_dialog_shows_a_spinner_and_reports_cancel(self):
        scope = self.load()
        events = []
        with bridge.runtime.context(scope):
            dialog_class = bridge.runtime.jclass(ui.DIALOG)
            dialog = dialog_class(None, 3)
            dialog.setCanCancel(True)
            dialog.setCanceledOnTouchOutside(False)
            dialog.setOnCancelListener(lambda shown: events.append(shown is dialog))
            dialog.show()
            self.assertTrue(dialog.isShowing())
            loading = dialog_class(None, dialog_class.ALERT_TYPE_LOADING)
            loading.setProgress(30)
        self.assertEqual(self.host.presented()[0]["progress"], "spinner")
        self.user_closed()
        ui.invoke("sample", self.host.presented()[0]["on_cancel"], [None])
        self.assertEqual(events, [True])


if __name__ == "__main__":
    import unittest
    unittest.main()
