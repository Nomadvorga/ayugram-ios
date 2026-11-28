"""``PIL.ImageFont``: fonts loaded by the host through CoreText.

``truetype(path, size)`` reads a TrueType or OpenType file; the size is the em size in
pixels. ``load_default(size)`` is the system font, not Pillow's embedded Aileron, so its
glyph shapes and metrics differ from Pillow's default font. Text is laid out left to right
on one line without Raqm; glyphs are drawn from their outlines, so color-bitmap glyphs
(emoji) are not drawn.
"""
from __future__ import annotations

import math
import os

import _ayu_images

from . import _host


class FreeTypeFont:
    """A font at one size. The name is Pillow's; the rasterizer is CoreText."""

    def __init__(self, font=None, size=10, index=0, encoding="", layout_engine=None):
        if isinstance(size, bool) or not isinstance(size, (int, float)):
            raise TypeError("size must be a number")
        if size <= 0:
            raise ValueError(f"font size must be greater than 0, not {size}")
        self.path = font
        self.size = size
        self.index = index
        self.encoding = encoding
        arguments = {"size": float(size)}
        temporary = None
        if font is not None:
            if hasattr(font, "read"):
                temporary = _ayu_images.temporary(".font")
                with open(temporary, "wb") as stream:
                    stream.write(font.read())
                arguments["path"] = temporary
            else:
                path = os.fsdecode(os.fspath(font))
                if not os.path.isfile(path):
                    raise OSError("cannot open resource")
                arguments["path"] = os.path.realpath(path)
            arguments["index"] = int(index)
        try:
            from ayu_bridge import BridgeError
            try:
                self._handle = _ayu_images.FontHandle(_ayu_images.call("image.font.load", arguments))
            except BridgeError as error:
                if error.code in ("IO_ERROR", "IMAGE_FORMAT"):
                    raise OSError("cannot open resource" if error.code == "IO_ERROR" else "unknown file format") from None
                translated = _host.translate(error)
                if translated is error:
                    raise
                raise translated from None
        finally:
            if temporary is not None:
                _ayu_images.remove(temporary)
        self._measured = {}

    def _id(self):
        return self._handle.require()

    def _measure(self, text, stroke_width=0):
        if not isinstance(text, str):
            if isinstance(text, (bytes, bytearray)):
                text = bytes(text).decode("latin-1")
            else:
                raise TypeError("expected string")
        key = (text, stroke_width)
        found = self._measured.get(key)
        if found is None:
            if len(self._measured) >= 256:
                self._measured.clear()
            found = self._measured[key] = _host.call("image.font.measure", {"font": self._id(), "text": text, "stroke_width": float(stroke_width)})
        return found

    def getname(self):
        return (self._handle.metrics["family"], self._handle.metrics["style"])

    def getmetrics(self):
        """``(ascent, descent)`` in whole pixels, rounded away from the baseline as FreeType does."""
        metrics = self._handle.metrics
        return (math.ceil(metrics["ascent"] - 1e-6), math.ceil(metrics["descent"] - 1e-6))

    def getlength(self, text, mode="", direction=None, features=None, language=None):
        _plain(direction, features, language)
        return self._measure(text)["advance"]

    def _anchor(self, text, anchor, stroke_width=0):
        """Where the pen starts relative to the anchor point: ``(dx, dy)`` to the baseline origin."""
        if anchor is None:
            anchor = "la"
        if not isinstance(anchor, str) or len(anchor) != 2:
            raise ValueError("anchor must be a 2 character string")
        measured = self._measure(text, stroke_width)
        ascent, descent = self.getmetrics()
        horizontal, vertical = anchor
        if horizontal in ("l", "s"):
            dx = 0.0
        elif horizontal == "m":
            dx = -measured["advance"] / 2.0
        elif horizontal == "r":
            dx = -measured["advance"]
        else:
            raise ValueError(f"bad anchor specified: {anchor}")
        ink = measured["ink"]
        if vertical == "a":
            dy = float(ascent)
        elif vertical == "t":
            dy = -float(math.floor(ink[1]))
        elif vertical == "m":
            dy = (ascent - descent) / 2.0
        elif vertical == "s":
            dy = 0.0
        elif vertical == "b":
            dy = -float(math.ceil(ink[3]))
        elif vertical == "d":
            dy = -float(descent)
        else:
            raise ValueError(f"bad anchor specified: {anchor}")
        return dx, dy

    def getbbox(self, text, mode="", direction=None, features=None, language=None, stroke_width=0, anchor=None):
        """The box of the ink, in pixels relative to the anchor point (default: left, ascender)."""
        _plain(direction, features, language)
        dx, dy = self._anchor(text, anchor, stroke_width)
        ink = self._measure(text, stroke_width)["ink"]
        return (math.floor(ink[0] + dx), math.floor(ink[1] + dy), math.ceil(ink[2] + dx), math.ceil(ink[3] + dy))


def _plain(direction, features, language):
    if direction not in (None, "ltr") or features is not None or language is not None:
        raise _host.unsupported("text direction, OpenType features and language (Raqm layout)")


def truetype(font=None, size=10, index=0, encoding="", layout_engine=None):
    """Load a TrueType or OpenType font file. A file that does not exist raises ``OSError``, as in Pillow."""
    if font is None:
        raise _host.unsupported("truetype() without a font file")
    return FreeTypeFont(font, size, index, encoding, layout_engine)


def load_default(size=None):
    """The system font (Pillow: Aileron Regular) at ``size`` pixels, 10 by default."""
    return FreeTypeFont(None, 10 if size is None else size)
