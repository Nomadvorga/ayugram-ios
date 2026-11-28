"""``SendMessagesHelper.generatePhotoSizes``: Android's scaled JPEG copies of a picture, as a ``TL_photo``.

Follows ``SendMessagesHelper.generatePhotoSizes(path, uri)`` and ``ImageLoader.scaleAndSaveImage``: a thumbnail
inside 90x90 at quality 55 and the picture inside ``AndroidUtilities.getPhotoSize()`` (1280) at quality 80, saved
as ``<volume_id>_<local_id>.jpg`` in the cache directory. The pixels are handled by the host image service.
"""
from __future__ import annotations

import os
import struct

import _ayu_images

OPERATIONS = ("image.decode", "image.resize", "image.encode", "image.transpose", "image.convert", "image.create",
              "image.alpha_composite", "telegram.connection")
PHOTO_SIZE = 1280
_VOLUME = -2147483648
# ``SharedConfig.lastLocalId`` starts here and counts down.
_last_local_id = -210000
# ``ImageLoader.loadBitmap`` turns the picture for these EXIF orientations only.
_TURNS = {3: "rotate_180", 6: "rotate_270", 8: "rotate_90"}


def _f32(value):
    return struct.unpack("f", struct.pack("f", value))[0]


def _scaled_size(width, height, max_side, min_side):
    """``(w, h, resize)`` of ``ImageLoader.scaleAndSaveImage``; None when a side would be zero."""
    # Java divides floats: 1000x3000 inside 90 is 30x90 there and 29x90 in double arithmetic.
    factor, anyway = max(_f32(width / max_side), _f32(height / max_side)), False
    if min_side and (width < min_side or height < min_side):
        if width < min_side and height > min_side:
            factor = _f32(width / min_side)
        elif width > min_side and height < min_side:
            factor = _f32(height / min_side)
        else:
            factor = max(_f32(width / min_side), _f32(height / min_side))
        anyway = True
    w, h = int(_f32(width / factor)), int(_f32(height / factor))
    if w == 0 or h == 0:
        return None
    return w, h, factor > 1 or anyway


def _type(w, h):
    for letter, side in (("s", 100), ("m", 320), ("x", 800), ("y", 1280)):
        if w <= side and h <= side:
            return letter
    return "w"


def _opaque(handle):
    """RGB pixels as Android's JPEG encoder writes a bitmap: transparency becomes black."""
    if handle.mode == "RGB":
        return handle
    if handle.mode in ("LA", "RGBA"):
        if handle.mode == "LA":
            handle = _ayu_images.new("image.convert", {"image": handle.require(), "mode": "RGBA"})
        black = _ayu_images.new("image.create", {"mode": "RGBA", "width": handle.width, "height": handle.height,
                                                 "color": [0, 0, 0, 255]})
        handle = _ayu_images.new("image.alpha_composite", {"image": black.require(), "source": handle.require()})
    return _ayu_images.new("image.convert", {"image": handle.require(), "mode": "RGB"})


def _local_id(directory):
    global _last_local_id
    while True:
        value, _last_local_id = _last_local_id, _last_local_id - 1
        # The counter is not persisted as on Android: never overwrite a file of an earlier run.
        if not os.path.exists(os.path.join(directory, f"{_VOLUME}_{value}.jpg")):
            return value


def _save(tlrpc, bitmap, directory, max_side, quality, min_side):
    plan = _scaled_size(bitmap.width, bitmap.height, max_side, min_side)
    if plan is None:
        return None
    w, h, resize = plan
    scaled = bitmap
    if resize:
        scaled = _ayu_images.new("image.resize", {"image": bitmap.require(), "width": w, "height": h, "filter": "bilinear"})
    location = tlrpc.TL_fileLocationToBeDeprecated()
    location.volume_id, location.dc_id, location.local_id = _VOLUME, _VOLUME, _local_id(directory)
    location.file_reference = b""
    size = tlrpc.TL_photoSize()
    size.location, size.w, size.h, size.type = location, scaled.width, scaled.height, _type(scaled.width, scaled.height)
    path = os.path.join(directory, f"{location.volume_id}_{location.local_id}.jpg")
    size.size = _ayu_images.encode_to_path(scaled, "JPEG", path, quality)
    return size


def generate(tlrpc, path, directory, current_time):
    """The ``TL_photo`` of ``generatePhotoSizes(path, null)``; None where Android returns null."""
    from ayu_bridge import BridgeError
    if path is None:
        return None
    try:
        bitmap, info = _ayu_images.decode(os.fspath(path))
    except BridgeError as error:
        if error.code in ("io_error", "image_format"):
            return None  # ``ImageLoader.loadBitmap`` gives null for a file it cannot read
        raise
    turn = _TURNS.get(info.get("orientation"))
    if turn is not None:
        bitmap = _ayu_images.new("image.transpose", {"image": bitmap.require(), "method": turn})
    bitmap = _opaque(bitmap)
    os.makedirs(directory, exist_ok=True)
    sizes = [size for size in (_save(tlrpc, bitmap, directory, 90, 55, 0),
                               _save(tlrpc, bitmap, directory, PHOTO_SIZE, 80, 101)) if size is not None]
    if not sizes:
        return None
    photo = tlrpc.TL_photo()
    photo.date, photo.sizes, photo.file_reference = current_time(), sizes, b""
    return photo
