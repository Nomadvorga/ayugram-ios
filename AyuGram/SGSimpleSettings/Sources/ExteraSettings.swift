import Foundation

// MARK: AyuGram
// exteraGram's preferences that have no Swiftgram counterpart. Read from memory on hot paths.
public final class ExteraSettings {
    public static let shared = ExteraSettings()

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
    private static let inlineAngleUnitKey = "extera.inlineAngleUnit"
    private static let inlineMeasureSystemKey = "extera.inlineMeasureSystem"
    private static let inlineTargetCurrencyKey = "extera.inlineTargetCurrency"
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
            ExteraSettings.key(.disableUnarchiveSwipe): false,
            ExteraSettings.key(.showOnlineStatus): false,
            ExteraSettings.key(.archiveOnPull): false,
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
            ExteraSettings.key(.inlineResults): false,
            ExteraSettings.key(.inlineMathResult): true,
            ExteraSettings.key(.inlineCurrencyRates): true,
            ExteraSettings.key(.inlineUnitConversion): true,
            ExteraSettings.key(.inlineTimeZones): false,
            ExteraSettings.key(.inlineDigitGrouping): true,
            ExteraSettings.inlineAngleUnitKey: 0,
            ExteraSettings.inlineMeasureSystemKey: 0,
            ExteraSettings.inlineTargetCurrencyKey: "",
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
        ])
    }

    public func value(_ key: Keys) -> Bool {
        return self.store.bool(ExteraSettings.key(key))
    }

    public func set(_ key: Keys, _ value: Bool) {
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

    public var inlineAngleUnit: InlineAngleUnit {
        get {
            return InlineAngleUnit(rawValue: self.store.int(ExteraSettings.inlineAngleUnitKey)) ?? .degrees
        }
        set {
            self.store.setInt(newValue.rawValue, ExteraSettings.inlineAngleUnitKey)
        }
    }

    public var inlineMeasureSystem: InlineMeasureSystem {
        get {
            return InlineMeasureSystem(rawValue: self.store.int(ExteraSettings.inlineMeasureSystemKey)) ?? .auto
        }
        set {
            self.store.setInt(newValue.rawValue, ExteraSettings.inlineMeasureSystemKey)
        }
    }

    // Currency code the amounts convert to; empty picks the currency of the account's phone number.
    public var inlineTargetCurrency: String {
        get {
            return self.store.string(ExteraSettings.inlineTargetCurrencyKey)
        }
        set {
            self.store.setString(newValue, ExteraSettings.inlineTargetCurrencyKey)
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
            return DefaultProfileTab(rawValue: self.store.int(ExteraSettings.defaultProfileTabKey)) ?? .default
        }
        set {
            self.store.setInt(newValue.rawValue, ExteraSettings.defaultProfileTabKey)
        }
    }

    public var stickerShape: StickerShape {
        get {
            return StickerShape(rawValue: self.store.int(ExteraSettings.stickerShapeKey)) ?? .default
        }
        set {
            self.store.setInt(newValue.rawValue, ExteraSettings.stickerShapeKey)
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

    public var videoMessagesCamera: VideoMessagesCamera {
        get {
            return VideoMessagesCamera(rawValue: self.store.int(ExteraSettings.videoMessagesCameraKey)) ?? .lastUsed
        }
        set {
            self.store.setInt(newValue.rawValue, ExteraSettings.videoMessagesCameraKey)
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

    public var titleText: TitleText {
        get {
            return TitleText(rawValue: self.store.int(ExteraSettings.titleTextKey)) ?? .default
        }
        set {
            self.store.setInt(newValue.rawValue, ExteraSettings.titleTextKey)
        }
    }

    public var avatarCorners: Int {
        get {
            let value = self.store.int(ExteraSettings.avatarCornersKey)
            return ExteraSettings.avatarCornersValues.contains(value) ? value : 28
        }
        set {
            self.store.setInt(newValue, ExteraSettings.avatarCornersKey)
        }
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

    public var doubleTapAction: DoubleTapAction {
        get {
            let value = DoubleTapAction(rawValue: self.store.int(ExteraSettings.doubleTapActionKey)) ?? .reactions
            return value == .edit ? .reactions : value
        }
        set {
            self.store.setInt(newValue.rawValue, ExteraSettings.doubleTapActionKey)
        }
    }

    // Unset (-1) follows the older "double tap to edit" switch, so its users keep their choice.
    public var doubleTapActionOutgoing: DoubleTapAction {
        get {
            if let value = DoubleTapAction(rawValue: self.store.int(ExteraSettings.doubleTapActionOutgoingKey)) {
                return value
            }
            switch SGSimpleSettings.shared.messageDoubleTapActionOutgoing {
            case SGSimpleSettings.MessageDoubleTapAction.edit.rawValue:
                return .edit
            case SGSimpleSettings.MessageDoubleTapAction.none.rawValue:
                return .disable
            default:
                return .reactions
            }
        }
        set {
            self.store.setInt(newValue.rawValue, ExteraSettings.doubleTapActionOutgoingKey)
        }
    }

    // Seconds skipped by a double tap on a video; 15 is what the stock player does.
    public var doubleTapSeekDuration: Int {
        get {
            let value = self.store.int(ExteraSettings.doubleTapSeekDurationKey)
            return ExteraSettings.doubleTapSeekDurationValues.contains(value) ? value : 15
        }
        set {
            self.store.setInt(newValue, ExteraSettings.doubleTapSeekDurationKey)
        }
    }

    // "Filter Zalgo": runs of combining marks beyond what real scripts use are dropped.
    public func filteredText(_ text: String) -> String {
        guard self.filterZalgo else {
            return text
        }
        var result = String.UnicodeScalarView()
        var combiningRun = 0
        var changed = false
        for scalar in text.unicodeScalars {
            let isCombining: Bool
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark:
                isCombining = true
            default:
                isCombining = false
            }
            if isCombining {
                combiningRun += 1
                if combiningRun > 2 {
                    changed = true
                    continue
                }
            } else {
                combiningRun = 0
            }
            result.append(scalar)
        }
        return changed ? String(result) : text
    }
}
