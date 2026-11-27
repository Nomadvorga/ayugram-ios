import Foundation
internal import TelegramApi

/// Builds boxed TL for the plugin bridge from plain values, through the generated `Api`
/// constructors, so the layout is the layer's by construction.
///
/// Every flag word is computed here from the values that are present. The serializer aborts the
/// process on a flag bit without its value, so no caller passes a flag word in.
///
/// The file depends on TelegramApi and Foundation only: `Build/run_telegram_tl_tests.py` of the
/// plugin bridge compiles it for macOS and checks its output with the SDK's TL parser.
enum AyuPluginTL {
    static func serialize<T: TLObjectBacked>(_ object: T) -> Data {
        let buffer = Buffer()
        object.serialize(buffer, true)
        return buffer.makeData()
    }

    private static func bit(_ condition: Bool, _ index: Int32) -> Int32 {
        return condition ? (1 << index) : 0
    }

    private static func some<T>(_ value: T?, _ index: Int32) -> Int32 {
        return value != nil ? (1 << index) : 0
    }

    // MARK: Peers

    enum PeerReference: Equatable {
        case user(Int64)
        case chat(Int64)
        case channel(Int64)

        var api: Api.Peer {
            switch self {
            case let .user(id): return .peerUser(.init(userId: id))
            case let .chat(id): return .peerChat(.init(chatId: id))
            case let .channel(id): return .peerChannel(.init(channelId: id))
            }
        }
    }

    struct AvatarPhoto {
        var photoId: Int64
        var datacenterId: Int32
        var strippedThumb: Data?
        var hasVideo = false
        var isPersonal = false
    }

    struct Username {
        var username: String
        var isEditable = false
        var isActive = false
    }

    struct Color {
        var color: Int32?
        var backgroundEmojiId: Int64?
    }

    struct EmojiStatus {
        var documentId: Int64
        var until: Int32?
    }

    struct Restriction {
        var platform: String
        var reason: String
        var text: String
    }

    struct BannedRights {
        /// The stored flags, in the bit positions of `chatBannedRights`.
        var flags: Int32
        var untilDate: Int32
    }

    enum UserStatus: Equatable {
        case empty
        case online(expires: Int32)
        case offline(wasOnline: Int32)
        case recently
        case lastWeek
        case lastMonth
    }

    private static func usernames(_ values: [Username]) -> [Api.Username]? {
        guard !values.isEmpty else {
            return nil
        }
        return values.map { .username(.init(flags: bit($0.isEditable, 0) | bit($0.isActive, 1), username: $0.username)) }
    }

    private static func restrictions(_ values: [Restriction]) -> [Api.RestrictionReason]? {
        guard !values.isEmpty else {
            return nil
        }
        return values.map { .restrictionReason(.init(platform: $0.platform, reason: $0.reason, text: $0.text)) }
    }

    private static func color(_ value: Color?) -> Api.PeerColor? {
        guard let value else {
            return nil
        }
        return .peerColor(.init(flags: some(value.color, 0) | some(value.backgroundEmojiId, 1), color: value.color, backgroundEmojiId: value.backgroundEmojiId))
    }

    private static func emojiStatus(_ value: EmojiStatus?) -> Api.EmojiStatus? {
        guard let value else {
            return nil
        }
        return .emojiStatus(.init(flags: some(value.until, 0), documentId: value.documentId, until: value.until))
    }

    private static func chatPhoto(_ value: AvatarPhoto?) -> Api.ChatPhoto {
        guard let value else {
            return .chatPhotoEmpty
        }
        return .chatPhoto(.init(flags: bit(value.hasVideo, 0) | some(value.strippedThumb, 1), photoId: value.photoId, strippedThumb: value.strippedThumb.map { Buffer(data: $0) }, dcId: value.datacenterId))
    }

    static func adminRights(flags: Int32) -> Api.ChatAdminRights {
        return .chatAdminRights(.init(flags: flags))
    }

    /// The app stores the granular send rights only. The two aggregate bits Android reads,
    /// `send_messages` (1) and `send_media` (2), are set when every right they cover is banned.
    static func bannedRightsFlags(stored: Int32) -> Int32 {
        let media: Int32 = (1 << 19) | (1 << 20) | (1 << 21) | (1 << 22) | (1 << 23) | (1 << 24)
        let plain: Int32 = 1 << 25
        var flags = stored & ~((1 << 1) | (1 << 2))
        if stored & media == media {
            flags |= 1 << 2
            if stored & plain != 0 {
                flags |= 1 << 1
            }
        }
        return flags
    }

    static func bannedRights(_ value: BannedRights) -> Api.ChatBannedRights {
        return .chatBannedRights(.init(flags: bannedRightsFlags(stored: value.flags), untilDate: value.untilDate))
    }

    // MARK: User

    struct User {
        var id: Int64
        var accessHash: Int64?
        /// The access hash is the public one of a `min` user.
        var isMin = false
        var isSelf = false
        var isContact = false
        var isMutualContact = false
        var isDeleted = false
        var isBot = false
        var botChatHistory = false
        var botNoChats = false
        var botInlineGeo = false
        var botAttachMenu = false
        var botCanEdit = false
        var botBusiness = false
        var botHasMainApp = false
        var botForumView = false
        var botForumCanManageTopics = false
        var botCanManageBots = false
        var botGuestChat = false
        var botGuard = false
        var botForumSidebar = false
        var isVerified = false
        var isSupport = false
        var isScam = false
        var isFake = false
        var isPremium = false
        var isCloseFriend = false
        var storiesHidden = false
        var contactRequirePremium = false
        var firstName: String?
        var lastName: String?
        var username: String?
        var phone: String?
        var photo: AvatarPhoto?
        var status: UserStatus?
        var restrictions: [Restriction] = []
        var botInlinePlaceholder: String?
        var emojiStatus: EmojiStatus?
        var usernames: [Username] = []
        var color: Color?
        var profileColor: Color?
        var botActiveUsers: Int32?
        var botVerificationIcon: Int64?
        var linkedCommunityId: Int64?
    }

    static func user(_ user: User) -> Api.User {
        let photo: Api.UserProfilePhoto? = user.photo.map { .userProfilePhoto(.init(flags: bit($0.hasVideo, 0) | some($0.strippedThumb, 1) | bit($0.isPersonal, 2), photoId: $0.photoId, strippedThumb: $0.strippedThumb.map { Buffer(data: $0) }, dcId: $0.datacenterId)) }
        let status: Api.UserStatus? = user.status.map { status in
            switch status {
            case .empty: return .userStatusEmpty
            case let .online(expires): return .userStatusOnline(.init(expires: expires))
            case let .offline(wasOnline): return .userStatusOffline(.init(wasOnline: wasOnline))
            case .recently: return .userStatusRecently(.init(flags: 0))
            case .lastWeek: return .userStatusLastWeek(.init(flags: 0))
            case .lastMonth: return .userStatusLastMonth(.init(flags: 0))
            }
        }
        let restrictionReason = restrictions(user.restrictions)
        let usernameList = usernames(user.usernames)
        let nameColor = color(user.color)
        let profileColor = color(user.profileColor)
        let emoji = emojiStatus(user.emojiStatus)
        // The cache does not keep the version of a bot's commands; the field is mandatory for a bot.
        let botInfoVersion: Int32? = user.isBot ? 0 : nil
        let botInlinePlaceholder = user.isBot ? user.botInlinePlaceholder : nil

        var flags: Int32 = some(user.accessHash, 0) | some(user.firstName, 1) | some(user.lastName, 2) | some(user.username, 3)
        flags |= some(user.phone, 4) | some(photo, 5) | some(status, 6)
        flags |= bit(user.isSelf, 10) | bit(user.isContact, 11) | bit(user.isMutualContact, 12) | bit(user.isDeleted, 13)
        flags |= bit(user.isBot, 14) | bit(user.isBot && user.botChatHistory, 15) | bit(user.isBot && user.botNoChats, 16)
        flags |= bit(user.isVerified, 17) | some(restrictionReason, 18) | some(botInlinePlaceholder, 19)
        flags |= bit(user.isMin && user.accessHash != nil, 20) | bit(user.isBot && user.botInlineGeo, 21) | bit(user.isSupport, 23)
        flags |= bit(user.isScam, 24) | bit(user.isFake, 26) | bit(user.isBot && user.botAttachMenu, 27) | bit(user.isPremium, 28)
        flags |= some(emoji, 30)

        var flags2: Int32 = some(usernameList, 0) | bit(user.isBot && user.botCanEdit, 1) | bit(user.isCloseFriend, 2) | bit(user.storiesHidden, 3)
        flags2 |= some(nameColor, 8) | some(profileColor, 9) | bit(user.contactRequirePremium, 10) | bit(user.isBot && user.botBusiness, 11)
        flags2 |= some(user.botActiveUsers, 12) | bit(user.isBot && user.botHasMainApp, 13) | some(user.botVerificationIcon, 14)
        flags2 |= bit(user.isBot && user.botForumView, 16) | bit(user.isBot && user.botForumCanManageTopics, 17)
        flags2 |= bit(user.isBot && user.botCanManageBots, 18) | bit(user.isBot && user.botGuestChat, 19) | bit(user.isBot && user.botGuard, 20)
        flags2 |= some(user.linkedCommunityId, 21) | bit(user.isBot && user.botForumSidebar, 22)

        return .user(.init(flags: flags, flags2: flags2, id: user.id, accessHash: user.accessHash, firstName: user.firstName, lastName: user.lastName, username: user.username, phone: user.phone, photo: photo, status: status, botInfoVersion: botInfoVersion, restrictionReason: restrictionReason, botInlinePlaceholder: botInlinePlaceholder, langCode: nil, emojiStatus: emoji, usernames: usernameList, storiesMaxId: nil, color: nameColor, profileColor: profileColor, botActiveUsers: user.botActiveUsers, botVerificationIcon: user.botVerificationIcon, sendPaidMessagesStars: nil, linkedCommunityId: user.linkedCommunityId))
    }

    // MARK: Chats

    struct Group {
        var id: Int64
        var title: String
        var photo: AvatarPhoto?
        var participantsCount: Int32
        var date: Int32
        var version: Int32
        var isCreator = false
        var hasLeft = false
        /// Removed from the group: Android's `chatForbidden`.
        var isForbidden = false
        var isDeactivated = false
        var callActive = false
        var callNotEmpty = false
        var noForwards = false
        var migratedTo: (channelId: Int64, accessHash: Int64)?
        var adminRights: Int32?
        var defaultBannedRights: BannedRights?
    }

    static func group(_ group: Group) -> Api.Chat {
        if group.isForbidden {
            return .chatForbidden(.init(id: group.id, title: group.title))
        }
        let migratedTo: Api.InputChannel? = group.migratedTo.map { .inputChannel(.init(channelId: $0.channelId, accessHash: $0.accessHash)) }
        let adminRights = group.adminRights.map { self.adminRights(flags: $0) }
        let defaultBannedRights = group.defaultBannedRights.map { self.bannedRights($0) }
        var flags: Int32 = bit(group.isCreator, 0) | bit(group.hasLeft, 2) | bit(group.isDeactivated, 5) | some(migratedTo, 6)
        flags |= some(adminRights, 14) | some(defaultBannedRights, 18) | bit(group.callActive, 23) | bit(group.callNotEmpty, 24) | bit(group.noForwards, 25)
        return .chat(.init(flags: flags, id: group.id, title: group.title, photo: chatPhoto(group.photo), participantsCount: group.participantsCount, date: group.date, version: group.version, migratedTo: migratedTo, adminRights: adminRights, defaultBannedRights: defaultBannedRights))
    }

    struct Channel {
        var id: Int64
        var accessHash: Int64?
        var isMin = false
        var title: String
        var username: String?
        var photo: AvatarPhoto?
        var date: Int32
        var isCreator = false
        var hasLeft = false
        /// Banned from the channel: Android's `channelForbidden`, which needs the access hash.
        var isForbidden = false
        var isBroadcast = false
        var isMegagroup = false
        var isVerified = false
        var signatures = false
        var isScam = false
        var hasLink = false
        var hasGeo = false
        var slowmodeEnabled = false
        var callActive = false
        var callNotEmpty = false
        var isFake = false
        var isGigagroup = false
        var noForwards = false
        var joinToSend = false
        var joinRequest = false
        var isForum = false
        var storiesHidden = false
        var signatureProfiles = false
        var autotranslation = false
        var broadcastMessagesAllowed = false
        var isMonoforum = false
        var forumTabs = false
        var inNews = false
        var forumSidebar = false
        var restrictions: [Restriction] = []
        var adminRights: Int32?
        var bannedRights: BannedRights?
        var defaultBannedRights: BannedRights?
        var participantsCount: Int32?
        var usernames: [Username] = []
        var color: Color?
        var profileColor: Color?
        var emojiStatus: EmojiStatus?
        var level: Int32?
        var subscriptionUntilDate: Int32?
        var botVerificationIcon: Int64?
        var sendPaidMessagesStars: Int64?
        var linkedMonoforumId: Int64?
        var linkedCommunityId: Int64?
    }

    static func channel(_ channel: Channel) -> Api.Chat {
        if channel.isForbidden, let accessHash = channel.accessHash {
            let flags: Int32 = bit(channel.isBroadcast, 5) | bit(channel.isMegagroup, 8) | bit(channel.isMonoforum, 10) | some(channel.bannedRights, 16)
            return .channelForbidden(.init(flags: flags, id: channel.id, accessHash: accessHash, title: channel.title, untilDate: channel.bannedRights?.untilDate))
        }
        let restrictionReason = restrictions(channel.restrictions)
        let adminRights = channel.adminRights.map { self.adminRights(flags: $0) }
        let bannedRights = channel.bannedRights.map { self.bannedRights($0) }
        let defaultBannedRights = channel.defaultBannedRights.map { self.bannedRights($0) }
        let usernameList = usernames(channel.usernames)
        let nameColor = color(channel.color)
        let profileColor = color(channel.profileColor)
        let emoji = emojiStatus(channel.emojiStatus)

        var flags: Int32 = bit(channel.isCreator, 0) | bit(channel.hasLeft || channel.isForbidden, 2) | bit(channel.isBroadcast, 5) | some(channel.username, 6)
        flags |= bit(channel.isVerified, 7) | bit(channel.isMegagroup, 8) | some(restrictionReason, 9) | bit(channel.signatures, 11)
        flags |= bit(channel.isMin && channel.accessHash != nil, 12) | some(channel.accessHash, 13) | some(adminRights, 14) | some(bannedRights, 15)
        flags |= some(channel.participantsCount, 17) | some(defaultBannedRights, 18) | bit(channel.isScam, 19) | bit(channel.hasLink, 20)
        flags |= bit(channel.hasGeo, 21) | bit(channel.slowmodeEnabled, 22) | bit(channel.callActive, 23) | bit(channel.callNotEmpty, 24)
        flags |= bit(channel.isFake, 25) | bit(channel.isGigagroup, 26) | bit(channel.noForwards, 27) | bit(channel.joinToSend, 28)
        flags |= bit(channel.joinRequest, 29) | bit(channel.isForum, 30)

        var flags2: Int32 = some(usernameList, 0) | bit(channel.storiesHidden, 1) | some(nameColor, 7) | some(profileColor, 8) | some(emoji, 9)
        flags2 |= some(channel.level, 10) | some(channel.subscriptionUntilDate, 11) | bit(channel.signatureProfiles, 12)
        flags2 |= some(channel.botVerificationIcon, 13) | some(channel.sendPaidMessagesStars, 14) | bit(channel.autotranslation, 15)
        flags2 |= bit(channel.broadcastMessagesAllowed, 16) | bit(channel.isMonoforum, 17) | some(channel.linkedMonoforumId, 18)
        flags2 |= bit(channel.forumTabs, 19) | some(channel.linkedCommunityId, 20) | bit(channel.inNews, 21) | bit(channel.forumSidebar, 23)

        return .channel(.init(flags: flags, flags2: flags2, id: channel.id, accessHash: channel.accessHash, title: channel.title, username: channel.username, photo: chatPhoto(channel.photo), date: channel.date, restrictionReason: restrictionReason, adminRights: adminRights, bannedRights: bannedRights, defaultBannedRights: defaultBannedRights, participantsCount: channel.participantsCount, usernames: usernameList, storiesMaxId: nil, color: nameColor, profileColor: profileColor, emojiStatus: emoji, level: channel.level, subscriptionUntilDate: channel.subscriptionUntilDate, botVerificationIcon: channel.botVerificationIcon, sendPaidMessagesStars: channel.sendPaidMessagesStars, linkedMonoforumId: channel.linkedMonoforumId, linkedCommunityId: channel.linkedCommunityId, pinnedMsgId: nil))
    }

    // MARK: Media

    enum PhotoSize {
        case stripped(Data)
        case plain(type: String, width: Int32, height: Int32, size: Int32)
        case progressive(type: String, width: Int32, height: Int32, sizes: [Int32])

        var api: Api.PhotoSize {
            switch self {
            case let .stripped(data): return .photoStrippedSize(.init(type: "i", bytes: Buffer(data: data)))
            case let .plain(type, width, height, size): return .photoSize(.init(type: type, w: width, h: height, size: size))
            case let .progressive(type, width, height, sizes): return .photoSizeProgressive(.init(type: type, w: width, h: height, sizes: sizes))
            }
        }
    }

    struct Photo {
        var id: Int64
        var accessHash: Int64
        var fileReference: Data
        var datacenterId: Int32
        var sizes: [PhotoSize]
        var hasStickers = false
    }

    static func photo(_ photo: Photo) -> Api.Photo {
        return .photo(.init(flags: bit(photo.hasStickers, 0), id: photo.id, accessHash: photo.accessHash, fileReference: Buffer(data: photo.fileReference), date: 0, sizes: photo.sizes.map { $0.api }, videoSizes: nil, dcId: photo.datacenterId))
    }

    struct Document {
        var id: Int64
        var accessHash: Int64
        var fileReference: Data
        var datacenterId: Int32
        var mimeType: String
        var size: Int64
        var thumbs: [PhotoSize] = []
        /// Built by the caller with the app's own attribute converter.
        var attributes: [Api.DocumentAttribute]
    }

    static func document(_ document: Document) -> Api.Document {
        let thumbs: [Api.PhotoSize]? = document.thumbs.isEmpty ? nil : document.thumbs.map { $0.api }
        return .document(.init(flags: some(thumbs, 0), id: document.id, accessHash: document.accessHash, fileReference: Buffer(data: document.fileReference), date: 0, mimeType: document.mimeType, size: document.size, thumbs: thumbs, videoThumbs: nil, dcId: document.datacenterId, attributes: document.attributes))
    }

    static func photoMedia(_ photo: Api.Photo, hasSpoiler: Bool, ttlSeconds: Int32?) -> Api.MessageMedia {
        return .messageMediaPhoto(.init(flags: (1 << 0) | some(ttlSeconds, 2) | bit(hasSpoiler, 3), photo: photo, ttlSeconds: ttlSeconds, video: nil))
    }

    static func documentMedia(_ document: Api.Document, hasSpoiler: Bool, noPremium: Bool, isVideo: Bool, isRound: Bool, isVoice: Bool, ttlSeconds: Int32?) -> Api.MessageMedia {
        var flags: Int32 = (1 << 0) | some(ttlSeconds, 2) | bit(noPremium, 3) | bit(hasSpoiler, 4)
        flags |= bit(isVideo, 6) | bit(isRound, 7) | bit(isVoice, 8)
        return .messageMediaDocument(.init(flags: flags, document: document, altDocuments: nil, videoCover: nil, videoTimestamp: nil, ttlSeconds: ttlSeconds))
    }

    /// A link preview whose content is not rebuilt: the message stays a text message with a
    /// preview Android shows as unavailable.
    static func emptyWebPageMedia(id: Int64, url: String?) -> Api.MessageMedia {
        return .messageMediaWebPage(.init(flags: 0, webpage: .webPageEmpty(.init(flags: some(url, 0), id: id, url: url))))
    }

    /// Media the app stores in a form these builders do not rebuild.
    static var unsupportedMedia: Api.MessageMedia {
        return .messageMediaUnsupported
    }

    // MARK: Messages

    struct ForwardHeader {
        var from: PeerReference?
        var fromName: String?
        var date: Int32
        var channelPost: Int32?
        var postAuthor: String?
        var savedFrom: (peer: PeerReference, messageId: Int32)?
        var psaType: String?
        var isImported = false
    }

    static func forwardHeader(_ header: ForwardHeader) -> Api.MessageFwdHeader {
        var flags: Int32 = some(header.from, 0) | some(header.channelPost, 2) | some(header.postAuthor, 3) | some(header.savedFrom, 4)
        flags |= some(header.fromName, 5) | some(header.psaType, 6) | bit(header.isImported, 7)
        return .messageFwdHeader(.init(flags: flags, fromId: header.from?.api, fromName: header.fromName, date: header.date, channelPost: header.channelPost, postAuthor: header.postAuthor, savedFromPeer: header.savedFrom?.peer.api, savedFromMsgId: header.savedFrom?.messageId, savedFromId: nil, savedFromName: nil, savedDate: nil, psaType: header.psaType))
    }

    struct ReplyHeader {
        var messageId: Int32?
        /// Set when the replied message is in another chat.
        var peer: PeerReference?
        var topMessageId: Int32?
        var isForumTopic = false
        var quoteText: String?
        var quoteEntities: [Api.MessageEntity]?
        var quoteOffset: Int32?
    }

    static func replyHeader(_ header: ReplyHeader) -> Api.MessageReplyHeader {
        let quoteEntities = header.quoteText == nil ? nil : header.quoteEntities.flatMap { $0.isEmpty ? nil : $0 }
        let quoteOffset = header.quoteText == nil ? nil : header.quoteOffset
        var flags: Int32 = some(header.peer, 0) | some(header.topMessageId, 1) | bit(header.isForumTopic, 3) | some(header.messageId, 4)
        flags |= some(header.quoteText, 6) | some(quoteEntities, 7) | bit(header.quoteText != nil, 9) | some(quoteOffset, 10)
        return .messageReplyHeader(.init(flags: flags, replyToMsgId: header.messageId, replyToPeerId: header.peer?.api, replyFrom: nil, replyMedia: nil, replyToTopId: header.topMessageId, quoteText: header.quoteText, quoteEntities: quoteEntities, quoteOffset: quoteOffset, todoItemId: nil, pollOption: nil, quoteRich: nil))
    }

    struct Message {
        var id: Int32
        var peer: PeerReference
        var from: PeerReference?
        var date: Int32
        var text: String
        var isOut = false
        var isMentioned = false
        var isMediaUnread = false
        var isSilent = false
        var isPost = false
        var isFromScheduled = false
        var editHidden = false
        var isPinned = false
        var noForwards = false
        var invertMedia = false
        var savedPeer: PeerReference?
        var forward: Api.MessageFwdHeader?
        var viaBotId: Int64?
        var reply: Api.MessageReplyHeader?
        var media: Api.MessageMedia?
        var entities: [Api.MessageEntity] = []
        /// `views` and `forwards` share one flag: both are sent when either is known.
        var views: Int32?
        var forwards: Int32?
        var editDate: Int32?
        var postAuthor: String?
        var groupedId: Int64?
        var ttlPeriod: Int32?
        var effect: Int64?
    }

    static func message(_ message: Message) -> Api.Message {
        let entities: [Api.MessageEntity]? = message.entities.isEmpty ? nil : message.entities
        let hasCounters = message.views != nil || message.forwards != nil
        let views: Int32? = hasCounters ? (message.views ?? 0) : nil
        let forwards: Int32? = hasCounters ? (message.forwards ?? 0) : nil

        var flags: Int32 = bit(message.isOut, 1) | some(message.forward, 2) | some(message.reply, 3) | bit(message.isMentioned, 4)
        flags |= bit(message.isMediaUnread, 5) | some(entities, 7) | some(message.from, 8) | some(message.media, 9)
        flags |= bit(hasCounters, 10) | some(message.viaBotId, 11) | bit(message.isSilent, 13) | bit(message.isPost, 14)
        flags |= some(message.editDate, 15) | some(message.postAuthor, 16) | some(message.groupedId, 17) | bit(message.isFromScheduled, 18)
        flags |= bit(message.editHidden, 21) | bit(message.isPinned, 24) | some(message.ttlPeriod, 25) | bit(message.noForwards, 26)
        flags |= bit(message.invertMedia, 27) | some(message.savedPeer, 28)
        let flags2: Int32 = some(message.effect, 2)

        return .message(.init(flags: flags, flags2: flags2, id: message.id, fromId: message.from?.api, fromBoostsApplied: nil, fromRank: nil, peerId: message.peer.api, savedPeerId: message.savedPeer?.api, fwdFrom: message.forward, viaBotId: message.viaBotId, viaBusinessBotId: nil, guestchatViaFrom: nil, replyTo: message.reply, date: message.date, message: message.text, media: message.media, replyMarkup: nil, entities: entities, views: views, forwards: forwards, replies: nil, editDate: message.editDate, postAuthor: message.postAuthor, groupedId: message.groupedId, reactions: nil, restrictionReason: nil, ttlPeriod: message.ttlPeriod, quickReplyShortcutId: nil, effect: message.effect, factcheck: nil, reportDeliveryUntilDate: nil, paidMessageStars: nil, suggestedPost: nil, scheduleRepeatPeriod: nil, summaryFromLanguage: nil, richMessage: nil))
    }

    // MARK: Full peers

    struct NotifySettings {
        /// Nil for the account's default.
        var showPreviews: Bool?
        /// Nil for the account's default, 0 for explicitly unmuted.
        var muteUntil: Int32?
    }

    static func notifySettings(_ settings: NotifySettings) -> Api.PeerNotifySettings {
        let showPreviews: Api.Bool? = settings.showPreviews.map { $0 ? .boolTrue : .boolFalse }
        return .peerNotifySettings(.init(flags: some(showPreviews, 0) | some(settings.muteUntil, 2), showPreviews: showPreviews, silent: nil, muteUntil: settings.muteUntil, iosSound: nil, androidSound: nil, otherSound: nil, storiesMuted: nil, storiesHideSender: nil, storiesIosSound: nil, storiesAndroidSound: nil, storiesOtherSound: nil))
    }

    struct PeerSettings {
        var reportSpam = false
        var addContact = false
        var blockContact = false
        var shareContact = false
        var needContactsException = false
        var autoarchived = false
        var inviteMembers = false
        var geoDistance: Int32?
    }

    static func peerSettings(_ settings: PeerSettings) -> Api.PeerSettings {
        var flags: Int32 = bit(settings.reportSpam, 0) | bit(settings.addContact, 1) | bit(settings.blockContact, 2) | bit(settings.shareContact, 3)
        flags |= bit(settings.needContactsException, 4) | some(settings.geoDistance, 6) | bit(settings.autoarchived, 7) | bit(settings.inviteMembers, 8)
        return .peerSettings(.init(flags: flags, geoDistance: settings.geoDistance, requestChatTitle: nil, requestChatDate: nil, businessBotId: nil, businessBotManageUrl: nil, chargePaidMessageStars: nil, registrationMonth: nil, phoneCountry: nil, nameChangeDate: nil, photoChangeDate: nil))
    }

    struct UserFull {
        var id: Int64
        var about: String?
        var settings = PeerSettings()
        var profilePhoto: Api.Photo?
        var personalPhoto: Api.Photo?
        var fallbackPhoto: Api.Photo?
        var notifySettings = NotifySettings()
        var pinnedMessageId: Int32?
        var commonChatsCount: Int32 = 0
        var ttlPeriod: Int32?
        var isBlocked = false
        var phoneCallsAvailable = false
        var phoneCallsPrivate = false
        var canPinMessage = false
        var hasScheduled = false
        var videoCallsAvailable = false
        var voiceMessagesForbidden = false
        var translationsDisabled = false
        var readDatesPrivate = false
        var contactRequirePremium = false
    }

    static func userFull(_ user: UserFull) -> Api.UserFull {
        var flags: Int32 = bit(user.isBlocked, 0) | some(user.about, 1) | some(user.profilePhoto, 2) | bit(user.phoneCallsAvailable, 4)
        flags |= bit(user.phoneCallsPrivate, 5) | some(user.pinnedMessageId, 6) | bit(user.canPinMessage, 7) | bit(user.hasScheduled, 12)
        flags |= bit(user.videoCallsAvailable, 13) | some(user.ttlPeriod, 14) | bit(user.voiceMessagesForbidden, 20) | some(user.personalPhoto, 21)
        flags |= some(user.fallbackPhoto, 22) | bit(user.translationsDisabled, 23) | bit(user.contactRequirePremium, 29) | bit(user.readDatesPrivate, 30)
        return .userFull(.init(flags: flags, flags2: 0, id: user.id, about: user.about, settings: peerSettings(user.settings), personalPhoto: user.personalPhoto, profilePhoto: user.profilePhoto, fallbackPhoto: user.fallbackPhoto, notifySettings: notifySettings(user.notifySettings), botInfo: nil, pinnedMsgId: user.pinnedMessageId, commonChatsCount: user.commonChatsCount, folderId: nil, ttlPeriod: user.ttlPeriod, theme: nil, privateForwardName: nil, botGroupAdminRights: nil, botBroadcastAdminRights: nil, wallpaper: nil, stories: nil, businessWorkHours: nil, businessLocation: nil, businessGreetingMessage: nil, businessAwayMessage: nil, businessIntro: nil, birthday: nil, personalChannelId: nil, personalChannelMessage: nil, stargiftsCount: nil, starrefProgram: nil, botVerification: nil, sendPaidMessagesStars: nil, disallowedGifts: nil, starsRating: nil, starsMyPendingRating: nil, starsMyPendingRatingDate: nil, mainTab: nil, savedMusic: nil, note: nil, botManagerId: nil, walletCard: nil, shareTheme: nil))
    }

    enum Participant {
        case member(userId: Int64, inviterId: Int64, date: Int32, rank: String?)
        case creator(userId: Int64, rank: String?)
        case admin(userId: Int64, inviterId: Int64, date: Int32, rank: String?)

        var api: Api.ChatParticipant {
            switch self {
            case let .member(userId, inviterId, date, rank): return .chatParticipant(.init(flags: some(rank, 0), userId: userId, inviterId: inviterId, date: date, rank: rank))
            case let .creator(userId, rank): return .chatParticipantCreator(.init(flags: some(rank, 0), userId: userId, rank: rank))
            case let .admin(userId, inviterId, date, rank): return .chatParticipantAdmin(.init(flags: some(rank, 0), userId: userId, inviterId: inviterId, date: date, rank: rank))
            }
        }
    }

    struct GroupFull {
        var id: Int64
        var about: String
        /// Nil when the member list is not cached: Android's `chatParticipantsForbidden`.
        var participants: [Participant]?
        var participantsVersion: Int32 = 0
        var chatPhoto: Api.Photo?
        var notifySettings = NotifySettings()
        var pinnedMessageId: Int32?
        var ttlPeriod: Int32?
        var hasScheduled = false
    }

    static func groupFull(_ group: GroupFull) -> Api.ChatFull {
        let participants: Api.ChatParticipants
        if let list = group.participants {
            participants = .chatParticipants(.init(chatId: group.id, participants: list.map { $0.api }, version: group.participantsVersion))
        } else {
            participants = .chatParticipantsForbidden(.init(flags: 0, chatId: group.id, selfParticipant: nil))
        }
        let flags: Int32 = some(group.chatPhoto, 2) | some(group.pinnedMessageId, 6) | bit(group.hasScheduled, 8) | some(group.ttlPeriod, 14)
        return .chatFull(.init(flags: flags, id: group.id, about: group.about, participants: participants, chatPhoto: group.chatPhoto, notifySettings: notifySettings(group.notifySettings), exportedInvite: nil, botInfo: nil, pinnedMsgId: group.pinnedMessageId, folderId: nil, call: nil, ttlPeriod: group.ttlPeriod, groupcallDefaultJoinAs: nil, themeEmoticon: nil, requestsPending: nil, recentRequesters: nil, availableReactions: nil, reactionsLimit: nil))
    }

    struct ChannelFull {
        var id: Int64
        var about: String
        var participantsCount: Int32?
        var adminsCount: Int32?
        /// `kicked_count` and `banned_count` share one flag: both are sent when either is known.
        var kickedCount: Int32?
        var bannedCount: Int32?
        var readInboxMaxId: Int32 = 0
        var readOutboxMaxId: Int32 = 0
        var unreadCount: Int32 = 0
        /// Nil is sent as `photoEmpty`: the field is mandatory.
        var chatPhoto: Api.Photo?
        var notifySettings = NotifySettings()
        var migratedFrom: (chatId: Int64, maxId: Int32)?
        var pinnedMessageId: Int32?
        var availableMinId: Int32?
        var linkedChatId: Int64?
        var slowmodeSeconds: Int32?
        var slowmodeNextSendDate: Int32?
        var pts: Int32 = 0
        var ttlPeriod: Int32?
        var canViewParticipants = false
        var canSetUsername = false
        var canSetStickers = false
        var hiddenPrehistory = false
        var hasScheduled = false
        var canViewStats = false
        var participantsHidden = false
        var translationsDisabled = false
        var antispam = false
    }

    static func channelFull(_ channel: ChannelFull) -> Api.ChatFull {
        let hasRemoved = channel.kickedCount != nil || channel.bannedCount != nil
        let kickedCount: Int32? = hasRemoved ? (channel.kickedCount ?? 0) : nil
        let bannedCount: Int32? = hasRemoved ? (channel.bannedCount ?? 0) : nil
        var flags: Int32 = some(channel.participantsCount, 0) | some(channel.adminsCount, 1) | bit(hasRemoved, 2) | bit(channel.canViewParticipants, 3)
        flags |= some(channel.migratedFrom, 4) | some(channel.pinnedMessageId, 5) | bit(channel.canSetUsername, 6) | bit(channel.canSetStickers, 7)
        flags |= some(channel.availableMinId, 9) | bit(channel.hiddenPrehistory, 10) | some(channel.linkedChatId, 14) | some(channel.slowmodeSeconds, 17)
        flags |= some(channel.slowmodeNextSendDate, 18) | bit(channel.hasScheduled, 19) | bit(channel.canViewStats, 20) | some(channel.ttlPeriod, 24)
        let flags2: Int32 = bit(channel.antispam, 1) | bit(channel.participantsHidden, 2) | bit(channel.translationsDisabled, 3)
        return .channelFull(.init(flags: flags, flags2: flags2, id: channel.id, about: channel.about, participantsCount: channel.participantsCount, adminsCount: channel.adminsCount, kickedCount: kickedCount, bannedCount: bannedCount, onlineCount: nil, readInboxMaxId: channel.readInboxMaxId, readOutboxMaxId: channel.readOutboxMaxId, unreadCount: channel.unreadCount, chatPhoto: channel.chatPhoto ?? .photoEmpty(.init(id: 0)), notifySettings: notifySettings(channel.notifySettings), exportedInvite: nil, botInfo: [], migratedFromChatId: channel.migratedFrom?.chatId, migratedFromMaxId: channel.migratedFrom?.maxId, pinnedMsgId: channel.pinnedMessageId, stickerset: nil, availableMinId: channel.availableMinId, folderId: nil, linkedChatId: channel.linkedChatId, location: nil, slowmodeSeconds: channel.slowmodeSeconds, slowmodeNextSendDate: channel.slowmodeNextSendDate, statsDc: nil, pts: channel.pts, call: nil, ttlPeriod: channel.ttlPeriod, pendingSuggestions: nil, groupcallDefaultJoinAs: nil, themeEmoticon: nil, requestsPending: nil, recentRequesters: nil, defaultSendAs: nil, availableReactions: nil, reactionsLimit: nil, stories: nil, wallpaper: nil, boostsApplied: nil, boostsUnrestrict: nil, emojiset: nil, botVerification: nil, stargiftsCount: nil, sendPaidMessagesStars: nil, mainTab: nil, guardBotId: nil, shareTheme: nil))
    }
}
