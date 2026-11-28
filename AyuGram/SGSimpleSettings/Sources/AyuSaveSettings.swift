import Foundation

// Key names match AyuGram for Android (AyuConfig).
public final class AyuSaveSettings: @unchecked Sendable {
    public static let shared = AyuSaveSettings()

    public enum Keys: String, CaseIterable {
        case saveDeletedMessages
        case saveMessagesHistory
        case saveForBots
        case saveReadDate
        case saveLocalOnline
    }

    private static let keyPrefix = "ayu."

    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: [
            AyuSaveSettings.key(.saveDeletedMessages): true,
            AyuSaveSettings.key(.saveMessagesHistory): true,
            AyuSaveSettings.key(.saveForBots): false,
            AyuSaveSettings.key(.saveReadDate): true,
            AyuSaveSettings.key(.saveLocalOnline): true,
        ])
    }

    private static func key(_ key: Keys) -> String {
        return keyPrefix + key.rawValue
    }

    public var saveDeletedMessages: Bool {
        get { return self.store.bool(AyuSaveSettings.key(.saveDeletedMessages)) }
        set { self.store.setBool(newValue, AyuSaveSettings.key(.saveDeletedMessages)) }
    }

    public var saveMessagesHistory: Bool {
        get { return self.store.bool(AyuSaveSettings.key(.saveMessagesHistory)) }
        set { self.store.setBool(newValue, AyuSaveSettings.key(.saveMessagesHistory)) }
    }

    // A hidden last seen shows the user's last known activity, approximately.
    public var saveLocalOnline: Bool {
        get { return self.store.bool(AyuSaveSettings.key(.saveLocalOnline)) }
        set { self.store.setBool(newValue, AyuSaveSettings.key(.saveLocalOnline)) }
    }

    public var saveForBots: Bool {
        get { return self.store.bool(AyuSaveSettings.key(.saveForBots)) }
        set { self.store.setBool(newValue, AyuSaveSettings.key(.saveForBots)) }
    }

    public var saveReadDate: Bool {
        get { return self.store.bool(AyuSaveSettings.key(.saveReadDate)) }
        set { self.store.setBool(newValue, AyuSaveSettings.key(.saveReadDate)) }
    }
}
