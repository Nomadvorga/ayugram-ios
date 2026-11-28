"""``android.app.ProgressDialog`` (``STYLE_SPINNER``) over the host's "indeterminate" progress dialog; fake host only."""
from __future__ import annotations

import json
import sys

import test_sdkport_ui as ui

import ayu_bridge as bridge

LIVE = ("setProgress", "setCancelable", "setMessage")


class Host(ui.UIHost):
    def __init__(self):
        super().__init__()
        self.calls = []

    def perform(self, request):
        operation, arguments = request["operation"], request["arguments"]
        if operation == "java.member" and arguments["name"] in LIVE:
            return {"kind": "method"}
        if operation == "java.invoke" and arguments["name"] in LIVE:
            self.calls.append((arguments["name"], arguments["args"]))
            return None
        return super().perform(request)


class ProgressDialogTests(ui.Case):
    def setUp(self):
        super().setUp()
        self.host = Host()
        sys.modules["_ayu_host"].dispatch = self.host.dispatch

    def test_shows_a_spinner_with_a_message_that_changes_on_screen(self):
        scope = self.load()
        events = []
        with bridge.runtime.context(scope):
            dialog_class = bridge.runtime.jclass("android.app.ProgressDialog")
            self.assertEqual((dialog_class.STYLE_SPINNER, dialog_class.STYLE_HORIZONTAL), (0, 1))
            dialog = dialog_class(None)
            dialog.setMessage("Scanning...")
            dialog.setCancelable(False)
            dialog.setButton(-2, "Stop", lambda shown, which: events.append((shown is dialog, which)))
            dialog.setOnDismissListener(lambda shown: events.append("dismiss"))
            self.assertFalse(dialog.isShowing())
            dialog.show()
            self.assertTrue(dialog.isShowing())
            dialog.setMessage("Scanned: 5\nFound: 1")
            dialog.setMessage(None)
            with self.assertRaises(bridge.UnsupportedAPI):
                dialog.setTitle("changed on screen")
            for absent in ("setProgress", "setMax", "setProgressStyle", "setIndeterminate"):
                self.assertFalse(hasattr(dialog, absent), absent)
            dialog.dismiss()
            self.assertFalse(dialog.isShowing())
        config = self.host.presented()[0]
        self.assertEqual((config["progress"], config["message"], config["cancelable"]), ("indeterminate", "Scanning...", False))
        self.assertNotIn("title", config)
        self.assertEqual(self.host.calls, [("setMessage", ["Scanned: 5\nFound: 1"]), ("setMessage", [None])])
        self.assertEqual((events, len(self.host.dismissed)), (["dismiss"], 1))

    def test_a_button_click_reports_the_dialog_and_its_id(self):
        scope = self.load()
        events = []
        with bridge.runtime.context(scope):
            dialog = bridge.runtime.jclass("android.app.ProgressDialog")(None, 0)
            dialog.setButton(dialog.BUTTON_NEGATIVE, "Stop", lambda shown, which: events.append((shown is dialog, which)))
            dialog.show()
            with self.assertRaises(TypeError):
                bridge.runtime.jclass("android.app.ProgressDialog")(None, "theme")
        del self.host.showing[:]
        ui.invoke("sample", self.host.presented()[0]["negative_button"]["on_click"], [None, -2])
        self.assertEqual(events, [(True, -2)])

    def test_preflight_accepts_the_spinner_members_and_blocks_the_horizontal_ones(self):
        body = ("from android.app import ProgressDialog\n"
                "def run(act):\n"
                "    dialog = ProgressDialog(act)\n"
                "    dialog.setMessage('a')\n"
                "    dialog.setCancelable(False)\n"
                "    dialog.show()\n"
                "    dialog.isShowing()\n"
                "    dialog.dismiss()\n")
        report = json.loads(bridge.preflight_plugin_json(ui.fixtures.source(imports=body)))
        self.assertEqual([(item["code"], item["detail"]) for item in report["blockers"]], [])
        report = json.loads(bridge.preflight_plugin_json(ui.fixtures.source(imports=body + "    dialog.setMax(100)\n")))
        self.assertEqual([(item["code"], item["detail"]) for item in report["blockers"]], [("MEMBER", "android.app.ProgressDialog.setMax")])


if __name__ == "__main__":
    import unittest
    unittest.main()
