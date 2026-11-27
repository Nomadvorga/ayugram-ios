import Foundation
import UIKit

/// An iOS icon standing in for an Android resource.
public enum AyuPluginIcon: Sendable, Equatable {
    /// An image set of the app's asset catalog.
    case asset(String)
    /// An SF Symbol that exists on iOS 15.
    case symbol(String)

    /// The untinted image, or nil when the running bundle lacks it.
    public func image() -> UIImage? {
        switch self {
        case let .asset(name): return UIImage(named: name, in: Bundle.main, compatibleWith: nil)
        case let .symbol(name): return UIImage(systemName: name)
        }
    }

    public func image(color: UIColor) -> UIImage? {
        self.image()?.withTintColor(color, renderingMode: .alwaysOriginal)
    }
}

/// `resources.resolve` and the resource-id object `{"resource": kind, "name": name}`
/// of `Python/protocol-telegram.md`. Android resource integers do not exist on
/// iOS: a name is served only through the explicit tables below, whose targets
/// are Telegram-iOS context-menu image sets and SF Symbols. `Tests/Python/test_menus_resources.py`
/// checks that every image set exists in `TelegramUI/Images.xcassets`.
enum AyuPluginResources {
    static let operation = "resources.resolve"
    static let maximumNameBytes = 128
    /// exteraGram icon-pack and size variants of one drawable.
    private static let variantSuffixes = ["_solar", "_remix", "_hw", "_ny", "_art", "_old", "_14", "_24"]
    private static let assetPrefix = "Chat/Context Menu/"

    /// The icon for an Android drawable name (`msg_settings`), or nil.
    static func icon(drawable name: String) -> AyuPluginIcon? {
        var base = Substring(name)
        var stripped = true
        while stripped {
            stripped = false
            if let icon = Self.drawables[String(base)] { return Self.qualified(icon) }
            for suffix in Self.variantSuffixes where base.hasSuffix(suffix) && base.count > suffix.count {
                base = base.dropLast(suffix.count)
                stripped = true
                break
            }
        }
        return nil
    }

    /// The still icon for an Android Lottie resource a bulletin shows (`R.raw.info`), or nil.
    static func icon(raw name: String) -> AyuPluginIcon? { Self.animations[name] }

    private static func qualified(_ icon: AyuPluginIcon) -> AyuPluginIcon {
        if case let .asset(name) = icon { return .asset(Self.assetPrefix + name) }
        return icon
    }

    /// Kind and name of a resource-id object; `invalid_arguments` for any other value.
    static func reference(_ value: AyuBridgeValue?) throws -> (kind: String, name: String) {
        guard let object = value?.object, Set(object.keys) == ["resource", "name"],
              let kind = object["resource"]?.string, let name = object["name"]?.string,
              Self.isIdentifier(kind), Self.isIdentifier(name) else {
            throw AyuBridgeFailure("invalid_arguments", "Expected an Android resource id")
        }
        return (kind, name)
    }

    static func isResource(_ value: AyuBridgeValue) -> Bool { value.object?["resource"] != nil }

    private static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= Self.maximumNameBytes && text.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7a) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x30 && byte <= 0x39) || byte == 0x5f
        }
    }

    static func icon(kind: String, name: String) -> AyuPluginIcon? {
        switch kind {
        case "drawable": return Self.icon(drawable: name)
        case "raw": return Self.icon(raw: name)
        default: return nil
        }
    }

    /// The icon a resource id names. A kind without a table or a name the
    /// tables lack fails with `invalid_arguments`; nothing is shown in its place.
    static func icon(resource value: AyuBridgeValue?) throws -> AyuPluginIcon {
        let (kind, name) = try Self.reference(value)
        guard let icon = Self.icon(kind: kind, name: name) else {
            throw AyuBridgeFailure("invalid_arguments", "Android resource R." + kind + "." + name + " has no iOS counterpart")
        }
        return icon
    }

    /// `resources.resolve`: whether the host maps the name.
    static func resolve(_ arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
        let (kind, name) = try Self.reference(.object(arguments))
        return .bool(Self.icon(kind: kind, name: name) != nil)
    }

    /// Android drawable names used by the plugin corpus as menu, settings and
    /// view icons. `.asset` names are relative to `Chat/Context Menu/`.
    static let drawables: [String: AyuPluginIcon] = [
        "action_share": .asset("Share"), "ai_chat": .symbol("sparkles"), "attach_arrow_right": .symbol("arrow.right"),
        "attach_send": .symbol("paperplane"), "avd_theme": .asset("ApplyTheme"), "bot_music": .symbol("music.note"),
        "calls_decline": .symbol("phone.down"), "calls_mute": .symbol("mic.slash"), "calls_speaker": .symbol("speaker.wave.2"),
        "calls_unmute": .symbol("mic"), "calls_video": .asset("VideoCall"), "camera_revert2": .symbol("arrow.triangle.2.circlepath.camera"),
        "chat_calls_voice": .asset("Call"), "chats_archive": .asset("Archive"), "chats_delete": .asset("Delete"), "chats_lock": .asset("Lock"),
        "chats_pin": .asset("Pin"), "chats_saved": .symbol("bookmark"), "dialog_media_game_20": .symbol("gamecontroller"),
        "etg_settings": .asset("Settings"), "files_folder": .asset("Folder"), "files_gallery": .asset("Image"),
        "files_internal": .symbol("internaldrive"), "files_music": .symbol("music.note"), "files_storage": .symbol("internaldrive"),
        "filled_access_fingerprint": .asset("TouchId"), "filled_access_sleeping": .symbol("moon.zzz"), "filled_add_sticker": .asset("AddSticker"),
        "filled_boost_plus": .asset("Boost"), "filled_fab_compose_32": .asset("Pencil"), "filled_giveaway_stars": .asset("Stars"),
        "filled_info": .symbol("info.circle.fill"), "filled_link": .asset("Link"), "filled_username": .asset("Mention"),
        "filter_custom": .asset("Folder"), "filter_game": .symbol("gamecontroller"), "filter_note": .symbol("note.text"),
        "fingerprint": .asset("TouchId"), "flash_auto": .symbol("bolt.badge.a"), "flash_on": .symbol("bolt"), "floating_check": .asset("Check"),
        "floating_pencil": .asset("Pencil"), "gift": .asset("Gift"), "gift_unpack": .asset("Gift"), "group_edit_profile": .asset("Edit"),
        "help": .asset("Help"), "ic_ab_back": .asset("Back"), "ic_ab_search": .asset("Search"), "ic_action_next": .symbol("forward.end"),
        "ic_action_previous": .symbol("backward.end"), "ic_delete": .asset("Delete"), "ic_gofullscreen": .asset("Expand"),
        "ic_layer_close": .symbol("xmark"), "ic_media_pause": .asset("Pause"), "ic_media_play": .asset("Play"), "ic_pause": .asset("Pause"),
        "ic_pauseinline": .asset("Pause"), "ic_play": .asset("Play"), "ic_unlock": .symbol("lock.open"), "input_bot": .asset("Bots"),
        "input_bot1": .asset("Bots"), "input_bot2": .asset("Bots"), "input_forward": .asset("Forward"), "input_keyboard": .symbol("keyboard"),
        "input_mic": .symbol("mic"), "input_notify_off": .asset("Muted"), "input_reply": .asset("Reply"), "input_schedule": .asset("Schedule"),
        "input_smile": .asset("Smile"), "iv_text": .asset("FormatText"), "media_button_restore": .symbol("arrow.uturn.backward"),
        "media_crop": .symbol("crop"), "media_flip": .symbol("arrow.left.and.right"), "media_more": .asset("More"),
        "media_repost": .symbol("arrow.2.squarepath"), "media_settings": .asset("Settings"), "media_share": .asset("Share"),
        "mentionbutton": .asset("Mention"), "menu_bots_add": .asset("Bots"), "menu_clear_cache": .asset("Clear"), "menu_delete": .asset("Delete"),
        "menu_devices": .symbol("laptopcomputer.and.iphone"), "menu_edit_appearance": .asset("Palette"), "menu_edit_price": .asset("PriceTag"),
        "menu_feature_code": .asset("FormatCode"), "menu_feature_links2": .asset("Link"), "menu_feature_reactions": .asset("Reactions"),
        "menu_feature_translate": .asset("Translate"), "menu_feature_voice": .symbol("mic"), "menu_gift": .asset("Gift"),
        "menu_hashtag": .symbol("number"), "menu_intro": .symbol("sparkles"), "menu_link_below": .asset("Link"), "menu_link_create2": .asset("Link"),
        "menu_night_mode": .asset("NightMode"), "menu_premium_chatbot": .asset("Bots"), "menu_premium_clock": .asset("Time"),
        "menu_privacy_policy": .asset("Privacy"), "menu_quality_hd": .asset("QualityHd"), "menu_quote": .asset("Quote"),
        "menu_random": .symbol("shuffle"), "menu_reply": .asset("Reply"), "menu_select_quote": .asset("QuoteSelected"),
        "menu_sidebar": .symbol("sidebar.left"), "menu_sticker": .asset("Sticker"), "menu_storage_path": .asset("Folder"),
        "menu_tag_edit": .asset("TagEditName"), "menu_tag_filter": .asset("TagFilter"), "menu_tag_plus": .asset("Tag"),
        "menu_tag_rename": .asset("TagEditName"), "menu_verification": .symbol("checkmark.seal"), "menu_views_recent": .asset("Eye"),
        "mini_quote": .asset("Quote"), "msg2_animations": .symbol("sparkles"), "msg2_battery": .symbol("battery.100"),
        "msg2_call_earpiece": .asset("Call"), "msg2_chats_add": .symbol("plus.bubble"), "msg2_data": .symbol("internaldrive"),
        "msg2_devices": .symbol("laptopcomputer.and.iphone"), "msg2_help": .asset("Help"), "msg2_language": .asset("Globe"),
        "msg2_reactions2": .asset("Reactions"), "msg2_secret": .asset("Lock"), "msg_actions": .asset("More"), "msg_add": .asset("Add"),
        "msg_add_contact": .asset("AddUser"), "msg_add_file": .symbol("doc.badge.plus"), "msg_addbot": .asset("Bots"),
        "msg_admins": .symbol("shield"), "msg_align_center": .symbol("text.aligncenter"), "msg_allowspeak": .symbol("mic"),
        "msg_archive": .asset("Archive"), "msg_archive_hide": .asset("HideArchive"), "msg_arrow_down": .symbol("arrow.down"),
        "msg_arrow_forward": .symbol("chevron.right"), "msg_arrow_up": .symbol("arrow.up"), "msg_arrowright": .symbol("arrow.right"),
        "msg_audio": .symbol("waveform"), "msg_autodelete": .asset("Timer"), "msg_autodelete_1m": .asset("Timer"),
        "msg_autodelete_badge2": .asset("Timer"), "msg_background": .symbol("photo"), "msg_battery": .symbol("battery.100"),
        "msg_block": .asset("Ban"), "msg_block2": .asset("Ban"), "msg_blur": .symbol("drop"), "msg_blur_linear": .symbol("drop"),
        "msg_blur_radial": .symbol("drop"), "msg_border": .symbol("square.dashed"), "msg_bot": .asset("Bots"), "msg_bots": .asset("Bots"),
        "msg_brightness": .symbol("sun.max"), "msg_brightness_high": .symbol("sun.max"), "msg_brightness_low": .symbol("sun.min"),
        "msg_bug": .symbol("ladybug"), "msg_calendar": .asset("Calendar"), "msg_calendar2": .asset("Calendar"), "msg_call": .asset("Call"),
        "msg_calls": .asset("Call"), "msg_calls_minimize": .asset("Collapse"), "msg_camera": .asset("Camera"), "msg_cancel": .symbol("xmark.circle"),
        "msg_channel": .asset("Channels"), "msg_chat": .asset("Chats"), "msg_chats_add": .symbol("plus.bubble"), "msg_check": .asset("Check"),
        "msg_clear": .asset("Clear"), "msg_clear_history": .asset("ClearMessages"), "msg_clearcache": .asset("Clear"), "msg_clock": .asset("Time"),
        "msg_clock2": .asset("Time"), "msg_close": .symbol("xmark"), "msg_cmd": .symbol("terminal"), "msg_code": .asset("FormatCode"),
        "msg_color": .asset("Palette"), "msg_colors": .asset("Palette"), "msg_contact": .asset("User"),
        "msg_contact_check": .symbol("person.crop.circle.badge.checkmark"), "msg_contacts": .asset("User"), "msg_copy": .asset("Copy"),
        "msg_current_location": .symbol("location"), "msg_customize": .asset("Customize"), "msg_delete": .asset("Delete"),
        "msg_delete_auto": .asset("Timer"), "msg_devices": .symbol("laptopcomputer.and.iphone"), "msg_discuss": .asset("MessageBubble"),
        "msg_discussion": .asset("MessageBubble"), "msg_done": .asset("Check"), "msg_download": .asset("Download"),
        "msg_download_settings": .asset("Download"), "msg_edit": .asset("Edit"), "msg_effect": .symbol("sparkles"), "msg_emoji": .asset("Smile"),
        "msg_emoji_cat": .asset("Smile"), "msg_emoji_edit": .asset("Smile"), "msg_emoji_flags": .symbol("flag"),
        "msg_emoji_objects": .symbol("lightbulb"), "msg_emoji_question": .asset("Help"), "msg_emoji_recent": .asset("Time"),
        "msg_emoji_smiles": .asset("Smile"), "msg_error": .symbol("exclamationmark.circle"), "msg_fave": .asset("Fave"), "msg_favs": .asset("Fave"),
        "msg_file": .asset("File"), "msg_filled_data_messages": .asset("Message"), "msg_filled_data_music": .symbol("music.note"),
        "msg_filled_data_sent": .symbol("paperplane.fill"), "msg_filled_data_voice": .symbol("mic.fill"),
        "msg_filled_reactions": .asset("Reactions"), "msg_filter": .symbol("line.3.horizontal.decrease.circle"), "msg_flash": .symbol("bolt"),
        "msg_folder": .asset("Folder"), "msg_folders": .asset("Folder"), "msg_folders_groups": .asset("Folder"),
        "msg_folders_requests": .asset("Folder"), "msg_forward": .asset("Forward"), "msg_forward_replace": .asset("Replace"),
        "msg_gallery": .asset("Image"), "msg_game": .symbol("gamecontroller"), "msg_gif": .symbol("livephoto"), "msg_gift_premium": .asset("Gift"),
        "msg_go_up": .symbol("arrow.up"), "msg_group": .asset("Groups"), "msg_groups": .asset("Groups"), "msg_groups_create": .asset("Groups"),
        "msg_header": .asset("FormatHeading"), "msg_help": .asset("Help"), "msg_hide": .symbol("eye.slash"), "msg_info": .asset("Info"),
        "msg_info_filled": .symbol("info.circle.fill"), "msg_input": .symbol("keyboard"), "msg_instant_link": .asset("Link"),
        "msg_language": .asset("Globe"), "msg_leave": .asset("Logout"), "msg_limit_stories": .asset("Stories"), "msg_line": .symbol("line.diagonal"),
        "msg_link": .asset("Link"), "msg_link2": .asset("Link"), "msg_link_2": .asset("Link"), "msg_list": .asset("List"),
        "msg_location": .symbol("location"), "msg_lock": .asset("Lock"), "msg_log": .symbol("list.bullet.rectangle"),
        "msg_login": .symbol("arrow.right.square"), "msg_map": .symbol("map"), "msg_markread": .asset("MarkAsRead"),
        "msg_markunread": .asset("MarkAsUnread"), "msg_mask": .symbol("theatermasks"), "msg_media": .asset("Image"),
        "msg_media_doc2": .asset("File"), "msg_mention": .asset("Mention"), "msg_menu": .symbol("line.3.horizontal"),
        "msg_message": .asset("Message"), "msg_message_s": .asset("Message"), "msg_mic": .symbol("mic"), "msg_mini_bomb": .symbol("flame"),
        "msg_mini_customize": .asset("Customize"), "msg_more": .asset("More"), "msg_msgbubble3": .asset("MessageBubble"),
        "msg_music": .symbol("music.note"), "msg_mute": .asset("Muted"), "msg_mute_1h": .asset("Mute2d"), "msg_mute_period": .asset("Mute2d"),
        "msg_notifications": .symbol("bell"), "msg_online": .symbol("dot.radiowaves.left.and.right"),
        "msg_opacity": .symbol("circle.lefthalf.filled"), "msg_openin": .symbol("arrow.up.right.square"), "msg_openprofile": .asset("User"),
        "msg_palette": .asset("Palette"), "msg_paste": .symbol("doc.on.clipboard"), "msg_payment_card": .asset("Card"),
        "msg_payment_discount": .asset("PriceTag"), "msg_pen": .asset("Pencil"), "msg_permissions": .symbol("key"), "msg_persons": .asset("Groups"),
        "msg_photo": .asset("Image"), "msg_photo_blur": .symbol("drop"), "msg_photo_crop": .symbol("crop"), "msg_photo_cropfix": .symbol("crop"),
        "msg_photo_curve": .symbol("waveform.path.ecg"), "msg_photo_edit": .asset("Draw"), "msg_photo_rotate": .symbol("rotate.right"),
        "msg_photo_settings": .symbol("slider.horizontal.3"), "msg_photo_sticker": .asset("Sticker"), "msg_photo_text2": .asset("FormatText"),
        "msg_photo_text_framed": .asset("FormatText"), "msg_photo_text_framed3": .asset("FormatText"),
        "msg_photo_text_regular": .asset("FormatText"), "msg_photos": .asset("Image"), "msg_pin": .asset("Pin"), "msg_pin_code": .asset("Lock"),
        "msg_play": .asset("Play"), "msg_played": .asset("Play"), "msg_plugins": .symbol("puzzlepiece.extension"), "msg_power": .symbol("power"),
        "msg_premium_icons": .symbol("star"), "msg_premium_speed": .asset("Speed"), "msg_premium_voice": .symbol("mic"),
        "msg_privacy": .asset("Privacy"), "msg_quote": .asset("Quote"), "msg_reactions": .asset("Reactions"), "msg_recent": .asset("Time"),
        "msg_refresh": .asset("Reload"), "msg_reminders": .symbol("bell"), "msg_reorder": .asset("ReorderItems"), "msg_reply": .asset("Reply"),
        "msg_report": .asset("Report"), "msg_report_personal": .asset("ReportPersonal"), "msg_reset": .symbol("arrow.counterclockwise"),
        "msg_resize": .symbol("arrow.up.left.and.arrow.down.right"), "msg_retract": .asset("Collapse"), "msg_retry": .asset("Reload"),
        "msg_rotate": .symbol("rotate.right"), "msg_round": .symbol("video.circle"), "msg_satellite": .symbol("antenna.radiowaves.left.and.right"),
        "msg_save": .asset("Save"), "msg_saved": .symbol("bookmark"), "msg_saved_messages": .symbol("bookmark"), "msg_schedule": .asset("Schedule"),
        "msg_scheduled": .asset("Schedule"), "msg_screencast": .symbol("rectangle.on.rectangle"), "msg_search": .asset("Search"),
        "msg_secret": .asset("Lock"), "msg_select": .asset("Select"), "msg_select_between": .asset("SelectAll"), "msg_send": .symbol("paperplane"),
        "msg_sendfile": .asset("File"), "msg_settings": .asset("Settings"), "msg_share": .asset("Share"), "msg_shareout": .asset("Share"),
        "msg_smile": .asset("Smile"), "msg_smile2": .asset("Smile"), "msg_sort": .symbol("arrow.up.arrow.down"),
        "msg_speak": .symbol("speaker.wave.2"), "msg_speaker": .symbol("speaker.wave.2"), "msg_speed": .asset("Speed"),
        "msg_speed_superfast": .asset("Speed"), "msg_speed_veryfast": .asset("Speed"), "msg_spellcheck": .symbol("textformat.abc"),
        "msg_spoiler": .symbol("eye.slash"), "msg_stats": .asset("Statistics"), "msg_sticker": .asset("Sticker"), "msg_stop": .symbol("stop"),
        "msg_storage": .symbol("internaldrive"), "msg_stories_archive": .asset("StoryArchive"), "msg_stories_stealth": .symbol("eye.slash"),
        "msg_stories_timer": .asset("Timer"), "msg_stories_views": .asset("Eye"), "msg_style": .asset("Palette"),
        "msg_switch": .symbol("arrow.left.arrow.right"), "msg_tag": .asset("Tag"), "msg_text": .asset("FormatText"),
        "msg_text_check": .symbol("text.badge.checkmark"), "msg_text_outlined": .asset("FormatText"), "msg_theme": .asset("ApplyTheme"),
        "msg_time": .asset("Time"), "msg_timer": .asset("Timer"), "msg_to_beginning": .symbol("arrow.up.to.line"), "msg_ton": .asset("Ton"),
        "msg_tone": .symbol("music.note"), "msg_topic": .symbol("bubble.left.and.bubble.right"), "msg_topic_create": .symbol("plus.bubble"),
        "msg_topic_restart": .asset("Reload"), "msg_topics": .symbol("bubble.left.and.bubble.right"), "msg_touchid": .asset("TouchId"),
        "msg_translate": .asset("Translate"), "msg_unarchive": .asset("Unarchive"), "msg_unfave": .asset("Unfave"), "msg_unmute": .asset("Unmute"),
        "msg_unpin": .asset("Unpin"), "msg_update": .symbol("arrow.triangle.2.circlepath"), "msg_user": .asset("User"),
        "msg_user_remove": .symbol("person.badge.minus"), "msg_users": .asset("Groups"), "msg_video": .symbol("video"),
        "msg_videocall": .asset("VideoCall"), "msg_view_file": .asset("File"), "msg_viewchats": .asset("Chats"),
        "msg_viewintopic": .asset("GoToMessage"), "msg_views": .asset("Eye"), "msg_visibility": .asset("Eye"), "msg_voice": .symbol("mic"),
        "msg_voice_headphones": .symbol("headphones"), "msg_voice_pip": .symbol("pip"), "msg_voice_unmute": .symbol("mic"),
        "msg_voice_unmuted": .symbol("mic"), "msg_voicechat": .asset("VoiceChat"), "msg_voicechat2": .asset("VoiceChat"),
        "msg_warning": .symbol("exclamationmark.triangle"), "msg_weather": .symbol("cloud.sun"), "msg_working": .asset("Time"),
        "msg_zoom_in": .asset("ZoomIn"), "msg_zoomin": .asset("ZoomIn"), "msg_zoomout": .asset("ZoomOut"), "msg_zoomout_stats": .asset("ZoomOut"),
        "notification": .symbol("bell"), "notifications_on": .symbol("bell"), "notifications_settings": .symbol("bell.badge"),
        "outline_header_search": .asset("Search"), "outline_lock": .asset("Lock"), "outline_menu": .symbol("line.3.horizontal"),
        "outline_notifications_off": .symbol("bell.slash"), "outline_visibility_off": .symbol("eye.slash"), "pip_video_expand": .asset("Expand"),
        "player": .asset("Play"), "player_cover_placeholder": .symbol("music.note"), "popup_fixed_alert": .symbol("exclamationmark.triangle"),
        "popup_fixed_alert2": .symbol("exclamationmark.triangle"), "popup_fixed_alert3": .symbol("exclamationmark.triangle"),
        "profile_discuss": .asset("MessageBubble"), "profile_newmsg": .asset("Message"), "proxy_check": .asset("Check"),
        "send_plane": .symbol("paperplane"), "settings_account": .asset("User"), "settings_sounds": .symbol("speaker.wave.2"),
        "star_small_inner": .symbol("star"), "tabs_reorder": .asset("ReorderItems"), "toggle_plugin": .symbol("power"), "ton_icon": .asset("Ton"),
    ]

    /// Android Lottie resources bulletins use, as still SF Symbols.
    static let animations: [String: AyuPluginIcon] = [
        "chats_infotip": .symbol("info.circle"), "check": .symbol("checkmark.circle"), "contact_check": .symbol("checkmark.circle"),
        "copy": .symbol("doc.on.doc"), "delete": .symbol("trash"), "done": .symbol("checkmark.circle"), "email_check_inbox": .symbol("envelope"),
        "error": .symbol("exclamationmark.triangle"), "forward": .symbol("arrowshape.turn.up.right"), "ic_delete": .symbol("trash"),
        "ic_download": .symbol("arrow.down.circle"), "ic_pin": .symbol("pin"), "ic_save_to_gallery": .symbol("square.and.arrow.down"),
        "ic_unpin": .symbol("pin.slash"), "info": .symbol("info.circle"), "saved_messages": .symbol("bookmark"),
        "sound_on": .symbol("speaker.wave.2"), "star_premium_2": .symbol("star"), "success": .symbol("checkmark.circle"),
        "voip_invite": .symbol("link"),
    ]
}
