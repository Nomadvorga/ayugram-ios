"""``android.graphics`` bitmaps, their factory, an off-screen ``Canvas`` and ``BitmapDrawable``.

The pixels live in the host image service (``_ayu_images``, *Images* in ``protocol-telegram.md``): a
``Bitmap`` is a handle, and every class here needs the ``image.*`` operations. A bitmap is
``ARGB_8888`` (host mode ``RGBA``) or opaque (host mode ``RGB``: ``RGB_565`` and decoded
images without alpha, kept at eight bits per channel). Colors are Android's ARGB ints with
straight alpha, as ``getPixel`` returns them.

A ``Canvas`` draws into one bitmap. It keeps the matrix and the rectangle clips itself and
sends each draw call with them; the host reads the ``Paint`` (and ``Path``) it is given by
reference. A view never draws through this class: there is no ``onDraw``.
"""
from __future__ import annotations

import math
import os

import _ayu_images

from . import android_graphics as _g
from . import java_lang as _l
from .java_lang import IllegalArgumentException, IllegalStateException, NullPointerException, Object, RuntimeException

_REQUIRES = ("image.create", "image.decode", "image.encode", "image.copy", "image.convert", "image.crop", "image.resize",
             "image.transform", "image.pixels.get", "image.pixels.put", "image.draw", "image.alpha_composite")
_Config = _g.CLASSES["android.graphics.Bitmap$Config"]
_CompressFormat = _g.CLASSES["android.graphics.Bitmap$CompressFormat"]
_MIME = {"JPEG": "image/jpeg", "PNG": "image/png", "GIF": "image/gif", "WEBP": "image/webp", "BMP": "image/bmp"}
_IDENTITY = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def _call(operation, arguments):
    return _ayu_images.call(operation, arguments)


def _new(operation, arguments):
    return _ayu_images.new(operation, arguments)


def _argb(color):
    """``[red, green, blue, alpha]`` of an Android color int."""
    if not _l.is_int(color):
        raise TypeError("Expected a color int")
    color &= 0xFFFFFFFF
    return [(color >> 16) & 255, (color >> 8) & 255, color & 255, color >> 24]


def _stored(value, alpha):
    """A color channel as Android reads it back from premultiplied storage (Skia's rounding both ways)."""
    product = value * alpha + 128
    premultiplied = (product + (product >> 8)) >> 8
    return min(255, (((255 << 25) + alpha) // (2 * alpha) * premultiplied + (1 << 23)) >> 24)


def _mode(config):
    """Host mode for a ``Bitmap.Config``; ``ARGB_4444`` is ``ARGB_8888`` since Android 4.4."""
    name = getattr(config, "name", lambda: None)() if config is not None else None
    if name in ("ARGB_8888", "ARGB_4444"):
        return "RGBA"
    if name == "RGB_565":
        return "RGB"
    raise _l.unsupported("Bitmap.Config " + str(name))


def _box(arguments, what):
    """``(left, top, right, bottom)`` from four numbers or one ``Rect``/``RectF``."""
    if len(arguments) == 1:
        rect = arguments[0]
        if rect is None:
            raise NullPointerException(what + " is null")
        if not isinstance(rect, (_g.Rect, _g.RectF)):
            raise _l.unsupported(what + " needs a Rect or RectF")
        arguments = (rect.left, rect.top, rect.right, rect.bottom)
    if len(arguments) != 4:
        raise TypeError(what + " takes a rectangle")
    return [float(value) for value in arguments]


class Bitmap(Object):
    """Mutable or immutable pixels in the host. Created by the static factories only."""
    __ayu_requires__ = _REQUIRES
    Config = _Config
    CompressFormat = _CompressFormat
    DENSITY_NONE = 0

    def __init__(self, *args):
        raise _l.unsupported("android.graphics.Bitmap has no public constructor")

    @classmethod
    def _wrap(cls, handle, mutable):
        bitmap = object.__new__(cls)
        bitmap._handle = handle
        bitmap._mutable = bool(mutable)
        bitmap._density = 160
        bitmap._width, bitmap._height = handle.width, handle.height
        bitmap._config = _Config.ARGB_8888 if handle.mode == "RGBA" else _Config.RGB_565
        return bitmap

    @classmethod
    def _adopt(cls, handle, mutable):
        """Wrap a host image, widening gray ones: a bitmap is RGB or RGBA."""
        if handle.mode in ("L", "LA"):
            wide = _new("image.convert", {"image": handle.require(), "mode": "RGB" if handle.mode == "L" else "RGBA"})
            handle.release()
            handle = wide
        return cls._wrap(handle, mutable)

    def _id(self, what):
        if self._handle.id is None:
            raise IllegalStateException(f"Can't call {what}() on a recycled bitmap")
        return self._handle.require()

    def _writable(self, what):
        if not self._mutable:
            raise IllegalStateException(f"Bitmap.{what}() on an immutable bitmap")
        return self._id(what)

    def to_bridge(self):
        """What ``ImageView.setImageBitmap`` receives: the host copies the pixels for the view."""
        return {"image": self._id("draw")}

    # Factories

    @staticmethod
    def createBitmap(*args):
        if len(args) == 1 and isinstance(args[0], Bitmap):
            source = args[0]
            return Bitmap._wrap(_new("image.copy", {"image": source._id("createBitmap")}), False)
        if len(args) in (5, 7) and isinstance(args[0], Bitmap):
            source, x, y, width, height = args[:5]
            identifier = source._id("createBitmap")
            if x < 0 or y < 0:
                raise IllegalArgumentException("x and y must be >= 0")
            if width <= 0 or height <= 0:
                raise IllegalArgumentException("width and height must be > 0")
            if x + width > source._width:
                raise IllegalArgumentException("x + width must be <= bitmap.width()")
            if y + height > source._height:
                raise IllegalArgumentException("y + height must be <= bitmap.height()")
            matrix = args[5] if len(args) == 7 else None
            if matrix is None or matrix.isIdentity():
                return Bitmap._wrap(_new("image.crop", {"image": identifier, "box": [x, y, x + width, y + height]}), False)
            if not isinstance(matrix, _g.Matrix) or not matrix.isAffine():
                raise _l.unsupported("Bitmap.createBitmap with a perspective matrix")
            return Bitmap._transformed(source, x, y, width, height, matrix._m, bool(args[6]))
        if len(args) == 4 and not _l.is_int(args[0]) and not isinstance(args[0], (list, tuple)):
            args = args[1:]  # (DisplayMetrics, width, height, config): the metrics only set the density
        if len(args) == 4 and isinstance(args[0], (list, tuple)):
            colors, width, height, config = args
            bitmap = Bitmap.createBitmap(width, height, config)
            bitmap._mutable = True
            bitmap.setPixels(colors, 0, width, 0, 0, width, height)
            bitmap._mutable = False
            return bitmap
        if len(args) in (3, 4) and _l.is_int(args[0]) and _l.is_int(args[1]):
            width, height, config = args[:3]
            if width <= 0 or height <= 0:
                raise IllegalArgumentException("width and height must be > 0")
            mode = _mode(config)
            if len(args) == 4 and not args[3] and mode == "RGBA":
                mode = "RGB"
            color = [0, 0, 0, 0][:len(mode)]
            return Bitmap._wrap(_new("image.create", {"mode": mode, "width": width, "height": height, "color": color}), True)
        raise _l.unsupported("this Bitmap.createBitmap overload")

    @staticmethod
    def _transformed(source, x, y, width, height, m, smooth):
        """The source rectangle mapped by an affine matrix, as Android sizes and places it."""
        corners = [(m[0] * px + m[1] * py + m[2], m[3] * px + m[4] * py + m[5]) for px, py in ((0, 0), (width, 0), (width, height), (0, height))]
        left, top = min(px for px, _ in corners), min(py for _, py in corners)
        new_width = int(round(max(px for px, _ in corners) - left))
        new_height = int(round(max(py for _, py in corners) - top))
        if new_width <= 0 or new_height <= 0:
            raise IllegalArgumentException("width and height must be > 0")
        determinant = m[0] * m[4] - m[1] * m[3]
        if determinant == 0:
            raise IllegalArgumentException("Matrix is not invertible")
        # Output pixel -> pixel of the cropped source: the inverse of the matrix followed by the shift to (left, top).
        a, b, d, e = m[4] / determinant, -m[1] / determinant, -m[3] / determinant, m[0] / determinant
        matrix = [a, b, a * (left - m[2]) + b * (top - m[5]), d, e, d * (left - m[2]) + e * (top - m[5])]
        cropped = _new("image.crop", {"image": source._id("createBitmap"), "box": [x, y, x + width, y + height]})
        try:
            handle = _new("image.transform", {"image": cropped.require(), "width": new_width, "height": new_height, "matrix": matrix,
                                              "filter": "bilinear" if smooth else "nearest"})
        finally:
            cropped.release()
        if handle.mode == "RGB" and not (m[1] == 0 and m[3] == 0):
            # A rotated opaque bitmap has uncovered corners, so Android gives the result an alpha channel.
            wide = _new("image.convert", {"image": handle.require(), "mode": "RGBA"})
            handle.release()
            handle = wide
        return Bitmap._wrap(handle, False)

    @staticmethod
    def createScaledBitmap(source, width, height, smooth):
        if source is None:
            raise NullPointerException("src is null")
        if width <= 0 or height <= 0:
            raise IllegalArgumentException("width and height must be > 0")
        return Bitmap._wrap(_new("image.resize", {"image": source._id("createScaledBitmap"), "width": int(width), "height": int(height),
                                                  "filter": "bilinear" if smooth else "nearest"}), False)

    # State

    def getWidth(self):
        return self._width

    def getHeight(self):
        return self._height

    def getConfig(self):
        return self._config

    def hasAlpha(self):
        return self._handle.mode == "RGBA"

    def isMutable(self):
        return self._mutable

    def isRecycled(self):
        return self._handle.id is None

    def recycle(self):
        self._handle.release()

    def getDensity(self):
        return self._density

    def setDensity(self, density):
        self._density = int(density)

    def getRowBytes(self):
        return self._width * (4 if self._config is _Config.ARGB_8888 else 2)

    def getByteCount(self):
        return self.getRowBytes() * self._height

    def getAllocationByteCount(self):
        return self.getByteCount()

    def copy(self, config, mutable):
        identifier = self._id("copy")
        mode = _mode(config)
        operation, arguments = ("image.copy", {"image": identifier}) if mode == self._handle.mode else ("image.convert", {"image": identifier, "mode": mode})
        return Bitmap._wrap(_new(operation, arguments), mutable)

    # Pixels

    def _check(self, x, y, width=1, height=1):
        if x < 0 or y < 0:
            raise IllegalArgumentException("x and y must be >= 0")
        if x + width > self._width:
            raise IllegalArgumentException("x + width must be <= bitmap.width()")
        if y + height > self._height:
            raise IllegalArgumentException("y + height must be <= bitmap.height()")

    def _colors(self, data):
        bands = self._handle.bands
        if bands == 3:
            return [_l.i32(0xFF000000 | data[i] << 16 | data[i + 1] << 8 | data[i + 2]) for i in range(0, len(data), 3)]
        colors = []
        for i in range(0, len(data), 4):
            alpha = data[i + 3]
            if alpha == 255:
                colors.append(_l.i32(0xFF000000 | data[i] << 16 | data[i + 1] << 8 | data[i + 2]))
            elif alpha == 0:
                colors.append(0)  # premultiplied storage keeps no color under zero alpha
            else:
                colors.append(_l.i32(alpha << 24 | _stored(data[i], alpha) << 16 | _stored(data[i + 1], alpha) << 8 | _stored(data[i + 2], alpha)))
        return colors

    def _bytes(self, colors):
        bands = self._handle.bands
        out = bytearray()
        for color in colors:
            out += bytes(_argb(color)[:bands])
        return bytes(out)

    def getPixel(self, x, y):
        self._id("getPixel")
        self._check(x, y)
        return self._colors(_ayu_images.read(self._handle, (x, y, x + 1, y + 1)))[0]

    def setPixel(self, x, y, color):
        self._writable("setPixel")
        self._check(x, y)
        _ayu_images.write(self._handle, self._bytes([color]), (x, y, x + 1, y + 1))

    def getPixels(self, pixels, offset, stride, x, y, width, height):
        """Fill a Python list (a Java ``int[]`` the host owns is not accepted) with ARGB ints."""
        self._id("getPixels")
        self._check(x, y, width, height)
        self._array(pixels, offset, stride, width, height)
        colors = self._colors(_ayu_images.read(self._handle, (x, y, x + width, y + height)))
        for row in range(height):
            pixels[offset + row * stride:offset + row * stride + width] = colors[row * width:(row + 1) * width]

    def setPixels(self, pixels, offset, stride, x, y, width, height):
        self._writable("setPixels")
        self._check(x, y, width, height)
        self._array(pixels, offset, stride, width, height)
        colors = []
        for row in range(height):
            colors.extend(pixels[offset + row * stride:offset + row * stride + width])
        _ayu_images.write(self._handle, self._bytes(colors), (x, y, x + width, y + height))

    @staticmethod
    def _array(pixels, offset, stride, width, height):
        if not isinstance(pixels, list):
            raise _l.unsupported("Bitmap pixels in anything but a Python list")
        if abs(stride) < width:
            raise IllegalArgumentException("abs(stride) must be >= width")
        last = offset + (height - 1) * stride
        if offset < 0 or offset + width > len(pixels) or last < 0 or last + width > len(pixels):
            raise _l.ArrayIndexOutOfBoundsException()

    def eraseColor(self, color):
        identifier = self._writable("eraseColor")
        _call("image.draw", {"image": identifier, "commands": [{"op": "fill", "fill": _argb(color)[:self._handle.bands]}]})

    def compress(self, compress_format, quality, stream):
        """Write the bitmap as PNG or JPEG to a Python-local ``OutputStream``; returns whether it was written."""
        self._id("compress")
        if stream is None:
            raise NullPointerException()
        if not 0 <= quality <= 100:
            raise IllegalArgumentException("quality must be 0..100")
        name = getattr(compress_format, "name", lambda: None)()
        if name not in ("PNG", "JPEG"):
            # ImageIO writes no WebP; a file of another format under that name would be a lie.
            raise _l.unsupported("Bitmap.compress to " + str(name))
        if not hasattr(type(stream), "write") or type(stream).__name__ == "RemoteObject":
            raise _l.unsupported("Bitmap.compress to a stream the host owns")
        source = self._handle
        opaque = None
        if name == "JPEG" and source.mode == "RGBA":
            # Android writes the premultiplied colors: the bitmap over black.
            black = _new("image.create", {"mode": "RGBA", "width": source.width, "height": source.height, "color": [0, 0, 0, 255]})
            try:
                over = _new("image.alpha_composite", {"image": black.require(), "source": source.require()})
            finally:
                black.release()
            try:
                opaque = source = _new("image.convert", {"image": over.require(), "mode": "RGB"})
            finally:
                over.release()
        try:
            data = _ayu_images.encode(source, name, quality if name == "JPEG" else None)
        finally:
            if opaque is not None:
                opaque.release()
        stream.write(data)
        return True


class Options(Object):
    """``BitmapFactory.Options``: ``inJustDecodeBounds``, ``inSampleSize`` and ``inMutable`` are honoured."""
    __ayu_requires__ = _REQUIRES

    def __init__(self):
        self.inJustDecodeBounds = False
        self.inSampleSize = 0
        self.inPreferredConfig = _Config.ARGB_8888
        self.inMutable = False
        self.inScaled = True
        self.inDensity = 0
        self.inTargetDensity = 0
        self.inScreenDensity = 0
        self.inPremultiplied = True
        self.inDither = False
        self.inPurgeable = False
        self.inInputShareable = False
        self.inPreferQualityOverSpeed = False
        self.inTempStorage = None
        self.inBitmap = None
        self.outWidth = 0
        self.outHeight = 0
        self.outMimeType = None
        self.outConfig = None



class BitmapFactory(Object):
    """Decodes JPEG, PNG, GIF (first frame), WebP and BMP. A file that cannot be decoded gives ``None``, as on Android."""
    __ayu_requires__ = _REQUIRES
    Options = Options

    def __init__(self):
        raise _l.unsupported("android.graphics.BitmapFactory cannot be constructed")

    @staticmethod
    def _decode(source, options):
        from ayu_bridge import BridgeError
        if options is not None and options.inBitmap is not None:
            raise _l.unsupported("BitmapFactory.Options.inBitmap")
        bounds = options is not None and options.inJustDecodeBounds
        try:
            if bounds:
                info = _ayu_images.describe(source)
            else:
                handle, info = _ayu_images.decode(source)
        except BridgeError as error:
            if error.code in ("IMAGE_FORMAT", "IO_ERROR"):
                if options is not None:
                    options.outWidth = options.outHeight = -1
                    options.outMimeType = None
                return None
            raise
        if info.get("format") not in _MIME:
            if not bounds:
                handle.release()
            return None
        sample = 1
        if options is not None and options.inSampleSize and options.inSampleSize > 1:
            # Android rounds the sample size down to a power of two.
            sample = 1 << (int(options.inSampleSize).bit_length() - 1)
        width, height = max(1, info["width"] // sample), max(1, info["height"] // sample)
        if options is not None:
            options.outWidth, options.outHeight = width, height
            options.outMimeType = _MIME[info["format"]]
            options.outConfig = _Config.ARGB_8888
        if bounds:
            return None
        if sample > 1:
            small = _new("image.resize", {"image": handle.require(), "width": width, "height": height, "filter": "box"})
            handle.release()
            handle = small
        return Bitmap._adopt(handle, bool(options is not None and options.inMutable))

    @staticmethod
    def decodeFile(path, options=None):
        if path is None:
            raise NullPointerException("pathName is null")
        if hasattr(type(path), "getPath"):
            path = path.getPath()
        path = os.fspath(path)
        if not os.path.isfile(path):
            return None
        return BitmapFactory._decode(path, options)

    @staticmethod
    def decodeByteArray(data, offset, length, options=None):
        data = _l.to_bytes(data)
        if offset < 0 or length < 0 or offset + length > len(data):
            raise _l.ArrayIndexOutOfBoundsException()
        return BitmapFactory._decode(data[offset:offset + length], options)

    @staticmethod
    def decodeStream(stream, padding=None, options=None):
        if stream is None:
            return None
        if type(stream).__name__ == "RemoteObject":
            raise _l.unsupported("BitmapFactory.decodeStream from a stream the host owns")
        if hasattr(type(stream), "readAllBytes"):
            data = _l.to_bytes(stream.readAllBytes())
        elif hasattr(type(stream), "read"):
            data = stream.read()
        else:
            raise _l.unsupported("BitmapFactory.decodeStream from this object")
        return BitmapFactory._decode(bytes(data), options)


class Canvas(Object):
    """A canvas that draws into one mutable bitmap.

    Provided: ``save``/``restore``, ``translate``, ``scale``, ``rotate``, ``skew``, ``concat``,
    ``setMatrix``, rectangle clips, ``drawColor`` (``SRC_OVER``, ``SRC``, ``CLEAR``),
    ``drawARGB``/``drawRGB``/``drawPaint``, rectangles, rounded rectangles, ovals, circles,
    arcs, lines, points, paths, one-line text and bitmaps. Shaders, color filters, transfer
    modes, path clips and layers are not.
    """
    __ayu_requires__ = _REQUIRES
    EdgeType = _g.CLASSES["android.graphics.Canvas$EdgeType"]

    def __init__(self, bitmap=None):
        self._bitmap = None
        self._matrix = _IDENTITY
        self._clips = []
        self._saved = []
        if bitmap is not None:
            self.setBitmap(bitmap)

    def setBitmap(self, bitmap):
        if bitmap is not None:
            if not isinstance(bitmap, Bitmap):
                raise TypeError("Canvas needs a Bitmap")
            if not bitmap._mutable:
                raise IllegalStateException("Immutable bitmap passed to Canvas constructor")
            if bitmap.isRecycled():
                raise RuntimeException("Canvas: trying to use a recycled bitmap")
        self._bitmap = bitmap
        self._matrix, self._clips, self._saved = _IDENTITY, [], []

    def _target(self):
        if self._bitmap is None:
            raise _l.unsupported("Canvas without a bitmap")
        if self._bitmap.isRecycled():
            raise RuntimeException("Canvas: trying to use a recycled bitmap")
        return self._bitmap._handle.require()

    def getWidth(self):
        return self._bitmap._width if self._bitmap is not None else 0

    def getHeight(self):
        return self._bitmap._height if self._bitmap is not None else 0

    # Matrix and clip state

    def save(self, flags=None):
        self._saved.append((self._matrix, list(self._clips)))
        return len(self._saved)

    def getSaveCount(self):
        return len(self._saved) + 1

    def restore(self):
        if not self._saved:
            raise IllegalStateException("Underflow in restore - more restores than saves")
        self._matrix, self._clips = self._saved.pop()

    def restoreToCount(self, count):
        if count < 1:
            raise IllegalArgumentException("Underflow in restoreToCount - more restores than saves")
        while len(self._saved) >= count:
            self.restore()

    def _concat(self, a, b, c, d, tx, ty):
        """Pre-concatenate: the new transform applies first, as Android's ``translate``/``scale`` do."""
        ma, mb, mc, md, mtx, mty = self._matrix
        self._matrix = (ma * a + mc * b, mb * a + md * b, ma * c + mc * d, mb * c + md * d,
                        ma * tx + mc * ty + mtx, mb * tx + md * ty + mty)

    def translate(self, dx, dy):
        self._concat(1.0, 0.0, 0.0, 1.0, float(dx), float(dy))

    def scale(self, sx, sy, *pivot):
        if pivot:
            px, py = pivot
            self.translate(px, py)
            self._concat(float(sx), 0.0, 0.0, float(sy), 0.0, 0.0)
            self.translate(-px, -py)
        else:
            self._concat(float(sx), 0.0, 0.0, float(sy), 0.0, 0.0)

    def rotate(self, degrees, *pivot):
        radians = math.radians(degrees)
        sin, cos = math.sin(radians), math.cos(radians)
        if pivot:
            px, py = pivot
            self.translate(px, py)
            self._concat(cos, sin, -sin, cos, 0.0, 0.0)
            self.translate(-px, -py)
        else:
            self._concat(cos, sin, -sin, cos, 0.0, 0.0)

    def skew(self, sx, sy):
        self._concat(1.0, float(sy), float(sx), 1.0, 0.0, 0.0)

    @staticmethod
    def _affine(matrix):
        if not isinstance(matrix, _g.Matrix) or not matrix.isAffine():
            raise _l.unsupported("a Canvas matrix that is not affine")
        m = matrix._m
        return (float(m[0]), float(m[3]), float(m[1]), float(m[4]), float(m[2]), float(m[5]))

    def concat(self, matrix):
        if matrix is not None:
            self._concat(*self._affine(matrix))

    def setMatrix(self, matrix):
        self._matrix = _IDENTITY if matrix is None else self._affine(matrix)

    def clipRect(self, *args):
        if len(args) == 5 or len(args) == 2:
            raise _l.unsupported("Canvas.clipRect with a Region.Op")
        left, top, right, bottom = _box(args, "clipRect")
        if len(self._clips) >= 32:
            raise _l.unsupported("more than 32 nested clips")
        self._clips.append({"matrix": list(self._matrix), "rect": [left, top, max(left, right), max(top, bottom)]})
        return right > left and bottom > top

    # Drawing

    def _draw(self, command, paint=None, needs_paint=True):
        if paint is None and needs_paint:
            raise NullPointerException("paint is null")
        if paint is not None:
            if type(paint).__name__ != "RemoteObject":
                raise _l.unsupported("a Paint the host does not own")
            command["paint"] = paint
        if self._matrix != _IDENTITY:
            command["matrix"] = list(self._matrix)
        if self._clips:
            command["clips"] = self._clips
        _call("image.draw", {"image": self._target(), "commands": [command]})

    def drawColor(self, color, mode=None):
        name = "SRC_OVER" if mode is None else getattr(mode, "name", lambda: None)()
        if name is None and type(mode).__name__ == "RemoteObject":
            name = str(mode.name())
        ink = _argb(color)
        bands = self._bitmap._handle.bands if self._bitmap is not None else 4
        if name == "SRC_OVER":
            self._draw({"op": "fill", "fill": ink, "blend": "over"}, needs_paint=False)
        elif name == "SRC":
            self._draw({"op": "fill", "fill": ink[:bands]}, needs_paint=False)
        elif name == "CLEAR":
            self._draw({"op": "fill", "fill": [0, 0, 0, 0][:bands]}, needs_paint=False)
        else:
            raise _l.unsupported("Canvas.drawColor with PorterDuff.Mode." + str(name))

    def drawARGB(self, alpha, red, green, blue):
        self.drawColor(_l.i32((alpha & 255) << 24 | (red & 255) << 16 | (green & 255) << 8 | (blue & 255)))

    def drawRGB(self, red, green, blue):
        self.drawARGB(255, red, green, blue)

    def drawPaint(self, paint):
        self._draw({"op": "fill"}, paint)

    def drawRect(self, *args):
        self._draw({"op": "rect", "box": _box(args[:-1], "drawRect")}, args[-1])

    def drawRoundRect(self, *args):
        *box, rx, ry, paint = args
        self._draw({"op": "round_rect", "box": _box(box, "drawRoundRect"), "radii": [float(rx), float(ry)]}, paint)

    def drawOval(self, *args):
        self._draw({"op": "ellipse", "box": _box(args[:-1], "drawOval")}, args[-1])

    def drawCircle(self, cx, cy, radius, paint):
        if radius > 0:
            self._draw({"op": "ellipse", "box": [float(cx - radius), float(cy - radius), float(cx + radius), float(cy + radius)]}, paint)

    def drawArc(self, *args):
        *box, start, sweep, use_center, paint = args
        self._draw({"op": "arc", "box": _box(box, "drawArc"), "start": float(start), "sweep": float(sweep), "center": bool(use_center)}, paint)

    def drawLine(self, x0, y0, x1, y1, paint):
        self._draw({"op": "line", "points": [float(x0), float(y0), float(x1), float(y1)]}, paint)

    def drawPoint(self, x, y, paint):
        # A zero-length line: the paint's cap and width give the dot its shape.
        self._draw({"op": "line", "points": [float(x), float(y), float(x), float(y)]}, paint)

    def drawPath(self, path, paint):
        if path is None:
            raise NullPointerException("path is null")
        if type(path).__name__ != "RemoteObject":
            raise _l.unsupported("a Path the host does not own")
        self._draw({"op": "path", "path": path}, paint)

    def drawText(self, text, *args):
        """One line of text with its baseline starting at (x, y), in the paint's size and color."""
        if len(args) == 5:
            start, end, x, y, paint = args
            text = str(text)[start:end]
        elif len(args) == 3:
            x, y, paint = args
        else:
            raise _l.unsupported("this Canvas.drawText overload")
        if str(text):
            self._draw({"op": "text", "text": str(text), "origin": [float(x), float(y)]}, paint)

    def drawBitmap(self, bitmap, *args):
        if not isinstance(bitmap, Bitmap):
            raise NullPointerException("bitmap is null") if bitmap is None else TypeError("Expected a Bitmap")
        if bitmap.isRecycled():
            raise RuntimeException("Canvas: trying to use a recycled bitmap")
        command = {"op": "image", "source": bitmap._handle.require()}
        if len(args) == 3 and isinstance(args[0], (int, float)):
            left, top, paint = args
            command["dst"] = [float(left), float(top), float(left + bitmap._width), float(top + bitmap._height)]
        elif len(args) == 3:
            source, destination, paint = args
            if source is not None:
                box = [int(value) for value in _box((source,), "drawBitmap")]
                box = [max(0, box[0]), max(0, box[1]), min(bitmap._width, box[2]), min(bitmap._height, box[3])]
                if box[2] <= box[0] or box[3] <= box[1]:
                    return
                command["src"] = box
            command["dst"] = _box((destination,), "drawBitmap")
        elif len(args) == 2:
            matrix, paint = args
            command["dst"] = [0.0, 0.0, float(bitmap._width), float(bitmap._height)]
            saved = self._matrix
            self._concat(*self._affine(matrix))
            try:
                self._draw(command, paint, needs_paint=False)
            finally:
                self._matrix = saved
            return
        else:
            raise _l.unsupported("this Canvas.drawBitmap overload")
        if command["dst"][2] > command["dst"][0] and command["dst"][3] > command["dst"][1]:
            self._draw(command, paint, needs_paint=False)


class BitmapDrawable(Object):
    """A drawable that shows one bitmap. ``ImageView.setImageDrawable`` accepts it; a view background does not."""
    __ayu_requires__ = _REQUIRES

    def __init__(self, *args):
        bitmap = None
        if len(args) == 2:
            bitmap = args[1]
        elif len(args) == 1 and (args[0] is None or isinstance(args[0], Bitmap)):
            bitmap = args[0]
        elif len(args) > 2:
            raise _l.unsupported("this BitmapDrawable constructor")
        if bitmap is not None and not isinstance(bitmap, Bitmap):
            raise _l.unsupported("a BitmapDrawable of anything but a Bitmap")
        self._bitmap = bitmap
        self._bounds = _g.Rect()
        self._alpha = 255
        self._filter = True
        self._antialias = False

    def getBitmap(self):
        return self._bitmap

    def getIntrinsicWidth(self):
        return self._bitmap.getWidth() if self._bitmap is not None else -1

    def getIntrinsicHeight(self):
        return self._bitmap.getHeight() if self._bitmap is not None else -1

    def setBounds(self, *args):
        left, top, right, bottom = (int(value) for value in _box(args, "setBounds"))
        self._bounds = _g.Rect(left, top, right, bottom)

    def getBounds(self):
        return self._bounds

    def setAlpha(self, alpha):
        self._alpha = max(0, min(255, int(alpha)))

    def getAlpha(self):
        return self._alpha

    def setFilterBitmap(self, enabled):
        self._filter = bool(enabled)

    def isFilterBitmap(self):
        return self._filter

    def setAntiAlias(self, enabled):
        self._antialias = bool(enabled)

    def mutate(self):
        return self

    def draw(self, canvas):
        """Stretch the bitmap over the bounds (gravity ``FILL``, the default)."""
        if self._bitmap is None or self._bounds.isEmpty():
            return
        bounds = self._bounds
        command = {"op": "image", "source": self._bitmap._id("draw"), "dst": [float(bounds.left), float(bounds.top), float(bounds.right), float(bounds.bottom)],
                   "alpha": self._alpha, "filter": self._filter, "blend": "over"}
        canvas._draw(command, needs_paint=False)

    def to_bridge(self):
        if self._bitmap is None:
            return None
        if self._alpha != 255:
            raise _l.unsupported("a translucent BitmapDrawable in a view")
        return self._bitmap.to_bridge()


CLASSES = _l.register({
    "android.graphics.Bitmap": Bitmap,
    "android.graphics.BitmapFactory": BitmapFactory,
    "android.graphics.BitmapFactory$Options": Options,
    "android.graphics.Canvas": Canvas,
    "android.graphics.drawable.BitmapDrawable": BitmapDrawable,
})
