"""``PIL.ImageEnhance``: ``Color``, ``Contrast``, ``Brightness`` and ``Sharpness``.

``enhance(factor)`` blends a degenerate image with the original: 0 gives the degenerate
image, 1 the original, larger factors extrapolate and clip.
"""
from __future__ import annotations

from . import Image, ImageFilter


class _Enhance:
    image = None
    degenerate = None

    def _keep_alpha(self):
        if "A" in self.image.getbands():
            self.degenerate.putalpha(self.image.getchannel("A"))

    def enhance(self, factor):
        return Image.blend(self.degenerate, self.image, factor)


class Color(_Enhance):
    def __init__(self, image):
        self.image = image
        self.intermediate_mode = "LA" if "A" in image.getbands() else "L"
        self.degenerate = image.convert(self.intermediate_mode).convert(image.mode)


class Contrast(_Enhance):
    def __init__(self, image):
        self.image = image
        histogram = image.convert("L").histogram()
        total = sum(histogram)
        mean = int(sum(index * count for index, count in enumerate(histogram)) / total + 0.5)
        self.degenerate = Image.new("L", image.size, mean).convert(image.mode)
        self._keep_alpha()


class Brightness(_Enhance):
    def __init__(self, image):
        self.image = image
        self.degenerate = Image.new(image.mode, image.size, 0)
        self._keep_alpha()


class Sharpness(_Enhance):
    def __init__(self, image):
        self.image = image
        self.degenerate = image.filter(ImageFilter.SMOOTH)
        self._keep_alpha()
