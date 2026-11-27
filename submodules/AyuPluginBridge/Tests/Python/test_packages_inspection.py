"""Static inspection of plugin packages; archives are built by the tests and never executed here."""
from __future__ import annotations

import datetime
import json
import os
import tempfile
import unittest
import warnings
import zipfile
from unittest.mock import patch

import test_bridge as fixtures

import _ayu_packages as packages
import _ayu_yaml
import ayu_bridge as bridge

MAIN = "from base_plugin import BasePlugin\nclass Plugin(BasePlugin):\n    pass\n"
METAINFO = "id: sample\nname: Synthetic Package\nversion: 1.2\n"


def write_archive(directory, files, name="synthetic.elyx"):
    path = os.path.join(directory, name)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            for entry, data in files.items():
                if isinstance(entry, zipfile.ZipInfo):
                    archive.writestr(entry, data)
                else:
                    archive.writestr(entry, data)
    return path


class Case(unittest.TestCase):
    def setUp(self):
        fixtures.BridgeTests.setUp(self)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    tearDown = fixtures.BridgeTests.tearDown

    def archive(self, files=None, **extra):
        content = {"metainfo.yml": METAINFO, "main.py": MAIN}
        content.update(files or {})
        content.update(extra)
        return write_archive(self.directory.name, {name: data for name, data in content.items() if data is not None})

    def preflight(self, files=None, **extra):
        return json.loads(bridge.preflight_package_json(self.archive(files, **extra)))

    def rejected(self, path, text):
        with self.assertRaisesRegex(bridge.BridgeError, "LOAD_REJECTED") as caught:
            bridge.preflight_package_json(path)
        self.assertIn(text, caught.exception.message)
        self.assertEqual(self.host.active, {})


class ArchiveTests(Case):
    def test_minimal_package_passes_without_authorizing_or_executing(self):
        report = self.preflight({"main.py": MAIN + "raise RuntimeError('must not execute')\n"})
        self.assertEqual(report["blockers"], [])
        self.assertEqual(report["metadata"], {
            "__id__": "sample", "__name__": "Synthetic Package", "__description__": "Description not provided",
            "__author__": "Unknown author", "__version__": "1.2"})
        self.assertEqual((report["main"], report["modules"], report["entries"]), ("main.py", ["main.py"], 2))
        self.assertEqual([r["operation"] for r in self.host.requests], ["runtime.capabilities"])
        self.assertEqual(bridge.runtime.scopes, {})

    def test_unsafe_entry_paths_are_rejected(self):
        link = zipfile.ZipInfo("link.py")
        link.external_attr = 0o120777 << 16
        for index, files in enumerate((
                {"../escape.py": ""}, {"/absolute.py": ""}, {"a/../b.py": ""}, {"a\\b.py": ""}, {"a//b.py": ""},
                {"./a.py": ""}, {"c:evil.py": ""}, {"x" * 600 + ".py": ""},
                {"/".join("d" for _ in range(40)) + ".py": ""}, {link: "target"})):
            with self.subTest(index=index):
                self.rejected(self.archive(files), "unsafe entry path" if index < 9 else "symbolic link")
        self.rejected(self.archive({"Main.PY": "", "main.py": MAIN, "MAIN.py": ""}), "duplicate")
        self.rejected(self.archive({"data": "file", "data/inner.py": ""}), "both a file and a directory")

    def test_archive_bounds_and_file_kind(self):
        path = self.archive({"extra.py": "x = 1\n"})
        for name, value, text in (("MAX_ENTRIES", 2, "entry limit"), ("MAX_TOTAL_BYTES", 20, "unpacked size limit"),
                                  ("MAX_ARCHIVE_BYTES", 10, "archive size limit"),
                                  ("MAX_SOURCE_BYTES", 4, "exceeds its size limit"),
                                  ("MAX_DATA_BYTES", 4, "exceeds its size limit"), ("MAX_MODULES", 1, "module limit")):
            with self.subTest(limit=name), patch.object(packages, name, value):
                self.rejected(path, text)
        not_zip = os.path.join(self.directory.name, "plain.elyx")
        with open(not_zip, "w") as stream:
            stream.write("not an archive")
        self.rejected(not_zip, "not a ZIP archive")
        self.rejected(os.path.join(self.directory.name, "absent.elyx"), "unavailable")
        self.rejected(self.directory.name, "regular file")
        os.symlink(path, os.path.join(self.directory.name, "linked.elyx"))
        self.rejected(os.path.join(self.directory.name, "linked.elyx"), "regular file")
        empty = os.path.join(self.directory.name, "empty.elyx")
        zipfile.ZipFile(empty, "w").close()
        self.rejected(empty, "empty")

    def test_encrypted_and_unreadable_archives_are_rejected(self):
        path = self.archive()
        with open(path, "rb") as stream:
            raw = bytearray(stream.read())
        for signature, offset in ((b"PK\x03\x04", 6), (b"PK\x01\x02", 8)):
            position = raw.find(signature)
            while position >= 0:
                raw[position + offset] |= 1
                position = raw.find(signature, position + 4)
        encrypted = os.path.join(self.directory.name, "encrypted.elyx")
        with open(encrypted, "wb") as stream:
            stream.write(raw)
        self.rejected(encrypted, "Encrypted")
        with open(path, "rb") as stream:
            raw = bytearray(stream.read())
        start = raw.find(b"PK\x03\x04", raw.find(b"main.py") - 40)
        raw[start + 40] ^= 0xFF
        corrupt = os.path.join(self.directory.name, "corrupt.elyx")
        with open(corrupt, "wb") as stream:
            stream.write(raw)
        with self.assertRaisesRegex(bridge.BridgeError, "LOAD_REJECTED"):
            bridge.preflight_package_json(corrupt)

    def test_package_names(self):
        self.assertTrue(all(packages.is_package_name(name) for name in ("a.elyx", "B.EAF", "c.elyx.zip")))
        self.assertFalse(any(packages.is_package_name(name) for name in ("a.plugin", "a.zip", "elyx")))


class ManifestTests(Case):
    def test_refmap_selects_main_metainfo_strings_and_assets(self):
        report = self.preflight({
            "metainfo.yml": None, "main.py": None,
            "refmap.json": json.dumps({"metainfo": "pkg/meta.yml", "main": "pkg/src/main.py", "strings": "pkg/locales",
                                       "assets": "pkg/res", "builder": {"ignored": True}}),
            "pkg/meta.yml": "__id__: refmapped\n__name__: Mapped\n__description__: '{about} here'\nunknown: dropped\n"
                            "app_version: '>=12.0'\ncategory:\n- tools\n- media\n",
            "pkg/src/main.py": MAIN, "pkg/locales/strings_en.yml": "about: English\n",
            "pkg/locales/strings_ru.json": '{"about": "Russian"}', "pkg/locales/readme.txt": "ignored",
            "pkg/res/icon.svg": "<svg/>", "pkg/res/tool.py": "import not_inspected_asset\n"})
        self.assertEqual(report["blockers"], [])
        self.assertEqual(report["metadata"]["__id__"], "refmapped")
        self.assertEqual(report["metadata"]["__description__"], "English here")
        self.assertEqual(report["metadata"]["__category__"], "tools,media")
        self.assertEqual(report["metadata"]["__app_version__"], ">=12.0")
        self.assertEqual(report["modules"], ["pkg/src/main.py"])
        self.assertEqual(report["refmap"]["main"], "pkg/src/main.py")

    def test_invalid_manifests_are_rejected(self):
        cases = (
            ({"metainfo.yml": None}, "Metainfo not found"),
            ({"metainfo.yml": "name: No id\n"}, "non-empty '__id__'"),
            ({"metainfo.yml": "id: 9lives\nname: Starts with a digit\n"}, "start with a letter"),
            ({"metainfo.yml": "id: bad-id\nname: Dash\n"}, "start with a letter"),
            ({"metainfo.yml": "- not\n- a mapping\n"}, "must hold a mapping"),
            ({"metainfo.yml": "id: [unterminated\n"}, "not valid YML"),
            ({"metainfo.yml": None, "metainfo.json": "{broken"}, "not valid JSON"),
            ({"metainfo.yml": METAINFO + "anchored: &a 1\n"}, "not valid YML"),
            ({"main.py": None}, "Main file not found"),
            ({"refmap.yml": "main: missing.py\n"}, "not in the package"),
            ({"refmap.yml": "main: ../main.py\n"}, "safe relative path"),
            ({"refmap.yml": "main: main.py\nassets: missing\n"}, "Assets directory not found"),
            ({"refmap.yml": "main: main.py\nstrings: missing\n"}, "Strings named by the refmap"),
            ({"refmap.yml": "main: main.py\nmetainfo: missing.yml\n"}, "Metainfo not found"),
            ({"refmap.yml": "main: [a]\n"}, "must be a path"),
            ({"metainfo.yml": METAINFO + "requires:\n  'bad id!': link\n"}, "plugin_id (min_version)"),
            ({"metainfo.yml": METAINFO + "requirements: {a: b}\n"}, "requirements"),
            ({"main.py": "def broken(:\n"}, "not valid UTF-8 Python source"),
            ({"main.py": "from android.view import *\n"}, "Wildcard native imports"),
            ({"refmap.yml": "main: assets/main.py\n", "assets/main.py": MAIN}, "data directory"),
        )
        for files, text in cases:
            with self.subTest(text=text):
                self.rejected(self.archive(files), text)

    def test_metainfo_versions_requirements_and_required_plugins(self):
        report = self.preflight({"metainfo.yml": METAINFO + (
            "app_version: '>=99.0'\nsdk_version: '>=1.4.0'\nrequirements: 'requests>=2, leftpad==1.0'\n"
            "requires:\n  zwylib (2.0.6): https://example.invalid/a\n  zwylib (9.0): https://example.invalid/b\n"
            "  other_plugin: https://example.invalid/c\n")})
        blockers = {(item["code"], item["detail"]) for item in report["blockers"]}
        self.assertIn(("PACKAGE", "required plugin other_plugin"), blockers)
        self.assertIn(("PACKAGE", "required plugin zwylib"), blockers)
        self.assertEqual(sum(code == "PACKAGE" for code, _ in blockers), 2)
        self.assertTrue(any(code == "VERSION_POLICY" and "99.0" in detail for code, detail in blockers))
        self.assertTrue(any(code == "REQUIREMENT" and detail.startswith("leftpad") for code, detail in blockers))
        self.assertEqual(report["requirements"], ["requests>=2", "leftpad==1.0"])

    def test_bytecode_wheels_and_android_binaries_are_reported(self):
        report = self.preflight({"refmap.yml": "main: main.py\nwheels: wheels\n", "wheels/x-1.0-py3-none-any.whl": b"PK",
                                 "lib/fast.pyc": b"\x00" * 20, "assets/engine.dex": b"dex"})
        self.assertEqual(sorted(item["detail"] for item in report["blockers"]),
                         ["bundled wheels", "compiled Python bytecode"])
        self.assertTrue(any(warning.startswith("NATIVE_PAYLOAD") for warning in report["warnings"]))
        report = self.preflight({"refmap.yml": "main: src/main.pyc\n", "main.py": None, "src/main.pyc": b"\x00" * 20})
        self.assertEqual([item["detail"] for item in report["blockers"]], ["compiled Python bytecode"])
        self.assertEqual(report["modules"], [])


class AnalysisTests(Case):
    def test_own_modules_are_not_dependencies_and_foreign_ones_are(self):
        report = self.preflight({
            "main.py": MAIN + "import helpers\nimport src.tools\nfrom src import tools\nfrom . import sibling\n"
                              "import config\nimport notes\nimport json, missing_library\nfrom other.pkg import thing\n",
            "helpers.py": "import ui\nfrom ui.settings import Header\nimport nested_only\n",
            "src/tools.py": "import beside\nfrom .beside import value\nimport helpers\n", "src/beside.py": "value = 1\n",
            "ui.py": "shadowing_an_sdk_root = True\n", "config.json": "{}", "notes.txt": "text",
            "deep/a/b.py": "import nested_only\nimport c\n", "deep/a/c.py": "", "deep/nested_only.py": ""})
        self.assertEqual(sorted(item["detail"] for item in report["blockers"] if item["code"] == "DEPENDENCY"),
                         ["missing_library", "nested_only", "other.pkg"])
        self.assertEqual([item for item in report["blockers"] if item["code"] != "DEPENDENCY"], [])
        self.assertEqual(len(report["modules"]), 8)

    def test_every_module_gets_the_plugin_preflight_checks(self):
        report = self.preflight({
            "main.py": MAIN + "from . import worker\n",
            "worker.py": "import ctypes, threading\nfrom android_utils import not_a_member\nimport zwylib\n"
                         "zwylib.DialogPicker\nfrom java import jclass\njclass('org.example.Missing')\n"
                         "from org.example.widgets import Widget\njclass(name_computed_at_runtime)\n"})
        self.assertEqual({(item["code"], item["detail"]) for item in report["blockers"]}, {
            ("IMPORT", "ctypes"), ("SDK_MEMBER", "android_utils.not_a_member"), ("SDK_MEMBER", "zwylib.DialogPicker"),
            ("CLASS", "org.example.Missing"), ("CLASS", "org.example.widgets.Widget")})
        self.assertTrue(any(warning.startswith("DYNAMIC_CLASSES") for warning in report["warnings"]))
        self.host.capabilities["operations"].remove("scheduler.schedule")
        report = self.preflight({"main.py": MAIN + "import threading\n"})
        self.assertEqual(report["blockers"], [{"code": "IMPORT", "detail": "threading"}])

    def test_elyx_names_follow_the_package(self):
        source = (MAIN + "import elyx\nfrom elyx import Asset, Assets, Strings, SettingsController, LazyDict, gen, gen2\n"
                         "from elyx import settings, metainfo, refmap, get_environment, import_module, Runnable\n"
                         "elyx.strings\nfrom elyx import assets\n")
        report = self.preflight({"main.py": source})
        self.assertEqual(sorted(item["detail"] for item in report["blockers"]), ["elyx.assets", "elyx.strings"])
        report = self.preflight({"main.py": source, "assets/a.txt": "a", "strings/strings_en.yml": "k: v\n"})
        self.assertEqual(report["blockers"], [])
        report = self.preflight({"main.py": MAIN + "from elyx import mvel_execute, paths\nimport elyx.sub\n"})
        self.assertEqual(sorted(item["detail"] for item in report["blockers"]),
                         ["elyx.mvel_execute", "elyx.paths", "elyx.sub"])
        report = json.loads(bridge.preflight_plugin_json(fixtures.source(
            imports="from elyxcore import Runnable, get_environment, Strings\nfrom elyxcore.utils import gen\n"
                    "from elyxcore import mvel_execute\n")))
        self.assertEqual(report["blockers"], [{"code": "SDK_MEMBER", "detail": "elyxcore.mvel_execute"}])

    def test_host_backed_sdk_entry_points_need_their_operations_in_every_module(self):
        files = {
            "main.py": MAIN + "import worker\nfrom wrappers import send_text\n"
                              "def use(plugin, target):\n    plugin.add_hook('name')\n    target.send_text(1, 'x')\n"
                              "    target.edit_message(1)\n",
            "worker.py": "from client_utils import get_send_messages_helper\nimport client_utils\n"
                         "def run():\n    client_utils.send_request(None, None)\n",
            # A method name the package defines itself is the package's own, whichever module calls it.
            "wrappers.py": "def send_text(peer, text):\n    return (peer, text)\n"}
        report = self.preflight(files)
        self.assertEqual(sorted(report["sdk_requirements"]), [
            "add_hook()", "client_utils.get_send_messages_helper", "client_utils.send_request", "edit_message()"])
        self.assertEqual([(item["code"], item["detail"]) for item in report["blockers"]], [
            ("OPERATION", "telegram.hooks.set (add_hook())"),
            ("OPERATION", "telegram.send_message (client_utils.get_send_messages_helper)"),
            ("OPERATION", "telegram.request (client_utils.send_request)"),
            ("OPERATION", "telegram.edit_message (edit_message())")])
        self.host.capabilities["operations"] += ["telegram.hooks.set", "telegram.send_message", "telegram.request"]
        self.assertEqual([item["detail"] for item in self.preflight(files)["blockers"]],
                         ["telegram.edit_message (edit_message())"])
        self.host.capabilities["operations"].append("telegram.edit_message")
        self.assertEqual(self.preflight(files)["blockers"], [])


class MeterTests(Case):
    def test_corpus_meter_counts_packages_without_executing_them(self):
        import sys
        from pathlib import Path
        sys.path.insert(0, str(Path(__file__).resolve().parents[4]))
        try:
            from tools.plugin_inspector import preflight
        finally:
            sys.path.pop(0)
        corpus = Path(self.directory.name, "corpus")
        corpus.mkdir()
        write_archive(str(corpus), {"metainfo.yml": METAINFO, "main.py": MAIN + "raise RuntimeError('never run')\n"},
                      "passing.elyx")
        write_archive(str(corpus), {"metainfo.yml": METAINFO, "main.py": MAIN + "import ctypes\n", "x.pyc": b"0"},
                      "blocked.eaf")
        write_archive(str(corpus), {"main.py": MAIN}, "no_manifest.elyx")
        (corpus / "broken.elyx").write_text("not an archive", encoding="utf-8")
        (corpus / "plain.plugin").write_text(fixtures.source(), encoding="utf-8")
        capabilities = {"operations": list(fixtures.OPERATIONS), "classes": ["android.view.View"], "modules": [],
                        "proxy_interfaces": {}}
        report = preflight.preflight_corpus(corpus, capabilities=capabilities, top=10)
        self.assertEqual((report["plugins"], report["passing"]), (1, 1))
        summary = report["packages"]
        self.assertEqual((summary["packages"], summary["inspectable"], summary["passing"], summary["blocked"],
                          summary["rejected"]), (4, 2, 1, 1, 2))
        self.assertEqual(summary["blocked_by_kind"], {"IMPORT": 1, "PACKAGE": 1})
        self.assertEqual(summary["blockers"]["PACKAGE"]["ranked"],
                         [{"detail": "compiled Python bytecode", "packages": 1}])
        self.assertEqual(summary["rejections"], [{"reason": "LOAD_REJECTED", "packages": 2}])
        text = preflight.render_text(report)
        self.assertIn("inspectable 2   pass 1   blocked 1   rejected 2", text)
        self.assertNotIn("never run", text)


class YAMLTests(unittest.TestCase):
    def test_block_and_flow_structures(self):
        document = ("# manifest\nid: sample\nname: 'It''s a\n  folded name'\ndescription: plain text that\n"
                    "  continues\n\n  after a blank line\ncategory:\n- tools\n- media\nnested:\n  flow: [1, two, {k: v}]\n"
                    "  map: {a: 1, 'b c': \"d\\te\"}\n  empty:\nitems:\n  - name: first\n    value: 1\n  - - inner\n"
                    "literal: |\n  line one\n   indented\n\n  line three\nfolded: >-\n  joined\n  words\n"
                    "\"quoted key\": \"multi\n  line \\\n  joined\\u00e9\"\n")
        self.assertEqual(_ayu_yaml.safe_load(document), {
            "id": "sample", "name": "It's a folded name", "description": "plain text that continues\nafter a blank line",
            "category": ["tools", "media"],
            "nested": {"flow": [1, "two", {"k": "v"}], "map": {"a": 1, "b c": "d\te"}, "empty": None},
            "items": [{"name": "first", "value": 1}, ["inner"]],
            "literal": "line one\n indented\n\nline three\n", "folded": "joined words",
            "quoted key": "multi line joined\u00e9"})

    def test_scalars_resolve_like_pyyaml(self):
        loaded = _ayu_yaml.safe_load(
            "a: yes\nb: No\nc: ~\nd: 0x1f\ne: 010\nf: 1_000\ng: 1:30\nh: 1.5\ni: 1e3\nj: 2026-11-09\n"
            "k: 2026-11-09 10:20:30\nl: '1.0'\nm: 1.0\nn: 1.3.1\no: -.inf\np: 0o17\nq: +5\nr: on\n1: int key\n")
        self.assertEqual(loaded, {
            "a": True, "b": False, "c": None, "d": 31, "e": 8, "f": 1000, "g": 90, "h": 1.5, "i": "1e3",
            "j": datetime.date(2026, 11, 9), "k": datetime.datetime(2026, 11, 9, 10, 20, 30), "l": "1.0", "m": 1.0,
            "n": "1.3.1", "o": float("-inf"), "p": "0o17", "q": 5, "r": True, 1: "int key"})
        self.assertIs(type(loaded["a"]), bool)
        self.assertIsNone(_ayu_yaml.safe_load(""))
        self.assertIsNone(_ayu_yaml.safe_load("# only a comment\n"))
        self.assertEqual(_ayu_yaml.safe_load(b"\xef\xbb\xbf---\na: 1\n...\n"), {"a": 1})

    def test_unsupported_or_malformed_yaml_fails_explicitly(self):
        for document in ("a: &anchor 1\n", "a: *alias\n", "a: !!str 1\n", "? complex\n: value\n", "a: <<\n",
                         "%YAML 1.1\n---\na: 1\n", "a: 1\n---\nb: 2\n", "a: 1\n b: 2\n", "a: b: c\n", "a:\n\tb: 1\n",
                         "a: 'unterminated\n", 'a: "bad \\q"\n', "a: [1, 2\n", "a: - x\n", "a: text # c\n  more\n",
                         "a: " + "[" * 80 + "]" * 80 + "\n", b"\xff\xfe"):
            with self.subTest(document=document), self.assertRaises(_ayu_yaml.YAMLError):
                _ayu_yaml.safe_load(document)
        with patch.object(_ayu_yaml, "MAX_CHARS", 8), self.assertRaises(_ayu_yaml.YAMLError):
            _ayu_yaml.safe_load("key: a long value\n")
        with patch.object(_ayu_yaml, "MAX_NODES", 5), self.assertRaises(_ayu_yaml.YAMLError):
            _ayu_yaml.safe_load("a: [1, 2, 3, 4, 5, 6]\n")
        with self.assertRaises(TypeError):
            _ayu_yaml.safe_load(1)


if __name__ == "__main__":
    unittest.main()
