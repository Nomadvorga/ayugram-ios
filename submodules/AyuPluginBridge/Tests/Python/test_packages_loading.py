"""Loading plugin packages through the bridge lifecycle; test-authored archives and a fake host only."""
from __future__ import annotations

import json
import os
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_bridge as fixtures
from test_packages_inspection import METAINFO, write_archive

import _ayu_packages as packages
import ayu_bridge as bridge

MAIN = '''
from base_plugin import BasePlugin
import helpers
import src.tools
from src.tools import describe
from . import sibling
import config
import notes
from elyx import metainfo, refmap, settings, strings, assets, Strings, get_environment
import elyx


class Plugin(BasePlugin):
    def on_plugin_load(self):
        settings.set("loaded", True)
        self.seen = {
            "module": __name__, "file": __file__, "helpers": helpers.VALUE, "tools": src.tools.__name__,
            "describe": describe(), "sibling": sibling.NAME, "config": (config.limit, config["nested"]["deep"]),
            "notes": notes.content, "meta": (metainfo["id"], metainfo.get("version")), "refmap": refmap["main"],
            "string": (strings.greeting, strings("hello", "A"), strings.get("missing"), strings.pluralize(3, "items")),
            "asset": (assets.icon.content_string(), assets.get("data/table.json").content(), "icon" in assets,
                      os.path.isfile(assets.get("icon.svg").path_str)),
            "environment": sorted(get_environment()), "setting": elyx.settings("loaded"),
            "strings_type": isinstance(strings, Strings),
        }

    def create_settings(self):
        from ui.settings import Header
        return [Header(strings.greeting)]
'''.replace("\nfrom base_plugin", "import os\nfrom base_plugin", 1)

FILES = {
    "refmap.yml": "main: main.py\nmetainfo: meta.yml\nstrings: locales\nassets: res\n",
    "meta.yml": METAINFO + "description: '{greeting} package'\nauthor: tests\n",
    "main.py": MAIN,
    "helpers.py": "import ui.settings\nVALUE = 'root helper'\n",
    "sibling.py": "NAME = __name__\n",
    "src/__init__.py": "",
    "src/tools.py": "from . import inner\nimport helpers\ndef describe():\n    return inner.WHERE + ' via ' + helpers.VALUE\n",
    "src/inner.py": "WHERE = __name__\n",
    "config.json": '{"limit": 5, "nested": {"deep": true}}',
    "notes.txt": "plain notes",
    "locales/strings_en.yml": "greeting: Hello\nhello: 'Hello {}'\nitems: [item, items, items]\n",
    "locales/strings_ru.yml": "greeting: Privet\n",
    "res/icon.svg": "<svg/>",
    "res/data/table.json": '{"rows": 2}',
}


def declare_size(path, entry, size):
    """Rewrite the unpacked size an archive's directory declares for one entry."""
    with open(path, "rb") as stream:
        raw = bytearray(stream.read())
    name, position = entry.encode("utf-8"), raw.find(b"PK\x01\x02")
    while position >= 0 and bytes(raw[position + 46:position + 46 + len(name)]) != name:
        position = raw.find(b"PK\x01\x02", position + 4)
    struct.pack_into("<L", raw, position + 24, size)
    with open(path, "wb") as stream:
        stream.write(raw)


def leftovers(root):
    return sorted(name for _, _, names in os.walk(root) for name in names if name.endswith(".ayu-unpack"))


class Case(unittest.TestCase):
    def setUp(self):
        fixtures.BridgeTests.setUp(self)
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        environment = patch.dict(os.environ, {"HOME": self.home.name, "LANG": "en_US.UTF-8", "LC_ALL": "",
                                              "LC_MESSAGES": ""})
        environment.start()
        self.addCleanup(environment.stop)
        self.modules = set(sys.modules)
        self.path = list(sys.path)

    def tearDown(self):
        fixtures.BridgeTests.tearDown(self)
        leaked = sorted(name for name in set(sys.modules) - self.modules
                        if name.startswith(packages.PLUGIN_NAMESPACE + ".") or name in ("beside", "helpers"))
        self.assertEqual(leaked, [])
        self.assertEqual(sys.path, self.path)

    def archive(self, files=None, name="synthetic.elyx", **extra):
        content = dict(FILES)
        content.update(files or {})
        content.update(extra)
        return write_archive(self.directory.name, {key: data for key, data in content.items() if data is not None},
                             name)

    def load(self, files=None, expected_id="sample", **extra):
        bridge.load_package(self.archive(files, **extra), "synthetic.elyx", expected_id)
        return bridge.runtime.scopes[expected_id]

    def root(self, plugin_id="sample"):
        return os.path.join(os.path.realpath(self.home.name), "Library", "Application Support", "AyuPluginFiles",
                            "plugins", "ElyxPlugins", plugin_id)


class LoadTests(Case):
    def test_package_loads_with_its_modules_environment_and_files(self):
        scope = self.load()
        plugin = scope.instance
        root = self.root()
        self.assertEqual(os.path.realpath(plugin.seen.pop("file")), os.path.join(root, "main.py"))
        self.assertEqual(plugin.seen, {
            "module": "ElyxPlugins.sample.main", "helpers": "root helper", "tools": "ElyxPlugins.sample.src.tools",
            "describe": "ElyxPlugins.sample.src.inner via root helper", "sibling": "ElyxPlugins.sample.sibling",
            "config": (5, True), "notes": "plain notes", "meta": ("sample", 1.2), "refmap": "main.py",
            "string": ("Hello", "Hello A", "missing", "3 items"),
            "asset": ("<svg/>", {"rows": 2}, True, True),
            "environment": ["assets", "metainfo", "refmap", "settings", "strings"], "setting": True,
            "strings_type": True})
        with bridge.runtime.context(scope):
            self.assertEqual((plugin.id, plugin.name, plugin.version, plugin.author, plugin.description),
                             ("sample", "Synthetic Package", "1.2", "tests", "Hello package"))
            self.assertEqual(plugin.strings["ru"], {"greeting": "Privet"})
        self.assertEqual(scope.state, "active")
        self.assertEqual(self.host.settings["sample"], {"loaded": True})
        self.assertEqual(json.loads(bridge.serialize_settings("sample")), [{"type": "Header", "text": "Hello"}])
        authorize = next(r for r in self.host.requests if r["operation"] == "plugin.authorize")
        self.assertEqual(authorize["arguments"]["metadata"]["__id__"], "sample")
        self.assertEqual(authorize["arguments"]["version_policy"]["sdk_version"], "1.4.6.5")
        self.assertNotIn("helpers", authorize["arguments"]["imports"])
        self.assertTrue(os.path.isfile(os.path.join(root, "res", "data", "table.json")))
        bridge.unload_plugin("sample")
        self.assertNotIn("sample", self.host.active)
        self.assertTrue(os.path.isfile(os.path.join(root, "main.py")))

    def test_strings_follow_the_device_language(self):
        with patch.dict(os.environ, {"LANG": "ru_RU.UTF-8"}):
            scope = self.load()
        self.assertEqual(scope.instance.seen["string"][0], "Privet")
        self.assertEqual(scope.instance.seen["string"][1], "Hello A")

    def test_reload_runs_the_new_archive_and_generations_do_not_share_modules(self):
        first = self.load().instance.seen["helpers"]
        bridge.unload_plugin("sample")
        scope = self.load({"helpers.py": "VALUE = 'second generation'\n"})
        self.assertEqual((first, scope.instance.seen["helpers"]), ("root helper", "second generation"))
        with self.assertRaisesRegex(bridge.BridgeError, "ALREADY_LOADED"):
            bridge.load_package(self.archive(), "synthetic.elyx", "sample")

    def test_modules_beside_the_main_file_load_from_the_unpacked_package(self):
        main = ("import os, sys\nsys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))\n"
                "import beside\nfrom base_plugin import BasePlugin\n"
                "class Plugin(BasePlugin):\n    def on_plugin_load(self):\n        self.where = beside.__file__\n")
        scope = self.load({"refmap.yml": "main: pkg/main.py\nmetainfo: meta.yml\n", "pkg/main.py": main,
                           "pkg/beside.py": "VALUE = 1\n", "main.py": None})
        self.assertEqual(os.path.realpath(scope.instance.where), os.path.join(self.root(), "pkg", "beside.py"))
        self.assertIn("beside", sys.modules)
        bridge.unload_plugin("sample")
        self.assertNotIn("beside", sys.modules)

    def test_other_packages_are_dependencies_and_the_finder_serves_the_own_package_only(self):
        other = ("from base_plugin import BasePlugin\nclass Plugin(BasePlugin):\n    def on_plugin_load(self):\n"
                 "        import importlib\n        import ElyxPlugins.other.main as own\n        self.own = own.__name__\n"
                 "        try:\n            importlib.import_module('ElyxPlugins.sample.helpers')\n"
                 "            self.result = 'imported'\n        except ImportError:\n            self.result = 'refused'\n")
        path = write_archive(self.directory.name, {"metainfo.yml": "id: other\nname: Other\n", "main.py": other},
                             "other.elyx")
        bridge.load_package(path, "other.elyx", "other")
        other_plugin = bridge.runtime.scopes["other"].instance
        # No module of an unloaded or foreign package is found for this plugin.
        self.assertEqual((other_plugin.result, other_plugin.own), ("refused", "ElyxPlugins.other.main"))
        self.load()
        blocked = write_archive(self.directory.name, {
            "metainfo.yml": "id: third\nname: Third\n",
            "main.py": "import ElyxPlugins.sample.helpers\nfrom base_plugin import BasePlugin\nclass P(BasePlugin):\n    pass\n"},
            "third.elyx")
        with self.assertRaisesRegex(bridge.BridgeError, "DEPENDENCY ElyxPlugins.sample.helpers"):
            bridge.load_package(blocked, "third.elyx", "third")
        plain = fixtures.source("plain", "    def on_plugin_load(self):\n        import elyx\n"
                                         "        self.public = elyx.LazyDict(a=1).a\n"
                                         "        self.bound = hasattr(elyx, 'settings')\n")
        bridge.load_plugin(plain, expected_id="plain")
        self.assertEqual((bridge.runtime.scopes["plain"].instance.public, bridge.runtime.scopes["plain"].instance.bound),
                         (1, False))
        import elyx
        import elyxcore
        self.assertEqual(elyx.__all__, elyxcore.__all__)
        self.assertTrue(all(getattr(elyx, name) is getattr(elyxcore, name) for name in elyx.__all__))
        report = json.loads(bridge.preflight_plugin_json(fixtures.source(imports="from elyx import Strings, settings\n")))
        self.assertEqual(report["blockers"], [{"code": "SDK_MEMBER", "detail": "elyx.settings"}])


class RejectionTests(Case):
    def assert_rejected(self, files, text, code="LOAD_REJECTED", expected_id="sample"):
        path = self.archive(files)
        with self.assertRaisesRegex(bridge.BridgeError, code) as caught:
            bridge.load_package(path, "synthetic.elyx", expected_id)
        self.assertIn(text, caught.exception.message)
        self.assertEqual(bridge.runtime.scopes, {})
        self.assertEqual(self.host.active, {})

    def test_blocked_packages_are_rejected_before_authorization(self):
        for files, text in (({"helpers.py": "import ctypes\n"}, "IMPORT ctypes"),
                            ({"src/extra.pyc": b"\x00" * 20}, "compiled Python bytecode"),
                            ({"helpers.py": "from org.example import Missing\n"}, "CLASS org.example.Missing"),
                            ({"helpers.py": "import not_bundled\n"}, "DEPENDENCY not_bundled"),
                            ({"helpers.py": "from elyx import mvel_execute\n"}, "SDK_MEMBER elyx.mvel_execute"),
                            ({"helpers.py": "from client_utils import get_send_messages_helper\n"},
                             "OPERATION telegram.send_message (client_utils.get_send_messages_helper)"),
                            ({"meta.yml": METAINFO + "sdk_version: '>=9.0'\n"}, "VERSION_POLICY")):
            with self.subTest(text=text):
                self.assert_rejected(files, text)
        self.assertFalse(any(r["operation"] in ("plugin.authorize", "plugin.activate") for r in self.host.requests))
        self.assertFalse(os.path.exists(self.root()))

    def test_identity_authorization_and_plugin_class_failures_clean_up(self):
        self.assert_rejected(None, "trusted expected ID", expected_id="another")
        self.host.reject_authorization = True
        self.assert_rejected(None, "Synthetic policy rejection")
        self.host.reject_authorization = False
        self.assert_rejected({"main.py": "VALUE = 1\n", "refmap.yml": "main: main.py\nmetainfo: meta.yml\n"},
                             "Could not find a class inheriting from BasePlugin")
        # Android reports a module that fails while it executes as an import failure.
        with self.assertRaises(ImportError) as caught:
            bridge.load_package(self.archive({"helpers.py": "VALUE = 1 / 0\n"}), "synthetic.elyx", "sample")
        self.assertIsInstance(caught.exception.__cause__, ZeroDivisionError)
        self.assertEqual(bridge.runtime.scopes, {})
        self.assertEqual(self.host.active, {})

    def test_load_budget_covers_every_package_module(self):
        previous = bridge.runtime.execution_limits["load"]
        bridge.runtime.execution_limits["load"] = 0.02
        try:
            with self.assertRaisesRegex(bridge.BridgeError, "EXECUTION_TIMEOUT"):
                bridge.load_package(self.archive({"helpers.py": "VALUE = 0\nwhile True:\n    VALUE += 1\n"}),
                                    "synthetic.elyx", "sample")
        finally:
            bridge.runtime.execution_limits["load"] = previous
        self.assertEqual(bridge.runtime.scopes, {})

    def test_unpacking_never_follows_a_link_out_of_the_plugin_directory(self):
        outside = tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)
        root = self.root()
        os.makedirs(root)
        os.symlink(outside.name, os.path.join(root, "res"))
        with self.assertRaisesRegex(bridge.BridgeError, "LOAD_REJECTED"):
            bridge.load_package(self.archive(), "synthetic.elyx", "sample")
        self.assertEqual(os.listdir(outside.name), [])
        self.assertEqual(bridge.runtime.scopes, {})
        os.remove(os.path.join(root, "res"))
        os.symlink(os.path.join(outside.name, "target"), os.path.join(root, "helpers.py"))
        with self.assertRaisesRegex(bridge.BridgeError, "LOAD_REJECTED"):
            bridge.load_package(self.archive(), "synthetic.elyx", "sample")
        self.assertEqual(os.listdir(outside.name), [])

    def test_traversal_entries_never_reach_the_file_system(self):
        for entry in ("../escape.py", "src/../../escape.py", "/escape.py", "res/..", "helpers.py.ayu-unpack"):
            with self.subTest(entry=entry):
                self.assert_rejected({entry: "x = 1\n"}, "unsafe entry path")
        self.assertFalse(any(r["operation"] == "plugin.authorize" for r in self.host.requests))
        self.assertEqual(os.listdir(self.home.name), [])

    def test_links_where_files_belong_are_refused_and_never_written_through(self):
        outside = tempfile.TemporaryDirectory()
        self.addCleanup(outside.cleanup)
        victim = os.path.join(outside.name, "victim.txt")
        with open(victim, "w") as stream:
            stream.write("untouched")
        root = self.root()
        os.makedirs(root)
        for name, destination in (("helpers.py", victim), ("helpers.py.ayu-unpack", victim),
                                  ("notes.txt.ayu-unpack", os.path.join(outside.name, "created")),
                                  ("config.json", os.path.join(outside.name, "created"))):
            with self.subTest(name=name):
                link = os.path.join(root, name)
                # Earlier attempts unpacked the files that precede the refused one.
                if os.path.lexists(link):
                    os.remove(link)
                os.symlink(destination, link)
                with self.assertRaisesRegex(bridge.BridgeError, "LOAD_REJECTED") as caught:
                    bridge.load_package(self.archive(), "synthetic.elyx", "sample")
                self.assertIn("link or directory", caught.exception.message)
                self.assertTrue(os.path.islink(link))
                os.remove(link)
                self.assertEqual(bridge.runtime.scopes, {})
        self.assertEqual(os.listdir(outside.name), ["victim.txt"])
        # A file an interrupted unpack left and a hard link to a foreign file are replaced, not opened.
        with open(os.path.join(root, "helpers.py.ayu-unpack"), "w") as stream:
            stream.write("stale")
        if os.path.lexists(os.path.join(root, "notes.txt")):
            os.remove(os.path.join(root, "notes.txt"))
        os.link(victim, os.path.join(root, "notes.txt"))
        self.load()
        with open(victim) as stream:
            self.assertEqual(stream.read(), "untouched")
        with open(os.path.join(root, "notes.txt")) as stream:
            self.assertEqual(stream.read(), "plain notes")
        self.assertEqual(leftovers(root), [])

    def test_entries_are_streamed_within_the_declared_and_total_limits(self):
        content = bytes((index * 31 + index // 7) % 251 for index in range(300000))
        root = self.root()
        with patch.object(packages, "MAX_ENTRY_BYTES", 100000):
            self.assert_rejected({"res/big.bin": content}, "entry size limit")
        self.assertFalse(any(r["operation"] == "plugin.authorize" for r in self.host.requests))
        # An entry that holds more than its header declares is refused and leaves nothing behind.
        path = self.archive({"res/big.bin": content})
        declare_size(path, "res/big.bin", 1000)
        with self.assertRaisesRegex(bridge.BridgeError, "LOAD_REJECTED") as caught:
            bridge.load_package(path, "synthetic.elyx", "sample")
        self.assertIn("res/big.bin cannot be read", caught.exception.message)
        self.assertFalse(os.path.exists(os.path.join(root, "res", "big.bin")))
        self.assertEqual((leftovers(root), bridge.runtime.scopes), ([], {}))
        # The total is counted over what is written, entry by entry.
        package = packages.Package(self.archive({"res/big.bin": content}))
        self.addCleanup(package.close)
        scratch = os.path.join(self.directory.name, "unpacked")
        with patch.object(packages, "MAX_TOTAL_BYTES", 200000):
            with self.assertRaisesRegex(bridge.BridgeError, "unpacked size limit"):
                packages._unpack(package, scratch)
        self.assertEqual(leftovers(scratch), [])
        self.assertFalse(os.path.exists(os.path.join(scratch, "res", "big.bin")))
        # A large file is never held whole: it is read in chunks, and never through Package.read.
        sizes, limits = [], []
        chunks, read = packages.Package.chunks, packages.Package.read

        def counted(package, name):
            for data in chunks(package, name):
                sizes.append(len(data))
                yield data

        def limited(package, name, limit):
            limits.append(limit)
            return read(package, name, limit)

        with patch.object(packages, "CHUNK_BYTES", 4096), patch.object(packages.Package, "chunks", counted), \
                patch.object(packages.Package, "read", limited):
            self.load({"res/big.bin": content})
        self.assertEqual((max(sizes), max(limits)), (4096, packages.MAX_SOURCE_BYTES))
        self.assertGreater(len(sizes), 300000 // 4096)
        with open(os.path.join(root, "res", "big.bin"), "rb") as stream:
            self.assertEqual(stream.read(), content)
        self.assertEqual(leftovers(root), [])

    def test_missing_container_fails_explicitly(self):
        with patch.dict(os.environ, {"HOME": "missing/relative"}):
            with self.assertRaises(bridge.UnsupportedAPI):
                bridge.load_package(self.archive(), "synthetic.elyx", "sample")
        self.assertEqual(bridge.runtime.scopes, {})
        self.assertEqual(self.host.active, {})


if __name__ == "__main__":
    unittest.main()
