"""A subset of the Pillow API over the host image service.

This is not Pillow. Pillow's decoders, resamplers and rasterizers are C extensions, which
this runtime cannot load; here every image is a handle to pixels the native host owns
(``_ayu_images``, ``protocol-images.md``), and each call below is one host operation or a
few. The names, argument conventions, modes and coordinate rules follow Pillow (HPND
license, Copyright 1997-2011 Secret Labs AB, 1995-2011 Fredrik Lundh, 2010 Jeffrey A. Clark
and contributors), and so does the arithmetic the host uses for conversion, pasting,
compositing, resampling and filtering. What Pillow has and this package lacks is absent
or raises ``UnsupportedAPI``; nothing is approximated silently. See "PIL" in
``protocol-images.md`` for the exact subset and the known rendering differences.
"""
# The Pillow release whose API and results this subset follows (see Build/generate_pil_reference.py).
__version__ = "13.0.0"


class UnidentifiedImageError(OSError):
    """Raised by ``Image.open`` for data the host cannot identify as a supported image."""
