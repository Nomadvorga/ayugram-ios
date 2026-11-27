"""Android constants, nested enums and ``getClass`` of host classes, served by the SDK on a synthetic host."""
from __future__ import annotations

import unittest

from pymembers_fixtures import HostCase, entry
from test_core_seam import ProviderSandbox
import _ayu_javalib as javalib
import ayu_bridge as bridge
import java
from _ayu_javalib import android_graphics, java_io, java_lang

INTENT, VIEW, PAINT, URI = "android.content.Intent", "android.view.View", "android.graphics.Paint", "android.net.Uri"
# Android SDK values (``android.content.Intent``, ``android.view.*``, ``android.animation.ValueAnimator``, ...).
EXPECTED = {
    INTENT: {"ACTION_GET_CONTENT": "android.intent.action.GET_CONTENT", "ACTION_OPEN_DOCUMENT": "android.intent.action.OPEN_DOCUMENT",
             "ACTION_CREATE_DOCUMENT": "android.intent.action.CREATE_DOCUMENT", "ACTION_PICK": "android.intent.action.PICK",
             "ACTION_OPEN_DOCUMENT_TREE": "android.intent.action.OPEN_DOCUMENT_TREE",
             "ACTION_SEND_MULTIPLE": "android.intent.action.SEND_MULTIPLE",
             "ACTION_BATTERY_CHANGED": "android.intent.action.BATTERY_CHANGED",
             "CATEGORY_OPENABLE": "android.intent.category.OPENABLE", "EXTRA_STREAM": "android.intent.extra.STREAM",
             "EXTRA_TEXT": "android.intent.extra.TEXT", "EXTRA_TITLE": "android.intent.extra.TITLE",
             "EXTRA_MIME_TYPES": "android.intent.extra.MIME_TYPES", "EXTRA_ALLOW_MULTIPLE": "android.intent.extra.ALLOW_MULTIPLE",
             "FLAG_GRANT_READ_URI_PERMISSION": 1, "FLAG_GRANT_WRITE_URI_PERMISSION": 2,
             "FLAG_GRANT_PERSISTABLE_URI_PERMISSION": 64, "FLAG_ACTIVITY_CLEAR_TASK": 32768,
             "FLAG_ACTIVITY_CLEAR_TOP": 67108864},
    VIEW: {"OVER_SCROLL_ALWAYS": 0, "OVER_SCROLL_IF_CONTENT_SCROLLS": 1, "OVER_SCROLL_NEVER": 2, "LAYER_TYPE_NONE": 0,
           "LAYER_TYPE_SOFTWARE": 1, "LAYER_TYPE_HARDWARE": 2, "IMPORTANT_FOR_ACCESSIBILITY_NO": 2,
           "SYSTEM_UI_FLAG_LIGHT_STATUS_BAR": 8192, "SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR": 16,
           "SCROLLBARS_INSIDE_INSET": 16777216, "LAYOUT_DIRECTION_RTL": 1, "FOCUS_DOWN": 130, "FOCUS_UP": 33},
    "android.view.MotionEvent": {"ACTION_OUTSIDE": 4, "ACTION_POINTER_DOWN": 5, "ACTION_POINTER_UP": 6, "ACTION_MASK": 255,
                                 "ACTION_POINTER_INDEX_MASK": 65280, "ACTION_POINTER_INDEX_SHIFT": 8},
    "android.view.HapticFeedbackConstants": {"VIRTUAL_KEY": 1, "KEYBOARD_TAP": 3, "CONTEXT_CLICK": 6, "SEGMENT_FREQUENT_TICK": 27,
                                             "FLAG_IGNORE_VIEW_SETTING": 1, "FLAG_IGNORE_GLOBAL_SETTING": 2},
    "android.view.Gravity": {"FILL": 119, "FILL_VERTICAL": 112, "FILL_HORIZONTAL": 7},
    "android.animation.ValueAnimator": {"INFINITE": -1, "RESTART": 1, "REVERSE": 2},
    "android.graphics.drawable.GradientDrawable": {"LINEAR_GRADIENT": 0, "RADIAL_GRADIENT": 1, "SWEEP_GRADIENT": 2, "LINE": 2,
                                                   "RING": 3},
    PAINT: {"UNDERLINE_TEXT_FLAG": 8, "STRIKE_THRU_TEXT_FLAG": 16, "FAKE_BOLD_TEXT_FLAG": 32},
    "android.content.Context": {"MODE_PRIVATE": 0, "MODE_MULTI_PROCESS": 4, "MODE_APPEND": 32768},
}


class ConstantTests(HostCase):
    def test_constants_have_the_android_values_on_class_and_instance(self):
        for name in EXPECTED:
            self.declare(name)
        scope = self.load()
        with bridge.runtime.context(scope):
            for name, constants in EXPECTED.items():
                facade, instance = java.jclass(name), self.reference(name)
                self.assertIsInstance(facade, bridge.JavaClass)
                for constant, value in constants.items():
                    with self.subTest(name=name, constant=constant):
                        self.assertEqual(getattr(facade, constant), value)
                        self.assertIs(type(getattr(facade, constant)), type(value))
                        self.assertEqual(getattr(instance, constant), value)
            self.assertEqual(self.host_requests(), [])
            # A constant cannot be assigned: the write goes to the host, which refuses it.
            with self.assertRaises(bridge.BridgeError):
                java.jclass(VIEW).OVER_SCROLL_NEVER = 3

    def test_constants_the_host_declares_stay_the_hosts(self):
        self.declare(INTENT, {"ACTION_GET_CONTENT": "host value"}, entry(static_fields=["ACTION_GET_CONTENT"]))
        scope = self.load()
        with bridge.runtime.context(scope):
            self.assertEqual(java.jclass(INTENT).ACTION_GET_CONTENT, "host value")
            self.assertEqual(java.jclass(INTENT).ACTION_OPEN_DOCUMENT, "android.intent.action.OPEN_DOCUMENT")

    def test_preflight_provides_the_constants_and_nothing_else(self):
        self.declare(INTENT, table=entry(constructor=True, methods=["addCategory", "addFlags"], static_fields=["ACTION_VIEW"]))
        self.declare(VIEW, table=entry(methods=["setOverScrollMode"], static_fields=["VISIBLE"]))
        imports = "from android.content import Intent\nfrom android.view import View\n"
        body = ("    def on_plugin_load(self):\n"
                "        intent = Intent(Intent.ACTION_GET_CONTENT)\n"
                "        intent.addCategory(Intent.CATEGORY_OPENABLE)\n"
                "        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)\n"
                "        intent.setType('*/*')\n"
                "        Intent.ACTION_INVENTED\n"
                "        View.OVER_SCROLL_NEVER, View.LAYER_TYPE_HARDWARE, View.TRANSLATION_X\n")
        self.assertEqual(self.blockers(imports, body), [
            ("OPERATION", "intents.launch (android.content.Intent.setType)"),
            ("MEMBER", "android.content.Intent.ACTION_INVENTED"), ("MEMBER", "android.view.View.TRANSLATION_X")])


class NestedEnumTests(HostCase):
    def test_local_nested_enum_is_a_member_of_the_host_outer_class(self):
        self.declare(PAINT, table=entry(constructor=True, methods=["setColor"]))
        scope = self.load(imports="from android.graphics import Paint\n")
        with bridge.runtime.context(scope):
            paint = scope.module.Paint
            self.assertIsInstance(paint, bridge.JavaClass)
            align = paint.Align
            self.assertIs(align, javalib.local_class("android.graphics.Paint$Align"))
            self.assertEqual((align.CENTER.name(), align.CENTER.ordinal(), [item.name() for item in align.values()]),
                             ("CENTER", 1, ["LEFT", "CENTER", "RIGHT"]))
            self.assertEqual(self.host_requests(), [])
            # The enum is local: an adapter that does not take it is told so, not handed a guess.
            with self.assertRaises(bridge.UnsupportedAPI):
                bridge.runtime.jclass("example.Native").echo(align.CENTER)
            # An instance has no nested classes; the host answers.
            with self.assertRaises(bridge.MissingMember):
                self.reference(PAINT).Align
        body = ("    def on_plugin_load(self):\n"
                "        Paint.Align.CENTER.name()\n"
                "        Paint.Align.JUSTIFY\n"
                "        Paint.Cap\n"
                "        Paint.Invented\n")
        self.assertEqual(self.blockers("from android.graphics import Paint\n", body, "MEMBER"),
                         ["android.graphics.Paint$Align.JUSTIFY", "android.graphics.Paint.Invented"])

    def test_host_nested_class_wins(self):
        self.declare(PAINT)
        self.declare(PAINT + "$Align", {"CENTER": "host center"})
        perform = self.host.perform

        def nested(request):
            arguments = request["arguments"]
            if request["operation"] == "java.member" and arguments["name"] == "Align":
                return {"kind": "class", "class_name": PAINT + "$Align"}
            return perform(request)

        self.host.perform = nested
        scope = self.load()
        with bridge.runtime.context(scope):
            self.assertEqual(java.jclass(PAINT).Align.CENTER, "host center")


class ClassObjectTests(HostCase):
    def setUp(self):
        HostCase.setUp(self)
        self.declare("java.lang.Class", {"forName": lambda target, args: {"$handle": "class:" + args[0], "$class": "java.lang.Class"}})
        self.declare(VIEW, table=entry(methods=["getClass"], static_methods=["getName"]))

    def test_get_class_of_a_host_class_is_the_hosts_class_object(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            found = java.jclass(VIEW).getClass()
            self.assertIsInstance(found, bridge.RemoteObject)
            self.assertEqual((found._handle, found._class_name), ("class:" + VIEW, "java.lang.Class"))
            self.assertEqual(self.host_requests("java.invoke"), [("java.lang.Class", "forName")])
            # On an object the member stays the host's own.
            with self.assertRaises(bridge.MissingMember):
                self.reference(VIEW).getClass
            self.assertEqual(self.host_requests()[-1], (VIEW, "getClass"))
        # The host's Class object answers the static members of its class, reflection included.
        body = ("    def on_plugin_load(self):\n"
                "        View.getClass().getName()\n"
                "        View.getClass().getSuperclass()\n")
        self.assertEqual(self.blockers("from android.view import View\n", body), [("MEMBER", "android.view.View.getSuperclass")])

    def test_without_a_host_class_class_the_member_is_missing(self):
        self.host.capabilities["classes"].remove("java.lang.Class")
        scope = self.load()
        with bridge.runtime.context(scope), self.assertRaises(bridge.MissingMember):
            java.jclass(VIEW).getClass
        self.assertEqual(self.blockers("from android.view import View\n", "    def on_plugin_load(self):\n        View.getClass()\n"),
                         [("MEMBER", "android.view.View.getClass")])


class UriTests(HostCase):
    def test_from_file_is_the_hosts_parse_of_the_encoded_file_uri(self):
        self.declare(URI, {"parse": lambda target, args: {"$handle": args[0], "$class": URI}}, entry(methods=["getPath"], static_methods=["parse"]))
        scope = self.load(imports="from android.net import Uri\n")
        with bridge.runtime.context(scope):
            uri = scope.module.Uri
            found = uri.fromFile(java_io.File("/data/a b/\u00e9t\u00e9 (1)~#.txt"))
            self.assertEqual((found._class_name, found._handle), (URI, "file:///data/a%20b/%C3%A9t%C3%A9%20(1)~%23.txt"))
            self.assertEqual(self.host_requests("java.invoke"), [(URI, "parse")])
            with self.assertRaises(java_lang.NullPointerException):
                uri.fromFile(None)
            for arguments in ((), ("/path",), (java_io.File("/a"), 1)):
                with self.subTest(arguments=arguments), self.assertRaises(TypeError):
                    uri.fromFile(*arguments)
        body = "    def on_plugin_load(self):\n        Uri.fromFile(None).getPath()\n        Uri.fromFile(None).vanished()\n"
        self.assertEqual(self.blockers("from android.net import Uri\n", body), [("MEMBER", "android.net.Uri.vanished")])


class DeclarationTests(unittest.TestCase):
    def test_host_member_kinds_are_validated(self):
        sandbox = ProviderSandbox()
        try:
            for index, text in enumerate(("HOST_MEMBERS = {'example.Native': {'field': HostField(7)}}\n",
                                          "HOST_MEMBERS = {'example.Native': {'field': HostField(object())}}\n",
                                          "HOST_MEMBERS = {'example.Native': {'nested': type('Nested', (), {})}}\n")):
                with self.subTest(text):
                    sandbox.install({f"synthetic_kind{index}": "from _ayu_javalib import HostField\nCLASSES = {}\n" + text})
                    try:
                        with self.assertRaises(javalib.ProviderError):
                            javalib.local_classes()
                    finally:
                        sandbox.remove()
        finally:
            javalib.reset()

    def test_served_member_precedence(self):
        capabilities = {"classes": [VIEW, "java.lang.Class"], "operations": [], "local_classes": frozenset({"android.graphics.Paint$Align"}),
                        "members": {VIEW: entry(methods=["OVER_SCROLL_NEVER"], static_methods=["getClass"])}}
        self.assertEqual(javalib.served_member(capabilities, VIEW, "OVER_SCROLL_NEVER", True), ("member", 2))
        self.assertIsNone(javalib.served_member(capabilities, VIEW, "OVER_SCROLL_NEVER", False))
        self.assertIsNone(javalib.served_member(capabilities, VIEW, "getClass", True))
        self.assertIsNone(javalib.served_member(capabilities, VIEW, "getClass", False))
        self.assertIsNone(javalib.served_member(capabilities, VIEW, "absent", True))
        self.assertIsNone(javalib.served_member(capabilities, None, "OVER_SCROLL_NEVER", True))
        self.assertEqual(javalib.served_member(capabilities, PAINT, "Align", True),
                         ("class", android_graphics.CLASSES["android.graphics.Paint$Align"]))
        self.assertIsNone(javalib.served_member(capabilities, PAINT, "Align", False))
        self.assertEqual(javalib.served_member({"classes": [VIEW, "java.lang.Class"]}, VIEW, "getClass", True), ("getClass", VIEW))


if __name__ == "__main__":
    unittest.main()
