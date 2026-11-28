"""android.graphics bitmaps over a synthetic image host: no Swift, no plugin source."""
from __future__ import annotations

import base64
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
import _ayu_images
import _ayu_javalib
from _ayu_javalib import android_bitmap as bitmaps
from _ayu_javalib import java_io as io
from _ayu_javalib import java_lang as lang

BANDS = {"L": 1, "LA": 2, "RGB": 3, "RGBA": 4}
MAGIC = b"SYNTHETIC-IMAGE\n"


class Host:
    """The few ``image.*`` operations the bitmap classes use, on straight-alpha bytes."""

    def __init__(self):
        self.capabilities = {"operations": list(_ayu_images.OPERATIONS)}
        self.scope = types.SimpleNamespace(state="active", generation=1)
        self.images = {}
        self.calls = []
        self.next = 0

    def require(self, scope=None):
        return self.scope

    def store(self, mode, width, height, data):
        self.next += 1
        ident = f"image-{self.next}"
        self.images[ident] = (mode, width, height, bytearray(data))
        return {"image": ident, "mode": mode, "width": width, "height": height}

    def parse(self, data):
        if not data.startswith(MAGIC):
            raise bridge.BridgeError("IMAGE_FORMAT", "Cannot identify the image")
        name, mode, width, height = data[len(MAGIC):].split(b"\n", 1)[0].decode().split()
        return name, mode, int(width), int(height), data[len(MAGIC):].split(b"\n", 1)[1]

    def call(self, operation, arguments):
        self.calls.append((operation, arguments))
        if operation == "image.release":
            for ident in arguments.get("images", ()):
                self.images.pop(ident, None)
            return None
        if operation == "image.create":
            return self.store(arguments["mode"], arguments["width"], arguments["height"],
                              bytes(arguments["color"]) * (arguments["width"] * arguments["height"]))
        if operation == "image.decode":
            if "data" in arguments:
                data = base64.b64decode(arguments["data"])
            else:
                with open(arguments["path"], "rb") as stream:
                    data = stream.read()
            name, mode, width, height, pixels = self.parse(data)
            extra = {"format": name, "orientation": 1, "frames": 1}
            if arguments.get("bounds"):
                return {"mode": mode, "width": width, "height": height, **extra}
            return {**self.store(mode, width, height, pixels), **extra}
        mode, width, height, data = self.images[arguments["image"]]
        bands = BANDS[mode]
        if operation == "image.encode":
            if arguments["format"] == "JPEG" and mode == "RGBA":
                raise bridge.BridgeError("INVALID_ARGUMENTS", "JPEG cannot store alpha")
            encoded = MAGIC + f"{arguments['format']} {mode} {width} {height}\n".encode() + bytes(data)
            with open(arguments["path"], "wb") as stream:
                stream.write(encoded)
            return {"bytes": len(encoded)}
        if operation == "image.copy":
            return self.store(mode, width, height, data)
        if operation == "image.convert":
            target = arguments["mode"]
            out = bytearray()
            for index in range(0, len(data), bands):
                out += data[index:index + 3] + (b"\xff" if bands == 3 else data[index + 3:index + 4])[:BANDS[target] - 3]
            return self.store(target, width, height, out)
        if operation == "image.alpha_composite":
            _, _, _, top = self.images[arguments["source"]]
            out = bytearray()
            for index in range(0, len(data), 4):
                alpha = top[index + 3]
                # Exact only over an opaque backdrop, which is all the bitmap classes ask for.
                out += bytes((top[index + band] * alpha + data[index + band] * (255 - alpha) + 127) // 255 for band in range(3)) + b"\xff"
            return self.store("RGBA", width, height, out)
        if operation in ("image.crop", "image.pixels.get", "image.pixels.put"):
            left, top, right, bottom = arguments["box"]
            rows = [(((top + row) * width + left) * bands, ((top + row) * width + right) * bands) for row in range(bottom - top)]
            if operation == "image.pixels.put":
                new, span = base64.b64decode(arguments["data"]), (right - left) * bands
                for row, (start, end) in enumerate(rows):
                    data[start:end] = new[row * span:(row + 1) * span]
                return None
            part = b"".join(bytes(data[start:end]) for start, end in rows)
            if operation == "image.pixels.get":
                return {"data": base64.b64encode(part).decode()}
            return self.store(mode, right - left, bottom - top, part)
        if operation == "image.resize":
            new_width, new_height = arguments["width"], arguments["height"]
            out = bytearray()
            for y in range(new_height):
                for x in range(new_width):
                    start = ((y * height // new_height) * width + x * width // new_width) * bands
                    out += data[start:start + bands]
            return self.store(mode, new_width, new_height, out)
        if operation == "image.draw":
            for command in arguments["commands"]:
                if command["op"] == "fill" and "fill" in command:
                    data[:] = bytes(command["fill"]) * (width * height)
            return None
        raise bridge.UnsupportedAPI(operation)


class BitmapTests(unittest.TestCase):
    def setUp(self):
        self.host = Host()
        self.home = tempfile.TemporaryDirectory()
        for patch in (mock.patch.object(_ayu_images, "_runtime", lambda: self.host),
                      mock.patch.dict(os.environ, {"HOME": self.home.name})):
            patch.start()
            self.addCleanup(patch.stop)
        self.addCleanup(self.home.cleanup)
        self.addCleanup(_ayu_images._pending.clear)

    def encoded(self, name, mode, width, height, pixels):
        return MAGIC + f"{name} {mode} {width} {height}\n".encode() + bytes(pixels)

    def test_classes_are_local_and_gated_on_the_image_operations(self):
        for name in ("android.graphics.Bitmap", "android.graphics.BitmapFactory", "android.graphics.BitmapFactory$Options",
                     "android.graphics.Canvas", "android.graphics.drawable.BitmapDrawable"):
            cls = _ayu_javalib.local_class(name)
            self.assertIs(cls, bitmaps.CLASSES[name])
            self.assertLessEqual(set(_ayu_javalib.requirements(cls)), set(_ayu_images.OPERATIONS))
            self.assertIn("image.decode", _ayu_javalib.requirements(cls))
        self.assertIs(bitmaps.Bitmap.Config.ARGB_8888, _ayu_javalib.local_class("android.graphics.Bitmap$Config").ARGB_8888)
        with self.assertRaises(bridge.UnsupportedAPI):
            bitmaps.Bitmap()

    def test_create_and_pixels_follow_android(self):
        Bitmap = bitmaps.Bitmap
        bitmap = Bitmap.createBitmap(3, 2, Bitmap.Config.ARGB_8888)
        self.assertEqual((bitmap.getWidth(), bitmap.getHeight(), bitmap.getConfig(), bitmap.hasAlpha(), bitmap.isMutable(),
                          bitmap.getRowBytes(), bitmap.getByteCount(), bitmap.getPixel(2, 1)),
                         (3, 2, Bitmap.Config.ARGB_8888, True, True, 12, 24, 0))
        bitmap.setPixel(1, 0, lang.i32(0xFF102030))
        self.assertEqual(bitmap.getPixel(1, 0), lang.i32(0xFF102030))
        # Premultiplied storage: 0x80 * (0x10, 0x20, 0x30) is kept as (8, 16, 24) and read back from that.
        bitmap.setPixel(0, 0, lang.i32(0x80102030))
        self.assertEqual(bitmap.getPixel(0, 0), lang.i32(0x80102030))
        bitmap.setPixel(0, 1, 0x01FFFFFF)
        self.assertEqual(bitmap.getPixel(0, 1), 0x01FFFFFF)
        bitmap.setPixel(2, 0, 0x02030405)
        self.assertEqual(bitmap.getPixel(2, 0), 0x02000000)
        bitmap.setPixel(2, 1, 0x00FFFFFF)
        self.assertEqual(bitmap.getPixel(2, 1), 0)
        pixels = [7] * 8
        bitmap.getPixels(pixels, 1, 3, 0, 0, 3, 2)
        self.assertEqual(pixels, [7, lang.i32(0x80102030), lang.i32(0xFF102030), 0x02000000, 0x01FFFFFF, 0, 0, 7])
        with self.assertRaises(lang.IllegalArgumentException):
            bitmap.getPixel(3, 0)
        with self.assertRaises(lang.IllegalArgumentException):
            Bitmap.createBitmap(0, 1, Bitmap.Config.ARGB_8888)
        opaque = Bitmap.createBitmap(1, 1, Bitmap.Config.RGB_565)
        self.assertEqual((opaque.hasAlpha(), opaque.getPixel(0, 0), opaque.getConfig()), (False, lang.i32(0xFF000000), Bitmap.Config.RGB_565))
        with self.assertRaises(bridge.UnsupportedAPI):
            Bitmap.createBitmap(1, 1, Bitmap.Config.HARDWARE)

    def test_scaled_copy_and_recycle(self):
        Bitmap = bitmaps.Bitmap
        source = Bitmap.createBitmap([lang.i32(0xFFFF0000), lang.i32(0xFF00FF00)], 2, 1, Bitmap.Config.ARGB_8888)
        self.assertFalse(source.isMutable())
        with self.assertRaises(lang.IllegalStateException):
            source.setPixel(0, 0, 0)
        scaled = Bitmap.createScaledBitmap(source, 4, 2, False)
        self.assertEqual((scaled.getWidth(), scaled.getHeight(), scaled.getPixel(1, 1), scaled.getPixel(2, 0)),
                         (4, 2, lang.i32(0xFFFF0000), lang.i32(0xFF00FF00)))
        self.assertEqual(self.host.calls[-3][1]["filter"], "nearest")
        Bitmap.createScaledBitmap(source, 1, 1, True)
        self.assertEqual(self.host.calls[-1][1]["filter"], "bilinear")
        part = Bitmap.createBitmap(source, 1, 0, 1, 1)
        self.assertEqual((part.getWidth(), part.getPixel(0, 0)), (1, lang.i32(0xFF00FF00)))
        with self.assertRaises(lang.IllegalArgumentException):
            Bitmap.createBitmap(source, 1, 0, 2, 1)
        copy = source.copy(Bitmap.Config.ARGB_8888, True)
        copy.eraseColor(lang.i32(0xFF0000FF))
        self.assertEqual((copy.getPixel(1, 0), source.getPixel(1, 0)), (lang.i32(0xFF0000FF), lang.i32(0xFF00FF00)))
        identifier = source._handle.id
        source.recycle()
        self.assertTrue(source.isRecycled())
        with self.assertRaises(lang.IllegalStateException):
            source.getPixel(0, 0)
        copy.getPixel(0, 0)  # the next call carries the queued release
        self.assertNotIn(identifier, self.host.images)

    def test_compress_writes_png_and_jpeg_over_black(self):
        Bitmap = bitmaps.Bitmap
        bitmap = Bitmap.createBitmap([lang.i32(0x80FF0000), 0x00FFFFFF, lang.i32(0xFF010203)], 3, 1, Bitmap.Config.ARGB_8888)
        stream = io.ByteArrayOutputStream()
        self.assertIs(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream), True)
        name, mode, width, height, pixels = self.host.parse(bytes(stream.toByteArray()))
        self.assertEqual((name, mode, width, height, pixels), ("PNG", "RGBA", 3, 1, bytes([255, 0, 0, 128, 255, 255, 255, 0, 1, 2, 3, 255])))
        self.assertNotIn("quality", [call for call in self.host.calls if call[0] == "image.encode"][-1][1])
        live = len(self.host.images)
        stream = io.ByteArrayOutputStream()
        self.assertIs(bitmap.compress(Bitmap.CompressFormat.JPEG, 80, stream), True)
        name, mode, width, height, pixels = self.host.parse(bytes(stream.toByteArray()))
        self.assertEqual((name, mode, pixels), ("JPEG", "RGB", bytes([128, 0, 0, 0, 0, 0, 1, 2, 3])))
        self.assertEqual([call for call in self.host.calls if call[0] == "image.encode"][-1][1]["quality"], 80)
        bitmap.getWidth()
        bitmap.getPixel(0, 0)
        self.assertEqual(len(self.host.images), live)
        for refused in (Bitmap.CompressFormat.WEBP, Bitmap.CompressFormat.WEBP_LOSSY, Bitmap.CompressFormat.WEBP_LOSSLESS):
            with self.assertRaises(bridge.UnsupportedAPI):
                bitmap.compress(refused, 80, io.ByteArrayOutputStream())
        with self.assertRaises(lang.IllegalArgumentException):
            bitmap.compress(Bitmap.CompressFormat.PNG, 101, io.ByteArrayOutputStream())
        with self.assertRaises(lang.NullPointerException):
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, None)

    def test_factory_decodes_bytes_files_and_streams(self):
        Factory = bitmaps.BitmapFactory
        data = self.encoded("PNG", "RGBA", 2, 2, [1, 2, 3, 255] * 4)
        bitmap = Factory.decodeByteArray(data, 0, len(data))
        self.assertEqual((bitmap.getWidth(), bitmap.getHeight(), bitmap.getPixel(1, 1), bitmap.isMutable(), bitmap.getConfig()),
                         (2, 2, lang.i32(0xFF010203), False, bitmaps.Bitmap.Config.ARGB_8888))
        self.assertIsNone(Factory.decodeByteArray(b"not an image", 0, 12))
        with self.assertRaises(lang.ArrayIndexOutOfBoundsException):
            Factory.decodeByteArray(data, 1, len(data))
        path = os.path.join(self.home.name, "picture.jpg")
        with open(path, "wb") as stream:
            stream.write(self.encoded("JPEG", "RGB", 4, 2, [9, 8, 7] * 8))
        options = Factory.Options()
        options.inJustDecodeBounds = True
        before = len(self.host.images)
        self.assertIsNone(Factory.decodeFile(path, options))
        self.assertEqual((options.outWidth, options.outHeight, options.outMimeType, len(self.host.images)), (4, 2, "image/jpeg", before))
        options = Factory.Options()
        options.inSampleSize = 3
        options.inMutable = True
        sampled = Factory.decodeFile(path, options)
        self.assertEqual((sampled.getWidth(), sampled.getHeight(), sampled.hasAlpha(), sampled.isMutable(), sampled.getPixel(0, 0)),
                         (2, 1, False, True, lang.i32(0xFF090807)))
        self.assertIsNone(Factory.decodeFile(os.path.join(self.home.name, "absent.png")))
        self.assertIsNone(Factory.decodeStream(None))
        streamed = Factory.decodeStream(io.ByteArrayInputStream(data))
        self.assertEqual((streamed.getWidth(), streamed.getPixel(0, 0)), (2, lang.i32(0xFF010203)))
        gray = Factory.decodeByteArray(self.encoded("PNG", "RGB", 1, 1, [5, 5, 5]), 0, len(self.encoded("PNG", "RGB", 1, 1, [5, 5, 5])))
        self.assertEqual(gray.getPixel(0, 0), lang.i32(0xFF050505))

    def test_a_view_receives_the_image_handle(self):
        bitmap = bitmaps.Bitmap.createBitmap(1, 1, bitmaps.Bitmap.Config.ARGB_8888)
        self.assertEqual(bitmap.to_bridge(), {"image": bitmap._handle.id})
        drawable = bitmaps.BitmapDrawable(None, bitmap)
        self.assertEqual((drawable.getBitmap() is bitmap, drawable.getIntrinsicWidth(), drawable.to_bridge()), (True, 1, {"image": bitmap._handle.id}))
        drawable.setAlpha(10)
        with self.assertRaises(bridge.UnsupportedAPI):
            drawable.to_bridge()
        bitmap.recycle()
        with self.assertRaises(lang.IllegalStateException):
            bitmap.to_bridge()


if __name__ == "__main__":
    unittest.main()
