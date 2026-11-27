"""Synthetic corpus-preflight meter tests; fixtures are parsed, never executed."""
import contextlib
import io
import json
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

from .preflight import (
    DEFAULT_BRIDGE, UNPRINTABLE, PreflightError, bridge_runtime, main, preflight_corpus,
    render_text, scrape_capabilities, scrape_host,
)
from .swift_members import scrape_members

HEADER = '__id__ = "{id}"\n__name__ = "Fixture"\nfrom base_plugin import BasePlugin\n'
CAPABILITIES = {"operations": ["runtime.capabilities"], "classes": ["com.synthetic.meter.Known"],
                "modules": [], "proxy_interfaces": {}}
PROVIDER = '''
class Local:
    pass


class Gated:
    __ayu_requires__ = ("synthetic.meter.absent",)


CLASSES = {"com.synthetic.meter.Local": Local, "com.synthetic.meter.Gated": Gated}
'''


def write(root, name, body, plugin_id=None):
    (root / name).write_text(HEADER.format(id=plugin_id or Path(name).stem) + body, encoding="utf-8")


@contextlib.contextmanager
def synthetic_provider(directory):
    """Point the bridge's local-class seam at one provider written for the test."""
    with bridge_runtime(DEFAULT_BRIDGE / "Python", CAPABILITIES):
        import _ayu_javalib as javalib
    (Path(directory) / "synthetic_meter.py").write_text(PROVIDER, encoding="utf-8")
    saved = (javalib.PROVIDER_MODULES, list(javalib.__path__))
    javalib.__path__[:] = [directory]
    javalib.PROVIDER_MODULES = ("synthetic_meter",)
    javalib.reset()
    try:
        yield
    finally:
        javalib.PROVIDER_MODULES, javalib.__path__[:] = saved
        sys.modules.pop("_ayu_javalib.synthetic_meter", None)
        javalib.reset()


class PreflightCorpusTests(unittest.TestCase):
    def corpus(self, root):
        marker = root / "NEVER_CREATED"
        write(root, "pass_one.plugin", "open(" + repr(str(marker)) + ', "w").write("PRIVATE_LITERAL")\n')
        write(root, "pass_two.plugin", "from com.synthetic.meter import Known\n")
        write(root, "class_only.plugin", "from com.synthetic.meter import Missing\n")
        write(root, "two_kinds.plugin", "import synthetic_absent_dependency\n"
              "from com.synthetic.meter import Missing, Other\n")
        write(root, "literal.plugin", 'from java import jclass\nA = jclass("PRIVATE://literal value")\n')
        write(root, "computed.plugin", "", plugin_id='x" + "y')
        (root / "binary.plugin").write_bytes(b"\xff\xfe\x00")
        (root / "ignored.txt").write_text("if (", encoding="utf-8")
        nested = root / "nested"
        nested.mkdir()
        write(nested, "deep.plugin", "from com.synthetic.meter import Deep\n")
        return marker

    def test_counts_rankings_and_no_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = self.corpus(root)
            report = preflight_corpus(root, capabilities=CAPABILITIES, top=1, include_ids=True)
            self.assertFalse(marker.exists())
            self.assertEqual((report["plugins"], report["passing"], report["blocked"], report["rejected"]), (7, 2, 3, 2))
            self.assertEqual(report["passing_ids"], ["pass_one", "pass_two"])
            self.assertEqual(report["blocked_by_kind"], {"CLASS": 3, "DEPENDENCY": 1})
            self.assertEqual(report["blocked_by_single_kind"], {"CLASS": 2})
            self.assertEqual(report["distinct_blockers_per_plugin"], {"0": 2, "1": 2, "2-5": 1, "6-15": 0, "16+": 0})
            self.assertEqual(list(report["blockers"]), ["CLASS", "DEPENDENCY"])
            classes = report["blockers"]["CLASS"]
            self.assertEqual((classes["distinct"], classes["omitted"]), (3, 2))
            self.assertEqual(classes["ranked"], [{"detail": "com.synthetic.meter.Missing", "plugins": 2}])
            self.assertEqual(report["blockers"]["DEPENDENCY"]["ranked"],
                             [{"detail": "synthetic_absent_dependency", "plugins": 1}])
            self.assertEqual(report["rejections"], [
                {"reason": "LOAD_REJECTED: Metadata must be literal", "plugins": 1},
                {"reason": "UNREADABLE: source is not bounded UTF-8 text", "plugins": 1}])
            self.assertFalse(report["execution_verified"])
            self.assertTrue(report["runtime_validation_required"])
            self.assertEqual(report["capabilities"]["source"], "file")
            self.assertEqual(report["capabilities"]["host_classes"], 1)
            full = preflight_corpus(root, capabilities=CAPABILITIES, top=5)
            self.assertNotIn("passing_ids", full)
            self.assertEqual([row["detail"] for row in full["blockers"]["CLASS"]["ranked"]],
                             ["com.synthetic.meter.Missing", UNPRINTABLE, "com.synthetic.meter.Other"])
            text = json.dumps(full) + render_text(full) + json.dumps(report) + render_text(report)
            for forbidden in ("PRIVATE", str(root), "class_only", "two_kinds.plugin", "NEVER_CREATED", "Deep"):
                self.assertNotIn(forbidden, text)
            self.assertIn("pass 2   blocked 3   rejected 2", render_text(report))
            self.assertEqual(preflight_corpus(root, capabilities=CAPABILITIES, top=5), full)
            self.assertNotIn("_ayu_host", sys.modules)

    def test_declared_metadata_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(root, "first.plugin", '__min_version__ = "1.0"\n__sdk_version__ = ">=1.0"\n')
            write(root, "second.plugin", '__min_version__ = "1.0"\n__requirements__ = []\n')
            report = preflight_corpus(root, capabilities=CAPABILITIES)
            self.assertEqual(report["declared_metadata"], {
                "__min_version__": 2, "__app_version__": 0, "__sdk_version__": 1, "__requirements__": 0})

    def test_local_classes_come_from_the_bridge_capability_validation(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as providers:
            root = Path(directory)
            write(root, "local.plugin", "from com.synthetic.meter import Local\n")
            write(root, "gated.plugin", "from com.synthetic.meter import Gated\n")
            before = preflight_corpus(root, capabilities=CAPABILITIES)
            self.assertEqual((before["passing"], before["blocked"]), (0, 2))
            with synthetic_provider(providers):
                report = preflight_corpus(root, capabilities=CAPABILITIES)
                self.assertEqual(report["capabilities"]["local_classes"], 1)
                self.assertEqual((report["passing"], report["blocked"]), (1, 1))
                self.assertEqual(report["blockers"]["CLASS"]["ranked"],
                                 [{"detail": "com.synthetic.meter.Gated", "plugins": 1}])
                declared = dict(CAPABILITIES, operations=CAPABILITIES["operations"] + ["synthetic.meter.absent"])
                self.assertEqual(preflight_corpus(root, capabilities=declared)["passing"], 2)

    def test_broken_class_provider_is_named(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as providers:
            root = Path(directory)
            write(root, "one.plugin", "")
            with synthetic_provider(providers):
                (Path(providers) / "synthetic_meter.py").write_text("CLASSES = []\n", encoding="utf-8")
                with self.assertRaises(PreflightError) as caught:
                    preflight_corpus(root, capabilities=CAPABILITIES)
            self.assertIn("ProviderError: Provider synthetic_meter must define a CLASSES dict", str(caught.exception))
            self.assertNotIn(providers, str(caught.exception))

    def test_swift_literal_scrape(self):
        with tempfile.TemporaryDirectory() as directory:
            bridge = Path(directory)
            (bridge / "Sources").mkdir()
            (bridge / "Integration").mkdir()
            (bridge / "Sources/Host.swift").write_text(
                'final class Host {\n'
                '    private let operations = ["runtime.capabilities", "java.member"]\n'
                '    private static let modules = [\n        "base_plugin", "ui.settings",\n    ]\n'
                '    private static let proxyInterfaces: [String: [String]] = ["java.lang.Runnable": ["run"], '
                '"android.view.View$OnClickListener": ["onClick"]]\n'
                '    private static let classes: [String: [String: Int]] = [\n'
                '        "android.view.View": ["GONE": 8], "org.telegram.messenger.R$drawable": [:],\n    ]\n'
                '    // "com.synthetic.Commented" is only mentioned in a comment\n'
                '    let message = "java.construct failed for \\(name)"\n}\n', encoding="utf-8")
            (bridge / "Integration/App.swift").write_text(
                'struct App {\n    public let capabilities = ["client.call"]\n'
                '    static let user = "org.telegram.tgnet.TLRPC$User"\n}\n', encoding="utf-8")
            self.assertEqual(scrape_capabilities(bridge), {
                "operations": ["client.call", "java.member", "runtime.capabilities"],
                "classes": ["android.view.View", "android.view.View$OnClickListener", "java.lang.Runnable",
                            "org.telegram.messenger.R$drawable", "org.telegram.tgnet.TLRPC$User"],
                "modules": ["base_plugin", "ui.settings"],
                "proxy_interfaces": {"android.view.View$OnClickListener": ["onClick"], "java.lang.Runnable": ["run"]}})
            (bridge / "Sources/Host.swift").write_text("struct Host {}\n", encoding="utf-8")
            (bridge / "Integration/App.swift").write_text("struct App {}\n", encoding="utf-8")
            with self.assertRaises(PreflightError):
                scrape_capabilities(bridge)
            with self.assertRaises(PreflightError):
                scrape_capabilities(bridge / "absent")

    def test_repository_host_sources_pass_capability_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(root, "view.plugin", "from android.view import View\nimport requests\n")
            report = preflight_corpus(root)
            self.assertEqual(report["capabilities"]["source"], "swift_literals")
            self.assertEqual((report["passing"], report["blocked"], report["rejected"]), (1, 0, 0))

    def test_invalid_inputs_are_generic_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugins = root / "plugins"
            plugins.mkdir()
            write(plugins, "one.plugin", "")
            with self.assertRaises(PreflightError) as caught:
                preflight_corpus(plugins, capabilities=dict(CAPABILITIES, PRIVATE_EXTRA=[]))
            self.assertEqual(str(caught.exception), "Bridge SDK rejected the host capabilities or a class provider: "
                             "ProtocolError: PROTOCOL_ERROR: Malformed host capabilities")
            with self.assertRaises(PreflightError):
                preflight_corpus(plugins, capabilities=CAPABILITIES, top=0)
            with self.assertRaises(PreflightError):
                preflight_corpus(root / "absent", capabilities=CAPABILITIES)
            bad = root / "caps.json"
            bad.write_text("[PRIVATE", encoding="utf-8")
            stderr = io.StringIO()
            with patch("sys.stderr", stderr):
                self.assertEqual(main(["--plugin-dir", str(plugins), "--capabilities", str(bad)]), 2)
                self.assertEqual(main(["--plugin-dir", str(root / "absent")]), 2)
            self.assertEqual(stderr.getvalue(), "Corpus preflight failed: Capability file is unavailable or invalid.\n"
                             "Corpus preflight failed: Plugin directory is unavailable.\n")
            self.assertNotIn("PRIVATE", stderr.getvalue())
            self.assertNotIn(str(root), stderr.getvalue())

    def test_cli_text_json_output_and_module_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugins = root / "plugins"
            plugins.mkdir()
            write(plugins, "one.plugin", "from com.synthetic.meter import Missing\n")
            caps = root / "caps.json"
            caps.write_text(json.dumps(CAPABILITIES), encoding="utf-8")
            output = root / "report.json"
            arguments = ["--plugin-dir", str(plugins), "--capabilities", str(caps)]
            self.assertEqual(main(arguments + ["--json", "--output", str(output)]), 0)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual((report["plugins"], report["blocked"]), (1, 1))
            stderr = io.StringIO()
            with patch("sys.stderr", stderr):
                self.assertEqual(main(arguments + ["--output", str(plugins / "report.txt")]), 2)
                self.assertEqual(main(arguments + ["--output", str(caps)]), 2)
            self.assertEqual(json.loads(caps.read_text(encoding="utf-8")), CAPABILITIES)
            stdout = io.StringIO()
            with patch("sys.stdout", stdout), patch("sys.argv", ["plugin_inspector", "preflight-corpus"] + arguments):
                with self.assertRaises(SystemExit) as exit_state:
                    runpy.run_module("tools.plugin_inspector", run_name="__main__")
            self.assertEqual(exit_state.exception.code, 0)
            self.assertIn("pass 0   blocked 1   rejected 0", stdout.getvalue())
            self.assertIn("    1  com.synthetic.meter.Missing", stdout.getvalue())


HOST_SWIFT = '''
final class Host {
    private let operations = ["runtime.capabilities", "java.member"]
    private static let modules = ["base_plugin"]
    private static let proxyInterfaces: [String: [String]] = ["java.lang.Runnable": ["run"]]
    private static let viewClasses: Set<String> = ["com.synthetic.view.Plain", "com.synthetic.view.Text"]
    private static let layoutFields: Set<String> = ["width", "height"]
    private static let classes: [String: [String: Value]] = [
        "com.synthetic.view.Plain": ["VISIBLE": .number(0)], "com.synthetic.view.Text": [:],
        "com.synthetic.view.Plain$LayoutParams": ["MATCH_PARENT": .number(-1)],
        "com.synthetic.view.Animator": [:], "com.synthetic.view.Marker": [:], "java.lang.Runnable": [:],
    ]
    private static let reflectionMethods: Set<String> = ["getName", "isArray"]
    private static let readMethods: Set<String> = ["getWidth"]
    private static let writeMethods: [String: Int] = ["setAlpha": 1, "setText": 1]
    private static let otherWriteMethods: [String: Int] = ["setMax": 1]
    private static let scrollReadMethods: Set<String> = ["getScrollX"]
    private static let scrollWriteMethods: [String: Int] = ["scrollTo": 2]
    private static let progressReadMethods: Set<String> = ["getMax"]
    private static func methods(for name: String) -> Set<String> {
        if name == "com.synthetic.view.Animator" { return ["alpha", "start"] }
        guard self.viewClasses.contains(name) else { return [] }
        var result = self.readMethods.union(self.writeMethods.keys)
        if name != "com.synthetic.view.Text" { result.subtract(["setText"]) } // a "comment" [ with brackets
        if name == "com.synthetic.view.Text" { result.formUnion(["setHint"]) }
        return result
    }
}
'''

ADAPTERS_SWIFT = '''
enum Adapters {
    static var registered: [AyuBridgeClassAdapter] {
        let enabled: Set<String> = ["com.synthetic.value.Box", "com.synthetic.value.Left", "com.synthetic.value.Right",
            "com.synthetic.value.Shifting", "com.synthetic.value.Keyed", "com.synthetic.value.Preset", "com.synthetic.value.Twice"]
        return self.adapters.filter { enabled.contains($0.name) }
    }
    private static let sideFields = ["x", "y"]
    private static let boxName = "com.synthetic.value.Box"
    static var box: AyuBridgeClassAdapter {
        let helpers: [String: Method] = [
            "size": { state, args, _ in .value(state["text \\(1)"] ?? .null) },
            "grow": { state, _, _ in Self.instance(Self.boxName, state) },
        ]
        return AyuBridgeClassAdapter(name: Self.boxName, constants: ["LIMIT": .integer(3), "NAME": .string("]")],
            constructor: { args, _ in [:] }, staticMethods: ["of": { _, _ in .instance(className: Self.boxName, state: [:]) }],
            staticFields: ["shared": { _ in .value(.null) }], methods: helpers,
            readableFields: ["width", "depth"], writableFields: ["width"], receiverMethods: ["grow"],
            results: ["of": Self.boxName, "shared": "com.synthetic.value.Left", "grow": "com.synthetic.value.Gone"])
    }
    private static func side(_ name: String, flipped: Bool) -> AyuBridgeClassAdapter {
        let fields = Self.sideFields
        let constructor: Constructor = { args, _ in [:] }
        return AyuBridgeClassAdapter(name: name, constructor: constructor, methods: ["flip": { state, _, _ in .value(.bool(flipped)) }],
            readableFields: Set(fields), writableFields: Set(fields))
    }
    static var left: AyuBridgeClassAdapter { Self.side("com.synthetic.value.Left", flipped: false) }
    static var right: AyuBridgeClassAdapter { self.side("com.synthetic.value.Right", flipped: true) }
    static var shifting: AyuBridgeClassAdapter {
        var methods: [String: Method] = ["first": { _, _, _ in .value(.null) }]
        if Self.flag { methods["second"] = { _, _, _ in .value(.null) } }
        return AyuBridgeClassAdapter(name: "com.synthetic.value.Shifting", methods: methods)
    }
    private static let keyNames = ["key_one", "key_two"]
    private static var keys: [String: Value] {
        var keys: [String: Value] = [:]
        for (index, name) in keyNames.enumerated() { keys[name] = .integer(Int64(index)) }
        return keys
    }
    static var keyed: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "com.synthetic.value.Keyed", constants: Self.keys)
    }
    static var preset: AyuBridgeClassAdapter {
        let presets: [String: String] = ["FIRST": "a", "SECOND": "b"]
        let fields = Dictionary(uniqueKeysWithValues: presets.map { key, value in (key, { _ in .value(.string(value)) } as Field) })
        return AyuBridgeClassAdapter(name: "com.synthetic.value.Preset", staticFields: fields)
    }
    static var twice: [AyuBridgeClassAdapter] {
        [AyuBridgeClassAdapter(name: "com.synthetic.value.Twice", methods: ["a": { _, _, _ in .value(.null) }]),
         AyuBridgeClassAdapter(name: "com.synthetic.value.Twice", methods: ["b": { _, _, _ in .value(.null) }])]
    }
    static var disabled: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "com.synthetic.value.Disabled", methods: ["never": { _, _, _ in .value(.null) }])
    }
    static var shadow: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "com.synthetic.view.Plain", methods: ["shadowed": { _, _, _ in .value(.null) }])
    }
}
'''


class SwiftMemberScrapeTests(unittest.TestCase):
    def scrape(self):
        return scrape_members({"Sources/Host.swift": HOST_SWIFT, "Sources/Adapters.swift": ADAPTERS_SWIFT})

    def test_literal_adapters_are_read_exactly(self):
        table = self.scrape()["table"]
        self.assertEqual(table["version"], 1)
        classes = table["classes"]
        self.assertEqual(classes["com.synthetic.value.Box"], {
            "constructor": True, "methods": ["getClass", "grow", "size"], "fields": ["depth", "width"],
            "writable_fields": ["width"], "static_methods": ["getName", "isArray", "of"],
            "static_fields": ["LIMIT", "NAME", "shared"],
            # A result naming a class the host does not register is dropped.
            "results": {"of": "com.synthetic.value.Box", "shared": "com.synthetic.value.Left"}})
        for name in ("com.synthetic.value.Left", "com.synthetic.value.Right"):
            self.assertEqual((classes[name]["constructor"], classes[name]["methods"], classes[name]["fields"],
                              classes[name]["writable_fields"]), (True, ["flip", "getClass"], ["x", "y"], ["x", "y"]))
        self.assertEqual(classes["com.synthetic.value.Keyed"]["static_fields"], ["key_one", "key_two"])
        self.assertEqual(classes["com.synthetic.value.Preset"]["static_fields"], ["FIRST", "SECOND"])
        self.assertFalse(classes["com.synthetic.value.Keyed"]["constructor"])

    def test_adapters_that_are_not_literal_have_no_table(self):
        result = self.scrape()
        classes = result["table"]["classes"]
        for name in ("com.synthetic.value.Shifting", "com.synthetic.value.Twice", "com.synthetic.value.Disabled"):
            self.assertNotIn(name, classes)
        self.assertEqual(result["disabled"], ["com.synthetic.value.Disabled"])

    def test_builtin_classes_and_the_view_upper_bound(self):
        result = self.scrape()
        classes = result["table"]["classes"]
        self.assertEqual(result["upper_bound"], ["com.synthetic.view.Plain", "com.synthetic.view.Text"])
        views = ["getClass", "getMax", "getScrollX", "getWidth", "scrollTo", "setAlpha", "setHint", "setMax", "setText"]
        self.assertEqual(classes["com.synthetic.view.Plain"], {
            "constructor": True, "methods": views, "fields": [], "writable_fields": [],
            "static_methods": ["getName", "isArray"], "static_fields": ["VISIBLE"], "results": {}})
        self.assertEqual(classes["com.synthetic.view.Text"]["methods"], views)
        self.assertEqual(classes["com.synthetic.view.Animator"]["methods"], ["alpha", "start"])
        self.assertEqual((classes["com.synthetic.view.Marker"]["methods"], classes["com.synthetic.view.Marker"]["constructor"]),
                         ([], False))
        params = classes["com.synthetic.view.Plain$LayoutParams"]
        self.assertEqual((params["constructor"], params["methods"], params["fields"], params["writable_fields"],
                          params["static_fields"]), (True, ["getClass"], ["height", "width"], ["height", "width"], ["MATCH_PARENT"]))

    def test_unreadable_sources_yield_no_table(self):
        self.assertEqual(scrape_members({"Sources/Host.swift": "struct Host {", "Sources/Other.swift": "struct Other {}"}),
                         {"table": {"version": 1, "classes": {}}, "disabled": [], "upper_bound": []})

    def test_scraped_capabilities_carry_the_table_and_drop_disabled_adapters(self):
        with tempfile.TemporaryDirectory() as directory:
            bridge = Path(directory)
            (bridge / "Sources").mkdir()
            (bridge / "Integration").mkdir()
            (bridge / "Sources/Host.swift").write_text(HOST_SWIFT, encoding="utf-8")
            (bridge / "Integration/Adapters.swift").write_text(ADAPTERS_SWIFT, encoding="utf-8")
            capabilities, notes = scrape_host(bridge)
            self.assertEqual(capabilities, scrape_capabilities(bridge))
            self.assertNotIn("com.synthetic.value.Disabled", capabilities["classes"])
            self.assertIn("com.synthetic.value.Shifting", capabilities["classes"])
            self.assertEqual(set(capabilities["members"]["classes"]) - set(capabilities["classes"]), set())
            self.assertEqual(notes, {"classes_with_members": 11, "upper_bound_classes": 2, "classes_without_members": 3})
            root = bridge / "plugins"
            root.mkdir()
            write(root, "fine.plugin", "from com.synthetic.value import Box\nBox.of().size()\nBox.shared.flip()\n")
            write(root, "missing.plugin", "from com.synthetic.value import Box, Shifting\n"
                  "Box.of().vanish()\nBox().depth = 1\nShifting.anything()\n")
            write(root, "unknown.plugin", "def run(view):\n    view.setText(1)\n")
            report = preflight_corpus(root, capabilities=capabilities, top=5, include_ids=True)
            self.assertEqual((report["passing_ids"], report["blocked_by_kind"]), (["fine", "unknown"], {"MEMBER": 1}))
            self.assertEqual([row["detail"] for row in report["blockers"]["MEMBER"]["ranked"]],
                             ["com.synthetic.value.Box.depth (write)", "com.synthetic.value.Box.vanish"])
            self.assertEqual(report["member_accesses"], {"verified": 6, "guarded": 0, "missing_accesses": 2, "unknown": 2, "unknown_java_style": 1})
            self.assertEqual(report["capabilities"]["member_tables"],
                             {"classes_with_members": 11, "upper_bound_classes": 0, "classes_without_members": 3})
            text = render_text(report)
            self.assertIn("Host member tables: 11 classes (0 as an upper bound), 3 unknown", text)
            self.assertIn("Member accesses: 8 on a known receiver class (2 missing, 0 more missing behind a probe), 2 with an unknown", text)

    def test_repository_host_sources_yield_member_tables(self):
        capabilities, notes = scrape_host(DEFAULT_BRIDGE)
        classes = capabilities["members"]["classes"]
        self.assertGreater(notes["classes_with_members"], 80)
        self.assertIn("setText", classes["android.widget.TextView"]["methods"])
        self.assertIn("putExtra", classes["android.content.Intent"]["methods"])
        self.assertNotIn("startActivity", classes["android.content.Intent"]["methods"])
        self.assertIn("CENTER", classes["android.view.Gravity"]["static_fields"])
        self.assertNotIn("android.graphics.Canvas", capabilities["classes"])
        with bridge_runtime(DEFAULT_BRIDGE / "Python", capabilities) as runtime:
            self.assertEqual(set(runtime._capabilities()["members"]), set(classes))


if __name__ == "__main__":
    unittest.main()
