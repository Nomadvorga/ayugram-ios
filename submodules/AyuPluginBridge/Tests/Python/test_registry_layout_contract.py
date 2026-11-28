"""The SDK side of ``plugins.list``, ``plugins.settings`` and ``ui.layout_params`` against the answers the Swift host gives."""
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
import test_telegram_host as telegram
from _ayu_javalib import telegram_ui as ui

CONTROLLER = "com.exteragram.messenger.plugins.PluginsController"
SETTINGS = "com.exteragram.messenger.plugins.ui.PluginSettingsActivity"
LAYOUT = "org.telegram.ui.Components.LayoutHelper"


class RegistryHost(telegram.TelegramHost):
    """Refuses what ``AyuPluginRegistryBridge`` refuses."""

    def perform(self, request):
        operation, arguments = request["operation"], request["arguments"]
        if operation == "plugins.settings":
            self.calls.append((operation, arguments))
            if arguments["action"] == "reload" and arguments["plugin_id"] != request["plugin_id"]:
                raise bridge.BridgeError("UNSUPPORTED_API", "Unsupported API: reloading the settings of another plugin")
            return None
        return super().perform(request)


class RegistryCase(telegram.TelegramCase):
    def setUp(self):
        super().setUp()
        self.host = RegistryHost(self.operations)
        sys.modules["_ayu_host"].dispatch = self.host.dispatch

    def test_records_as_the_host_lists_them(self):
        scope = self.load()
        # The host leaves optional fields out: no version without metadata, no error unless the plugin failed.
        self.host.results["plugins.list"] = [
            {"id": "sample", "name": "Sample", "enabled": True, "version": "1.2", "author": "@a", "icon": "pack/3", "description": "About"},
            {"id": "bare", "name": "Bare", "enabled": False},
            {"id": "failed", "name": "Failed", "enabled": False, "error": True},
        ]
        with bridge.runtime.context(scope):
            controller = telegram.runtime_class(CONTROLLER).getInstance()
            plugins = controller.plugins
            sample, bare, failed = plugins.get("sample"), plugins.get("bare"), plugins.get("failed")
            self.assertEqual((sample.getVersion(), sample.getAuthor(), sample.getIcon(), sample.getDescription(), sample.isEnabled()),
                             ("1.2", "@a", "pack/3", "About", True))
            self.assertEqual((bare.getVersion(), bare.getAuthor(), bare.getIcon(), bare.getDescription(), bare.isEnabled(), bare.hasError()),
                             ("1.0", None, None, None, False, False))
            self.assertEqual((failed.hasError(), failed.isEnabled()), (True, False))
            self.assertEqual((controller.isPluginActive("sample"), controller.isPluginActive(sample), controller.isPluginActive("bare"),
                              controller.isPluginActive("absent")), (True, True, False, False))
            self.assertEqual(self.host.last("plugins.list"), {})

    def test_settings_reload_and_open(self):
        scope = self.load()
        self.host.results["plugins.list"] = [{"id": "other", "name": "Other", "enabled": True}]
        with bridge.runtime.context(scope):
            controller_class = telegram.runtime_class(CONTROLLER)
            controller = controller_class.getInstance()
            controller.loadPluginSettings()
            self.assertEqual(self.host.last("plugins.settings"), {"action": "reload", "plugin_id": "sample"})
            with self.assertRaises(bridge.BridgeError) as refused:
                controller.loadPluginSettings("other")
            self.assertEqual(refused.exception.code, "UNSUPPORTED_API")
            # Android declares openPluginSettings static: plugins call it on the class and on the instance.
            controller_class.openPluginSettings("other")
            self.assertEqual(self.host.last("plugins.settings"), {"action": "open", "plugin_id": "other"})
            controller.openPluginSettings(controller.plugins.get("other"), "page:row")
            self.assertEqual(self.host.last("plugins.settings"), {"action": "open", "plugin_id": "other", "link_alias": "page:row"})
            controller.openPluginSettings("other", object())
            self.assertEqual(self.host.last("plugins.settings"), {"action": "open", "plugin_id": "other"})
            for invalid in (None, "", 7):
                with self.assertRaises(TypeError):
                    controller_class.openPluginSettings(invalid)

    def test_settings_activity_carries_its_target_row(self):
        scope = self.load()
        self.host.results.update({"plugins.list": [{"id": "other", "name": "Other", "enabled": True}],
                                  "telegram.screen": {"kind": "dialogs", "account": 0}})
        with bridge.runtime.context(scope):
            other = telegram.runtime_class(CONTROLLER).getInstance().plugins.get("other")
            activity = telegram.runtime_class(SETTINGS)
            fragment = telegram.client.get_last_fragment()
            fragment.presentFragment(activity(other, "row"))
            self.assertEqual(self.host.last("plugins.settings"), {"action": "open", "plugin_id": "other", "link_alias": "row"})
            fragment.presentFragment(activity(other, None))
            self.assertEqual(self.host.last("plugins.settings"), {"action": "open", "plugin_id": "other"})
            for rest in (("Title", [], None), (7,)):
                with self.assertRaises(bridge.UnsupportedAPI):
                    activity(other, *rest)
            with self.assertRaises(TypeError):
                activity("other")

    def test_layout_helper_arguments(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            layout = telegram.runtime_class(LAYOUT)
            layout.createFrame(-1, 48)
            self.assertEqual(self.host.last("ui.layout_params"), {"kind": "frame", "width": -1, "height": 48})
            layout.createFrameMarginPx(-1, -2, 51, 3, 6, 9, 12)
            self.assertEqual(self.host.last("ui.layout_params"), {"kind": "frame", "width": -1, "height": -2, "gravity": 51,
                                                                "margins": [3, 6, 9, 12], "margins_in_pixels": True})
            layout.createLinear(-1, -2, 0, 16, 8, 16, 8)
            self.assertEqual(self.host.last("ui.layout_params"), {"kind": "linear", "width": -1, "height": -2, "gravity": 0,
                                                                "margins": [16, 8, 16, 8]})
            layout.createLinear(0, -1, 1.0)
            self.assertEqual(self.host.last("ui.layout_params"), {"kind": "linear", "width": 0, "height": -1, "weight": 1.0})

    def test_linear_relatively_passes_the_gravity_as_weight_like_android(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            layout = telegram.runtime_class(LAYOUT)
            for rtl, weight in ((False, 51.0), (True, 53.0)):
                with patch.object(ui, "_is_rtl", return_value=rtl):
                    layout.createLinearRelatively(-1, -2, 0x00800033, 1, 2, 3, 4)
                self.assertEqual(self.host.last("ui.layout_params"), {"kind": "linear", "width": -1, "height": -2, "weight": weight,
                                                                    "margins": [1, 2, 3, 4], "relative": True})
            with patch.object(ui, "_is_rtl", return_value=True):
                layout.createLinearRelatively(-1, -2, 0x00800005)
            self.assertEqual(self.host.last("ui.layout_params"), {"kind": "linear", "width": -1, "height": -2, "weight": 3.0, "relative": True})
            with self.assertRaises(TypeError):
                layout.createLinearRelatively(-1, -2, 1.5)
        self.assertEqual([ui._absolute_gravity(value, rtl) for value, rtl in ((17, True), (0x00800003, False), (0x00800003, True),
                                                                              (0x00800005, False), (0x00800011, True))],
                         [17, 3, 5, 5, 17])


if __name__ == "__main__":
    unittest.main()
