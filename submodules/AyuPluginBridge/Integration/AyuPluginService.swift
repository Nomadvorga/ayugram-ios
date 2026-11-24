import CryptoKit
import Foundation
import UIKit
import AyuPluginPython

private final class AyuPluginResourceAnchor: NSObject {}

private final class AyuRuntimeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: APBPythonRuntime?
    private var errorSink: (@Sendable (String, String?) -> Void)?
    func attach(_ runtime: APBPythonRuntime, errorSink: @escaping @Sendable (String, String?) -> Void) { self.lock.lock(); self.runtime = runtime; self.errorSink = errorSink; self.lock.unlock() }
    func deliver(_ owner: String, _ callback: String, _ arguments: [AyuBridgeValue]) {
        self.invoke(owner, callback, arguments) { _, _ in }
    }
    func invoke(_ owner: String, _ callback: String, _ arguments: [AyuBridgeValue], completion: @escaping @Sendable (String?, Error?) -> Void) {
        struct Event: Encodable { let version = 1; let plugin_id: String; let callback_id: String; let arguments: [AyuBridgeValue] }
        guard let data = try? JSONEncoder().encode(Event(plugin_id: owner, callback_id: callback, arguments: arguments)), let json = String(data: data, encoding: .utf8) else {
            completion(nil, NSError(domain: "AyuPluginPython", code: 2)); return
        }
        self.lock.lock(); let runtime = self.runtime; self.lock.unlock()
        guard let runtime else { completion(nil, NSError(domain: "AyuPluginPython", code: 2)); return }
        runtime.invokeCallback(json: json, pluginID: owner) { [weak self] result, error in
            if error != nil, let self {
                self.lock.lock(); let sink = self.errorSink; self.lock.unlock()
                sink?(owner, callback.split(separator: ":").first.map(String.init))
            }
            completion(result, error)
        }
    }
    func event(_ owner: String, generation: String, name: String) {
        struct Event: Encodable { let version = 1; let plugin_id: String; let generation: String; let name = "app"; let arguments: [String] }
        guard let data = try? JSONEncoder().encode(Event(plugin_id: owner, generation: generation, arguments: [name])), let json = String(data: data, encoding: .utf8) else { return }
        self.lock.lock(); let runtime = self.runtime; self.lock.unlock()
        runtime?.emitEvent(json: json, pluginID: owner) { [weak self] _, error in
            guard error != nil, let self else { return }
            self.lock.lock(); let sink = self.errorSink; self.lock.unlock(); sink?(owner, generation)
        }
    }
}

public struct AyuInstalledPlugin: Codable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public var blockers: [String]
    public var isEnabled = false
    public var isBusy = false
    public var error: String?
    /// A source-verified native adapter, not an assertion that Android APIs executed.
    public var nativeAdapter: String?
    public var status: String {
        if self.isBusy { return "Выполняется операция…" }
        if self.isEnabled { return self.error == nil ? (self.nativeAdapter == nil ? "Включён" : "Включён · нативный адаптер") : "Включён · ошибка" }
        if !self.blockers.isEmpty { return "Не поддерживается этой сборкой" }
        return self.error == nil ? "Выключен" : "Ошибка · выключен"
    }
}

public struct AyuPluginSetting: Sendable {
    public let descriptor: AyuBridgeValue
    public var value: AyuBridgeValue
    public var type: String { self.descriptor["type"].string ?? "Unknown" }
    public var key: String? { self.descriptor["key"].string }
    public var text: String { String((self.descriptor["text"].string ?? self.type).prefix(256)) }
    public var isSecret: Bool { ["key", "token", "password", "secret"].contains { self.key?.lowercased().contains($0) == true } }
}

@MainActor public final class AyuPluginService {
    public static let shared: AyuPluginService = {
        let application = AyuPluginApplicationBridge.shared
        do { return AyuPluginService(provider: application, classRegistry: try application.classRegistry()) }
        catch { preconditionFailure("Invalid compiled application adapters") }
    }()
    public static let didChange = Notification.Name("AyuPluginServiceDidChange")
    /// This build has no general plugin runtime. Only audited native adapters
    /// and one pinned Python source are importable; everything else is rejected
    /// before any code is written or Python starts.
    nonisolated static let groupMentionsID = "group_mentions"
    nonisolated static let groupMentionsSHA256 = "25ae71486b29481d57cc36eaf40e931522a655227d2870dfc898174b8d96f28e"
    nonisolated static let supportedPluginSummary = "Ball, Pull to Next Chat, SandBox, Screenshot Privacy, NewYear Interface и Group Mentions"
    nonisolated static let unsupportedBlocker = "Эта сборка поддерживает только проверенные плагины: " + supportedPluginSummary + ". Остальные .plugin не импортируются и не запускаются."
    nonisolated static let pinnedPythonBlocker = "Исходник Group Mentions не совпадает с проверенной версией. Эта сборка не запускает изменённый Python-код."
    public private(set) var plugins: [AyuInstalledPlugin] = []
    public private(set) var startupError: String?
    public let host: AyuPluginNativeHost
    private let runtime = APBPythonRuntime()
    private let relay: AyuRuntimeRelay
    private let sendHookSource: AyuPluginSendHookSource?
    private let defaults: UserDefaults
    private let root: URL
    private var preparation: Task<Void, Error>?
    private var runtimePreparation: Task<Void, Error>?
    private var atmosphericAdapter: AyuAtmosphericPluginAdapter?
    private var nativeAdapters: [String: AyuNativePluginAdapter] = [:]
    private var pending: Set<String> = []
    private var pendingImportSlots = 0
    private var classes: Set<String> = []
    private var modules: Set<String> = []
    private var pythonGenerations: [String: String] = [:]
    private var appInForeground = false
    private var appIsActive = false
    nonisolated private static let maximumBytes = 1_048_576

    public init(defaults: UserDefaults = .standard, provider: AyuPluginHostProvider = AyuUnsupportedPluginHostProvider(), classRegistry: AyuBridgeClassRegistry = .standard, limits: AyuPluginBridgeLimits = AyuPluginBridgeLimits()) {
        let relay = AyuRuntimeRelay()
        self.relay = relay; self.defaults = defaults
        self.sendHookSource = provider as? AyuPluginSendHookSource
        self.host = AyuPluginNativeHost(defaults: defaults, provider: provider, classRegistry: classRegistry, limits: limits, trustedOwner: { nil }, callback: { owner, callback, arguments in relay.deliver(owner, callback, arguments) })
        self.root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AyuPlugins", isDirectory: true)
        relay.attach(self.runtime) { [weak self] owner, generation in Task { @MainActor in
            guard let self, let generation, self.pythonGenerations[owner] == generation,
                  self.plugins.contains(where: { $0.id == owner && $0.isEnabled && !$0.isBusy }) else { return }
            self.update(owner) { $0.error = "Ошибка обработчика Python. Плагин остаётся включённым; его можно выключить." }
        } }
    }

    public enum Failure: LocalizedError, Sendable {
        case resources, pythonResources, sdkResources, runtimeStartup, sdkStartup, runtimeQueue
        case source, identity, duplicate, storage, inactive, busy, runtime, protocolError, operation(String)
        case unsupportedPlugin
        public var errorDescription: String? {
            switch self {
            case .resources: return "Не удалось найти встроенный тестовый плагин."
            case .pythonResources: return "Не найдена стандартная библиотека Python: AyuPythonResources.bundle/python."
            case .sdkResources: return "Не найден SDK плагинов: AyuPluginSDK.bundle/Python."
            case .runtimeStartup: return "Не удалось запустить встроенный Python. Перезапустите приложение; если ошибка повторится, сообщите номер сборки."
            case .sdkStartup: return "Встроенный Python не смог загрузить SDK плагинов. Сообщите номер сборки."
            case .runtimeQueue: return "Очередь Python заполнена. Дождитесь завершения текущих операций."
            case .source: return "Нужен обычный UTF-8 файл .plugin размером до 1 МиБ."
            case .identity: return "Неверный идентификатор плагина или метаданные."
            case .duplicate: return "Плагин с таким идентификатором уже установлен. Сначала удалите его."
            case .storage: return "Не удалось безопасно прочитать или сохранить плагин."
            case .inactive: return "Сначала включите плагин."
            case .busy: return "Дождитесь завершения текущей операции."
            case .runtime: return "Python отклонил операцию. Проверьте зависимости и поддерживаемые API."
            case .protocolError: return "SDK вернул неподдерживаемый формат данных."
            case .unsupportedPlugin: return AyuPluginService.unsupportedBlocker
            case let .operation(code): return "Операция моста отклонена: \(code)."
            }
        }
    }

    public func prepare() async throws {
        if let preparation = self.preparation { return try await preparation.value }
        let task = Task { @MainActor in
            let root = self.root
            self.plugins = try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw Failure.storage }
                let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return files.filter { $0.pathExtension == "json" }.prefix(64).compactMap { url -> AyuInstalledPlugin? in
                    guard let data = try? Self.read(url, limit: 65_536), var record = try? JSONDecoder().decode(AyuInstalledPlugin.self, from: data), Self.validID(record.id), url.deletingPathExtension().lastPathComponent == record.id else { return nil }
                    record.isEnabled = false; record.isBusy = false; record.error = nil
                    record.nativeAdapter = nil
                    // Recheck bytes instead of trusting saved native-adapter metadata.
                    let sourceURL = root.appendingPathComponent(record.id + ".plugin")
                    if record.id == AyuAtmosphericPluginAdapter.pluginID {
                        if let source = try? Self.read(sourceURL, limit: Self.maximumBytes),
                           let verified = AyuAtmosphericPluginAdapter.record(for: source) {
                            record = verified
                        } else {
                            record.nativeAdapter = nil
                            record.blockers = ["Нативный адаптер требует исходный Atmospheric Snow 1.0.1 с проверенной контрольной суммой."]
                        }
                    } else if let descriptor = AyuNativePluginCatalog.descriptor(id: record.id) {
                        if let source = try? Self.read(sourceURL, limit: Self.maximumBytes),
                           let verified = descriptor.record(for: source) {
                            record = verified
                        } else {
                            record.nativeAdapter = nil
                            record.blockers = [AyuNativePluginCatalog.blocker(for: record.id)]
                        }
                    } else if record.id == Self.groupMentionsID {
                        if let source = try? Self.read(sourceURL, limit: Self.maximumBytes),
                           let verified = Self.pinnedPythonRecord(for: source) {
                            record = verified
                        } else {
                            record.nativeAdapter = nil
                            record.blockers = [Self.pinnedPythonBlocker]
                        }
                    } else {
                        // A plugin installed by an older build is no longer a
                        // supported route. Keep it visible so the user can
                        // delete it, but never run it again.
                        record.nativeAdapter = nil
                        record.blockers = [Self.unsupportedBlocker]
                    }
                    return record
                }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }.value
            self.changed()
        }
        self.preparation = task
        do { try await task.value } catch { self.startupError = (error as? Failure)?.localizedDescription ?? Failure.storage.localizedDescription; self.changed(); throw error }
    }

    /// Python remains lazy: the pinned Atmospheric Snow adapter never starts an interpreter.
    private func prepareRuntime() async throws {
        if let task = self.runtimePreparation { return try await task.value }
        // Resolve before caching a task: a resource lookup failure did not start
        // Python and must not become a permanently cached interpreter failure.
        guard let home = Self.resource(.pythonHome) else { throw Failure.pythonResources }
        guard let sdk = Self.resource(.sdk) else { throw Failure.sdkResources }
        let task = Task { @MainActor in
            _ = try await self.complete(starting: true) { done in self.runtime.start(pythonHome: home.path, sdkPath: sdk.path, dispatchHandler: { [host = self.host] owner, request in host.dispatch(request, owner: owner) }, completion: done) }
            let caps = try await self.command("runtime.capabilities", owner: "inspector", arguments: [:], bootstrap: true)
            self.classes = Set(caps["classes"].array?.compactMap(\.string) ?? caps["classes"].object?.keys.map { $0 } ?? [])
            self.modules = Set(caps["modules"].array?.compactMap(\.string) ?? [])
        }
        self.runtimePreparation = task
        // Once native startup was attempted, retain failures until process exit.
        // CPython may already own the process even when importing the SDK failed.
        try await task.value
    }

    public func importPlugin(from url: URL) async throws {
        try await self.prepare()
        guard self.plugins.count + self.pendingImportSlots < 64 else { throw Failure.operation("RESOURCE_LIMIT") }
        self.pendingImportSlots += 1
        defer { self.pendingImportSlots -= 1 }
        let source = try await Task.detached(priority: .utility) {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard url.pathExtension.lowercased() == "plugin", let source = String(data: try Self.read(url, limit: Self.maximumBytes), encoding: .utf8) else { throw Failure.source }
            return source
        }.value
        let (record, _) = try await self.inspect(source)
        guard !self.plugins.contains(where: { $0.id == record.id }), self.pending.insert(record.id).inserted else { throw Failure.duplicate }
        defer { self.pending.remove(record.id) }
        let root = self.root
        do {
            try await Task.detached(priority: .utility) {
                let sourceURL = root.appendingPathComponent(record.id + ".plugin"), metadataURL = root.appendingPathComponent(record.id + ".json")
                guard !FileManager.default.fileExists(atPath: sourceURL.path), !FileManager.default.fileExists(atPath: metadataURL.path) else { throw Failure.duplicate }
                try Data(source.utf8).write(to: sourceURL, options: .atomic)
                do { try JSONEncoder().encode(record).write(to: metadataURL, options: .atomic) }
                catch { try? FileManager.default.removeItem(at: sourceURL); throw Failure.storage }
            }.value
        } catch { throw (error as? Failure) ?? Failure.storage }
        guard self.plugins.count < 64 else { throw Failure.operation("RESOURCE_LIMIT") }
        self.plugins.append(record); self.changed()
    }

    /// Call only after the user explicitly trusts this installed plugin for this process.
    public func enable(_ id: String) async throws {
        try await self.prepare()
        if self.plugins.contains(where: { $0.id == id && $0.isEnabled && !$0.isBusy }) { return }
        try self.begin(id)
        defer { self.finish(id) }
        let url = self.root.appendingPathComponent(id + ".plugin")
        do {
            let source = try await Task.detached(priority: .utility) { guard let text = String(data: try Self.read(url, limit: Self.maximumBytes), encoding: .utf8) else { throw Failure.source }; return text }.value
            let (inspection, _) = try await self.inspect(source)
            guard inspection.id == id else { throw Failure.identity }
            self.update(id) { $0.blockers = inspection.blockers; $0.error = nil; $0.nativeAdapter = inspection.nativeAdapter }
            guard inspection.blockers.isEmpty else { throw Failure.operation("UNSUPPORTED_API") }
            if inspection.nativeAdapter == AyuAtmosphericPluginAdapter.adapterID {
                let adapter = AyuAtmosphericPluginAdapter(defaults: self.defaults, reportError: { [weak self] message in
                    self?.update(id) { $0.error = message }
                })
                try adapter.enable()
                self.atmosphericAdapter = adapter
                self.update(id) { $0.isEnabled = true; $0.nativeAdapter = inspection.nativeAdapter }
                return
            }
            if let descriptor = AyuNativePluginCatalog.descriptor(id: id), inspection.nativeAdapter == descriptor.adapterID {
                let adapter = descriptor.make(self.defaults, AyuNativePluginReporter { [weak self] message in
                    self?.update(id) { $0.error = message }
                })
                adapter.verifiedSource = source
                try adapter.enable()
                self.nativeAdapters[id] = adapter
                self.update(id) { $0.isEnabled = true; $0.nativeAdapter = inspection.nativeAdapter }
                return
            }
            // No generic Python route: only the pinned Group Mentions source
            // may reach the interpreter, and it starts lazily here.
            guard id == Self.groupMentionsID else { throw Failure.unsupportedPlugin }
            try await self.prepareRuntime()
            let json = try await self.complete { self.runtime.load(source: source, filename: id + ".plugin", completion: $0) }
            let loaded = try self.decode(json)
            guard loaded["plugin_id"].string == id, let generation = loaded["generation"].string,
                  generation.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { throw Failure.protocolError }
            self.pythonGenerations[id] = generation
            self.update(id) { $0.isEnabled = true }
            self.relay.event(id, generation: generation, name: "START")
            if self.appIsActive { self.relay.event(id, generation: generation, name: "RESUME") }
        } catch {
            self.pythonGenerations.removeValue(forKey: id)
            // Also handle a successful load followed by a malformed result: revoke both layers.
            if id == AyuAtmosphericPluginAdapter.pluginID {
                self.atmosphericAdapter?.disable(); self.atmosphericAdapter = nil
            }
            self.nativeAdapters.removeValue(forKey: id)?.disable()
            if self.runtimePreparation != nil { _ = try? await self.complete { self.runtime.unload(pluginID: id, completion: $0) } }
            await self.detach(id); self.update(id) { $0.isEnabled = false; $0.error = self.message(error) }; throw error
        }
    }

    public func disable(_ id: String) async throws {
        try self.begin(id); defer { self.finish(id) }
        self.pythonGenerations.removeValue(forKey: id)
        if id == AyuAtmosphericPluginAdapter.pluginID, let adapter = self.atmosphericAdapter {
            adapter.disable(); self.atmosphericAdapter = nil
            self.update(id) { $0.isEnabled = false; $0.error = nil }
            return
        }
        if let adapter = self.nativeAdapters.removeValue(forKey: id) {
            adapter.disable()
            self.update(id) { $0.isEnabled = false; $0.error = nil }
            return
        }
        var failure: Error?
        if self.plugins.first(where: { $0.id == id })?.isEnabled == true {
            do { _ = try await self.complete { self.runtime.unload(pluginID: id, completion: $0) } } catch { failure = error }
        }
        await self.detach(id)
        self.update(id) { $0.isEnabled = false; $0.error = failure.map(self.message) }
        if let failure { throw failure }
    }

    public func delete(_ id: String) async throws {
        guard Self.validID(id) else { throw Failure.identity }
        if self.plugins.first(where: { $0.id == id })?.isEnabled == true { try await self.disable(id) }
        try self.begin(id); defer { self.finish(id) }
        let root = self.root
        do { try await Task.detached(priority: .utility) { for ext in ["plugin", "json"] { let path = root.appendingPathComponent(id + "." + ext); if FileManager.default.fileExists(atPath: path.path) { _ = try Self.read(path, limit: ext == "plugin" ? Self.maximumBytes : 65_536); try FileManager.default.removeItem(at: path) } } }.value }
        catch { throw Failure.storage }
        self.defaults.removeObject(forKey: "AyuPluginBridge.v1." + id)
        self.plugins.removeAll { $0.id == id }; self.changed()
    }

    public func settings(_ id: String) async throws -> [AyuPluginSetting] {
        guard self.plugins.contains(where: { $0.id == id && $0.isEnabled && !$0.isBusy }) else { throw Failure.inactive }
        if id == AyuAtmosphericPluginAdapter.pluginID, let adapter = self.atmosphericAdapter { return try adapter.settings() }
        if let adapter = self.nativeAdapters[id] { return try adapter.settings() }
        let json = try await self.complete { self.runtime.settings(pluginID: id, completion: $0) }
        guard let rows = try self.decode(json).array, rows.count <= 256 else { throw Failure.protocolError }
        let values = try await self.command("settings.all", owner: id, arguments: [:])
        return try Self.settings(rows: rows, values: values)
    }

    /// Rows returned by a `create_sub_fragment` callback. The same bounded
    /// persistence keys are used as on the root settings page.
    public func subpage(pluginID: String, callbackID: String) async throws -> [AyuPluginSetting] {
        guard self.plugins.contains(where: { $0.id == pluginID && $0.isEnabled && !$0.isBusy }) else { throw Failure.inactive }
        guard !callbackID.isEmpty, callbackID.utf8.count <= 128 else { throw Failure.protocolError }
        let json = try await self.invokeCallback(pluginID, callbackID, [])
        guard let rows = try self.decode(json).array, rows.count <= 256 else { throw Failure.protocolError }
        let values = try await self.command("settings.all", owner: pluginID, arguments: [:])
        return try Self.settings(rows: rows, values: values)
    }

    private static func settings(rows: [AyuBridgeValue], values: AyuBridgeValue) throws -> [AyuPluginSetting] {
        return try rows.map { row in
            let value = row["key"].string.flatMap { values.object?[$0] } ?? row["default"]
            guard (value.string?.utf8.count ?? 0) <= 8192 else { throw Failure.operation("SETTING_VALUE_TOO_LARGE") }
            return AyuPluginSetting(descriptor: row, value: value)
        }
    }

    private func invokeCallback(_ owner: String, _ callback: String, _ arguments: [AyuBridgeValue]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.relay.invoke(owner, callback, arguments) { json, error in
                if let json, error == nil { continuation.resume(returning: json) }
                else { continuation.resume(throwing: Self.runtimeFailure(error, starting: false)) }
            }
        }
    }

    public var hasSendHooks: Bool { self.sendHookSource?.sendHooks().isEmpty == false }

    /// One callback round trip. `relay.invoke` may complete on the Python
    /// thread, so the result is handed back through a continuation and the
    /// caller stays on its own executor.
    private func sendHookResult(_ owner: String, _ callback: String, _ arguments: [AyuBridgeValue]) async -> AyuBridgeValue? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AyuBridgeValue?, Never>) in
            self.relay.invoke(owner, callback, arguments) { json, error in
                guard error == nil, let json, json.utf8.count <= Self.maximumBytes,
                      let decoded = try? JSONDecoder().decode(AyuBridgeValue.self, from: Data(json.utf8)) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: decoded)
            }
        }
    }

    /// Runs the original plugin `on_send_message_hook` chain before enqueueing.
    /// A plugin result with CANCEL suppresses the send; MODIFY/MODIFY_FINAL
    /// replaces the mutable `message`/`caption` fields. Completion is on main.
    public func applySendHooks(message: String?, caption: String?, peerID: Int64, accountIndex: Int64, completion: @escaping @MainActor (String?, String?, Bool) -> Void) {
        let hooks = self.sendHookSource?.sendHooks() ?? []
        guard !hooks.isEmpty else { completion(message, caption, false); return }
        var params: [String: AyuBridgeValue] = ["peer": .integer(peerID)]
        if let message { params["message"] = .string(message) }
        if let caption { params["caption"] = .string(caption) }
        Task { @MainActor in
            var values = params
            for hook in hooks {
                guard let decoded = await self.sendHookResult(hook.pluginID, hook.callbackID, [.integer(accountIndex), .object(values)]),
                      let result = decoded.object else { continue }
                let strategy = result["strategy"]?.integer ?? 0
                if strategy == 1 {
                    completion(values["message"]?.string, values["caption"]?.string, true)
                    return
                }
                if strategy == 2 || strategy == 3, let updated = result["params"]?.object {
                    values = updated
                }
            }
            completion(values["message"]?.string, values["caption"]?.string, false)
        }
    }

    public func set(_ row: AyuPluginSetting, value: AyuBridgeValue, pluginID: String) async throws {
        guard let key = row.key, key.utf8.count <= 256, (value.string?.utf8.count ?? 0) <= 8192 else { throw Failure.protocolError }
        guard self.plugins.contains(where: { $0.id == pluginID && $0.isEnabled && !$0.isBusy }) else { throw Failure.inactive }
        if pluginID == AyuAtmosphericPluginAdapter.pluginID, let adapter = self.atmosphericAdapter {
            try adapter.set(row, value: value); self.changed(); return
        }
        if let adapter = self.nativeAdapters[pluginID] {
            try adapter.set(row, value: value); self.changed(); return
        }
        _ = try await self.command("settings.set", owner: pluginID, arguments: ["key": .string(key), "value": value, "reload_settings": .bool(true)])
        if let callback = row.descriptor["on_change"]["$callback"].string { self.relay.deliver(pluginID, callback, [value]) }
    }
    public func activate(_ row: AyuPluginSetting, pluginID: String, presenter: UIViewController? = nil, completion: @escaping () -> Void = {}) {
        guard self.plugins.contains(where: { $0.id == pluginID && $0.isEnabled && !$0.isBusy }) else { return }
        if pluginID == AyuAtmosphericPluginAdapter.pluginID, let adapter = self.atmosphericAdapter {
            do { try adapter.activate(row); self.changed() }
            catch { self.update(pluginID) { $0.error = self.message(error) } }
            completion()
            return
        }
        if let adapter = self.nativeAdapters[pluginID] {
            do { try adapter.activate(row, presenter: presenter, completion: { [weak self] in self?.changed(); completion() }) }
            catch { self.update(pluginID) { $0.error = self.message(error) }; completion() }
            return
        }
        if let callback = row.descriptor["on_click"]["$callback"].string { self.relay.deliver(pluginID, callback, [.null]) }
        completion()
    }

    /// Nil unless the enabled source-verified adapter contributes a full-screen
    /// or host-owned surface. The plugin manager uses this for its action row.
    public func nativeActionTitle(for id: String) -> String? {
        guard self.plugins.contains(where: { $0.id == id && $0.isEnabled && !$0.isBusy }) else { return nil }
        return self.nativeAdapters[id]?.actionTitle
    }

    public func openNativePlugin(_ id: String, from presenter: UIViewController) throws {
        guard self.plugins.contains(where: { $0.id == id && $0.isEnabled && !$0.isBusy }) else { throw Failure.inactive }
        guard let adapter = self.nativeAdapters[id] else { throw Failure.inactive }
        switch id {
        case "screenshot_privacy":
            guard let privacy = adapter as? AyuScreenshotPrivacyAdapter else { throw Failure.inactive }
            privacy.open(from: presenter)
        case "sand_box":
            guard let sand = adapter as? AyuSandBoxAdapter else { throw Failure.inactive }
            sand.open(from: presenter)
        case "ball":
            guard let ball = adapter as? AyuBallAdapter else { throw Failure.inactive }
            ball.open(from: presenter)
        default:
            adapter.open(from: presenter)
        }
    }
    public func mount(_ view: UIView?, pluginID: String) { self.host.setMountContainer(view, pluginID: pluginID) }

    /// Fed by Telegram's application bindings. Never starts Python and never
    /// synchronously waits for it. Queued events carry the exact load generation.
    public func applicationDidChange(inForeground: Bool, isActive: Bool) {
        if self.appIsActive && !isActive { self.emitApplicationEvent("PAUSE") }
        if self.appInForeground && !inForeground { self.emitApplicationEvent("STOP") }
        if !self.appIsActive && isActive { self.emitApplicationEvent("RESUME") }
        self.appInForeground = inForeground; self.appIsActive = isActive
    }
    private func emitApplicationEvent(_ name: String) {
        for (id, generation) in self.pythonGenerations {
            guard self.plugins.contains(where: { $0.id == id && $0.isEnabled && !$0.isBusy }) else { continue }
            self.relay.event(id, generation: generation, name: name)
        }
    }

    /// Only audited sources pass: five native contracts and the one pinned
    /// Group Mentions Python source. Unknown plugins are rejected without
    /// importing, writing or starting an interpreter.
    private func inspect(_ source: String) async throws -> (AyuInstalledPlugin, AyuBridgeValue) {
        let data = Data(source.utf8)
        if let record = AyuAtmosphericPluginAdapter.record(for: data) { return (record, .object([:])) }
        if let record = AyuNativePluginCatalog.record(for: data) { return (record, .object([:])) }
        if let record = Self.pinnedPythonRecord(for: data) { return (record, .object([:])) }
        throw Failure.unsupportedPlugin
    }

    nonisolated private static func pinnedPythonRecord(for source: Data) -> AyuInstalledPlugin? {
        guard source.count <= self.maximumBytes else { return nil }
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        guard digest == self.groupMentionsSHA256 else { return nil }
        return AyuInstalledPlugin(id: self.groupMentionsID, name: "Group Mentions", version: "1.2", blockers: [], nativeAdapter: nil)
    }

    private func command(_ operation: String, owner: String, arguments: [String: AyuBridgeValue], bootstrap: Bool = false) async throws -> AyuBridgeValue {
        let body: AyuBridgeValue = .object(["version": .integer(1), "id": .string("1"), "plugin_id": .string(bootstrap ? "$runtime" : owner), "operation": .string(operation), "arguments": .object(arguments)])
        let request = String(decoding: try JSONEncoder().encode(body), as: UTF8.self), host = self.host
        let response = try self.decode(await Task.detached(priority: .userInitiated) { host.dispatch(request, owner: owner) }.value)
        if let code = response["error"]["code"].string { throw Failure.operation(Self.apiLabel(code)) }
        guard response["version"].number == 1 else { throw Failure.protocolError }; return response["result"]
    }
    private func complete(starting: Bool = false, _ work: (@escaping @Sendable (String?, Error?) -> Void) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in work { json, error in if let json, error == nil { continuation.resume(returning: json) } else { continuation.resume(throwing: Self.runtimeFailure(error, starting: starting)) } } }
    }
    // Never forward localizedDescription/userInfo/tracebacks from Python. Only
    // native-owned domain and numeric codes affect these fixed diagnostics.
    nonisolated static func runtimeFailure(_ error: Error?, starting: Bool) -> Failure {
        if let error = error as NSError?, error.domain == "AyuPluginPython" {
            if error.code == 4 { return .runtimeQueue }
            if error.code == 3 { return .source }
            if starting && error.code == 2 { return .sdkStartup }
        }
        return starting ? .runtimeStartup : .runtime
    }
    private func detach(_ id: String) async { await withCheckedContinuation { continuation in self.host.detach(pluginID: id) { continuation.resume() } } }
    private func decode(_ json: String) throws -> AyuBridgeValue { guard json.utf8.count <= Self.maximumBytes else { throw Failure.protocolError }; do { return try JSONDecoder().decode(AyuBridgeValue.self, from: Data(json.utf8)) } catch { throw Failure.protocolError } }
    private func begin(_ id: String) throws { guard Self.validID(id), let row = self.plugins.first(where: { $0.id == id }) else { throw Failure.identity }; guard !row.isBusy else { throw Failure.busy }; self.update(id) { $0.isBusy = true; $0.error = nil } }
    private func finish(_ id: String) { self.update(id) { $0.isBusy = false } }
    private func update(_ id: String, _ change: (inout AyuInstalledPlugin) -> Void) { if let index = self.plugins.firstIndex(where: { $0.id == id }) { change(&self.plugins[index]); self.changed() } }
    private func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }
    private func message(_ error: Error) -> String { (error as? Failure)?.localizedDescription ?? Failure.runtime.localizedDescription }
    nonisolated private static func validID(_ id: String) -> Bool { id.range(of: "^[A-Za-z][A-Za-z0-9_-]{1,31}$", options: .regularExpression) != nil }
    nonisolated private static func apiLabel(_ text: String) -> String { text.utf8.count <= 180 && text.range(of: "^[A-Za-z][A-Za-z0-9_.$<>=!+,-]*$", options: .regularExpression) != nil ? text : "неизвестная или вычисляемая зависимость" }
    nonisolated private static func read(_ url: URL, limit: Int) throws -> Data {
        let flags = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]); guard flags.isRegularFile == true, flags.isSymbolicLink != true else { throw Failure.source }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data(); guard data.count <= limit else { throw Failure.source }; return data
    }
    private static func resource(_ payload: AyuPluginResourceLocator.Payload) -> URL? {
        let roots = [Bundle.main, Bundle(for: AyuPluginResourceAnchor.self), Bundle(for: APBPythonRuntime.self)].compactMap(\.resourceURL)
        return AyuPluginResourceLocator.locate(payload, roots: roots)
    }
}
