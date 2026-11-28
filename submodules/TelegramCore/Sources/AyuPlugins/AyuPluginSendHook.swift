import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

/// An outgoing message as the plugin send hook sees it, before it is queued. Built from an
/// `EnqueueMessage` by `ayuPluginDescribeOutgoingMessages` and written back by
/// `ayuPluginApplySendHook`.
public struct AyuPluginHookedOutgoingMessage: Equatable {
    public struct Reference: Equatable {
        public var dialogId: Int64
        public var messageId: Int32
        /// The boxed `Message`.
        public var message: Data
    }

    /// Android's dialog id of the chat the message goes to.
    public var dialogId: Int64
    /// The text of a text message, or the caption when `isMedia`.
    public var text: String
    public var isMedia: Bool
    /// Boxed `MessageEntity` values with UTF-16 offsets into `text`.
    public var entities: [Data]
    /// The replied message and the thread's top message, when they are stored and can be
    /// rebuilt as TL.
    public var replyTo: Reference?
    public var replyToTop: Reference?
    /// The id of the replied message, also when it could not be described.
    public var replyToMessageId: Int32?
    /// The file being sent when the media is a local file reference.
    public var path: String?
    /// The media when it already is a document or a photo of the server.
    public var document: Data?
    public var photo: Data?
    public var silent: Bool
    public var scheduleTime: Int32
    public var scheduleRepeatPeriod: Int32
    public var disablesLinkPreview: Bool
    public var invertsMedia: Bool
    public var effectId: Int64
    public var hasSpoiler: Bool
    /// True when the fields above are all there is to the message, so that sending them as a new
    /// message loses nothing: what lets a plugin send its hook's object again.
    public var isComplete: Bool = false
}

/// The fields `ayuPluginApplySendHook` writes back, by their `SendMessageParams` names.
public let ayuPluginSendHookMutableFields: Set<String> = [
    "message", "caption", "entities", "replyToMsg", "notify", "scheduleDate", "scheduleRepeatPeriod", "searchLinks",
    "invert_media", "effect_id", "hasMediaSpoilers",
]

private func ayuPluginReference(transaction: Transaction, id: MessageId) -> AyuPluginHookedOutgoingMessage.Reference? {
    guard id.namespace == Namespaces.Message.Cloud, let dialogId = ayuPluginDialogId(peerId: id.peerId), let message = transaction.getMessage(id), let value = try? ayuPluginTLMessage(message) else {
        return nil
    }
    return AyuPluginHookedOutgoingMessage.Reference(dialogId: dialogId, messageId: id.id, message: AyuPluginTL.serialize(value))
}

/// Describes the messages the chat screen is about to queue for `peerId`. An entry is nil for a
/// message the hook does not see: a forward, or a chat without an Android dialog id.
public func ayuPluginDescribeOutgoingMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]) -> Signal<[AyuPluginHookedOutgoingMessage?], NoError> {
    guard let dialogId = ayuPluginDialogId(peerId: peerId) else {
        return .single(messages.map { _ in nil })
    }
    return account.postbox.transaction { transaction -> [AyuPluginHookedOutgoingMessage?] in
        return messages.map { message -> AyuPluginHookedOutgoingMessage? in
            guard case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, _, _) = message else {
                return nil
            }
            // A link preview rides as the message's media; the message is still a text message.
            let isLinkPreview = mediaReference?.media is TelegramMediaWebpage
            var isComplete = (mediaReference == nil || isLinkPreview) && inlineStickers.isEmpty && replyToStoryId == nil && localGroupingKey == nil
            var result = AyuPluginHookedOutgoingMessage(dialogId: dialogId, text: text, isMedia: mediaReference != nil && !isLinkPreview, entities: [], replyTo: nil, replyToTop: nil, replyToMessageId: nil, path: nil, document: nil, photo: nil, silent: false, scheduleTime: 0, scheduleRepeatPeriod: 0, disablesLinkPreview: false, invertsMedia: false, effectId: 0, hasSpoiler: false)
            for attribute in attributes {
                if let attribute = attribute as? TextEntitiesMessageAttribute {
                    var peers = SimpleDictionary<PeerId, Peer>()
                    for peerId in attribute.associatedPeerIds {
                        if let peer = transaction.getPeer(peerId) {
                            peers[peerId] = peer
                        }
                    }
                    result.entities = apiEntitiesFromMessageTextEntities(attribute.entities, associatedPeers: peers).map { AyuPluginTL.serialize($0) }
                } else if let attribute = attribute as? NotificationInfoMessageAttribute {
                    result.silent = attribute.flags.contains(.muted)
                    if !attribute.flags.subtracting(.muted).isEmpty { isComplete = false }
                } else if let attribute = attribute as? OutgoingScheduleInfoMessageAttribute {
                    result.scheduleTime = attribute.scheduleTime
                    result.scheduleRepeatPeriod = attribute.repeatPeriod ?? 0
                } else if let attribute = attribute as? OutgoingContentInfoMessageAttribute {
                    result.disablesLinkPreview = attribute.flags.contains(.disableLinkPreviews)
                    if !attribute.flags.subtracting(.disableLinkPreviews).isEmpty { isComplete = false }
                } else if attribute is InvertMediaMessageAttribute {
                    result.invertsMedia = true
                } else if let attribute = attribute as? EffectMessageAttribute {
                    result.effectId = attribute.id
                } else if attribute is MediaSpoilerMessageAttribute {
                    result.hasSpoiler = true
                } else if let attribute = attribute as? WebpagePreviewMessageAttribute {
                    // The server builds the default preview of a re-sent text by itself; a chosen size or link it cannot know.
                    if attribute.forceLargeMedia != nil || attribute.isManuallyAdded { isComplete = false }
                    if attribute.leadingPreview && !attributes.contains(where: { $0 is InvertMediaMessageAttribute }) { isComplete = false }
                } else {
                    isComplete = false
                }
            }
            if let reply = replyToMessageId {
                if reply.quote != nil || reply.innerSubject != nil { isComplete = false }
            }
            if let replyId = replyToMessageId?.messageId, replyId.namespace == Namespaces.Message.Cloud {
                result.replyToMessageId = replyId.id
                result.replyTo = ayuPluginReference(transaction: transaction, id: replyId)
            }
            // A reply or a thread the hook cannot be shown would be dropped by a new message.
            if replyToMessageId != nil && result.replyTo == nil { isComplete = false }
            if let threadId, let topId = Int32(exactly: threadId), topId > 0, peerId.namespace == Namespaces.Peer.CloudChannel {
                result.replyToTop = ayuPluginReference(transaction: transaction, id: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: topId))
            }
            if let media = mediaReference?.media {
                if let file = media as? TelegramMediaFile {
                    if let resource = file.resource as? LocalFileReferenceMediaResource {
                        result.path = resource.localFilePath
                    } else if let document = ayuPluginTLDocument(file) {
                        result.document = AyuPluginTL.serialize(document)
                    }
                } else if let image = media as? TelegramMediaImage, let photo = ayuPluginTLPhoto(image) {
                    result.photo = AyuPluginTL.serialize(photo)
                }
            }
            result.isComplete = isComplete && (threadId == nil || result.replyToTop != nil)
            return result
        }
    }
}

/// Moves entity ranges across one replaced UTF-16 span, the span between the common prefix and
/// the common suffix of the two texts: what a text-only hook leaves the app to do.
private func ayuPluginRemappedEntities(_ entities: [MessageTextEntity], from old: String, to new: String) -> [MessageTextEntity] {
    let a = old as NSString
    let b = new as NSString
    let maximum = min(a.length, b.length)
    var prefix = 0
    while prefix < maximum && a.character(at: prefix) == b.character(at: prefix) {
        prefix += 1
    }
    var suffix = 0
    while suffix < maximum - prefix && a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix) {
        suffix += 1
    }
    let oldEnd = a.length - suffix
    let delta = b.length - a.length
    func map(_ offset: Int) -> Int {
        if offset >= oldEnd {
            return offset + delta
        } else if offset > prefix {
            return prefix
        } else {
            return offset
        }
    }
    return entities.compactMap { entity -> MessageTextEntity? in
        let lower = max(0, min(map(entity.range.lowerBound), b.length))
        let upper = max(lower, min(map(entity.range.upperBound), b.length))
        return upper > lower ? MessageTextEntity(range: lower ..< upper, type: entity.type) : nil
    }
}

/// The message to queue for `peerId` after the hooks ran: `original` with every field in which `result`
/// differs from `described` (what `ayuPluginDescribeOutgoingMessages` returned for it) written
/// back. With `remapEntities` the text was changed by a hook that returns text only, and the
/// existing entities are moved instead of replaced.
///
/// Returns nil when the result cannot be applied (entities that are not `MessageEntity` values of
/// the layer, or that lie outside the text); the caller then sends `original`.
public func ayuPluginApplySendHook(peerId: PeerId, original: EnqueueMessage, described: AyuPluginHookedOutgoingMessage, result: AyuPluginHookedOutgoingMessage, remapEntities: Bool) -> EnqueueMessage? {
    guard case let .message(text, originalAttributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = original else {
        return original
    }
    if result == described {
        return original
    }
    var attributes = originalAttributes
    func replace<T: MessageAttribute>(_ type: T.Type, with attribute: T?) {
        attributes.removeAll(where: { $0 is T })
        if let attribute {
            attributes.append(attribute)
        }
    }
    func moveEntities() {
        if let current = attributes.first(where: { $0 is TextEntitiesMessageAttribute }) as? TextEntitiesMessageAttribute {
            let entities = ayuPluginRemappedEntities(current.entities, from: text, to: result.text)
            replace(TextEntitiesMessageAttribute.self, with: entities.isEmpty ? nil : TextEntitiesMessageAttribute(entities: entities))
        }
    }
    if remapEntities && result.text != text {
        moveEntities()
    } else if result.entities != described.entities {
        // The plugin's entities belong to the text it returned.
        guard let entities = try? ayuPluginMessageEntities(result.entities, text: result.text) else {
            return nil
        }
        replace(TextEntitiesMessageAttribute.self, with: entities.isEmpty ? nil : TextEntitiesMessageAttribute(entities: entities))
    } else if result.text != text, (try? ayuPluginMessageEntities(result.entities, text: result.text)) == nil {
        // The hook returned the entities it was given with a text they no longer fit. They are
        // kept as given while they fit; here they are moved instead of sending ranges past the text.
        moveEntities()
    }
    if result.silent != described.silent {
        var flags = (attributes.first(where: { $0 is NotificationInfoMessageAttribute }) as? NotificationInfoMessageAttribute)?.flags ?? []
        if result.silent {
            flags.insert(.muted)
        } else {
            flags.remove(.muted)
        }
        replace(NotificationInfoMessageAttribute.self, with: flags.isEmpty ? nil : NotificationInfoMessageAttribute(flags: flags))
    }
    if result.scheduleTime != described.scheduleTime || result.scheduleRepeatPeriod != described.scheduleRepeatPeriod {
        replace(OutgoingScheduleInfoMessageAttribute.self, with: result.scheduleTime > 0 ? OutgoingScheduleInfoMessageAttribute(scheduleTime: result.scheduleTime, repeatPeriod: result.scheduleRepeatPeriod > 0 ? result.scheduleRepeatPeriod : nil) : nil)
    }
    if result.disablesLinkPreview != described.disablesLinkPreview {
        var flags = (attributes.first(where: { $0 is OutgoingContentInfoMessageAttribute }) as? OutgoingContentInfoMessageAttribute)?.flags ?? []
        if result.disablesLinkPreview {
            flags.insert(.disableLinkPreviews)
        } else {
            flags.remove(.disableLinkPreviews)
        }
        replace(OutgoingContentInfoMessageAttribute.self, with: flags.isEmpty ? nil : OutgoingContentInfoMessageAttribute(flags: flags))
    }
    if result.invertsMedia != described.invertsMedia {
        replace(InvertMediaMessageAttribute.self, with: result.invertsMedia ? InvertMediaMessageAttribute() : nil)
    }
    if result.effectId != described.effectId {
        replace(EffectMessageAttribute.self, with: result.effectId != 0 ? EffectMessageAttribute(id: result.effectId) : nil)
    }
    if result.hasSpoiler != described.hasSpoiler {
        replace(MediaSpoilerMessageAttribute.self, with: result.hasSpoiler ? MediaSpoilerMessageAttribute() : nil)
    }
    var replySubject = replyToMessageId
    if result.replyToMessageId != described.replyToMessageId {
        if let id = result.replyToMessageId {
            guard id > 0 else {
                return nil
            }
            // A hook names a message of the chat the message goes to.
            replySubject = EngineMessageReplySubject(messageId: MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: id), quote: nil, innerSubject: nil)
        } else {
            replySubject = nil
        }
    }
    return .message(text: result.text, attributes: attributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replySubject, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
}
