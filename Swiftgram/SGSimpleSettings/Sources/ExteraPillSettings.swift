import CoreFoundation
import Foundation

/// Native, data-only HTTP pills, inspired by exteraGram's pillstack/custom subsystem.
/// No executable templates, plugins, account variables, or Telegram credentials are evaluated.
public struct ExteraPillSpec: Codable, Equatable {
    public enum Format: String, Codable, CaseIterable {
        case text, number, percent, bytes
    }

    public var id: UUID
    public var enabled: Bool
    public var label: String
    public var url: String
    /// Empty selects the JSON root. Supports keys, [index], negative indices, and quoted keys.
    public var jsonPath: String
    /// Zero means manual refresh; otherwise 60 ... 86400 seconds.
    public var refresh: Int
    public var format: Format
    public var decimals: Int
    public var prefix: String
    public var suffix: String

    public init(id: UUID = UUID(), enabled: Bool = true, label: String = "", url: String = "", jsonPath: String = "", refresh: Int = 300, format: Format = .text, decimals: Int = 2, prefix: String = "", suffix: String = "") {
        self.id = id
        self.enabled = enabled
        self.label = label
        self.url = url
        self.jsonPath = jsonPath
        self.refresh = refresh
        self.format = format
        self.decimals = decimals
        self.prefix = prefix
        self.suffix = suffix
    }

    public func validated() throws -> ExteraPillSpec {
        var result = self
        result.label = self.label.trimmingCharacters(in: .whitespacesAndNewlines)
        result.url = self.url.trimmingCharacters(in: .whitespacesAndNewlines)
        result.jsonPath = self.jsonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.label.isEmpty, result.label.count <= 32,
              result.url.utf8.count <= 2048, Self.requestURL(result.url) != nil,
              result.jsonPath.utf8.count <= 256,
              (result.refresh == 0 || (60 ... 86400).contains(result.refresh)),
              (0 ... 8).contains(result.decimals),
              result.prefix.count <= 32, result.suffix.count <= 32 else {
            throw ExteraPillError.invalidConfiguration
        }
        _ = try ExteraPillJSONPath.tokens(result.jsonPath)
        return result
    }

    public static func requestURL(_ string: String) -> URL? {
        guard !string.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else { return nil }
        return components.url
    }
}

public enum ExteraPillError: Error {
    case invalidConfiguration, invalidPath, missingValue, invalidNumber, invalidJSON
    case invalidFile, unsupportedVersion, limitReached, responseTooLarge, network, httpStatus(Int)
}

/// Strict JSON path traversal: no evaluation, recursive descent, or unbounded result expansion.
public enum ExteraPillJSONPath {
    enum Token {
        case key(String), index(Int)
    }

    static func tokens(_ path: String) throws -> [Token] {
        let characters = Array(path)
        var offset = 0
        var result: [Token] = []
        if characters.first == "$", characters.count == 1 || characters[1] == "." || characters[1] == "[" {
            offset = 1
        }
        while offset < characters.count {
            guard result.count < 32 else { throw ExteraPillError.invalidPath }
            if characters[offset] == "." {
                guard offset > 0 else { throw ExteraPillError.invalidPath }
                offset += 1
                guard offset < characters.count, characters[offset] != ".", characters[offset] != "[" else { throw ExteraPillError.invalidPath }
            } else if !result.isEmpty, characters[offset] != "[" {
                throw ExteraPillError.invalidPath
            }
            if characters[offset] == "[" {
                let start = offset
                offset += 1
                guard offset < characters.count else { throw ExteraPillError.invalidPath }
                if characters[offset] == "\"" {
                    offset += 1
                    var escaped = false
                    while offset < characters.count {
                        let character = characters[offset]
                        offset += 1
                        if escaped { escaped = false; continue }
                        if character == "\\" { escaped = true; continue }
                        if character == "\"" { break }
                    }
                    guard offset < characters.count, characters[offset] == "]" else { throw ExteraPillError.invalidPath }
                    let quoted = String(characters[(start + 1) ..< offset])
                    guard let data = quoted.data(using: .utf8), let key = try? JSONDecoder().decode(String.self, from: data) else { throw ExteraPillError.invalidPath }
                    result.append(.key(key))
                } else {
                    let numberStart = offset
                    while offset < characters.count, characters[offset] != "]" { offset += 1 }
                    let raw = String(characters[numberStart ..< offset])
                    guard let index = Int(raw), raw == String(index) else { throw ExteraPillError.invalidPath }
                    result.append(.index(index))
                }
                guard offset < characters.count, characters[offset] == "]" else { throw ExteraPillError.invalidPath }
                offset += 1
            } else {
                let start = offset
                while offset < characters.count, characters[offset] != ".", characters[offset] != "[" {
                    guard characters[offset] != "]", !characters[offset].isWhitespace else { throw ExteraPillError.invalidPath }
                    offset += 1
                }
                guard start < offset else { throw ExteraPillError.invalidPath }
                result.append(.key(String(characters[start ..< offset])))
            }
        }
        return result
    }

    public static func resolve(_ root: Any, path: String) throws -> Any {
        guard path.utf8.count <= 256 else { throw ExteraPillError.invalidPath }
        var current = root
        for token in try self.tokens(path) {
            switch token {
            case let .key(key):
                if let array = current as? [Any], key == "length" {
                    current = array.count
                } else if let object = current as? [String: Any], let child = object[key] {
                    current = child
                } else { throw ExteraPillError.missingValue }
            case let .index(index):
                guard let array = current as? [Any] else { throw ExteraPillError.missingValue }
                // Avoid overflow for Int.min and Int.max, including malicious imported paths.
                guard index >= -array.count, index < array.count else { throw ExteraPillError.missingValue }
                current = array[index < 0 ? array.count + index : index]
            }
        }
        guard !(current is NSNull) else { throw ExteraPillError.missingValue }
        return current
    }
}

public enum ExteraPillFormatting {
    public static func render(_ value: Any, spec: ExteraPillSpec, locale: Locale = .current) throws -> String {
        let content: String
        switch spec.format {
        case .text:
            if let string = value as? String {
                content = string
            } else if let number = value as? NSNumber {
                content = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
            } else { throw ExteraPillError.missingValue }
        case .number, .percent, .bytes:
            let number: Double?
            if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
                number = value.doubleValue
            } else if let value = value as? String {
                number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            } else { number = nil }
            guard let number, number.isFinite else { throw ExteraPillError.invalidNumber }
            if spec.format == .bytes {
                guard number >= 0, number < Double(Int64.max) else { throw ExteraPillError.invalidNumber }
                content = ByteCountFormatter.string(fromByteCount: Int64(number), countStyle: .file)
            } else {
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = spec.format == .percent ? .percent : .decimal
                formatter.minimumFractionDigits = min(8, max(0, spec.decimals))
                formatter.maximumFractionDigits = min(8, max(0, spec.decimals))
                guard let string = formatter.string(from: NSNumber(value: number)) else { throw ExteraPillError.invalidNumber }
                content = string
            }
        }
        let normalized = (spec.prefix + content + spec.suffix).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !normalized.isEmpty else { throw ExteraPillError.missingValue }
        return String(normalized.prefix(128))
    }
}

/// Persists the complete ordered list atomically. Import validates everything before changing storage.
public final class ExteraPillSettings: @unchecked Sendable {
    public static let shared = ExteraPillSettings()
    public static let didChange = Notification.Name("ExteraPillSettingsDidChange")
    public static let maximumPills = 24
    public static let maximumFileSize = 64 * 1024
    private static let key = "extera.customHTTPPills.v1"

    private struct Document: Codable {
        var version: Int
        var pills: [ExteraPillSpec]
    }

    private let lock = NSRecursiveLock()
    private var value: [ExteraPillSpec]

    private init() {
        let string = AyuSettingsStore.shared.userDefaults.string(forKey: Self.key) ?? ""
        self.value = (try? Self.decode(Data(string.utf8))) ?? []
    }

    public var pills: [ExteraPillSpec] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.value
    }

    public func replace(_ pills: [ExteraPillSpec]) throws {
        try self.update { _ in pills }
    }

    private func update(_ transform: ([ExteraPillSpec]) -> [ExteraPillSpec]) throws {
        self.lock.lock()
        do {
            let validated = try Self.validate(transform(self.value))
            let data = try Self.encode(validated)
            self.value = validated
            // Writes are serialized with the in-memory snapshot; observers are notified after unlocking.
            AyuSettingsStore.shared.userDefaults.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
        } catch {
            self.lock.unlock()
            throw error
        }
        self.lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    public func upsert(_ spec: ExteraPillSpec) throws {
        try self.update { current in
            var pills = current
            if let index = pills.firstIndex(where: { $0.id == spec.id }) { pills[index] = spec }
            else { pills.append(spec) }
            return pills
        }
    }

    public func exportData() throws -> Data {
        return try Self.encode(self.pills)
    }

    public static func decode(_ data: Data) throws -> [ExteraPillSpec] {
        guard data.count <= Self.maximumFileSize else { throw ExteraPillError.invalidFile }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1 else { throw ExteraPillError.unsupportedVersion }
        return try self.validate(document.pills)
    }

    private static func validate(_ pills: [ExteraPillSpec]) throws -> [ExteraPillSpec] {
        guard pills.count <= Self.maximumPills else { throw ExteraPillError.limitReached }
        guard Set(pills.map { $0.id }).count == pills.count else { throw ExteraPillError.invalidFile }
        return try pills.map { try $0.validated() }
    }

    private static func encode(_ pills: [ExteraPillSpec]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, pills: pills))
        guard data.count <= Self.maximumFileSize else { throw ExteraPillError.invalidFile }
        return data
    }
}
