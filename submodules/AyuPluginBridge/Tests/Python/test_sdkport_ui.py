"""Alerts, bulletins, listeners and storage helpers; synthetic plugins and a fake host only."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
import warnings
from unittest.mock import patch

import test_bridge as fixtures

import android_utils
import ayu_bridge as bridge
import file_utils
from ui.alert import AlertDialogBuilder
from ui.bulletin import BulletinHelper

DIALOG = "org.telegram.ui.ActionBar.AlertDialog"


class UIHost(fixtures.FakeHost):
    """Fake host with the presentation operation and the listener proxies the Swift host declares."""

    def __init__(self):
        super().__init__()
        self.capabilities["classes"] += [DIALOG, "java.lang.Runnable", "android.view.View$OnClickListener",
                                         "android.view.View$OnTouchListener"]
        self.capabilities["proxy_interfaces"].update({
            "java.lang.Runnable": ["run"], "android.view.View$OnClickListener": ["onClick"],
            "android.view.View$OnTouchListener": ["onTouch"]})
        self.dismissed = []
        # Dialogs on screen. The host removes one without a callback when the user cancels it.
        self.showing = []

    def perform(self, request):
        operation, arguments = request["operation"], request["arguments"]
        if operation == "ui.present":
            if arguments["kind"] == "bulletin":
                return None
            handle = "dialog-" + str(len(self.requests))
            self.handles[handle] = (request["plugin_id"], [])
            self.showing.append(handle)
            return {"$handle": handle, "$class": DIALOG}
        if operation == "java.member" and arguments["name"] in ("dismiss", "isShowing"):
            return {"kind": "method"}
        if operation == "java.invoke" and arguments["name"] == "isShowing":
            return arguments["target"]["$handle"] in self.showing
        if operation == "java.invoke" and arguments["name"] == "dismiss":
            handle = arguments["target"]["$handle"]
            self.dismissed.append(handle)
            if handle in self.showing:
                self.showing.remove(handle)
            return None
        if operation == "java.proxy":
            handle = "proxy-" + str(len(self.requests))
            self.handles[handle] = (request["plugin_id"], arguments)
            return {"$handle": handle, "$class": arguments["interfaces"][0]}
        return super().perform(request)

    def presented(self, kind="alert"):
        return [r["arguments"]["config"] for r in self.requests
                if r["operation"] == "ui.present" and r["arguments"]["kind"] == kind]

    def logged(self):
        return [r["arguments"]["message"] for r in self.requests if r["operation"] == "log.write"]


def invoke(plugin_id, callback, arguments=()):
    return bridge.invoke_callback_json(json.dumps({
        "version": 1, "plugin_id": plugin_id, "callback_id": callback["$callback"], "arguments": list(arguments)}))


class Case(unittest.TestCase):
    tearDown = fixtures.BridgeTests.tearDown
    load = fixtures.BridgeTests.load

    def setUp(self):
        fixtures.BridgeTests.setUp(self)
        self.host = UIHost()
        sys.modules["_ayu_host"].dispatch = self.host.dispatch


class AlertTests(Case):
    def test_cancel_switches_follow_android_and_join_into_the_host_flag(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            ignored = AlertDialogBuilder(None).set_title("T").set_positive_button("OK")
            # Android applies these only to a created dialog and logs otherwise.
            self.assertIsNone(ignored.set_cancelable(False))
            self.assertIsNone(ignored.set_canceled_on_touch_outside(False))
            ignored.show()
            created = AlertDialogBuilder(None).set_title("T").set_positive_button("OK").create()
            created.set_canceled_on_touch_outside(False)
            created.show()
            created.set_canceled_on_touch_outside(False)
            # The outside-tap switch still keeps the presented dialog non-cancelable.
            created.set_cancelable(True)
            with self.assertRaises(bridge.UnsupportedAPI):
                created.set_canceled_on_touch_outside(True)
            with self.assertRaises(bridge.UnsupportedAPI):
                created.set_title("changed on screen")
        first, second = self.host.presented()
        self.assertNotIn("cancelable", first)
        self.assertIs(second["cancelable"], False)
        self.assertEqual(sum("best called after create() or show()" in line for line in self.host.logged()), 2)

    def test_dismiss_listener_runs_after_a_click_and_after_dismiss_only(self):
        scope = self.load()
        events = []
        with bridge.runtime.context(scope):
            builder = AlertDialogBuilder(None).set_message("M").set_negative_button("No")
            builder.set_on_dismiss_listener(lambda dialog: events.append(("dismiss", dialog)))
            builder.set_on_cancel_listener(None).set_on_back_button_listener(None).show()
            self.assertTrue(builder.get_dialog().isShowing())
            self.assertIsNone(builder.set_progress(5))
        invoke("sample", self.host.presented()[0]["negative_button"]["on_click"], [None, -2])
        self.assertEqual(events, [("dismiss", builder)])
        with bridge.runtime.context(scope):
            self.assertFalse(builder.get_dialog().isShowing())
            builder.dismiss()
            other = AlertDialogBuilder(None).set_title("T").set_positive_button("OK")
            other.set_on_dismiss_listener(lambda dialog: events.append("second")).show()
            other.get_dialog().dismiss()
            other.dismiss()
        self.assertEqual(events, [("dismiss", builder), "second"])
        self.assertEqual(len(self.host.dismissed), 1)
        self.assertEqual(scope.callbacks, {})

    def test_unreported_events_are_refused_and_red_buttons_degrade_with_one_log(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            builder = AlertDialogBuilder(None).set_title("T").set_positive_button("OK")
            with self.assertRaises(bridge.UnsupportedAPI):
                builder.set_on_back_button_listener(lambda dialog, which: None)
            with self.assertRaises(TypeError):
                builder.set_on_cancel_listener("not callable")
            # Colour is cosmetic: the dialog works, and the missing styling is logged once per generation.
            self.assertIs(builder.make_button_red(AlertDialogBuilder.BUTTON_POSITIVE), builder)
            builder.make_button_red(AlertDialogBuilder.BUTTON_NEGATIVE).make_button_red(7)
            AlertDialogBuilder(None).set_title("Other").make_button_red(AlertDialogBuilder.BUTTON_POSITIVE)
            for invalid, error in (("positive", TypeError), (None, TypeError), (True, TypeError), (-1.0, TypeError),
                                   (2 ** 31, OverflowError)):
                with self.subTest(invalid=invalid), self.assertRaises(error):
                    builder.make_button_red(invalid)
            builder.show()
        config = self.host.presented()[0]
        self.assertEqual(sorted(config), ["context", "positive_button", "title"])
        self.assertEqual(sorted(config["positive_button"]), ["on_click", "text"])
        self.assertEqual(sum("red button styling is not rendered on iOS" in line for line in self.host.logged()), 1)
        bridge.unload_plugin("sample")
        with bridge.runtime.context(self.load()):
            AlertDialogBuilder(None).make_button_red(AlertDialogBuilder.BUTTON_POSITIVE)
        self.assertEqual(sum("red button styling is not rendered on iOS" in line for line in self.host.logged()), 2)

    def test_dismissal_without_a_callback_is_noticed_and_the_dialog_shows_again(self):
        scope = self.load()
        events = []
        with bridge.runtime.context(scope):
            builder = AlertDialogBuilder(None).set_title("T")
            builder.set_positive_button("OK", lambda dialog, which: events.append(
                (which, dialog.show() is dialog, dialog.get_dialog().isShowing())))
            builder.set_on_dismiss_listener(lambda dialog: events.append("dismiss")).show()
            self.assertIs(builder.show(), builder)
            self.assertEqual(len(self.host.presented()), 1)
            # The user closes it with the host's own Cancel button: no callback reaches Python.
            self.host.showing.clear()
            self.assertEqual((events, len(scope.callbacks)), ([], 1))
            self.assertFalse(builder.get_dialog().isShowing())
            self.assertEqual((events, scope.callbacks), (["dismiss"], {}))
            # Nothing is stuck: setters work again and show() presents a second time.
            builder.set_title("Again").show()
            self.assertEqual([config["title"] for config in self.host.presented()], ["T", "Again"])
            self.host.showing.clear()
            builder.show()
            self.assertEqual((len(self.host.presented()), events), (3, ["dismiss", "dismiss"]))
        del events[:]
        # The host closes a dialog before it delivers the click, but Android's listener still
        # sees it showing: show() inside the listener changes nothing and the dialog then closes.
        self.host.showing.clear()
        invoke("sample", self.host.presented()[2]["positive_button"]["on_click"], [None, -1])
        self.assertEqual((events, len(self.host.presented())), ([(-1, True, True), "dismiss"], 3))
        with bridge.runtime.context(scope):
            builder.dismiss()
            self.assertEqual(self.host.dismissed, [])
            # Shown again after a click, and again after dismiss().
            builder.show()
            builder.dismiss()
            builder.show()
            self.assertTrue(builder.get_dialog().isShowing())
        self.assertEqual((len(self.host.presented()), len(self.host.dismissed)), (5, 1))
        self.assertEqual(events, [(-1, True, True), "dismiss", "dismiss"])

    def test_failing_listener_is_logged_and_the_dialog_still_closes(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            builder = AlertDialogBuilder(None).set_title("T").set_items(["One", 2], lambda dialog, which: 1 / 0)
            builder.show()
        config = self.host.presented()[0]
        self.assertEqual(config["items"]["labels"], ["One", "2"])
        invoke("sample", config["items"]["on_click"], [None, 1])
        with bridge.runtime.context(scope):
            self.assertFalse(builder.get_dialog().isShowing())
        self.assertTrue(any("ItemsClickListener: ZeroDivisionError" in line for line in self.host.logged()))

    def test_host_views_are_forwarded_and_unpresentable_options_fail(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            view = bridge.runtime.jclass("android.view.View")()
            builder = AlertDialogBuilder(None, 0, object()).set_title(None).set_view(view, 300)
            builder.set_positive_button("OK").set_dim_enabled(False).set_blurred_background(True).show()
            for call in (lambda: AlertDialogBuilder(None, 1),
                         lambda: AlertDialogBuilder(None).set_top_image(1, 0),
                         lambda: AlertDialogBuilder(None).set_top_animation(1, 1, True, 0),
                         lambda: AlertDialogBuilder(None).set_message_text_view_clickable(True),
                         lambda: AlertDialogBuilder(None).set_view("not a view"),
                         lambda: builder.get_button(AlertDialogBuilder.BUTTON_POSITIVE),
                         lambda: builder.get_dialog().getWindow()):
                with self.subTest(call=call), self.assertRaises(bridge.UnsupportedAPI):
                    call()
            self.assertIsNone(AlertDialogBuilder(None).get_button(AlertDialogBuilder.BUTTON_POSITIVE))
            self.assertIsNone(AlertDialogBuilder(None).get_dialog())
            self.assertIs(AlertDialogBuilder(None).set_message_text_view_clickable(False).get_context(), None)
        config = self.host.presented()[0]
        self.assertEqual(config["view"]["$class"], "android.view.View")
        self.assertNotIn("title", config)


class BulletinTests(Case):
    def test_undo_runs_exactly_one_of_its_callbacks(self):
        scope = self.load()
        calls = []
        with bridge.runtime.context(scope):
            BulletinHelper.show_undo("Deleted", lambda: calls.append("undo"), lambda: calls.append("action"), "1 chat")
            BulletinHelper.show_undo("Deleted", lambda: calls.append("undo2"), lambda: calls.append("action2"))
            BulletinHelper.show_undo("Deleted", lambda: calls.append("undo3"))
        first, second, third = self.host.presented("bulletin")
        self.assertEqual((first["text"], first["duration_ms"], first["button"]["text"]),
                         ("Deleted\n1 chat", 5000, "Undo"))
        timers = [(token, args) for token, (_, args) in self.host.tokens.items() if "delay_ms" in args]
        self.assertEqual([args["delay_ms"] for _, args in timers], [5000, 5000])
        invoke("sample", first["button"]["on_click"])
        self.assertNotIn(timers[0][0], self.host.tokens)
        invoke("sample", timers[1][1]["callback"])
        invoke("sample", third["button"]["on_click"])
        self.assertEqual(calls, ["undo", "action2", "undo3"])
        with self.assertRaises(bridge.BridgeError):
            invoke("sample", timers[0][1]["callback"])

    def test_stock_bulletins_and_classmethod_signatures(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            BulletinHelper.show_link_copied()
            BulletinHelper.show_link_copied(True)
            BulletinHelper.show_file_saved_to_gallery(True, 3)
            BulletinHelper.show_file_saved_to_gallery()
            BulletinHelper.show_file_saved_to_downloads("AUDIO", 2)
            BulletinHelper().show_error("through an instance")
            with self.assertRaises(bridge.UnsupportedAPI):
                BulletinHelper.show_two_line("Title", "Subtitle", 7)
            with self.assertRaises(TypeError):
                BulletinHelper.show_undo("x", None)
        self.assertEqual([(c["style"], c["text"]) for c in self.host.presented("bulletin")], [
            ("simple", "Link copied to clipboard."),
            ("simple", "This link will only work for members of this chat."),
            ("simple", "3 videos saved to gallery"), ("simple", "Photo saved to gallery"),
            ("simple", "2 files saved to downloads"), ("error", "through an instance")])


class ListenerTests(Case):
    def test_listeners_export_declared_proxies_and_follow_android_results(self):
        scope = self.load()
        seen = []
        with bridge.runtime.context(scope):
            click = android_utils.OnClickListener(lambda view: seen.append(("click", view)))
            touch = android_utils.OnTouchListener(lambda view, event: seen.append(("touch", event)) or 1)
            broken = android_utils.OnTouchListener(lambda view, event: 1 / 0)
            runnable = android_utils.R(lambda: seen.append("run"))
            self.assertIsNone(click.onClick("v"))
            self.assertIs(touch.onTouch("v", "e"), True)
            self.assertIs(broken.onTouch("v", "e"), False)
            self.assertIsNone(runnable.run())
            exported = bridge.runtime.encode([click, touch, runnable])
            self.assertEqual([item["$class"] for item in exported], [
                "android.view.View$OnClickListener", "android.view.View$OnTouchListener", "java.lang.Runnable"])
            for call in (lambda: android_utils.OnLongClickListener(print), lambda: android_utils.R(None),
                         lambda: android_utils.OnClickListener("no")):
                with self.subTest(call=call), self.assertRaises((bridge.UnsupportedAPI, TypeError)):
                    call()
        self.assertEqual(seen, [("click", "v"), ("touch", "e"), "run"])
        self.assertTrue(any("onTouch listener: ZeroDivisionError" in line for line in self.host.logged()))
        bridge.unload_plugin("sample")
        self.assertIsNone(click.onClick("after unload"))
        self.assertEqual(len(seen), 3)

    def test_undeclared_listeners_stay_blockers(self):
        report = json.loads(bridge.preflight_plugin_json(fixtures.source(
            imports="from android_utils import OnTouchListener, OnKeyListener, OnSeekBarChangeListener\n")))
        self.assertEqual([item["detail"] for item in report["blockers"] if item["code"] == "SDK_MEMBER"],
                         ["android_utils.OnKeyListener", "android_utils.OnSeekBarChangeListener"])


class StorageTests(Case):
    def test_directories_are_created_inside_the_application_container(self):
        scope = self.load()
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {"HOME": home}), \
                bridge.runtime.context(scope):
            home = os.path.realpath(home)
            support = os.path.join(home, "Library", "Application Support", "AyuPluginFiles")
            self.assertEqual(os.path.realpath(file_utils.get_cache_dir()),
                             os.path.join(home, "Library", "Caches", "AyuPluginFiles"))
            for helper, name in ((file_utils.get_plugins_dir, "plugins"), (file_utils.get_files_dir, "files"),
                                 (file_utils.get_images_dir, "images"), (file_utils.get_videos_dir, "videos"),
                                 (file_utils.get_audios_dir, "audios"), (file_utils.get_documents_dir, "documents")):
                with self.subTest(name=name):
                    path = helper()
                    self.assertEqual(os.path.realpath(path), os.path.join(support, name))
                    self.assertTrue(os.path.isdir(path))
            target = os.path.join(file_utils.get_files_dir(), "nested", "note.txt")
            file_utils.ensure_dir_exists(os.path.dirname(target))
            file_utils.write_file(target, "synthetic")
            self.assertEqual(file_utils.read_file(target), "synthetic")
            self.assertEqual(file_utils.list_dir(file_utils.get_files_dir(), recursive=True), [target])
            self.assertTrue(file_utils.delete_file(target))

    def test_plugin_file_is_the_android_path_inside_the_writable_plugins_directory(self):
        text = ("import os, sys, traceback\n" + fixtures.source(body=(
            "    def __init__(self):\n        super().__init__()\n"
            "        self.here = os.path.dirname(os.path.realpath(__file__))\n"
            "        self.made = os.path.join(self.here, 'sample_data')\n        os.makedirs(self.made)\n"
            "        self.frame = sys._getframe().f_code.co_filename\n"
            "    def on_plugin_load(self):\n        from extera_utils.get_caller import get_plugin_id\n"
            "        self.caller = (lambda: get_plugin_id())()\n        try:\n            raise ValueError('synthetic')\n"
            "        except ValueError:\n            self.trace = traceback.format_exc()\n")))
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {"HOME": home}):
            plugins = os.path.join(home, "Library", "Application Support", "AyuPluginFiles", "plugins")
            self.host.reject_authorization = True
            with self.assertRaisesRegex(bridge.BridgeError, "LOAD_REJECTED"):
                bridge.load_plugin(text, "sample.plugin", "sample")
            self.host.reject_authorization = False
            # Neither a rejected nor an accepted load creates storage; only the plugin does.
            self.assertEqual(os.listdir(home), [])
            with warnings.catch_warnings():
                # Formatting a traceback looks for the source through a loader the plugin module lacks.
                warnings.simplefilter("ignore", DeprecationWarning)
                bridge.load_plugin(text, "sample.plugin", "sample")
            scope = bridge.runtime.scopes["sample"]
            plugin, path = scope.instance, os.path.join(plugins, "sample.plugin")
            self.assertEqual((scope.module.__file__, plugin.frame, scope.source_filename), (path, path, path))
            self.assertEqual(os.listdir(plugins), ["sample_data"])
            self.assertEqual(plugin.made, os.path.join(os.path.realpath(plugins), "sample_data"))
            with bridge.runtime.context(scope):
                self.assertEqual(os.path.realpath(file_utils.get_plugins_dir()), plugin.here)
            self.assertEqual(plugin.caller, ("[sample.plugin:on_plugin_load:" + plugin.caller[0].split(":")[2], "sample"))
            self.assertIn(f'File "{path}", line ', plugin.trace)
            bridge.unload_plugin("sample")
            # The load budget still recognises the plugin's frames under their new filename.
            previous = bridge.runtime.execution_limits["load"]
            bridge.runtime.execution_limits["load"] = 0.02
            try:
                with self.assertRaisesRegex(bridge.BridgeError, "EXECUTION_TIMEOUT"):
                    bridge.load_plugin(fixtures.source() + "VALUE = 0\nwhile True:\n    VALUE += 1\n", "sample.plugin")
            finally:
                bridge.runtime.execution_limits["load"] = previous
            bridge.load_plugin(fixtures.source(plugin_id="other"), "/elsewhere/other.plugin", "other")
            self.assertEqual(bridge.runtime.scopes["other"].module.__file__, "/elsewhere/other.plugin")
        with patch.dict(os.environ, {"HOME": "relative/or/missing"}):
            bridge.load_plugin(fixtures.source(), "sample.plugin", "sample")
            self.assertEqual(bridge.runtime.scopes["sample"].module.__file__, "sample.plugin")

    def test_missing_container_and_file_handlers_fail_explicitly(self):
        scope = self.load()
        with patch.dict(os.environ, {"HOME": "relative/or/missing"}), bridge.runtime.context(scope):
            with self.assertRaises(bridge.UnsupportedAPI):
                file_utils.get_cache_dir()
            self.assertIs(file_utils.FilesController.SUPPORT_ICONS, False)
            self.assertIs(file_utils.FilesController.DIRECT_FILE_ICONS, False)
            with self.assertRaises(bridge.UnsupportedAPI):
                file_utils.FilesController.unregister("txt", "secret")
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {"HOME": home}):
            with self.assertRaisesRegex(bridge.BridgeError, "NO_PLUGIN_CONTEXT"):
                file_utils.get_files_dir()
            self.assertEqual(os.listdir(home), [])


if __name__ == "__main__":
    unittest.main()
