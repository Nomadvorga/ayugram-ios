"""``android.graphics`` value types implemented in Python.

Geometry, colour arithmetic, constants and enums only: nothing here draws. Bitmaps,
canvases, drawables, shaders with pixels and text measurement need the host.
``Matrix`` and ``ColorMatrix`` compute in double precision and store 32-bit floats,
so a result can differ from Skia's in the last float digit.
"""
from __future__ import annotations

import math

from . import java_lang as _l
from .java_lang import Enum, IllegalArgumentException, NullPointerException, Object, RuntimeException

_f = _l.to_float32


def _color(value):
    return _l.i32(value)


def _channel(value):
    return int(value * 255.0 + 0.5) if isinstance(value, float) else value


_NAMES = {
    "black": 0xFF000000, "darkgray": 0xFF444444, "gray": 0xFF888888, "lightgray": 0xFFCCCCCC, "white": 0xFFFFFFFF,
    "red": 0xFFFF0000, "green": 0xFF00FF00, "blue": 0xFF0000FF, "yellow": 0xFFFFFF00, "cyan": 0xFF00FFFF,
    "magenta": 0xFFFF00FF, "aqua": 0xFF00FFFF, "fuchsia": 0xFFFF00FF, "darkgrey": 0xFF444444, "grey": 0xFF888888,
    "lightgrey": 0xFFCCCCCC, "lime": 0xFF00FF00, "maroon": 0xFF800000, "navy": 0xFF000080, "olive": 0xFF808000,
    "purple": 0xFF800080, "silver": 0xFFC0C0C0, "teal": 0xFF008080,
}


def _unit_byte(value):
    if not value > 0:
        return 0
    return 255 if value >= 1 else int(value * 65536) >> 8


class Color(Object):
    """Packed ARGB ``int`` helpers. ``Color`` instances (API 26 colour spaces) are not provided."""
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    BLACK, DKGRAY, GRAY, LTGRAY, WHITE = (_color(_NAMES[name]) for name in (
        "black", "darkgray", "gray", "lightgray", "white"))
    RED, GREEN, BLUE, YELLOW, CYAN, MAGENTA = (_color(_NAMES[name]) for name in (
        "red", "green", "blue", "yellow", "cyan", "magenta"))
    TRANSPARENT = 0

    def __init__(self):
        raise _l.unsupported("android.graphics.Color instances are not supported; use packed int colors")

    @staticmethod
    def alpha(color):
        return (color >> 24) & 0xFF

    @staticmethod
    def red(color):
        return (color >> 16) & 0xFF

    @staticmethod
    def green(color):
        return (color >> 8) & 0xFF

    @staticmethod
    def blue(color):
        return color & 0xFF

    @staticmethod
    def rgb(red, green, blue):
        return _color(0xFF000000 | (_channel(red) << 16) | (_channel(green) << 8) | _channel(blue))

    @staticmethod
    def argb(alpha, red, green, blue):
        return _color((_channel(alpha) << 24) | (_channel(red) << 16) | (_channel(green) << 8) | _channel(blue))

    @staticmethod
    def parseColor(text):
        if text is None:
            raise NullPointerException()
        if text[:1] == "#":
            color = _l.parse_integer(text[1:], 16, 64)
            if len(text) == 7:
                color |= 0xFF000000
            elif len(text) != 9:
                raise IllegalArgumentException("Unknown color")
            return _color(color)
        color = _NAMES.get(text.lower())
        if color is None:
            raise IllegalArgumentException("Unknown color")
        return _color(color)

    @staticmethod
    def luminance(color):
        def linear(channel):
            value = channel / 255.0
            return value / 12.92 if value < 0.04045 else ((value + 0.055) / 1.055) ** 2.4
        return _f(0.2126 * linear(Color.red(color)) + 0.7152 * linear(Color.green(color)) +
                  0.0722 * linear(Color.blue(color)))

    @staticmethod
    def RGBToHSV(red, green, blue, hsv):
        if len(hsv) < 3:
            raise RuntimeException("3 components required for hsv")
        red, green, blue = red & 0xFF, green & 0xFF, blue & 0xFF
        low, high = min(red, green, blue), max(red, green, blue)
        delta = high - low
        value = _f(high / 255.0)
        if delta == 0:
            hue, saturation = 0.0, 0.0
        else:
            saturation = _f(delta / high)
            if red == high:
                hue = (green - blue) / delta
            elif green == high:
                hue = 2 + (blue - red) / delta
            else:
                hue = 4 + (red - green) / delta
            hue *= 60
            if hue < 0:
                hue += 360
            hue = _f(hue)
        hsv[0], hsv[1], hsv[2] = hue, saturation, value

    @staticmethod
    def colorToHSV(color, hsv):
        Color.RGBToHSV(Color.red(color), Color.green(color), Color.blue(color), hsv)

    @staticmethod
    def HSVToColor(*args):
        alpha, hsv = (0xFF, args[0]) if len(args) == 1 else args
        if len(hsv) < 3:
            raise RuntimeException("3 components required for hsv")
        # Skia's fixed-point conversion.
        saturation, value = _unit_byte(hsv[1]), _unit_byte(hsv[2])
        if saturation == 0:
            return Color.argb(alpha & 0xFF, value, value, value)
        hue = 0 if hsv[0] < 0 or hsv[0] >= 360 else int(hsv[0] / 60 * 65536)
        fraction, scale = hue & 0xFFFF, value + 1
        p = ((255 - saturation) * scale) >> 8
        q = ((255 - (saturation * fraction >> 16)) * scale) >> 8
        t = ((255 - (saturation * (65536 - fraction) >> 16)) * scale) >> 8
        red, green, blue = ((value, t, p), (q, value, p), (p, value, t), (p, q, value), (t, p, value),
                            (value, p, q))[min(hue >> 16, 5)]
        return Color.argb(alpha & 0xFF, red, green, blue)



class Point(Object):
    def __init__(self, *args):
        if len(args) == 1 and isinstance(args[0], Point):
            self.x, self.y = args[0].x, args[0].y
        elif len(args) in (0, 2):
            self.x, self.y = args or (0, 0)
        else:
            raise TypeError("Point takes (), (x, y) or (Point)")

    def set(self, x, y):
        self.x, self.y = x, y

    def negate(self):
        self.x, self.y = -self.x, -self.y

    def offset(self, dx, dy):
        self.x, self.y = self.x + dx, self.y + dy

    def equals(self, *args):
        if len(args) == 2:
            return self.x == args[0] and self.y == args[1]
        return self == args[0]

    def __eq__(self, other):
        return type(other) is type(self) and self.x == other.x and self.y == other.y

    def __hash__(self):
        return hash((self.x, self.y))

    def hashCode(self):
        return _l.i32(31 * self.x + self.y)

    def toString(self):
        return f"Point({self.x}, {self.y})"

    def to_bridge(self):
        return {"x": self.x, "y": self.y}


class PointF(Point):
    def __init__(self, *args):
        Point.__init__(self, *args)
        self.x, self.y = _f(self.x), _f(self.y)

    def set(self, *args):
        self.x, self.y = (_f(args[0].x), _f(args[0].y)) if len(args) == 1 else (_f(args[0]), _f(args[1]))

    def offset(self, dx, dy):
        self.x, self.y = _f(self.x + dx), _f(self.y + dy)

    def length(*args):
        x, y = (args[0].x, args[0].y) if len(args) == 1 else args
        return _f(math.hypot(x, y))

    def hashCode(self):
        return _l.i32(31 * _l.Float.floatToIntBits(self.x) + _l.Float.floatToIntBits(self.y))

    def toString(self):
        return f"PointF({_l.float_to_string(self.x)}, {_l.float_to_string(self.y)})"


class _Box(Object):
    """Shared ``Rect``/``RectF`` behaviour; ``_n`` converts a coordinate to the class's number type."""

    def __init__(self, *args):
        if len(args) == 1:
            if args[0] is None:
                args = ()
            elif isinstance(args[0], _Box):
                args = (args[0].left, args[0].top, args[0].right, args[0].bottom)
        if len(args) not in (0, 4):
            raise TypeError("takes (), (left, top, right, bottom) or another rectangle")
        self.left, self.top, self.right, self.bottom = (self._n(item) for item in (args or (0, 0, 0, 0)))

    def _box(self, args):
        if len(args) == 1:
            return args[0].left, args[0].top, args[0].right, args[0].bottom
        if len(args) != 4:
            raise TypeError("Expected a rectangle or (left, top, right, bottom)")
        return args

    def set(self, *args):
        self.left, self.top, self.right, self.bottom = (self._n(item) for item in self._box(args))

    def setEmpty(self):
        self.set(0, 0, 0, 0)

    def isEmpty(self):
        return self.left >= self.right or self.top >= self.bottom

    def width(self):
        return self._n(self.right - self.left)

    def height(self):
        return self._n(self.bottom - self.top)

    def offset(self, dx, dy):
        self.set(self.left + dx, self.top + dy, self.right + dx, self.bottom + dy)

    def offsetTo(self, left, top):
        self.set(left, top, self.right + left - self.left, self.bottom + top - self.top)

    def inset(self, *args):
        if len(args) == 1:
            args = self._box(args)
        left, top, right, bottom = args if len(args) == 4 else (args[0], args[1], args[0], args[1])
        self.set(self.left + left, self.top + top, self.right - right, self.bottom - bottom)

    def contains(self, *args):
        if len(args) == 2:
            x, y = args
            return self.left < self.right and self.top < self.bottom and \
                self.left <= x < self.right and self.top <= y < self.bottom
        left, top, right, bottom = self._box(args)
        return self.left < self.right and self.top < self.bottom and \
            self.left <= left and self.top <= top and self.right >= right and self.bottom >= bottom

    def intersects(*args):
        # Instance ``intersects(left, top, right, bottom)`` and static ``intersects(a, b)``.
        first, (left, top, right, bottom) = args[0], args[0]._box(args[1:])
        return first.left < right and left < first.right and first.top < bottom and top < first.bottom

    def intersect(self, *args):
        left, top, right, bottom = self._box(args)
        if self.left < right and left < self.right and self.top < bottom and top < self.bottom:
            self.set(max(self.left, left), max(self.top, top), min(self.right, right), min(self.bottom, bottom))
            return True
        return False

    def setIntersect(self, first, second):
        if first.left < second.right and second.left < first.right and \
                first.top < second.bottom and second.top < first.bottom:
            self.set(max(first.left, second.left), max(first.top, second.top),
                     min(first.right, second.right), min(first.bottom, second.bottom))
            return True
        return False

    def union(self, *args):
        if len(args) == 2:
            x, y = args
            self.set(min(self.left, x), min(self.top, y), max(self.right, x), max(self.bottom, y))
            return
        left, top, right, bottom = self._box(args)
        if left < right and top < bottom:
            if self.left < self.right and self.top < self.bottom:
                self.set(min(self.left, left), min(self.top, top), max(self.right, right), max(self.bottom, bottom))
            else:
                self.set(left, top, right, bottom)

    def sort(self):
        if self.left > self.right:
            self.left, self.right = self.right, self.left
        if self.top > self.bottom:
            self.top, self.bottom = self.bottom, self.top

    def __eq__(self, other):
        return type(other) is type(self) and (self.left, self.top, self.right, self.bottom) == \
            (other.left, other.top, other.right, other.bottom)

    def __hash__(self):
        return hash((self.left, self.top, self.right, self.bottom))

    def to_bridge(self):
        return {"left": self.left, "top": self.top, "right": self.right, "bottom": self.bottom}


class Rect(_Box):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    @staticmethod
    def _n(value):
        if not _l.is_int(value):
            raise TypeError("Rect coordinates are ints")
        return _l.i32(value)

    def centerX(self):
        return (self.left + self.right) >> 1

    def centerY(self):
        return (self.top + self.bottom) >> 1

    def exactCenterX(self):
        return _f((self.left + self.right) * 0.5)

    def exactCenterY(self):
        return _f((self.top + self.bottom) * 0.5)

    def hashCode(self):
        result = self.left
        for item in (self.top, self.right, self.bottom):
            result = _l.i32(31 * result + item)
        return result

    def toString(self):
        return f"Rect({self.left}, {self.top} - {self.right}, {self.bottom})"

    def toShortString(self):
        return f"[{self.left},{self.top}][{self.right},{self.bottom}]"

    def flattenToString(self):
        return f"{self.left} {self.top} {self.right} {self.bottom}"

    @staticmethod
    def unflattenFromString(text):
        import re
        match = re.fullmatch(r"(-?\d+) (-?\d+) (-?\d+) (-?\d+)", text or "")
        return Rect(*map(int, match.groups())) if match else None


class RectF(_Box):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    @staticmethod
    def _n(value):
        return _f(value)

    def centerX(self):
        return _f((self.left + self.right) * 0.5)

    def centerY(self):
        return _f((self.top + self.bottom) * 0.5)

    def round(self, target):
        target.set(*(_l.truncate(math.floor(item + 0.5)) for item in (self.left, self.top, self.right, self.bottom)))

    def roundOut(self, target):
        target.set(math.floor(self.left), math.floor(self.top), math.ceil(self.right), math.ceil(self.bottom))

    def hashCode(self):
        result = 0
        for item in (self.left, self.top, self.right, self.bottom):
            result = _l.i32(31 * result + (_l.Float.floatToIntBits(item) if item != 0 else 0))
        return result

    def toString(self):
        return "RectF(" + ", ".join(_l.float_to_string(item) for item in (
            self.left, self.top, self.right, self.bottom)) + ")"

    def toShortString(self):
        return "[%s,%s][%s,%s]" % tuple(_l.float_to_string(item) for item in (
            self.left, self.top, self.right, self.bottom))


class Insets(Object):
    def __init__(self, *args):
        raise _l.unsupported("Use Insets.of")

    @staticmethod
    def of(*args):
        if len(args) == 1:
            args = (0, 0, 0, 0) if args[0] is None else (args[0].left, args[0].top, args[0].right, args[0].bottom)
        insets = object.__new__(Insets)
        insets.left, insets.top, insets.right, insets.bottom = args
        return insets

    def _sides(self):
        return self.left, self.top, self.right, self.bottom

    @staticmethod
    def add(first, second):
        return Insets.of(*(a + b for a, b in zip(first._sides(), second._sides())))

    @staticmethod
    def subtract(first, second):
        return Insets.of(*(a - b for a, b in zip(first._sides(), second._sides())))

    @staticmethod
    def max(first, second):
        return Insets.of(*(max(a, b) for a, b in zip(first._sides(), second._sides())))

    @staticmethod
    def min(first, second):
        return Insets.of(*(min(a, b) for a, b in zip(first._sides(), second._sides())))

    def __eq__(self, other):
        return isinstance(other, Insets) and self._sides() == other._sides()

    def __hash__(self):
        return hash(self._sides())

    def toString(self):
        return f"Insets{{left={self.left}, top={self.top}, right={self.right}, bottom={self.bottom}}}"


Insets.NONE = Insets.of(0, 0, 0, 0)


class _ScaleToFit(Enum):
    pass


_l.enum_constants(_ScaleToFit, "FILL", "START", "CENTER", "END")
_IDENTITY = (1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0)


def _multiply(a, b):
    return [sum(a[row * 3 + k] * b[k * 3 + column] for k in range(3)) for row in range(3) for column in range(3)]


class Matrix(Object):
    """3x3 transform. ``setPolyToPoly`` is not provided."""
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    MSCALE_X, MSKEW_X, MTRANS_X, MSKEW_Y, MSCALE_Y, MTRANS_Y, MPERSP_0, MPERSP_1, MPERSP_2 = range(9)
    ScaleToFit = _ScaleToFit

    def __init__(self, source=None):
        self._m = list(source._m) if isinstance(source, Matrix) else list(_IDENTITY)

    def _store(self, values):
        self._m = [_f(item) for item in values]

    def set(self, source):
        self._m = list(_IDENTITY) if source is None else list(source._m)

    def reset(self):
        self._m = list(_IDENTITY)

    def isIdentity(self):
        return tuple(self._m) == _IDENTITY

    def isAffine(self):
        return tuple(self._m[6:]) == (0.0, 0.0, 1.0)

    def rectStaysRect(self):
        m = self._m
        if not self.isAffine():
            return False
        return m[1] == 0 and m[3] == 0 and m[0] != 0 and m[4] != 0 or \
            m[0] == 0 and m[4] == 0 and m[1] != 0 and m[3] != 0

    @staticmethod
    def _translate(dx, dy):
        return [1.0, 0.0, dx, 0.0, 1.0, dy, 0.0, 0.0, 1.0]

    @staticmethod
    def _pivot(values, pivot):
        if not pivot:
            return values
        px, py = pivot
        return _multiply(_multiply(Matrix._translate(px, py), values), Matrix._translate(-px, -py))

    @staticmethod
    def _scale(sx, sy, *pivot):
        return Matrix._pivot([sx, 0.0, 0.0, 0.0, sy, 0.0, 0.0, 0.0, 1.0], pivot)

    @staticmethod
    def _sin_cos(sin, cos, *pivot):
        return Matrix._pivot([cos, -sin, 0.0, sin, cos, 0.0, 0.0, 0.0, 1.0], pivot)

    @staticmethod
    def _rotate(degrees, *pivot):
        radians = math.radians(degrees)
        sin, cos = math.sin(radians), math.cos(radians)
        # Skia snaps values within 1/4096 of zero, so right angles stay exact.
        sin, cos = (0.0 if abs(sin) <= 1 / 4096 else sin), (0.0 if abs(cos) <= 1 / 4096 else cos)
        return Matrix._sin_cos(sin, cos, *pivot)

    @staticmethod
    def _skew(kx, ky, *pivot):
        return Matrix._pivot([1.0, kx, 0.0, ky, 1.0, 0.0, 0.0, 0.0, 1.0], pivot)

    def setConcat(self, first, second):
        self._store(_multiply(first._m, second._m))
        return True

    def preConcat(self, other):
        self._store(_multiply(self._m, other._m))
        return True

    def postConcat(self, other):
        self._store(_multiply(other._m, self._m))
        return True

    def getValues(self, values):
        if len(values) < 9:
            raise _l.ArrayIndexOutOfBoundsException()
        for index, item in enumerate(self._m):
            values[index] = item

    def setValues(self, values):
        if len(values) < 9:
            raise _l.ArrayIndexOutOfBoundsException()
        self._store(values[index] for index in range(9))

    def invert(self, inverse):
        a, b, c, d, e, f, g, h, i = self._m
        determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        if determinant == 0 or not math.isfinite(determinant):
            return False
        values = [(e * i - f * h), (c * h - b * i), (b * f - c * e),
                  (f * g - d * i), (a * i - c * g), (c * d - a * f),
                  (d * h - e * g), (b * g - a * h), (a * e - b * d)]
        if inverse is not None:
            inverse._store(item / determinant for item in values)
        return True

    def _map(self, x, y, translate=True):
        m = self._m
        nx = m[0] * x + m[1] * y + (m[2] if translate else 0.0)
        ny = m[3] * x + m[4] * y + (m[5] if translate else 0.0)
        if not self.isAffine() and translate:
            w = m[6] * x + m[7] * y + m[8]
            if w != 0:
                nx, ny = nx / w, ny / w
        return _f(nx), _f(ny)

    def _map_array(self, args, translate):
        if len(args) == 1:
            target, target_index, source, source_index, count = args[0], 0, args[0], 0, len(args[0]) // 2
        elif len(args) == 2:
            target, source = args
            if len(target) != len(source):
                raise _l.ArrayIndexOutOfBoundsException()
            target_index, source_index, count = 0, 0, len(source) // 2
        elif len(args) == 5:
            target, target_index, source, source_index, count = args
        else:
            raise TypeError("takes (points), (dst, src) or (dst, dstIndex, src, srcIndex, pointCount)")
        if source_index < 0 or target_index < 0 or count < 0 or source_index + 2 * count > len(source) or \
                target_index + 2 * count > len(target):
            raise _l.ArrayIndexOutOfBoundsException()
        mapped = [self._map(source[source_index + 2 * index], source[source_index + 2 * index + 1], translate)
                  for index in range(count)]
        for index, (x, y) in enumerate(mapped):
            target[target_index + 2 * index], target[target_index + 2 * index + 1] = x, y

    def mapPoints(self, *args):
        self._map_array(args, True)

    def mapVectors(self, *args):
        self._map_array(args, False)

    def mapRect(self, *args):
        target, source = (args[0], args[0]) if len(args) == 1 else args
        if target is None or source is None:
            raise NullPointerException()
        corners = [self._map(x, y) for x in (source.left, source.right) for y in (source.top, source.bottom)]
        target.set(min(x for x, _ in corners), min(y for _, y in corners),
                   max(x for x, _ in corners), max(y for _, y in corners))
        return self.rectStaysRect()

    def mapRadius(self, radius):
        first, second = self._map(radius, 0, False), self._map(0, radius, False)
        return _f(math.sqrt(math.hypot(*first) * math.hypot(*second)))

    def setRectToRect(self, source, target, fit):
        if source is None or target is None:
            raise NullPointerException()
        if source.isEmpty():
            self.reset()
            return False
        if target.isEmpty():
            self._store([0.0] * 8 + [1.0])
            return True
        sx, sy = target.width() / source.width(), target.height() / source.height()
        x_larger = False
        if fit is not _ScaleToFit.FILL:
            x_larger = sx > sy
            sx = sy = min(sx, sy)
        tx, ty = target.left - source.left * sx, target.top - source.top * sy
        if fit in (_ScaleToFit.CENTER, _ScaleToFit.END):
            slack = target.width() - source.width() * sy if x_larger else target.height() - source.height() * sy
            if fit is _ScaleToFit.CENTER:
                slack /= 2
            if x_larger:
                tx += slack
            else:
                ty += slack
        self._store([sx, 0.0, tx, 0.0, sy, ty, 0.0, 0.0, 1.0])
        return True

    def setPolyToPoly(self, *args):
        raise _l.unsupported("Matrix.setPolyToPoly is not supported")

    def __eq__(self, other):
        return isinstance(other, Matrix) and self._m == other._m

    def __hash__(self):
        return 44

    def hashCode(self):
        return 44

    def toShortString(self):
        text = [_l.float_to_string(item) for item in self._m]
        return "[%s, %s, %s][%s, %s, %s][%s, %s, %s]" % tuple(text)

    def toString(self):
        return "Matrix{" + self.toShortString() + "}"


def _transform(name, builder):
    def setter(self, *args):
        self._store(builder(*args))

    def pre(self, *args):
        self._store(_multiply(self._m, builder(*args)))
        return True

    def post(self, *args):
        self._store(_multiply(builder(*args), self._m))
        return True

    setattr(Matrix, "set" + name, setter)
    setattr(Matrix, "pre" + name, pre)
    setattr(Matrix, "post" + name, post)


for _name, _builder in (("Translate", Matrix._translate), ("Scale", Matrix._scale), ("Rotate", Matrix._rotate),
                        ("Skew", Matrix._skew), ("SinCos", Matrix._sin_cos)):
    _transform(_name, _builder)


class ColorMatrix(Object):
    """4x5 colour transform in row-major order."""

    def __init__(self, source=None):
        self._m = [0.0] * 20
        if source is None:
            self.reset()
        else:
            self.set(source)

    def getArray(self):
        return self._m

    def reset(self):
        self._m[:] = [1.0 if index % 6 == 0 else 0.0 for index in range(20)]

    def set(self, source):
        values = source._m if isinstance(source, ColorMatrix) else source
        if len(values) < 20:
            raise _l.ArrayIndexOutOfBoundsException()
        self._m[:] = [_f(values[index]) for index in range(20)]

    def setScale(self, red, green, blue, alpha):
        self._m[:] = [0.0] * 20
        self._m[0], self._m[6], self._m[12], self._m[18] = _f(red), _f(green), _f(blue), _f(alpha)

    def setRotate(self, axis, degrees):
        self.reset()
        radians = math.radians(degrees)
        cos, sin = _f(math.cos(radians)), _f(math.sin(radians))
        m = self._m
        if axis == 0:
            m[6] = m[12] = cos
            m[7], m[11] = sin, -sin
        elif axis == 1:
            m[0] = m[12] = cos
            m[2], m[10] = -sin, sin
        elif axis == 2:
            m[0] = m[6] = cos
            m[1], m[5] = sin, -sin
        else:
            raise RuntimeException()

    def setSaturation(self, saturation):
        self.reset()
        inverse = 1 - saturation
        red, green, blue = 0.213 * inverse, 0.715 * inverse, 0.072 * inverse
        m = self._m
        m[0], m[1], m[2] = _f(red + saturation), _f(green), _f(blue)
        m[5], m[6], m[7] = _f(red), _f(green + saturation), _f(blue)
        m[10], m[11], m[12] = _f(red), _f(green), _f(blue + saturation)

    def setConcat(self, first, second):
        a, b, result = first._m, second._m, []
        for row in range(0, 20, 5):
            for column in range(4):
                result.append(sum(a[row + k] * b[column + 5 * k] for k in range(4)))
            result.append(sum(a[row + k] * b[4 + 5 * k] for k in range(4)) + a[row + 4])
        self._m[:] = [_f(item) for item in result]

    def preConcat(self, other):
        self.setConcat(self, other)

    def postConcat(self, other):
        self.setConcat(other, self)

    def setRGB2YUV(self):
        self.reset()
        m = self._m
        m[0], m[1], m[2] = _f(0.299), _f(0.587), _f(0.114)
        m[5], m[6], m[7] = _f(-0.16874), _f(-0.33126), _f(0.5)
        m[10], m[11], m[12] = _f(0.5), _f(-0.41869), _f(-0.08131)

    def setYUV2RGB(self):
        self.reset()
        m = self._m
        m[2] = _f(1.402)
        m[5], m[6], m[7] = 1.0, _f(-0.34414), _f(-0.71414)
        m[10], m[11], m[12] = 1.0, _f(1.772), 0.0

    def __eq__(self, other):
        return isinstance(other, ColorMatrix) and self._m == other._m

    __hash__ = None

    def to_bridge(self):
        return list(self._m)


class PixelFormat(Object):
    UNKNOWN, TRANSLUCENT, TRANSPARENT, OPAQUE = 0, -3, -2, -1
    RGBA_8888, RGBX_8888, RGB_888, RGB_565, RGBA_5551, RGBA_4444, A_8, L_8, LA_88, RGB_332 = 1, 2, 3, 4, 6, 7, 8, 9, 10, 11
    YCbCr_422_SP, YCbCr_420_SP, YCbCr_422_I, RGBA_F16, RGBA_1010102, JPEG = 0x10, 0x11, 0x14, 0x16, 0x2B, 0x100
    _BITS = {1: 32, 2: 32, 3: 24, 4: 16, 6: 16, 7: 16, 8: 8, 9: 8, 10: 16, 11: 8, 0x10: 16, 0x11: 12, 0x14: 16,
             0x16: 64, 0x2B: 32}

    def __init__(self):
        self.bitsPerPixel, self.bytesPerPixel = 0, 0

    @staticmethod
    def getPixelFormatInfo(pixel_format, info):
        bits = PixelFormat._BITS.get(pixel_format)
        if bits is None:
            raise IllegalArgumentException(f"unknown pixel format {pixel_format}")
        info.bitsPerPixel, info.bytesPerPixel = bits, (bits + 7) // 8

    @staticmethod
    def formatHasAlpha(pixel_format):
        return pixel_format in (8, 10, 7, 6, 1, 0x16, 0x2B, -3, -2)


class ImageFormat(Object):
    UNKNOWN, RGB_565, NV16, NV21, YUY2, RAW_SENSOR, PRIVATE, YUV_420_888 = 0, 4, 0x10, 0x11, 0x14, 0x20, 0x22, 0x23
    RAW_PRIVATE, RAW10, RAW12, YUV_422_888, YUV_444_888, FLEX_RGB_888, FLEX_RGBA_8888 = 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A
    JPEG, DEPTH_POINT_CLOUD, Y8, YV12, DEPTH16, HEIC, DEPTH_JPEG = 0x100, 0x101, 0x20203859, 0x32315659, 0x44363159, 0x48454946, 0x69656963
    _BITS = {4: 16, 0x10: 16, 0x11: 12, 0x14: 16, 0x20: 16, 0x23: 12, 0x24: 1, 0x25: 10, 0x26: 12, 0x27: 16, 0x28: 24,
             0x29: 24, 0x2A: 32, 0x20203859: 8, 0x32315659: 12, 0x44363159: 16}

    def __init__(self):
        raise _l.unsupported("android.graphics.ImageFormat cannot be constructed")

    @staticmethod
    def getBitsPerPixel(image_format):
        return ImageFormat._BITS.get(image_format, -1)


def _enum(name, *constants):
    cls = _l.JavaMeta(name.rpartition("$")[2], (Enum,), {"__module__": __name__, "__qualname__": name})
    return _l.enum_constants(cls, *constants)


_Mode = _enum("PorterDuff$Mode", "CLEAR", "SRC", "DST", "SRC_OVER", "DST_OVER", "SRC_IN", "DST_IN", "SRC_OUT",
              "DST_OUT", "SRC_ATOP", "DST_ATOP", "XOR", "DARKEN", "LIGHTEN", "MULTIPLY", "SCREEN", "ADD", "OVERLAY")
_TileMode = _enum("Shader$TileMode", "CLAMP", "REPEAT", "MIRROR", "DECAL")
_ENUMS = {
    "android.graphics.Paint$Style": _enum("Paint$Style", "FILL", "STROKE", "FILL_AND_STROKE"),
    "android.graphics.Paint$Cap": _enum("Paint$Cap", "BUTT", "ROUND", "SQUARE"),
    "android.graphics.Paint$Join": _enum("Paint$Join", "MITER", "ROUND", "BEVEL"),
    "android.graphics.Paint$Align": _enum("Paint$Align", "LEFT", "CENTER", "RIGHT"),
    "android.graphics.Path$Direction": _enum("Path$Direction", "CW", "CCW"),
    "android.graphics.Path$FillType": _enum("Path$FillType", "WINDING", "EVEN_ODD", "INVERSE_WINDING",
                                           "INVERSE_EVEN_ODD"),
    "android.graphics.Path$Op": _enum("Path$Op", "DIFFERENCE", "INTERSECT", "UNION", "XOR", "REVERSE_DIFFERENCE"),
    "android.graphics.Region$Op": _enum("Region$Op", "DIFFERENCE", "INTERSECT", "UNION", "XOR",
                                       "REVERSE_DIFFERENCE", "REPLACE"),
    "android.graphics.Bitmap$Config": _enum("Bitmap$Config", "ALPHA_8", "RGB_565", "ARGB_4444", "ARGB_8888",
                                           "RGBA_F16", "HARDWARE", "RGBA_1010102"),
    "android.graphics.Bitmap$CompressFormat": _enum("Bitmap$CompressFormat", "JPEG", "PNG", "WEBP", "WEBP_LOSSY",
                                                   "WEBP_LOSSLESS"),
    "android.graphics.BlurMaskFilter$Blur": _enum("BlurMaskFilter$Blur", "NORMAL", "SOLID", "OUTER", "INNER"),
    "android.graphics.Canvas$EdgeType": _enum("Canvas$EdgeType", "BW", "AA"),
    "android.graphics.drawable.GradientDrawable$Orientation": _enum(
        "GradientDrawable$Orientation", "TOP_BOTTOM", "TR_BL", "RIGHT_LEFT", "BR_TL", "BOTTOM_TOP", "BL_TR",
        "LEFT_RIGHT", "TL_BR"),
}


class PorterDuff(Object):
    Mode = _l.HostFirst("android.graphics.PorterDuff$Mode", _Mode)

    def __init__(self):
        raise _l.unsupported("android.graphics.PorterDuff cannot be constructed")


class Shader(Object):
    """Base shader state: the local matrix only. Gradient and bitmap shaders need the host."""
    TileMode = _l.HostFirst("android.graphics.Shader$TileMode", _TileMode)

    def __init__(self):
        self._matrix = None

    def setLocalMatrix(self, matrix):
        self._matrix = None if matrix is None or matrix.isIdentity() else Matrix(matrix)

    def getLocalMatrix(self, matrix):
        if self._matrix is None:
            matrix.reset()
            return False
        matrix.set(self._matrix)
        return True


class Typeface(Object):
    """Family, style and weight description. Font files and glyph data need the host."""
    NORMAL, BOLD, ITALIC, BOLD_ITALIC = 0, 1, 2, 3

    def __init__(self, *args):
        raise _l.unsupported("Use Typeface.create or Typeface.defaultFromStyle")

    @staticmethod
    def _make(family, weight, italic):
        typeface = object.__new__(Typeface)
        typeface._family, typeface._weight, typeface._italic = family, weight, bool(italic)
        return typeface

    @staticmethod
    def create(source, *args):
        family = source._family if isinstance(source, Typeface) else source
        base_weight = source._weight if isinstance(source, Typeface) else 400
        if family is not None and not isinstance(family, str):
            raise TypeError("Typeface.create takes a family name or a Python-local Typeface")
        if len(args) == 1:
            style = args[0]
            if style & ~3:
                style = 0
            return Typeface._make(family, 700 if style & 1 else (base_weight if base_weight < 700 else 400),
                                  bool(style & 2))
        if len(args) == 2:
            weight, italic = args
            if not 1 <= weight <= 1000:
                raise IllegalArgumentException("weight is out of range [1, 1000]")
            return Typeface._make(family, weight, italic)
        raise TypeError("Typeface.create takes (family, style) or (typeface, weight, italic)")

    @staticmethod
    def defaultFromStyle(style):
        return (Typeface.DEFAULT, Typeface.DEFAULT_BOLD, Typeface._make(None, 400, True),
                Typeface._make(None, 700, True))[style if 0 <= style <= 3 else 0]

    @staticmethod
    def createFromFile(*args):
        raise _l.unsupported("Loading font files needs the host")

    createFromAsset = createFromFile

    def getStyle(self):
        return (1 if self._weight >= 600 else 0) | (2 if self._italic else 0)

    def getWeight(self):
        return self._weight

    def isBold(self):
        return self._weight >= 600

    def isItalic(self):
        return self._italic

    def getSystemFontFamilyName(self):
        return self._family

    def __eq__(self, other):
        return isinstance(other, Typeface) and (self._family, self._weight, self._italic) == \
            (other._family, other._weight, other._italic)

    def __hash__(self):
        return hash((self._family, self._weight, self._italic))


Typeface.DEFAULT = Typeface._make(None, 400, False)
Typeface.DEFAULT_BOLD = Typeface._make(None, 700, False)
Typeface.SANS_SERIF = Typeface._make("sans-serif", 400, False)
Typeface.SERIF = Typeface._make("serif", 400, False)
Typeface.MONOSPACE = Typeface._make("monospace", 400, False)


# Android constants of classes the host adapts (graphics, views, animation): pure data. A nested enum such
# as ``Paint.Align`` needs no entry: the Python-local ``Outer$Inner`` class is a member of the host's outer class.
HOST_MEMBERS = {
    "android.graphics.Paint": {
        "UNDERLINE_TEXT_FLAG": 0x08, "STRIKE_THRU_TEXT_FLAG": 0x10, "FAKE_BOLD_TEXT_FLAG": 0x20,
        "LINEAR_TEXT_FLAG": 0x40, "SUBPIXEL_TEXT_FLAG": 0x80,
    },
    "android.graphics.drawable.GradientDrawable": {
        "LINE": 2, "RING": 3, "LINEAR_GRADIENT": 0, "RADIAL_GRADIENT": 1, "SWEEP_GRADIENT": 2,
    },
    "android.view.View": {
        "OVER_SCROLL_ALWAYS": 0, "OVER_SCROLL_IF_CONTENT_SCROLLS": 1, "OVER_SCROLL_NEVER": 2,
        "LAYER_TYPE_NONE": 0, "LAYER_TYPE_SOFTWARE": 1, "LAYER_TYPE_HARDWARE": 2,
        "IMPORTANT_FOR_ACCESSIBILITY_AUTO": 0, "IMPORTANT_FOR_ACCESSIBILITY_YES": 1,
        "IMPORTANT_FOR_ACCESSIBILITY_NO": 2, "IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS": 4,
        "SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR": 0x00000010, "SYSTEM_UI_FLAG_LIGHT_STATUS_BAR": 0x00002000,
        "SCROLLBARS_INSIDE_OVERLAY": 0, "SCROLLBARS_INSIDE_INSET": 0x01000000,
        "SCROLLBARS_OUTSIDE_OVERLAY": 0x02000000, "SCROLLBARS_OUTSIDE_INSET": 0x03000000,
        "LAYOUT_DIRECTION_LTR": 0, "LAYOUT_DIRECTION_RTL": 1, "LAYOUT_DIRECTION_INHERIT": 2,
        "LAYOUT_DIRECTION_LOCALE": 3,
        "FOCUS_BACKWARD": 1, "FOCUS_FORWARD": 2, "FOCUS_LEFT": 17, "FOCUS_UP": 33, "FOCUS_RIGHT": 66, "FOCUS_DOWN": 130,
    },
    "android.view.Gravity": {
        "FILL": 119, "FILL_VERTICAL": 112, "FILL_HORIZONTAL": 7, "CLIP_VERTICAL": 128, "CLIP_HORIZONTAL": 8,
    },
    "android.view.MotionEvent": {
        "ACTION_OUTSIDE": 4, "ACTION_POINTER_DOWN": 5, "ACTION_POINTER_UP": 6, "ACTION_MASK": 0xFF,
        "ACTION_POINTER_INDEX_MASK": 0xFF00, "ACTION_POINTER_INDEX_SHIFT": 8,
    },
    "android.view.HapticFeedbackConstants": {
        "VIRTUAL_KEY": 1, "KEYBOARD_TAP": 3, "CONTEXT_CLICK": 6, "KEYBOARD_PRESS": 3, "KEYBOARD_RELEASE": 7,
        "VIRTUAL_KEY_RELEASE": 8, "TEXT_HANDLE_MOVE": 9, "GESTURE_START": 12, "GESTURE_END": 13,
        "CONFIRM": 16, "REJECT": 17, "SEGMENT_TICK": 26, "SEGMENT_FREQUENT_TICK": 27,
        "FLAG_IGNORE_VIEW_SETTING": 0x0001, "FLAG_IGNORE_GLOBAL_SETTING": 0x0002,
    },
    "android.animation.ValueAnimator": {"INFINITE": -1, "RESTART": 1, "REVERSE": 2},
}

CLASSES = _l.register({
    "android.graphics.Color": Color,
    "android.graphics.Point": Point,
    "android.graphics.PointF": PointF,
    "android.graphics.Rect": Rect,
    "android.graphics.RectF": RectF,
    "android.graphics.Insets": Insets,
    "android.graphics.Matrix": Matrix,
    "android.graphics.Matrix$ScaleToFit": _ScaleToFit,
    "android.graphics.ColorMatrix": ColorMatrix,
    "android.graphics.PixelFormat": PixelFormat,
    "android.graphics.ImageFormat": ImageFormat,
    "android.graphics.PorterDuff": PorterDuff,
    "android.graphics.PorterDuff$Mode": _Mode,
    "android.graphics.Shader": Shader,
    "android.graphics.Shader$TileMode": _TileMode,
    "android.graphics.Typeface": Typeface,
    **_ENUMS,
})
