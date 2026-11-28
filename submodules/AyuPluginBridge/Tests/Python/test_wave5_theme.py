"""``org.telegram.ui.ActionBar.Theme``: the Android key table in the Swift host and its preflight.

Plugin sources are synthetic; preflight only parses them.
"""
import json
import re
import unittest
from pathlib import Path

import test_bridge as fixtures
import ayu_bridge as bridge

THEME = "org.telegram.ui.ActionBar.Theme"
SWIFT = (Path(__file__).resolve().parents[2] / "Integration" / "AyuPluginTheme.swift").read_text(encoding="utf-8")
TABLE = {name: (int(key), int(light, 16), int(dark, 16))
         for name, key, light, dark in re.findall(r"^    (\w+) (\d+) ([0-9A-F]{8}) ([0-9A-F]{8})$", SWIFT, re.M)}
PALETTE_METHODS = ["getColor", "isCurrentThemeDark", "isCurrentThemeNight", "getActiveTheme", "getSelectorDrawable"]
USES = ("from org.telegram.ui.ActionBar import Theme\n"
        "def colors():\n"
        "    return [Theme.getColor(Theme.key_dialogTextBlack), Theme.getColor(Theme.key_dialogTextHint, None),\n"
        "            Theme.getColor(Theme.key_chat_attachPhotoBackground), Theme.getColor(Theme.key_premiumStarGradient2),\n"
        "            Theme.multAlpha(Theme.getColor(Theme.key_dialogTextRed), 0.5), Theme.isCurrentThemeDark()]\n")


def java_int(value):
    return value - (1 << 32) if value >= 1 << 31 else value


class AndroidKeyTableTests(unittest.TestCase):
    def test_table_pins_exteragram_ids_and_default_colours(self):
        # exteraGram 13.2.2: Theme.java ids, ThemeColors.java defaults, darkblue.attheme values.
        self.assertEqual(len(TABLE), 864)
        ids = {key for key, _, _ in TABLE.values()}
        # Android numbers 866 keys; the two wallpaper-computed service backgrounds are left out.
        self.assertEqual((len(ids), min(ids), max(ids)), (864, 0, 865))
        android = {
            "dialogBackground": (1, 0xFFFFFFFF, 0xFF212D3B), "dialogTextBlack": (3, 0xFF1A1D21, 0xFFF6F6F6),
            "dialogTextHint": (13, 0xFF979797, 0xFF7D8B99), "windowBackgroundWhite": (49, 0xFFFFFFFF, 0xFF1D2733),
            "divider": (101, 0xFFD9D9D9, 0x95000000), "chat_attachPhotoBackground": (248, 0x0C000000, 0x0C000000),
            "chat_outBubble": (316, 0xFFEFFFDE, 0xFF3E618A), "premiumStarGradient2": (799, 0xFFE3ECFA, 0xFFC066FA),
        }
        for name, expected in android.items():
            self.assertEqual(TABLE[name], expected, name)
        # The values a plugin sees are signed Java ints.
        self.assertEqual(java_int(TABLE["dialogTextBlack"][1]), -15065823)
        self.assertEqual(java_int(TABLE["dialogTextBlack"][2]), -592138)
        self.assertEqual(java_int(TABLE["premiumStarGradient2"][2]), -4167942)

    def test_slot_table_names_android_keys_with_their_ids(self):
        slots = re.findall(r'"key_(\w+)": Key\(id: (\d+), slot: \.\w+', SWIFT)
        self.assertGreater(len(slots), 90)
        for name, key in slots:
            self.assertEqual(TABLE[name][0], int(key), name)

    def test_keys_android_does_not_define_are_absent(self):
        for name in ("dialogTextRed", "dialogButtonRed", "listSelectorSDK21", "chat_serviceBackground", "chat_serviceBackgroundSelected"):
            self.assertNotIn(name, TABLE)


class ThemePreflightTests(unittest.TestCase):
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown

    def publish(self, static_methods, static_fields):
        self.host.capabilities["classes"] = sorted(set(self.host.capabilities.get("classes", [])) | {THEME})
        self.host.capabilities["members"] = {"version": 1, "classes": {THEME: {
            "constructor": False, "methods": [], "fields": [], "writable_fields": [],
            "static_methods": static_methods, "static_fields": static_fields, "results": {}}}}

    def members(self):
        report = json.loads(bridge.preflight_plugin_json(fixtures.source("wave5_theme", "    pass\n", USES)))
        return [item["detail"] for item in report["blockers"] if item["code"] == "MEMBER"]

    def test_bound_palette_host_leaves_only_keys_android_lacks(self):
        self.publish(PALETTE_METHODS, ["key_" + name for name in TABLE])
        self.assertEqual(self.members(), [THEME + ".key_dialogTextRed"])

    def test_host_without_a_palette_blocks_colour_members_but_not_mult_alpha(self):
        self.publish([], [])
        self.assertEqual(self.members(), [THEME + "." + name for name in sorted(
            ["getColor", "isCurrentThemeDark", "key_chat_attachPhotoBackground", "key_dialogTextBlack", "key_dialogTextHint",
             "key_dialogTextRed", "key_premiumStarGradient2"])])


if __name__ == "__main__":
    unittest.main()
