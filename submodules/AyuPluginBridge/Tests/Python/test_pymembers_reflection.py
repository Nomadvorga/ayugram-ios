"""``java.lang.Class`` lookups and ``java.lang.reflect`` over Python-local classes and host classes.

The host is synthetic and plugin sources are test-authored.
"""
from __future__ import annotations

import unittest

from pymembers_fixtures import CONTEXT, HostCase, entry
import ayu_bridge as bridge
from _ayu_javalib import android_graphics, java_lang, java_reflect

WIDGET = "org.sample.Widget"
BARE = "org.sample.Bare"
CLASS = "java.lang.Class"
HOST_CLASS_METHODS = ["forName", "getName", "getSimpleName", "getPackageName", "isPrimitive", "isArray", "isInterface",
                      "isEnum", "getComponentType", "getDeclaredMethod", "getDeclaredMethods"]


class ReflectionCase(HostCase):
    """A host with ``java.lang.Class``, one class with a member table and one without.

    As the Swift host does, a class object is a reference whose ``$class`` is the class it
    stands for; it answers the reflection methods, an instance does not.
    """

    def setUp(self):
        super().setUp()
        self.fields = {"width": 4, "COUNT": 2}

        def for_name(target, args):
            if len(args) != 1 or args[0] not in self.host.capabilities["classes"]:
                raise bridge.UnsupportedAPI(str(args[0]))
            return {"$handle": "class:" + args[0], "$class": args[0]}

        self.declare(CLASS, {"forName": for_name}, entry(static_methods=HOST_CLASS_METHODS))
        self.declare(WIDGET, {
            "width": lambda target, args: None, "COUNT": 0,
            "area": lambda target, args: self.fields["width"] * args[0],
            "create": lambda target, args: {"$handle": "widget", "$class": WIDGET},
            "getClass": lambda target, args: {"$handle": "class:" + WIDGET, "$class": WIDGET},
            "getDeclaredMethod": lambda target, args: {"$handle": "method:" + args[0], "$class": WIDGET},
        }, entry(fields=["width"], methods=["getClass", "area"], static_fields=["COUNT"],
                 static_methods=["create"] + HOST_CLASS_METHODS[1:], results={"create": WIDGET}))
        self.script[WIDGET]["width"] = self.fields["width"]
        self.script[WIDGET]["COUNT"] = self.fields["COUNT"]
        self.declare(BARE)
        self.declare(CONTEXT, table=entry(methods=["getClass"]))
        perform = self.host.perform

        def classes(request):
            operation, arguments = request["operation"], request["arguments"]
            target = arguments.get("target") if isinstance(arguments, dict) else None
            is_class = isinstance(target, dict) and str(target.get("$handle", "")).startswith("class:")
            if operation == "java.member" and arguments["name"] == "isPrimitive" and "$handle" in target:
                if not is_class:
                    raise bridge.UnsupportedAPI("No such member")
                return {"kind": "method"}
            if operation == "java.set_field":
                self.fields[arguments["name"]] = arguments["value"]
                return None
            return perform(request)

        self.host.perform = classes

    def plugin(self):
        scope = self.load(imports="from java import jclass\n")
        return scope, bridge.runtime.jclass


class LocalMirrorTests(ReflectionCase):
    def test_fields_of_a_local_class_are_found_read_and_written(self):
        scope, jclass = self.plugin()
        with bridge.runtime.context(scope):
            mirror = android_graphics.Point.getClass()
            field = mirror.getDeclaredField("x")
            self.assertIs(type(field), java_reflect.Field)
            self.assertEqual((field.getName(), field.getDeclaringClass(), field.getModifiers()), ("x", mirror, 1))
            self.assertEqual(field, mirror.getField("x"))
            self.assertEqual(field.toString(), "public android.graphics.Point.x")
            point = android_graphics.Point(3, 4)
            self.assertFalse(field.isAccessible())
            field.setAccessible(True)
            self.assertTrue(field.isAccessible())
            self.assertEqual((field.get(point), field.getInt(point)), (3, 3))
            field.set(point, 9)
            self.assertEqual(point.x, 9)
            with self.assertRaises(java_lang.NullPointerException):
                field.get(None)
            with self.assertRaises(java_lang.IllegalArgumentException):
                field.get("not a point")
            with self.assertRaises(java_lang.IllegalArgumentException):
                field.getBoolean(point)
            with self.assertRaises(java_lang.NoSuchFieldException) as missing:
                mirror.getDeclaredField("z")
            self.assertEqual(missing.exception.getMessage(), "z")
            self.assertEqual([item.getName() for item in mirror.getDeclaredFields()], ["x", "y"])
            constant = java_lang.Integer.getClass().getField("MAX_VALUE")
            self.assertEqual((constant.get(None), constant.getModifiers()), (2 ** 31 - 1, 1 | 8))
            self.assertTrue(java_lang.Modifier.isStatic(constant.getModifiers()))
            with self.assertRaises(bridge.UnsupportedAPI):
                java_reflect.Field()

    def test_methods_are_found_by_name_and_parameter_count_and_invoked(self):
        scope, jclass = self.plugin()
        with bridge.runtime.context(scope):
            mirror = android_graphics.Point.getClass()
            integer = java_lang.Integer.TYPE
            method = mirror.getDeclaredMethod("offset", integer, integer)
            self.assertIs(type(method), java_reflect.Method)
            self.assertEqual(method.getName(), "offset")
            self.assertEqual(method, mirror.getMethod("offset", [integer, integer]))
            point = android_graphics.Point(1, 2)
            self.assertIsNone(method.invoke(point, 10, 20))
            self.assertEqual((point.x, point.y), (11, 22))
            with self.assertRaises(java_lang.NoSuchMethodException) as missing:
                mirror.getDeclaredMethod("offset", integer)
            self.assertEqual(missing.exception.getMessage(), "android.graphics.Point.offset [int]")
            with self.assertRaises(java_lang.NoSuchMethodException) as missing:
                mirror.getMethod("explode")
            self.assertEqual(missing.exception.getMessage(), "android.graphics.Point.explode []")
            names = {item.getName() for item in mirror.getDeclaredMethods()}
            self.assertLessEqual({"set", "negate", "offset", "equals"}, names)
            # The seam's wire hook and Python's own methods are not Java members.
            self.assertFalse(names & {"to_bridge", "__init__", "__eq__"})
            # ``getMethods`` adds what the class inherits.
            inherited = {item.getName() for item in java_lang.Integer.getClass().getMethods()}
            self.assertLess({item.getName() for item in java_lang.Integer.getClass().getDeclaredMethods()}, inherited)
            parse = java_lang.Integer.getClass().getMethod("parseInt", java_lang.String.getClass())
            self.assertTrue(java_lang.Modifier.isStatic(parse.getModifiers()))
            self.assertEqual(parse.invoke(None, "42"), 42)
            # What the method throws arrives wrapped, as Java reports it.
            with self.assertRaises(java_reflect.InvocationTargetException) as thrown:
                parse.invoke(None, "forty-two")
            self.assertIsInstance(thrown.exception.getCause(), java_lang.NumberFormatException)
            self.assertIs(thrown.exception.getTargetException(), thrown.exception.getCause())

    def test_parameters_are_known_from_a_declared_signature_or_a_plain_definition(self):
        scope, jclass = self.plugin()
        with bridge.runtime.context(scope):
            mirror = android_graphics.Point.getClass()
            offset = mirror.getMethod("offset", None, None)
            self.assertEqual(offset.getParameterCount(), 2)
            # ``equals`` stands for two Java overloads, and nothing declares the types of ``offset``.
            for unknown in (mirror.getMethod("equals", None).getParameterCount, offset.getParameterTypes, offset.getReturnType):
                with self.subTest(unknown=unknown), self.assertRaises(bridge.UnsupportedAPI):
                    unknown()

            class Declared(java_lang.Object):
                def resize(self, width, height, source):
                    return None

                resize.__ayu_java_signature__ = (("int", "int", "android.graphics.Point"), "void")

            resize = java_lang.Class._of(Declared).getDeclaredMethod("resize", None, None, None)
            self.assertEqual(resize.getParameterCount(), 3)
            self.assertEqual([item.getName() for item in resize.getParameterTypes()], ["int", "int", "android.graphics.Point"])
            self.assertEqual(resize.getParameterTypes()[2], mirror)
            self.assertEqual((resize.getReturnType().getName(), resize.getReturnType().isPrimitive()), ("void", True))

    def test_primitives_have_no_members_and_a_class_is_not_its_class_object(self):
        scope, jclass = self.plugin()
        with bridge.runtime.context(scope):
            primitive = java_lang.Integer.TYPE
            self.assertEqual((primitive.getDeclaredFields(), primitive.getMethods()), ([], []))
            with self.assertRaises(java_lang.NoSuchFieldException):
                primitive.getDeclaredField("value")
            with self.assertRaises(java_lang.NoSuchMethodException):
                primitive.getMethod("intValue")
            # A local class is not its own Class object, as on Android.
            with self.assertRaises(AttributeError):
                android_graphics.Point.getDeclaredField


class HostClassTests(ReflectionCase):
    def test_for_name_finds_local_classes_and_asks_the_host_for_its_own(self):
        scope, jclass = self.plugin()
        with bridge.runtime.context(scope):
            Class = jclass(CLASS)
            self.assertIs(type(Class), bridge.JavaClass)
            local = Class.forName("android.graphics.Point")
            self.assertEqual(local, android_graphics.Point.getClass())
            host = Class.forName(WIDGET, False, None)
            self.assertIs(type(host), bridge.RemoteObject)
            self.assertEqual(self.host.requests[-1]["arguments"]["args"], [WIDGET])
            for name in ("org.sample.Missing", "int"):
                with self.subTest(name=name), self.assertRaises(java_lang.ClassNotFoundException) as missing:
                    Class.forName(name)
                self.assertEqual(missing.exception.getMessage(), name)
            with self.assertRaises(java_lang.NullPointerException):
                Class.forName(None)
            with self.assertRaises(TypeError):
                Class.forName()

    def test_fields_and_methods_of_a_host_class_come_from_its_member_table(self):
        scope, jclass = self.plugin()
        with bridge.runtime.context(scope):
            Widget = jclass(WIDGET)
            widget = Widget.create()
            for mirror in (widget.getClass(), Widget.getClass(), Widget):
                with self.subTest(mirror=mirror):
                    field = mirror.getDeclaredField("width")
                    self.assertEqual((field.getName(), field.get(widget), field.getModifiers()), ("width", 4, 1))
                    self.assertEqual(mirror.getField("COUNT").get(None), 2)
                    self.assertEqual([item.getName() for item in mirror.getFields()], ["COUNT", "width"])
                    with self.assertRaises(java_lang.NoSuchFieldException):
                        mirror.getDeclaredField("hidden")
                    area = mirror.getMethod("area", java_lang.Integer.TYPE)
                    self.assertEqual(area.invoke(widget, 5), 20)
                    self.assertEqual(mirror.getMethod("create").invoke(None)._handle, "widget")
                    # ``Class`` methods the host answers on every class object are not the class's own.
                    self.assertEqual([item.getName() for item in mirror.getMethods()], ["area", "create"])
                    with self.assertRaises(java_lang.NoSuchMethodException) as missing:
                        mirror.getMethod("explode")
                    self.assertEqual(missing.exception.getMessage(), WIDGET + ".explode []")
            field = Widget.getDeclaredField("width")
            field.set(widget, 6)
            self.assertEqual(self.fields["width"], 6)
            with self.assertRaises(java_lang.NullPointerException):
                field.get(None)
            self.assertEqual(field.getDeclaringClass()._handle, "class:" + WIDGET)
            # The host's own lookup stays the host's.
            self.assertEqual(widget.getClass().getDeclaredMethod("area")._handle, "method:area")
            # An object that is not a Class has no such member.
            self.assertFalse(hasattr(widget, "getDeclaredField"))
            with self.assertRaises(bridge.UnsupportedAPI):
                jclass(BARE).getDeclaredField("anything")
            # Members the SDK serves on a host class are part of its model.
            mode = jclass(CONTEXT).getField("MODE_PRIVATE")
            self.assertEqual((mode.get(None), java_lang.Modifier.isStatic(mode.getModifiers())), (0, True))
            self.assertEqual(jclass(CONTEXT).getMethod("getPackageName").getName(), "getPackageName")


class PreflightTests(ReflectionCase):
    IMPORTS = "from java import jclass\nfrom android.graphics import Point\nfrom android.content import Context\n"

    def found(self, *statements):
        body = "    def on_plugin_load(self, value=None):\n" + "".join("        " + line + "\n" for line in statements)
        return self.blockers(self.IMPORTS, body)

    def test_a_literal_lookup_on_a_resolved_class_is_checked_against_its_model(self):
        self.assertEqual(self.found(
            "Point.getClass().getDeclaredField('x')",
            "Point(1, 2).getClass().getDeclaredMethod('offset', None, None)",
            "Point.getClass().getName()",
            "jclass('org.sample.Widget').getClass().getDeclaredField('width')",
            "jclass('org.sample.Widget').getDeclaredField('COUNT')",
            "jclass('org.sample.Widget').create().getClass().getMethod('area')",
            "Context.getClass().getField('MODE_PRIVATE')",
        ), [])
        self.assertEqual(self.found(
            "Point.getClass().getDeclaredField('z')",
            "Point.getClass().getMethod('explode')",
            "jclass('org.sample.Widget').getClass().getDeclaredField('hidden')",
            "jclass('org.sample.Widget').create().getClass().getField('secret')",
            "Point.getClass().getDeclaredConstructors()",
        ), [("MEMBER", "android.graphics.Point.explode"), ("MEMBER", "android.graphics.Point.z"),
            ("MEMBER", "java.lang.Class.getDeclaredConstructors"),
            ("MEMBER", WIDGET + ".hidden"), ("MEMBER", WIDGET + ".secret")])

    def test_the_curated_blocker_stays_for_what_is_not_resolved(self):
        curated = [("OPERATION", "sdk.unprovided_member (getDeclaredField())")]
        self.assertEqual(self.found("value.getClass().getDeclaredField('x')"), curated)
        self.assertEqual(self.found("Point.getClass().getDeclaredField(value)"), curated)
        self.assertEqual(self.found("jclass('org.sample.Bare').getDeclaredField('x')"), curated)
        # A probe for the member itself is not a blocker, as for any other member.
        self.assertEqual(self.found("try:", "    Point.getClass().getDeclaredField('z')",
                                    "except AttributeError:", "    pass"), [])


if __name__ == "__main__":
    unittest.main()
