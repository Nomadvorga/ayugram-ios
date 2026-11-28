"""``android.media.ExifInterface`` for JPEG files: read the common tags, remove tags, save.

Values are formatted as AOSP's ``getAttribute`` does. Tags are removed in place inside the
existing TIFF block (entries dropped, their value bytes zeroed), so maker notes and the
thumbnail keep their offsets; Android rewrites the whole block instead. Writing a value,
tags outside the table below and Exif inside PNG/WebP/HEIF/raw files are refused.
"""
from __future__ import annotations

import os
import struct

from . import java_lang as _l
from .java_io import FileNotFoundException, IOException
from .java_lang import NullPointerException, Object

_PRIMARY, _EXIF, _GPS = 0, 1, 2
_TAGS = {
    "ImageWidth": (_PRIMARY, 256), "ImageLength": (_PRIMARY, 257), "ImageDescription": (_PRIMARY, 270),
    "Make": (_PRIMARY, 271), "Model": (_PRIMARY, 272), "Orientation": (_PRIMARY, 274),
    "Software": (_PRIMARY, 305), "DateTime": (_PRIMARY, 306), "Artist": (_PRIMARY, 315),
    "Copyright": (_PRIMARY, 33432),
    "DateTimeOriginal": (_EXIF, 36867), "DateTimeDigitized": (_EXIF, 36868), "UserComment": (_EXIF, 37510),
    "GPSLatitudeRef": (_GPS, 1), "GPSLatitude": (_GPS, 2), "GPSLongitudeRef": (_GPS, 3),
    "GPSLongitude": (_GPS, 4), "GPSAltitudeRef": (_GPS, 5), "GPSAltitude": (_GPS, 6),
    "GPSTimeStamp": (_GPS, 7), "GPSDateStamp": (_GPS, 29),
}
_POINTERS = {_EXIF: 34665, _GPS: 34853}
_SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4}
_FORMATS = {3: "H", 4: "I", 8: "h", 9: "i", 11: "f", 12: "d"}
_ASCII_PREFIX = b"ASCII\0\0\0"


def _exif_span(data):
    """(start, end) of the TIFF block of a JPEG's Exif APP1 segment, or None."""
    position = 2
    while position + 4 <= len(data) and data[position] == 0xFF:
        marker = data[position + 1]
        if marker in (0xDA, 0xD9):
            break
        length = struct.unpack_from(">H", data, position + 2)[0]
        if length < 2:
            break
        if marker == 0xE1 and data[position + 4:position + 10] == b"Exif\0\0":
            return position + 10, min(position + 2 + length, len(data))
        position += 2 + length
    return None


def _foreign_exif(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return b"eXIf" in data
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return b"EXIF" in data
    if data[4:8] == b"ftyp":
        return data[8:12] in (b"heic", b"heix", b"hevc", b"mif1", b"msf1", b"avif", b"avis")
    return data[:4] in (b"II*\0", b"MM\0*") or data[:8] == b"FUJIFILM"


class _Tiff:
    def __init__(self, block):
        self.block = bytearray(block)
        self.order = {b"II": "<", b"MM": ">"}.get(bytes(block[:2]))
        if self.order is None or len(block) < 8 or self._u16(2) != 42:
            raise ValueError("not a TIFF block")

    def _u16(self, offset):
        return struct.unpack_from(self.order + "H", self.block, offset)[0]

    def _u32(self, offset):
        return struct.unpack_from(self.order + "I", self.block, offset)[0]

    def entries(self, offset):
        """[(tag, format, count, value offset, value size)] and the next-IFD offset."""
        if not 0 < offset <= len(self.block) - 2:
            return [], 0
        count = self._u16(offset)
        if offset + 2 + count * 12 + 4 > len(self.block):
            return [], 0
        result = []
        for index in range(count):
            entry = offset + 2 + index * 12
            kind, components = self._u16(entry + 2), self._u32(entry + 4)
            size = _SIZES.get(kind, 0) * components
            value = entry + 8 if size <= 4 else self._u32(entry + 8)
            result.append((self._u16(entry), kind, components, value, size))
        return result, self._u32(offset + 2 + count * 12)

    def directories(self):
        """IFD offsets in AOSP's lookup order: {group: [offset, ...]}; primary also lists IFD1."""
        first = self._u32(4)
        primary, following = self.entries(first)
        groups = {_PRIMARY: [first] + ([following] if following else []), _EXIF: [], _GPS: []}
        for tag, kind, _count, value, size in primary:
            for group, pointer in _POINTERS.items():
                if tag == pointer and size == 4 and kind in (4, 13):
                    groups[group].append(self._u32(value))
        return groups

    def find(self, group, tag):
        for offset in self.directories()[group]:
            for entry in self.entries(offset)[0]:
                if entry[0] == tag and 0 < entry[4] and entry[3] + entry[4] <= len(self.block):
                    return entry
        return None

    def value(self, entry):
        """A str, or a list of ints, floats or (numerator, denominator) pairs, as AOSP's getValue."""
        _tag, kind, count, offset, size = entry
        raw = bytes(self.block[offset:offset + size])
        if kind in (1, 6):
            if len(raw) == 1 and raw[0] <= 1:
                return chr(raw[0] + ord("0"))
            return raw.decode("ascii", "replace")
        if kind in (2, 7):
            if raw.startswith(_ASCII_PREFIX):
                raw = raw[len(_ASCII_PREFIX):]
            text = raw.split(b"\0", 1)[0]
            return "".join(chr(byte) if byte >= 32 else "?" for byte in text)
        if kind in (5, 10):
            numbers = struct.unpack(self.order + ("II" if kind == 5 else "ii") * count, raw)
            return list(zip(numbers[::2], numbers[1::2]))
        return list(struct.unpack(self.order + _FORMATS[kind] * count, raw))

    def remove(self, offset, tags):
        entries, following = self.entries(offset)
        kept = [entry for entry in entries if entry[0] not in tags]
        if len(kept) == len(entries):
            return len(kept)
        records = []
        for index, entry in enumerate(entries):
            start = offset + 2 + index * 12
            if entry[0] in tags:
                if entry[4] > 4 and entry[3] + entry[4] <= len(self.block):
                    self.block[entry[3]:entry[3] + entry[4]] = bytes(entry[4])
            else:
                records.append(bytes(self.block[start:start + 12]))
        body = struct.pack(self.order + "H", len(kept)) + b"".join(records) + struct.pack(self.order + "I", following)
        total = 2 + len(entries) * 12 + 4
        self.block[offset:offset + total] = body + bytes(total - len(body))
        return len(kept)


class ExifInterface(Object):
    TAG_IMAGE_WIDTH = "ImageWidth"
    TAG_IMAGE_LENGTH = "ImageLength"
    TAG_IMAGE_DESCRIPTION = "ImageDescription"
    TAG_MAKE = "Make"
    TAG_MODEL = "Model"
    TAG_ORIENTATION = "Orientation"
    TAG_SOFTWARE = "Software"
    TAG_DATETIME = "DateTime"
    TAG_ARTIST = "Artist"
    TAG_COPYRIGHT = "Copyright"
    TAG_DATETIME_ORIGINAL = "DateTimeOriginal"
    TAG_DATETIME_DIGITIZED = "DateTimeDigitized"
    TAG_USER_COMMENT = "UserComment"
    TAG_GPS_LATITUDE_REF = "GPSLatitudeRef"
    TAG_GPS_LATITUDE = "GPSLatitude"
    TAG_GPS_LONGITUDE_REF = "GPSLongitudeRef"
    TAG_GPS_LONGITUDE = "GPSLongitude"
    TAG_GPS_ALTITUDE_REF = "GPSAltitudeRef"
    TAG_GPS_ALTITUDE = "GPSAltitude"
    TAG_GPS_TIMESTAMP = "GPSTimeStamp"
    TAG_GPS_DATESTAMP = "GPSDateStamp"

    ORIENTATION_UNDEFINED = 0
    ORIENTATION_NORMAL = 1
    ORIENTATION_FLIP_HORIZONTAL = 2
    ORIENTATION_ROTATE_180 = 3
    ORIENTATION_FLIP_VERTICAL = 4
    ORIENTATION_TRANSPOSE = 5
    ORIENTATION_ROTATE_90 = 6
    ORIENTATION_TRANSVERSE = 7
    ORIENTATION_ROTATE_270 = 8

    def __init__(self, filename):
        if filename is None:
            raise NullPointerException("filename cannot be null")
        path = filename.getAbsolutePath() if hasattr(filename, "getAbsolutePath") else filename
        if not isinstance(path, str):
            raise _l.unsupported("ExifInterface opens a file path or a File on iOS")
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError as error:
            raise FileNotFoundException(f"{path}: open failed: {os.strerror(error.errno or 2)}") from None
        self._path, self._data, self._removed, self._tiff, self._span = path, data, set(), None, None
        self._jpeg = data[:3] == b"\xff\xd8\xff"
        if self._jpeg:
            self._span = _exif_span(data)
            if self._span is not None:
                try:
                    self._tiff = _Tiff(data[self._span[0]:self._span[1]])
                except (ValueError, struct.error):
                    self._tiff = None
        elif _foreign_exif(data):
            raise _l.unsupported("ExifInterface reads Exif only from JPEG files on iOS")

    def _value(self, tag):
        if tag is None:
            raise NullPointerException("tag shouldn't be null")
        if tag not in _TAGS:
            raise _l.unsupported(f"ExifInterface tag {tag} is not available on iOS")
        if self._tiff is None or tag in self._removed:
            return None
        try:
            entry = self._tiff.find(*_TAGS[tag])
            if entry is None:
                return None
            value = self._tiff.value(entry)
            return value if isinstance(value, str) else value + [entry[1]]
        except (KeyError, struct.error):
            return None

    def getAttribute(self, tag):
        value = self._value(tag)
        if value is None or isinstance(value, str):
            return value
        kind, value = value[-1], value[:-1]
        if tag == "GPSTimeStamp":
            if kind not in (5, 10) or len(value) != 3 or any(denominator == 0 for _n, denominator in value):
                return None
            return "%02d:%02d:%02d" % tuple(int(numerator / denominator) for numerator, denominator in value)
        if kind in (5, 10):
            return ",".join(f"{numerator}/{denominator}" for numerator, denominator in value)
        if kind in (11, 12):
            raise _l.unsupported("ExifInterface floating point values are not formatted on iOS")
        return ",".join(str(item) for item in value)

    def getAttributeInt(self, tag, defaultValue):
        value = self._value(tag)
        if value is None:
            return defaultValue
        if isinstance(value, str):
            text = value[1:] if value[:1] in "+-" else value
            if text.isascii() and text.isdigit() and -2 ** 31 <= int(value) < 2 ** 31:
                return int(value)
            return defaultValue
        if len(value) == 2 and value[-1] in (3, 4, 8, 9):
            item = value[0] & 0xFFFFFFFF
            return item - (1 << 32) if item >= 1 << 31 else item
        return defaultValue

    def setAttribute(self, tag, value):
        if tag is None:
            raise NullPointerException("tag shouldn't be null")
        if tag not in _TAGS:
            raise _l.unsupported(f"ExifInterface tag {tag} is not available on iOS")
        if value is not None:
            raise _l.unsupported("ExifInterface.setAttribute only removes a tag (null value) on iOS")
        self._removed.add(tag)

    def saveAttributes(self):
        if not self._jpeg:
            raise IOException("ExifInterface only supports saving attributes on JPEG, PNG, WebP, and DNG formats.")
        if self._tiff is None or not self._removed:
            return
        tiff = self._tiff
        for group in (_GPS, _EXIF, _PRIMARY):
            tags = {number for name, (owner, number) in _TAGS.items() if owner == group and name in self._removed}
            groups = tiff.directories()
            for offset in groups[group]:
                left = tiff.remove(offset, tags)
                if left == 0 and group != _PRIMARY:
                    tiff.remove(groups[_PRIMARY][0], {_POINTERS[group]})
        start, end = self._span
        if not tiff.entries(tiff.directories()[_PRIMARY][0])[0] and len(tiff.directories()[_PRIMARY]) == 1:
            data = self._data[:start - 10] + self._data[end:]
            self._tiff = self._span = None
        else:
            data = self._data[:start] + bytes(tiff.block) + self._data[end:]
        temporary = self._path + ".exif.tmp"
        try:
            with open(temporary, "wb") as handle:
                handle.write(data)
            os.replace(temporary, self._path)
        except OSError as error:
            raise IOException(f"Failed to save new file: {error}") from None
        self._data = data
        self._removed = set()


CLASSES = _l.register({
    "android.media.ExifInterface": ExifInterface,
})
