"""Wave 6 messenger lane: ``UserObject.getUserName`` over Android's ``ContactsController.formatName``."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
from _ayu_javalib import telegram_messenger as messenger
from _ayu_javalib import telegram_tl as tl

R = tl.TLRPC
UserObject = messenger.UserObject


def user(first=None, last=None, phone=None, deleted=False):
    value = R.TL_user()
    value.id, value.first_name, value.last_name, value.phone, value.deleted = 7, first, last, phone, deleted
    return value


class _Locale:
    def __init__(self, language):
        self.language = language

    def getLanguage(self):
        return self.language


class _Runtime:
    def __init__(self, language):
        self.language, self.asked = language, []

    def jclass(self, name):
        self.asked.append(name)
        return self

    def getInstance(self):
        return self

    def getCurrentLocale(self):
        return _Locale(self.language)


class GetUserNameTests(unittest.TestCase):
    def name(self, value, order=1):
        with patch.object(messenger, "_name_display_order", return_value=order):
            return UserObject.getUserName(value)

    def test_first_then_last_in_the_default_order(self):
        self.assertEqual(self.name(user("Ada", "Lovelace")), "Ada Lovelace")
        self.assertEqual(self.name(user("Ada")), "Ada")
        self.assertEqual(self.name(user(None, "Lovelace")), "Lovelace")
        self.assertEqual(self.name(user("", "")), "")

    def test_last_then_first_in_the_korean_order(self):
        self.assertEqual(self.name(user("Ada", "Lovelace"), order=2), "Lovelace Ada")
        self.assertEqual(self.name(user("Ada"), order=2), "Ada")
        self.assertEqual(self.name(user(None, "Lovelace"), order=2), "Lovelace")

    def test_trims_like_java_and_keeps_wider_spaces(self):
        self.assertEqual(self.name(user(" \tAda\n", " Lovelace ")), "Ada Lovelace")
        self.assertEqual(self.name(user("\u00a0Ada\u2003", "  ")), "\u00a0Ada\u2003")

    def test_drops_direction_marks_and_stacked_diacritics(self):
        self.assertEqual(self.name(user("\u202eAda\u200f", "L\u200e")), "Ada L")
        # Android's pattern backtracks: two marks in a row become one, three or more become two.
        self.assertEqual(self.name(user("a\u0301\u0302\u0303\u0304", "e\u0301\u0302")), "a\u0301\u0302 e\u0301")
        self.assertEqual(self.name(user("e\u0301", "o\u0301\u0302\u0303")), "e\u0301 o\u0301\u0302")

    def test_name_wins_over_the_phone(self):
        self.assertEqual(self.name(user("Ada", None, "15550100")), "Ada")
        self.assertEqual(self.name(user(None, None, "")), "")

    def test_refuses_what_needs_android_strings_or_phone_format(self):
        for value in (None, R.TL_userEmpty(), user("Ada", deleted=True), user(None, None, "15550100"),
                      user("\u200f", " ", "15550100")):
            with self.subTest(value=value), self.assertRaises(bridge.UnsupportedAPI):
                self.name(value)

    def test_order_follows_the_host_locale_language(self):
        for language, order in (("ko", 2), ("KO", 2), ("en", 1), ("kok", 1), ("", 1), (None, 1)):
            runtime = _Runtime(language)
            with self.subTest(language=language), patch.object(messenger, "_runtime", return_value=runtime):
                self.assertEqual(messenger._name_display_order(), order)
                self.assertEqual(runtime.asked, ["org.telegram.messenger.LocaleController"])


if __name__ == "__main__":
    unittest.main()
