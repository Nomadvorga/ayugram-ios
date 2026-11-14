import Foundation

// Key names match AyuGram for Android (AyuConfig).
public final class AyuCustomizationSettings: @unchecked Sendable {
    public static let shared = AyuCustomizationSettings()

    public enum Keys: String, CaseIterable {
        case deletedMark
        case semiTransparentDeletedMessages
        case disableAds
    }

    public enum DeletedMark: Int, CaseIterable {
        case nothing = 0
        case trashBin = 1
        case cross = 2
        case eyeCrossed = 3

        public var text: String? {
            switch self {
            case .nothing:
                return nil
            case .trashBin:
                return "🗑"
            case .cross:
                return "✕"
            case .eyeCrossed:
                return "🙈"
            }
        }
    }

    private static let keyPrefix = "ayu."

    private static let defaultValues: [String: Any] = [
        keyPrefix + Keys.deletedMark.rawValue: DeletedMark.trashBin.rawValue,
        keyPrefix + Keys.semiTransparentDeletedMessages.rawValue: true,
        keyPrefix + Keys.disableAds.rawValue: true,
    ]

    private let defaults: UserDefaults

    private init() {
        self.defaults = UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard
        self.defaults.register(defaults: AyuCustomizationSettings.defaultValues)
    }

    public var deletedMark: DeletedMark {
        get { return DeletedMark(rawValue: self.defaults.integer(forKey: AyuCustomizationSettings.keyPrefix + Keys.deletedMark.rawValue)) ?? .trashBin }
        set { self.defaults.set(newValue.rawValue, forKey: AyuCustomizationSettings.keyPrefix + Keys.deletedMark.rawValue) }
    }

    public var semiTransparentDeletedMessages: Bool {
        get { return self.defaults.bool(forKey: AyuCustomizationSettings.keyPrefix + Keys.semiTransparentDeletedMessages.rawValue) }
        set { self.defaults.set(newValue, forKey: AyuCustomizationSettings.keyPrefix + Keys.semiTransparentDeletedMessages.rawValue) }
    }

    // Sponsored messages in channels and sponsored peers in search.
    public var disableAds: Bool {
        get { return self.defaults.bool(forKey: AyuCustomizationSettings.keyPrefix + Keys.disableAds.rawValue) }
        set { self.defaults.set(newValue, forKey: AyuCustomizationSettings.keyPrefix + Keys.disableAds.rawValue) }
    }
}
