"""Calls into the host image service with Pillow's exception types."""
from __future__ import annotations

import _ayu_images


def translate(error):
    """The exception Pillow raises where the host reports ``error``."""
    from . import UnidentifiedImageError
    code = getattr(error, "code", None)
    message = getattr(error, "message", str(error))
    if code == "INVALID_ARGUMENTS":
        return ValueError(message)
    if code == "IO_ERROR":
        return OSError(message)
    if code == "IMAGE_FORMAT":
        return UnidentifiedImageError(message)
    return error


def call(operation, arguments):
    from ayu_bridge import BridgeError
    try:
        return _ayu_images.call(operation, arguments)
    except BridgeError as error:
        translated = translate(error)
        if translated is error:
            raise
        raise translated from None


def new(operation, arguments):
    return _ayu_images.Handle(call(operation, arguments))


def unsupported(feature):
    from ayu_bridge import UnsupportedAPI
    return UnsupportedAPI("PIL: " + feature + " is not provided")
