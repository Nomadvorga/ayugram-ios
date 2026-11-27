"""``PIL.ImageDraw``: rectangles, rounded rectangles, ellipses, lines and text.

Coordinates are Pillow's: a box ``[x0, y0, x1, y1]`` includes the pixels of its right and
bottom edge, and outlines lie inside the box. Shapes are not anti-aliased and replace the
pixels they cover, alpha included (``Draw(image, "RGBA")`` on an ``RGB`` image blends with
the ink's alpha instead). Text edges are anti-aliased.
"""
from __future__ import annotations

import math

from . import Image, ImageFont
from . import _host


def _points(xy):
    values = list(xy)
    if values and isinstance(values[0], (list, tuple)):
        values = [coordinate for point in values for coordinate in point]
    if len(values) % 2 or not all(isinstance(value, (int, float)) for value in values):
        raise ValueError("incorrect coordinate type")
    return values


def _box(xy):
    values = _points(xy)
    if len(values) != 4:
        raise ValueError("coordinate list must contain exactly 2 coordinates")
    x0, y0, x1, y1 = (int(value) for value in values)
    if x1 < x0:
        raise ValueError("x1 must be greater than or equal to x0")
    if y1 < y0:
        raise ValueError("y1 must be greater than or equal to y0")
    return x0, y0, x1, y1


class ImageDraw:
    font = None

    def __init__(self, im, mode=None):
        if not isinstance(im, Image.Image):
            raise TypeError("ImageDraw needs an image")
        im._id()
        self._image = im
        self.im = im
        blend = False
        if mode is None:
            mode = im.mode
        if mode != im.mode:
            if mode == "RGBA" and im.mode == "RGB":
                blend = True
            else:
                raise ValueError("mode mismatch")
        self.mode = mode
        self._blend = blend
        # Pillow's default ink is -1 in the image's mode: white for color images, 0 for gray ones.
        self.ink = {"L": [0], "LA": [0, 255]}.get(im.mode, [255] * len(mode))
        self.fill = False
        self.fontmode = "L"

    def _commands(self, commands):
        commands = [command for command in commands if command is not None]
        if commands:
            for command in commands:
                command["blend"] = "over" if self._blend else "replace"
            _host.call("image.draw", {"image": self._image._id(), "commands": commands})
            self._image._touch()

    def _color(self, color):
        return Image._ink(color, self._image.mode, alpha=self._blend)

    def _getink(self, ink, fill=None):
        """Pillow's rule: with neither given, the outline uses the default ink (or the fill, when ``fill`` is set)."""
        result_ink = result_fill = None
        if ink is None and fill is None:
            if self.fill:
                result_fill = list(self.ink)
            else:
                result_ink = list(self.ink)
        else:
            if ink is not None:
                result_ink = self._color(ink)
            if fill is not None:
                result_fill = self._color(fill)
        return result_ink, result_fill

    def getfont(self):
        if not self.font:
            self.font = ImageFont.load_default()
        return self.font

    def _getfont(self, font_size):
        return ImageFont.load_default(font_size) if font_size is not None else self.getfont()

    # Shapes

    def _shape(self, op, xy, fill, outline, width, **extra):
        x0, y0, x1, y1 = _box(xy)
        ink, fill_ink = self._getink(outline, fill)
        commands = []
        if fill_ink is not None:
            commands.append(dict({"op": op, "box": [x0, y0, x1 + 1, y1 + 1], "fill": fill_ink}, **extra))
        if ink is not None and ink != fill_ink and width != 0:
            if isinstance(width, bool) or not isinstance(width, int) or width < 0:
                raise TypeError("width must be a non-negative integer")
            # The outline is the band between the shape and the same shape `width` pixels inside it.
            commands.append(dict({"op": op, "box": [x0, y0, x1 + 1, y1 + 1], "fill": ink, "ring": width}, **extra))
        self._commands(commands)

    def rectangle(self, xy, fill=None, outline=None, width=1):
        self._shape("rect", xy, fill, outline, width)

    def ellipse(self, xy, fill=None, outline=None, width=1):
        self._shape("ellipse", xy, fill, outline, width)

    def rounded_rectangle(self, xy, radius=0, fill=None, outline=None, width=1, *, corners=None):
        if corners is not None and not all(corners):
            raise _host.unsupported("rounded_rectangle() with square corners")
        values = _points(xy)
        if len(values) != 4:
            raise ValueError("coordinate list must contain exactly 2 coordinates")
        if values[2] < values[0]:
            raise ValueError("x1 must be greater than or equal to x0")
        if values[3] < values[1]:
            raise ValueError("y1 must be greater than or equal to y0")
        diameter = min(values[2] - values[0], values[3] - values[1], radius * 2)
        x0, y0, x1, y1 = (round(value) for value in values)
        if diameter <= 0:
            return self._shape("rect", (x0, y0, x1, y1), fill, outline, width)
        # Pillow's corner is a circle whose box spans `diameter` + 1 pixels.
        self._shape("round_rect", (x0, y0, x1, y1), fill, outline, width, radius=(int(diameter) + 1) / 2.0)

    def line(self, xy, fill=None, width=1, joint=None):
        ink = self._getink(fill)[0]
        points = [int(value) for value in _points(xy)]
        if ink is None or len(points) < 4 or width == 0:
            return
        width = max(1, int(width))
        low = (width - 1) // 2
        commands = []
        for index in range(0, len(points) - 2, 2):
            x0, y0, x1, y1 = points[index:index + 4]
            if y0 == y1:
                # Pillow's rows for a horizontal line of this width, both end pixels included.
                commands.append({"op": "rect", "box": [min(x0, x1), y0 - low, max(x0, x1) + 1, y0 - low + width], "fill": ink})
            elif x0 == x1:
                commands.append({"op": "rect", "box": [x0 - low, min(y0, y1), x0 - low + width, max(y0, y1) + 1], "fill": ink})
            else:
                # A one-pixel line reaches half a pixel past the centers of its end pixels, so both are inked.
                reach = 0.5 / math.hypot(x1 - x0, y1 - y0) if width == 1 else 0.0
                dx, dy = (x1 - x0) * reach, (y1 - y0) * reach
                commands.append({"op": "line", "points": [x0 + 0.5 - dx, y0 + 0.5 - dy, x1 + 0.5 + dx, y1 + 0.5 + dy], "stroke": ink,
                                 "width": width})
        if joint == "curve" and width > 4:
            radius = width / 2.0 - 1
            for index in range(2, len(points) - 2, 2):
                x, y = points[index], points[index + 1]
                commands.append({"op": "ellipse", "box": [x - radius, y - radius, x + radius + 1, y + radius + 1], "fill": ink})
        for start in range(0, len(commands), 128):
            self._commands(commands[start:start + 128])

    # Text

    @staticmethod
    def _multiline(text):
        return "\n" in text if isinstance(text, str) else b"\n" in text

    def _checked(self, direction, features, language, embedded_color=False):
        ImageFont._plain(direction, features, language)
        if embedded_color:
            raise _host.unsupported("embedded color glyphs")

    def textlength(self, text, font=None, direction=None, features=None, language=None, embedded_color=False, *, font_size=None):
        if self._multiline(text):
            raise ValueError("can't measure length of multiline text")
        self._checked(direction, features, language, embedded_color)
        if font is None:
            font = self._getfont(font_size)
        return font.getlength(text)

    def textbbox(self, xy, text, font=None, anchor=None, spacing=4, align="left", direction=None, features=None, language=None,
                 stroke_width=0, embedded_color=False, *, font_size=None):
        if self._multiline(text):
            return self.multiline_textbbox(xy, text, font, anchor, spacing, align, direction, features, language, stroke_width,
                                           embedded_color, font_size=font_size)
        self._checked(direction, features, language, embedded_color)
        if font is None:
            font = self._getfont(font_size)
        box = font.getbbox(text, stroke_width=stroke_width, anchor=anchor)
        return box[0] + xy[0], box[1] + xy[1], box[2] + xy[0], box[3] + xy[1]

    def _spacing(self, font, stroke_width, spacing):
        return self.textbbox((0, 0), "A", font, stroke_width=stroke_width)[3] + stroke_width + spacing

    def _lines(self, xy, text, font, anchor, spacing, align, stroke_width):
        """Anchor point of every line of a multiline text, as Pillow lays it out."""
        if anchor is None:
            anchor = "la"
        elif len(anchor) != 2:
            raise ValueError("anchor must be a 2 character string")
        elif anchor[1] in "tb":
            raise ValueError("anchor not supported for multiline text")
        lines = text.split("\n")
        line_spacing = self._spacing(font, stroke_width, spacing)
        widths = [self.textlength(line, font) for line in lines]
        widest = max(widths)
        top = xy[1]
        if anchor[1] == "m":
            top -= (len(lines) - 1) * line_spacing / 2.0
        elif anchor[1] == "d":
            top -= (len(lines) - 1) * line_spacing
        placed = []
        for line, width in zip(lines, widths):
            left = xy[0]
            difference = widest - width
            if anchor[0] == "m":
                left -= difference / 2.0
            elif anchor[0] == "r":
                left -= difference
            if align == "center":
                left += difference / 2.0
            elif align == "right":
                left += difference
            elif align != "left":
                raise ValueError('align must be "left", "center" or "right"')
            placed.append(((left, top), line))
            top += line_spacing
        return anchor, placed

    def multiline_textbbox(self, xy, text, font=None, anchor=None, spacing=4, align="left", direction=None, features=None,
                           language=None, stroke_width=0, embedded_color=False, *, font_size=None):
        self._checked(direction, features, language, embedded_color)
        if font is None:
            font = self._getfont(font_size)
        anchor, placed = self._lines(xy, text, font, anchor, spacing, align, stroke_width)
        box = None
        for position, line in placed:
            line_box = self.textbbox(position, line, font, anchor, stroke_width=stroke_width)
            box = line_box if box is None else (min(box[0], line_box[0]), min(box[1], line_box[1]),
                                                max(box[2], line_box[2]), max(box[3], line_box[3]))
        return (xy[0], xy[1], xy[0], xy[1]) if box is None else box

    def multiline_text(self, xy, text, fill=None, font=None, anchor=None, spacing=4, align="left", direction=None, features=None,
                       language=None, stroke_width=0, stroke_fill=None, embedded_color=False, *, font_size=None):
        self._checked(direction, features, language, embedded_color)
        if font is None:
            font = self._getfont(font_size)
        anchor, placed = self._lines(xy, text, font, anchor, spacing, align, stroke_width)
        for position, line in placed:
            self.text(position, line, fill, font, anchor, stroke_width=stroke_width, stroke_fill=stroke_fill)

    def text(self, xy, text, fill=None, font=None, anchor=None, spacing=4, align="left", direction=None, features=None,
             language=None, stroke_width=0, stroke_fill=None, embedded_color=False, *, font_size=None):
        if self._multiline(text):
            return self.multiline_text(xy, text, fill, font, anchor, spacing, align, direction, features, language, stroke_width,
                                       stroke_fill, embedded_color, font_size=font_size)
        self._checked(direction, features, language, embedded_color)
        if font is None:
            font = self._getfont(font_size)
        ink = self._getink(fill)[0]
        if ink is None or text == "":
            return None
        dx, dy = font._anchor(text, anchor, stroke_width)
        command = {"op": "text", "text": text, "font": font._id(), "origin": [float(xy[0] + dx), float(xy[1] + dy)], "fill": ink}
        if stroke_width:
            command["stroke_width"] = float(stroke_width)
            command["stroke_ink"] = self._color(stroke_fill) if stroke_fill is not None else ink
        self._commands([command])
        return None


def Draw(im, mode=None):
    return ImageDraw(im, mode)
