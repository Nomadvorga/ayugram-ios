"""Android's MVEL menu conditions (``_ayu_mvel``): the subset, Android's failure rules, the unknown rule, preflight."""
import ast
import json
import unittest

import test_bridge as harness
import _ayu_mvel as mvel
import ayu_bridge as bridge
import test_telegram_host as telegram
from _ayu_javalib import telegram_messenger as messenger
from base_plugin import MenuItemData, MenuItemType

R = telegram.R


def photo_message(caption=""):
    value = telegram.text_message(text=caption)
    value.media = R.TL_messageMediaPhoto()
    value.flags |= 512
    return value


class Thing:
    """A model with a field, a getter, a boolean getter, a method and a member the SDK refuses."""
    count, name, nothing = 3, "Ann", None

    def getTitle(self):
        return "Title"

    def isReady(self):
        return True

    def twice(self, value):
        return value * 2

    def explode(self):
        raise ValueError("as a Java exception would")

    @property
    def label(self):
        raise bridge.UnsupportedAPI("a localized label")


class EvaluationTests(unittest.TestCase):
    CONTEXT = {"thing": Thing(), "text": "Héllo 😀", "n": 5, "flag": True, "none": None, "map": {"key": 7}}

    def check(self, text, expected, context=None):
        self.assertEqual(mvel.evaluate(mvel.compile(text), self.CONTEXT if context is None else context), expected, text)

    def test_the_subset_evaluates_as_mvel_does(self):
        shown, hidden = (True, True), (False, True)
        for text, expected in {
            "": shown, "true": shown, "false": hidden, "!false": shown, "flag": shown, "!flag": hidden,
            "thing != null": shown, "thing == null": hidden, "none == null": shown, "none == nil": shown, "null == null": shown,
            "n > 4 && n >= 5 && n < 6 && n <= 5": shown, "n == 5": shown, "n == 5.0": shown, "n != 5": hidden, "n > -1": shown,
            "n == 5L": shown, "n < 2.5": hidden,
            "thing.count == 3": shown, "thing.title == 'Title'": shown, 'thing.getTitle() == "Title"': shown,
            "thing.ready": shown, "thing.isReady": shown, "thing.isReady()": shown, "thing.twice(n) == 10": shown,
            "thing.twice(thing.twice(2)) > 7": shown, "thing.nothing == null": shown,
            "text.length() == 8": shown, "!text.isEmpty()": shown, "text.startsWith('Hé')": shown, "text.contains('zz')": hidden,
            "text.toLowerCase().endsWith('😀')": shown, "text.equals(text)": shown, "text == 'x'": hidden, "'a' < 'b'": shown,
            "'it\\'s'.length() == 4": shown, "map.key == 7": shown,
            "false || (flag && !(n > 9))": shown, "flag && false || flag": shown, "(flag || false) && false": hidden,
            "  flag  &&\n flag ": shown, "flag==true": shown, "flag != n": shown,
        }.items():
            self.check(text, expected)

    def test_what_throws_on_android_hides_the_item(self):
        for text in ("missing != null", "missing == null || true", "none.count == 1", "none.size() > 0", "thing.explode()",
                     "n", "text", "!n", "n && flag", "flag > 1", "none > 1", "text.length(1) > 0", "text.contains(n)",
                     "map.other == null", "Missing.call()", "lower.case.only()"):
            self.check(text, (False, True))
        # Short-circuit: the operand that would throw is never read.
        self.check("flag || missing", (True, True))
        self.check("none != null && none.count > 1", (False, True))

    def test_an_unmodelled_read_is_unknown_unless_the_other_operand_decides(self):
        unknown = (False, False)
        for text in ("thing.label != null", "thing.absent", "thing.absent()", "text.codePointAt(0) > 1", "n.intValue() > 1",
                     "thing.label != null && flag", "thing.label != null || false", "!(thing.label == null)",
                     "thing.label != null || missing", "thing.label.length() > 0"):
            self.check(text, unknown)
        self.check("thing.label != null || flag", (True, True))
        self.check("flag || thing.label != null", (True, True))
        self.check("thing.label != null && !flag", (False, True))
        self.check("(thing.label != null && thing.label.length() > 0) || thing.count == 3", (True, True))

    def test_anything_outside_the_subset_is_refused(self):
        for text in (" ", "a +", "n + 1 > 2", "n * 2", "flag ? 1 : 2", "flag and flag", "text contains 'a'", "thing instanceof Thing",
                     "empty", "isdef n", "new java.lang.Object()", "n = 5", "flag & flag", "flag | flag", "list[0]", "f(n)",
                     "thing.", "thing..count", "(flag", "flag)", "flag flag", "'open", "'\\u0041'", "n == 5; true", "5.count",
                     "thing.?count", "{1,2}", "-n", "@flag", "flag && " * 600 + "flag", "(" * 40 + "flag" + ")" * 40, "x" * 5000):
            with self.assertRaises(mvel.Unsupported, msg=text):
                mvel.compile(text)
        with self.assertRaises(TypeError):
            mvel.compile(None)


class MenuConditionTests(telegram.TelegramCase):
    def conditions(self, scope, *texts):
        """The condition callbacks of items added with these strings (None where the host got no condition)."""
        with bridge.runtime.context(scope):
            for index, text in enumerate(texts):
                scope.instance.add_menu_item(MenuItemData(MenuItemType.MESSAGE_CONTEXT_MENU, "Item", lambda context: None,
                                                          item_id=f"item{index}", condition=text))
        configs = {arguments["item_id"]: arguments for name, arguments in self.host.calls if name == "menus.add"}
        return [configs[f"item{index}"].get("condition") for index in range(len(texts))]

    def test_string_conditions_are_evaluated_over_the_menu_context(self):
        scope = self.load()
        self.host.results["telegram.screen"] = {"kind": "chat", "account": 0, "dialog_id": 42}
        listen = "message != null && ((message.messageText != null && message.messageText.length() > 0) || message.caption != null)"
        photo, text, user, channel, empty, voice = self.conditions(
            scope, "message != null && (message.isPhoto() || message.isSticker())", listen, "user != null && !user.self && !user.bot",
            "chat == null || !org.telegram.messenger.ChatObject.isChannelAndNotMegaGroup(chat)", "",
            "message != null && (message.isVoice() || message.isRoundVideo())")
        self.assertIsNone(empty)                    # Android: an empty condition always holds

        def context(message=None, **more):
            wire = {"account": 0, "dialog_id": 42, "user": telegram.user().to_bridge(), **more}
            if message is not None:
                wire["message"] = message.to_bridge()
            return wire
        plain, picture, captioned = telegram.text_message(), photo_message(), photo_message("look")
        for index, (callback, wire, expected) in enumerate((
                (photo, context(plain), False), (photo, context(picture), True), (photo, context(), False),
                (text, context(plain), True), (text, context(telegram.text_message(text="")), False),
                # The label Android puts in ``messageText`` of a media message is not modelled: the caption decides.
                (text, context(captioned), True), (text, context(picture), False),
                (user, context(), True), (user, {"account": 0, "dialog_id": -4}, False),
                # Android's map has no ``chat`` in a private chat, so the name does not resolve there.
                (channel, context(), False), (voice, context(plain), False))):
            self.assertIs(self.fire(scope, callback, wire), expected, index)
        bot = telegram.user()
        bot.bot = True
        self.assertIs(self.fire(scope, user, context(user=bot.to_bridge())), False)
        group = R.TL_chat()
        group.id, group.title, group.photo = 9, "Group", R.TL_chatPhotoEmpty()
        self.assertIs(self.fire(scope, channel, {"account": 0, "dialog_id": -9, "chat": group.to_bridge()}), True)
        broadcast = R.TL_channel()
        broadcast.id, broadcast.title, broadcast.broadcast, broadcast.photo = 9, "News", True, R.TL_chatPhotoEmpty()
        self.assertIs(self.fire(scope, channel, {"account": 0, "dialog_id": -9, "chat": broadcast.to_bridge()}), False)
        # The hidden item whose condition read an unmodelled member is logged once.
        logged = [request["arguments"]["message"] for request in self.host.requests if request["operation"] == "log.write"]
        self.assertEqual(sum("does not model" in message for message in logged), 1)

    def test_a_condition_outside_the_subset_is_refused_when_the_item_is_added(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            for condition in ("message.getId() + 1 > 2", "message instanceof Object", 5):
                with self.assertRaises((bridge.UnsupportedAPI, TypeError)):
                    scope.instance.add_menu_item(MenuItemData(MenuItemType.MESSAGE_CONTEXT_MENU, "Item", lambda context: None,
                                                              condition=condition))
        self.assertFalse([name for name, _ in self.host.calls if name == "menus.add"])


class PreflightTests(telegram.TelegramCase):
    ITEM = ("    def on_plugin_load(self):\n"
            "        self.add_menu_item(MenuItemData(menu_type=MenuItemType.MESSAGE_CONTEXT_MENU, text='x', on_click=self.go,\n"
            "                                        condition={}))\n    def go(self, context):\n        pass\n")
    IMPORTS = "from base_plugin import MenuItemData, MenuItemType\n"

    def report(self, condition, prefix=""):
        text = harness.source("conditions", imports=self.IMPORTS + prefix, body=self.ITEM.format(condition))
        return json.loads(bridge.preflight_plugin_json(text))

    def blockers(self, condition, prefix=""):
        return sorted((item["code"], item["detail"]) for item in self.report(condition, prefix)["blockers"])

    def test_literal_conditions_are_checked_against_the_subset_and_the_models(self):
        for condition in ("'message != null && (message.isPhoto() || message.isSticker())'", "'user != null && !user.self && !user.bot'",
                          "'message.messageText != null && message.messageText.length() > 0 || message.caption != null'",
                          "'chat == null || !org.telegram.messenger.ChatObject.isChannelAndNotMegaGroup(chat)'",
                          "'message.messageOwner.message != null && !message.messageOwner.message.isEmpty()'",
                          "'chat != null && chat.broadcast'", "'fragment != null && unknownName.anything()'", "''", "None",
                          "lambda context: True", "self.go"):
            self.assertEqual(self.blockers(condition), [], condition)
        self.assertEqual(self.blockers("'message.getId() + 1 > 2'"), [
            ("OPERATION", "sdk.unprovided_member (MenuItemData condition, unexpected text at offset 16: message.getId() + 1 > 2)")])
        self.assertEqual(self.blockers("'message.isNoSuchThing() || message.noSuchField != null'"), [
            ("MEMBER", "org.telegram.messenger.MessageObject.isNoSuchThing"), ("MEMBER", "org.telegram.messenger.MessageObject.noSuchField")])
        self.assertEqual(self.blockers("'user.noSuchFlag'"), [("MEMBER", "org.telegram.tgnet.TLRPC$User.noSuchFlag")])
        self.assertEqual(self.blockers("'org.telegram.messenger.ChatObject.noSuchCheck(chat)'"), [
            ("MEMBER", "org.telegram.messenger.ChatObject.noSuchCheck")])
        self.assertEqual(self.blockers("'org.example.Missing.check(chat)'"), [("CLASS", "org.example.Missing")])

    def test_constant_names_are_followed_and_computed_conditions_are_a_warning(self):
        bad = "SHARED = 'user != null '\nCONDITION = SHARED + ('&& message.isNoSuchThing()'\n    ' && true')\n"
        self.assertEqual(self.blockers("CONDITION", bad), [("MEMBER", "org.telegram.messenger.MessageObject.isNoSuchThing")])
        report = self.report("CONDITION", bad)
        self.assertEqual(report["menu_conditions"], ["user != null && message.isNoSuchThing() && true"])
        for prefix, condition in (("import os\nCONDITION = os.environ.get('X')\n", "CONDITION"), ("CONDITION = 'a'\nCONDITION = 'b +'\n", "CONDITION"),
                                  ("", "f'message != null{1}'"), ("", "self.unknown")):
            report = self.report(condition, prefix)
            self.assertEqual((report["blockers"], report["menu_conditions"]), ([], []), condition)
            self.assertTrue(any(warning.startswith("DYNAMIC_MENU_CONDITIONS") for warning in report["warnings"]), condition)
        self.assertFalse(any(warning.startswith("DYNAMIC_MENU_CONDITIONS") for warning in self.report("'user != null'")["warnings"]))
        conditions, dynamic = mvel.static_conditions(ast.parse("MenuItemData(1, 'x', print, None, None, None, 'user != null')\n"
                                                               "self.add_menu_item(condition=other)\n"))
        self.assertEqual((conditions, dynamic), (["user != null"], 1))

    def test_a_string_condition_needs_the_typed_menus(self):
        self.host.capabilities["operations"].remove("menus.add")
        self.assertIn(("OPERATION", "menus.add (MenuItemData condition)"), self.blockers("'user != null'"))
        self.assertNotIn(("OPERATION", "menus.add (MenuItemData condition)"), self.blockers("None"))


if __name__ == "__main__":
    unittest.main()
