#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import SGSimpleSettings

public struct VoskModelStatus: Equatable, Sendable {
    public let model: VoskModelDescriptor
    public let isInstalled: Bool
}

/// A store-wide lease prevents mutation/deletion while C code owns model files.
/// All native loading/processing is outside the store lock, on a worker queue.
final class VoskModelLease {
    let url: URL
    private let release: () -> Void
    init(url: URL, release: @escaping () -> Void) { self.url = url; self.release = release }
    deinit { self.release() }
}

public final class VoskModelStore: @unchecked Sendable {
    public static let shared = VoskModelStore()
    private let lock = NSLock()
    private var owner: UUID?
    private let worker = DispatchQueue(label: "Extera.Vosk.ModelFiles", qos: .utility)
    private let root: URL
    private let fm = FileManager.default
    private let models: [VoskModelDescriptor]
    private let validate: (String) throws -> Void
    typealias Download = (VoskModelDescriptor, URL, VoskCancellation, @escaping (Double) -> Void) async throws -> Void
    private let download: Download

    private struct Receipt: Codable {
        let sha256: String
        let expandedBytes: Int
    }

    private convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(root: support.appendingPathComponent("ExteraVosk", isDirectory: true))
    }

    // Internal injection seam for exact-production host tests, without network or
    // loading an iOS binary into a macOS process. App callers use shared only.
    init(root: URL, models: [VoskModelDescriptor] = VoskModelCatalogue.all,
         validate: @escaping (String) throws -> Void = VoskRecognizer.validate,
         download: @escaping Download = { model, target, cancellation, progress in
             try await VoskDownload(model: model, target: target, cancellation: cancellation, progress: progress).run()
         }) {
        self.root = root
        self.models = models
        self.validate = validate
        self.download = download
        // Setup errors are surfaced by operations. No model download happens here.
        do {
            try self.prepareRoot()
            try self.removeStagingDirectories()
        } catch { /* Operations retry setup and surface failures to the caller. */ }
    }

    private func prepareRoot() throws {
        if self.fm.fileExists(atPath: self.root.path) {
            guard try self.fm.attributesOfItem(atPath: self.root.path)[.type] as? FileAttributeType == .typeDirectory else { throw VoskSpeechError.storageFailure }
        } else { try self.fm.createDirectory(at: self.root, withIntermediateDirectories: true) }
        var root = self.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        // Interrupted operations are confined to staging. Clean only our UUID
        // directories on a fresh process, before an owner can exist.
    }

    private func location(_ model: VoskModelDescriptor) -> URL {
        self.root.appendingPathComponent(model.language, isDirectory: true)
    }

    private func installed(_ model: VoskModelDescriptor) -> Bool {
        let path = self.location(model)
        guard let attributes = try? self.fm.attributesOfItem(atPath: path.path), attributes[.type] as? FileAttributeType == .typeDirectory,
              let bytes = try? Data(contentsOf: path.appendingPathComponent(".extera-vosk.json")),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: bytes),
              receipt.sha256 == model.sha256, receipt.expandedBytes == model.expandedBytes else { return false }
        return model.requiredFiles.allSatisfy { item in
            guard let attributes = try? self.fm.attributesOfItem(atPath: path.appendingPathComponent(item).path) else { return false }
            return attributes[.type] as? FileAttributeType == .typeRegular
        }
    }

    public func catalogue() -> [VoskModelStatus] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.models.map { VoskModelStatus(model: $0, isInstalled: self.installed($0)) }
    }

    private func acquire() throws -> UUID {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.owner == nil else { throw VoskSpeechError.busy }
        let token = UUID()
        self.owner = token
        return token
    }

    private func release(_ token: UUID) {
        self.lock.lock()
        if self.owner == token { self.owner = nil }
        self.lock.unlock()
    }

    func lease(language: String) throws -> VoskModelLease {
        guard let model = self.models.first(where: { $0.language == language }) else { throw VoskSpeechError.unsupportedLanguage }
        let token = try self.acquire()
        guard self.installed(model) else { self.release(token); throw VoskSpeechError.notInstalled }
        return VoskModelLease(url: self.location(model), release: { [self] in self.release(token) })
    }

    private func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.worker.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Explicit user action only. No selection change on download completion.
    public func install(language: String, progress: @escaping (Double) -> Void) async throws {
        guard let model = self.models.first(where: { $0.language == language }) else { throw VoskSpeechError.unsupportedLanguage }
        let token = try self.acquire()
        defer { self.release(token) }
        let cancellation = VoskCancellation()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            if self.installed(model) { return }
            let stage = self.root.appendingPathComponent("staging-" + token.uuidString, isDirectory: true)
            try self.prepareRoot()
            try self.fm.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? self.fm.removeItem(at: stage) }
            let archive = stage.appendingPathComponent("model.zip")
            let unpacked = stage.appendingPathComponent("unpacked", isDirectory: true)
            let capacity = try self.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            let required = model.archiveBytes + Int64(model.expandedBytes) + 16 * 1024 * 1024
            if let capacity, capacity < required { throw VoskSpeechError.storageFailure }
            try cancellation.check()
            try await self.download(model, archive, cancellation, progress)
            try await self.perform {
                try cancellation.check()
                let archiveSize = try self.fm.attributesOfItem(atPath: archive.path)[.size] as? NSNumber
                guard archiveSize?.int64Value == model.archiveBytes else { throw VoskSpeechError.integrityFailed }
                let input = try FileHandle(forReadingFrom: archive)
                defer { try? input.close() }
                var hash = SHA256()
                while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try cancellation.check()
                    hash.update(data: data)
                }
                let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
                guard actual == model.sha256 else { throw VoskSpeechError.integrityFailed }
                // No extraction or native model parse before SHA-256 succeeds.
                try self.fm.createDirectory(at: unpacked, withIntermediateDirectories: false)
                try VoskSafeArchive.extract(archive: archive, destination: unpacked, model: model, cancellation: cancellation)
                try cancellation.check()
                try self.validate(unpacked.path)
                try cancellation.check()
                let receipt = try JSONEncoder().encode(Receipt(sha256: model.sha256, expandedBytes: model.expandedBytes))
                try receipt.write(to: unpacked.appendingPathComponent(".extera-vosk.json"), options: .atomic)
                try cancellation.check()
                let target = self.location(model)
                if self.fm.fileExists(atPath: target.path) { try self.fm.removeItem(at: target) }
                try self.fm.moveItem(at: unpacked, to: target)
                // Cancellation racing the atomic publication rolls back this new install.
                do { try cancellation.check() }
                catch { try? self.fm.removeItem(at: target); throw error }
            }
        }, onCancel: { cancellation.cancel() })
    }

    /// Verifies the actual native model under a lease before persisting Use.
    public func use(language: String) async throws {
        let cancellation = VoskCancellation()
        let configuration = ExteraVoskSettings.shared.configuration
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            let lease = try self.lease(language: language)
            defer { withExtendedLifetime(lease) {} }
            try await self.perform {
                try cancellation.check()
                try self.validate(lease.url.path)
            }
            // UI choices and this final compare/write run on the same executor.
            // Native validation never blocks the main thread.
            try await MainActor.run {
                try cancellation.check()
                guard configuration == ExteraVoskSettings.shared.configuration else { throw VoskSpeechError.cancelled }
                // Keep lease until the settings write, preventing a concurrent delete.
                ExteraVoskSettings.shared.select(language: language)
                withExtendedLifetime(lease) {}
            }
        }, onCancel: { cancellation.cancel() })
    }

    /// Busy during recognition/install. No unlink while native code owns a lease.
    public func delete(language: String) async throws {
        try Task.checkCancellation()
        let cancellation = VoskCancellation()
        guard let model = self.models.first(where: { $0.language == language }) else { throw VoskSpeechError.unsupportedLanguage }
        let token = try self.acquire()
        defer { self.release(token) }
        try await withTaskCancellationHandler(operation: {
            try await self.perform {
                try cancellation.check()
                let target = self.location(model)
                // Removal is the commit point. Once it starts, finish updating
                // preferences even if Cancel arrives while FileManager runs.
                if self.fm.fileExists(atPath: target.path) { try self.fm.removeItem(at: target) }
                guard !self.fm.fileExists(atPath: target.path) else { throw VoskSpeechError.storageFailure }
            }
            await MainActor.run { ExteraVoskSettings.shared.clearDeletedSelection(language: language) }
        }, onCancel: { cancellation.cancel() })
    }

    /// Call explicitly on app startup to discard interrupted staging, not models.
    public func removeInterruptedDownloads() async throws {
        let token = try self.acquire()
        defer { self.release(token) }
        try await self.perform {
            try self.prepareRoot()
            try self.removeStagingDirectories()
        }
    }

    private func removeStagingDirectories() throws {
        for child in try self.fm.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) {
            guard child.lastPathComponent.hasPrefix("staging-"), UUID(uuidString: String(child.lastPathComponent.dropFirst(8))) != nil else { continue }
            try self.fm.removeItem(at: child)
        }
    }
}
