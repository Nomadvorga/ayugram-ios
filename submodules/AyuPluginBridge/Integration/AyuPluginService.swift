import CryptoKit
import Foundation
import UIKit
import AyuPluginPython

private final class AyuPluginResourceAnchor: NSObject {}

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
    public var author: String? = nil
    public var description: String? = nil
    public var requirements: [String]? = nil
    public var icon: String? = nil
    /// `elyx` or `eaf` when the stored bytes are a package archive; nil for a `.plugin` source.
    public var packageExtension: String? = nil
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

/// Read-only inspection of the exact bytes shown in the installation sheet.
/// Previewing does not persist, authorize or execute plugin code.
public struct AyuPluginImportPreview: Sendable {
    public let plugin: AyuInstalledPlugin
    public let author: String
    public let description: String
    public let requirements: [String]
    public let sourceSHA256: String
    public let isUpdate: Bool
    public let batchBlockers: [AyuPluginBatchBlocker]
}

@MainActor public final class AyuPluginService {
    public static let shared: AyuPluginService = {
        let application = AyuPluginApplicationBridge.shared
        let provider = AyuPluginMenuHostProvider(application: application)
        do { return AyuPluginService(provider: provider, classRegistry: try application.classRegistry()) }
        catch { preconditionFailure("Invalid compiled application adapters") }
    }()
    public static let didChange = Notification.Name("AyuPluginServiceDidChange")
    nonisolated static let groupMentionsID = "group_mentions"
    nonisolated static let groupMentionsSHA256 = "25ae71486b29481d57cc36eaf40e931522a655227d2870dfc898174b8d96f28e"
    nonisolated static let unsupportedBlocker = "Плагин требует возможности, которые ещё не реализованы в этой версии iOS-моста."
    nonisolated static let missingVersion = "—"
    /// Shown when the plugin's callback queue was full and a delivery was discarded.
    nonisolated static let deliveryOverflowMessage = "Очередь обратных вызовов плагина переполнена: часть событий отброшена. Плагин остаётся включённым."
    nonisolated public static let packageExtensions = ["elyx", "eaf"]
    public private(set) var plugins: [AyuInstalledPlugin] = []
    public private(set) var startupError: String?
    public let host: AyuPluginNativeHost
    let registry: AyuPluginRegistryBridge
    private let runtime = APBPythonRuntime()
    private let relay: AyuPluginRuntimeRelay
    private let sendHookSource: AyuPluginSendHookSource?
    private let defaults: UserDefaults
    private let root: URL
    private let batchLogRoot: URL
    private var cachedLatestBatchLogURL: URL?
    private var preparation: Task<Void, Error>?
    private var runtimePreparation: Task<Void, Error>?
    private var atmosphericAdapter: AyuAtmosphericPluginAdapter?
    private var nativeAdapters: [String: AyuNativePluginAdapter] = [:]
    private var pending: Set<String> = []
    private var pendingImportSlots = 0
    private var currentBatchID: String?
    private var classes: Set<String> = []
    private var modules: Set<String> = []
    private var pythonGenerations: [String: String] = [:]
    private var appInForeground = false
    private var appIsActive = false
    nonisolated private static let maximumBytes = 1_048_576
    nonisolated public static let maximumSourceBytes = 4_194_304
    /// The SDK's archive bound (`_ayu_packages.MAX_ARCHIVE_BYTES`).
    nonisolated public static let maximumPackageBytes = 67_108_864

    public init(defaults: UserDefaults = .standard, provider: AyuPluginHostProvider = AyuUnsupportedPluginHostProvider(), classRegistry: AyuBridgeClassRegistry = .standard, limits: AyuPluginBridgeLimits = AyuPluginBridgeLimits()) {
        let relay = AyuPluginRuntimeRelay()
        self.relay = relay; self.defaults = defaults
        let registry = AyuPluginRegistryBridge()
        self.registry = registry
        self.sendHookSource = provider as? AyuPluginSendHookSource
        self.host = AyuPluginNativeHost(defaults: defaults, provider: AyuPluginRegistryHostProvider(base: provider, registry: registry), classRegistry: classRegistry, limits: limits, trustedOwner: { nil }, callback: { owner, callback, arguments in relay.deliver(owner, callback, arguments) }, delivery: { relay.deliver($0) })
        self.root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AyuPlugins", isDirectory: true)
        self.batchLogRoot = self.root.appendingPathComponent("BatchLogs", isDirectory: true)
        relay.attach(self.runtime) { [weak self] owner, generation, problem in Task { @MainActor in
            guard let self, let generation, self.pythonGenerations[owner] == generation,
                  self.plugins.contains(where: { $0.id == owner && $0.isEnabled && !$0.isBusy }) else { return }
            switch problem {
            case .handler: self.update(owner) { $0.error = "Ошибка обработчика Python. Плагин остаётся включённым; его можно выключить." }
            case .overflow: self.update(owner) { $0.error = Self.deliveryOverflowMessage }
            }
        } }
        registry.bind(self.registryScreens())
        AyuPluginMenuBridge.shared.invokeCallback = { [weak self] owner, callbackID, arguments in
            guard let self else { return nil }
            return await self.menuCallbackResult(owner, callbackID: callbackID, arguments: arguments)
        }
        // Telegram hook answers use the same generation-checked relay as menu conditions.
        AyuPluginTelegramBridge.shared.setAnswerInvoker { [weak self] owner, callbackID, arguments, completion in
            Task { @MainActor in
                guard let self else { completion(nil); return }
                completion(await self.menuCallbackResult(owner, callbackID: callbackID, arguments: arguments))
            }
        }
    }

    public enum Failure: LocalizedError, Sendable {
        case resources, pythonResources, sdkResources, runtimeStartup, sdkStartup, runtimeQueue
        case source, identity, duplicate, storage, inactive, busy, runtime, protocolError, operation(String)
        case sourceChanged, updateRequiresDisable
        case unsupportedPlugin
        public var errorDescription: String? {
            switch self {
            case .resources: return "Не удалось найти встроенный тестовый плагин."
            case .pythonResources: return "Не найдена стандартная библиотека Python: AyuPythonResources.bundle/python."
            case .sdkResources: return "Не найден SDK плагинов: AyuPluginSDK.bundle/Python."
            case .runtimeStartup: return "Не удалось запустить встроенный Python. Перезапустите приложение; если ошибка повторится, сообщите номер сборки."
            case .sdkStartup: return "Встроенный Python не смог загрузить SDK плагинов. Сообщите номер сборки."
            case .runtimeQueue: return "Очередь Python заполнена. Дождитесь завершения текущих операций."
            case .source: return "Нужен обычный UTF-8 файл .plugin размером до 4 МиБ или пакет .elyx/.eaf размером до 64 МиБ."
            case .identity: return "Неверный идентификатор плагина или метаданные."
            case .duplicate: return "Плагин с таким идентификатором уже установлен. Сначала удалите его."
            case .sourceChanged: return "Файл изменился после просмотра. Откройте его заново перед установкой."
            case .updateRequiresDisable: return "Выключите плагин перед обновлением. Его настройки сохранятся."
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
                // Archives a previous process staged and never installed.
                try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true))
                let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return AyuPluginCapacity.boundedMetadataURLs(files).compactMap { url -> AyuInstalledPlugin? in
                    guard let data = try? Self.read(url, limit: 65_536), var record = try? JSONDecoder().decode(AyuInstalledPlugin.self, from: data), Self.validID(record.id), url.deletingPathExtension().lastPathComponent == record.id else { return nil }
                    record.isEnabled = false; record.isBusy = false; record.error = nil
                    record.nativeAdapter = nil
                    // Recheck bytes instead of trusting saved native-adapter metadata.
                    let sourceURL = root.appendingPathComponent(record.id + ".plugin")
                    if record.id == AyuAtmosphericPluginAdapter.pluginID {
                        if let source = try? Self.read(sourceURL, limit: Self.maximumSourceBytes),
                           let verified = AyuAtmosphericPluginAdapter.record(for: source) {
                            record = verified
                        } else {
                            record.nativeAdapter = nil
                            record.blockers = ["Нативный адаптер требует исходный Atmospheric Snow 1.0.1 с проверенной контрольной суммой."]
                        }
                    } else if let descriptor = AyuNativePluginCatalog.descriptor(id: record.id) {
                        if let source = try? Self.read(sourceURL, limit: Self.maximumSourceBytes),
                           let verified = descriptor.record(for: source) {
                            record = verified
                        } else {
                            record.nativeAdapter = nil
                            record.blockers = [AyuNativePluginCatalog.blocker(for: record.id)]
                        }
                    } else if let packageExtension = record.packageExtension {
                        // The archive is inspected by Python at explicit enable, never here.
                        record.nativeAdapter = nil
                        let archive = root.appendingPathComponent(record.id + "." + packageExtension)
                        record.blockers = Self.packageExtensions.contains(packageExtension) && (try? Self.requireRegularFile(archive)) != nil
                            ? [] : ["Архив пакета недоступен."]
                    } else {
                        record.nativeAdapter = nil
                        record.blockers = []
                        if let source = try? Self.read(sourceURL, limit: Self.maximumSourceBytes),
                           String(data: source, encoding: .utf8) != nil {
                            if let verified = Self.pinnedPythonRecord(for: source) { record = verified }
                        } else {
                            record.blockers = ["Исходник недоступен или не является допустимым UTF-8 файлом .plugin."]
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

    public func previewPlugin(from url: URL) async throws -> AyuPluginImportPreview {
        try await self.prepare()
        let source = try await Self.importSource(from: url, root: self.root)
        defer { Self.discard(source) }
        let (record, report) = try await self.inspect(source)
        let metadata = report["metadata"]
        return AyuPluginImportPreview(plugin: record,
            author: record.author ?? String((metadata["__author__"].string ?? "").prefix(256)),
            description: record.description ?? String((metadata["__description__"].string ?? "").prefix(8192)),
            requirements: record.requirements ?? [],
            sourceSHA256: source.sha256,
            isUpdate: self.plugins.contains(where: { $0.id == record.id }),
            batchBlockers: Self.batchBlockers(record: record, report: report))
    }

    /// Re-inspects the selected bytes before committing. Updating preserves the
    /// existing settings namespace and always leaves the new version disabled.
    public func importPlugin(from url: URL, replacingExisting: Bool = false, expectedSHA256: String? = nil) async throws {
        try await self.prepare()
        guard AyuPluginCapacity.canReserveImport(installed: self.plugins.count, pending: self.pendingImportSlots, replacingExisting: replacingExisting) else { throw Failure.operation("RESOURCE_LIMIT") }
        self.pendingImportSlots += 1
        defer { self.pendingImportSlots -= 1 }
        let source = try await Self.importSource(from: url, root: self.root)
        defer { Self.discard(source) }
        if let expectedSHA256, source.sha256 != expectedSHA256 { throw Failure.sourceChanged }
        let (record, _) = try await self.inspect(source)
        if let existing = self.plugins.first(where: { $0.id == record.id }) {
            guard replacingExisting else { throw Failure.duplicate }
            guard !existing.isBusy else { throw Failure.busy }
            guard !existing.isEnabled else { throw Failure.updateRequiresDisable }
        } else {
            guard !replacingExisting else { throw Failure.identity }
            guard AyuPluginCapacity.canImport(installed: self.plugins.count, reserved: self.pendingImportSlots) else { throw Failure.operation("RESOURCE_LIMIT") }
        }
        guard self.pending.insert(record.id).inserted else { throw Failure.busy }
        defer { self.pending.remove(record.id) }
        if self.plugins.contains(where: { $0.id == record.id }) { try self.begin(record.id) }
        defer { self.finish(record.id) }
        let root = self.root
        do {
            try await Task.detached(priority: .utility) {
                try Self.store(source, record: record, root: root, replacingExisting: replacingExisting)
            }.value
        } catch { throw (error as? Failure) ?? Failure.storage }
        if let index = self.plugins.firstIndex(where: { $0.id == record.id }) {
            self.plugins[index] = record
        } else { self.plugins.append(record) }
        self.plugins.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.changed()
    }

    /// Bytes selected for import, or the stored bytes of an installed plugin. A selected package is
    /// first copied into the store's staging directory, so the archive that was hashed and inspected
    /// is the file that gets installed.
    private enum ImportedSource: Sendable {
        case plugin(String)
        case package(archive: URL, fileExtension: String, sha256: String)
        var sha256: String {
            switch self {
            case let .plugin(source): return AyuPluginService.digest(source)
            case let .package(_, _, sha256): return sha256
            }
        }
    }

    nonisolated private static let stagingDirectoryName = "Staging"

    nonisolated private static func importSource(from url: URL, root: URL) async throws -> ImportedSource {
        try await Task.detached(priority: .utility) {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let fileExtension = url.pathExtension.lowercased()
            if Self.packageExtensions.contains(fileExtension) {
                let staged = try Self.stagePackage(url, fileExtension: fileExtension, root: root)
                return .package(archive: staged.url, fileExtension: fileExtension, sha256: staged.sha256)
            }
            guard fileExtension == "plugin",
                  let source = String(data: try Self.read(url, limit: Self.maximumSourceBytes), encoding: .utf8) else { throw Failure.source }
            return .plugin(source)
        }.value
    }

    /// Removes a staged archive that was not installed. An installed one has already been moved away.
    nonisolated private static func discard(_ source: ImportedSource) {
        guard case let .package(archive, _, _) = source else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: archive) }
    }

    nonisolated private static func stagingDirectory(_ root: URL) throws -> URL {
        let staging = root.appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        guard try staging.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw Failure.storage }
        return staging
    }

    /// Streams one regular file of at most 64 MiB into the staging directory and hashes what was written.
    nonisolated private static func stagePackage(_ url: URL, fileExtension: String, root: URL) throws -> (url: URL, sha256: String) {
        try Self.requireRegularFile(url)
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: url) } catch { throw Failure.source }
        defer { try? input.close() }
        let destination: URL, output: FileHandle
        do {
            destination = try Self.stagingDirectory(root).appendingPathComponent(UUID().uuidString.lowercased() + "." + fileExtension)
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw Failure.storage }
            output = try FileHandle(forWritingTo: destination)
        } catch { throw Failure.storage }
        do {
            var hasher = SHA256(), total = 0
            while true {
                let chunk: Data
                do { chunk = try input.read(upToCount: 1_048_576) ?? Data() } catch { throw Failure.source }
                if chunk.isEmpty { break }
                total += chunk.count
                guard total <= Self.maximumPackageBytes else { throw Failure.source }
                hasher.update(data: chunk)
                do { try output.write(contentsOf: chunk) } catch { throw Failure.storage }
            }
            guard total > 0 else { throw Failure.source }
            do { try output.close() } catch { throw Failure.storage }
            return (destination, hasher.finalize().map { String(format: "%02x", $0) }.joined())
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// SHA-256 of a stored archive, read in pieces.
    nonisolated private static func packageDigest(_ url: URL) throws -> String {
        try Self.requireRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256(), total = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            total += chunk.count
            guard total <= Self.maximumPackageBytes else { throw Failure.source }
            hasher.update(data: chunk)
        }
        guard total > 0 else { throw Failure.source }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Replaces one plugin's stored bytes and metadata. A failed step restores the previous version,
    /// and settings are never touched here. The previous bytes are set aside by rename, so an
    /// archive is never held in memory.
    nonisolated private static func store(_ source: ImportedSource, record: AyuInstalledPlugin, root: URL, replacingExisting: Bool) throws {
        let manager = FileManager.default
        let metadataURL = root.appendingPathComponent(record.id + ".json")
        let stored = (["plugin"] + Self.packageExtensions).map { root.appendingPathComponent(record.id + "." + $0) }
            .filter { manager.fileExists(atPath: $0.path) }
        var previous: (url: URL, parked: URL, metadata: Data)?
        if replacingExisting {
            guard stored.count == 1 else { throw Failure.storage }
            try Self.requireRegularFile(stored[0])
            let parked = try Self.stagingDirectory(root).appendingPathComponent(UUID().uuidString.lowercased() + ".previous")
            previous = (stored[0], parked, try Self.read(metadataURL, limit: 65_536))
        } else {
            guard stored.isEmpty, !manager.fileExists(atPath: metadataURL.path) else { throw Failure.duplicate }
        }
        let metadata = try JSONEncoder().encode(record)
        guard metadata.count <= 65_536 else { throw Failure.operation("METADATA_QUOTA") }
        let target = root.appendingPathComponent(record.id + "." + (record.packageExtension ?? "plugin"))
        if let previous { try manager.moveItem(at: previous.url, to: previous.parked) }
        do {
            switch source {
            case let .plugin(text): try Data(text.utf8).write(to: target, options: .atomic)
            case let .package(archive, _, _): try manager.moveItem(at: archive, to: target)
            }
            try metadata.write(to: metadataURL, options: .atomic)
        } catch {
            try? manager.removeItem(at: target)
            if let previous {
                try manager.moveItem(at: previous.parked, to: previous.url)
                try previous.metadata.write(to: metadataURL, options: .atomic)
            }
            throw Failure.storage
        }
        if let previous { try? manager.removeItem(at: previous.parked) }
    }

    /// `<Application Support>/AyuPluginFiles/plugins/ElyxPlugins/<id>`, where the SDK unpacks a package.
    /// A link in place of one of the directories is left alone and reported.
    nonisolated private static func removeUnpackedPackage(_ id: String) throws {
        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for component in ["AyuPluginFiles", "plugins", "ElyxPlugins"] {
            directory.appendPathComponent(component, isDirectory: true)
            guard let flags = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
            guard flags.isDirectory == true, flags.isSymbolicLink != true else { throw Failure.storage }
        }
        let unpacked = directory.appendingPathComponent(id, isDirectory: true)
        guard (try? unpacked.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil else { return }
        try FileManager.default.removeItem(at: unpacked)
    }

    nonisolated private static func requireRegularFile(_ url: URL) throws {
        guard let flags = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              flags.isRegularFile == true, flags.isSymbolicLink != true else { throw Failure.source }
    }

    nonisolated private static func digest(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Call only after the user explicitly trusts this installed plugin for this process.
    public func enable(_ id: String) async throws { _ = try await self.enable(id, phaseReporter: { _, _ in }) }

    private func enable(_ id: String, phaseReporter: AyuPluginBatchRunner.PhaseReporter) async throws -> AyuPluginBatchLoadContext {
        try await self.prepare()
        if self.plugins.contains(where: { $0.id == id && $0.isEnabled && !$0.isBusy }) {
            return AyuPluginBatchLoadContext(sourceSHA256: nil, pluginVersion: nil, blockers: [])
        }
        try self.begin(id)
        defer { self.finish(id) }
        let packageExtension = self.plugins.first(where: { $0.id == id })?.packageExtension
        let url = self.root.appendingPathComponent(id + "." + (packageExtension ?? "plugin"))
        do {
            try await phaseReporter(.readSource, nil)
            let source: ImportedSource = try await Task.detached(priority: .utility) {
                if let packageExtension {
                    guard Self.packageExtensions.contains(packageExtension) else { throw Failure.source }
                    return .package(archive: url, fileExtension: packageExtension, sha256: try Self.packageDigest(url))
                }
                guard let text = String(data: try Self.read(url, limit: Self.maximumSourceBytes), encoding: .utf8) else { throw Failure.source }
                return .plugin(text)
            }.value
            let sourceSHA256 = source.sha256
            var context = AyuPluginBatchLoadContext(sourceSHA256: sourceSHA256, pluginVersion: nil, blockers: [])
            try await phaseReporter(.inspect, context)
            let (inspection, report) = try await self.inspect(source)
            let blockers = Self.batchBlockers(record: inspection, report: report)
            context = AyuPluginBatchLoadContext(sourceSHA256: sourceSHA256, pluginVersion: inspection.version,
                blockers: !inspection.blockers.isEmpty && blockers.isEmpty
                    ? [AyuPluginBatchBlocker.sanitized(code: "ADAPTER_SOURCE", identifier: "source_pin")!]
                    : blockers)
            try await phaseReporter(.inspect, context)
            guard inspection.id == id else { throw Failure.identity }
            self.update(id) { $0.blockers = inspection.blockers; $0.error = nil; $0.nativeAdapter = inspection.nativeAdapter }
            guard inspection.blockers.isEmpty else { throw Failure.operation("UNSUPPORTED_API") }
            if inspection.nativeAdapter == AyuAtmosphericPluginAdapter.adapterID {
                try await phaseReporter(.nativeEnable, context)
                let adapter = AyuAtmosphericPluginAdapter(defaults: self.defaults, reportError: { [weak self] message in
                    self?.update(id) { $0.error = message }
                })
                try adapter.enable()
                self.atmosphericAdapter = adapter
                self.update(id) { $0.isEnabled = true; $0.nativeAdapter = inspection.nativeAdapter }
                return context
            }
            if let descriptor = AyuNativePluginCatalog.descriptor(id: id), inspection.nativeAdapter == descriptor.adapterID {
                try await phaseReporter(.nativeEnable, context)
                let adapter = descriptor.make(self.defaults, AyuNativePluginReporter { [weak self] message in
                    self?.update(id) { $0.error = message }
                })
                if case let .plugin(source) = source { adapter.verifiedSource = source }
                try adapter.enable()
                self.nativeAdapters[id] = adapter
                self.update(id) { $0.isEnabled = true; $0.nativeAdapter = inspection.nativeAdapter }
                return context
            }
            try await phaseReporter(.runtimePrepare, context)
            try await self.prepareRuntime()
            try await phaseReporter(.runtimeLoad, context)
            let loaded: AyuBridgeValue
            switch source {
            case let .plugin(source):
                let json = try await self.complete { self.runtime.load(source: source, filename: id + ".plugin", completion: $0) }
                loaded = try self.decode(json)
            case let .package(archive, fileExtension, _):
                let json = try await self.complete { self.runtime.loadPackage(path: archive.path, filename: id + "." + fileExtension, completion: $0) }
                loaded = try self.decode(json)
            }
            guard loaded["plugin_id"].string == id, let generation = loaded["generation"].string,
                  generation.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else { throw Failure.protocolError }
            self.pythonGenerations[id] = generation
            self.update(id) { $0.isEnabled = true }
            self.relay.event(id, generation: generation, name: "START")
            if self.appIsActive { self.relay.event(id, generation: generation, name: "RESUME") }
            return context
        } catch {
            try? await phaseReporter(.cleanup, nil)
            self.pythonGenerations.removeValue(forKey: id)
            // Also handle a successful load followed by a malformed result: revoke both layers.
            if id == AyuAtmosphericPluginAdapter.pluginID {
                self.atmosphericAdapter?.disable(); self.atmosphericAdapter = nil
            }
            self.nativeAdapters.removeValue(forKey: id)?.disable()
            self.relay.cancel(id)
            if self.runtimePreparation != nil { _ = try? await self.complete { self.runtime.unload(pluginID: id, completion: $0) } }
            await self.detach(id); self.relay.cancel(id); self.update(id) { $0.isEnabled = false; $0.error = self.message(error) }; throw error
        }
    }

    /// Batch consent is supplied by the manager. Plugin owners still pass through
    /// the normal begin/finish and generation cleanup paths one at a time.
    public func enableBatch(_ ids: [String], isCancelled: @escaping @MainActor () -> Bool = { false },
                            progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async throws -> AyuPluginBatchSummary {
        try await self.prepare()
        guard self.currentBatchID == nil else { throw Failure.busy }
        let batchID = UUID().uuidString.lowercased()
        self.currentBatchID = batchID
        defer { self.currentBatchID = nil }
        let journal = AyuPluginBatchJournal(root: self.batchLogRoot, sourceRoot: self.root, batchID: batchID)
        self.cachedLatestBatchLogURL = journal.url
        let summary = try await AyuPluginBatchRunner.run(ids: ids, journal: journal,
            isEnabled: { id in self.plugins.contains(where: { $0.id == id && $0.isEnabled }) },
            isCancelled: isCancelled,
            pluginName: { id in self.plugins.first(where: { $0.id == id })?.name ?? "[redacted]" },
            diagnostic: Self.batchDiagnostic,
            progress: progress,
            enable: { id, report in
                let context = try await self.enable(id, phaseReporter: report)
                return AyuPluginBatchLoadResult(generation: self.pythonGenerations[id], context: context)
            })
        return summary
    }

    /// Application Support path for the most recent report. Directory metadata
    /// is enumerated on a utility executor and cached by the manager.
    public func latestBatchLog() async throws -> URL? {
        let root = self.batchLogRoot
        if let cachedLatestBatchLogURL {
            let isReadable = await Task.detached(priority: .utility) {
                (try? AyuPluginBatchJournal.readReport(at: cachedLatestBatchLogURL, within: root)) != nil
            }.value
            return isReadable ? cachedLatestBatchLogURL : nil
        }
        let latest = try await Task.detached(priority: .utility) { try AyuPluginBatchJournal.latestReport(in: root) }.value
        self.cachedLatestBatchLogURL = latest
        return latest
    }
    /// Opens only a validated generated report inside the private log directory.
    public func batchLogData(at url: URL) async throws -> Data {
        let root = self.batchLogRoot
        return try await Task.detached(priority: .utility) { try AyuPluginBatchJournal.readReport(at: url, within: root) }.value
    }

    /// Multi-file import performs static inspection and hash-verified installs
    /// sequentially. It never enables a plugin; trust is a separate later action.
    public func importBatch(from urls: [URL], isCancelled: @escaping @MainActor () -> Bool = { false },
                            progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async throws -> AyuPluginBatchSummary {
        guard !urls.isEmpty, urls.count <= AyuPluginCapacity.maximumInstalledPlugins else { throw Failure.operation("RESOURCE_LIMIT") }
        try await self.prepare()
        guard self.currentBatchID == nil else { throw Failure.busy }
        let batchID = UUID().uuidString.lowercased()
        self.currentBatchID = batchID
        defer { self.currentBatchID = nil }
        let journal = AyuPluginBatchJournal(root: self.batchLogRoot, sourceRoot: self.root, batchID: batchID)
        self.cachedLatestBatchLogURL = journal.url
        let started = ProcessInfo.processInfo.systemUptime
        var summary = AyuPluginBatchSummary(batchID: batchID, requested: urls.count, logPath: journal.url.lastPathComponent)
        try await journal.open()
        try await journal.append(phase: .batch, result: "import_started", totals: summary)
        var logFailed = false
        for (index, url) in urls.enumerated() {
            let fileName = Self.safeImportFileName(url)
            if Task.isCancelled || isCancelled() {
                summary.cancelled += 1
                do { try await journal.append(fileName: fileName, phase: .readSource, result: "cancelled", diagnostic: .cancelled, fileIndex: index + 1) }
                catch { logFailed = true }
                progress(index + 1, urls.count)
                continue
            }
            let itemStarted = ProcessInfo.processInfo.systemUptime
            var phase = AyuPluginBatchPhase.readSource
            var pluginID: String?
            var pluginName: String?
            var context: AyuPluginBatchLoadContext?
            do {
                try await journal.append(fileName: fileName, phase: phase, result: "started", fileIndex: index + 1)
                phase = .inspect
                let preview = try await self.previewPlugin(from: url)
                pluginID = preview.plugin.id
                pluginName = preview.plugin.name
                context = AyuPluginBatchLoadContext(sourceSHA256: preview.sourceSHA256,
                    pluginVersion: preview.plugin.version, blockers: preview.batchBlockers)
                try await journal.append(pluginID: pluginID, pluginName: pluginName, fileName: fileName,
                    phase: .inspect, result: "validated_disabled", context: context, fileIndex: index + 1)
                phase = .importPlugin
                try await journal.append(pluginID: pluginID, pluginName: pluginName, fileName: fileName,
                    phase: phase, result: "started", context: context, fileIndex: index + 1)
                // Existing IDs fail closed rather than being replaced by a batch.
                try await self.importPlugin(from: url, replacingExisting: false, expectedSHA256: preview.sourceSHA256)
                summary.succeeded += 1
                do {
                    try await journal.append(pluginID: pluginID, pluginName: pluginName, fileName: fileName,
                        phase: phase, result: "installed_disabled", durationMilliseconds: Self.elapsedMilliseconds(since: itemStarted),
                        context: context, fileIndex: index + 1)
                } catch { logFailed = true }
            } catch {
                let skipped: Bool
                if let failure = error as? Failure {
                    switch failure {
                    case .duplicate, .updateRequiresDisable: skipped = true
                    default: skipped = false
                    }
                } else {
                    skipped = false
                }
                if skipped { summary.skipped += 1 } else { summary.failed += 1 }
                do { try await journal.append(pluginID: pluginID, pluginName: pluginName, fileName: fileName,
                    phase: phase, result: skipped ? "skipped" : "failed", diagnostic: Self.batchDiagnostic(error),
                    durationMilliseconds: Self.elapsedMilliseconds(since: itemStarted), context: context, fileIndex: index + 1) }
                catch { logFailed = true }
            }
            progress(index + 1, urls.count)
        }
        summary.durationMilliseconds = Self.elapsedMilliseconds(since: started)
        try await journal.append(phase: .summary, result: logFailed ? "log_incomplete" : (summary.cancelled > 0 ? "cancelled" : "import_completed"),
            diagnostic: logFailed ? .storage : nil, durationMilliseconds: summary.durationMilliseconds, totals: summary)
        if logFailed { throw Failure.storage }
        return summary
    }

    nonisolated private static let maximumPendingImports = AyuPluginCapacity.maximumInstalledPlugins

    private nonisolated static func batchDiagnostic(_ error: Error) -> AyuPluginBatchDiagnostic {
        guard let failure = error as? Failure else { return .runtime }
        switch failure {
        case .resources: return .resources
        case .pythonResources: return .pythonResources
        case .sdkResources: return .sdkResources
        case .runtimeStartup: return .runtimeStartup
        case .sdkStartup: return .sdkStartup
        case .runtimeQueue: return .runtimeQueue
        case .source: return .source
        case .identity: return .identity
        case .duplicate: return .duplicate
        case .storage: return .storage
        case .inactive: return .inactive
        case .busy: return .busy
        case .runtime: return .runtime
        case .protocolError: return .protocolError
        case .sourceChanged: return .sourceChanged
        case .updateRequiresDisable: return .updateRequiresDisable
        case .unsupportedPlugin: return .unsupported
        case let .operation(code): return .operation(code)
        }
    }

    private static func batchBlockers(record: AyuInstalledPlugin, report: AyuBridgeValue) -> [AyuPluginBatchBlocker] {
        var safe: [AyuPluginBatchBlocker] = []
        for finding in (report["blockers"].array ?? []).prefix(32) {
            guard let blocker = AyuPluginBatchBlocker.sanitized(code: finding["code"].string, identifier: finding["detail"].string) else { continue }
            if !safe.contains(blocker) { safe.append(blocker) }
        }
        if !record.blockers.isEmpty && safe.isEmpty {
            let isVersionPolicy = record.blockers.contains { $0.hasPrefix("VERSION_POLICY:") }
            let fallback = AyuPluginBatchBlocker.sanitized(code: isVersionPolicy ? "VERSION_POLICY" : "ADAPTER_SOURCE",
                identifier: isVersionPolicy ? "app_version" : "source_pin")
            if let fallback { safe.append(fallback) }
        }
        return safe
    }

    private static func safeImportFileName(_ url: URL) -> String {
        let basename = url.lastPathComponent
        return String(basename.unicodeScalars.filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-.()")).contains($0) }.prefix(80))
    }

    private static func elapsedMilliseconds(since started: TimeInterval) -> Int {
        Int(max(0, ProcessInfo.processInfo.systemUptime - started) * 1000)
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
        // Deliveries still queued for this generation never reach the interpreter.
        self.relay.cancel(id)
        if self.plugins.first(where: { $0.id == id })?.isEnabled == true {
            do { _ = try await self.complete { self.runtime.unload(pluginID: id, completion: $0) } } catch { failure = error }
        }
        await self.detach(id)
        self.relay.cancel(id)
        self.update(id) { $0.isEnabled = false; $0.error = failure.map(self.message) }
        if let failure { throw failure }
    }

    public func delete(_ id: String) async throws {
        guard Self.validID(id) else { throw Failure.identity }
        if self.plugins.first(where: { $0.id == id })?.isEnabled == true { try await self.disable(id) }
        try self.begin(id); defer { self.finish(id) }
        let root = self.root
        do { try await Task.detached(priority: .utility) {
            try Self.removeUnpackedPackage(id)
            for ext in Self.packageExtensions { let path = root.appendingPathComponent(id + "." + ext); if FileManager.default.fileExists(atPath: path.path) { try Self.requireRegularFile(path); try FileManager.default.removeItem(at: path) } }
            for ext in ["plugin", "json"] { let path = root.appendingPathComponent(id + "." + ext); if FileManager.default.fileExists(atPath: path.path) { _ = try Self.read(path, limit: ext == "plugin" ? Self.maximumSourceBytes : 65_536); try FileManager.default.removeItem(at: path) } }
        }.value }
        catch { throw Failure.storage }
        self.defaults.removeObject(forKey: "AyuPluginBridge.v1." + id)
        self.plugins.removeAll { $0.id == id }; self.changed()
    }

    /// A private copy of the stored file for the share sheet, named `<id>.<extension>`. Only the
    /// stored bytes are read; the caller removes the copy's directory when the sheet closes.
    public func exportCopy(_ id: String) async throws -> URL {
        guard Self.validID(id), let plugin = self.plugins.first(where: { $0.id == id }) else { throw Failure.identity }
        guard !plugin.isBusy else { throw Failure.busy }
        let fileExtension = plugin.packageExtension ?? "plugin"
        guard fileExtension == "plugin" || Self.packageExtensions.contains(fileExtension) else { throw Failure.source }
        let stored = self.root.appendingPathComponent(id + "." + fileExtension)
        do {
            return try await Task.detached(priority: .utility) {
                try Self.requireRegularFile(stored)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AyuPluginShare-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let copy = directory.appendingPathComponent(stored.lastPathComponent)
                do { try FileManager.default.copyItem(at: stored, to: copy) }
                catch { try? FileManager.default.removeItem(at: directory); throw error }
                return copy
            }.value
        } catch { throw (error as? Failure) ?? Failure.storage }
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

    /// Settings UI drops queued notifications from a previous activation.
    func shouldReloadSettings(pluginID: String, generation: String) -> Bool {
        self.pythonGenerations[pluginID] == generation &&
            self.plugins.contains(where: { $0.id == pluginID && $0.isEnabled && !$0.isBusy })
    }

    /// `plugins.settings` reload: the open settings screens of this plugin serialize its rows again.
    func reloadSettings(pluginID: String) {
        guard let generation = self.pythonGenerations[pluginID], self.shouldReloadSettings(pluginID: pluginID, generation: generation) else { return }
        NotificationCenter.default.post(name: AyuPluginNativeHost.settingsDidChange, object: self.host,
            userInfo: ["pluginID": pluginID, "generation": generation])
    }

    /// One callback round trip. `relay.invoke` may complete on the Python
    /// thread, so the result is handed back through a continuation and the
    /// caller stays on its own executor.
    private func sendHookResult(_ owner: String, _ callback: String, _ arguments: [AyuBridgeValue]) async -> AyuBridgeValue? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AyuBridgeValue?, Never>) in
            self.relay.invoke(owner, callback, arguments) { json, error in
                guard error == nil, let json, json.utf8.count <= Self.maximumBytes,
                      let decoded = try? AyuBridgeJSON.decode(Data(json.utf8)) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: decoded)
            }
        }
    }

    /// Menu conditions and clicks use the same generation gate as send hooks;
    /// Python is invoked only through the serialized runtime relay, never on UI.
    private func menuCallbackResult(_ owner: String, callbackID: String, arguments: [AyuBridgeValue]) async -> AyuBridgeValue? {
        guard let generation = self.pythonGenerations[owner], callbackID.hasPrefix(generation + ":"),
              self.plugins.contains(where: { $0.id == owner && $0.isEnabled && !$0.isBusy }) else { return nil }
        let result = await self.sendHookResult(owner, callbackID, arguments)
        guard self.pythonGenerations[owner] == generation,
              self.plugins.contains(where: { $0.id == owner && $0.isEnabled && !$0.isBusy }) else { return nil }
        return result
    }

    /// Runs the original plugin `on_send_message_hook` chain before enqueueing.
    /// A plugin result with CANCEL suppresses the send; MODIFY/MODIFY_FINAL
    /// replaces the mutable `message`/`caption` fields. Completion is on main.
    public func applySendHooks(message: String?, caption: String?, peerID: Int64, accountIndex: Int64, completion: @escaping @MainActor (String?, String?, Bool) -> Void) {
        let hooks = self.sendHookSource?.sendHooks() ?? []
        guard !hooks.isEmpty else { completion(message, caption, false); return }
        Task { @MainActor in
            var chain = AyuBridgeSendHookChain(message: message, caption: caption, peerID: peerID, accountIndex: accountIndex)
            for hook in hooks {
                guard !chain.isFinished else { break }
                // A snapshot may outlive a disable/update while awaiting Python.
                guard let generation = self.pythonGenerations[hook.pluginID],
                      hook.callbackID.hasPrefix(generation + ":"),
                      self.plugins.contains(where: { $0.id == hook.pluginID && $0.isEnabled && !$0.isBusy }) else { continue }
                let result = await self.sendHookResult(hook.pluginID, hook.callbackID, chain.arguments)
                guard self.pythonGenerations[hook.pluginID] == generation,
                      self.plugins.contains(where: { $0.id == hook.pluginID && $0.isEnabled && !$0.isBusy }) else { continue }
                chain.apply(result)
            }
            completion(chain.message, chain.caption, chain.isCancelled)
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

    private func inspect(_ source: String) async throws -> (AyuInstalledPlugin, AyuBridgeValue) {
        let data = Data(source.utf8)
        if let record = AyuAtmosphericPluginAdapter.record(for: data) { return (record, .object([:])) }
        if let record = AyuNativePluginCatalog.record(for: data) { return (record, .object([:])) }
        if let record = Self.pinnedPythonRecord(for: data) { return (record, .object([:])) }
        try await self.prepareRuntime()
        let json = try await self.complete { self.runtime.preflight(source: source, filename: "import.plugin", completion: $0) }
        let report = try self.decode(json)
        return (try self.record(from: report), report)
    }

    private func inspect(_ source: ImportedSource) async throws -> (AyuInstalledPlugin, AyuBridgeValue) {
        switch source {
        case let .plugin(text): return try await self.inspect(text)
        case let .package(archive, fileExtension, _): return try await self.inspectPackage(at: archive, fileExtension: fileExtension)
        }
    }

    /// Static package preflight on the interpreter worker: nothing is authorized, unpacked or executed.
    private func inspectPackage(at archive: URL, fileExtension: String) async throws -> (AyuInstalledPlugin, AyuBridgeValue) {
        try await self.prepareRuntime()
        let json = try await self.complete { self.runtime.preflightPackage(path: archive.path, filename: "import." + fileExtension, completion: $0) }
        let report = try self.decode(json)
        guard report["package"] == .bool(true) else { throw Failure.protocolError }
        var record = try self.record(from: report)
        record.packageExtension = fileExtension
        return (record, report)
    }

    /// The installed-plugin record of a preflight report, with its blockers.
    private func record(from report: AyuBridgeValue) throws -> AyuInstalledPlugin {
        let metadata = report["metadata"]
        guard let id = metadata["__id__"].string, Self.validID(id),
              let name = metadata["__name__"].string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 1024, let findings = report["blockers"].array else { throw Failure.protocolError }
        let version = metadata["__version__"].string ?? Self.missingVersion
        guard version.utf8.count <= 128 else { throw Failure.source }
        var blockers: [String] = []
        for finding in findings.prefix(64) {
            guard let code = finding["code"].string, let detail = finding["detail"].string else { throw Failure.protocolError }
            blockers.append("\(Self.apiLabel(code)): \(String(detail.prefix(160)))")
        }
        if id == AyuAtmosphericPluginAdapter.pluginID {
            blockers.append("Нативный адаптер требует исходный Atmospheric Snow 1.0.1 с проверенной контрольной суммой.")
        } else if AyuNativePluginCatalog.descriptor(id: id) != nil {
            blockers.append(AyuNativePluginCatalog.blocker(for: id))
        }
        var record = AyuInstalledPlugin(id: id, name: name, version: version, blockers: blockers, nativeAdapter: nil)
        record.author = String((metadata["__author__"].string ?? "").prefix(256))
        record.description = String((metadata["__description__"].string ?? "").prefix(8192))
        record.requirements = (report["requirements"].array ?? []).prefix(64).compactMap { $0.string.map { String($0.prefix(256)) } }
        record.icon = metadata["__icon__"].string.flatMap { $0.isEmpty || $0.utf8.count > 256 ? nil : $0 }
        return record
    }

    nonisolated private static func pinnedPythonRecord(for source: Data) -> AyuInstalledPlugin? {
        guard source.count <= self.maximumBytes else { return nil }
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        guard digest == self.groupMentionsSHA256 else { return nil }
        return AyuInstalledPlugin(id: self.groupMentionsID, name: "Group Mentions", version: "1.2", blockers: [], nativeAdapter: nil)
    }

    private func command(_ operation: String, owner: String, arguments: [String: AyuBridgeValue], bootstrap: Bool = false) async throws -> AyuBridgeValue {
        let body: AyuBridgeValue = .object(["version": .integer(1), "id": .string("1"), "plugin_id": .string(bootstrap ? "$runtime" : owner), "operation": .string(operation), "arguments": .object(arguments)])
        let request = String(decoding: try AyuBridgeJSON.encode(body), as: UTF8.self), host = self.host
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
    private func decode(_ json: String) throws -> AyuBridgeValue { guard json.utf8.count <= Self.maximumBytes else { throw Failure.protocolError }; do { return try AyuBridgeJSON.decode(Data(json.utf8)) } catch { throw Failure.protocolError } }
    private func begin(_ id: String) throws { guard Self.validID(id), let row = self.plugins.first(where: { $0.id == id }) else { throw Failure.identity }; guard !row.isBusy else { throw Failure.busy }; self.update(id) { $0.isBusy = true; $0.error = nil } }
    private func finish(_ id: String) { self.update(id) { $0.isBusy = false } }
    private func update(_ id: String, _ change: (inout AyuInstalledPlugin) -> Void) { if let index = self.plugins.firstIndex(where: { $0.id == id }) { change(&self.plugins[index]); self.changed() } }
    private func changed() {
        self.registry.update(self.plugins.map(AyuPluginRegistryRecord.init))
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
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
