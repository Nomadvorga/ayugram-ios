import Foundation

public let ayuSettingsDidChangeNotification = AyuSettingsStore.didChangeNotification

// In-memory copy of the AyuGram settings. Hot paths (every network request, every message
// layout) read from here: UserDefaults is read once per key and written only on changes.
final class AyuSettingsStore: @unchecked Sendable {
    static let shared = AyuSettingsStore()

    // Posted after any AyuGram setting changes, for UI that shows a setting outside its screen.
    static let didChangeNotification = Notification.Name("AyuSettingsDidChange")

    let userDefaults: UserDefaults
    private let lock = NSLock()
    private var values: [String: Any] = [:]

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
        self.lock.lock()
        self.values[key] = value
        self.lock.unlock()
        self.userDefaults.set(value, forKey: key)
        NotificationCenter.default.post(name: AyuSettingsStore.didChangeNotification, object: nil)
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
        self.lock.lock()
        self.values[key] = value
        self.lock.unlock()
        self.userDefaults.set(value, forKey: key)
        NotificationCenter.default.post(name: AyuSettingsStore.didChangeNotification, object: nil)
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
        self.lock.lock()
        self.values[key] = value
        self.lock.unlock()
        self.userDefaults.set(value, forKey: key)
        NotificationCenter.default.post(name: AyuSettingsStore.didChangeNotification, object: nil)
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
        self.lock.lock()
        self.values[key] = value
        self.lock.unlock()
        self.userDefaults.set(value, forKey: key)
        NotificationCenter.default.post(name: AyuSettingsStore.didChangeNotification, object: nil)
    }
}
