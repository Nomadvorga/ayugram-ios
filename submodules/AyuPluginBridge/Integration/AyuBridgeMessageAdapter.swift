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

/// Integer tags emitted by the Python SDK's `HookResult.to_bridge()`.
public enum AyuBridgeSendHookStrategy: Int64, Sendable {
    case `default` = 0
    case cancel = 1
    case modify = 2
    case modifyFinal = 3
}

/// Pure state for the SDK send-message callback chain. The caller owns callback
/// ordering, generation checks and asynchronous delivery. Only message/caption
/// strings are mutable; account and destination always come from the app.
public struct AyuBridgeSendHookChain: Equatable, Sendable {
    public static let maximumTextBytes = 65_536

    public let accountIndex: Int64
    public let peerID: Int64
    public private(set) var message: String?
    public private(set) var caption: String?
    public private(set) var isCancelled = false
    public private(set) var isFinal = false

    public init(message: String?, caption: String?, peerID: Int64, accountIndex: Int64) {
        self.message = message
        self.caption = caption
        self.peerID = peerID
        self.accountIndex = accountIndex
    }

    public var isFinished: Bool { self.isCancelled || self.isFinal }

    /// A fresh snapshot for each callback, with exact signed Int64 context.
    /// Account is a separate callback argument, never a mutable params field.
    public var arguments: [AyuBridgeValue] {
        var params: [String: AyuBridgeValue] = ["peer": .integer(self.peerID)]
        if let message = self.message { params["message"] = .string(message) }
        if let caption = self.caption { params["caption"] = .string(caption) }
        return [.integer(self.accountIndex), .object(params)]
    }

    /// Nil, unknown strategies and malformed changes keep the last valid content.
    /// CANCEL stops immediately. MODIFY_FINAL stops even if its params are absent
    /// or malformed, matching Android's final-result behavior. DEFAULT ignores
    /// params. Missing mutable fields preserve their current values, while null
    /// cannot remove a present field or inject an absent one. Empty captions are
    /// valid; an empty text message is not a sendable replacement.
    public mutating func apply(_ result: AyuBridgeValue?) {
        guard !self.isFinished, let object = result?.object,
              let raw = object["strategy"]?.integer,
              let strategy = AyuBridgeSendHookStrategy(rawValue: raw) else { return }
        switch strategy {
        case .default:
            return
        case .cancel:
            self.isCancelled = true
        case .modify, .modifyFinal:
            if let params = object["params"]?.object,
               let replacement = self.validatedReplacement(params) {
                self.message = replacement.message
                self.caption = replacement.caption
            }
            self.isFinal = strategy == .modifyFinal
        }
    }

    private func validatedReplacement(_ params: [String: AyuBridgeValue]) -> (message: String?, caption: String?)? {
        guard Set(params.keys).isSubset(of: ["peer", "message", "caption"]) else { return nil }
        if let peer = params["peer"], peer != .integer(self.peerID) { return nil }
        var message = self.message
        var caption = self.caption
        for (key, current) in [("message", self.message), ("caption", self.caption)] {
            guard let value = params[key] else { continue }
            // An absent slot remains absent; plugins cannot switch the native
            // send between a text message and a media caption.
            if current == nil {
                guard value == .null else { return nil }
                continue
            }
            guard let text = value.string, text.utf8.count <= Self.maximumTextBytes,
                  key != "message" || !text.isEmpty else { return nil }
            if key == "message" { message = text } else { caption = text }
        }
        return (message, caption)
    }
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
        if let reason = pre.cancelled { throw AyuBridgeMessageError.missingCapability(name: "send.cancelled", reason: reason) }
        let sent = try await self.transport.send(self.decodeRequest(pre.payload, original: request, now: now))
        _ = try self.hooks.publish(.messageSendPost, payload: ["message": AyuBridgeValue.encodable(sent)])
        return sent
    }

    public func edit(_ request: AyuBridgeEditMessageRequest) async throws -> AyuBridgeIncomingMessage {
        if let entities = request.entities {
            let content = request.text ?? request.caption ?? ""
            for (index, entity) in entities.enumerated() where entity.offset < 0 || entity.length < 0 || Int(entity.offset) + Int(entity.length) > (content as NSString).length {
                throw AyuBridgeMessageError.entityOutOfRange(index: index)
            }
        }
        let pre = try self.hooks.publish(.messageEditPre, payload: ["request": AyuBridgeValue.encodable(request)])
        if let reason = pre.cancelled { throw AyuBridgeMessageError.missingCapability(name: "edit.cancelled", reason: reason) }
        let edited = try await self.transport.edit(self.decodeEditRequest(pre.payload, original: request))
        _ = try self.hooks.publish(.messageEditPost, payload: ["message": AyuBridgeValue.encodable(edited)])
        return edited
    }

    public func delete(accountID: Int64, chatID: Int64, messageID: Int64) async throws {
        let pre = try self.hooks.publish(.messageDeletePre, payload: ["account_id": .integer(accountID), "chat_id": .integer(chatID), "message_id": .integer(messageID)])
        if let reason = pre.cancelled { throw AyuBridgeMessageError.missingCapability(name: "delete.cancelled", reason: reason) }
        try await self.transport.delete(accountID: accountID, chatID: chatID, messageID: messageID)
    }

    private func decodeRequest(_ payload: [String: AyuBridgeValue], original: AyuBridgeOutgoingMessage, now: Date) -> AyuBridgeOutgoingMessage {
        guard let data = try? JSONEncoder().encode(payload["request"] ?? .null),
              let request = try? JSONDecoder().decode(AyuBridgeOutgoingMessage.self, from: data),
              request.accountID == original.accountID, request.chatID == original.chatID,
              Self.boundedText(request.text), Self.boundedText(request.caption),
              (try? request.validate(now: now)) != nil else { return original }
        return request
    }

    private func decodeEditRequest(_ payload: [String: AyuBridgeValue], original: AyuBridgeEditMessageRequest) -> AyuBridgeEditMessageRequest {
        guard let data = try? JSONEncoder().encode(payload["request"] ?? .null),
              let request = try? JSONDecoder().decode(AyuBridgeEditMessageRequest.self, from: data),
              request.accountID == original.accountID, request.chatID == original.chatID,
              request.messageID == original.messageID,
              Self.boundedText(request.text), Self.boundedText(request.caption) else { return original }
        let length = ((request.text ?? request.caption ?? "") as NSString).length
        guard (request.entities ?? []).allSatisfy({ $0.offset >= 0 && $0.length >= 0 && Int($0.offset) + Int($0.length) <= length }) else { return original }
        return request
    }

    private static func boundedText(_ text: String?) -> Bool {
        (text?.utf8.count ?? 0) <= AyuBridgeSendHookChain.maximumTextBytes
    }
}

extension AyuBridgeValue {
    init<T: Encodable>(encodable value: T) {
        let data = try? JSONEncoder().encode(value)
        self = data.flatMap { try? JSONDecoder().decode(AyuBridgeValue.self, from: $0) } ?? .null
    }
}
