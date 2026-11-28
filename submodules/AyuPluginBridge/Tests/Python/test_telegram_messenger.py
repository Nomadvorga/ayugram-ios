"""Pure ``org.telegram.messenger`` logic over TL objects; no host is involved."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_javalib
import ayu_bridge as bridge
from _ayu_javalib import exteragram
from _ayu_javalib import telegram_messenger as messenger
from _ayu_javalib import telegram_tl as tl
from _ayu_javalib import telegram_ui as ui

R = tl.TLRPC
MessageObject = messenger.MessageObject


def document(mime, *attributes, name=None):
    value = R.TL_document()
    value.id, value.dc_id, value.mime_type, value.size = 9, 2, mime, 1234
    for attribute in attributes:
        value.attributes.add(attribute)
    if name is not None:
        item = R.TL_documentAttributeFilename()
        item.file_name = name
        value.attributes.add(item)
    return value


def audio(voice=False, title=None, performer=None, duration=3.5):
    value = R.TL_documentAttributeAudio()
    value.voice, value.title, value.performer, value.duration = voice, title, performer, duration
    return value


def video(width=640, height=480, round_message=False):
    value = R.TL_documentAttributeVideo()
    value.w, value.h, value.round_message, value.duration = width, height, round_message, 12.0
    return value


def message(media_document=None, text="hi", channel=77):
    value = R.TL_message()
    value.id, value.message = 5, text
    value.peer_id = R.TL_peerChannel()
    value.peer_id.channel_id = channel
    if media_document is not None:
        value.media = R.TL_messageMediaDocument()
        value.media.document = media_document
    return value


class MessageObjectTests(unittest.TestCase):
    def test_identity_and_dialog_rules(self):
        owner = message()
        obj = MessageObject(3, owner, False, False)
        self.assertEqual((obj.currentAccount, obj.getId(), obj.getDialogId(), obj.getChatId(), owner.dialog_id), (3, 5, -77, 77, -77))
        self.assertEqual(MessageObject.getDialogId(message(channel=8)), -8)
        private = R.TL_message()
        private.peer_id, private.from_id = R.TL_peerUser(), R.TL_peerUser()
        private.peer_id.user_id, private.from_id.user_id = 10, 20
        self.assertEqual(MessageObject.getDialogId(private), 20)
        private.dialog_id, private.out = 0, True
        self.assertEqual(MessageObject(0, private).getDialogId(), 10)
        self.assertEqual((MessageObject.getFromChatId(private), MessageObject.getPeerId(owner.peer_id)), (20, -77))
        self.assertEqual(obj.to_bridge()["id"], 5)
        with self.assertRaises(TypeError):
            MessageObject(0, R.TL_inputPeerSelf())

    def test_text_caption_and_unimplemented_members(self):
        plain = MessageObject(0, message())
        self.assertEqual((plain.messageText, plain.caption, plain.isMediaEmpty()), ("hi", None, True))
        media = MessageObject(0, message(document("audio/mpeg", audio())))
        self.assertEqual((media.caption, media.isMediaEmpty()), ("hi", False))
        for read in (lambda: media.messageText, lambda: media.type):
            with self.subTest(read=read), self.assertRaises(bridge.UnsupportedAPI):
                read()
        with self.assertRaises(bridge.UnsupportedAPI):
            media.type = 1

    def test_media_classification_matches_android(self):
        music = message(document("audio/mpeg", audio(title="T", performer="P"), name="a/b.mp3"))
        obj = MessageObject(0, music)
        self.assertEqual((obj.isMusic(), obj.isVoice(), obj.isVideo(), obj.isGif(), obj.isPhoto()), (True, False, False, False, False))
        self.assertEqual((obj.getDuration(), obj.getMusicTitle(), obj.getMusicAuthor(), obj.getDocumentName(), obj.getFileName(),
                          obj.getSize()), (3.5, "T", "P", "ab.mp3", "2_9.mp3", 1234))
        self.assertTrue(MessageObject.isMusicMessage(music))
        voice = MessageObject(0, message(document("audio/ogg", audio(voice=True))))
        self.assertEqual((voice.isVoice(), voice.isMusic(), voice.getMusicTitle(False)), (True, False, None))
        with self.assertRaises(bridge.UnsupportedAPI):
            voice.getMusicTitle()
        self.assertEqual(MessageObject(0, message(document("audio/mpeg", audio()))).getMusicTitle(), "Unknown title")
        clip = MessageObject(0, message(document("video/mp4", video())))
        self.assertEqual((clip.isVideo(), clip.isRoundVideo(), clip.isMusic()), (True, False, False))
        round_clip = MessageObject(0, message(document("video/mp4", video(round_message=True))))
        self.assertEqual((round_clip.isVideo(), round_clip.isRoundVideo(), round_clip.caption), (False, True, None))
        gif = document("video/mp4", video(), R.TL_documentAttributeAnimated())
        self.assertEqual((MessageObject.isGifDocument(gif), MessageObject.isVideoDocument(gif), MessageObject.isNewGifDocument(gif)),
                         (True, False, True))
        self.assertFalse(MessageObject.isVideoDocument(document("video/mp4", video(), name="setup.EXE")))
        self.assertTrue(MessageObject.isVideoDocument(document("video/mp4", video(), name="clip.mp4")))
        sticker = document("image/webp", R.TL_documentAttributeSticker())
        self.assertEqual((MessageObject.isStickerDocument(sticker), MessageObject.isVideoStickerDocument(sticker),
                          MessageObject.isStaticStickerDocument(sticker), MessageObject.isAnimatedStickerDocument(sticker)),
                         (True, False, True, False))
        self.assertFalse(MessageObject.isVoiceDocument(None))

    def test_forward_and_reply_flags(self):
        owner = message()
        owner.fwd_from = R.TL_messageFwdHeader()
        self.assertFalse(MessageObject(0, owner).isForwarded())
        owner.flags |= R.MESSAGE_FLAG_FWD
        self.assertTrue(MessageObject.isForwardedMessage(owner))
        owner.reply_to = R.TL_messageReplyHeader()
        owner.reply_to.reply_to_msg_id = 4
        owner.flags |= R.MESSAGE_FLAG_REPLY
        self.assertEqual((MessageObject(0, owner).isReply(), MessageObject(0, owner).getReplyMsgId()), (True, 4))


class StaticHelperTests(unittest.TestCase):
    def test_dialog_object(self):
        dialog = messenger.DialogObject
        encrypted = dialog.makeEncryptedDialogId(-1)
        self.assertEqual((dialog.isEncryptedDialog(encrypted), dialog.getEncryptedChatId(encrypted), dialog.isUserDialog(encrypted)),
                         (True, -1, False))
        self.assertEqual((dialog.isUserDialog(5), dialog.isChatDialog(-5), dialog.isEncryptedDialog(-5)), (True, True, False))
        folder = dialog.makeFolderDialogId(1)
        self.assertEqual((dialog.isFolderDialogId(folder), dialog.getFolderId(folder), dialog.isFolderDialogId(-folder)), (True, 1, False))
        peer = R.TL_peerChat()
        peer.chat_id = 4
        user = R.TL_user()
        user.id = 6
        self.assertEqual((dialog.getPeerDialogId(peer), dialog.getPeerDialogId(None), dialog.getDialogId(user)), (-4, 0, 6))
        with self.assertRaises(TypeError):
            dialog.isEncryptedDialog(2 ** 63)

    def test_chat_and_user_predicates(self):
        channel = R.TL_channel()
        channel.id, channel.megagroup = 3, True
        group = R.TL_chat()
        chat = messenger.ChatObject
        self.assertEqual((chat.isChannel(channel), chat.isMegagroup(channel), chat.isChannelAndNotMegaGroup(channel),
                          chat.isChannel(group), chat.isChannel(None), chat.isForum(None)), (True, True, False, False, False, False))
        channel.megagroup, channel.left = False, True
        self.assertEqual((chat.isChannelAndNotMegaGroup(channel), chat.isNotInChat(channel), chat.isInChat(group),
                          chat.isNotInChat(R.TL_chatForbidden()), chat.hasAdminRights(channel)), (True, True, True, True, False))
        channel.creator = True
        name = R.TL_username()
        name.username, name.active = "room", True
        channel.usernames.add(name)
        self.assertEqual((chat.hasAdminRights(channel), chat.getPublicUsername(channel), chat.isPublic(group)), (True, "room", False))
        # Rights are pure functions of the chat (``test_pymembers_helpers``).
        self.assertTrue(chat.canPost(channel))
        user = R.TL_user()
        user.id, user.bot = 777000, True
        users = messenger.UserObject
        self.assertEqual((users.isBot(user), users.isService(user.id), users.isDeleted(None), users.isDeleted(user),
                          users.isUserSelf(user), users.isReplyUser(708513), users.getPublicUsername(user)),
                         (True, True, True, False, False, True, None))

    def test_file_loader_names(self):
        loader = messenger.FileLoader
        named = document("audio/mpeg", name=" a<b>:c.Mp3 ")
        self.assertEqual((loader.getDocumentFileName(named), loader.getAttachFileName(named), loader.getDocumentExtension(named)),
                         ("abc.Mp3", "2_9.Mp3", "MP3"))
        self.assertEqual(loader.getAttachFileName(document("video/mp4")), "2_9.mp4")
        self.assertEqual(loader.getAttachFileName(document("application/zip")), "2_9")
        self.assertIsNone(loader.getDocumentFileName(None))
        sizes = []
        for kind, width in (("s", 90), ("m", 320), ("x", 800)):
            size = R.TL_photoSize()
            size.type, size.w, size.h = kind, width, width
            sizes.append(size)
        sizes.insert(0, R.TL_photoSizeEmpty())
        self.assertEqual(loader.getClosestPhotoSizeWithSize(sizes, 400).w, 320)
        self.assertEqual(loader.getClosestPhotoSizeWithSize(sizes, 50).w, 90)
        self.assertEqual(loader.getClosestPhotoSizeWithSize(sizes, 1280).w, 800)
        # By the smaller side Android keeps growing until the size covers the request.
        self.assertEqual(loader.getClosestPhotoSizeWithSize(sizes, 100, True).w, 320)
        self.assertIsNone(loader.getClosestPhotoSizeWithSize([], 100))
        location = R.TL_fileLocationToBeDeprecated()
        location.volume_id, location.local_id = 4, 5
        sizes[1].location = location
        self.assertEqual((loader.getAttachFileName(sizes[1]), loader.getAttachFileName(sizes[1], "png"), loader.getAttachFileName(sizes[2])),
                         ("4_5.jpg", "4_5.png", ""))
        self.assertEqual((loader.PRIORITY_HIGH, loader.MEDIA_DIR_CACHE), (3, 4))

    def test_utilities(self):
        utilities = messenger.Utilities
        self.assertEqual((utilities.MD5("a"), utilities.bytesToHex([-1, 16]), utilities.hexToBytes("ff10"), utilities.parseInt("ab-12c"),
                          utilities.parseLong("x77"), utilities.clamp(5, 3, 1), utilities.bytesToInt(b"\xff\xff\xff\xff")),
                         ("0cc175b9c0f1b6a831c399e269772661", "FF10", b"\xff\x10", -12, 77, 3, -1))
        self.assertEqual(len(utilities.generateRandomString()), 16)
        self.assertTrue(0 <= utilities.random.nextInt(10) < 10)
        self.assertIs(_ayu_javalib.local_class("org.telegram.messenger.Utilities$Callback"), utilities.Callback)
        with self.assertRaises(bridge.UnsupportedAPI):
            utilities.stackBlurBitmap
        self.assertFalse(hasattr(utilities, "stackBlurBitmap"))

    def test_resource_ids_are_symbolic(self):
        resources = messenger.R
        icon = resources.drawable.msg_clear
        self.assertEqual(icon.to_bridge(), {"resource": "drawable", "name": "msg_clear"})
        self.assertTrue(icon == resources.drawable.msg_clear and icon != resources.raw.msg_clear and icon != 0 and icon)
        self.assertEqual(len({icon, resources.drawable.msg_clear, resources.string.Search}), 2)
        self.assertIs(_ayu_javalib.local_class("org.telegram.messenger.R$drawable"), resources.drawable)
        self.assertFalse(hasattr(resources, "nothing"))
        self.assertEqual(messenger.BuildVars.BUILD_VERSION_STRING, "13.2.2")
        with self.assertRaises(bridge.UnsupportedAPI):
            messenger.BuildVars.APP_ID


class HostObjectTests(unittest.TestCase):
    def test_static_helpers_refuse_host_objects(self):
        chat, user = (bridge.RemoteObject(bridge.runtime, None, "h", "org.telegram.tgnet.TLRPC$" + name) for name in ("Chat", "User"))
        calls = (lambda: messenger.ChatObject.isChannel(chat), lambda: messenger.ChatObject.isMegagroup(chat),
                 lambda: messenger.ChatObject.getPublicUsername(chat, editable=True), lambda: messenger.ChatObject.isForum(chat),
                 lambda: messenger.DialogObject.getDialogId(chat), lambda: messenger.DialogObject.getDialogId(obj=user),
                 lambda: messenger.UserObject.isBot(user), lambda: messenger.UserObject.isDeleted(user),
                 lambda: messenger.FileLoader.getAttachFileName(chat), lambda: MessageObject.isVideoDocument(user),
                 lambda: messenger.SendMessageParams.of(user, 1, None, None, None, None, True, 0, 0))
        for call in calls:
            with self.subTest(call=call), self.assertRaises(bridge.UnsupportedAPI) as caught:
                call()
            # Not an AttributeError: ``getattr(..., default)`` must not turn the refusal into an answer.
            self.assertNotIsInstance(caught.exception, AttributeError)
            self.assertIn("host object <native org.telegram.tgnet.TLRPC$", str(caught.exception))
        channel = R.TL_channel()
        channel.id = 9
        self.assertEqual((messenger.ChatObject.isChannel(channel), messenger.DialogObject.getDialogId(channel),
                          messenger.DialogObject.getDialogId(None)), (True, -9, 0))


class GatingTests(unittest.TestCase):
    def test_host_backed_classes_name_their_operations(self):
        today = ["client.call", "hooks.register", "menus.register", "java.construct", "java.invoke", "java.set_field"]
        usable = _ayu_javalib.local_class_names(today)
        for name in ("org.telegram.tgnet.TLRPC", "org.telegram.messenger.MessageObject", "org.telegram.messenger.DialogObject",
                     "org.telegram.messenger.Utilities", "org.telegram.ui.LaunchActivity",
                     "com.exteragram.messenger.plugins.PluginsConstants"):
            self.assertIn(name, usable)
        expected = {
            "org.telegram.messenger.R": "resources.resolve",
            "org.telegram.messenger.R$drawable": "resources.resolve",
            "org.telegram.messenger.R$string": "resources.resolve",
            "org.telegram.messenger.ChatObject": "telegram.peer",
            "org.telegram.messenger.UserObject": "telegram.peer",
            "org.telegram.messenger.FileLoader": "telegram.files.path",
            "org.telegram.messenger.MessagesController": "telegram.peer",
            "org.telegram.messenger.AccountInstance": "telegram.peer",
            "org.telegram.messenger.SendMessagesHelper": "telegram.send_message",
            "org.telegram.messenger.MessagesStorage": "telegram.messages",
            "org.telegram.messenger.MediaController": "telegram.player",
            "org.telegram.tgnet.ConnectionsManager": "telegram.request",
            "org.telegram.ui.Components.LayoutHelper": "ui.layout_params",
            "org.telegram.ui.ActionBar.BaseFragment": "telegram.screen",
            "org.telegram.ui.ChatActivity": "telegram.screen",
            "com.exteragram.messenger.plugins.PluginsController": "plugins.list",
            "com.exteragram.messenger.plugins.ui.PluginSettingsActivity": "plugins.list",
        }
        for name, operation in expected.items():
            with self.subTest(name=name):
                self.assertNotIn(name, usable)
                self.assertEqual(_ayu_javalib.missing_operations(name, today)[0], operation)
        overrides = {name for name in list(messenger.CLASSES) + list(ui.CLASSES) + list(exteragram.CLASSES)
                     if _ayu_javalib.overrides_host(_ayu_javalib.local_class(name))}
        self.assertEqual(overrides, {"org.telegram.messenger.MessagesController", "org.telegram.messenger.AccountInstance",
                                     "org.telegram.ui.ActionBar.BaseFragment", "org.telegram.ui.ActionBar.AlertDialog"})

    def test_constants_mirror_android(self):
        constants = exteragram.PluginsConstants
        self.assertEqual((constants.SEND_MESSAGE_HOOK, constants.Strategy.MODIFY_FINAL, constants.MenuItemTypes.CHAT_ACTION_MENU,
                          constants.HookFilterTypes.OR), ("send_message_hook", "MODIFY_FINAL", "chat_action_menu", "or"))
        self.assertIs(_ayu_javalib.local_class("com.exteragram.messenger.plugins.PluginsConstants$Strategy"), constants.Strategy)
        self.assertEqual((ui.ChatActivity.MODE_SAVED, ui.LayoutHelper.MATCH_PARENT), (3, -1))


if __name__ == "__main__":
    unittest.main()
