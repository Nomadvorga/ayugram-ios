"""Static receiver inference: which class a member access is on, decided without executing anything.

Sources are synthetic and only parsed.
"""
import ast
import textwrap
import unittest

import test_bridge  # noqa: F401  (puts the SDK on sys.path)
import _ayu_inspection as inspection
import _ayu_javalib as javalib
import _ayu_members as members
import ayu_bridge as bridge

LABEL, PANEL = "com.synthetic.widget.Label", "com.synthetic.widget.Panel"
EMPTY = {"constructor": False, "methods": [], "fields": [], "writable_fields": [], "static_methods": [],
         "static_fields": [], "results": {}}
HOST = {
    LABEL: dict(EMPTY, constructor=True, methods=["setText", "getText", "getParent"], fields=["width"],
                writable_fields=["width"], static_methods=["create"], static_fields=["CENTER"],
                results={"create": LABEL, "getParent": PANEL}),
    LABEL + "$Mode": dict(EMPTY, static_fields=["FAST"]),
    PANEL: dict(EMPTY, methods=["addView"], static_fields=["shared"], results={"shared": LABEL}),
    "org.telegram.messenger.MessagesController": dict(EMPTY, methods=["getUser"]),
}
IMPORTS = "from com.synthetic.widget import Label, Panel, Bare, Ghost\n"


class InferenceCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        javalib.reset()
        host = list(HOST) + ["com.synthetic.widget.Bare"]
        local = javalib.local_class_names([]) - set(host)
        cls.tables = members.Tables({"classes": host, "local_classes": local, "members": HOST})

    def inventory(self, source, watch=frozenset()):
        tree = ast.parse(IMPORTS + textwrap.dedent(source))
        return inspection.member_inventory(tree, bridge.SDK_MODULES, self.tables, watch)

    def missing(self, source):
        found = self.inventory(source)
        suffix = {"read": "", "write": "=", "construct": ""}
        return [item["class"].rpartition(".")[2] + "." + item["member"] + suffix[item["use"]] for item in found["missing"]]

    def assertCounts(self, source, verified, unknown, missing=()):
        found = self.inventory(source)
        names = [item["class"].rpartition(".")[2] + "." + item["member"] for item in found["missing"]]
        self.assertEqual((found["verified"], found["unknown"], names), (verified, unknown, list(missing)))


class ResolvedReceiverTests(InferenceCase):
    def test_static_members_of_an_imported_class(self):
        self.assertCounts("Label.create()\nLabel.CENTER\nLabel.absent()\nLabel.MISSING\n", 2, 0,
                          ["Label.MISSING", "Label.absent"])

    def test_instance_bound_to_a_name_within_a_function(self):
        self.assertCounts('''
            def build(context):
                label = Label(context)
                label.setText("a")
                label.setColor(1)
                return label.width
            ''', 3, 0, ["Label.setColor"])

    def test_instance_side_does_not_see_static_members_of_a_host_class(self):
        self.assertEqual(self.missing("Label(None).create()\nLabel(None).CENTER\nLabel.setText('a')\n"),
                         ["Label.CENTER", "Label.create", "Label.setText"])

    def test_classes_named_by_string(self):
        self.assertCounts('''
            import java
            import hook_utils
            from java import jclass as J
            from hook_utils import find_class
            First = J("com.synthetic.widget.Label")
            Second = java.jclass("com.synthetic.widget.Label")
            Third = find_class("com.synthetic.widget.Label")
            Fourth = hook_utils.find_class(class_name="com.synthetic.widget.Panel")
            First.create(); Second.create(); Third.create()
            First.one(); Second.two(); Third.three(); Fourth.four()
            ''', 3, 0, ["Label.one", "Label.three", "Label.two", "Panel.four"])

    def test_attribute_of_the_plugins_own_instance(self):
        self.assertCounts('''
            class Plugin:
                kind = Label

                def start(self):
                    self.label = Label(None)
                    self.loader = jclass_later()

                def stop(self):
                    self.label.setText("x")
                    self.label.vanish()
                    self.kind.create()
                    self.kind.broken()
                    self.loader.anything()
                    self.never_assigned.anything()
            ''', 3, 2, ["Label.broken", "Label.vanish"])

    def test_nested_classes(self):
        found = self.inventory("Label.Mode.FAST\nLabel.Mode.SLOW\nM = Label.Mode\nM.OTHER\n")
        self.assertEqual([(item["class"], item["member"]) for item in found["missing"]],
                         [(LABEL + "$Mode", "OTHER"), (LABEL + "$Mode", "SLOW")])
        self.assertEqual(found["verified"], 4)

    def test_chains_follow_declared_results_only(self):
        self.assertCounts('''
            Label.create().setText("x")
            Label.create().lost()
            Panel.shared.setText("x")
            Panel.shared.gone
            Label(None).getParent().addView(1)
            Label(None).getParent().missing()
            Label(None).getText().strip()
            Label(None).getParent().addView(1).more()
            ''', 16, 2, ["Label.gone", "Label.lost", "Panel.missing"])

    def test_reads_through_getattr_and_writes(self):
        self.assertEqual(self.missing('''
            label = Label(None)
            label.width = 3
            label.height = 3
            Label.CENTER = 1
            getattr(label, "setText")("x")
            getattr(label, "setFont")("x")
            Panel()
            '''), ["Label.CENTER=", "Label.height=", "Label.setFont", "Panel.<init>"])

    def test_python_local_classes(self):
        found = self.inventory('''
            from java.lang import Math, StringBuilder
            from android.os import Build, Process
            Math.max(1, 2)
            Math.imaginary(1)
            Math()
            Build.VERSION.SDK_INT
            Build.VERSION.IMAGINARY
            Process.killProcess(Process.myPid())
            text = StringBuilder().append("a").append("b")
            text.reverse()
            text.imaginary()
            ''')
        self.assertEqual([(item["class"], item["member"]) for item in found["missing"]], [
            ("android.os.Build$VERSION", "IMAGINARY"), ("android.os.Process", "killProcess"),
            ("java.lang.Math", "<init>"), ("java.lang.Math", "imaginary"), ("java.lang.StringBuilder", "imaginary")])
        self.assertEqual(found["unknown"], 0)

    def test_controller_getters_name_their_class(self):
        self.assertCounts('''
            import client_utils
            from client_utils import get_messages_controller, get_last_fragment
            get_messages_controller().getUser(1)
            client_utils.get_messages_controller().lost()
            get_last_fragment().anything()
            ''', 1, 1, ["MessagesController.lost"])
        self.assertEqual(inspection._controller_getters()["client_utils.get_messages_controller"],
                         "org.telegram.messenger.MessagesController")

    def test_bindings_that_keep_one_class(self):
        self.assertCounts('''
            label = None
            label = Label(None)
            left, right = Label(None), Panel.shared
            again = again_or = None
            again = again or Label(None)
            chosen = Label(None) if left else Label(None)

            def use():
                label.one(); left.two(); right.three(); again.four(); chosen.five()
                return [(lambda: label.six())(), [label.seven() for _ in range(2)]]
            ''', 6, 0, ["Label." + name for name in ("five", "four", "one", "seven", "six", "three", "two")])


class UnknownReceiverTests(InferenceCase):
    def assertNothingReported(self, source, unknown):
        found = self.inventory(source)
        self.assertEqual((found["missing"], found["guarded"], found["unknown"]), ([], 0, unknown))
        return found

    def test_parameters_loops_and_unknown_calls(self):
        self.assertNothingReported('''
            def handle(view, *rest, **options):
                view.absent()
                rest.absent()
                for item in view:
                    item.absent()
                with open("x") as stream:
                    stream.absent()
                made = factory()
                made.absent()
                try:
                    pass
                except Exception as error:
                    error.absent()
                return [each.absent() for each in view]
            ''', 7)

    def test_a_name_with_two_classes_or_an_unknown_binding_is_not_resolved(self):
        self.assertNothingReported('''
            mixed = Label(None)
            mixed = Panel.shared.getParent()
            mixed.absent()
            shadowed = Label(None)

            def run(shadowed, flag):
                shadowed.absent()
                rebound = Label(None)
                rebound += 1
                rebound.absent()
                first, *others = Label(None), Label(None)
                first.absent()

            def rebind():
                global target
                target = factory()

            target = Label(None)
            target.absent()
            ''', 5)

    def test_a_plugin_class_of_the_same_name_hides_the_java_class(self):
        self.assertNothingReported('''
            class Label:
                pass
            Label.absent()
            Label().absent()
            ''', 2)

    def test_attribute_assigned_through_another_receiver_is_not_certain(self):
        self.assertNothingReported('''
            class Plugin:
                def start(self):
                    self.label = Label(None)
                    self.label.absent()

            def patch(plugin):
                plugin.label = factory()
            ''', 2)

    def test_class_without_a_host_table_is_unknown_not_missing(self):
        found = self.assertNothingReported("Bare.anything()\nBare().other()\nBare.CONSTANT\n", 4)
        self.assertEqual(found["verified"], 0)

    def test_undeclared_classes_are_left_to_the_class_blocker(self):
        found = self.assertNothingReported('''
            from java import jclass
            Ghost.anything()
            Ghost(1).other().more()
            jclass("com.synthetic.widget.Phantom").anything()
            ''', 0)
        self.assertEqual(found["verified"], 0)

    def test_python_receivers_are_not_member_accesses(self):
        found = self.assertNothingReported('''
            import os
            import client_utils
            from base_plugin import BasePlugin

            class Plugin(BasePlugin):
                def run(self):
                    self.log("x")
                    os.path.join("a", "b")
                    "text".upper()
                    client_utils.get_selected_account
                    return BasePlugin.on_plugin_load
            ''', 0)
        self.assertEqual(found["unknown_java_style"], 0)

    def test_cyclic_bindings_terminate(self):
        self.assertNothingReported("first = second\nsecond = first\nfirst.absent()\nsecond.absent()\n", 2)

    def test_unknown_counts_separate_java_style_names(self):
        found = self.inventory("def run(view):\n    view.setText('a')\n    view.CONSTANT_NAME\n    view.strip()\n")
        self.assertEqual((found["unknown"], found["unknown_java_style"]), (3, 2))

    def test_watched_names_on_unknown_receivers(self):
        found = self.inventory('''
            def run(view):
                view.getWindow()
                Label(None).getDecorView()
                Label(None).setText("x")
                view.setText("x")
            ''', frozenset({"getWindow", "getDecorView", "setText", "unused"}))
        self.assertEqual(found["unresolved"], ["getWindow", "setText"])
        self.assertEqual([item["member"] for item in found["missing"]], ["getDecorView"])


class GuardedAccessTests(InferenceCase):
    def test_probes_do_not_report_a_missing_member(self):
        found = self.inventory('''
            label = Label(None)

            def first():
                if hasattr(label, "setFont"):
                    label.setFont(1)

            def second():
                setter = getattr(label, "setShadow", None)
                if setter is not None:
                    label.setShadow(1)

            def third():
                try:
                    label.setBorder(1)
                except AttributeError:
                    pass

            def fourth():
                try:
                    label.setRadius(1)
                except (TypeError, AttributeError) as error:
                    print(error)
            ''')
        self.assertEqual((found["missing"], found["guarded"]), ([], 4))

    def test_a_probe_guards_its_own_function_only(self):
        self.assertEqual(self.missing('''
            label = Label(None)

            def probing():
                return hasattr(label, "setFont")

            def using():
                label.setFont(1)
            '''), ["Label.setFont"])

    def test_blanket_and_reraising_handlers_are_not_probes(self):
        self.assertEqual(self.missing('''
            label = Label(None)
            try:
                label.one()
            except Exception:
                pass
            try:
                label.two()
            except:
                pass
            try:
                label.three()
            except AttributeError:
                raise
            try:
                label.four()
            except Exception:
                pass
            except AttributeError:
                pass
            try:
                pass
            except AttributeError:
                label.five()
            '''), ["Label.five", "Label.four", "Label.one", "Label.three", "Label.two"])

    def test_constructor_is_never_guarded(self):
        self.assertEqual(self.missing("try:\n    Panel()\nexcept AttributeError:\n    pass\n"), ["Panel.<init>"])


if __name__ == "__main__":
    unittest.main()
