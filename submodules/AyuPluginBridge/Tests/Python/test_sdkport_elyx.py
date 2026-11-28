"""Public Elyx API helpers outside the package loader; synthetic data and a fake host only."""
from __future__ import annotations

import io
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import test_bridge as fixtures
from test_sdkport_ui import UIHost

import ayu_bridge as bridge
import elyxcore
from elyxcore.assets import Asset, AssetNotFoundException, Assets, load_data_file, normalize_name
from elyxcore.localization import Strings
from elyxcore.settings import SettingsController
from elyxcore.utils import LazyDict, gen, gen2, hash_map, safe_func


class Case(unittest.TestCase):
    tearDown = fixtures.BridgeTests.tearDown
    load = fixtures.BridgeTests.load

    def setUp(self):
        fixtures.BridgeTests.setUp(self)
        self.host = UIHost()
        sys.modules["_ayu_host"].dispatch = self.host.dispatch


class ProxyTests(Case):
    def test_generated_listeners_pass_bound_arguments_and_contain_failures(self):
        scope = self.load()
        seen = []
        with bridge.runtime.context(scope):
            click = bridge.runtime.jclass("android.view.View$OnClickListener")
            touch = bridge.runtime.jclass("android.view.View$OnTouchListener")
            listener = gen(click, "onClick")(lambda view, tag, extra=None: seen.append((view, tag, extra)), "tag", extra=1)
            self.assertIsNone(listener.onClick("view"))
            self.assertIs(gen(click, "onClick"), gen(click, "onClick"))
            failing = gen(touch, "onTouch", True, True)(lambda view, event: 1 / 0)
            self.assertIs(failing.onTouch("v", "e"), True)
            self.assertIs(gen(touch, "onTouch", True)(lambda view, event: False).onTouch("v", "e"), False)
            both = gen2(touch, True, onTouch=lambda view, event, suffix: event + suffix)("!")
            self.assertEqual(both.onTouch("v", "e"), "e!")
            helper = elyxcore.OnClickListener(lambda view: seen.append("helper"))
            helper.onClick("view")
            runnable = elyxcore.Runnable(lambda: seen.append("run"))
            runnable.run()
            exported = bridge.runtime.encode([listener, helper, runnable])
            self.assertEqual([item["$class"] for item in exported], [
                "android.view.View$OnClickListener", "android.view.View$OnClickListener", "java.lang.Runnable"])
            for call in (lambda: gen(click, "onClick", False, "default"), lambda: gen("not a class", "run")):
                with self.subTest(call=call), self.assertRaises((ValueError, TypeError)):
                    call()
        self.assertEqual(seen, [("view", "tag", 1), "helper", "run"])
        self.assertTrue(any("[ElyxCore] ZeroDivisionError" in line for line in self.host.logged()))

    def test_small_helpers(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            values = LazyDict(a=1)
            values.b = 2
            self.assertEqual((values.a, values["b"]), (1, 2))
            with self.assertRaises(KeyError):
                values.missing
            self.assertIsNone(safe_func(lambda: 1 / 0)())
            self.assertEqual(safe_func(lambda value: value + 1)(1), 2)
            mapping = hash_map({"k": 1})
            self.assertEqual((type(mapping).__name__, mapping.get("k")), ("HashMap", 1))
            with self.assertRaisesRegex(RuntimeError, "only available from plugin code"):
                elyxcore.get_environment()
            self.assertIs(elyxcore.import_module("json"), __import__("json"))
            with self.assertRaises(TypeError):
                elyxcore.import_module(".relative")
        self.assertFalse(hasattr(elyxcore, "mvel_execute"))


class ValueTests(Case):
    def test_settings_controller_is_the_owner_namespace(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            settings = SettingsController("sample")
            settings["a"] = 1
            settings.set("b", "two", reload_settings=True)
            self.assertEqual((settings["a"], settings("b"), settings.get("c", 3), settings.get_settings()),
                             (1, "two", 3, {"a": 1, "b": "two"}))
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                SettingsController("other").get("a")
        writes = [r["arguments"]["reload_settings"] for r in self.host.requests if r["operation"] == "settings.set"]
        self.assertEqual(writes, [False, True])

    def test_strings_choose_locale_with_english_and_key_fallbacks(self):
        scope = self.load()
        tables = {"en": {"hi": "Hello {}", "only": "English", "words": ["file", "files", "files"]},
                  "de": {"hi": "Hallo {}"}}
        with bridge.runtime.context(scope), patch.dict(os.environ, {"LANG": "de_DE.UTF-8", "LC_ALL": "",
                                                                    "LC_MESSAGES": ""}):
            strings = Strings(tables)
            self.assertEqual(Strings.get_current_language(), "de")
            self.assertEqual((strings.hi, strings("hi", "A"), strings["only"], strings.absent, strings.get("absent", "d"),
                              strings.get_with_locale("hi", locale="en"), strings("hi", "B", locale="xx"),
                              strings.pluralize(21, "words"), strings.pluralize(5, "words")),
                             ("Hallo {}", "Hallo A", "English", "absent", "d", "Hello {}", "Hello B", "21 file",
                              "5 files"))
            self.assertIs(strings.all_strings, tables)
            with self.assertRaisesRegex(RuntimeError, "read-only"):
                strings["hi"] = "changed"

    def test_assets_resolve_names_folders_and_content(self):
        scope = self.load()
        with tempfile.TemporaryDirectory() as directory, bridge.runtime.context(scope):
            root = Path(directory, "res")
            (root / "icons").mkdir(parents=True)
            (root / "my-icon.v2.svg").write_text("<svg/>", encoding="utf-8")
            (root / "table.json").write_text('{"rows": 2}', encoding="utf-8")
            (root / "config.yml").write_text("a: [1, 2]\n", encoding="utf-8")
            (root / "blob.bin").write_bytes(b"\xff\xfe")
            (root / "icons" / "git.svg").write_text("<git/>", encoding="utf-8")
            assets = Assets(str(root))
            icon = assets.my_icon
            self.assertEqual((icon.name, icon.filename, icon.ext, icon.content_string(), icon.path_str),
                             ("my_icon", "my-icon.v2.svg", "svg", "<svg/>", str(root / "my-icon.v2.svg")))
            self.assertEqual((assets["table"].content(), assets.get("config.yml").content_yaml(), assets.blob.content(),
                              assets.get("icons/git").content_string(), assets.icons.git.content_bytes()),
                             ({"rows": 2}, {"a": [1, 2]}, b"\xff\xfe", "<git/>", b"<git/>"))
            self.assertEqual((len(assets), "table" in assets, "table.json" in assets, "absent" in assets,
                              sorted(assets), repr(assets.icons)),
                             (5, True, True, False, ["blob.bin", "config.yml", "icons", "my-icon.v2.svg", "table.json"],
                              f"<Elyx.Assets dir_path={root / 'icons'}>"))
            self.assertEqual(assets.icons.parent.dir_path, root)
            self.assertEqual(Asset.from_path(str(root / "table.json")).content_json(), {"rows": 2})
            self.assertEqual(type(icon.java_file).__name__, "File")
            with self.assertRaises(AssetNotFoundException):
                assets.get("absent")
            with self.assertRaises(AttributeError):
                assets.__wrapped__
            for call in (lambda: Assets(str(root / "absent")), lambda: Asset(str(root), "", "x"),
                         lambda: Asset(str(root / "table.json"), "x", "x")):
                with self.subTest(call=call), self.assertRaises(ValueError):
                    call()
            with self.assertRaises(IsADirectoryError):
                Asset.from_path(str(root))
            # The converters compose host classes through the class registry and fail when it has none.
            requested = []

            def registry(name):
                requested.append(name)
                raise bridge.UnsupportedAPI("Java class is not declared by host: " + name)

            with patch.object(bridge.runtime, "jclass", side_effect=registry):
                for convert in (icon.to_image_location, icon.to_drawable, icon.to_svg_bitmap, icon.to_lottie_drawable):
                    with self.subTest(convert=convert.__name__), self.assertRaises(bridge.UnsupportedAPI):
                        convert()
            self.assertEqual(requested[:3], ["org.telegram.messenger.ImageLocation",
                                             "android.graphics.drawable.Drawable", "org.telegram.messenger.SvgHelper"])
            plugins = Path(directory, "plugins", "sample")
            plugins.mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, "plugin directory"):
                Assets(plugins)

    def test_data_files_load_from_bytes_paths_and_archives(self):
        self.assertEqual(normalize_name("my-icon v2"), "my_icon_v2")
        self.assertEqual(load_data_file(b"anything"), {})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "values.yaml")
            path.write_text("k: yes\n", encoding="utf-8")
            self.assertEqual(load_data_file(path), {"k": True})
            self.assertEqual(load_data_file(Path(directory, "values.yaml").rename(Path(directory, "values.txt"))), {})
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                archive.writestr("dir/meta.json", '{"a": 1}')
            with zipfile.ZipFile(buffer) as archive:
                self.assertEqual(load_data_file("dir/meta.json", archive), {"a": 1})
                self.assertEqual(load_data_file(archive.getinfo("dir/meta.json"), archive), {"a": 1})
            with self.assertRaises(TypeError):
                load_data_file("dir/meta.json")


if __name__ == "__main__":
    unittest.main()
