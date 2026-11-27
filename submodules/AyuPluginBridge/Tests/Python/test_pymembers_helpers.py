"""Helpers of ``ChatObject``, ``UserObject`` and ``MessageObject`` that are functions of TL objects, and SDK-served statics.

The host is synthetic; TL objects and plugin sources are test-authored.
"""
from __future__ import annotations

import unittest
from unittest.mock import patch

from pymembers_fixtures import HostCase, entry
import ayu_bridge as bridge
from _ayu_javalib import exteragram, java_nio, telegram_messenger as messenger, telegram_tl

R = telegram_tl.TLRPC
CONFIG = "org.telegram.messenger.UserConfig"
BUFFER = "java.nio.ByteBuffer"
SELF = 500


def rights(kind, **granted):
    value = kind()
    for name, flag in granted.items():
        setattr(value, name, flag)
    return value


def peer(kind, **ids):
    return rights(kind, **ids)


class PeerCase(HostCase):
    """A host with ``telegram.peer``, the selected account and the account's own user id."""

    def setUp(self):
        super().setUp()
        self.operations("telegram.peer", "client.call")
        self.peers = {}
        self.declare(CONFIG, {"selectedAccount": 0, "getClientUserId": lambda target, args: SELF},
                     entry(methods=["getClientUserId"], static_fields=["selectedAccount"]))
        perform = self.host.perform

        def telegram(request):
            operation, arguments = request["operation"], request["arguments"]
            if operation == "client.call" and arguments["name"] == "get_user_config":
                return {"$handle": "config", "$class": CONFIG}
            return perform(request)

        self.host.perform = telegram
        # The cached peers, as the local ``MessagesController`` decodes them from ``telegram.peer``.
        cached = patch.object(messenger, "_peer", lambda account, kind, identifier, expected: self.peers.get((kind, identifier)))
        cached.start()
        self.addCleanup(cached.stop)


class ChatRightsTests(PeerCase):
    def test_admin_and_banned_rights_decide_what_the_user_can_do(self):
        chat = messenger.ChatObject
        scope = self.load()
        with bridge.runtime.context(scope):
            channel = R.TL_channel()
            channel.id, channel.broadcast = 9, True
            # Android answers true without a chat, and false for a chat that grants nothing.
            self.assertEqual((chat.canUserDoAction(None, chat.ACTION_POST), chat.canPost(channel), chat.canPinMessages(channel),
                              chat.canWriteToChat(channel), chat.canUserDoAdminAction(None, chat.ACTION_POST)),
                             (True, False, False, False, False))
            channel.admin_rights = rights(R.TL_chatAdminRights, post_messages=True, edit_messages=True)
            self.assertEqual((chat.canPost(channel), chat.canWriteToChat(channel), chat.canPinMessages(channel),
                              chat.canBlockUsers(channel), chat.canUserDoAdminAction(channel, chat.ACTION_POST),
                              chat.canUserDoAdminAction(channel.admin_rights, chat.ACTION_POST),
                              chat.canUserDoAdminAction(channel.admin_rights, chat.ACTION_MANAGE_WELCOME)),
                             (True, True, True, False, True, True, False))
            channel.admin_rights.manage_welcome_messages = True
            self.assertTrue(chat.canUserDoAdminAction(channel, chat.ACTION_MANAGE_WELCOME))
            channel.admin_rights, channel.creator = None, True
            self.assertTrue(all(chat.canUserDoAdminAction(channel, action) for action in range(29)))

            group = R.TL_channel()
            group.id, group.megagroup = 10, True
            # No default rights: a bannable action is refused; with them, whatever they do not ban is allowed.
            self.assertFalse(chat.canSendMessages(group))
            group.default_banned_rights = rights(R.TL_chatBannedRights, send_polls=True, pin_messages=True)
            self.assertEqual((chat.canSendMessages(group), chat.canSendPolls(group), chat.canSendPhoto(group),
                              chat.canSendAnyMedia(group), chat.canPinMessages(group), chat.canAddUsers(group),
                              chat.canPost(group), chat.isActionBanned(group, chat.ACTION_SEND_POLLS),
                              chat.isActionBannedByDefault(group, chat.ACTION_SEND)),
                             (True, False, True, True, False, True, False, True, False))
            # An admin is not held to the default restrictions, except for the admin actions themselves.
            group.admin_rights = rights(R.TL_chatAdminRights, delete_messages=True)
            self.assertEqual((chat.canSendPolls(group), chat.canPinMessages(group), chat.canChangeChatInfo(group)),
                             (True, False, True))
            group.admin_rights = None
            group.banned_rights = rights(R.TL_chatBannedRights, send_messages=True, view_messages=True)
            self.assertEqual((chat.canSendMessages(group), chat.isKickedFromChat(group), chat.isKickedFromChat(None)),
                             (False, True, True))
            group.banned_rights = None
            group.left, group.join_to_send = True, True
            self.assertFalse(chat.canSendMessages(group))

            participant = R.TL_channelParticipantAdmin()
            participant.admin_rights = rights(R.TL_chatAdminRights, ban_users=True)
            self.assertEqual((chat.canUserDoAction(group, participant, chat.ACTION_BLOCK_USERS),
                              chat.canUserDoAction(group, participant, chat.ACTION_SEND_POLLS),
                              chat.canUserDoAction(group, participant, chat.ACTION_PIN),
                              chat.canUserDoAction(group, None, chat.ACTION_SEND), chat.canUserDoAction(None, None, 0)),
                             (True, True, False, False, True))
            with self.assertRaises(TypeError):
                chat.canUserDoAction(group)

    def test_boosts_lift_restrictions_through_the_full_chat(self):
        chat = messenger.ChatObject
        scope = self.load()
        with bridge.runtime.context(scope):
            group = R.TL_channel()
            group.id, group.megagroup = 11, True
            group.default_banned_rights = rights(R.TL_chatBannedRights, send_messages=True, send_photos=True)
            self.assertEqual((chat.canSendMessages(group), chat.canSendPhoto(group)), (False, False))
            full = R.TL_channelFull()
            full.id, full.boosts_unrestrict, full.boosts_applied = 11, 2, 1
            self.assertFalse(chat.isIgnoredChatRestrictionsForBoosters(full))
            full.boosts_applied = 2
            self.assertTrue(chat.isIgnoredChatRestrictionsForBoosters(full))
            self.peers[("chat_full", 11)] = full
            self.assertEqual((chat.isIgnoredChatRestrictionsForBoosters(group), chat.canSendMessages(group),
                              chat.canSendPhoto(group), chat.canPost(group)), (True, True, True, False))
            self.assertFalse(chat.isIgnoredChatRestrictionsForBoosters(None))
            # A host snapshot is not a TL chat.
            with self.assertRaises(bridge.UnsupportedAPI):
                chat.canPost(self.reference(CONFIG))

    def test_forum_layout_and_user_predicates(self):
        chat, users = messenger.ChatObject, messenger.UserObject
        forum = R.TL_channel()
        forum.forum, forum.forum_tabs = True, True
        self.assertEqual((chat.areTabsEnabled(forum), chat.areTabsEnabled(None), chat.isSidebarEnabled(forum),
                          chat.shouldSendAnonymously(forum)), (True, False, False, False))
        forum.forum_sidebar = True
        self.assertTrue(chat.isSidebarEnabled(forum))
        user = R.TL_user()
        user.username = "Main"
        other = R.TL_username()
        other.username, other.active = "second", True
        user.usernames.add(other)
        self.assertEqual((users.hasPublicUsername(user, "main"), users.hasPublicUsername(user, "SECOND"),
                          users.hasPublicUsername(user, "third"), users.hasPublicUsername(None, "main"),
                          users.hasPublicUsername(user, None)), (True, True, False, False, False))
        self.assertEqual((users.hasPhoto(user), users.getPhoto(user), users.isBotForum(user)), (False, None, False))
        user.photo = R.TL_userProfilePhotoEmpty()
        self.assertFalse(users.hasPhoto(user))
        user.photo = R.TL_userProfilePhoto()
        user.bot_forum_view, user.bot_forum_can_manage_topics = True, True
        self.assertEqual((users.hasPhoto(user), users.getPhoto(user), users.isBotForum(user), users.isBotForumSidebar(user),
                          users.isBotForumWithEditableTopics(user)), (True, user.photo, True, False, True))


class MessageTopicTests(PeerCase):
    @staticmethod
    def message(kind=R.TL_message, **peer_ids):
        value = kind()
        value.id = 40
        value.peer_id = peer(R.TL_peerChannel if "channel_id" in peer_ids else R.TL_peerUser, **peer_ids)
        return value

    def test_topic_of_a_message(self):
        objects = messenger.MessageObject
        scope = self.load()
        with bridge.runtime.context(scope):
            plain = self.message(channel_id=7)
            self.assertEqual((objects.getTopicId(0, plain), objects.getTopicId(0, plain, True)), (0, 1))
            plain.reply_to = rights(R.TL_messageReplyHeader, forum_topic=True, reply_to_msg_id=31, reply_to_top_id=30)
            self.assertEqual(objects.getTopicId(0, plain, True), 30)
            plain.reply_to.reply_to_top_id = 0
            self.assertEqual(objects.getTopicId(0, plain), 31)
            service = self.message(R.TL_messageService, channel_id=7)
            service.reply_to = rights(R.TL_messageReplyHeader, forum_topic=True, reply_to_msg_id=31, reply_to_top_id=30)
            self.assertEqual(objects.getTopicId(0, service, True), 31)
            service.action = R.TL_messageActionPinMessage()
            self.assertEqual(objects.getTopicId(0, service, True), 30)
            service.action = R.TL_messageActionTopicCreate()
            self.assertEqual(objects.getTopicId(0, service, True), 40)

            # Saved Messages: the dialog a message was saved from is its topic.
            saved = self.message(user_id=SELF)
            saved.from_id = peer(R.TL_peerUser, user_id=SELF)
            self.assertEqual((objects.getTopicId(0, saved), objects.getSavedDialogId(SELF, saved)), (SELF, SELF))
            saved.fwd_from = R.TL_messageFwdHeader()
            self.assertEqual(objects.getTopicId(0, saved), messenger.UserObject.ANONYMOUS)
            saved.fwd_from.saved_from_peer = peer(R.TL_peerChannel, channel_id=8)
            self.assertEqual(objects.getTopicId(0, saved), -8)
            saved.saved_peer_id = peer(R.TL_peerUser, user_id=12)
            self.assertEqual((objects.getTopicId(0, saved), objects.getMonoForumTopicId(saved)), (12, 12))
            saved.from_id = peer(R.TL_peerUser, user_id=3)
            saved.saved_peer_id = None
            self.assertEqual(objects.getSavedDialogId(SELF, saved), 0)
            saved.flags, saved.quick_reply_shortcut_id = 0x40000000, 6
            self.assertEqual(objects.getTopicId(0, saved), 6)

            # Forum type flags: a monoforum reads the saved peer, a bot forum without a topic is pending.
            storage = messenger.MessagesStorage
            direct = self.message(channel_id=7)
            direct.saved_peer_id = peer(R.TL_peerChannel, channel_id=44)
            self.assertEqual((objects.getTopicId(0, direct, storage.FORUM_TYPE_DIRECT),
                              objects.getTopicId(0, self.message(channel_id=7), storage.FORUM_TYPE_BOT),
                              objects.getTopicId(0, self.message(channel_id=7), storage.FORUM_TYPE_CHAT)), (-44, -1, 1))
            with self.assertRaises(TypeError):
                objects.getTopicId(0)

    def test_instance_topic_reads_the_dialogs_chat_and_fields(self):
        objects = messenger.MessageObject
        scope = self.load()
        with bridge.runtime.context(scope):
            forum = R.TL_channel()
            forum.id, forum.forum = 7, True
            self.peers[("chat", 7)] = forum
            owner = self.message(channel_id=7)
            wrapped = objects(0, owner)
            self.assertEqual(wrapped.getTopicId(), 1)
            owner.reply_to = rights(R.TL_messageReplyHeader, forum_topic=True, reply_to_top_id=30)
            self.assertEqual(wrapped.getTopicId(), 30)
            del self.peers[("chat", 7)]
            self.assertEqual(wrapped.getTopicId(), 30)
            owner.reply_to = None
            self.assertEqual(wrapped.getTopicId(), 0)
            self.assertFalse(wrapped.isTopicMainMessage)
            wrapped.isTopicMainMessage = True
            self.assertTrue(wrapped.isTopicMainMessage)
            with self.assertRaises(TypeError):
                wrapped.getTopicId(0, owner)

    def test_photo_of_a_message(self):
        objects = messenger.MessageObject
        owner = self.message(channel_id=7)
        self.assertEqual((objects.getPhoto(owner), objects.getPhoto(None), objects(0, owner).getPhoto()), (None, None, None))
        owner.media = R.TL_messageMediaPhoto()
        owner.media.photo = R.TL_photo()
        self.assertIs(objects(0, owner).getPhoto(), owner.media.photo)
        page = R.TL_messageMediaWebPage()
        page.webpage = R.TL_webPage()
        page.webpage.photo = R.TL_photo()
        owner.media = page
        self.assertIs(objects.getPhoto(owner), page.webpage.photo)


class ServedStaticsTests(PeerCase):
    def test_allocated_buffers_are_local_where_the_host_adapts_byte_buffer(self):
        self.declare(BUFFER, table=entry(methods=["capacity"], static_methods=["wrap"]))
        scope = self.load(imports="from java.nio import ByteBuffer\n")
        with bridge.runtime.context(scope):
            buffers = scope.module.ByteBuffer
            self.assertIs(type(buffers), bridge.JavaClass)
            direct, heap = buffers.allocateDirect(8), buffers.allocate(4)
            self.assertEqual((type(direct), direct.capacity(), direct.isDirect(), heap.isDirect(), heap.capacity()),
                             (java_nio.ByteBuffer, 8, True, False, 4))
            direct.putInt(0x01020304)
            heap.putInt(0x01020304)
            self.assertEqual((direct.getInt(0), bytes(heap.array())), (0x01020304, b"\x01\x02\x03\x04"))
            with self.assertRaises(ValueError):
                buffers.allocateDirect(-1)
            self.assertEqual(self.host_requests(), [])
        body = ("    def on_plugin_load(self):\n        buffer = ByteBuffer.allocateDirect(16)\n"
                "        buffer.order(None)\n        ByteBuffer.wrap(b'')\n        ByteBuffer.allocateShared(1)\n")
        self.assertEqual(self.blockers("from java.nio import ByteBuffer\n", body), [("MEMBER", BUFFER + ".allocateShared")])
        # Preflight knows the result is the local class, whose members the host's table does not list.
        import _ayu_members
        tables = _ayu_members.Tables(bridge.runtime._capabilities())
        self.assertEqual(tables.call(BUFFER, "allocateDirect", True), ("instance", java_nio.ByteBuffer))

    def test_plugins_controller_posts_to_the_plugins_queue(self):
        self.operations("plugins.list", "plugins.settings")
        scope = self.load()
        ran = []
        with bridge.runtime.context(scope):
            controller = exteragram.PluginsController

            class Task:
                def run(self):
                    ran.append("task")

            controller.runOnPluginsQueue(Task())
            controller.runOnPluginsQueue(lambda: ran.append("callable"))
            self.assertEqual((controller.isPluginEngineSupported(), controller.getInstance().isInitialized()), (True, True))
        scheduled = [item["arguments"] for item in self.host.requests if item["operation"] == "scheduler.schedule"]
        self.assertEqual([item["queue"] for item in scheduled], ["pluginsQueue", "pluginsQueue"])
        self.assertEqual(ran, [])


if __name__ == "__main__":
    unittest.main()
