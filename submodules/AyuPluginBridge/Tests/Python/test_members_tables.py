"""Member tables: the host's published table and what Python-local classes provide.

Providers here are synthetic; no plugin is read or executed.
"""
import unittest

import test_bridge  # noqa: F401  (puts the SDK on sys.path)
import _ayu_javalib as javalib
import _ayu_members as members
from test_core_seam import ProviderSandbox

PROVIDER = '''
class Unsupported(RuntimeError, AttributeError):
    pass


class IllegalStateException(RuntimeError):
    pass


def unsupported(message):
    return Unsupported(message)


class Hidden:
    def __init__(self, name):
        self.name = name

    def __get__(self, instance, owner):
        raise unsupported(self.name)


class Meta(type):
    def __getattr__(cls, name):
        raise unsupported(name)

    @property
    def current(cls):
        return cls()


class Base(metaclass=Meta):
    LIMIT = 7

    def __init__(self):
        self.width = 0
        self.__dict__["height"] = 0
        values = self.__dict__
        values["depth"], self._private = 0, None

    def __getattr__(self, name):
        raise unsupported(name)

    def size(self):
        return self.width

    def legacy(self):
        return 1

    def unfinished(self):
        """Declared for completeness."""
        raise unsupported("Base.unfinished")

    def abstract(self):
        raise NotImplementedError

    def closed(self):
        raise IllegalStateException("always closed, as on Android")

    def partial(self, value):
        if value is None:
            raise unsupported("Base.partial(null)")
        return value

    def _fail(self, *args):
        raise unsupported("alias")

    aliasOne = aliasTwo = _fail

    @staticmethod
    def create():
        return Base()

    @staticmethod
    def broken():
        raise unsupported("Base.broken")

    @classmethod
    def make(cls):
        return cls()

    def chain(self):
        self.width += 1
        return self

    def other(self):
        result = Other()
        return result

    def either(self, flag):
        return Other() if flag else Base()

    def maybe(self, flag):
        if flag:
            return None
        return Other()

    @property
    def area(self):
        return self.width * self.height


class Child(Base):
    legacy = Hidden("legacy")

    def unfinished(self):
        return 2

    class Kind:
        FIRST = 1


class Other(metaclass=Meta):
    DEFAULT = Base()

    def __init__(self):
        raise unsupported("Other cannot be constructed")


class Open(metaclass=Meta):
    def __getattr__(self, name):
        if name.startswith("dyn"):
            return name
        raise unsupported(name)

    def fill(self, source):
        self.__dict__.update(source)


class Strict(metaclass=Meta):
    def __init__(self):
        self.value = 0

    def __setattr__(self, name, value):
        if name != "value":
            raise AttributeError(name)
        object.__setattr__(self, name, value)


CLASSES = {
    "com.synthetic.Base": Base, "com.synthetic.Child": Child, "com.synthetic.Child$Kind": Child.Kind,
    "com.synthetic.Other": Other, "com.synthetic.Open": Open, "com.synthetic.Strict": Strict,
}
'''

ENTRY = {"constructor": True, "methods": ["show"], "fields": ["width"], "writable_fields": ["width"],
         "static_methods": ["of"], "static_fields": ["LIMIT"], "results": {"of": "example.View"}}


class HostTableValidationTests(unittest.TestCase):
    def table(self, **changes):
        return {"version": 1, "classes": {"example.View": dict(ENTRY, **changes)}}

    def test_valid_table_is_returned_by_class(self):
        self.assertEqual(members.validate(self.table(), ["example.View"]), {"example.View": ENTRY})
        self.assertEqual(members.validate({"version": 1, "classes": {}}, []), {})

    def test_newer_version_is_ignored_as_a_whole(self):
        self.assertIsNone(members.validate({"version": 2, "classes": "anything", "extra": 1}, []))

    def test_malformed_tables_are_rejected(self):
        invalid = [
            None, [], {"classes": {}}, {"version": "1", "classes": {}}, {"version": 0, "classes": {}},
            {"version": True, "classes": {}}, {"version": 1}, {"version": 1, "classes": [], },
            {"version": 1, "classes": {}, "extra": 1},
            {"version": 1, "classes": {"example.Unknown": ENTRY}},
            self.table(constructor=1), self.table(methods="show"), self.table(methods=["show", "show"]),
            self.table(methods=["_private"]), self.table(methods=["a b"]), self.table(methods=[7]),
            self.table(methods=["x" * 129]), self.table(methods=["имя"]), self.table(writable_fields=["height"]),
            self.table(results={"absent": "example.View"}), self.table(results={"of": "example.Unknown"}),
            self.table(results=["of"]), self.table(results={"of": 3}),
            {"version": 1, "classes": {"example.View": {key: value for key, value in ENTRY.items() if key != "fields"}}},
            {"version": 1, "classes": {"example.View": dict(ENTRY, more=[])}},
        ]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                members.validate(value, ["example.View"])
        with self.assertRaises(ValueError):
            members.validate(self.table(methods=["m%d" % index for index in range(members.MAX_NAMES + 1)]),
                             ["example.View"])


class LocalTableTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = ProviderSandbox()
        self.sandbox.install({"synthetic_members": PROVIDER})
        self.addCleanup(self.sandbox.remove)
        self.tables = members.Tables({"classes": ["example.Host"], "local_classes": javalib.local_class_names([])})
        self.base = self.tables.named("com.synthetic.Base")
        self.child = self.tables.named("com.synthetic.Child")

    def provided(self, reference, member, static=False, store=False):
        return self.tables.access(reference, member, static, store)[0]

    def test_implemented_members_and_fields_are_provided(self):
        for member in ("size", "partial", "create", "make", "chain", "LIMIT", "area", "closed"):
            self.assertIs(self.provided(self.base, member), True, member)
        for member in ("width", "height", "depth"):
            self.assertIs(self.provided(self.base, member), True, member)
            self.assertIs(self.provided(self.base, member, static=True), False, member)
        for member in ("create", "make", "LIMIT", "size", "current"):
            self.assertIs(self.provided(self.base, member, static=True), True, member)

    def test_members_that_only_raise_are_not_provided(self):
        for member in ("unfinished", "abstract", "aliasOne", "aliasTwo", "broken", "absent"):
            self.assertIs(self.provided(self.base, member), False, member)
            self.assertIs(self.provided(self.base, member, static=True), False, member)
        # The name exists on the class; that alone proves nothing.
        self.assertTrue(callable(vars(self.base)["unfinished"]))

    def test_subclass_overrides_and_hidden_names(self):
        self.assertIs(self.provided(self.child, "unfinished"), True)
        self.assertIs(self.provided(self.child, "legacy"), False)
        self.assertIs(self.provided(self.base, "legacy"), True)
        self.assertIs(self.provided(self.child, "width"), True)

    def test_private_names_are_never_members(self):
        table = members.local(self.base)
        self.assertFalse([name for name in table.instance if name.startswith("_")])

    def test_constructor_availability(self):
        self.assertIs(self.tables.construct(self.base), True)
        self.assertIs(self.tables.construct(self.tables.named("com.synthetic.Other")), False)

    def test_dynamic_attribute_hooks_leave_other_names_unknown(self):
        reference = self.tables.named("com.synthetic.Open")
        self.assertIs(self.provided(reference, "fill"), True)
        self.assertIsNone(self.provided(reference, "dynamic"))
        self.assertIs(self.provided(reference, "dynamic", static=True), False)

    def test_writes(self):
        strict = self.tables.named("com.synthetic.Strict")
        self.assertIs(self.provided(strict, "value", store=True), True)
        self.assertIs(self.provided(strict, "other", store=True), False)
        # A plain Python class accepts any attribute.
        self.assertIs(self.provided(self.base, "anything", store=True), True)

    def test_values_and_results_name_their_class(self):
        other = self.tables.named("com.synthetic.Other")
        self.assertEqual(self.tables.access(self.child, "Kind", True),
                         (True, ("class", self.tables.named("com.synthetic.Child$Kind"))))
        self.assertEqual(self.tables.access(other, "DEFAULT", True), (True, ("instance", self.base)))
        self.assertEqual(self.tables.access(self.base, "LIMIT", True), (True, None))
        self.assertEqual(self.tables.call(self.base, "create", True), ("instance", self.base))
        self.assertEqual(self.tables.call(self.child, "make", True), ("instance", self.child))
        self.assertEqual(self.tables.call(self.child, "chain", False), ("instance", self.child))
        self.assertEqual(self.tables.call(self.base, "other", False), ("instance", other))
        for member in ("either", "maybe", "size", "partial", "absent", "broken"):
            self.assertIsNone(self.tables.call(self.base, member, False), member)
        # An instance method read from the class is not bound: its ``self`` is whatever is passed.
        self.assertIsNone(self.tables.call(self.base, "chain", True))

    def test_labels(self):
        self.assertEqual(self.tables.label(self.child), "com.synthetic.Child")
        self.assertEqual(self.tables.label("example.Host"), "example.Host")
        self.assertEqual(self.tables.named("example.Host"), "example.Host")
        self.assertIsNone(self.tables.named("example.Unknown"))


class HostTableTests(unittest.TestCase):
    def setUp(self):
        entry = dict(ENTRY, results={"of": "example.View", "LIMIT": "example.Other"})
        other = {"constructor": False, "methods": [], "fields": [], "writable_fields": [], "static_methods": [],
                 "static_fields": [], "results": {}}
        self.tables = members.Tables({
            "classes": ["example.View", "example.View$Inner", "example.Other", "example.Bare"], "local_classes": [],
            "members": {"example.View": entry, "example.Other": other}})

    def test_static_and_instance_sides_are_separate(self):
        access = self.tables.access
        self.assertEqual(access("example.View", "of", True), (True, None))
        self.assertEqual(access("example.View", "of", False), (False, None))
        self.assertEqual(access("example.View", "show", False), (True, None))
        self.assertEqual(access("example.View", "show", True), (False, None))
        self.assertEqual(access("example.View", "LIMIT", True), (True, ("instance", "example.Other")))
        self.assertEqual(access("example.View", "LIMIT", False), (False, None))
        self.assertEqual(access("example.View", "width", False), (True, None))

    def test_nested_class_is_a_static_member_even_without_a_table(self):
        self.assertEqual(self.tables.access("example.View", "Inner", True), (True, ("class", "example.View$Inner")))
        self.assertEqual(self.tables.access("example.View", "Inner", False), (False, None))

    def test_writes_need_a_writable_instance_field(self):
        self.assertEqual(self.tables.access("example.View", "width", False, True), (True, None))
        self.assertEqual(self.tables.access("example.View", "LIMIT", True, True), (False, None))
        self.assertEqual(self.tables.access("example.View", "show", False, True), (False, None))

    def test_class_without_a_table_is_unknown(self):
        self.assertEqual(self.tables.access("example.Bare", "anything", True), (None, None))
        self.assertEqual(self.tables.access("example.Bare", "anything", False, True), (None, None))
        self.assertIsNone(self.tables.construct("example.Bare"))
        self.assertIsNone(self.tables.call("example.Bare", "anything", True))

    def test_declared_results_and_constructors(self):
        self.assertEqual(self.tables.call("example.View", "of", True), ("instance", "example.View"))
        self.assertIsNone(self.tables.call("example.View", "of", False))
        self.assertIsNone(self.tables.call("example.View", "show", False))
        self.assertIs(self.tables.construct("example.View"), True)
        self.assertIs(self.tables.construct("example.Other"), False)


class BundledProviderTests(unittest.TestCase):
    """The bundled providers stay readable, and their tables agree with the objects they describe."""

    @classmethod
    def setUpClass(cls):
        javalib.reset()
        cls.classes = javalib.local_classes()

    def test_every_bundled_class_has_a_table_that_matches_its_objects(self):
        self.assertGreater(len(self.classes), 3000)
        for name, cls in self.classes.items():
            table = members.local(cls)
            self.assertIsNotNone(table, name)
            resolvable = {item for item in set(dir(cls)) | set(dir(type(cls))) if not item.startswith("_")}
            self.assertFalse(resolvable - set(table.values), name)
            try:
                fields = {item for item in vars(cls()) if not item.startswith("_")}
            except Exception:
                continue  # no public no-argument constructor outside a plugin
            if not table.open_instance:
                self.assertFalse(fields - table.instance, name)

    def test_known_stubs_and_constructors(self):
        tables = members.Tables({"classes": [], "local_classes": javalib.local_class_names([])})
        process = tables.named("android.os.Process")
        self.assertEqual(tables.access(process, "killProcess", True), (False, None))
        self.assertEqual(tables.access(process, "myPid", True), (True, None))
        self.assertIs(tables.construct(tables.named("java.lang.Math")), False)
        self.assertIs(tables.construct(tables.named("java.util.ArrayList")), True)
        builder = tables.named("java.lang.StringBuilder")
        self.assertEqual(tables.call(builder, "append", False), ("instance", builder))

    def test_generated_tl_fields_come_from_the_schema(self):
        tables = members.Tables({"classes": [], "local_classes": javalib.local_class_names([])})
        request = tables.named("org.telegram.tgnet.TLRPC$TL_messages_sendMessage")
        self.assertEqual(tables.access(request, "peer", False), (True, None))
        self.assertEqual(tables.access(request, "peer", False, True), (True, None))
        self.assertEqual(tables.access(request, "no_such_field", False), (False, None))
        self.assertEqual(tables.access(request, "no_such_field", False, True), (False, None))


if __name__ == "__main__":
    unittest.main()
