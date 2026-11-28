"""Android version and requirement policy, on synthetic metadata only."""
import json
import unittest

import test_bridge as fixtures
import _ayu_policy as policy
import ayu_bridge as bridge


class VersionComparisonTests(unittest.TestCase):
    def test_emulated_versions_are_the_reference_revision(self):
        self.assertEqual((policy.SDK_VERSION, policy.APP_VERSION), ("1.4.6.5", "13.2.2"))

    def test_components_compare_as_integers_with_missing_ones_zero(self):
        self.assertEqual(policy.compare_version_values("12.10.6", "12.9.0"), 1)
        self.assertEqual(policy.compare_version_values("1.4", "1.4.0.0"), 0)
        self.assertEqual(policy.compare_version_values("12.10.06", "12.10.6"), 0)
        self.assertEqual(policy.compare_version_values("1.4.6.5", "1.4.6.5.1"), -1)
        self.assertEqual(policy.compare_version_values("1.4.", "1.4"), 0)
        self.assertEqual(policy.compare_version_values("+13", "13"), 0)
        self.assertEqual(policy.compare_version_values("0", "-1"), 1)

    def test_operators(self):
        cases = {"==": (False, True, False), ">": (False, False, True), "<": (True, False, False),
                 ">=": (False, True, True), "<=": (True, True, False)}
        for operator, expected in cases.items():
            with self.subTest(operator):
                self.assertEqual(tuple(policy.compare_versions(operator, current, "13.2.2")
                                       for current in ("13.2.1", "13.2.2", "13.10")), expected)
        for operator in ("!=", "~=", "=", ""):
            with self.subTest(operator), self.assertRaises(ValueError):
                policy.compare_versions(operator, "1", "1")

    def test_malformed_components_fail_only_when_they_are_reached(self):
        for target in ("13.2.beta", "13..2", "", "13.2 ", "13.2.2147483648", "13.2.1_0", "v13"):
            with self.subTest(target), self.assertRaises(ValueError):
                policy.compare_version_values("13.2.2", target)
        # Java stops parsing at the first differing component.
        self.assertEqual(policy.compare_version_values("13.2.2", "13.3.beta"), -1)
        self.assertEqual(policy.compare_version_values("13.2.2", "12.x"), 1)


class VersionPolicyTests(unittest.TestCase):
    def findings(self, **metadata):
        return policy.version_findings({f"__{key}__": value for key, value in metadata.items()})

    def test_satisfied_constraints(self):
        for metadata in ({}, {"min_version": "12.5.1"}, {"min_version": "13.2.2"}, {"min_version": 12},
                         {"min_version": 12.5}, {"app_version": ">=13.1.1"}, {"app_version": ">= 12.0 "},
                         {"app_version": "<14"}, {"app_version": "==13.2.2.0"}, {"sdk_version": ">=1.4.6.5"},
                         {"sdk_version": "<=1.4.6.5"}, {"sdk_version": ">1.4.6.4"},
                         {"min_version": "11.12.0", "app_version": ">=12.5.1", "sdk_version": ">=1.4.3.3"}):
            with self.subTest(metadata):
                self.assertEqual(self.findings(**metadata), [])

    def test_newer_versions_block_with_the_reason(self):
        self.assertEqual(self.findings(min_version="13.3"),
                         ["app_version>=13.3 is not met by the emulated exteraGram 13.2.2"])
        self.assertEqual(self.findings(app_version="==13.1.1"),
                         ["app_version==13.1.1 is not met by the emulated exteraGram 13.2.2"])
        self.assertEqual(self.findings(sdk_version=">1.4.6.5"),
                         ["sdk_version>1.4.6.5 is not met by the emulated plugin SDK 1.4.6.5"])
        self.assertEqual(self.findings(app_version=">=14.0", sdk_version=">=1.4.7"), [
            "app_version>=14.0 is not met by the emulated exteraGram 13.2.2",
            "sdk_version>=1.4.7 is not met by the emulated plugin SDK 1.4.6.5"])
        self.assertEqual(policy.version_findings({"__min_version__": "13.3"}, app_version="13.3.0"), [])
        self.assertEqual(policy.version_findings({"__sdk_version__": ">=1.4.7"}, sdk_version="1.5"), [])

    def test_app_version_replaces_min_version(self):
        self.assertEqual(self.findings(min_version="99.0", app_version=">=12.0"), [])
        self.assertEqual(self.findings(min_version=">=12.0", app_version=">=12.0"), [])
        self.assertEqual(self.findings(min_version="12.0", app_version=">=99.0"),
                         ["app_version>=99.0 is not met by the emulated exteraGram 13.2.2"])

    def test_invalid_constraints_block(self):
        invalid = "app_version is not a valid version constraint"
        for metadata in ({"app_version": "12.0"}, {"app_version": "=>12.0"}, {"app_version": ""},
                         {"app_version": ">="}, {"app_version": ">= "}, {"app_version": ">=12.0\n"},
                         {"app_version": ">=13.2.x"}, {"app_version": None}, {"app_version": True},
                         {"min_version": ">=12.0"}, {"min_version": ""}, {"min_version": ["12", "0"]}):
            with self.subTest(metadata):
                self.assertEqual(self.findings(**metadata), [invalid])
        self.assertEqual(self.findings(sdk_version="1.4"), ["sdk_version is not a valid version constraint"])

    def test_shapes_android_drops_are_reported(self):
        self.assertEqual(self.findings(app_version=(">=12.0",)), ["app_version must be a constant"])
        self.assertEqual(self.findings(sdk_version={"min": "1"}), ["sdk_version must be a constant"])
        self.assertEqual(self.findings(min_version=[["12"]]), ["min_version must be a constant"])

    def test_long_or_unprintable_constraint_text_is_not_echoed(self):
        self.assertEqual(self.findings(app_version=">=99." + "0" * 80),
                         ["app_version<constraint> is not met by the emulated exteraGram 13.2.2"])
        self.assertEqual(self.findings(app_version=">=99\t"),
                         ["app_version<constraint> is not met by the emulated exteraGram 13.2.2"])


class RequirementPolicyTests(unittest.TestCase):
    def test_android_splitting(self):
        self.assertEqual(policy.requirement_list("one, two"), ["one", "two"])
        self.assertEqual(policy.requirement_list("one>=1.2,<2, two ,, "), ["one>=1.2,<2", "two"])
        self.assertEqual(policy.requirement_list(["one>=1.2,<2", "two"]), ["one>=1.2,<2", "two"])
        self.assertEqual(policy.requirement_list(["one,two", "three"]), ["one", "two", "three"])
        self.assertEqual(policy.requirement_list("one (>=1), two,!=3, three,\t~=4"),
                         ["one (>=1)", "two,!=3", "three,\t~=4"])
        # Android joins a list before splitting, so a specifier item rejoins its package.
        self.assertEqual(policy.requirement_list(["one>=1", "<2"]), ["one>=1,<2"])
        self.assertEqual(policy.requirement_list([1, None, "two"]), ["1", "None", "two"])
        self.assertEqual(policy.requirement_list([]), [])
        self.assertEqual(policy.requirement_list(""), [])
        for value in (("one", "two"), [["one"]], {"one": "1"}, [("one",)]):
            with self.subTest(value):
                self.assertIsNone(policy.requirement_list(value))

    def test_distribution_names(self):
        cases = {"Requests": "requests", "yt_dlp==1": "yt-dlp", "ruamel.yaml>=0.1": "ruamel-yaml",
                 "requests[socks]>=2 ; python_version < '3'": "requests", "one (>=1.0)": "one",
                 "PyYAML": "pyyaml", "a__b..c--d": "a-b-c-d", "@Odd": "@odd"}
        for requirement, name in cases.items():
            with self.subTest(requirement):
                self.assertEqual(policy.distribution_name(requirement), name)

    def test_only_bundled_modules_satisfy(self):
        stdlib = {"dataclasses", "enum", "typing"}
        self.assertEqual(policy.requirement_findings(["requests>=2.32.2,<3", "Requests"], {"requests"}), [])
        self.assertEqual(policy.requirement_findings(["dataclasses", "enum34==1.1", "typing"], stdlib), [])
        self.assertEqual(policy.requirement_findings(["requests"], stdlib),
                         ["requests (host does not declare its bundled module)"])
        self.assertEqual(policy.requirement_findings(["Pillow>=9", "lxml"], {"requests"} | stdlib), [
            "pillow (bundled by Android exteraGram, not by this bridge)",
            "lxml (bundled by Android exteraGram, not by this bridge)"])
        self.assertEqual(policy.requirement_findings(["one==1.0", "One", "two_x"], {"one", "requests"}),
                         ["one", "two-x"])

    def test_bundled_table_names_are_normalized_and_android_preinstalled_set_is_exact(self):
        for name, modules in policy.BUNDLED_DISTRIBUTIONS.items():
            self.assertEqual(policy.distribution_name(name), name)
            self.assertTrue(modules and all(isinstance(module, str) and module for module in modules))
        self.assertEqual(policy.ANDROID_PREINSTALLED, {
            "beautifulsoup4", "debugpy", "lxml", "packaging", "pillow", "requests", "pyyaml"})


class BridgePolicyTests(unittest.TestCase):
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown

    def text(self, metadata, plugin_id="sample", body="    pass\n"):
        return fixtures.source(plugin_id, body) + "\n" + metadata

    def blockers(self, metadata):
        report = json.loads(bridge.preflight_plugin_json(self.text(metadata)))
        return report, [(item["code"], item["detail"]) for item in report["blockers"]]

    def authorizations(self):
        return [item for item in self.host.requests if item["operation"] == "plugin.authorize"]

    def test_preflight_passes_satisfied_metadata(self):
        self.host.capabilities["modules"] = ["requests"]
        report, blockers = self.blockers(
            '__requirements__ = "requests>=2.32.2,<3, dataclasses"\n__min_version__ = "11.12.0"\n'
            '__app_version__ = ">=12.5.1"\n__sdk_version__ = ">=1.4.3.3"\n')
        self.assertEqual(blockers, [])
        self.assertEqual(report["requirements"], ["requests>=2.32.2,<3", "dataclasses"])
        self.assertEqual(self.authorizations(), [])

    def test_preflight_names_unbundled_packages_and_unmet_versions(self):
        report, blockers = self.blockers(
            '__requirements__ = ["requests", "Synthetic_Wheel>=1,<2", "synthetic-wheel", "Pillow"]\n'
            '__app_version__ = ">=99.0"\n__sdk_version__ = "1.4"\n')
        self.assertEqual(blockers, [
            ("REQUIREMENT", "requests (host does not declare its bundled module)"),
            ("REQUIREMENT", "synthetic-wheel"),
            ("REQUIREMENT", "pillow (bundled by Android exteraGram, not by this bridge)"),
            ("VERSION_POLICY", "app_version>=99.0 is not met by the emulated exteraGram 13.2.2"),
            ("VERSION_POLICY", "sdk_version is not a valid version constraint")])
        self.assertEqual(report["requirements"], ["requests", "Synthetic_Wheel>=1,<2", "synthetic-wheel", "Pillow"])

    def test_unsupported_requirement_shapes_are_rejected_with_the_reason(self):
        for value in ('("one", "two")', '[["one"]]', '{"one": "1"}'):
            for entry in (bridge.preflight_plugin_json, bridge.inspect_plugin_json, bridge.load_plugin):
                with self.subTest(value=value, entry=entry.__name__), self.assertRaises(bridge.BridgeError) as caught:
                    entry(self.text("__requirements__ = " + value + "\n"))
                self.assertEqual((caught.exception.code, caught.exception.message),
                                 ("LOAD_REJECTED", "__requirements__ must be a string or a list of constants"))
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.preflight_plugin_json(self.text("__requirements__ = " + repr(["wheel"] * 257) + "\n"))
        self.assertEqual(caught.exception.message, "__requirements__ exceeds its entry limit")
        self.assertEqual(self.authorizations(), [])

    def test_load_with_satisfied_metadata_reports_the_evaluated_versions(self):
        self.host.capabilities["modules"] = ["requests"]
        bridge.load_plugin(self.text('__requirements__ = "requests"\n__min_version__ = "12.5.1"\n'
                                     '__sdk_version__ = ">=1.4.0"\n'))
        arguments = self.authorizations()[0]["arguments"]
        self.assertEqual(arguments["requirements"], [])
        self.assertEqual(arguments["version_policy"], {"app_version": "13.2.2", "sdk_version": "1.4.6.5"})
        self.assertEqual(arguments["metadata"]["__requirements__"], "requests")
        self.assertEqual(arguments["metadata"]["__min_version__"], "12.5.1")

    def test_load_rejects_before_authorization_and_execution(self):
        cases = {
            '__requirements__ = ["synthetic-wheel==1.0"]\n': "Requirement is not bundled: synthetic-wheel",
            '__requirements__ = "requests"\n': "Requirement is not bundled: requests (host does not declare its bundled module)",
            '__min_version__ = "99.0"\n':
                "Version constraint is not satisfied: app_version>=99.0 is not met by the emulated exteraGram 13.2.2",
            '__sdk_version__ = ">=1.4.6.6"\n':
                "Version constraint is not satisfied: sdk_version>=1.4.6.6 is not met by the emulated plugin SDK 1.4.6.5",
            '__app_version__ = "12.0"\n': "Version constraint is not satisfied: app_version is not a valid version constraint",
        }
        for metadata, message in cases.items():
            with self.subTest(metadata), self.assertRaises(bridge.BridgeError) as caught:
                bridge.load_plugin(self.text(metadata + "raise RuntimeError('must not execute')\n"))
            self.assertEqual((caught.exception.code, caught.exception.message), ("LOAD_REJECTED", message))
        self.assertEqual(self.authorizations(), [])
        self.assertEqual(bridge.runtime.scopes, {})


if __name__ == "__main__":
    unittest.main()
