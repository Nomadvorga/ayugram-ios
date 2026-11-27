"""``PIL.ImageFilter``: Gaussian and box blur, the 3x3 and 5x5 kernel presets, rank filters and unsharp masking.

The host filters every band on its own, alpha included, with Pillow's kernels, border rule
(pixels the kernel cannot cover are copied) and rounding.
"""
from __future__ import annotations

from . import _host


class Filter:
    def filter(self, image):
        raise NotImplementedError


class MultibandFilter(Filter):
    pass


class BuiltinFilter(MultibandFilter):
    filterargs = None

    def filter(self, image):
        (width, height), scale, offset, kernel = self.filterargs
        if width != height or width not in (3, 5) or len(kernel) != width * height:
            raise ValueError("not a 3x3 or 5x5 kernel")
        return image._new("image.filter", {"image": image._id(), "kind": "kernel", "size": width,
                                           "kernel": [float(value) for value in kernel], "scale": float(scale), "offset": float(offset)})


class Kernel(BuiltinFilter):
    """A 3x3 or 5x5 convolution kernel; ``scale`` defaults to the sum of the weights."""
    name = "Kernel"

    def __init__(self, size, kernel, scale=None, offset=0):
        kernel = list(kernel)
        if scale is None:
            scale = sum(kernel)
        if size[0] * size[1] != len(kernel):
            raise ValueError("not enough coefficients in kernel")
        self.filterargs = tuple(size), scale, offset, kernel


class RankFilter(Filter):
    name = "Rank"

    def __init__(self, size, rank):
        self.size = size
        self.rank = rank

    def filter(self, image):
        return image._new("image.filter", {"image": image._id(), "kind": "rank", "size": int(self.size), "rank": int(self.rank)})


class MedianFilter(RankFilter):
    name = "Median"

    def __init__(self, size=3):
        self.size = size
        self.rank = size * size // 2


class MinFilter(RankFilter):
    name = "Min"

    def __init__(self, size=3):
        self.size = size
        self.rank = 0


class MaxFilter(RankFilter):
    name = "Max"

    def __init__(self, size=3):
        self.size = size
        self.rank = size * size - 1


def _radius(radius):
    if isinstance(radius, (int, float)):
        return float(radius)
    x, y = radius
    return [float(x), float(y)]


class GaussianBlur(MultibandFilter):
    """Three box blurs that approximate a Gaussian of the given standard deviation, as in Pillow."""
    name = "GaussianBlur"

    def __init__(self, radius=2):
        self.radius = radius

    def filter(self, image):
        radius = _radius(self.radius)
        if radius in (0.0, [0.0, 0.0]):
            return image.copy()
        return image._new("image.filter", {"image": image._id(), "kind": "gaussian_blur", "radius": radius})


class BoxBlur(MultibandFilter):
    name = "BoxBlur"

    def __init__(self, radius):
        values = (radius, radius) if isinstance(radius, (int, float)) else tuple(radius)
        if values[0] < 0 or values[1] < 0:
            raise ValueError("radius must be >= 0")
        self.radius = radius

    def filter(self, image):
        radius = _radius(self.radius)
        if radius in (0.0, [0.0, 0.0]):
            return image.copy()
        return image._new("image.filter", {"image": image._id(), "kind": "box_blur", "radius": radius})


class UnsharpMask(MultibandFilter):
    name = "UnsharpMask"

    def __init__(self, radius=2, percent=150, threshold=3):
        self.radius = radius
        self.percent = percent
        self.threshold = threshold

    def filter(self, image):
        return image._new("image.filter", {"image": image._id(), "kind": "unsharp", "radius": _radius(self.radius),
                                           "percent": int(self.percent), "threshold": int(self.threshold)})


class BLUR(BuiltinFilter):
    name = "Blur"
    filterargs = (5, 5), 16, 0, (1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1, 1)


class CONTOUR(BuiltinFilter):
    name = "Contour"
    filterargs = (3, 3), 1, 255, (-1, -1, -1, -1, 8, -1, -1, -1, -1)


class DETAIL(BuiltinFilter):
    name = "Detail"
    filterargs = (3, 3), 6, 0, (0, -1, 0, -1, 10, -1, 0, -1, 0)


class EDGE_ENHANCE(BuiltinFilter):
    name = "Edge-enhance"
    filterargs = (3, 3), 2, 0, (-1, -1, -1, -1, 10, -1, -1, -1, -1)


class EDGE_ENHANCE_MORE(BuiltinFilter):
    name = "Edge-enhance More"
    filterargs = (3, 3), 1, 0, (-1, -1, -1, -1, 9, -1, -1, -1, -1)


class EMBOSS(BuiltinFilter):
    name = "Emboss"
    filterargs = (3, 3), 1, 128, (-1, 0, 0, 0, 1, 0, 0, 0, 0)


class FIND_EDGES(BuiltinFilter):
    name = "Find Edges"
    filterargs = (3, 3), 1, 0, (-1, -1, -1, -1, 8, -1, -1, -1, -1)


class SHARPEN(BuiltinFilter):
    name = "Sharpen"
    filterargs = (3, 3), 16, 0, (-2, -2, -2, -2, 32, -2, -2, -2, -2)


class SMOOTH(BuiltinFilter):
    name = "Smooth"
    filterargs = (3, 3), 13, 0, (1, 1, 1, 1, 5, 1, 1, 1, 1)


class SMOOTH_MORE(BuiltinFilter):
    name = "Smooth More"
    filterargs = (5, 5), 100, 0, (1, 1, 1, 1, 1, 1, 5, 5, 5, 1, 1, 5, 44, 5, 1, 1, 5, 5, 5, 1, 1, 1, 1, 1, 1)
