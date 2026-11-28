"""``SendMessagesHelper.generatePhotoSizes`` follows Android's ``generatePhotoSizes``/``scaleAndSaveImage``."""
from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_images
import _ayu_operations
from ayu_bridge import BridgeError, UnsupportedAPI
from _ayu_javalib import telegram_messenger as messenger
from _ayu_javalib import telegram_photo_sizes as sizes

TLRPC = messenger.TLRPC


class _Host:
    """The image service reduced to sizes and modes."""

    def __init__(self, width=0, height=0, mode="RGB", orientation=1, missing=False):
        self.source = (width, height, mode, orientation)
        self.missing, self.images, self.calls, self.encoded = missing, {}, [], []

    def _add(self, mode, width, height):
        name = f"i{len(self.images)}"
        self.images[name] = (mode, width, height)
        return {"image": name, "mode": mode, "width": width, "height": height}

    def call(self, operation, arguments):
        self.calls.append(operation)
        if operation == "image.decode":
            if self.missing:
                raise BridgeError("io_error", "no such file")
            width, height, mode, orientation = self.source
            return dict(self._add(mode, width, height), format="JPEG", orientation=orientation, frames=1)
        if operation == "image.create":
            return self._add(arguments["mode"], arguments["width"], arguments["height"])
        mode, width, height = self.images[arguments["image"]]
        if operation == "image.resize":
            return self._add(mode, arguments["width"], arguments["height"])
        if operation == "image.transpose":
            turned = arguments["method"] in ("rotate_90", "rotate_270")
            return self._add(mode, height if turned else width, width if turned else height)
        if operation == "image.convert":
            return self._add(arguments["mode"], width, height)
        if operation == "image.alpha_composite":
            return self._add("RGBA", width, height)
        if operation == "image.encode":
            assert mode == "RGB" and arguments["format"] == "JPEG"
            self.encoded.append((Path(arguments["path"]).name, width, height, arguments["quality"]))
            Path(arguments["path"]).write_bytes(b"jpeg")
            return {"bytes": 1000 + arguments["quality"]}
        raise AssertionError(operation)


class GeneratePhotoSizesTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = str(Path(directory.name).resolve() / "cache")
        scope = types.SimpleNamespace(state="unloaded", generation=1)
        runtime = types.SimpleNamespace(require=lambda *args: scope)
        for patch in (mock.patch.object(_ayu_images, "_runtime", lambda: runtime),
                      mock.patch.object(sizes, "_last_local_id", -210000)):
            patch.start()
            self.addCleanup(patch.stop)

    def _generate(self, host, path="/in.png"):
        with mock.patch.object(_ayu_images, "call", host.call):
            return sizes.generate(TLRPC, path, self.directory, lambda: 1700000000)

    def test_thumbnail_and_photo_of_a_large_picture(self):
        host = _Host(4000, 2000)
        photo = self._generate(host)
        self.assertIsInstance(photo, TLRPC.TL_photo)
        self.assertEqual((photo.date, photo.file_reference, len(photo.sizes)), (1700000000, b"", 2))
        thumb, big = photo.sizes
        self.assertEqual([(s.type, s.w, s.h, s.size) for s in (thumb, big)], [("s", 90, 45, 1055), ("y", 1280, 640, 1080)])
        self.assertEqual(host.encoded, [("-2147483648_-210000.jpg", 90, 45, 55), ("-2147483648_-210001.jpg", 1280, 640, 80)])
        for size in photo.sizes:
            self.assertIsInstance(size.location, TLRPC.TL_fileLocationToBeDeprecated)
            self.assertEqual((size.location.volume_id, size.location.dc_id, size.location.file_reference),
                             (-2147483648, -2147483648, b""))
            self.assertTrue((Path(self.directory) / f"-2147483648_{size.location.local_id}.jpg").is_file())

    def test_a_small_picture_keeps_its_thumbnail_and_is_scaled_up_to_101(self):
        host = _Host(50, 40)
        photo = self._generate(host)
        self.assertEqual([(s.type, s.w, s.h) for s in photo.sizes], [("s", 50, 40), ("m", 101, 80)])
        self.assertEqual(host.calls.count("image.resize"), 1)

    def test_a_picture_inside_the_photo_size_is_not_resized(self):
        photo = self._generate(_Host(900, 600))
        self.assertEqual([(s.type, s.w, s.h) for s in photo.sizes], [("s", 90, 60), ("y", 900, 600)])

    def test_exif_rotation_and_transparency(self):
        host = _Host(3000, 1000, mode="RGBA", orientation=6)
        photo = self._generate(host)
        self.assertEqual([(s.w, s.h) for s in photo.sizes], [(30, 90), (426, 1280)])
        self.assertEqual(host.calls[:5], ["image.decode", "image.transpose", "image.create", "image.alpha_composite",
                                          "image.convert"])

    def test_null_where_android_returns_null(self):
        self.assertIsNone(self._generate(_Host(missing=True)))
        self.assertIsNone(self._generate(_Host(10, 10), path=None))

    def test_local_ids_never_reuse_an_existing_file(self):
        Path(self.directory).mkdir()
        (Path(self.directory) / "-2147483648_-210000.jpg").write_bytes(b"old")
        photo = self._generate(_Host(10, 10))
        self.assertEqual([s.location.local_id for s in photo.sizes], [-210001, -210002])

    def test_other_host_failures_are_raised(self):
        host = _Host(10, 10)
        host.call = mock.Mock(side_effect=BridgeError("resource_limit", "too large"))
        with self.assertRaises(BridgeError):
            self._generate(host)


class HelperTests(unittest.TestCase):
    def test_member_is_gated_on_its_operations_not_refused(self):
        self.assertNotIn("generatePhotoSizes", _ayu_operations.UNPROVIDED_MEMBERS)
        self.assertEqual(_ayu_operations.METHODS["generatePhotoSizes"], (sizes.OPERATIONS,))
        for name in ("prepareSendingPhoto", "prepareSendingDocument"):
            self.assertIn(name, _ayu_operations.UNPROVIDED_MEMBERS)

    def test_helper_passes_the_cache_directory_and_server_time(self):
        helper = messenger.SendMessagesHelper.__new__(messenger.SendMessagesHelper)
        helper.__dict__["currentAccount"] = 0
        compose = types.SimpleNamespace(_external_cache_dir=lambda: types.SimpleNamespace(getAbsolutePath=lambda: "/cache"))
        with mock.patch.object(messenger, "_compose", lambda: compose), \
                mock.patch.object(sizes, "generate", return_value="photo") as generate:
            self.assertEqual(helper.generatePhotoSizes("/a.jpg", None), "photo")
        self.assertEqual(generate.call_args.args[:3], (TLRPC, "/a.jpg", "/cache"))
        with self.assertRaises(UnsupportedAPI):
            helper.generatePhotoSizes("/a.jpg", object())
        with self.assertRaises(UnsupportedAPI):
            helper.generatePhotoSizes(None, "/a.jpg", None, False)

    def test_generated_photo_is_a_send_parameter(self):
        import client_utils
        photo = TLRPC.TL_photo()
        size = TLRPC.TL_photoSize()
        size.type, size.w, size.h, size.size = "y", 1280, 640, 10
        photo.date, photo.sizes, photo.file_reference = 5, [size], b""
        wire = client_utils._send_wire({"peer": 1, "photo": photo, "path": "/a.jpg", "message": None}, None)
        self.assertEqual(set(wire), {"peer", "photo", "path"})
        self.assertIs(wire["photo"], photo)


if __name__ == "__main__":
    unittest.main()
