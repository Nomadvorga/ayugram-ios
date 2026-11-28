import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

/// A JPEG the caller prepared, with its pixel size.
public struct AyuPluginLocalImage {
    public var jpegData: Data
    public var dimensions: PixelDimensions

    public init(jpegData: Data, dimensions: PixelDimensions) {
        self.jpegData = jpegData
        self.dimensions = dimensions
    }
}

/// A local file to upload as a document, video or audio. The file is copied into the media
/// store before the message is queued, so the caller may delete it afterwards.
public struct AyuPluginLocalFile {
    public var path: String
    public var mimeType: String
    /// Used as given when `descriptionDocument` is nil.
    public var attributes: [TelegramMediaFileAttribute]
    public var thumbnail: AyuPluginLocalImage?
    /// A boxed `Document` whose MIME type and attributes describe the upload instead.
    public var descriptionDocument: Data?

    public init(path: String, mimeType: String, attributes: [TelegramMediaFileAttribute], thumbnail: AyuPluginLocalImage?, descriptionDocument: Data?) {
        self.path = path
        self.mimeType = mimeType
        self.attributes = attributes
        self.thumbnail = thumbnail
        self.descriptionDocument = descriptionDocument
    }
}

public enum AyuPluginOutgoingMedia {
    case none
    case localImage(AyuPluginLocalImage)
    case localFile(AyuPluginLocalFile)
    /// A boxed `Document` that exists on the server, with a file reference that is still valid.
    case document(Data)
    /// A boxed `Photo` that exists on the server.
    case photo(Data)
}

/// A message for `ayuPluginEnqueueMessage`. Dialog ids are Android's: a user id, or the negated
/// group or channel id.
public struct AyuPluginOutgoingMessage {
    public var dialogId: Int64
    /// The text, or the caption of `media`.
    public var text: String
    /// Boxed `MessageEntity` values with UTF-16 offsets into `text`.
    public var entities: [Data]
    public var media: AyuPluginOutgoingMedia
    public var replyTo: (dialogId: Int64, messageId: Int32)?
    public var threadMessageId: Int32?
    public var silent: Bool
    public var scheduleTime: Int32?
    public var scheduleRepeatPeriod: Int32?
    public var disablesLinkPreview: Bool
    public var invertsMedia: Bool
    public var effectId: Int64?
    public var hasSpoiler: Bool

    public init(dialogId: Int64, text: String, entities: [Data] = [], media: AyuPluginOutgoingMedia = .none, replyTo: (dialogId: Int64, messageId: Int32)? = nil, threadMessageId: Int32? = nil, silent: Bool = false, scheduleTime: Int32? = nil, scheduleRepeatPeriod: Int32? = nil, disablesLinkPreview: Bool = false, invertsMedia: Bool = false, effectId: Int64? = nil, hasSpoiler: Bool = false) {
        self.dialogId = dialogId
        self.text = text
        self.entities = entities
        self.media = media
        self.replyTo = replyTo
        self.threadMessageId = threadMessageId
        self.silent = silent
        self.scheduleTime = scheduleTime
        self.scheduleRepeatPeriod = scheduleRepeatPeriod
        self.disablesLinkPreview = disablesLinkPreview
        self.invertsMedia = invertsMedia
        self.effectId = effectId
        self.hasSpoiler = hasSpoiler
    }
}

/// The peer id of an Android dialog id whose peer the account has cached: a user for a positive
/// id; for a negative one the channel with the negated id, else the basic group.
func ayuPluginCachedPeer(transaction: Transaction, dialogId: Int64) -> Peer? {
    let limit: Int64 = (1 << 52) - 1
    if dialogId > 0, dialogId <= limit {
        return transaction.getPeer(PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(dialogId)))
    } else if dialogId < 0, dialogId >= -limit {
        let id = PeerId.Id._internalFromInt64Value(-dialogId)
        return transaction.getPeer(PeerId(namespace: Namespaces.Peer.CloudChannel, id: id)) ?? transaction.getPeer(PeerId(namespace: Namespaces.Peer.CloudGroup, id: id))
    } else {
        return nil
    }
}

/// Android's dialog id of a cloud peer; nil for secret chats and local peers, which Android
/// numbers differently.
public func ayuPluginDialogId(peerId: PeerId) -> Int64? {
    let id = peerId.id._internalGetInt64Value()
    switch peerId.namespace {
    case Namespaces.Peer.CloudUser:
        return id
    case Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel:
        return -id
    default:
        return nil
    }
}

/// Entities a plugin sent, checked against the text before any range is built from them.
func ayuPluginMessageEntities(_ values: [Data], text: String) throws -> [MessageTextEntity] {
    let textLength = (text as NSString).length
    var result: [MessageTextEntity] = []
    for value in values {
        guard let entity = Api.parse(Buffer(data: value)) as? Api.MessageEntity else {
            throw AyuPluginCoreError.invalidArguments("entities must hold MessageEntity objects")
        }
        var offset: Int32?
        var length: Int32?
        for (name, parameter) in entity.descriptionFields().1 {
            if name == "offset" {
                offset = parameter.value as? Int32
            } else if name == "length" {
                length = parameter.value as? Int32
            }
        }
        guard let offset, let length, offset >= 0, length >= 0, Int(offset) + Int(length) <= textLength else {
            throw AyuPluginCoreError.invalidArguments("an entity lies outside the text")
        }
        if case let .inputMessageEntityMentionName(data) = entity {
            guard case let .inputUser(user) = data.userId, user.userId > 0, user.userId <= (1 << 52) - 1 else {
                throw AyuPluginCoreError.unsupported("a mention entity of a user without an id")
            }
            result.append(MessageTextEntity(range: Int(offset) ..< Int(offset) + Int(length), type: .TextMention(peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(user.userId)))))
            continue
        }
        let converted = messageTextEntitiesFromApiEntities([entity])
        guard converted.count == 1 else {
            throw AyuPluginCoreError.unsupported("an entity type the app does not send")
        }
        result.append(contentsOf: converted)
    }
    return result
}

private func ayuPluginRandomId() -> Int64 {
    return Int64.random(in: Int64.min ... Int64.max)
}

private func ayuPluginStoredImage(mediaBox: MediaBox, image: AyuPluginLocalImage) -> TelegramMediaImageRepresentation {
    let resource = LocalFileMediaResource(fileId: ayuPluginRandomId(), size: Int64(image.jpegData.count))
    mediaBox.storeResourceData(resource.id, data: image.jpegData, synchronous: true)
    return TelegramMediaImageRepresentation(dimensions: image.dimensions, resource: resource, progressiveSizes: [], immediateThumbnailData: nil)
}

/// Builds the media of an outgoing message. Runs on the caller's queue and copies local files.
private func ayuPluginMedia(mediaBox: MediaBox, media: AyuPluginOutgoingMedia) throws -> AnyMediaReference? {
    switch media {
    case .none:
        return nil
    case let .localImage(image):
        guard image.dimensions.width > 0, image.dimensions.height > 0, !image.jpegData.isEmpty else {
            throw AyuPluginCoreError.invalidArguments("path is not an image")
        }
        let representation = ayuPluginStoredImage(mediaBox: mediaBox, image: image)
        return .standalone(media: TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: ayuPluginRandomId()), representations: [representation], immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: []))
    case let .localFile(file):
        var mimeType = file.mimeType
        var attributes = file.attributes
        if let description = file.descriptionDocument {
            guard let document = Api.parse(Buffer(data: description)) as? Api.Document, let described = telegramMediaFileFromApiDocument(document, altDocuments: nil) else {
                throw AyuPluginCoreError.invalidArguments("document must be a Document")
            }
            if !described.mimeType.isEmpty {
                mimeType = described.mimeType
            }
            attributes = described.attributes
            if !attributes.contains(where: { if case .FileName = $0 { return true } else { return false } }) {
                attributes.append(.FileName(fileName: (file.path as NSString).lastPathComponent))
            }
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber, size.int64Value > 0 else {
            throw AyuPluginCoreError.invalidArguments("path is not a readable, nonempty file")
        }
        let resource = LocalFileMediaResource(fileId: ayuPluginRandomId(), size: size.int64Value)
        // Synchronous, so the caller may delete its file once the message is queued. On APFS
        // the copy is a clone.
        do {
            try FileManager.default.copyItem(atPath: file.path, toPath: mediaBox.resourcePath(resource))
        } catch {
            throw AyuPluginCoreError.invalidArguments("path could not be read")
        }
        var previews: [TelegramMediaImageRepresentation] = []
        if let thumbnail = file.thumbnail, thumbnail.dimensions.width > 0, thumbnail.dimensions.height > 0, !thumbnail.jpegData.isEmpty {
            previews.append(ayuPluginStoredImage(mediaBox: mediaBox, image: thumbnail))
        }
        return .standalone(media: TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: ayuPluginRandomId()), partialReference: nil, resource: resource, previewRepresentations: previews, videoThumbnails: [], immediateThumbnailData: nil, mimeType: mimeType, size: size.int64Value, attributes: attributes, alternativeRepresentations: []))
    case let .document(data):
        guard let document = Api.parse(Buffer(data: data)) as? Api.Document, let file = telegramMediaFileFromApiDocument(document, altDocuments: nil) else {
            throw AyuPluginCoreError.invalidArguments("document must be an existing Document")
        }
        return .standalone(media: file)
    case let .photo(data):
        guard let photo = Api.parse(Buffer(data: data)) as? Api.Photo, let image = telegramMediaImageFromApiPhoto(photo) else {
            throw AyuPluginCoreError.invalidArguments("photo must be an existing Photo")
        }
        return .standalone(media: image)
    }
}

/// Queues a message exactly as the chat screen does (`enqueueMessages`): it appears in the chat
/// at once and is delivered by the pending-message manager. Completes when it is queued; fails
/// without queuing anything when the peer is not cached or a value cannot be honoured.
public func ayuPluginEnqueueMessage(account: Account, message: AyuPluginOutgoingMessage) -> Signal<Never, AyuPluginCoreError> {
    let postbox = account.postbox
    return postbox.transaction { transaction -> Result<(PeerId, PeerId?), AyuPluginCoreError> in
        guard let peer = ayuPluginCachedPeer(transaction: transaction, dialogId: message.dialogId) else {
            return .failure(.invalidArguments("peer is not known to the account"))
        }
        var replyPeerId: PeerId?
        if let replyTo = message.replyTo {
            guard let replyPeer = ayuPluginCachedPeer(transaction: transaction, dialogId: replyTo.dialogId) else {
                return .failure(.invalidArguments("replyToMsg is in a dialog the account does not know"))
            }
            replyPeerId = replyPeer.id
        }
        return .success((peer.id, replyPeerId))
    }
    |> castError(AyuPluginCoreError.self)
    // Copying a file does not belong on the Postbox queue.
    |> deliverOn(Queue.concurrentDefaultQueue())
    |> mapToSignal { resolved -> Signal<Never, AyuPluginCoreError> in
        let peerId: PeerId
        let replyPeerId: PeerId?
        switch resolved {
        case let .success(value):
            (peerId, replyPeerId) = value
        case let .failure(error):
            return .fail(error)
        }
        var attributes: [MessageAttribute] = []
        let mediaReference: AnyMediaReference?
        do {
            let entities = try ayuPluginMessageEntities(message.entities, text: message.text)
            if !entities.isEmpty {
                attributes.append(TextEntitiesMessageAttribute(entities: entities))
            }
            mediaReference = try ayuPluginMedia(mediaBox: postbox.mediaBox, media: message.media)
        } catch let error as AyuPluginCoreError {
            return .fail(error)
        } catch {
            return .fail(.invalidArguments("message could not be prepared"))
        }
        if message.silent {
            attributes.append(NotificationInfoMessageAttribute(flags: .muted))
        }
        if let scheduleTime = message.scheduleTime {
            attributes.append(OutgoingScheduleInfoMessageAttribute(scheduleTime: scheduleTime, repeatPeriod: message.scheduleRepeatPeriod))
        }
        if message.disablesLinkPreview {
            attributes.append(OutgoingContentInfoMessageAttribute(flags: .disableLinkPreviews))
        }
        if message.invertsMedia {
            attributes.append(InvertMediaMessageAttribute())
        }
        if let effectId = message.effectId {
            attributes.append(EffectMessageAttribute(id: effectId))
        }
        if message.hasSpoiler {
            attributes.append(MediaSpoilerMessageAttribute())
        }
        var replySubject: EngineMessageReplySubject?
        if let replyTo = message.replyTo, let replyPeerId {
            replySubject = EngineMessageReplySubject(messageId: MessageId(peerId: replyPeerId, namespace: Namespaces.Message.Cloud, id: replyTo.messageId), quote: nil, innerSubject: nil)
        }
        let enqueued: EnqueueMessage = .message(text: message.text, attributes: attributes, inlineStickers: [:], mediaReference: mediaReference, threadId: message.threadMessageId.flatMap { Int64($0) }, replyToMessageId: replySubject, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])
        return enqueueMessages(account: account, peerId: peerId, messages: [enqueued])
        |> castError(AyuPluginCoreError.self)
        |> mapToSignal { ids -> Signal<Never, AyuPluginCoreError> in
            if ids.contains(where: { $0 != nil }) {
                return .complete()
            } else {
                return .fail(.invalidArguments("the message could not be queued for this peer"))
            }
        }
    }
}

/// An edit for `ayuPluginRequestEditMessage`.
public struct AyuPluginMessageEdit {
    public var dialogId: Int64
    public var messageId: Int32
    /// Nil keeps the text and its entities.
    public var text: String?
    public var entities: [Data]
    /// Replaces the media; `.none` keeps it.
    public var media: AyuPluginOutgoingMedia
    public var hasSpoiler: Bool

    public init(dialogId: Int64, messageId: Int32, text: String?, entities: [Data], media: AyuPluginOutgoingMedia, hasSpoiler: Bool) {
        self.dialogId = dialogId
        self.messageId = messageId
        self.text = text
        self.entities = entities
        self.media = media
        self.hasSpoiler = hasSpoiler
    }
}

/// The rules of the chat screen's "Edit" action (`canEditMessage` in ChatMessageItemCommon),
/// for a message of the regular cloud history.
func ayuPluginCanEditMessage(accountPeerId: PeerId, limits: LimitsConfiguration, message: Message) -> Bool {
    guard message.id.namespace == Namespaces.Message.Cloud, message.id.peerId.namespace != Namespaces.Peer.SecretChat else {
        return false
    }
    var hasEditRights = false
    var unlimitedInterval = false
    let outgoing = !message.flags.contains(.Incoming)
    let channel = message.peers[message.id.peerId] as? TelegramChannel
    if let author = message.author, author.id == accountPeerId, message.peers[message.id.peerId] != nil {
        hasEditRights = true
        if let channel {
            if channel.flags.contains(.isGigagroup) {
                hasEditRights = channel.flags.contains(.isCreator) || channel.adminRights != nil
            }
            switch channel.info {
            case .broadcast:
                unlimitedInterval = channel.hasPermission(.editAllMessages) || outgoing
            case .group:
                unlimitedInterval = channel.hasPermission(.pinMessages)
            }
        }
    } else if let author = message.author, author.id != message.id.peerId, author.id.namespace == Namespaces.Peer.CloudChannel, message.id.peerId.namespace == Namespaces.Peer.CloudChannel, outgoing {
        hasEditRights = !message.media.contains(where: { $0 is TelegramMediaInvoice })
    } else if message.author?.id == message.id.peerId, let channel {
        switch channel.info {
        case .broadcast:
            if channel.hasPermission(.editAllMessages) || outgoing {
                unlimitedInterval = true
                hasEditRights = true
            }
        case .group:
            if outgoing {
                hasEditRights = true
                unlimitedInterval = channel.hasPermission(.pinMessages)
            }
        }
    }
    guard hasEditRights, message.forwardInfo == nil else {
        return false
    }
    for attribute in message.attributes {
        if attribute is InlineBotMessageAttribute {
            return false
        }
        if attribute is PublishedSuggestedPostMessageAttribute, message.timestamp > Int32(Date().timeIntervalSince1970) - 60 * 60 * 24 {
            return false
        }
    }
    for media in message.media {
        if let file = media as? TelegramMediaFile {
            if file.isSticker || file.isAnimatedSticker || file.isInstantVideo {
                return false
            }
        } else if media is TelegramMediaContact || media is TelegramMediaExpiredContent || media is TelegramMediaMap || media is TelegramMediaPoll || media is TelegramMediaDice || media is TelegramMediaGame || media is TelegramMediaInvoice || media is TelegramMediaStory || media is TelegramMediaGiveaway || media is TelegramMediaGiveawayResults || media is TelegramMediaAction {
            return false
        } else if media is TelegramMediaTodo {
            unlimitedInterval = true
        }
    }
    if message.id.peerId == accountPeerId || unlimitedInterval {
        return true
    }
    return Int64(message.timestamp) + Int64(limits.maxMessageEditingInterval) > Int64(Date().timeIntervalSince1970)
}

/// Starts the edit request the chat screen sends. Completes once the message was found editable
/// and the request was started; the request itself finishes later and reports its outcome only
/// through the message's own state. Fails with `invalidArguments` when the message is not
/// stored or the account may not edit it.
public func ayuPluginRequestEditMessage(account: Account, edit: AyuPluginMessageEdit) -> Signal<Never, AyuPluginCoreError> {
    let postbox = account.postbox
    let accountPeerId = account.peerId
    return postbox.transaction { transaction -> Result<Message, AyuPluginCoreError> in
        guard let peer = ayuPluginCachedPeer(transaction: transaction, dialogId: edit.dialogId) else {
            return .failure(.invalidArguments("dialog_id is not known to the account"))
        }
        guard let message = transaction.getMessage(MessageId(peerId: peer.id, namespace: Namespaces.Message.Cloud, id: edit.messageId)) else {
            return .failure(.invalidArguments("the message is not stored"))
        }
        guard ayuPluginCanEditMessage(accountPeerId: accountPeerId, limits: currentLimitsConfiguration(transaction: transaction), message: message) else {
            return .failure(.invalidArguments("the message is not editable by the account"))
        }
        return .success(message)
    }
    |> castError(AyuPluginCoreError.self)
    |> deliverOn(Queue.concurrentDefaultQueue())
    |> mapToSignal { found -> Signal<Never, AyuPluginCoreError> in
        let message: Message
        switch found {
        case let .success(value):
            message = value
        case let .failure(error):
            return .fail(error)
        }
        let text = edit.text ?? message.text
        var entitiesAttribute: TextEntitiesMessageAttribute?
        let media: RequestEditMessageMedia
        do {
            if edit.text != nil {
                let entities = try ayuPluginMessageEntities(edit.entities, text: text)
                entitiesAttribute = entities.isEmpty ? nil : TextEntitiesMessageAttribute(entities: entities)
            } else {
                entitiesAttribute = message.textEntitiesAttribute
            }
            if case .none = edit.media {
            } else if edit.hasSpoiler {
                // The edit request has no spoiler argument; the flag would be dropped.
                return .fail(.unsupported("telegram.edit_message attach.spoiler"))
            }
            if let reference = try ayuPluginMedia(mediaBox: postbox.mediaBox, media: edit.media) {
                media = .update(reference)
            } else {
                media = .keep
            }
        } catch let error as AyuPluginCoreError {
            return .fail(error)
        } catch {
            return .fail(.invalidArguments("the edit could not be prepared"))
        }
        let _ = _internal_requestEditMessage(account: account, messageId: message.id, text: text, media: media, entities: entitiesAttribute, richText: nil, inlineStickers: [:], webpagePreviewAttribute: nil, disableUrlPreview: false, scheduleInfoAttribute: nil, invertMediaAttribute: message.attributes.first(where: { $0 is InvertMediaMessageAttribute }) as? InvertMediaMessageAttribute).start()
        return .complete()
    }
}

/// The peer of an Android dialog id when the account has it cached; no request is made.
public func ayuPluginCachedPeer(account: Account, dialogId: Int64) -> Signal<EnginePeer?, NoError> {
    return account.postbox.transaction { transaction -> EnginePeer? in
        return ayuPluginCachedPeer(transaction: transaction, dialogId: dialogId).flatMap(EnginePeer.init)
    }
}
