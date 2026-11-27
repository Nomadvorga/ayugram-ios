import Foundation
import UIKit

/// The five Android menu types of `menus.add` (`Python/protocol-telegram.md`).
public enum AyuPluginMenuKind: String, Sendable, CaseIterable {
    case messageContextMenu = "message_context_menu"
    case chatActionMenu = "chat_action_menu"
    case profileActionMenu = "profile_action_menu"
    case drawerMenu = "drawer_menu"
    case mainMenu = "main_menu"

    /// Kinds whose items one native menu shows. iOS has no drawer: like Android's
    /// main menu, the host's plugin menu lists the drawer items too.
    var shown: [AyuPluginMenuKind] {
        switch self {
        case .drawerMenu, .mainMenu: return [.mainMenu, .drawerMenu]
        default: return [self]
        }
    }

    var needsDialog: Bool {
        switch self {
        case .messageContextMenu, .chatActionMenu, .profileActionMenu: return true
        case .drawerMenu, .mainMenu: return false
        }
    }
}

/// What app code knows where it opens a menu: its own account key (nil for the
/// app's primary account) and the raw peer and message ids. The app binding
/// turns it into a location; modules that build menus need no other bridge or
/// account knowledge.
public struct AyuPluginMenuRequest: Sendable, Equatable {
    public struct Peer: Sendable, Equatable {
        public let namespace: Int32
        public let id: Int64
        public init(namespace: Int32, id: Int64) { self.namespace = namespace; self.id = id }
    }
    public let kind: AyuPluginMenuKind
    public let accountKey: Int64?
    public let peer: Peer?
    public let messageID: Int32?
    public init(kind: AyuPluginMenuKind, accountKey: Int64?, peer: Peer? = nil, messageID: Int32? = nil) {
        self.kind = kind; self.accountKey = accountKey; self.peer = peer; self.messageID = messageID
    }
}

/// A request pinned to a bridge account slot and to the screen that was visible
/// when the menu opened. Both identities are revalidated before a click is delivered.
public struct AyuPluginMenuLocation: Sendable, Equatable {
    public let kind: AyuPluginMenuKind
    public let screenIdentity: UUID
    public let accountIdentity: UUID
    public let accountIndex: Int64
    /// Android dialog id; present exactly for the message, chat and profile menus.
    public let dialogID: Int64?
    /// Present exactly for the message context menu.
    public let messageID: Int32?

    /// Nil unless the ids fit the kind and, for the two chat menus, the visible
    /// screen is that dialog's chat.
    public init?(kind: AyuPluginMenuKind, screen: AyuPluginScreenSnapshot, accountIdentity: UUID, dialogID: Int64?, messageID: Int32?) {
        guard screen.accountIndex >= 0 else { return nil }
        if kind.needsDialog {
            guard let dialogID, dialogID != 0, dialogID != Int64.min else { return nil }
            if kind != .profileActionMenu, screen.dialogID != dialogID { return nil }
        } else if dialogID != nil { return nil }
        if kind == .messageContextMenu {
            guard let messageID, messageID > 0 else { return nil }
        } else if messageID != nil { return nil }
        self.kind = kind; self.screenIdentity = screen.identity; self.accountIdentity = accountIdentity
        self.accountIndex = screen.accountIndex; self.dialogID = dialogID; self.messageID = messageID
    }

    /// Whether the same account still shows the same screen.
    public func isCurrent(screen: AyuPluginScreenSnapshot?, accountIdentity: UUID?) -> Bool {
        guard let screen, let accountIdentity, accountIdentity == self.accountIdentity,
              screen.identity == self.screenIdentity, screen.accountIndex == self.accountIndex else { return false }
        return self.kind == .profileActionMenu || !self.kind.needsDialog || screen.dialogID == self.dialogID
    }
}

/// One plugin row of an opened native menu.
public struct AyuPluginMenuEntry: Sendable {
    /// Stable within the menu: `<plugin id>:<item id>`.
    public let identifier: String
    public let text: String
    public let subtext: String?
    public let icon: AyuPluginIcon?
    public let hasLongClick: Bool
    let token: String
    /// The `context` its callbacks receive; nil for a `menus.register` row.
    let arguments: [AyuBridgeValue]?
}

/// The plugin rows of one opened native menu and the only way to activate them.
/// Immutable, so a menu row's action may use it from any closure.
public final class AyuPluginMenuSession: @unchecked Sendable {
    public let entries: [AyuPluginMenuEntry]
    private let bridge: AyuPluginMenuBridge
    private let isScreenCurrent: @MainActor () -> Bool
    private let legacyContext: AyuPluginMenuContext?

    init(bridge: AyuPluginMenuBridge, entries: [AyuPluginMenuEntry], legacyContext: AyuPluginMenuContext?, isScreenCurrent: @escaping @MainActor () -> Bool) {
        self.bridge = bridge; self.entries = entries; self.legacyContext = legacyContext; self.isScreenCurrent = isScreenCurrent
    }

    /// Call after the native menu was told to close. Delivers `on_click`, or
    /// `on_long_click` for a row that has one; nothing is delivered when the
    /// screen or account changed or the item was removed meanwhile.
    public func activate(_ entry: AyuPluginMenuEntry, longClick: Bool = false) {
        guard !longClick || entry.hasLongClick else { return }
        let bridge = self.bridge, isCurrent = self.isScreenCurrent, legacyContext = self.legacyContext
        Task { @MainActor in
            if entry.arguments != nil {
                await bridge.deliver(entry, longClick: longClick, isCurrent: isCurrent)
            } else if let legacyContext {
                await bridge.perform(token: entry.token, context: legacyContext, isCurrent: isCurrent)
            }
        }
    }
}

/// `menus.add` state: registrations by generation, and the Telegram reads that
/// fill a menu `context`. Registration runs on the host worker; queries and
/// clicks start on main and never make it wait.
final class AyuPluginTypedMenus: @unchecked Sendable {
    static let operation = "menus.add"

    struct Limits: Sendable {
        var itemsPerGeneration = 64
        var textBytes = 256
        var itemIDBytes = 128
        var iconBytes = 128
        /// Plugin rows one native menu shows, in priority order.
        var entriesPerMenu = 64
        var conditionTimeout: TimeInterval = 2
        var readTimeout: TimeInterval = 2
        /// JSON size of one callback's arguments.
        var contextPayloadBytes = 1_048_576
        var outboundTLBytes = 4_194_304
    }

    /// The cache reads a `context` needs. They are `peer` and `messages` of
    /// `AyuPluginTelegramBackend`, which answer on any thread and are never called on main.
    struct TLSource: Sendable {
        let account: @Sendable (Int64) -> AyuPluginTelegramAccount?
        let peer: @Sendable (AyuPluginTelegramAccount, AyuPluginTelegramPeerKind, Int64,
                             @escaping @Sendable (Result<Data?, AyuPluginTelegramBackendError>) -> Void) -> Void
        let messages: @Sendable (AyuPluginTelegramAccount, Int64, [Int32],
                                 @escaping @Sendable (Result<[Data?], AyuPluginTelegramBackendError>) -> Void) -> Void
    }

    struct Entry: Sendable {
        let owner: String
        let token: String
        let kind: AyuPluginMenuKind
        let itemID: String
        let text: String
        let subtext: String?
        let icon: AyuPluginIcon?
        let priority: Int32
        let click: AyuBridgeNativeCallback
        let longClick: AyuBridgeNativeCallback?
        let condition: AyuBridgeNativeCallback?
        var order: UInt64 = 0
        var committed = false
        func release() { self.click.release(); self.longClick?.release(); self.condition?.release() }
    }

    struct LocationBinding {
        let resolve: @MainActor (AyuPluginMenuRequest) -> AyuPluginMenuLocation?
        let isCurrent: @MainActor (AyuPluginMenuLocation, AyuPluginMenuRequest) -> Bool
    }

    let limits: Limits
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "AyuPluginBridge.menus")
    private var entries: [String: Entry] = [:]
    private var nextOrder: UInt64 = 0
    private var source: (@Sendable () -> TLSource?)?
    @MainActor var pendingQueries = 0
    @MainActor var locations: LocationBinding?

    init(limits: Limits = Limits()) { self.limits = limits }

    func setTLSource(_ source: (@Sendable () -> TLSource?)?) {
        self.lock.lock(); self.source = source; self.lock.unlock()
    }

    func tlSource() -> TLSource? {
        self.lock.lock(); let source = self.source; self.lock.unlock()
        return source?()
    }

    /// `menus.add` is declared only while both reads are served.
    var isAvailable: Bool { self.tlSource() != nil }

    // MARK: Registration (host worker)

    private static func invalid(_ message: String) -> AyuBridgeFailure { AyuBridgeFailure("invalid_arguments", message) }

    private static func text(_ value: AyuBridgeValue?, _ what: String, maxBytes: Int) throws -> String {
        guard let text = value?.string, !text.isEmpty, text.utf8.count <= maxBytes else {
            throw Self.invalid(what + " must be a nonempty string of at most \(maxBytes) UTF-8 bytes")
        }
        return text
    }

    private static func isCallback(_ value: AyuBridgeValue?) -> Bool {
        guard let object = value?.object, object.count == 1, object["$callback"]?.string != nil else { return false }
        return true
    }

    func prepareAdd(pluginID: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        guard self.isAvailable else { throw AyuBridgeFailure.unsupported(Self.operation) }
        let required: Set<String> = ["type", "item_id", "text", "priority", "on_click"]
        let optional: Set<String> = ["icon", "subtext", "on_long_click", "condition"]
        let keys = Set(arguments.keys)
        if let unknown = keys.subtracting(required).subtracting(optional).sorted().first {
            throw Self.invalid("Unknown argument " + String(unknown.prefix(64)))
        }
        if let missing = required.subtracting(keys).sorted().first { throw Self.invalid("Missing argument " + missing) }
        guard let kind = arguments["type"]?.string.flatMap(AyuPluginMenuKind.init(rawValue:)) else { throw Self.invalid("Unknown menu type") }
        let itemID = try Self.text(arguments["item_id"], "item_id", maxBytes: self.limits.itemIDBytes)
        let text = try Self.text(arguments["text"], "text", maxBytes: self.limits.textBytes)
        let subtext = try arguments["subtext"].map { try Self.text($0, "subtext", maxBytes: self.limits.textBytes) }
        guard let priority = arguments["priority"]?.integer.flatMap(Int32.init(exactly:)) else { throw Self.invalid("priority must be a 32-bit integer") }
        // An Android drawable name without an iOS counterpart shows no icon, as
        // Android shows none for a name its resources lack.
        let icon = try arguments["icon"].map { try Self.text($0, "icon", maxBytes: self.limits.iconBytes) }.flatMap(AyuPluginResources.icon(drawable:))
        if arguments["condition"]?.string != nil { throw AyuBridgeFailure.unsupported("Android MVEL menu conditions") }
        for key in ["on_click", "on_long_click", "condition"] where arguments[key] != nil {
            guard Self.isCallback(arguments[key]) else { throw Self.invalid(key + " must be a callback reference") }
        }
        try self.checkCapacity(owner: pluginID, itemID: itemID)
        // Callbacks are resolved only after every plain field was validated; a
        // refusal below hands the resolved ids back.
        var resolved: [AyuBridgeNativeCallback] = []
        func callback(_ key: String) throws -> AyuBridgeNativeCallback? {
            guard let reference = arguments[key] else { return nil }
            let callback = try context.callback(reference)
            resolved.append(callback)
            return callback
        }
        let entry: Entry
        do {
            guard let click = try callback("on_click") else { throw Self.invalid("Missing argument on_click") }
            entry = Entry(owner: pluginID, token: UUID().uuidString, kind: kind, itemID: itemID, text: text, subtext: subtext, icon: icon,
                          priority: priority, click: click, longClick: try callback("on_long_click"), condition: try callback("condition"))
            self.lock.lock()
            do { try self.checkCapacityLocked(owner: pluginID, itemID: itemID) } catch { self.lock.unlock(); throw error }
            self.entries[entry.token] = entry
            self.lock.unlock()
        } catch {
            for callback in resolved { callback.release() }
            throw error
        }
        let token = entry.token
        return AyuBridgeProviderResult(.value(.string(token)), rollback: { self.remove(token, owner: pluginID) }, commit: { _ in
            self.lock.lock(); defer { self.lock.unlock() }
            // Unregistering or detaching removed the reservation; a late commit restores nothing.
            guard self.entries[token] != nil else { return }
            self.nextOrder &+= 1
            self.entries[token]?.order = self.nextOrder
            self.entries[token]?.committed = true
        })
    }

    private func checkCapacity(owner: String, itemID: String) throws {
        self.lock.lock(); defer { self.lock.unlock() }
        try self.checkCapacityLocked(owner: owner, itemID: itemID)
    }

    private func checkCapacityLocked(owner: String, itemID: String) throws {
        let owned = self.entries.values.filter { $0.owner == owner }
        guard !owned.contains(where: { $0.itemID == itemID }) else { throw Self.invalid("item_id is already registered") }
        guard owned.count < self.limits.itemsPerGeneration else { throw AyuBridgeFailure("resource_limit", "Menu item quota exceeded") }
    }

    func owner(of token: String) -> String? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.entries[token]?.owner
    }

    func remove(_ token: String, owner: String) {
        self.lock.lock()
        let removed = self.entries[token]?.owner == owner ? self.entries.removeValue(forKey: token) : nil
        self.lock.unlock()
        removed?.release()
    }

    /// The host forgets a detached generation's callbacks itself.
    func detach(pluginID: String) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.entries = self.entries.filter { $0.value.owner != pluginID }
    }

    /// Committed items a menu of `kind` shows: descending priority, then registration order.
    func entries(shownIn kind: AyuPluginMenuKind) -> [Entry] {
        let kinds = kind.shown
        self.lock.lock(); defer { self.lock.unlock() }
        return self.entries.values.filter { $0.committed && kinds.contains($0.kind) }
            .sorted { $0.priority == $1.priority ? $0.order < $1.order : $0.priority > $1.priority }
    }

    func entry(_ token: String) -> Entry? {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let entry = self.entries[token], entry.committed else { return nil }
        return entry
    }

    // MARK: Context

    private final class Once<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?
        init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }
        func resume(_ value: Value?) {
            self.lock.lock(); let continuation = self.continuation; self.continuation = nil; self.lock.unlock()
            continuation?.resume(returning: value)
        }
    }

    /// Starts a read off main and resumes once: with its answer, or with nil when
    /// it fails or does not answer within the bound. A late answer is ignored.
    private func read<Value: Sendable>(_ start: @escaping @Sendable (@escaping @Sendable (Result<Value, AyuPluginTelegramBackendError>) -> Void) -> Void) async -> Value? {
        let queue = self.queue, timeout = self.limits.readTimeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let once = Once(continuation)
            queue.async {
                start { result in
                    if case let .success(value) = result { once.resume(value) } else { once.resume(nil) }
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    private func tl(_ data: Data?) -> AyuBridgeValue? {
        guard let data, AyuPluginTelegramTL.isBoxed(data), data.count <= self.limits.outboundTLBytes else { return nil }
        return AyuPluginTelegramTL.encode(data)
    }

    private func fits(_ context: [String: AyuBridgeValue]) -> Bool {
        guard let data = try? JSONEncoder().encode([AyuBridgeValue.object(context)]) else { return false }
        return data.count <= self.limits.contextPayloadBytes
    }

    /// The contract's `context` of a location, or nil when a value its menu type
    /// promises (the dialog's `user` or `chat`, the pressed `message`) cannot be
    /// rebuilt: the menu then shows no plugin rows rather than a partial context.
    func context(for location: AyuPluginMenuLocation, source: TLSource) async -> AyuBridgeValue? {
        guard let account = source.account(location.accountIndex), account.identity == location.accountIdentity else { return nil }
        var context: [String: AyuBridgeValue] = ["account": .integer(location.accountIndex)]
        guard location.kind.needsDialog else { return .object(context) }
        guard let dialogID = location.dialogID else { return nil }
        context["dialog_id"] = .integer(dialogID)
        let isUser = dialogID > 0
        let peerID = isUser ? dialogID : -dialogID
        async let peerRead: Data?? = self.read { source.peer(account, isUser ? .user : .chat, peerID, $0) }
        if location.kind == .messageContextMenu {
            guard let messageID = location.messageID else { return nil }
            async let messageRead: [Data?]? = self.read { source.messages(account, dialogID, [messageID], $0) }
            guard let peer = self.tl((await peerRead) ?? nil), let stored = await messageRead, stored.count == 1,
                  let message = self.tl(stored[0]) else { return nil }
            context[isUser ? "user" : "chat"] = peer
            context["message"] = message
            return self.fits(context) ? .object(context) : nil
        }
        async let fullRead: Data?? = self.read { source.peer(account, isUser ? .userFull : .chatFull, peerID, $0) }
        let full = self.tl((await fullRead) ?? nil)
        guard let peer = self.tl((await peerRead) ?? nil) else { return nil }
        context[isUser ? "user" : "chat"] = peer
        guard self.fits(context) else { return nil }
        if let full {
            // The full object is sent "when cached"; one too large for a callback is left out.
            var extended = context
            extended[isUser ? "user_full" : "chat_full"] = full
            if self.fits(extended) { context = extended }
        }
        return .object(context)
    }
}

/// Collects condition answers on main until every one arrived or the bound passed.
@MainActor private final class AyuPluginMenuConditionGate {
    private var allowed: Set<String> = []
    private var remaining: Int
    private var finished = false
    private var continuation: CheckedContinuation<Set<String>, Never>?

    init(count: Int) { self.remaining = count }

    func answer(_ token: String, _ shown: Bool) {
        guard !self.finished else { return }
        if shown { self.allowed.insert(token) }
        self.remaining -= 1
        if self.remaining <= 0 { self.finish() }
    }

    func finish() {
        guard !self.finished else { return }
        self.finished = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: self.allowed)
    }

    func wait() async -> Set<String> {
        if self.finished { return self.allowed }
        return await withCheckedContinuation { self.continuation = $0 }
    }
}

public extension AyuPluginMenuBridge {
    /// Installed by the app binding, on main. `resolve` pins a request to the
    /// bridge account slot and the visible screen (nil when the app is locked or
    /// inactive, or the peer has no Android dialog id); `isCurrent` revalidates it.
    @MainActor func bindLocations(resolve: @escaping @MainActor (AyuPluginMenuRequest) -> AyuPluginMenuLocation?,
                                  isCurrent: @escaping @MainActor (AyuPluginMenuLocation, AyuPluginMenuRequest) -> Bool) {
        self.typed.locations = AyuPluginTypedMenus.LocationBinding(resolve: resolve, isCurrent: isCurrent)
    }

    @MainActor func unbindLocations() { self.typed.locations = nil }

    /// The plugin rows for a native menu the app is showing. Call it after the
    /// native rows are on screen: it waits for Telegram's cache and for Python
    /// conditions (each hidden after 2 seconds), never blocking main.
    /// `isPresented` says whether that same menu is still up.
    @MainActor func open(_ request: AyuPluginMenuRequest, isPresented: @escaping @MainActor () -> Bool) async -> AyuPluginMenuSession {
        guard let binding = self.typed.locations, let location = binding.resolve(request) else {
            return AyuPluginMenuSession(bridge: self, entries: [], legacyContext: nil, isScreenCurrent: { false })
        }
        let isScreenCurrent: @MainActor () -> Bool = { binding.isCurrent(location, request) }
        let isMenuCurrent: @MainActor () -> Bool = { isPresented() && binding.isCurrent(location, request) }
        var entries = await self.typedEntries(location, isCurrent: isMenuCurrent)
        var legacyContext: AyuPluginMenuContext?
        if location.kind == .messageContextMenu, let dialogID = location.dialogID, let messageID = location.messageID {
            let context = AyuPluginMenuContext(screenIdentity: location.screenIdentity, accountIdentity: location.accountIdentity,
                accountIndex: location.accountIndex, dialogID: dialogID, messageID: Int64(messageID))
            legacyContext = context
            entries += await self.items(context: context, isCurrent: isMenuCurrent).map { item in
                AyuPluginMenuEntry(identifier: item.itemID ?? item.token, text: item.text, subtext: nil,
                    icon: item.symbolName.map(AyuPluginIcon.symbol), hasLongClick: false, token: item.token, arguments: nil)
            }
        }
        guard !Task.isCancelled, isMenuCurrent() else {
            return AyuPluginMenuSession(bridge: self, entries: [], legacyContext: nil, isScreenCurrent: { false })
        }
        return AyuPluginMenuSession(bridge: self, entries: Array(entries.prefix(self.typed.limits.entriesPerMenu)),
                                    legacyContext: legacyContext, isScreenCurrent: isScreenCurrent)
    }

    @MainActor internal func typedEntries(_ location: AyuPluginMenuLocation, isCurrent: @escaping @MainActor () -> Bool) async -> [AyuPluginMenuEntry] {
        let typed = self.typed
        guard isCurrent(), let invoke = self.invokeCallback, typed.pendingQueries < 4 else { return [] }
        let candidates = Array(typed.entries(shownIn: location.kind).prefix(typed.limits.entriesPerMenu))
        guard !candidates.isEmpty, let source = typed.tlSource() else { return [] }
        typed.pendingQueries += 1
        defer { typed.pendingQueries -= 1 }
        guard let context = await typed.context(for: location, source: source), !Task.isCancelled, isCurrent() else { return [] }
        let arguments = [context]
        var allowed: Set<String> = []
        let conditional = candidates.filter { $0.condition != nil }
        if !conditional.isEmpty {
            // Every condition is queued at once, so each has the same bound and
            // the menu waits for Python at most that long in total.
            let gate = AyuPluginMenuConditionGate(count: conditional.count)
            for entry in conditional {
                guard let condition = entry.condition else { continue }
                Task { @MainActor in
                    let value = await invoke(entry.owner, condition.id, arguments)
                    gate.answer(entry.token, value == .bool(true))
                }
            }
            let timeout = UInt64(typed.limits.conditionTimeout * 1_000_000_000)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeout)
                gate.finish()
            }
            allowed = await gate.wait()
            guard !Task.isCancelled, isCurrent() else { return [] }
        }
        return candidates.compactMap { entry in
            // Removed while Python was answering.
            guard typed.entry(entry.token) != nil, entry.condition == nil || allowed.contains(entry.token) else { return nil }
            return AyuPluginMenuEntry(identifier: entry.owner + ":" + entry.itemID, text: entry.text, subtext: entry.subtext, icon: entry.icon,
                                      hasLongClick: entry.longClick != nil, token: entry.token, arguments: arguments)
        }
    }

    /// Delivers a click with the context the menu was opened with. The service's
    /// relay checks the Python generation; a removed item delivers nothing.
    @MainActor internal func deliver(_ entry: AyuPluginMenuEntry, longClick: Bool, isCurrent: @MainActor () -> Bool) async {
        guard let arguments = entry.arguments, isCurrent(), let invoke = self.invokeCallback,
              let registered = self.typed.entry(entry.token),
              let callback = longClick ? registered.longClick : registered.click else { return }
        _ = await invoke(registered.owner, callback.id, arguments)
    }
}

extension AyuPluginTelegramBridge {
    /// The two cache reads `menus.add` needs, or nil unless the bound backend
    /// lists both `telegram.peer` and `telegram.messages`.
    func menuContextSource() -> AyuPluginTypedMenus.TLSource? {
        guard let backend = self.currentBackend(), let environment = self.currentEnvironment(),
              backend.operations.isSuperset(of: [Operation.peer, Operation.messages]) else { return nil }
        return AyuPluginTypedMenus.TLSource(account: environment.account,
            peer: { account, kind, id, completion in backend.peer(account: account, kind: kind, id: id, completion: completion) },
            messages: { account, dialogID, ids, completion in backend.messages(account: account, dialogID: dialogID, ids: ids, completion: completion) })
    }
}
