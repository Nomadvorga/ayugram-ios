"""Bundled shim modules that are plain modules: imports and members they do not have.

``requests`` is one source file the host declares, not a package and not an SDK module. Synthetic
plugins only.
"""
import json
import unittest

import test_bridge as fixtures
import ayu_bridge as bridge


class ShimSubmoduleTests(unittest.TestCase):
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown

    def blockers(self, imports, body="    pass\n"):
        self.host.capabilities["modules"] = ["requests", "requests.exceptions"]
        report = json.loads(bridge.preflight_plugin_json(fixtures.source("sample", body, imports)))
        return [(item["code"], item["detail"]) for item in report["blockers"]]

    def test_requests_is_a_shim_not_an_sdk_module(self):
        self.assertNotIn("requests", bridge.SDK_MODULES)
        self.assertTrue((fixtures.SDK / "requests.py").is_file())
        self.assertFalse((fixtures.SDK / "requests").exists())

    def test_what_the_shim_provides_passes(self):
        imports = ("import requests\nimport requests.exceptions\nfrom requests import Session, get, exceptions\n"
                   "from requests.exceptions import Timeout, RequestException\nfrom requests import __version__\n")
        body = ("    def run(self):\n        try:\n            return requests.get('https://example.invalid').json()\n"
                "        except requests.exceptions.Timeout:\n            return requests.__version__\n")
        self.assertEqual(self.blockers(imports, body), [])

    def test_missing_submodule_imports_are_blockers(self):
        self.assertEqual(self.blockers("from requests.adapters import HTTPAdapter\n"), [("SDK_MEMBER", "requests.adapters")])
        self.assertEqual(self.blockers("import requests.adapters\n"), [("SDK_MEMBER", "requests.adapters")])
        self.assertEqual(self.blockers("import requests.packages.urllib3.util.retry as retry\n"),
                         [("SDK_MEMBER", "requests.packages")])
        self.assertEqual(self.blockers("from requests import adapters, HTTPAdapter, get\n"),
                         [("SDK_MEMBER", "requests.HTTPAdapter"), ("SDK_MEMBER", "requests.adapters")])

    def test_a_missing_submodule_read_through_the_module_is_a_blocker(self):
        body = ("    def run(self, text):\n        adapter = requests.adapters.HTTPAdapter(max_retries=1)\n"
                "        return requests.structures.LookupDict(text), adapter, requests.codes.ok\n")
        self.assertEqual(self.blockers("import requests\n", body), [
            ("SDK_MEMBER", "requests.adapters"), ("SDK_MEMBER", "requests.codes"), ("SDK_MEMBER", "requests.structures")])
        aliased = "    def run(self, text):\n        return http.structures.LookupDict(text)\n"
        self.assertEqual(self.blockers("import requests as http\n", aliased), [("SDK_MEMBER", "requests.structures")])
        present = "    def run(self):\n        return requests.exceptions.Timeout, requests.Session.get\n"
        self.assertEqual(self.blockers("import requests\n", present), [])

    def test_a_plain_member_of_a_shim_is_outside_this_check(self):
        # A shim is not an SDK module, so its own members are not an SDK surface
        # (``test_sdk_inventory`` pins that); only names used as a namespace are checked.
        body = "    def run(self):\n        return requests.not_supported()\n"
        self.assertEqual(self.blockers("import requests\n", body), [])

    def test_an_import_the_plugin_guards_is_not_a_blocker(self):
        guarded = ("try:\n    from requests.adapters import HTTPAdapter\n    import requests.packages\n"
                   "    from requests import structures\nexcept ImportError:\n    HTTPAdapter = None\n")
        self.assertEqual(self.blockers(guarded), [])
        reraised = "try:\n    from requests.adapters import HTTPAdapter\nexcept ImportError:\n    raise\n"
        self.assertEqual(self.blockers(reraised), [("SDK_MEMBER", "requests.adapters")])
        unrelated = "try:\n    from requests.adapters import HTTPAdapter\nexcept ValueError:\n    HTTPAdapter = None\n"
        self.assertEqual(self.blockers(unrelated), [("SDK_MEMBER", "requests.adapters")])

    def test_a_member_probe_is_not_a_blocker_but_a_blanket_handler_is(self):
        probe = ("    def run(self, text):\n        try:\n            return requests.structures.LookupDict(text)\n"
                 "        except AttributeError:\n            return text\n")
        self.assertEqual(self.blockers("import requests\n", probe), [])
        blanket = probe.replace("except AttributeError", "except Exception")
        self.assertEqual(self.blockers("import requests\n", blanket), [("SDK_MEMBER", "requests.structures")])
        deferred = ("    def run(self, text):\n        try:\n            def later():\n"
                    "                return requests.structures.LookupDict(text)\n        except AttributeError:\n            later = None\n"
                    "        return later\n")
        self.assertEqual(self.blockers("import requests\n", deferred), [("SDK_MEMBER", "requests.structures")])

    def test_load_rejects_the_missing_submodule_before_authorization(self):
        self.host.capabilities["modules"] = ["requests", "requests.exceptions"]
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.load_plugin(fixtures.source("sample", "    pass\n", "from requests.adapters import HTTPAdapter\n")
                               + "raise RuntimeError('must not execute')\n")
        self.assertEqual(caught.exception.code, "LOAD_REJECTED")
        self.assertIn("requests.adapters", caught.exception.message)
        self.assertEqual([item for item in self.host.requests if item["operation"] == "plugin.authorize"], [])

    def test_modules_outside_the_sdk_directory_are_not_checked_here(self):
        self.host.capabilities["modules"] = ["yaml"]
        report = json.loads(bridge.preflight_plugin_json(fixtures.source(
            "sample", "    pass\n", "import yaml.tokens\nfrom yaml.missing import nothing\n")))
        self.assertEqual(report["blockers"], [])


if __name__ == "__main__":
    unittest.main()
