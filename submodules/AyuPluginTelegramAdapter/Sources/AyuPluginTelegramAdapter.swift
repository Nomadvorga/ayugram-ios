import AyuPluginBridge
import Foundation
import SwiftSignalKit
import TelegramCore

/// The app's `AyuPluginTelegramBackend`: maps the bridge's account slots to `Account`s and
/// carries each operation out through TelegramCore's plugin surface (`Sources/AyuPlugins`).
/// It holds no Telegram logic of its own and no Postbox access; what a request asks for is
/// decided by `AyuPluginTelegramSendPlan` and its siblings in the bridge module, where it is tested.
///
/// Methods are called on the bridge's host worker and return at once; completions run on
/// TelegramCore's queues.
public final class AyuPluginTelegramAdapter: AyuPluginTelegramBackend, @unchecked Sendable {
    public static let shared = AyuPluginTelegramAdapter()

    /// One account slot of the application bridge. `identity` is the slot's, so a reference the
    /// bridge resolved before the slot was rebound is refused.
    public struct Slot {
        public let index: Int64
        public let identity: UUID
        public let account: Account

        public init(index: Int64, identity: UUID, account: Account) {
            self.index = index
            self.identity = identity
            self.account = account
        }
    }

    /// Opens a chat, a profile or a username on main. Injected by app UI code; without it
    /// `telegram.navigation.open` is not served.
    public typealias Navigator = @Sendable (_ account: Account, _ target: AyuPluginTelegramNavigationTarget,
                                            _ completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) -> Void
    /// Drives the shared audio player. Injected by app UI code; without it `telegram.player` is not served.
    public typealias Player = @Sendable (_ action: AyuPluginTelegramPlayerAction,
                                         _ completion: @escaping @Sendable (Result<AyuPluginTelegramPlayerState, AyuPluginTelegramBackendError>) -> Void) -> Void

    private struct State {
        var slots: [Int64: Slot] = [:]
        var bridge: AyuPluginTelegramBridge?
        var describesScreen = false
        var routesSendHook = false
        var navigator: Navigator?
        var player: Player?
    }

    private let lock = NSLock()
    private var state = State()
    /// File preparation blocks; it never runs on the bridge's worker or on a TelegramCore queue.
    private let preparationQueue = DispatchQueue(label: "AyuPluginTelegramAdapter.media", qos: .userInitiated, attributes: .concurrent)

    private static let coreOperations: Set<String> = [
        "telegram.request", "telegram.request.cancel", "telegram.connection", "telegram.send_message", "telegram.edit_message",
        "telegram.peer", "telegram.messages", "telegram.files.path", "telegram.files.load",
    ]
    /// Every action of the bridge has its TelegramCore call in `perform` below.
    private static let actionOperations = AyuPluginTelegramAction.operations

    private func read<Value>(_ body: (State) -> Value) -> Value {
        self.lock.lock(); defer { self.lock.unlock() }
        return body(self.state)
    }

    private func write(_ body: (inout State) -> Void) {
        self.lock.lock(); defer { self.lock.unlock() }
        body(&self.state)
    }

    // MARK: Application wiring

    /// Replaces the registered accounts; the application binding calls it whenever its slots change.
    public func setAccounts(_ slots: [Slot]) {
        self.write { $0.slots = Dictionary(slots.map { ($0.index, $0) }, uniquingKeysWith: { _, last in last }) }
    }

    /// Makes this adapter the bridge's backend. `describesScreen` and `routesSendHook` state what
    /// the caller wired: that its screen snapshot fills `telegram`, and that outgoing messages of
    /// the chat screen pass `applySendHooks`. The two operations are listed only then.
    public func bind(to bridge: AyuPluginTelegramBridge = .shared, describesScreen: Bool, routesSendHook: Bool) {
        self.write {
            $0.bridge = bridge
            $0.describesScreen = describesScreen
            $0.routesSendHook = routesSendHook
        }
        bridge.bind(backend: self)
    }

    public func setNavigator(_ navigator: Navigator?) {
        self.write { $0.navigator = navigator }
    }

    public func setPlayer(_ player: Player?) {
        self.write { $0.player = player }
    }

    private func account(_ reference: AyuPluginTelegramAccount) -> Account? {
        return self.read { state in
            guard let slot = state.slots[reference.index], slot.identity == reference.identity else { return nil }
            return slot.account
        }
    }

    private func slotIndex(where matches: (Account) -> Bool) -> Int64? {
        return self.read { state in state.slots.values.first(where: { matches($0.account) })?.index }
    }

    private static func backendError(_ error: AyuPluginCoreError) -> AyuPluginTelegramBackendError {
        switch error {
        case let .invalidArguments(text): return .invalidArguments(text)
        case let .unsupported(text): return .unsupported(text)
        }
    }

    private static func backendError(_ error: Error) -> AyuPluginTelegramBackendError {
        if let error = error as? AyuPluginTelegramBackendError { return error }
        if let error = error as? AyuPluginCoreError { return self.backendError(error) }
        return .invalidArguments("The request could not be read")
    }

    // MARK: AyuPluginTelegramBackend

    public var operations: Set<String> {
        let state = self.read { $0 }
        var result = Self.coreOperations.union(Self.actionOperations)
        if state.describesScreen { result.insert("telegram.screen") }
        if state.routesSendHook { result.insert("telegram.hooks.send_message") }
        if ayuPluginInterceptsAllHookStreams { result.insert("telegram.hooks.set") }
        if state.navigator != nil { result.insert("telegram.navigation.open") }
        if state.player != nil { result.insert("telegram.player") }
        return result
    }

    public var sendMessageParameters: Set<String> { AyuPluginTelegramSendPlan.supportedParameters }

    public var sendHookMutableFields: Set<String> { ayuPluginSendHookMutableFields }

    public func sendRequest(account: AyuPluginTelegramAccount, function: Data, flags: Int32,
                            completion: @escaping @Sendable (AyuPluginTelegramRequestResult) -> Void) throws -> AyuPluginTelegramCancellation {
        guard let target = self.account(account) else { throw AyuPluginTelegramBackendError.accountUnavailable }
        let disposable: Disposable
        do {
            // Android's RequestFlagFailOnServerErrors.
            disposable = try ayuPluginSendRawRequest(account: target, function: function, failOnServerErrors: flags & 2 != 0, completion: { result in
                switch result {
                case let .response(data): completion(.response(data))
                case let .rpcError(code, text): completion(.rpcError(AyuPluginTelegramRPCError(code: code, text: text)))
                case .sessionClosed: completion(.transportFailure("SESSION_CLOSED"))
                case .cancelledByHook: completion(.cancelledByHook)
                }
            })
        } catch {
            throw Self.backendError(error)
        }
        let cancellation = AyuPluginDisposableBox(disposable)
        return AyuPluginTelegramCancellation { cancellation.dispose() }
    }

    public func connectionState(account: AyuPluginTelegramAccount,
                                completion: @escaping @Sendable (Result<AyuPluginTelegramConnectionState, AyuPluginTelegramBackendError>) -> Void) {
        guard let target = self.account(account) else { completion(.failure(.accountUnavailable)); return }
        let network = target.network
        let time = network.globalTime
        let difference = network.globalTimeDifference
        let datacenterID = Int32(clamping: network.datacenterId)
        let _ = (target.networkState |> take(1)).start(next: { state in
            let status: AyuPluginTelegramConnectionState.Status
            switch state {
            case .waitingForNetwork: status = .init(networkAvailable: false, connected: false, updating: false, usesProxy: false)
            case let .connecting(proxy): status = .init(networkAvailable: true, connected: false, updating: false, usesProxy: proxy != nil)
            case let .updating(proxy): status = .init(networkAvailable: true, connected: true, updating: true, usesProxy: proxy != nil)
            case let .online(proxy): status = .init(networkAvailable: true, connected: true, updating: false, usesProxy: proxy != nil)
            }
            completion(.success(AyuPluginTelegramConnectionState(timeMilliseconds: Int64((time * 1000).rounded()),
                timeDifference: Int32(clamping: Int64(difference.rounded())), status: status, datacenterID: datacenterID)))
        })
    }

    public func sendMessage(account: AyuPluginTelegramAccount, message: AyuPluginTelegramOutgoingMessage,
                            completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        guard let target = self.account(account) else { completion(.failure(.accountUnavailable)); return }
        let plan: AyuPluginTelegramSendPlan
        do { plan = try AyuPluginTelegramSendPlan(message) } catch { completion(.failure(Self.backendError(error))); return }
        let target_ = AyuPluginUncheckedBox(target)
        self.preparationQueue.async {
            let media: AyuPluginOutgoingMedia
            do { media = try AyuPluginLocalMedia.prepare(plan.media, highQuality: plan.highQuality) } catch { completion(.failure(Self.backendError(error))); return }
            let outgoing = AyuPluginOutgoingMessage(dialogId: plan.dialog.dialogID, text: plan.text, entities: plan.entities, media: media,
                replyTo: plan.reply.map { (dialogId: $0.dialog.dialogID, messageId: $0.messageID) }, threadMessageId: plan.threadMessageID,
                silent: plan.silent, scheduleTime: plan.scheduleDate, scheduleRepeatPeriod: plan.scheduleRepeatPeriod,
                disablesLinkPreview: plan.disablesLinkPreview, invertsMedia: plan.invertsMedia, effectId: plan.effectID, hasSpoiler: plan.hasSpoiler)
            let _ = ayuPluginEnqueueMessage(account: target_.value, message: outgoing).start(error: { error in
                completion(.failure(Self.backendError(error)))
            }, completed: {
                completion(.success(()))
            })
        }
    }

    public func editMessage(account: AyuPluginTelegramAccount, edit: AyuPluginTelegramMessageEdit,
                            completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        guard let target = self.account(account) else { completion(.failure(.accountUnavailable)); return }
        let plan: AyuPluginTelegramEditPlan
        do { plan = try AyuPluginTelegramEditPlan(edit) } catch { completion(.failure(Self.backendError(error))); return }
        let target_ = AyuPluginUncheckedBox(target)
        self.preparationQueue.async {
            var media: AyuPluginOutgoingMedia = .none
            if let attachment = plan.attachment {
                do {
                    media = try AyuPluginLocalMedia.prepare(.file(path: attachment.path, kind: attachment.kind, description: nil), highQuality: false)
                } catch { completion(.failure(Self.backendError(error))); return }
            }
            let request = AyuPluginMessageEdit(dialogId: plan.dialog.dialogID, messageId: plan.messageID, text: plan.text, entities: plan.entities,
                                               media: media, hasSpoiler: plan.attachment?.spoiler ?? false)
            let _ = ayuPluginRequestEditMessage(account: target_.value, edit: request).start(error: { error in
                completion(.failure(Self.backendError(error)))
            }, completed: {
                completion(.success(()))
            })
        }
    }

    public func peer(account: AyuPluginTelegramAccount, kind: AyuPluginTelegramPeerKind, id: Int64,
                     completion: @escaping @Sendable (Result<Data?, AyuPluginTelegramBackendError>) -> Void) {
        guard let target = self.account(account) else { completion(.failure(.accountUnavailable)); return }
        guard AyuPluginTelegramDialog.isPeerID(id) else { completion(.success(nil)); return }
        let coreKind: AyuPluginPeerKind
        switch kind {
        case .user: coreKind = .user
        case .chat: coreKind = .chat
        case .userFull: coreKind = .userFull
        case .chatFull: coreKind = .chatFull
        }
        let _ = ayuPluginPeerTL(account: target, kind: coreKind, id: id).start(next: { data in
            completion(.success(data))
        })
    }

    public func messages(account: AyuPluginTelegramAccount, dialogID: Int64, ids: [Int32],
                         completion: @escaping @Sendable (Result<[Data?], AyuPluginTelegramBackendError>) -> Void) {
        guard let target = self.account(account) else { completion(.failure(.accountUnavailable)); return }
        guard let dialog = AyuPluginTelegramDialog(dialogID: dialogID) else {
            completion(.failure(.invalidArguments("dialog_id is not a user, group or channel")))
            return
        }
        let _ = ayuPluginMessagesTL(account: target, dialogId: dialog.dialogID, ids: ids).start(next: { values in
            completion(.success(values))
        }, error: { error in
            completion(.failure(Self.backendError(error)))
        })
    }

    public func navigate(account: AyuPluginTelegramAccount, target: AyuPluginTelegramNavigationTarget,
                         completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        guard let navigator = self.read({ $0.navigator }) else { completion(.failure(.unsupported("telegram.navigation.open"))); return }
        guard let resolved = self.account(account) else { completion(.failure(.accountUnavailable)); return }
        navigator(resolved, target, completion)
    }

    public func filePath(account: AyuPluginTelegramAccount, target: Data, cache: Bool,
                         completion: @escaping @Sendable (Result<String, AyuPluginTelegramBackendError>) -> Void) {
        guard let resolved = self.account(account) else { completion(.failure(.accountUnavailable)); return }
        // `cache` selects one of Android's directories; the app has one media store.
        do { completion(.success(try ayuPluginFilePath(account: resolved, target: target))) } catch { completion(.failure(Self.backendError(error))) }
    }

    public func loadFile(account: AyuPluginTelegramAccount, target: Data, parent: Data?, priority: Int32, cacheType: Int32,
                         completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        guard let resolved = self.account(account) else { completion(.failure(.accountUnavailable)); return }
        // `priority` and `cacheType` have no counterpart: the media store schedules by its own
        // fetch priorities and has one location.
        let _ = ayuPluginLoadFile(account: resolved, target: target, parent: parent).start(error: { error in
            completion(.failure(Self.backendError(error)))
        }, completed: {
            completion(.success(()))
        })
    }

    public func cancelFileLoad(account: AyuPluginTelegramAccount, target: Data,
                               completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        guard let resolved = self.account(account) else { completion(.failure(.accountUnavailable)); return }
        do { try ayuPluginCancelFileLoad(account: resolved, target: target); completion(.success(())) } catch { completion(.failure(Self.backendError(error))) }
    }

    public func player(action: AyuPluginTelegramPlayerAction,
                       completion: @escaping @Sendable (Result<AyuPluginTelegramPlayerState, AyuPluginTelegramBackendError>) -> Void) {
        guard let player = self.read({ $0.player }) else { completion(.failure(.unsupported("telegram.player"))); return }
        player(action, completion)
    }

    public func perform(account: AyuPluginTelegramAccount, action: AyuPluginTelegramAction,
                        completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) {
        guard let target = self.account(account) else { completion(.failure(.accountUnavailable)); return }
        let signal: Signal<Never, AyuPluginCoreError>
        switch action {
        case let .deleteMessages(dialogID, ids, revoke):
            signal = ayuPluginDeleteMessages(account: target, dialogId: dialogID, ids: ids, forEveryone: revoke)
        case let .readDialog(dialogID, maxID):
            signal = ayuPluginReadDialog(account: target, dialogId: dialogID, maxId: maxID)
        case let .processUpdates(updates):
            do { try ayuPluginProcessUpdates(account: target, updates: updates); completion(.success(())) } catch { completion(.failure(Self.backendError(error))) }
            return
        case let .storePeers(users, chats):
            signal = ayuPluginStorePeers(account: target, users: users, chats: chats)
        case let .loadFullPeer(kind, id):
            signal = ayuPluginLoadFullPeer(account: target, isUser: kind == .user, id: id)
        }
        let _ = signal.start(error: { error in
            completion(.failure(Self.backendError(error)))
        }, completed: {
            completion(.success(()))
        })
    }

    // MARK: Request and update hooks

    public func hookFilterDidChange(_ filter: AyuPluginTelegramHookFilter) {
        guard !filter.isEmpty, let bridge = self.read({ $0.bridge }) else {
            ayuPluginSetHookInterceptor(nil)
            return
        }
        func ids(_ values: Set<UInt32>) -> Set<Int32> { Set(values.map { Int32(bitPattern: $0) }) }
        ayuPluginSetHookInterceptor(AyuPluginHookInterceptor(
            requests: ids(filter.requests), updates: ids(filter.updates), containers: ids(filter.containers),
            servesNetwork: { [weak self] network in
                self?.slotIndex(where: { $0.network === network }) != nil
            },
            servesAccount: { [weak self] peerId in
                self?.slotIndex(where: { $0.peerId == peerId }) != nil
            },
            interceptRequest: { [weak self] network, function, completion in
                guard let index = self?.slotIndex(where: { $0.network === network }) else { completion(function); return }
                let completion = AyuPluginUncheckedBox(completion)
                bridge.interceptRequest(account: index, function: function) { decision in
                    switch decision {
                    case let .proceed(data): completion.value(data)
                    case .cancel: completion.value(nil)
                    }
                }
            },
            interceptResponse: { [weak self] network, constructorId, response, error, completion in
                guard let index = self?.slotIndex(where: { $0.network === network }) else { completion(response, error); return }
                let completion = AyuPluginUncheckedBox(completion)
                let result = AyuPluginTelegramResponse(response: response, error: error.map { AyuPluginTelegramRPCError(code: $0.code, text: $0.text) })
                bridge.interceptResponse(account: index, constructor: UInt32(bitPattern: constructorId), result: result) { answer in
                    completion.value(answer.response, answer.error.map { (code: $0.code, text: $0.text) })
                }
            },
            interceptContainer: { [weak self] peerId, container, completion in
                guard let index = self?.slotIndex(where: { $0.peerId == peerId }) else { completion(container); return }
                let completion = AyuPluginUncheckedBox(completion)
                bridge.interceptUpdates(account: index, container: container) { decision in
                    switch decision {
                    case let .proceed(data): completion.value(data)
                    case .cancel: completion.value(nil)
                    }
                }
            },
            interceptUpdate: { [weak self] peerId, update, completion in
                guard let index = self?.slotIndex(where: { $0.peerId == peerId }) else { completion(update); return }
                let completion = AyuPluginUncheckedBox(completion)
                bridge.interceptUpdate(account: index, update: update) { decision in
                    switch decision {
                    case let .proceed(data): completion.value(data)
                    case .cancel: completion.value(nil)
                    }
                }
            }
        ))
    }

    // MARK: Send-message hook (called by the chat screen)

    /// Whether any plugin hooks outgoing messages. Cheap; the chat screen checks it before
    /// taking the asynchronous path of `applySendHooks`.
    public var hasSendMessageHooks: Bool {
        return self.read({ $0.bridge })?.hasSendMessageHooks ?? false
    }

    /// Shows the messages the chat screen is about to queue for `peerId` to the plugins' send
    /// hooks, one after another, and reports on main what to queue instead: the messages with
    /// the hooks' changes applied, or nil when a hook cancelled the send. Forwards, and chats
    /// without an Android dialog id, pass unchanged.
    public func applySendHooks(account: Account, peerId: EnginePeer.Id, messages: [EnqueueMessage], completion: @escaping ([EnqueueMessage]?) -> Void) {
        let finish: ([EnqueueMessage]?) -> Void = { result in
            Queue.mainQueue().async { completion(result) }
        }
        guard let bridge = self.read({ $0.bridge }), let index = self.slotIndex(where: { $0 === account }) else {
            finish(messages)
            return
        }
        let _ = ayuPluginDescribeOutgoingMessages(account: account, peerId: peerId, messages: messages).start(next: { described in
            let run = AyuPluginSendHookRun(bridge: bridge, accountIndex: index, peerId: peerId, messages: messages, described: described, finish: finish)
            run.step(0)
        })
    }
}

/// One pass of the send hooks over a batch of outgoing messages.
private final class AyuPluginSendHookRun: @unchecked Sendable {
    private let bridge: AyuPluginTelegramBridge
    private let accountIndex: Int64
    private let peerId: EnginePeer.Id
    private let described: [AyuPluginHookedOutgoingMessage?]
    private let finish: ([EnqueueMessage]?) -> Void
    private let lock = NSLock()
    private var messages: [EnqueueMessage]

    init(bridge: AyuPluginTelegramBridge, accountIndex: Int64, peerId: EnginePeer.Id, messages: [EnqueueMessage],
         described: [AyuPluginHookedOutgoingMessage?], finish: @escaping ([EnqueueMessage]?) -> Void) {
        self.bridge = bridge
        self.accountIndex = accountIndex
        self.peerId = peerId
        self.messages = messages
        self.described = described
        self.finish = finish
    }

    func step(_ index: Int) {
        self.lock.lock()
        let count = self.messages.count
        let original: EnqueueMessage? = index < count ? self.messages[index] : nil
        self.lock.unlock()
        guard let original else {
            self.lock.lock(); let result = self.messages; self.lock.unlock()
            self.finish(result)
            return
        }
        guard index < self.described.count, let described = self.described[index] else {
            self.step(index + 1)
            return
        }
        let peerId = self.peerId
        self.bridge.interceptSendMessage(account: self.accountIndex, message: AyuPluginSendHookValues.hooked(described)) { decision in
            switch decision {
            case .cancel:
                self.finish(nil)
            case let .send(hooked, remapEntities):
                let result = AyuPluginSendHookValues.result(hooked, described: described)
                // A result that cannot be applied changes nothing.
                let updated = ayuPluginApplySendHook(peerId: peerId, original: original, described: described, result: result, remapEntities: remapEntities) ?? original
                self.lock.lock(); self.messages[index] = updated; self.lock.unlock()
                self.step(index + 1)
            }
        }
    }
}

/// The two shapes of an outgoing message: TelegramCore's description and the bridge's hook value.
enum AyuPluginSendHookValues {
    static func hooked(_ described: AyuPluginHookedOutgoingMessage) -> AyuPluginTelegramHookedMessage {
        var message = AyuPluginTelegramHookedMessage(peer: described.dialogId)
        // An attachment always has a caption, possibly empty, so that a hook can write one.
        if described.isMedia { message.caption = described.text } else { message.message = described.text }
        message.entities = described.entities.isEmpty ? nil : described.entities
        message.replyTo = described.replyTo.map { AyuPluginTelegramMessageReference(dialogID: $0.dialogId, messageID: $0.messageId, message: $0.message) }
        message.replyToTop = described.replyToTop.map { AyuPluginTelegramMessageReference(dialogID: $0.dialogId, messageID: $0.messageId, message: $0.message) }
        message.path = described.path
        message.document = described.document
        message.photo = described.photo
        message.notify = !described.silent
        message.scheduleDate = described.scheduleTime
        message.scheduleRepeatPeriod = described.scheduleRepeatPeriod
        message.searchLinks = !described.disablesLinkPreview
        message.invertMedia = described.invertsMedia
        message.effectID = described.effectId
        message.hasMediaSpoilers = described.hasSpoiler
        return message
    }

    /// What the hooks left of `described`. The bridge knows a reply only when the app could
    /// describe it, so an untouched reply target keeps the app's own id.
    static func result(_ hooked: AyuPluginTelegramHookedMessage, described: AyuPluginHookedOutgoingMessage) -> AyuPluginHookedOutgoingMessage {
        var result = described
        result.text = (described.isMedia ? hooked.caption : hooked.message) ?? described.text
        result.entities = hooked.entities ?? []
        if hooked.replyToMessageID != described.replyTo?.messageId {
            result.replyToMessageId = hooked.replyToMessageID
        }
        result.silent = !hooked.notify
        result.scheduleTime = hooked.scheduleDate
        result.scheduleRepeatPeriod = hooked.scheduleRepeatPeriod
        result.disablesLinkPreview = !hooked.searchLinks
        result.invertsMedia = hooked.invertMedia
        result.effectId = hooked.effectID
        result.hasSpoiler = hooked.hasMediaSpoilers
        return result
    }
}

/// Carries a value TelegramCore does not mark `Sendable` (an `Account`, a completion of its
/// plugin surface) into a `@Sendable` closure. Each use hands the value to one queue.
final class AyuPluginUncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A request's disposable as the bridge's cancellation: disposing is thread-safe and idempotent.
final class AyuPluginDisposableBox: @unchecked Sendable {
    private let disposable: Disposable
    init(_ disposable: Disposable) { self.disposable = disposable }
    func dispose() { self.disposable.dispose() }
}
