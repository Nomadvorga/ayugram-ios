import CoreFoundation
import Foundation

/// Controls shortcut visibility only. Every administrative action still requires live server rights.
public final class ExteraAdminSettings: @unchecked Sendable {
    public static let shared = ExteraAdminSettings(defaults: UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard)
    public static let quickAdminShortcutsKey = "extera.chat.quickAdminShortcuts"

    private let defaults: UserDefaults
    private let lock = NSRecursiveLock()
    private var cachedValue: Bool?
    private var explicitlyWritten = false

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Android ExteraConfig.quickAdminShortcuts defaults to true. No existing preference is replaced.
    public var quickAdminShortcuts: Bool {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            if let value = self.cachedValue { return value }
            let value: Bool
            if let stored = self.defaults.object(forKey: Self.quickAdminShortcutsKey) as? NSNumber,
                CFGetTypeID(stored) == CFBooleanGetTypeID() {
                value = stored.boolValue
            } else {
                value = true
            }
            self.cachedValue = value
            return value
        }
        set {
            self.lock.lock()
            if self.explicitlyWritten && self.cachedValue == newValue {
                self.lock.unlock()
                return
            }
            self.cachedValue = newValue
            self.explicitlyWritten = true
            self.defaults.set(newValue, forKey: Self.quickAdminShortcutsKey)
            self.lock.unlock()
            NotificationCenter.default.post(name: ayuSettingsDidChangeNotification, object: nil)
        }
    }

    public func reset() { self.quickAdminShortcuts = true }
}
