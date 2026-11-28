"""``android.app.Dialog`` with a black full-screen theme over the host's custom-view dialog; fake host only."""
from __future__ import annotations

import sys

import test_sdkport_ui as ui

import ayu_bridge as bridge


class FullscreenDialogTests(ui.Case):
    def setUp(self):
        super().setUp()
        self.host = ui.UIHost()
        sys.modules["_ayu_host"].dispatch = self.host.dispatch

    def test_presents_the_content_view_alone_and_reports_dismissal(self):
        scope = self.load()
        events = []
        with bridge.runtime.context(scope):
            style = bridge.runtime.jclass("android.R").style
            self.assertEqual((style.Theme_Black_NoTitleBar, style.Theme_Black_NoTitleBar_Fullscreen), (16973833, 16973834))
            dialog_class = bridge.runtime.jclass("android.app.Dialog")
            dialog = dialog_class(None, style.Theme_Black_NoTitleBar_Fullscreen)
            dialog.setOnDismissListener(lambda shown: events.append(("dismiss", shown is dialog)))
            dialog.setOnCancelListener(lambda shown: events.append(("cancel", shown is dialog)))
            with self.assertRaises(bridge.UnsupportedAPI):
                dialog.show()
            dialog.setContentView(bridge.runtime.jclass("android.view.View")())
            self.assertFalse(dialog.isShowing())
            dialog.show()
            dialog.show()
            self.assertTrue(dialog.isShowing())
            dialog.dismiss()
            dialog.dismiss()
            self.assertFalse(dialog.isShowing())
            dialog.show()
            dialog.cancel()
            self.assertFalse(hasattr(dialog, "getWindow"))
        configs = self.host.presented()
        self.assertEqual(len(configs), 2)
        self.assertEqual(set(configs[0]), {"context", "view", "fullscreen"})
        self.assertEqual((configs[0]["fullscreen"], configs[0]["view"]["$class"]), (True, "android.view.View"))
        self.assertEqual(events, [("dismiss", True), ("cancel", True), ("dismiss", True)])
        self.assertEqual(len(self.host.dismissed), 2)

    def test_the_floating_default_theme_is_refused(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            dialog_class = bridge.runtime.jclass("android.app.Dialog")
            for arguments in ((None,), (None, 0), (None, 16973835)):
                with self.assertRaises(bridge.UnsupportedAPI):
                    dialog_class(*arguments)
            with self.assertRaises(TypeError):
                dialog_class(None, "theme")
            with self.assertRaises(bridge.UnsupportedAPI):
                dialog_class(None, 16973834).setContentView("not a view")
        self.assertEqual(self.host.presented(), [])
        self.assertEqual([dialog_class.__ayu_constructs__(a) for a in ([...], [..., ...], [..., 0], [..., 16973834])],
                         [False, True, False, True])
