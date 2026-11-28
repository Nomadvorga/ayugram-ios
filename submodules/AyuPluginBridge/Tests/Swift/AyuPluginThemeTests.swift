import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

@MainActor
final class AyuPluginThemeTests: XCTestCase {
    private let theme = "org.telegram.ui.ActionBar.Theme"

    /// A palette with a different opaque colour in every slot.
    nonisolated private static func palette(isDark: Bool = false, isNight: Bool = false, without missing: Set<AyuPluginThemePalette.Slot> = []) -> AyuPluginThemePalette {
        var colors: [AyuPluginThemePalette.Slot: UInt32] = [:]
        for (index, slot) in AyuPluginThemePalette.Slot.allCases.enumerated() where !missing.contains(slot) {
            colors[slot] = 0xFF00_0000 | UInt32(index + 1) << 8 | 0x7F
        }
        return AyuPluginThemePalette(isDark: isDark, isNight: isNight, colors: colors)
    }

    private func session(_ application: AyuPluginApplicationBridge) async throws -> AyuMemberTestHost {
        try await AyuMemberTestHost(provider: application, registry: try application.classRegistry())
    }

    func testKeyTableUsesAndroidValuesAndEverySlot() {
        let keys = AyuPluginTheme.keys
        XCTAssertEqual(Set(keys.values.map(\.id)).count, keys.count)
        // The constants of exteraGram 13.2.2 (`Theme.java`): a plugin may hold the number itself.
        let android: [String: Int64] = [
            "key_dialogBackground": 1, "key_dialogTextBlack": 3, "key_windowBackgroundWhite": 49, "key_listSelector": 54,
            "key_windowBackgroundWhiteBlackText": 78, "key_windowBackgroundGray": 98, "key_divider": 101, "key_text_RedRegular": 113,
            "key_actionBarDefault": 165, "key_chats_name": 196, "key_chat_inBubble": 268, "key_chat_messagePanelIcons": 490,
            "key_featuredStickers_addButton": 688, "key_featuredStickers_buttonText": 692, "key_player_progress": 747,
        ]
        for (name, id) in android { XCTAssertEqual(keys[name]?.id, id, name) }
        // The slot table names Android keys only, with Android's ids.
        let table = Dictionary(uniqueKeysWithValues: AyuPluginTheme.androidKeys.map { ($0.name, $0) })
        for (name, key) in keys { XCTAssertEqual(table[name]?.id, key.id, name) }
        XCTAssertEqual(AyuPluginTheme.keyConstants.count, AyuPluginTheme.androidKeys.count)
        XCTAssertEqual(AyuPluginTheme.keyConstants["key_divider"], .integer(101))
        XCTAssertEqual(Set(keys.values.map(\.slot)), Set(AyuPluginThemePalette.Slot.allCases))
        // Keys Android does not define at this version stay absent, as do the two it computes from the wallpaper.
        for name in ["key_actionBarTitle", "key_dialogTextRed", "key_dialogButtonRed", "key_listSelectorSDK21", "key_chat_serviceBackground", "key_chat_serviceBackgroundSelected"] {
            XCTAssertNil(AyuPluginTheme.keyConstants[name], name)
        }
    }

    /// A sample of exteraGram 13.2.2: `Theme.java` ids, `ThemeColors.java` defaults and `darkblue.attheme`.
    func testAndroidKeyTablePinsIdsAndDefaultColours() {
        let table = Dictionary(uniqueKeysWithValues: AyuPluginTheme.androidKeys.map { ($0.name, $0) })
        XCTAssertEqual(table.count, 864)
        XCTAssertEqual(Set(AyuPluginTheme.androidKeys.map(\.id)).count, 864)
        XCTAssertEqual(AyuPluginTheme.androidKeys.map(\.id).max(), 865)
        let android: [(String, Int64, UInt32, UInt32)] = [
            ("key_wallpaperFileOffset", 0, 0xFFFF_0000, 0xFFFF_FFFF),
            ("key_dialogBackground", 1, 0xFFFF_FFFF, 0xFF21_2D3B),
            ("key_dialogTextBlack", 3, 0xFF1A_1D21, 0xFFF6_F6F6),
            ("key_dialogTextHint", 13, 0xFF97_9797, 0xFF7D_8B99),
            ("key_windowBackgroundWhite", 49, 0xFFFF_FFFF, 0xFF1D_2733),
            ("key_divider", 101, 0xFFD9_D9D9, 0x9500_0000),
            ("key_chats_name", 196, 0xFF1A_1D21, 0xFFE9_EEF4),
            ("key_chat_attachPhotoBackground", 248, 0x0C00_0000, 0x0C00_0000),
            ("key_chat_outBubble", 316, 0xFFEF_FFDE, 0xFF3E_618A),
            ("key_chat_messagePanelSend", 491, 0xFF22_9AF0, 0xFF22_9AF0),
            ("key_undo_cancelColor", 732, 0xFF85_CAFF, 0xFF85_CAFF),
            ("key_premiumStarGradient2", 799, 0xFFE3_ECFA, 0xFFC0_66FA),
            ("key_iv_background", 843, 0xFFFF_FFFF, 0xFF00_0000),
        ]
        for (name, id, light, dark) in android {
            XCTAssertEqual(table[name], AyuPluginTheme.AndroidKey(name: name, id: id, light: light, dark: dark), name)
        }
        // getColor returns a signed Java int; a key without a slot answers by the theme's appearance.
        let light = AyuPluginThemePalette(isDark: false, isNight: false, colors: [:])
        let dark = AyuPluginThemePalette(isDark: true, isNight: false, colors: [:])
        XCTAssertEqual(try AyuPluginTheme.color(799, palette: light), -1_839_878)
        XCTAssertEqual(try AyuPluginTheme.color(799, palette: dark), -4_167_942)
        XCTAssertEqual(try AyuPluginTheme.color(3, palette: light), -15_065_823)
        XCTAssertEqual(try AyuPluginTheme.color(3, palette: dark), -592_138)
        XCTAssertEqual(try AyuPluginTheme.color(248, palette: light), 0x0C00_0000)
        XCTAssertThrowsError(try AyuPluginTheme.color(866, palette: light))
        XCTAssertThrowsError(try AyuPluginTheme.color(-1, palette: light))
    }

    func testWithoutABoundPaletteColorMembersAreRefusedAndNotAdvertised() async throws {
        let application = AyuPluginApplicationBridge()
        let session = try await self.session(application)
        let capabilities = try await session.call("runtime.capabilities", owner: "inspector", pluginID: "$runtime")
        let entry = capabilities["members"]["classes"][self.theme]
        let statics = Set(entry["static_methods"].array?.compactMap(\.string) ?? [])
        let fields = Set(entry["static_fields"].array?.compactMap(\.string) ?? [])
        XCTAssertTrue(statics.isDisjoint(with: ["getColor", "isCurrentThemeDark", "isCurrentThemeNight", "getActiveTheme", "getSelectorDrawable"]))
        XCTAssertTrue(statics.isSuperset(of: ["createSelectorDrawable", "createSimpleSelectorRoundRectDrawable", "createRoundRectDrawable"]))
        XCTAssertTrue(fields.filter { $0.hasPrefix("key_") }.isEmpty)
        XCTAssertNil(entry["results"]["getActiveTheme"].string)
        XCTAssertEqual(entry["results"]["createSelectorDrawable"], .string("android.graphics.drawable.RippleDrawable"))

        var code = await session.failure { try await session.call("java.member", ["target": AyuMemberTestHost.type(self.theme), "name": .string("key_dialogBackground")]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.call("java.get_field", ["target": AyuMemberTestHost.type(self.theme), "name": .string("key_dialogBackground")]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.call("java.member", ["target": AyuMemberTestHost.type(self.theme), "name": .string("getColor")]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        for (method, args) in [("getColor", [AyuBridgeValue.integer(1)]), ("isCurrentThemeDark", []), ("isCurrentThemeNight", []), ("getActiveTheme", []), ("getSelectorDrawable", [.bool(false)])] {
            code = await session.failure { try await session.invokeStatic(self.theme, method, args) }
            XCTAssertEqual(code, "UNSUPPORTED_API", method)
        }
        // The former UIKit-trait members are gone.
        code = await session.failure { try await session.invokeStatic(self.theme, "isDarkThemeEnabled") }
        XCTAssertEqual(code, "UNSUPPORTED_API")
    }

    func testColorsComeFromThePaletteSlotOfEachKey() async throws {
        let application = AyuPluginApplicationBridge()
        let palette = AyuTestBox<AyuPluginThemePalette?>(Self.palette())
        application.presentation.bind(palette: { palette.value }, language: nil)
        let session = try await self.session(application)
        let capabilities = try await session.call("runtime.capabilities", owner: "inspector", pluginID: "$runtime")
        let entry = capabilities["members"]["classes"][self.theme]
        XCTAssertEqual(Set(entry["static_fields"].array?.compactMap(\.string) ?? []), Set(AyuPluginTheme.keyConstants.keys))
        XCTAssertTrue(Set(entry["static_methods"].array?.compactMap(\.string) ?? []).isSuperset(of: ["getColor", "isCurrentThemeDark", "isCurrentThemeNight", "getActiveTheme", "getSelectorDrawable"]))
        XCTAssertEqual(entry["results"]["getActiveTheme"], .string("org.telegram.ui.ActionBar.Theme$ThemeInfo"))

        for (name, key) in AyuPluginTheme.keys {
            let constant = try await session.field(self.theme, name)
            XCTAssertEqual(constant, .integer(key.id), name)
            let slot = try XCTUnwrap(Self.palette().colors[key.slot])
            let expected = key.alpha.map { (slot & 0x00FF_FFFF) | $0 << 24 } ?? slot
            ayuExpect(try await session.invokeStatic(self.theme, "getColor", [constant]), .integer(Int64(Int32(bitPattern: expected))), name)
        }
        // Translucent forms of a slot keep its colour and take the key's alpha.
        let accent = try XCTUnwrap(Self.palette().colors[.dialogAccent])
        ayuExpect(try await session.invokeStatic(self.theme, "getColor", [.integer(5)]), .integer(Int64(Int32(bitPattern: (accent & 0x00FF_FFFF) | 0x3300_0000))))
        // The ResourcesProvider overload with the app-wide theme.
        ayuExpect(try await session.invokeStatic(self.theme, "getColor", [.integer(1), .null]), .integer(Int64(Int32(bitPattern: try XCTUnwrap(Self.palette().colors[.dialogBackground])))))

        // A key with no slot answers with Android's default for the light appearance.
        ayuExpect(try await session.invokeStatic(self.theme, "getColor", [try await session.field(self.theme, "key_premiumStarGradient2")]), .integer(-1_839_878))
        var code = await session.failure { try await session.invokeStatic(self.theme, "getColor", [.integer(866)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.invokeStatic(self.theme, "getColor", [.integer(-1)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.invokeStatic(self.theme, "getColor", [.string("key_divider")]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        code = await session.failure { try await session.invokeStatic(self.theme, "getColor") }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")

        // The colours follow the theme: every call reads the provider.
        palette.value = AyuPluginThemePalette(isDark: true, isNight: true, colors: [.dialogBackground: 0xFF10_2030])
        ayuExpect(try await session.invokeStatic(self.theme, "getColor", [.integer(1)]), .integer(Int64(Int32(bitPattern: 0xFF10_2030))))
        ayuExpect(try await session.invokeStatic(self.theme, "isCurrentThemeDark"), .bool(true))
        ayuExpect(try await session.invokeStatic(self.theme, "isCurrentThemeNight"), .bool(true))
        // A slot the app could not fill answers with Android's dark default.
        ayuExpect(try await session.invokeStatic(self.theme, "getColor", [.integer(101)]), .integer(Int64(Int32(bitPattern: 0x9500_0000))))
        ayuExpect(try await session.invokeStatic(self.theme, "getColor", [.integer(799)]), .integer(-4_167_942))
        palette.value = nil
        code = await session.failure { try await session.invokeStatic(self.theme, "getColor", [.integer(1)]) }
        XCTAssertEqual(code, "DATA_UNAVAILABLE")
    }

    func testDarkFlagsAndActiveTheme() async throws {
        let application = AyuPluginApplicationBridge()
        let palette = AyuTestBox<AyuPluginThemePalette?>(Self.palette(isDark: true, isNight: false))
        application.presentation.bind(palette: { palette.value }, language: nil)
        let session = try await self.session(application)
        ayuExpect(try await session.invokeStatic(self.theme, "isCurrentThemeDark"), .bool(true))
        ayuExpect(try await session.invokeStatic(self.theme, "isCurrentThemeNight"), .bool(false))
        let info = try await session.invokeStatic(self.theme, "getActiveTheme")
        XCTAssertEqual(info["$class"], .string("org.telegram.ui.ActionBar.Theme$ThemeInfo"))
        ayuExpect(try await session.invoke(info, "isDark"), .bool(true))
        ayuExpect(try await session.invoke(info, "isLight"), .bool(false))
        palette.value = Self.palette(isDark: false)
        ayuExpect(try await session.invoke(try await session.invokeStatic(self.theme, "getActiveTheme"), "isDark"), .bool(false))
        let code = await session.failure { try await session.invokeStatic(self.theme, "isCurrentThemeDark", [.integer(1)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
    }

    func testSelectorDrawablesBecomeBackgroundsWithAPressedHighlight() async throws {
        let application = AyuPluginApplicationBridge()
        application.presentation.bind(palette: { Self.palette() }, language: nil)
        let session = try await self.session(application)
        let view = try await session.construct("android.widget.FrameLayout")
        let native = try await session.mount(view, size: CGSize(width: 100, height: 40))

        let selector = try await session.invokeStatic(self.theme, "createSimpleSelectorRoundRectDrawable", [.integer(8), .integer(-16776961), .integer(0x4000_0000)])
        XCTAssertEqual(selector["$class"], .string("android.graphics.drawable.RippleDrawable"))
        ayuExpect(try await session.invoke(view, "setBackground", [selector]), .null)
        try await session.flush(view)
        let renderer = try XCTUnwrap(native.members.drawable)
        XCTAssertEqual(renderer.style.color, UIColor(red: 0, green: 0, blue: 1, alpha: 1))
        XCTAssertEqual(renderer.style.cornerRadius, 8)
        XCTAssertEqual(renderer.style.ripple?.kind, "round_rect")
        ayuExpect(try await session.invoke(view, "getBackground"), selector)
        let press = try XCTUnwrap(native.gestureRecognizers?.compactMap { $0 as? AyuBridgePressRecognizer }.first)
        // Only a clickable view shows its pressed state.
        press.onChange?(true)
        XCTAssertFalse(renderer.isPressed)
        _ = try await session.invoke(view, "setOnClickListener", [.object(["$callback": .string("click")])])
        try await session.flush(view)
        press.onChange?(true)
        XCTAssertTrue(renderer.isPressed)
        press.onChange?(false)
        XCTAssertFalse(renderer.isPressed)

        // createRoundRectDrawable is a plain shape: no extended layers, no press recognizer.
        let shape = try await session.invokeStatic(self.theme, "createRoundRectDrawable", [.integer(6), .integer(-65536)])
        XCTAssertEqual(shape["$class"], .string("android.graphics.drawable.ShapeDrawable"))
        _ = try await session.invoke(view, "setBackgroundDrawable", [shape])
        try await session.flush(view)
        XCTAssertNil(native.members.drawable)
        XCTAssertNil(native.gestureRecognizers?.first { $0 is AyuBridgePressRecognizer })
        XCTAssertEqual(native.backgroundColor, UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(native.layer.cornerRadius, 6)

        // getSelectorDrawable(false) is a bare list selector; (true) sits on the list row colour.
        let listSelector = try XCTUnwrap(Self.palette().colors[.listHighlight]), row = try XCTUnwrap(Self.palette().colors[.listItemBackground])
        let bare = try await session.invokeStatic(self.theme, "getSelectorDrawable", [.bool(false)])
        _ = try await session.invoke(view, "setBackground", [bare])
        try await session.flush(view)
        XCTAssertEqual(native.members.drawable?.style.ripple?.kind, "rect")
        XCTAssertEqual(native.members.drawable?.style.color.cgColor.alpha, 0)
        let expectedRipple = (listSelector & 0x00FF_FFFF) | 0x8000_0000
        XCTAssertEqual(native.members.drawable?.style.ripple?.color, UIColor(red: CGFloat((expectedRipple >> 16) & 255) / 255, green: CGFloat((expectedRipple >> 8) & 255) / 255,
                                                                             blue: CGFloat(expectedRipple & 255) / 255, alpha: 128.0 / 255))
        let onRow = try await session.invokeStatic(self.theme, "getSelectorDrawable", [.integer(0x1000_0000), .bool(true)])
        _ = try await session.invoke(view, "setBackground", [onRow])
        try await session.flush(view)
        XCTAssertEqual(native.members.drawable?.style.color, UIColor(red: CGFloat((row >> 16) & 255) / 255, green: CGFloat((row >> 8) & 255) / 255, blue: CGFloat(row & 255) / 255, alpha: 1))
        let code = await session.failure { try await session.invokeStatic(self.theme, "getSelectorDrawable", [.integer(1), .integer(2)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")

        let circle = try await session.invokeStatic(self.theme, "createSelectorDrawable", [.integer(0x2000_0000)])
        _ = try await session.invoke(view, "setBackground", [circle])
        try await session.flush(view)
        XCTAssertEqual(native.members.drawable?.style.ripple?.radius, 20)
        XCTAssertEqual(native.members.drawable?.style.ripple?.bounded, false)
    }

    func testTelegramTypefacesAndWindowInsets() async throws {
        let application = AyuPluginApplicationBridge()
        let session = try await self.session(application)
        let utilities = "org.telegram.messenger.AndroidUtilities"
        let bold = try await session.invokeStatic(utilities, "bold")
        XCTAssertEqual(bold["$class"], .string("android.graphics.Typeface"))
        ayuExpect(try await session.invoke(bold, "getWeight"), .integer(500))
        ayuExpect(try await session.invoke(bold, "isBold"), .bool(false))
        let mono = try await session.invokeStatic(utilities, "getTypeface", [.string("fonts/rmono.ttf")])
        ayuExpect(try await session.invoke(mono, "getWeight"), .integer(400))
        ayuExpect(try await session.invokeStatic(utilities, "getTypeface", [.string("fonts/none.ttf")]), .null)
        let text = try await session.construct("android.widget.TextView")
        ayuExpect(try await session.invoke(text, "setTypeface", [bold]), .null)
        ayuExpect(try await session.invoke(text, "getTypeface"), bold)

        // Without a visible window there are no insets to report.
        for name in ["statusBarHeight", "navigationBarHeight"] {
            let code = await session.failure { try await session.call("java.member", ["target": AyuMemberTestHost.type(utilities), "name": .string(name)]) }
            XCTAssertEqual(code, "SCREEN_UNAVAILABLE", name)
        }
        let capabilities = try await session.call("runtime.capabilities", owner: "inspector", pluginID: "$runtime")
        let entry = capabilities["members"]["classes"][utilities]
        XCTAssertTrue(Set(entry["static_fields"].array?.compactMap(\.string) ?? []).isSuperset(of: ["statusBarHeight", "navigationBarHeight"]))
        XCTAssertTrue(Set(entry["static_methods"].array?.compactMap(\.string) ?? []).isSuperset(of: ["bold", "getTypeface"]))
        XCTAssertEqual(entry["results"]["bold"], .string("android.graphics.Typeface"))
    }

    func testWindowInsetsOfTheVisibleScreen() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Window insets require an application-owned UIWindowScene")
        }
        let application = AyuPluginApplicationBridge()
        application.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 12)], selected: 0)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        let presenter = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        window.rootViewController = presenter
        window.isHidden = false
        defer { window.isHidden = true }
        application.bindScreen(screen: { screen }, presenter: { presenter })
        let session = try await self.session(application)
        let utilities = "org.telegram.messenger.AndroidUtilities"
        ayuExpect(try await session.field(utilities, "statusBarHeight"), .integer(Int64(window.safeAreaInsets.top.rounded())))
        ayuExpect(try await session.field(utilities, "navigationBarHeight"), .integer(Int64(window.safeAreaInsets.bottom.rounded())))
    }

    func testLocaleInfoNamesTheTelegramLanguagePack() async throws {
        let application = AyuPluginApplicationBridge()
        let session = try await self.session(application)
        let controller = "org.telegram.messenger.LocaleController"
        let info = "org.telegram.messenger.LocaleController$LocaleInfo"
        // The static flag and the instance method agree.
        let instance = try await session.invokeStatic(controller, "getInstance")
        ayuExpect(try await session.field(controller, "isRTL"), try await session.invoke(instance, "isRTL"))

        // Without a bound language the pack code is neither advertised nor answered.
        var capabilities = try await session.call("runtime.capabilities", owner: "inspector", pluginID: "$runtime")
        XCTAssertEqual(capabilities["members"]["classes"][info]["fields"], .array([.string("pluralLangCode")]))
        XCTAssertFalse((capabilities["members"]["classes"][info]["methods"].array ?? []).contains(.string("getLangCode")))
        var localeInfo = try await session.invoke(instance, "getCurrentLocaleInfo")
        var code = await session.failure { try await session.call("java.member", ["target": localeInfo, "name": .string("shortName")]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.call("java.get_field", ["target": localeInfo, "name": .string("shortName")]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.invoke(localeInfo, "getLangCode") }
        XCTAssertEqual(code, "UNSUPPORTED_API")

        let language = AyuTestBox<AyuPluginLanguage?>(AyuPluginLanguage(code: "pt-BR", baseCode: nil))
        application.presentation.bind(palette: nil, language: { language.value })
        capabilities = try await session.call("runtime.capabilities", owner: "inspector", pluginID: "$runtime")
        XCTAssertEqual(Set(capabilities["members"]["classes"][info]["fields"].array?.compactMap(\.string) ?? []), ["pluralLangCode", "shortName", "baseLangCode"])
        localeInfo = try await session.invoke(instance, "getCurrentLocaleInfo")
        // Android keeps pack codes lowercase with underscores and gives them back with hyphens.
        ayuExpect(try await session.call("java.get_field", ["target": localeInfo, "name": .string("shortName")]), .string("pt_br"))
        ayuExpect(try await session.invoke(localeInfo, "getLangCode"), .string("pt-br"))
        ayuExpect(try await session.call("java.get_field", ["target": localeInfo, "name": .string("baseLangCode")]), .string(""))
        ayuExpect(try await session.invoke(localeInfo, "getBaseLangCode"), .string(""))
        let plural = try await session.call("java.get_field", ["target": localeInfo, "name": .string("pluralLangCode")])
        XCTAssertNotNil(plural.string)

        // An unofficial pack names its base.
        language.value = AyuPluginLanguage(code: "ru-custom", baseCode: "ru-RU")
        localeInfo = try await session.invoke(instance, "getCurrentLocaleInfo")
        ayuExpect(try await session.call("java.get_field", ["target": localeInfo, "name": .string("shortName")]), .string("ru_custom"))
        ayuExpect(try await session.call("java.get_field", ["target": localeInfo, "name": .string("baseLangCode")]), .string("ru_RU"))
        ayuExpect(try await session.invoke(localeInfo, "getBaseLangCode"), .string("ru-RU"))
        language.value = nil
        code = await session.failure { try await session.invoke(instance, "getCurrentLocaleInfo") }
        XCTAssertEqual(code, "DATA_UNAVAILABLE")
    }
}
