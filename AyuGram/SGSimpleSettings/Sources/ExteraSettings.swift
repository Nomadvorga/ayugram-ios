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
        case hideKeyboardOnScroll
        case disableUnarchiveSwipe
        case showOnlineStatus
        case archiveOnPull
        case pauseOnMinimizeVoice
        case pauseOnMinimizeRound
        case senderMiniAvatars
        case replyColors
        case replyEmoji
        case replyBackground
        case preferOriginalQuality
        case showClearButton
        case showHistoryButton
    }

    public static let doubleTapSeekDurationValues: [Int] = [5, 10, 15, 30]
    private static let doubleTapSeekDurationKey = "extera.doubleTapSeekDuration"
    private static let defaultProfileTabKey = "extera.defaultProfileTab"
    private static let stickerShapeKey = "extera.stickerShape"
    private static let titleTextKey = "extera.titleText"
    private static let avatarCornersKey = "extera.avatarCorners"
    private static let doubleTapActionKey = "extera.doubleTapAction"
    private static let doubleTapActionOutgoingKey = "extera.doubleTapActionOutOwner"

    // Corner radius of a 56 pt avatar; 28 is a circle, the stock look.
    public static let avatarCornersValues: [Int] = [0, 4, 8, 12, 16, 20, 24, 28]

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
            ExteraSettings.key(.hideKeyboardOnScroll): false,
            ExteraSettings.key(.disableUnarchiveSwipe): false,
            ExteraSettings.key(.showOnlineStatus): false,
            ExteraSettings.key(.archiveOnPull): false,
            ExteraSettings.key(.pauseOnMinimizeVoice): false,
            ExteraSettings.key(.pauseOnMinimizeRound): false,
            ExteraSettings.key(.senderMiniAvatars): false,
            ExteraSettings.key(.replyColors): true,
            ExteraSettings.key(.replyEmoji): true,
            ExteraSettings.key(.replyBackground): true,
            ExteraSettings.key(.preferOriginalQuality): false,
            ExteraSettings.key(.showClearButton): false,
            ExteraSettings.key(.showHistoryButton): false,
            ExteraSettings.doubleTapSeekDurationKey: 15,
            ExteraSettings.defaultProfileTabKey: 0,
            ExteraSettings.stickerShapeKey: 0,
            ExteraSettings.titleTextKey: 0,
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
