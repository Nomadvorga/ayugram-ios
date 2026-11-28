"""``ChatActivity``'s private ``dialog_id`` through reflection; every other private field keeps failing."""
from __future__ import annotations

from pymembers_fixtures import HostCase
import ayu_bridge as bridge
import _ayu_operations
from _ayu_javalib import java_lang, java_reflect, telegram_ui


class PrivateFieldTests(HostCase):
    def chat(self, dialog):
        fragment = object.__new__(telegram_ui.ChatActivity)
        fragment.__dict__.update(arguments=None, _host=None, _info={"account": 0, "kind": "chat", "dialog_id": dialog})
        return fragment

    def test_dialog_id_is_a_private_declared_field_read_after_set_accessible(self):
        scope = self.load(imports="from java import jclass\n")
        with bridge.runtime.context(scope):
            mirror = java_lang.Class._of(telegram_ui.ChatActivity)
            field = mirror.getDeclaredField("dialog_id")
            self.assertIs(type(field), java_reflect.Field)
            self.assertEqual(field.getModifiers(), java_lang.Modifier.PRIVATE)
            self.assertIn("dialog_id", [item.getName() for item in mirror.getDeclaredFields()])
            fragment = self.chat(-1001234)
            with self.assertRaises(java_lang.IllegalAccessException):
                field.get(fragment)
            field.setAccessible(True)
            self.assertEqual((field.get(fragment), field.getLong(fragment)), (-1001234, -1001234))
            with self.assertRaises(java_lang.NullPointerException):
                field.get(None)
            with self.assertRaises(java_lang.IllegalArgumentException):
                field.get("not a fragment")
            with self.assertRaises(bridge.UnsupportedAPI):
                field.set(fragment, 5)

    def test_it_is_private_and_declared_by_chat_activity_only(self):
        scope = self.load(imports="from java import jclass\n")
        with bridge.runtime.context(scope):
            mirror = java_lang.Class._of(telegram_ui.ChatActivity)
            with self.assertRaises(java_lang.NoSuchFieldException):
                mirror.getField("dialog_id")
            self.assertNotIn("dialog_id", [item.getName() for item in mirror.getFields()])
            self.assertFalse(hasattr(self.chat(7), "dialog_id"))
            for name in ("chatListView", "mergeDialogId", "themeDelegate", "__ayu_private_fields__"):
                with self.assertRaises(java_lang.NoSuchFieldException):
                    mirror.getDeclaredField(name)
            with self.assertRaises(java_lang.NoSuchFieldException):
                java_lang.Class._of(telegram_ui.DialogsActivity).getDeclaredField("dialog_id")

    def test_the_curated_refusals_of_the_lane_stay(self):
        for name in ("getDeclaredField", "queryFinalized"):
            self.assertIn(name, _ayu_operations.UNPROVIDED_MEMBERS)
