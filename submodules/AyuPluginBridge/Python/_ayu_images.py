"""Client of the host image service (the ``image.*`` operations, see *Images* in ``protocol-telegram.md``).

Shared by the ``PIL`` package and the ``android.graphics`` bitmap classes. Pixels stay in the
host: Python holds a ``Handle`` and every operation names images by handle. Encoded files
travel through the file system, not through JSON; only explicit pixel access crosses the
transport, in chunks of at most ``TRANSFER_BYTES``.
"""
from __future__ import annotations

import base64
import os
import tempfile

OPERATIONS = (
    "image.create", "image.decode", "image.encode", "image.release", "image.copy", "image.convert", "image.band",
    "image.merge", "image.putalpha", "image.pixels.get", "image.pixels.put", "image.point", "image.stats",
    "image.crop", "image.resize", "image.transpose", "image.transform", "image.paste", "image.alpha_composite",
    "image.blend", "image.chop", "image.filter", "image.draw", "image.font.load", "image.font.measure",
)
MODES = {"L": 1, "LA": 2, "RGB": 3, "RGBA": 4}
# Raw bytes of one pixel transfer; as base64 inside its envelope this stays under the 262,144-byte request bound.
TRANSFER_BYTES = 131_072
_LIVE = ("loading", "active", "unloading")
# generation -> (scope, image ids, font ids) released by the garbage collector and not yet sent.
_pending = {}


def _runtime():
    from ayu_bridge import runtime
    return runtime


def _queue(scope, kind, ident):
    if scope.state not in _LIVE:
        return  # the host dropped everything the generation owned
    entry = _pending.setdefault(scope.generation, (scope, [], []))
    entry[1 if kind == "images" else 2].append(ident)


def flush():
    """Send the releases the current plugin generation has queued."""
    runtime = _runtime()
    scope = runtime.require()
    for generation in [key for key, entry in _pending.items() if entry[0].state not in _LIVE]:
        del _pending[generation]
    entry = _pending.pop(scope.generation, None)
    if entry is None or entry[0] is not scope:
        return
    for key, values in (("images", entry[1]), ("fonts", entry[2])):
        for start in range(0, len(values), 256):
            runtime.call("image.release", {key: values[start:start + 256]})


def call(operation, arguments):
    """One host operation, after the releases queued for this generation."""
    runtime = _runtime()
    if operation not in runtime.capabilities["operations"]:
        from ayu_bridge import UnsupportedAPI
        runtime.require()
        raise UnsupportedAPI(f"Images need host operation {operation}")
    if _pending:
        flush()
    return runtime.call(operation, arguments)


class Handle:
    """A host image owned by one plugin generation. Dropping the last reference frees the pixels."""
    __slots__ = ("id", "mode", "width", "height", "scope", "__weakref__")
    kind = "images"

    def __init__(self, info):
        if (not isinstance(info, dict) or not isinstance(info.get("image"), str) or info.get("mode") not in MODES
                or type(info.get("width")) is not int or type(info.get("height")) is not int):
            from ayu_bridge import ProtocolError
            raise ProtocolError("Malformed image description")
        self.id, self.mode, self.width, self.height = info["image"], info["mode"], info["width"], info["height"]
        self.scope = _runtime().require()

    @property
    def size(self):
        return (self.width, self.height)

    @property
    def bands(self):
        return MODES[self.mode]

    def require(self):
        """The handle's id, for an operation of the generation that owns it."""
        if self.id is None:
            raise ValueError("Operation on a closed image")
        _runtime().require(self.scope)
        return self.id

    def update(self, info):
        """Adopt the description the host returned for an in-place change."""
        self.mode, self.width, self.height = info["mode"], info["width"], info["height"]

    def release(self):
        ident, self.id = self.id, None
        if ident is None:
            return
        _queue(self.scope, self.kind, ident)
        runtime = _runtime()
        try:
            # Only on the interpreter queue and inside the owning generation; otherwise the next call sends it.
            from ayu_bridge import _current
            import _ayu_threads
            if _current.get() is self.scope and not _ayu_threads.off_queue(runtime):
                flush()
        except Exception:
            pass

    def __del__(self):
        try:
            self.release()
        except BaseException:
            pass


class FontHandle(Handle):
    """A host font."""
    __slots__ = ("metrics",)
    kind = "fonts"

    def __init__(self, info):
        if not isinstance(info, dict) or not isinstance(info.get("font"), str):
            from ayu_bridge import ProtocolError
            raise ProtocolError("Malformed font description")
        self.id, self.mode, self.width, self.height = info["font"], None, 0, 0
        self.metrics = info
        self.scope = _runtime().require()


def new(operation, arguments):
    """An operation whose result is a new image."""
    return Handle(call(operation, arguments))


def temporary(suffix):
    """A fresh private file for one encode or decode; the caller removes it."""
    descriptor, path = tempfile.mkstemp(prefix="ayu-image-", suffix=suffix)
    os.close(descriptor)
    return os.path.realpath(path)


def remove(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def decode(source):
    """Decode a path or the bytes of an encoded image; returns ``(Handle, info)``."""
    if isinstance(source, (bytes, bytearray, memoryview)):
        data = bytes(source)
        if len(data) <= 96_000:
            info = call("image.decode", {"data": base64.b64encode(data).decode("ascii")})
        else:
            path = temporary(".img")
            try:
                with open(path, "wb") as stream:
                    stream.write(data)
                info = call("image.decode", {"path": path})
            finally:
                remove(path)
    else:
        info = call("image.decode", {"path": os.path.realpath(os.fspath(source))})
    return Handle(info), info


def describe(source):
    """What ``decode`` would report for a path or encoded bytes, without keeping the pixels."""
    if isinstance(source, (bytes, bytearray, memoryview)):
        data = bytes(source)
        if len(data) <= 96_000:
            return call("image.decode", {"data": base64.b64encode(data).decode("ascii"), "bounds": True})
        path = temporary(".img")
        try:
            with open(path, "wb") as stream:
                stream.write(data)
            return call("image.decode", {"path": path, "bounds": True})
        finally:
            remove(path)
    return call("image.decode", {"path": os.path.realpath(os.fspath(source)), "bounds": True})


def encode_to_path(handle, image_format, path, quality=None):
    arguments = {"image": handle.require(), "format": image_format, "path": os.path.realpath(os.fspath(path))}
    if quality is not None:
        arguments["quality"] = quality
    return call("image.encode", arguments)["bytes"]


def encode(handle, image_format, quality=None):
    """The encoded bytes of an image."""
    path = temporary("." + image_format.lower())
    try:
        encode_to_path(handle, image_format, path, quality)
        with open(path, "rb") as stream:
            return stream.read()
    finally:
        remove(path)


def _boxes(left, top, right, bottom, bands):
    """Split a pixel box into boxes of at most ``TRANSFER_BYTES``, rows first."""
    width = right - left
    columns = max(1, min(width, TRANSFER_BYTES // bands))
    rows = max(1, TRANSFER_BYTES // (columns * bands))
    for y in range(top, bottom, rows):
        for x in range(left, right, columns):
            yield x, y, min(right, x + columns), min(bottom, y + rows)


def read(handle, box=None):
    """Raw interleaved bytes of a box (the whole image by default), rows top to bottom."""
    left, top, right, bottom = box or (0, 0, handle.width, handle.height)
    bands, ident = handle.bands, handle.require()
    width = right - left
    out = bytearray(width * (bottom - top) * bands)
    for x0, y0, x1, y1 in _boxes(left, top, right, bottom, bands):
        chunk = base64.b64decode(call("image.pixels.get", {"image": ident, "box": [x0, y0, x1, y1]})["data"])
        span = (x1 - x0) * bands
        for row in range(y1 - y0):
            start = ((y0 - top + row) * width + (x0 - left)) * bands
            out[start:start + span] = chunk[row * span:(row + 1) * span]
    return bytes(out)


def write(handle, data, box=None):
    """Replace the bytes of a box (the whole image by default)."""
    left, top, right, bottom = box or (0, 0, handle.width, handle.height)
    bands, ident = handle.bands, handle.require()
    width = right - left
    if len(data) != width * (bottom - top) * bands:
        raise ValueError("pixel data does not match the box")
    view = memoryview(data)
    for x0, y0, x1, y1 in _boxes(left, top, right, bottom, bands):
        span = (x1 - x0) * bands
        chunk = bytearray()
        for row in range(y1 - y0):
            start = ((y0 - top + row) * width + (x0 - left)) * bands
            chunk += view[start:start + span]
        call("image.pixels.put", {"image": ident, "box": [x0, y0, x1, y1], "data": base64.b64encode(chunk).decode("ascii")})
