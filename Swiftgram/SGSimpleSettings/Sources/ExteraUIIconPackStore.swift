import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public struct ExteraCustomUIIconPack: Codable, Equatable {
    public let id: String
    public let name: String
    public let author: String
    public let version: String
    public let icons: [String: String]
    public let revision: String
    public let checksums: [String: String]
}

/// Immutable, validated preview bytes. Install consumes these same bytes, never reopens the external URL.
public struct ExteraUIIconPackImport {
    public let pack: ExteraCustomUIIconPack
    public let archiveSHA256: String
    public let files: [String: Data]

    public static func validate(_ data: Data) throws -> ExteraUIIconPackImport {
        return try make(files: ExteraUIIconArchive.decode(data), archiveSHA256: digest(data))
    }

    static func make(files: [String: Data], archiveSHA256: String = "") throws -> ExteraUIIconPackImport {
        guard let metadata = files["metadata.json"], metadata.count <= ExteraUIIconArchive.maxMetadataBytes,
              let json = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let name = json["packName"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 1024,
              let id = json["packId"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.utf8.count <= 256, !id.hasPrefix("base."), !id.contains("/"), !id.contains("\\"), id != ".", id != "..",
              !id.unicodeScalars.contains(where: { $0.value < 32 }) else { throw ExteraUIIconError.invalidMetadata }
        let author = json["author"] as? String ?? "Unknown", version = json["version"] as? String ?? "1.0"
        guard json["author"] == nil || json["author"] is String, json["version"] == nil || json["version"] is String else { throw ExteraUIIconError.invalidMetadata }
        guard author.utf8.count <= 1024, version.utf8.count <= 256 else { throw ExteraUIIconError.invalidMetadata }
        if let schema = json["schemaVersion"] {
            guard let number = schema as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == 1 else { throw ExteraUIIconError.invalidMetadata }
        }
        let icons: [String: String]
        if let value = json["icons"] {
            guard let dictionary = value as? [String: String] else { throw ExteraUIIconError.invalidMetadata }
            icons = dictionary
        } else { icons = [:] }
        guard icons.count <= ExteraUIIconArchive.maxEntries, files.count <= ExteraUIIconArchive.maxEntries else { throw ExteraUIIconError.limitExceeded }
        var total = 0, checksums: [String: String] = [:], seen = Set<String>()
        for (path, bytes) in files {
            guard try ExteraUIIconArchive.path(path) == path,
                  seen.insert(path.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted else { throw ExteraUIIconError.unsafePath }
            guard bytes.count <= ExteraUIIconArchive.maxFileBytes, bytes.count <= ExteraUIIconArchive.maxTotalBytes - total else { throw ExteraUIIconError.limitExceeded }
            total += bytes.count; checksums[path] = digest(bytes)
        }
        for (key, path) in icons {
            guard !key.isEmpty, key.utf8.count <= 256, key.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 95 }),
                  try ExteraUIIconArchive.path(path) == path, files[path] != nil, path != "metadata.json" else { throw ExteraUIIconError.invalidMetadata }
        }
        // Canonical hashes include names and their contents, not dictionary iteration order or mtimes.
        var canonical = Data()
        for name in checksums.keys.sorted() { canonical.append(Data(name.utf8)); canonical.append(0); canonical.append(Data(checksums[name]!.utf8)); canonical.append(0) }
        let pack = ExteraCustomUIIconPack(id: id, name: name, author: author, version: version, icons: icons, revision: digest(canonical), checksums: checksums)
        return ExteraUIIconPackImport(pack: pack, archiveSHA256: archiveSHA256, files: files)
    }

    public static func digest(_ data: Data) -> String { return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

public struct ExteraUIIconPackSnapshot: Equatable {
    public let enabled: [ExteraCustomUIIconPack]
    public let hidden: [ExteraCustomUIIconPack]
    public var all: [ExteraCustomUIIconPack] { return enabled + hidden }
    public static let empty = ExteraUIIconPackSnapshot(enabled: [], hidden: [])
}

public struct ExteraUIIconPackBackupPlan {
    public let packs: [ExteraUIIconPackImport]
    public let enabled: [String]
    public let hidden: [String]
    fileprivate init(packs: [ExteraUIIconPackImport], enabled: [String], hidden: [String]) {
        self.packs = packs; self.enabled = enabled; self.hidden = hidden
    }
}

/// Serializes mutations and publishes a catalog only after an immutable revision is durably staged.
/// Old revision directories remain available to value snapshots until the next explicit maintenance pass.
public final class ExteraUIIconPackStore: @unchecked Sendable {
    public static let shared: ExteraUIIconPackStore = {
        let root: URL
        #if os(iOS)
        root = (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP_IDENTIFIER)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("Library/Application Support/ExteraUIIconPacks", isDirectory: true)
        #else
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ExteraUIIconPacks", isDirectory: true)
        #endif
        return ExteraUIIconPackStore(root: root)
    }()
    private struct Catalog: Codable {
        var schema = 1
        var enabled: [String] = []
        var hidden: [String] = []
        var packs: [String: ExteraCustomUIIconPack] = [:]
    }
    private let root: URL
    private let lock = NSRecursiveLock()
    private var catalog: Catalog
    private var mutationDepth = 0
    public static let maxPacks = 64
    /// Base64 expands the archives; headroom covers the bounded IDs, hashes, and
    /// enabled/hidden ordering in the JSON envelope.
    public static let maxBackupBytes = ((ExteraUIIconArchive.maxArchiveBytes + 2) / 3) * 4 + 512 * 1024

    public init(root: URL) {
        self.root = root
        self.catalog = (try? Self.loadCatalog(root)) ?? Catalog()
    }

    private static func loadCatalog(_ root: URL) throws -> Catalog {
        let url = root.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Catalog() }
        let bytes = try ExteraUIIconArchive.readFile(url, limit: 4 * 1024 * 1024)
        let value = try JSONDecoder().decode(Catalog.self, from: bytes)
        guard value.schema == 1, value.packs.count <= maxPacks,
              Set(value.enabled + value.hidden).count == value.enabled.count + value.hidden.count,
              Set(value.enabled + value.hidden) == Set(value.packs.keys) else { throw ExteraUIIconError.corruptFile }
        for (id, pack) in value.packs {
            guard id == pack.id, Self.validRevision(pack.revision), pack.checksums["metadata.json"] != nil,
                  pack.checksums.count <= ExteraUIIconArchive.maxEntries,
                  pack.checksums.allSatisfy({ (try? ExteraUIIconArchive.path($0.key)) == $0.key && Self.validRevision($0.value) }),
                  pack.icons.allSatisfy({ pack.checksums[$0.value] != nil }) else { throw ExteraUIIconError.corruptFile }
        }
        return value
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        self.lock.lock(); defer { self.lock.unlock() }; return try body()
    }
    /// flock protects app-group writers in separate processes/store instances. Nested edit/install
    /// shares the outer transaction; catalog reload prevents stale-instance lost updates.
    private func mutate<T>(_ body: () throws -> T) throws -> T {
        return try self.locked {
            if self.mutationDepth > 0 { return try body() }
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            guard try self.root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ExteraUIIconError.unsafePath }
            let descriptor = open(self.root.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
            guard descriptor >= 0 else { throw ExteraUIIconError.storage }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw ExteraUIIconError.storage }
            defer { _ = flock(descriptor, LOCK_UN) }
            self.catalog = try Self.loadCatalog(self.root)
            self.mutationDepth += 1
            defer { self.mutationDepth -= 1 }
            return try body()
        }
    }
    public var snapshot: ExteraUIIconPackSnapshot {
        return self.locked {
            return ExteraUIIconPackSnapshot(enabled: self.catalog.enabled.compactMap { self.catalog.packs[$0] }, hidden: self.catalog.hidden.compactMap { self.catalog.packs[$0] })
        }
    }
    public func reload() throws { try self.locked { self.catalog = try Self.loadCatalog(self.root) }; self.changed() }
    private static func validRevision(_ value: String) -> Bool { return value.count == 64 && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) } }
    private func directory(_ pack: ExteraCustomUIIconPack) -> URL {
        return self.root.appendingPathComponent("revisions", isDirectory: true).appendingPathComponent(pack.revision, isDirectory: true)
    }
    private func publish(_ value: Catalog) throws {
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 4 * 1024 * 1024 else { throw ExteraUIIconError.limitExceeded }
        try bytes.write(to: self.root.appendingPathComponent("catalog.json"), options: .atomic)
        self.catalog = value
    }
    private func changed() {
        // Never synchronously deliver a main-queue observer while a mutation owns the store lock.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ExteraUIIconSettings.didChange, object: self)
            NotificationCenter.default.post(name: ayuSettingsDidChangeNotification, object: nil)
        }
    }

    public func data(for pack: ExteraCustomUIIconPack, path: String) throws -> Data {
        return try self.locked {
            guard Self.validRevision(pack.revision), try ExteraUIIconArchive.path(path) == path, let checksum = pack.checksums[path] else { throw ExteraUIIconError.unsafePath }
            let url = self.directory(pack).appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  self.directory(pack).resolvingSymlinksInPath().path == self.root.resolvingSymlinksInPath().appendingPathComponent("revisions/" + pack.revision).path,
                  url.resolvingSymlinksInPath().path.hasPrefix(self.directory(pack).resolvingSymlinksInPath().path + "/") else { throw ExteraUIIconError.unsafePath }
            let bytes = try ExteraUIIconArchive.readFile(url, limit: ExteraUIIconArchive.maxFileBytes)
            guard ExteraUIIconPackImport.digest(bytes) == checksum else { throw ExteraUIIconError.corruptFile }
            return bytes
        }
    }

    private func stage(_ preview: ExteraUIIconPackImport) throws {
            // Public previews cannot forge their revision: reconstruct the manifest from their bytes.
            let validated = try ExteraUIIconPackImport.make(files: preview.files)
            guard validated.pack == preview.pack else { throw ExteraUIIconError.corruptFile }
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            let destination = self.directory(preview.pack)
            let stage = self.root.appendingPathComponent("stage-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            for (name, bytes) in preview.files {
                let url = stage.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url, options: .atomic)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard try destination.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ExteraUIIconError.unsafePath }
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: stage, to: destination) }
            else {
                for name in preview.files.keys { _ = try self.data(for: preview.pack, path: name) }
            }
    }

    public func install(_ preview: ExteraUIIconPackImport, enable: Bool) throws {
        try self.mutate {
            guard self.catalog.packs[preview.pack.id] != nil || self.catalog.packs.count < Self.maxPacks else { throw ExteraUIIconError.limitExceeded }
            try self.stage(preview)
            var value = self.catalog
            value.packs[preview.pack.id] = preview.pack
            if !value.enabled.contains(preview.pack.id) && !value.hidden.contains(preview.pack.id) {
                if enable { value.enabled.append(preview.pack.id) } else { value.hidden.insert(preview.pack.id, at: 0) }
            } else if enable && !value.enabled.contains(preview.pack.id) {
                value.hidden.removeAll { $0 == preview.pack.id }; value.enabled.append(preview.pack.id)
            }
            try self.publish(value)
        }
        self.changed()
    }

    public func setEnabled(_ id: String, enabled: Bool) throws {
        try self.mutate {
            guard self.catalog.packs[id] != nil else { throw ExteraUIIconError.invalidMetadata }
            var value = self.catalog
            value.enabled.removeAll { $0 == id }; value.hidden.removeAll { $0 == id }
            if enabled { value.enabled.insert(id, at: 0) } else { value.hidden.insert(id, at: 0) }
            try self.publish(value)
        }
        self.changed()
    }
    public func reorder(_ ids: [String], enabled: Bool) throws {
        try self.mutate {
            let old = enabled ? self.catalog.enabled : self.catalog.hidden
            guard Set(ids) == Set(old), ids.count == old.count else { throw ExteraUIIconError.invalidMetadata }
            var value = self.catalog
            if enabled { value.enabled = ids } else { value.hidden = ids }
            try self.publish(value)
        }
        self.changed()
    }
    public func delete(_ id: String) throws {
        try self.mutate {
            var value = self.catalog
            value.packs.removeValue(forKey: id); value.enabled.removeAll { $0 == id }; value.hidden.removeAll { $0 == id }
            try self.publish(value)
        }
        self.changed()
    }
    public func export(_ pack: ExteraCustomUIIconPack) throws -> Data {
        return try self.locked {
            var files: [String: Data] = [:]
            for name in pack.checksums.keys { files[name] = try self.data(for: pack, path: name) }
            return try ExteraUIIconArchive.encode(files)
        }
    }

    /// Opaque JSON for the host's settings-backup envelope. Each embedded archive remains an
    /// ordinary Android .icons ZIP; the outer object also preserves enabled/hidden ordering.
    /// Base selection stays in the existing host-owned basePack backup field.
    public func exportBackup() throws -> Data {
        return try self.mutate {
            var archives: [String: String] = [:], checksums: [String: String] = [:]
            var total = 0
            for (id, pack) in self.catalog.packs {
                let bytes = try self.export(pack)
                guard bytes.count <= ExteraUIIconArchive.maxArchiveBytes - total else { throw ExteraUIIconError.limitExceeded }
                total += bytes.count
                archives[id] = bytes.base64EncodedString(); checksums[id] = ExteraUIIconPackImport.digest(bytes)
            }
            let result = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "archives": archives, "sha256": checksums, "enabled": self.catalog.enabled, "hidden": self.catalog.hidden], options: [.sortedKeys])
            guard result.count <= Self.maxBackupBytes else { throw ExteraUIIconError.limitExceeded }
            return result
        }
    }
    public static func prepareBackupRestore(_ data: Data) throws -> ExteraUIIconPackBackupPlan {
        guard data.count <= Self.maxBackupBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              let archives = object["archives"] as? [String: String], let checksums = object["sha256"] as? [String: String],
              let enabled = object["enabled"] as? [String], let hidden = object["hidden"] as? [String],
              archives.count <= Self.maxPacks, Set(archives.keys) == Set(checksums.keys),
              Set(enabled + hidden) == Set(archives.keys), Set(enabled + hidden).count == enabled.count + hidden.count else { throw ExteraUIIconError.invalidMetadata }
        var packs: [ExteraUIIconPackImport] = [], total = 0
        for id in archives.keys.sorted() {
            guard let encoded = archives[id], let bytes = Data(base64Encoded: encoded), bytes.count <= ExteraUIIconArchive.maxArchiveBytes - total,
                  ExteraUIIconPackImport.digest(bytes) == checksums[id] else { throw ExteraUIIconError.corruptFile }
            total += bytes.count
            let preview = try ExteraUIIconPackImport.validate(bytes)
            guard preview.pack.id == id else { throw ExteraUIIconError.invalidMetadata }
            packs.append(preview)
        }
        return ExteraUIIconPackBackupPlan(packs: packs, enabled: enabled, hidden: hidden)
    }
    /// Validate every image before committing any catalog change. The host passes
    /// ExteraUIIconRendering.validate; a failed restore leaves the previous catalog active.
    public func restoreBackup(_ plan: ExteraUIIconPackBackupPlan, validate: (ExteraUIIconPackImport) throws -> Void) throws {
        for preview in plan.packs { try validate(preview) }
        try self.mutate {
            for preview in plan.packs { try self.stage(preview) }
            var value = Catalog()
            value.enabled = plan.enabled; value.hidden = plan.hidden
            for preview in plan.packs { value.packs[preview.pack.id] = preview.pack }
            try self.publish(value)
        }
        self.changed()
    }
    public func create(name: String, author: String, version: String) throws -> ExteraCustomUIIconPack {
        let id = "custom." + UUID().uuidString.lowercased()
        let metadata = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "packId": id, "packName": name, "author": author, "version": version.isEmpty ? "1.0" : version, "icons": [:]] as [String: Any], options: [.sortedKeys])
        let preview = try ExteraUIIconPackImport.make(files: ["metadata.json": metadata])
        try self.install(preview, enable: true)
        return preview.pack
    }
    /// nil resource edits pack details; nil image resets an override and reveals the next owner.
    public func edit(_ id: String, name: String? = nil, author: String? = nil, version: String? = nil,
                     resource: String? = nil, image: Data? = nil, fileExtension: String? = nil) throws {
        try self.mutate {
            guard let pack = self.catalog.packs[id] else { throw ExteraUIIconError.invalidMetadata }
            var files: [String: Data] = [:]
            for path in pack.checksums.keys { files[path] = try self.data(for: pack, path: path) }
            var icons = pack.icons
            if let resource {
                let previous = icons.removeValue(forKey: resource)
                if let image, let ext = fileExtension, ["png", "webp", "jpg", "jpeg", "svg", "xml"].contains(ext) {
                    let path = "icons/" + UUID().uuidString.lowercased() + "." + ext
                    files[path] = image; icons[resource] = path
                } else if image != nil { throw ExteraUIIconError.unsupportedImage }
                if let previous, !icons.values.contains(previous) { files.removeValue(forKey: previous) }
            }
            guard let original = files["metadata.json"], var json = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw ExteraUIIconError.invalidMetadata }
            json["schemaVersion"] = 1; json["icons"] = icons
            json["packName"] = name ?? pack.name; json["author"] = author ?? pack.author; json["version"] = version ?? pack.version
            files["metadata.json"] = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try self.install(ExteraUIIconPackImport.make(files: files), enable: false)
        }
    }
}
