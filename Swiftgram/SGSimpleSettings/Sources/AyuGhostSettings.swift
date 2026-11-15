import Foundation

// Ghost mode as in AyuGram iOS (Telegram-iOS-Ghost): one master switch, and options that take
// effect only while it is on. Defaults follow that project: the master switch is off, every
// option under it is on.
public final class AyuGhostSettings: @unchecked Sendable {
    public static let shared = AyuGhostSettings()

    public enum Keys: String, CaseIterable {
        case ghostMode
        case hideReadMessages
        case hideReadStories
        case hideOnline
        case hideTyping
        case automaticOffline
        case onlinePulseOnSend
        case markReadAfterAction
        case useScheduledMessages
        case sendWithoutSound
    }

    public enum SendWithoutSound: Int, CaseIterable {
        case never = 0
        case inGhostMode = 1
        case always = 2
    }

    private static let keyPrefix = "ayu.ghost."

    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: [
            AyuGhostSettings.key(.ghostMode): false,
            AyuGhostSettings.key(.hideReadMessages): true,
            AyuGhostSettings.key(.hideReadStories): true,
            AyuGhostSettings.key(.hideOnline): true,
            AyuGhostSettings.key(.hideTyping): true,
            AyuGhostSettings.key(.automaticOffline): true,
            AyuGhostSettings.key(.onlinePulseOnSend): true,
            AyuGhostSettings.key(.markReadAfterAction): true,
            AyuGhostSettings.key(.useScheduledMessages): false,
            AyuGhostSettings.key(.sendWithoutSound): SendWithoutSound.never.rawValue,
        ])
    }

    private static func key(_ key: Keys) -> String {
        return keyPrefix + key.rawValue
    }

    public func value(_ key: Keys) -> Bool {
        return self.store.bool(AyuGhostSettings.key(key))
    }

    public func set(_ key: Keys, _ value: Bool) {
        self.store.setBool(value, AyuGhostSettings.key(key))
    }

    public var isGhostModeActive: Bool {
        return self.value(.ghostMode)
    }

    public func setGhostModeActive(_ active: Bool) {
        self.set(.ghostMode, active)
    }

    public var suppressReadMessages: Bool {
        return self.isGhostModeActive && self.value(.hideReadMessages)
    }

    public var suppressStoryViews: Bool {
        return self.isGhostModeActive && self.value(.hideReadStories)
    }

    public var suppressOnlineStatus: Bool {
        return self.isGhostModeActive && self.value(.hideOnline)
    }

    public var suppressTyping: Bool {
        return self.isGhostModeActive && self.value(.hideTyping)
    }

    // Goes offline right after anything that makes the account online, e.g. sending a message.
    public var sendAutomaticOffline: Bool {
        return self.suppressOnlineStatus && self.value(.automaticOffline)
    }

    // Shows the account online for 0.2 s when it sends a message, then offline again.
    public var pulseOnlineOnSend: Bool {
        return self.suppressOnlineStatus && self.value(.onlinePulseOnSend)
    }

    // With read receipts hidden, sending a message to a chat still marks it as read there.
    public var markReadAfterAction: Bool {
        get { return self.value(.markReadAfterAction) }
        set { self.set(.markReadAfterAction, newValue) }
    }

    // Outgoing messages are scheduled a few seconds ahead, so sending them does not make the account online.
    public var useScheduledMessages: Bool {
        get { return self.value(.useScheduledMessages) }
        set { self.set(.useScheduledMessages, newValue) }
    }

    public var sendWithoutSound: SendWithoutSound {
        get { return SendWithoutSound(rawValue: self.store.int(AyuGhostSettings.key(.sendWithoutSound))) ?? .never }
        set { self.store.setInt(newValue.rawValue, AyuGhostSettings.key(.sendWithoutSound)) }
    }
}

// The last moment the account was allowed to be online while ghost mode hides it,
// shown in the account's own profile.
public final class AyuGhostLastSeen: @unchecked Sendable {
    public static let shared = AyuGhostLastSeen()

    private static let key = "ayu.ghost.lastSeen"

    private let store = AyuSettingsStore.shared

    private init() {
    }

    public var timestamp: Int32 {
        let value = self.store.int(AyuGhostLastSeen.key)
        if value == 0 {
            return Int32(Date().timeIntervalSince1970)
        }
        return Int32(clamping: value)
    }

    public func recordNow() {
        self.store.setInt(Int(Date().timeIntervalSince1970), AyuGhostLastSeen.key)
    }
}
