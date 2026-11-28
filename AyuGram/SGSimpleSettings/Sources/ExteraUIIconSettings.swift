import Foundation

/// Built-in UI glyph families. These identifiers are independent of alternate app icons.
public enum ExteraUIIconPack: String, CaseIterable, Codable, Sendable {
    case native = "base.default"
    case solar = "base.solar"
    case remix = "base.remix"

    public static func normalized(_ identifier: String?) -> ExteraUIIconPack {
        return identifier.flatMap(Self.init(rawValue:)) ?? .native
    }

    public var author: String {
        switch self {
        case .native: return "Telegram"
        case .solar: return "@Design480"
        case .remix: return "Remix-Design"
        }
    }
}

/// Device-local, app-group selection. Unsupported or corrupt values resolve to native artwork.
public final class ExteraUIIconSettings: @unchecked Sendable {
    public static let shared: ExteraUIIconSettings = {
        let _ = SGSimpleSettings.shared
        return ExteraUIIconSettings(defaults: UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard)
    }()
    public static let storageKey = "extera.uiIcons.basePack"
    public static let didChange = Notification.Name("ExteraUIIconSettingsDidChange")

    private let defaults: UserDefaults
    private let lock = NSRecursiveLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var pack: ExteraUIIconPack {
        self.lock.lock()
        defer { self.lock.unlock() }
        return ExteraUIIconPack.normalized(self.defaults.string(forKey: Self.storageKey))
    }

    public func select(_ pack: ExteraUIIconPack) {
        self.lock.lock()
        let changed = self.pack != pack
        self.defaults.set(pack.rawValue, forKey: Self.storageKey)
        self.lock.unlock()
        if changed {
            NotificationCenter.default.post(name: Self.didChange, object: self)
            NotificationCenter.default.post(name: ayuSettingsDidChangeNotification, object: nil)
        }
    }
}
