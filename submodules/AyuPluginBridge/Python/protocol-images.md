# AyuPluginBridge image service contract

This document specifies the `image.*` operations shared by the bounded Pillow-compatible
facade (`Python/PIL/`) and the Android bitmap/Canvas facade
(`Python/_ayu_javalib/android_bitmap.py`). This is a limited image API, not a complete
Pillow or Android graphics implementation. The host declares these operations only when
the corresponding image service is installed.

## Ownership, limits and pixels

Image and font handles are opaque, scoped to the calling plugin generation, and cannot be
used by another plugin. `image.release` frees explicitly released handles; ending or
replacing a generation drops all of its images, fonts and pending view snapshots. Image
pixels stay in the host except for explicit pixel reads/writes; encoded image files are
passed by path rather than embedded in JSON.

Pixels are 8-bit, interleaved, top-to-bottom, with straight (not premultiplied) alpha.
Supported modes are `L`, `LA`, `RGB` and `RGBA`; their band counts are 1, 2, 3 and 4.
The default image bounds are 64 live images, 128 MiB of pixel storage, at most 16,777,216
pixels per image, and at most 16,384 pixels on either side. The default font bound is 32
per generation; font files are limited to 64 MiB. A pixel transfer is at most 131,072 raw
bytes, a draw request at most 256 commands, text at most 16,384 UTF-8 bytes and a path at
most 4,096 points. Pending image snapshots for native views are bounded to 256 per
generation. These quotas are configurable host limits and may be lowered; exceeding one
fails with `resource_limit`.

Malformed arguments, mismatched modes/sizes and out-of-range values fail with
`invalid_arguments`. An unsupported filter, transform or image feature fails explicitly;
unknown operations are not treated as successful no-ops. Paths and file access are
validated by the host and remain subject to the app's file-access policy.

## Operations

Every operation receives a closed JSON argument object. The names below are the complete
image-service operation set; see `Python/_ayu_images.py` and
`Sources/AyuBridgeImages.swift` for the validated request fields and value shapes.

| Operation | Purpose |
|---|---|
| `image.create` | Allocate a filled image in one of the supported modes. |
| `image.decode` | Decode encoded bytes or a file path; optional bounds-only mode reads metadata without allocating pixels. |
| `image.encode` | Encode an owned image to a file path in a supported format, with bounded quality. |
| `image.release` | Release lists of image and/or font handles owned by the caller. |
| `image.copy` | Make an independently owned image copy. |
| `image.convert` | Convert an image to a supported pixel mode. |
| `image.band` | Extract one channel as a grayscale image. |
| `image.merge` | Merge same-sized grayscale bands into a supported mode. |
| `image.putalpha` | Replace/add an alpha channel using a constant or same-sized grayscale image. |
| `image.pixels.get` | Read a bounded rectangle of raw pixel bytes, returned as base64. |
| `image.pixels.put` | Write exactly sized raw pixel bytes into a bounded rectangle. |
| `image.point` | Apply a bounded lookup table to image channels. |
| `image.stats` | Return bounded image statistics for a requested supported statistic. |
| `image.crop` | Return a cropped image for a bounded rectangle. |
| `image.resize` | Resize with a supported resampling filter and optional source box. |
| `image.transpose` | Apply a supported transpose/rotation operation. |
| `image.transform` | Apply a bounded affine transform with a supported filter and fill color. |
| `image.paste` | Paste a same-mode image, or a color through a mask, into an owned image. |
| `image.alpha_composite` | Alpha-composite two equal-sized `RGBA` images into a new image. |
| `image.blend` | Blend equal-sized, same-mode images by a bounded alpha value. |
| `image.chop` | Apply supported difference, multiply, subtract, add or offset operations. |
| `image.filter` | Apply one of the explicitly implemented image filters. |
| `image.draw` | Draw a bounded list of validated commands into an owned image. Java `Paint`/`Path` values are resolved as typed, owned references. |
| `image.font.load` | Load a bounded system or app-accessible font and return its metrics and an owned handle. |
| `image.font.measure` | Measure bounded text with an owned font and optional bounded stroke width. |

The Pillow and Android facades expose only the subsets backed by these operations. Unsupported
Pillow methods and Android drawing APIs raise an explicit unsupported-API error; a clean
static preflight does not establish runtime compatibility for every image operation.
