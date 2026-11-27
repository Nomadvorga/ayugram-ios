"""``PIL.ImageOps``: the operations the plugin corpus uses, with Pillow's definitions."""
from __future__ import annotations

from . import Image, ImageColor


def _lut(image, lut):
    if image.mode not in ("L", "RGB"):
        raise OSError(f"not supported for mode {image.mode}")
    if image.mode == "RGB" and len(lut) == 256:
        lut = lut + lut + lut
    return image.point(lut)


def _color(color, mode):
    return ImageColor.getcolor(color, mode) if isinstance(color, str) else color


def grayscale(image):
    return image.convert("L")


def invert(image):
    return _lut(image, list(range(255, -1, -1)))


def mirror(image):
    """Flip left to right."""
    return image.transpose(Image.Transpose.FLIP_LEFT_RIGHT)


def flip(image):
    """Flip top to bottom."""
    return image.transpose(Image.Transpose.FLIP_TOP_BOTTOM)


def posterize(image, bits):
    """Keep the ``bits`` most significant bits of every band."""
    mask = ~(2 ** (8 - bits) - 1)
    return _lut(image, [index & mask for index in range(256)])


def solarize(image, threshold=128):
    """Invert every value at or above ``threshold``."""
    return _lut(image, [index if index < threshold else 255 - index for index in range(256)])


def autocontrast(image, cutoff=0, ignore=None, mask=None, preserve_tone=False):
    """Stretch each band so its darkest remaining value is 0 and its lightest 255."""
    if mask is not None:
        from ._host import unsupported
        raise unsupported("autocontrast() with a mask")
    histogram = image.convert("L").histogram() if preserve_tone else image.histogram()
    lut = []
    for layer in range(0, len(histogram), 256):
        h = histogram[layer:layer + 256]
        if ignore is not None:
            for index in ([ignore] if isinstance(ignore, int) else ignore):
                h[index] = 0
        if cutoff:
            if not isinstance(cutoff, tuple):
                cutoff = (cutoff, cutoff)
            total = sum(h)
            for share, order in ((cutoff[0], range(256)), (cutoff[1], range(255, -1, -1))):
                cut = int(total * share // 100)
                for index in order:
                    if cut > h[index]:
                        cut -= h[index]
                        h[index] = 0
                    else:
                        h[index] -= cut
                        cut = 0
                    if cut <= 0:
                        break
        low = next((index for index in range(256) if h[index]), 255)
        high = next((index for index in range(255, -1, -1) if h[index]), 0)
        if high <= low:
            lut.extend(range(256))
        else:
            scale = 255.0 / (high - low)
            offset = -low * scale
            lut.extend(max(0, min(255, int(index * scale + offset))) for index in range(256))
    return _lut(image, lut)


def colorize(image, black, white, mid=None, blackpoint=0, whitepoint=255, midpoint=127):
    """Map an ``L`` image onto a ramp from ``black`` to ``white`` (through ``mid``); returns ``RGB``."""
    if image.mode != "L":
        raise ValueError(f"mode must be L, not {image.mode}")
    if not 0 <= blackpoint <= whitepoint <= 255:
        raise ValueError("blackpoint and whitepoint must each be between or equal to 0 and 255, "
                         "with blackpoint less than or equal to whitepoint")
    if mid is not None and not blackpoint <= midpoint <= whitepoint:
        raise ValueError("midpoint must be between or equal to blackpoint and whitepoint")
    rgb_black, rgb_white = _color(black, "RGB"), _color(white, "RGB")
    rgb_mid = _color(mid, "RGB") if mid is not None else None
    channels = ([], [], [])

    def ramp(start, stop, steps):
        for index in range(steps):
            for channel in range(3):
                channels[channel].append(start[channel] + index * (stop[channel] - start[channel]) // steps)

    for channel in range(3):
        channels[channel].extend([rgb_black[channel]] * blackpoint)
    if rgb_mid is None:
        ramp(rgb_black, rgb_white, whitepoint - blackpoint)
    else:
        ramp(rgb_black, rgb_mid, midpoint - blackpoint)
        ramp(rgb_mid, rgb_white, whitepoint - midpoint)
    for channel in range(3):
        channels[channel].extend([rgb_white[channel]] * (256 - whitepoint))
    return _lut(image.convert("RGB"), channels[0] + channels[1] + channels[2])


def fit(image, size, method=Image.Resampling.BICUBIC, bleed=0.0, centering=(0.5, 0.5)):
    """Crop to the aspect ratio of ``size`` around ``centering`` and resize to ``size``."""
    centering_x, centering_y = centering
    if not 0.0 <= centering_x <= 1.0:
        centering_x = 0.5
    if not 0.0 <= centering_y <= 1.0:
        centering_y = 0.5
    if not 0.0 <= bleed < 0.5:
        bleed = 0.0
    bleed_pixels = (bleed * image.size[0], bleed * image.size[1])
    live = (image.size[0] - bleed_pixels[0] * 2, image.size[1] - bleed_pixels[1] * 2)
    live_ratio = live[0] / live[1]
    output_ratio = size[0] / size[1]
    if live_ratio == output_ratio:
        crop_width, crop_height = live
    elif live_ratio >= output_ratio:
        crop_width, crop_height = output_ratio * live[1], live[1]
    else:
        crop_width, crop_height = live[0], live[0] / output_ratio
    crop_left = bleed_pixels[0] + (live[0] - crop_width) * centering_x
    crop_top = bleed_pixels[1] + (live[1] - crop_height) * centering_y
    return image.resize(size, method, box=(crop_left, crop_top, crop_left + crop_width, crop_top + crop_height))


def exif_transpose(image, *, in_place=False):
    """Apply the orientation the file declared, so the pixels are upright."""
    method = {2: Image.Transpose.FLIP_LEFT_RIGHT, 3: Image.Transpose.ROTATE_180, 4: Image.Transpose.FLIP_TOP_BOTTOM,
              5: Image.Transpose.TRANSPOSE, 6: Image.Transpose.ROTATE_270, 7: Image.Transpose.TRANSVERSE,
              8: Image.Transpose.ROTATE_90}.get(image._orientation)
    if in_place:
        if method is not None:
            image._adopt(image.transpose(method))
            image._orientation = 1
        return None
    result = image.copy() if method is None else image.transpose(method)
    result._orientation = 1
    return result
