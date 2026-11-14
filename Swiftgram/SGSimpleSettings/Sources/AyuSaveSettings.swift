import Foundation

// Key names match AyuGram for Android (AyuConfig).
public final class AyuSaveSettings: @unchecked Sendable {
    public static let shared = AyuSaveSettings()

    public enum Keys: String, CaseIterable {
        case saveDeletedMessages
        case saveMessagesHistory
        case saveForBots
        case saveReadDate
    }

    private static let keyPrefix = "ayu."

    private static let defaultValues: [String: Any] = [
        keyPrefix + Keys.saveDeletedMessages.rawValue: true,
        keyPrefix + Keys.saveMessagesHistory.rawValue: true,
        keyPrefix + Keys.saveForBots.rawValue: false,
        keyPrefix + Keys.saveReadDate.rawValue: true,
    ]

    private let defaults: UserDefaults

    private init() {
        self.defaults = UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard
        self.defaults.register(defaults: AyuSaveSettings.defaultValues)
    }

    public var saveDeletedMessages: Bool {
        get { return self.defaults.bool(forKey: AyuSaveSettings.keyPrefix + Keys.saveDeletedMessages.rawValue) }
        set { self.defaults.set(newValue, forKey: AyuSaveSettings.keyPrefix + Keys.saveDeletedMessages.rawValue) }
    }

    public var saveMessagesHistory: Bool {
        get { return self.defaults.bool(forKey: AyuSaveSettings.keyPrefix + Keys.saveMessagesHistory.rawValue) }
        set { self.defaults.set(newValue, forKey: AyuSaveSettings.keyPrefix + Keys.saveMessagesHistory.rawValue) }
    }

    public var saveReadDate: Bool {
        get { return self.defaults.bool(forKey: AyuSaveSettings.keyPrefix + Keys.saveReadDate.rawValue) }
        set { self.defaults.set(newValue, forKey: AyuSaveSettings.keyPrefix + Keys.saveReadDate.rawValue) }
    }

    public var saveForBots: Bool {
        get { return self.defaults.bool(forKey: AyuSaveSettings.keyPrefix + Keys.saveForBots.rawValue) }
        set { self.defaults.set(newValue, forKey: AyuSaveSettings.keyPrefix + Keys.saveForBots.rawValue) }
    }
}
