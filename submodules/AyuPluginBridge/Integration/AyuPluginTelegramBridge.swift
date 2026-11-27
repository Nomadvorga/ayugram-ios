import Foundation

/// Bridge side of `Python/protocol-telegram.md`: closed-argument validation,
/// account checks, TL value bounds, per-generation ownership and quotas, and
/// hook chains. Telegram itself is reached through `AyuPluginTelegramBackend`;
/// without a bound backend nothing is declared and every call is refused.
///
/// State is keyed by plugin and dropped by `detach`, which the host calls from
/// its deactivate barrier, so an owner entry never outlives its generation.
public final class AyuPluginTelegramBridge: @unchecked Sendable {
    public static let shared = AyuPluginTelegramBridge()

    public struct Limits: Sendable {
        /// Decoded size of a TL value the SDK sends.
        public var inboundTLBytes = 1_048_576
        /// Decoded size of a TL value the host sends.
        public var outboundTLBytes = 4_194_304
        /// JSON size of a request callback's arguments, enough for one `outboundTLBytes`
        /// value: a larger response is replaced by `RESPONSE_TOO_LARGE`.
        public var callbackPayloadBytes = AyuPluginBridgeLimits().guaranteedCallbackBytes
        /// JSON size of a hook callback's arguments (the SDK reads 6,000,000 characters).
        public var hookPayloadBytes = 5_900_000
        public var requestsPerGeneration = 64
        public var hookConstructors = 4096
        public var sendHooksPerGeneration = 16
        public var pendingHookEvents = 256
        public var hookAnswerTimeout: TimeInterval = 2
        public var stateReadTimeout: TimeInterval = 5
        public init() {}
    }

    /// Calls a registered Python callback and reports its decoded result, or nil
    /// when the callback failed or its generation is gone. Never blocks.
    public typealias AnswerInvoker = @Sendable (_ pluginID: String, _ callbackID: String, _ arguments: [AyuBridgeValue],
                                                _ completion: @escaping @Sendable (AyuBridgeValue?) -> Void) -> Void

    /// What the application bridge already owns: account slots, the visible
    /// screen and the three-field `hooks.register` send hooks.
    struct Environment: Sendable {
        let account: @Sendable (Int64) -> AyuPluginTelegramAccount?
        /// Worker-only: reads the main-thread screen snapshot.
        let screen: @Sendable () -> AyuPluginScreenSnapshot?
        let legacySendHooks: @Sendable () -> [AyuPluginSendHook]
    }

    enum Operation {
        static let request = "telegram.request"
        static let requestCancel = "telegram.request.cancel"
        static let connection = "telegram.connection"
        static let hooksSet = "telegram.hooks.set"
        static let hooksSendMessage = "telegram.hooks.send_message"
        static let sendMessage = "telegram.send_message"
        static let editMessage = "telegram.edit_message"
        static let peer = "telegram.peer"
        static let messages = "telegram.messages"
        static let screen = "telegram.screen"
        static let navigationOpen = "telegram.navigation.open"
        static let filesPath = "telegram.files.path"
        static let filesLoad = "telegram.files.load"
        static let player = "telegram.player"
        static let served: Set<String> = [request, requestCancel, connection, hooksSet, hooksSendMessage, sendMessage,
            editMessage, peer, messages, screen, navigationOpen, filesPath, filesLoad, player]
    }

    struct Request {
        let account: Int64
        let callback: AyuBridgeNativeCallback
        var cancellation: AyuPluginTelegramCancellation?
    }

    struct HookSet {
        var requests: [UInt32: Int32]
        var updates: [UInt32: Int32]
        var containers: [UInt32: Int32]
        var onRequest: String
        var onResponse: String
        var onUpdate: String
        var onUpdates: String
    }

    struct SendHook {
        let priority: Int32
        let callbackID: String
        let order: UInt64
        var committed: Bool
    }

    struct Owner {
        let epoch = UUID()
        var requests: [Int32: Request] = [:]
        var nextRequestID: Int32 = 1
        var hooks: HookSet?
        var sendHooks: [String: SendHook] = [:]
    }

    final class AnswerBox: @unchecked Sendable {
        let owner: String
        private let lock = NSLock()
        private var completion: (@Sendable (AyuBridgeValue?) -> Void)?
        init(owner: String, completion: @escaping @Sendable (AyuBridgeValue?) -> Void) {
            self.owner = owner; self.completion = completion
        }
        func fire(_ value: AyuBridgeValue?) {
            self.lock.lock(); let completion = self.completion; self.completion = nil; self.lock.unlock()
            completion?(value)
        }
    }

    private final class ResultBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        private var closed = false
        /// False once a value is stored or the waiter gave up.
        func store(_ value: Value) -> Bool {
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.closed else { return false }
            self.closed = true; self.value = value
            return true
        }
        func take() -> Value? {
            self.lock.lock(); defer { self.lock.unlock() }
            self.closed = true
            return self.value
        }
    }

    let limits: Limits
    let lock = NSLock()
    let queue = DispatchQueue(label: "AyuPluginBridge.telegram")
    var owners: [String: Owner] = [:]
    var pendingAnswers: [UUID: AnswerBox] = [:]
    var activeChains = 0
    var sendHookOrder: UInt64 = 0
    var publishedFilter = AyuPluginTelegramHookFilter()
    var backend: AyuPluginTelegramBackend?
    var invoker: AnswerInvoker?
    var environment: Environment?
    private let containerRoots: [String]

    public convenience init(limits: Limits = Limits()) {
        self.init(limits: limits, containerRoots: [NSHomeDirectory(), NSTemporaryDirectory()])
    }

    init(limits: Limits, containerRoots: [String]) {
        self.limits = limits
        self.containerRoots = containerRoots.map { Self.canonicalPath($0) }
    }

    /// The app binds its backend once it can serve Telegram; nil unbinds it.
    public func bind(backend: AyuPluginTelegramBackend?) {
        self.lock.lock()
        self.backend = backend
        let filter = self.publishedFilter
        self.lock.unlock()
        backend?.hookFilterDidChange(filter)
    }

    public func setAnswerInvoker(_ invoker: AnswerInvoker?) {
        self.lock.lock(); self.invoker = invoker; self.lock.unlock()
    }

    func setEnvironment(_ environment: Environment?) {
        self.lock.lock(); self.environment = environment; self.lock.unlock()
    }

    func currentBackend() -> AyuPluginTelegramBackend? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.backend
    }

    func currentInvoker() -> AnswerInvoker? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.invoker
    }

    func currentEnvironment() -> Environment? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.environment
    }

    /// Declared only while a backend is bound and lists the operation, so
    /// `runtime.capabilities` and preflight never promise more than is served.
    public var capabilities: [String] {
        guard let backend = self.currentBackend(), self.currentEnvironment() != nil else { return [] }
        var declared = Operation.served.union(AyuPluginTelegramAction.operations).intersection(backend.operations)
        if !declared.contains(Operation.request) { declared.remove(Operation.requestCancel) }
        return declared.sorted()
    }

    func prepareCall(pluginID: String, operation: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        guard !Thread.isMainThread, context.pluginID == pluginID else { throw AyuBridgeFailure("wrong_thread", "Telegram adapter is worker-only") }
        guard self.capabilities.contains(operation), let backend = self.currentBackend(), let environment = self.currentEnvironment() else {
            throw AyuBridgeFailure.unsupported(operation)
        }
        switch operation {
        case Operation.request:
            return try self.prepareRequest(owner: pluginID, arguments: arguments, context: context, backend: backend, environment: environment)
        case Operation.requestCancel:
            try Self.closed(arguments, required: ["account", "request_id"])
            let account = try Self.account(arguments["account"], environment: environment)
            let id = Int32(try Self.integer(arguments["request_id"], 1...Int64(Int32.max), "request_id"))
            return AyuBridgeProviderResult(.value(.null), commit: { _ in self.cancelRequest(owner: pluginID, epoch: nil, id: id, account: account.index) })
        case Operation.connection:
            try Self.closed(arguments, required: ["account"])
            let account = try Self.account(arguments["account"], environment: environment)
            let state: AyuPluginTelegramConnectionState = try self.wait(operation) { backend.connectionState(account: account, completion: $0) }
            return AyuBridgeProviderResult(.value(.object([
                "time_ms": .integer(state.timeMilliseconds), "time_difference": .integer(Int64(state.timeDifference)),
                "state": .integer(state.status.rawValue), "datacenter_id": .integer(Int64(state.datacenterID)),
            ])))
        case Operation.hooksSet:
            return try self.prepareHookSet(owner: pluginID, arguments: arguments, context: context)
        case Operation.hooksSendMessage:
            return try self.prepareSendHook(owner: pluginID, arguments: arguments, context: context)
        case Operation.sendMessage:
            try Self.closed(arguments, required: ["account", "params"])
            let account = try Self.account(arguments["account"], environment: environment)
            let message = try self.outgoingMessage(arguments["params"], supported: backend.sendMessageParameters)
            let _: Void = try self.wait(operation) { backend.sendMessage(account: account, message: message, completion: $0) }
            return AyuBridgeProviderResult(.value(.null))
        case Operation.editMessage:
            let edit = try self.messageEdit(arguments)
            let account = try Self.account(arguments["account"], environment: environment)
            let _: Void = try self.wait(operation) { backend.editMessage(account: account, edit: edit, completion: $0) }
            return AyuBridgeProviderResult(.value(.null))
        case Operation.peer:
            try Self.closed(arguments, required: ["account", "kind", "id"])
            let account = try Self.account(arguments["account"], environment: environment)
            guard let kind = arguments["kind"]?.string.flatMap(AyuPluginTelegramPeerKind.init(rawValue:)) else { throw Self.invalid("Unknown peer kind") }
            let id = try Self.integer(arguments["id"], 1...Int64.max, "id")
            let data: Data? = try self.wait(operation) { backend.peer(account: account, kind: kind, id: id, completion: $0) }
            return AyuBridgeProviderResult(.value(try self.outbound(data, what: operation)))
        case Operation.messages:
            try Self.closed(arguments, required: ["account", "dialog_id", "ids"])
            let account = try Self.account(arguments["account"], environment: environment)
            let dialogID = try Self.dialogID(arguments["dialog_id"], "dialog_id")
            guard let values = arguments["ids"]?.array, (1...100).contains(values.count) else { throw Self.invalid("ids must hold 1 to 100 message ids") }
            let ids = try values.map { Int32(try Self.integer($0, Self.int32Range, "ids")) }
            let stored: [Data?] = try self.wait(operation) { backend.messages(account: account, dialogID: dialogID, ids: ids, completion: $0) }
            guard stored.count == ids.count else { throw AyuBridgeFailure("invalid_state", "Telegram backend returned a message list of the wrong length") }
            return AyuBridgeProviderResult(.value(.array(try stored.map { try self.outbound($0, what: operation) })))
        case Operation.screen:
            return AyuBridgeProviderResult(.value(try Self.screen(arguments, environment: environment)))
        case Operation.navigationOpen:
            let target = try Self.navigationTarget(arguments)
            let account = try Self.account(arguments["account"], environment: environment)
            let _: Void = try self.wait(operation) { backend.navigate(account: account, target: target, completion: $0) }
            return AyuBridgeProviderResult(.value(.null))
        case Operation.filesPath:
            try Self.closed(arguments, required: ["account", "target", "cache"])
            let account = try Self.account(arguments["account"], environment: environment)
            let target = try self.inbound(arguments["target"], "target")
            let cache = try Self.bool(arguments["cache"], "cache")
            let path: String = try self.wait(operation) { backend.filePath(account: account, target: target, cache: cache, completion: $0) }
            guard path.hasPrefix("/"), path.utf8.count <= 4096 else { throw AyuBridgeFailure("invalid_state", "Telegram backend returned an invalid file path") }
            return AyuBridgeProviderResult(.value(.string(path)))
        case Operation.filesLoad:
            return try self.loadFile(arguments, backend: backend, environment: environment)
        case Operation.player:
            return AyuBridgeProviderResult(.value(try self.player(arguments, backend: backend)))
        case _ where AyuPluginTelegramAction.operations.contains(operation):
            let action = try self.action(operation, arguments)
            let account = try Self.account(arguments["account"], environment: environment)
            let _: Void = try self.wait(operation) { backend.perform(account: account, action: action, completion: $0) }
            return AyuBridgeProviderResult(.value(.null))
        default:
            throw AyuBridgeFailure.unsupported(operation)
        }
    }

    /// Deactivate barrier: in-flight requests are cancelled and forgotten (their
    /// callbacks never fire), the hook set and send hooks go away, and hook
    /// chains waiting for this plugin continue as if it had answered strategy 0.
    public func detach(pluginID: String) {
        self.lock.lock()
        let state = self.owners.removeValue(forKey: pluginID)
        let waiting = self.pendingAnswers.filter { $0.value.owner == pluginID }
        for key in waiting.keys { self.pendingAnswers.removeValue(forKey: key) }
        let (filter, backend) = self.refreshFilterLocked()
        self.lock.unlock()
        for request in (state?.requests ?? [:]).values { request.cancellation?.cancel() }
        for answer in waiting.values { answer.fire(nil) }
        if let filter { backend?.hookFilterDidChange(filter) }
    }

    // MARK: Requests

    private func prepareRequest(owner: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext,
                                backend: AyuPluginTelegramBackend, environment: Environment) throws -> AyuBridgeProviderResult {
        // The host registered the callback id before this call; resolve it first so
        // every refusal below can hand the one-shot id back.
        let callback = try Self.callback(arguments["callback"], context: context)
        do {
            try Self.closed(arguments, required: ["account", "request", "flags", "callback"])
            let account = try Self.account(arguments["account"], environment: environment)
            let function = try self.inbound(arguments["request"], "request")
            let flags = Int32(try Self.integer(arguments["flags"], 0...Int64(Int32.max), "flags"))
            if let name = AyuPluginTelegramRefusedFunctions.table[AyuPluginTelegramTL.constructor(of: function)] {
                throw AyuBridgeFailure.unsupported("telegram.request does not send " + name)
            }
            self.lock.lock()
            var state = self.owners[owner] ?? Owner()
            guard state.requests.count < self.limits.requestsPerGeneration else {
                self.lock.unlock()
                throw AyuBridgeFailure("resource_limit", "Too many requests in flight")
            }
            var candidate = state.nextRequestID
            while state.requests[candidate] != nil { candidate = candidate == Int32.max ? 1 : candidate + 1 }
            let id = candidate
            state.nextRequestID = id == Int32.max ? 1 : id + 1
            state.requests[id] = Request(account: account.index, callback: callback, cancellation: nil)
            let epoch = state.epoch
            self.owners[owner] = state
            self.lock.unlock()
            let cancellation: AyuPluginTelegramCancellation
            do {
                cancellation = try backend.sendRequest(account: account, function: function, flags: flags) { result in
                    self.finishRequest(owner: owner, epoch: epoch, id: id, result: result)
                }
            } catch {
                self.lock.lock()
                if self.owners[owner]?.epoch == epoch { self.owners[owner]?.requests.removeValue(forKey: id) }
                self.lock.unlock()
                throw Self.failure(error)
            }
            self.lock.lock()
            let pending = self.owners[owner]?.epoch == epoch && self.owners[owner]?.requests[id] != nil
            if pending { self.owners[owner]?.requests[id]?.cancellation = cancellation }
            self.lock.unlock()
            // Already answered or revoked while the backend was starting it.
            if !pending { cancellation.cancel() }
            return AyuBridgeProviderResult(.value(.integer(Int64(id))), rollback: {
                self.cancelRequest(owner: owner, epoch: epoch, id: id, account: nil)
            })
        } catch {
            callback.release()
            throw error
        }
    }

    private func finishRequest(owner: String, epoch: UUID, id: Int32, result: AyuPluginTelegramRequestResult) {
        self.lock.lock()
        guard self.owners[owner]?.epoch == epoch, let request = self.owners[owner]?.requests.removeValue(forKey: id) else {
            self.lock.unlock(); return
        }
        self.lock.unlock()
        // The 64 requests in flight bound these callbacks, so the delivery queue always has a
        // slot; when it has no room for the bytes, the plugin gets a transport failure instead.
        request.callback.send(self.callbackArguments(result), orOnOverflow: Self.callbackQueueFull)
        request.callback.release()
    }

    private func cancelRequest(owner: String, epoch: UUID?, id: Int32, account: Int64?) {
        self.lock.lock()
        guard let state = self.owners[owner], epoch == nil || state.epoch == epoch, let request = state.requests[id],
              account == nil || request.account == account else { self.lock.unlock(); return }
        self.owners[owner]?.requests.removeValue(forKey: id)
        self.lock.unlock()
        request.callback.release()
        request.cancellation?.cancel()
    }

    /// The request callback's arguments when the response could not be queued for delivery.
    static let callbackQueueFull: [AyuBridgeValue] = [.null, AyuPluginTelegramTL.encode(AyuPluginTelegramTL.error(code: -1, text: "CALLBACK_QUEUE_FULL"))]

    /// `(response, error)` of a request callback. A response the callback
    /// envelope cannot carry becomes the contract's `RESPONSE_TOO_LARGE` error
    /// instead of being dropped by the host.
    func callbackArguments(_ result: AyuPluginTelegramRequestResult) -> [AyuBridgeValue] {
        func failure(_ code: Int32, _ text: String) -> [AyuBridgeValue] {
            [.null, AyuPluginTelegramTL.encode(AyuPluginTelegramTL.error(code: code, text: text))]
        }
        switch result {
        case let .response(data):
            guard AyuPluginTelegramTL.isBoxed(data) else { return failure(-1, "INVALID_RESPONSE") }
            guard data.count <= self.limits.outboundTLBytes else { return failure(500, "RESPONSE_TOO_LARGE") }
            let arguments: [AyuBridgeValue] = [AyuPluginTelegramTL.encode(data), .null]
            guard Self.fits(arguments, payload: data.count, limit: self.limits.callbackPayloadBytes) else { return failure(500, "RESPONSE_TOO_LARGE") }
            return arguments
        case let .rpcError(error): return failure(error.code, error.text)
        case let .transportFailure(text): return failure(-1, String(text.prefix(64)))
        case .cancelledByHook: return [.null, .null]
        }
    }

    // MARK: Sending and editing

    private static let integerParameters: [String: ClosedRange<Int64>] = [
        "scheduleDate": 0...Int64(Int32.max), "scheduleRepeatPeriod": 0...Int64(Int32.max), "ttl": 0...Int64(Int32.max),
        "quick_reply_shortcut_id": int32Range, "effect_id": Int64.min...Int64.max, "monoForumPeer": Int64.min...Int64.max,
        "payStars": 0...Int64.max, "stars": 0...Int64.max, "dice_stake": 0...Int64.max,
    ]
    private static let booleanParameters: Set<String> = ["notify", "searchLinks", "invert_media", "hasMediaSpoilers", "updateStickersOrder", "sendingHighQuality"]
    private static let objectParameters: Set<String> = ["document", "photo", "location", "poll", "game", "invoice", "mediaWebPage", "webPage",
        "replyMarkup", "user", "todo", "cover", "richMessage"]
    private static let otherParameters: Set<String> = ["peer", "message", "caption", "entities", "replyToMsg", "replyToTopMsg", "params", "path", "attach"]
    /// Every `params` key of `telegram.send_message` the contract lists.
    static let sendMessageParameters: Set<String> = Set(integerParameters.keys).union(booleanParameters).union(objectParameters).union(otherParameters)

    private func outgoingMessage(_ value: AyuBridgeValue?, supported: Set<String>) throws -> AyuPluginTelegramOutgoingMessage {
        guard let params = value?.object else { throw Self.invalid("params must be an object") }
        let keys = params.keys.sorted()
        if let unknown = keys.first(where: { !Self.sendMessageParameters.contains($0) }) {
            throw Self.invalid("Unknown send parameter " + String(unknown.prefix(64)))
        }
        if let refused = keys.first(where: { !supported.contains($0) }) {
            throw AyuBridgeFailure.unsupported("telegram.send_message parameter " + refused)
        }
        var message = AyuPluginTelegramOutgoingMessage(peer: try Self.dialogID(params["peer"], "peer"))
        message.keys = keys
        for key in keys {
            let item = params[key] ?? .null
            if let range = Self.integerParameters[key] {
                message.integers[key] = try Self.integer(item, range, key)
            } else if Self.booleanParameters.contains(key) {
                message.booleans[key] = try Self.bool(item, key)
            } else if Self.objectParameters.contains(key) {
                message.objects[key] = try self.inbound(item, key)
            } else {
                switch key {
                case "message": message.message = try Self.text(item, maxBytes: AyuBridgeSendHookChain.maximumTextBytes, key)
                case "caption": message.caption = try Self.text(item, maxBytes: AyuBridgeSendHookChain.maximumTextBytes, key)
                case "entities": message.entities = try self.entities(item)
                case "replyToMsg": message.replyTo = try self.messageReference(item, key)
                case "replyToTopMsg": message.replyToTop = try self.messageReference(item, key)
                case "params": message.parameters = try Self.stringMap(item, key)
                case "path": message.path = try self.containerPath(item, key)
                case "attach":
                    guard let attach = item.object, Set(attach.keys) == ["kind"],
                          let kind = attach["kind"]?.string.flatMap(AyuPluginTelegramAttachmentKind.init(rawValue:)) else {
                        throw Self.invalid("attach must name a kind")
                    }
                    message.attachment = kind
                default: break
                }
            }
        }
        guard message.attachment == nil || message.path != nil else { throw Self.invalid("attach needs path") }
        guard message.path == nil || message.attachment != nil || message.objects["document"] != nil || message.objects["photo"] != nil else {
            throw Self.invalid("path needs attach, document or photo")
        }
        return message
    }

    private func messageEdit(_ arguments: [String: AyuBridgeValue]) throws -> AyuPluginTelegramMessageEdit {
        try Self.closed(arguments, required: ["account", "dialog_id", "message_id"], optional: ["text", "entities", "attach", "params"])
        var edit = AyuPluginTelegramMessageEdit(dialogID: try Self.dialogID(arguments["dialog_id"], "dialog_id"),
                                                messageID: Int32(try Self.integer(arguments["message_id"], Self.int32Range, "message_id")))
        if let text = arguments["text"] { edit.text = try Self.text(text, maxBytes: AyuBridgeSendHookChain.maximumTextBytes, "text") }
        if let entities = arguments["entities"] { edit.entities = try self.entities(entities) }
        if let value = arguments["attach"] {
            guard let attach = value.object, Set(attach.keys) == ["kind", "path", "spoiler"],
                  let kind = attach["kind"]?.string.flatMap(AyuPluginTelegramAttachmentKind.init(rawValue:)) else {
                throw Self.invalid("attach must hold kind, path and spoiler")
            }
            edit.attachment = .init(kind: kind, path: try self.containerPath(attach["path"] ?? .null, "attach.path"),
                                    spoiler: try Self.bool(attach["spoiler"], "attach.spoiler"))
        }
        if let params = arguments["params"] { edit.parameters = try Self.stringMap(params, "params") }
        guard edit.text != nil || edit.attachment != nil else { throw Self.invalid("An edit needs text or attach") }
        guard edit.entities == nil || edit.text != nil else { throw Self.invalid("entities need text") }
        return edit
    }

    // MARK: State

    private static func screen(_ arguments: [String: AyuBridgeValue], environment: Environment) throws -> AyuBridgeValue {
        try Self.closed(arguments, required: [])
        guard let snapshot = environment.screen() else { return .null }
        guard environment.account(snapshot.accountIndex) != nil else { throw AyuBridgeFailure("account_unavailable", "Requested account is not active") }
        guard let detail = snapshot.telegram else { throw AyuBridgeFailure.unsupported("telegram.screen without a screen description") }
        var result: [String: AyuBridgeValue] = ["kind": .string(detail.kind.rawValue), "account": .integer(snapshot.accountIndex)]
        switch detail.kind {
        case .chat, .profile:
            // The fragment adapter reads `dialogID` of the same snapshot for a peer chat.
            guard let dialogID = detail.dialogID, dialogID != 0, detail.kind != .chat || snapshot.dialogID == nil || snapshot.dialogID == dialogID else {
                throw AyuBridgeFailure("invalid_state", "Screen snapshot is inconsistent")
            }
            result["dialog_id"] = .integer(dialogID)
        case .dialogs, .other:
            break
        }
        if detail.kind == .chat {
            if let topicID = detail.topicID, topicID != 0 { result["topic_id"] = .integer(Int64(topicID)) }
            if let chatMode = detail.chatMode { result["chat_mode"] = .integer(Int64(chatMode)) }
        }
        return .object(result)
    }

    private static func navigationTarget(_ arguments: [String: AyuBridgeValue]) throws -> AyuPluginTelegramNavigationTarget {
        if arguments["username"] != nil {
            try Self.closed(arguments, required: ["account", "username", "type"])
            let username = try Self.text(arguments["username"], maxBytes: 64, "username")
            guard !username.isEmpty, username.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }) else {
                throw Self.invalid("username must be a nonempty name")
            }
            return .username(username, type: Int32(try Self.integer(arguments["type"], Self.int32Range, "type")))
        }
        try Self.closed(arguments, required: ["account", "dialog_id", "screen"], optional: ["message_id"])
        let dialogID = try Self.dialogID(arguments["dialog_id"], "dialog_id")
        guard let screen = arguments["screen"]?.string.flatMap(AyuPluginTelegramNavigationTarget.Screen.init(rawValue:)) else { throw Self.invalid("Unknown screen") }
        var messageID: Int32?
        if let value = arguments["message_id"] {
            guard screen == .chat else { throw Self.invalid("message_id needs the chat screen") }
            messageID = Int32(try Self.integer(value, 1...Int64(Int32.max), "message_id"))
        }
        return .dialog(id: dialogID, screen: screen, messageID: messageID)
    }

    private func loadFile(_ arguments: [String: AyuBridgeValue], backend: AyuPluginTelegramBackend, environment: Environment) throws -> AyuBridgeProviderResult {
        if arguments["cancel"] != nil {
            try Self.closed(arguments, required: ["account", "target", "cancel"])
            guard arguments["cancel"] == .bool(true) else { throw Self.invalid("cancel must be true") }
            let account = try Self.account(arguments["account"], environment: environment)
            let target = try self.inbound(arguments["target"], "target")
            let _: Void = try self.wait(Operation.filesLoad) { backend.cancelFileLoad(account: account, target: target, completion: $0) }
            return AyuBridgeProviderResult(.value(.null))
        }
        try Self.closed(arguments, required: ["account", "target", "priority", "cache_type"], optional: ["parent"])
        let account = try Self.account(arguments["account"], environment: environment)
        let target = try self.inbound(arguments["target"], "target")
        let priority = Int32(try Self.integer(arguments["priority"], 0...3, "priority"))
        let cacheType = Int32(try Self.integer(arguments["cache_type"], 0...Int64(Int32.max), "cache_type"))
        let parent = try arguments["parent"].map { try self.inbound($0, "parent") }
        let _: Void = try self.wait(Operation.filesLoad) {
            backend.loadFile(account: account, target: target, parent: parent, priority: priority, cacheType: cacheType, completion: $0)
        }
        return AyuBridgeProviderResult(.value(.null))
    }

    private func player(_ arguments: [String: AyuBridgeValue], backend: AyuPluginTelegramBackend) throws -> AyuBridgeValue {
        let action: AyuPluginTelegramPlayerAction
        switch arguments["action"]?.string {
        case "seek":
            try Self.closed(arguments, required: ["action", "progress"])
            guard let progress = arguments["progress"]?.number, progress.isFinite, (0...1).contains(progress) else { throw Self.invalid("progress must be between 0 and 1") }
            action = .seek(progress)
        case let name?:
            try Self.closed(arguments, required: ["action"])
            switch name {
            case "state": action = .state
            case "pause": action = .pause
            case "resume": action = .resume
            case "next": action = .next
            case "previous": action = .previous
            case "stop": action = .stop
            default: throw Self.invalid("Unknown player action")
            }
        case nil:
            throw Self.invalid("action must be a string")
        }
        let state: AyuPluginTelegramPlayerState = try self.wait(Operation.player) { backend.player(action: action, completion: $0) }
        guard state.accountIndex >= 0, state.progress.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              (state.positionMilliseconds ?? 0) >= 0, (state.durationMilliseconds ?? 0) >= 0 else {
            throw AyuBridgeFailure("invalid_state", "Telegram backend returned an invalid player state")
        }
        var result: [String: AyuBridgeValue] = ["account": .integer(state.accountIndex), "paused": .bool(state.paused)]
        if let message = state.message {
            result["message"] = try self.outbound(message, what: Operation.player)
            if let progress = state.progress { result["progress"] = .number(progress) }
            if let position = state.positionMilliseconds { result["position_ms"] = .integer(position) }
            if let duration = state.durationMilliseconds { result["duration_ms"] = .integer(duration) }
        }
        return .object(result)
    }

    // MARK: Values

    static let int32Range = Int64(Int32.min)...Int64(Int32.max)

    static func invalid(_ message: String) -> AyuBridgeFailure { AyuBridgeFailure("invalid_arguments", message) }

    static func failure(_ error: Error) -> AyuBridgeFailure {
        func bounded(_ text: String) -> String { String(text.prefix(200)) }
        guard let error = error as? AyuPluginTelegramBackendError else {
            return (error as? AyuBridgeFailure) ?? AyuBridgeFailure("invalid_state", "Telegram backend failed")
        }
        switch error {
        case let .invalidArguments(text): return AyuBridgeFailure("invalid_arguments", bounded(text))
        case let .unsupported(text): return AyuBridgeFailure.unsupported(bounded(text))
        case .accountUnavailable: return AyuBridgeFailure("account_unavailable", "Requested account is not active")
        case .screenUnavailable: return AyuBridgeFailure("screen_unavailable", "No visible screen")
        case let .resourceLimit(text): return AyuBridgeFailure("resource_limit", bounded(text))
        }
    }

    /// Arguments are closed objects: a key the contract does not list is refused.
    static func closed(_ arguments: [String: AyuBridgeValue], required: Set<String>, optional: Set<String> = []) throws {
        let keys = Set(arguments.keys)
        if let unknown = keys.subtracting(required).subtracting(optional).sorted().first {
            throw Self.invalid("Unknown argument " + String(unknown.prefix(64)))
        }
        if let missing = required.subtracting(keys).sorted().first { throw Self.invalid("Missing argument " + missing) }
    }

    static func integer(_ value: AyuBridgeValue?, _ range: ClosedRange<Int64>, _ what: String) throws -> Int64 {
        guard let integer = value?.integer, range.contains(integer) else { throw Self.invalid(what + " must be an integer in range") }
        return integer
    }

    static func bool(_ value: AyuBridgeValue?, _ what: String) throws -> Bool {
        guard let bool = value?.bool else { throw Self.invalid(what + " must be a boolean") }
        return bool
    }

    static func text(_ value: AyuBridgeValue?, maxBytes: Int, _ what: String) throws -> String {
        guard let text = value?.string, text.utf8.count <= maxBytes else { throw Self.invalid(what + " must be a bounded string") }
        return text
    }

    /// An Android dialog id: a user id, or the negated chat or channel id.
    static func dialogID(_ value: AyuBridgeValue?, _ what: String) throws -> Int64 {
        guard let id = value?.integer, id != 0, id != Int64.min else { throw Self.invalid(what + " must be a dialog id") }
        return id
    }

    static func account(_ value: AyuBridgeValue?, environment: Environment) throws -> AyuPluginTelegramAccount {
        let index = try Self.integer(value, 0...Int64.max, "account")
        guard let account = environment.account(index) else { throw AyuBridgeFailure("account_unavailable", "Requested account is not active") }
        return account
    }

    static func callback(_ value: AyuBridgeValue?, context: AyuBridgeAdapterContext) throws -> AyuBridgeNativeCallback {
        guard let value, let object = value.object, object.count == 1, object["$callback"]?.string != nil else {
            throw Self.invalid("Expected a callback reference")
        }
        return try context.callback(value)
    }

    static func stringMap(_ value: AyuBridgeValue, _ what: String) throws -> [String: String] {
        guard let object = value.object, object.count <= 64 else { throw Self.invalid(what + " must be a small string map") }
        var result: [String: String] = [:]
        for (key, item) in object {
            guard key.utf8.count <= 256, let text = item.string, text.utf8.count <= 4096 else { throw Self.invalid(what + " must map strings to strings") }
            result[key] = text
        }
        return result
    }

    func inbound(_ value: AyuBridgeValue?, _ what: String) throws -> Data {
        try AyuPluginTelegramTL.decode(value, limit: self.limits.inboundTLBytes, what: what)
    }

    func entities(_ value: AyuBridgeValue) throws -> [Data] {
        guard let items = value.array, items.count <= 1024 else { throw Self.invalid("entities must be a bounded list") }
        return try items.map { try self.inbound($0, "entities") }
    }

    private func messageReference(_ value: AyuBridgeValue, _ what: String) throws -> AyuPluginTelegramMessageReference {
        guard let object = value.object, Set(object.keys) == ["dialog_id", "id", "message"] else { throw Self.invalid(what + " must be a message reference") }
        return AyuPluginTelegramMessageReference(dialogID: try Self.dialogID(object["dialog_id"], what),
            messageID: Int32(try Self.integer(object["id"], Self.int32Range, what)), message: try self.inbound(object["message"], what))
    }

    /// A dispatch result. The response envelope is bounded by the host itself.
    private func outbound(_ data: Data?, what: String) throws -> AyuBridgeValue {
        guard let data else { return .null }
        guard AyuPluginTelegramTL.isBoxed(data) else { throw AyuBridgeFailure("invalid_state", "Telegram backend returned an invalid TL object") }
        guard data.count <= self.limits.outboundTLBytes else { throw AyuBridgeFailure("resource_limit", what + " result exceeds the TL size limit") }
        return AyuPluginTelegramTL.encode(data)
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A local file the host may read: absolute and inside the app container
    /// after resolving `..` and symbolic links.
    private func containerPath(_ value: AyuBridgeValue, _ what: String) throws -> String {
        let path = try Self.text(value, maxBytes: 4096, what)
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value == 0 }) else { throw Self.invalid(what + " must be an absolute path") }
        let resolved = Self.canonicalPath(path)
        guard self.containerRoots.contains(where: { $0 != "/" && resolved.hasPrefix($0 + "/") }) else {
            throw Self.invalid(what + " must lie inside the app container")
        }
        return resolved
    }

    /// Whether callback arguments carrying `payload` TL bytes fit `limit` bytes
    /// of JSON as the relay encodes them (base64 `/` is not escaped). Near the
    /// limit the exact size is measured.
    static func fits(_ arguments: [AyuBridgeValue], payload: Int, limit: Int) -> Bool {
        if (payload + 2) / 3 * 4 + 256 <= limit { return true }
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(arguments) else { return false }
        return data.count <= limit
    }

    /// Blocks the host worker (never main) until the backend answers or the
    /// bounded wait ends; a late completion is ignored.
    private func wait<Value: Sendable>(_ operation: String,
                                       _ start: (@escaping @Sendable (Result<Value, AyuPluginTelegramBackendError>) -> Void) -> Void) throws -> Value {
        let box = ResultBox<Result<Value, AyuPluginTelegramBackendError>>()
        let semaphore = DispatchSemaphore(value: 0)
        start { result in
            if box.store(result) { semaphore.signal() }
        }
        _ = semaphore.wait(timeout: .now() + self.limits.stateReadTimeout)
        guard let result = box.take() else { throw AyuBridgeFailure("timeout", operation + " was not answered in time") }
        switch result {
        case let .success(value): return value
        case let .failure(error): throw Self.failure(error)
        }
    }
}
