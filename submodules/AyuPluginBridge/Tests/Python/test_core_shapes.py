"""Chaquopy import shapes, host-class overrides and SDK-served host members, on synthetic sources."""
import json
import sys
import unittest

import test_bridge as fixtures
from test_core_seam import ProviderSandbox
import _ayu_javalib as javalib
import ayu_bridge as bridge
import java
from _ayu_javalib import concurrency

# Host adapters a Python-local class replaces; every other shared name stays host-first.
OVERRIDDEN = {
    "android.graphics.Color", "android.graphics.Matrix", "android.graphics.Rect", "android.graphics.RectF",
    "android.os.Bundle", "android.os.Handler", "android.os.SystemClock", "android.text.InputType",
    "java.lang.Boolean", "java.lang.Byte", "java.lang.Float", "java.lang.Integer", "java.lang.Long",
    "java.lang.Short", "java.lang.System", "java.lang.ref.WeakReference", "java.net.URL", "java.net.URLEncoder",
    "java.util.ArrayList", "java.util.Collections", "java.util.HashMap",
    "java.util.concurrent.atomic.AtomicBoolean", "java.util.concurrent.atomic.AtomicLong",
}
HOST_FIRST = {
    "java.lang.String", "java.lang.Object", "java.lang.Class", "java.lang.CharSequence", "java.lang.Runnable",
    "java.io.ByteArrayOutputStream", "java.nio.ByteBuffer", "java.util.Locale", "android.text.TextUtils",
    "android.text.SpannableString", "android.text.style.StyleSpan", "android.text.TextWatcher",
    "android.graphics.Typeface", "android.graphics.PorterDuff$Mode", "android.util.TypedValue",
}


class BridgeCase(unittest.TestCase):
    load = fixtures.BridgeTests.load
    setUp = fixtures.BridgeTests.setUp

    def tearDown(self):
        fixtures.BridgeTests.tearDown(self)
        for name in [name for name in sys.modules if name.startswith(("android.", "java.lang", "java.util"))
                     or name == "android"]:
            del sys.modules[name]

    def blockers(self, imports):
        report = json.loads(bridge.preflight_plugin_json(fixtures.source(imports=imports)))
        return [(item["code"], item["detail"]) for item in report["blockers"]]


class ImportShapeTests(BridgeCase):
    def test_chaquopy_extension_module_is_the_java_module_surface(self):
        imports = ("from java.chaquopy import dynamic_proxy, jclass as lookup\nimport java.chaquopy\n"
                   "cast = java.chaquopy.cast\n")
        self.assertEqual(self.blockers(imports), [])
        self.assertEqual(self.blockers("from java.chaquopy import absent_function\n"),
                         [("SDK_MEMBER", "java.chaquopy.absent_function")])
        module = self.load(imports=imports).module
        self.assertIs(module.dynamic_proxy, java.dynamic_proxy)
        self.assertIs(module.lookup, java.jclass)
        self.assertIs(module.cast, java.cast)
        self.assertIs(sys.modules["java.chaquopy"], java.chaquopy)
        self.assertIn("java.chaquopy", bridge.SDK_MODULES)

    def test_dex_and_subclass_functions_stay_blockers_and_fail_on_access(self):
        for name in ("unload_class_loader", "add_class_loader", "unload_classes", "static_proxy", "Override"):
            with self.subTest(name):
                self.assertEqual(self.blockers(f"from java import {name}\n"), [("SDK_MEMBER", "java." + name)])
                with self.assertRaises(bridge.UnsupportedAPI):
                    getattr(java, name)
                with self.assertRaises(bridge.UnsupportedAPI):
                    getattr(java.chaquopy, name)
        with self.assertRaises(AttributeError):
            java.no_such_function
        with self.assertRaises(bridge.BridgeError) as caught:
            self.load(imports="try:\n    from java import unload_class_loader\nexcept Exception:\n    pass\n")
        self.assertEqual(caught.exception.message, "SDK member is not implemented: java.unload_class_loader")

    def test_class_path_import_blocks_unless_a_handler_absorbs_it(self):
        reason = " (a Java class is not an importable module)"
        self.assertEqual(self.blockers("import android.graphics.PorterDuff as PorterDuff\n"),
                         [("IMPORT", "android.graphics.PorterDuff" + reason)])
        self.assertEqual(self.blockers("from android.graphics.PorterDuff import Mode\n"),
                         [("IMPORT", "android.graphics.PorterDuff.Mode" + reason)])
        unguarded = (
            "try:\n    import android.graphics.PorterDuff\nexcept ValueError:\n    pass\n",
            "try:\n    import android.graphics.PorterDuff\nexcept ImportError:\n    raise\n",
            "try:\n    def late():\n        import android.graphics.PorterDuff\nexcept Exception:\n    pass\n",
            "try:\n    pass\nexcept Exception:\n    import android.graphics.PorterDuff\n",
        )
        for imports in unguarded:
            with self.subTest(imports):
                self.assertEqual(self.blockers(imports), [("IMPORT", "android.graphics.PorterDuff" + reason)])
        with self.assertRaises(bridge.BridgeError) as caught:
            self.load(imports="import android.graphics.PorterDuff\n")
        self.assertEqual((caught.exception.code, caught.exception.message),
                         ("LOAD_REJECTED", "A Java class is not an importable module: android.graphics.PorterDuff"))

    def test_absorbed_class_path_import_takes_the_handler_as_on_android(self):
        imports = (
            "try:\n    import android.graphics.PorterDuff as PorterDuff\nexcept:\n    PorterDuff = 'absent'\n"
            "try:\n    from android.graphics.PorterDuff import Mode\nexcept ImportError:\n    Mode = 'absent'\n"
            "try:\n    try:\n        import android.graphics.Rect\n    except ValueError:\n        pass\n"
            "except (KeyError, ModuleNotFoundError) as error:\n    Rect = type(error).__name__\n"
            "from android.graphics import PorterDuff as Real\n")
        self.assertEqual(self.blockers(imports), [])
        module = self.load(imports=imports).module
        self.assertEqual((module.PorterDuff, module.Mode, module.Rect), ("absent", "absent", "ModuleNotFoundError"))
        self.assertIs(module.Real, javalib.local_class("android.graphics.PorterDuff"))

    def test_unknown_packages_and_classes_keep_their_blockers(self):
        self.assertEqual(self.blockers("try:\n    import android.absentpackage\nexcept ImportError:\n    pass\n"),
                         [("DEPENDENCY", "android.absentpackage")])
        self.assertEqual(self.blockers("try:\n    from android.absent.Thing import Inner\nexcept ImportError:\n    pass\n"),
                         [("CLASS", "android.absent.Thing.Inner")])
        self.assertEqual(self.blockers("import android.graphics\nimport java.util\nfrom java.util import ArrayList\n"), [])


class InterruptedExceptionTests(BridgeCase):
    def test_declared_by_the_thread_model_as_a_checked_java_exception(self):
        from _ayu_javalib import java_lang
        cls = javalib.local_class("java.lang.InterruptedException")
        self.assertIs(cls, concurrency.InterruptedException)
        self.assertTrue(issubclass(cls, java_lang.Exception_))
        self.assertFalse(issubclass(cls, java_lang.RuntimeException))
        self.assertEqual(self.blockers("from java.lang import InterruptedException, Thread\n"), [])
        error = cls("woken")
        self.assertEqual((error.getMessage(), error.toString()), ("woken", "java.lang.InterruptedException: woken"))

    def test_interrupt_surfaces_as_that_class_and_clears_the_flag(self):
        module = self.load(imports=(
            "from java.lang import InterruptedException, Thread\n"
            "from java.util.concurrent import CountDownLatch, Semaphore\n")).module
        self.assertIs(module.InterruptedException, concurrency.InterruptedException)
        scope = bridge.runtime.scopes["sample"]
        with bridge.runtime.context(scope):
            outcomes = []
            for blocked in (lambda: module.Thread.sleep(10_000), lambda: module.CountDownLatch(1).await_(),
                            lambda: module.Semaphore(0).acquire()):
                module.Thread.currentThread().interrupt()
                self.assertTrue(module.Thread.currentThread().isInterrupted())
                with self.assertRaises(module.InterruptedException):
                    blocked()
                outcomes.append(module.Thread.currentThread().isInterrupted())
            self.assertEqual(outcomes, [False, False, False])


class HostOverrideTests(BridgeCase):
    def setUp(self):
        BridgeCase.setUp(self)
        self.host.capabilities["classes"] += sorted(OVERRIDDEN | HOST_FIRST) + ["int"]

    def test_exactly_the_audited_adapters_are_overridden(self):
        audited = {name for name, cls in javalib.local_classes().items()
                   if cls.__module__.rpartition(".")[2].startswith(("java_", "android_", "org_json", "concurrency"))}
        self.assertEqual(javalib.host_override_names(fixtures.OPERATIONS) & audited, OVERRIDDEN)
        self.assertTrue(HOST_FIRST <= audited)
        scope = self.load(imports="from java import jclass\n" + "".join(
            f"C{index} = jclass({name!r})\n" for index, name in enumerate(sorted(OVERRIDDEN | HOST_FIRST))))
        for index, name in enumerate(sorted(OVERRIDDEN | HOST_FIRST)):
            resolved = getattr(scope.module, f"C{index}")
            with self.subTest(name):
                if name in OVERRIDDEN:
                    self.assertIs(resolved, javalib.local_class(name))
                else:
                    self.assertIsInstance(resolved, bridge.JavaClass)
        authorize = next(item for item in self.host.requests if item["operation"] == "plugin.authorize")
        self.assertEqual(authorize["arguments"]["classes"], sorted(HOST_FIRST))

    def test_overriding_values_reach_the_host_in_wire_form(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            native = java.jclass("example.Native")
            cls = java.jclass
            array_list = cls("java.util.ArrayList")([1, "two"])
            array_list.add(cls("java.lang.Integer").valueOf(3))
            mapping = cls("java.util.HashMap")()
            mapping.put("list", array_list)
            mapping.put("flag", cls("java.lang.Boolean").valueOf(True))
            self.assertEqual(native.echo(mapping), {"list": [1, "two", 3], "flag": True})
            self.assertEqual(native.echo(cls("java.lang.Long")(2 ** 40)), 2 ** 40)
            self.assertEqual(native.echo(cls("java.lang.Float")(1.5)), 1.5)
            self.assertEqual(native.echo(cls("java.net.URL")("https://example.invalid/a?b=1")), "https://example.invalid/a?b=1")
            self.assertEqual(native.echo(cls("android.graphics.Rect")(1, 2, 3, 4)),
                             {"left": 1, "top": 2, "right": 3, "bottom": 4})
            self.assertEqual(native.echo(cls("android.graphics.Color").parseColor("#FF0000")), -65536)
            self.assertEqual(native.echo(cls("java.util.Collections").singletonList("one")), ["one"])
            bundle = cls("android.os.Bundle")()
            bundle.putString("key", "value")
            self.assertEqual(native.echo(bundle), {"key": "value"})
            keyed = cls("java.util.HashMap")()
            keyed.put(1, "one")
            with self.assertRaises(bridge.ProtocolError):
                native.echo(keyed)
            for opaque in (cls("java.util.concurrent.atomic.AtomicLong")(1), cls("android.graphics.Matrix")(),
                           cls("java.lang.ref.WeakReference")(None)):
                with self.assertRaises(bridge.UnsupportedAPI):
                    native.echo(opaque)

    def test_host_instances_and_class_references_of_overridden_names_stay_usable(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            array_list, integer = java.jclass("java.util.ArrayList"), java.jclass("java.lang.Integer")
            remote = bridge.runtime.decode({"$handle": "host-list", "$class": "java.util.ArrayList"})
            self.assertIsInstance(remote, bridge.RemoteObject)
            self.assertEqual(remote.answer, 42)
            self.assertEqual(java.cast(array_list, remote)._handle, "host-list")
            self.assertEqual(self.host.requests[-1]["arguments"]["class_name"], "java.util.ArrayList")
            with self.assertRaises(TypeError):
                java.cast(array_list, object())
            # The class itself still names the host's declaration, e.g. as an array component type.
            native = java.jclass("example.Native")
            self.assertIs(native.echo(integer), integer)
            self.assertEqual(self.host.requests[-1]["arguments"]["args"], [{"$java_class": "java.lang.Integer"}])
            self.assertIsInstance(integer.TYPE, bridge.JavaClass)
            self.assertEqual(integer.TYPE._name, "int")

            class Narrow(integer):
                pass

            with self.assertRaises(bridge.UnsupportedAPI):
                native.echo(Narrow)


class HostMemberTests(BridgeCase):
    def setUp(self):
        BridgeCase.setUp(self)
        self.host.capabilities["classes"].append("android.content.Context")

    def context(self):
        return bridge.runtime.decode({"$handle": "context", "$class": "android.content.Context"})

    def members(self):
        return [item["arguments"]["name"] for item in self.host.requests if item["operation"] == "java.member"]

    def test_context_hands_out_the_local_clipboard_manager(self):
        scope = self.load(imports="from android.content import Context, ClipboardManager, ClipData\n")
        module = scope.module
        with bridge.runtime.context(scope):
            context = self.context()
            self.assertEqual((module.Context.CLIPBOARD_SERVICE, context.CLIPBOARD_SERVICE, context.WINDOW_SERVICE),
                             ("clipboard", "clipboard", "window"))
            manager = context.getSystemService(module.Context.CLIPBOARD_SERVICE)
            self.assertIsInstance(manager, module.ClipboardManager)
            self.assertIs(module.ClipboardManager, javalib.local_class("android.content.ClipboardManager"))
            for service in ("window", "audio", module.Context.ACTIVITY_SERVICE):
                with self.subTest(service), self.assertRaises(bridge.UnsupportedAPI):
                    context.getSystemService(service)
            for arguments in ((), (None,), ("clipboard", 1), (module.ClipboardManager,)):
                with self.subTest(arguments=arguments), self.assertRaises(bridge.UnsupportedAPI):
                    context.getSystemService(*arguments)
            self.assertEqual(self.members(), [])
            # Every other member is still the host's.
            self.assertEqual(context.answer, 42)
            self.assertEqual(self.members(), ["answer"])

    def test_clipboard_service_needs_the_host_clipboard_route(self):
        self.host.capabilities["operations"].remove("client.call")
        scope = self.load()
        with bridge.runtime.context(scope):
            with self.assertRaises(bridge.UnsupportedAPI) as caught:
                self.context().getSystemService("clipboard")
            self.assertIn("client.call", caught.exception.message)

    def test_invalid_host_member_declarations_are_provider_errors(self):
        sandbox = ProviderSandbox()
        cases = ("HOST_MEMBERS = []\n", "HOST_MEMBERS = {'bad-name': {}}\n", "HOST_MEMBERS = {'example.Native': []}\n",
                 "HOST_MEMBERS = {'example.Native': {'_hidden': 1}}\n", "HOST_MEMBERS = {'example.Native': {'value': object()}}\n")
        try:
            for index, text in enumerate(cases):
                with self.subTest(text):
                    sandbox.install({f"synthetic_member{index}": "CLASSES = {}\n" + text})
                    with self.assertRaises(javalib.ProviderError):
                        javalib.local_classes()
                    sandbox.remove()
            sandbox.install({"synthetic_one": "CLASSES = {}\nHOST_MEMBERS = {'example.Native': {'served': 7}}\n",
                             "synthetic_two": "CLASSES = {}\nHOST_MEMBERS = {'example.Native': {'served': 8}}\n"})
            with self.assertRaises(javalib.ProviderError):
                javalib.local_classes()
            sandbox.remove()
            sandbox.install({"synthetic_one": "def twice(value):\n    return value * 2\n\nCLASSES = {}\n"
                                              "HOST_MEMBERS = {'example.Native': {'served': 7, 'twice': twice}}\n"})
            scope = self.load()
            with bridge.runtime.context(scope):
                native = java.jclass("example.Native")
                self.assertEqual((native.served, native().served, native().twice(4), native.answer), (7, 7, 8, 42))
        finally:
            sandbox.remove()


if __name__ == "__main__":
    unittest.main()
