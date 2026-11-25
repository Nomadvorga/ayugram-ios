import Foundation

/// Message appearance preferences, cached for use during asynchronous chat layout.
public final class ExteraMessageSettings: @unchecked Sendable {
    public static let shared = ExteraMessageSettings()

    public enum Keys: String, CaseIterable {
        case hideReactionsInPrivateChats
        case removeMessageTail
        case replyColors
        case replyEmoji
        case replyBackground
        case showForwardsCount
        case showPollResultsBeforeVoting
    }

    private let store = AyuSettingsStore.shared

    private static func key(_ key: Keys) -> String {
        return "extera.\(key.rawValue)"
    }

    private init() {
        self.store.register(defaults: [
            Self.key(.hideReactionsInPrivateChats): false,
            Self.key(.removeMessageTail): false,
            Self.key(.replyColors): true,
            Self.key(.replyEmoji): true,
            Self.key(.replyBackground): true,
            Self.key(.showForwardsCount): false,
            Self.key(.showPollResultsBeforeVoting): false,
        ])
    }

    public func value(_ key: Keys) -> Bool {
        return self.store.bool(Self.key(key))
    }

    public func set(_ key: Keys, _ value: Bool) {
        self.store.setBool(value, Self.key(key))
    }

    /// Shares the existing AyuGram channel control and its persisted value.
    public var hideReactionsInChannels: Bool {
        get { return AyuCustomizationSettings.shared.hideChannelReactions }
        set { AyuCustomizationSettings.shared.hideChannelReactions = newValue }
    }

    /// Shares the existing AyuGram group control and its persisted value.
    public var hideReactionsInGroups: Bool {
        get { return AyuCustomizationSettings.shared.hideGroupReactions }
        set { AyuCustomizationSettings.shared.hideGroupReactions = newValue }
    }

    public var hideReactionsInPrivateChats: Bool {
        get { return self.value(.hideReactionsInPrivateChats) }
        set { self.set(.hideReactionsInPrivateChats, newValue) }
    }

    public var removeMessageTail: Bool {
        get { return self.value(.removeMessageTail) }
        set { self.set(.removeMessageTail, newValue) }
    }

    public var replyColors: Bool {
        get { return self.value(.replyColors) }
        set { self.set(.replyColors, newValue) }
    }

    public var replyEmoji: Bool {
        get { return self.value(.replyEmoji) }
        set { self.set(.replyEmoji, newValue) }
    }

    public var replyBackground: Bool {
        get { return self.value(.replyBackground) }
        set { self.set(.replyBackground, newValue) }
    }

    public var showForwardsCount: Bool {
        get { return self.value(.showForwardsCount) }
        set { self.set(.showForwardsCount, newValue) }
    }

    public var showPollResultsBeforeVoting: Bool {
        get { return self.value(.showPollResultsBeforeVoting) }
        set { self.set(.showPollResultsBeforeVoting, newValue) }
    }
}
