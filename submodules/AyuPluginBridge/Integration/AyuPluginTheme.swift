import Foundation

/// The colours of the app's current presentation theme that Android theme keys are answered
/// from, as ARGB values. The app fills the slots it has a colour for; a key whose slot is
/// missing is refused.
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

    /// Android key name to the palette slot that colours the same element on iOS. Keys with no
    /// counterpart in the presentation theme are absent and stay refused.
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

    static let keyConstants: [String: AyuBridgeValue] = Dictionary(uniqueKeysWithValues: keys.map { name, key in (name, AyuBridgeValue.integer(key.id)) })
    private static let keysByID: [Int64: Key] = Dictionary(keys.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// `Theme.getColor(key)` as a signed Java int.
    static func color(_ id: Int64, palette: AyuPluginThemePalette) throws -> Int64 {
        guard let key = Self.keysByID[id] else { throw AyuBridgeFailure.unsupported("Theme color key \(id)") }
        guard let color = palette.colors[key.slot] else { throw AyuBridgeFailure.unsupported("Theme color slot " + key.slot.rawValue) }
        let argb = key.alpha.map { (color & 0x00FF_FFFF) | $0 << 24 } ?? color
        return Int64(Int32(bitPattern: argb))
    }

    private static func color(named name: String, palette: AyuPluginThemePalette) throws -> Int64 {
        guard let key = Self.keys[name] else { throw AyuBridgeFailure.unsupported("Theme." + name) }
        return try Self.color(key.id, palette: palette)
    }

    /// Members that answer from the palette: hidden while the app has bound none.
    private static let paletteMembers: Set<String> = Set(keys.keys).union(["getColor", "isCurrentThemeDark", "isCurrentThemeNight", "getActiveTheme", "getSelectorDrawable"])

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
}
