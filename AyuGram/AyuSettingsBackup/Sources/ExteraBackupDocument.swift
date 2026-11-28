// Ported from exteraGram for Android (com.exteragram.messenger.backup.PreferencesUtils, the file format), GPL v3 or later, © exteraGram.

import Foundation

public enum ExteraBackupValue: Equatable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case strings([String])

    public var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }

    // A number without a fraction that fits Int32, the only integers Android's preferences hold.
    public var intValue: Int? {
        if case let .number(value) = self, value.isFinite, value == value.rounded(), abs(value) <= Double(Int32.max) {
            return Int(value)
        }
        return nil
    }

    public var floatValue: Double? {
        if case let .number(value) = self, value.isFinite {
            return value
        }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }
}

// A ".extera" settings backup: named groups of preferences, the same file exteraGram for Android writes.
public struct ExteraBackupDocument: Equatable {
    public static let fileExtension = "extera"
    public static let exteraConfig = "exteraconfig"
    public static let mainConfig = "mainconfig"
    // Preferences that exist only in AyuGram for iOS; Android skips groups it does not know.
    public static let iosConfig = "ayugramios"
    public static let maxFileSize = 4 * 1024 * 1024

    public var configs: [String: [String: ExteraBackupValue]]

    public init(configs: [String: [String: ExteraBackupValue]] = [:]) {
        self.configs = configs
    }

    public static func isBackupFile(name: String?) -> Bool {
        return name?.lowercased().hasSuffix("." + self.fileExtension) ?? false
    }

    public static func generateName(_ custom: String? = nil) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let suffix = String((0 ..< 4).map { _ in alphabet[Int.random(in: 0 ..< alphabet.count)] })
        return "\(custom ?? "backup")-\(suffix).\(self.fileExtension)"
    }

    // nil for a file that is too large, is not text, or does not hold a JSON object of objects.
    public init?(fileData: Data) {
        guard fileData.count <= ExteraBackupDocument.maxFileSize, let raw = String(data: fileData, encoding: .utf8) else {
            return nil
        }
        // Android reads the file line by line and joins the lines.
        var text = String(raw.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }.map(Character.init))
        if InvisibleEncryptor.isEncrypted(text) {
            guard let decoded = InvisibleEncryptor.decode(text) else {
                return nil
            }
            text = decoded
        }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return nil
        }
        var configs: [String: [String: ExteraBackupValue]] = [:]
        for name in root.keys.sorted() {
            guard let object = root[name] as? [String: Any] else {
                continue
            }
            var values: [String: ExteraBackupValue] = [:]
            for (key, value) in object {
                if let parsed = ExteraBackupDocument.value(value) {
                    values[key] = parsed
                }
            }
            // Old backups name the group of the main preferences after the account: "mainconfig1".
            var group = name
            if name.hasPrefix(ExteraBackupDocument.mainConfig), name != ExteraBackupDocument.mainConfig {
                let suffix = name.dropFirst(ExteraBackupDocument.mainConfig.count)
                if suffix.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) {
                    if root[ExteraBackupDocument.mainConfig] is [String: Any] || configs[ExteraBackupDocument.mainConfig] != nil {
                        continue
                    }
                    group = ExteraBackupDocument.mainConfig
                }
            }
            configs[group] = values
        }
        self.configs = configs
    }

    private static func value(_ value: Any) -> ExteraBackupValue? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let string = value as? String {
            return .string(string)
        }
        if let array = value as? [Any] {
            var strings: [String] = []
            for item in array {
                guard let string = item as? String else {
                    return nil
                }
                strings.append(string)
            }
            return .strings(strings)
        }
        return nil
    }

    public func json() -> String {
        var root: [String: Any] = [:]
        for (name, values) in self.configs where !values.isEmpty {
            var object: [String: Any] = [:]
            for (key, value) in values {
                switch value {
                case let .bool(value):
                    object[key] = value
                case let .number(value):
                    if value.isFinite, value == value.rounded(), abs(value) <= Double(Int32.max) {
                        object[key] = Int(value)
                    } else if value.isFinite {
                        object[key] = value
                    }
                case let .string(value):
                    object[key] = value
                case let .strings(value):
                    object[key] = value
                }
            }
            root[name] = object
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    public func fileData(encrypt: Bool = true) -> Data {
        let json = self.json()
        return Data((encrypt ? InvisibleEncryptor.encode(json) : json).utf8)
    }
}
