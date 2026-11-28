import Foundation
internal import TelegramApi

// Vectors for `Build/run_telegram_tl_tests.py`: every builder of
// `TelegramCore/Sources/AyuPlugins/AyuPluginTLBuilders.swift` with nothing optional set and with
// everything set. Each line is `name<TAB>base64`; the script decodes it with the SDK's parser.

private func emit<T: TLObjectBacked>(_ name: String, _ object: T) {
    print(name + "\t" + AyuPluginTL.serialize(object).base64EncodedString())
}

private let thumb = Data([1, 2, 3, 4, 5])
private let avatar = AyuPluginTL.AvatarPhoto(photoId: 77, datacenterId: 2, strippedThumb: thumb, hasVideo: true, isPersonal: true)
private let banned = AyuPluginTL.BannedRights(flags: (1 << 0) | (1 << 19) | (1 << 20) | (1 << 21) | (1 << 22) | (1 << 23) | (1 << 24) | (1 << 25), untilDate: 2_000_000_000)
private let bold = Api.MessageEntity.messageEntityBold(.init(offset: 0, length: 4))

emit("user.min", AyuPluginTL.user(AyuPluginTL.User(id: 5)))

private var fullUser = AyuPluginTL.User(id: 0x1_0000_0001)
fullUser.accessHash = -9
fullUser.isSelf = true
fullUser.isContact = true
fullUser.isMutualContact = true
fullUser.isBot = true
fullUser.botChatHistory = true
fullUser.botNoChats = true
fullUser.botInlineGeo = true
fullUser.botAttachMenu = true
fullUser.botCanEdit = true
fullUser.botBusiness = true
fullUser.botHasMainApp = true
fullUser.botForumView = true
fullUser.botForumCanManageTopics = true
fullUser.botCanManageBots = true
fullUser.botGuestChat = true
fullUser.botGuard = true
fullUser.botForumSidebar = true
fullUser.isVerified = true
fullUser.isSupport = true
fullUser.isScam = true
fullUser.isFake = true
fullUser.isPremium = true
fullUser.isCloseFriend = true
fullUser.storiesHidden = true
fullUser.contactRequirePremium = true
fullUser.firstName = "First"
fullUser.lastName = "Last \u{1F600}"
fullUser.username = "name"
fullUser.phone = "15550100"
fullUser.photo = avatar
fullUser.status = .online(expires: 123)
fullUser.restrictions = [AyuPluginTL.Restriction(platform: "ios", reason: "r", text: "t")]
fullUser.botInlinePlaceholder = "search"
fullUser.emojiStatus = AyuPluginTL.EmojiStatus(documentId: 11, until: 12)
fullUser.usernames = [AyuPluginTL.Username(username: "name", isEditable: true, isActive: true), AyuPluginTL.Username(username: "other")]
fullUser.color = AyuPluginTL.Color(color: 3, backgroundEmojiId: 4)
fullUser.profileColor = AyuPluginTL.Color(color: nil, backgroundEmojiId: nil)
fullUser.botActiveUsers = 9
fullUser.botVerificationIcon = 10
fullUser.linkedCommunityId = 13
emit("user.full", AyuPluginTL.user(fullUser))

private var deletedUser = AyuPluginTL.User(id: 6)
deletedUser.isDeleted = true
deletedUser.isMin = true
deletedUser.accessHash = 1
// A placeholder without the bot flag must not reach the wire.
deletedUser.botInlinePlaceholder = "ignored"
deletedUser.botCanEdit = true
emit("user.deleted", AyuPluginTL.user(deletedUser))

for (name, status) in [("empty", AyuPluginTL.UserStatus.empty), ("offline", .offline(wasOnline: 55)), ("recently", .recently), ("lastWeek", .lastWeek), ("lastMonth", .lastMonth)] {
    var user = AyuPluginTL.User(id: 7)
    user.status = status
    emit("user.status." + name, AyuPluginTL.user(user))
}

emit("group.min", AyuPluginTL.group(AyuPluginTL.Group(id: 20, title: "G", participantsCount: 3, date: 100, version: 2)))
private var fullGroup = AyuPluginTL.Group(id: 21, title: "Group", participantsCount: 4, date: 101, version: 5)
fullGroup.photo = avatar
fullGroup.isCreator = true
fullGroup.hasLeft = true
fullGroup.isDeactivated = true
fullGroup.callActive = true
fullGroup.callNotEmpty = true
fullGroup.noForwards = true
fullGroup.migratedTo = (channelId: 900, accessHash: 901)
fullGroup.adminRights = (1 << 0) | (1 << 12)
fullGroup.defaultBannedRights = banned
emit("group.full", AyuPluginTL.group(fullGroup))
private var forbiddenGroup = AyuPluginTL.Group(id: 22, title: "Gone", participantsCount: 0, date: 0, version: 0)
forbiddenGroup.isForbidden = true
emit("group.forbidden", AyuPluginTL.group(forbiddenGroup))

emit("channel.min", AyuPluginTL.channel(AyuPluginTL.Channel(id: 30, title: "C", date: 200)))
private var fullChannel = AyuPluginTL.Channel(id: 31, title: "Channel", date: 201)
fullChannel.accessHash = 32
fullChannel.isMin = true
fullChannel.username = "chan"
fullChannel.photo = AyuPluginTL.AvatarPhoto(photoId: 78, datacenterId: 4)
fullChannel.isCreator = true
fullChannel.hasLeft = true
fullChannel.isBroadcast = true
fullChannel.isMegagroup = true
fullChannel.isVerified = true
fullChannel.signatures = true
fullChannel.isScam = true
fullChannel.hasLink = true
fullChannel.hasGeo = true
fullChannel.slowmodeEnabled = true
fullChannel.callActive = true
fullChannel.callNotEmpty = true
fullChannel.isFake = true
fullChannel.isGigagroup = true
fullChannel.noForwards = true
fullChannel.joinToSend = true
fullChannel.joinRequest = true
fullChannel.isForum = true
fullChannel.storiesHidden = true
fullChannel.signatureProfiles = true
fullChannel.autotranslation = true
fullChannel.broadcastMessagesAllowed = true
fullChannel.isMonoforum = true
fullChannel.forumTabs = true
fullChannel.inNews = true
fullChannel.forumSidebar = true
fullChannel.restrictions = [AyuPluginTL.Restriction(platform: "all", reason: "porn", text: "x")]
fullChannel.adminRights = 1 << 3
fullChannel.bannedRights = banned
fullChannel.defaultBannedRights = AyuPluginTL.BannedRights(flags: 1 << 25, untilDate: Int32.max)
fullChannel.participantsCount = 1234
fullChannel.usernames = [AyuPluginTL.Username(username: "chan", isActive: true)]
fullChannel.color = AyuPluginTL.Color(color: 1, backgroundEmojiId: nil)
fullChannel.profileColor = AyuPluginTL.Color(color: nil, backgroundEmojiId: 2)
fullChannel.emojiStatus = AyuPluginTL.EmojiStatus(documentId: 5, until: nil)
fullChannel.level = 6
fullChannel.subscriptionUntilDate = 7
fullChannel.botVerificationIcon = 8
fullChannel.sendPaidMessagesStars = 9
fullChannel.linkedMonoforumId = 10
fullChannel.linkedCommunityId = 11
emit("channel.full", AyuPluginTL.channel(fullChannel))
private var forbiddenChannel = AyuPluginTL.Channel(id: 33, title: "Banned", date: 0)
forbiddenChannel.isForbidden = true
forbiddenChannel.accessHash = 34
forbiddenChannel.isMegagroup = true
forbiddenChannel.bannedRights = banned
emit("channel.forbidden", AyuPluginTL.channel(forbiddenChannel))
private var kickedWithoutHash = AyuPluginTL.Channel(id: 35, title: "Kicked", date: 0)
kickedWithoutHash.isForbidden = true
emit("channel.forbidden.nohash", AyuPluginTL.channel(kickedWithoutHash))

print("bannedFlags\t\(AyuPluginTL.bannedRightsFlags(stored: banned.flags))\t\(AyuPluginTL.bannedRightsFlags(stored: (1 << 19) | (1 << 20) | (1 << 21) | (1 << 22) | (1 << 23) | (1 << 24)))\t\(AyuPluginTL.bannedRightsFlags(stored: (1 << 1) | (1 << 2) | (1 << 25)))")

private let photo = AyuPluginTL.photo(AyuPluginTL.Photo(id: 40, accessHash: 41, fileReference: Data([9, 9]), datacenterId: 5, sizes: [.stripped(thumb), .plain(type: "m", width: 320, height: 200, size: 1000), .progressive(type: "y", width: 1280, height: 800, sizes: [100, 200, 300])], hasStickers: true))
emit("photo", photo)
private let document = AyuPluginTL.document(AyuPluginTL.Document(id: 50, accessHash: 51, fileReference: Data(), datacenterId: 1, mimeType: "video/mp4", size: 5_000_000_000, thumbs: [.plain(type: "m", width: 10, height: 20, size: 30)], attributes: [.documentAttributeFilename(.init(fileName: "a.mp4")), .documentAttributeVideo(.init(flags: 1 << 1, duration: 1.5, w: 640, h: 480, preloadPrefixSize: nil, videoStartTs: nil, videoCodec: nil))]))
emit("document", document)
emit("document.min", AyuPluginTL.document(AyuPluginTL.Document(id: 52, accessHash: 53, fileReference: Data([1]), datacenterId: 2, mimeType: "", size: 0, attributes: [])))
emit("media.photo", AyuPluginTL.photoMedia(photo, hasSpoiler: true, ttlSeconds: 10))
emit("media.photo.min", AyuPluginTL.photoMedia(photo, hasSpoiler: false, ttlSeconds: nil))
emit("media.document", AyuPluginTL.documentMedia(document, hasSpoiler: true, noPremium: true, isVideo: true, isRound: true, isVoice: true, ttlSeconds: 20))
emit("media.document.min", AyuPluginTL.documentMedia(document, hasSpoiler: false, noPremium: false, isVideo: false, isRound: false, isVoice: false, ttlSeconds: nil))

private let forward = AyuPluginTL.forwardHeader(AyuPluginTL.ForwardHeader(from: .channel(60), fromName: "Hidden", date: 300, channelPost: 61, postAuthor: "Author", savedFrom: (peer: .user(62), messageId: 63), psaType: "covid", isImported: true))
emit("forward", forward)
emit("forward.min", AyuPluginTL.forwardHeader(AyuPluginTL.ForwardHeader(date: 301)))
private let reply = AyuPluginTL.replyHeader(AyuPluginTL.ReplyHeader(messageId: 70, peer: .chat(71), topMessageId: 72, isForumTopic: true, quoteText: "quote", quoteEntities: [bold], quoteOffset: 2))
emit("reply", reply)
emit("reply.min", AyuPluginTL.replyHeader(AyuPluginTL.ReplyHeader(messageId: 73)))
// Quote details without a quote text must not reach the wire.
emit("reply.noquote", AyuPluginTL.replyHeader(AyuPluginTL.ReplyHeader(messageId: 74, quoteEntities: [bold], quoteOffset: 3)))

emit("message.min", AyuPluginTL.message(AyuPluginTL.Message(id: 80, peer: .user(81), date: 400, text: "")))
private var fullMessage = AyuPluginTL.Message(id: 82, peer: .channel(83), from: .user(84), date: 401, text: "Bold text \u{1F600}")
fullMessage.isOut = true
fullMessage.isMentioned = true
fullMessage.isMediaUnread = true
fullMessage.isSilent = true
fullMessage.isPost = true
fullMessage.isFromScheduled = true
fullMessage.editHidden = true
fullMessage.isPinned = true
fullMessage.noForwards = true
fullMessage.invertMedia = true
fullMessage.savedPeer = .user(85)
fullMessage.forward = forward
fullMessage.viaBotId = 86
fullMessage.reply = reply
fullMessage.media = AyuPluginTL.documentMedia(document, hasSpoiler: false, noPremium: false, isVideo: true, isRound: false, isVoice: false, ttlSeconds: nil)
fullMessage.entities = [bold]
fullMessage.views = 87
fullMessage.editDate = 402
fullMessage.postAuthor = "Signed"
fullMessage.groupedId = 88
fullMessage.ttlPeriod = 89
fullMessage.effect = 90
emit("message.full", AyuPluginTL.message(fullMessage))
private var forwardsOnly = AyuPluginTL.Message(id: 91, peer: .chat(92), date: 403, text: "x")
forwardsOnly.forwards = 5
emit("message.forwards", AyuPluginTL.message(forwardsOnly))
emit("media.webpage", AyuPluginTL.emptyWebPageMedia(id: 95, url: "https://example.org/"))
emit("media.webpage.min", AyuPluginTL.emptyWebPageMedia(id: 96, url: nil))
emit("media.unsupported", AyuPluginTL.unsupportedMedia)

emit("userFull.min", AyuPluginTL.userFull(AyuPluginTL.UserFull(id: 100)))
private var userFull = AyuPluginTL.UserFull(id: 101)
userFull.about = "About"
userFull.settings = AyuPluginTL.PeerSettings(reportSpam: true, addContact: true, blockContact: true, shareContact: true, needContactsException: true, autoarchived: true, inviteMembers: true, geoDistance: 500)
userFull.profilePhoto = photo
userFull.personalPhoto = photo
userFull.fallbackPhoto = photo
userFull.notifySettings = AyuPluginTL.NotifySettings(showPreviews: false, muteUntil: Int32.max)
userFull.pinnedMessageId = 102
userFull.commonChatsCount = 3
userFull.ttlPeriod = 86400
userFull.isBlocked = true
userFull.phoneCallsAvailable = true
userFull.phoneCallsPrivate = true
userFull.canPinMessage = true
userFull.hasScheduled = true
userFull.videoCallsAvailable = true
userFull.voiceMessagesForbidden = true
userFull.translationsDisabled = true
userFull.readDatesPrivate = true
userFull.contactRequirePremium = true
emit("userFull.full", AyuPluginTL.userFull(userFull))

emit("groupFull.min", AyuPluginTL.groupFull(AyuPluginTL.GroupFull(id: 110, about: "")))
private var groupFull = AyuPluginTL.GroupFull(id: 111, about: "Group about")
groupFull.participants = [.creator(userId: 1, rank: "boss"), .admin(userId: 2, inviterId: 1, date: 10, rank: nil), .member(userId: 3, inviterId: 2, date: 11, rank: nil)]
groupFull.participantsVersion = 7
groupFull.chatPhoto = photo
groupFull.notifySettings = AyuPluginTL.NotifySettings(showPreviews: true, muteUntil: 0)
groupFull.pinnedMessageId = 112
groupFull.ttlPeriod = 60
groupFull.hasScheduled = true
emit("groupFull.full", AyuPluginTL.groupFull(groupFull))

emit("channelFull.min", AyuPluginTL.channelFull(AyuPluginTL.ChannelFull(id: 120, about: "")))
private var channelFull = AyuPluginTL.ChannelFull(id: 121, about: "Channel about")
channelFull.participantsCount = 1000
channelFull.adminsCount = 5
channelFull.kickedCount = 6
channelFull.readInboxMaxId = 7
channelFull.readOutboxMaxId = 8
channelFull.unreadCount = 9
channelFull.chatPhoto = photo
channelFull.notifySettings = AyuPluginTL.NotifySettings(showPreviews: nil, muteUntil: 5)
channelFull.migratedFrom = (chatId: 122, maxId: 123)
channelFull.pinnedMessageId = 124
channelFull.availableMinId = 125
channelFull.linkedChatId = 126
channelFull.slowmodeSeconds = 30
channelFull.slowmodeNextSendDate = 127
channelFull.pts = 128
channelFull.ttlPeriod = 129
channelFull.canViewParticipants = true
channelFull.canSetUsername = true
channelFull.canSetStickers = true
channelFull.hiddenPrehistory = true
channelFull.hasScheduled = true
channelFull.canViewStats = true
channelFull.participantsHidden = true
channelFull.translationsDisabled = true
channelFull.antispam = true
emit("channelFull.full", AyuPluginTL.channelFull(channelFull))

emit("dialog.min", AyuPluginTL.dialog(AyuPluginTL.Dialog(peer: .user(130))))
private var dialog = AyuPluginTL.Dialog(peer: .channel(131))
dialog.isPinned = true
dialog.isMarkedUnread = true
dialog.topMessageId = 132
dialog.readInboxMaxId = 133
dialog.readOutboxMaxId = 134
dialog.unreadCount = 135
dialog.unreadMentionsCount = 136
dialog.unreadReactionsCount = 137
dialog.unreadPollVotesCount = 138
dialog.notifySettings = AyuPluginTL.NotifySettings(showPreviews: true, muteUntil: Int32.max)
dialog.pts = 139
dialog.folderId = 1
emit("dialog.full", AyuPluginTL.dialog(dialog))
emit("dialog.group", AyuPluginTL.dialog(AyuPluginTL.Dialog(peer: .chat(140), folderId: 1)))
emit("dialog.folder", AyuPluginTL.folderRow(AyuPluginTL.FolderRow(folderId: 1, title: "Archived Chats", topPeer: .chat(141), topMessageId: 142, unreadMutedPeersCount: 143, unreadUnmutedPeersCount: 144, unreadMutedMessagesCount: 145, unreadUnmutedMessagesCount: 146)))

// `AyuPluginOrderedGate` (the ordering of hooked requests and update containers): one line,
// `gate<TAB>ok` or the failed checks.

private final class GateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [Int] = []
    private var busy: [Bool] = []

    func ran(_ index: Int) { self.lock.lock(); self.order.append(index); self.lock.unlock() }
    func busyChanged(_ value: Bool) { self.lock.lock(); self.busy.append(value); self.lock.unlock() }
    func take() -> (order: [Int], busy: [Bool]) {
        self.lock.lock(); defer { self.lock.unlock() }
        let result = (self.order, self.busy)
        self.order = []; self.busy = []
        return result
    }
}

private final class GateDone: @unchecked Sendable {
    private let lock = NSLock()
    private var done: (() -> Void)?

    func hold(_ done: @escaping () -> Void) { self.lock.lock(); self.done = done; self.lock.unlock() }
    func release() {
        self.lock.lock(); let done = self.done; self.done = nil; self.lock.unlock()
        done?()
    }
}

private func gateProblems() -> [String] {
    var problems: [String] = []
    let log = GateLog()
    let gate = AyuPluginOrderedGate(busyChanged: { log.busyChanged($0) })

    for index in 0 ..< 3 {
        gate.add { done in log.ran(index); done() }
    }
    var seen = log.take()
    if seen.order != [0, 1, 2] || seen.busy != [true, false, true, false, true, false] || gate.isBusy {
        problems.append("synchronous steps: \(seen)")
    }

    // A long run of synchronous steps behind a held one must not recurse.
    let held = GateDone()
    let count = 50_000
    gate.add { done in log.ran(-1); held.hold(done) }
    for index in 0 ..< count {
        gate.add { done in log.ran(index); done() }
    }
    seen = log.take()
    if seen.order != [-1] || seen.busy != [true] || !gate.isBusy { problems.append("a held step let \(seen.order.count - 1) later steps run") }
    held.release()
    seen = log.take()
    if seen.order != Array(0 ..< count) || seen.busy != [false] || gate.isBusy {
        problems.append("queued steps: \(seen.order.count) ran, busy \(seen.busy)")
    }

    // Steps that finish on other threads, the earlier ones later.
    let finished = DispatchSemaphore(value: 0)
    for index in 0 ..< 8 {
        gate.add { done in
            log.ran(index)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(8 - index)) {
                done()
                if index == 7 { finished.signal() }
            }
        }
    }
    if finished.wait(timeout: .now() + 5) == .timedOut { problems.append("asynchronous steps did not finish") }
    usleep(20_000)
    seen = log.take()
    if seen.order != Array(0 ..< 8) || seen.busy != [true, false] || gate.isBusy {
        problems.append("asynchronous steps: \(seen)")
    }

    // A second `done` of one step must not end the step after it.
    gate.add { done in log.ran(0); done(); done() }
    gate.add { done in log.ran(1); held.hold(done) }
    gate.add { done in log.ran(2); done() }
    seen = log.take()
    if seen.order != [0, 1] { problems.append("repeated done: \(seen.order)") }
    held.release()
    seen = log.take()
    if seen.order != [2] || gate.isBusy { problems.append("after repeated done: \(seen.order)") }
    return problems
}

private let gateFailures = gateProblems()
print("gate\t" + (gateFailures.isEmpty ? "ok" : gateFailures.joined(separator: "; ")))
