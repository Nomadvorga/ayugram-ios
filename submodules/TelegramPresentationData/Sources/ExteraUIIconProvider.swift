import Display
import SGSimpleSettings
import UIKit

/// Semantic glyphs shared by settings, navigation and message menus.
public enum ExteraUIIconRole: String, CaseIterable {
    case settings, contacts, calls, chats, archive, saved, groups, channel, profile
    case ghost, wallet, browser, qrCode, notifications, privacy, data, devices, folders
    case appearance, language, stickers, bots, copy, forward, reply, delete, edit, select
    case report, pin, unpin, link, photo, info, search, add, menu

    public var androidResource: String {
        switch self {
        case .settings: return "msg_settings"
        case .contacts: return "msg_contacts"
        case .calls: return "msg_calls"
        case .chats: return "msg_msgbubble3"
        case .archive: return "msg_archive"
        case .saved: return "msg_saved"
        case .groups: return "msg_groups"
        case .channel: return "msg_channel"
        case .profile: return "msg_openprofile"
        case .ghost: return "ghost"
        case .wallet: return "menu_wallet"
        case .browser: return "menu_website"
        case .qrCode: return "msg_qrcode"
        case .notifications: return "msg_notifications"
        case .privacy: return "msg_secret"
        case .data: return "msg_data"
        case .devices: return "msg_devices"
        case .folders: return "msg_folder"
        case .appearance: return "msg_theme"
        case .language: return "msg_language"
        case .stickers: return "msg_sticker"
        case .bots: return "msg_bots"
        case .copy: return "msg_copy"
        case .forward: return "msg_share"
        case .reply: return "msg_reply"
        case .delete: return "msg_delete"
        case .edit: return "msg_edit"
        case .select: return "msg_select"
        case .report: return "msg_report_other"
        case .pin: return "msg_pin"
        case .unpin: return "msg_unpin"
        case .link: return "msg_link2"
        case .photo: return "msg_photos"
        case .info: return "msg_info"
        case .search: return "msg_search"
        case .add: return "msg_add"
        case .menu: return "msg_list"
        }
    }
}

/// A value snapshot: renderers may receive this explicitly without reading preferences.
/// No theme cache stores these images, so a new selection never reuses another pack's glyph.
public struct ExteraUIIconProvider: Equatable {
    public let pack: ExteraUIIconPack

    public init(pack: ExteraUIIconPack) {
        self.pack = pack
    }

    public static var current: ExteraUIIconProvider {
        return ExteraUIIconProvider(pack: ExteraUIIconSettings.shared.pack)
    }

    public func assetName(for role: ExteraUIIconRole) -> String? {
        switch self.pack {
        case .native: return nil
        case .solar: return "ExteraUI_solar_" + role.androidResource
        case .remix: return "ExteraUI_remix_" + role.androidResource
        }
    }

    /// Missing resources and native selection both evaluate the caller's original fallback.
    public func image(for role: ExteraUIIconRole, fallback: @autoclosure () -> UIImage? = nil) -> UIImage? {
        guard let name = self.assetName(for: role), let image = UIImage(bundleImageName: name) else {
            return fallback()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    public func navigationImage(id: String, fallback: @autoclosure () -> UIImage?) -> UIImage? {
        let role: ExteraUIIconRole?
        switch id {
        case "settings": role = .settings
        case "contacts": role = .contacts
        case "calls": role = .calls
        case "profile": role = .profile
        case "ghost": role = .ghost
        case "archive": role = .archive
        case "newGroup": role = .groups
        case "savedMessages": role = .saved
        case "wallet": role = .wallet
        case "newChannel": role = .channel
        case "browser": role = .browser
        case "qrCode": role = .qrCode
        default: role = nil
        }
        guard let role else { return fallback() }
        return self.image(for: role, fallback: fallback())
    }
}
