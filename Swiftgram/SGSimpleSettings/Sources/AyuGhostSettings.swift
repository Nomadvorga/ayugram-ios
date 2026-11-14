import Foundation

// Key names match AyuGram for Android (AyuGhostConfig).
// Values live in the app group and are read on every access, so the share and
// notification extensions observe changes made in the main app without a restart.
public final class AyuGhostSettings: @unchecked Sendable {
    public static let shared = AyuGhostSettings()

    public enum Keys: String, CaseIterable {
        case sendReadMessagePackets
        case sendReadStoryPackets
        case sendOnlinePackets
        case sendUploadProgress
        case sendOfflinePacketAfterOnline
        case markReadAfterAction
        case useScheduledMessages
        case sendWithoutSound
    }

    public enum SendWithoutSound: Int, CaseIterable {
        case never = 0
        case inGhostMode = 1
        case always = 2
    }

    private static let keyPrefix = "ayu."

    private static let defaultValues: [String: Any] = [
        keyPrefix + Keys.sendReadMessagePackets.rawValue: true,
        keyPrefix + Keys.sendReadStoryPackets.rawValue: true,
        keyPrefix + Keys.sendOnlinePackets.rawValue: true,
        keyPrefix + Keys.sendUploadProgress.rawValue: true,
        keyPrefix + Keys.sendOfflinePacketAfterOnline.rawValue: false,
        keyPrefix + Keys.markReadAfterAction.rawValue: true,
        keyPrefix + Keys.useScheduledMessages.rawValue: false,
        keyPrefix + Keys.sendWithoutSound.rawValue: SendWithoutSound.never.rawValue,
    ]

    private let defaults: UserDefaults

    private init() {
        self.defaults = UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard
        self.defaults.register(defaults: AyuGhostSettings.defaultValues)
    }

    public func value(_ key: Keys) -> Bool {
        return self.defaults.bool(forKey: AyuGhostSettings.keyPrefix + key.rawValue)
    }

    public func set(_ key: Keys, _ value: Bool) {
        self.defaults.set(value, forKey: AyuGhostSettings.keyPrefix + key.rawValue)
    }

    public var sendReadMessagePackets: Bool {
        get { return self.value(.sendReadMessagePackets) }
        set { self.set(.sendReadMessagePackets, newValue) }
    }

    public var sendReadStoryPackets: Bool {
        get { return self.value(.sendReadStoryPackets) }
        set { self.set(.sendReadStoryPackets, newValue) }
    }

    public var sendOnlinePackets: Bool {
        get { return self.value(.sendOnlinePackets) }
        set { self.set(.sendOnlinePackets, newValue) }
    }

    public var sendUploadProgress: Bool {
        get { return self.value(.sendUploadProgress) }
        set { self.set(.sendUploadProgress, newValue) }
    }

    public var sendOfflinePacketAfterOnline: Bool {
        get { return self.value(.sendOfflinePacketAfterOnline) }
        set { self.set(.sendOfflinePacketAfterOnline, newValue) }
    }

    // With read packets off, sending a message to a chat still marks it as read there.
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
        get { return SendWithoutSound(rawValue: self.defaults.integer(forKey: AyuGhostSettings.keyPrefix + Keys.sendWithoutSound.rawValue)) ?? .never }
        set { self.defaults.set(newValue.rawValue, forKey: AyuGhostSettings.keyPrefix + Keys.sendWithoutSound.rawValue) }
    }

    public var isGhostModeActive: Bool {
        return !self.sendReadMessagePackets && !self.sendReadStoryPackets && !self.sendOnlinePackets && !self.sendUploadProgress && self.sendOfflinePacketAfterOnline
    }

    public func setGhostModeActive(_ active: Bool) {
        self.sendReadMessagePackets = !active
        self.sendReadStoryPackets = !active
        self.sendOnlinePackets = !active
        self.sendUploadProgress = !active
        self.sendOfflinePacketAfterOnline = active
    }
}
