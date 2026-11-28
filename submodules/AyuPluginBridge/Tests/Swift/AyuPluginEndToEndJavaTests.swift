import Foundation
import XCTest
@testable import AyuPluginBridge

/// The Java facade: host class adapters and Python-local classes used by one plugin.
@MainActor
final class AyuPluginEndToEndJavaTests: XCTestCase {
    func testHostAdaptersConstructInvokeAndReadFields() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_java_host", """
        from android.graphics import Paint, Typeface
        from android.graphics.drawable import ColorDrawable, GradientDrawable
        from android.net import Uri
        from android.text import SpannableString, TextUtils
        from android.text.style import ForegroundColorSpan
        from android.util import TypedValue
        from android.view import Gravity, View, ViewGroup
        from android.widget import FrameLayout, LinearLayout, TextView
        from base_plugin import BasePlugin
        from client_utils import get_last_fragment, get_user_config
        from hook_utils import find_class
        from java import cast, jarray, jclass, jfloat, jint
        from java.lang import Float, String
        from org.telegram.messenger import AndroidUtilities, ApplicationLoader, LocaleController, UserConfig

        \(AyuEndToEnd.recorder)


        class HostJavaPlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                uri = Uri.parse("https://user@example.org:8443/a/b%20c/last?item=first&item=second&empty=#frag")
                self.record("uri", lambda: [uri.getScheme(), uri.getHost(), uri.getPort(), uri.getPath(), uri.getEncodedPath(),
                                            uri.getLastPathSegment(), uri.getQueryParameter("item"), uri.getQueryParameter("empty"),
                                            uri.getQueryParameter("absent"), uri.getFragment(), uri.toString()])
                self.record("uri_class", lambda: [uri.getClass().getName(), uri.getClass().getSimpleName(), Uri.getName()])
                self.record("uri_missing_member", lambda: [hasattr(uri, "build" + "Upon"), getattr(uri, "normalize" + "Scheme", "absent")])
                self.record("uri_missing_call", lambda: getattr(uri, "build" + "Upon")())
                self.record("uri_no_constructor", lambda: globals()["Uri"]())

                paint = Paint(Paint.ANTI_ALIAS_FLAG)
                self.record("paint_flags", lambda: [Paint.ANTI_ALIAS_FLAG, paint.getFlags(), paint.isAntiAlias()])
                self.record("paint_color", lambda: [paint.setColor(-65536), paint.getColor(), paint.setAlpha(128), paint.getAlpha(), paint.getColor()])
                self.record("paint_stroke", lambda: [paint.setStrokeWidth(2.5), paint.getStrokeWidth(), paint.setStrokeWidth(4.0), paint.getStrokeWidth(), type(paint.getStrokeWidth()).__name__])
                self.record("paint_style", lambda: [paint.setStyle(Paint.Style.STROKE), paint.getStyle().getClass().getName()])
                def number_types():
                    context = ApplicationLoader.applicationContext
                    row = LinearLayout(context)
                    row.addView(TextView(context))
                    row.setPadding(4, 0, 4, 0)
                    row.setAlpha(1.0)
                    floats = jarray(jfloat)([1, 2.5])
                    ints = jarray(jint)([1, 2])
                    params = LinearLayout.LayoutParams(-1, -2, 1)
                    values = [paint.getTextSize(), row.getAlpha(), row.getChildCount(), row.getPaddingLeft(), row.getVisibility(), View.GONE,
                              floats[0], ints[0], params.weight, params.width]
                    return [type(value).__name__ for value in values] + [str(Float.valueOf(2).floatValue()), type(AndroidUtilities.dpf2(3)).__name__]
                self.record("number_types", number_types)
                self.record("paint_bad_argument", lambda: paint.setColor("red"))
                self.record("paint_kwargs", lambda: paint.setColor(color=1))

                self.record("constants", lambda: [View.VISIBLE, View.INVISIBLE, View.GONE, Gravity.CENTER, Gravity.LEFT | Gravity.TOP,
                                                  ViewGroup.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT, TypedValue.COMPLEX_UNIT_DIP])
                self.record("static_methods", lambda: [TextUtils.isEmpty(""), TextUtils.isEmpty(None), TextUtils.isEmpty("x"), AndroidUtilities.dp(10) > 0])
                self.record("find_class", lambda: [find_class("android.net.Uri").parse("tg://resolve").getScheme(), find_class("no.such." + "Class")])
                self.record("jclass_undeclared", lambda: jclass("android.hardware." + "camera2.CameraManager"))

                context = ApplicationLoader.applicationContext
                self.record("context", lambda: [context.getClass().getName(), get_last_fragment().getParentActivity().getClass().getName()])
                text = TextView(context)
                self.record("text_view", lambda: [text.setText("hello"), str(text.getText()), text.setTextSize(TypedValue.COMPLEX_UNIT_DIP, 15), text.setTextColor(-1),
                                                  text.setGravity(Gravity.CENTER), text.getGravity(), text.setVisibility(View.GONE), text.getVisibility(),
                                                  text.setAlpha(0.5), text.getAlpha(), text.setTag("tag"), text.getTag()])
                layout = LinearLayout(context)
                params = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                self.record("layout_fields", lambda: [params.width, params.height, params.weight, params.leftMargin])
                def write_fields():
                    params.weight = 1.5
                    params.leftMargin = 12
                    params.gravity = Gravity.CENTER
                    return [params.weight, params.leftMargin, params.gravity]
                self.record("layout_writes", write_fields)
                self.record("layout_margins", lambda: [params.setMargins(1, 2, 3, 4), params.leftMargin, params.topMargin, params.rightMargin, params.bottomMargin])
                self.record("layout_unknown_field", lambda: getattr(params, "eleva" + "tion"))
                self.record("tree", lambda: [layout.setOrientation(LinearLayout.VERTICAL), layout.addView(text, params), layout.getChildCount(),
                                             layout.getChildAt(0).getClass().getName(), text.getParent().getClass().getName(),
                                             text.getLayoutParams().getClass().getName(), layout.removeView(text), layout.getChildCount()])
                frame = FrameLayout(context)
                self.record("frame_params", lambda: [frame.addView(layout, FrameLayout.LayoutParams(-1, -2)), layout.getLayoutParams().width])
                self.record("drawables", lambda: [text.setBackground(ColorDrawable(-16777216)), text.getBackground().getClass().getName(),
                                                  GradientDrawable().setCornerRadius(8.0)])
                self.record("typeface", lambda: [text.setTypeface(Typeface.DEFAULT_BOLD), Typeface.DEFAULT.getClass().getName()])
                self.record("spannable", lambda: (lambda span: [span.setSpan(ForegroundColorSpan(-65536), 0, 4, 33), span.length(), span.toString(), text.setText(span)])(SpannableString("span text")))

                self.record("arrays", lambda: (lambda values: [len(values), values[0], values[2], list(values)])(jarray(jint)([1, 2, 3])))
                self.record("array_write", lambda: (lambda values: [values.__setitem__(1, 9), list(values)])(jarray(jint)([1, 2, 3])))
                self.record("array_bounds", lambda: jarray(jint)([1])[5])
                self.record("cast", lambda: [cast(View, text).getClass().getName(), cast(TextView, text).getText() is not None])
                self.record("cast_wrong", lambda: cast(LinearLayout, text))

                config = get_user_config()
                self.record("account", lambda: [UserConfig.selectedAccount, config.getClientUserId(), config.isClientActivated(),
                                                config.getCurrentUser().id, config.getCurrentUser().first_name, config.getCurrentUser().username,
                                                UserConfig.getInstance(UserConfig.selectedAccount).getClientUserId()])
                self.record("locale", lambda: [type(LocaleController.getInstance().getCurrentLocale().getLanguage()).__name__, LocaleController.getInstance().isRTL() in (True, False)])
                self.record("string", lambda: [String("abc").length(), String.valueOf(12), str(String("abc"))])
        """))
        func stored(_ key: String) -> AyuBridgeValue { stack.stored(id, key) }
        func refusal(_ key: String, _ prefix: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(stored(key).string?.hasPrefix(prefix), true, "\(key): \(stored(key))", file: file, line: line)
        }
        let address = "https://user@example.org:8443/a/b%20c/last?item=first&item=second&empty=#frag"
        XCTAssertEqual(stored("uri"), .array([.string("https"), .string("example.org"), .integer(8443), .string("/a/b c/last"), .string("/a/b%20c/last"),
            .string("last"), .string("first"), .string(""), .null, .string("frag"), .string(address)]))
        XCTAssertEqual(stored("uri_class"), .array([.string("android.net.Uri"), .string("Uri"), .string("android.net.Uri")]))
        XCTAssertEqual(stored("uri_missing_member"), .array([.bool(false), .string("absent")]), "A missing member reads as a missing attribute")
        refusal("uri_missing_call", "!MissingMember: UNSUPPORTED_API")
        refusal("uri_no_constructor", "!BridgeError: UNSUPPORTED_API")
        XCTAssertEqual(stored("paint_flags"), .array([.integer(1), .integer(1), .bool(true)]))
        XCTAssertEqual(stored("paint_color"), .array([.null, .integer(-65536), .null, .integer(128), .integer(-2_130_771_968)]))
        XCTAssertEqual(stored("paint_stroke"), .array([.null, .number(2.5), .null, .number(4), .string("float")]))
        XCTAssertEqual(stored("number_types"), .array([.string("float"), .string("float"), .string("int"), .string("int"), .string("int"), .string("int"),
                                                       .string("float"), .string("int"), .string("float"), .string("int"), .string("2.0"), .string("float")]))
        refusal("paint_bad_argument", "!BridgeError: UNSUPPORTED_API")
        refusal("paint_kwargs", "!BridgeError: UNSUPPORTED_API")
        XCTAssertEqual(stored("constants"), .array([.integer(0), .integer(4), .integer(8), .integer(17), .integer(51), .integer(-1), .integer(-2), .integer(1)]))
        XCTAssertEqual(stored("static_methods"), .array([.bool(true), .bool(true), .bool(false), .bool(true)]))
        refusal("find_class", "!UnsupportedAPI: UNSUPPORTED_API: Java class is not declared by host: no.such.Class")
        refusal("jclass_undeclared", "!UnsupportedAPI: UNSUPPORTED_API")
        XCTAssertEqual(stored("context"), .array([.string("android.content.Context"), .string("android.content.Context")]))
        XCTAssertEqual(stored("text_view"), .array([.null, .string("hello"), .null, .null, .null, .integer(17), .null, .integer(8), .null, .number(0.5), .null, .string("tag")]))
        XCTAssertEqual(stored("layout_fields"), .array([.integer(-1), .integer(-2), .number(0), .integer(0)]), "The weight is a Java float")
        XCTAssertEqual(stored("layout_writes"), .array([.number(1.5), .integer(12), .integer(17)]))
        XCTAssertEqual(stored("layout_margins"), .array([.null, .integer(1), .integer(2), .integer(3), .integer(4)]), "setMargins is reached through java.member")
        refusal("layout_unknown_field", "!MissingMember: UNSUPPORTED_API")
        XCTAssertEqual(stored("tree"), .array([.null, .null, .integer(1), .string("android.widget.TextView"), .string("android.widget.LinearLayout"),
            .string("android.widget.LinearLayout$LayoutParams"), .null, .integer(0)]))
        XCTAssertEqual(stored("frame_params"), .array([.null, .integer(-1)]))
        XCTAssertEqual(stored("drawables").array?.prefix(2), [.null, .string("android.graphics.drawable.ColorDrawable")])
        XCTAssertEqual(stored("typeface"), .array([.null, .string("android.graphics.Typeface")]))
        XCTAssertEqual(stored("spannable"), .array([.null, .integer(9), .string("span text"), .null]))
        XCTAssertEqual(stored("arrays"), .array([.integer(3), .integer(1), .integer(3), .array([.integer(1), .integer(2), .integer(3)])]))
        XCTAssertEqual(stored("array_write"), .array([.null, .array([.integer(1), .integer(9), .integer(3)])]))
        refusal("array_bounds", "!IndexError")
        XCTAssertEqual(stored("cast"), .array([.string("android.widget.TextView"), .bool(true)]))
        refusal("cast_wrong", "!BridgeError")
        let user = AyuBridgeValue.integer(9_007_199_254_740_993)
        XCTAssertEqual(stored("account"), .array([.integer(0), user, .bool(true), user, .string("Synthetic"), .string("synthetic"), user]), "Int64 user ids stay exact")
        XCTAssertEqual(stored("locale"), .array([.string("str"), .bool(true)]))
        XCTAssertEqual(stored("string"), .array([.integer(3), .string("12"), .string("abc")]), "str() of a host object is its toString()")
        XCTAssertEqual(stored("paint_style"), .array([.null, .string("android.graphics.Paint$Style")]))
        await stack.remove(id)
        stack.unbindApplication()
    }

    /// The published member table is what preflight trusts; `java.member` is what a running plugin gets.
    func testEveryDeclaredMemberOfEveryHostClassResolves() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_members", """
        import ayu_bridge
        from base_plugin import BasePlugin
        from java import jclass


        class MembersPlugin(BasePlugin):
            def on_plugin_load(self):
                capabilities = ayu_bridge.runtime.capabilities
                table = capabilities["members"]
                classes = table["classes"] if "version" in table else table
                missing, checked, constructed = [], 0, 0
                def resolve(target, label, name):
                    nonlocal checked
                    checked += 1
                    try:
                        getattr(target, name)
                    except ayu_bridge.MissingMember:
                        missing.append(label + "." + name)
                    except ayu_bridge.BridgeError:
                        pass
                for name in sorted(classes):
                    if name in capabilities["local_classes"]:
                        continue
                    entry = classes[name]
                    facade = jclass(name)
                    for member in list(entry["static_methods"]) + list(entry["static_fields"]):
                        resolve(facade, name, member)
                    if not entry["constructor"]:
                        continue
                    try:
                        instance = facade()
                    except ayu_bridge.BridgeError:
                        continue
                    constructed += 1
                    for member in list(entry["methods"]) + list(entry["fields"]):
                        resolve(instance, name + "#", member)
                self.set_setting("missing", missing)
                self.set_setting("counts", [checked > 500, constructed > 10])
        """))
        XCTAssertEqual(stack.stored(id, "missing"), .array([]), "Declared members that java.member refuses")
        XCTAssertEqual(stack.stored(id, "counts"), .array([.bool(true), .bool(true)]))
        await stack.remove(id)
        stack.unbindApplication()
    }

    func testPythonLocalClassesWorkBesideHostAdapters() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_java_local", """
        import sys
        import ayu_bridge
        from android.graphics import Color, Paint, PorterDuff, PorterDuffColorFilter, Rect
        from android.net import Uri
        from android.os import Bundle, SystemClock
        from android.text import SpannableString, TextUtils
        from android.view import View
        from android.widget import ImageView, LinearLayout, TextView
        from base_plugin import BasePlugin
        from java import jclass
        from java.lang import Boolean, Integer, Long, Math, String, StringBuilder, System
        from java.net import URLEncoder
        from java.util import ArrayList, Collections, HashMap, Locale
        from java.util.concurrent.atomic import AtomicBoolean, AtomicLong
        from org.json import JSONArray, JSONObject
        from org.telegram.messenger import ApplicationLoader

        \(AyuEndToEnd.recorder)


        class LocalJavaPlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                capabilities = ayu_bridge.runtime.capabilities
                host, local = set(capabilities["classes"]), set(capabilities["local_classes"])
                overrides = set(sys.modules["_ayu_" + "javalib"].host_override_names(capabilities["operations"]))

                def resolution():
                    wrong = []
                    for name in sorted(host | overrides):
                        resolved = jclass(name)
                        if isinstance(resolved, type) != (name in local):
                            wrong.append(name)
                    return [wrong, sorted(overrides - local), len(host & local) == len(host & overrides)]
                self.record("resolution", resolution)
                self.record("kinds", lambda: [isinstance(cls, type) for cls in (Color, Rect, Bundle, ArrayList, HashMap, Integer, System, URLEncoder, Collections, Uri, Paint, TextUtils, TextView, String)])

                self.record("color", lambda: [Color.parseColor("#FF0000"), Color.argb(255, 0, 0, 255), Color.RED, Color.alpha(-2130771968), Color.rgb(1, 2, 3)])
                self.record("collections", lambda: (lambda items, table: [items.add("a"), items.add("b"), items.size(), items.get(1), items.contains("a"), list(items),
                                                                          table.put("k", 1), table.get("k"), table.containsKey("k"), table.getOrDefault("z", 9), table.size(),
                                                                          Collections.emptyList().size()])(ArrayList(), HashMap()))
                self.record("boxes", lambda: [Integer.parseInt("42"), Integer.MAX_VALUE, Integer.valueOf(7).intValue(), Long.parseLong("9007199254740993"), Long.MAX_VALUE,
                                              Boolean.parseBoolean("TRUE"), Math.max(1, 2), Math.abs(-2.5)])
                self.record("text", lambda: [StringBuilder().append("a").append(1).toString(), URLEncoder.encode("a b&c/d", "UTF-8"), String.valueOf(12)])
                self.record("json", lambda: (lambda value: [value.getInt("a"), value.optString("missing", "d"), value.getJSONArray("l").length(), JSONArray("[1,2]").getInt(1),
                                                            value.put("b", True).getBoolean("b")])(JSONObject('{"a": 1, "l": [1, 2, 3]}')))
                self.record("bundle", lambda: (lambda bundle: [bundle.putString("k", "v"), bundle.getString("k"), bundle.getInt("absent", 5), bundle.containsKey("k")])(Bundle()))
                self.record("clocks", lambda: [System.currentTimeMillis() > 1600000000000, SystemClock.elapsedRealtime() >= 0, SystemClock.uptimeMillis() >= 0])
                self.record("atomics", lambda: (lambda flag, count: [flag.compareAndSet(False, True), flag.get(), count.incrementAndGet(), count.addAndGet(5)])(AtomicBoolean(False), AtomicLong(0)))
                self.record("rect", lambda: (lambda rect: [rect.width(), rect.height(), rect.contains(5, 5), rect.left, rect.centerX()])(Rect(0, 0, 10, 20)))

                paint = Paint()
                context = ApplicationLoader.applicationContext
                text = TextView(context)
                layout = LinearLayout(context)
                layout.addView(text)
                self.record("local_values_in_host_calls", lambda: [paint.setColor(Color.parseColor("#00FF00")), paint.getColor(), paint.getColor() == Color.GREEN,
                                                                    text.setTextColor(Color.RED), text.setVisibility(View.VISIBLE), text.setText(StringBuilder("built").toString()), text.getText()])
                self.record("local_object_as_host_argument", lambda: text.setTag(ArrayList()))
                self.record("boxed_as_host_argument", lambda: [paint.setAlpha(Integer.valueOf(64)), paint.getAlpha()])

                uri = Uri.parse("https://example.org/x")
                span = SpannableString("span")
                self.record("identity", lambda: [uri == uri, text.getParent() == layout, layout.getChildAt(0) == text, text.getParent() is not layout,
                                                 layout.getChildAt(0) in [text], {text: 1}.get(layout.getChildAt(0))])
                self.record("enum_constants", lambda: [Paint.Style.FILL == Paint.Style.FILL, (paint.setStyle(Paint.Style.STROKE), paint.getStyle() == Paint.Style.STROKE)[1], paint.getStyle() != Paint.Style.FILL])
                def constant_identity():
                    names = {Paint.Style.FILL: "fill", Paint.Style.STROKE: "stroke", Paint.Cap.ROUND: "round"}
                    paint.setStyle(Paint.Style.FILL)
                    paint.setStrokeCap(Paint.Cap.ROUND)
                    filter = PorterDuffColorFilter(-1, PorterDuff.Mode.SRC_IN)
                    return [Paint.Style.FILL is Paint.Style.FILL, paint.getStyle() is Paint.Style.FILL, names[paint.getStyle()], names[paint.getStrokeCap()],
                            Paint.Style.FILL == Paint.Style.STROKE, Paint.Style.FILL in (Paint.Style.STROKE, Paint.Style.FILL_AND_STROKE),
                            filter.getMode() is PorterDuff.Mode.SRC_IN, ImageView.ScaleType.CENTER_CROP is ImageView.ScaleType.CENTER_CROP,
                            TextUtils.TruncateAt.END == TextUtils.TruncateAt.END, Locale.US is Locale.US, Locale.US == Locale.UK,
                            ApplicationLoader.applicationContext is ApplicationLoader.applicationContext,
                            Uri.parse("https://example.org/x") == uri, len({Paint.Style.FILL, Paint.Style.FILL, Paint.Style.STROKE})]
                self.record("constant_identity", constant_identity)
                self.record("str", lambda: [str(uri), "%s" % uri, str(span), str(String("abc")), repr(uri), str(Integer.valueOf(7)), str(ArrayList())])
                self.record("truth", lambda: [bool(uri), uri is not None])
        """))
        func stored(_ key: String) -> AyuBridgeValue { stack.stored(id, key) }
        XCTAssertEqual(stored("resolution"), .array([.array([]), .array([]), .bool(true)]), "A host class resolves to the host facade unless a usable local class overrides it")
        XCTAssertEqual(stored("kinds"), .array(Array(repeating: .bool(true), count: 9) + Array(repeating: .bool(false), count: 5)))
        XCTAssertEqual(stored("color"), .array([.integer(-65536), .integer(-16_776_961), .integer(-65536), .integer(128), .integer(-16_711_165)]))
        XCTAssertEqual(stored("collections"), .array([.bool(true), .bool(true), .integer(2), .string("b"), .bool(true), .array([.string("a"), .string("b")]),
            .null, .integer(1), .bool(true), .integer(9), .integer(1), .integer(0)]))
        XCTAssertEqual(stored("boxes"), .array([.integer(42), .integer(2_147_483_647), .integer(7), .integer(9_007_199_254_740_993), .integer(Int64.max), .bool(true), .integer(2), .number(2.5)]))
        XCTAssertEqual(stored("text"), .array([.string("a1"), .string("a+b%26c%2Fd"), .string("12")]))
        XCTAssertEqual(stored("json"), .array([.integer(1), .string("d"), .integer(3), .integer(2), .bool(true)]))
        XCTAssertEqual(stored("bundle"), .array([.null, .string("v"), .integer(5), .bool(true)]))
        XCTAssertEqual(stored("clocks"), .array([.bool(true), .bool(true), .bool(true)]))
        XCTAssertEqual(stored("atomics"), .array([.bool(true), .bool(true), .integer(1), .integer(6)]))
        XCTAssertEqual(stored("rect"), .array([.integer(10), .integer(20), .bool(true), .integer(0), .integer(5)]))
        XCTAssertEqual(stored("local_values_in_host_calls"), .array([.null, .integer(-16_711_936), .bool(true), .null, .null, .null, .string("built")]))
        XCTAssertEqual(stored("local_object_as_host_argument").string?.hasPrefix("!BridgeError: INVALID_ARGUMENTS"), true, "A Python-local object is refused by a host method, not dropped")
        XCTAssertEqual(stored("boxed_as_host_argument"), .array([.null, .integer(64)]))
        XCTAssertEqual(stored("identity"), .array([.bool(true), .bool(true), .bool(true), .bool(false), .bool(true), .integer(1)]), "References to one host object are one Python object")
        XCTAssertEqual(stored("str"), .array([.string("https://example.org/x"), .string("https://example.org/x"), .string("span"), .string("abc"), .string("<native android.net.Uri>"), .string("7"), .string("[]")]))
        XCTAssertEqual(stored("truth"), .array([.bool(true), .bool(true)]))
        XCTAssertEqual(stored("enum_constants"), .array([.bool(true), .bool(true), .bool(true)]))
        XCTAssertEqual(stored("constant_identity"), .array([
            .bool(true), .bool(true), .string("fill"), .string("round"), .bool(false), .bool(false), .bool(true), .bool(true), .bool(true),
            .bool(true), .bool(false), .bool(true), .bool(false), .integer(2),
        ]), "Constants are singletons; two parsed Uris stay two objects")
        await stack.remove(id)
        stack.unbindApplication()
    }
}
