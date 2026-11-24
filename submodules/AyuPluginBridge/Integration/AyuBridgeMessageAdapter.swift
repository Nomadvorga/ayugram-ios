import Foundation

/// Message DTO and send/edit/delete semantics, protocol-level: the app host
/// implements `AyuBridgeMessageTransport`, plugins get exact text, entities
/// (UTF-16 offsets, as Telegram encodes them), caption, reply, topic, silent,
/// schedule and account scoping. No TelegramCore import.

public enum AyuBridgeMessageEntityKind: String, Codable, Sendable, CaseIterable {
    case mention, hashtag, botCommand = "bot_command", url, email, bold, italic, underline, strikethrough = "strikethrough"
    case spoiler, code, pre, customEmoji = "custom_emoji", textUrl = "text_url", blockquote
}

public struct AyuBridgeMessageEntity: Codable, Equatable, Sendable {
    public let kind: AyuBridgeMessageEntityKind
    /// UTF-16 code unit offset, matching Telegram's wire format.
    public let offset: Int32
    /// UTF-16 code unit length.
    public let length: Int32
    public var url: String?
    public var documentID: Int64?
    public var language: String?

    public init(kind: AyuBridgeMessageEntityKind, offset: Int32, length: Int32, url: String? = nil, documentID: Int64? = nil, language: String? = nil) {
        self.kind = kind; self.offset = offset; self.length = length; self.url = url; self.documentID = documentID; self.language = language
    }
}

public enum AyuBridgeMessageError: Error, Equatable, Sendable {
    case entityOutOfRange(index: Int)
    case emptyText
    case silentAndScheduleConflict
    case scheduleInPast(Date)
    case transportUnavailable(String)
    case missingCapability(name: String, reason: String)
    case notEditable
}

public struct AyuBridgeOutgoingMessage: Codable, Equatable, Sendable {
    public var accountID: Int64
    public var chatID: Int64
    public var text: String?
    public var caption: String?
    public var entities: [AyuBridgeMessageEntity]
    public var replyToMessageID: Int64?
    public var topicID: Int64?
    public var silent: Bool
    public var scheduleDate: Date?
    public var media: [AyuBridgeValue]

    public init(accountID: Int64, chatID: Int64, text: String? = nil, caption: String? = nil,
                entities: [AyuBridgeMessageEntity] = [], replyToMessageID: Int64? = nil, topicID: Int64? = nil,
                silent: Bool = false, scheduleDate: Date? = nil, media: [AyuBridgeValue] = []) {
        self.accountID = accountID; self.chatID = chatID; self.text = text; self.caption = caption
        self.entities = entities; self.replyToMessageID = replyToMessageID; self.topicID = topicID
        self.silent = silent; self.scheduleDate = scheduleDate; self.media = media
    }

    /// Send rules: text or caption or media must be present; silent and
    /// scheduled are mutually exclusive; schedule must be in the future.
    public func validate(now: Date = Date()) throws {
        if (self.text ?? "").isEmpty && (self.caption ?? "").isEmpty && self.media.isEmpty { throw AyuBridgeMessageError.emptyText }
        if self.silent && self.scheduleDate != nil { throw AyuBridgeMessageError.silentAndScheduleConflict }
        if let date = self.scheduleDate, date <= now { throw AyuBridgeMessageError.scheduleInPast(date) }
        let content = self.text ?? self.caption ?? ""
        for (index, entity) in self.entities.enumerated() where Int(entity.offset) + Int(entity.length) > (content as NSString).length || entity.offset < 0 || entity.length < 0 {
            throw AyuBridgeMessageError.entityOutOfRange(index: index)
        }
    }
}

public struct AyuBridgeIncomingMessage: Codable, Equatable, Sendable {
    public let accountID: Int64
    public let chatID: Int64
    public let messageID: Int64
    public let senderID: Int64
    public let text: String?
    public let entities: [AyuBridgeMessageEntity]
    public let date: Date
    public let isOutgoing: Bool
}

public struct AyuBridgeEditMessageRequest: Codable, Equatable, Sendable {
    public var accountID: Int64
    public var chatID: Int64
    public var messageID: Int64
    public var text: String?
    /// nil entities mean "keep the message's current entities", matching edit
    /// semantics; an empty array clears them.
    public var entities: [AyuBridgeMessageEntity]?
    public var caption: String?

    public init(accountID: Int64, chatID: Int64, messageID: Int64, text: String? = nil, entities: [AyuBridgeMessageEntity]? = nil, caption: String? = nil) {
        self.accountID = accountID; self.chatID = chatID; self.messageID = messageID
        self.text = text; self.entities = entities; self.caption = caption
    }
}

public enum AyuBridgeLifecycleEvent: Codable, Sendable {
    case received(AyuBridgeIncomingMessage)
    case edited(AyuBridgeIncomingMessage)
    case deleted(accountID: Int64, chatID: Int64, messageID: Int64)
}

/// The app implements this on its main actor; the adapter awaits it.
public protocol AyuBridgeMessageTransport: Sendable {
    func send(_ request: AyuBridgeOutgoingMessage) async throws -> AyuBridgeIncomingMessage
    func edit(_ request: AyuBridgeEditMessageRequest) async throws -> AyuBridgeIncomingMessage
    func delete(accountID: Int64, chatID: Int64, messageID: Int64) async throws
}

/// Converts Swift `String.CharacterView` offsets to Telegram's UTF-16 offsets.
/// An entity over an astral-plane emoji (surrogate pair) is +2 UTF-16 units per
/// code point, which is the correction plugins routinely get wrong.
public enum AyuBridgeEntityOffsets {
    public static func utf16Offset(characterOffset: Int, characterLength: Int, in text: String) -> (offset: Int32, length: Int32) {
        let prefix = text.prefix(characterOffset)
        let range = text.dropFirst(characterOffset).prefix(characterLength)
        return (Int32((prefix as NSString).length), Int32((range as NSString).length))
    }

    public static func characterOffset(utf16Offset: Int32, utf16Length: Int32, in text: String) -> (offset: Int, length: Int) {
        let utf16 = Array(text.utf16)
        let start = Int(utf16Offset), end = min(Int(utf16Offset) + Int(utf16Length), utf16.count)
        guard start <= end else { return (0, 0) }
        let prefixCount = utf16[..<start].filter { !UTF16.isTrailSurrogate($0) }.count
        let rangeCount = utf16[start..<end].filter { !UTF16.isTrailSurrogate($0) }.count
        return (prefixCount, rangeCount)
    }

    private enum UTF16 {
        static func isTrailSurrogate(_ unit: UInt16) -> Bool { unit >= 0xDC00 && unit <= 0xDFFF }
    }
}

/// Adapter side used by the native host: validates requests, applies hook
/// registries around the transport call, and surfaces typed errors.
public final class AyuBridgeMessageAdapter: Sendable {
    public let transport: any AyuBridgeMessageTransport
    public let hooks: AyuBridgeHookRegistry

    public init(transport: any AyuBridgeMessageTransport, hooks: AyuBridgeHookRegistry) {
        self.transport = transport
        self.hooks = hooks
    }

    public func send(_ request: AyuBridgeOutgoingMessage, now: Date = Date()) async throws -> AyuBridgeIncomingMessage {
        try request.validate(now: now)
        let pre = try self.hooks.publish(.messageSendPre, payload: ["request": AyuBridgeValue.encodable(request)])
        if let reason = pre.cancelled { throw AyuBridgeMessageError.missingCapability(name: "send.cancelled", reason) }
        let sent = try await self.transport.send(self.decodeRequest(pre.payload))
        _ = try self.hooks.publish(.messageSendPost, payload: ["message": AyuBridgeValue.encodable(sent)])
        return sent
    }

    public func edit(_ request: AyuBridgeEditMessageRequest) async throws -> AyuBridgeIncomingMessage {
        if let entities = request.entities {
            let content = request.text ?? request.caption ?? ""
            for (index, entity) in entities.enumerated() where Int(entity.offset) + Int(entity.length) > (content as NSString).length {
                throw AyuBridgeMessageError.entityOutOfRange(index: index)
            }
        }
        let pre = try self.hooks.publish(.messageEditPre, payload: ["request": AyuBridgeValue.encodable(request)])
        if let reason = pre.cancelled { throw AyuBridgeMessageError.missingCapability(name: "edit.cancelled", reason) }
        let edited = try await self.transport.edit(self.decodeEditRequest(pre.payload))
        _ = try self.hooks.publish(.messageEditPost, payload: ["message": AyuBridgeValue.encodable(edited)])
        return edited
    }

    public func delete(accountID: Int64, chatID: Int64, messageID: Int64) async throws {
        let pre = try self.hooks.publish(.messageDeletePre, payload: ["account_id": .integer(accountID), "chat_id": .integer(chatID), "message_id": .integer(messageID)])
        if let reason = pre.cancelled { throw AyuBridgeMessageError.missingCapability(name: "delete.cancelled", reason) }
        try await self.transport.delete(accountID: accountID, chatID: chatID, messageID: messageID)
    }

    private func decodeRequest(_ payload: [String: AyuBridgeValue]) -> AyuBridgeOutgoingMessage {
        let data = try? JSONEncoder().encode(payload["request"] ?? .null)
        return (try? JSONDecoder().decode(AyuBridgeOutgoingMessage.self, from: data ?? Data())) ?? AyuBridgeOutgoingMessage(accountID: 0, chatID: 0, text: "")
    }

    private func decodeEditRequest(_ payload: [String: AyuBridgeValue]) -> AyuBridgeEditMessageRequest {
        let data = try? JSONEncoder().encode(payload["request"] ?? .null)
        return (try? JSONDecoder().decode(AyuBridgeEditMessageRequest.self, from: data ?? Data())) ?? AyuBridgeEditMessageRequest(accountID: 0, chatID: 0, messageID: 0)
    }
}

extension AyuBridgeValue {
    init<T: Encodable>(encodable value: T) {
        let data = try? JSONEncoder().encode(value)
        self = data.flatMap { try? JSONDecoder().decode(AyuBridgeValue.self, from: $0) } ?? .null
    }
}
