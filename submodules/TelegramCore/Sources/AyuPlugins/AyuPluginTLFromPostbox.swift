import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

/// Rebuilds the TL objects Android plugins read from what the account has stored. Only the
/// field mapping lives here; the flag words and the layout are `AyuPluginTL`'s.
///
/// The app's models keep less than the server sent, so the result is what the cache knows:
/// absent optional fields are absent, a bot's `bot_info_version` is 0, documents and photos
/// have date 0, and reply markup, reactions, reply counters and bot descriptions are not rebuilt.

public enum AyuPluginPeerKind {
    case user
    /// A basic group or a channel.
    case chat
    case userFull
    case chatFull
}

private func ayuPluginPeerReference(_ peerId: PeerId) -> AyuPluginTL.PeerReference? {
    let id = peerId.id._internalGetInt64Value()
    switch peerId.namespace {
    case Namespaces.Peer.CloudUser:
        return .user(id)
    case Namespaces.Peer.CloudGroup:
        return .chat(id)
    case Namespaces.Peer.CloudChannel:
        return .channel(id)
    default:
        return nil
    }
}

private func ayuPluginAvatar(_ representations: [TelegramMediaImageRepresentation]) -> AyuPluginTL.AvatarPhoto? {
    for representation in representations {
        if let resource = representation.resource as? CloudPeerPhotoSizeMediaResource, let photoId = resource.photoId {
            return AyuPluginTL.AvatarPhoto(photoId: photoId, datacenterId: Int32(clamping: resource.datacenterId), strippedThumb: representation.immediateThumbnailData, hasVideo: representation.hasVideo, isPersonal: representation.isPersonal)
        }
    }
    return nil
}

private func ayuPluginAccessHash(_ accessHash: TelegramPeerAccessHash?) -> (value: Int64?, isMin: Bool) {
    switch accessHash {
    case let .personal(value):
        return (value, false)
    case let .genericPublic(value):
        return (value, true)
    case nil:
        return (nil, false)
    }
}

private func ayuPluginUsernames(_ usernames: [TelegramPeerUsername]) -> [AyuPluginTL.Username] {
    return usernames.map { AyuPluginTL.Username(username: $0.username, isEditable: $0.flags.contains(.isEditable), isActive: $0.flags.contains(.isActive)) }
}

private func ayuPluginRestrictions(_ info: PeerAccessRestrictionInfo?) -> [AyuPluginTL.Restriction] {
    return (info?.rules ?? []).map { AyuPluginTL.Restriction(platform: $0.platform, reason: $0.reason, text: $0.text) }
}

private func ayuPluginColor(_ color: Int32?, _ backgroundEmojiId: Int64?) -> AyuPluginTL.Color? {
    if color == nil && backgroundEmojiId == nil {
        return nil
    }
    return AyuPluginTL.Color(color: color, backgroundEmojiId: backgroundEmojiId)
}

private func ayuPluginBannedRights(_ rights: TelegramChatBannedRights?) -> AyuPluginTL.BannedRights? {
    return rights.map { AyuPluginTL.BannedRights(flags: $0.flags.rawValue, untilDate: $0.untilDate) }
}

/// The app drops the `other` right (bit 12) on parsing and adds it back on sending.
private func ayuPluginAdminRights(_ rights: TelegramChatAdminRights) -> Int32 {
    return rights.rights.rawValue | (1 << 12)
}

func ayuPluginTLUser(_ user: TelegramUser, accountPeerId: PeerId, isContact: Bool, presence: TelegramUserPresence?, timestamp: Int32) -> Api.User {
    var value = AyuPluginTL.User(id: user.id.id._internalGetInt64Value())
    let accessHash = ayuPluginAccessHash(user.accessHash)
    value.accessHash = accessHash.value
    value.isMin = accessHash.isMin
    value.isSelf = user.id == accountPeerId
    value.isContact = isContact
    value.isMutualContact = user.flags.contains(.mutualContact)
    if let botInfo = user.botInfo {
        value.isBot = true
        value.botChatHistory = botInfo.flags.contains(.hasAccessToChatHistory)
        value.botNoChats = !botInfo.flags.contains(.worksWithGroups)
        value.botInlineGeo = botInfo.flags.contains(.requiresGeolocationForInlineRequests)
        value.botAttachMenu = botInfo.flags.contains(.canBeAddedToAttachMenu)
        value.botCanEdit = botInfo.flags.contains(.canEdit)
        value.botBusiness = botInfo.flags.contains(.isBusiness)
        value.botHasMainApp = botInfo.flags.contains(.hasWebApp)
        value.botForumView = botInfo.flags.contains(.hasForum)
        value.botForumCanManageTopics = botInfo.flags.contains(.forumManagedByUser)
        value.botCanManageBots = botInfo.flags.contains(.canManageBots)
        value.botGuestChat = botInfo.flags.contains(.isGuestChat)
        value.botGuard = botInfo.flags.contains(.isGuardBot)
        value.botForumSidebar = botInfo.flags.contains(.displayForumAsSidebar)
        value.botInlinePlaceholder = botInfo.inlinePlaceholder
    } else {
        // The app keeps no deleted flag: a deleted account is a user without a name.
        value.isDeleted = user.firstName == nil && user.lastName == nil
    }
    value.isVerified = user.flags.contains(.isVerified)
    value.isSupport = user.flags.contains(.isSupport)
    value.isScam = user.flags.contains(.isScam)
    value.isFake = user.flags.contains(.isFake)
    value.isPremium = user.flags.contains(.isPremium)
    value.isCloseFriend = user.flags.contains(.isCloseFriend)
    value.contactRequirePremium = user.flags.contains(.requirePremium)
    value.storiesHidden = user.storiesHidden ?? false
    value.firstName = user.firstName
    value.lastName = user.lastName
    value.username = user.username
    value.phone = user.phone
    value.photo = ayuPluginAvatar(user.photo)
    if let presence {
        switch presence.status {
        case .none:
            value.status = .empty
        case let .present(until):
            // One stored value covers both: an expiry in the future is "online until".
            value.status = until > timestamp ? .online(expires: until) : .offline(wasOnline: until)
        case .recently:
            value.status = .recently
        case .lastWeek:
            value.status = .lastWeek
        case .lastMonth:
            value.status = .lastMonth
        }
    }
    value.restrictions = ayuPluginRestrictions(user.restrictionInfo)
    if let emojiStatus = user.emojiStatus {
        value.emojiStatus = AyuPluginTL.EmojiStatus(documentId: emojiStatus.fileId, until: emojiStatus.expirationDate)
    }
    value.usernames = ayuPluginUsernames(user.usernames)
    var nameColor: Int32?
    if case let .preset(color) = user.nameColor {
        nameColor = color.rawValue
    }
    value.color = ayuPluginColor(nameColor, user.backgroundEmojiId)
    value.profileColor = ayuPluginColor(user.profileColor?.rawValue, user.profileBackgroundEmojiId)
    value.botActiveUsers = user.botInfo != nil ? user.subscriberCount : nil
    value.botVerificationIcon = user.verificationIconFileId
    value.linkedCommunityId = user.linkedCommunityId?.id._internalGetInt64Value()
    return AyuPluginTL.user(value)
}

func ayuPluginTLGroup(_ group: TelegramGroup) -> Api.Chat {
    var value = AyuPluginTL.Group(id: group.id.id._internalGetInt64Value(), title: group.title, participantsCount: Int32(clamping: group.participantCount), date: group.creationDate, version: Int32(clamping: group.version))
    value.photo = ayuPluginAvatar(group.photo)
    switch group.role {
    case .creator:
        value.isCreator = true
    case let .admin(rights, _):
        value.adminRights = ayuPluginAdminRights(rights)
    case .member:
        break
    }
    switch group.membership {
    case .Member:
        break
    case .Left:
        value.hasLeft = true
    case .Removed:
        value.isForbidden = true
    }
    value.isDeactivated = group.flags.contains(.deactivated)
    value.callActive = group.flags.contains(.hasVoiceChat)
    value.callNotEmpty = group.flags.contains(.hasActiveVoiceChat)
    value.noForwards = group.flags.contains(.copyProtectionEnabled)
    if let migration = group.migrationReference {
        value.migratedTo = (channelId: migration.peerId.id._internalGetInt64Value(), accessHash: migration.accessHash)
    }
    value.defaultBannedRights = ayuPluginBannedRights(group.defaultBannedRights)
    return AyuPluginTL.group(value)
}

func ayuPluginTLChannel(_ channel: TelegramChannel) -> Api.Chat {
    var value = AyuPluginTL.Channel(id: channel.id.id._internalGetInt64Value(), title: channel.title, date: channel.creationDate)
    let accessHash = ayuPluginAccessHash(channel.accessHash)
    value.accessHash = accessHash.value
    value.isMin = accessHash.isMin
    value.username = channel.username
    value.photo = ayuPluginAvatar(channel.photo)
    switch channel.participationStatus {
    case .member:
        break
    case .left:
        value.hasLeft = true
    case .kicked:
        value.isForbidden = true
    }
    switch channel.info {
    case let .broadcast(info):
        value.isBroadcast = true
        value.signatures = info.flags.contains(.messagesShouldHaveSignatures)
        value.signatureProfiles = info.flags.contains(.messagesShouldHaveProfiles)
        value.hasLink = info.flags.contains(.hasDiscussionGroup)
        value.broadcastMessagesAllowed = info.flags.contains(.hasMonoforum)
    case let .group(info):
        value.isMegagroup = true
        value.slowmodeEnabled = info.flags.contains(.slowModeEnabled)
    }
    value.isCreator = channel.flags.contains(.isCreator)
    value.isVerified = channel.flags.contains(.isVerified)
    value.isScam = channel.flags.contains(.isScam)
    value.hasGeo = channel.flags.contains(.hasGeo)
    value.callActive = channel.flags.contains(.hasVoiceChat)
    value.callNotEmpty = channel.flags.contains(.hasActiveVoiceChat)
    value.isFake = channel.flags.contains(.isFake)
    value.isGigagroup = channel.flags.contains(.isGigagroup)
    value.noForwards = channel.flags.contains(.copyProtectionEnabled)
    value.joinToSend = channel.flags.contains(.joinToSend)
    value.joinRequest = channel.flags.contains(.requestToJoin)
    value.isForum = channel.flags.contains(.isForum)
    value.autotranslation = channel.flags.contains(.autoTranslateEnabled)
    value.isMonoforum = channel.flags.contains(.isMonoforum)
    value.forumTabs = channel.flags.contains(.displayForumAsTabs)
    value.inNews = channel.flags.contains(.isInNews)
    value.forumSidebar = channel.flags.contains(.displayForumAsSidebar)
    value.storiesHidden = channel.storiesHidden ?? false
    value.restrictions = ayuPluginRestrictions(channel.restrictionInfo)
    value.adminRights = channel.adminRights.map(ayuPluginAdminRights)
    value.bannedRights = ayuPluginBannedRights(channel.bannedRights)
    value.defaultBannedRights = ayuPluginBannedRights(channel.defaultBannedRights)
    value.usernames = ayuPluginUsernames(channel.usernames)
    value.color = ayuPluginColor(channel.nameColor?.rawValue, channel.backgroundEmojiId)
    value.profileColor = ayuPluginColor(channel.profileColor?.rawValue, channel.profileBackgroundEmojiId)
    if let emojiStatus = channel.emojiStatus {
        value.emojiStatus = AyuPluginTL.EmojiStatus(documentId: emojiStatus.fileId, until: emojiStatus.expirationDate)
    }
    value.level = channel.approximateBoostLevel
    value.subscriptionUntilDate = channel.subscriptionUntilDate
    value.botVerificationIcon = channel.verificationIconFileId
    value.sendPaidMessagesStars = channel.sendPaidMessageStars?.value
    value.linkedMonoforumId = channel.linkedMonoforumId?.id._internalGetInt64Value()
    value.linkedCommunityId = channel.linkedCommunityId?.id._internalGetInt64Value()
    return AyuPluginTL.channel(value)
}

/// A cached peer as boxed `User` or `Chat`; nil for a kind of peer Android does not have
/// (secret chats, communities).
func ayuPluginTLPeer(transaction: Transaction, peer: Peer, accountPeerId: PeerId, timestamp: Int32) -> Data? {
    if let user = peer as? TelegramUser {
        return AyuPluginTL.serialize(ayuPluginTLUser(user, accountPeerId: accountPeerId, isContact: transaction.isPeerContact(peerId: user.id), presence: transaction.getPeerPresence(peerId: user.id) as? TelegramUserPresence, timestamp: timestamp))
    } else if let group = peer as? TelegramGroup {
        return AyuPluginTL.serialize(ayuPluginTLGroup(group))
    } else if let channel = peer as? TelegramChannel {
        return AyuPluginTL.serialize(ayuPluginTLChannel(channel))
    } else {
        return nil
    }
}

// MARK: Media

func ayuPluginTLPhoto(_ image: TelegramMediaImage) -> Api.Photo? {
    guard case let .cloud(imageId, accessHash, fileReference) = image.reference else {
        return nil
    }
    var sizes: [AyuPluginTL.PhotoSize] = []
    var datacenterId: Int32?
    if let thumbnail = image.immediateThumbnailData {
        sizes.append(.stripped(thumbnail))
    }
    for representation in image.representations {
        guard let resource = representation.resource as? CloudPhotoSizeMediaResource else {
            continue
        }
        datacenterId = datacenterId ?? Int32(clamping: resource.datacenterId)
        if !representation.progressiveSizes.isEmpty {
            sizes.append(.progressive(type: resource.sizeSpec, width: representation.dimensions.width, height: representation.dimensions.height, sizes: representation.progressiveSizes))
        } else {
            sizes.append(.plain(type: resource.sizeSpec, width: representation.dimensions.width, height: representation.dimensions.height, size: Int32(clamping: resource.size ?? 0)))
        }
    }
    guard let datacenterId else {
        return nil
    }
    return AyuPluginTL.photo(AyuPluginTL.Photo(id: imageId, accessHash: accessHash, fileReference: fileReference ?? Data(), datacenterId: datacenterId, sizes: sizes, hasStickers: image.flags.contains(.hasStickers)))
}

func ayuPluginTLDocument(_ file: TelegramMediaFile) -> Api.Document? {
    guard let resource = file.resource as? CloudDocumentMediaResource else {
        return nil
    }
    var thumbs: [AyuPluginTL.PhotoSize] = []
    if let thumbnail = file.immediateThumbnailData {
        thumbs.append(.stripped(thumbnail))
    }
    for representation in file.previewRepresentations {
        if let thumbnailResource = representation.resource as? CloudDocumentSizeMediaResource {
            thumbs.append(.plain(type: thumbnailResource.sizeSpec, width: representation.dimensions.width, height: representation.dimensions.height, size: 0))
        }
    }
    return AyuPluginTL.document(AyuPluginTL.Document(id: resource.fileId, accessHash: resource.accessHash, fileReference: resource.fileReference ?? Data(), datacenterId: Int32(clamping: resource.datacenterId), mimeType: file.mimeType, size: file.size ?? resource.size ?? 0, thumbs: thumbs, attributes: inputDocumentAttributesFromFileAttributes(file.attributes)))
}

// MARK: Messages

/// Entities as the server sends them: the app's converter is the one for outgoing messages and
/// writes a text mention with an input user.
private func ayuPluginTLEntities(_ entities: [MessageTextEntity], peers: SimpleDictionary<PeerId, Peer>) -> [Api.MessageEntity] {
    return apiEntitiesFromMessageTextEntities(entities, associatedPeers: peers).compactMap { entity -> Api.MessageEntity? in
        guard case let .inputMessageEntityMentionName(data) = entity else {
            return entity
        }
        guard case let .inputUser(user) = data.userId else {
            return nil
        }
        return .messageEntityMentionName(.init(offset: data.offset, length: data.length, userId: user.userId))
    }
}

/// A stored message of the cloud history as a boxed-ready `Message`. Throws `unsupported` for a
/// message that has no faithful `message` constructor here: a service message, or one in a chat
/// Android numbers differently.
func ayuPluginTLMessage(_ message: Message) throws -> Api.Message {
    guard let peer = ayuPluginPeerReference(message.id.peerId) else {
        throw AyuPluginCoreError.unsupported("a message of a secret chat")
    }
    if message.media.contains(where: { $0 is TelegramMediaAction }) {
        throw AyuPluginCoreError.unsupported("a service message")
    }
    var value = AyuPluginTL.Message(id: message.id.id, peer: peer, date: message.timestamp, text: message.text)
    var isBroadcast = false
    if let channel = message.peers[message.id.peerId] as? TelegramChannel, case .broadcast = channel.info {
        isBroadcast = true
    }
    if let author = message.author {
        if isBroadcast && author.id == message.id.peerId {
            value.isPost = true
        } else {
            value.from = ayuPluginPeerReference(author.id)
        }
    } else if isBroadcast {
        value.isPost = true
    }
    value.isOut = !message.flags.contains(.Incoming)
    value.isFromScheduled = message.flags.contains(.WasScheduled)
    value.noForwards = message.flags.contains(.CopyProtected)
    value.isPinned = message.tags.contains(.pinned)
    value.groupedId = message.groupingKey

    var hasSpoiler = false
    var noPremium = false
    var mediaTimeout: Int32?
    var replyAttribute: ReplyMessageAttribute?
    var contentConsumed: Bool?
    for attribute in message.attributes {
        if let attribute = attribute as? TextEntitiesMessageAttribute {
            value.entities = ayuPluginTLEntities(attribute.entities, peers: message.peers)
        } else if let attribute = attribute as? ReplyMessageAttribute {
            replyAttribute = attribute
        } else if let attribute = attribute as? ViewCountMessageAttribute {
            value.views = Int32(clamping: attribute.count)
        } else if let attribute = attribute as? ForwardCountMessageAttribute {
            value.forwards = Int32(clamping: attribute.count)
        } else if let attribute = attribute as? EditedMessageAttribute {
            value.editDate = attribute.date
            value.editHidden = attribute.isHidden
        } else if let attribute = attribute as? AuthorSignatureMessageAttribute {
            value.postAuthor = attribute.signature
        } else if let attribute = attribute as? InlineBotMessageAttribute {
            if let peerId = attribute.peerId, peerId.namespace == Namespaces.Peer.CloudUser {
                value.viaBotId = peerId.id._internalGetInt64Value()
            }
        } else if let attribute = attribute as? AutoremoveTimeoutMessageAttribute {
            value.ttlPeriod = attribute.timeout
        } else if let attribute = attribute as? AutoclearTimeoutMessageAttribute {
            mediaTimeout = attribute.timeout
        } else if let attribute = attribute as? NotificationInfoMessageAttribute {
            value.isSilent = attribute.flags.contains(.muted)
        } else if let attribute = attribute as? ConsumablePersonalMentionMessageAttribute {
            value.isMentioned = true
            contentConsumed = (contentConsumed ?? true) && attribute.consumed
        } else if let attribute = attribute as? ConsumableContentMessageAttribute {
            contentConsumed = (contentConsumed ?? true) && attribute.consumed
        } else if let attribute = attribute as? EffectMessageAttribute {
            value.effect = attribute.id
        } else if attribute is MediaSpoilerMessageAttribute {
            hasSpoiler = true
        } else if attribute is NonPremiumMessageAttribute {
            noPremium = true
        } else if attribute is InvertMediaMessageAttribute {
            value.invertMedia = true
        }
    }
    value.isMediaUnread = contentConsumed == false

    if let info = message.forwardInfo {
        var header = AyuPluginTL.ForwardHeader(date: info.date)
        header.isImported = info.flags.contains(.isImported)
        header.psaType = info.psaType
        if let source = info.source, let reference = ayuPluginPeerReference(source.id) {
            header.from = reference
            header.channelPost = info.sourceMessageId?.id
            header.postAuthor = info.authorSignature
        } else if let author = info.author, let reference = ayuPluginPeerReference(author.id) {
            header.from = reference
            header.postAuthor = info.authorSignature
        } else {
            header.fromName = info.authorSignature
        }
        value.forward = AyuPluginTL.forwardHeader(header)
    }

    let isForumTopic = message.flags.contains(.IsForumTopic)
    if let replyAttribute {
        var header = AyuPluginTL.ReplyHeader(messageId: replyAttribute.messageId.id)
        if replyAttribute.messageId.peerId != message.id.peerId {
            header.peer = ayuPluginPeerReference(replyAttribute.messageId.peerId)
        }
        header.topMessageId = replyAttribute.threadMessageId?.id
        header.isForumTopic = isForumTopic
        if replyAttribute.isQuote, let quote = replyAttribute.quote {
            header.quoteText = quote.text
            header.quoteEntities = ayuPluginTLEntities(quote.entities, peers: message.peers)
            header.quoteOffset = quote.offset.flatMap { Int32(exactly: $0) }
        }
        value.reply = AyuPluginTL.replyHeader(header)
    } else if isForumTopic, let threadId = message.threadId, let topicId = Int32(exactly: threadId), message.id.peerId.namespace == Namespaces.Peer.CloudChannel {
        value.reply = AyuPluginTL.replyHeader(AyuPluginTL.ReplyHeader(messageId: topicId, isForumTopic: true))
    }

    for media in message.media {
        if let image = media as? TelegramMediaImage {
            value.media = ayuPluginTLPhoto(image).map { AyuPluginTL.photoMedia($0, hasSpoiler: hasSpoiler, ttlSeconds: mediaTimeout) } ?? AyuPluginTL.unsupportedMedia
        } else if let file = media as? TelegramMediaFile {
            value.media = ayuPluginTLDocument(file).map { AyuPluginTL.documentMedia($0, hasSpoiler: hasSpoiler, noPremium: noPremium, isVideo: file.isVideo, isRound: file.isInstantVideo, isVoice: file.isVoice, ttlSeconds: mediaTimeout) } ?? AyuPluginTL.unsupportedMedia
        } else if let webpage = media as? TelegramMediaWebpage {
            value.media = AyuPluginTL.emptyWebPageMedia(id: webpage.webpageId.id, url: webpage.content.url)
        } else {
            value.media = AyuPluginTL.unsupportedMedia
        }
        break
    }
    return AyuPluginTL.message(value)
}

// MARK: Full peers

private func ayuPluginNotifySettings(_ settings: PeerNotificationSettings?) -> AyuPluginTL.NotifySettings {
    guard let settings = settings as? TelegramPeerNotificationSettings else {
        return AyuPluginTL.NotifySettings()
    }
    var value = AyuPluginTL.NotifySettings()
    switch settings.muteState {
    case .default:
        break
    case .unmuted:
        value.muteUntil = 0
    case let .muted(until):
        value.muteUntil = until
    }
    switch settings.displayPreviews {
    case .default:
        break
    case .show:
        value.showPreviews = true
    case .hide:
        value.showPreviews = false
    }
    return value
}

private func ayuPluginTimeout(_ timeout: CachedPeerAutoremoveTimeout) -> Int32? {
    if case let .known(value) = timeout {
        return value?.peerValue
    }
    return nil
}

private func ayuPluginKnownPhoto(_ photo: CachedPeerProfilePhoto) -> Api.Photo? {
    if case let .known(image) = photo {
        return image.flatMap(ayuPluginTLPhoto)
    }
    return nil
}

private func ayuPluginCloudMessageId(_ id: MessageId?) -> Int32? {
    guard let id, id.namespace == Namespaces.Message.Cloud else {
        return nil
    }
    return id.id
}

func ayuPluginTLUserFull(peerId: PeerId, data: CachedUserData, notificationSettings: PeerNotificationSettings?) -> Api.UserFull {
    var value = AyuPluginTL.UserFull(id: peerId.id._internalGetInt64Value())
    value.about = data.about
    if let status = data.peerStatusSettings {
        value.settings.reportSpam = status.flags.contains(.canReport)
        value.settings.addContact = status.flags.contains(.canAddContact)
        value.settings.blockContact = status.flags.contains(.canBlock)
        value.settings.shareContact = status.flags.contains(.canShareContact)
        value.settings.needContactsException = status.flags.contains(.addExceptionWhenAddingContact)
        value.settings.autoarchived = status.flags.contains(.autoArchived)
        value.settings.inviteMembers = status.flags.contains(.suggestAddMembers)
    }
    value.profilePhoto = ayuPluginKnownPhoto(data.photo)
    value.personalPhoto = ayuPluginKnownPhoto(data.personalPhoto)
    value.fallbackPhoto = ayuPluginKnownPhoto(data.fallbackPhoto)
    value.notifySettings = ayuPluginNotifySettings(notificationSettings)
    value.pinnedMessageId = ayuPluginCloudMessageId(data.pinnedMessageId)
    value.commonChatsCount = data.commonGroupCount
    value.ttlPeriod = ayuPluginTimeout(data.autoremoveTimeout)
    value.isBlocked = data.isBlocked
    value.phoneCallsAvailable = data.voiceCallsAvailable
    value.phoneCallsPrivate = data.callsPrivate
    value.canPinMessage = data.canPinMessages
    value.hasScheduled = data.hasScheduledMessages
    value.videoCallsAvailable = data.videoCallsAvailable
    value.voiceMessagesForbidden = !data.voiceMessagesAvailable
    value.translationsDisabled = data.flags.contains(.translationHidden)
    value.readDatesPrivate = data.flags.contains(.readDatesPrivate)
    value.contactRequirePremium = data.flags.contains(.premiumRequired)
    return AyuPluginTL.userFull(value)
}

func ayuPluginTLGroupFull(peerId: PeerId, data: CachedGroupData, notificationSettings: PeerNotificationSettings?) -> Api.ChatFull {
    var value = AyuPluginTL.GroupFull(id: peerId.id._internalGetInt64Value(), about: data.about ?? "")
    if let participants = data.participants {
        value.participants = participants.participants.map { participant -> AyuPluginTL.Participant in
            switch participant {
            case let .member(id, invitedBy, invitedAt, rank):
                return .member(userId: id.id._internalGetInt64Value(), inviterId: invitedBy.id._internalGetInt64Value(), date: invitedAt, rank: rank)
            case let .creator(id, rank):
                return .creator(userId: id.id._internalGetInt64Value(), rank: rank)
            case let .admin(id, invitedBy, invitedAt, rank):
                return .admin(userId: id.id._internalGetInt64Value(), inviterId: invitedBy.id._internalGetInt64Value(), date: invitedAt, rank: rank)
            }
        }
        value.participantsVersion = participants.version
    }
    value.chatPhoto = data.photo.flatMap(ayuPluginTLPhoto)
    value.notifySettings = ayuPluginNotifySettings(notificationSettings)
    value.pinnedMessageId = ayuPluginCloudMessageId(data.pinnedMessageId)
    value.ttlPeriod = ayuPluginTimeout(data.autoremoveTimeout)
    value.hasScheduled = data.hasScheduledMessages
    return AyuPluginTL.groupFull(value)
}

func ayuPluginTLChannelFull(peerId: PeerId, data: CachedChannelData, notificationSettings: PeerNotificationSettings?, readState: CombinedPeerReadState?, pts: Int32?) -> Api.ChatFull {
    var value = AyuPluginTL.ChannelFull(id: peerId.id._internalGetInt64Value(), about: data.about ?? "")
    value.participantsCount = data.participantsSummary.memberCount
    value.adminsCount = data.participantsSummary.adminCount
    value.kickedCount = data.participantsSummary.kickedCount
    value.bannedCount = data.participantsSummary.bannedCount
    if let readState {
        for (namespace, state) in readState.states where namespace == Namespaces.Message.Cloud {
            if case let .idBased(maxIncomingReadId, maxOutgoingReadId, _, count, _) = state {
                value.readInboxMaxId = maxIncomingReadId
                value.readOutboxMaxId = maxOutgoingReadId
                value.unreadCount = count
            }
        }
    }
    value.chatPhoto = data.photo.flatMap(ayuPluginTLPhoto)
    value.notifySettings = ayuPluginNotifySettings(notificationSettings)
    if let migration = data.migrationReference, migration.maxMessageId.peerId.namespace == Namespaces.Peer.CloudGroup {
        value.migratedFrom = (chatId: migration.maxMessageId.peerId.id._internalGetInt64Value(), maxId: migration.maxMessageId.id)
    }
    value.pinnedMessageId = ayuPluginCloudMessageId(data.pinnedMessageId)
    value.availableMinId = ayuPluginCloudMessageId(data.minAvailableMessageId)
    if case let .known(linked) = data.linkedDiscussionPeerId, let linked {
        value.linkedChatId = linked.id._internalGetInt64Value()
    }
    value.slowmodeSeconds = data.slowModeTimeout
    value.slowmodeNextSendDate = data.slowModeValidUntilTimestamp
    value.pts = pts ?? 0
    value.ttlPeriod = ayuPluginTimeout(data.autoremoveTimeout)
    value.canViewParticipants = data.flags.contains(.canDisplayParticipants)
    value.canSetUsername = data.flags.contains(.canChangeUsername)
    value.canSetStickers = data.flags.contains(.canSetStickerSet)
    value.hiddenPrehistory = !data.flags.contains(.preHistoryEnabled)
    value.hasScheduled = data.hasScheduledMessages
    value.canViewStats = data.flags.contains(.canViewStats)
    value.translationsDisabled = data.flags.contains(.translationHidden)
    value.antispam = data.flags.contains(.antiSpamEnabled)
    if case let .known(hidden) = data.membersHidden {
        value.participantsHidden = hidden.value
    }
    return AyuPluginTL.channelFull(value)
}

// MARK: Public surface

/// A cached peer as boxed TL of the layer `ayuPluginApiLayer`: `User`, `Chat` (`chat`, `channel`,
/// `chatForbidden`, `channelForbidden`), `UserFull` or `ChatFull`. `id` is the positive user,
/// group or channel id. Nil when the peer, or its full info, is not stored; no request is made.
public func ayuPluginPeerTL(account: Account, kind: AyuPluginPeerKind, id: Int64) -> Signal<Data?, NoError> {
    let accountPeerId = account.peerId
    return account.postbox.transaction { transaction -> Data? in
        guard id > 0, id <= (1 << 52) - 1 else {
            return nil
        }
        let timestamp = Int32(clamping: Int64(Date().timeIntervalSince1970))
        let peer: Peer?
        switch kind {
        case .user, .userFull:
            peer = ayuPluginCachedPeer(transaction: transaction, dialogId: id)
        case .chat, .chatFull:
            peer = ayuPluginCachedPeer(transaction: transaction, dialogId: -id)
        }
        guard let peer else {
            return nil
        }
        switch kind {
        case .user, .chat:
            return ayuPluginTLPeer(transaction: transaction, peer: peer, accountPeerId: accountPeerId, timestamp: timestamp)
        case .userFull:
            guard let data = transaction.getPeerCachedData(peerId: peer.id) as? CachedUserData else {
                return nil
            }
            return AyuPluginTL.serialize(ayuPluginTLUserFull(peerId: peer.id, data: data, notificationSettings: transaction.getPeerNotificationSettings(id: peer.id)))
        case .chatFull:
            let cachedData = transaction.getPeerCachedData(peerId: peer.id)
            let notificationSettings = transaction.getPeerNotificationSettings(id: peer.id)
            if let data = cachedData as? CachedGroupData {
                return AyuPluginTL.serialize(ayuPluginTLGroupFull(peerId: peer.id, data: data, notificationSettings: notificationSettings))
            } else if let data = cachedData as? CachedChannelData {
                return AyuPluginTL.serialize(ayuPluginTLChannelFull(peerId: peer.id, data: data, notificationSettings: notificationSettings, readState: transaction.getCombinedPeerReadState(peer.id), pts: (transaction.getPeerChatState(peer.id) as? ChannelState)?.pts))
            } else {
                return nil
            }
        }
    }
}

/// Stored messages of a dialog's cloud history as boxed `Message`, one entry per id in order:
/// nil for an id that is not stored, and for a stored message that cannot be rebuilt (a service
/// message). A wrong object is never returned in its place.
public func ayuPluginMessagesTL(account: Account, dialogId: Int64, ids: [Int32]) -> Signal<[Data?], AyuPluginCoreError> {
    return account.postbox.transaction { transaction -> [Data?] in
        guard let peer = ayuPluginCachedPeer(transaction: transaction, dialogId: dialogId) else {
            return ids.map { _ in nil }
        }
        return ids.map { id -> Data? in
            guard id > 0, let message = transaction.getMessage(MessageId(peerId: peer.id, namespace: Namespaces.Message.Cloud, id: id)) else {
                return nil
            }
            return ayuPluginMessageTL(message)
        }
    }
    |> castError(AyuPluginCoreError.self)
}

/// A message the app holds as a boxed `Message`; nil when it is not a cloud message or cannot
/// be rebuilt (a service message, a message of a secret chat).
public func ayuPluginMessageTL(_ message: EngineRawMessage) -> Data? {
    guard message.id.namespace == Namespaces.Message.Cloud, let value = try? ayuPluginTLMessage(message) else {
        return nil
    }
    return AyuPluginTL.serialize(value)
}
