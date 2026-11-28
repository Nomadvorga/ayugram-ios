"""android.* value providers, exercised directly: no host and no plugin source."""
from __future__ import annotations

import os
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
import _ayu_javalib as javalib
from _ayu_javalib import android_bitmap as bitmap
from _ayu_javalib import android_compose as compose
from _ayu_javalib import android_content as content
from _ayu_javalib import android_graphics as graphics
from _ayu_javalib import android_os as android_os
from _ayu_javalib import android_text as text
from _ayu_javalib import android_util as util
from _ayu_javalib import java_io as io
from _ayu_javalib import java_lang as lang


class BuildTests(unittest.TestCase):
    def test_build_describes_the_emulated_api_and_the_real_hardware(self):
        build = android_os.Build
        self.assertEqual((build.VERSION.SDK_INT, build.VERSION.RELEASE, build.VERSION.CODENAME, build.VERSION.SDK),
                         (36, "16", "REL", "36"))
        self.assertEqual((build.MANUFACTURER, build.BRAND, build.SUPPORTED_ABIS, build.SUPPORTED_64_BIT_ABIS, build.UNKNOWN),
                         ("Apple", "Apple", (), (), "unknown"))
        self.assertEqual(build.MODEL, os.uname().machine)
        self.assertEqual({build.BOARD, build.HARDWARE, build.FINGERPRINT, build.ID, build.CPU_ABI, build.SERIAL}, {"unknown"})
        codes = build.VERSION_CODES
        self.assertEqual((codes.BASE, codes.M, codes.N, codes.O, codes.P, codes.Q, codes.R, codes.S, codes.S_V2, codes.TIRAMISU,
                          codes.UPSIDE_DOWN_CAKE, codes.VANILLA_ICE_CREAM, codes.BAKLAVA, codes.CUR_DEVELOPMENT),
                         (1, 23, 24, 26, 28, 29, 30, 31, 32, 33, 34, 35, 36, 10000))
        self.assertTrue(build.VERSION.SDK_INT >= codes.O)
        self.assertIs(android_os.CLASSES["android.os.Build$VERSION"], build.VERSION)
        self.assertFalse(hasattr(build, "getSerial"))
        with self.assertRaises(bridge.UnsupportedAPI):
            build()

    def test_bundle_typed_access(self):
        bundle = android_os.Bundle()
        bundle.putInt("i", 5)
        bundle.putLong("l", 2 ** 40)
        bundle.putString("s", "x")
        bundle.putBoolean("b", True)
        bundle.putFloat("f", 0.5)
        bundle.putStringArrayList("a", ["q"])
        nested = android_os.Bundle()
        bundle.putBundle("n", nested)
        self.assertEqual((bundle.getInt("i"), bundle.getLong("i"), bundle.getLong("l"), bundle.getInt("zz", 7), bundle.getString("s"),
                          bundle.getString("zz"), bundle.getString("zz", "d"), bundle.getBoolean("b"), bundle.getFloat("f"),
                          bundle.getStringArrayList("a"), bundle.getBundle("n") is nested, bundle.get("l"), bundle.size(),
                          bundle.containsKey("i"), sorted(bundle.keySet()), len(bundle), "i" in bundle),
                         (5, 0, 2 ** 40, 7, "x", None, "d", True, 0.5, ["q"], True, 2 ** 40, 7, True, list("abfilns"), 7, True))
        copy = android_os.Bundle(bundle)
        bundle.remove("i")
        self.assertEqual((copy.getInt("i"), bundle.containsKey("i"), copy == bundle, bundle.to_bridge()["s"]), (5, False, False, "x"))
        with self.assertRaises(OverflowError):
            bundle.putInt("x", 2 ** 31)
        with self.assertRaises(TypeError):
            bundle.putInt("x", True)
        with self.assertRaises(TypeError):
            bundle.putString("x", 5)
        bundle.putString("x", None)
        self.assertIsNone(bundle.getString("x", None))
        self.assertGreater(android_os.SystemClock.elapsedRealtime(), 0)
        self.assertGreater(android_os.StatFs("/").getTotalBytes(), 0)
        with self.assertRaises(lang.IllegalArgumentException):
            android_os.StatFs("/synthetic/absent/path")
        sink = io.ByteArrayOutputStream()
        self.assertEqual((android_os.FileUtils.copy(io.ByteArrayInputStream(b"copy"), sink), sink.toString()), (4, "copy"))


class ContentTests(unittest.TestCase):
    def test_clip_data(self):
        clip = content.ClipData.newPlainText("label", "hello")
        self.assertEqual((clip.getItemCount(), clip.getItemAt(0).getText(), clip.getItemAt(0).coerceToText(None), clip.getDescription().getLabel(),
                          clip.getDescription().getMimeType(0), clip.getDescription().hasMimeType("text/*"),
                          clip.getDescription().hasMimeType("image/*"), str(clip)),
                         (1, "hello", "hello", "label", "text/plain", True, False, "ClipData { text/plain {ClipData.Item { T:hello }} }"))
        clip.addItem(content.ClipData.Item("second"))
        html = content.ClipData.newHtmlText("l", "t", "<b>t</b>")
        self.assertEqual((clip.getItemCount(), html.getItemAt(0).getHtmlText(), html.getDescription().getMimeType(0),
                          content.ClipData.Item is content.CLASSES["android.content.ClipData$Item"]), (2, "<b>t</b>", "text/html", True))
        with self.assertRaises(lang.IndexOutOfBoundsException):
            clip.getItemAt(5)
        with self.assertRaises(lang.IllegalArgumentException):
            content.ClipData.Item(None, "<b>html only</b>")
        with self.assertRaises(bridge.UnsupportedAPI):
            content.ClipData.newUri(None, "l", "content://x")
        self.assertFalse(hasattr(type(clip), "to_bridge"))

    def test_content_values_component_name_and_filter(self):
        values = content.ContentValues()
        values.put("a", 5)
        values.put("b", "12")
        values.put("c", 1.9)
        values.putNull("d")
        values.put("e", True)
        self.assertEqual((values.getAsInteger("a"), values.getAsInteger("b"), values.getAsInteger("c"), values.getAsString("a"),
                          values.getAsLong("zz"), values.getAsBoolean("e"), values.getAsBoolean("b"), values.getAsDouble("b"),
                          values.getAsInteger("e"), values.getAsShort("b"), values.size(), values.containsKey("d"), values.get("d"),
                          str(values), sorted(values.keySet())),
                         (5, 12, 1, "5", None, True, False, 12.0, None, 12, 5, True, None, "a=5 b=12 c=1.9 d=null e=true", list("abcde")))
        values.remove("a")
        self.assertEqual((values.containsKey("a"), content.ContentValues(values) == values), (False, True))
        name = content.ComponentName("com.a", "com.a.B")
        self.assertEqual((name.getPackageName(), name.getClassName(), name.getShortClassName(), name.flattenToString(),
                          name.flattenToShortString(), str(name), content.ComponentName.unflattenFromString("com.a/.B"),
                          content.ComponentName.unflattenFromString("broken")),
                         ("com.a", "com.a.B", ".B", "com.a/com.a.B", "com.a/.B", "ComponentInfo{com.a/com.a.B}", name, None))
        filter_ = content.IntentFilter("ACTION_X")
        filter_.addAction("ACTION_Y")
        filter_.addAction("ACTION_X")
        filter_.addCategory("CAT")
        filter_.addDataType("image/*")
        self.assertEqual((filter_.countActions(), filter_.hasAction("ACTION_Y"), filter_.getAction(0), list(filter_.actionsIterator()),
                          filter_.hasCategory("CAT"), filter_.hasDataType("image/png"), filter_.hasDataType("text/plain"),
                          content.IntentFilter(filter_).countActions(), filter_.getPriority()),
                         (2, True, "ACTION_X", ["ACTION_X", "ACTION_Y"], True, True, False, 2, 0))
        with self.assertRaises(content.IntentFilter.MalformedMimeTypeException):
            content.IntentFilter("a", "bad/")

    def test_dialog_interface(self):
        dialog = content.DialogInterface
        self.assertEqual((dialog.BUTTON_POSITIVE, dialog.BUTTON_NEGATIVE, dialog.BUTTON_NEUTRAL), (-1, -2, -3))
        self.assertIs(dialog.OnDismissListener, content.CLASSES["android.content.DialogInterface$OnDismissListener"])

        class Listener(dialog.OnClickListener):
            def onClick(self, target, which):
                return which

        self.assertEqual((Listener().onClick(None, dialog.BUTTON_POSITIVE), isinstance(Listener(), dialog.OnClickListener)), (-1, True))
        with self.assertRaises(bridge.UnsupportedAPI):
            dialog.OnShowListener().onShow(None)


class GraphicsTests(unittest.TestCase):
    def test_canvas_nested_enum_matches_the_provider_registry(self):
        classes = javalib.local_classes()
        edge_type = classes["android.graphics.Canvas$EdgeType"]
        self.assertIs(classes["android.graphics.Canvas"], bitmap.Canvas)
        self.assertIs(edge_type, graphics.CLASSES["android.graphics.Canvas$EdgeType"])
        self.assertIs(bitmap.Canvas.EdgeType, edge_type)

    def test_color(self):
        color = graphics.Color
        self.assertEqual((color.WHITE, color.BLACK, color.RED, color.TRANSPARENT, color.DKGRAY), (-1, -16777216, -65536, 0, -12303292))
        self.assertEqual((color.parseColor("#FF0000"), color.parseColor("#80ff0000"), color.parseColor("Red"), color.parseColor("teal"),
                          color.argb(255, 1, 2, 3), color.rgb(255, 255, 255), color.argb(0.5, 1.0, 0.0, 0.0), color.alpha(-1),
                          color.red(color.RED), color.green(0x00123456), color.blue(0x00123456)),
                         (-65536, -2130771968, -65536, -16744320, -16711165, -1, -2130771968, 255, 255, 0x34, 0x56))
        for value, kind in (("#12345", lang.IllegalArgumentException), ("nocolor", lang.IllegalArgumentException),
                            ("#GGGGGG", lang.NumberFormatException)):
            with self.subTest(value), self.assertRaises(kind):
                color.parseColor(value)
        self.assertEqual((color.HSVToColor([0.0, 1.0, 1.0]), color.HSVToColor([120.0, 1.0, 1.0]), color.HSVToColor([240.0, 1.0, 1.0]),
                          color.HSVToColor(128, [0.0, 0.0, 1.0]), color.HSVToColor([400.0, 1.0, 1.0]), color.HSVToColor([0.0, 0.0, 0.0])),
                         (color.RED, color.GREEN, color.BLUE, color.argb(128, 255, 255, 255), color.RED, color.BLACK))
        hsv = [0.0] * 3
        color.colorToHSV(color.parseColor("#336699"), hsv)
        self.assertEqual(hsv[0], 210.0)
        self.assertAlmostEqual(hsv[1], 2 / 3, places=6)
        self.assertAlmostEqual(hsv[2], 0.6, places=6)
        color.colorToHSV(color.GRAY, hsv)
        self.assertEqual(hsv[:2], [0.0, 0.0])
        self.assertEqual((color.luminance(color.WHITE), color.luminance(color.BLACK)), (1.0, 0.0))
        with self.assertRaises(bridge.UnsupportedAPI):
            color.valueOf(1)

    def test_points_and_rectangles(self):
        rect = graphics.Rect(0, 0, 10, 20)
        self.assertEqual((rect.width(), rect.height(), rect.centerX(), rect.exactCenterY(), rect.contains(5, 5), rect.contains(10, 5),
                          rect.contains(graphics.Rect(1, 1, 2, 2)), rect.isEmpty(), graphics.Rect().isEmpty(), rect.hashCode(), str(rect),
                          rect.toShortString(), rect.flattenToString(), graphics.Rect.unflattenFromString("1 2 3 4"),
                          graphics.Rect.intersects(graphics.Rect(0, 0, 1, 1), graphics.Rect(1, 1, 2, 2)), rect.intersects(5, 5, 30, 30)),
                         (10, 20, 5, 10.0, True, False, True, False, True, 330, "Rect(0, 0 - 10, 20)", "[0,0][10,20]", "0 0 10 20",
                          graphics.Rect(1, 2, 3, 4), False, True))
        self.assertTrue(rect.intersect(5, 5, 30, 30))
        self.assertFalse(rect.intersect(100, 100, 200, 200))
        self.assertEqual(rect, graphics.Rect(5, 5, 10, 20))
        rect.union(0, 0, 3, 3)
        rect.offset(1, 1)
        rect.inset(1, 1)
        self.assertEqual((rect.left, rect.top, rect.right, rect.bottom, rect.to_bridge()), (2, 2, 10, 20, {"left": 2, "top": 2, "right": 10, "bottom": 20}))
        rect.left = 50
        rect.sort()
        self.assertEqual((rect.left, rect.right), (10, 50))
        with self.assertRaises(TypeError):
            graphics.Rect(0.5, 0, 1, 1)
        floating = graphics.RectF(graphics.Rect(2, 2, 10, 20))
        floating.offset(0.5, 0.5)
        rounded = graphics.Rect()
        floating.roundOut(rounded)
        self.assertEqual((str(floating), floating.centerX(), floating.width(), rounded, floating.contains(2.5, 2.5)),
                         ("RectF(2.5, 2.5, 10.5, 20.5)", 6.5, 8.0, graphics.Rect(2, 2, 11, 21), True))
        point = graphics.Point(1, 2)
        point.offset(1, 1)
        self.assertEqual((str(point), point.x, point.equals(2, 3), point.hashCode(), point == graphics.Point(2, 3), graphics.PointF(3, 4).length(),
                          graphics.PointF.length(3, 4), str(graphics.PointF(1.5, 2)), graphics.Insets.of(1, 2, 3, 4).top,
                          graphics.Insets.add(graphics.Insets.of(1, 1, 1, 1), graphics.Insets.NONE)),
                         ("Point(2, 3)", 2, True, 65, True, 5.0, 5.0, "PointF(1.5, 2.0)", 2, graphics.Insets.of(1, 1, 1, 1)))

    def test_matrix(self):
        matrix = graphics.Matrix()
        self.assertTrue(matrix.isIdentity())
        matrix.setScale(2, 3)
        self.assertTrue(matrix.postTranslate(10, 20))
        matrix.preRotate(90)
        points = [1.0, 0.0]
        matrix.mapPoints(points)
        self.assertEqual((points, str(matrix), matrix.isIdentity(), matrix.rectStaysRect(), matrix.isAffine()),
                         ([10.0, 23.0], "Matrix{[0.0, -2.0, 10.0][3.0, 0.0, 20.0][0.0, 0.0, 1.0]}", False, True, True))
        inverse = graphics.Matrix()
        self.assertTrue(matrix.invert(inverse))
        inverse.mapPoints(points)
        self.assertAlmostEqual(points[0], 1.0, places=5)
        self.assertAlmostEqual(points[1], 0.0, places=5)
        singular = graphics.Matrix()
        singular.setScale(0, 1)
        self.assertFalse(singular.invert(inverse))
        pivot = graphics.Matrix()
        pivot.setScale(2, 2, 1, 1)
        box = graphics.RectF(0, 0, 1, 1)
        self.assertTrue(pivot.mapRect(box))
        values = [0.0] * 9
        pivot.getValues(values)
        self.assertEqual((box, values, pivot == graphics.Matrix(pivot), pivot.mapRadius(2), pivot.hashCode()),
                         (graphics.RectF(-1, -1, 1, 1), [2.0, 0.0, -1.0, 0.0, 2.0, -1.0, 0.0, 0.0, 1.0], True, 4.0, 44))
        vectors = [1.0, 1.0]
        pivot.mapVectors(vectors)
        self.assertEqual(vectors, [2.0, 2.0])
        fitted = graphics.Matrix()
        self.assertTrue(fitted.setRectToRect(graphics.RectF(0, 0, 10, 10), graphics.RectF(0, 0, 100, 50), graphics.Matrix.ScaleToFit.CENTER))
        self.assertEqual(str(fitted), "Matrix{[5.0, 0.0, 25.0][0.0, 5.0, 0.0][0.0, 0.0, 1.0]}")
        concat = graphics.Matrix()
        concat.setConcat(pivot, pivot)
        fitted.setValues([1, 0, 0, 0, 1, 0, 0, 0, 1])
        self.assertEqual((concat.mapRadius(1), fitted.isIdentity()), (4.0, True))
        with self.assertRaises(bridge.UnsupportedAPI):
            matrix.setPolyToPoly([], 0, [], 0, 0)

    def test_color_matrix_constants_and_enums(self):
        saturation = graphics.ColorMatrix()
        saturation.setSaturation(0)
        row = saturation.getArray()[:5]
        self.assertEqual([round(item, 3) for item in row], [0.213, 0.715, 0.072, 0.0, 0.0])
        scale = graphics.ColorMatrix()
        scale.setScale(2, 2, 2, 1)
        live = saturation.getArray()
        saturation.postConcat(scale)
        self.assertIs(saturation.getArray(), live)
        self.assertEqual(([round(item, 3) for item in live[:3]], live[18], graphics.ColorMatrix(live) == saturation, len(saturation.to_bridge())),
                         ([0.426, 1.43, 0.144], 1.0, True, 20))
        saturation.reset()
        self.assertEqual(saturation, graphics.ColorMatrix())
        self.assertEqual((graphics.PixelFormat.TRANSLUCENT, graphics.PixelFormat.OPAQUE, graphics.PixelFormat.formatHasAlpha(1),
                          graphics.PixelFormat.formatHasAlpha(4), graphics.ImageFormat.JPEG, graphics.ImageFormat.getBitsPerPixel(0x11)),
                         (-3, -1, True, False, 256, 12))
        info = graphics.PixelFormat()
        graphics.PixelFormat.getPixelFormatInfo(graphics.PixelFormat.RGB_565, info)
        self.assertEqual((info.bitsPerPixel, info.bytesPerPixel), (16, 2))
        mode = graphics.PorterDuff.Mode
        self.assertEqual((mode.SRC_IN.name(), mode.SRC_IN.ordinal(), mode.valueOf("MULTIPLY").ordinal(), len(mode.values()),
                          graphics.Shader.TileMode.CLAMP.ordinal(), str(graphics.CLASSES["android.graphics.Bitmap$Config"].ARGB_8888),
                          graphics.CLASSES["android.graphics.Paint$Style"].STROKE.ordinal(),
                          graphics.CLASSES["android.graphics.drawable.GradientDrawable$Orientation"].TOP_BOTTOM.ordinal()),
                         ("SRC_IN", 5, 14, 18, 0, "ARGB_8888", 1, 0))
        with self.assertRaises(lang.IllegalArgumentException) as caught:
            mode.valueOf("NOPE")
        self.assertEqual(caught.exception.getMessage(), "No enum constant android.graphics.PorterDuff$Mode.NOPE")
        shader, local = graphics.Shader(), graphics.Matrix()
        self.assertFalse(shader.getLocalMatrix(local))
        local.setScale(2, 2)
        shader.setLocalMatrix(local)
        read = graphics.Matrix()
        self.assertEqual((shader.getLocalMatrix(read), read), (True, local))
        typeface = graphics.Typeface
        self.assertEqual((typeface.BOLD_ITALIC, typeface.DEFAULT_BOLD.isBold(), typeface.DEFAULT.getStyle(),
                          typeface.create("serif", typeface.BOLD_ITALIC).getStyle(), typeface.create(typeface.MONOSPACE, 500, True).getWeight(),
                          typeface.defaultFromStyle(typeface.BOLD) is typeface.DEFAULT_BOLD), (3, True, 0, 3, 500, True))
        with self.assertRaises(bridge.UnsupportedAPI):
            typeface.createFromFile("/font.ttf")


class UtilTests(unittest.TestCase):
    def test_base64_matches_android_flags(self):
        codec = util.Base64
        self.assertEqual((codec.encodeToString(b"hello", codec.DEFAULT), codec.encodeToString(b"hello", codec.NO_WRAP),
                          codec.encodeToString(b"\xfb\xff", codec.URL_SAFE | codec.NO_WRAP | codec.NO_PADDING),
                          bytes(codec.encode(b"x" * 60, codec.CRLF))[-2:], len(codec.encode(b"x" * 100, codec.DEFAULT)),
                          codec.encodeToString(b"", codec.DEFAULT), codec.encodeToString(b"abcdef", 2, 3, codec.NO_WRAP)),
                         ("aGVsbG8=\n", "aGVsbG8=", "-_8", b"\r\n", 138, "", "Y2Rl"))
        self.assertEqual((bytes(codec.decode("aGVsbG8=\n", codec.DEFAULT)), bytes(codec.decode("aGVsbG8", codec.DEFAULT)),
                          bytes(codec.decode(b"-_8", codec.URL_SAFE)), codec.decode("/w==", 0).to_bridge()), (b"hello", b"hello", b"\xfb\xff", [-1]))
        for broken in ("a", "!!!!", "aGVsbG8===", "aG=Vs"):
            with self.subTest(broken), self.assertRaises(lang.IllegalArgumentException) as caught:
                codec.decode(broken, 0)
        self.assertEqual(caught.exception.getMessage(), "bad base-64")

    def test_sparse_arrays_and_small_values(self):
        sparse = util.SparseArray()
        sparse.put(5, "e")
        sparse.put(1, "a")
        sparse.append(9, "z")
        self.assertEqual((sparse.size(), sparse.keyAt(0), sparse.valueAt(2), sparse.get(5), sparse.get(7), sparse.get(7, "d"), sparse.indexOfKey(9),
                          sparse.indexOfKey(4), sparse.indexOfValue("e"), str(sparse), list(sparse), 5 in sparse, sparse.to_bridge()),
                         (3, 1, "z", "e", None, "d", 2, -2, 1, "{1=a, 5=e, 9=z}", [1, 5, 9], True, {"1": "a", "5": "e", "9": "z"}))
        sparse.delete(5)
        sparse.removeAt(0)
        sparse.setValueAt(0, "Z")
        self.assertEqual((sparse.size(), sparse.keyAt(0), sparse.valueAt(0), sparse.clone().size()), (1, 9, "Z", 1))
        with self.assertRaises(lang.ArrayIndexOutOfBoundsException):
            sparse.keyAt(3)
        with self.assertRaises(TypeError):
            sparse.put(2 ** 40, "too wide")
        wide, integers, flags = util.LongSparseArray(), util.SparseIntArray(), util.SparseBooleanArray()
        wide.put(2 ** 40, "x")
        integers.put(3, 7)
        flags.put(1, True)
        self.assertEqual((wide.get(2 ** 40), integers.get(3), integers.get(4), integers.get(4, -1), flags.get(1), flags.get(2)),
                         ("x", 7, 0, -1, True, False))
        with self.assertRaises(TypeError):
            integers.put(1, "text")
        pair = util.Pair.create(1, "a")
        self.assertEqual((str(pair), pair.first, pair.second, pair == util.Pair(1, "a"), pair.hashCode(), list(pair), str(util.Size(3, 4)),
                          util.Size.parseSize("640x480").getWidth(), str(util.SizeF(1.5, 2)), util.Size(3, 4) == util.Size(3, 4)),
                         ("Pair{1 a}", 1, "a", True, 1 ^ 97, [1, "a"], "3x4", 640, "1.5x2.0", True))
        with self.assertRaises(lang.NumberFormatException):
            util.Size.parseSize("wide")
        metrics = util.DisplayMetrics()
        self.assertEqual((metrics.density, metrics.widthPixels, util.DisplayMetrics.DENSITY_DEFAULT), (0.0, 0, 160))
        metrics.density = metrics.scaledDensity = 3.0
        value = util.TypedValue
        self.assertEqual((value.applyDimension(value.COMPLEX_UNIT_DIP, 10, metrics), value.applyDimension(value.COMPLEX_UNIT_PX, 10, None),
                          value.applyDimension(value.COMPLEX_UNIT_SP, 2, metrics), value().resourceId, value.COMPLEX_UNIT_SP), (30.0, 10.0, 6.0, 0, 2))
        with self.assertRaises(bridge.UnsupportedAPI):
            metrics.setToDefaults()


class TextTests(unittest.TestCase):
    def test_spannable_string(self):
        value = text.SpannableString("hello world")
        bold, red = text.StyleSpan(1), text.ForegroundColorSpan(-65536)
        value.setSpan(bold, 0, 5, text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        value.setSpan(red, 6, 11, text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        self.assertIsInstance(value, lang.CharSequence)
        self.assertEqual((str(value), value.length(), len(value), value.charAt(4), value.getSpanStart(bold), value.getSpanEnd(red),
                          value.getSpanFlags(red), value.getSpans(0, 11, text.StyleSpan), value.getSpans(0, 11, lang.Object),
                          value.getSpans(0, 11, text.CharacterStyle), value.getSpans(0, 11, text.MetricAffectingSpan), value.getSpans(5, 6, None),
                          value.nextSpanTransition(0, 11, None), value.getSpanStart(object()), value.to_bridge(), bold.getStyle(),
                          red.getForegroundColor()),
                         ("hello world", 11, 11, "o", 0, 11, 33, [bold], [bold, red], [bold, red], [bold], [], 5, -1, "hello world", 1, -65536))
        part = value.subSequence(3, 8)
        self.assertEqual((str(part), type(part), part.getSpans(0, 5, None), part.getSpanEnd(bold), part.getSpanStart(red)),
                         ("lo wo", text.SpannableString, [bold, red], 2, 3))
        value.setSpan(bold, 1, 2, 0)
        value.removeSpan(red)
        self.assertEqual((value.getSpanStart(bold), value.getSpans(0, 11, None), str(text.SpannableString(value).getSpans(0, 11, None) == [bold])),
                         (1, [bold], "True"))
        with self.assertRaises(lang.IndexOutOfBoundsException) as caught:
            value.setSpan(bold, 5, 99, 0)
        self.assertEqual(caught.exception.getMessage(), "setSpan (5 ... 99) ends beyond length 11")
        self.assertFalse(hasattr(text.SpannedString("x"), "setSpan"))
        self.assertEqual(text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE, 33)

    def test_builder_edits_move_spans(self):
        builder = text.SpannableStringBuilder("abc")
        exclusive, inclusive = text.UnderlineSpan(), text.UnderlineSpan()
        builder.setSpan(exclusive, 0, 3, text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        self.assertIs(builder.append("def"), builder)
        self.assertEqual((str(builder), builder.getSpanEnd(exclusive)), ("abcdef", 3))
        builder.setSpan(inclusive, 0, 6, text.Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        builder.append("!").insert(0, ">")
        self.assertEqual((str(builder), builder.getSpanStart(inclusive), builder.getSpanEnd(inclusive), builder.getSpanStart(exclusive),
                          builder.getSpanEnd(exclusive)), (">abcdef!", 0, 8, 1, 4))
        builder.delete(1, 4)
        self.assertEqual((str(builder), builder.getSpanStart(exclusive), builder.getSpans(0, builder.length(), None)), (">def!", -1, [inclusive]))
        builder.replace(0, 1, "XY")
        styled = text.SpannableString("hello")
        bold = text.StyleSpan(1)
        styled.setSpan(bold, 0, 5, 33)
        builder.append(styled, 1, 3)
        link = text.URLSpan("https://example.invalid")
        builder.append("Z", link, 33)
        self.assertEqual((str(builder), builder.getSpanStart(inclusive), builder.getSpanEnd(inclusive), builder.getSpanStart(bold),
                          builder.getSpanEnd(bold), builder.getSpanStart(link), link.getURL(), builder.length()),
                         ("XYdef!elZ", 0, 9, 6, 8, 8, "https://example.invalid", 9))
        builder.clear()
        self.assertEqual((builder.length(), builder.getSpans(0, 0, None)), (0, []))
        with self.assertRaises(lang.IndexOutOfBoundsException):
            builder.delete(0, 5)

    def test_text_utils_and_spans(self):
        utils = text.TextUtils
        styled = text.SpannableString("s")
        mark = text.StrikethroughSpan()
        styled.setSpan(mark, 0, 1, 33)
        joined = utils.concat("a", styled)
        self.assertEqual((utils.isEmpty(None), utils.isEmpty(""), utils.isEmpty(styled), utils.equals("a", lang.String("a")), utils.equals(None, None),
                          utils.join(", ", [1, "b"]), utils.split("", ","), utils.split("a,b,", ","), utils.htmlEncode("<a href='x'>&\"</a>"),
                          utils.isDigitsOnly("123"), utils.isDigitsOnly("12a"), utils.getTrimmedLength("  ab "), utils.concat("a", "b"),
                          type(joined), joined.getSpanStart(mark), str(utils.expandTemplate("x ^1 y ^^ ^2", "ONE", "2")), utils.indexOf("hello", "l"),
                          utils.lastIndexOf("hello", "l"), utils.isGraphic(" \n"), utils.isGraphic(" a"), str(utils.TruncateAt.END),
                          utils.regionMatches("hello", 1, "well", 1, 3)),
                         (True, True, False, True, True, "1, b", [], ["a", "b", ""], "&lt;a href=&#39;x&#39;&gt;&amp;&quot;&lt;/a&gt;", True, False, 2,
                          "ab", text.SpannedString, 1, "x ONE y ^ 2", 2, 3, False, True, "END", True))
        with self.assertRaises(bridge.UnsupportedAPI):
            utils.ellipsize("text", None, 10.0, utils.TruncateAt.END)
        with self.assertRaises(lang.IllegalArgumentException):
            utils.expandTemplate("^3", "only")
        self.assertEqual((text.RelativeSizeSpan(1.5).getSizeChange(), text.AbsoluteSizeSpan(12, True).getDip(), text.AbsoluteSizeSpan(12).getDip(),
                          text.TypefaceSpan("serif").getFamily(), text.BackgroundColorSpan(-1).getBackgroundColor(), text.StyleSpan(2).getStyle(),
                          isinstance(text.URLSpan("u"), text.ClickableSpan), isinstance(text.StyleSpan(1), text.UpdateLayout),
                          text.CLASSES["android.text.Layout$Alignment"].ALIGN_CENTER.ordinal(),
                          text.InputType.TYPE_CLASS_NUMBER | text.InputType.TYPE_NUMBER_FLAG_DECIMAL, text.InputType.TYPE_TEXT_VARIATION_PASSWORD),
                         (1.5, True, False, "serif", -1, 2, True, True, 2, 8194, 128))
        self.assertEqual((text.Layout.Alignment.ALIGN_NORMAL.name(), text.Layout.DIR_RIGHT_TO_LEFT), ("ALIGN_NORMAL", -1))
        for call in (text.Layout, lambda: text.Layout.getDesiredWidth("text", None)):
            with self.assertRaises(bridge.UnsupportedAPI):
                call()
        with self.assertRaises(TypeError):
            text.ForegroundColorSpan()
        with self.assertRaises(TypeError):
            text.ForegroundColorSpan("red")
        limit = text.InputFilter.LengthFilter(5)
        self.assertEqual((limit.filter("abcdef", 0, 6, "xy", 2, 2), limit.filter("ab", 0, 2, "xy", 2, 2), limit.filter("ab", 0, 2, "12345", 5, 5),
                          limit.getMax(), text.InputFilter.AllCaps().filter("aB", 0, 2, "", 0, 0), text.InputFilter.AllCaps().filter("AB", 0, 2, "", 0, 0)),
                         ("abc", None, "", 5, "AB", None))

    def test_html(self):
        html = text.Html
        parsed = html.fromHtml("<p>Hello <b>bold</b> and <i>it</i><br>next <font color='#ff0000'>red</font> "
                               "<a href=\"https://example.invalid\">link</a></p><p>second   para</p>")
        self.assertEqual(str(parsed), "Hello bold and it\nnext red link\n\nsecond para\n\n")
        self.assertEqual([(type(span).__name__, parsed.getSpanStart(span), parsed.getSpanEnd(span)) for span in parsed.getSpans(0, parsed.length(), None)],
                         [("StyleSpan", 6, 10), ("StyleSpan", 15, 17), ("ForegroundColorSpan", 23, 26), ("URLSpan", 27, 31)])
        self.assertEqual(parsed.getSpans(0, parsed.length(), text.ForegroundColorSpan)[0].getForegroundColor(), -65536)
        self.assertIsInstance(parsed, text.Spanned)
        self.assertEqual((str(html.fromHtml("a<br>b &amp; c")), str(html.fromHtml("<p>a</p><p>b</p>", html.FROM_HTML_MODE_COMPACT)),
                          str(html.fromHtml("<h1>T</h1>x")), str(html.fromHtml("x<img src='y'>z")), str(html.fromHtml("plain")),
                          html.escapeHtml("a  <b> \u00e9"), html.fromHtml("<u>u</u>").to_bridge()),
                         ("a\nb & c", "a\nb\n", "T\n\nx", "x\ufffcz", "plain", "a&nbsp; &lt;b&gt; &#233;", "u"))
        with self.assertRaises(bridge.UnsupportedAPI):
            html.fromHtml("x", 0, object(), None)
        with self.assertRaises(bridge.UnsupportedAPI):
            html.toHtml(parsed)


class ComposeHelperTests(unittest.TestCase):
    def test_log_records_are_split_on_character_boundaries(self):
        self.assertEqual(list(compose._chunks("")), [""])
        chunks = list(compose._chunks("\u00e9" * 3000 + "x"))
        self.assertEqual(([len(chunk.encode("utf-8")) for chunk in chunks], "".join(chunks)), ([4000, 2001], "\u00e9" * 3000 + "x"))
        self.assertEqual((compose.Log.__ayu_requires__, compose.ClipboardManager.__ayu_requires__, compose.Log.getStackTraceString(None),
                          compose.Log.DEBUG, compose.Log.isLoggable("t", compose.Log.VERBOSE)), (("log.write",), ("client.call",), "", 3, False))
        try:
            raise lang.IllegalStateException("synthetic")
        except lang.IllegalStateException as error:
            self.assertIn("java.lang.IllegalStateException: synthetic", compose.Log.getStackTraceString(error))


if __name__ == "__main__":
    unittest.main()
