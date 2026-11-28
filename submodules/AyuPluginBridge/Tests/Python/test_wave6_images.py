"""``org.telegram.messenger.ImageLocation`` follows Android's ``ImageLocation.java``."""
from __future__ import annotations

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_javalib as javalib
from _ayu_javalib import telegram_images as images
from _ayu_javalib import telegram_messenger as messenger

TLRPC = images.TLRPC
ImageLocation = images.ImageLocation


def _photo():
    photo = TLRPC.TL_photo()
    photo.id, photo.access_hash, photo.dc_id, photo.file_reference = 77, 99, 4, b"ref"
    size = TLRPC.TL_photoSize()
    size.type, size.w, size.h, size.size = "y", 1280, 720, 5000
    return photo, size


class ImageLocationTests(unittest.TestCase):
    def test_registered_under_the_java_name(self):
        self.assertIs(javalib.local_classes()["org.telegram.messenger.ImageLocation"], ImageLocation)
        self.assertEqual((ImageLocation.TYPE_BIG, ImageLocation.TYPE_SMALL, ImageLocation.TYPE_STRIPPED,
                          ImageLocation.TYPE_VIDEO_SMALL, ImageLocation.TYPE_VIDEO_BIG), (0, 1, 2, 3, 4))

    def test_path(self):
        self.assertIsNone(ImageLocation.getForPath(None))
        location = ImageLocation.getForPath("/tmp/a.jpg")
        self.assertEqual((location.path, location.imageType, location.location, location.isEncrypted()),
                         ("/tmp/a.jpg", 0, None, False))
        self.assertEqual(ImageLocation.getForVideoPath("/tmp/a.mp4").imageType, 2)

    def test_document(self):
        document = TLRPC.TL_document()
        document.id, document.size, document.dc_id = 5, 1234, 2
        location = ImageLocation.getForDocument(document)
        self.assertIs(location.document, document)
        self.assertEqual((location.currentSize, location.getSize(), location.location), (1234, 1234, None))
        self.assertIsNone(ImageLocation.getForDocument(None))
        self.assertIs(location._ayu_file_target(), document)

    def test_photo_size_of_a_photo(self):
        photo, size = _photo()
        location = ImageLocation.getForPhoto(size, photo)
        self.assertIsInstance(location.location, TLRPC.TL_fileLocationToBeDeprecated)
        # Android's PhotoSize.TLdeserialize: volume_id = -photo_id, local_id = type.charAt(0).
        self.assertEqual((location.location.volume_id, location.location.local_id), (-77, ord("y")))
        self.assertEqual((location.dc_id, location.photoId, location.access_hash, location.file_reference,
                          location.thumbSize, location.currentSize, location.photoPeerType, location.imageType),
                         (4, 77, 99, b"ref", "y", 5000, ImageLocation.TYPE_SMALL, 0))
        self.assertIs(location.photo, photo)
        self.assertIs(location._ayu_file_target(), size)
        self.assertIsNone(ImageLocation.getForPhoto(None, photo))
        self.assertIsNone(ImageLocation.getForPhoto(size, None))
        self.assertIs(ImageLocation.getForObject(size, photo).photo, photo)

    def test_inline_sizes_carry_only_the_size(self):
        stripped = TLRPC.TL_photoStrippedSize()
        stripped.type, stripped.bytes = "i", b"\x01\x02"
        for location in (ImageLocation.getForPhoto(stripped, None), ImageLocation.getForDocument(stripped, None),
                         ImageLocation.getForObject(stripped, TLRPC.TL_message())):
            self.assertIs(location.photoSize, stripped)
            self.assertIsNone(location.location)
        self.assertIsNone(ImageLocation.getForObject(_photo()[1], TLRPC.TL_message()))
        self.assertIsNone(ImageLocation.getForObject(stripped, object()))

    def test_document_thumb(self):
        document = TLRPC.TL_document()
        document.id, document.access_hash, document.dc_id, document.file_reference = 8, 3, 5, b"d"
        size = TLRPC.TL_photoSize()
        size.type, size.size = "m", 10
        location = ImageLocation.getForDocument(size, document)
        self.assertEqual((location.location.volume_id, location.location.local_id, location.documentId, location.dc_id,
                          location.thumbSize, location.photoId), (-8, 1000 + ord("m"), 8, 5, "m", 0))
        self.assertIsNone(location.document)

    def test_user(self):
        user = TLRPC.TL_user()
        user.id, user.access_hash = 42, 1000
        self.assertIsNone(ImageLocation.getForUser(user, ImageLocation.TYPE_BIG))
        user.photo = TLRPC.TL_userProfilePhoto()
        user.photo.photo_id, user.photo.dc_id, user.photo.stripped_thumb = 900, 2, b"\x01"
        big = ImageLocation.getForUserOrChat(user, ImageLocation.TYPE_BIG)
        small = ImageLocation.getForUser(0, user, ImageLocation.TYPE_SMALL)
        self.assertEqual((big.location.volume_id, big.location.local_id, small.location.local_id),
                         (-900, ord("c"), ord("a")))
        self.assertIsInstance(big.photoPeer, TLRPC.TL_inputPeerUser)
        self.assertEqual((big.photoPeer.user_id, big.photoPeer.access_hash, big.photoPeerType, small.photoPeerType,
                          big.photoId, big.dc_id, big.thumbSize, big.photo), (42, 1000, 0, 1, 900, 2, None, None))
        stripped = ImageLocation.getForUser(user, ImageLocation.TYPE_STRIPPED)
        self.assertIsInstance(stripped.photoSize, TLRPC.TL_photoStrippedSize)
        self.assertEqual((stripped.photoSize.type, stripped.photoSize.bytes), ("s", b"\x01"))
        user.access_hash = 0
        self.assertIsNone(ImageLocation.getForUser(user, ImageLocation.TYPE_BIG))
        with self.assertRaises(Exception):
            big._ayu_file_target()

    def test_chat_and_channel(self):
        chat = TLRPC.TL_chat()
        chat.id = 7
        chat.photo = TLRPC.TL_chatPhoto()
        chat.photo.photo_id = 11
        location = ImageLocation.getForChat(chat, ImageLocation.TYPE_SMALL)
        self.assertIsInstance(location.photoPeer, TLRPC.TL_inputPeerChat)
        self.assertEqual((location.photoPeer.chat_id, location.photoId, location.location.local_id), (7, 11, ord("a")))
        self.assertIsNone(ImageLocation.getForChat(chat, ImageLocation.TYPE_STRIPPED))
        channel = TLRPC.TL_channel()
        channel.id, channel.photo = 8, chat.photo
        self.assertIsNone(ImageLocation.getForChat(channel, ImageLocation.TYPE_BIG))
        channel.access_hash = 55
        location = ImageLocation.getForUserOrChat(channel, ImageLocation.TYPE_BIG)
        self.assertIsInstance(location.photoPeer, TLRPC.TL_inputPeerChannel)
        self.assertEqual((location.photoPeer.channel_id, location.photoPeer.access_hash), (8, 55))
        self.assertIsNone(ImageLocation.getForUserOrChat(None, 0))

    def test_unimplemented_factories_refuse(self):
        for name in ("getForSticker", "getForWebFile", "getKey"):
            with self.assertRaises(Exception) as caught:
                getattr(ImageLocation, name) if name != "getKey" else getattr(ImageLocation.getForPath("/a"), name)
            self.assertIn("UNSUPPORTED_API", str(caught.exception))

    def test_file_loader_unwraps_the_location(self):
        photo, size = _photo()
        loader = messenger.FileLoader.__new__(messenger.FileLoader)
        self.assertIs(loader._target(ImageLocation.getForPhoto(size, photo)), size)
        with self.assertRaises(Exception) as caught:
            loader._target(ImageLocation.getForPath("/tmp/a.jpg"))
        self.assertNotIsInstance(caught.exception, TypeError)


if __name__ == "__main__":
    unittest.main()
