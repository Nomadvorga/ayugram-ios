import Foundation

/// Chat gestures and composer preferences inspired by exteraGram's non-plugin chat settings.
public final class ExteraChatSettings {
    public static let shared = ExteraChatSettings()

    /// Stable action identifiers, matching exteraGram's action IDs rather than its menu indices.
    /// `inherit` preserves the existing Swiftgram outgoing double-tap preference.
    public enum DoubleTapAction: Int, CaseIterable {
        case inherit = -1
        case disabled = 0
        case reaction = 1
        case reply = 2
        case copy = 3
        case forward = 4
        case edit = 5
        case save = 6
        case repeatMessage = 7
        case delete = 8
        case translate = 9
    }

    public enum Keys: String, CaseIterable {
        case doubleTapIncoming
        case doubleTapOutgoing
        case hideKeyboardOnScroll
        case swipeToReplyIncoming
        case swipeToReplyOutgoing
    }

    private let store = AyuSettingsStore.shared

    private static func key(_ key: Keys) -> String {
        return "extera.chat.\(key.rawValue)"
    }

    private init() {
        self.store.register(defaults: [
            Self.key(.doubleTapIncoming): DoubleTapAction.reaction.rawValue,
            Self.key(.doubleTapOutgoing): DoubleTapAction.inherit.rawValue,
            Self.key(.hideKeyboardOnScroll): false,
            Self.key(.swipeToReplyIncoming): true,
            Self.key(.swipeToReplyOutgoing): true,
        ])
    }

    public var doubleTapIncoming: DoubleTapAction {
        get { return DoubleTapAction(rawValue: self.store.int(Self.key(.doubleTapIncoming))) ?? .reaction }
        set { self.store.setInt(newValue.rawValue, Self.key(.doubleTapIncoming)) }
    }

    public var doubleTapOutgoing: DoubleTapAction {
        get { return DoubleTapAction(rawValue: self.store.int(Self.key(.doubleTapOutgoing))) ?? .inherit }
        set { self.store.setInt(newValue.rawValue, Self.key(.doubleTapOutgoing)) }
    }

    /// Resolves the legacy outgoing preference without overwriting it during migration.
    public func effectiveDoubleTapAction(incoming: Bool) -> DoubleTapAction {
        let action = incoming ? self.doubleTapIncoming : self.doubleTapOutgoing
        guard action == .inherit else {
            return action
        }
        if !incoming {
            switch SGSimpleSettings.shared.messageDoubleTapActionOutgoing {
            case SGSimpleSettings.MessageDoubleTapAction.none.rawValue:
                return .disabled
            case SGSimpleSettings.MessageDoubleTapAction.edit.rawValue:
                return .edit
            default:
                break
            }
        }
        return .reaction
    }

    public var hideKeyboardOnScroll: Bool {
        get { return self.store.bool(Self.key(.hideKeyboardOnScroll)) }
        set { self.store.setBool(newValue, Self.key(.hideKeyboardOnScroll)) }
    }

    /// Alias of Swiftgram's existing composer setting; both mention panels share its storage.
    public var addCommaAfterMention: Bool {
        get { return SGSimpleSettings.shared.commaAfterMention }
        set { SGSimpleSettings.shared.commaAfterMention = newValue }
    }

    public var swipeToReplyIncoming: Bool {
        get { return self.store.bool(Self.key(.swipeToReplyIncoming)) }
        set { self.store.setBool(newValue, Self.key(.swipeToReplyIncoming)) }
    }

    public var swipeToReplyOutgoing: Bool {
        get { return self.store.bool(Self.key(.swipeToReplyOutgoing)) }
        set { self.store.setBool(newValue, Self.key(.swipeToReplyOutgoing)) }
    }

    public func isSwipeToReplyEnabled(incoming: Bool) -> Bool {
        return incoming ? self.swipeToReplyIncoming : self.swipeToReplyOutgoing
    }
}
