import Foundation

/// The bridge side of `Python/protocol-telegram.md` talks to Telegram through
/// this file's protocol only. The module has no Telegram dependency: TL objects
/// are opaque boxed bytes, ids are Android dialog ids, and every type here is a
/// value. The app implements the protocol next to TelegramCore (see
/// `Resources/CommonBridge/TELEGRAM-BACKEND.md`).

/// An account slot of the application bridge. `identity` changes when the slot
/// is rebound, so a backend can refuse a stale reference.
public struct AyuPluginTelegramAccount: Sendable, Equatable {
    public let index: Int64
    public let identity: UUID
    public let userID: Int64
    public init(index: Int64, identity: UUID, userID: Int64) {
        self.index = index; self.identity = identity; self.userID = userID
    }
}

/// Failures a backend may report. The text is shown to the plugin: it names an
/// argument or a capability, never account data.
public enum AyuPluginTelegramBackendError: Error, Sendable, Equatable {
    case invalidArguments(String)
    case unsupported(String)
    case accountUnavailable
    case screenUnavailable
    case resourceLimit(String)
}

public struct AyuPluginTelegramRPCError: Sendable, Equatable {
    public var code: Int32
    public var text: String
    public init(code: Int32, text: String) { self.code = code; self.text = text }
}

public enum AyuPluginTelegramRequestResult: Sendable, Equatable {
    /// Boxed response bytes; a bare vector for a function that returns one.
    case response(Data)
    case rpcError(AyuPluginTelegramRPCError)
    /// No answer from the server: delivered to the plugin as error code -1.
    case transportFailure(String)
    /// A pre-request hook of any plugin cancelled the request.
    case cancelledByHook
}

public struct AyuPluginTelegramCancellation: Sendable {
    private let action: @Sendable () -> Void
    public init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    public func cancel() { self.action() }
}

public struct AyuPluginTelegramConnectionState: Sendable, Equatable {
    /// Android's `ConnectionsManager.ConnectionState*` values.
    public enum Status: Int64, Sendable { case connecting = 1, waitingForNetwork, connected, connectingToProxy, updating }
    public var timeMilliseconds: Int64
    public var timeDifference: Int32
    public var status: Status
    public var datacenterID: Int32
    public init(timeMilliseconds: Int64, timeDifference: Int32, status: Status, datacenterID: Int32) {
        self.timeMilliseconds = timeMilliseconds; self.timeDifference = timeDifference
        self.status = status; self.datacenterID = datacenterID
    }
}

/// The wire form of an SDK `MessageObject`; the host identifies the message by ids.
public struct AyuPluginTelegramMessageReference: Sendable, Equatable {
    public var dialogID: Int64
    public var messageID: Int32
    public var message: Data
    public init(dialogID: Int64, messageID: Int32, message: Data) {
        self.dialogID = dialogID; self.messageID = messageID; self.message = message
    }
}

public enum AyuPluginTelegramAttachmentKind: String, Sendable, CaseIterable { case photo, document, video, audio }

/// `telegram.send_message` after bridge validation. `keys` lists the `params`
/// keys the plugin sent (sorted); every one of them is in the backend's
/// `sendMessageParameters`.
public struct AyuPluginTelegramOutgoingMessage: Sendable, Equatable {
    public var keys: [String] = []
    public var peer: Int64
    public var message: String?
    public var caption: String?
    public var entities: [Data]?
    public var replyTo: AyuPluginTelegramMessageReference?
    public var replyToTop: AyuPluginTelegramMessageReference?
    /// `notify`, `searchLinks`, `invert_media`, `hasMediaSpoilers`, `updateStickersOrder`, `sendingHighQuality`.
    public var booleans: [String: Bool] = [:]
    /// `scheduleDate`, `scheduleRepeatPeriod`, `ttl`, `effect_id`, `quick_reply_shortcut_id`,
    /// `monoForumPeer`, `payStars`, `stars`, `dice_stake`.
    public var integers: [String: Int64] = [:]
    public var parameters: [String: String]?
    public var path: String?
    public var attachment: AyuPluginTelegramAttachmentKind?
    /// `document`, `photo`, `location`, `poll`, `game`, `invoice`, `mediaWebPage`, `webPage`,
    /// `replyMarkup`, `user`, `todo`, `cover`, `richMessage` as boxed TL.
    public var objects: [String: Data] = [:]
    public init(peer: Int64) { self.peer = peer }
}

public struct AyuPluginTelegramMessageEdit: Sendable, Equatable {
    public struct Attachment: Sendable, Equatable {
        public var kind: AyuPluginTelegramAttachmentKind
        public var path: String
        public var spoiler: Bool
        public init(kind: AyuPluginTelegramAttachmentKind, path: String, spoiler: Bool) {
            self.kind = kind; self.path = path; self.spoiler = spoiler
        }
    }
    public var dialogID: Int64
    public var messageID: Int32
    public var text: String?
    public var entities: [Data]?
    public var attachment: Attachment?
    public var parameters: [String: String]?
    public init(dialogID: Int64, messageID: Int32) { self.dialogID = dialogID; self.messageID = messageID }
}

public enum AyuPluginTelegramPeerKind: String, Sendable, CaseIterable {
    case user, chat
    case userFull = "user_full"
    case chatFull = "chat_full"
}

public enum AyuPluginTelegramNavigationTarget: Sendable, Equatable {
    public enum Screen: String, Sendable, CaseIterable { case chat, profile }
    case dialog(id: Int64, screen: Screen, messageID: Int32?)
    /// Android's `openByUserName(username, fragment, type)`.
    case username(String, type: Int32)
}

public enum AyuPluginTelegramPlayerAction: Sendable, Equatable {
    case state, pause, resume, next, previous, stop
    case seek(Double)
}

public struct AyuPluginTelegramPlayerState: Sendable, Equatable {
    /// Account of the loaded message, or the selected account when nothing is loaded.
    public var accountIndex: Int64
    public var paused: Bool
    public var message: Data?
    public var progress: Double?
    public var positionMilliseconds: Int64?
    public var durationMilliseconds: Int64?
    public init(accountIndex: Int64, paused: Bool, message: Data? = nil, progress: Double? = nil,
                positionMilliseconds: Int64? = nil, durationMilliseconds: Int64? = nil) {
        self.accountIndex = accountIndex; self.paused = paused; self.message = message; self.progress = progress
        self.positionMilliseconds = positionMilliseconds; self.durationMilliseconds = durationMilliseconds
    }
}

/// What `telegram.screen` adds to `AyuPluginScreenSnapshot`. The app fills it
/// in the same snapshot the fragment adapter reads, so both describe one screen.
public struct AyuPluginTelegramScreen: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable { case chat, profile, dialogs, other }
    public var kind: Kind
    /// Present for `chat` and `profile`.
    public var dialogID: Int64?
    public var topicID: Int32?
    /// Android's `ChatActivity.MODE_*`.
    public var chatMode: Int32?
    public init(kind: Kind, dialogID: Int64? = nil, topicID: Int32? = nil, chatMode: Int32? = nil) {
        self.kind = kind; self.dialogID = dialogID; self.topicID = topicID; self.chatMode = chatMode
    }
}

/// Union of every active plugin's hook set. The backend consults it on its own
/// queues and calls the bridge only for a listed constructor.
public struct AyuPluginTelegramHookFilter: Sendable, Equatable {
    public var requests: Set<UInt32> = []
    public var updates: Set<UInt32> = []
    public var containers: Set<UInt32> = []
    public init() {}
    public var isEmpty: Bool { self.requests.isEmpty && self.updates.isEmpty && self.containers.isEmpty }
}

public enum AyuPluginTelegramHookDecision: Sendable, Equatable {
    /// The object to continue with: the original bytes or a plugin's replacement.
    case proceed(Data)
    case cancel
}

public struct AyuPluginTelegramResponse: Sendable, Equatable {
    public var response: Data?
    public var error: AyuPluginTelegramRPCError?
    public init(response: Data?, error: AyuPluginTelegramRPCError?) { self.response = response; self.error = error }
}

/// An outgoing message as the send-message hook sees it. Unset optionals and
/// default values are not sent to the plugin (it then reads Android's default).
public struct AyuPluginTelegramHookedMessage: Sendable, Equatable {
    public var peer: Int64
    public var message: String?
    public var caption: String?
    /// UTF-16 offsets into `message`, else `caption`. Nil when there are none.
    public var entities: [Data]?
    /// The replied message and the thread's top message, when the app can
    /// describe them as TL. A reply the app leaves out is invisible to hooks.
    public var replyTo: AyuPluginTelegramMessageReference?
    public var replyToTop: AyuPluginTelegramMessageReference?
    /// Reply targets after the hooks ran. The bridge derives them from the two
    /// references and from plugin answers; an id that differs from its
    /// reference is a plugin's change, and that reference is then nil.
    public var replyToMessageID: Int32?
    public var replyToTopMessageID: Int32?
    public var path: String?
    public var document: Data?
    public var photo: Data?
    public var notify = true
    public var scheduleDate: Int32 = 0
    public var scheduleRepeatPeriod: Int32 = 0
    public var searchLinks = true
    public var invertMedia = false
    public var effectID: Int64 = 0
    public var hasMediaSpoilers = false
    public var monoForumPeer: Int64 = 0
    public var quickReplyShortcutID: Int32 = 0
    public var payStars: Int64 = 0
    /// True when these fields are all there is to the message: no attachment, quote, preview option
    /// or other part the struct cannot carry. A plugin may then send its hook's object again as a
    /// new message (Android's cancel, change, `sendMessage(params)`); otherwise the SDK refuses that.
    public var isComplete = false
    public init(peer: Int64) { self.peer = peer }
}

public enum AyuPluginTelegramSendDecision: Sendable, Equatable {
    /// `remapEntities` is true when the last text change came from a three-field
    /// `hooks.register` hook, which returns text only: `entities` then still
    /// describe the text before that change and the app remaps them itself.
    case send(AyuPluginTelegramHookedMessage, remapEntities: Bool)
    case cancel
}

/// Implemented by the app. Methods are called on the bridge's host worker,
/// never on main, and return promptly; a completion may run on any thread and
/// is called exactly once. The bridge waits a bounded time for the state reads
/// and ignores a completion that arrives later.
public protocol AyuPluginTelegramBackend: AnyObject, Sendable {
    /// The `telegram.*` operations this backend implements exactly as the
    /// contract says. The bridge declares nothing else.
    var operations: Set<String> { get }
    /// `params` keys of `telegram.send_message` the backend honours; the bridge
    /// refuses any other key by name instead of dropping it.
    var sendMessageParameters: Set<String> { get }
    /// Fields of a send-message hook result the backend applies. A result that
    /// changes any other field is discarded whole.
    var sendHookMutableFields: Set<String> { get }

    /// `telegram.request`. Throws `invalidArguments` for bytes that are not a
    /// function of the backend's layer and `unsupported` for a function it will
    /// not send; otherwise the request is queued through the account's normal
    /// network stack (after the request hooks) and `completion` reports it once.
    /// Cancelling after the completion ran must be harmless.
    func sendRequest(account: AyuPluginTelegramAccount, function: Data, flags: Int32,
                     completion: @escaping @Sendable (AyuPluginTelegramRequestResult) -> Void) throws -> AyuPluginTelegramCancellation
    func connectionState(account: AyuPluginTelegramAccount,
                         completion: @escaping @Sendable (Result<AyuPluginTelegramConnectionState, AyuPluginTelegramBackendError>) -> Void)
    /// Called whenever the union of the plugins' hook sets changes.
    func hookFilterDidChange(_ filter: AyuPluginTelegramHookFilter)
    /// Completes once the message is queued for sending.
    func sendMessage(account: AyuPluginTelegramAccount, message: AyuPluginTelegramOutgoingMessage,
                     completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void)
    /// Completes once the edit is queued; `invalidArguments` when the account cannot edit the message.
    func editMessage(account: AyuPluginTelegramAccount, edit: AyuPluginTelegramMessageEdit,
                     completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void)
    /// Boxed `User`, `Chat`, `UserFull` or `ChatFull` rebuilt from the local cache, nil when not cached.
    func peer(account: AyuPluginTelegramAccount, kind: AyuPluginTelegramPeerKind, id: Int64,
              completion: @escaping @Sendable (Result<Data?, AyuPluginTelegramBackendError>) -> Void)
    /// One entry per id, in order: the boxed `Message` rebuilt from the local store, or nil.
    func messages(account: AyuPluginTelegramAccount, dialogID: Int64, ids: [Int32],
                  completion: @escaping @Sendable (Result<[Data?], AyuPluginTelegramBackendError>) -> Void)
    /// The account's chat list for `telegram.dialogs`: at most
    /// `AyuPluginTelegramBridge.dialogListLimit` entries; the default refuses.
    func dialogs(account: AyuPluginTelegramAccount,
                 completion: @escaping @Sendable (Result<[AyuPluginTelegramDialogEntry], AyuPluginTelegramBackendError>) -> Void)
    /// Completes once navigation is queued on main.
    func navigate(account: AyuPluginTelegramAccount, target: AyuPluginTelegramNavigationTarget,
                  completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void)
    /// An absolute path: the local copy when it is complete, else a path in the cache at which no file exists.
    func filePath(account: AyuPluginTelegramAccount, target: Data, cache: Bool,
                  completion: @escaping @Sendable (Result<String, AyuPluginTelegramBackendError>) -> Void)
    func loadFile(account: AyuPluginTelegramAccount, target: Data, parent: Data?, priority: Int32, cacheType: Int32,
                  completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void)
    func cancelFileLoad(account: AyuPluginTelegramAccount, target: Data,
                        completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void)
    /// The state of the shared audio player after `action`.
    func player(action: AyuPluginTelegramPlayerAction,
                completion: @escaping @Sendable (Result<AyuPluginTelegramPlayerState, AyuPluginTelegramBackendError>) -> Void)
    /// A `telegram.action.*` operation the backend lists (`AyuPluginTelegramActions.swift`).
    /// Completes once the change is applied locally or queued, with nil or, for
    /// `addDialogsToFolder`, the action's result; the default refuses.
    func perform(account: AyuPluginTelegramAccount, action: AyuPluginTelegramAction,
                 completion: @escaping @Sendable (Result<Int32?, AyuPluginTelegramBackendError>) -> Void)
}

/// One row of the chat list with what Android keeps beside the TL object.
public struct AyuPluginTelegramDialogEntry: Sendable, Equatable {
    /// A boxed `Dialog`: `dialog`, or `dialogFolder` for the archive's row in the main list.
    public let dialog: Data
    /// Date of the dialog's newest message, 0 when it has none (Android's `last_message_date`).
    public let lastMessageDate: Int32
    /// Android's `pinnedNum`: 0 for an unpinned dialog, otherwise larger for a higher row.
    public let pinnedNumber: Int32

    public init(dialog: Data, lastMessageDate: Int32, pinnedNumber: Int32) {
        self.dialog = dialog
        self.lastMessageDate = lastMessageDate
        self.pinnedNumber = pinnedNumber
    }
}

public extension AyuPluginTelegramBackend {
    func dialogs(account: AyuPluginTelegramAccount,
                 completion: @escaping @Sendable (Result<[AyuPluginTelegramDialogEntry], AyuPluginTelegramBackendError>) -> Void) {
        completion(.failure(.unsupported("telegram.dialogs")))
    }
}

/// `{"tl": "<base64>"}` values and the few TL primitives the bridge reads itself.
enum AyuPluginTelegramTL {
    static let errorConstructor: UInt32 = 0xc4b9f9bb
    /// `dialog` and `dialogFolder` of the layer in `protocol-telegram.md`.
    static let dialogConstructors: Set<UInt32> = [0xfc89f7f3, 0x71bd134c]

    static func encode(_ data: Data) -> AyuBridgeValue { .object(["tl": .string(data.base64EncodedString())]) }

    /// A boxed object is a constructor id followed by 4-byte words.
    static func isBoxed(_ data: Data) -> Bool { data.count >= 4 && data.count % 4 == 0 }

    static func decode(_ value: AyuBridgeValue?, limit: Int, what: String) throws -> Data {
        guard let object = value?.object, object.count == 1, let text = object["tl"]?.string else {
            throw AyuBridgeFailure("invalid_arguments", what + " must be a TL value")
        }
        guard text.utf8.count <= (limit + 2) / 3 * 4 else {
            throw AyuBridgeFailure("invalid_arguments", what + " exceeds the TL size limit")
        }
        guard let data = Data(base64Encoded: text), data.count <= limit, Self.isBoxed(data) else {
            throw AyuBridgeFailure("invalid_arguments", what + " is not a boxed TL object")
        }
        return data
    }

    static func constructor(of data: Data) -> UInt32 {
        var result: UInt32 = 0
        for (index, byte) in data.prefix(4).enumerated() { result |= UInt32(byte) << (8 * UInt32(index)) }
        return result
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }

    /// `error#c4b9f9bb code:int text:string`.
    static func error(code: Int32, text: String) -> Data {
        var data = Data()
        Self.append(Self.errorConstructor, to: &data)
        Self.append(UInt32(bitPattern: code), to: &data)
        let bytes = Array(text.utf8.prefix(4096))
        if bytes.count < 254 {
            data.append(UInt8(bytes.count))
        } else {
            data.append(254)
            for shift in stride(from: 0, to: 24, by: 8) { data.append(UInt8(truncatingIfNeeded: bytes.count >> shift)) }
        }
        data.append(contentsOf: bytes)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    /// Strict: the constructor, both fields and nothing after the padding.
    static func parseError(_ data: Data) -> AyuPluginTelegramRPCError? {
        let bytes = Array(data)
        guard bytes.count >= 12, bytes.count % 4 == 0, Self.constructor(of: data) == Self.errorConstructor else { return nil }
        let code = Int32(bitPattern: Self.constructor(of: Data(bytes[4..<8])))
        var offset = 8
        var length = Int(bytes[offset]); offset += 1
        if length == 254 {
            guard bytes.count >= offset + 3 else { return nil }
            length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
            offset += 3
        } else if length == 255 { return nil }
        guard length <= 4096, bytes.count >= offset + length else { return nil }
        guard let text = String(bytes: bytes[offset..<(offset + length)], encoding: .utf8) else { return nil }
        offset += length
        while offset % 4 != 0 { offset += 1 }
        guard offset == bytes.count else { return nil }
        return AyuPluginTelegramRPCError(code: code, text: text)
    }
}

/// Functions `telegram.request` never sends for a plugin, and a request hook
/// may never substitute. Generated by `Build/telegram_refused_functions.py`
/// from `submodules/TelegramApi/swift_scheme.tl`; `Tests/Python/test_telegram_refusals.py`
/// recomputes it.
enum AyuPluginTelegramRefusedFunctions {
    static let table: [UInt32: String] = [
        0x0d36bf79: "auth.checkRecoveryPassword", 0x0dae54f8: "invokeWithApnsSecret", 0x1df92984: "invokeWithGooglePlayIntegrity",
        0x1f040578: "auth.cancelCode", 0x2c85094c: "auth.finishFirebasePnvLogin", 0x2db873a9: "auth.importWebTokenAuthorization",
        0x365275f2: "invokeWithMessagesRange", 0x37096c70: "auth.recoverPassword", 0x3dc4b4f0: "invokeAfterMsgs",
        0x3e72ba19: "auth.logOut", 0x490dada1: "auth.cancelWebTokenAuthorization", 0x518ad0b7: "auth.initPasskeyLogin",
        0x56e59f9c: "auth.checkPaidAuth", 0x644f15c0: "auth.initFirebasePnvLogin", 0x67a3ff2c: "auth.importBotAuthorization",
        0x783f6b56: "auth.firebasePnvSignUp", 0x7e960193: "auth.resetLoginEmail", 0x8d52a951: "auth.signIn",
        0x8e39261e: "auth.requestFirebaseSms", 0x8e48a188: "auth.dropTempAuthKeys", 0x9308ce1b: "account.resetPassword",
        0x95ac5ce4: "auth.importLoginToken", 0x9857ad07: "auth.finishPasskeyLogin", 0x9fab0d1a: "auth.resetAuthorizations",
        0xa2c0cf74: "account.deleteAccount", 0xa57a7dad: "auth.importAuthorization", 0xa59b102f: "account.updatePasswordSettings",
        0xa677244f: "auth.sendCode", 0xaac7b717: "auth.signUp", 0xaca9fd2e: "invokeWithTakeout",
        0xadbb0f94: "invokeWithReCaptcha", 0xb7e085fe: "auth.exportLoginToken", 0xbf9459b7: "invokeWithoutUpdates",
        0xc1cd5ea9: "initConnection", 0xcae47523: "auth.resendCode", 0xcb9deff6: "auth.reportMissingCode",
        0xcb9f372d: "invokeAfterMsg", 0xcdd42a05: "auth.bindTempAuthKey", 0xd18b4d16: "auth.checkPassword",
        0xd897bc66: "auth.requestPasswordRecovery", 0xda9b0d0d: "invokeWithLayer", 0xdd289f8e: "invokeWithBusinessConnection",
        0xdf77f3bc: "account.resetAuthorization", 0xe5bfffcd: "auth.exportAuthorization", 0xe894ad4d: "auth.acceptLoginToken",
    ]
}
