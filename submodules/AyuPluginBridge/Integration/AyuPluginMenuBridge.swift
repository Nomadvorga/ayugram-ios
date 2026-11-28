import Foundation
import UIKit

/// A deliberately narrow native menu surface. Android MVEL conditions, message
/// objects, custom subtitles and long presses need separate, explicit adapters.
public struct AyuPluginMenuContext: Equatable, Sendable {
    public let screenIdentity: UUID
    public let accountIdentity: UUID
    public let accountIndex: Int64
    public let dialogID: Int64
    public let messageID: Int64

    public init(screenIdentity: UUID, accountIdentity: UUID, accountIndex: Int64, dialogID: Int64, messageID: Int64) {
        self.screenIdentity = screenIdentity; self.accountIdentity = accountIdentity; self.accountIndex = accountIndex
        self.dialogID = dialogID; self.messageID = messageID
    }

    // Only actual available values cross the boundary. In particular, do not
    // manufacture a Java MessageObject or BaseFragment reference here.
    public var arguments: [AyuBridgeValue] {
        [.object(["account": .integer(self.accountIndex), "dialog_id": .integer(self.dialogID), "message_id": .integer(self.messageID)])]
    }
}

public struct AyuPluginMenuItem: Sendable {
    public let token: String
    public let itemID: String?
    public let text: String
    public let symbolName: String?
}

/// Provider reservations run on the native host worker. Menu queries/actions run
/// on main and await the service's authenticated, generation-checked Python relay.
public final class AyuPluginMenuBridge: AyuPluginHostProvider, @unchecked Sendable {
    public static let shared = AyuPluginMenuBridge()
    /// Served without Telegram. `menus.add` joins them only while a bound
    /// Telegram backend can fill its `context`, so it is not part of this literal.
    private let operations = ["menus.register", "menus.unregister", "resources.resolve"]
    public var capabilities: [String] { self.typed.isAvailable ? self.operations + [AyuPluginTypedMenus.operation] : self.operations }
    let typed: AyuPluginTypedMenus
    public typealias CallbackInvoker = @MainActor (String, String, [AyuBridgeValue]) async -> AyuBridgeValue?
    @MainActor public var invokeCallback: CallbackInvoker?
    private let lock = NSLock()
    private struct Entry: Sendable {
        let owner: String
        let token: String
        let itemID: String?
        let text: String
        let symbol: String?
        let priority: Int64
        let click: String
        let condition: String?
        var order: UInt64 = 0
    }
    private var pending: [String: Entry] = [:]
    private var registered: [String: Entry] = [:]
    private var nextOrder: UInt64 = 0
    @MainActor private var pendingEvaluations = 0

    public init() { self.typed = AyuPluginTypedMenus() }

    init(typed: AyuPluginTypedMenus) { self.typed = typed }

    public func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
        throw AyuBridgeFailure.unsupported(operation)
    }

    public func prepareCall(pluginID: String, operation: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        guard !Thread.isMainThread, context.pluginID == pluginID else {
            throw AyuBridgeFailure("wrong_thread", "Menu registration is worker-only")
        }
        if operation == "menus.unregister" {
            guard Set(arguments.keys) == ["token"], let token = arguments["token"]?.string,
                  UUID(uuidString: token) != nil else { throw Self.invalid() }
            self.lock.lock()
            let owner = self.registered[token]?.owner ?? self.pending[token]?.owner
            self.lock.unlock()
            guard (owner ?? self.typed.owner(of: token)) ?? pluginID == pluginID else { throw AyuBridgeFailure("invalid_handle", "Menu token belongs to another plugin") }
            return AyuBridgeProviderResult(.value(.null), commit: { _ in self.remove(token, owner: pluginID); self.typed.remove(token, owner: pluginID) })
        }
        if operation == AyuPluginTypedMenus.operation { return try self.typed.prepareAdd(pluginID: pluginID, arguments: arguments, context: context) }
        if operation == AyuPluginResources.operation { return AyuBridgeProviderResult(.value(try AyuPluginResources.resolve(arguments))) }
        guard operation == "menus.register" else { throw AyuBridgeFailure.unsupported(operation) }
        guard arguments["type"] == nil || arguments["menu_type"] == nil else { throw Self.invalid() }
        guard let menuType = (arguments["type"] ?? arguments["menu_type"])?.string else { throw Self.invalid() }
        guard menuType.uppercased() == "MESSAGE_CONTEXT_MENU" else {
            throw AyuBridgeFailure.unsupported("menu type; only MESSAGE_CONTEXT_MENU is implemented")
        }
        guard let text = arguments["text"]?.string,
              let priority = arguments["priority"]?.integer, priority >= Int64(Int32.min), priority <= Int64(Int32.max),
              let clickReference = arguments["on_click"] else {
            throw Self.invalid()
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 512 else { throw Self.invalid() }
        guard Set(arguments.keys).isSubset(of: ["type", "menu_type", "text", "priority", "on_click", "condition", "icon", "item_id"]) else {
            throw AyuBridgeFailure.unsupported("menu field")
        }
        let conditionReference: AyuBridgeValue?
        if let reference = arguments["condition"], reference != .null {
            guard reference.string == nil else { throw AyuBridgeFailure.unsupported("Android MVEL menu conditions") }
            guard reference.object?["$callback"]?.string != nil else { throw Self.invalid() }
            conditionReference = reference
        } else { conditionReference = nil }
        let itemID: String?
        if let value = arguments["item_id"], value != .null {
            guard let supplied = value.string, !supplied.isEmpty, supplied.utf8.count <= 128 else { throw Self.invalid() }
            itemID = supplied
        } else { itemID = nil }
        var symbol: String?
        if let icon = arguments["icon"], icon != .null {
            guard let name = icon.string else { throw Self.invalid() }
            guard let mapped = Self.icons[name] else { throw AyuBridgeFailure.unsupported("menu icon") }
            symbol = mapped
        }
        self.lock.lock()
        let ownerCountBeforeCallbacks = self.registered.values.filter { $0.owner == pluginID }.count + self.pending.values.filter { $0.owner == pluginID }.count
        let duplicateItemIDBeforeCallbacks = itemID.map { supplied in
            Array(self.registered.values).contains { $0.owner == pluginID && $0.itemID == supplied }
                || Array(self.pending.values).contains { $0.owner == pluginID && $0.itemID == supplied }
        } ?? false
        let hasCapacity = ownerCountBeforeCallbacks < 16 && self.pending.count + self.registered.count < 256
        self.lock.unlock()
        guard hasCapacity, !duplicateItemIDBeforeCallbacks else {
            throw AyuBridgeFailure("resource_limit", "Menu registration quota exceeded")
        }
        // Resolve callbacks only after every ordinary field has been validated;
        // contexts and wire references never escape this host call. The service
        // authenticates their generation again at use.
        let click = try context.callback(clickReference).id
        let resolvedCondition: String?
        if let reference = conditionReference {
            resolvedCondition = try context.callback(reference).id
        } else { resolvedCondition = nil }
        let token = UUID().uuidString
        let entry = Entry(owner: pluginID, token: token, itemID: itemID, text: text, symbol: symbol, priority: priority, click: click, condition: resolvedCondition)
        self.lock.lock()
        let ownerCount = self.registered.values.filter { $0.owner == pluginID }.count + self.pending.values.filter { $0.owner == pluginID }.count
        let duplicateItemID = itemID.map { supplied in
            Array(self.registered.values).contains { $0.owner == pluginID && $0.itemID == supplied }
                || Array(self.pending.values).contains { $0.owner == pluginID && $0.itemID == supplied }
        } ?? false
        guard ownerCount < 16, self.pending.count + self.registered.count < 256, !duplicateItemID else {
            self.lock.unlock(); throw AyuBridgeFailure("resource_limit", "Menu registration quota exceeded")
        }
        self.pending[token] = entry
        self.lock.unlock()
        return AyuBridgeProviderResult(.value(.string(token)), rollback: { self.remove(token, owner: pluginID) }, commit: { _ in
            self.lock.lock(); defer { self.lock.unlock() }
            // detach/unregister removes the reservation, so a delayed commit can
            // never restore a revoked generation or consume a newer reservation.
            guard var reserved = self.pending.removeValue(forKey: token) else { return }
            self.nextOrder &+= 1; reserved.order = self.nextOrder
            self.registered[token] = reserved
        })
    }

    public func detach(pluginID: String) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.pending = self.pending.filter { $0.value.owner != pluginID }
        self.registered = self.registered.filter { $0.value.owner != pluginID }
        self.typed.detach(pluginID: pluginID)
    }

    private func remove(_ token: String, owner: String) {
        self.lock.lock(); defer { self.lock.unlock() }
        if self.pending[token]?.owner == owner { self.pending.removeValue(forKey: token) }
        if self.registered[token]?.owner == owner { self.registered.removeValue(forKey: token) }
    }

    private func entries() -> [Entry] {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.registered.values.sorted { $0.priority == $1.priority ? $0.order < $1.order : $0.priority > $1.priority }
    }

    private func entry(_ token: String) -> Entry? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.registered[token]
    }

    @MainActor public func items(context: AyuPluginMenuContext, isCurrent: @escaping @MainActor () -> Bool) async -> [AyuPluginMenuItem] {
        guard context.accountIndex >= 0, context.dialogID != 0, context.dialogID != Int64.min,
              context.messageID > 0, isCurrent(), let invoke = self.invokeCallback,
              self.pendingEvaluations < 4 else { return [] }
        self.pendingEvaluations += 1
        defer { self.pendingEvaluations -= 1 }
        var result: [AyuPluginMenuItem] = []
        // Bound Python work and rendered rows, including registrations whose
        // condition returns false. Never enqueue a task for every plugin entry.
        for entry in self.entries().prefix(32) {
            guard !Task.isCancelled, isCurrent() else { return [] }
            guard self.entry(entry.token) != nil else { continue }
            if let condition = entry.condition {
                let value = await invoke(entry.owner, condition, context.arguments)
                guard !Task.isCancelled, isCurrent() else { return [] }
                guard self.entry(entry.token) != nil, value == .bool(true) else { continue }
            }
            result.append(AyuPluginMenuItem(token: entry.token, itemID: entry.itemID.map { entry.owner + ":" + $0 }, text: entry.text, symbolName: entry.symbol))
            if result.count == 16 { break }
        }
        return result
    }

    /// Rechecks native registration, current account/screen/message and Python
    /// generation after each await. A revoked item cannot invoke a new load.
    @MainActor public func perform(token: String, context: AyuPluginMenuContext, isCurrent: @escaping @MainActor () -> Bool) async {
        guard !Task.isCancelled, isCurrent(), let invoke = self.invokeCallback,
              let entry = self.entry(token), self.pendingEvaluations < 4 else { return }
        self.pendingEvaluations += 1
        defer { self.pendingEvaluations -= 1 }
        if let condition = entry.condition {
            let value = await invoke(entry.owner, condition, context.arguments)
            guard value == .bool(true) else { return }
        }
        guard !Task.isCancelled, isCurrent(), self.entry(token) != nil else { return }
        _ = await invoke(entry.owner, entry.click, context.arguments)
    }

    private static let icons = [
        "msg_archive": "archivebox", "msg_audio": "waveform", "msg_block": "hand.raised",
        "msg_bot": "cpu", "msg_calendar": "calendar", "msg_calendar2": "calendar",
        "msg_channel": "megaphone", "msg_copy": "doc.on.doc", "msg_delete": "trash",
        "msg_download": "arrow.down.to.line", "msg_edit": "pencil", "msg_file": "doc",
        "msg_forward": "arrowshape.turn.up.right", "msg_gallery": "photo.on.rectangle",
        "msg_gif": "livephoto", "msg_info": "info.circle", "msg_link": "link",
        "msg_list": "list.bullet", "msg_media": "photo.on.rectangle.angled", "msg_palette": "paintpalette",
        "msg_photo": "photo", "msg_quote": "quote.bubble", "msg_reactions": "face.smiling",
        "msg_reply": "arrowshape.turn.up.left", "msg_retry": "arrow.clockwise",
        "msg_save": "square.and.arrow.down", "msg_scheduled": "clock",
        "msg_search": "magnifyingglass", "msg_settings": "gearshape",
        "msg_share": "square.and.arrow.up", "msg_stats": "chart.bar",
        "msg_sticker": "sticker", "msg_tag": "tag", "msg_theme": "paintbrush",
        "msg_translate": "character.bubble", "msg_voice": "mic", "gift": "gift"
    ]
    private static func invalid() -> AyuBridgeFailure { AyuBridgeFailure("invalid_arguments", "Invalid menu arguments") }
}

/// Adds menu transport while preserving the real account, dialog and send-hook
/// provider. The service must install this composite as its native host provider.
public final class AyuPluginMenuHostProvider: AyuPluginHostProvider, AyuPluginSendHookSource, AyuPluginDialogHost, @unchecked Sendable {
    private let application: AyuPluginApplicationBridge
    private let menus: AyuPluginMenuBridge
    private let telegram: AyuPluginTelegramBridge
    private let speech: AyuPluginSpeechBridge
    public init(application: AyuPluginApplicationBridge, menus: AyuPluginMenuBridge = .shared, telegram: AyuPluginTelegramBridge = .shared, speech: AyuPluginSpeechBridge = .shared) {
        self.application = application; self.menus = menus; self.telegram = telegram; self.speech = speech
        menus.typed.setTLSource { [weak telegram] in telegram?.menuContextSource() }
        telegram.setEnvironment(application.telegramEnvironment())
    }
    public var capabilities: [String] { self.application.capabilities + self.menus.capabilities + self.telegram.capabilities + self.speech.capabilities }
    public func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
        try self.application.call(pluginID: pluginID, operation: operation, arguments: arguments)
    }
    public func prepareCall(pluginID: String, operation: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        if self.menus.capabilities.contains(operation) { return try self.menus.prepareCall(pluginID: pluginID, operation: operation, arguments: arguments, context: context) }
        if operation.hasPrefix("telegram.") || operation == AyuPluginTelegramBridge.Operation.hooksURLOpen { return try self.telegram.prepareCall(pluginID: pluginID, operation: operation, arguments: arguments, context: context) }
        // A token of `telegram.hooks.send_message` is removed here; any other goes to the three-field hook's owner.
        if operation.hasPrefix("speech.") { return try self.speech.prepareCall(pluginID: pluginID, operation: operation, arguments: arguments) }
        if operation == "hooks.unregister", let result = try self.telegram.prepareUnregister(pluginID: pluginID, arguments: arguments) { return result }
        return try self.application.prepareCall(pluginID: pluginID, operation: operation, arguments: arguments, context: context)
    }
    public func detach(pluginID: String) { self.menus.detach(pluginID: pluginID); self.application.detach(pluginID: pluginID); self.telegram.detach(pluginID: pluginID); self.speech.detach(pluginID: pluginID) }
    public func sendHooks() -> [AyuPluginSendHook] { self.application.sendHooks() }
    public func reserveDialogToken(_ token: String, pluginID: String) throws { try self.application.reserveDialogToken(token, pluginID: pluginID) }
    @MainActor public func presentBridgeDialog(_ controller: UIViewController, token: String, pluginID: String) throws { try self.application.presentBridgeDialog(controller, token: token, pluginID: pluginID) }
    public func dismissBridgeDialog(token: String, pluginID: String) { self.application.dismissBridgeDialog(token: token, pluginID: pluginID) }
}
