import Foundation

/// The colours of the app's current presentation theme that Android theme keys are answered
/// from, as ARGB values. The app fills the slots it has a colour for; a key whose slot is
/// missing, or that has no slot, is answered with Android's default for the appearance.
public struct AyuPluginThemePalette: Sendable, Equatable {
    /// Closed set of roles. Each names the element of the iOS presentation theme it holds.
    public enum Slot: String, CaseIterable, Sendable {
        /// Alerts and sheets: opaque background, grouped (gray) background, texts, accent,
        /// action button text, separators and input fields.
        case dialogBackground, dialogGroupedBackground, dialogPrimaryText, dialogSecondaryText, dialogPlaceholderText
        case dialogAccent, dialogActionText, dialogSeparator, dialogInputBackground, dialogInputBorder
        /// List (settings) screens: screen and row backgrounds, texts, accent, destructive,
        /// separators, the pressed row, the section header fill, input stroke and placeholders.
        case listBackground, listItemBackground, listPrimaryText, listSecondaryText, listFreeText, listPlaceholderText
        case listDisabledText, listAccent, listDestructive, listSeparator, listHighlight, listSectionHeaderFill
        case listInputStroke, listControlSecondary, listMediaPlaceholder
        /// Check marks and accent-filled buttons, and switches.
        case checkFill, checkStroke, checkForeground, switchOff, switchOn
        /// Navigation bar, popup menus.
        case navigationBackground, navigationPrimaryText, navigationSecondaryText, navigationButton, navigationControl, navigationAccent
        case menuBackground, menuPrimary
        /// Chat list rows.
        case chatListTitle, chatListSecretTitle, chatListMessageText, chatListDate, chatListUnreadBadge, chatListPinnedBackground
        /// Message bubbles and the chat input panel.
        case incomingBubble, outgoingBubble, incomingText, outgoingText, incomingLink, outgoingLink
        case incomingMediaControl, incomingReactionBackground
        case inputPanelBackground, inputPanelSeparator, inputPanelText, inputPanelPlaceholder, inputPanelControl, inputPanelAction
        case mediaPanelBackground
    }

    /// The theme's overall dark appearance (`Theme.isCurrentThemeDark`).
    public let isDark: Bool
    /// The theme was switched to by the automatic night mode (`Theme.isCurrentThemeNight`).
    public let isNight: Bool
    public let colors: [Slot: UInt32]

    public init(isDark: Bool, isNight: Bool, colors: [Slot: UInt32]) {
        self.isDark = isDark; self.isNight = isNight; self.colors = colors
    }
}

/// The app's interface language as Telegram names it.
public struct AyuPluginLanguage: Sendable, Equatable {
    /// Language pack code, for example `en` or `pt-br`.
    public let code: String
    /// Base language pack of an unofficial pack; nil for an official one.
    public let baseCode: String?

    public init(code: String, baseCode: String?) {
        self.code = code; self.baseCode = baseCode
    }
}

/// What the app's presentation data supplies to plugins. The providers are read on the host
/// worker for every call, so a theme or language change needs no notification.
public final class AyuPluginPresentation: @unchecked Sendable {
    public typealias PaletteProvider = @Sendable () -> AyuPluginThemePalette?
    public typealias LanguageProvider = @Sendable () -> AyuPluginLanguage?
    private let lock = NSLock()
    private var paletteProvider: PaletteProvider?
    private var languageProvider: LanguageProvider?

    public init() {}

    /// Both closures must be safe to call from any thread. Passing nil unbinds.
    public func bind(palette: PaletteProvider?, language: LanguageProvider?) {
        self.lock.lock(); self.paletteProvider = palette; self.languageProvider = language; self.lock.unlock()
    }

    var hasPalette: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.paletteProvider != nil }
    var hasLanguage: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.languageProvider != nil }

    func palette() throws -> AyuPluginThemePalette {
        self.lock.lock(); let provider = self.paletteProvider; self.lock.unlock()
        guard let provider else { throw AyuBridgeFailure.unsupported("Theme colors without a bound presentation theme") }
        guard let palette = provider() else { throw AyuBridgeFailure("data_unavailable", "The presentation theme is unavailable") }
        return palette
    }

    func language() throws -> AyuPluginLanguage {
        self.lock.lock(); let provider = self.languageProvider; self.lock.unlock()
        guard let provider else { throw AyuBridgeFailure.unsupported("LocaleInfo without a bound interface language") }
        guard let language = provider(), !language.code.isEmpty, language.code.utf8.count <= 64, (language.baseCode ?? "").utf8.count <= 64 else {
            throw AyuBridgeFailure("data_unavailable", "The interface language is unavailable")
        }
        return language
    }
}

/// `org.telegram.ui.ActionBar.Theme`: Android colour keys answered from the presentation
/// palette, the dark flags, and the drawable factories.
enum AyuPluginTheme {
    static let className = "org.telegram.ui.ActionBar.Theme"
    static let themeInfoName = "org.telegram.ui.ActionBar.Theme$ThemeInfo"

    struct Key: Sendable {
        /// The value of the Android constant (exteraGram 13.2.2, `Theme.java`).
        let id: Int64
        let slot: AyuPluginThemePalette.Slot
        /// Replaces the alpha of the slot's colour, for keys that are a translucent form of it.
        var alpha: UInt32? = nil
    }

    /// Android key name to the palette slot that colours the same element on iOS. A key with no
    /// counterpart here is answered with Android's own default from `androidKeys`.
    static let keys: [String: Key] = [
        "key_dialogBackground": Key(id: 1, slot: .dialogBackground),
        "key_dialogBackgroundGray": Key(id: 2, slot: .dialogGroupedBackground),
        "key_dialogTextBlack": Key(id: 3, slot: .dialogPrimaryText),
        "key_dialogTextLink": Key(id: 4, slot: .dialogAccent),
        "key_dialogLinkSelection": Key(id: 5, slot: .dialogAccent, alpha: 0x33),
        "key_dialogTextBlue": Key(id: 6, slot: .dialogAccent),
        "key_dialogTextBlue2": Key(id: 7, slot: .dialogAccent),
        "key_dialogTextGray": Key(id: 9, slot: .dialogAccent),
        "key_dialogTextGray2": Key(id: 10, slot: .dialogSecondaryText),
        "key_dialogTextGray3": Key(id: 11, slot: .dialogSecondaryText),
        "key_dialogTextHint": Key(id: 13, slot: .dialogPlaceholderText),
        "key_dialogInputField": Key(id: 14, slot: .dialogInputBorder),
        "key_dialogInputFieldActivated": Key(id: 15, slot: .dialogAccent),
        "key_dialogRoundCheckBox": Key(id: 21, slot: .checkFill),
        "key_dialogRoundCheckBoxCheck": Key(id: 22, slot: .checkForeground),
        "key_dialogRadioBackground": Key(id: 23, slot: .checkStroke),
        "key_dialogRadioBackgroundChecked": Key(id: 24, slot: .dialogAccent),
        "key_dialogLineProgress": Key(id: 25, slot: .dialogAccent),
        "key_dialogLineProgressBackground": Key(id: 26, slot: .dialogSeparator),
        "key_dialogButton": Key(id: 27, slot: .dialogActionText),
        "key_dialogIcon": Key(id: 29, slot: .dialogPrimaryText),
        "key_dialogGrayLine": Key(id: 30, slot: .dialogSeparator),
        "key_dialogSearchBackground": Key(id: 34, slot: .dialogInputBackground),
        "key_dialogFloatingButton": Key(id: 38, slot: .checkFill),
        "key_windowBackgroundWhite": Key(id: 49, slot: .listItemBackground),
        "key_listSelector": Key(id: 54, slot: .listHighlight),
        "key_windowBackgroundWhiteInputField": Key(id: 56, slot: .listInputStroke),
        "key_windowBackgroundWhiteInputFieldActivated": Key(id: 57, slot: .listAccent),
        "key_windowBackgroundWhiteGrayIcon": Key(id: 58, slot: .listSecondaryText),
        "key_windowBackgroundWhiteBlueText": Key(id: 59, slot: .listAccent),
        "key_windowBackgroundWhiteBlueText2": Key(id: 60, slot: .listAccent),
        "key_windowBackgroundWhiteBlueText4": Key(id: 62, slot: .listAccent),
        "key_windowBackgroundWhiteBlueButton": Key(id: 66, slot: .listAccent),
        "key_windowBackgroundWhiteGrayText": Key(id: 70, slot: .listSecondaryText),
        "key_windowBackgroundWhiteGrayText2": Key(id: 71, slot: .listSecondaryText),
        "key_windowBackgroundWhiteGrayText3": Key(id: 72, slot: .listSecondaryText),
        "key_windowBackgroundWhiteGrayText4": Key(id: 73, slot: .listFreeText),
        "key_windowBackgroundWhiteBlackText": Key(id: 78, slot: .listPrimaryText),
        "key_windowBackgroundWhiteHintText": Key(id: 79, slot: .listPlaceholderText),
        "key_windowBackgroundWhiteValueText": Key(id: 80, slot: .listAccent),
        "key_windowBackgroundWhiteBlueHeader": Key(id: 83, slot: .listAccent),
        "key_switchTrack": Key(id: 84, slot: .switchOff),
        "key_switchTrackChecked": Key(id: 85, slot: .switchOn),
        "key_windowBackgroundGray": Key(id: 98, slot: .listBackground),
        "key_divider": Key(id: 101, slot: .listSeparator),
        "key_graySection": Key(id: 102, slot: .listSectionHeaderFill),
        "key_radioBackground": Key(id: 104, slot: .checkStroke),
        "key_radioBackgroundChecked": Key(id: 105, slot: .checkFill),
        "key_checkboxDisabled": Key(id: 107, slot: .listDisabledText),
        "key_checkboxCheck": Key(id: 108, slot: .checkForeground),
        "key_text_RedRegular": Key(id: 113, slot: .listDestructive),
        "key_text_RedBold": Key(id: 114, slot: .listDestructive),
        "key_inappPlayerBackground": Key(id: 119, slot: .navigationBackground),
        "key_actionBarDefault": Key(id: 165, slot: .navigationBackground),
        "key_actionBarDefaultIcon": Key(id: 168, slot: .navigationButton),
        "key_actionBarActionModeDefaultIcon": Key(id: 171, slot: .navigationButton),
        "key_actionBarActionModeDefaultSelector": Key(id: 172, slot: .listHighlight),
        "key_actionBarDefaultTitle": Key(id: 173, slot: .navigationPrimaryText),
        "key_actionBarDefaultSubtitle": Key(id: 174, slot: .navigationSecondaryText),
        "key_actionBarDefaultSubmenuItem": Key(id: 177, slot: .menuPrimary),
        "key_actionBarDefaultSubmenuItemIcon": Key(id: 178, slot: .menuPrimary),
        "key_actionBarDefaultSubmenuBackground": Key(id: 179, slot: .menuBackground),
        "key_actionBarTabActiveText": Key(id: 181, slot: .navigationAccent),
        "key_actionBarTabUnactiveText": Key(id: 182, slot: .navigationSecondaryText),
        "key_actionBarTabLine": Key(id: 183, slot: .navigationAccent),
        "key_chats_unreadCounter": Key(id: 193, slot: .chatListUnreadBadge),
        "key_chats_name": Key(id: 196, slot: .chatListTitle),
        "key_chats_secretName": Key(id: 198, slot: .chatListSecretTitle),
        "key_chats_message": Key(id: 205, slot: .chatListMessageText),
        "key_chats_date": Key(id: 215, slot: .chatListDate),
        "key_chats_pinnedOverlay": Key(id: 217, slot: .chatListPinnedBackground),
        "key_chats_actionIcon": Key(id: 239, slot: .checkForeground),
        "key_chats_actionBackground": Key(id: 240, slot: .checkFill),
        "key_chat_attachPhotoBackground": Key(id: 248, slot: .listMediaPlaceholder),
        "key_chat_inBubble": Key(id: 268, slot: .incomingBubble),
        "key_chat_outBubble": Key(id: 316, slot: .outgoingBubble),
        "key_chat_outAudioProgress": Key(id: 356, slot: .outgoingBubble),
        "key_chat_messageTextIn": Key(id: 393, slot: .incomingText),
        "key_chat_messageTextOut": Key(id: 394, slot: .outgoingText),
        "key_chat_messageLinkIn": Key(id: 395, slot: .incomingLink),
        "key_chat_messageLinkOut": Key(id: 396, slot: .outgoingLink),
        "key_chat_inAudioProgress": Key(id: 449, slot: .incomingBubble),
        "key_chat_messagePanelBackground": Key(id: 485, slot: .inputPanelBackground),
        "key_chat_messagePanelShadow": Key(id: 486, slot: .inputPanelSeparator),
        "key_chat_messagePanelText": Key(id: 487, slot: .inputPanelText),
        "key_chat_messagePanelHint": Key(id: 488, slot: .inputPanelPlaceholder),
        "key_chat_messagePanelIcons": Key(id: 490, slot: .inputPanelControl),
        "key_chat_messagePanelSend": Key(id: 491, slot: .inputPanelAction),
        "key_chat_inLoader": Key(id: 501, slot: .incomingMediaControl),
        "key_chat_searchPanelIcons": Key(id: 516, slot: .inputPanelControl),
        "key_chat_emojiPanelBackground": Key(id: 526, slot: .mediaPanelBackground),
        "key_featuredStickers_addButton": Key(id: 688, slot: .checkFill),
        "key_featuredStickers_addButtonPressed": Key(id: 690, slot: .checkFill, alpha: 0x8C),
        "key_featuredStickers_buttonText": Key(id: 692, slot: .checkForeground),
        "key_sheet_scrollUp": Key(id: 734, slot: .listControlSecondary),
        "key_sheet_other": Key(id: 735, slot: .navigationControl),
        "key_player_actionBarTitle": Key(id: 740, slot: .navigationPrimaryText),
        "key_player_background": Key(id: 743, slot: .navigationBackground),
        "key_player_progressBackground": Key(id: 745, slot: .listControlSecondary),
        "key_player_progress": Key(id: 747, slot: .navigationAccent),
        "key_chat_inReactionButtonBackground": Key(id: 779, slot: .incomingReactionBackground),
    ]

    /// A colour key as Android defines it: the constant's value and the colour `Theme.getColor`
    /// returns for it under Android's default light theme and its default dark theme (Dark Blue).
    struct AndroidKey: Sendable, Equatable {
        let name: String
        let id: Int64
        let light: UInt32
        let dark: UInt32
    }

    static let androidKeys: [AndroidKey] = androidTable.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: " ")
        guard fields.count == 4, let id = Int64(fields[1]), let light = UInt32(fields[2], radix: 16), let dark = UInt32(fields[3], radix: 16) else { return nil }
        return AndroidKey(name: "key_" + fields[0], id: id, light: light, dark: dark)
    }

    static let keyConstants: [String: AyuBridgeValue] = Dictionary(androidKeys.map { ($0.name, AyuBridgeValue.integer($0.id)) }, uniquingKeysWith: { first, _ in first })
    private static let androidByID: [Int64: AndroidKey] = Dictionary(androidKeys.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    private static let androidByName: [String: AndroidKey] = Dictionary(androidKeys.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    /// `Theme.getColor(key)` as a signed Java int: the presentation theme's colour of the key's
    /// slot, else Android's default for the theme's appearance.
    static func color(_ id: Int64, palette: AyuPluginThemePalette) throws -> Int64 {
        guard let android = Self.androidByID[id] else { throw AyuBridgeFailure.unsupported("Theme color key \(id)") }
        let argb: UInt32
        if let key = Self.keys[android.name], let color = palette.colors[key.slot] {
            argb = key.alpha.map { (color & 0x00FF_FFFF) | $0 << 24 } ?? color
        } else {
            argb = palette.isDark ? android.dark : android.light
        }
        return Int64(Int32(bitPattern: argb))
    }

    private static func color(named name: String, palette: AyuPluginThemePalette) throws -> Int64 {
        guard let key = Self.androidByName[name] else { throw AyuBridgeFailure.unsupported("Theme." + name) }
        return try Self.color(key.id, palette: palette)
    }

    /// Members that answer from the palette: hidden while the app has bound none.
    private static let paletteMembers: Set<String> = Set(keyConstants.keys).union(["getColor", "isCurrentThemeDark", "isCurrentThemeNight", "getActiveTheme", "getSelectorDrawable"])

    static func adapters(presentation: AyuPluginPresentation) -> [AyuBridgeClassAdapter] {
        let theme = AyuBridgeClassAdapter(name: "org.telegram.ui.ActionBar.Theme",
            constants: Self.keyConstants,
            staticMethods: [
                "getColor": { args, _ in
                    // The second argument is a ResourcesProvider; only the app-wide theme (null) exists here.
                    guard args.count == 1 || (args.count == 2 && args[1] == .null), let key = args[0].integer else {
                        throw AyuBridgeFailure("invalid_arguments", "Theme.getColor expects a color key")
                    }
                    return .value(.integer(try Self.color(key, palette: presentation.palette())))
                },
                "isCurrentThemeDark": { args, _ in
                    guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Theme.isCurrentThemeDark takes no arguments") }
                    return .value(.bool(try presentation.palette().isDark))
                },
                "isCurrentThemeNight": { args, _ in
                    guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Theme.isCurrentThemeNight takes no arguments") }
                    return .value(.bool(try presentation.palette().isNight))
                },
                "getActiveTheme": { args, _ in
                    guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Theme.getActiveTheme takes no arguments") }
                    return .instance(className: Self.themeInfoName, state: ["dark": .bool(try presentation.palette().isDark)])
                },
                "createSelectorDrawable": { args, _ in try AyuBridgeDrawables.selector(args) },
                "createSimpleSelectorRoundRectDrawable": { args, _ in try AyuBridgeDrawables.simpleSelectorRoundRect(args) },
                "createRoundRectDrawable": { args, _ in try AyuBridgeDrawables.roundRect(args) },
                "getSelectorDrawable": { args, _ in
                    // (whiteBackground) and (color, whiteBackground); the background is the list row colour.
                    let palette = try presentation.palette()
                    let color: Int64
                    if args.count == 1 {
                        color = try Self.color(named: "key_listSelector", palette: palette)
                    } else {
                        guard args.count == 2 else { throw AyuBridgeFailure("invalid_arguments", "Theme.getSelectorDrawable takes a color and a background flag") }
                        color = try AyuBridgeDrawables.color(args[0], "selector ARGB color")
                    }
                    guard let whiteBackground = args[args.count - 1].bool else { throw AyuBridgeFailure.unsupported("Theme.getSelectorDrawable overload") }
                    let background = whiteBackground ? try Self.color(named: "key_windowBackgroundWhite", palette: palette) : nil
                    return AyuBridgeDrawables.listSelector(color: color, background: background)
                },
            ],
            results: [
                "getActiveTheme": "org.telegram.ui.ActionBar.Theme$ThemeInfo",
                "createSelectorDrawable": "android.graphics.drawable.RippleDrawable",
                "createSimpleSelectorRoundRectDrawable": "android.graphics.drawable.RippleDrawable",
                "createRoundRectDrawable": "android.graphics.drawable.ShapeDrawable",
                "getSelectorDrawable": "android.graphics.drawable.RippleDrawable",
            ],
            hiddenMembers: { presentation.hasPalette ? [] : Self.paletteMembers })
        let themeInfo = AyuBridgeClassAdapter(name: "org.telegram.ui.ActionBar.Theme$ThemeInfo",
            methods: [
                "isDark": { state, args, _ in
                    guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "ThemeInfo.isDark takes no arguments") }
                    return .value(state["dark"] ?? .bool(false))
                },
                "isLight": { state, args, _ in
                    guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "ThemeInfo.isLight takes no arguments") }
                    return .value(.bool(state["dark"] == .bool(false)))
                },
            ],
            validateState: { state in
                guard state.count == 1, state["dark"]?.bool != nil else { throw AyuBridgeFailure("invalid_arguments", "Invalid ThemeInfo state") }
            })
        return [theme, themeInfo]
    }

    /// `name id light dark` for every key of exteraGram 13.2.2: `Theme.java` (ids), `ThemeColors.java`
    /// (light, with `getDefaultColor`'s fallbacks) and `darkblue.attheme` over the same defaults (dark).
    /// The two service-background keys are computed from the wallpaper on Android and are absent.
    private static let androidTable = """
    wallpaperFileOffset 0 FFFF0000 FFFFFFFF
    dialogBackground 1 FFFFFFFF FF212D3B
    dialogBackgroundGray 2 FFF0F0F0 FF1C2631
    dialogTextBlack 3 FF1A1D21 FFF6F6F6
    dialogTextLink 4 FF2678B6 FF64B5EF
    dialogLinkSelection 5 3362A9E3 3362A9E3
    dialogTextBlue 6 FF2F8CC9 FF64B5EF
    dialogTextBlue2 7 FF3A95D5 FF64B5EF
    dialogTextBlue4 8 FF19A7E8 FF64B5EF
    dialogTextGray 9 FF348BC1 FF7D8B99
    dialogTextGray2 10 FF757575 FF7D8B99
    dialogTextGray3 11 FF999999 FF7D8B99
    dialogTextGray4 12 FFB3B3B3 FF7D8B99
    dialogTextHint 13 FF979797 FF7D8B99
    dialogInputField 14 FFDBDBDB FF7D8B99
    dialogInputFieldActivated 15 FF229AF0 FF229AF0
    dialogCheckboxSquareBackground 16 FF229AF0 FF229AF0
    dialogCheckboxSquareCheck 17 FFFFFFFF FFFFFFFF
    dialogCheckboxSquareUnchecked 18 FF737373 FF546679
    dialogCheckboxSquareDisabled 19 FFB0B0B0 FF445362
    dialogScrollGlow 20 FFF5F6F7 FFF5F6F7
    dialogRoundCheckBox 21 FF229AF0 FF1A9CFF
    dialogRoundCheckBoxCheck 22 FFFFFFFF FFFFFFFF
    dialogRadioBackground 23 FFB3B3B3 FF546679
    dialogRadioBackgroundChecked 24 FF229AF0 FF229AF0
    dialogLineProgress 25 FF527DA3 FF5E9DD4
    dialogLineProgressBackground 26 FFDBDBDB FF314352
    dialogButton 27 FF298ACF FF64B5EF
    dialogButtonSelector 28 0F000000 FF324156
    dialogIcon 29 FF1A1D21 FF8B9BAA
    dialogGrayLine 30 FFD2D2D2 FF0F1012
    dialogTopBackground 31 FF298ACF FF326A98
    dialog_inlineProgressBackground 32 F6F0F2F5 FF151E27
    dialog_inlineProgress 33 FF6B7378 FF7E8D9A
    dialogSearchBackground 34 FFF2F4F5 FF2A394B
    dialogSearchHint 35 FF98A0A7 FF7F8892
    dialogSearchIcon 36 FFA1A8AF FF77808F
    dialogSearchText 37 FF222222 FFFFFFFF
    dialogFloatingButton 38 FF229AF0 FF1A9CFF
    dialogFloatingButtonPressed 39 0F000000 FF1A9CFF
    dialogFloatingIcon 40 FFFFFFFF FFFFFFFF
    dialogShadowLine 41 12000000 14000000
    dialogEmptyImage 42 FF9FA4A8 FF7D8B99
    dialogEmptyText 43 FF8C9094 FF7D8B99
    dialogSwipeRemove 44 FFE56555 FFE86C6A
    dialogReactionMentionBackground 45 FFEB5E5E FFEB5E5E
    dialogCardShadow 46 17000000 40000000
    dialogGiftsBackground 47 FFF5F6F7 FF151E27
    dialogGiftsTabText 48 FF56595C 6FF1FDFF
    windowBackgroundWhite 49 FFFFFFFF FF1D2733
    windowBackgroundUnchecked 50 FF96A2AD FF1D2733
    windowBackgroundChecked 51 FF229AF0 FF4E81AB
    windowBackgroundCheckText 52 FFFFFFFF FFFFFFFF
    progressCircle 53 FF1C93E3 FF64B5FD
    listSelector 54 0F000000 14E6F7FF
    settings_listSelector 55 1D000010 14E6F7FF
    windowBackgroundWhiteInputField 56 FFDBDBDB FF485B6F
    windowBackgroundWhiteInputFieldActivated 57 FF229AF0 FF6EB2EF
    windowBackgroundWhiteGrayIcon 58 FF1A1D21 FF7D8B99
    windowBackgroundWhiteBlueText 59 FF4092CD FF64B5EF
    windowBackgroundWhiteBlueText2 60 FF3A95D5 FF79C4FC
    windowBackgroundWhiteBlueText3 61 FF2678B6 FF64B5EF
    windowBackgroundWhiteBlueText4 62 FF1C93E3 FF64B5EF
    windowBackgroundWhiteBlueText5 63 FF4C8ECA FF64B5EF
    windowBackgroundWhiteBlueText6 64 FF3A8CCF FF3A8CCF
    windowBackgroundWhiteBlueText7 65 FF377AAE FF79C4FC
    windowBackgroundWhiteBlueButton 66 FF1E88D3 E079C4FC
    windowBackgroundWhiteBlueIcon 67 FF379DE5 E079C4FC
    windowBackgroundWhiteGreenText 68 FF26972C FF61BD67
    windowBackgroundWhiteGreenText2 69 FF37A818 FF61D36B
    windowBackgroundWhiteGrayText 70 FF808384 FF7D8B99
    windowBackgroundWhiteGrayText2 71 FF82868A 6FF1FDFF
    windowBackgroundWhiteGrayText3 72 FF999999 FF7D8B99
    windowBackgroundWhiteGrayText4 73 FF808080 C87D8B99
    windowBackgroundWhiteGrayText5 74 FFA3A3A3 FF7D8B99
    windowBackgroundWhiteGrayText6 75 FF757575 FF7D8B99
    windowBackgroundWhiteGrayText7 76 FFC6C6C6 FFC6C6C6
    windowBackgroundWhiteGrayText8 77 FF6D6D72 FF7D8B99
    windowBackgroundWhiteBlackText 78 FF1A1D21 FFFFFFFF
    windowBackgroundWhiteHintText 79 FFA8A8A8 FF7D8B99
    windowBackgroundWhiteValueText 80 FF298ACF E079C4FC
    windowBackgroundWhiteLinkText 81 FF298ACF FF5EABE1
    windowBackgroundWhiteLinkSelection 82 3362A9E3 3364B5FD
    windowBackgroundWhiteBlueHeader 83 FF298ACF FF79C4FC
    switchTrack 84 FFA6ADB3 FF5D7484
    switchTrackChecked 85 FF229AF0 FF61A3D7
    switchTrackBlue 86 FF78828A FF58626E
    switchTrackBlueChecked 87 FF1079C4 FF80D5FF
    switchTrackBlueThumb 88 FFFFFFFF FF1D2733
    switchTrackBlueThumbChecked 89 FFFFFFFF FF4E81AB
    switchTrackBlueSelector 90 17404A53 19B9DDFA
    switchTrackBlueSelectorChecked 91 21024781 328CD7FF
    switch2Track 92 FFF57E7E FFF57E7E
    switch2TrackChecked 93 FF229AF0 FF229AF0
    checkboxSquareBackground 94 FF229AF0 FF64B5E5
    checkboxSquareCheck 95 FFFFFFFF FFFFFFFF
    checkboxSquareUnchecked 96 FF737373 FF546679
    checkboxSquareDisabled 97 FFB0B0B0 64445362
    windowBackgroundGray 98 FFF1F1F3 FF151E27
    windowBackgroundGrayShadow 99 FF000000 FF000000
    emptyListPlaceholder 100 FF73787B FF7D8B99
    divider 101 FFD9D9D9 95000000
    graySection 102 FFF5F5F5 FF141D27
    graySectionText 103 FF82878A FF7D8B99
    radioBackground 104 FFB3B3B3 9E7D8B99
    radioBackgroundChecked 105 FF229AF0 FF64B5EF
    checkbox 106 FF5EC245 FF5EC245
    checkboxDisabled 107 FFB0B9C2 FF3E5263
    checkboxCheck 108 FFFFFFFF FFFFFFFF
    fastScrollActive 109 FF229AF0 FF229AF0
    fastScrollInactive 110 FFC9CDD1 FF3D4A59
    fastScrollText 111 FFFFFFFF FFFFFFFF
    pollCreateIcons 112 FF909599 FF7D8B99
    text_RedRegular 113 FFCC2929 FFEE686F
    text_RedBold 114 FFCC4747 FFEE686F
    fill_RedNormal 115 FFEB5E5E FFEB5E5E
    fill_RedDark 116 FFFF0000 FFFF0000
    inappPlayerPerformer 117 FF1A1D21 FFFFFFFF
    inappPlayerTitle 118 FF1A1D21 6EDCF4FF
    inappPlayerBackground 119 FFFFFFFF FF212D3B
    inappPlayerPlayPause 120 FF229AF0 FF64B5EF
    inappPlayerClose 121 FF898B86 6EDCF4FF
    returnToCallBackground 122 FF44A1E3 FF5DA5E7
    returnToCallMutedBackground 123 FF9DA7B1 FF1D2733
    returnToCallText 124 FFFFFFFF FFFFFFFF
    contextProgressInner1 125 FFBFDFF6 64818E9B
    contextProgressOuter1 126 FF2B96E2 FF68B6F8
    contextProgressInner2 127 FFBFDFF6 FFBFDFF6
    contextProgressOuter2 128 FFFFFFFF FFFFFFFF
    contextProgressInner3 129 FFB3B3B3 FFB3B3B3
    contextProgressOuter3 130 FFFFFFFF FFFFFFFF
    contextProgressInner4 131 FFCACDD0 64818E9B
    contextProgressOuter4 132 FF2F3438 FF68B6F8
    avatar_text 133 FFFFFFFF FFFFFFFF
    avatar_backgroundSaved 134 FF69BDF9 FF69BDF9
    avatar_background2Saved 135 FF409FE1 FF409FE1
    avatar_backgroundArchived 136 FFB8C2CC FF384B5A
    avatar_backgroundArchivedHidden 137 FF229AF0 FF229AF0
    avatar_backgroundRed 138 FFFF845E FFE86C6A
    avatar_backgroundOrange 139 FFFEBB5B FFF2BC64
    avatar_backgroundViolet 140 FFB694F9 FFB694F9
    avatar_backgroundGreen 141 FF9AD164 FF9AD164
    avatar_backgroundCyan 142 FF5BCBE3 FF5BCBE3
    avatar_backgroundBlue 143 FF5CAFFA FF5CAFFA
    avatar_backgroundPink 144 FFFF8AAC FFFF8AAC
    avatar_background2Red 145 FFD45246 FFE14747
    avatar_background2Orange 146 FFF68136 FFE58943
    avatar_background2Violet 147 FF6C61DF FF6C61DF
    avatar_background2Green 148 FF46BA43 FF46BA43
    avatar_background2Cyan 149 FF359AD4 FF359AD4
    avatar_background2Blue 150 FF408ACF FF408ACF
    avatar_background2Pink 151 FFD95574 FFD95574
    avatar_backgroundGray 152 FFA1ABB5 FFA1ABB5
    avatar_backgroundInProfileBlue 153 FFFFFFFF FF549CDD
    avatar_backgroundActionBarBlue 154 FFF5F5F5 FF212D3B
    avatar_actionBarSelectorBlue 155 121A1D21 1EE6F5FF
    avatar_actionBarIconBlue 156 FF1A1D21 FFFFFFFF
    avatar_subtitleInProfileBlue 157 FF1A1D21 FF8B97A2
    avatar_nameInMessageRed 158 FFCC5049 FFE88878
    avatar_nameInMessageOrange 159 FFD67722 FFE8AB5A
    avatar_nameInMessageViolet 160 FF955CDB FF8C8DEA
    avatar_nameInMessageGreen 161 FF40A920 FF7DD071
    avatar_nameInMessageCyan 162 FF309EBA FF53CCC6
    avatar_nameInMessageBlue 163 FF368AD1 FF5CADEA
    avatar_nameInMessagePink 164 FFC7508B FFE8749A
    actionBarDefault 165 FFFFFFFF FF242D39
    actionBarDefaultSelector 166 121A1D21 1ECFE8FF
    actionBarWhiteSelector 167 121A1D21 10FFFFFF
    actionBarDefaultIcon 168 FF1A1D21 FFFFFFFF
    actionBarActionModeDefault 169 FFFFFFFF FF263240
    actionBarActionModeDefaultTop 170 10000000 FF22303D
    actionBarActionModeDefaultIcon 171 FF1A1D21 FFFFFFFF
    actionBarActionModeDefaultSelector 172 FFE2E2E2 19DAF7FF
    actionBarDefaultTitle 173 FF1A1D21 FFFFFFFF
    actionBarDefaultSubtitle 174 FF79817E 7DDBF2FF
    actionBarDefaultSearch 175 FF1A1D21 FFFFFFFF
    actionBarDefaultSearchPlaceholder 176 FF79817E 78DCF4FF
    actionBarDefaultSubmenuItem 177 FF1A1D21 FFFFFFFF
    actionBarDefaultSubmenuItemIcon 178 FF1A1D21 FFFFFFFF
    actionBarDefaultSubmenuBackground 179 FFFFFFFF FF283848
    actionBarDefaultSubmenuSeparator 180 FFF5F5F5 FF1F2E3F
    actionBarTabActiveText 181 FF298ACF FF6ABFFF
    actionBarTabUnactiveText 182 FF777C7F FF8B97A2
    actionBarTabLine 183 FF298ACF FF64ADFF
    actionBarTabSelector 184 121A1D21 3736546A
    actionBarDefaultArchived 185 FFFFFFFF FF2E384B
    actionBarDefaultArchivedSelector 186 121A1D21 FF3E3E3F
    actionBarDefaultArchivedIcon 187 FF1A1D21 FFFFFFFF
    actionBarDefaultArchivedTitle 188 FF1A1D21 FFFFFFFF
    actionBarDefaultArchivedSearch 189 FF1A1D21 FFFFFFFF
    actionBarDefaultArchivedSearchPlaceholder 190 FF838C96 78DCF4FF
    actionBarBrowser 191 FFFFFFFF FF242D39
    chats_onlineCircle 192 FF4BCB1C FF64B5EF
    chats_unreadCounter 193 FF229AF0 FF64B5EF
    chats_unreadCounterMuted 194 FFBEC3C7 FF3E5263
    chats_unreadCounterText 195 FFFFFFFF FFFFFFFF
    chats_name 196 FF1A1D21 FFE9EEF4
    chats_nameArchived 197 FF1A1D21 FFE9EEF4
    chats_secretName 198 FF00A60E FF71D756
    chats_secretIcon 199 FF19B126 FF71D756
    chats_pinnedIcon 200 FF919294 FF586D80
    chats_archiveBackground 201 FF229AF0 FF5796CC
    chats_archivePinBackground 202 FF9FAAB3 FF2E3E4B
    chats_archiveIcon 203 FFFFFFFF FFFFFFFF
    chats_archiveText 204 FFFFFFFF FFFFFFFF
    chats_message 205 FF75787A FF7D8B99
    chats_messageArchived 206 FF919191 FF7D8B99
    chats_message_threeLines 207 FF8E9091 FF7D8B99
    chats_draft 208 FFDD4B39 D9FC474A
    chats_nameMessage 209 FF298ACF FFE9EEF4
    chats_nameMessageArchived 210 FF8B8D8F FF7D8B99
    chats_nameMessage_threeLines 211 FF424449 FFE9EEF4
    chats_nameMessageArchived_threeLines 212 FF5E5E5E FFE9EEF4
    chats_attachMessage 213 FF298ACF FF7D8E98
    chats_actionMessage 214 FF298ACF FF64AFE9
    chats_date 215 FF848688 FF737F8B
    chats_date_bold 216 FF919395 FF737F8B
    chats_pinnedOverlay 217 08000000 08FFFFFF
    chats_tabletSelectedOverlay 218 0F000000 0FFFFFFF
    chats_sentCheck 219 FF46AA36 FF64B5EF
    chats_sentReadCheck 220 FF46AA36 FF64B5EF
    chats_sentClock 221 FF75BD5E FF4C5F6A
    chats_sentError 222 FFD55252 FFD55252
    chats_sentErrorIcon 223 FFFFFFFF FFFFFFFF
    chats_verifiedBackground 224 FF33A8E6 FF64B5EF
    chats_verifiedCheck 225 FFFFFFFF FFFFFFFF
    chats_muteIcon 226 FFBDC1C4 FF4E5F6A
    chats_mentionIcon 227 FFFFFFFF FFFFFFFF
    chats_menuTopShadow 228 00000000 A4141D26
    chats_menuTopShadowCats 229 00000000 00000000
    chats_menuBackground 230 FFFFFFFF FF1B242F
    chats_menuItemText 231 FF444444 F4FFFFFF
    chats_menuItemCheck 232 FF598FBA FF598FBA
    chats_menuItemIcon 233 FF889198 FF7E8D9A
    chats_menuName 234 FFFFFFFF FFFFFFFF
    chats_menuPhone 235 FFFFFFFF 93C0D0DD
    chats_menuPhoneCats 236 FFC2E5FF FF7C90A4
    chats_menuTopBackgroundCats 237 FF598FBA FF23303F
    chats_menuTopBackground 238 00000000 00000000
    chats_actionIcon 239 FFFFFFFF FFFFFFFF
    chats_actionBackground 240 FF65A9E0 FF5FA3DE
    chats_actionPressedBackground 241 FF569DD6 FF569DD6
    chats_archivePullDownBackground 242 FFC6C9CC FF3E5263
    chats_archivePullDownBackgroundActive 243 FF229AF0 FF5FA3DE
    chats_tabUnreadActiveBackground 244 FF66ADE1 FF66ADE1
    chats_tabUnreadUnactiveBackground 245 FFC5C9CC FFC5C9CC
    chat_attachCheckBoxCheck 246 FFFFFFFF FFFFFFFF
    chat_attachCheckBoxBackground 247 FF229AF0 FF1A9CFF
    chat_attachPhotoBackground 248 0C000000 0C000000
    chat_attachActiveTab 249 FF33A7F5 FF6ABFFF
    chat_attachUnactiveTab 250 FF92999E FF6D91A6
    chat_attachPermissionImage 251 FF333333 FFF6F6F6
    chat_attachPermissionMark 252 FFE25050 FFF6574E
    chat_attachPermissionText 253 FF6F777A FFF6F6F6
    chat_attachEmptyImage 254 FFCCCCCC FF7D8B99
    chat_inPollCorrectAnswer 255 FF60C255 FF60C255
    chat_outPollCorrectAnswer 256 FF60C255 FF60C255
    chat_inPollWrongAnswer 257 FFEB6060 FFF66F6B
    chat_outPollWrongAnswer 258 FFEB6060 FFF66F6B
    chat_attachIcon 259 FFFFFFFF FFFFFFFF
    chat_attachGalleryBackground 260 FF459DF5 FF4D96F5
    chat_attachAudioBackground 261 FFEB6060 FFF66F6B
    chat_attachContactBackground 262 FFF2C04B FFDEB045
    chat_attachContactText 263 FFDFA000 FFDEB045
    chat_attachLocationBackground 264 FF60C255 FF60C255
    chat_attachPollBackground 265 FFF2C04B FFDEB045
    chat_status 266 FF298ACF FF73BBF7
    chat_inGreenCall 267 FF00C853 FF48DD76
    chat_inBubble 268 FFFFFFFF FF232E3B
    chat_inBubbleSelectedOverlay 269 FFFF0000 FFFF0000
    chat_inBubbleShadow 270 FF1D3753 32000000
    chat_compact_background 271 FFFFFFFF FF1D2733
    chat_compact_backgroundGradient 272 08000000 00000000
    chat_compact_glassOutline 273 24000000 00000000
    chat_compact_glassShadow 274 14000000 00000000
    chat_compact_glassHairline 275 0D000000 00000000
    chat_compact_topicSeparatorText 276 FF000000 FFFFFFFF
    chat_compact_inputGlassOutline 277 24000000 00000000
    chat_compact_buttonGlassOutline 278 24000000 00000000
    chat_compact_fadeEdge 279 FFFFFFFF FF1D2733
    chat_compact_fadeMiddle 280 A3FFFFFF A31D2733
    chat_compact_actionBackground 281 0D000000 1AFFFFFF
    chat_compact_actionText 282 FF000000 FFFFFFFF
    chat_compact_actionIcon 283 FF000000 FFFFFFFF
    chat_compact_botButtonText 284 FF000000 FFFFFFFF
    chat_compact_pullingDownText 285 FF000000 FFFFFFFF
    chat_compact_topicEmptyText 286 FF000000 FFFFFFFF
    chat_compact_progress 287 FF000000 FFFFFFFF
    chat_compact_outBackground 288 0F000000 1AFFFFFF
    chat_compact_outTimeText 289 FF808384 80FFFFFF
    chat_compact_outCheck 290 FF1A1D21 FFFFFFFF
    chat_compact_outReplyBackground 291 0D000000 0DFFFFFF
    chat_compact_outReplyLine 292 FF1A1D21 FFFFFFFF
    chat_compact_outReplyText 293 FF1A1D21 FFFFFFFF
    chat_compact_inTimeText 294 80A1AAB3 6C8091A0
    chat_compact_replyText 295 FF808384 80FFFFFF
    chat_compact_sideButtonIcon 296 FF1A1D21 FFFFFFFF
    chat_compact_inAudioDuration 297 FF1A1D21 FFFFFFFF
    chat_compact_inWaveform 298 FF1A1D21 FFFFFFFF
    chat_compact_inWaveformBackground 299 4D1A1D21 4DFFFFFF
    chat_compact_inTranscribeButton 300 FF1A1D21 FFFFFFFF
    chat_compact_outAccent 301 FF1A1D21 FFFFFFFF
    chat_compact_outAccentFill 302 FF1A1D21 FFFFFFFF
    chat_compact_outAccentIcon 303 FFFFFFFF FF1A1D21
    chat_compact_outSecondaryText 304 FF808384 80FFFFFF
    chat_compact_outAccentLight 305 1A1A1D21 1FFFFFFF
    chat_compact_outAccentBorder 306 261A1D21 33FFFFFF
    chat_compact_reactionBackground 307 0D000000 1AFFFFFF
    chat_compact_reactionText 308 FF1A1D21 FFFFFFFF
    chat_compact_reactionBackgroundSelected 309 FF1A1D21 FFFFFFFF
    chat_compact_reactionTextSelected 310 FFFFFFFF FF1A1D21
    actionBarActionModeReaction 311 FFF0F0F0 12FFFFFF
    actionBarActionModeReactionText 312 FF82868A FFFFFFFF
    actionBarActionModeReactionDot 313 FFC0C0C0 FF353E47
    buttonNeutral 314 FFE4E4E4 5E171A1D
    buttonNeutralText 315 FF1A1D21 FFFFFFFF
    chat_outBubble 316 FFEFFFDE FF3E618A
    chat_outBubbleSelected 317 FFD9F7C5 FF4B7DAF
    chat_outBubbleShadow 318 FF1E750C 32000000
    chat_outBubbleGradient1 319 00000000 00000000
    chat_outBubbleGradient2 320 00000000 00000000
    chat_outBubbleGradient3 321 00000000 00000000
    chat_outGreenCall 322 FF00C853 FF48DD76
    chat_outSentCheck 323 FF5DB050 FF87C7FF
    chat_outSentCheckSelected 324 FF5DB050 FFBEDFFA
    chat_outSentCheckRead 325 FF5DB050 FF87C7FF
    chat_outSentCheckReadSelected 326 FF5DB050 FFBEDFFA
    chat_outSentClock 327 FF75BD5E FF82ABCB
    chat_outSentClockSelected 328 FF75BD5E FFBEDFFA
    chat_outMediaIcon 329 FFEFFFDE FFFFFFFF
    chat_outMediaIconSelected 330 FFE1F8CF FFFFFFFF
    chat_outViews 331 FF6EB257 FF8FBCDF
    chat_outViewsSelected 332 FF6EB257 FFBEDFFA
    chat_outMenu 333 FF91CE7E FF6D9ACE
    chat_outMenuSelected 334 FF91CE7E DFBEDFFA
    chat_outInstant 335 FF55AB4F FF8CC6FF
    chat_outInstantSelected 336 FF489943 FFBEDFFA
    chat_outPreviewInstantText 337 FF55AB4F FF9ACDFF
    chat_outForwardedNameText 338 FF55AB4F FF8CC6FF
    chat_outViaBotNameText 339 FF55AB4F FF8CC6FF
    chat_outReplyLine 340 FF6EB969 FF9ACDFF
    chat_outReplyLine2 341 FF40A920 FF9ACDFF
    chat_outReplyNameText 342 FF55AB4F FF9ACDFF
    chat_outReplyMessageText 343 FF000000 FFFFFFFF
    chat_outReplyMediaMessageText 344 FF65B05B FF8FBCDF
    chat_outReplyMediaMessageSelectedText 345 FF65B05B FFFFFFFF
    chat_outPreviewLine 346 FF88C97B FF9ACDFF
    chat_outSiteNameText 347 FF55AB4F FFFFFFFF
    chat_outContactNameText 348 FF55AB4F FFFFFFFF
    chat_outContactPhoneText 349 FF354234 FF8FBCDF
    chat_outContactPhoneSelectedText 350 FF354234 FFBEDFFA
    chat_outAudioPerformerText 351 FF354234 FF8FBCDF
    chat_outAudioPerformerSelectedText 352 FF354234 FFBEDFFA
    chat_outTimeSelectedText 353 FF70B15C FFBEDFFA
    chat_outAdminText 354 FF70B15C FF8FBCDF
    chat_outAdminSelectedText 355 FF70B15C FFBEDFFA
    chat_outAudioProgress 356 FFEFFFDE FFFFFFFF
    chat_outAudioSelectedProgress 357 FFE1F8CF FFFFFFFF
    chat_outTimeText 358 FF70B15C FF8FBCDF
    chat_outAudioTitleText 359 FF55AB4F FFFFFFFF
    chat_outAudioDurationText 360 FF65B05B FF8FBCDF
    chat_outAudioDurationSelectedText 361 FF65B05B FFBEDFFA
    chat_outAudioSeekbar 362 FFBBE3AC E66591C3
    chat_outAudioCacheSeekbar 363 3FBBE3AC FF6591C3
    chat_outAudioSeekbarSelected 364 FFA9DD96 FF6F9FD6
    chat_outAudioSeekbarFill 365 FF78C272 FF86C4FB
    chat_outVoiceSeekbar 366 FFBBE3AC E66591C3
    chat_outVoiceSeekbarSelected 367 FFA9DD96 FF72A4DC
    chat_outVoiceSeekbarFill 368 FF78C272 FF86C4FB
    chat_outFileProgress 369 FFDAF5C3 FFFFFFFF
    chat_outFileProgressSelected 370 FFC5ECA7 FFFFFFFF
    chat_outFileNameText 371 FF55AB4F FFFFFFFF
    chat_outFileInfoText 372 FF65B05B FF8FBCDF
    chat_outFileInfoSelectedText 373 FF65B05B FFBEDFFA
    chat_outFileBackground 374 FFDAF5C3 FF47709A
    chat_outFileBackgroundSelected 375 FFC5ECA7 FF5289BE
    chat_outVenueInfoText 376 FF65B05B FF8FBCDF
    chat_outVenueInfoSelectedText 377 FF65B05B FFBEDFFA
    chat_outLinkSelectBackground 378 3362A9E3 5A62A9E3
    chat_outLoader 379 FF78C272 FF68A3D7
    chat_outLoaderSelected 380 FF6AB564 FF68A3D7
    chat_outLocationIcon 381 FF87BF78 FFFFFFFF
    chat_outContactBackground 382 FF78C272 FF68A3D7
    chat_outContactIcon 383 FFEFFFDE FFFFFFFF
    chat_outReactionButtonBackground 384 FF78C272 FFFFFFFF
    chat_outTextSelectionHighlight 385 2E3F9923 5A62A9E3
    chat_outTextSelectionCursor 386 FF419FE8 FF419FE8
    chat_outBubbleLocationPlaceholder 387 1E307311 1E307311
    chat_outBubbleSelectedOverlay 388 FFFF0000 FFFF0000
    chat_outPsaNameText 389 FF5A9C39 FF7DD071
    chat_outBubbleGradientAnimated 390 FFFF0000 FFFF0000
    chat_outBubbleGradientSelectedOverlay 391 14000000 14FFFFFF
    chat_inBubbleSelected 392 FFECF7FD FF314A61
    chat_messageTextIn 393 FF000000 FFFAFAFA
    chat_messageTextOut 394 FF000000 FFFAFAFA
    chat_messageLinkIn 395 FF2678B6 FF79C4FC
    chat_messageLinkOut 396 FF2678B6 FF9ACDFF
    chat_serviceText 397 FFFFFFFF FFFFFFFF
    chat_serviceLink 398 FFFFFFFF FFFFFFFF
    chat_serviceIcon 399 FFFFFFFF FFFFFFFF
    chat_serviceBackgroundSelector 402 20FFFFFF 20FFFFFF
    chat_muteIcon 403 FF79817E 3CBCE5FF
    chat_lockIcon 404 FF222222 FFFFFFFF
    chat_inSentClock 405 FFA1AAB3 FF5D6F80
    chat_inSentClockSelected 406 FF93BDCA FF8DB2D3
    chat_mediaSentCheck 407 FFFFFFFF FFFFFFFF
    chat_mediaSentClock 408 FFFFFFFF B2FFFFFF
    chat_inMediaIcon 409 FFFFFFFF FFFFFFFF
    chat_inMediaIconSelected 410 FFEFF8FE FFFFFFFF
    chat_mediaTimeBackground 411 66000000 66000000
    chat_inViews 412 FFA1AAB3 FF798997
    chat_inViewsSelected 413 FF93BDCA FF8DB2D3
    chat_mediaViews 414 FFFFFFFF FFFFFFFF
    chat_inMenu 415 FFB6BDC5 7993B1CD
    chat_inMenuSelected 416 FF98C1CE A58DB2D3
    chat_mediaMenu 417 FFFFFFFF FFFFFFFF
    chat_inInstant 418 FF298ACF FF79C4FC
    chat_inInstantSelected 419 FF3079B5 FFA9CFEE
    chat_sentError 420 FFDB3535 FFF6574E
    chat_sentErrorIcon 421 FFFFFFFF FFFFFFFF
    chat_selectedBackground 422 280A90F0 2A5F9DE3
    chat_previewDurationText 423 FFFFFFFF FFFFFFFF
    chat_previewGameText 424 FFFFFFFF FFFFFFFF
    chat_inPreviewInstantText 425 FF298ACF FF79C4FC
    chat_secretTimeText 426 FFE4E2E0 FFC7D9EB
    chat_stickerNameText 427 FFFFFFFF FFFFFFFF
    chat_botButtonText 428 FFFFFFFF FFFFFFFF
    chat_inForwardedNameText 429 FF3886C7 FF79C4FC
    chat_inPsaNameText 430 FF5A9C39 FF7DD071
    chat_inViaBotNameText 431 FF298ACF FF79C4FC
    chat_stickerViaBotNameText 432 FFFFFFFF FFFFFFFF
    chat_inQuote 433 FF459BD8 FF79C4FC
    chat_outQuote 434 FF6AB860 FF9ACDFF
    chat_inReplyLine 435 FF599FD8 FF79C4FC
    chat_stickerReplyLine 436 FFFFFFFF FFFFFFFF
    chat_inReplyNameText 437 FF298ACF FF79C4FC
    chat_stickerReplyNameText 438 FFFFFFFF FFFFFFFF
    chat_inReplyMessageText 439 FF000000 FFFFFFFF
    chat_inReplyMediaMessageText 440 FFA1AAB3 FF798897
    chat_inReplyMediaMessageSelectedText 441 FF89B4C1 FF8DB2D3
    chat_stickerReplyMessageText 442 FFFFFFFF FFFFFFFF
    chat_inPreviewLine 443 FF70B4E8 FF79C4FC
    chat_inSiteNameText 444 FF298ACF FF79C4FC
    chat_inContactNameText 445 FF4E9AD4 FF79C4FC
    chat_inContactPhoneText 446 FF2F3438 FF798897
    chat_inContactPhoneSelectedText 447 FF2F3438 FF8DB2D3
    chat_mediaProgress 448 FFFFFFFF FFFFFFFF
    chat_inAudioProgress 449 FFFFFFFF FFFFFFFF
    chat_inAudioSelectedProgress 450 FFEFF8FE FFFFFFFF
    chat_mediaTimeText 451 FFFFFFFF FFFFFFFF
    chat_inAdminText 452 FFC0C6CB D98091A0
    chat_inAdminSelectedText 453 FF89B4C1 FF8DB2D3
    chat_inTimeText 454 FFA1AAB3 D98091A0
    chat_inTimeSelectedText 455 FF89B4C1 FF8DB2D3
    chat_inAudioPerformerText 456 FF2F3438 FF798897
    chat_inAudioPerformerSelectedText 457 FF2F3438 FF8DB2D3
    chat_inAudioTitleText 458 FF4E9AD4 FF79C4FC
    chat_inAudioDurationText 459 FFA1AAB3 FF7A8897
    chat_inAudioDurationSelectedText 460 FF89B4C1 FF8DB2D3
    chat_inAudioSeekbar 461 FFE4EAF0 FF516170
    chat_inAudioCacheSeekbar 462 3FE4EAF0 FF516170
    chat_inAudioSeekbarSelected 463 FFBCDEE8 FF7391AB
    chat_inAudioSeekbarFill 464 FF229AF0 FF229AF0
    chat_inVoiceSeekbar 465 FFDEE5EB FF5D6F80
    chat_inVoiceSeekbarSelected 466 FFBCDEE8 FF7391AB
    chat_inVoiceSeekbarFill 467 FF229AF0 FF64B5EF
    chat_inFileProgress 468 FFEBF0F5 FFFFFFFF
    chat_inFileProgressSelected 469 FFCBEAF6 FFFFFFFF
    chat_inFileNameText 470 FF298ACF FFFFFFFF
    chat_inFileInfoText 471 FFA1AAB3 FF798997
    chat_inFileInfoSelectedText 472 FF89B4C1 FF8DB2D3
    chat_inFileBackground 473 FFEBF0F5 FF2F3C4A
    chat_inFileBackgroundSelected 474 FFCBEAF6 FF3D5778
    chat_inVenueInfoText 475 FFA1AAB3 FF798997
    chat_inVenueInfoSelectedText 476 FF89B4C1 FF8DB2D3
    chat_mediaInfoText 477 FFFFFFFF FFFFFFFF
    chat_linkSelectBackground 478 3362A9E3 5A62A9E3
    chat_textSelectBackground 479 6662A9E3 5A62A9E3
    chat_wallpaper 480 FFFF0000 FF151E27
    chat_wallpaper_gradient_to1 481 FFFF0000 FFFF0000
    chat_wallpaper_gradient_to2 482 00000000 00000000
    chat_wallpaper_gradient_to3 483 00000000 00000000
    chat_wallpaper_gradient_rotation 484 FFFF0000 FFFF0000
    chat_messagePanelBackground 485 FFFFFFFF FF212D3B
    chat_messagePanelShadow 486 FF000000 43000000
    chat_messagePanelText 487 FF000000 FFFFFFFF
    chat_messagePanelHint 488 FF858A84 6EDBEFFF
    chat_messagePanelCursor 489 FF54A1DB FF54A1DB
    chat_messagePanelIcons 490 FF8E959B 6EE0F0FF
    chat_messagePanelSend 491 FF229AF0 FF229AF0
    chat_messagePanelVoiceLock 492 FFA4A4A4 FFFFFFFF
    chat_messagePanelVoiceLockBackground 493 FFFFFFFF FF314358
    chat_messagePanelVoiceLockShadow 494 FF000000 FF000000
    chat_topPanelBackground 495 FFFFFFFF FF212D3B
    chat_topPanelClose 496 FF818786 6EDCF4FF
    chat_topPanelLine 497 FF3FA8EF FF5E9DD4
    chat_topPanelTitle 498 FF298ACF FF6BB2E6
    chat_topPanelMessage 499 FF767E7C 6EDCF4FF
    chat_addContact 500 FF298ACF FF79C4FC
    chat_inLoader 501 FF229AF0 FF609DD2
    chat_inLoaderSelected 502 FF65ABE0 FF609DD2
    chat_inLoaderPhoto 503 FFA2B8C8 FF243442
    chat_mediaLoaderPhoto 504 66000000 66000000
    chat_mediaLoaderPhotoSelected 505 7F000000 7F000000
    chat_mediaLoaderPhotoIcon 506 FFFFFFFF FFFFFFFF
    chat_mediaLoaderPhotoIconSelected 507 FFD9D9D9 FFD9D9D9
    chat_inLocationBackground 508 FFEBF0F5 FF334251
    chat_inLocationIcon 509 FFA2B5C7 FFFFFFFF
    chat_inContactBackground 510 FF229AF0 FF609DD2
    chat_inContactIcon 511 FFFFFFFF FFFFFFFF
    chat_replyPanelIcons 512 FF229AF0 FF229AF0
    chat_replyPanelClose 513 FF8E959B 6EDCF4FF
    chat_replyPanelName 514 FF298ACF FF79C4FC
    chat_replyPanelLine 515 FFE8E8E8 5E171A1D
    chat_searchPanelIcons 516 FF676A6F FF79C4FC
    chat_searchPanelText 517 FF676A6F FFFFFFFF
    chat_secretChatStatusText 518 FF7F7F7F FF798997
    chat_fieldOverlayText 519 FF298ACF FF64B5EF
    chat_stickersHintPanel 520 FFFFFFFF FF323D4F
    chat_botSwitchToInlineText 521 FF4391CC FF79C4FC
    chat_unreadMessagesStartArrowIcon 522 FFA2B5C7 FF5A6B7A
    chat_unreadMessagesStartText 523 FF5695CC DAFFFFFF
    chat_unreadMessagesStartBackground 524 FFFFFFFF FF253442
    chat_inlineResultIcon 525 FF5795CC FF79C4FC
    chat_emojiPanelBackground 526 FFF0F2F5 FF1D2733
    chat_emojiSearchBackground 527 FFE5E9EE 0ACDEAFF
    chat_emojiSearchIcon 528 FF94A1AF FF677687
    chat_emojiPanelShadowLine 529 12000000 32000000
    chat_emojiPanelEmptyText 530 FF949BA1 FF7D8B99
    chat_emojiPanelIcon 531 FF9DA4AB FF677687
    chat_emojiBottomPanelIcon 532 FF8C9197 FF677687
    chat_emojiPanelIconSelected 533 FF5E6976 FF64B5EF
    chat_emojiPanelStickerPackSelector 534 FFE2E5E7 0ACDEAFF
    chat_emojiPanelStickerPackSelectorLine 535 FF56ABF0 FF64B5EF
    chat_emojiPanelBackspace 536 FF8C9197 FF677687
    chat_emojiPanelTrendingTitle 537 FF222222 FFFFFFFF
    chat_emojiPanelStickerSetName 538 FF828B94 FF828B94
    chat_emojiPanelStickerSetNameHighlight 539 FF278DDB FF64B5EF
    chat_emojiPanelStickerSetNameIcon 540 FFB1B6BC FFB1B6BC
    chat_emojiPanelTrendingDescription 541 FF8A8A8A FF7D8B99
    chat_botKeyboardButtonText 542 F0444444 FFFFFFFF
    chat_botKeyboardButtonBackground 543 66BCC3C8 FF293645
    chat_botKeyboardButtonBackgroundPressed 544 66808C94 FF3A4C62
    chat_emojiPanelNewTrending 545 FF4DA6EA FF4DA6EA
    chat_messagePanelVoicePressed 546 FFFFFFFF FFFFFFFF
    chat_messagePanelVoiceBackground 547 FF229AF0 FF229AF0
    chat_messagePanelVoiceDelete 548 FF737373 FFFFFFFF
    chat_messagePanelVoiceDuration 549 FFFFFFFF FFFFFFFF
    chat_recordedVoicePlayPause 550 FFFFFFFF FFFFFFFF
    chat_recordedVoiceProgress 551 FFB1DEFF FFB1DEFF
    chat_recordedVoiceProgressInner 552 FFFFFFFF FFFFFFFF
    chat_recordedVoiceDot 553 FFDA564D FFED5D54
    chat_recordedVoiceBackground 554 FF5DADE8 FF5DADE8
    chat_recordedVoiceDarkerBackground 555 FF1F89DB FF1F89DB
    chat_recordVoiceCancel 556 FF3A95D4 FF73B9EE
    chat_recordTime 557 FF8E959B FFFFFFFF
    chat_messagePanelCancelInlineBot 558 FFADADAD 64E1F0FF
    chat_gifSaveHintText 559 FFFFFFFF FFFFFFFF
    chat_gifSaveHintBackground 560 E21F2B38 E21F2B38
    chat_goDownButton 561 FFFFFFFF FF212D3B
    chat_goDownButtonCounter 562 FFFFFFFF FFFFFFFF
    chat_goDownButtonCounterBackground 563 FF229AF0 FF51AAEE
    chat_inTextSelectionHighlight 564 5062A9E3 5A62A9E3
    chat_TextSelectionCursor 565 FF419FE8 FF419FE8
    chat_inBubbleLocationPlaceholder 566 1E506373 1E506373
    chat_BlurAlpha 567 B2000000 B2000000
    chat_BlurAlphaSlow 568 C1000000 CC000000
    chat_editMediaButton 569 FF1A9CFF FF1A9CFF
    chat_msgIvButtonDefaultIn 570 FFEDEDED FFEDEDED
    chat_msgIvButtonDefaultInPressed 571 FFEDEDED FFEDEDED
    chat_msgIvButtonDefaultInText 572 FF1A1D21 FFFAFAFA
    chat_msgIvButtonPrimaryIn 573 FF229AF0 FF229AF0
    chat_msgIvButtonPrimaryInPressed 574 FF229AF0 FF4299DB
    chat_msgIvButtonPrimaryInText 575 FFF8FCFF FFF8FCFF
    chat_msgIvButtonDangerIn 576 FFF8EAE9 FFF8EAE9
    chat_msgIvButtonDangerInPressed 577 FFF8EAE9 FFF8EAE9
    chat_msgIvButtonDangerInText 578 FFCC5049 FFE88878
    chat_msgIvButtonSuccessIn 579 FFE8F4E4 FFE8F4E4
    chat_msgIvButtonSuccessInPressed 580 FFE8F4E4 FFE8F4E4
    chat_msgIvButtonSuccessInText 581 FF40A920 FF40A920
    chat_msgIvButtonDefaultInlineIn 582 FFE9F3FA FFE9F3FA
    chat_msgIvButtonDefaultInlineInPressed 583 FFE9F3FA FFE9F3FA
    chat_msgIvButtonDefaultInlineInText 584 FF298ACF FF298ACF
    chat_msgIvButtonDefaultOut 585 FFDCF4CB FFDCF4CB
    chat_msgIvButtonDefaultOutPressed 586 FFDCF4CB FFDCF4CB
    chat_msgIvButtonDefaultOutText 587 FF53AB49 FFFAFAFA
    chat_msgIvButtonPrimaryOut 588 FF53AB49 FF53AB49
    chat_msgIvButtonPrimaryOutPressed 589 FF53AB49 FF4299DB
    chat_msgIvButtonPrimaryOutText 590 FFFAFCF9 FFFAFCF9
    chat_msgIvButtonDangerOut 591 FFEAE9CB FFEAE9CB
    chat_msgIvButtonDangerOutPressed 592 FFEAE9CB FFEAE9CB
    chat_msgIvButtonDangerOutText 593 FFCC5049 FFCC5049
    chat_msgIvButtonSuccessOut 594 FFDCF4CB FFDCF4CB
    chat_msgIvButtonSuccessOutPressed 595 FFDCF4CB FFDCF4CB
    chat_msgIvButtonSuccessOutText 596 FF40A920 FF40A920
    chat_msgIvButtonDefaultInlineOut 597 FFDCF4CB FFDCF4CB
    chat_msgIvButtonDefaultInlineOutPressed 598 FFDCF4CB FFDCF4CB
    chat_msgIvButtonDefaultInlineOutText 599 FF53AB49 FF53AB49
    voipgroup_listSelector 600 0EFFFFFF 0EFFFFFF
    voipgroup_inviteMembersBackground 601 FF222A33 FF222A33
    voipgroup_actionBar 602 FF0F1317 FF0F1317
    voipgroup_actionBarItems 603 FFFFFFFF FFFFFFFF
    voipgroup_actionBarItemsSelector 604 1EBADBFF 1EBADBFF
    voipgroup_actionBarUnscrolled 605 FF191F26 FF191F26
    voipgroup_listViewBackgroundUnscrolled 606 FF222A33 FF222A33
    voipgroup_lastSeenTextUnscrolled 607 FF858D94 FF858D94
    voipgroup_mutedIconUnscrolled 608 FF7E868C FF7E868C
    voipgroup_nameText 609 FFFFFFFF FFFFFFFF
    voipgroup_lastSeenText 610 FF79838A FF79838A
    voipgroup_listeningText 611 FF4DB8FF FF4DB8FF
    voipgroup_speakingText 612 FF77EE7D FF77EE7D
    voipgroup_mutedIcon 613 FF6F7980 FF6F7980
    voipgroup_mutedByAdminIcon 614 FFFF7070 FFFF7070
    voipgroup_listViewBackground 615 FF1C2229 FF1C2229
    voipgroup_dialogBackground 616 FF1C2229 FF1C2229
    voipgroup_leaveCallMenu 617 FFFF7575 FFFF7575
    voipgroup_checkMenu 618 FF6BB6F9 FF6BB6F9
    voipgroup_soundButton 619 7D2C414D 7D2C414D
    voipgroup_soundButtonActive 620 7D22A4EB 7D22A4EB
    voipgroup_soundButtonActiveScrolled 621 8233B4FF 8233B4FF
    voipgroup_soundButton2 622 7D28593A 7D28593A
    voipgroup_soundButtonActive2 623 7D18B751 7D18B751
    voipgroup_soundButtonActive2Scrolled 624 8224BF46 8224BF46
    voipgroup_leaveButton 625 7DF75C5C 7DF75C5C
    voipgroup_leaveButtonScrolled 626 82D14D54 82D14D54
    voipgroup_muteButton 627 FF77E55C FF77E55C
    voipgroup_muteButton2 628 FF7DDCAA FF7DDCAA
    voipgroup_muteButton3 629 FF56C7FE FF56C7FE
    voipgroup_unmuteButton 630 FF539EF8 FF539EF8
    voipgroup_unmuteButton2 631 FF66D4FB FF66D4FB
    voipgroup_disabledButton 632 FF1C2229 FF1C2229
    voipgroup_rtmpButton 633 FF2A3853 FF2A3853
    voipgroup_disabledButtonActive 634 FF2C3A45 FF2C3A45
    voipgroup_disabledButtonActiveScrolled 635 8277A1FC 8277A1FC
    voipgroup_connectingProgress 636 FF28BAFF FF28BAFF
    voipgroup_scrollUp 637 FF394654 FF394654
    voipgroup_searchPlaceholder 638 FF858D94 FF858D94
    voipgroup_searchBackground 639 FF303B47 FF303B47
    voipgroup_searchText 640 FFFFFFFF FFFFFFFF
    voipgroup_overlayGreen1 641 FF12B522 FF12B522
    voipgroup_overlayGreen2 642 FF00D6C1 FF00D6C1
    voipgroup_overlayBlue1 643 FF2BCEFF FF2BCEFF
    voipgroup_overlayBlue2 644 FF0976E3 FF0976E3
    voipgroup_topPanelGreen1 645 FF52CE5D FF52CE5D
    voipgroup_topPanelGreen2 646 FF00B1C0 FF00B1C0
    voipgroup_topPanelBlue1 647 FF60C7FB FF60C7FB
    voipgroup_topPanelBlue2 648 FF519FF9 FF519FF9
    voipgroup_topPanelGray 649 FF8599AA FF5F7381
    voipgroup_overlayAlertGradientMuted 650 FF236D92 FF236D92
    voipgroup_overlayAlertGradientMuted2 651 FF2C4D6B FF2C4D6B
    voipgroup_overlayAlertGradientUnmuted 652 FF0C8A8C FF0C8A8C
    voipgroup_overlayAlertGradientUnmuted2 653 FF284C75 FF284C75
    voipgroup_overlayAlertMutedByAdmin 654 FF67709E FF67709E
    voipgroup_overlayAlertMutedByAdmin2 655 FF2F5078 FF2F5078
    voipgroup_mutedByAdminGradient 656 FF57A4FE FF57A4FE
    voipgroup_mutedByAdminGradient2 657 FFF05459 FFF05459
    voipgroup_mutedByAdminGradient3 658 FF766EE9 FF766EE9
    voipgroup_mutedByAdminMuteButton 659 7F78A3FF 7F78A3FF
    voipgroup_mutedByAdminMuteButtonDisabled 660 3378A3FF 3378A3FF
    voipgroup_windowBackgroundWhiteInputField 661 FFDBDBDB FFDBDBDB
    voipgroup_windowBackgroundWhiteInputFieldActivated 662 FF229AF0 FF229AF0
    table_background 663 FFF7F7F7 0A92C4FF
    table_border 664 FFE0E0E0 19FFFFFF
    passport_authorizeBackground 665 FF45ABEF FF4383BA
    passport_authorizeBackgroundSelected 666 FF409DDB FF4E93D7
    passport_authorizeText 667 FFFFFFFF FFFFFFFF
    profile_creatorIcon 668 FF3A95D5 FF64B5EF
    profile_title 669 FF222222 FFFFFFFF
    profile_actionIcon 670 FF81868A FFFFFFFF
    profile_actionBackground 671 FFFFFFFF FF61AAE1
    profile_actionPressedBackground 672 121A1D21 FF4C9AD4
    profile_verifiedBackground 673 FF229AF0 FF64B5FD
    profile_verifiedCheck 674 FFFFFFFF FFFFFFFF
    profile_status 675 FF222222 FF73BBF7
    chat_tagAdmin 676 FF40A920 FF40A920
    chat_tagCreator 677 FF955CDB FF955CDB
    profile_tabText 678 FF878C90 78DCF4FF
    profile_tabSelectedText 679 FF3A95D5 FF79C4FC
    profile_tabSelectedLine 680 FF4FA6E9 FF79C4FC
    profile_tabSelector 681 0F000000 14E6F7FF
    sharedMedia_startStopLoadIcon 682 FF36A2EE FF64B5EF
    sharedMedia_linkPlaceholder 683 FFF0F3F5 FF273745
    sharedMedia_linkPlaceholderText 684 FFB7BEC3 FFB7BEC3
    sharedMedia_photoPlaceholder 685 FFEDF3F7 FF151E27
    featuredStickers_addedIcon 686 FF229AF0 FF64B5EF
    featuredStickers_buttonProgress 687 FFFFFFFF FFFFFFFF
    featuredStickers_addButton 688 FF229AF0 FF229AF0
    featuredStickers_addButton2 689 FF56BAF0 FF56BAF0
    featuredStickers_addButtonPressed 690 FF2288D1 FF2288D1
    featuredStickers_removeButtonText 691 FF5093D3 FF5093D3
    featuredStickers_buttonText 692 FFFFFFFF FFFFFFFF
    featuredStickers_unread 693 FF4DA6EA FF4DA6EA
    stickers_menu 694 FFB6BDC5 FF5C707F
    stickers_menuSelector 695 0F000000 0F000000
    changephoneinfo_image2 696 FF229AF0 FF229AF0
    groupcreate_hintText 697 FFA1AAB3 FF7D8B99
    groupcreate_cursor 698 FF52A3DB FF64B5EF
    groupcreate_sectionShadow 699 FF000000 FF000000
    groupcreate_sectionText 700 FF7C8288 99FFFFFF
    groupcreate_spanText 701 FF222222 FFF5F5F5
    groupcreate_spanBackground 702 FFF2F2F2 FF2C3C4E
    groupcreate_spanDelete 703 FFFFFFFF FFFFFFFF
    contacts_inviteBackground 704 FF55BE61 FF55BE61
    contacts_inviteText 705 FFFFFFFF FFFFFFFF
    login_progressInner 706 FFE1EAF2 FFE1EAF2
    login_progressOuter 707 FF62A0D0 FF62A0D0
    picker_enabledButton 708 FF19A7E8 FF6ABFFF
    picker_disabledButton 709 FF999999 FF576D80
    picker_badge 710 FF29B6F7 FF56ABF7
    picker_badgeText 711 FFFFFFFF FFFFFFFF
    location_sendLocationBackground 712 FF469DF6 FF68A3D7
    location_sendLocationIcon 713 FFFFFFFF FFFFFFFF
    location_sendLocationText 714 FF1C8AD8 FF79C4FC
    location_sendLiveLocationBackground 715 FF4FC244 FF4FC244
    location_sendLiveLocationIcon 716 FFFFFFFF FFFFFFFF
    location_sendLiveLocationText 717 FF36AB24 FF61BD67
    location_liveLocationProgress 718 FF359FE5 FF68A3D7
    location_placeLocationBackground 719 FF4CA8EA FF68A3D7
    location_actionIcon 720 FF3A4045 FFF6F6F6
    location_actionActiveIcon 721 FF4290E6 FF79C4FC
    location_actionBackground 722 FFFFFFFF FF212D3B
    location_actionPressedBackground 723 FFF2F2F2 FF1C2631
    dialog_liveLocationProgress 724 FF359FE5 FF68A3D7
    files_folderIcon 725 FFFFFFFF FFFFFFFF
    files_folderIconBackground 726 FF5DAFEB FF5DAFEB
    files_iconText 727 FFFFFFFF FFFFFFFF
    sessions_devicesImage 728 FF969696 FF969696
    calls_callReceivedGreenIcon 729 FF00C853 FF48DD76
    calls_callReceivedRedIcon 730 FFFF4848 FFFF4848
    undo_background 731 EA272F38 F22C3B4D
    undo_cancelColor 732 FF85CAFF FF85CAFF
    undo_infoColor 733 FFFFFFFF FFFFFFFF
    sheet_scrollUp 734 FFE1E4E8 25FFFFFF
    sheet_other 735 FFC9CDD3 43FFFFFF
    bot_loadingIcon 736 FFF2F2F2 1EFFFFFF
    gift_ribbon 737 FF46A4F2 FF41607F
    gift_ribbon_soldout 738 FFCC4747 FF7E4B41
    player_actionBarSelector 739 0F000000 FF324153
    player_actionBarTitle 740 FF2F3438 FFFFFFFF
    player_actionBarSubtitle 741 FF8A8A8A 78DCF4FF
    player_actionBarItems 742 FF8A8A8A FFFFFFFF
    player_background 743 FFFFFFFF FF1F2A36
    player_time 744 FF8C9296 FF7D8B99
    player_progressBackground 745 FFEBEDF0 FF394758
    player_progressCachedBackground 746 FFC5DCF0 FF546982
    player_progress 747 FF54AAEB FF64B5EF
    player_button 748 FF333333 FFFFFFFF
    player_buttonActive 749 FF4CA8EA FF64B5EF
    statisticChartSignature 750 7F252529 B7A3B1C2
    statisticChartSignatureAlpha 751 7F252529 8BFFFFFF
    statisticChartHintLine 752 1A182D3B 1AFFFFFF
    statisticChartActiveLine 753 33000000 32FFFFFF
    statisticChartInactivePickerChart 754 99E2EEF9 C8313D4C
    statisticChartActivePickerChart 755 D8BACCD9 D8526679
    statisticChartRipple 756 2C7E9DB7 2CA4BDD2
    statisticChartBackZoomColor 757 FF108BE3 FF46AAEE
    statisticChartChevronColor 758 FFD2D5D7 FF767C85
    statisticChartLine_blue 759 FF327FE5 FF529FFF
    statisticChartLine_green 760 FF61C752 FF3DC23F
    statisticChartLine_red 761 FFE05356 FFF34C44
    statisticChartLine_golden 762 FFEBA52D FFDEAC1F
    statisticChartLine_lightblue 763 FF58A8ED FF3C78EC
    statisticChartLine_lightgreen 764 FF8FCF39 FF8FCF39
    statisticChartLine_orange 765 FFF28C39 FFF28C39
    statisticChartLine_indigo 766 FF7F79F3 FF875CE2
    statisticChartLine_purple 767 FF9F79E8 FF875CE2
    statisticChartLine_cyan 768 FF40D0CA FF40D0CA
    statisticChartLineEmpty 769 FFEEEEEE FFEEEEEE
    color_lightblue 770 FF58A8ED FF3C78EC
    color_blue 771 FF327FE5 FF529FFF
    color_green 772 FF61C752 FF3DC23F
    color_lightgreen 773 FF8FCF39 FF8FCF39
    color_red 774 FFE05356 FFF34C44
    color_orange 775 FFF28C39 FFF28C39
    color_yellow 776 FFEBA52D FFDEAC1F
    color_purple 777 FF9F79E8 FF875CE2
    color_cyan 778 FF40D0CA FF40D0CA
    chat_inReactionButtonBackground 779 FF229AF0 FF609DD2
    chat_outReactionButtonText 780 FF55AB4F FFFFFFFF
    chat_inReactionButtonText 781 FF298ACF FFFFFFFF
    chat_inReactionButtonTextSelected 782 FFFFFFFF FFFFFFFF
    chat_outReactionButtonTextSelected 783 FFFFFFFF FF1D2733
    chat_reactionServiceButtonBackgroundSelected 784 FFFFFFFF FF3E618A
    chat_reactionServiceButtonTextSelected 785 FF000000 FFFAFAFA
    reactionStarSelector 786 40F0AB1F 40F0AB1F
    premiumGradient0 787 FF4ACD43 FF4ACD43
    premiumGradient1 788 FF55A5FF FF55A5FF
    premiumGradient2 789 FFA767FF FFA767FF
    premiumGradient3 790 FFDB5C9D FFDB5C9D
    premiumGradient4 791 FFF38926 FFF38926
    premiumGradientBackground1 792 FF55A5FF FF212635
    premiumGradientBackground2 793 FFA767FF FF151A21
    premiumGradientBackground3 794 FFDB5C9D FF131A21
    premiumGradientBackground4 795 FFF38926 FF161922
    premiumGradientBackgroundOverlay 796 FFFFFFFF FFFFFFFF
    premiumStartSmallStarsColor 797 5AFFFFFF 718362FF
    premiumStarGradient1 798 FFFFFFFF FF1473FF
    premiumStarGradient2 799 FFE3ECFA FFC066FA
    premiumCoinGradient1 800 FF1473FF FF1473FF
    premiumCoinGradient2 801 FFC066FA FFC066FA
    premiumStartSmallStarsColor2 802 5AFFFFFF 5AFFFFFF
    premiumGradientBottomSheet1 803 FF5B9DE7 FF5B9DE7
    premiumGradientBottomSheet2 804 FFAB87DD FFAB87DD
    premiumGradientBottomSheet3 805 FFE794BE FFE794BE
    topics_unreadCounter 806 FF4ECC5E FF64B5EF
    topics_unreadCounterMuted 807 FF8B8D8F FF7D8B99
    starsGradient1 808 FFFEC846 FFFEC846
    starsGradient2 809 FFEC920A FFEC920A
    stories_circle1 810 FF2C9EFC FF39DF3C
    stories_circle2 811 FF2FC183 FF4DBBFF
    stories_circle_dialog1 812 FF2C9EFC FF4AED55
    stories_circle_dialog2 813 FF2FC183 FF4DC3FF
    stories_circle_closeFriends1 814 FF81CE2D FFC9EB38
    stories_circle_closeFriends2 815 FF18BD36 FF09C167
    stories_circle_live1 816 FFFF6B5B FFFF6B5B
    stories_circle_live2 817 FFFA4874 FFFA4874
    chat_inCodeBackground 818 FF6F889E FFFFFFFF
    chat_outCodeBackground 819 123C7503 331C395C
    chat_inTableBackground 820 FFF7F7F7 0A92C4FF
    chat_outTableBackground 821 FFDEF0CC 331C395C
    chat_inTableBorder 822 FFE0E0E0 19FFFFFF
    chat_outTableBorder 823 FFC9DBB6 19FFFFFF
    chat_inDivider 824 FFE5E5E5 FFE5E5E5
    chat_outDivider 825 336EB969 336EB969
    chat_inArticleCodeBackground 826 FFF1F5F9 FFF1F5F9
    chat_outArticleCodeBackground 827 123C7503 331C395C
    chat_inArticleCodeScrollbarBackground 828 FFE1E6EB FFE1E6EB
    chat_inArticleCodeScrollbar 829 FFC5CDD5 FFC5CDD5
    chat_outArticleCodeScrollbarBackground 830 FFE4EBDC FFE4EBDC
    chat_outArticleCodeScrollbar 831 FFCCD5C2 FFCCD5C2
    chat_inArticleDetailsArrow 832 FF9EA4A8 FF9EA4A8
    chat_outArticleDetailsArrow 833 FF84A37B FF84A37B
    chat_inArticleDetailsLine 834 FFD8D8D8 FFD8D8D8
    chat_outArticleDetailsLine 835 FFCBD8C5 FFCBD8C5
    code_keyword 836 FFE05356 FFFF9380
    code_operator 837 FF4DBBFF 7FFFFFFF
    code_constant 838 FF7F79F3 FFFF9380
    code_string 839 FF37C123 FF88E378
    code_number 840 FF327FE5 FF59DED7
    code_comment 841 80000000 7FFFFFFF
    code_function 842 FFF28C39 FFFF9380
    iv_background 843 FFFFFFFF FF000000
    iv_backgroundGray 844 FFF0F0F0 FF1F1F1F
    iv_ab_progress 845 FF229AF0 FF229AF0
    iv_navigationBackground 846 FFF0F0F0 FF000000
    share_linkText 847 FF222222 B7FFFFFF
    share_linkBackground 848 0F000000 14FFFFFF
    share_icon 849 FF6E7275 FFFFFFFF
    glass_defaultIcon 850 991B2227 A0FFFFFF
    glass_defaultText 851 991B2227 A0FFFFFF
    glass_targetMainTabs 852 FFFFFFFF FF202E3E
    glass_targetMainTopPanel 853 FFFFFFFF FF233141
    glass_tabSelected 854 FF1A91E6 FF1A91E6
    glass_tabSelectedText 855 FF0D7FCF FF0D7FCF
    glass_tabUnselected 856 FF1A1D21 FF1A1D21
    botKeyboard_button_primary 857 FF229AF0 FF229AF0
    botKeyboard_button_danger 858 FFDB4646 FFDB4646
    botKeyboard_button_success 859 FF40B135 FF40B135
    telegram_color_dialogsLogo 860 FF168BDB FFFFFFFF
    telegram_color 861 FF229AF0 FF229AF0
    telegram_color_text 862 FF298ACF FF298ACF
    wallet_comment 863 FFF5F5F5 FFF5F5F5
    wallet_out_commentBorder 864 FFD9D9D9 FF495461
    wallet_inputCurrency 865 FF219949 FF219949
    """
}
