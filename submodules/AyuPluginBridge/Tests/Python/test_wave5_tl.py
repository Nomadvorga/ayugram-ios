"""Wave 5 TL lane: legacy class names, ``StarsAmount.ofStars`` and ``getClass`` on TL classes."""
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_javalib
from _ayu_javalib import telegram_tl as tl

R = tl.TLRPC
OLD = "org.telegram.tgnet.TLRPC$TL_account_updateProfile"
NEW = "org.telegram.tgnet.tl.TL_account$updateProfile"


def tl_string(text):
    data = text.encode("utf-8")
    body = bytes((len(data),)) + data
    return body + b"\0" * (-len(body) % 4)


class LegacyNameTests(unittest.TestCase):
    def test_old_account_update_profile_name_is_the_current_class(self):
        local = _ayu_javalib.local_classes()
        self.assertIs(local[OLD], local[NEW])
        self.assertIs(R.TL_account_updateProfile, local[NEW])
        self.assertEqual(_ayu_javalib.local_name(local[OLD]()), NEW)
        self.assertEqual(tl.simple_name(local[OLD]), "updateProfile")
        self.assertEqual(tl.classes_named("updateProfile"), [local[NEW]])

    def test_update_profile_bytes_follow_the_scheme(self):
        # account.updateProfile#78515775 flags:# first_name:flags.0?string last_name:flags.1?string
        # about:flags.2?string = User
        request = R.TL_account_updateProfile()
        self.assertEqual((request.flags, request.first_name, request.last_name, request.about), (0, None, None, None))
        request.about = "Listening"
        self.assertEqual(tl.encode(request), struct.pack("<II", 0x78515775, 0))
        request.flags |= 4
        self.assertEqual(tl.encode(request), struct.pack("<II", 0x78515775, 4) + tl_string("Listening"))
        request.flags, request.first_name, request.last_name = 7, "A", ""
        expected = struct.pack("<II", 0x78515775, 7) + tl_string("A") + tl_string("") + tl_string("Listening")
        self.assertEqual(tl.encode(request), expected)
        self.assertEqual(expected.hex(), "7557517807000000" "01410000" "00000000" "094c697374656e696e670000")
        decoded = tl.decode(expected)
        self.assertIs(type(decoded), R.TL_account_updateProfile)
        self.assertEqual((decoded.first_name, decoded.last_name, decoded.about), ("A", "", "Listening"))
        self.assertTrue(tl.is_function(R.TL_account_updateProfile))


class StarsAmountTests(unittest.TestCase):
    def test_of_stars_builds_a_stars_amount(self):
        # starsAmount#bbb6b4a3 amount:long nanos:int = StarsAmount
        stars = _ayu_javalib.local_class("org.telegram.tgnet.tl.TL_stars")
        amount = stars.StarsAmount.ofStars(5)
        self.assertIs(type(amount), stars.TL_starsAmount)
        self.assertEqual((amount.amount, amount.nanos), (5, 0))
        self.assertEqual(tl.encode(amount), struct.pack("<Iqi", 0xBBB6B4A3, 5, 0))
        self.assertEqual(tl.encode(amount).hex(), "a3b4b6bb" "0500000000000000" "00000000")


class GetClassTests(unittest.TestCase):
    def test_class_and_object_answer_their_java_class(self):
        mirror = R.WebPage.getClass()
        self.assertEqual((mirror.getName(), mirror.getSimpleName()), ("org.telegram.tgnet.TLRPC$WebPage", "WebPage"))
        message = R.TL_message().getClass()
        self.assertEqual((message.getName(), message.getSimpleName()),
                         ("org.telegram.tgnet.TLRPC$TL_message", "TL_message"))
        self.assertEqual(message.getSuperclass().getName(), "org.telegram.tgnet.TLRPC$Message")
        self.assertEqual(message.getSuperclass().getSuperclass().getName(), "org.telegram.tgnet.TLObject")
        self.assertIs(R.TL_message().getClass(), message)
        nested = _ayu_javalib.local_class(NEW)().getClass()
        self.assertEqual((nested.getName(), nested.getSimpleName()), (NEW, "updateProfile"))

    def test_get_class_is_not_a_field(self):
        message = R.TL_message()
        with self.assertRaises(AttributeError):
            message.getClass = None
        self.assertEqual(tl.encode(R.TL_inputPeerSelf()), struct.pack("<I", 0x7DA07EC9))


if __name__ == "__main__":
    unittest.main()
