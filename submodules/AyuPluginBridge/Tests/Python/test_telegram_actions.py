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
ACTIONS = ["telegram.action.delete_messages", "telegram.action.read_dialog", "telegram.action.process_updates",
           "telegram.action.store_peers", "telegram.action.load_full_peer"]


class ActionHost(base.TelegramHost):
    def perform(self, request):
        if request["operation"] in ACTIONS:
            self.calls.append((request["operation"], request["arguments"]))
            return None
        return super().perform(request)

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


class UndeclaredActionTests(ActionCase):
    declared = ["telegram.action.read_dialog"]

    def test_each_member_needs_its_own_operation(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            controller = messenger.MessagesController.getInstance(0)
            controller.markDialogAsRead(4, 9, 9, 0, False, 0, 0, True, 0)
            for call in (lambda: controller.deleteMessages([1], None, None, 4, 0, True, 0), lambda: controller.processUpdates(R.TL_updates()),
                         lambda: controller.putUsers([base.user()], False), lambda: controller.loadFullChat(5, 0, False)):
                with self.assertRaises(bridge.UnsupportedAPI):
                    call()
            self.assertEqual([name for name, _ in self.host.calls], ["telegram.action.read_dialog"])

    def test_preflight_names_the_missing_operation(self):
        members = {"deleteMessages": "telegram.action.delete_messages", "markDialogAsRead": "telegram.action.read_dialog",
                   "processUpdates": "telegram.action.process_updates", "putUser": "telegram.action.store_peers",
                   "putUsers": "telegram.action.store_peers", "putChat": "telegram.action.store_peers",
                   "putChats": "telegram.action.store_peers", "loadFullUser": "telegram.action.load_full_peer",
                   "loadFullChat": "telegram.action.load_full_peer"}
        for member, operation in members.items():
            self.assertEqual(_ayu_operations.METHODS[member], ((operation,),))
            self.assertTrue(callable(getattr(messenger.MessagesController, member)))
        self.assertNotIn("deleteMessages", _ayu_operations.UNPROVIDED_MEMBERS)
        self.assertEqual(sorted(set(operation for operation in members.values())), sorted(ACTIONS))


if __name__ == "__main__":
    unittest.main()
