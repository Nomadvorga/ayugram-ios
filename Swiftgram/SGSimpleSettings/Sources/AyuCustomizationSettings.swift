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
        case disableOpenLinkWarning
        case hideNotificationBadge
        case hideFolderCounters
        case copyUsernameAsLink
        case disableSimilarChannels
        case disableCustomBackgrounds
        case simpleQuotesAndReplies
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
            AyuCustomizationSettings.key(.disableOpenLinkWarning): false,
            AyuCustomizationSettings.key(.hideNotificationBadge): false,
            AyuCustomizationSettings.key(.hideFolderCounters): false,
            AyuCustomizationSettings.key(.copyUsernameAsLink): true,
            AyuCustomizationSettings.key(.disableSimilarChannels): false,
            AyuCustomizationSettings.key(.disableCustomBackgrounds): false,
            AyuCustomizationSettings.key(.simpleQuotesAndReplies): false,
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

    // Hidden links open without the "Open this link?" prompt.
    public var disableOpenLinkWarning: Bool {
        get { return self.store.bool(AyuCustomizationSettings.key(.disableOpenLinkWarning)) }
        set { self.store.setBool(newValue, AyuCustomizationSettings.key(.disableOpenLinkWarning)) }
    }

    // No unread counter on the app icon, set both by the app and by the notification service extension.
    public var hideNotificationBadge: Bool {
        get { return self.store.bool(AyuCustomizationSettings.key(.hideNotificationBadge)) }
        set { self.store.setBool(newValue, AyuCustomizationSettings.key(.hideNotificationBadge)) }
    }

    public var hideFolderCounters: Bool {
        get { return self.store.bool(AyuCustomizationSettings.key(.hideFolderCounters)) }
        set { self.store.setBool(newValue, AyuCustomizationSettings.key(.hideFolderCounters)) }
    }

    public var copyUsernameAsLink: Bool {
        get { return self.store.bool(AyuCustomizationSettings.key(.copyUsernameAsLink)) }
        set { self.store.setBool(newValue, AyuCustomizationSettings.key(.copyUsernameAsLink)) }
    }

    // No similar channels for a channel: neither the panel after joining nor the profile tab.
    public var disableSimilarChannels: Bool {
        get { return self.store.bool(AyuCustomizationSettings.key(.disableSimilarChannels)) }
        set { self.store.setBool(newValue, AyuCustomizationSettings.key(.disableSimilarChannels)) }
    }

    // Chats keep the app wallpaper instead of the theme or wallpaper the other side set.
    public var disableCustomBackgrounds: Bool {
        get { return self.store.bool(AyuCustomizationSettings.key(.disableCustomBackgrounds)) }
        set { self.store.setBool(newValue, AyuCustomizationSettings.key(.disableCustomBackgrounds)) }
    }

    // Replies use the theme accent instead of the author's name color and pattern.
    public var simpleQuotesAndReplies: Bool {
        get { return self.store.bool(AyuCustomizationSettings.key(.simpleQuotesAndReplies)) }
        set { self.store.setBool(newValue, AyuCustomizationSettings.key(.simpleQuotesAndReplies)) }
    }

    // What copying a username puts on the pasteboard.
    public func copiedUsername(_ username: String) -> String {
        return self.copyUsernameAsLink ? "https://t.me/\(username)" : "@\(username)"
    }

    // The prefix of a deleted message's time, nil when the mark is hidden.
    public func deletedMarkPrefix(lang: String) -> String? {
        if !self.showDeletedMarker {
            return nil
        }
        return self.deletedMark.text(lang: lang)
    }
}
