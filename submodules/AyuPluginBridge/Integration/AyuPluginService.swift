import Foundation
import UIKit
import AyuPluginPython

private final class AyuRuntimeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: APBPythonRuntime?
    private var errorSink: (@Sendable (String) -> Void)?
    func attach(_ runtime: APBPythonRuntime, errorSink: @escaping @Sendable (String) -> Void) { self.lock.lock(); self.runtime = runtime; self.errorSink = errorSink; self.lock.unlock() }
    func deliver(_ owner: String, _ callback: String, _ arguments: [AyuBridgeValue]) {
        struct Event: Encodable { let version = 1; let plugin_id: String; let callback_id: String; let arguments: [AyuBridgeValue] }
        guard let data = try? JSONEncoder().encode(Event(plugin_id: owner, callback_id: callback, arguments: arguments)), let json = String(data: data, encoding: .utf8) else { return }
        self.lock.lock(); let runtime = self.runtime; self.lock.unlock()
        runtime?.invokeCallback(json: json, pluginID: owner) { [weak self] _, error in
            guard error != nil, let self else { return }
            self.lock.lock(); let sink = self.errorSink; self.lock.unlock(); sink?(owner)
        } // Expired callbacks never revive a plugin.
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
    public static let shared = AyuPluginService()
    public static let didChange = Notification.Name("AyuPluginServiceDidChange")
    public private(set) var plugins: [AyuInstalledPlugin] = []
    public private(set) var startupError: String?
    public let host: AyuPluginNativeHost
    private let runtime = APBPythonRuntime()
    private let relay: AyuRuntimeRelay
    private let defaults: UserDefaults
    private let root: URL
    private var preparation: Task<Void, Error>?
    private var runtimePreparation: Task<Void, Error>?
    private var atmosphericAdapter: AyuAtmosphericPluginAdapter?
    private var pending: Set<String> = []
    private var pendingImportSlots = 0
    private var classes: Set<String> = []
    private var modules: Set<String> = []
    nonisolated private static let maximumBytes = 1_048_576

    public init(defaults: UserDefaults = .standard, provider: AyuPluginHostProvider = AyuUnsupportedPluginHostProvider(), classRegistry: AyuBridgeClassRegistry = .standard, limits: AyuPluginBridgeLimits = AyuPluginBridgeLimits()) {
        let relay = AyuRuntimeRelay()
        self.relay = relay; self.defaults = defaults
        self.host = AyuPluginNativeHost(defaults: defaults, provider: provider, classRegistry: classRegistry, limits: limits, trustedOwner: { nil }, callback: { owner, callback, arguments in relay.deliver(owner, callback, arguments) })
        self.root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AyuPlugins", isDirectory: true)
        relay.attach(self.runtime) { [weak self] owner in Task { @MainActor in
            guard let self, self.plugins.contains(where: { $0.id == owner && $0.isEnabled && !$0.isBusy }) else { return }
            self.update(owner) { $0.error = "Ошибка обработчика Python. Плагин остаётся включённым; его можно выключить." }
        } }
    }

    public enum Failure: LocalizedError, Sendable {
        case resources, source, identity, duplicate, storage, inactive, busy, runtime, protocolError, operation(String)
        public var errorDescription: String? {
            switch self {
            case .resources: return "В сборке отсутствуют Python runtime или SDK плагинов."
            case .source: return "Нужен обычный UTF-8 файл .plugin размером до 1 МиБ."
            case .identity: return "Неверный идентификатор плагина или метаданные."
            case .duplicate: return "Плагин с таким идентификатором уже установлен. Сначала удалите его."
            case .storage: return "Не удалось безопасно прочитать или сохранить плагин."
            case .inactive: return "Сначала включите плагин."
            case .busy: return "Дождитесь завершения текущей операции."
            case .runtime: return "Python отклонил операцию. Проверьте зависимости и поддерживаемые API."
            case .protocolError: return "SDK вернул неподдерживаемый формат данных."
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
                    if record.id == AyuAtmosphericPluginAdapter.pluginID {
                        let sourceURL = root.appendingPathComponent(record.id + ".plugin")
                        if let source = try? Self.read(sourceURL, limit: Self.maximumBytes),
                           let verified = AyuAtmosphericPluginAdapter.record(for: source) {
                            record = verified
                        } else {
                            record.nativeAdapter = nil
                            record.blockers = ["Нативный адаптер требует исходный Atmospheric Snow 1.0.1 с проверенной контрольной суммой."]
                        }
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
        let task = Task { @MainActor in
            guard let home = Self.resource("AyuPythonResources", "python"), let sdk = Self.resource("AyuPluginSDK", "Python") else { throw Failure.resources }
            _ = try await self.complete { done in self.runtime.start(pythonHome: home.path, sdkPath: sdk.path, dispatchHandler: { [host = self.host] owner, request in host.dispatch(request, owner: owner) }, completion: done) }
            let caps = try await self.command("runtime.capabilities", owner: "inspector", arguments: [:], bootstrap: true)
            self.classes = Set(caps["classes"].array?.compactMap(\.string) ?? caps["classes"].object?.keys.map { $0 } ?? [])
            self.modules = Set(caps["modules"].array?.compactMap(\.string) ?? [])
        }
        self.runtimePreparation = task
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

    public func importBundledTest() async throws {
        guard let url = Self.resource("AyuPluginSDK", "Resources/bridge_smoke.plugin") else { throw Failure.resources }
        try await self.importPlugin(from: url)
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
            let json = try await self.complete { self.runtime.load(source: source, filename: id + ".plugin", completion: $0) }
            guard try self.decode(json)["plugin_id"].string == id else { throw Failure.protocolError }
            self.update(id) { $0.isEnabled = true }
        } catch {
            // Also handle a successful load followed by a malformed result: revoke both layers.
            if id == AyuAtmosphericPluginAdapter.pluginID {
                self.atmosphericAdapter?.disable(); self.atmosphericAdapter = nil
            }
            if self.runtimePreparation != nil { _ = try? await self.complete { self.runtime.unload(pluginID: id, completion: $0) } }
            await self.detach(id); self.update(id) { $0.isEnabled = false; $0.error = self.message(error) }; throw error
        }
    }

    public func disable(_ id: String) async throws {
        try self.begin(id); defer { self.finish(id) }
        if id == AyuAtmosphericPluginAdapter.pluginID, let adapter = self.atmosphericAdapter {
            adapter.disable(); self.atmosphericAdapter = nil
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
        let json = try await self.complete { self.runtime.settings(pluginID: id, completion: $0) }
        guard let rows = try self.decode(json).array, rows.count <= 256 else { throw Failure.protocolError }
        let values = try await self.command("settings.all", owner: id, arguments: [:])
        return try rows.map { row in
            let value = row["key"].string.flatMap { values.object?[$0] } ?? row["default"]
            guard (value.string?.utf8.count ?? 0) <= 8192 else { throw Failure.operation("SETTING_VALUE_TOO_LARGE") }
            return AyuPluginSetting(descriptor: row, value: value)
        }
    }

    public func set(_ row: AyuPluginSetting, value: AyuBridgeValue, pluginID: String) async throws {
        guard let key = row.key, key.utf8.count <= 256, (value.string?.utf8.count ?? 0) <= 8192 else { throw Failure.protocolError }
        guard self.plugins.contains(where: { $0.id == pluginID && $0.isEnabled && !$0.isBusy }) else { throw Failure.inactive }
        if pluginID == AyuAtmosphericPluginAdapter.pluginID, let adapter = self.atmosphericAdapter {
            try adapter.set(row, value: value); self.changed(); return
        }
        _ = try await self.command("settings.set", owner: pluginID, arguments: ["key": .string(key), "value": value, "reload_settings": .bool(true)])
        if let callback = row.descriptor["on_change"]["$callback"].string { self.relay.deliver(pluginID, callback, [value]) }
    }
    public func activate(_ row: AyuPluginSetting, pluginID: String) {
        if pluginID == AyuAtmosphericPluginAdapter.pluginID, let adapter = self.atmosphericAdapter {
            guard self.plugins.contains(where: { $0.id == pluginID && $0.isEnabled && !$0.isBusy }) else { return }
            do { try adapter.activate(row); self.changed() }
            catch { self.update(pluginID) { $0.error = self.message(error) } }
            return
        }
        if let callback = row.descriptor["on_click"]["$callback"].string { self.relay.deliver(pluginID, callback, [.null]) }
    }
    public func mount(_ view: UIView?, pluginID: String) { self.host.setMountContainer(view, pluginID: pluginID) }

    private func inspect(_ source: String) async throws -> (AyuInstalledPlugin, AyuBridgeValue) {
        if let record = AyuAtmosphericPluginAdapter.record(for: Data(source.utf8)) { return (record, .object([:])) }
        try await self.prepareRuntime()
        let json = try await self.complete { self.runtime.inspect(source: source, filename: "import.plugin", completion: $0) }
        let report = try self.decode(json), metadata = report["metadata"]
        guard let id = metadata["__id__"].string, Self.validID(id), let name = metadata["__name__"].string, !name.isEmpty, name.utf8.count <= 256 else { throw Failure.identity }
        if id == AyuAtmosphericPluginAdapter.pluginID {
            return (AyuInstalledPlugin(id: id, name: "NewYear Interface", version: "1.0.1", blockers: ["Исходник не совпадает с проверенным Atmospheric Snow 1.0.1 (SHA-256). Нативный адаптер не может его выполнить."]), report)
        }
        var blockers = (report["classes"].array ?? []).compactMap(\.string).filter { !self.classes.contains($0) }.map { "Класс не поддерживается: " + Self.apiLabel($0) }
        for (module, symbols) in (report["unsupported_sdk_symbols"].object ?? [:]).sorted(by: { $0.key < $1.key }) {
            for symbol in symbols.array ?? [] {
                blockers.append("Функция SDK не реализована: " + Self.apiLabel(module + "." + (symbol.string ?? "")))
            }
        }
        if let sdk = report["sdk_modules"].array, let candidates = report["python_stdlib_candidates"].array {
            // Candidate modules are not a promise that every CPython API works on iOS.
            let allowed = Set((sdk + candidates).compactMap(\.string)).union(self.modules)
            for name in (report["imports"].array ?? []).compactMap(\.string) {
                let root = name.split(separator: ".").first.map(String.init) ?? name
                if ["threading", "_thread", "subprocess", "multiprocessing"].contains(root) { blockers.append("Возможности процессов и потоков не поддерживаются: " + Self.apiLabel(name)) }
                else if !allowed.contains(name) && !allowed.contains(root) && !self.classes.contains(where: { $0.hasPrefix(name + ".") }) { blockers.append("Импорт не предоставлен сборкой: " + Self.apiLabel(name)) }
            }
        }
        for requirement in report["requirements"].array ?? [] { blockers.append("Внешняя зависимость недоступна: " + Self.apiLabel(requirement.string ?? "")) }
        if !(report["warnings"].array ?? []).isEmpty { blockers.append("Инспектор обнаружил неподдерживаемые возможности Python. Подробности проверит runtime.") }
        let title = String(name.components(separatedBy: .controlCharacters).joined(separator: " ").prefix(128))
        let version = metadata["__version__"].string ?? "1.0"
        return (AyuInstalledPlugin(id: id, name: title, version: version.range(of: "^[0-9A-Za-z.+_-]{1,64}$", options: .regularExpression) != nil ? version : "—", blockers: Array(blockers.prefix(64))), report)
    }
    private func command(_ operation: String, owner: String, arguments: [String: AyuBridgeValue], bootstrap: Bool = false) async throws -> AyuBridgeValue {
        let body: AyuBridgeValue = .object(["version": .integer(1), "id": .string("1"), "plugin_id": .string(bootstrap ? "$runtime" : owner), "operation": .string(operation), "arguments": .object(arguments)])
        let request = String(decoding: try JSONEncoder().encode(body), as: UTF8.self), host = self.host
        let response = try self.decode(await Task.detached(priority: .userInitiated) { host.dispatch(request, owner: owner) }.value)
        if let code = response["error"]["code"].string { throw Failure.operation(Self.apiLabel(code)) }
        guard response["version"].number == 1 else { throw Failure.protocolError }; return response["result"]
    }
    private func complete(_ work: (@escaping @Sendable (String?, Error?) -> Void) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in work { json, error in if let json, error == nil { continuation.resume(returning: json) } else { continuation.resume(throwing: Failure.runtime) } } }
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
    private static func resource(_ bundle: String, _ directory: String) -> URL? {
        for parent in [Bundle.main, Bundle(for: APBPythonRuntime.self)] {
            if let url = parent.url(forResource: bundle, withExtension: "bundle"), let resources = Bundle(url: url)?.resourceURL?.appendingPathComponent(directory), FileManager.default.fileExists(atPath: resources.path) { return resources }
        }
        return nil
    }
}
