import Foundation

public let ayuSettingsDidChangeNotification = AyuSettingsStore.didChangeNotification

// In-memory copy of the AyuGram settings. Hot paths (every network request, every message
// layout) read from here: UserDefaults is read once per key and written only on changes.
final class AyuSettingsStore: @unchecked Sendable {
    static let shared = AyuSettingsStore()

    // Posted after any AyuGram setting changes, for UI that shows a setting outside its screen.
    static let didChangeNotification = Notification.Name("AyuSettingsDidChange")

    let userDefaults: UserDefaults
    private let lock = NSRecursiveLock()
    private var values: [String: Any] = [:]
    private var explicitlyWrittenKeys: Set<String> = []
    private var batchDepth = 0

    private init() {
        self.userDefaults = UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard
    }

    func register(defaults: [String: Any]) {
        self.userDefaults.register(defaults: defaults)
    }

    func bool(_ key: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let value = self.values[key] as? Bool {
            return value
        }
        let value = self.userDefaults.bool(forKey: key)
        self.values[key] = value
        return value
    }

    func setBool(_ value: Bool, _ key: String) {
        self.setValue(value, key)
    }

    func int(_ key: String) -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let value = self.values[key] as? Int {
            return value
        }
        let value = self.userDefaults.integer(forKey: key)
        self.values[key] = value
        return value
    }

    func setInt(_ value: Int, _ key: String) {
        self.setValue(value, key)
    }

    func string(_ key: String) -> String {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let value = self.values[key] as? String {
            return value
        }
        let value = self.userDefaults.string(forKey: key) ?? ""
        self.values[key] = value
        return value
    }

    func setString(_ value: String, _ key: String) {
        self.setValue(value, key)
    }

    func intDictionary(_ key: String) -> [String: Int] {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let value = self.values[key] as? [String: Int] {
            return value
        }
        let value = self.userDefaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        self.values[key] = value
        return value
    }

    func setIntDictionary(_ value: [String: Int], _ key: String) {
        self.setValue(value, key)
    }

    /// Coalesces nested updates into one custom notification, including batches
    /// containing only Swiftgram-backed changes. No lock is held across caller code.
    func performBatchUpdates(_ updates: () -> Void) {
        self.lock.lock()
        self.batchDepth += 1
        self.lock.unlock()
        updates()
        self.lock.lock()
        self.batchDepth -= 1
        let notify = self.batchDepth == 0
        self.lock.unlock()
        if notify {
            NotificationCenter.default.post(name: AyuSettingsStore.didChangeNotification, object: nil)
        }
    }

    private func setValue<Value: Equatable>(_ value: Value, _ key: String) {
        self.lock.lock()
        // Registered defaults are also returned by object(forKey:). Track explicit
        // writes ourselves so migration-sensitive first writes always persist.
        if let current = self.values[key] as? Value, current == value, self.explicitlyWrittenKeys.contains(key) {
            self.lock.unlock()
            return
        }
        // Serialize the cache and defaults write together. Otherwise concurrent
        // writers can leave the disk holding an older value than the hot-path cache.
        self.values[key] = value
        self.explicitlyWrittenKeys.insert(key)
        // Foundation may deliver its own defaults notification synchronously.
        // A reentrant reader must see the new cache rather than deadlock or read
        // an older value; the recursive lock still serializes other writers.
        self.userDefaults.set(value, forKey: key)
        let notify = self.batchDepth == 0
        self.lock.unlock()
        // Observers can read or change settings; never call them while locked.
        if notify {
            NotificationCenter.default.post(name: AyuSettingsStore.didChangeNotification, object: nil)
        }
    }
}
