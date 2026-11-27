import Foundation
import XCTest
@testable import AyuPluginBridge

/// Typeface, Theme and view members through the real SDK: each plugin must pass the member-aware
/// preflight against the host's own member table before it runs.
@MainActor
final class AyuPluginEndToEndMembersTests: XCTestCase {
    func testTypefacesWithWeightAndFamily() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_members_typeface", """
        from android.graphics import Paint, Typeface
        from android.widget import EditText, TextView
        from base_plugin import BasePlugin
        from org.telegram.messenger import AndroidUtilities, ApplicationLoader

        \(AyuEndToEnd.recorder)


        class TypefacePlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                context = ApplicationLoader.applicationContext
                self.record("presets", lambda: [Typeface.DEFAULT.getWeight(), Typeface.DEFAULT_BOLD.getStyle(), Typeface.DEFAULT_BOLD.getWeight(),
                                                Typeface.MONOSPACE.getStyle(), Typeface.SERIF.isBold(), Typeface.SANS_SERIF.isItalic(),
                                                Typeface.BOLD, Typeface.BOLD_ITALIC])
                self.record("create", lambda: [Typeface.create("sans-serif-medium", Typeface.NORMAL).getWeight(),
                                               Typeface.create("sans-serif-medium", Typeface.BOLD).getWeight(),
                                               Typeface.create(Typeface.DEFAULT, Typeface.BOLD).isBold(),
                                               Typeface.create(None, 500, True).isItalic(),
                                               Typeface.create(Typeface.DEFAULT, 500, False).getStyle(),
                                               Typeface.create("no-such-family", Typeface.ITALIC).getWeight(),
                                               Typeface.defaultFromStyle(Typeface.BOLD).getWeight()])
                self.record("create_unavailable", lambda: Typeface.create("cursive", Typeface.NORMAL))
                self.record("create_weight", lambda: Typeface.create(Typeface.DEFAULT, 1200, False))
                bold = AndroidUtilities.bold()
                self.record("telegram", lambda: [bold.getWeight(), bold.isBold(), bold.getClass().getName(),
                                                 AndroidUtilities.getTypeface(AndroidUtilities.TYPEFACE_ROBOTO_MEDIUM).getWeight(),
                                                 AndroidUtilities.getTypeface("fonts/rmono.ttf").getStyle(),
                                                 AndroidUtilities.getTypeface(AndroidUtilities.TYPEFACE_ROBOTO_EXTRA_BOLD).getWeight(),
                                                 AndroidUtilities.getTypeface("fonts/absent.ttf")])
                text = TextView(context)
                self.record("text_view", lambda: [text.getTypeface(), text.setTypeface(bold), text.getTypeface().getWeight(),
                                                  text.setTypeface(text.getTypeface(), Typeface.BOLD), text.getTypeface().getWeight(),
                                                  text.setTypeface(None, Typeface.ITALIC), text.getTypeface().isItalic(),
                                                  text.setTypeface(Typeface.MONOSPACE), text.setTextSize(18), text.getTypeface().getStyle(),
                                                  text.setTypeface(None), text.getTypeface()])
                edit = EditText(context)
                self.record("edit_text", lambda: [edit.setTypeface(Typeface.DEFAULT_BOLD), edit.getTypeface().isBold()])
                paint = Paint()
                self.record("paint", lambda: [paint.getTypeface(), paint.setTypeface(Typeface.MONOSPACE).getClass().getName(),
                                              paint.getTypeface().getStyle(), paint.setTypeface(None), paint.getTypeface()])
                self.record("wrong_argument", lambda: text.setTypeface("bold"))
        """))
        func stored(_ key: String) -> AyuBridgeValue { stack.stored(id, key) }
        XCTAssertEqual(stored("presets"), .array([.integer(400), .integer(1), .integer(700), .integer(0), .bool(false), .bool(false), .integer(1), .integer(3)]))
        // Bold is 300 above the family's own weight; an unknown family is the default one.
        XCTAssertEqual(stored("create"), .array([.integer(500), .integer(800), .bool(true), .bool(true), .integer(0), .integer(400), .integer(700)]))
        XCTAssertEqual(stored("create_unavailable").string?.hasPrefix("!BridgeError: UNSUPPORTED_API"), true, "\(stored("create_unavailable"))")
        XCTAssertEqual(stored("create_weight").string?.hasPrefix("!BridgeError: INVALID_ARGUMENTS"), true, "\(stored("create_weight"))")
        // Telegram's bold is the medium weight; an asset that does not exist is null.
        XCTAssertEqual(stored("telegram"), .array([.integer(500), .bool(false), .string("android.graphics.Typeface"), .integer(500), .integer(0), .integer(800), .null]))
        XCTAssertEqual(stored("text_view"), .array([.null, .null, .integer(500), .null, .integer(700), .null, .bool(true), .null, .null, .integer(0), .null, .null]))
        XCTAssertEqual(stored("edit_text"), .array([.null, .bool(true)]))
        XCTAssertEqual(stored("paint"), .array([.null, .string("android.graphics.Typeface"), .integer(0), .null, .null]))
        XCTAssertEqual(stored("wrong_argument").string?.hasPrefix("!"), true, "\(stored("wrong_argument"))")
        await stack.remove(id)
    }

    func testThemeColorsFollowTheBoundPresentationTheme() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let dark = AyuTestBox(false)
        let palette: @Sendable () -> AyuPluginThemePalette = {
            AyuPluginThemePalette(isDark: dark.value, isNight: false, colors: [
                .dialogBackground: dark.value ? 0xFF1C_1C1D : 0xFFFF_FFFF, .checkFill: 0xFF00_7AFF, .checkForeground: 0xFFFF_FFFF,
                .listSeparator: 0xFFC8_C7CC, .listHighlight: 0xFFE5_E5EA, .listItemBackground: 0xFFFF_FFFF, .dialogAccent: 0xFF00_7AFF,
                .listDestructive: 0xFFFF_3B30,
            ])
        }
        stack.application.presentation.bind(palette: palette, language: { AyuPluginLanguage(code: "pt-br", baseCode: nil) })
        defer { stack.application.presentation.bind(palette: nil, language: nil) }
        let source = AyuEndToEnd.source(id: "e2e_members_theme", """
        from android.widget import FrameLayout, TextView
        from base_plugin import BasePlugin
        from org.telegram.messenger import AndroidUtilities, ApplicationLoader, LocaleController
        from org.telegram.ui.ActionBar import Theme

        \(AyuEndToEnd.recorder)


        class ThemePlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                context = ApplicationLoader.applicationContext
                self.record("keys", lambda: [Theme.key_dialogBackground, Theme.key_featuredStickers_addButton, Theme.key_divider,
                                             getattr(Theme, "key_text_RedRegular"), hasattr(Theme, "key_" + "dialogTextRed")])
                self.record("colors", lambda: [Theme.getColor(Theme.key_dialogBackground), Theme.getColor(Theme.key_featuredStickers_addButton),
                                               Theme.getColor(Theme.key_featuredStickers_buttonText), Theme.getColor(Theme.key_divider),
                                               Theme.getColor(Theme.key_dialogLinkSelection), Theme.getColor(Theme.key_text_RedBold, None)])
                self.record("dark", lambda: [Theme.isCurrentThemeDark(), Theme.isCurrentThemeNight(), Theme.getActiveTheme().isDark()])
                self.record("unfilled_slot", lambda: Theme.getColor(Theme.key_chats_name))
                self.record("unknown_key", lambda: Theme.getColor(799))
                button = TextView(context)
                row = FrameLayout(context)
                self.record("drawables", lambda: [
                    button.setBackground(Theme.createSimpleSelectorRoundRectDrawable(AndroidUtilities.dp(8), Theme.getColor(Theme.key_featuredStickers_addButton),
                                                                                      Theme.multAlpha(Theme.getColor(Theme.key_featuredStickers_buttonText), 0.2))),
                    button.getBackground().getClass().getName(),
                    row.setBackground(Theme.createSelectorDrawable(Theme.getColor(Theme.key_listSelector), 2)), row.getBackground().getClass().getName(),
                    row.setBackground(Theme.getSelectorDrawable(False)), row.setBackgroundDrawable(Theme.getSelectorDrawable(True)),
                    row.setBackground(Theme.createRoundRectDrawable(AndroidUtilities.dp(6), Theme.getColor(Theme.key_dialogBackground))),
                    row.getBackground().getClass().getName(), row.setBackground(Theme.createSelectorDrawable(0x20000000, 7, AndroidUtilities.dp(12)))])
                self.record("drawable_arguments", lambda: Theme.createRoundRectDrawable(4))
                info = LocaleController.getInstance().getCurrentLocaleInfo()
                self.record("language", lambda: [info.shortName, info.getLangCode(), info.baseLangCode, LocaleController.isRTL])
        """)
        let id = try await stack.start(source)
        func stored(_ key: String) -> AyuBridgeValue { stack.stored(id, key) }
        // Android's own key numbers; a key Android does not define is not an attribute.
        XCTAssertEqual(stored("keys"), .array([.integer(1), .integer(688), .integer(101), .integer(113), .bool(false)]))
        XCTAssertEqual(stored("colors"), .array([.integer(-1), .integer(Int64(Int32(bitPattern: 0xFF00_7AFF))), .integer(-1), .integer(Int64(Int32(bitPattern: 0xFFC8_C7CC))),
                                                 .integer(0x3300_7AFF), .integer(Int64(Int32(bitPattern: 0xFFFF_3B30)))]))
        XCTAssertEqual(stored("dark"), .array([.bool(false), .bool(false), .bool(false)]))
        XCTAssertEqual(stored("unfilled_slot").string?.hasPrefix("!BridgeError: UNSUPPORTED_API"), true, "\(stored("unfilled_slot"))")
        XCTAssertEqual(stored("unknown_key").string?.hasPrefix("!BridgeError: UNSUPPORTED_API"), true, "\(stored("unknown_key"))")
        let ripple = AyuBridgeValue.string("android.graphics.drawable.RippleDrawable")
        XCTAssertEqual(stored("drawables"), .array([.null, ripple, .null, ripple, .null, .null, .null, .string("android.graphics.drawable.ShapeDrawable"), .null]))
        XCTAssertEqual(stored("drawable_arguments").string?.hasPrefix("!BridgeError: INVALID_ARGUMENTS"), true, "\(stored("drawable_arguments"))")
        XCTAssertEqual(stored("language"), .array([.string("pt_br"), .string("pt-br"), .string(""), .bool(false)]))
        await stack.remove(id)

        // The same plugin under a dark theme reads the dark colours.
        dark.value = true
        let again = try await stack.start(source)
        XCTAssertEqual(stack.stored(again, "dark"), .array([.bool(true), .bool(false), .bool(true)]))
        XCTAssertEqual(stack.stored(again, "colors").array?.first, .integer(Int64(Int32(bitPattern: 0xFF1C_1C1D))))
        await stack.remove(again)

        // Without the app's presentation theme the colour members are preflight blockers, not UIKit defaults.
        stack.application.presentation.bind(palette: nil, language: nil)
        let preview = try await stack.preview(source)
        let blockers = preview.plugin.blockers.joined(separator: "\n")
        for member in ["Theme.key_dialogBackground", "Theme.getColor", "Theme.isCurrentThemeDark", "Theme.getSelectorDrawable", "LocaleInfo.shortName"] {
            XCTAssertTrue(blockers.contains(member), "\(member) is not a blocker in: \(blockers)")
        }
        XCTAssertFalse(blockers.contains("createSelectorDrawable"), blockers)
    }

    func testViewMembersAndGradientDrawables() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_members_views", """
        from android.content.res import ColorStateList
        from android.graphics.drawable import GradientDrawable
        from android.view import View
        from android.widget import EditText, FrameLayout, LinearLayout, ProgressBar, TextView
        from android_utils import OnLongClickListener
        from base_plugin import BasePlugin
        from java import dynamic_proxy, jarray, jfloat, jint
        from org.telegram.messenger import AndroidUtilities, ApplicationLoader

        \(AyuEndToEnd.recorder)


        class FocusListener(dynamic_proxy(View.OnFocusChangeListener)):
            def onFocusChange(self, view, has_focus):
                pass


        class LongClickListener(dynamic_proxy(View.OnLongClickListener)):
            def onLongClick(self, view):
                return True


        class ViewsPlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                context = ApplicationLoader.applicationContext
                text = TextView(context)
                self.record("text_metrics", lambda: [
                    text.getIncludeFontPadding(), text.setIncludeFontPadding(False), text.getIncludeFontPadding(),
                    text.setLineSpacing(AndroidUtilities.dp(4), 1.2), text.getLineSpacingExtra(), text.getLineSpacingMultiplier(),
                    text.setLetterSpacing(0.05), text.getLetterSpacing(), text.setMinHeight(AndroidUtilities.dp(48)), text.setMinWidth(100),
                    text.getMinHeight(), text.getMinWidth(), text.setTextIsSelectable(True), text.isTextSelectable()])
                self.record("float_types", lambda: [type(text.getLineSpacingExtra()).__name__, type(text.getLetterSpacing()).__name__, type(text.getMinHeight()).__name__])
                row = LinearLayout(context)
                frame = FrameLayout(context)
                self.record("long_click", lambda: [
                    row.isLongClickable(), row.setOnLongClickListener(OnLongClickListener(lambda view: True)), row.isLongClickable(),
                    text.setOnLongClickListener(LongClickListener()), frame.setOnLongClickListener(LongClickListener()),
                    row.setLongClickable(False), row.isLongClickable(), row.setOnLongClickListener(None)])
                self.record("weight_sum", lambda: [row.getWeightSum(), row.setWeightSum(3.0), row.getWeightSum()])
                edit = EditText(context)
                self.record("edit", lambda: [edit.setSelectAllOnFocus(True), edit.isCursorVisible(), edit.setCursorVisible(False), edit.isCursorVisible(),
                                             edit.setOnFocusChangeListener(FocusListener()), edit.setOnFocusChangeListener(None),
                                             edit.setMinHeight(40), edit.getMinHeight(), edit.setLetterSpacing(0.1)])
                spinner = ProgressBar(context)
                bar = ProgressBar(context, None, 0x01010078)
                self.record("progress", lambda: [
                    spinner.setIndeterminate(False), spinner.isIndeterminate(), bar.isIndeterminate(), bar.setIndeterminate(True), bar.isIndeterminate(),
                    spinner.setIndeterminateTintList(ColorStateList.valueOf(-65536)), bar.setProgressBackgroundTintList(ColorStateList.valueOf(-1)),
                    bar.setIndeterminateTintList(None)])
                gradient = GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, [-65536, -16776961])
                self.record("gradient", lambda: [
                    gradient.setCornerRadii([8.0, 8.0, 8.0, 8.0, 0.0, 0.0, 0.0, 0.0]) is gradient or gradient.getClass().getName(),
                    gradient.setColors(jarray(jint)([-1, -16777216, -65536])).getClass().getName(),
                    gradient.setGradientType(GradientDrawable.RADIAL_GRADIENT).getClass().getName(), gradient.setGradientRadius(120.0) is None,
                    gradient.setOrientation(GradientDrawable.Orientation.TOP_BOTTOM) is None, gradient.setCornerRadii(jarray(jfloat)([4.0] * 8)) is None,
                    gradient.setAlpha(200) is None, frame.setBackground(gradient), frame.getBackground().getClass().getName(),
                    GradientDrawable.Orientation.BL_TR.name(), GradientDrawable.Orientation.BL_TR.ordinal()])
                self.record("gradient_colors", lambda: gradient.setColors([-1]))
                self.record("gradient_radii", lambda: gradient.setCornerRadii([1.0, 2.0]))
                self.record("wrong_class", lambda: row.setLineSpacing(1.0, 1.0))
                self.record("wrong_argument", lambda: text.setLetterSpacing("wide"))
                self.record("edit_selectable", lambda: edit.setTextIsSelectable(True))
        """))
        func stored(_ key: String) -> AyuBridgeValue { stack.stored(id, key) }
        func refusal(_ key: String, _ prefix: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(stored(key).string?.hasPrefix(prefix), true, "\(key): \(stored(key))", file: file, line: line)
        }
        XCTAssertEqual(stored("text_metrics"), .array([.bool(true), .null, .bool(false), .null, .number(4), .number(1.2), .null, .number(0.05), .null, .null,
                                                       .integer(48), .integer(100), .null, .bool(true)]))
        XCTAssertEqual(stored("float_types"), .array([.string("float"), .string("float"), .string("int")]))
        XCTAssertEqual(stored("long_click"), .array([.bool(false), .null, .bool(true), .null, .null, .null, .bool(false), .null]))
        XCTAssertEqual(stored("weight_sum"), .array([.number(0), .null, .number(3)]))
        XCTAssertEqual(stored("edit"), .array([.null, .bool(true), .null, .bool(false), .null, .null, .null, .integer(40), .null]))
        // The default ProgressBar style is indeterminate only; the horizontal one switches.
        XCTAssertEqual(stored("progress"), .array([.null, .bool(true), .bool(false), .null, .bool(true), .null, .null, .null]))
        let gradient = AyuBridgeValue.string("android.graphics.drawable.GradientDrawable")
        XCTAssertEqual(stored("gradient"), .array([gradient, gradient, gradient, .bool(false), .bool(false), .bool(false), .bool(false), .null, gradient, .string("BL_TR"), .integer(5)]))
        refusal("gradient_colors", "!BridgeError: INVALID_ARGUMENTS")
        refusal("gradient_radii", "!BridgeError: INVALID_ARGUMENTS")
        refusal("wrong_class", "!")
        refusal("wrong_argument", "!BridgeError: INVALID_ARGUMENTS")
        refusal("edit_selectable", "!")
        await stack.remove(id)
    }
}
