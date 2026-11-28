"""``MessagesController``'s chat list against a synthetic host: ``telegram.dialogs``."""
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_operations
import ayu_bridge as bridge
import test_telegram_host as base
from _ayu_javalib import telegram_messenger as messenger

harness = base.harness

R = base.R
OPERATION = "telegram.dialogs"
FOLDER_ID = messenger.DialogObject.makeFolderDialogId(1)


def dialog(peer_id, date, pinned_num=0, folder=0, unread=0):
    value = R.TL_dialog()
    if peer_id > 0:
        value.peer = R.TL_peerUser()
        value.peer.user_id = peer_id
    else:
        value.peer = R.TL_peerChannel()
        value.peer.channel_id = -peer_id
    value.notify_settings = R.TL_peerNotifySettings()
    value.pinned, value.unread_count, value.top_message = pinned_num > 0, unread, 7
    if folder:
        value.folder_id = folder
        value.flags |= 16
    if value.pinned:
        value.flags |= 4
    return {"dialog": value.to_bridge(), "last_message_date": date, "pinned_num": pinned_num}


def archive_row(pinned_num=3):
    value = R.TL_dialogFolder()
    value.folder = R.TL_folder()
    value.folder.id, value.folder.title = 1, "Archived Chats"
    value.peer = R.TL_peerUser()
    value.pinned = True
    value.flags |= 4
    return {"dialog": value.to_bridge(), "last_message_date": 0, "pinned_num": pinned_num}


class DialogCase(base.TelegramCase):
    operations = base.OPERATIONS + [OPERATION]

    def setUp(self):
        super().setUp()
        messenger._dialog_cache.clear()
        self.addCleanup(messenger._dialog_cache.clear)
        self.clock = [100.0]
        patched = mock.patch.object(messenger.time, "monotonic", lambda: self.clock[0])
        patched.start()
        self.addCleanup(patched.stop)
        self.answer = []
        perform = self.host.perform

        def answering(request):
            if request["operation"] == OPERATION:
                self.host.calls.append((OPERATION, request["arguments"]))
                return self.answer
            return perform(request)
        self.host.perform = answering


class DialogListTests(DialogCase):
    def test_lists_are_snapshots_in_androids_order_with_the_local_fields(self):
        scope = self.load()
        self.answer = [dialog(11, 500), dialog(-12, 900, folder=1, unread=4), dialog(13, 100, pinned_num=1), archive_row(),
                       dialog(14, 700), dialog(15, 50, pinned_num=2), dialog(-16, 800, folder=1, pinned_num=1)]
        with bridge.runtime.context(scope):
            controller = messenger.MessagesController.getInstance(2)
            dialogs = controller.allDialogs
            self.assertEqual(self.host.calls[-1], (OPERATION, {"account": 2}))
            self.assertEqual([item.id for item in dialogs], [FOLDER_ID, 15, 13, -16, -12, 14, 11])
            self.assertEqual((dialogs.size(), type(dialogs.get(0)).__name__, dialogs.get(0).isFolder), (7, "TL_dialogFolder", True))
            archived = dialogs.get(4)
            self.assertEqual((archived.id, archived.folder_id, archived.unread_count, archived.last_message_date,
                              archived.pinned, archived.pinnedNum, archived.top_message, archived.isFolder),
                             (-12, 1, 4, 900, False, 0, 7, False))
            self.assertEqual((dialogs.get(1).pinned, dialogs.get(1).pinnedNum, dialogs.get(1).last_message_date), (True, 2, 50))
            self.assertEqual([item.id for item in controller.getAllDialogs()], [item.id for item in dialogs])
            self.assertEqual([item.id for item in controller.getDialogs(0)], [FOLDER_ID, 15, 13, 14, 11])
            self.assertEqual([item.id for item in controller.getDialogs(1)], [-16, -12])
            self.assertEqual(controller.getDialogs(2).size(), 0)
            by_id = controller.dialogs_dict
            self.assertEqual((by_id.size(), by_id.get(14).last_message_date, by_id.get(99), by_id.get(FOLDER_ID).isFolder), (7, 700, None, True))
            self.assertEqual((controller.getDialog(-16).pinnedNum, controller.getDialog(99)), (1, None))
            # Every read is a new snapshot: a change to one does not show in the next.
            dialogs.get(1).folder_id = 1
            dialogs.clear()
            self.assertEqual((controller.allDialogs.size(), controller.getDialog(15).folder_id), (7, 0))
            # All of these reads were served by one host answer; a quarter second later the host is asked again.
            self.assertEqual(len(self.host.calls), 1)
            self.answer = []
            self.clock[0] += 0.2
            self.assertEqual(controller.allDialogs.size(), 7)
            self.clock[0] += 0.05
            self.assertFalse(controller.allDialogs)
            self.assertEqual(len(self.host.calls), 2)
            self.assertEqual((controller.getAllDialogs().size(), controller.dialogs_dict.size(), controller.getDialog(15)), (0, 0, None))
            for value in ("0", None, 1.5):
                with self.assertRaises(TypeError):
                    controller.getDialogs(value)
                with self.assertRaises(TypeError):
                    controller.getDialog(value)

    def test_a_state_change_and_another_account_end_the_reuse(self):
        self.host.capabilities["operations"] += ["telegram.action.add_dialogs_to_folder", "telegram.action.read_all_dialogs"]
        scope = self.load()
        self.host.results.update({"telegram.action.add_dialogs_to_folder": 1})
        perform = self.host.perform

        def acting(request):
            if request["operation"].startswith("telegram.action."):
                return self.host.results.get(request["operation"])
            return perform(request)
        self.host.perform = acting
        self.answer = [dialog(11, 500)]
        with bridge.runtime.context(scope):
            controller = messenger.MessagesController.getInstance(0)
            self.assertEqual(controller.getDialog(11).folder_id, 0)
            self.answer = [dialog(11, 500, folder=1)]
            self.assertEqual(controller.getDialog(11).folder_id, 0)
            self.assertEqual(controller.addDialogToFolder(11, 1, -1, 0), 1)
            self.assertEqual(controller.getDialog(11).folder_id, 1)
            self.answer = []
            messenger.MessagesStorage.getInstance(0).readAllDialogs(0)
            self.assertIsNone(controller.getDialog(11))
            self.answer = [dialog(12, 5)]
            self.assertEqual(messenger.MessagesController.getInstance(3).allDialogs.size(), 1)
            self.assertEqual(controller.allDialogs.size(), 1, "The other account's answer is not this account's")
            self.assertEqual([arguments["account"] for name, arguments in self.host.calls if name == OPERATION], [0, 0, 0, 3, 0])

    def test_an_invalid_host_answer_is_a_protocol_error(self):
        scope = self.load()
        good = dialog(11, 500)
        answers = [None, {}, [good] * 2, [good["dialog"]], [dict(good, extra=1)], [dict(good, last_message_date=-1)],
                   [dict(good, last_message_date=True)], [dict(good, pinned_num=2 ** 31)], [dict(good, pinned_num="1")],
                   [{"dialog": good["dialog"], "pinned_num": 0}], [dict(good, dialog=None)], [dict(good, dialog=base.user().to_bridge())],
                   [dialog(index + 1, 5) for index in range(2001)]]
        with bridge.runtime.context(scope):
            controller = messenger.MessagesController.getInstance(0)
            for answer in answers:
                self.answer = answer
                with self.assertRaises(bridge.ProtocolError, msg=repr(answer)[:80]):
                    controller.allDialogs
            self.answer = [dialog(index + 1, 5) for index in range(2000)]
            self.assertEqual(controller.getAllDialogs().size(), 2000)

    def test_init_dialog_follows_android(self):
        value = R.TL_dialog()
        value.peer = R.TL_peerChat()
        value.peer.chat_id = 9
        messenger.DialogObject.initDialog(value)
        self.assertEqual(value.id, -9)
        value.peer.chat_id = 10
        messenger.DialogObject.initDialog(value)
        self.assertEqual(value.id, -9, "An id that is set is kept")
        messenger.DialogObject.initDialog(None)
        empty = R.TL_dialog()
        messenger.DialogObject.initDialog(empty)
        self.assertEqual(empty.id, 0)


class UndeclaredDialogTests(base.TelegramCase):
    def test_every_member_needs_the_operation(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            controller = messenger.MessagesController.getInstance(0)
            for read in (lambda: controller.allDialogs, lambda: controller.dialogs_dict, controller.getAllDialogs,
                         lambda: controller.getDialogs(0), lambda: controller.getDialog(5)):
                with self.assertRaises(bridge.UnsupportedAPI):
                    read()
        self.assertNotIn(OPERATION, [name for name, _ in self.host.calls])

    def test_preflight_gates_field_reads_and_calls_by_name(self):
        def blockers(body):
            text = harness.source("dialogs", imports="from org.telegram.messenger import MessagesController\n",
                                  body="    def on_plugin_load(self):\n        mc = MessagesController.getInstance(0)\n" + body)
            report = json.loads(bridge.preflight_plugin_json(text))
            return sorted((item["code"], item["detail"]) for item in report["blockers"])
        cases = {"        return mc.allDialogs.size()\n": [("OPERATION", "telegram.dialogs (allDialogs)")],
                 "        return mc.dialogs_dict.get(5)\n": [("OPERATION", "telegram.dialogs (dialogs_dict)")],
                 "        return mc.getAllDialogs()\n": [("OPERATION", "telegram.dialogs (getAllDialogs())")],
                 "        return mc.getDialogs(0), mc.getDialog(5)\n": [("OPERATION", "telegram.dialogs (getDialog())"),
                                                                        ("OPERATION", "telegram.dialogs (getDialogs())")],
                 # A field of that name the plugin only writes is its own.
                 "        self.allDialogs = []\n": []}
        for body, expected in cases.items():
            self.assertEqual(blockers(body), expected, body)
        self.host.capabilities["operations"] += [OPERATION]
        for body in cases:
            self.assertEqual(blockers(body), [], body)
        self.assertEqual(_ayu_operations.requirements([], [], field_reads=["allDialogs", "unknown"]), {"allDialogs": [[OPERATION]]})
        for member in ("allDialogs", "dialogs_dict"):
            self.assertIsInstance(vars(messenger.MessagesController)[member], property)


class AndroidAbsentMemberTests(base.TelegramCase):
    def test_a_member_android_lacks_blocks_only_where_its_error_is_not_absorbed(self):
        def members(body):
            text = harness.source("absent", imports="from client_utils import get_messages_controller\n",
                                  body="    def on_plugin_load(self):\n" + body)
            report = json.loads(bridge.preflight_plugin_json(text))
            return [item["detail"] for item in report["blockers"] if item["code"] == "MEMBER"]
        controller = "org.telegram.messenger.MessagesController."
        guarded = ("        try:\n            get_messages_controller().callCallbackQuery(5, '')\n        except:\n            pass\n"
                   "        try:\n            get_messages_controller().editMessageReplyMarkup(5, 6, None)\n"
                   "        except Exception as error:\n            self.log(str(error))\n")
        self.assertEqual(members(guarded), [])
        self.assertEqual(members("        get_messages_controller().callCallbackQuery(5, '')\n"), [controller + "callCallbackQuery"])
        # A member Android has stays a blocker inside a handler too.
        self.assertEqual(members("        try:\n            get_messages_controller().pinMessage(5)\n        except Exception:\n            pass\n"),
                         [controller + "pinMessage"])
        for name in ("callCallbackQuery", "editMessageReplyMarkup"):
            self.assertFalse(hasattr(messenger.MessagesController, name))


if __name__ == "__main__":
    unittest.main()
