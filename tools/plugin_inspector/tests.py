"""Small behavioral regression suite. Run from the repository root with unittest."""
import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.plugin_inspector.inspector import (
    MAX_SOURCE_BYTES,
    ManifestError,
    inspect_source,
    load_manifest,
    main,
    render_markdown,
    validate_manifest,
)


def implemented(**extra):
    return {"status": "supported", "implementation": "tests/fixture-bridge", **extra}


def fixture_manifest():
    return {
        "schema_version": 1,
        "python": {"version": "3.13", "implementation": "tests/CPython-fixture", "stdlib": ["json", "typing", "os"]},
        "modules": {
            "java": implemented(symbols={"jclass": implemented(), "dynamic_proxy": implemented()}),
            "hook_utils": implemented(symbols={"find_class": implemented()}),
            "base_plugin": implemented(symbols={
                "BasePlugin": implemented(members={"get_setting": implemented(), "add_on_send_message_hook": implemented()}),
                "MethodHook": implemented(),
            }),
        },
        "java_classes": {
            "org.telegram.ui.MainTabsActivity": implemented(members={
                "getInstance": implemented(returns="self"),
                "createView": implemented(),
            }),
        },
        "features": {},
        "dependencies": {},
    }


class InspectorTests(unittest.TestCase):
    def findings(self, report, category=None, target=None):
        return [item for item in report["findings"] if (category is None or item["category"] == category) and (target is None or item["target"] == target)]

    def test_never_executes_top_level_or_emits_source_literals(self):
        source = 'raise RuntimeError("USER_PRIVATE_VALUE")\nAPI_KEY = "DO_NOT_DISCLOSE_123"\n'
        with patch("builtins.eval", side_effect=AssertionError("must not eval")), patch("builtins.exec", side_effect=AssertionError("must not exec")):
            report = inspect_source(source, fixture_manifest())
        output = json.dumps(report) + render_markdown(report)
        self.assertNotIn("USER_PRIVATE_VALUE", output)
        self.assertNotIn("DO_NOT_DISCLOSE_123", output)
        self.assertFalse(report["execution_verified"])
        self.assertTrue(report["runtime_validation_required"])

    def test_default_manifest_does_not_claim_bridge_implementation(self):
        report = inspect_source('from base_plugin import BasePlugin\nfrom android.widget import TextView\n')
        self.assertEqual(report["status"], "unknown")
        self.assertTrue(all(item["status"] == "unknown" for item in report["findings"]))

    def test_import_alias_and_import_time_class_lookup(self):
        report = inspect_source('from java import jclass as jc\nActivity = jc("org.telegram.ui.MainTabsActivity")\n', fixture_manifest())
        lookup = self.findings(report, "java_class_lookup")
        self.assertEqual([(item["target"], item["phase"], item["line"]) for item in lookup], [("org.telegram.ui.MainTabsActivity", "import", 2)])
        self.assertEqual(report["status"], "supported")

    def test_runtime_lookup_constant_and_exact_member_coverage(self):
        source = '''from java import jclass
CLASS_NAME = "org.telegram.ui.MainTabsActivity"
def f():
    Activity = jclass(CLASS_NAME)
    Activity.createView()
    Activity.missingMethod()
'''
        report = inspect_source(source, fixture_manifest())
        self.assertEqual(self.findings(report, "java_class_lookup")[0]["phase"], "runtime")
        self.assertEqual(self.findings(report, "java_call", "org.telegram.ui.MainTabsActivity.createView")[0]["status"], "supported")
        self.assertEqual(self.findings(report, "java_call", "org.telegram.ui.MainTabsActivity.missingMethod")[0]["status"], "unknown")

    def test_direct_java_class_import_alias(self):
        source = 'from org.telegram.ui import MainTabsActivity as Tabs\nTabs.createView()\n'
        report = inspect_source(source, fixture_manifest())
        self.assertEqual(report["status"], "supported")
        self.assertEqual(self.findings(report, "java_class_import")[0]["target"], "org.telegram.ui.MainTabsActivity")

    def test_function_argument_shadowing_does_not_resolve_java_lookup(self):
        source = 'from java import jclass\ndef f(jclass):\n    jclass("org.telegram.ui.MainTabsActivity")\n'
        report = inspect_source(source, fixture_manifest())
        self.assertEqual(self.findings(report, "java_class_lookup"), [])

    def test_reassignment_invalidates_alias(self):
        source = 'from java import jclass as jc\njc = None\njc("org.telegram.ui.MainTabsActivity")\n'
        report = inspect_source(source, fixture_manifest())
        self.assertEqual(self.findings(report, "java_class_lookup"), [])

    def test_default_expressions_run_in_import_phase(self):
        source = 'from java import jclass\ndef f(value=jclass("org.telegram.ui.MainTabsActivity")):\n    pass\n'
        report = inspect_source(source, fixture_manifest())
        self.assertEqual(self.findings(report, "java_class_lookup")[0]["phase"], "import")

    def test_reflection_hooks_and_proxy_remain_explicit_features(self):
        source = '''from base_plugin import MethodHook
from java import jclass, dynamic_proxy
class Hook(MethodHook):
    pass
Activity = jclass("org.telegram.ui.MainTabsActivity")
Activity.getDeclaredMethod(method_name)
dynamic_proxy(Activity)
plugin.hook_all_methods(Activity, method_name, Hook())
'''
        report = inspect_source(source, fixture_manifest())
        targets = {item["target"] for item in self.findings(report, "feature")}
        self.assertTrue({"method_hooks", "reflection", "computed_reflection", "dynamic_proxy", "computed_hook"}.issubset(targets))
        self.assertEqual(report["status"], "unknown")

    def test_unresolved_java_return_type_is_not_assumed_compatible(self):
        source = 'from java import jclass\nA = jclass("org.telegram.ui.MainTabsActivity")\nA.createView().setText("private text")\n'
        report = inspect_source(source, fixture_manifest())
        self.assertTrue(self.findings(report, "feature", "dynamic_java_members"))
        self.assertNotIn("private text", json.dumps(report))

    def test_declared_return_type_resolves_instance(self):
        source = 'from java import jclass\nA = jclass("org.telegram.ui.MainTabsActivity")\ninstance = A.getInstance()\ninstance.createView()\n'
        report = inspect_source(source, fixture_manifest())
        self.assertEqual(report["status"], "supported")

    def test_sdk_instance_method_requires_its_own_manifest_entry(self):
        source = '''from base_plugin import BasePlugin
class P(BasePlugin):
    def on_plugin_load(self):
        self.add_on_send_message_hook()
        self.hook_everything()
'''
        report = inspect_source(source, fixture_manifest())
        self.assertEqual(self.findings(report, "bridge_call", "base_plugin.BasePlugin.add_on_send_message_hook")[0]["status"], "supported")
        self.assertEqual(self.findings(report, "bridge_call", "base_plugin.BasePlugin.hook_everything")[0]["status"], "unknown")

    def test_dynamic_and_native_apis_and_process_restriction(self):
        source = 'import ctypes\nimport numpy\nimport os\nfrom importlib import import_module\nimport_module(module_name)\nos.system("private shell command")\n'
        report = inspect_source(source, fixture_manifest())
        self.assertEqual(report["status"], "unsupported")
        self.assertTrue(self.findings(report, "native_dependency", "numpy"))
        self.assertTrue(self.findings(report, "feature", "native_ffi"))
        self.assertTrue(self.findings(report, "feature", "dynamic_code"))
        self.assertNotIn("private shell command", json.dumps(report))

    def test_metadata_and_requirements_do_not_emit_urls_or_keys(self):
        source = '''__id__ = "group_mentions"
__name__ = "Group Mentions"
__version__ = "1.2"
__sdk_version__ = ">=1.4.0"
__requirements__ = ["requests>=2.0", "https://user:PRIVATE_PASSWORD@example.invalid/pkg.whl"]
API_KEY = "sk-test-PRIVATE_SECRET"
'''
        report = inspect_source(source, fixture_manifest())
        self.assertEqual(report["metadata"]["name"], "Group Mentions")
        self.assertEqual(report["metadata"]["sdk_version"], ">=1.4.0")
        output = json.dumps(report) + render_markdown(report)
        self.assertNotIn("PRIVATE_PASSWORD", output)
        self.assertNotIn("PRIVATE_SECRET", output)
        self.assertNotIn("example.invalid", output)
        self.assertTrue(self.findings(report, "declared_dependency", "requests"))

    def test_class_lookup_arbitrary_literals_are_redacted(self):
        report = inspect_source('from java import jclass\njclass("https://private.invalid/?api_key=SECRET")\n', fixture_manifest())
        self.assertNotIn("SECRET", json.dumps(report))
        self.assertNotIn("private.invalid", json.dumps(report))
        self.assertEqual(self.findings(report, "java_class_lookup")[0]["status"], "unknown")

    def test_positive_status_requires_implementation_reference(self):
        manifest = fixture_manifest()
        manifest["java_classes"]["org.telegram.ui.MainTabsActivity"] = {"status": "supported"}
        report = inspect_source('from java import jclass\njclass("org.telegram.ui.MainTabsActivity")\n', manifest)
        self.assertEqual(report["status"], "unknown")

    def test_partial_and_unsupported_declarations_propagate(self):
        for status in ("partial", "unsupported"):
            manifest = fixture_manifest()
            manifest["java_classes"]["org.telegram.ui.MainTabsActivity"] = {"status": status, "implementation": "tests/fixture-bridge"}
            report = inspect_source('from org.telegram.ui import MainTabsActivity\n', manifest)
            self.assertEqual(report["status"], status)

    def test_invalid_syntax_never_echoes_source_or_exception_text(self):
        report = inspect_source('SECRET_IDENTIFIER = "PRIVATE_SECRET"\nif (\n', fixture_manifest())
        self.assertEqual(report["error"]["code"], "invalid_or_excessive_python")
        self.assertNotIn("SECRET", json.dumps(report))
        self.assertEqual(report["status"], "unknown")

    def test_size_bound_and_manifest_validation(self):
        report = inspect_source(b"#" * (MAX_SOURCE_BYTES + 1), fixture_manifest())
        self.assertEqual(report["error"]["code"], "source_too_large")
        invalid = copy.deepcopy(fixture_manifest())
        invalid["modules"]["java"]["status"] = "probably"
        with self.assertRaises(ManifestError):
            validate_manifest(invalid)

    def test_hook_target_checks_exact_java_member(self):
        source = '''from java import jclass
Activity = jclass("org.telegram.ui.MainTabsActivity")
plugin.hook_all_methods(Activity, "createView", hook)
plugin.hook_all_methods(Activity, "missingMethod", hook)
'''
        report = inspect_source(source, fixture_manifest())
        self.assertEqual(self.findings(report, "hook_target", "org.telegram.ui.MainTabsActivity.createView")[0]["status"], "supported")
        self.assertEqual(self.findings(report, "hook_target", "org.telegram.ui.MainTabsActivity.missingMethod")[0]["status"], "unknown")

    def test_conditional_alias_does_not_claim_selected_class(self):
        source = '''from java import jclass
if condition:
    Target = jclass("org.telegram.ui.MainTabsActivity")
else:
    Target = arbitrary_factory()
Target.createView()
'''
        report = inspect_source(source, fixture_manifest())
        self.assertTrue(self.findings(report, "feature", "conditional_binding"))
        self.assertEqual(report["status"], "unknown")

    def test_comprehension_argument_does_not_reuse_import_alias(self):
        source = 'from java import jclass\nvalues = [jclass("org.telegram.ui.MainTabsActivity") for jclass in callbacks]\n'
        report = inspect_source(source, fixture_manifest())
        self.assertEqual(self.findings(report, "java_class_lookup"), [])

    def test_cli_refuses_to_overwrite_input(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.plugin"
            source = '__id__ = "sample"\n'
            path.write_text(source, encoding="utf-8")
            with patch("sys.stderr.write"):
                self.assertEqual(main([str(path), "--output", str(path)]), 2)
            self.assertEqual(path.read_text(encoding="utf-8"), source)

    def test_cli_json_and_markdown_do_not_import_plugin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "sample.plugin"
            output = root / "report.json"
            marker = root / "SHOULD_NOT_EXIST"
            source.write_text('__id__ = "sample"\n__name__ = "Sample"\n__version__ = "1.0"\nopen(' + repr(str(marker)) + ', "w").write("executed")\n', encoding="utf-8")
            self.assertEqual(main([str(source), "--output", str(output)]), 0)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["metadata"]["id"], "sample")
            self.assertFalse(marker.exists())
            self.assertEqual(main([str(source), "--format", "markdown", "--output", str(output)]), 0)
            self.assertIn("Runtime compatibility has not been verified.", output.read_text(encoding="utf-8"))
            self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main()
