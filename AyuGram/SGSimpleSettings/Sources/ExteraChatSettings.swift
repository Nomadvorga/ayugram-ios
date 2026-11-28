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
        // AyuGram's explicit read receipt, shown in reference screenshot 85.
        case read = 10
    }

    /// Stable values for the channel's bottom action. Existing installations default to mute.
    public enum ChannelBottomButton: Int, CaseIterable {
        case hidden = 0
        case mute = 1
        case discuss = 2
    }

    public enum Keys: String, CaseIterable {
        case doubleTapIncoming
        case doubleTapOutgoing
        case hideKeyboardOnScroll
        case swipeToReplyIncoming
        case swipeToReplyOutgoing
        case channelBottomButton
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
            // Sentinel preserves the legacy setting without disk reads during layout.
            Self.key(.channelBottomButton): -1,
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

    /// The unset sentinel falls back to the legacy preference through the cached store.
    public var channelBottomButton: ChannelBottomButton {
        get {
            let rawValue = self.store.int(Self.key(.channelBottomButton))
            guard rawValue != -1 else {
                return SGSimpleSettings.shared.hideChannelBottomButton ? .hidden : .mute
            }
            return ChannelBottomButton(rawValue: rawValue) ?? .mute
        }
        set { self.store.setInt(newValue.rawValue, Self.key(.channelBottomButton)) }
    }

    /// The legacy hide switch remains an override without discarding the saved mode.
    public var effectiveChannelBottomButton: ChannelBottomButton {
        return SGSimpleSettings.shared.hideChannelBottomButton ? .hidden : self.channelBottomButton
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
