"""``PIL.ImageChops``: ``difference``, ``multiply``, ``add``, ``subtract`` and ``offset``.

The two images must have the same mode; the result covers their common area.
"""
from __future__ import annotations


def _chop(kind, image1, image2, scale=1.0, offset=0):
    if image1.mode != image2.mode:
        raise ValueError("images do not match")
    return image1._new("image.chop", {"image": image1._id(), "source": image2._id(), "kind": kind,
                                      "scale": float(scale), "offset": float(offset)})


def difference(image1, image2):
    """``abs(image1 - image2)``."""
    return _chop("difference", image1, image2)


def multiply(image1, image2):
    """``image1 * image2 / 255``."""
    return _chop("multiply", image1, image2)


def add(image1, image2, scale=1.0, offset=0):
    """``(image1 + image2) / scale + offset``, clipped."""
    return _chop("add", image1, image2, scale, offset)


def subtract(image1, image2, scale=1.0, offset=0):
    """``(image1 - image2) / scale + offset``, clipped."""
    return _chop("subtract", image1, image2, scale, offset)


def offset(image, xoffset, yoffset=None):
    """Shift the image; what leaves one edge enters at the opposite one."""
    if yoffset is None:
        yoffset = xoffset
    return image._new("image.chop", {"image": image._id(), "kind": "offset", "dx": int(xoffset), "dy": int(yoffset)})
