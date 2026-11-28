"""Pinned third-party distributions: requirement matching and host declaration.

Synthetic metadata only. No distribution is installed, imported or downloaded here.
"""
import json
import re
import unittest
from pathlib import Path

import test_bridge as fixtures
import _ayu_policy as policy
import ayu_bridge as bridge

BRIDGE = Path(__file__).resolve().parents[2]
REPO = BRIDGE.parents[1]
LOCK = REPO / "third-party" / "ayu-python" / "packages.lock.json"


def host_modules():
    """The module names the Swift host declares in ``runtime.capabilities``."""
    text = (BRIDGE / "Sources" / "AyuPluginNativeHost.swift").read_text(encoding="utf-8")
    body = re.search(r"\bstatic\s+let\s+modules\s*=\s*\[([^\]]*)\]", text).group(1)
    body = "\n".join(line for line in body.splitlines() if not line.lstrip().startswith("//"))
    return re.findall(r'"([^"\\]+)"', body)


class PipVersionTests(unittest.TestCase):
    """``PipController.VersionComparator`` and ``checkVersionSatisfies`` of exteraGram b4d852f."""

    def test_release_components_compare_numerically_with_missing_ones_zero(self):
        ordered = ["0.9", "1.0", "1.0.1", "1.2", "1.10", "1.47", "1.48.1", "2", "2026.8.19", "2026.11.23"]
        for index, low in enumerate(ordered):
            self.assertEqual(policy.compare_pip_versions(low, low), 0)
            for high in ordered[index + 1:]:
                with self.subTest(low=low, high=high):
                    self.assertLess(policy.compare_pip_versions(low, high), 0)
                    self.assertGreater(policy.compare_pip_versions(high, low), 0)
        for left, right in (("1.0", "1.0.0"), ("1", "1.0.0.0"), ("1.01", "1.1"), ("v1.2", "1.2"), (" 1.2 ", "1.2"),
                            ("1.2+local.7", "1.2"), ("1.0RC1", "1.0rc1")):
            with self.subTest(left=left, right=right):
                self.assertEqual(policy.compare_pip_versions(left, right), 0)

    def test_pre_and_post_releases_order_around_the_release(self):
        ordered = ["1.0.dev1", "1.0a1", "1.0a2", "1.0b1", "1.0rc1", "1.0", "1.0.post1", "1.1"]
        for index, low in enumerate(ordered):
            for high in ordered[index + 1:]:
                with self.subTest(low=low, high=high):
                    self.assertLess(policy.compare_pip_versions(low, high), 0)
                    self.assertGreater(policy.compare_pip_versions(high, low), 0)
        self.assertEqual(policy.compare_pip_versions("1.0alpha1", "1.0a1") < 0, False)  # same weight, then text order
        self.assertEqual(policy.compare_pip_versions("1.0c1", "1.0rc1") < 0, True)

    def test_epoch_dominates_and_a_malformed_one_is_zero(self):
        self.assertGreater(policy.compare_pip_versions("1!1.0", "2.0"), 0)
        self.assertLess(policy.compare_pip_versions("1!9", "2!1"), 0)
        self.assertEqual(policy.compare_pip_versions("x!1.0", "1.0"), 0)
        self.assertEqual(policy.compare_pip_versions("0!1.0", "1.0"), 0)

    def test_a_component_beyond_32_bits_compares_as_text_below_any_number(self):
        # Kotlin's toIntOrNull yields null there, and a number outranks a non-number.
        self.assertLess(policy.compare_pip_versions("1.2147483648", "1.0"), 0)
        self.assertEqual(policy.compare_pip_versions("1.2147483647", "1.2147483647"), 0)

    def test_specifiers_are_parsed_as_android_does(self):
        cases = {
            "mutagen": [],
            "mutagen>=1.47,<2": [(">=", "1.47"), ("<", "2")],
            "mutagen == 1.48.1": [("==", "1.48.1")],
            "one (>=1.0, !=1.5)": [(">=", "1.0"), ("!=", "1.5")],
            "requests[socks]>=2 ; python_version < '3'": [(">=", "2")],
            "pkg~=1.4.2": [("~=", "1.4.2")],
            "pkg===1.0": [("===", "1.0")],
            "pkg>=1,nonsense,<=3": [(">=", "1"), ("<=", "3")],
            "pkg 1.0": [],
            "pkg=1.0": [],
            "@odd>=1": [],
            "pkg>=1\n,<0": [(">=", "1")],
        }
        for requirement, specifiers in cases.items():
            with self.subTest(requirement):
                self.assertEqual(policy.requirement_specifiers(requirement), specifiers)

    def test_every_specifier_must_hold(self):
        satisfied = {
            "1.48.1": ["==1.48.1", ">=1.47,<2", ">1.48", "<=1.48.1", "!=1.48.0", "==1.48.*", "==1.*", "!=1.47.*",
                       "~=1.47", "~=1.48.0", "~=1.48.1", "===1.48.1", "==1.48.1.0", ">=1.48.1rc1", "==*"],
            "2026.11.23": [">=2025.1.0", "!=2026.8.19", "~=2026.8"],
        }
        unsatisfied = {
            "1.48.1": ["==1.48.0", "==1.47.0", ">=2", ">1.48.1", "<1.48.1", "<1.0", "!=1.48.1", "==1.47.*", "!=1.48.*",
                       "~=1.49", "~=1.47.0", "~=2.0", "===1.48.1.0", "===v1.48.1", ">=1.47,<1.48", "==2.*"],
            "2026.11.23": ["==2026.8.19", "<2026", "~=2026.8.0"],
        }
        for expected, table in ((True, satisfied), (False, unsatisfied)):
            for version, specifiers in table.items():
                for text in specifiers:
                    with self.subTest(version=version, specifier=text):
                        parsed = policy.requirement_specifiers("pkg" + text)
                        self.assertTrue(parsed)
                        self.assertIs(policy.version_satisfies(version, parsed), expected)
        self.assertTrue(policy.version_satisfies("1.0", []))


class PinnedRequirementTests(unittest.TestCase):
    def test_pinned_distribution_satisfies_only_specifiers_its_version_meets(self):
        version = policy.PINNED_DISTRIBUTIONS["mutagen"][0]
        self.assertEqual(version, "1.48.1")
        for requirement in ("mutagen", "Mutagen", "mutagen==1.48.1", "mutagen>=1.47,<2", "mutagen (>=1.0)",
                            "mutagen>=1.47 ; python_version >= '3.8'"):
            with self.subTest(requirement):
                self.assertEqual(policy.requirement_findings([requirement], {"mutagen"}), [])
        cases = {
            "mutagen==1.47.0": "mutagen (==1.47.0 is not met by the bundled 1.48.1)",
            "mutagen>=2": "mutagen (>=2 is not met by the bundled 1.48.1)",
            "mutagen>=1.47,<1.48": "mutagen (>=1.47,<1.48 is not met by the bundled 1.48.1)",
            "mutagen!=1.48.*": "mutagen (!=1.48.* is not met by the bundled 1.48.1)",
            "mutagen<1." + "0" * 80: "mutagen (<constraint> is not met by the bundled 1.48.1)",
            "mutagen<1.\x070": "mutagen (<constraint> is not met by the bundled 1.48.1)",
        }
        for requirement, finding in cases.items():
            with self.subTest(requirement):
                self.assertEqual(policy.requirement_findings([requirement], {"mutagen"}), [finding])

    def test_pinned_distribution_still_blocks_when_the_host_does_not_declare_its_modules(self):
        for name, (_, modules) in policy.PINNED_DISTRIBUTIONS.items():
            with self.subTest(name):
                self.assertEqual(policy.requirement_findings([name], set()),
                                 [name + " (host does not declare its bundled module)"])
                self.assertEqual(policy.requirement_findings([name], set(modules)), [])
                self.assertEqual(policy.requirement_findings([name], set(modules[:-1])),
                                 [name + " (host does not declare its bundled module)"])

    def test_android_preinstalled_distributions_are_not_version_checked(self):
        # PipController skips its preinstalled set before reading any specifier.
        modules = {"bs4", "packaging", "yaml"}
        self.assertEqual(policy.requirement_findings(
            ["beautifulsoup4==0.1", "PyYAML<1", "packaging>=99", "pyyaml"], modules), [])
        self.assertEqual(policy.requirement_findings(["PyYAML<1"], set()),
                         ["pyyaml (host does not declare its bundled module)"])

    def test_unpinned_distributions_stay_blockers_whatever_the_host_declares(self):
        everything = {module for _, modules in policy.PINNED_DISTRIBUTIONS.values() for module in modules}
        everything |= {"websocket", "yt_dlp", "PIL", "babel", "socks", "nowfy", "alib", "yandex_music", "lxml", "debugpy"}
        self.assertEqual(policy.requirement_findings(
            ["websocket-client>=1.8.0", "yt-dlp==2026.8.19", "yt-dlp-ejs==0.8.0", "babel", "PySocks", "nowfy",
             "exteragram-alib", "yandex-music==3.2.2", "Pillow", "lxml", "debugpy"], everything),
            ["websocket-client", "yt-dlp", "yt-dlp-ejs", "babel", "pysocks", "nowfy", "exteragram-alib", "yandex-music",
             "pillow (bundled by Android exteraGram, not by this bridge)",
             "lxml (bundled by Android exteraGram, not by this bridge)",
             "debugpy (bundled by Android exteraGram, not by this bridge)"])


class PinnedInventoryTests(unittest.TestCase):
    """The policy table, the packaging lock and the Swift declaration describe one set."""

    def test_policy_table_repeats_the_packaging_lock(self):
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        pinned = {package["name"]: (package["version"], tuple(package["modules"])) for package in lock["packages"]}
        self.assertEqual(policy.PINNED_DISTRIBUTIONS, pinned)
        self.assertEqual(len(pinned), len(lock["packages"]))

    def test_table_names_are_normalized_and_do_not_overlap_the_unversioned_table(self):
        for name, (version, modules) in policy.PINNED_DISTRIBUTIONS.items():
            self.assertEqual(policy.distribution_name(name), name)
            self.assertEqual(policy.compare_pip_versions(version, version), 0)
            self.assertTrue(modules and all(isinstance(module, str) and module.isidentifier() for module in modules))
        self.assertFalse(set(policy.PINNED_DISTRIBUTIONS) & set(policy.BUNDLED_DISTRIBUTIONS))
        modules = [module for _, modules in policy.PINNED_DISTRIBUTIONS.values() for module in modules]
        self.assertEqual(len(modules), len(set(modules)))
        self.assertFalse(set(modules) & bridge.SDK_MODULES)

    def test_host_declares_exactly_the_shipped_modules(self):
        declared = host_modules()
        self.assertEqual(len(declared), len(set(declared)))
        pinned = {module for _, modules in policy.PINNED_DISTRIBUTIONS.values() for module in modules}
        self.assertLessEqual(pinned, set(declared))
        sdk = BRIDGE / "Python"
        for name in declared:
            top = name.split(".")[0]
            with self.subTest(module=name):
                # A declared module is an SDK source file or a module of a pinned distribution.
                self.assertTrue(top in pinned or (sdk / (top + ".py")).is_file() or (sdk / top / "__init__.py").is_file())


class BridgePinnedDependencyTests(unittest.TestCase):
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown

    def text(self, metadata="", imports=""):
        return fixtures.source("sample", "    pass\n", imports) + "\n" + metadata

    def blockers(self, metadata="", imports=""):
        report = json.loads(bridge.preflight_plugin_json(self.text(metadata, imports)))
        return [(item["code"], item["detail"]) for item in report["blockers"]]

    def authorizations(self):
        return [item for item in self.host.requests if item["operation"] == "plugin.authorize"]

    def test_preflight_accepts_pinned_imports_and_requirements_the_host_declares(self):
        self.host.capabilities["modules"] = ["mutagen", "cachetools", "yaml", "bs4"]
        imports = ("import mutagen\nfrom mutagen.id3 import ID3\nfrom cachetools import LRUCache\n"
                   "import yaml\nfrom bs4 import BeautifulSoup\n")
        self.assertEqual(self.blockers('__requirements__ = ["mutagen>=1.47,<2", "cachetools", "PyYAML"]\n', imports), [])

    def test_preflight_blocks_pinned_imports_and_requirements_the_host_does_not_declare(self):
        imports = "import mutagen\nfrom mutagen.id3 import ID3\nimport yaml\n"
        self.assertEqual(self.blockers('__requirements__ = "mutagen, cachetools"\n', imports), [
            ("DEPENDENCY", "mutagen"), ("DEPENDENCY", "mutagen.id3"), ("DEPENDENCY", "yaml"),
            ("REQUIREMENT", "mutagen (host does not declare its bundled module)"),
            ("REQUIREMENT", "cachetools (host does not declare its bundled module)")])

    def test_preflight_blocks_a_pin_the_bundled_version_cannot_meet(self):
        self.host.capabilities["modules"] = ["mutagen", "tinydb"]
        self.assertEqual(self.blockers('__requirements__ = ["mutagen==1.47.0", "tinydb>=4", "tinydb>=4,<4.5"]\n'), [
            ("REQUIREMENT", "mutagen (==1.47.0 is not met by the bundled 1.48.1)"),
            ("REQUIREMENT", "tinydb (>=4,<4.5 is not met by the bundled 4.9.0)")])

    def test_load_accepts_a_met_pin_and_sends_the_host_nothing_to_install(self):
        self.host.capabilities["modules"] = ["mutagen"]
        bridge.load_plugin(self.text('__requirements__ = ["mutagen==1.48.1"]\n'))
        self.assertEqual(self.authorizations()[0]["arguments"]["requirements"], [])

    def test_load_rejects_unmet_or_undeclared_pins_before_authorization_and_execution(self):
        cases = [
            (["mutagen"], '__requirements__ = ["mutagen>=2"]\n', "",
             "Requirement is not bundled: mutagen (>=2 is not met by the bundled 1.48.1)"),
            ([], '__requirements__ = ["mutagen"]\n', "",
             "Requirement is not bundled: mutagen (host does not declare its bundled module)"),
            ([], "", "import mutagen\n", "Undeclared dependency: mutagen"),
            (["mutagen"], "", "import websocket\n", "Undeclared dependency: websocket"),
        ]
        for modules, metadata, imports, message in cases:
            self.host.capabilities["modules"] = modules
            with self.subTest(message), self.assertRaises(bridge.BridgeError) as caught:
                bridge.load_plugin(self.text(metadata + "raise RuntimeError('must not execute')\n", imports))
            self.assertEqual((caught.exception.code, caught.exception.message), ("LOAD_REJECTED", message))
        self.assertEqual(self.authorizations(), [])
        self.assertEqual(bridge.runtime.scopes, {})


if __name__ == "__main__":
    unittest.main()
