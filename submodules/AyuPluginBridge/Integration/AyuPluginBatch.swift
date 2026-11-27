import Foundation

/// Shared inventory, import and selection bound. Source and bridge quotas remain independent.
public enum AyuPluginCapacity {
    public static let maximumInstalledPlugins = 500

    public static func canImport(installed: Int, reserved: Int) -> Bool {
        installed >= 0 && reserved > 0 && reserved <= maximumInstalledPlugins && installed <= maximumInstalledPlugins - reserved
    }

    public static func canReserveImport(installed: Int, pending: Int, replacingExisting: Bool = false) -> Bool {
        guard installed >= 0, installed <= maximumInstalledPlugins,
              pending >= 0, pending <= maximumInstalledPlugins else { return false }
        return replacingExisting || installed + pending <= maximumInstalledPlugins
    }

    static func boundedMetadataURLs(_ urls: [URL]) -> [URL] {
        urls.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(maximumInstalledPlugins)
            .map { $0 }
    }
}

public struct AyuPluginBatchSummary: Codable, Sendable {
    public let batchID: String
    public let requested: Int
    public var succeeded = 0
    public var failed = 0
    public var skipped = 0
    public var cancelled = 0
    public var durationMilliseconds = 0
    public let logPath: String
}

/// Safe static-preflight evidence. `identifier` is retained only when it is a
/// grammar-checked class/module/member token; raw finding detail is discarded.
public struct AyuPluginBatchBlocker: Codable, Sendable, Equatable {
    public let code: String
    public let identifier: String?
    public init(code: String, identifier: String?) {
        self.code = code; self.identifier = identifier
    }

    static func sanitized(code: String?, identifier: String?) -> AyuPluginBatchBlocker? {
        let knownCodes: Set<String> = ["SDK_MEMBER", "IMPORT", "CLASS", "DEPENDENCY", "REQUIREMENT", "OPERATION", "ADAPTER_SOURCE", "VERSION_POLICY"]
        guard let code, knownCodes.contains(code) else { return nil }
        let safeIdentifier = identifier.flatMap {
            $0.utf8.count <= 192 && $0.range(of: "\\A[A-Za-z_][A-Za-z0-9_.$]*\\z", options: .regularExpression) != nil ? $0 : nil
        }
        return AyuPluginBatchBlocker(code: code, identifier: safeIdentifier)
    }
}

struct AyuPluginBatchLoadContext: Sendable {
    let sourceSHA256: String?
    let pluginVersion: String?
    let blockers: [AyuPluginBatchBlocker]
}

struct AyuPluginBatchLoadResult: Sendable {
    let generation: String?
    let context: AyuPluginBatchLoadContext
}

struct AyuPluginBatchFailure: Error, Sendable {
    let diagnostic: AyuPluginBatchDiagnostic
    let phase: AyuPluginBatchPhase
    let context: AyuPluginBatchLoadContext?
}

/// A closed diagnostic vocabulary: no exception text, plugin source, settings,
/// author/description, URLs, or plugin-provided operation strings enter the log.
enum AyuPluginBatchDiagnostic: Sendable {
    case resources, pythonResources, sdkResources, runtimeStartup, sdkStartup, runtimeQueue
    case source, identity, duplicate, storage, inactive, busy, runtime, protocolError
    case sourceChanged, updateRequiresDisable, unsupported, operation(String), cancelled

    private static let knownOperationCodes: Set<String> = [
        "UNSUPPORTED_API", "RESOURCE_LIMIT", "METADATA_QUOTA", "LOG_QUOTA", "SETTING_VALUE_TOO_LARGE",
        "INVALID_ARGUMENTS", "INVALID_STATE", "SCREEN_UNAVAILABLE", "CALLBACK_EXPIRED", "CALLBACK_REF"
    ]

    var code: String {
        switch self {
        case .resources: return "RESOURCES"
        case .pythonResources: return "PYTHON_RESOURCES"
        case .sdkResources: return "SDK_RESOURCES"
        case .runtimeStartup: return "RUNTIME_STARTUP"
        case .sdkStartup: return "SDK_STARTUP"
        case .runtimeQueue: return "RUNTIME_QUEUE"
        case .source: return "SOURCE"
        case .identity: return "IDENTITY"
        case .duplicate: return "DUPLICATE"
        case .storage: return "STORAGE"
        case .inactive: return "INACTIVE"
        case .busy: return "BUSY"
        case .runtime: return "RUNTIME"
        case .protocolError: return "PROTOCOL"
        case .sourceChanged: return "SOURCE_CHANGED"
        case .updateRequiresDisable: return "UPDATE_REQUIRES_DISABLE"
        case .unsupported: return "UNSUPPORTED_API"
        case .cancelled: return "CANCELLED"
        case let .operation(raw): return Self.knownOperationCodes.contains(raw) ? raw : "BRIDGE_OPERATION"
        }
    }

    var detail: String {
        switch self {
        case .resources: return "The bundled test plugin resource is missing."
        case .pythonResources: return "The bundled Python standard library is missing; the interpreter was not started."
        case .sdkResources: return "The bundled plugin SDK is missing; the interpreter could not prepare."
        case .runtimeStartup: return "The Python runtime could not start. Restart the app and retry; no interpreter diagnostics were saved."
        case .sdkStartup: return "The Python runtime started but the bundled SDK failed to initialize. No traceback was saved."
        case .runtimeQueue: return "The bounded Python work queue is full. Wait for current operations and retry."
        case .source: return "The installed source could not be read as a bounded regular UTF-8 plugin file. Source contents were not logged."
        case .identity: return "The installed plugin identity did not match its validated record."
        case .duplicate: return "The same plugin ID appeared more than once in the batch; later copies were not loaded."
        case .storage: return "The Application Support report or plugin storage could not be safely read or written."
        case .inactive: return "The plugin was not active for the requested operation."
        case .busy: return "The plugin already has an operation in progress and was not started again."
        case .runtime: return "The host rejected plugin loading. Runtime exception text and tracebacks were intentionally omitted."
        case .protocolError: return "The host received an invalid or unsupported runtime response."
        case .sourceChanged: return "The reviewed plugin file changed before installation; review it again before retrying."
        case .updateRequiresDisable: return "The existing plugin must be disabled before replacement."
        case .unsupported: return "The plugin requires APIs unavailable in this build; it remains disabled."
        case let .operation(raw):
            switch raw {
            case "RESOURCE_LIMIT": return "The installed-plugin or concurrent-import capacity was reached."
            case "METADATA_QUOTA": return "The validated plugin metadata exceeded its storage limit."
            case "LOG_QUOTA": return "The per-batch report reached its size limit; no plugin source or runtime detail was added."
            case "SETTING_VALUE_TOO_LARGE": return "A plugin setting exceeded the host value limit."
            case "INVALID_ARGUMENTS": return "The host rejected an invalid operation request."
            case "INVALID_STATE": return "The requested operation was not valid in the plugin's current state."
            case "SCREEN_UNAVAILABLE": return "The required app screen was unavailable for the operation."
            case "CALLBACK_EXPIRED", "CALLBACK_REF": return "The plugin callback was no longer valid."
            case "UNSUPPORTED_API": return "The plugin requires APIs unavailable in this build; it remains disabled."
            default: return "The bridge rejected the operation. Plugin-provided error text was not saved."
            }
        case .cancelled: return "Batch cancellation was requested; this plugin and remaining plugins were not started."
        }
    }
}

enum AyuPluginBatchPhase: String, Codable, Sendable {
    case batch, queued, readSource = "read_source", inspect, nativeEnable = "native_enable", importPlugin = "import"
    case runtimePrepare = "runtime_prepare", runtimeLoad = "runtime_load", cleanup, enable, summary
}

/// One JSON object per line. Every completed append is synchronized before the
/// next plugin starts. A crash leaves the last durable phase in an unfinished log.
actor AyuPluginBatchJournal {
    static let maximumFileBytes = 2 * 1_048_576
    static let maximumRetainedFiles = 8
    static let maximumTotalBytes = maximumFileBytes * maximumRetainedFiles
    static let maximumAge: TimeInterval = 14 * 24 * 60 * 60
    // Reserve room for a terminal summary even when a phase limit is reached.
    private static let summaryReserve = 4096
    static let maximumEntryBytes = 3584
    private static let terminalResults: Set<String> = ["succeeded", "failed", "cancelled", "skipped", "already_enabled", "duplicate_skipped", "installed_disabled"]

    struct Entry: Codable, Sendable {
        let timestamp: String
        let batchID: String
        let pluginID: String?
        let pluginName: String?
        let fileName: String?
        let phase: AyuPluginBatchPhase
        let result: String
        let errorCode: String?
        let detail: String?
        let generation: String?
        let durationMilliseconds: Int
        let sourcePath: String?
        let sourceSHA256: String?
        let pluginVersion: String?
        var blockers: [AyuPluginBatchBlocker]
        var blockersOmitted: Int
        let phaseEntriesOmitted: Int
        let fileIndex: Int?
        let appVersion: String
        let appBuild: String
        let logPath: String
        let totals: AyuPluginBatchSummary?
    }

    private let root: URL
    private let sourceRoot: URL
    private let batchID: String
    nonisolated let url: URL
    private var bytes = 0
    private var opened = false
    private var terminalsRemaining = AyuPluginCapacity.maximumInstalledPlugins
    private var phaseEntriesOmitted = 0
    private let startedAt = ProcessInfo.processInfo.systemUptime

    init(root: URL, sourceRoot: URL, batchID: String) {
        self.root = root; self.sourceRoot = sourceRoot; self.batchID = batchID
        self.url = root.appendingPathComponent("batch-" + batchID + ".jsonl")
    }

    func open(now: Date = Date()) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: self.root, withIntermediateDirectories: true)
        guard try self.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              !manager.fileExists(atPath: self.url.path) else { throw AyuPluginService.Failure.storage }
        try self.prune(now: now, keeping: Self.maximumRetainedFiles - 1)
        try Data().write(to: self.url, options: .atomic)
        var directory = self.root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        self.opened = true
    }

    /// Plugin names are length-bounded and stripped of URLs/control characters;
    /// plugin-provided errors and source text never enter this interface.
    func append(pluginID: String? = nil, pluginName: String? = nil, fileName: String? = nil, phase: AyuPluginBatchPhase, result: String,
                diagnostic: AyuPluginBatchDiagnostic? = nil, generation: String? = nil,
                durationMilliseconds: Int? = nil, context: AyuPluginBatchLoadContext? = nil,
                fileIndex: Int? = nil, totals: AyuPluginBatchSummary? = nil) throws {
        guard self.opened else { throw AyuPluginService.Failure.storage }
        let safeID = pluginID.flatMap { Self.validID($0) ? $0 : nil }
        let safeGeneration = generation.flatMap { $0.range(of: "\\A[0-9a-f]{32}\\z", options: .regularExpression) != nil ? $0 : nil }
        let safeName = pluginName.map(Self.sanitizedName)
        let safeHash = context?.sourceSHA256.flatMap { Self.validHash($0) ? $0 : nil }
        let safeVersion = context?.pluginVersion.map(Self.sanitizedVersion)
        let rawBlockers = context?.blockers ?? []
        let safeBlockers = rawBlockers.prefix(32).compactMap { AyuPluginBatchBlocker.sanitized(code: $0.code, identifier: $0.identifier) }
        var entry = Entry(timestamp: ISO8601DateFormatter().string(from: Date()), batchID: self.batchID,
            pluginID: safeID, pluginName: safeName, fileName: fileName.map(Self.sanitizedName), phase: phase, result: result,
            errorCode: diagnostic?.code, detail: diagnostic?.detail, generation: safeGeneration,
            durationMilliseconds: max(0, durationMilliseconds ?? Int((ProcessInfo.processInfo.systemUptime - self.startedAt) * 1000)),
            sourcePath: safeID.map { id in
                // A stored package archive is named by its own extension.
                let stored = AyuPluginService.packageExtensions.first {
                    FileManager.default.fileExists(atPath: self.sourceRoot.appendingPathComponent(id + "." + $0).path)
                }
                return id + "." + (stored ?? "plugin")
            },
            sourceSHA256: safeHash, pluginVersion: safeVersion,
            blockers: safeBlockers, blockersOmitted: rawBlockers.count - safeBlockers.count,
            phaseEntriesOmitted: self.phaseEntriesOmitted, fileIndex: fileIndex,
            appVersion: Self.applicationVersion, appBuild: Self.applicationBuild,
            logPath: self.url.lastPathComponent, totals: totals)
        var data = try JSONEncoder().encode(entry); data.append(0x0a)
        // Bound evidence as well as the file. Retain exact checked tokens that
        // fit and disclose omitted blockers, never truncate an identifier.
        while data.count > Self.maximumEntryBytes && !entry.blockers.isEmpty {
            entry.blockers.removeLast(); entry.blockersOmitted += 1
            data = try JSONEncoder().encode(entry); data.append(0x0a)
        }
        guard data.count <= Self.maximumEntryBytes else { throw AyuPluginService.Failure.operation("LOG_QUOTA") }
        let terminal = phase != .summary && Self.terminalResults.contains(result)
        let limit: Int
        if phase == .summary { limit = Self.maximumFileBytes }
        else if terminal { limit = Self.maximumFileBytes - Self.summaryReserve }
        else {
            limit = Self.maximumFileBytes - Self.summaryReserve - self.terminalsRemaining * Self.maximumEntryBytes
            if self.bytes + data.count > limit { self.phaseEntriesOmitted += 1; return }
        }
        guard self.bytes + data.count <= limit else { throw AyuPluginService.Failure.operation("LOG_QUOTA") }
        let flags = try self.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard flags.isRegularFile == true, flags.isSymbolicLink != true else { throw AyuPluginService.Failure.storage }
        let handle = try FileHandle(forWritingTo: self.url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        self.bytes += data.count
        if terminal { self.terminalsRemaining = max(0, self.terminalsRemaining - 1) }
    }

    private func prune(now: Date, keeping: Int) throws {
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(at: self.root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("batch-") && $0.pathExtension == "jsonl" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
        var retained = 0
        for file in files {
            let flags = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
            guard flags.isRegularFile == true, flags.isSymbolicLink != true else { throw AyuPluginService.Failure.storage }
            if retained >= keeping || (flags.fileSize ?? 0) > Self.maximumFileBytes || now.timeIntervalSince(flags.contentModificationDate ?? .distantPast) > Self.maximumAge {
                try manager.removeItem(at: file)
            } else { retained += 1 }
        }
    }

    nonisolated static func readReport(at url: URL, within root: URL) throws -> Data {
        let standardizedRoot = root.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.deletingLastPathComponent() == standardizedRoot,
              standardizedURL.lastPathComponent.hasPrefix("batch-"), standardizedURL.pathExtension == "jsonl" else {
            throw AyuPluginService.Failure.storage
        }
        let rootValues = try standardizedRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw AyuPluginService.Failure.storage }
        let values = try standardizedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AyuPluginService.Failure.storage }
        let handle = try FileHandle(forReadingFrom: standardizedURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes, String(data: data, encoding: .utf8) != nil else { throw AyuPluginService.Failure.storage }
        return data
    }

    nonisolated static func latestReport(in root: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let directory = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directory.isDirectory == true, directory.isSymbolicLink != true else { throw AyuPluginService.Failure.storage }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("batch-") && $0.pathExtension == "jsonl" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
        // Normal retention keeps eight. The extra scan allowance tolerates a
        // crash during cleanup without opening report contents on the main actor.
        for file in files.prefix(Self.maximumRetainedFiles * 2) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { continue }
            guard values.isRegularFile == true else { continue }
            guard (values.fileSize ?? Self.maximumFileBytes + 1) <= Self.maximumFileBytes,
                  Date().timeIntervalSince(values.contentModificationDate ?? .distantPast) <= Self.maximumAge else { continue }
            return file
        }
        return nil
    }

    nonisolated private static func sanitizedName(_ value: String) -> String {
        let noURL = value.replacingOccurrences(of: "(?i)https?://\\S+|www\\.\\S+", with: "[redacted]", options: .regularExpression)
        let secretRedacted = noURL.replacingOccurrences(of: "(?i)(token|secret|password|api[_-]?key|authorization)\\s*[:=]\\s*[^\\s,;]+", with: "$1=[redacted]", options: .regularExpression)
        let allowed = secretRedacted.unicodeScalars.filter { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-.()[]=:" )).contains($0) }
        let result = String(String.UnicodeScalarView(allowed.prefix(80))).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "[redacted]" : result
    }

    nonisolated private static func sanitizedVersion(_ value: String) -> String {
        guard value.utf8.count <= 64,
              value.range(of: "\\A[0-9][0-9A-Za-z.+_-]*\\z", options: .regularExpression) != nil else { return "[redacted]" }
        return value
    }

    nonisolated private static func validHash(_ value: String) -> Bool {
        value.range(of: "\\A[0-9a-f]{64}\\z", options: .regularExpression) != nil
    }

    nonisolated private static let applicationVersion: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return sanitizedVersion(value)
    }()

    nonisolated private static let applicationBuild: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return sanitizedVersion(value)
    }()

    nonisolated static func validID(_ id: String) -> Bool {
        id.utf8.count <= 32 && id.range(of: "\\A[A-Za-z][A-Za-z0-9_-]{1,31}\\z", options: .regularExpression) != nil
    }
}

/// Runs on the service actor, awaiting each complete load (including its failure
/// cleanup) before touching the next owner. Tests inject only synthetic work.
@MainActor enum AyuPluginBatchRunner {
    typealias PhaseReporter = @MainActor (AyuPluginBatchPhase, AyuPluginBatchLoadContext?) async throws -> Void

    static func run(ids: [String], journal: AyuPluginBatchJournal,
                    isEnabled: (String) -> Bool, isCancelled: () -> Bool,
                    pluginName: (String) -> String,
                    diagnostic: (Error) -> AyuPluginBatchDiagnostic,
                    progress: (Int, Int) -> Void,
                    enable: (String, PhaseReporter) async throws -> AyuPluginBatchLoadResult) async throws -> AyuPluginBatchSummary {
        guard !ids.isEmpty, ids.count <= AyuPluginCapacity.maximumInstalledPlugins,
              ids.allSatisfy(AyuPluginBatchJournal.validID) else { throw AyuPluginService.Failure.identity }
        var seen: Set<String> = []
        let ordered = ids.filter { seen.insert($0).inserted }
        let batchID = journal.url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "batch-", with: "")
        let duplicateCount = ids.count - ordered.count
        var summary = AyuPluginBatchSummary(batchID: batchID, requested: ids.count, skipped: duplicateCount, logPath: journal.url.lastPathComponent)
        let started = ProcessInfo.processInfo.systemUptime
        try await journal.open()
        try await journal.append(phase: .batch, result: "started", totals: summary)
        var logFailed = false
        var seenIDs: Set<String> = []
        for (index, id) in ids.enumerated() {
            guard seenIDs.insert(id).inserted else {
                do { try await journal.append(pluginID: id, pluginName: pluginName(id), phase: .enable, result: "duplicate_skipped", diagnostic: .duplicate, fileIndex: index + 1) }
                catch { logFailed = true }
                progress(index + 1, ids.count)
                continue
            }
            var latestContext: AyuPluginBatchLoadContext?
            let cancelled = Task.isCancelled || isCancelled()
            if cancelled {
                summary.cancelled += 1
                do { try await journal.append(pluginID: id, pluginName: pluginName(id), phase: .enable, result: "cancelled", diagnostic: .cancelled, fileIndex: index + 1) }
                catch { logFailed = true }
            } else if isEnabled(id) {
                summary.skipped += 1
                do { try await journal.append(pluginID: id, pluginName: pluginName(id), phase: .enable, result: "already_enabled", fileIndex: index + 1) }
                catch { logFailed = true }
            } else {
                let pluginStarted = ProcessInfo.processInfo.systemUptime
                var failurePhase = AyuPluginBatchPhase.queued
                do {
                    try await journal.append(pluginID: id, pluginName: pluginName(id), phase: .queued, result: "started", fileIndex: index + 1)
                    let phaseName = pluginName(id)
                    let loadResult = try await enable(id, { phase, context in
                        if phase != .cleanup { failurePhase = phase }
                        if let context { latestContext = context }
                        do {
                            try await journal.append(pluginID: id, pluginName: phaseName, phase: phase, result: "started", context: context, fileIndex: index + 1)
                        } catch {
                            logFailed = true
                            throw AyuPluginBatchFailure(diagnostic: .storage, phase: phase, context: context ?? latestContext)
                        }
                    })
                    summary.succeeded += 1
                    do { try await journal.append(pluginID: id, pluginName: pluginName(id), phase: .enable, result: "succeeded", generation: loadResult.generation, durationMilliseconds: elapsed(pluginStarted), context: loadResult.context, fileIndex: index + 1) }
                    catch { logFailed = true }
                } catch {
                    summary.failed += 1
                    let batchFailure = error as? AyuPluginBatchFailure
                    let failureDiagnostic = batchFailure?.diagnostic ?? diagnostic(error)
                    let failureContext = batchFailure?.context ?? latestContext
                    let phase = batchFailure?.phase ?? failurePhase
                    do { try await journal.append(pluginID: id, pluginName: pluginName(id), phase: phase, result: "failed", diagnostic: failureDiagnostic, durationMilliseconds: elapsed(pluginStarted), context: failureContext, fileIndex: index + 1) }
                    catch { logFailed = true }
                }
            }
            progress(index + 1, ids.count)
        }
        summary.durationMilliseconds = elapsed(started)
        try await journal.append(phase: .summary, result: logFailed ? "log_incomplete" : (summary.cancelled > 0 ? "cancelled" : "completed"), diagnostic: logFailed ? .storage : nil, durationMilliseconds: summary.durationMilliseconds, totals: summary)
        // Do not silently present a successful durable batch when writes failed.
        if logFailed { throw AyuPluginService.Failure.storage }
        return summary
    }

    private static func elapsed(_ started: TimeInterval) -> Int {
        Int(max(0, ProcessInfo.processInfo.systemUptime - started) * 1000)
    }
}
