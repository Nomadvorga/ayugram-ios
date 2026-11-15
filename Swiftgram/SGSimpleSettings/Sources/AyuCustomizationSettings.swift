import Foundation
import UIKit

// Deleted message styles of AyuGram for Android and AyuGram iOS (Telegram-iOS-Ghost) together.
public final class AyuCustomizationSettings: @unchecked Sendable {
    public static let shared = AyuCustomizationSettings()

    public enum Keys: String, CaseIterable {
        case showDeletedMarker
        case deletedMark
        case deletedMarkColor
        case semiTransparentDeletedMessages
        case disableAds
    }

    public enum DeletedMark: Int, CaseIterable {
        case trashBin = 0
        case text = 1
        case cross = 2
        case compact = 3
        case eyeCrossed = 4

        public func text(lang: String) -> String {
            switch self {
            case .trashBin:
                return "🗑"
            case .text:
                return lang.hasPrefix("ru") || lang.hasPrefix("uk") || lang.hasPrefix("be") ? "Удалено" : "Deleted"
            case .cross:
                return "✕"
            case .compact:
                return "DEL"
            case .eyeCrossed:
                return "🙈"
            }
        }
    }

    public enum DeletedMarkColor: Int, CaseIterable {
        case red = 0
        case orange = 1
        case gray = 2
        case purple = 3
        case theme = 4

        public var color: UIColor? {
            switch self {
            case .red:
                return UIColor.systemRed
            case .orange:
                return UIColor.systemOrange
            case .gray:
                return UIColor.systemGray
            case .purple:
                return UIColor.systemPurple
            case .theme:
                return nil
            }
        }
    }

    private static let keyPrefix = "ayu."

    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: [
            AyuCustomizationSettings.key(.showDeletedMarker): true,
            AyuCustomizationSettings.key(.deletedMark): DeletedMark.trashBin.rawValue,
            AyuCustomizationSettings.key(.deletedMarkColor): DeletedMarkColor.red.rawValue,
            AyuCustomizationSettings.key(.semiTransparentDeletedMessages): true,
            AyuCustomizationSettings.key(.disableAds): true,
        ])
    }

    private static func key(_ key: Keys) -> String {
        return keyPrefix + key.rawValue
    }

    public var showDeletedMarker: Bool {
        get { return self.store.bool(AyuCustomizationSettings.key(.showDeletedMarker)) }
        set { self.store.setBool(newValue, AyuCustomizationSettings.key(.showDeletedMarker)) }
    }

    public var deletedMark: DeletedMark {
        get { return DeletedMark(rawValue: self.store.int(AyuCustomizationSettings.key(.deletedMark))) ?? .trashBin }
        set { self.store.setInt(newValue.rawValue, AyuCustomizationSettings.key(.deletedMark)) }
    }

    public var deletedMarkColor: DeletedMarkColor {
        get { return DeletedMarkColor(rawValue: self.store.int(AyuCustomizationSettings.key(.deletedMarkColor))) ?? .red }
        set { self.store.setInt(newValue.rawValue, AyuCustomizationSettings.key(.deletedMarkColor)) }
    }

    public var semiTransparentDeletedMessages: Bool {
        get { return self.store.bool(AyuCustomizationSettings.key(.semiTransparentDeletedMessages)) }
        set { self.store.setBool(newValue, AyuCustomizationSettings.key(.semiTransparentDeletedMessages)) }
    }

    // Sponsored messages in channels and sponsored peers in search.
    public var disableAds: Bool {
        get { return self.store.bool(AyuCustomizationSettings.key(.disableAds)) }
        set { self.store.setBool(newValue, AyuCustomizationSettings.key(.disableAds)) }
    }

    // The prefix of a deleted message's time, nil when the mark is hidden.
    public func deletedMarkPrefix(lang: String) -> String? {
        if !self.showDeletedMarker {
            return nil
        }
        return self.deletedMark.text(lang: lang)
    }
}
