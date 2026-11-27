"""``PIL.Image``: the image class and its factory functions, over host-owned pixels.

Modes are ``L``, ``LA``, ``RGB`` and ``RGBA`` (eight bits per band, straight alpha). Palette
(``P``), bilevel (``1``), CMYK, HSV and wider modes are not provided: asking for one raises
``UnsupportedAPI``. Files are read through the host's decoders (JPEG, PNG, GIF, WebP, BMP,
TIFF; the first frame only) and written as PNG or JPEG.
"""
from __future__ import annotations

import enum
import math
import os

import _ayu_images

from . import ImageColor, UnidentifiedImageError
from . import _host


class Resampling(enum.IntEnum):
    NEAREST = 0
    BOX = 4
    BILINEAR = 2
    HAMMING = 5
    BICUBIC = 3
    LANCZOS = 1


class Transpose(enum.IntEnum):
    FLIP_LEFT_RIGHT = 0
    FLIP_TOP_BOTTOM = 1
    ROTATE_90 = 2
    ROTATE_180 = 3
    ROTATE_270 = 4
    TRANSPOSE = 5
    TRANSVERSE = 6


class Transform(enum.IntEnum):
    AFFINE = 0
    EXTENT = 1


NEAREST = Resampling.NEAREST
BOX = Resampling.BOX
BILINEAR = Resampling.BILINEAR
HAMMING = Resampling.HAMMING
BICUBIC = Resampling.BICUBIC
LANCZOS = Resampling.LANCZOS
FLIP_LEFT_RIGHT = Transpose.FLIP_LEFT_RIGHT
FLIP_TOP_BOTTOM = Transpose.FLIP_TOP_BOTTOM
ROTATE_90 = Transpose.ROTATE_90
ROTATE_180 = Transpose.ROTATE_180
ROTATE_270 = Transpose.ROTATE_270
TRANSPOSE = Transpose.TRANSPOSE
TRANSVERSE = Transpose.TRANSVERSE
AFFINE = Transform.AFFINE
EXTENT = Transform.EXTENT

_FILTERS = {0: "nearest", 4: "box", 2: "bilinear", 5: "hamming", 3: "bicubic", 1: "lanczos"}
_TRANSPOSES = {0: "flip_left_right", 1: "flip_top_bottom", 2: "rotate_90", 3: "rotate_180", 4: "rotate_270",
               5: "transpose", 6: "transverse"}
_MODES = _ayu_images.MODES
# Extensions and format names Pillow knows; only PNG and JPEG (and WEBP where the system encodes it) are written.
_EXTENSIONS = {".png": "PNG", ".apng": "PNG", ".jpg": "JPEG", ".jpeg": "JPEG", ".jpe": "JPEG", ".jfif": "JPEG",
               ".webp": "WEBP", ".gif": "GIF", ".bmp": "BMP", ".tif": "TIFF", ".tiff": "TIFF", ".ico": "ICO",
               ".pdf": "PDF", ".tga": "TGA", ".ppm": "PPM", ".icns": "ICNS"}
_FORMATS = frozenset(_EXTENSIONS.values()) | {"MPO", "JPEG2000", "EPS", "DDS", "PCX", "SGI"}
_WRITABLE = ("PNG", "JPEG", "WEBP")
# Save parameters that change only the size or layout of the file, not its pixels.
_HINTS = frozenset({"optimize", "progressive", "progression", "compress_level", "subsampling", "method", "bitmap_format"})
# Save parameters that would change the file's content and are not implemented.
_REFUSED = frozenset({"save_all", "append_images", "exif", "icc_profile", "pnginfo", "transparency", "lossless", "dpi",
                      "qtables", "xmp", "comment", "duration", "loop", "disposal", "palette", "bits"})


def _mode(mode):
    if mode not in _MODES:
        raise _host.unsupported("mode " + repr(mode)[:20])
    return mode


def _byte(value):
    if isinstance(value, float):
        value = int(value)
    if not isinstance(value, int):
        raise TypeError("color must be int or tuple")
    return max(0, min(255, value))


def _ink(color, mode, alpha=False):
    """One value per band of ``mode`` for a Pillow color.

    ``alpha`` keeps a fourth value of an RGB color (``ImageDraw`` in ``RGBA`` mode on an ``RGB`` image).
    """
    bands = _MODES[mode]
    if color is None:
        return [0] * bands
    if isinstance(color, str):
        if alpha and mode == "RGB":
            return list(ImageColor.getcolor(color, "RGBA"))
        color = ImageColor.getcolor(color, mode)
    if isinstance(color, (int, float)):
        if isinstance(color, float):
            color = int(color)
        if bands == 1:
            return [_byte(color)]
        if mode == "LA":
            return [color & 255, (color >> 8) & 255]
        # An integer is the packed pixel, red in the low byte.
        packed = [color & 255, (color >> 8) & 255, (color >> 16) & 255, (color >> 24) & 255]
        if mode == "RGB" and alpha:
            return packed[:3] + [255]
        return packed[:bands]
    try:
        values = list(color)
    except TypeError:
        raise TypeError("color must be int or tuple") from None
    if bands == 1:
        if len(values) != 1:
            raise TypeError("color must be int or single-element tuple")
        return [_byte(values[0])]
    if mode == "LA":
        if len(values) == 1:
            return [_byte(values[0]), 255]
        if len(values) == 2:
            return [_byte(values[0]), _byte(values[1])]
        raise TypeError("color must be int, or tuple of one or two elements")
    if len(values) == 3:
        values.append(255)
    if len(values) != 4:
        raise TypeError("color must be int, or tuple of one, three or four elements")
    values = [_byte(value) for value in values]
    if mode == "RGB" and not alpha:
        return values[:3]
    return values


def _size(size):
    try:
        width, height = size
    except (TypeError, ValueError):
        raise ValueError("Size must be a sequence of length 2") from None
    for value in (width, height):
        if isinstance(value, bool) or not isinstance(value, int):
            raise TypeError("integer argument expected, got " + type(value).__name__)
    if width < 0 or height < 0:
        raise ValueError("Width and height must be >= 0")
    return width, height


def _resample(resample, allowed, default):
    if resample is None:
        resample = default
    if isinstance(resample, bool) or not isinstance(resample, int) or int(resample) not in allowed:
        raise ValueError(f"Unknown resampling filter ({resample}).")
    return int(resample)


class PixelAccess:
    """``image.load()``: ``pixels[x, y]`` reads and writes single pixels.

    Reads are served from a cached strip of rows; a write, and any other change made through
    the image object, discards the strip.
    """

    def __init__(self, image):
        self._image = image
        self._strip = None

    def _position(self, xy):
        try:
            x, y = xy
        except (TypeError, ValueError):
            raise TypeError("argument must be sequence of length 2") from None
        width, height = self._image.size
        if x < 0:
            x += width
        if y < 0:
            y += height
        if not (isinstance(x, int) and isinstance(y, int)) or not (0 <= x < width and 0 <= y < height):
            raise IndexError("image index out of range")
        return x, y

    def __getitem__(self, xy):
        x, y = self._position(xy)
        image = self._image
        bands, width = image._handle.bands, image.width
        strip = self._strip
        if strip is None or strip[0] != image._version or not strip[1] <= y < strip[2]:
            rows = max(1, _ayu_images.TRANSFER_BYTES // (width * bands))
            top = y - y % rows
            bottom = min(image.height, top + rows)
            strip = self._strip = (image._version, top, bottom, _ayu_images.read(image._handle, (0, top, width, bottom)))
        start = ((y - strip[1]) * width + x) * bands
        return strip[3][start] if bands == 1 else tuple(strip[3][start:start + bands])

    def __setitem__(self, xy, color):
        x, y = self._position(xy)
        image = self._image
        _ayu_images.write(image._handle, bytes(_ink(color, image.mode)), (x, y, x + 1, y + 1))
        image._touch()


class Image:
    """An image whose pixels live in the host."""
    format = None
    format_description = None

    def __init__(self):
        raise TypeError("Use Image.new() or Image.open()")

    @classmethod
    def _wrap(cls, handle, source=None):
        image = object.__new__(cls)
        image._handle = handle
        image._version = 0
        image.info = dict(source.info) if source is not None else {}
        image.readonly = 0
        image._frames = 1
        # Pillow keeps the file's EXIF block in ``info`` of every derived image; this is the part of it that is used.
        image._orientation = source._orientation if source is not None else 1
        return image

    # Attributes

    @property
    def mode(self):
        return self._handle.mode

    @property
    def size(self):
        return self._handle.size

    @property
    def width(self):
        return self._handle.width

    @property
    def height(self):
        return self._handle.height

    @property
    def n_frames(self):
        return self._frames

    @property
    def is_animated(self):
        return self._frames > 1

    def __repr__(self):
        return f"<PIL.Image.Image image mode={self.mode} size={self.width}x{self.height}>"

    def __enter__(self):
        return self

    def __exit__(self, *arguments):
        pass

    def _id(self):
        return self._handle.require()

    def _touch(self):
        self._version += 1

    def _new(self, operation, arguments):
        return Image._wrap(_host.new(operation, arguments), self)

    def _adopt(self, other):
        """Become ``other`` (an in-place Pillow method that Pillow implements by swapping the core image)."""
        self._handle, other._handle = other._handle, self._handle
        self._touch()

    def close(self):
        self._handle.release()

    def load(self):
        self._id()
        return PixelAccess(self)

    def verify(self):
        """The file was decoded completely when it was opened; nothing is left to check."""
        self._id()

    def draft(self, mode, size):
        """Pillow's decoder hint. The image is already decoded, so nothing is reconfigured."""
        return None

    def seek(self, frame):
        if frame != 0:
            if 0 < frame < self._frames:
                raise _host.unsupported("a frame other than the first")
            raise EOFError("attempt to seek outside sequence")

    def tell(self):
        return 0

    def getbands(self):
        return tuple(self.mode)

    # Copies and modes

    def copy(self):
        return self._new("image.copy", {"image": self._id()})

    def convert(self, mode=None, matrix=None, dither=None, palette=0, colors=256):
        if mode is None or mode == self.mode:
            return self.copy()
        if matrix is not None:
            raise _host.unsupported("convert() with a matrix")
        return self._new("image.convert", {"image": self._id(), "mode": _mode(mode)})

    def split(self):
        return tuple(self._new("image.band", {"image": self._id(), "band": index}) for index in range(len(self.mode)))

    def getchannel(self, channel):
        if isinstance(channel, str):
            try:
                channel = self.getbands().index(channel)
            except ValueError:
                raise ValueError(f'The image has no channel "{channel}"') from None
        if isinstance(channel, bool) or not isinstance(channel, int) or not 0 <= channel < len(self.mode):
            raise ValueError("band index out of range")
        return self._new("image.band", {"image": self._id(), "band": channel})

    def putalpha(self, alpha):
        if isinstance(alpha, Image):
            if alpha.mode != "L":
                raise ValueError("illegal image mode")
            value = alpha._id()
        else:
            value = _byte(alpha)
        self._handle.update(_host.call("image.putalpha", {"image": self._id(), "alpha": value}))
        self._touch()

    # Geometry

    def crop(self, box=None):
        if box is None:
            return self.copy()
        left, top, right, bottom = (int(round(value)) for value in box)
        if right < left:
            raise ValueError("Coordinate 'right' is less than 'left'")
        if bottom < top:
            raise ValueError("Coordinate 'lower' is less than 'upper'")
        return self._new("image.crop", {"image": self._id(), "box": [left, top, right, bottom]})

    def resize(self, size, resample=None, box=None, reducing_gap=None):
        resample = _resample(resample, _FILTERS, Resampling.BICUBIC)
        if reducing_gap is not None and reducing_gap < 1.0:
            raise ValueError("reducing_gap must be 1.0 or greater")
        width, height = _size(size)
        arguments = {"image": self._id(), "width": width, "height": height, "filter": _FILTERS[resample]}
        if box is not None:
            arguments["box"] = [float(value) for value in box]
        elif (width, height) == self.size:
            return self.copy()
        return self._new("image.resize", arguments)

    def thumbnail(self, size, resample=Resampling.BICUBIC, reducing_gap=2.0):
        """Shrink in place to fit ``size``, keeping the aspect ratio."""
        x, y = (math.floor(value) for value in size)
        if x >= self.width and y >= self.height:
            return

        def round_aspect(number, key):
            return max(min(math.floor(number), math.ceil(number), key=key), 1)

        aspect = self.width / self.height
        if x / y >= aspect:
            x = round_aspect(y * aspect, key=lambda n: abs(aspect - n / y))
        else:
            y = round_aspect(x / aspect, key=lambda n: 0 if n == 0 else abs(aspect - x / n))
        if (x, y) != self.size:
            self._adopt(self.resize((x, y), resample))
        self.readonly = 0

    def transpose(self, method):
        if isinstance(method, bool) or not isinstance(method, int) or int(method) not in _TRANSPOSES:
            raise ValueError("Unknown transposition method")
        return self._new("image.transpose", {"image": self._id(), "method": _TRANSPOSES[int(method)]})

    def transform(self, size, method, data=None, resample=Resampling.NEAREST, fill=1, fillcolor=None):
        resample = _resample(resample, (0, 2, 3), Resampling.NEAREST)
        width, height = _size(size)
        if method == Transform.AFFINE:
            matrix = [float(value) for value in data[:6]]
        elif method == Transform.EXTENT:
            x0, y0, x1, y1 = data
            matrix = [(x1 - x0) / width, 0.0, float(x0), 0.0, (y1 - y0) / height, float(y0)]
        else:
            raise _host.unsupported("transform method " + repr(method)[:24])
        if len(matrix) != 6:
            raise ValueError("an affine transform needs six coefficients")
        arguments = {"image": self._id(), "width": width, "height": height, "matrix": matrix, "filter": _FILTERS[resample]}
        if fillcolor is not None:
            arguments["fill"] = _ink(fillcolor, self.mode)
        return self._new("image.transform", arguments)

    def rotate(self, angle, resample=Resampling.NEAREST, expand=0, center=None, translate=None, fillcolor=None):
        """Rotate counter-clockwise by ``angle`` degrees around the center."""
        angle = angle % 360.0
        if not (center or translate):
            if angle == 0:
                return self.copy()
            if angle == 180:
                return self.transpose(Transpose.ROTATE_180)
            if angle in (90, 270) and (expand or self.width == self.height):
                return self.transpose(Transpose.ROTATE_90 if angle == 90 else Transpose.ROTATE_270)
        width, height = self.size
        shift = (0, 0) if translate is None else translate
        middle = (width / 2.0, height / 2.0) if center is None else center
        radians = -math.radians(angle)
        matrix = [round(math.cos(radians), 15), round(math.sin(radians), 15), 0.0,
                  round(-math.sin(radians), 15), round(math.cos(radians), 15), 0.0]

        def apply(x, y):
            a, b, c, d, e, f = matrix
            return a * x + b * y + c, d * x + e * y + f

        matrix[2], matrix[5] = apply(-middle[0] - shift[0], -middle[1] - shift[1])
        matrix[2] += middle[0]
        matrix[5] += middle[1]
        if expand:
            corners = [apply(x, y) for x, y in ((0, 0), (width, 0), (width, height), (0, height))]
            new_width = math.ceil(max(x for x, _ in corners)) - math.floor(min(x for x, _ in corners))
            new_height = math.ceil(max(y for _, y in corners)) - math.floor(min(y for _, y in corners))
            matrix[2], matrix[5] = apply(-(new_width - width) / 2.0, -(new_height - height) / 2.0)
            width, height = new_width, new_height
        return self.transform((width, height), Transform.AFFINE, matrix, resample, fillcolor=fillcolor)

    # Compositing

    def paste(self, im, box=None, mask=None):
        if isinstance(box, Image):
            if mask is not None:
                raise ValueError("If using second argument as mask, third argument must be None")
            box, mask = None, box
        box = (0, 0) if box is None else tuple(box)
        if len(box) == 2:
            if isinstance(im, Image):
                size = im.size
            elif isinstance(mask, Image):
                size = mask.size
            else:
                raise ValueError("cannot determine region size; use 4-item box")
            box += (box[0] + size[0], box[1] + size[1])
        left, top, right, bottom = (int(value) for value in box)
        region = (right - left, bottom - top)
        if mask is not None and not isinstance(mask, Image):
            raise TypeError("mask must be an image")
        if mask is not None and mask.size != region:
            raise ValueError("images do not match")
        arguments = {"image": self._id(), "box": [left, top]}
        keep = None
        if isinstance(im, Image):
            if im.size != region:
                raise ValueError("images do not match")
            # Pasting an alpha image into RGB copies its color bands, which is what the conversion does.
            keep = im if im.mode == self.mode else im.convert(self.mode)
            arguments["source"] = keep._id()
        elif mask is None:
            if region[0] <= 0 or region[1] <= 0:
                return
            keep = new(self.mode, region, im)
            arguments["source"] = keep._id()
        else:
            arguments["color"] = _ink(im, self.mode)
        if mask is not None:
            arguments["mask"] = mask._id()
        _host.call("image.paste", arguments)
        self._touch()

    def alpha_composite(self, im, dest=(0, 0), source=(0, 0)):
        """Composite ``im`` over this image in place; both must be ``RGBA``."""
        if not isinstance(source, (list, tuple)) or not isinstance(dest, (list, tuple)):
            raise ValueError("Source and destination must be sequences")
        if len(source) not in (2, 4):
            raise ValueError("Source must be a sequence of length 2 or 4")
        if len(dest) != 2:
            raise ValueError("Destination must be a sequence of length 2")
        if min(source) < 0:
            raise ValueError("Source must be non-negative")
        source = tuple(source) + im.size if len(source) == 2 else tuple(source)
        overlay = im if source == (0, 0) + im.size else im.crop(source)
        box = tuple(dest) + (dest[0] + overlay.width, dest[1] + overlay.height)
        if box == (0, 0) + self.size:
            background = self
        else:
            background = self.crop(box)
        result = alpha_composite(background, overlay)
        self.paste(result, box)

    # Pixels

    def getpixel(self, xy):
        return PixelAccess(self)[xy]

    def putpixel(self, xy, value):
        PixelAccess(self)[xy] = value

    def tobytes(self, encoder_name="raw", *arguments):
        if encoder_name != "raw" or arguments not in ((), (self.mode,)):
            raise _host.unsupported("tobytes() with an encoder")
        return _ayu_images.read(self._handle)

    def getdata(self, band=None):
        """Pixel values as a list: integers for one band, tuples otherwise."""
        image = self if band is None else self.getchannel(band)
        data = _ayu_images.read(image._handle)
        bands = image._handle.bands
        if bands == 1:
            return list(data)
        return list(zip(*(data[index::bands] for index in range(bands))))

    def putdata(self, data, scale=1.0, offset=0.0):
        bands = self._handle.bands
        count = self.width * self.height
        out = bytearray(_ayu_images.read(self._handle))
        for index, value in enumerate(data):
            if index >= count:
                break
            if bands == 1:
                out[index] = _byte(value * scale + offset if (scale, offset) != (1.0, 0.0) else value)
            else:
                out[index * bands:(index + 1) * bands] = bytes(_ink(value, self.mode))
        _ayu_images.write(self._handle, bytes(out))
        self._touch()

    def point(self, lut, mode=None):
        if mode is not None and mode != self.mode:
            raise _host.unsupported("point() to another mode")
        bands = self._handle.bands
        if callable(lut):
            lut = [lut(index) for index in range(256)] * bands
        table = list(lut)
        if len(table) == 256 and bands > 1:
            table = table * bands
        if len(table) != 256 * bands:
            raise ValueError("wrong number of lut entries")
        return self._new("image.point", {"image": self._id(), "table": [_byte(value) for value in table]})

    def histogram(self, mask=None, extrema=None):
        if mask is not None or extrema is not None:
            raise _host.unsupported("histogram() with a mask or extrema")
        return _host.call("image.stats", {"image": self._id(), "kind": "histogram"})

    def getbbox(self, *, alpha_only=True):
        image = self
        if not alpha_only and self.mode in ("LA", "RGBA"):
            image = self.convert("RGB" if self.mode == "RGBA" else "L")
            alpha = self.getchannel("A").getbbox()
            color = image.getbbox()
            boxes = [box for box in (alpha, color) if box]
            if not boxes:
                return None
            return (min(box[0] for box in boxes), min(box[1] for box in boxes), max(box[2] for box in boxes), max(box[3] for box in boxes))
        box = _host.call("image.stats", {"image": image._id(), "kind": "bbox"})
        return None if box is None else tuple(box)

    def getextrema(self):
        extrema = [tuple(pair) for pair in _host.call("image.stats", {"image": self._id(), "kind": "extrema"})]
        return extrema[0] if len(extrema) == 1 else tuple(extrema)

    def getcolors(self, maxcolors=256):
        colors = _host.call("image.stats", {"image": self._id(), "kind": "colors", "max": int(maxcolors)})
        if colors is None:
            return None
        return [(count, value[0] if len(value) == 1 else tuple(value)) for count, value in colors]

    def filter(self, filter):
        from . import ImageFilter
        if callable(filter):
            filter = filter()
        if not isinstance(filter, ImageFilter.Filter):
            raise TypeError("filter argument should be ImageFilter.Filter instance or class")
        return filter.filter(self)

    # Files

    def save(self, fp, format=None, **params):
        filename = None
        if isinstance(fp, (str, bytes, os.PathLike)):
            filename = os.fsdecode(os.fspath(fp))
        elif not hasattr(fp, "write"):
            raise TypeError("fp must be a path or a writable file object")
        if format is None:
            name = filename if filename is not None else getattr(fp, "name", "")
            extension = os.path.splitext(name if isinstance(name, str) else "")[1].lower()
            if extension not in _EXTENSIONS:
                raise ValueError(f"unknown file extension: {extension}")
            format = _EXTENSIONS[extension]
        format = format.upper()
        if format not in _FORMATS:
            raise KeyError(format)
        refused = sorted(key for key, value in params.items() if key in _REFUSED and value not in (None, False))
        if format not in _WRITABLE:
            raise _host.unsupported("saving as " + format)
        if refused:
            raise _host.unsupported("save(" + refused[0] + "=...)")
        quality = None
        if format != "PNG":
            quality = params.get("quality", 75)
            if isinstance(quality, bool) or not isinstance(quality, int):
                raise _host.unsupported("a quality that is not a number")
            quality = max(0, min(100, quality))
        if format == "JPEG" and self.mode not in ("L", "RGB"):
            raise OSError(f"cannot write mode {self.mode} as JPEG")
        if filename is not None:
            try:
                _host.call("image.encode", dict({"image": self._id(), "format": format, "path": os.path.realpath(filename)},
                                               **({} if quality is None else {"quality": quality})))
            except OSError:
                if not os.path.isdir(os.path.dirname(os.path.realpath(filename))):
                    raise FileNotFoundError(2, "No such file or directory", filename) from None
                raise
            return
        from ayu_bridge import BridgeError
        try:
            data = _ayu_images.encode(self._handle, format, quality)
        except BridgeError as error:
            translated = _host.translate(error)
            if translated is error:
                raise
            raise translated from None
        fp.write(data)


# Factories

def new(mode, size, color=0):
    width, height = _size(size)
    if width == 0 or height == 0:
        raise _host.unsupported("an image without pixels")
    return Image._wrap(_host.new("image.create", {"mode": _mode(mode), "width": width, "height": height, "color": _ink(color, mode)}))


def open(fp, mode="r", formats=None):
    if mode != "r":
        raise ValueError(f"bad mode {mode!r}")
    from ayu_bridge import BridgeError
    label = fp
    try:
        if isinstance(fp, (str, bytes, os.PathLike)):
            path = os.fsdecode(os.fspath(fp))
            if not os.path.exists(path):
                raise FileNotFoundError(2, "No such file or directory", path)
            if os.path.isdir(path):
                raise IsADirectoryError(21, "Is a directory", path)
            handle, info = _ayu_images.decode(path)
        elif hasattr(fp, "read"):
            data = fp.read()
            if not isinstance(data, (bytes, bytearray, memoryview)):
                raise TypeError("file object must be opened in binary mode")
            handle, info = _ayu_images.decode(data)
        else:
            raise TypeError("fp must be a path or a readable binary file object")
    except BridgeError as error:
        if error.code == "IMAGE_FORMAT":
            raise UnidentifiedImageError(f"cannot identify image file {label!r}") from None
        translated = _host.translate(error)
        if translated is error:
            raise
        raise translated from None
    if formats is not None and info.get("format") not in [str(name).upper() for name in formats]:
        handle.release()
        raise UnidentifiedImageError(f"cannot identify image file {label!r}")
    image = Image._wrap(handle)
    image.format = info.get("format")
    image._frames = info.get("frames", 1)
    image._orientation = info.get("orientation", 1)
    if isinstance(fp, (str, os.PathLike)):
        image.filename = os.fsdecode(os.fspath(fp))
    return image


def merge(mode, bands):
    bands = list(bands)
    if _mode(mode) and len(bands) != _MODES[mode]:
        raise ValueError("wrong number of bands")
    for band in bands:
        if band.mode != "L":
            raise ValueError("mode mismatch")
        if band.size != bands[0].size:
            raise ValueError("size mismatch")
    return Image._wrap(_host.new("image.merge", {"mode": mode, "bands": [band._id() for band in bands]}))


def blend(im1, im2, alpha):
    """``im1 * (1 - alpha) + im2 * alpha``."""
    return im1._new("image.blend", {"image": im1._id(), "source": im2._id(), "alpha": float(alpha)})


def composite(image1, image2, mask):
    """``image1`` where ``mask`` is 255, ``image2`` where it is 0."""
    image = image2.copy()
    image.paste(image1, None, mask)
    return image


def alpha_composite(im1, im2):
    """``im2`` over ``im1``; both ``RGBA`` and the same size."""
    return im1._new("image.alpha_composite", {"image": im1._id(), "source": im2._id()})
