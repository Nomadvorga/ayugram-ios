import Foundation

/// Hook registration and the hook chains of `Python/protocol-telegram.md`.
/// The backend calls the `intercept…` methods for objects whose constructor
/// `hookFilter` lists; each plugin is asked in descending priority (ties in
/// ascending plugin id), at most once per event, and has
/// `Limits.hookAnswerTimeout` to answer before the chain continues as if it
/// had returned strategy 0. Completions run on the bridge's queue, or on the
/// caller's thread when no plugin is interested.
extension AyuPluginTelegramBridge {
    struct Participant: Sendable {
        let owner: String
        /// Nil for a three-field `hooks.register` send hook owned by the application bridge.
        let epoch: UUID?
        let priority: Int32
        let callbackID: String
    }

    enum Step<State: Sendable>: Sendable {
        case next(State)
        case final(State)
        case cancel
    }

    struct SendState: Sendable {
        var message: AyuPluginTelegramHookedMessage
        var remapEntities = false
    }

    // MARK: Registration

    func prepareHookSet(owner: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        try Self.closed(arguments, required: ["requests", "updates", "containers", "on_request", "on_response", "on_update", "on_updates"])
        let total = ["requests", "updates", "containers"].reduce(0) { $0 + (arguments[$1]?.array?.count ?? 0) }
        guard total <= self.limits.hookConstructors else { throw AyuBridgeFailure("resource_limit", "Too many hook constructors") }
        let set = HookSet(
            requests: try Self.constructors(arguments["requests"], "requests"),
            updates: try Self.constructors(arguments["updates"], "updates"),
            containers: try Self.constructors(arguments["containers"], "containers"),
            onRequest: try Self.callback(arguments["on_request"], context: context).id,
            onResponse: try Self.callback(arguments["on_response"], context: context).id,
            onUpdate: try Self.callback(arguments["on_update"], context: context).id,
            onUpdates: try Self.callback(arguments["on_updates"], context: context).id)
        return AyuBridgeProviderResult(.value(.null), commit: { _ in
            self.lock.lock()
            var state = self.owners[owner] ?? Owner()
            // One assignment replaces the whole set; three empty lists clear it.
            state.hooks = total == 0 ? nil : set
            self.owners[owner] = state
            let (filter, backend) = self.refreshFilterLocked()
            self.lock.unlock()
            if let filter { backend?.hookFilterDidChange(filter) }
        })
    }

    private static func constructors(_ value: AyuBridgeValue?, _ what: String) throws -> [UInt32: Int32] {
        guard let items = value?.array else { throw Self.invalid(what + " must be a list") }
        var result: [UInt32: Int32] = [:]
        var previous: Int64 = -1
        for item in items {
            guard let pair = item.array, pair.count == 2, let constructor = pair[0].integer, constructor > previous,
                  constructor <= Int64(UInt32.max), let priority = pair[1].integer, Self.int32Range.contains(priority) else {
                throw Self.invalid(what + " must hold [constructor, priority] pairs sorted by constructor without duplicates")
            }
            previous = constructor
            result[UInt32(constructor)] = Int32(priority)
        }
        return result
    }

    func prepareSendHook(owner: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        try Self.closed(arguments, required: ["priority", "callback"])
        let priority = Int32(try Self.integer(arguments["priority"], Self.int32Range, "priority"))
        let callbackID = try Self.callback(arguments["callback"], context: context).id
        let token = UUID().uuidString
        self.lock.lock()
        var state = self.owners[owner] ?? Owner()
        guard state.sendHooks.count < self.limits.sendHooksPerGeneration else {
            self.lock.unlock()
            throw AyuBridgeFailure("resource_limit", "Send hook quota exceeded")
        }
        self.sendHookOrder &+= 1
        state.sendHooks[token] = SendHook(priority: priority, callbackID: callbackID, order: self.sendHookOrder, committed: false)
        let epoch = state.epoch
        self.owners[owner] = state
        self.lock.unlock()
        return AyuBridgeProviderResult(.value(.string(token)), rollback: {
            self.removeSendHook(token: token, owner: owner, epoch: epoch)
        }, commit: { _ in
            // A detach between reservation and commit removed the owner entry.
            self.lock.lock()
            if self.owners[owner]?.epoch == epoch { self.owners[owner]?.sendHooks[token]?.committed = true }
            self.lock.unlock()
        })
    }

    /// `hooks.unregister {token}` for a token of `telegram.hooks.send_message`;
    /// nil when the token is not one, so the three-field hook's owner handles it.
    func prepareUnregister(pluginID: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeProviderResult? {
        guard Set(arguments.keys) == ["token"], let token = arguments["token"]?.string else { return nil }
        self.lock.lock()
        let holder = self.owners.first(where: { $0.value.sendHooks[token] != nil })?.key
        self.lock.unlock()
        guard let holder else { return nil }
        guard holder == pluginID else { throw AyuBridgeFailure("invalid_handle", "Send hook token belongs to another plugin") }
        return AyuBridgeProviderResult(.value(.null), commit: { _ in self.removeSendHook(token: token, owner: pluginID, epoch: nil) })
    }

    private func removeSendHook(token: String, owner: String, epoch: UUID?) {
        self.lock.lock()
        if epoch == nil || self.owners[owner]?.epoch == epoch { self.owners[owner]?.sendHooks.removeValue(forKey: token) }
        self.lock.unlock()
    }

    /// Recomputes the union filter. Returns it only when it changed, with the
    /// backend to tell; the caller holds `lock` and notifies after unlocking.
    func refreshFilterLocked() -> (AyuPluginTelegramHookFilter?, AyuPluginTelegramBackend?) {
        var filter = AyuPluginTelegramHookFilter()
        for state in self.owners.values {
            guard let hooks = state.hooks else { continue }
            filter.requests.formUnion(hooks.requests.keys)
            filter.updates.formUnion(hooks.updates.keys)
            filter.containers.formUnion(hooks.containers.keys)
        }
        guard filter != self.publishedFilter else { return (nil, self.backend) }
        self.publishedFilter = filter
        return (filter, self.backend)
    }

    // MARK: Interception (called by the backend)

    public var hookFilter: AyuPluginTelegramHookFilter {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.publishedFilter
    }

    /// Whether any plugin hooks outgoing messages, through either operation.
    public var hasSendMessageHooks: Bool { !self.sendParticipants().isEmpty }

    /// Before an outgoing API request is serialized. `.cancel` completes the
    /// request for its sender with no response and no error. A replacement is
    /// never one of the functions `telegram.request` refuses; the backend must
    /// still check that it is a function of its layer.
    public func interceptRequest(account: Int64, function: Data, completion: @escaping @Sendable (AyuPluginTelegramHookDecision) -> Void) {
        let limit = self.limits.inboundTLBytes
        self.interceptObject(account: account, object: function, field: "request", completion: completion, select: { hooks, constructor in
            hooks.requests[constructor].map { ($0, hooks.onRequest) }
        }, accept: { data in
            data.count <= limit && AyuPluginTelegramRefusedFunctions.table[AyuPluginTelegramTL.constructor(of: data)] == nil
        })
    }

    /// For each listed update inside a processed container; `.cancel` drops the update.
    public func interceptUpdate(account: Int64, update: Data, completion: @escaping @Sendable (AyuPluginTelegramHookDecision) -> Void) {
        self.interceptObject(account: account, object: update, field: "update", completion: completion, select: { hooks, constructor in
            hooks.updates[constructor].map { ($0, hooks.onUpdate) }
        }, accept: { _ in true })
    }

    /// Before a listed container is processed; `.cancel` drops the container.
    public func interceptUpdates(account: Int64, container: Data, completion: @escaping @Sendable (AyuPluginTelegramHookDecision) -> Void) {
        self.interceptObject(account: account, object: container, field: "updates", completion: completion, select: { hooks, constructor in
            hooks.containers[constructor].map { ($0, hooks.onUpdates) }
        }, accept: { _ in true })
    }

    /// When the response of a hooked request arrives, before it is delivered.
    /// `constructor` is the id of the request that was sent. A plugin can
    /// replace the response and the error but cannot remove either.
    public func interceptResponse(account: Int64, constructor: UInt32, result: AyuPluginTelegramResponse,
                                  completion: @escaping @Sendable (AyuPluginTelegramResponse) -> Void) {
        let participants = self.participants { $0.hooks.flatMap { hooks in hooks.requests[constructor].map { ($0, hooks.onResponse) } } }
        guard result.response.map(AyuPluginTelegramTL.isBoxed) ?? true else { completion(result); return }
        let limits = self.limits
        self.runChain(participants, state: result, arguments: { current, _ in
            let error = current.error.map { AyuPluginTelegramTL.error(code: $0.code, text: $0.text) }
            let values: [AyuBridgeValue] = [.integer(account), .integer(Int64(constructor)),
                current.response.map(AyuPluginTelegramTL.encode) ?? .null, error.map(AyuPluginTelegramTL.encode) ?? .null]
            return Self.hookArguments(values, payload: (current.response?.count ?? 0) + (error?.count ?? 0), limits: limits)
        }, apply: { current, _, answer in
            guard let object = answer.object, Set(object.keys).isSubset(of: ["strategy", "response", "error"]),
                  let strategy = object["strategy"]?.integer, strategy == 2 || strategy == 3 else { return .next(current) }
            var next = current
            if let value = object["response"], value != .null,
               let data = try? AyuPluginTelegramTL.decode(value, limit: limits.inboundTLBytes, what: "response") {
                next.response = data
            }
            if let value = object["error"], value != .null,
               let data = try? AyuPluginTelegramTL.decode(value, limit: limits.inboundTLBytes, what: "error"),
               let error = AyuPluginTelegramTL.parseError(data) {
                next.error = error
            }
            return strategy == 3 ? .final(next) : .next(next)
        }, completion: { completion($0 ?? result) })
    }

    /// Before an outgoing message is enqueued (text and media, not forwards).
    /// Runs the typed hooks and the three-field `hooks.register` hooks as one
    /// priority-ordered chain; a plugin registered both ways is asked through
    /// the typed hook only. A plugin result that is invalid, or that changes a
    /// field outside the backend's `sendHookMutableFields`, changes nothing.
    public func interceptSendMessage(account: Int64, message: AyuPluginTelegramHookedMessage,
                                     completion: @escaping @Sendable (AyuPluginTelegramSendDecision) -> Void) {
        var initial = message
        initial.replyToMessageID = message.replyTo?.messageID
        initial.replyToTopMessageID = message.replyToTop?.messageID
        if initial.entities?.isEmpty == true { initial.entities = nil }
        let mutable = self.currentBackend()?.sendHookMutableFields ?? []
        let limits = self.limits
        self.runChain(self.sendParticipants(), state: SendState(message: initial), arguments: { state, participant in
            if participant.epoch == nil {
                return AyuBridgeSendHookChain(message: state.message.message, caption: state.message.caption,
                                              peerID: state.message.peer, accountIndex: account).arguments
            }
            let payload = [state.message.replyTo?.message, state.message.replyToTop?.message, state.message.document, state.message.photo]
                .reduce((state.message.entities ?? []).reduce(0) { $0 + $1.count }) { $0 + ($1?.count ?? 0) }
            return Self.hookArguments([.integer(account), .object(Self.hookParameters(state.message))], payload: payload, limits: limits)
        }, apply: { state, participant, answer in
            participant.epoch == nil ? Self.legacySendStep(answer, state: state, account: account, mutable: mutable)
                : Self.typedSendStep(answer, state: state, mutable: mutable, limit: limits.inboundTLBytes)
        }, completion: { state in
            completion(state.map { .send($0.message, remapEntities: $0.remapEntities) } ?? .cancel)
        })
    }

    // MARK: Chains

    private func interceptObject(account: Int64, object: Data, field: String, completion: @escaping @Sendable (AyuPluginTelegramHookDecision) -> Void,
                                 select: (HookSet, UInt32) -> (Int32, String)?, accept: @escaping @Sendable (Data) -> Bool) {
        guard AyuPluginTelegramTL.isBoxed(object) else { completion(.proceed(object)); return }
        let constructor = AyuPluginTelegramTL.constructor(of: object)
        let participants = self.participants { $0.hooks.flatMap { select($0, constructor) } }
        let limits = self.limits
        self.runChain(participants, state: object, arguments: { current, _ in
            Self.hookArguments([.integer(account), AyuPluginTelegramTL.encode(current)], payload: current.count, limits: limits)
        }, apply: { current, _, answer in
            guard let fields = answer.object, Set(fields.keys).isSubset(of: ["strategy", field]), let strategy = fields["strategy"]?.integer else {
                return .next(current)
            }
            switch strategy {
            case 1: return .cancel
            case 2, 3:
                var next = current
                // A replacement of the wrong shape changes nothing, but MODIFY_FINAL still ends the chain.
                if let value = fields[field], value != .null,
                   let data = try? AyuPluginTelegramTL.decode(value, limit: limits.inboundTLBytes, what: field), accept(data) {
                    next = data
                }
                return strategy == 3 ? .final(next) : .next(next)
            default: return .next(current)
            }
        }, completion: { completion($0.map { .proceed($0) } ?? .cancel) })
    }

    /// Interested plugins of one TL hook stream, in calling order.
    private func participants(_ select: (Owner) -> (Int32, String)?) -> [Participant] {
        self.lock.lock()
        let found = self.owners.compactMap { owner, state in
            select(state).map { Participant(owner: owner, epoch: state.epoch, priority: $0.0, callbackID: $0.1) }
        }
        self.lock.unlock()
        return Self.ordered(found)
    }

    private func sendParticipants() -> [Participant] {
        self.lock.lock()
        var found: [Participant] = self.owners.compactMap { owner, state in
            // One call per plugin per event: its highest-priority registration.
            let hooks = state.sendHooks.values.filter(\.committed)
            guard let hook = hooks.max(by: { $0.priority == $1.priority ? $0.order > $1.order : $0.priority < $1.priority }) else { return nil }
            return Participant(owner: owner, epoch: state.epoch, priority: hook.priority, callbackID: hook.callbackID)
        }
        let environment = self.environment
        self.lock.unlock()
        var seen = Set(found.map(\.owner))
        // The source lists hooks by descending priority, then registration order.
        for hook in environment?.legacySendHooks() ?? [] where seen.insert(hook.pluginID).inserted {
            found.append(Participant(owner: hook.pluginID, epoch: nil, priority: Int32(clamping: hook.priority), callbackID: hook.callbackID))
        }
        return Self.ordered(found)
    }

    private static func ordered(_ participants: [Participant]) -> [Participant] {
        participants.sorted { $0.priority == $1.priority ? $0.owner < $1.owner : $0.priority > $1.priority }
    }

    private static func hookArguments(_ values: [AyuBridgeValue], payload: Int, limits: Limits) -> [AyuBridgeValue]? {
        guard payload <= limits.outboundTLBytes, Self.fits(values, payload: payload, limit: limits.hookPayloadBytes) else { return nil }
        return values
    }

    private func runChain<State: Sendable>(_ participants: [Participant], state: State,
                                           arguments: @escaping @Sendable (State, Participant) -> [AyuBridgeValue]?,
                                           apply: @escaping @Sendable (State, Participant, AyuBridgeValue) -> Step<State>,
                                           completion: @escaping @Sendable (State?) -> Void) {
        self.lock.lock()
        // Past the bound, events pass unchanged rather than queue without limit.
        guard !participants.isEmpty, self.activeChains < self.limits.pendingHookEvents else {
            self.lock.unlock()
            completion(state)
            return
        }
        self.activeChains += 1
        self.lock.unlock()
        self.queue.async {
            self.step(participants, 0, state, arguments, apply) { result in
                self.lock.lock(); self.activeChains -= 1; self.lock.unlock()
                completion(result)
            }
        }
    }

    private func step<State: Sendable>(_ participants: [Participant], _ index: Int, _ state: State,
                                       _ arguments: @escaping @Sendable (State, Participant) -> [AyuBridgeValue]?,
                                       _ apply: @escaping @Sendable (State, Participant, AyuBridgeValue) -> Step<State>,
                                       _ finish: @escaping @Sendable (State?) -> Void) {
        guard index < participants.count else { finish(state); return }
        let participant = participants[index]
        // An object too large to show a plugin passes it by unchanged.
        guard let values = arguments(state, participant) else {
            self.step(participants, index + 1, state, arguments, apply, finish)
            return
        }
        self.ask(participant, values) { answer in
            guard let answer else {
                self.step(participants, index + 1, state, arguments, apply, finish)
                return
            }
            switch apply(state, participant, answer) {
            case let .next(next): self.step(participants, index + 1, next, arguments, apply, finish)
            case let .final(next): finish(next)
            case .cancel: finish(nil)
            }
        }
    }

    /// One bounded round trip. `completion` runs once on `queue` with the
    /// decoded answer, or nil after the timeout, a failed callback or a detach.
    private func ask(_ participant: Participant, _ arguments: [AyuBridgeValue], completion: @escaping @Sendable (AyuBridgeValue?) -> Void) {
        let queue = self.queue
        let box = AnswerBox(owner: participant.owner) { value in queue.async { completion(value) } }
        let registered = participant.epoch != nil || (self.currentEnvironment()?.legacySendHooks() ?? []).contains {
            $0.pluginID == participant.owner && $0.callbackID == participant.callbackID
        }
        let key = UUID()
        self.lock.lock()
        let live = registered && (participant.epoch == nil || self.owners[participant.owner]?.epoch == participant.epoch)
        guard live, let invoker = self.invoker else {
            self.lock.unlock()
            box.fire(nil)
            return
        }
        self.pendingAnswers[key] = box
        self.lock.unlock()
        queue.asyncAfter(deadline: .now() + self.limits.hookAnswerTimeout) { self.resolve(key, nil) }
        invoker(participant.owner, participant.callbackID, arguments) { value in self.resolve(key, value) }
    }

    private func resolve(_ key: UUID, _ value: AyuBridgeValue?) {
        self.lock.lock()
        let box = self.pendingAnswers.removeValue(forKey: key)
        self.lock.unlock()
        box?.fire(value)
    }

    // MARK: Send-message hook values

    /// `params` to the plugin. Defaults are omitted: the SDK object then holds Android's.
    static func hookParameters(_ message: AyuPluginTelegramHookedMessage) -> [String: AyuBridgeValue] {
        var params: [String: AyuBridgeValue] = ["peer": .integer(message.peer), "notify": .bool(message.notify)]
        if let text = message.message { params["message"] = .string(text) }
        if let caption = message.caption { params["caption"] = .string(caption) }
        if let entities = message.entities, !entities.isEmpty { params["entities"] = .array(entities.map(AyuPluginTelegramTL.encode)) }
        if let reply = message.replyTo, reply.messageID == message.replyToMessageID { params["replyToMsg"] = AyuPluginTelegramTL.encode(reply.message) }
        if let top = message.replyToTop, top.messageID == message.replyToTopMessageID { params["replyToTopMsg"] = AyuPluginTelegramTL.encode(top.message) }
        if let path = message.path { params["path"] = .string(path) }
        if let document = message.document { params["document"] = AyuPluginTelegramTL.encode(document) }
        if let photo = message.photo { params["photo"] = AyuPluginTelegramTL.encode(photo) }
        if message.scheduleDate != 0 { params["scheduleDate"] = .integer(Int64(message.scheduleDate)) }
        if message.scheduleRepeatPeriod != 0 { params["scheduleRepeatPeriod"] = .integer(Int64(message.scheduleRepeatPeriod)) }
        if !message.searchLinks { params["searchLinks"] = .bool(false) }
        if message.invertMedia { params["invert_media"] = .bool(true) }
        if message.effectID != 0 { params["effect_id"] = .integer(message.effectID) }
        if message.hasMediaSpoilers { params["hasMediaSpoilers"] = .bool(true) }
        if message.monoForumPeer != 0 { params["monoForumPeer"] = .integer(message.monoForumPeer) }
        if message.quickReplyShortcutID != 0 { params["quick_reply_shortcut_id"] = .integer(Int64(message.quickReplyShortcutID)) }
        if message.payStars != 0 { params["payStars"] = .integer(message.payStars) }
        return params
    }

    private static func typedSendStep(_ answer: AyuBridgeValue, state: SendState, mutable: Set<String>, limit: Int) -> Step<SendState> {
        guard let object = answer.object, Set(object.keys).isSubset(of: ["strategy", "params"]), let strategy = object["strategy"]?.integer else {
            return .next(state)
        }
        switch strategy {
        case 1: return .cancel
        case 2, 3:
            var next = state
            if let params = object["params"]?.object, let (message, changed) = Self.modifiedMessage(params, current: state.message, limit: limit),
               changed.isSubset(of: mutable) {
                next.message = message
                // The plugin's entities belong to the text it returned.
                if !changed.isDisjoint(with: ["message", "caption", "entities"]) { next.remapEntities = false }
            }
            return strategy == 3 ? .final(next) : .next(next)
        default: return .next(state)
        }
    }

    private static func legacySendStep(_ answer: AyuBridgeValue, state: SendState, account: Int64, mutable: Set<String>) -> Step<SendState> {
        var chain = AyuBridgeSendHookChain(message: state.message.message, caption: state.message.caption, peerID: state.message.peer, accountIndex: account)
        chain.apply(answer)
        if chain.isCancelled { return .cancel }
        var next = state
        var changed: Set<String> = []
        if chain.message != state.message.message { changed.insert("message") }
        if chain.caption != state.message.caption { changed.insert("caption") }
        if !changed.isEmpty, changed.isSubset(of: mutable) {
            next.message.message = chain.message
            next.message.caption = chain.caption
            next.remapEntities = true
        }
        return chain.isFinal ? .final(next) : .next(next)
    }

    /// The message a typed hook result asks for and the fields it changes, or
    /// nil for a result of the wrong shape. Text can be rewritten, not moved
    /// between `message` and `caption` or removed.
    static func modifiedMessage(_ params: [String: AyuBridgeValue], current: AyuPluginTelegramHookedMessage,
                                limit: Int) -> (AyuPluginTelegramHookedMessage, Set<String>)? {
        var next = current
        var changed: Set<String> = []
        func note<Value: Equatable>(_ key: String, _ path: WritableKeyPath<AyuPluginTelegramHookedMessage, Value>, _ value: Value) {
            if next[keyPath: path] != value { next[keyPath: path] = value; changed.insert(key) }
        }
        for (key, value) in params {
            switch key {
            case "peer":
                guard let peer = value.integer, peer != 0, peer != Int64.min else { return nil }
                note(key, \.peer, peer)
            case "message", "caption":
                let path: WritableKeyPath<AyuPluginTelegramHookedMessage, String?> = key == "message" ? \.message : \.caption
                if value == .null {
                    guard current[keyPath: path] == nil else { return nil }
                } else {
                    guard let text = value.string, current[keyPath: path] != nil, text.utf8.count <= AyuBridgeSendHookChain.maximumTextBytes,
                          key != "message" || !text.isEmpty else { return nil }
                    note(key, path, text)
                }
            case "entities":
                var entities: [Data]?
                if value != .null {
                    guard let items = value.array, items.count <= 1024 else { return nil }
                    var decoded: [Data] = []
                    for item in items {
                        guard let data = try? AyuPluginTelegramTL.decode(item, limit: limit, what: key) else { return nil }
                        decoded.append(data)
                    }
                    entities = decoded.isEmpty ? nil : decoded
                }
                note(key, \.entities, entities)
            case "replyToMsg", "replyToTopMsg":
                var id: Int32?
                if value != .null {
                    guard let raw = value.integer, raw != 0, Self.int32Range.contains(raw) else { return nil }
                    id = Int32(raw)
                }
                if key == "replyToMsg" {
                    if next.replyToMessageID != id { next.replyTo = nil }
                    note(key, \.replyToMessageID, id)
                } else {
                    if next.replyToTopMessageID != id { next.replyToTop = nil }
                    note(key, \.replyToTopMessageID, id)
                }
            case "notify", "searchLinks", "invert_media", "hasMediaSpoilers":
                guard let flag = value.bool else { return nil }
                switch key {
                case "notify": note(key, \.notify, flag)
                case "searchLinks": note(key, \.searchLinks, flag)
                case "invert_media": note(key, \.invertMedia, flag)
                default: note(key, \.hasMediaSpoilers, flag)
                }
            case "scheduleDate", "scheduleRepeatPeriod":
                guard let raw = value.integer, (0...Int64(Int32.max)).contains(raw) else { return nil }
                note(key, key == "scheduleDate" ? \.scheduleDate : \.scheduleRepeatPeriod, Int32(raw))
            case "effect_id":
                guard let effect = value.integer else { return nil }
                note(key, \.effectID, effect)
            default:
                return nil
            }
        }
        return (next, changed)
    }
}
