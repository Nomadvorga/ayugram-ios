import Foundation

// MARK: AyuGram
// exteraGram's preferences that have no Swiftgram counterpart. Read from memory on hot paths.
public final class ExteraSettings {
    public static let shared = ExteraSettings()

    /// Publish one settings change after a compound control has updated its children.
    public static func performBatchUpdates(_ updates: () -> Void) {
        AyuSettingsStore.shared.performBatchUpdates(updates)
    }


    public enum Keys: String, CaseIterable {
        case disableNumberRounding
        case inAppVibration
        case replaceEditedWithIcon
        case hideShareButton
        case disableGreetingSticker
        case filterZalgo
        case removeMessageTail
        case addCommaAfterMention
        case showForwardsCount
        case hideReactionsInPrivateChats
        case showResultsBeforeVoting
        case disableMarkdown
        case relativeLastSeen
        case hideActionBarStatus
        case hideDialogsSearchBar
        case hideKeyboardOnScroll
        case disableUnarchiveSwipe
        case showOnlineStatus
        case archiveOnPull
        case pauseOnMinimizeVoice
        case pauseOnMinimizeRound
        case pauseOnMinimizeVideo
        case senderMiniAvatars
        case replyColors
        case replyEmoji
        case replyBackground
        case preferOriginalQuality
        case showClearButton
        case showHistoryButton
        case showDetailsButton
        case singleCornerRadius
        case tabCounterUnmutedOnly
        case showRepeatButton
        case inlineResults
        case inlineMathResult
        case inlineCurrencyRates
        case inlineUnitConversion
        case inlineTimeZones
        case inlineDigitGrouping
        case swipeActionsLoop
        case swipeActionsReversed
        case showExteraBadges
        case showSaveMessageButton
        case showSearchImageButton
        case showProxyCountry
        case showShareAsImageButton
        case enableAdBlock
        case telegramAiSummaries
        case telegramAiEditor
        // Keys of the options that came with master's own port.
        case forceSnow
        case centerTitle
        case hideFloatingButton
        case tabTitleStyle
        case tabCounterMode
        case folderTabBackgrounds
        case avatarCorners
        case chatListTitle
        case disableNotificationDelay
        case hideArchiveFolder
        case showIdAndDc
        case customSavePath
        case translationTargetLanguage
    }

    public static let doubleTapSeekDurationValues: [Int] = [5, 10, 15, 30]
    private static let doubleTapSeekDurationKey = "extera.doubleTapSeekDuration"
    private static let defaultProfileTabKey = "extera.defaultProfileTab"
    private static let stickerShapeKey = "extera.stickerShape"
    private static let videoMessagesCameraKey = "extera.videoMessagesCamera"
    private static let swipeActionKey = "extera.swipeAction"
    private static let swipeActionsKey = "extera.swipeActions"
    // The stored value until a list is saved: the list is then the one action of `swipeActionKey`.
    private static let swipeActionsUnset = "-"
    private static let titleTextKey = "extera.titleText"
    private static let doNotUseProxyKey = "extera.doNotUseProxy"
    private static let avatarCornersKey = "extera.avatarCorners"
    private static let doubleTapActionKey = "extera.doubleTapAction"
    private static let doubleTapActionOutgoingKey = "extera.doubleTapActionOutOwner"
    private static let targetLangKey = "extera.targetLang"

    // Corner radius of a 56 pt avatar; 28 is a circle, the stock look.
    public static let avatarCornersValues: [Int] = [0, 4, 8, 12, 16, 20, 24, 28]

    // Network conditions under which the saved proxy is bypassed; the raw values match exteraGram's flags.
    public struct ProxyDisableConditions: OptionSet {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let vpn = ProxyDisableConditions(rawValue: 1 << 0)
        public static let mobileData = ProxyDisableConditions(rawValue: 1 << 1)
        public static let wifi = ProxyDisableConditions(rawValue: 1 << 2)
    }

    public enum TitleText: Int, CaseIterable {
        case `default` = 0
        case username = 1
        case firstName = 2
        case appName = 3
    }

    // Raw values are exteraGram's action ids (DoubleTapUtils.ACTION_*).
    public enum DoubleTapAction: Int, CaseIterable {
        case disable = 0
        case reactions = 1
        case reply = 2
        case copy = 3
        case forward = 4
        case edit = 5
        case save = 6
        case `repeat` = 7
        case delete = 8
        case translate = 9

        public static let incomingCases: [DoubleTapAction] = DoubleTapAction.allCases.filter { $0 != .edit }
        // exteraGram's SwipeAction values, in its order.
        public static let swipeListCases: [DoubleTapAction] = [.reactions, .reply, .copy, .forward, .edit, .save, .repeat, .delete, .translate]

        // exteraGram's "swipeActions" preference: action ids separated by commas, the first runs on a plain swipe.
        // Unknown ids and repetitions are dropped, as SwipeAction.enabled() does.
        public static func swipeList(fromAndroid value: String) -> [DoubleTapAction] {
            var result: [DoubleTapAction] = []
            for part in value.split(separator: ",") {
                guard let id = Int(part.trimmingCharacters(in: .whitespaces)), let action = DoubleTapAction(rawValue: id), swipeListCases.contains(action), !result.contains(action) else {
                    continue
                }
                result.append(action)
            }
            return result
        }

        // Switching an action on puts it where exteraGram's own order has it among the enabled ones
        // (SwipeAction.setEnabled); switching it off removes it.
        public static func swipeList(_ actions: [DoubleTapAction], toggling action: DoubleTapAction) -> [DoubleTapAction] {
            var result = actions
            if let index = result.firstIndex(of: action) {
                result.remove(at: index)
                return result
            }
            guard swipeListCases.contains(action) else {
                return result
            }
            var position = 0
            for candidate in swipeListCases {
                if candidate == action {
                    break
                }
                if result.contains(candidate) {
                    position += 1
                }
            }
            result.insert(action, at: position)
            return result
        }

        // Moves an enabled action next to `reference`: after it when dragged downwards, else before it.
        // Without a reference the action goes to the end when dragged downwards, else to the beginning.
        public static func swipeList(_ actions: [DoubleTapAction], moving action: DoubleTapAction, to reference: DoubleTapAction?, downwards: Bool) -> [DoubleTapAction] {
            var result = actions
            guard let index = result.firstIndex(of: action) else {
                return result
            }
            result.remove(at: index)
            if let reference, let referenceIndex = result.firstIndex(of: reference) {
                result.insert(action, at: downwards ? referenceIndex + 1 : referenceIndex)
            } else if downwards {
                result.append(action)
            } else {
                result.insert(action, at: 0)
            }
            return result
        }

        // The message menu's icon of the action.
        public var menuIconName: String? {
            switch self {
            case .disable:
                return nil
            case .reactions:
                return "Chat/Context Menu/Reactions"
            case .reply:
                return "Chat/Context Menu/Reply"
            case .copy:
                return "Chat/Context Menu/Copy"
            case .forward:
                return "Chat/Context Menu/Forward"
            case .edit:
                return "Chat/Context Menu/Edit"
            case .save:
                return "Chat/Context Menu/Cloud"
            case .repeat:
                return "Chat/Context Menu/Resend"
            case .delete:
                return "Chat/Context Menu/Delete"
            case .translate:
                return "Chat/Context Menu/Translate"
            }
        }

        public static func androidSwipeList(_ actions: [DoubleTapAction]) -> String {
            return actions.map { "\($0.rawValue)" }.joined(separator: ",")
        }
    }

    // The camera a video message starts on. "Last used" is what AyuGram did before this choice existed.
    public enum VideoMessagesCamera: Int, CaseIterable {
        case lastUsed = 0
        case front = 1
        case back = 2
    }

    public enum InlineAngleUnit: Int, CaseIterable {
        case degrees = 0
        case radians = 1
    }

    public enum InlineMeasureSystem: Int, CaseIterable {
        case auto = 0
        case metric = 1
        case imperial = 2
    }

    public enum DefaultProfileTab: Int, CaseIterable {
        case `default` = 0
        case media = 1
        case commonGroups = 2
    }

    public enum StickerShape: Int, CaseIterable {
        case `default` = 0
        case rounded = 1
        case roundedAsMessage = 2
    }

    public enum ChatListTitle: Int, CaseIterable {
        case ayuGram = 0
        case fullName = 1
        case firstName = 2
        case chats = 3
        case username = 4
    }

    /// exteraGram's "Tab title style": folder tabs show text and icons, text only, or icons only.
    public enum TabTitleStyle: Int, CaseIterable {
        case textWithIcons = 0
        case textOnly = 1
        case iconsOnly = 2
    }

    /// exteraGram's "Tab counter": all chats, unmuted chats only, or off.
    public enum TabCounterMode: Int, CaseIterable {
        case allChats = 0
        case unmuted = 1
        case off = 2
    }

    /// exteraGram's "Show ID and DC": 0 hides it, 1 prints Telegram API ids, 2 prints Bot API ids.
    public enum ShowIdAndDc: Int, CaseIterable {
        case hide = 0
        case telegram = 1
        case bot = 2
    }

    private let store = AyuSettingsStore.shared

    private static func key(_ key: Keys) -> String {
        return "extera.\(key.rawValue)"
    }

    private init() {
        self.store.register(defaults: [
            ExteraSettings.key(.disableNumberRounding): false,
            ExteraSettings.key(.inAppVibration): true,
            ExteraSettings.key(.replaceEditedWithIcon): false,
            ExteraSettings.key(.hideShareButton): false,
            ExteraSettings.key(.disableGreetingSticker): false,
            ExteraSettings.key(.filterZalgo): false,
            ExteraSettings.key(.removeMessageTail): false,
            ExteraSettings.key(.addCommaAfterMention): false,
            ExteraSettings.key(.showForwardsCount): false,
            ExteraSettings.key(.hideReactionsInPrivateChats): false,
            ExteraSettings.key(.showResultsBeforeVoting): false,
            ExteraSettings.key(.disableMarkdown): false,
            ExteraSettings.key(.relativeLastSeen): false,
            ExteraSettings.key(.hideActionBarStatus): false,
            ExteraSettings.key(.hideDialogsSearchBar): false,
            ExteraSettings.key(.hideKeyboardOnScroll): false,
            ExteraSettings.key(.disableUnarchiveSwipe): true,
            ExteraSettings.key(.showOnlineStatus): false,
            ExteraSettings.key(.archiveOnPull): true,
            ExteraSettings.key(.pauseOnMinimizeVoice): false,
            ExteraSettings.key(.pauseOnMinimizeRound): false,
            ExteraSettings.key(.pauseOnMinimizeVideo): false,
            ExteraSettings.key(.senderMiniAvatars): false,
            ExteraSettings.key(.replyColors): true,
            ExteraSettings.key(.replyEmoji): true,
            ExteraSettings.key(.replyBackground): true,
            ExteraSettings.key(.preferOriginalQuality): false,
            ExteraSettings.key(.showClearButton): false,
            ExteraSettings.key(.showHistoryButton): false,
            ExteraSettings.key(.showDetailsButton): false,
            ExteraSettings.key(.singleCornerRadius): false,
            ExteraSettings.key(.tabCounterUnmutedOnly): false,
            ExteraSettings.key(.showRepeatButton): true,
            ExteraSettings.key(.inlineMathResult): true,
            ExteraSettings.key(.inlineCurrencyRates): true,
            ExteraSettings.key(.inlineUnitConversion): true,
            ExteraSettings.key(.inlineDigitGrouping): true,
            ExteraSettings.targetLangKey: "",
            ExteraSettings.doubleTapSeekDurationKey: 15,
            ExteraSettings.defaultProfileTabKey: 0,
            ExteraSettings.stickerShapeKey: 0,
            ExteraSettings.videoMessagesCameraKey: 0,
            ExteraSettings.swipeActionKey: DoubleTapAction.reply.rawValue,
            ExteraSettings.swipeActionsKey: ExteraSettings.swipeActionsUnset,
            ExteraSettings.key(.swipeActionsLoop): false,
            ExteraSettings.key(.swipeActionsReversed): false,
            ExteraSettings.key(.showExteraBadges): false,
            ExteraSettings.key(.showSaveMessageButton): false,
            ExteraSettings.key(.showSearchImageButton): false,
            ExteraSettings.key(.showProxyCountry): false,
            ExteraSettings.key(.showShareAsImageButton): false,
            ExteraSettings.key(.enableAdBlock): false,
            ExteraSettings.key(.telegramAiSummaries): true,
            ExteraSettings.key(.telegramAiEditor): true,
            ExteraSettings.titleTextKey: 0,
            ExteraSettings.doNotUseProxyKey: 0,
            ExteraSettings.avatarCornersKey: 28,
            ExteraSettings.doubleTapActionKey: DoubleTapAction.reactions.rawValue,
            ExteraSettings.doubleTapActionOutgoingKey: -1,
            ExteraSettings.key(.forceSnow): false,
            ExteraSettings.key(.centerTitle): false,
            ExteraSettings.key(.hideFloatingButton): false,
            ExteraSettings.key(.tabTitleStyle): TabTitleStyle.textWithIcons.rawValue,
            ExteraSettings.key(.tabCounterMode): TabCounterMode.allChats.rawValue,
            ExteraSettings.key(.folderTabBackgrounds): false,
            ExteraSettings.key(.chatListTitle): ChatListTitle.ayuGram.rawValue,
            ExteraSettings.key(.disableNotificationDelay): false,
            ExteraSettings.key(.hideArchiveFolder): false,
            ExteraSettings.key(.customSavePath): "",
        ])
    }

    // Options that master's port stores under its own keys: one stored value serves both settings screens,
    // the backup table and every reader.
    private static let bridged: [Keys: (get: () -> Bool, set: (Bool) -> Void)] = [
        .hideKeyboardOnScroll: ({ ExteraChatSettings.shared.hideKeyboardOnScroll }, { ExteraChatSettings.shared.hideKeyboardOnScroll = $0 }),
        .addCommaAfterMention: ({ ExteraChatSettings.shared.addCommaAfterMention }, { ExteraChatSettings.shared.addCommaAfterMention = $0 }),
        .pauseOnMinimizeVoice: ({ ExteraMediaSettings.shared.pauseOnMinimizeVoice }, { ExteraMediaSettings.shared.pauseOnMinimizeVoice = $0 }),
        .pauseOnMinimizeRound: ({ ExteraMediaSettings.shared.pauseOnMinimizeRound }, { ExteraMediaSettings.shared.pauseOnMinimizeRound = $0 }),
        .pauseOnMinimizeVideo: ({ ExteraMediaSettings.shared.pauseOnMinimizeVideo }, { ExteraMediaSettings.shared.pauseOnMinimizeVideo = $0 }),
        .preferOriginalQuality: ({ ExteraMediaSettings.shared.preferOriginalQuality }, { ExteraMediaSettings.shared.preferOriginalQuality = $0 }),
        .showResultsBeforeVoting: ({ ExteraMessageSettings.shared.showPollResultsBeforeVoting }, { ExteraMessageSettings.shared.showPollResultsBeforeVoting = $0 }),
        .inlineResults: ({ ExteraMathSettings.shared.inlineResults }, { ExteraMathSettings.shared.inlineResults = $0 }),
        .inlineMathResult: ({ ExteraMathSettings.shared.inlineMathResult }, { ExteraMathSettings.shared.inlineMathResult = $0 }),
        .inlineTimeZones: ({ ExteraMathSettings.shared.inlineTimeZones }, { ExteraMathSettings.shared.inlineTimeZones = $0 }),
        .inlineDigitGrouping: ({ ExteraMathSettings.shared.inlineDigitGrouping }, { ExteraMathSettings.shared.inlineDigitGrouping = $0 }),
        .inlineCurrencyRates: ({ ExteraMathSettings.shared.inlineCurrencies }, { ExteraMathSettings.shared.inlineCurrencies = $0 }),
        .inlineUnitConversion: ({ ExteraMathSettings.shared.inlineUnits }, { ExteraMathSettings.shared.inlineUnits = $0 }),
        .showSaveMessageButton: ({ ExteraMenuSettings.shared.showSaveMessageButton }, { ExteraMenuSettings.shared.showSaveMessageButton = $0 }),
        .showRepeatButton: ({ ExteraMenuSettings.shared.showRepeatMessageButton }, { ExteraMenuSettings.shared.showRepeatMessageButton = $0 }),
        .showClearButton: ({ ExteraMenuSettings.shared.showClearButton }, { ExteraMenuSettings.shared.showClearButton = $0 }),
        .showHistoryButton: ({ ExteraMenuSettings.shared.showHistoryButton }, { ExteraMenuSettings.shared.showHistoryButton = $0 }),
        .showDetailsButton: ({ ExteraMenuSettings.shared.showDetailsButton }, { ExteraMenuSettings.shared.showDetailsButton = $0 }),
        .showShareAsImageButton: ({ ExteraMenuSettings.shared.showMessageImageExportButton }, { ExteraMenuSettings.shared.showMessageImageExportButton = $0 }),
        .telegramAiEditor: ({ ExteraAISettings.shared.configuration.showEditor }, { value in let _ = try? ExteraAISettings.shared.update { $0.showEditor = value } }),
        .telegramAiSummaries: ({ ExteraAISettings.shared.configuration.showSummaries }, { value in let _ = try? ExteraAISettings.shared.update { $0.showSummaries = value } }),
        .enableAdBlock: ({ ExteraBrowserSettings.shared.adBlockingEnabled }, { ExteraBrowserSettings.shared.adBlockingEnabled = $0 }),
        // "Unmuted only" is one of the three tab counter modes; switching it off keeps a hidden counter hidden.
        .tabCounterUnmutedOnly: ({ ExteraSettings.shared.tabCounterMode == .unmuted }, { value in
            if value {
                ExteraSettings.shared.tabCounterMode = .unmuted
            } else if ExteraSettings.shared.tabCounterMode == .unmuted {
                ExteraSettings.shared.tabCounterMode = .allChats
            }
        }),
    ]

    public func value(_ key: Keys) -> Bool {
        if let bridge = ExteraSettings.bridged[key] {
            return bridge.get()
        }
        return self.store.bool(ExteraSettings.key(key))
    }

    public func set(_ key: Keys, _ value: Bool) {
        if let bridge = ExteraSettings.bridged[key] {
            bridge.set(value)
            return
        }
        self.store.setBool(value, ExteraSettings.key(key))
    }

    public var disableNumberRounding: Bool {
        return self.value(.disableNumberRounding)
    }

    public var inAppVibration: Bool {
        return self.value(.inAppVibration)
    }

    public var replaceEditedWithIcon: Bool {
        return self.value(.replaceEditedWithIcon)
    }

    public var hideShareButton: Bool {
        return self.value(.hideShareButton)
    }

    public var disableGreetingSticker: Bool {
        return self.value(.disableGreetingSticker)
    }

    public var filterZalgo: Bool {
        return self.value(.filterZalgo)
    }

    public var removeMessageTail: Bool {
        return self.value(.removeMessageTail)
    }

    public var addCommaAfterMention: Bool {
        return self.value(.addCommaAfterMention)
    }

    public var showForwardsCount: Bool {
        return self.value(.showForwardsCount)
    }

    public var hideReactionsInPrivateChats: Bool {
        return self.value(.hideReactionsInPrivateChats)
    }

    public var showResultsBeforeVoting: Bool {
        return self.value(.showResultsBeforeVoting)
    }

    public var disableMarkdown: Bool {
        return self.value(.disableMarkdown)
    }

    public var relativeLastSeen: Bool {
        return self.value(.relativeLastSeen)
    }

    public var hideDialogsSearchBar: Bool {
        return self.value(.hideDialogsSearchBar)
    }

    public var hideActionBarStatus: Bool {
        return self.value(.hideActionBarStatus)
    }

    public var hideKeyboardOnScroll: Bool {
        return self.value(.hideKeyboardOnScroll)
    }

    public var disableUnarchiveSwipe: Bool {
        return self.value(.disableUnarchiveSwipe)
    }

    public var showOnlineStatus: Bool {
        return self.value(.showOnlineStatus)
    }

    public var archiveOnPull: Bool {
        return self.value(.archiveOnPull)
    }

    public var pauseOnMinimizeVoice: Bool {
        return self.value(.pauseOnMinimizeVoice)
    }

    public var pauseOnMinimizeRound: Bool {
        return self.value(.pauseOnMinimizeRound)
    }

    public var pauseOnMinimizeVideo: Bool {
        return self.value(.pauseOnMinimizeVideo)
    }

    public var senderMiniAvatars: Bool {
        return self.value(.senderMiniAvatars)
    }

    public var replyColors: Bool {
        return self.value(.replyColors)
    }

    public var replyEmoji: Bool {
        return self.value(.replyEmoji)
    }

    public var replyBackground: Bool {
        return self.value(.replyBackground)
    }

    public var preferOriginalQuality: Bool {
        return self.value(.preferOriginalQuality)
    }

    public var showClearButton: Bool {
        return self.value(.showClearButton)
    }

    public var showHistoryButton: Bool {
        return self.value(.showHistoryButton)
    }

    public var tabCounterUnmutedOnly: Bool {
        return self.value(.tabCounterUnmutedOnly)
    }

    public var singleCornerRadius: Bool {
        return self.value(.singleCornerRadius)
    }

    public var showDetailsButton: Bool {
        return self.value(.showDetailsButton)
    }

    public var showRepeatButton: Bool {
        return self.value(.showRepeatButton)
    }

    // The master switch of the results shown after "=" in the message field.
    public var inlineResults: Bool {
        return self.value(.inlineResults)
    }

    public var inlineMathResult: Bool {
        return self.value(.inlineMathResult)
    }

    public var inlineCurrencyRates: Bool {
        return self.value(.inlineCurrencyRates)
    }

    public var inlineUnitConversion: Bool {
        return self.value(.inlineUnitConversion)
    }

    public var inlineTimeZones: Bool {
        return self.value(.inlineTimeZones)
    }

    public var inlineDigitGrouping: Bool {
        return self.value(.inlineDigitGrouping)
    }

    public var inlineResultsEnabled: Bool {
        return self.inlineResults && (self.inlineMathResult || self.inlineCurrencyRates || self.inlineUnitConversion || self.inlineTimeZones)
    }

    // The three values below are stored by the math settings of master's port, under the same keys but as strings.
    public var inlineAngleUnit: InlineAngleUnit {
        get {
            return ExteraMathSettings.shared.inlineAngleUnit == .radians ? .radians : .degrees
        }
        set {
            ExteraMathSettings.shared.inlineAngleUnit = newValue == .radians ? .radians : .degrees
        }
    }

    public var inlineMeasureSystem: InlineMeasureSystem {
        get {
            switch ExteraMathSettings.shared.inlineMeasureSystem {
            case .auto:
                return .auto
            case .metric:
                return .metric
            case .imperial:
                return .imperial
            }
        }
        set {
            switch newValue {
            case .auto:
                ExteraMathSettings.shared.inlineMeasureSystem = .auto
            case .metric:
                ExteraMathSettings.shared.inlineMeasureSystem = .metric
            case .imperial:
                ExteraMathSettings.shared.inlineMeasureSystem = .imperial
            }
        }
    }

    // Currency code the amounts convert to; empty picks the currency automatically (stored as "auto").
    public var inlineTargetCurrency: String {
        get {
            let value = ExteraMathSettings.shared.inlineTargetCurrency
            return value == "auto" ? "" : value
        }
        set {
            ExteraMathSettings.shared.inlineTargetCurrency = newValue.isEmpty ? "auto" : newValue
        }
    }

    // Language code messages are translated to; empty follows the app language.
    public var targetLang: String {
        get {
            return self.store.string(ExteraSettings.targetLangKey)
        }
        set {
            self.store.setString(newValue, ExteraSettings.targetLangKey)
        }
    }

    public func translationTargetLanguage(appLanguage: String) -> String {
        let target = self.targetLang
        return target.isEmpty ? appLanguage : target
    }

    public var defaultProfileTab: DefaultProfileTab {
        get {
            return DefaultProfileTab(rawValue: ExteraGeneralSettings.shared.defaultProfileTab.rawValue) ?? .default
        }
        set {
            ExteraGeneralSettings.shared.defaultProfileTab = ExteraGeneralSettings.DefaultProfileTab(rawValue: newValue.rawValue) ?? .default
        }
    }

    // One stored value with the sticker settings of master's port, which draw the shape.
    public var stickerShape: StickerShape {
        get {
            switch ExteraStickerSettings.shared.shape {
            case .original:
                return .default
            case .rounded:
                return .rounded
            case .bubble:
                return .roundedAsMessage
            }
        }
        set {
            switch newValue {
            case .default:
                ExteraStickerSettings.shared.shape = .original
            case .rounded:
                ExteraStickerSettings.shared.shape = .rounded
            case .roundedAsMessage:
                ExteraStickerSettings.shared.shape = .bubble
            }
        }
    }

    // The actions of a swipe to the left on a message, in order: the first runs on a plain swipe, the others are
    // picked by moving up or down during the swipe. Empty switches the swipe off; Reply alone is the stock gesture.
    public var swipeActions: [DoubleTapAction] {
        get {
            let stored = self.store.string(ExteraSettings.swipeActionsKey)
            if stored != ExteraSettings.swipeActionsUnset {
                return DoubleTapAction.swipeList(fromAndroid: stored)
            }
            let single = DoubleTapAction(rawValue: self.store.int(ExteraSettings.swipeActionKey)) ?? .reply
            if single == .disable {
                return []
            }
            return [DoubleTapAction.swipeListCases.contains(single) ? single : .reply]
        }
        set {
            self.store.setString(DoubleTapAction.androidSwipeList(newValue.filter { DoubleTapAction.swipeListCases.contains($0) }), ExteraSettings.swipeActionsKey)
        }
    }

    // The action of a plain swipe: the first of `swipeActions`.
    public var swipeAction: DoubleTapAction {
        get {
            return self.swipeActions.first ?? .disable
        }
        set {
            self.swipeActions = newValue == .disable ? [] : [newValue]
        }
    }

    public var swipeActionsLoop: Bool {
        return self.value(.swipeActionsLoop)
    }

    public var swipeActionsReversed: Bool {
        return self.value(.swipeActionsReversed)
    }

    // Stored by the media settings of master's port, which the round video camera reads.
    public var videoMessagesCamera: VideoMessagesCamera {
        get {
            if ExteraMediaSettings.shared.rememberLastUsedCamera {
                return .lastUsed
            }
            return ExteraMediaSettings.shared.videoMessagesCamera == 1 ? .back : .front
        }
        set {
            switch newValue {
            case .lastUsed:
                ExteraMediaSettings.shared.rememberLastUsedCamera = true
            case .front:
                ExteraMediaSettings.shared.rememberLastUsedCamera = false
                ExteraMediaSettings.shared.videoMessagesCamera = 0
            case .back:
                ExteraMediaSettings.shared.rememberLastUsedCamera = false
                ExteraMediaSettings.shared.videoMessagesCamera = 1
            }
        }
    }

    public var doNotUseProxy: ProxyDisableConditions {
        get {
            return ProxyDisableConditions(rawValue: self.store.int(ExteraSettings.doNotUseProxyKey) & 7)
        }
        set {
            self.store.setInt(newValue.rawValue, ExteraSettings.doNotUseProxyKey)
        }
    }

    // Stored as the chat list title of master's port, which the chat list reads.
    public var titleText: TitleText {
        get {
            switch self.chatListTitle {
            case .chats:
                return .default
            case .username:
                return .username
            case .firstName, .fullName:
                return .firstName
            case .ayuGram:
                return .appName
            }
        }
        set {
            switch newValue {
            case .default:
                self.chatListTitle = .chats
            case .username:
                self.chatListTitle = .username
            case .firstName:
                self.chatListTitle = .firstName
            case .appName:
                self.chatListTitle = .ayuGram
            }
        }
    }

    public var avatarCorners: Int {
        get {
            return min(28, max(0, self.store.int(ExteraSettings.avatarCornersKey)))
        }
        set {
            let value = min(28, max(0, newValue))
            if value != self.avatarCorners {
                self.store.setInt(value, ExteraSettings.avatarCornersKey)
            }
        }
    }

    // Stateless geometry: caller applies it only when settings, scope or size change.
    // The same radius as `avatarCornerRadius(side:forum:)`, so avatars shaped by their layer and avatars drawn
    // with the shape agree.
    public func avatarCornerRadius(forDiameter diameter: Double, isForum: Bool = false) -> Double {
        let side = max(0.0, diameter)
        if let radius = self.avatarCornerRadius(side: CGFloat(side), forum: isForum) {
            return floor(Double(radius))
        }
        return floor(side * (isForum ? 0.25 : 0.5))
    }

    // Corner radius of an avatar with the given side, or nil while the stock shape applies
    // (a circle; a rounded square with a quarter-side radius for forums, which stay half as round
    // unless "Single Corner Radius" gives them the shape of every other avatar).
    public func avatarCornerRadius(side: CGFloat, forum: Bool = false) -> CGFloat? {
        let corners = self.avatarCorners
        let single = forum && self.singleCornerRadius
        if corners == 28 && !single {
            return nil
        }
        let radius = CGFloat(corners) * side / 56.0
        return forum && !single ? radius * 0.5 : radius
    }

    // Both double tap choices are stored by the chat settings of master's port (same action ids), so the two
    // settings screens show one value. Its "Read" action has no case here and reads as the default action; the
    // gesture itself is dispatched from `ExteraChatSettings` (sgHandleDoubleTapMessageAction), which knows it.
    public var doubleTapAction: DoubleTapAction {
        get {
            let value = DoubleTapAction(rawValue: ExteraChatSettings.shared.effectiveDoubleTapAction(incoming: true).rawValue) ?? .reactions
            return value == .edit ? .reactions : value
        }
        set {
            ExteraChatSettings.shared.doubleTapIncoming = ExteraChatSettings.DoubleTapAction(rawValue: newValue.rawValue) ?? .reaction
        }
    }

    public var doubleTapActionOutgoing: DoubleTapAction {
        get {
            return DoubleTapAction(rawValue: ExteraChatSettings.shared.effectiveDoubleTapAction(incoming: false).rawValue) ?? .reactions
        }
        set {
            ExteraChatSettings.shared.doubleTapOutgoing = ExteraChatSettings.DoubleTapAction(rawValue: newValue.rawValue) ?? .reaction
        }
    }

    // Seconds skipped by a double tap on a video, stored by the media settings of master's port.
    public var doubleTapSeekDuration: Int {
        get {
            return ExteraMediaSettings.shared.doubleTapSeekDuration
        }
        set {
            ExteraMediaSettings.shared.doubleTapSeekDuration = newValue
        }
    }

    // "Filter Zalgo": repeated or stacked combining overlays are removed while
    // ordinary isolated diacritics remain intact.
    public func filteredText(_ text: String, force: Bool = false) -> String {
        guard force || self.filterZalgo else {
            return text
        }
        return ExteraZalgoFilter.clean(text)
    }

    public var centerTitle: Bool {
        return self.value(.centerTitle)
    }

    /// exteraGram's "Hide floating button": on iOS the compose action lives in the chat list header.
    public var hideFloatingButton: Bool {
        return self.value(.hideFloatingButton)
    }

    public var tabTitleStyle: TabTitleStyle {
        get { return TabTitleStyle(rawValue: self.store.int(ExteraSettings.key(.tabTitleStyle))) ?? .textWithIcons }
        set {
            if newValue != self.tabTitleStyle {
                self.store.setInt(newValue.rawValue, ExteraSettings.key(.tabTitleStyle))
            }
        }
    }

    public var tabCounterMode: TabCounterMode {
        get { return TabCounterMode(rawValue: self.store.int(ExteraSettings.key(.tabCounterMode))) ?? .allChats }
        set {
            if newValue != self.tabCounterMode {
                self.store.setInt(newValue.rawValue, ExteraSettings.key(.tabCounterMode))
            }
        }
    }

    /// Use each Telegram folder's configured color for the selected tab background.
    public var folderTabBackgrounds: Bool {
        get { return self.value(.folderTabBackgrounds) }
        set { self.set(.folderTabBackgrounds, newValue) }
    }

    public var chatListTitle: ChatListTitle {
        get { return ChatListTitle(rawValue: self.store.int(ExteraSettings.key(.chatListTitle))) ?? .ayuGram }
        set {
            if newValue != self.chatListTitle {
                self.store.setInt(newValue.rawValue, ExteraSettings.key(.chatListTitle))
            }
        }
    }

    public func chatListTitleText(firstName: String, lastName: String, chatsTitle: String, username: String? = nil) -> String {
        switch self.chatListTitle {
        case .ayuGram:
            return "AyuGram"
        case .chats:
            return chatsTitle
        case .fullName:
            let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
            return name.isEmpty ? "AyuGram" : name
        case .firstName:
            return firstName.isEmpty ? "AyuGram" : firstName
        case .username:
            if let username, !username.isEmpty { return "@" + username }
            let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
            return name.isEmpty ? chatsTitle : name
        }
    }

    public var forceSnow: Bool {
        return self.value(.forceSnow)
    }

    public var disableNotificationDelay: Bool {
        return self.value(.disableNotificationDelay)
    }

    public var hideArchiveFolder: Bool {
        return self.value(.hideArchiveFolder)
    }

    public var showIdAndDc: ShowIdAndDc {
        get {
            // Migrate Swiftgram's boolean pair once: it showed the Bot API form.
            if self.store.userDefaults.object(forKey: ExteraSettings.key(.showIdAndDc)) == nil {
                return SGSimpleSettings.shared.showProfileId ? .bot : .hide
            }
            return ShowIdAndDc(rawValue: self.store.int(ExteraSettings.key(.showIdAndDc))) ?? .hide
        }
        set {
            self.store.setInt(newValue.rawValue, ExteraSettings.key(.showIdAndDc))
        }
    }

    /// "Show ID and DC" as text for a peer id, in the API form exteraGram offers.
    public func idText(namespace: Int32, id: Int64, isChannel: Bool, isGroup: Bool) -> String {
        switch self.showIdAndDc {
        case .hide:
            return ""
        case .telegram:
            return "\(id)"
        case .bot:
            if isChannel {
                return "-100\(id)"
            } else if isGroup {
                return "-\(id)"
            } else {
                return "\(id)"
            }
        }
    }

    public var customSavePath: String {
        get {
            return self.store.string(ExteraSettings.key(.customSavePath))
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value != self.customSavePath {
                self.store.setString(value, ExteraSettings.key(.customSavePath))
            }
        }
    }

    /// exteraGram saves into `Pictures/AyuGram` by default; on iOS the same folder becomes a Photos album.
    public static let defaultSaveFolderName = "AyuGram"

    /// Name of the Photos album saved media goes to.
    public var saveFolderName: String {
        let value = self.customSavePath
        return value.isEmpty ? ExteraSettings.defaultSaveFolderName : value
    }

    // Master's name of the port's `targetLang`: one stored value serves both.
    public var translationTargetLanguage: String {
        get {
            return self.targetLang
        }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value != self.targetLang {
                self.targetLang = value
            }
        }
    }

    /// The language translations go to when the chat has no choice of its own.
    public func effectiveTranslationTargetLanguage(_ baseLanguageCode: String) -> String {
        var code = self.translationTargetLanguage
        if code.isEmpty {
            code = baseLanguageCode
        }
        let rawSuffix = "-raw"
        if code.hasSuffix(rawSuffix) {
            code = String(code.dropLast(rawSuffix.count))
        }
        return code
    }
}
