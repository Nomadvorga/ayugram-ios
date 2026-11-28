"""``org.telegram.ui.ActionBar.AlertDialog`` and its ``Builder`` as a Python-local facade over ``ui.alert``.

The host is synthetic and plugin sources are test-authored.
"""
from __future__ import annotations

import json
import unittest

from pymembers_fixtures import CONTEXT, HostCase, entry
import ayu_bridge as bridge
from _ayu_javalib import android_content, telegram_ui

DIALOG = "org.telegram.ui.ActionBar.AlertDialog"
IMPORTS = "from org.telegram.ui.ActionBar import AlertDialog\n"


class DialogCase(HostCase):
    """A host that declares its ``AlertDialog`` adapter (``dismiss``, ``isShowing``) and presents alerts."""

    def setUp(self):
        super().setUp()
        self.showing, self.dismissed = [], []

        def gone(target, args):
            self.dismissed.append(target["$handle"])
            if target["$handle"] in self.showing:
                self.showing.remove(target["$handle"])

        self.declare(DIALOG, {"isShowing": lambda target, args: target["$handle"] in self.showing, "dismiss": gone},
                     entry(methods=["dismiss", "getClass", "isShowing"]))
        self.declare(CONTEXT)
        perform = self.host.perform

        def presenting(request):
            if request["operation"] == "ui.present" and request["arguments"]["kind"] == "alert":
                handle = "dialog-" + str(len(self.host.requests))
                self.host.handles[handle] = (request["plugin_id"], [])
                self.showing.append(handle)
                return {"$handle": handle, "$class": DIALOG}
            return perform(request)

        self.host.perform = presenting

    def presented(self):
        return [item["arguments"]["config"] for item in self.host.requests if item["operation"] == "ui.present"]

    def logged(self):
        return [item["arguments"]["message"] for item in self.host.requests if item["operation"] == "log.write"]

    def click(self, callback, which, plugin_id="sample"):
        """The host's report of a button or item click; it has closed the dialog by then."""
        del self.showing[:]
        return bridge.invoke_callback_json(json.dumps({
            "version": 1, "plugin_id": plugin_id, "callback_id": callback["$callback"], "arguments": [None, which]}))

    def dialog_class(self):
        scope = self.load(imports=IMPORTS)
        return scope, scope.module.AlertDialog


class BuilderTests(DialogCase):
    def test_the_class_is_local_while_the_hosts_dialog_stays_a_host_object(self):
        scope, dialog_class = self.dialog_class()
        with bridge.runtime.context(scope):
            self.assertIs(dialog_class, telegram_ui.AlertDialog)
            self.assertIs(bridge.runtime.jclass(DIALOG + "$Builder"), dialog_class.Builder)
            self.assertIs(bridge.runtime.jclass(DIALOG + "$OnButtonClickListener"), dialog_class.OnButtonClickListener)
            self.assertEqual((dialog_class.BUTTON_POSITIVE, dialog_class.BUTTON_NEGATIVE, dialog_class.BUTTON_NEUTRAL,
                              dialog_class.BUTTON_NEGATIVE_2), (-1, -2, -3, -4))
            self.assertEqual((dialog_class.ALERT_TYPE_MESSAGE, dialog_class.ALERT_TYPE_LOADING,
                              dialog_class.ALERT_TYPE_SPINNER), (0, 2, 3))
            shown = dialog_class.Builder(self.reference(CONTEXT)).setTitle("T").setPositiveButton("OK", None).show()
            # What ``ui.present`` returned is the host's adapter, which answers for the dialog on screen.
            native = shown._presenter._native
            self.assertIs(type(native), bridge.RemoteObject)
            self.assertTrue(shown.isShowing())
            self.assertIn((DIALOG, "isShowing"), self.host_requests("java.invoke"))

    def test_setters_chain_and_show_presents_one_alert_with_android_listener_arguments(self):
        scope, dialog_class = self.dialog_class()
        events = []
        with bridge.runtime.context(scope):
            context = self.reference(CONTEXT)
            builder = dialog_class.Builder(context)
            self.assertIs(builder.getContext(), context)
            for result in (builder.setTitle("Title"), builder.setMessage("Message"),
                           builder.setPositiveButton("Yes", lambda dialog, which: events.append(("yes", dialog, which))),
                           builder.setNegativeButton("No", None),
                           builder.setNeutralButton("Later", lambda dialog, which: events.append(("later", dialog, which))),
                           builder.setOnDismissListener(lambda dialog: events.append(("dismissed", dialog))),
                           builder.setOnPreDismissListener(lambda dialog: events.append(("dismissing", dialog))),
                           builder.setMessageTextViewClickable(False), builder.setDimEnabled(False),
                           builder.setBlurredBackground(True), builder.setDialogButtonColorKey(7)):
                self.assertIs(result, builder)
            self.assertEqual(self.presented(), [])
            dialog = builder.create()
            self.assertIs(type(dialog), dialog_class)
            self.assertFalse(dialog.isShowing())
            self.assertIs(builder.show(), dialog)
            self.assertIs(builder.create(), dialog)
            self.assertTrue(dialog.isShowing())
            # Android leaves a dialog that is on screen alone.
            self.assertIsNone(dialog.show())
        config, = self.presented()
        self.assertEqual((config["title"], config["message"]), ("Title", "Message"))
        self.assertEqual([config[key]["text"] for key in ("positive_button", "negative_button", "neutral_button")],
                         ["Yes", "No", "Later"])
        self.click(config["neutral_button"]["on_click"], -3)
        self.assertEqual(events, [("later", dialog, -3), ("dismissing", dialog), ("dismissed", dialog)])
        with bridge.runtime.context(scope):
            self.assertFalse(dialog.isShowing())
            # A dismissed dialog is shown again by show(), with new callbacks.
            dialog.show()
            self.assertTrue(dialog.isShowing())
        self.click(self.presented()[1]["positive_button"]["on_click"], -1)
        self.assertEqual(events[3:], [("yes", dialog, -1), ("dismissing", dialog), ("dismissed", dialog)])

    def test_listeners_may_be_interface_implementations(self):
        scope, dialog_class = self.dialog_class()
        events = []
        with bridge.runtime.context(scope):
            import java

            class Click(java.dynamic_proxy(dialog_class.OnButtonClickListener)):
                def onClick(self, dialog, which):
                    events.append(("button", dialog, which))

            class Choose(java.dynamic_proxy(android_content.DialogInterface.OnClickListener)):
                def onClick(self, dialog, which):
                    events.append(("item", dialog, which))

            class Gone(java.dynamic_proxy(android_content.DialogInterface.OnDismissListener)):
                def onDismiss(self, dialog):
                    events.append(("gone", dialog))

            first = dialog_class.Builder(None).setMessage("M").setPositiveButton("OK", Click()).show()
            second = dialog_class.Builder(None).setItems(["a", "b"], Choose()).setOnDismissListener(Gone()).show()
            for listener in (object(), 5, "onClick"):
                with self.subTest(listener=listener), self.assertRaises(TypeError):
                    dialog_class.Builder(None).setPositiveButton("OK", listener)
        one, two = self.presented()
        self.click(one["positive_button"]["on_click"], -1)
        self.assertEqual(two["items"]["labels"], ["a", "b"])
        self.click(two["items"]["on_click"], 1)
        self.assertEqual(events, [("button", first, -1), ("item", second, 1), ("gone", second)])

    def test_constructor_forms_follow_the_java_overloads_and_refuse_progress_styles(self):
        scope, dialog_class = self.dialog_class()
        with bridge.runtime.context(scope):
            provider = self.reference(CONTEXT, "provider")
            for arguments in ((None,), (None, None), (None, provider), (None, 0, None), (None, 0, provider)):
                with self.subTest(arguments=arguments):
                    self.assertIs(type(dialog_class.Builder(*arguments).create()), dialog_class)
            for arguments in ((None, 0), (None, provider, 0), (None, "0", None), (None, 0, None, None), (None, True, None)):
                with self.subTest(arguments=arguments), self.assertRaises(TypeError):
                    dialog_class.Builder(*arguments)
            for style in (dialog_class.ALERT_TYPE_LOADING, dialog_class.ALERT_TYPE_SPINNER):
                with self.subTest(style=style):
                    self.assertIs(type(dialog_class.Builder(None, style, None).create()), dialog_class)
                    self.assertIs(type(dialog_class(None, style)), dialog_class)
            with self.assertRaises(bridge.UnsupportedAPI):
                dialog_class(None, 1)
            with self.assertRaises(TypeError):
                dialog_class(None, None)
            # A dialog built without the builder takes the same setters.
            plain = dialog_class(None, 0)
            plain.setTitle("T")
            plain.setMessage("M")
            plain.setButton(dialog_class.BUTTON_NEGATIVE, "No", None)
            plain.setPositiveButton("Yes", None)
            plain.setPositiveButton(None, None)
            with self.assertRaises(bridge.UnsupportedAPI):
                plain.setButton(dialog_class.BUTTON_NEGATIVE_2, "Other", None)
            plain.setCancelable(False)
            plain.show()
            with self.assertRaises(bridge.UnsupportedAPI):
                plain.setMessage("changed on screen")
            plain.cancel()
            self.assertFalse(plain.isShowing())
        config, = self.presented()
        self.assertEqual({key: config[key] if key in ("title", "message", "cancelable") else config[key]["text"]
                          for key in config if key != "context"},
                         {"title": "T", "message": "M", "negative_button": "No", "cancelable": False})
        self.assertEqual(len(self.dismissed), 1)

    def test_what_the_host_alert_lacks_is_refused_or_logged_not_hidden(self):
        scope, dialog_class = self.dialog_class()
        with bridge.runtime.context(scope):
            builder = dialog_class.Builder(None).setTitle("T").setPositiveButton("Delete", None)
            self.assertIs(builder.makeRed(dialog_class.BUTTON_POSITIVE), builder)
            builder.create().redPositive()
            for hint in (lambda: builder.setCustomViewOffset(8), builder.forceVerticalButtons, lambda: builder.setWidth(300),
                         builder.makeCustomMaxHeight, lambda: builder.setDimAlpha(0.5), lambda: builder.setCustomViewOffset(4)):
                self.assertIs(hint(), builder)
            with self.assertRaises(bridge.UnsupportedAPI):
                builder.setItems(["a"], [1], None)
            with self.assertRaises(bridge.UnsupportedAPI):
                builder.setMessageTextViewClickable(True)
            with self.assertRaises(bridge.UnsupportedAPI):
                builder.setView(object())
            for owner, name in ((builder, "setOnCancelListener"), (builder, "setOnBackButtonListener"), (builder, "setTopImage"),
                                (builder, "setCancelable"), (builder.create(), "getButton"), (builder.create(), "getWindow"),
                                (builder.create(), "setOnShowListener")):
                with self.subTest(name=name):
                    self.assertFalse(hasattr(owner, name))
                    with self.assertRaises(bridge.UnsupportedAPI):
                        getattr(owner, name)
        logged = self.logged()
        self.assertEqual(sum("red button styling is not rendered" in line for line in logged), 1)
        self.assertEqual(sum("is not rendered on iOS; the dialog keeps the host's layout" in line for line in logged), 5)


class PreflightTests(DialogCase):
    BODY = "    def on_plugin_load(self):\n        ctx = None\n"

    def members(self, statements, imports=IMPORTS):
        return self.blockers(imports, self.BODY + "".join("        " + line + "\n" for line in statements))

    def test_builder_chains_resolve_to_the_dialog_and_its_members(self):
        self.assertEqual(self.members([
            "builder = AlertDialog.Builder(ctx)",
            "builder.setTitle('T').setMessage('M').setPositiveButton('OK', None)",
            "dialog = builder.create()",
            "dialog.setCanceledOnTouchOutside(False)",
            "dialog.show()",
            "AlertDialog.Builder(ctx, None).setItems(['a'], None).show().dismiss()",
            "plain = AlertDialog(ctx, 0)",
            "plain.setMessage('M')",
        ]), [])
        self.assertEqual(self.members([
            "dialog = AlertDialog.Builder(ctx).setTitle('T').create()",
            "dialog.getButton(AlertDialog.BUTTON_POSITIVE)",
            "AlertDialog.Builder(ctx).setOnCancelListener(None)",
            "AlertDialog.Builder(ctx).show().getWindow()",
        ]), [("MEMBER", DIALOG + "$Builder.setOnCancelListener"), ("MEMBER", DIALOG + ".getButton"),
             ("MEMBER", DIALOG + ".getWindow")])

    def test_a_literal_progress_style_is_a_missing_constructor(self):
        self.assertEqual(self.members(["AlertDialog(ctx, 1).show()"]), [("MEMBER", DIALOG + ".<init>")])
        self.assertEqual(self.members(["AlertDialog.Builder(ctx, 4, None)"]), [("MEMBER", DIALOG + "$Builder.<init>")])
        self.assertEqual(self.members(["AlertDialog(ctx, 3).show()", "AlertDialog(ctx, 2, None)", "AlertDialog.Builder(ctx, 3, None)"]), [])
        self.assertEqual(self.members(["style = 0", "AlertDialog(ctx, style)", "AlertDialog.Builder(ctx, 0, None)"]), [])

    def test_the_sdk_builders_progress_styles_are_provided(self):
        found = self.members(["AlertDialogBuilder(ctx, AlertDialogBuilder.ALERT_TYPE_SPINNER)",
                              "AlertDialogBuilder(ctx, AlertDialogBuilder.ALERT_TYPE_MESSAGE)"],
                             "from ui.alert import AlertDialogBuilder\n")
        self.assertEqual(found, [])

    def test_without_the_presentation_operation_the_builder_is_gated(self):
        self.operations(remove=["ui.present"])
        self.assertEqual(self.members(["AlertDialog.Builder(ctx).show()"]), [("OPERATION", "ui.present (" + DIALOG + ".Builder)")])
        scope = self.load(imports=IMPORTS)
        with bridge.runtime.context(scope):
            # The host's adapter answers: it has neither a constructor nor the nested class.
            self.assertIs(type(scope.module.AlertDialog), bridge.JavaClass)
            with self.assertRaises(bridge.UnsupportedAPI):
                bridge.runtime.jclass(DIALOG + "$Builder")


if __name__ == "__main__":
    unittest.main()
