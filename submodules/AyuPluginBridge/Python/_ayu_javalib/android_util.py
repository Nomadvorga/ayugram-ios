"""``android.util`` containers and codecs implemented in Python.

``Log`` lives in ``android_compose`` because it is composed over the host's log
operation. ``DisplayMetrics`` is the plain value holder Android constructs (all
fields zero); the real screen metrics come from a host ``Resources``/``Display``.
"""
from __future__ import annotations

import base64 as _base64
import bisect

from . import java_lang as _l
from .java_lang import IllegalArgumentException, NullPointerException, Object, jstr


class Base64(Object):
    DEFAULT, NO_PADDING, NO_WRAP, CRLF, URL_SAFE, NO_CLOSE = 0, 1, 2, 4, 8, 16

    def __init__(self):
        raise _l.unsupported("android.util.Base64 cannot be constructed")

    @staticmethod
    def _input(args):
        if len(args) == 2:
            data, flags = args
            return (data.encode("ascii", "replace") if isinstance(data, str) else _l.to_bytes(data)), flags
        if len(args) == 4:
            data, offset, length, flags = args
            data = _l.to_bytes(data)
            _l.check_range(offset, length, len(data))
            return data[offset:offset + length], flags
        raise TypeError("takes (input, flags) or (input, offset, length, flags)")

    @staticmethod
    def encode(*args):
        data, flags = Base64._input(args)
        encoded = _base64.urlsafe_b64encode(data) if flags & Base64.URL_SAFE else _base64.b64encode(data)
        if flags & Base64.NO_PADDING:
            encoded = encoded.rstrip(b"=")
        if not flags & Base64.NO_WRAP and encoded:
            newline = b"\r\n" if flags & Base64.CRLF else b"\n"
            encoded = b"".join(encoded[index:index + 76] + newline for index in range(0, len(encoded), 76))
        return _l.ByteArray(encoded)

    @staticmethod
    def encodeToString(*args):
        return bytes(Base64.encode(*args)).decode("ascii")

    @staticmethod
    def decode(*args):
        data, flags = Base64._input(args)
        alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" + (
            b"-_" if flags & Base64.URL_SAFE else b"+/")
        body, padding = bytearray(), 0
        for item in data:
            if item in b" \t\r\n":
                continue
            if item == 61:
                padding += 1
            elif item not in alphabet or padding:
                raise IllegalArgumentException("bad base-64")
            else:
                body.append(item)
        remainder = len(body) % 4
        if remainder == 1 or padding > 2 or padding and padding != (4 - remainder) % 4:
            raise IllegalArgumentException("bad base-64")
        body += b"=" * (-len(body) % 4)
        return _l.ByteArray(_base64.b64decode(bytes(body), altchars=b"-_" if flags & Base64.URL_SAFE else None))


class Pair(Object):
    def __init__(self, first, second):
        self.first, self.second = first, second

    @staticmethod
    def create(first, second):
        return Pair(first, second)

    def __eq__(self, other):
        return isinstance(other, Pair) and _l.java_equals(self.first, other.first) and \
            _l.java_equals(self.second, other.second)

    def __hash__(self):
        return self.hashCode()

    def hashCode(self):
        return _l.java_hash(self.first) ^ _l.java_hash(self.second)

    def __iter__(self):
        return iter((self.first, self.second))

    def toString(self):
        return "Pair{" + jstr(self.first) + " " + jstr(self.second) + "}"

    def to_bridge(self):
        return [self.first, self.second]


class _Size(Object):
    def __init__(self, width, height):
        self._width, self._height = self._n(width), self._n(height)

    def getWidth(self):
        return self._width

    def getHeight(self):
        return self._height

    def __eq__(self, other):
        return type(other) is type(self) and (self._width, self._height) == (other._width, other._height)

    def __hash__(self):
        return hash((self._width, self._height))

    def toString(self):
        return jstr(self._width) + "x" + jstr(self._height)

    def to_bridge(self):
        return {"width": self._width, "height": self._height}

    @classmethod
    def parseSize(cls, text):
        if text is None:
            raise NullPointerException("string must not be null")
        left, separator, right = text.partition("*") if "*" in text else text.partition("x")
        if not separator:
            raise _l.NumberFormatException(f'Invalid Size: "{text}"')
        try:
            return cls(cls._parse(left), cls._parse(right))
        except _l.NumberFormatException:
            raise _l.NumberFormatException(f'Invalid Size: "{text}"') from None


class Size(_Size):
    _parse = staticmethod(_l.Integer.parseInt)

    @staticmethod
    def _n(value):
        if not _l.is_int(value):
            raise TypeError("Size takes ints")
        return _l.i32(value)

    def hashCode(self):
        return _l.i32(self._height ^ ((self._width << 16) | ((self._width & 0xFFFFFFFF) >> 16)))


class SizeF(_Size):
    _parse = staticmethod(_l.Float.parseFloat)
    _n = staticmethod(_l.to_float32)

    def toString(self):
        return _l.float_to_string(self._width) + "x" + _l.float_to_string(self._height)

    def hashCode(self):
        return _l.Float.floatToIntBits(self._width) ^ _l.Float.floatToIntBits(self._height)


class _Sparse(Object):
    """Integer-keyed map kept in ascending key order, as Android's sparse arrays are."""
    _DEFAULT = None
    _BITS = 32

    def __init__(self, capacity=10):
        self._keys, self._values = [], []

    def _key(self, key):
        if not _l.is_int(key) or not -(1 << (self._BITS - 1)) <= key < 1 << (self._BITS - 1):
            raise TypeError(f"{type(self).__name__} keys are {self._BITS}-bit integers")
        return key

    def _find(self, key):
        index = bisect.bisect_left(self._keys, self._key(key))
        return index if index < len(self._keys) and self._keys[index] == key else ~index

    def get(self, key, default=None):
        index = self._find(key)
        if index >= 0:
            return self._values[index]
        return self._DEFAULT if default is None else default

    def put(self, key, value):
        index = self._find(key)
        if index >= 0:
            self._values[index] = value
        else:
            self._keys.insert(~index, key)
            self._values.insert(~index, value)

    def append(self, key, value):
        self.put(key, value)

    def delete(self, key):
        index = self._find(key)
        if index >= 0:
            del self._keys[index], self._values[index]

    def remove(self, key):
        self.delete(key)

    def removeAt(self, index):
        self._at(index)
        del self._keys[index], self._values[index]

    def size(self):
        return len(self._keys)

    def _at(self, index):
        if not 0 <= index < len(self._keys):
            raise _l.ArrayIndexOutOfBoundsException(f"length={len(self._keys)}; index={index}")
        return index

    def keyAt(self, index):
        return self._keys[self._at(index)]

    def valueAt(self, index):
        return self._values[self._at(index)]

    def setValueAt(self, index, value):
        self._values[self._at(index)] = value

    def indexOfKey(self, key):
        return self._find(key)

    def indexOfValue(self, value):
        for index, item in enumerate(self._values):
            if item is value or type(item) in (bool, int, float, str) and item == value:
                return index
        return -1

    def contains(self, key):
        return self._find(key) >= 0

    def clear(self):
        del self._keys[:], self._values[:]

    def clone(self):
        copy = type(self)()
        copy._keys, copy._values = list(self._keys), list(self._values)
        return copy

    def __len__(self):
        return len(self._keys)

    def __contains__(self, key):
        return _l.is_int(key) and self._find(key) >= 0

    def __iter__(self):
        return iter(list(self._keys))

    def toString(self):
        return "{" + ", ".join(jstr(key) + "=" + ("(this Map)" if value is self else jstr(value))
                               for key, value in zip(self._keys, self._values)) + "}"

    def to_bridge(self):
        return {str(key): value for key, value in zip(self._keys, self._values)}


class SparseArray(_Sparse):
    pass


class LongSparseArray(_Sparse):
    _BITS = 64


def _typed_sparse(name, kind, default):
    def get(self, key, fallback=default):
        index = self._find(key)
        return self._values[index] if index >= 0 else fallback

    def put(self, key, value):
        if isinstance(value, bool) != (kind is bool) or not isinstance(value, kind):
            raise TypeError(f"{name} values are {kind.__name__}")
        _Sparse.put(self, key, value)

    return _l.JavaMeta(name, (_Sparse,), {"__module__": __name__, "__qualname__": name, "get": get, "put": put,
                                          "append": put})


SparseIntArray = _typed_sparse("SparseIntArray", int, 0)
SparseLongArray = _typed_sparse("SparseLongArray", int, 0)
SparseBooleanArray = _typed_sparse("SparseBooleanArray", bool, False)


class DisplayMetrics(Object):
    DENSITY_LOW, DENSITY_MEDIUM, DENSITY_TV, DENSITY_HIGH = 120, 160, 213, 240
    DENSITY_XHIGH, DENSITY_XXHIGH, DENSITY_XXXHIGH, DENSITY_DEFAULT = 320, 480, 640, 160
    DENSITY_DEFAULT_SCALE = 0.00625

    def __init__(self):
        self.density = self.scaledDensity = self.xdpi = self.ydpi = 0.0
        self.densityDpi = self.widthPixels = self.heightPixels = 0

    def setTo(self, other):
        for name in ("density", "scaledDensity", "xdpi", "ydpi", "densityDpi", "widthPixels", "heightPixels"):
            setattr(self, name, getattr(other, name))

    def setToDefaults(self):
        raise _l.unsupported("The device display density is only known to the host")

    def equals(self, other):
        return isinstance(other, DisplayMetrics) and all(
            getattr(self, name) == getattr(other, name)
            for name in ("density", "scaledDensity", "xdpi", "ydpi", "densityDpi", "widthPixels", "heightPixels"))

    def toString(self):
        return (f"DisplayMetrics{{density={jstr(self.density)}, width={self.widthPixels}, "
                f"height={self.heightPixels}, scaledDensity={jstr(self.scaledDensity)}, "
                f"xdpi={jstr(self.xdpi)}, ydpi={jstr(self.ydpi)}}}")


class TypedValue(Object):
    TYPE_NULL, TYPE_REFERENCE, TYPE_ATTRIBUTE, TYPE_STRING, TYPE_FLOAT, TYPE_DIMENSION, TYPE_FRACTION = 0, 1, 2, 3, 4, 5, 6
    TYPE_FIRST_INT, TYPE_INT_DEC, TYPE_INT_HEX, TYPE_INT_BOOLEAN = 0x10, 0x10, 0x11, 0x12
    TYPE_FIRST_COLOR_INT, TYPE_INT_COLOR_ARGB8, TYPE_INT_COLOR_RGB8 = 0x1C, 0x1C, 0x1D
    TYPE_INT_COLOR_ARGB4, TYPE_INT_COLOR_RGB4, TYPE_LAST_COLOR_INT, TYPE_LAST_INT = 0x1E, 0x1F, 0x1F, 0x1F
    COMPLEX_UNIT_PX, COMPLEX_UNIT_DIP, COMPLEX_UNIT_SP, COMPLEX_UNIT_PT, COMPLEX_UNIT_IN, COMPLEX_UNIT_MM = range(6)
    COMPLEX_UNIT_SHIFT, COMPLEX_UNIT_MASK, COMPLEX_UNIT_FRACTION, COMPLEX_UNIT_FRACTION_PARENT = 0, 0xF, 0, 1
    COMPLEX_RADIX_SHIFT, COMPLEX_RADIX_MASK, COMPLEX_MANTISSA_SHIFT, COMPLEX_MANTISSA_MASK = 4, 0x3, 8, 0xFFFFFF
    COMPLEX_RADIX_23p0, COMPLEX_RADIX_16p7, COMPLEX_RADIX_8p15, COMPLEX_RADIX_0p23 = 0, 1, 2, 3
    DENSITY_DEFAULT, DENSITY_NONE = 0, 0xFFFF
    DATA_NULL_UNDEFINED, DATA_NULL_EMPTY = 0, 1

    def __init__(self):
        self.type = self.data = self.assetCookie = self.resourceId = self.changingConfigurations = self.density = 0
        self.string = None

    @staticmethod
    def applyDimension(unit, value, metrics):
        if unit == TypedValue.COMPLEX_UNIT_PX:
            return _l.to_float32(value)
        if metrics is None:
            raise NullPointerException("metrics is null")
        factor = {1: lambda: metrics.density, 2: lambda: metrics.scaledDensity,
                  3: lambda: metrics.xdpi * (1.0 / 72), 4: lambda: metrics.xdpi,
                  5: lambda: metrics.xdpi * (1.0 / 25.4)}.get(unit)
        return _l.to_float32(value * factor()) if factor else 0.0

    @staticmethod
    def complexToFloat(complex_value):
        mantissa = _l.i32(complex_value & (0xFFFFFF << 8))
        return _l.to_float32(mantissa * (1.0 / (1 << 8), 1.0 / (1 << 15), 1.0 / (1 << 23), 1.0 / (1 << 31))[
            (complex_value >> 4) & 0x3])

    @staticmethod
    def complexToDimension(data, metrics):
        return TypedValue.applyDimension(data & 0xF, TypedValue.complexToFloat(data), metrics)

    def getFloat(self):
        return _l.Float.intBitsToFloat(self.data)

    def getDimension(self, metrics):
        return TypedValue.complexToDimension(self.data, metrics)

    def setTo(self, other):
        for name in ("type", "data", "assetCookie", "resourceId", "changingConfigurations", "density", "string"):
            setattr(self, name, getattr(other, name))


CLASSES = _l.register({
    "android.util.Base64": Base64,
    "android.util.Pair": Pair,
    "android.util.Size": Size,
    "android.util.SizeF": SizeF,
    "android.util.SparseArray": SparseArray,
    "android.util.LongSparseArray": LongSparseArray,
    "android.util.SparseIntArray": SparseIntArray,
    "android.util.SparseLongArray": SparseLongArray,
    "android.util.SparseBooleanArray": SparseBooleanArray,
    "android.util.DisplayMetrics": DisplayMetrics,
    "android.util.TypedValue": TypedValue,
})
