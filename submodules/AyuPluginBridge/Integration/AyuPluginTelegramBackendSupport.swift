import Foundation

/// Decisions a Telegram backend makes before it touches Telegram: which dialog
/// an Android id names, and what an outgoing message or an edit asks for. They
/// live here, without a Telegram type, so that they are compiled and tested
/// with this module; the app's adapter only carries their results out.

/// The peer behind an Android dialog id.
public enum AyuPluginTelegramDialog: Sendable, Equatable {
    case user(Int64)
    /// A basic group or a channel: Android negates both ids into one space.
    case chat(Int64)

    /// Telegram ids fit 52 bits; the app's peer id type cannot hold more than 56.
    public static let maximumPeerID: Int64 = (1 << 52) - 1

    /// Nil for 0 and for ids outside the peer range, which covers Android's
    /// encrypted-chat and folder dialog ids (bits 62 and 61).
    public init?(dialogID: Int64) {
        if (1...Self.maximumPeerID).contains(dialogID) {
            self = .user(dialogID)
        } else if dialogID < 0, dialogID >= -Self.maximumPeerID {
            self = .chat(-dialogID)
        } else {
            return nil
        }
    }

    public var dialogID: Int64 {
        switch self {
        case let .user(id): return id
        case let .chat(id): return -id
        }
    }

    /// The positive id of `telegram.peer`, when it is one the app can hold.
    public static func isPeerID(_ id: Int64) -> Bool { (1...Self.maximumPeerID).contains(id) }
}

/// `telegram.send_message` reduced to what the iOS send queue takes. Building
/// it refuses, by name, every request that would otherwise lose a field.
public struct AyuPluginTelegramSendPlan: Sendable, Equatable {
    public enum Media: Sendable, Equatable {
        case none
        /// A local file. `description` is the `document` or `photo` the plugin
        /// sent with it (MIME type, attributes), when it sent one.
        case file(path: String, kind: AyuPluginTelegramAttachmentKind, description: Data?)
        /// An existing document or photo, as boxed TL.
        case document(Data)
        case photo(Data)
    }

    public struct Reply: Sendable, Equatable {
        public var dialog: AyuPluginTelegramDialog
        public var messageID: Int32
    }

    public var dialog: AyuPluginTelegramDialog
    /// The message text, or the caption of `media`.
    public var text: String
    public var entities: [Data]
    public var media: Media
    public var reply: Reply?
    /// Top message of the thread or topic the message goes to.
    public var threadMessageID: Int32?
    public var silent = false
    public var scheduleDate: Int32?
    public var scheduleRepeatPeriod: Int32?
    public var disablesLinkPreview = false
    public var invertsMedia = false
    public var effectID: Int64?
    public var hasSpoiler = false
    public var highQuality = false

    /// The `params` keys this plan carries; a backend that executes the whole
    /// plan lists exactly these in `sendMessageParameters`.
    public static let supportedParameters: Set<String> = [
        "peer", "message", "caption", "entities", "replyToMsg", "replyToTopMsg", "notify", "scheduleDate",
        "scheduleRepeatPeriod", "searchLinks", "invert_media", "effect_id", "hasMediaSpoilers", "sendingHighQuality",
        "path", "attach", "document", "photo",
    ]

    public init(_ message: AyuPluginTelegramOutgoingMessage) throws {
        func invalid(_ text: String) -> AyuPluginTelegramBackendError { .invalidArguments(text) }
        var named = Set(message.keys)
        named.formUnion(message.booleans.keys)
        named.formUnion(message.integers.keys)
        named.formUnion(message.objects.keys)
        if message.parameters != nil { named.insert("params") }
        if let refused = named.subtracting(Self.supportedParameters).sorted().first {
            throw AyuPluginTelegramBackendError.unsupported("telegram.send_message parameter " + refused)
        }
        guard let dialog = AyuPluginTelegramDialog(dialogID: message.peer) else {
            throw invalid("peer is not a user, group or channel")
        }
        self.dialog = dialog

        let document = message.objects["document"]
        let photo = message.objects["photo"]
        guard document == nil || photo == nil else { throw invalid("document and photo exclude each other") }
        if let path = message.path {
            if let kind = message.attachment {
                guard photo == nil || kind == .photo else { throw invalid("photo describes a photo attachment only") }
                guard document == nil || kind != .photo else { throw invalid("document does not describe a photo attachment") }
                self.media = .file(path: path, kind: kind, description: document ?? photo)
            } else if let document {
                self.media = .file(path: path, kind: .document, description: document)
            } else if let photo {
                self.media = .file(path: path, kind: .photo, description: photo)
            } else {
                throw invalid("path needs attach, document or photo")
            }
        } else {
            guard message.attachment == nil else { throw invalid("attach needs path") }
            if let document { self.media = .document(document) } else if let photo { self.media = .photo(photo) } else { self.media = .none }
        }

        if self.media == .none {
            guard message.caption == nil else { throw invalid("caption needs an attachment") }
            guard let text = message.message, !text.isEmpty else { throw invalid("message must not be empty") }
            self.text = text
        } else {
            guard message.message == nil else { throw invalid("an attachment takes caption, not message") }
            self.text = message.caption ?? ""
        }
        self.entities = message.entities ?? []
        guard self.entities.isEmpty || !self.text.isEmpty else { throw invalid("entities need text") }

        if let reply = message.replyTo {
            guard let replyDialog = AyuPluginTelegramDialog(dialogID: reply.dialogID), reply.messageID > 0 else {
                throw invalid("replyToMsg is not a sent message")
            }
            self.reply = Reply(dialog: replyDialog, messageID: reply.messageID)
        }
        if let top = message.replyToTop {
            guard top.dialogID == message.peer, top.messageID > 0 else { throw invalid("replyToTopMsg is not a message of the dialog") }
            self.threadMessageID = top.messageID
        }

        self.silent = message.booleans["notify"] == false
        self.disablesLinkPreview = message.booleans["searchLinks"] == false
        self.invertsMedia = message.booleans["invert_media"] == true
        if message.booleans["hasMediaSpoilers"] == true {
            switch self.media {
            case .file(_, .photo, _), .file(_, .video, _), .document, .photo: self.hasSpoiler = true
            default: throw invalid("hasMediaSpoilers needs a photo or a video")
            }
        }
        if message.booleans["sendingHighQuality"] == true {
            guard case .file(_, .photo, _) = self.media else { throw invalid("sendingHighQuality needs a photo file") }
            self.highQuality = true
        }
        if let date = message.integers["scheduleDate"], date != 0 {
            guard let value = Int32(exactly: date), value > 0 else { throw invalid("scheduleDate is out of range") }
            self.scheduleDate = value
        }
        if let period = message.integers["scheduleRepeatPeriod"], period != 0 {
            guard let value = Int32(exactly: period), value > 0, self.scheduleDate != nil else { throw invalid("scheduleRepeatPeriod needs scheduleDate") }
            self.scheduleRepeatPeriod = value
        }
        if let effect = message.integers["effect_id"], effect != 0 { self.effectID = effect }
    }
}

/// `telegram.edit_message` reduced to what the iOS edit request takes.
public struct AyuPluginTelegramEditPlan: Sendable, Equatable {
    public var dialog: AyuPluginTelegramDialog
    public var messageID: Int32
    /// Nil keeps the message's text and entities.
    public var text: String?
    public var entities: [Data]
    public var attachment: AyuPluginTelegramMessageEdit.Attachment?

    public init(_ edit: AyuPluginTelegramMessageEdit) throws {
        // Android's free-form edit options have no counterpart in the iOS edit request.
        guard edit.parameters == nil else { throw AyuPluginTelegramBackendError.unsupported("telegram.edit_message parameter params") }
        guard let dialog = AyuPluginTelegramDialog(dialogID: edit.dialogID) else {
            throw AyuPluginTelegramBackendError.invalidArguments("dialog_id is not a user, group or channel")
        }
        guard edit.messageID > 0 else { throw AyuPluginTelegramBackendError.invalidArguments("message_id is not a sent message") }
        guard edit.text != nil || edit.attachment != nil else { throw AyuPluginTelegramBackendError.invalidArguments("An edit needs text or attach") }
        guard edit.entities == nil || edit.text != nil else { throw AyuPluginTelegramBackendError.invalidArguments("entities need text") }
        self.dialog = dialog
        self.messageID = edit.messageID
        self.text = edit.text
        self.entities = edit.entities ?? []
        self.attachment = edit.attachment
    }
}

public extension AyuPluginTelegramConnectionState.Status {
    /// Android's connection state for the app's network state: connecting
    /// through a proxy is its own value, and fetching missed updates over a
    /// live connection is `updating`.
    init(networkAvailable: Bool, connected: Bool, updating: Bool, usesProxy: Bool) {
        if !networkAvailable {
            self = .waitingForNetwork
        } else if !connected {
            self = usesProxy ? .connectingToProxy : .connecting
        } else {
            self = updating ? .updating : .connected
        }
    }
}
