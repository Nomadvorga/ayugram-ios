"""`menus.add` declaration and the resource tables of the Swift host; `R` kinds and bulletin icons in the SDK."""
import json
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
import test_bridge as harness
import test_telegram_host as telegram
from _ayu_javalib import telegram_messenger as messenger
from ui.bulletin import BulletinHelper

BRIDGE = Path(__file__).resolve().parents[2]
REPOSITORY = BRIDGE.parents[1]
RESOURCES = BRIDGE / "Integration" / "AyuPluginResources.swift"
ASSETS = REPOSITORY / "submodules" / "TelegramUI" / "Images.xcassets" / "Chat" / "Context Menu"
# What the corpus meter reads as declared operations (tools/plugin_inspector/preflight.py).
OPERATION_LISTS = re.compile(r"\blet\s+(?:operations|capabilities)\s*=\s*\[([^\]]*)\]")


class SwiftDeclarationTests(unittest.TestCase):
    def literals(self):
        found = set()
        for folder in ("Sources", "Integration"):
            for path in sorted((BRIDGE / folder).glob("*.swift")):
                for body in OPERATION_LISTS.findall(path.read_text(encoding="utf-8")):
                    found.update(re.findall(r'"([^"\\]*)"', body))
        return found

    def test_menus_add_is_not_declared_by_a_literal(self):
        # It is declared at run time only while a Telegram backend serves its context.
        literals = self.literals()
        self.assertIn("menus.register", literals)
        self.assertIn("resources.resolve", literals)
        self.assertNotIn("menus.add", literals)
        menus = (BRIDGE / "Integration" / "AyuPluginMenuBridge.swift").read_text(encoding="utf-8")
        self.assertIn("self.typed.isAvailable ? self.operations + [AyuPluginTypedMenus.operation] : self.operations", menus)

    def test_every_mapped_asset_exists_in_the_app_catalog(self):
        text = RESOURCES.read_text(encoding="utf-8")
        assets = set(re.findall(r'\.asset\("([^"]+)"\)', text))
        symbols = set(re.findall(r'\.symbol\("([^"]+)"\)', text))
        self.assertGreater(len(assets), 50)
        self.assertGreater(len(symbols), 50)
        self.assertIn('assetPrefix = "Chat/Context Menu/"', text)
        for name in sorted(assets):
            with self.subTest(asset=name):
                self.assertTrue((ASSETS / (name + ".imageset") / "Contents.json").is_file())
        for name in sorted(symbols):
            with self.subTest(symbol=name):
                self.assertRegex(name, r"\A[a-z0-9]+(\.[a-z0-9]+)*\Z")

    def test_table_names_are_android_resource_identifiers(self):
        drawables, animations = RESOURCES.read_text(encoding="utf-8").split("static let animations", 1)
        for table, least in ((drawables, 400), (animations, 10)):
            names = re.findall(r'"([^"]+)": \.(?:asset|symbol)\(', table)
            self.assertGreater(len(names), least)
            self.assertEqual(len(names), len(set(names)))
            for name in names:
                self.assertRegex(name, r"\A[a-z0-9_]+\Z")


class PresentingHost(telegram.TelegramHost):
    """Accepts bulletins and keeps their configs."""

    def __init__(self, operations):
        super().__init__(operations)
        self.bulletins = []

    def perform(self, request):
        if request["operation"] == "ui.present":
            self.bulletins.append(request["arguments"]["config"])
            return None
        return super().perform(request)


class ResourceCase(telegram.TelegramCase):
    def setUp(self):
        super().setUp()
        self.host = PresentingHost(self.operations)
        sys.modules["_ayu_host"].dispatch = self.host.dispatch


class ResourceKindTests(ResourceCase):
    operations = ("resources.resolve",)

    def blockers(self, text):
        report = json.loads(bridge.preflight_plugin_json(text))
        return sorted((item["code"], item["detail"]) for item in report["blockers"])

    def source(self, body, imports="from org.telegram.messenger import R\n"):
        return harness.source("kinds", imports=imports, body="    def on_plugin_load(self):\n" + body)

    def test_only_icon_kinds_pass_preflight(self):
        self.assertEqual(self.blockers(self.source("        self.a = R.drawable.msg_info\n        self.b = R.raw.info\n")), [])
        self.assertEqual(self.blockers(self.source("        self.a = R.string.AppName\n")),
                         [("MEMBER", "org.telegram.messenger.R.string")])
        self.assertEqual(self.blockers(self.source("        self.a = R.style.Theme\n        self.b = R.id.item\n")),
                         [("MEMBER", "org.telegram.messenger.R.id"), ("MEMBER", "org.telegram.messenger.R.style")])
        lookup = self.source('        self.a = find_class("org.telegram.messenger.R$string")\n'
                             '        self.b = find_class("org.telegram.messenger.R$drawable")\n',
                             imports="from hook_utils import find_class\n")
        self.assertEqual(self.blockers(lookup), [("CLASS", "org.telegram.messenger.R$string")])

    def test_kind_requirements_name_their_operations(self):
        import _ayu_javalib
        declared = ["resources.resolve"]
        self.assertEqual(_ayu_javalib.missing_operations("org.telegram.messenger.R$drawable", declared), ())
        self.assertEqual(_ayu_javalib.missing_operations("org.telegram.messenger.R$raw", declared), ())
        self.assertEqual(_ayu_javalib.missing_operations("org.telegram.messenger.R$string", declared), ("resources.strings",))
        self.assertEqual(_ayu_javalib.missing_operations("org.telegram.messenger.R$color", declared), ("resources.android",))

    def test_an_unserved_kind_raises_inside_a_plugin(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            self.assertEqual(messenger.R.drawable.msg_info.to_bridge(), {"resource": "drawable", "name": "msg_info"})
            self.assertEqual(messenger.R.raw.info.to_bridge(), {"resource": "raw", "name": "info"})
            for kind in ("string", "style", "color"):
                with self.subTest(kind=kind), self.assertRaises(bridge.UnsupportedAPI) as raised:
                    getattr(getattr(messenger.R, kind), "Name")
                self.assertIn("resources.", str(raised.exception))
        # Outside a plugin the value is only symbolic.
        self.assertEqual(repr(messenger.R.string.Name), "R.string.Name")

    def test_bulletin_icons_are_resource_ids_on_a_declaring_host(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            BulletinHelper.show_simple("Plain", 0)
            BulletinHelper.show_simple("Icon", messenger.R.raw.info)
            BulletinHelper.show_two_line("Title", "Subtitle", messenger.R.drawable.msg_info)
            BulletinHelper.show_with_button("Button", messenger.R.raw.error, "Undo", lambda: None)
            with self.assertRaises(bridge.UnsupportedAPI):
                BulletinHelper.show_simple("Android integer", 0x7F080001)
            with self.assertRaises(bridge.UnsupportedAPI):
                BulletinHelper.show_simple("Not an id", "info")
        configs = self.host.bulletins
        self.assertEqual([config.get("icon") for config in configs], [
            None, {"resource": "raw", "name": "info"}, {"resource": "drawable", "name": "msg_info"},
            {"resource": "raw", "name": "error"}])
        self.assertNotIn("icon", configs[0])


class UndeclaredResourceTests(ResourceCase):
    operations = ()

    def test_a_resource_id_is_not_sent_to_a_host_without_the_operation(self):
        scope = self.load()
        with bridge.runtime.context(scope), self.assertRaises(bridge.UnsupportedAPI):
            BulletinHelper.show_simple("Icon", messenger.ResourceId("raw", "info"))
        self.assertEqual(self.host.bulletins, [])


if __name__ == "__main__":
    unittest.main()
