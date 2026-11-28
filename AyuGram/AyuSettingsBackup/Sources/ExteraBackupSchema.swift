// Ported from exteraGram for Android (com.exteragram.messenger.backup.PreferencesUtils, export / import / diff), GPL v3 or later, © exteraGram.

import Foundation

// One preference of a backup: where it lives in the file, which values are acceptable, how to read and write it.
public struct ExteraBackupEntry {
    public let group: String
    public let key: String
    // nil leaves the preference out of an export.
    let read: () -> ExteraBackupValue?
    // nil for a value the preference cannot take; otherwise what `read` will return once it is stored
    // (a preference may keep less than the file says) and the action that stores it.
    let write: (ExteraBackupValue) -> (stored: ExteraBackupValue, action: () -> Void)?

    public init(group: String, key: String, read: @escaping () -> ExteraBackupValue?, write: @escaping (ExteraBackupValue) -> (stored: ExteraBackupValue, action: () -> Void)?) {
        self.group = group
        self.key = key
        self.read = read
        self.write = write
    }

    public static func bool(_ key: String, group: String = ExteraBackupDocument.exteraConfig, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> ExteraBackupEntry {
        return ExteraBackupEntry(group: group, key: key, read: { .bool(get()) }, write: { value in
            guard let value = value.boolValue else {
                return nil
            }
            return (.bool(value), { set(value) })
        })
    }

    // `get` may return nil for a state the file cannot express; `accepts` returns false for a value the
    // preference refuses. `stored` is the value the preference keeps of an acceptable one, for example
    // the nearest of the states it has.
    public static func int(_ key: String, group: String = ExteraBackupDocument.exteraConfig, range: ClosedRange<Int>, get: @escaping () -> Int?, accepts: @escaping (Int) -> Bool = { _ in true }, stored: @escaping (Int) -> Int = { $0 }, set: @escaping (Int) -> Void) -> ExteraBackupEntry {
        return ExteraBackupEntry(group: group, key: key, read: { get().map { .number(Double($0)) } }, write: { value in
            guard let value = value.intValue, range.contains(value), accepts(value) else {
                return nil
            }
            let kept = stored(value)
            return (.number(Double(kept)), { set(kept) })
        })
    }

    public static func float(_ key: String, group: String = ExteraBackupDocument.exteraConfig, range: ClosedRange<Double>, get: @escaping () -> Double?, stored: @escaping (Double) -> Double = { $0 }, set: @escaping (Double) -> Void) -> ExteraBackupEntry {
        return ExteraBackupEntry(group: group, key: key, read: { get().map { .number($0) } }, write: { value in
            guard let value = value.floatValue, range.contains(value) else {
                return nil
            }
            let kept = stored(value)
            return (.number(kept), { set(kept) })
        })
    }

    public static func string(_ key: String, group: String = ExteraBackupDocument.exteraConfig, get: @escaping () -> String?, accepts: @escaping (String) -> Bool, stored: @escaping (String) -> String = { $0 }, set: @escaping (String) -> Void) -> ExteraBackupEntry {
        return ExteraBackupEntry(group: group, key: key, read: { get().map { .string($0) } }, write: { value in
            guard let value = value.stringValue, value.utf16.count <= 1024 * 1024, accepts(value) else {
                return nil
            }
            let kept = stored(value)
            return (.string(kept), { set(kept) })
        })
    }
}

public struct ExteraBackupSchema {
    public let entries: [ExteraBackupEntry]

    public init(entries: [ExteraBackupEntry]) {
        self.entries = entries
    }

    public func export() -> ExteraBackupDocument {
        var document = ExteraBackupDocument()
        for entry in self.entries {
            if let value = entry.read() {
                document.configs[entry.group, default: [:]][entry.key] = value
            }
        }
        return document
    }

    private func accepted(_ document: ExteraBackupDocument) -> [(ExteraBackupEntry, ExteraBackupValue, () -> Void)] {
        var result: [(ExteraBackupEntry, ExteraBackupValue, () -> Void)] = []
        for entry in self.entries {
            if let value = document.configs[entry.group]?[entry.key], let (stored, action) = entry.write(value) {
                result.append((entry, stored, action))
            }
        }
        return result
    }

    // A file counts as a backup when it holds at least one value this app can take.
    public func recognizes(_ document: ExteraBackupDocument) -> Bool {
        return !self.accepted(document).isEmpty
    }

    // How many preferences an import would change.
    public func differenceCount(_ document: ExteraBackupDocument) -> Int {
        return self.accepted(document).filter { $0.0.read() != $0.1 }.count
    }

    // Stores every acceptable value, in the order of the entries; returns how many were stored.
    @discardableResult
    public func apply(_ document: ExteraBackupDocument) -> Int {
        let accepted = self.accepted(document)
        for (_, _, action) in accepted {
            action()
        }
        return accepted.count
    }
}
