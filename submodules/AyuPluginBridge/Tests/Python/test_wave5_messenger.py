"""Wave 5 messenger lane: ``MessageObject.isSticker``/``isDocument`` over Android's computed type."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_operations
import ayu_bridge as bridge
from _ayu_javalib import telegram_messenger as messenger
from _ayu_javalib import telegram_tl as tl

R = tl.TLRPC
MessageObject = messenger.MessageObject


def document(mime, *attributes, name=None, thumbs=False):
    value = R.TL_document()
    value.id, value.dc_id, value.mime_type, value.size = 9, 2, mime, 1234
    for attribute in attributes:
        value.attributes.add(attribute)
    if name is not None:
        item = R.TL_documentAttributeFilename()
        item.file_name = name
        value.attributes.add(item)
    if thumbs:
        value.thumbs.add(R.TL_photoSize())
    return value


def sticker(short_name=None):
    value = R.TL_documentAttributeSticker()
    if short_name is not None:
        value.stickerset = R.TL_inputStickerSetShortName()
        value.stickerset.short_name = short_name
    return value


def audio(voice=False):
    value = R.TL_documentAttributeAudio()
    value.voice, value.duration = voice, 3.0
    return value


def video(round_message=False, animated=False):
    value = R.TL_documentAttributeVideo()
    value.w, value.h, value.round_message, value.duration = 640, 480, round_message, 12.0
    return (value, R.TL_documentAttributeAnimated()) if animated else (value,)


def message(media=None, text="hi", cls=None):
    value = (cls or R.TL_message)()
    value.id, value.message = 5, text
    value.peer_id = R.TL_peerChannel()
    value.peer_id.channel_id = 77
    if isinstance(media, R.Document):
        value.media = R.TL_messageMediaDocument()
        value.media.document = media
    elif media is not None:
        value.media = media
    return value


def answers(owner):
    obj = MessageObject(0, owner)
    return obj.isSticker(), obj.isDocument()


class StickerAndDocumentTests(unittest.TestCase):
    def test_names_left_the_unprovided_list(self):
        self.assertNotIn("isSticker", _ayu_operations.UNPROVIDED_MEMBERS)
        self.assertNotIn("isDocument", _ayu_operations.UNPROVIDED_MEMBERS)

    def test_documents_follow_the_android_type(self):
        cases = {
            "file": (document("application/pdf", name="a.pdf"), (False, True)),
            "webp sticker": (document("image/webp", sticker()), (True, False)),
            "webm sticker": (document("video/webm", sticker()), (True, False)),
            "webp without the attribute": (document("image/webp"), (False, True)),
            "tgs sticker": (document("application/x-tgsticker", sticker("set"), thumbs=True), (False, False)),
            "tgs without thumbs": (document("application/x-tgsticker", sticker("set")), (False, True)),
            "voice": (document("audio/ogg", audio(True)), (False, False)),
            "music": (document("audio/mpeg", audio()), (False, False)),
            "video": (document("video/mp4", *video()), (False, False)),
            "round": (document("video/mp4", *video(round_message=True)), (False, True)),
            "gif": (document("video/mp4", *video(animated=True)), (False, True)),
            "no mime": (document(None), (False, True)),
        }
        for name, (media, expected) in cases.items():
            with self.subTest(name):
                self.assertEqual(answers(message(media)), expected)

    def test_other_media_and_messages(self):
        photo = R.TL_messageMediaPhoto()
        photo.photo = R.TL_photo()
        self.assertEqual(answers(message(photo)), (False, False))
        self.assertEqual(answers(message(R.TL_messageMediaDice())), (False, False))
        self.assertEqual(answers(message(text="plain text")), (False, False))
        self.assertEqual(answers(message(text="привет 🙂")), (False, False))
        self.assertEqual(answers(message(cls=R.TL_messageService)), (False, False))
        page = R.TL_messageMediaWebPage()
        page.webpage = R.TL_webPage()
        page.webpage.document = document("image/webp", sticker())
        self.assertEqual(answers(message(page)), (False, True))
        expired = message(R.TL_messageMediaDocument())
        expired.media.ttl_seconds = 5
        self.assertEqual(answers(expired), (False, False))

    def test_grouped_image_gif_is_a_file(self):
        owner = message(document("image/gif"))
        self.assertEqual(MessageObject(0, owner)._media_type(), MessageObject.TYPE_GIF)
        owner.grouped_id = 4
        self.assertEqual(MessageObject(0, owner)._media_type(), MessageObject.TYPE_FILE)

    def test_state_the_sdk_cannot_see_is_refused(self):
        for text in ("🙂", "👍🏽", "1\ufe0f\u20e3"):
            obj = MessageObject(0, message(text=text))
            with self.subTest(text), self.assertRaises(bridge.UnsupportedAPI):
                obj.isSticker()
            self.assertFalse(obj.isDocument())
        self.assertFalse(MessageObject(0, message(text="1")).isSticker())
        restricted = message(document("image/webp", sticker()))
        restricted.restriction_reason.add(object())
        with self.assertRaises(bridge.UnsupportedAPI):
            MessageObject(0, restricted).isSticker()
        with self.assertRaises(TypeError):
            MessageObject.isSticker(message())


if __name__ == "__main__":
    unittest.main()
