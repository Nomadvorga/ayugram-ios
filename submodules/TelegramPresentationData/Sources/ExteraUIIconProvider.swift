import Display
import SGSimpleSettings
import UIKit

/// Semantic glyphs shared by settings, navigation and message menus.
public enum ExteraUIIconRole: String, CaseIterable {
    case settings, contacts, calls, chats, archive, saved, groups, channel, profile
    case ghost, wallet, browser, qrCode, notifications, privacy, data, devices, folders
    case appearance, language, stickers, bots, copy, forward, reply, delete, edit, select
    case report, pin, unpin, link, photo, info, search, add, menu
    case back, calendar, clear, customize, downloadTone, draw, factCheck, favorite, gift
    case goToMessage, message, priceTag, rate, reactions, read, reload, replies, resend
    case restrict, schedule, selectAll, speed, statistics, stopPoll, thumbsDown, thumbsUp
    case time, unfavorite, unvote, selfExpiring, views, powerSaving, birthday
    case storageUsage, dataUsage, stories, video, file, gif, emoji, clock, block
    case key, support, faq, changePhone, topics, admins, permissions, location
    case requests, music, voice, upload, download, recentActions, chatHistory, translate
    case disabled, doubleTapReactions, doubleTapReply, doubleTapForward, repeatAction, readUntil

    /// Exact incoming-action order and resource keys from Android DoubleTapUtils.getDoubleTapIcons(false).
    public static let incomingDoubleTapActions: [ExteraUIIconRole] = [
        .disabled, .doubleTapReactions, .doubleTapReply, .copy, .doubleTapForward,
        .saved, .repeatAction, .delete, .translate, .readUntil
    ]

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
        case .back: return "msg_arrow_back"
        case .calendar: return "msg_calendar"
        case .clear: return "msg_clear"
        case .customize: return "msg_customize"
        case .downloadTone: return "msg_tone_add"
        case .draw: return "msg_header_draw"
        case .factCheck: return "menu_verification"
        case .favorite: return "msg_fave"
        case .gift: return "menu_gift"
        case .goToMessage: return "msg_message"
        case .message: return "msg_discussion"
        case .priceTag: return "menu_tag_edit"
        case .rate: return "msg_rate_up"
        case .reactions: return "msg_reactions"
        case .read: return "msg_markread"
        case .reload: return "msg_retry"
        case .replies: return "msg_viewreplies"
        case .resend: return "msg_send"
        case .restrict: return "msg_permissions"
        case .schedule: return "msg_calendar2"
        case .selectAll: return "msg_select"
        case .speed: return "msg_speed"
        case .statistics: return "msg_stats"
        case .stopPoll: return "msg_pollstop"
        case .thumbsDown: return "msg_rate_down"
        case .thumbsUp: return "msg_rate_up"
        case .time: return "msg_recent"
        case .unfavorite: return "msg_unfave"
        case .unvote: return "msg_unvote"
        case .selfExpiring: return "msg_autodelete"
        case .views: return "msg_views"
        case .powerSaving: return "msg_brightness_low"
        case .birthday: return "menu_gift"
        case .storageUsage: return "msg_filled_storageusage"
        case .dataUsage: return "msg_filled_datausage"
        case .stories: return "msg_menu_stories"
        case .video: return "msg_filled_data_videos"
        case .file: return "msg_filled_data_files"
        case .gif: return "msg_gif"
        case .emoji: return "msg_emoji_smiles"
        case .clock: return "msg_recent"
        case .block: return "msg_block"
        case .key: return "msg_pin_code"
        case .support: return "msg_help"
        case .faq: return "msg_info"
        case .changePhone: return "msg_newphone"
        case .topics: return "msg_topics"
        case .admins: return "msg_admins"
        case .permissions: return "msg_permissions"
        case .location: return "msg_location"
        case .requests: return "msg_requests"
        case .music: return "msg_filled_data_music"
        case .voice: return "msg_filled_data_voice"
        case .upload: return "msg_filled_data_sent"
        case .download: return "msg_download"
        case .recentActions: return "msg_log"
        case .chatHistory: return "msg_discuss"
        case .translate: return "msg_translate"
        case .disabled: return "msg_block"
        case .doubleTapReactions: return "msg_reactions2"
        case .doubleTapReply: return "menu_reply"
        case .doubleTapForward: return "msg_forward"
        case .repeatAction: return "msg_repeat"
        case .readUntil: return "msg_view_file"
        }
    }
}

/// A value snapshot: renderers may receive this explicitly without reading preferences.
/// No theme cache stores these images, so a new selection never reuses another pack's glyph.
public struct ExteraUIIconProvider: Equatable {
    public let pack: ExteraUIIconPack
    public let customPacks: [ExteraCustomUIIconPack]

    public init(pack: ExteraUIIconPack, customPacks: [ExteraCustomUIIconPack] = []) {
        self.pack = pack
        self.customPacks = customPacks
    }

    public static var current: ExteraUIIconProvider {
        return ExteraUIIconProvider(pack: ExteraUIIconSettings.shared.pack, customPacks: ExteraUIIconPackStore.shared.snapshot.enabled)
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
        return self.image(androidResource: role.androidResource, fallback: fallback())
    }

    /// First declaring custom owner wins. A broken owner falls directly through to base/native,
    /// matching Android; it never reveals a lower custom owner until its mapping is reset.
    public func image(androidResource: String, fallback: @autoclosure () -> UIImage? = nil) -> UIImage? {
        if let owner = self.customPacks.first(where: { $0.icons[androidResource] != nil }),
           let path = owner.icons[androidResource], let image = ExteraUIIconRendering.image(pack: owner, path: path) {
            return image
        }
        let prefix: String
        switch self.pack {
        case .native: return fallback()
        case .solar: prefix = "ExteraUI_solar_"
        case .remix: prefix = "ExteraUI_remix_"
        }
        return UIImage(bundleImageName: prefix + androidResource)?.withRenderingMode(.alwaysTemplate) ?? fallback()
    }

    public func hasImage(for role: ExteraUIIconRole) -> Bool {
        return self.image(for: role) != nil
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
