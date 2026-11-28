"""``android.media.ExifInterface`` on synthetic JPEG bytes built here."""
from __future__ import annotations

from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_javalib as javalib
from _ayu_javalib import android_exif
from _ayu_javalib.java_io import FileNotFoundException, IOException
from ayu_bridge import UnsupportedAPI

ExifInterface = android_exif.ExifInterface
_SCAN = b"\xff\xda\x00\x02scan-data\xff\xd9"


def _tiff(order, primary, exif=None, gps=None):
    """A TIFF block; each directory is [(tag, format, count, payload bytes)]."""
    def layout(entries, base, pointers=()):
        size = 2 + (len(entries) + len(pointers)) * 12 + 4
        return size, base + size

    def build(entries, base):
        head, tail = struct.pack(order + "H", len(entries)), b""
        data_at = base + 2 + len(entries) * 12 + 4
        for tag, kind, count, payload in entries:
            head += struct.pack(order + "HHI", tag, kind, count)
            if len(payload) <= 4:
                head += payload.ljust(4, b"\0")
            else:
                head += struct.pack(order + "I", data_at + len(tail))
                tail += payload
        return head + struct.pack(order + "I", 0) + tail

    def length(entries):
        return 2 + len(entries) * 12 + 4 + sum(len(p) for _t, _k, _c, p in entries if len(p) > 4)

    primary = list(primary)
    pointer = lambda value: struct.pack(order + "I", value)
    extra = [(34665, exif), (34853, gps)]
    offset = 8 + length(primary) + 12 * sum(1 for _tag, entries in extra if entries)
    blocks = []
    for tag, entries in extra:
        if entries:
            primary.append((tag, 4, 1, pointer(offset)))
            blocks.append((entries, offset))
            offset += length(entries)
    header = (b"II*\0" if order == "<" else b"MM\0*") + struct.pack(order + "I", 8)
    return header + build(primary, 8) + b"".join(build(entries, base) for entries, base in blocks)


def _jpeg(tiff):
    body = b"Exif\0\0" + tiff
    app0 = b"\xff\xe0\x00\x07JFIF\0"
    return b"\xff\xd8" + app0 + b"\xff\xe1" + struct.pack(">H", len(body) + 2) + body + _SCAN


def _sample(order=">"):
    rational = lambda *pairs: b"".join(struct.pack(order + "II", n, d) for n, d in pairs)
    primary = [
        (271, 2, 6, b"Canon\0"), (272, 2, 8, b"EOS 90D\0"), (274, 3, 1, struct.pack(order + "H", 6)),
        (306, 2, 20, b"2026:11:27 10:00:00\0"),
    ]
    exif = [(36867, 2, 20, b"2025:01:02 03:04:05\0"), (37510, 7, 13, b"ASCII\0\0\0hello"), (40962, 4, 1, struct.pack(order + "I", 640))]
    gps = [
        (1, 2, 2, b"N\0"), (2, 5, 3, rational((55, 1), (45, 1), (2101, 100))),
        (7, 5, 3, rational((9, 1), (5, 1), (61, 2))), (29, 2, 11, b"2026:11:27\0"),
    ]
    return _jpeg(_tiff(order, primary, exif, gps))


class ExifInterfaceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def _file(self, data, name="a.jpg"):
        path = Path(self.directory.name) / name
        path.write_bytes(data)
        return str(path)

    def test_registered_with_android_tag_names(self):
        self.assertIs(javalib.local_classes()["android.media.ExifInterface"], ExifInterface)
        self.assertEqual((ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_DATETIME_ORIGINAL,
                          ExifInterface.TAG_USER_COMMENT, ExifInterface.TAG_GPS_DATESTAMP,
                          ExifInterface.ORIENTATION_ROTATE_90),
                         ("GPSLatitude", "DateTimeOriginal", "UserComment", "GPSDateStamp", 6))

    def test_reads_values_as_android_formats_them(self):
        for order in "<>":
            exif = ExifInterface(self._file(_sample(order)))
            self.assertEqual(exif.getAttribute("Make"), "Canon")
            self.assertEqual(exif.getAttribute("Model"), "EOS 90D")
            self.assertEqual(exif.getAttribute("Orientation"), "6")
            self.assertEqual(exif.getAttributeInt("Orientation", 1), 6)
            self.assertEqual(exif.getAttribute("DateTimeOriginal"), "2025:01:02 03:04:05")
            self.assertEqual(exif.getAttribute("UserComment"), "hello")
            self.assertEqual(exif.getAttribute("GPSLatitudeRef"), "N")
            self.assertEqual(exif.getAttribute("GPSLatitude"), "55/1,45/1,2101/100")
            self.assertEqual(exif.getAttribute("GPSTimeStamp"), "09:05:30")
            self.assertEqual(exif.getAttribute("GPSDateStamp"), "2026:11:27")
            self.assertIsNone(exif.getAttribute("Artist"))
            self.assertEqual(exif.getAttributeInt("Make", 9), 9)
            self.assertEqual(exif.getAttributeInt("ImageWidth", -1), -1)

    def test_removed_tags_are_gone_from_the_saved_file(self):
        for order in "<>":
            path = self._file(_sample(order))
            exif = ExifInterface(path)
            for tag in ("Make", "DateTimeOriginal", "UserComment", "GPSLatitude", "GPSLatitudeRef",
                        "GPSTimeStamp", "GPSDateStamp"):
                exif.setAttribute(tag, None)
                self.assertIsNone(exif.getAttribute(tag))
            self.assertIn(b"Canon", Path(path).read_bytes())
            exif.saveAttributes()
            saved = Path(path).read_bytes()
            self.assertEqual(len(saved), len(_sample(order)))
            self.assertTrue(saved.endswith(_SCAN))
            for secret in (b"Canon", b"2025:01:02", b"hello", b"2026:11:27\0"):
                self.assertNotIn(secret, saved)
            again = ExifInterface(path)
            for tag in ("Make", "DateTimeOriginal", "UserComment", "GPSLatitude", "GPSTimeStamp"):
                self.assertIsNone(again.getAttribute(tag))
            self.assertEqual(again.getAttribute("Model"), "EOS 90D")
            self.assertEqual(again.getAttribute("DateTime"), "2026:11:27 10:00:00")
            self.assertEqual(again.getAttributeInt("Orientation", 1), 6)
            tiff = android_exif._Tiff(saved[android_exif._exif_span(saved)[0]:android_exif._exif_span(saved)[1]])
            groups = tiff.directories()
            self.assertEqual(groups[android_exif._GPS], [])
            self.assertEqual([entry[0] for entry in tiff.entries(groups[android_exif._EXIF][0])[0]], [40962])

    def test_removing_every_tag_drops_the_exif_segment(self):
        path = self._file(_jpeg(_tiff("<", [(271, 2, 6, b"Canon\0")])))
        exif = ExifInterface(path)
        exif.setAttribute(ExifInterface.TAG_MAKE, None)
        exif.saveAttributes()
        self.assertEqual(Path(path).read_bytes(), b"\xff\xd8\xff\xe0\x00\x07JFIF\0" + _SCAN)
        self.assertIsNone(ExifInterface(path).getAttribute("Make"))

    def test_files_without_exif_have_no_attributes(self):
        plain = ExifInterface(self._file(b"\xff\xd8" + _SCAN))
        self.assertIsNone(plain.getAttribute("Make"))
        self.assertEqual(plain.getAttributeInt("Orientation", 1), 1)
        plain.saveAttributes()
        archive = ExifInterface(self._file(b"PK\x03\x04 not an image", "a.docx"))
        self.assertIsNone(archive.getAttribute("GPSLatitude"))
        with self.assertRaises(IOException):
            archive.saveAttributes()

    def test_refusals(self):
        with self.assertRaises(FileNotFoundException):
            ExifInterface(str(Path(self.directory.name) / "missing.jpg"))
        with self.assertRaises(TypeError):
            ExifInterface(None)
        with self.assertRaises(UnsupportedAPI):
            ExifInterface(self._file(b"\x89PNG\r\n\x1a\n....eXIf....", "a.png"))
        exif = ExifInterface(self._file(_sample()))
        with self.assertRaises(UnsupportedAPI):
            exif.setAttribute("Make", "Nikon")
        with self.assertRaises(UnsupportedAPI):
            exif.getAttribute("FNumber")


if __name__ == "__main__":
    unittest.main()
