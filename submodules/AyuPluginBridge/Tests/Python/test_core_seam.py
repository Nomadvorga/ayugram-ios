"""Python-local Java class seam, exercised with a synthetic provider only."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

import test_bridge as fixtures
import _ayu_javalib as javalib
import ayu_bridge as bridge
import hook_utils
import jarray as jarray_module
import java

PROVIDER = '''
class Counter:
    START = 7

    class Unit:
        NAME = "unit"

    def __init__(self, value=0):
        self.value = value

    def increment(self):
        self.value += 1
        return self.value

    @staticmethod
    def of(value):
        return Counter(value)

    def to_bridge(self):
        return {"count": self.value}


class Opaque:
    pass


class Gated:
    __ayu_requires__ = ("synthetic.gated",)


class Listener:
    def run(self):
        raise NotImplementedError


class Watcher:
    def changed(self):
        raise NotImplementedError


class Shadow:
    pass


class Replacement:
    __ayu_overrides_host__ = True


class ReplacementChild(Replacement):
    pass


CLASSES = {
    "com.synthetic.Counter": Counter,
    "com.synthetic.Counter$Unit": Counter.Unit,
    "com.synthetic.Opaque": Opaque,
    "com.synthetic.Gated": Gated,
    "kotlin.synthetic.Listener": Listener,
    "dalvik.synthetic.Watcher": Watcher,
    "example.Native": Shadow,
    "example.Replaced": Replacement,
    "example.ReplacedChild": ReplacementChild,
}
'''


class ProviderSandbox:
    """Points the seam at providers written into a temporary directory."""

    def install(self, providers, listed=None):
        self.directory = tempfile.TemporaryDirectory()
        self.saved = (javalib.PROVIDER_MODULES, list(javalib.__path__))
        for name, text in providers.items():
            (Path(self.directory.name) / (name + ".py")).write_text(text, encoding="utf-8")
        javalib.__path__[:] = [self.directory.name]
        javalib.PROVIDER_MODULES = tuple(listed if listed is not None else providers)
        javalib.reset()

    def remove(self):
        javalib.PROVIDER_MODULES, javalib.__path__[:] = self.saved
        for name in [name for name in sys.modules if name.startswith("_ayu_javalib.synthetic")]:
            del sys.modules[name]
        for name in [name for name in sys.modules
                     if name.split(".")[0] in ("com", "kotlin", "dalvik", "example")
                     or name.startswith("java.") and name != "java.chaquopy"]:
            del sys.modules[name]
        javalib.reset()
        self.directory.cleanup()


class ProviderLoadingTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = ProviderSandbox()

    def tearDown(self):
        self.sandbox.remove()

    def test_fixed_provider_list_and_absent_providers_are_skipped(self):
        self.assertEqual(javalib.PROVIDER_MODULES, (
            "java_lang", "java_reflect", "java_util", "java_io", "java_nio", "java_net", "java_text", "java_time",
            "org_json", "android_os", "android_text", "android_util", "android_content", "android_graphics", "android_bitmap",
            "android_compose", "android_intents", "android_media", "android_exif", "android_view", "concurrency", "telegram_tl", "telegram_messenger", "telegram_images", "telegram_events", "telegram_ui",
            "exteragram"))
        self.sandbox.install({"synthetic_one": PROVIDER}, listed=("synthetic_absent", "synthetic_one"))
        self.assertIn("com.synthetic.Counter", javalib.local_classes())
        self.assertEqual(javalib.local_class("com.synthetic.Counter").START, 7)
        self.assertIsNone(javalib.local_class("com.synthetic.Missing"))
        self.assertNotIn("_ayu_javalib.synthetic_absent", sys.modules)

    def test_requirements_gate_advertised_names(self):
        self.sandbox.install({"synthetic_one": PROVIDER})
        self.assertNotIn("com.synthetic.Gated", javalib.local_class_names(["java.member"]))
        self.assertIn("com.synthetic.Counter", javalib.local_class_names([]))
        self.assertIn("com.synthetic.Gated", javalib.local_class_names(["synthetic.gated"]))
        self.assertIsNone(javalib.local_class("com.synthetic.Gated", []))
        self.assertIsNotNone(javalib.local_class("com.synthetic.Gated", ["synthetic.gated"]))
        self.assertEqual(javalib.missing_operations("com.synthetic.Gated", []), ("synthetic.gated",))
        self.assertIsNone(javalib.missing_operations("com.synthetic.Missing", []))

    def test_local_name_covers_classes_subclasses_and_instances(self):
        self.sandbox.install({"synthetic_one": PROVIDER})
        counter = javalib.local_class("com.synthetic.Counter")
        self.assertEqual(javalib.local_name(counter), "com.synthetic.Counter")
        self.assertEqual(javalib.local_name(type("Sub", (counter,), {})()), "com.synthetic.Counter")
        self.assertIsNone(javalib.local_name(dict))
        self.assertIsNone(javalib.local_name(3))

    def test_import_error_of_an_existing_provider_is_not_swallowed(self):
        self.sandbox.install({"synthetic_broken": "import synthetic_module_that_does_not_exist\nCLASSES = {}\n"})
        with self.assertRaises(ImportError):
            javalib.local_classes()

    def test_invalid_declarations_are_rejected(self):
        cases = {
            "no dict": "CLASSES = []\n",
            "bad name": "class A: pass\nCLASSES = {'com.synthetic.Bad-Name': A}\n",
            "leading digit": "class A: pass\nCLASSES = {'1com.A': A}\n",
            "non string": "class A: pass\nCLASSES = {7: A}\n",
            "too long": "class A: pass\nCLASSES = {'com.' + 'a' * 300: A}\n",
            "not a class": "CLASSES = {'com.synthetic.Value': object()}\n",
            "requires string": "class A:\n    __ayu_requires__ = 'java.member'\nCLASSES = {'com.synthetic.A': A}\n",
            "requires item": "class A:\n    __ayu_requires__ = (1,)\nCLASSES = {'com.synthetic.A': A}\n",
            "nested": "class A: pass\nclass B: pass\nCLASSES = {'com.synthetic.A': A, 'com.synthetic.A$B': B}\n",
        }
        for index, (label, text) in enumerate(cases.items()):
            with self.subTest(label):
                self.sandbox.install({f"synthetic_case{index}": text})
                with self.assertRaises(javalib.ProviderError):
                    javalib.local_classes()
                self.sandbox.remove()
        self.sandbox.install({})

    def test_duplicate_names_across_providers_are_rejected(self):
        self.sandbox.install({"synthetic_one": "class A: pass\nCLASSES = {'com.synthetic.A': A}\n",
                              "synthetic_two": "class A: pass\nCLASSES = {'com.synthetic.A': A}\n"})
        with self.assertRaises(javalib.ProviderError):
            javalib.local_classes()


class SeamTests(unittest.TestCase):
    load = fixtures.BridgeTests.load

    def setUp(self):
        fixtures.BridgeTests.setUp(self)
        self.sandbox = ProviderSandbox()
        self.sandbox.install({"synthetic_one": PROVIDER})

    def tearDown(self):
        fixtures.BridgeTests.tearDown(self)
        self.sandbox.remove()

    def blockers(self, text):
        return {(item["code"], item["detail"]) for item in json.loads(bridge.preflight_plugin_json(text))["blockers"]}

    def test_preflight_counts_usable_local_classes_as_declared(self):
        text = fixtures.source(imports=(
            "from com.synthetic import Counter, Gated, Absent\n"
            "from kotlin.synthetic import Listener\n"
            "from java import jclass\n"
            "from hook_utils import find_class\n"
            "A = jclass('com.synthetic.Opaque')\nB = find_class('com.synthetic.Counter$Unit')\n"))
        self.assertEqual(self.blockers(text), {("CLASS", "com.synthetic.Gated"), ("CLASS", "com.synthetic.Absent")})
        self.host.capabilities["operations"].append("synthetic.gated")
        self.assertEqual(self.blockers(text), {("CLASS", "com.synthetic.Absent")})
        # The host's own declaration is never rewritten.
        self.assertNotIn("com.synthetic.Counter", self.host.capabilities["classes"])

    def test_package_without_any_declared_class_is_a_dependency_blocker(self):
        self.assertEqual(self.blockers(fixtures.source(imports="import dalvik.absent\nimport de.absent.deep\n")),
                         {("DEPENDENCY", "dalvik.absent"), ("DEPENDENCY", "de.absent.deep")})
        self.assertEqual(self.blockers(fixtures.source(imports="import dalvik.synthetic\nimport com.synthetic\n")),
                         set())

    def test_attribute_of_an_imported_package_is_checked_as_a_class(self):
        text = fixtures.source(imports="import com.synthetic\nA = com.synthetic.Counter\nB = com.synthetic.Absent\n")
        self.assertEqual(self.blockers(text), {("CLASS", "com.synthetic.Absent")})

    def test_plugin_imports_and_uses_local_classes(self):
        scope = self.load(imports=(
            "from com.synthetic import Counter\n"
            "from kotlin.synthetic import Listener\n"
            "import dalvik.synthetic\n"
            "from java import jclass\n"
            "from hook_utils import find_class\n"
            "counter = Counter.of(Counter.START)\ncounter.increment()\n"
            "unit = find_class('com.synthetic.Counter$Unit')\n"
            "same = jclass('com.synthetic.Counter') is Counter\n"
            "watcher = dalvik.synthetic.Watcher\n"))
        module = scope.module
        self.assertEqual(module.counter.value, 8)
        self.assertTrue(module.same)
        self.assertIs(module.unit, module.Counter.Unit)
        self.assertEqual(module.unit.NAME, "unit")
        self.assertIs(module.watcher, javalib.local_class("dalvik.synthetic.Watcher"))
        authorize = next(item for item in self.host.requests if item["operation"] == "plugin.authorize")
        self.assertEqual(authorize["arguments"]["classes"], [])

    def test_host_declared_class_wins_over_local(self):
        scope = self.load(imports="from java import jclass\nNative = jclass('example.Native')\n")
        self.assertIsInstance(scope.module.Native, bridge.JavaClass)
        self.assertNotIn("example.Native", bridge.runtime.capabilities["local_classes"])
        authorize = next(item for item in self.host.requests if item["operation"] == "plugin.authorize")
        self.assertEqual(authorize["arguments"]["classes"], ["example.Native"])

    def test_local_class_that_overrides_the_host_wins_and_is_not_authorized(self):
        self.host.capabilities["classes"] += ["example.Replaced", "example.ReplacedChild"]
        scope = self.load(imports="from java import jclass\nReplaced = jclass('example.Replaced')\n"
                                  "Child = jclass('example.ReplacedChild')\n")
        self.assertIs(scope.module.Replaced, javalib.local_class("example.Replaced"))
        self.assertIn("example.Replaced", bridge.runtime.capabilities["local_classes"])
        # The override is read from the class's own body, so the subclass stays shadowed.
        self.assertIsInstance(scope.module.Child, bridge.JavaClass)
        authorize = next(item for item in self.host.requests if item["operation"] == "plugin.authorize")
        self.assertEqual(authorize["arguments"]["classes"], ["example.ReplacedChild"])

    def test_override_flag_must_be_a_boolean(self):
        self.sandbox.remove()
        self.sandbox.install({"synthetic_bad": "class Bad:\n    __ayu_overrides_host__ = 1\n\n"
                                               "CLASSES = {'example.Bad': Bad}\n"})
        with self.assertRaises(javalib.ProviderError):
            javalib.local_classes()

    def test_gated_class_is_rejected_at_load_and_at_lookup(self):
        with self.assertRaises(bridge.BridgeError) as caught:
            self.load(imports="from com.synthetic import Gated\n")
        self.assertEqual(caught.exception.code, "LOAD_REJECTED")
        scope = self.load("second")
        with bridge.runtime.context(scope):
            with self.assertRaises(bridge.UnsupportedAPI) as caught:
                java.jclass("com.synthetic.Gated")
            self.assertIn("synthetic.gated", caught.exception.message)
            with self.assertRaises(bridge.UnsupportedAPI):
                java.jclass("com.synthetic.Absent")
            with self.assertRaises(bridge.UnsupportedAPI):
                hook_utils.find_class("com.synthetic.Gated")

    def test_undeclared_package_under_a_new_root_is_rejected(self):
        with self.assertRaises(bridge.BridgeError) as caught:
            self.load(imports="from dalvik.system import InMemoryDexClassLoader\n")
        self.assertEqual(caught.exception.code, "LOAD_REJECTED")
        scope = self.load("second")
        with bridge.runtime.context(scope):
            with self.assertRaises(bridge.UnsupportedAPI):
                __import__("de.absent")

    def test_local_values_cross_to_the_host_only_through_to_bridge(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            counter = java.jclass("com.synthetic.Counter")
            native = java.jclass("example.Native")
            self.assertEqual(native.echo(counter(3)), {"count": 3})
            with self.assertRaises(bridge.UnsupportedAPI):
                native.echo(java.jclass("com.synthetic.Opaque")())
            callbacks = len(scope.callbacks)
            with self.assertRaises(bridge.UnsupportedAPI):
                native.echo(counter)
            self.assertEqual(len(scope.callbacks), callbacks)

    def test_host_references_must_name_host_classes(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            with self.assertRaises(bridge.ProtocolError):
                bridge.runtime.decode({"$handle": "h", "$class": "com.synthetic.Counter"})
            self.assertIs(bridge.runtime.decode({"$java_class": "com.synthetic.Counter"}),
                          javalib.local_class("com.synthetic.Counter"))

    def test_dynamic_proxy_cast_and_arrays_with_local_classes(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            listener = java.jclass("kotlin.synthetic.Listener")
            watcher = java.jclass("dalvik.synthetic.Watcher")
            counter = java.jclass("com.synthetic.Counter")
            base = java.dynamic_proxy(listener, watcher)
            self.assertTrue(issubclass(base, listener) and issubclass(base, watcher))

            class Both(base):
                def run(self):
                    return "ran"

            self.assertEqual(Both().run(), "ran")
            with self.assertRaises(bridge.UnsupportedAPI):
                java.dynamic_proxy(listener, java.jclass("example.Listener"))
            with self.assertRaises(bridge.UnsupportedAPI):
                java.jclass("example.Native").echo(Both())

            value = counter(1)
            self.assertIs(java.cast(counter, value), value)
            self.assertIs(java.cast("com.synthetic.Counter", value), value)
            self.assertIsNone(java.cast(counter, None))
            with self.assertRaises(TypeError):
                java.cast(counter, Both())
            remote = java.jclass("example.Native")()
            with self.assertRaises(bridge.UnsupportedAPI):
                java.cast(counter, remote)

            array = java.jarray(counter)([value, None])
            self.assertEqual((len(array), array.length, array[0]), (2, 2, value))
            array[1] = counter(5)
            with self.assertRaises(TypeError):
                array[0] = Both()
            with self.assertRaises(TypeError):
                array.append(value)
            with self.assertRaises(TypeError):
                java.jarray(counter)([object()])
            self.assertEqual(java.jarray(counter)(3), [None, None, None])
            self.assertEqual(java.jclass("example.Native").echo(array), [{"count": 1}, {"count": 5}])

    def test_array_signatures_and_typecodes(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            self.assertEqual(len(java.jarray("I")([1, 2, 3])), 3)
            self.assertEqual(len(jarray_module.zeros(4, "b")), 4)
            self.assertEqual(len(jarray_module.array([1.5], "f")), 1)
            self.assertEqual(len(java.jarray("Lcom/synthetic/Counter;")(2)), 2)
            for bad in ("Q", "Lcom/synthetic/Absent;"):
                with self.assertRaises(bridge.UnsupportedAPI):
                    java.jarray(bad)
            with self.assertRaises(bridge.UnsupportedAPI):
                jarray_module.zeros(1, "q")

    def test_capability_change_is_detected_while_plugins_are_active(self):
        self.load()
        self.host.capabilities["operations"].append("synthetic.gated")
        with self.assertRaises(bridge.ProtocolError):
            self.load("second")
        bridge.unload_plugin("sample")
        self.load("second", imports="from com.synthetic import Gated\n")
        self.assertIn("com.synthetic.Gated", bridge.runtime.capabilities["local_classes"])

    def test_unchanged_capabilities_allow_a_second_plugin(self):
        self.load(imports="from com.synthetic import Counter\n")
        self.load("second", imports="from com.synthetic import Counter\n")
        self.assertEqual(set(bridge.runtime.scopes), {"sample", "second"})


if __name__ == "__main__":
    unittest.main()
