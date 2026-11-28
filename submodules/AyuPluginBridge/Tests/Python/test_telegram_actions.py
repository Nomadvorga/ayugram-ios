"""``MessagesController`` state changes against a synthetic host: one ``telegram.action.*`` operation each."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_operations
import ayu_bridge as bridge
import test_telegram_host as base
from _ayu_javalib import telegram_messenger as messenger

R = base.R
ACTIONS = ["telegram.action.delete_messages", "telegram.action.read_dialog", "telegram.action.read_all_dialogs",
           "telegram.action.process_updates", "telegram.action.store_peers", "telegram.action.load_full_peer",
           "telegram.action.add_dialogs_to_folder"]


class ActionHost(base.TelegramHost):
    def perform(self, request):
        if request["operation"] in ACTIONS:
            self.calls.append((request["operation"], request["arguments"]))
            if request["operation"] == "telegram.action.add_dialogs_to_folder":
                return self.folder_results.pop(0) if self.folder_results else 1
            return None
        return super().perform(request)

    folder_results = ()

    def named(self, operation):
        return [arguments for name, arguments in self.calls if name == operation]


class ActionCase(base.TelegramCase):
    declared = ACTIONS

    def setUp(self):
        super().setUp()
        self.host = ActionHost(base.OPERATIONS + list(self.declared))
        sys.modules["_ayu_host"].dispatch = self.host.dispatch


class ActionTests(ActionCase):
    def test_delete_messages_maps_every_android_overload(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            controller = messenger.MessagesController.getInstance(2)
            controller.deleteMessages([7, 9], None, None, -55, 0, True, 0)                      # topicId, forAll, mode
            controller.deleteMessages([8], [], None, 42, 3, False, 0, False)                    # ..., cacheOnly
            controller.deleteMessages([6], None, None, 42, True, 0, False, 0, None, 0)          # forAll first
            controller.deleteMessages([5], None, None, 42, False, False)                        # forAll, scheduled
            controller.deleteMessages([], None, None, 42, 0, True, 0)
            self.assertEqual(self.host.named("telegram.action.delete_messages"), [
                {"account": 2, "dialog_id": -55, "ids": [7, 9], "revoke": True},
                {"account": 2, "dialog_id": 42, "ids": [8], "revoke": False},
                {"account": 2, "dialog_id": 42, "ids": [6], "revoke": True},
                {"account": 2, "dialog_id": 42, "ids": [5], "revoke": False},
            ])
            self.host.calls.clear()
            controller.deleteMessages(list(range(1, 251)), None, None, 42, 0, True, 0)
            self.assertEqual([len(call["ids"]) for call in self.host.named("telegram.action.delete_messages")], [100, 100, 50])
            self.host.calls.clear()
            for arguments in (([1], None, R.TL_encryptedChat(), 42, 0, True, 0), ([1], [5], None, 42, 0, True, 0),
                              ([1], None, None, 42, 0, True, 1), ([1], None, None, 42, True, True),
                              ([1], None, None, 42, 0, True, 0, True)):
                with self.assertRaises(bridge.UnsupportedAPI):
                    controller.deleteMessages(*arguments)
            for arguments in (([1], None, None, 42), ([1], None, None, 42, 0), ([1], None, None, 42, "x", 0), (["1"], None, None, 42, True, 0)):
                with self.assertRaises((TypeError, ValueError)):
                    controller.deleteMessages(*arguments)
            self.assertEqual(self.host.calls, [])

    def test_read_process_store_and_load(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            controller = messenger.MessagesController.getInstance(1)
            controller.markDialogAsRead(-9, 77, 77, 1_700_000_000, False, 0, 0, True, 0)
            updates = R.TL_updates()
            controller.processUpdates(updates, False)
            ann, group = base.user(), R.TL_chatEmpty()
            group.id = 5
            self.assertTrue(controller.putUser(ann, False))
            self.assertFalse(controller.putUser(None, False))
            controller.putUsers([ann, base.user(43)], True)
            controller.putChat(group, False)
            controller.putChats([group], False)
            controller.putChats([], False)
            controller.loadFullUser(ann, 0, True)
            controller.loadFullUser(None, 0, True)
            controller.loadFullChat(5, 0, False)
            self.assertEqual(self.host.calls, [
                ("telegram.action.read_dialog", {"account": 1, "dialog_id": -9, "max_id": 77}),
                ("telegram.action.process_updates", {"account": 1, "updates": updates.to_bridge()}),
                ("telegram.action.store_peers", {"account": 1, "users": [ann.to_bridge()], "chats": []}),
                ("telegram.action.store_peers", {"account": 1, "users": [ann.to_bridge(), base.user(43).to_bridge()], "chats": []}),
                ("telegram.action.store_peers", {"account": 1, "users": [], "chats": [group.to_bridge()]}),
                ("telegram.action.store_peers", {"account": 1, "users": [], "chats": [group.to_bridge()]}),
                ("telegram.action.load_full_peer", {"account": 1, "kind": "user", "id": 42}),
                ("telegram.action.load_full_peer", {"account": 1, "kind": "chat", "id": 5}),
            ])
            self.host.calls.clear()
            controller.putUsers([base.user(index) for index in range(1, 302)], False)
            self.assertEqual([len(call["users"]) for call in self.host.named("telegram.action.store_peers")], [200, 101])
            with self.assertRaises(bridge.UnsupportedAPI):
                controller.markDialogAsRead(-9, 77, 77, 0, False, 12, 0, True, 0)
            with self.assertRaises(bridge.UnsupportedAPI):
                controller.loadFullUser(ann, 0, True, lambda full: None)
            for call in (lambda: controller.processUpdates(ann), lambda: controller.putUsers([group], False),
                         lambda: controller.putChat(ann, False)):
                with self.assertRaises(TypeError):
                    call()

    def test_read_all_dialogs_of_a_folder_or_of_all(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            storage = messenger.MessagesStorage.getInstance(1)
            for folder in (-1, 0, 1):
                storage.readAllDialogs(folder)
            self.assertEqual(self.host.calls, [("telegram.action.read_all_dialogs", {"account": 1, "folder_id": folder})
                                               for folder in (-1, 0, 1)])
            for folder in ("0", None, 1.0, 2 ** 31):
                with self.assertRaises((TypeError, ValueError)):
                    storage.readAllDialogs(folder)
            self.assertEqual(len(self.host.calls), 3)


    def test_add_dialog_to_folder_maps_both_android_overloads(self):
        scope = self.load()
        secret = messenger.DialogObject.makeEncryptedDialogId(5)
        folder = messenger.DialogObject.makeFolderDialogId(1)
        with bridge.runtime.context(scope):
            controller = messenger.MessagesController.getInstance(2)
            operation = "telegram.action.add_dialogs_to_folder"
            self.host.folder_results = [2, 1, 0]
            self.assertEqual(controller.addDialogToFolder(42, 1, -1, 0), 2)                      # dialogId, folderId, pinnedNum, taskId
            self.assertEqual(controller.addDialogToFolder([42, -55, 42, 0, folder], 0, 0, None, 0), 1)
            self.assertEqual(controller.addDialogToFolder([7], 1, -1, [], 0), 0)
            self.assertEqual(self.host.named(operation), [{"account": 2, "dialog_ids": [42], "folder_id": 1},
                                                          {"account": 2, "dialog_ids": [42, -55], "folder_id": 0},
                                                          {"account": 2, "dialog_ids": [7], "folder_id": 1}])
            self.host.calls.clear()
            # Nothing the host could move: Android answers 0 without a request.
            for dialogs in ([], None, [0], [folder]):
                self.assertEqual(controller.addDialogToFolder(dialogs, 1, -1, None, 0), 0)
            self.assertEqual(self.host.calls, [])
            # Longer lists go in calls of 100; the archive appeared if any call says so.
            self.host.folder_results = [1, 2, 0]
            self.assertEqual(controller.addDialogToFolder(list(range(1, 251)), 1, -1, None, 0), 2)
            self.assertEqual([len(call["dialog_ids"]) for call in self.host.named(operation)], [100, 100, 50])
            self.host.calls.clear()
            for arguments in ((42, 1, 3, 0), (42, 1, -1, 9), (42, 2, -1, 0), (42, -1, -1, 0), (secret, 1, -1, 0),
                              ([42, secret], 1, -1, None, 0), ([42], 1, -1, None, 9)):
                with self.assertRaises(bridge.UnsupportedAPI):
                    controller.addDialogToFolder(*arguments)
            for arguments in ((42, 1, -1), (42, 1, -1, None, 0), ([42], 1, -1, 0), ("42", 1, -1, 0), (42, "1", -1, 0),
                              (42, 1, None, 0), ([42.0], 1, -1, None, 0), (42, 1, -1, None)):
                with self.assertRaises(TypeError):
                    controller.addDialogToFolder(*arguments)
            self.assertEqual(self.host.calls, [])
            for answer in (None, 3, True, "1"):
                self.host.folder_results = [answer]
                with self.assertRaises(bridge.ProtocolError):
                    controller.addDialogToFolder(42, 1, -1, 0)


class UndeclaredActionTests(ActionCase):
    declared = ["telegram.action.read_dialog"]

    def test_each_member_needs_its_own_operation(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            controller = messenger.MessagesController.getInstance(0)
            controller.markDialogAsRead(4, 9, 9, 0, False, 0, 0, True, 0)
            for call in (lambda: controller.deleteMessages([1], None, None, 4, 0, True, 0), lambda: controller.processUpdates(R.TL_updates()),
                         lambda: controller.putUsers([base.user()], False), lambda: controller.loadFullChat(5, 0, False),
                         lambda: controller.addDialogToFolder(4, 1, -1, 0)):
                with self.assertRaises(bridge.UnsupportedAPI):
                    call()
            with self.assertRaises(bridge.UnsupportedAPI):
                messenger.MessagesStorage.getInstance(0).readAllDialogs(-1)
            self.assertEqual([name for name, _ in self.host.calls], ["telegram.action.read_dialog"])

    def test_preflight_names_the_missing_operation(self):
        members = {"deleteMessages": "telegram.action.delete_messages", "markDialogAsRead": "telegram.action.read_dialog",
                   "processUpdates": "telegram.action.process_updates", "putUser": "telegram.action.store_peers",
                   "putUsers": "telegram.action.store_peers", "putChat": "telegram.action.store_peers",
                   "putChats": "telegram.action.store_peers", "loadFullUser": "telegram.action.load_full_peer",
                   "loadFullChat": "telegram.action.load_full_peer", "addDialogToFolder": "telegram.action.add_dialogs_to_folder"}
        for member, operation in members.items():
            self.assertEqual(_ayu_operations.METHODS[member], ((operation,),))
            self.assertTrue(callable(getattr(messenger.MessagesController, member)))
        self.assertNotIn("deleteMessages", _ayu_operations.UNPROVIDED_MEMBERS)
        self.assertNotIn("addDialogToFolder", _ayu_operations.UNPROVIDED_MEMBERS)
        self.assertEqual(_ayu_operations.METHODS["readAllDialogs"], (("telegram.action.read_all_dialogs",),))
        self.assertNotIn("readAllDialogs", _ayu_operations.UNPROVIDED_MEMBERS)
        self.assertTrue(callable(messenger.MessagesStorage.readAllDialogs))
        self.assertEqual(sorted(set(members.values()) | {"telegram.action.read_all_dialogs"}), sorted(ACTIONS))


if __name__ == "__main__":
    unittest.main()
