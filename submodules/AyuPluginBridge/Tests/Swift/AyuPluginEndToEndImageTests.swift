import Foundation
import ImageIO
import XCTest
@testable import AyuPluginBridge

/// The image service behind its two SDK facades, used by synthetic plugins through the real
/// interpreter and the real SDK: the `PIL` package, checked against values the real Pillow
/// produced for the same code (`Build/generate_pil_reference.py`), and the Android bitmap classes.
@MainActor
final class AyuPluginEndToEndImageTests: XCTestCase {
    // BEGIN PILLOW CASES
    static let pillowCases = #"""
    def pillow_cases(record, workdir, font_path):
        import base64, io, os
        from PIL import Image, ImageChops, ImageColor, ImageDraw, ImageEnhance, ImageFilter, ImageFont, ImageOps

        def gradient(mode, width=48, height=36):
            image = Image.new(mode, (width, height))
            if mode == "L":
                data = [(x * 5 + y * 3) % 256 for y in range(height) for x in range(width)]
            elif mode == "RGB":
                data = [((x * 5) % 256, (y * 7) % 256, (x * y) % 256) for y in range(height) for x in range(width)]
            else:
                data = [((x * 5) % 256, (y * 7) % 256, (x * y) % 256, (x * 9 + y * 4) % 256) for y in range(height) for x in range(width)]
            image.putdata(data)
            return image

        def grid(image, columns=5, rows=4):
            width, height = image.size
            return [image.getpixel(((2 * i + 1) * width // (2 * columns), (2 * j + 1) * height // (2 * rows)))
                    for j in range(rows) for i in range(columns)]

        def describe(image):
            return [image.mode, list(image.size)]

        def ink_count(image):
            histogram = image.histogram()
            return sum(histogram[1:256])

        rgb, rgba, gray = gradient("RGB"), gradient("RGBA"), gradient("L")

        # Modes and colors
        record("new_colors", [Image.new("RGB", (2, 2), "white").getpixel((0, 0)), Image.new("RGB", (2, 2), 255).getpixel((1, 1)),
                              Image.new("RGBA", (2, 2)).getpixel((0, 0)), Image.new("L", (2, 2), 7).getpixel((0, 0)),
                              Image.new("RGB", (2, 2), (1, 2, 3)).getpixel((1, 0)), Image.new("RGBA", (2, 2), (9, 8, 7)).getpixel((0, 1)),
                              Image.new("RGBA", (2, 2), "#10203040").getpixel((0, 0)), Image.new("L", (2, 2), "red").getpixel((0, 0))])
        record("color_strings", [ImageColor.getrgb("rgb(10%, 20%, 30%)"), ImageColor.getrgb("hsl(210, 50%, 40%)"), ImageColor.getcolor("#abc", "RGBA"),
                                 ImageColor.getcolor("gold", "L"), ImageColor.getrgb("hsv(30, 80%, 90%)")])
        for mode in ("L", "LA", "RGB", "RGBA"):
            record("convert_rgba_" + mode, describe(rgba.convert(mode)) + grid(rgba.convert(mode), 4, 3))
            record("convert_l_" + mode, describe(gray.convert(mode)) + grid(gray.convert(mode), 4, 3))
        record("bands", [rgba.getbands(), [band.mode for band in rgba.split()], grid(rgba.getchannel("A"), 4, 2), grid(rgba.getchannel(1), 4, 2),
                         describe(Image.merge("RGB", rgba.split()[:3])), grid(Image.merge("RGBA", list(reversed(rgba.split()))), 4, 2)])

        # Geometry
        for name in ("NEAREST", "BOX", "BILINEAR", "HAMMING", "BICUBIC", "LANCZOS"):
            resample = getattr(Image.Resampling, name)
            record("resize_down_" + name, describe(rgb.resize((17, 11), resample)) + grid(rgb.resize((17, 11), resample)))
            record("resize_up_" + name, grid(rgb.resize((90, 70), resample)))
            record("resize_alpha_" + name, grid(rgba.resize((20, 30), resample)))
        record("resize_default", grid(gray.resize((20, 15))))
        record("resize_legacy_names", [int(Image.LANCZOS), int(Image.BICUBIC), int(Image.NEAREST), int(Image.BILINEAR), grid(gray.resize((10, 10), Image.LANCZOS), 3, 3)])
        record("resize_box", grid(rgb.resize((20, 20), Image.Resampling.BILINEAR, box=(4.5, 3.25, 40.0, 30.5))))
        record("crop", [describe(rgb.crop((5, 6, 25, 20))), grid(rgb.crop((5, 6, 25, 20)), 3, 3), describe(rgb.crop((-4, -4, 10, 10))),
                        rgb.crop((-4, -4, 10, 10)).getpixel((0, 0)), rgb.crop((-4, -4, 10, 10)).getpixel((5, 5)), rgb.crop((40, 30, 60, 50)).getpixel((10, 10))])
        for name in ("FLIP_LEFT_RIGHT", "FLIP_TOP_BOTTOM", "ROTATE_90", "ROTATE_180", "ROTATE_270", "TRANSPOSE", "TRANSVERSE"):
            out = rgb.transpose(getattr(Image.Transpose, name))
            record("transpose_" + name, describe(out) + grid(out, 3, 3) + [out.getpixel((0, 0)), out.getpixel((out.width - 1, 0))])
        record("rotate_sizes", [describe(rgb.rotate(90, expand=True)), describe(rgb.rotate(90)), describe(rgb.rotate(45, expand=True)),
                                describe(rgb.rotate(30)), describe(rgb.rotate(180)), describe(rgb.rotate(-17.5, expand=1))])
        record("rotate_90", grid(rgb.rotate(90, expand=True), 3, 3))
        record("rotate_30_nearest", grid(rgb.rotate(30), 3, 3))
        record("rotate_30_bilinear", grid(rgb.rotate(30, Image.Resampling.BILINEAR, expand=True, fillcolor=(9, 9, 9)), 4, 4))
        record("rotate_30_bicubic", grid(rgba.rotate(30, Image.Resampling.BICUBIC), 3, 3))
        record("transform_affine", grid(rgb.transform((40, 30), Image.Transform.AFFINE, (0.9, 0.2, 3.0, -0.1, 1.1, 2.0), Image.Resampling.BILINEAR), 4, 3))
        record("transform_affine_nearest", grid(rgb.transform((40, 30), Image.Transform.AFFINE, (1.0, 0.0, -5.0, 0.0, 1.0, -4.0)), 4, 3))
        sizes = []
        for size, box in (((48, 36), (20, 20)), ((48, 36), (100, 10)), ((36, 48), (20, 20)), ((100, 30), (33, 33)), ((7, 300), (5, 64)), ((48, 36), (400, 400))):
            image = Image.new("L", size)
            image.thumbnail(box)
            sizes.append(list(image.size))
        record("thumbnail_sizes", sizes)
        thumb = rgb.copy()
        thumb.thumbnail((20, 20), Image.Resampling.LANCZOS)
        record("thumbnail_pixels", grid(thumb, 3, 3))

        # Compositing
        mask = Image.new("L", (20, 14), 0)
        mask.putdata([(x * 13 + y * 5) % 256 for y in range(14) for x in range(20)])
        patch = Image.new("RGB", (20, 14), (250, 10, 120))
        target = rgb.copy(); target.paste(patch, (10, 8))
        record("paste_plain", grid(target))
        target = rgb.copy(); target.paste(patch, (10, 8), mask)
        record("paste_mask", grid(target))
        target = rgb.copy(); target.paste(patch, (-6, -5), mask)
        record("paste_negative", grid(target))
        target = rgb.copy(); target.paste(patch, (40, 30))
        record("paste_clipped", grid(target))
        target = rgba.copy(); target.paste((1, 2, 3, 200), (4, 4), mask)
        record("paste_color_mask", grid(target))
        target = rgb.copy(); target.paste((255, 255, 0), (3, 4, 30, 20))
        record("paste_color_box", grid(target))
        overlay = Image.new("RGBA", (20, 14), (0, 200, 100, 90))
        target = rgba.copy(); target.paste(overlay, (12, 9), overlay)
        record("paste_rgba_mask", grid(target))
        target = rgb.copy(); target.paste(overlay, (12, 9))
        record("paste_rgba_into_rgb", grid(target))
        other = gradient("RGBA").transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        record("alpha_composite", grid(Image.alpha_composite(rgba, other)))
        target = rgba.copy(); target.alpha_composite(overlay, (5, 6))
        record("alpha_composite_method", grid(target))
        record("blend", [grid(Image.blend(rgb, rgb.transpose(Image.Transpose.FLIP_TOP_BOTTOM), 0.3), 4, 3),
                         grid(Image.blend(rgb, rgb.transpose(Image.Transpose.FLIP_TOP_BOTTOM), 1.7), 4, 3)])
        wide_mask = gray.resize(rgb.size)
        record("composite", grid(Image.composite(rgb, rgb.transpose(Image.Transpose.ROTATE_180), wide_mask)))
        target = rgb.copy(); target.putalpha(77)
        record("putalpha_int", describe(target) + grid(target, 3, 2))
        target = rgb.copy(); target.putalpha(gray)
        record("putalpha_image", describe(target) + grid(target, 3, 2))
        target = rgba.copy(); target.putalpha(200)
        record("putalpha_existing", grid(target, 3, 2))

        # Filters
        filters = {"gaussian_2": ImageFilter.GaussianBlur(2), "gaussian_5_5": ImageFilter.GaussianBlur(radius=5.5), "gaussian_30": ImageFilter.GaussianBlur(30),
                   "gaussian_0_4": ImageFilter.GaussianBlur(0.4), "box_3": ImageFilter.BoxBlur(3), "blur": ImageFilter.BLUR, "contour": ImageFilter.CONTOUR,
                   "detail": ImageFilter.DETAIL, "edge_enhance": ImageFilter.EDGE_ENHANCE, "edge_enhance_more": ImageFilter.EDGE_ENHANCE_MORE,
                   "emboss": ImageFilter.EMBOSS, "find_edges": ImageFilter.FIND_EDGES, "sharpen": ImageFilter.SHARPEN, "smooth": ImageFilter.SMOOTH,
                   "smooth_more": ImageFilter.SMOOTH_MORE, "median": ImageFilter.MedianFilter(3), "max": ImageFilter.MaxFilter(3), "min": ImageFilter.MinFilter(5),
                   "unsharp": ImageFilter.UnsharpMask(radius=2, percent=160, threshold=3), "kernel": ImageFilter.Kernel((3, 3), (1, 0, -1, 2, 0, -2, 1, 0, -1), 1, 128)}
        for name, value in filters.items():
            record("filter_" + name, grid(rgb.filter(value)) + [rgb.filter(value).getpixel((0, 0)), rgb.filter(value).getpixel((47, 35))])
        record("filter_alpha", grid(rgba.filter(ImageFilter.GaussianBlur(3))) + grid(gray.filter(ImageFilter.SHARPEN), 4, 2))

        # ImageOps, ImageEnhance, ImageChops, point
        record("ops_basic", [grid(ImageOps.invert(rgb), 3, 2), grid(ImageOps.grayscale(rgb), 3, 2), grid(ImageOps.mirror(rgb), 3, 2), grid(ImageOps.flip(rgb), 3, 2),
                             grid(ImageOps.posterize(rgb, 2), 3, 2), grid(ImageOps.solarize(rgb, threshold=100), 3, 2)])
        low = gray.point(lambda value: 40 + value // 3)
        record("ops_autocontrast", [grid(ImageOps.autocontrast(low), 4, 3), grid(ImageOps.autocontrast(low, cutoff=1), 4, 3), grid(ImageOps.autocontrast(rgb.point(lambda v: 30 + v // 2)), 3, 2)])
        record("ops_colorize", [describe(ImageOps.colorize(gray, black="#704214", white="#C2B280")), grid(ImageOps.colorize(gray, black="#704214", white="#C2B280"), 4, 3),
                                grid(ImageOps.colorize(gray, (0, 0, 0), (255, 255, 255), mid=(255, 0, 0)), 4, 3)])
        record("ops_fit", [describe(ImageOps.fit(rgb, (20, 20), Image.Resampling.LANCZOS)), grid(ImageOps.fit(rgb, (20, 20), Image.Resampling.LANCZOS), 3, 3),
                           grid(ImageOps.fit(rgb, (30, 10), Image.Resampling.LANCZOS, centering=(0.0, 1.0)), 3, 3), grid(ImageOps.fit(rgb, (16, 40)), 3, 3)])
        record("enhance", [grid(ImageEnhance.Contrast(rgb).enhance(1.5), 3, 3), grid(ImageEnhance.Brightness(rgb).enhance(0.32), 3, 3),
                           grid(ImageEnhance.Color(rgb).enhance(0.3), 3, 3), grid(ImageEnhance.Sharpness(rgb).enhance(2.0), 3, 3),
                           grid(ImageEnhance.Contrast(rgba).enhance(0.5), 3, 3), grid(ImageEnhance.Color(rgba).enhance(1.8), 3, 3)])
        flipped = rgb.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        record("chops", [grid(ImageChops.difference(rgb, flipped), 3, 3), grid(ImageChops.multiply(rgb, flipped), 3, 3), grid(ImageChops.subtract(rgb, flipped), 3, 3),
                         grid(ImageChops.subtract(rgb, flipped, 2.0, 60), 3, 3), grid(ImageChops.add(rgb, flipped, 2.0), 3, 3),
                         grid(ImageChops.offset(rgb, 3, 4), 3, 3), grid(ImageChops.offset(rgb, -2, -2), 3, 3), grid(ImageChops.offset(gray, 50), 3, 3)])
        record("point", [grid(rgb.point(lambda value: value * 1.5), 3, 3), grid(gray.point([255 - index for index in range(256)]), 3, 3)])
        sparse = Image.new("RGBA", (30, 20), (0, 0, 0, 0))
        sparse.paste((5, 6, 7, 255), (4, 3, 11, 9))
        record("stats", [sparse.getbbox(), Image.new("L", (5, 5)).getbbox(), gray.getextrema(), rgb.getextrema(), sorted(sparse.getcolors()),
                         Image.new("RGB", (3, 3), "red").getcolors(), rgb.getcolors(8), gray.histogram()[:12], len(rgb.histogram()), sum(rgba.histogram()[768:])])
        access = rgb.load()
        before = access[3, 4]
        access[3, 4] = (1, 2, 3)
        probe = gray.copy()
        probe.putpixel((2, 2), 99)
        record("pixels", [before, access[3, 4], rgb.getpixel((3, 4)), probe.getpixel((2, 2)), list(gray.getdata())[:6], list(rgba.getdata())[50:52],
                          len(rgb.tobytes()), list(rgb.tobytes()[:6]), list(rgba.getdata(3))[:4]])

        # Drawing geometry (shapes are not anti-aliased)
        def canvas():
            image = Image.new("L", (80, 60), 0)
            return image, ImageDraw.Draw(image)

        shapes = {}
        image, draw = canvas(); draw.rectangle([10, 20, 50, 40], fill=255); shapes["rect_fill"] = [image.getbbox(), ink_count(image)]
        image, draw = canvas(); draw.rectangle([(10.6, 20.4), (50.5, 40.9)], outline=255, width=3); shapes["rect_outline"] = [image.getbbox(), ink_count(image), image.getpixel((12, 30)), image.getpixel((13, 30))]
        image, draw = canvas(); draw.rectangle([10, 20, 50, 40], fill=100, outline=200); shapes["rect_both"] = [image.getpixel((10, 20)), image.getpixel((11, 21)), image.getpixel((50, 40)), ink_count(image)]
        image, draw = canvas(); draw.rectangle([10, 20, 50, 40]); shapes["rect_default"] = [image.getbbox(), ink_count(image), image.getpixel((10, 30)), image.getpixel((30, 30))]
        image, draw = canvas(); draw.ellipse([10, 20, 50, 40], fill=255); shapes["ellipse_fill"] = [image.getbbox(), ink_count(image), image.getpixel((30, 30)), image.getpixel((12, 22)), image.getpixel((10, 30)), image.getpixel((30, 20))]
        image, draw = canvas(); draw.ellipse([10, 20, 50, 40], outline=255, width=3); shapes["ellipse_outline"] = [image.getbbox(), ink_count(image), image.getpixel((30, 30)), image.getpixel((11, 30))]
        image, draw = canvas(); draw.ellipse((5, 5, 55, 55), fill=255); shapes["circle"] = [image.getbbox(), ink_count(image)]
        image, draw = canvas(); draw.rounded_rectangle([10, 20, 50, 40], radius=6, fill=255); shapes["round_fill"] = [image.getbbox(), ink_count(image), image.getpixel((10, 20)), image.getpixel((16, 20)), image.getpixel((10, 26)), image.getpixel((12, 22))]
        image, draw = canvas(); draw.rounded_rectangle([10, 20, 50, 40], radius=6, outline=255, width=2); shapes["round_outline"] = [image.getbbox(), ink_count(image), image.getpixel((30, 30)), image.getpixel((11, 30)), image.getpixel((12, 30))]
        image, draw = canvas(); draw.rounded_rectangle((4, 4, 70, 50), radius=18, fill=255, outline=128, width=4); shapes["round_both"] = [image.getbbox(), ink_count(image), image.getpixel((37, 6)), image.getpixel((37, 9)), image.getpixel((37, 27))]
        for width in (0, 1, 2, 3, 4, 5):
            image, draw = canvas(); draw.line([(10, 20), (50, 20)], fill=255, width=width); shapes["hline_%d" % width] = [image.getbbox(), ink_count(image)]
            image, draw = canvas(); draw.line((10, 20, 10, 40), fill=255, width=width); shapes["vline_%d" % width] = [image.getbbox(), ink_count(image)]
        image, draw = canvas(); draw.line([(10, 20), (50, 20), (50, 40)], fill=255, width=3); shapes["polyline"] = [image.getbbox(), ink_count(image)]
        image, draw = canvas(); draw.line([(10, 10), (40, 30)], fill=255); shapes["diagonal_1"] = [image.getbbox(), ink_count(image), image.getpixel((10, 10)), image.getpixel((40, 30)), image.getpixel((25, 20))]
        image, draw = canvas(); draw.line([(10, 10), (40, 30)], fill=255, width=4); shapes["diagonal_4"] = [image.getbbox(), ink_count(image), image.getpixel((25, 20))]
        image, draw = canvas(); draw.line([(5, 50), (30, 10), (70, 45)], fill=255, width=8, joint="curve"); shapes["joint"] = [image.getbbox(), ink_count(image), image.getpixel((30, 12))]
        for name, value in shapes.items():
            record("draw_" + name, value)

        # Ink semantics
        image = Image.new("RGBA", (10, 10), (10, 20, 30, 40)); ImageDraw.Draw(image).rectangle([2, 2, 5, 5], fill=(200, 100, 50, 0))
        blended = Image.new("RGB", (10, 10), (10, 20, 30)); ImageDraw.Draw(blended, "RGBA").rectangle([2, 2, 5, 5], fill=(200, 100, 50, 128))
        named = Image.new("RGB", (10, 10)); ImageDraw.Draw(named).rectangle([0, 0, 4, 4], fill="white", outline="#ff0000")
        record("draw_ink", [image.getpixel((3, 3)), image.getpixel((0, 0)), blended.getpixel((3, 3)), blended.getpixel((0, 0)), named.getpixel((2, 2)), named.getpixel((0, 0)), named.getpixel((9, 9))])

        # Files: written and read back by this implementation
        files = {}
        for mode, source in (("L", gray), ("LA", gray.convert("LA")), ("RGB", rgb), ("RGBA", rgba)):
            path = os.path.join(workdir, "roundtrip_" + mode + ".png")
            source.save(path)
            with Image.open(path) as reopened:
                files["png_" + mode] = [reopened.format, reopened.mode, list(reopened.size), grid(reopened, 4, 3)]
        buffer = io.BytesIO()
        rgba.save(buffer, format="PNG")
        files["png_stream"] = [list(buffer.getvalue()[:8]), describe(Image.open(io.BytesIO(buffer.getvalue())))]
        smooth = Image.new("RGB", (64, 64))
        smooth.putdata([(x * 3, y * 3, 128) for y in range(64) for x in range(64)])
        path = os.path.join(workdir, "smooth.jpg")
        smooth.save(path, "JPEG", quality=95)
        reopened = Image.open(path)
        files["jpeg_rgb"] = [reopened.format, reopened.mode, list(reopened.size)]
        record("jpeg_pixels", grid(reopened, 4, 4))
        buffer = io.BytesIO()
        smooth.convert("L").save(buffer, "JPEG", quality=90)
        reopened = Image.open(io.BytesIO(buffer.getvalue()))
        files["jpeg_l"] = [reopened.format, reopened.mode, list(reopened.size), list(buffer.getvalue()[:3])]
        for label, call in (("jpeg_rgba", lambda: rgba.save(os.path.join(workdir, "bad.jpg"))), ("extension", lambda: rgb.save(os.path.join(workdir, "bad.xyz"))),
                            ("format", lambda: rgb.save(io.BytesIO(), "NOPE")), ("no_format", lambda: rgb.save(io.BytesIO())),
                            ("missing", lambda: Image.open(os.path.join(workdir, "absent.png"))), ("garbage", lambda: Image.open(io.BytesIO(b"not an image at all")))):
            try:
                call()
                files["error_" + label] = "no error"
            except Exception as error:
                files["error_" + label] = type(error).__name__
        for name, value in files.items():
            record("file_" + name, value)

        # Fonts and text, with a font file both rasterizers can read
        if font_path:
            font = ImageFont.truetype(font_path, 40)
            small = ImageFont.truetype(font_path, size=14)
            draw = ImageDraw.Draw(Image.new("RGB", (400, 200)))
            record("font_metrics", [list(font.getmetrics()), list(small.getmetrics()), font.getname()[0]])
            record("font_bbox", [font.getbbox("Ay"), font.getbbox("Hello"), small.getbbox("Ay"), font.getbbox("x", anchor="ls"), font.getbbox("Ay", anchor="mm"),
                                 font.getbbox("Ay", anchor="rb"), font.getbbox("Ay", anchor="lt"), font.getbbox("Ay", anchor="ld"), font.getbbox("Ay", stroke_width=3)])
            record("font_length", [font.getlength("Hello"), small.getlength("Hello world"), draw.textlength("Ay", font=font), font.getlength("")])
            record("text_bbox", [draw.textbbox((0, 0), "Ay", font=font), draw.textbbox((50, 60), "Hello", font=font, anchor="mm"),
                                 draw.textbbox((10, 10), "one\ntwo lines", font=small), draw.multiline_textbbox((0, 0), "a\nbb\nccc", font=small, spacing=10),
                                 draw.textbbox((200, 100), "one\ntwo lines", font=small, anchor="ma", align="center")])
            image = Image.new("L", (300, 120), 0)
            ImageDraw.Draw(image).text((20, 30), "Hello", font=font, fill=255)
            record("text_drawn", [image.getbbox(), ink_count(image)])
            image = Image.new("L", (300, 120), 0)
            ImageDraw.Draw(image).text((150, 60), "Hello", font=font, fill=255, anchor="mm")
            record("text_centered", [image.getbbox(), ink_count(image)])
            image = Image.new("L", (300, 120), 0)
            ImageDraw.Draw(image).text((20, 30), "Hi", font=font, fill=255, stroke_width=3, stroke_fill=255)
            record("text_stroke", [image.getbbox(), ink_count(image)])
            image = Image.new("RGB", (300, 120), (0, 0, 0))
            ImageDraw.Draw(image).text((10, 10), "one\ntwo lines", font=small, fill=(255, 0, 0), align="center")
            record("text_multiline", [image.getbbox(), image.getextrema()])
            try:
                ImageFont.truetype(os.path.join(workdir, "no-such-font.ttf"), 20)
                record("font_missing", "no error")
            except OSError as error:
                record("font_missing", [type(error).__name__, str(error)])
    """#
    // END PILLOW CASES

    // BEGIN PILLOW EXPECTED
    /// Pillow 13.0.0, written by Build/generate_pil_reference.py.
    static let pillowExpected = #"""
    {"alpha_composite":[[190,28,152,169],[102,28,82,167],[116,28,92,252],[84,28,67,167],[155,28,124,169],[192,91,48,208],[113,91,178,206],[119,91,53,15],[83,91,181,206],[132,91,49,208],[201,154,171,237],[122,154,141,235],[118,154,131,80],[78,154,66,235],[113,154,131,237],[215,217,53,255],[132,217,228,253],[117,217,215,134],[71,217,179,253],[93,217,98,255]],"alpha_composite_method":[[20,28,16,52],[70,28,56,142],[120,28,96,232],[165,28,132,57],[215,28,172,147],[20,91,52,88],[39,139,146,205],[10,191,97,98],[165,91,173,93],[215,91,47,183],[20,154,88,124],[70,154,52,214],[120,154,16,48],[165,154,214,129],[215,154,178,219],[20,217,124,160],[70,217,178,250],[120,217,232,84],[165,217,255,165],[215,217,53,255]],"bands":[["R","G","B","A"],["L","L","L","L"],[90,198,50,158,162,14,122,230],[63,63,63,63,189,189,189,189],["RGB",[48,36]],[[90,54,63,30],[198,162,63,90],[50,14,63,150],[158,122,63,210],[162,162,189,30],[14,230,189,90],[122,42,189,150],[230,110,189,210]]],"blend":[[[30,90,77],[90,90,78],[150,90,156],[210,90,234],[30,123,106],[90,123,62],[150,123,95],[210,123,231],[30,157,135],[90,157,46],[150,157,137],[210,157,228]],[[30,255,255],[90,255,0],[150,255,47],[210,255,153],[30,114,97],[90,114,37],[150,114,255],[210,114,172],[30,0,0],[90,0,133],[150,0,162],[210,0,191]]],"chops":[[[155,0,186],[5,0,6],[165,0,198],[155,0,46],[5,0,18],[165,0,82],[155,0,94],[5,0,30],[165,0,34]],[[30,6,44],[54,6,77],[27,6,39],[30,62,107],[54,62,109],[27,62,102],[30,172,137],[54,172,145],[27,172,144]],[[0,0,0],[5,0,6],[165,0,198],[0,0,0],[5,0,18],[165,0,82],[0,0,94],[5,0,30],[165,0,0]],[[0,60,0],[62,60,63],[142,60,159],[0,60,37],[62,60,69],[142,60,101],[0,60,107],[62,60,75],[142,60,43]],[[117,42,141],[117,42,141],[117,42,141],[117,126,167],[117,126,167],[117,126,167],[117,210,193],[117,210,193],[117,210,193]],[[25,14,10],[105,14,42],[185,14,74],[25,98,70],[105,98,38],[185,98,6],[25,182,130],[105,182,34],[185,182,194]],[[50,56,80],[130,56,208],[210,56,80],[50,140,200],[130,140,8],[210,140,72],[50,224,64],[130,224,64],[210,224,64]],[114,194,18,42,122,202,78,158,238]],"color_strings":[[26,51,77],[51,102,153],[170,187,204,255],202,[230,138,46]],"composite":[[191,193,48],[134,156,191],[118,119,147],[136,86,146],[194,49,167],[170,139,149],[124,127,200],[118,115,129],[146,104,149],[214,91,47],[149,112,61],[114,125,108],[119,137,23],[156,148,211],[39,97,64],[129,112,151],[104,149,161],[119,186,209],[71,29,58],[60,67,24]],"convert_l_L":["L",[48,36],48,108,168,228,84,144,204,8,120,180,240,44],"convert_l_LA":["LA",[48,36],[48,255],[108,255],[168,255],[228,255],[84,255],[144,255],[204,255],[8,255],[120,255],[180,255],[240,255],[44,255]],"convert_l_RGB":["RGB",[48,36],[48,48,48],[108,108,108],[168,168,168],[228,228,228],[84,84,84],[144,144,144],[204,204,204],[8,8,8],[120,120,120],[180,180,180],[240,240,240],[44,44,44]],"convert_l_RGBA":["RGBA",[48,36],[48,48,48,255],[108,108,108,255],[168,168,168,255],[228,228,228,255],[84,84,84,255],[144,144,144,255],[204,204,204,255],[8,8,8,255],[120,120,120,255],[180,180,180,255],[240,240,240,255],[44,44,44,255]],"convert_rgba_L":["L",[48,36],38,64,90,116,95,109,122,165,153,153,183,213],"convert_rgba_LA":["LA",[48,36],[38,78],[64,186],[90,38],[116,146],[95,126],[109,234],[122,86],[165,194],[153,174],[153,26],[183,134],[213,242]],"convert_rgba_RGB":["RGB",[48,36],[30,42,36],[90,42,108],[150,42,180],[210,42,252],[30,126,108],[90,126,68],[150,126,28],[210,126,244],[30,210,180],[90,210,28],[150,210,132],[210,210,236]],"convert_rgba_RGBA":["RGBA",[48,36],[30,42,36,78],[90,42,108,186],[150,42,180,38],[210,42,252,146],[30,126,108,126],[90,126,68,234],[150,126,28,86],[210,126,244,194],[30,210,180,174],[90,210,28,26],[150,210,132,134],[210,210,236,242]],"crop":[["RGB",[20,14]],[[40,56,64],[75,56,120],[105,56,168],[40,91,104],[75,91,195],[105,91,17],[40,119,136],[75,119,255],[105,119,101]],["RGB",[14,14]],[0,0,0],[5,7,1],[0,0,0]],"draw_circle":[[5,5,56,56],2025],"draw_diagonal_1":[[10,10,41,31],31,255,255,255],"draw_diagonal_4":[[9,9,42,33],144,255],"draw_ellipse_fill":[[10,20,51,41],677,255,0,255,255],"draw_ellipse_outline":[[10,20,51,41],260,0,255],"draw_hline_0":[null,0],"draw_hline_1":[[10,20,51,21],41],"draw_hline_2":[[10,20,51,22],82],"draw_hline_3":[[10,19,51,22],123],"draw_hline_4":[[10,19,51,23],164],"draw_hline_5":[[10,18,51,23],205],"draw_ink":[[200,100,50,0],[10,20,30,40],[105,60,40],[10,20,30],[255,255,255],[255,0,0],[0,0,0]],"draw_joint":[[2,7,74,53],786,255],"draw_polyline":[[10,19,52,41],182],"draw_rect_both":[200,100,200,861],"draw_rect_default":[null,0,0,0],"draw_rect_fill":[[10,20,51,41],861],"draw_rect_outline":[[10,20,51,41],336,255,0],"draw_round_both":[[4,4,71,51],2853,128,255,255],"draw_round_fill":[[10,20,51,41],821,0,255,255,255],"draw_round_outline":[[10,20,51,41],204,0,255,0],"draw_vline_0":[null,0],"draw_vline_1":[[10,20,11,41],21],"draw_vline_2":[[10,20,12,41],42],"draw_vline_3":[[9,20,12,41],63],"draw_vline_4":[[9,20,13,41],84],"draw_vline_5":[[8,20,13,41],105],"enhance":[[[0,3,12],[120,3,156],[240,3,255],[0,129,156],[120,129,204],[240,129,252],[0,255,255],[120,255,252],[240,255,204]],[[12,13,15],[38,13,46],[64,13,76],[12,40,46],[38,40,56],[64,40,66],[12,67,76],[38,67,66],[64,67,56]],[[41,42,43],[89,66,97],[138,91,150],[83,109,114],[127,128,143],[169,147,172],[126,177,186],[164,191,190],[202,205,194]],[[40,42,48],[120,42,144],[200,42,255],[40,126,144],[120,126,176],[200,126,228],[40,210,255],[120,210,228],[200,210,176]],[[79,80,83,96],[119,80,131,240],[159,80,179,128],[79,122,131,144],[119,122,147,32],[159,122,163,176],[79,164,179,192],[119,164,163,80],[159,164,147,224]],[[38,42,52,96],[154,14,197,240],[255,0,255,128],[0,145,177,144],[112,122,212,32],[234,101,248,176],[0,247,255,192],[69,231,228,80],[197,215,154,224]]],"file_error_extension":"ValueError","file_error_format":"KeyError","file_error_garbage":"UnidentifiedImageError","file_error_jpeg_rgba":"OSError","file_error_missing":"FileNotFoundError","file_error_no_format":"ValueError","file_jpeg_l":["JPEG","L",[64,64],[255,216,255]],"file_jpeg_rgb":["JPEG","RGB",[64,64]],"file_png_L":["PNG","L",[48,36],[48,108,168,228,84,144,204,8,120,180,240,44]],"file_png_LA":["PNG","LA",[48,36],[[48,255],[108,255],[168,255],[228,255],[84,255],[144,255],[204,255],[8,255],[120,255],[180,255],[240,255],[44,255]]],"file_png_RGB":["PNG","RGB",[48,36],[[30,42,36],[90,42,108],[150,42,180],[210,42,252],[30,126,108],[90,126,68],[150,126,28],[210,126,244],[30,210,180],[90,210,28],[150,210,132],[210,210,236]]],"file_png_RGBA":["PNG","RGBA",[48,36],[[30,42,36,78],[90,42,108,186],[150,42,180,38],[210,42,252,146],[30,126,108,126],[90,126,68,234],[150,126,28,86],[210,126,244,194],[30,210,180,174],[90,210,28,26],[150,210,132,134],[210,210,236,242]]],"file_png_stream":[[137,80,78,71,13,10,26,10],["RGBA",[48,36]]],"filter_alpha":[[21,29,17,53],[70,29,58,142],[120,29,95,176],[165,29,107,64],[214,29,108,146],[21,91,54,89],[70,91,155,177],[120,91,121,100],[165,91,129,93],[214,91,127,182],[21,154,89,125],[70,154,120,193],[120,154,131,61],[165,154,125,129],[214,154,126,198],[21,216,106,161],[70,216,129,141],[120,216,125,84],[165,216,132,165],[214,216,125,130],57,117,177,237,111,171,231,35],"filter_blur":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,124],[20,91,52],[70,91,182],[120,91,88],[165,91,157],[215,91,143],[20,154,88],[70,154,84],[120,154,128],[165,154,118],[215,154,114],[20,217,124],[70,217,146],[120,217,136],[165,217,143],[215,217,149],[0,0,0],[235,245,109]],"filter_box_3":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,115],[20,91,52],[70,91,172],[120,91,103],[165,91,136],[215,91,136],[20,154,88],[70,154,99],[120,154,126],[165,154,130],[215,154,121],[20,217,124],[70,217,141],[120,217,133],[165,217,140],[215,217,131],[4,6,1],[231,239,102]],"filter_contour":[[255,255,255],[255,255,255],[255,255,255],[255,255,255],[255,255,255],[255,255,255],[255,255,255],[255,255,255],[255,255,255],[255,255,0],[255,255,255],[255,255,255],[255,255,0],[255,255,255],[255,255,255],[255,255,255],[255,255,255],[255,255,255],[255,255,255],[255,255,0],[0,0,0],[235,245,109]],"filter_detail":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[20,91,52],[70,91,182],[120,91,56],[165,91,173],[215,91,47],[20,154,88],[70,154,52],[120,154,0],[165,154,214],[215,154,178],[20,217,124],[70,217,178],[120,217,255],[165,217,255],[215,217,53],[0,0,0],[235,245,109]],"filter_edge_enhance":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[20,91,52],[70,91,182],[120,91,56],[165,91,173],[215,91,0],[20,154,88],[70,154,52],[120,154,0],[165,154,255],[215,154,178],[20,217,124],[70,217,178],[120,217,255],[165,217,255],[215,217,0],[0,0,0],[235,245,109]],"filter_edge_enhance_more":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[20,91,52],[70,91,182],[120,91,56],[165,91,173],[215,91,0],[20,154,88],[70,154,52],[120,154,0],[165,154,255],[215,154,178],[20,217,124],[70,217,178],[120,217,255],[165,217,255],[215,217,0],[0,0,0],[235,245,109]],"filter_emboss":[[133,121,129],[133,121,119],[133,121,109],[133,121,100],[133,121,90],[133,121,138],[133,121,128],[133,121,118],[133,121,109],[133,121,99],[133,121,147],[133,121,137],[133,121,127],[133,121,118],[133,121,108],[133,121,156],[133,121,146],[133,121,136],[133,121,255],[133,121,117],[0,0,0],[235,245,109]],"filter_find_edges":[[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,0],[0,0,255],[0,0,0],[0,0,0],[0,0,0],[0,0,255],[0,0,255],[0,0,0],[0,0,0],[235,245,109]],"filter_gaussian_0_4":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[20,91,52],[70,91,182],[120,91,56],[165,91,173],[215,91,50],[20,154,88],[70,154,52],[120,154,50],[165,154,211],[215,154,178],[20,217,124],[70,217,178],[120,217,198],[165,217,220],[215,217,56],[0,0,0],[235,245,103]],"filter_gaussian_2":[[20,28,16],[70,28,56],[120,28,96],[165,28,124],[215,28,126],[20,91,52],[70,91,174],[120,91,97],[165,91,142],[215,91,122],[20,154,88],[70,154,95],[120,154,127],[165,154,133],[215,154,129],[20,217,119],[70,217,144],[120,217,130],[165,217,136],[215,217,127],[5,7,0],[230,238,108]],"filter_gaussian_30":[[84,104,57],[100,104,62],[118,104,67],[135,104,72],[151,104,76],[84,116,61],[100,116,66],[118,116,71],[135,116,76],[151,116,81],[84,129,65],[100,129,70],[118,129,76],[135,129,81],[151,129,86],[84,141,69],[100,141,74],[118,141,80],[135,141,86],[151,141,91],[79,99,54],[156,146,94]],"filter_gaussian_5_5":[[25,35,24],[70,35,64],[120,35,86],[165,35,92],[210,35,95],[25,91,60],[70,91,122],[120,91,128],[165,91,126],[210,91,125],[25,154,84],[70,154,129],[120,154,127],[165,154,127],[210,154,127],[25,210,91],[70,210,125],[120,210,126],[165,210,128],[210,210,124],[15,21,9],[220,224,120]],"filter_kernel":[[88,128,96],[88,128,96],[88,128,96],[88,128,96],[88,128,96],[88,128,24],[88,128,24],[88,128,24],[88,128,24],[88,128,255],[88,128,0],[88,128,0],[88,128,255],[88,128,208],[88,128,0],[88,128,0],[88,128,0],[88,128,255],[88,128,255],[88,128,136],[0,0,0],[235,245,109]],"filter_max":[[25,35,25],[75,35,75],[125,35,125],[170,35,170],[220,35,220],[25,98,70],[75,98,210],[125,98,94],[170,98,220],[220,98,248],[25,161,115],[75,161,89],[125,161,250],[170,161,247],[220,161,244],[25,224,160],[75,224,224],[125,224,238],[170,224,255],[220,224,236],[5,7,1],[235,245,109]],"filter_median":[[20,28,15],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[20,91,52],[70,91,182],[120,91,56],[165,91,173],[215,91,60],[20,154,88],[70,154,52],[120,154,40],[165,154,202],[215,154,178],[20,217,124],[70,217,178],[120,217,201],[165,217,192],[215,217,64],[0,0,0],[235,245,74]],"filter_min":[[10,14,4],[60,14,24],[110,14,44],[155,14,62],[205,14,2],[10,77,22],[60,77,132],[110,77,8],[155,77,13],[205,77,4],[10,140,40],[60,140,4],[110,140,8],[155,140,0],[205,140,8],[10,203,58],[60,203,0],[110,203,0],[155,203,0],[205,203,10],[0,0,0],[225,231,15]],"filter_sharpen":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[20,91,52],[70,91,182],[120,91,56],[165,91,173],[215,91,15],[20,154,88],[70,154,52],[120,154,0],[165,154,246],[215,154,178],[20,217,124],[70,217,178],[120,217,255],[165,217,255],[215,217,21],[0,0,0],[235,245,109]],"filter_smooth":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[20,91,52],[70,91,182],[120,91,56],[165,91,173],[215,91,67],[20,154,88],[70,154,52],[120,154,75],[165,154,194],[215,154,178],[20,217,124],[70,217,178],[120,217,173],[165,217,176],[215,217,73],[0,0,0],[235,245,109]],"filter_smooth_more":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,164],[20,91,52],[70,91,182],[120,91,61],[165,91,170],[215,91,75],[20,154,88],[70,154,57],[120,154,72],[165,154,186],[215,154,168],[20,217,124],[70,217,173],[120,217,178],[165,217,186],[215,217,81],[0,0,0],[235,245,109]],"filter_unsharp":[[20,28,16],[70,28,56],[120,28,96],[165,28,144],[215,28,245],[20,91,52],[70,91,194],[120,91,0],[165,91,222],[215,91,0],[20,154,88],[70,154,0],[120,154,0],[165,154,255],[215,154,255],[20,217,132],[70,217,232],[120,217,255],[165,217,255],[215,217,0],[0,0,0],[243,255,109]],"font_bbox":[[-1,8,47,45],[0,8,91,37],[-1,3,16,16],[0,-21,20,0],[-24,-15,24,22],[-48,-37,0,0],[-1,0,47,37],[-1,-38,47,-1],[-4,5,50,48]],"font_length":[91.0,70.0,46.9844,0.0],"font_metrics":[[37,9],[13,3],"Arial"],"font_missing":["OSError","cannot open resource"],"jpeg_pixels":[[25,24,128],[72,23,128],[121,24,129],[169,24,129],[25,71,130],[72,71,128],[121,72,128],[169,71,128],[25,119,129],[73,120,130],[121,120,128],[169,119,128],[23,168,129],[72,168,130],[120,168,130],[169,167,128]],"new_colors":[[255,255,255],[255,0,0],[0,0,0,0],7,[1,2,3],[9,8,7,255],[16,32,48,64],76],"ops_autocontrast":[[48,108,168,228,84,144,204,6,120,180,240,42],[48,109,170,230,85,145,206,6,121,182,242,42],[[43,64,72],[130,64,216],[217,64,104],[43,196,216],[130,196,136],[217,196,56]]],"ops_basic":[[[215,192,183],[135,192,39],[55,192,151],[215,66,39],[135,66,119],[55,66,199]],[57,97,109,148,162,177],[[195,63,95],[115,63,207],[35,63,63],[195,189,29],[115,189,109],[35,189,189]],[[40,182,208],[120,182,112],[200,182,16],[40,56,64],[120,56,192],[200,56,64]],[[0,0,64],[64,0,192],[192,0,64],[0,128,192],[64,128,128],[192,128,0]],[[40,63,72],[135,63,39],[55,63,151],[40,66,39],[135,66,119],[55,66,56]]],"ops_colorize":[["RGB",[48,36]],[[127,87,40],[146,113,65],[166,139,91],[185,166,116],[139,102,55],[158,129,80],[177,155,106],[114,69,23],[150,118,70],[169,145,96],[189,171,121],[126,85,38]],[[96,0,0],[216,0,0],[255,81,81],[255,201,201],[168,0,0],[255,33,33],[255,153,153],[16,0,0],[240,0,0],[255,105,105],[255,225,225],[88,0,0]]],"ops_fit":[["RGB",[20,20]],[[59,41,69],[122,41,141],[176,41,227],[59,129,227],[122,129,205],[176,129,135],[59,204,91],[122,204,223],[176,204,145]],[[41,153,176],[121,153,53],[201,153,113],[41,198,208],[121,198,176],[201,198,114],[41,232,17],[121,232,26],[201,232,23]],[[93,37,99],[120,37,128],[142,37,152],[93,126,77],[120,126,174],[142,126,149],[93,208,18],[120,208,198],[142,208,77]]],"paste_clipped":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[20,91,52],[70,91,182],[120,91,56],[165,91,173],[215,91,47],[20,154,88],[70,154,52],[120,154,16],[165,154,214],[215,154,178],[20,217,124],[70,217,178],[120,217,232],[165,217,255],[250,10,120]],"paste_color_box":[[255,255,0],[255,255,0],[255,255,0],[165,28,132],[215,28,172],[255,255,0],[255,255,0],[255,255,0],[165,91,173],[215,91,47],[20,154,88],[70,154,52],[120,154,16],[165,154,214],[215,154,178],[20,217,124],[70,217,178],[120,217,232],[165,217,255],[215,217,53]],"paste_color_mask":[[20,28,16,52],[35,15,29,172],[120,28,96,232],[165,28,132,57],[215,28,172,147],[17,75,43,108],[23,30,59,193],[120,91,56,12],[165,91,173,93],[215,91,47,183],[20,154,88,124],[70,154,52,214],[120,154,16,48],[165,154,214,129],[215,154,178,219],[20,217,124,160],[70,217,178,250],[120,217,232,84],[165,217,255,165],[215,217,53,255]],"paste_mask":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[20,91,52],[124,67,163],[226,25,108],[165,91,173],[215,91,47],[20,154,88],[70,154,52],[120,154,16],[165,154,214],[215,154,178],[20,217,124],[70,217,178],[120,217,232],[165,217,255],[215,217,53]],"paste_negative":[[178,16,87],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[20,91,52],[70,91,182],[120,91,56],[165,91,173],[215,91,47],[20,154,88],[70,154,52],[120,154,16],[165,154,214],[215,154,178],[20,217,124],[70,217,178],[120,217,232],[165,217,255],[215,217,53]],"paste_plain":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[20,91,52],[250,10,120],[250,10,120],[165,91,173],[215,91,47],[20,154,88],[70,154,52],[120,154,16],[165,154,214],[215,154,178],[20,217,124],[70,217,178],[120,217,232],[165,217,255],[215,217,53]],"paste_rgba_into_rgb":[[20,28,16],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[20,91,52],[0,200,100],[0,200,100],[165,91,173],[215,91,47],[20,154,88],[0,200,100],[0,200,100],[165,154,214],[215,154,178],[20,217,124],[70,217,178],[120,217,232],[165,217,255],[215,217,53]],"paste_rgba_mask":[[20,28,16,52],[70,28,56,142],[120,28,96,232],[165,28,132,57],[215,28,172,147],[20,91,52,88],[45,129,153,147],[78,129,72,40],[165,91,173,93],[215,91,47,183],[20,154,88,124],[45,170,69,170],[78,170,46,63],[165,154,214,129],[215,154,178,219],[20,217,124,160],[70,217,178,250],[120,217,232,84],[165,217,255,165],[215,217,53,255]],"pixels":[[15,28,12],[1,2,3],[1,2,3],99,[0,5,10,15,20,25],[[10,7,2,22],[15,7,3,31]],5184,[0,0,0,5,0,0],[0,9,18,27]],"point":[[[60,63,72],[180,63,216],[255,63,255],[60,189,216],[180,189,255],[255,189,255],[60,255,255],[180,255,255],[255,255,255]],[197,117,37,161,81,1,125,45,221]],"putalpha_existing":[[40,63,72,200],[120,63,216,200],[200,63,104,200],[40,189,216,200],[120,189,136,200],[200,189,56,200]],"putalpha_image":["RGBA",[48,36],[40,63,72,67],[120,63,216,147],[200,63,104,227],[40,189,216,121],[120,189,136,201],[200,189,56,25]],"putalpha_int":["RGBA",[48,36],[40,63,72,77],[120,63,216,77],[200,63,104,77],[40,189,216,77],[120,189,136,77],[200,189,56,77]],"resize_alpha_BICUBIC":[[27,27,19,65],[75,27,55,151],[123,24,91,245],[168,22,127,68],[218,26,162,155],[27,91,71,103],[75,93,202,189],[145,72,145,7],[170,91,211,106],[219,93,71,193],[27,150,119,137],[75,152,68,226],[125,153,57,53],[171,151,163,140],[219,151,194,227],[27,218,182,175],[68,219,183,71],[126,221,72,91],[171,217,74,178],[217,221,37,68]],"resize_alpha_BILINEAR":[[27,27,19,65],[75,25,54,151],[123,25,89,234],[168,22,123,68],[220,26,160,154],[27,94,74,103],[75,94,202,189],[134,93,80,19],[173,93,204,106],[220,94,75,192],[27,150,119,137],[75,150,72,223],[125,153,72,53],[171,151,158,140],[220,151,182,226],[27,220,174,175],[68,223,172,74],[126,221,81,91],[171,219,85,178],[216,219,56,72]],"resize_alpha_BOX":[[27,30,23,66],[74,28,60,151],[122,27,97,237],[172,28,136,71],[220,27,176,156],[27,92,72,102],[75,91,195,187],[120,90,75,17],[171,90,193,107],[220,91,61,192],[27,153,121,138],[75,154,74,223],[125,153,28,53],[172,153,115,143],[220,154,200,228],[27,216,171,174],[72,217,182,88],[123,214,114,89],[172,216,45,179],[216,216,57,93]],"resize_alpha_HAMMING":[[27,27,23,65],[75,27,57,151],[123,26,93,237],[168,26,131,68],[220,26,167,154],[27,91,74,103],[75,93,199,189],[120,93,80,19],[170,91,197,106],[220,92,69,192],[27,152,120,137],[76,152,73,223],[129,153,52,53],[171,153,153,140],[220,152,189,226],[27,218,171,175],[69,220,177,59],[123,218,81,91],[171,217,73,178],[217,221,60,68]],"resize_alpha_LANCZOS":[[27,27,19,65],[75,25,55,151],[123,25,92,252],[168,22,127,68],[220,26,163,154],[27,94,74,103],[75,93,195,189],[0,0,5,0],[170,93,214,106],[220,92,73,192],[27,150,119,137],[75,152,65,226],[125,148,55,55],[171,151,173,140],[219,151,204,225],[27,220,190,175],[70,225,192,69],[126,221,70,91],[171,217,67,178],[216,216,15,67]],"resize_alpha_NEAREST":[[30,28,24,70],[75,28,60,151],[125,28,100,241],[170,28,136,66],[220,28,176,156],[30,91,78,106],[75,91,195,187],[125,91,69,21],[170,91,186,102],[220,91,60,192],[30,154,132,142],[75,154,74,223],[125,154,38,57],[170,154,236,138],[220,154,200,228],[30,217,186,178],[75,217,209,3],[125,217,7,93],[170,217,30,174],[220,217,84,8]],"resize_box":[[42,43,52],[78,43,96],[113,43,140],[149,43,184],[184,43,179],[42,91,109],[78,91,202],[113,91,40],[149,91,130],[184,91,194],[42,138,166],[78,138,51],[113,138,193],[149,138,77],[184,138,203],[42,186,206],[78,186,157],[113,186,90],[149,186,65],[184,186,184]],"resize_default":[37,85,132,181,229,66,114,161,210,77,95,143,190,245,31,124,172,219,2,60],"resize_down_BICUBIC":["RGB",[17,11],[18,30,16],[75,30,65],[117,30,102],[160,30,149],[217,30,151],[18,100,52],[75,100,213],[117,100,67],[160,100,179],[217,100,110],[18,145,77],[75,145,45],[117,145,182],[160,145,159],[217,145,129],[18,215,115],[75,215,186],[117,215,171],[160,215,174],[217,215,110]],"resize_down_BILINEAR":["RGB",[17,11],[19,31,17],[75,31,66],[118,31,104],[160,31,142],[216,31,145],[19,100,54],[75,100,198],[118,100,81],[160,100,165],[216,100,112],[19,145,78],[75,145,63],[118,145,169],[160,145,149],[216,145,128],[19,214,115],[75,214,174],[118,214,157],[160,214,159],[216,214,115]],"resize_down_BOX":["RGB",[17,11],[20,32,18],[75,32,68],[118,32,106],[160,32,144],[215,32,151],[20,98,56],[75,98,210],[118,98,73],[160,98,192],[215,98,90],[20,147,84],[75,147,59],[118,147,195],[160,147,160],[215,147,135],[20,214,122],[75,214,180],[118,214,173],[160,214,165],[215,214,117]],"resize_down_HAMMING":["RGB",[17,11],[19,31,16],[75,31,66],[117,31,103],[160,31,141],[216,31,159],[19,100,53],[75,100,205],[117,100,78],[160,100,179],[216,100,106],[19,145,77],[75,145,58],[117,145,184],[160,145,151],[216,145,130],[19,214,114],[75,214,185],[117,214,170],[160,214,172],[216,214,96]],"resize_down_LANCZOS":["RGB",[17,11],[18,30,16],[75,30,65],[118,30,99],[160,30,157],[217,30,151],[18,100,52],[75,100,222],[118,100,57],[160,100,188],[217,100,112],[18,145,77],[75,145,33],[118,145,189],[160,145,168],[217,145,130],[18,215,115],[75,215,196],[118,215,183],[160,215,187],[217,215,113]],"resize_down_NEAREST":["RGB",[17,11],[20,28,16],[75,28,60],[120,28,96],[160,28,128],[215,28,172],[20,98,56],[75,98,210],[120,98,80],[160,98,192],[215,98,90],[20,147,84],[75,147,59],[120,147,248],[160,147,160],[215,147,135],[20,217,124],[75,217,209],[120,217,232],[160,217,224],[215,217,53]],"resize_legacy_names":[1,3,0,2,[48,144,216,91,187,90,123,225,32]],"resize_up_BICUBIC":[[23,27,17],[71,27,55],[119,27,92],[167,27,129],[215,27,166],[23,92,60],[71,92,186],[119,92,56],[167,92,182],[215,92,52],[23,153,99],[71,153,54],[119,153,77],[167,153,233],[215,153,171],[23,218,143],[71,218,185],[119,218,226],[167,218,165],[215,218,57]],"resize_up_BILINEAR":[[23,27,17],[71,27,55],[119,27,92],[167,27,129],[215,27,166],[23,92,60],[71,92,186],[119,92,56],[167,92,182],[215,92,53],[23,153,99],[71,153,54],[119,153,93],[167,153,218],[215,153,171],[23,218,143],[71,218,185],[119,218,203],[167,218,156],[215,218,58]],"resize_up_BOX":[[25,28,20],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[25,91,65],[70,91,182],[120,91,56],[165,91,173],[215,91,47],[25,154,110],[70,154,52],[120,154,16],[165,154,214],[215,154,178],[25,217,155],[70,217,178],[120,217,232],[165,217,255],[215,217,53]],"resize_up_HAMMING":[[23,28,19],[70,28,56],[120,28,96],[166,28,132],[215,28,171],[23,91,60],[70,91,182],[120,91,55],[166,91,177],[215,91,48],[23,154,102],[70,154,53],[120,154,35],[166,154,218],[215,154,177],[23,217,144],[70,217,179],[120,217,226],[166,217,203],[215,217,54]],"resize_up_LANCZOS":[[23,27,18],[71,27,55],[119,27,92],[167,27,129],[215,27,162],[23,92,59],[71,92,186],[119,92,57],[167,92,181],[215,92,57],[23,153,101],[71,153,54],[119,153,84],[167,153,242],[215,153,167],[23,218,142],[71,218,185],[119,218,234],[167,218,160],[215,218,60]],"resize_up_NEAREST":[[25,28,20],[70,28,56],[120,28,96],[165,28,132],[215,28,172],[25,91,65],[70,91,182],[120,91,56],[165,91,173],[215,91,47],[25,154,110],[70,154,52],[120,154,16],[165,154,214],[215,154,178],[25,217,155],[70,217,178],[120,217,232],[165,217,255],[215,217,53]],"rotate_30_bicubic":[[77,0,0,141],[149,49,255,41],[217,109,171,198],[45,71,99,128],[114,123,167,29],[187,183,196,186],[17,144,75,115],[85,198,155,18],[0,0,0,0]],"rotate_30_bilinear":[[9,9,9],[9,9,9],[201,24,140],[9,9,9],[36,4,4],[101,56,164],[166,109,104],[231,161,45],[1,89,3],[66,141,12],[131,194,216],[196,245,93],[9,9,9],[31,226,202],[9,9,9],[9,9,9]],"rotate_30_nearest":[[80,0,0],[150,56,240],[220,112,192],[50,70,100],[120,126,176],[190,182,220],[20,147,84],[90,203,10],[0,0,0]],"rotate_90":[[195,42,234],[195,126,190],[195,210,146],[115,42,138],[115,126,158],[115,210,178],[35,42,42],[35,126,126],[35,210,210]],"rotate_sizes":[["RGB",[36,48]],["RGB",[48,36]],["RGB",[60,60]],["RGB",[48,36]],["RGB",[48,36]],["RGB",[58,50]]],"stats":[[4,3,11,9],null,[0,255],[[0,235],[0,245],[0,255]],[[42,[5,6,7,255]],[558,[0,0,0,0]]],[[9,[255,0,0]]],null,[7,6,5,7,6,6,7,5,6,7,6,6],768,1728],"text_bbox":[[-1,8,47,45],[4,45,95,74],[10,15,65,40],[0,5,21,59],[172.0,105,227.0,130]],"text_centered":[[107,45,194,74],1108],"text_drawn":[[23,38,110,67],1108],"text_multiline":[[10,15,65,40],[[0,255],[0,0],[0,0]]],"text_stroke":[[20,35,59,70],1151],"thumbnail_pixels":[[40,39,44],[124,39,133],[195,39,186],[40,122,138],[124,122,186],[195,122,195],[40,206,184],[124,206,196],[195,206,134]],"thumbnail_sizes":[[20,15],[13,10],[15,20],[33,10],[1,64],[48,36]],"transform_affine":[[42,49,59],[87,42,105],[132,35,132],[177,28,142],[52,126,189],[97,119,76],[142,112,200],[187,105,51],[62,203,107],[107,196,91],[152,189,56],[197,182,119]],"transform_affine_nearest":[[0,7,0],[50,7,10],[100,7,20],[150,7,30],[0,77,0],[50,77,110],[100,77,220],[150,77,74],[0,147,0],[50,147,210],[100,147,164],[150,147,118]],"transpose_FLIP_LEFT_RIGHT":["RGB",[48,36],[195,42,234],[115,42,138],[35,42,42],[195,126,190],[115,126,158],[35,126,126],[195,210,146],[115,210,178],[35,210,210],[235,0,0],[0,0,0]],"transpose_FLIP_TOP_BOTTOM":["RGB",[48,36],[40,203,232],[120,203,184],[200,203,136],[40,119,136],[120,119,152],[200,119,168],[40,35,40],[120,35,120],[200,35,200],[0,245,0],[235,245,109]],"transpose_ROTATE_180":["RGB",[48,36],[195,203,107],[115,203,155],[35,203,203],[195,119,151],[115,119,135],[35,119,119],[195,35,195],[115,35,115],[35,35,35],[235,245,109],[0,245,0]],"transpose_ROTATE_270":["RGB",[36,48],[40,203,232],[40,119,136],[40,35,40],[120,203,184],[120,119,152],[120,35,120],[200,203,136],[200,119,168],[200,35,200],[0,245,0],[0,0,0]],"transpose_ROTATE_90":["RGB",[36,48],[195,42,234],[195,126,190],[195,210,146],[115,42,138],[115,126,158],[115,210,178],[35,42,42],[35,126,126],[35,210,210],[235,0,0],[235,245,109]],"transpose_TRANSPOSE":["RGB",[36,48],[40,42,48],[40,126,144],[40,210,240],[120,42,144],[120,126,176],[120,210,208],[200,42,240],[200,126,208],[200,210,176],[0,0,0],[0,245,0]],"transpose_TRANSVERSE":["RGB",[36,48],[195,203,107],[195,119,151],[195,35,195],[115,203,155],[115,119,135],[115,35,115],[35,203,203],[35,119,119],[35,35,35],[235,245,109],[235,0,0]]}
    """#
    // END PILLOW EXPECTED

    /// How far a value may be from Pillow's: `absolute` units, or `relative` of the larger one.
    /// Anything not listed must be equal.
    private static let tolerances: [(prefix: String, absolute: Double, relative: Double, reason: String)] = [
        ("resize_", 1, 0, "fixed-point resampling: one rounding step"),
        ("thumbnail_pixels", 1, 0, "resampling"),
        ("ops_fit", 1, 0, "resampling"),
        ("rotate_30", 1, 0, "floating-point sampling positions"),
        ("transform_affine", 1, 0, "floating-point sampling positions"),
        ("filter_", 1, 0, "single-precision kernel sums"),
        ("enhance", 1, 0, "built on the smoothing filter and blend"),
        ("jpeg_pixels", 8, 0, "another JPEG encoder and decoder"),
        ("draw_ellipse", 1, 0.04, "another ellipse rasterizer: edge pixels"),
        ("draw_circle", 1, 0.04, "another ellipse rasterizer: edge pixels"),
        ("draw_round", 1, 0.04, "another corner rasterizer: edge pixels"),
        ("draw_diagonal", 1, 0.12, "another line rasterizer: edge pixels"),
        ("draw_joint", 2, 0.12, "another line rasterizer and round joints"),
        ("font_", 3, 0.05, "CoreText metrics against FreeType's"),
        ("text_", 3, 0.2, "CoreText outlines against FreeType's hinted bitmaps"),
    ]

    private static func tolerance(_ name: String) -> (absolute: Double, relative: Double) {
        let found = self.tolerances.first { name.hasPrefix($0.prefix) }
        return (found?.absolute ?? 0, found?.relative ?? 0)
    }

    private static func matches(_ actual: AyuBridgeValue, _ expected: AyuBridgeValue, _ tolerance: (absolute: Double, relative: Double)) -> Bool {
        if let left = actual.array, let right = expected.array {
            return left.count == right.count && zip(left, right).allSatisfy { self.matches($0, $1, tolerance) }
        }
        if let left = actual.number, let right = expected.number {
            let difference = abs(left - right)
            return difference <= tolerance.absolute + 1e-6 || difference <= tolerance.relative * max(abs(left), abs(right))
        }
        return actual == expected
    }

    private static let font = "/System/Library/Fonts/Supplemental/Arial.ttf"

    private func results(_ stack: AyuEndToEnd, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: AyuBridgeValue] {
        guard let path = stack.stored(id, "results").string, let data = FileManager.default.contents(atPath: path) else {
            XCTFail("The plugin stored no results: \(stack.stored(id))", file: file, line: line)
            return [:]
        }
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        let decoded = try JSONDecoder().decode(AyuBridgeValue.self, from: data)
        XCTAssertEqual(decoded["error"], .null, "The plugin raised", file: file, line: line)
        return decoded["results"].object ?? [:]
    }

    private static func plugin(id: String, imports: String = "", function: String, body: String, arguments: String) -> String {
        return """
        __id__ = "\(id)"
        __name__ = "Synthetic \(id)"
        __description__ = "AyuPluginBridge end-to-end fixture"
        __author__ = "AyuPluginBridge tests"
        __version__ = "1.0.0"

        import json
        import os
        import tempfile
        import traceback
        from base_plugin import BasePlugin
        \(imports)

        """ + body + """


        class ImagePlugin(BasePlugin):
            def on_plugin_load(self):
                results, error = {}, None
                workdir = tempfile.mkdtemp(prefix="ayu-image-e2e-")
                try:
                    \(function)(results.__setitem__, workdir\(arguments))
                except BaseException:
                    error = traceback.format_exc()
                path = os.path.join(workdir, "results.json")
                with open(path, "w") as stream:
                    json.dump({"results": results, "error": error}, stream)
                self.set_setting("results", path)

        """
    }

    func testPillowSubsetMatchesPillow() async throws {
        let stack = try AyuEndToEnd.shared()
        let hasFont = FileManager.default.fileExists(atPath: Self.font)
        let source = Self.plugin(id: "e2e_pillow", function: "pillow_cases", body: Self.pillowCases, arguments: hasFont ? ", \"\(Self.font)\"" : ", None")
        let id = try await stack.start(source)
        let results = try self.results(stack, id)
        await stack.remove(id)
        let expected = try JSONDecoder().decode([String: AyuBridgeValue].self, from: Data(Self.pillowExpected.utf8))
        XCTAssertGreaterThan(expected.count, 100, "Run Build/generate_pil_reference.py")
        var compared = 0
        for (name, value) in expected.sorted(by: { $0.key < $1.key }) {
            guard let actual = results[name] else {
                if !hasFont, name.hasPrefix("font_") || name.hasPrefix("text_") { continue }
                XCTFail("\(name) was not recorded")
                continue
            }
            compared += 1
            XCTAssertTrue(Self.matches(actual, value, Self.tolerance(name)), "\(name): \(Self.text(actual)) is not Pillow's \(Self.text(value))")
        }
        XCTAssertEqual(Set(results.keys).subtracting(expected.keys), [], "Cases without a Pillow reference")
        XCTAssertGreaterThan(compared, 100)
    }

    private static func text(_ value: AyuBridgeValue) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
    }
}
