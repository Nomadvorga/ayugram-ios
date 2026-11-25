import Foundation

/// Local navigation layout. Stable string identifiers keep saved order independent of UI indices.
public final class ExteraNavigationSettings: @unchecked Sendable {
    public static let shared: ExteraNavigationSettings = {
        // Run Swiftgram's one-time defaults migration before inspecting its legacy preferences.
        let _ = SGSimpleSettings.shared
        return ExteraNavigationSettings(defaults: UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard, legacyDefaults: .standard)
    }()
    public static let storageKey = "extera.navigation.configuration"

    public enum BarMode: Int, Codable, CaseIterable { case show = 0, hide = 1, floating = 2 }
    public enum TabletMode: Int, Codable, CaseIterable { case automatic = 0, on = 1, off = 2 }
    public enum Tab: String, Codable, CaseIterable {
        case contacts, calls, news, chats, feed, settings
    }
    public enum MenuItem: String, Codable, CaseIterable {
        case profile, ghost, archive, newGroup, savedMessages, settings, feed, wallet
        case contacts, newChannel, calls, browser, qrCode
    }

    public struct Configuration: Codable, Equatable {
        public var barMode: BarMode = .floating
        public var tabletMode: TabletMode = .automatic
        public var hideLabels = false
        public var sidebar = false
        public var immersiveSidebar = true
        public var tabsCustomized = false
        public var tabs: [String] = ["contacts", "calls", "chats", "settings"]
        public var menu: [String] = ["profile", "ghost", "divider:default", "archive", "newGroup", "savedMessages", "settings", "feed", "wallet"]
        public var hiddenMenu: [String] = ["contacts", "newChannel", "calls", "browser", "qrCode"]

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case barMode, tabletMode, hideLabels, sidebar, immersiveSidebar, tabsCustomized, tabs, menu, hiddenMenu
        }

        public init(from decoder: Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.barMode = (try? values.decode(BarMode.self, forKey: .barMode)) ?? .floating
            self.tabletMode = (try? values.decode(TabletMode.self, forKey: .tabletMode)) ?? .automatic
            self.hideLabels = (try? values.decode(Bool.self, forKey: .hideLabels)) ?? false
            self.sidebar = (try? values.decode(Bool.self, forKey: .sidebar)) ?? false
            self.immersiveSidebar = (try? values.decode(Bool.self, forKey: .immersiveSidebar)) ?? true
            self.tabsCustomized = (try? values.decode(Bool.self, forKey: .tabsCustomized)) ?? false
            self.tabs = (try? values.decode([String].self, forKey: .tabs)) ?? self.tabs
            self.menu = (try? values.decode([String].self, forKey: .menu)) ?? self.menu
            self.hiddenMenu = (try? values.decode([String].self, forKey: .hiddenMenu)) ?? self.hiddenMenu
            self.normalize()
        }

        /// Chats and Settings are escape routes even if an imported layout removes every tab.
        public mutating func normalize() {
            var seen = Set<String>()
            self.tabs = self.tabs.filter { Tab(rawValue: $0) != nil && seen.insert($0).inserted }
            for tab in [Tab.chats, .settings] where !self.tabs.contains(tab.rawValue) { self.tabs.append(tab.rawValue) }
            seen.removeAll()
            self.menu = Array(self.menu.prefix(100)).filter {
                (MenuItem(rawValue: $0) != nil || Self.isValidDividerIdentifier($0)) && seen.insert($0).inserted
            }
            self.hiddenMenu = self.hiddenMenu.filter { MenuItem(rawValue: $0) != nil && seen.insert($0).inserted }
            for item in MenuItem.allCases where !seen.contains(item.rawValue) { self.hiddenMenu.append(item.rawValue) }
            // Hiding the bar must never hide the only Settings route in its menu.
            if self.barMode == .hide && !self.menu.contains(MenuItem.settings.rawValue) {
                self.hiddenMenu.removeAll { $0 == MenuItem.settings.rawValue }
                if self.menu.count == 100 { self.menu.removeLast() }
                self.menu.append(MenuItem.settings.rawValue)
            }
            // An item displaced by the Settings escape route remains available in the editor.
            for item in MenuItem.allCases where !self.menu.contains(item.rawValue) && !self.hiddenMenu.contains(item.rawValue) {
                self.hiddenMenu.append(item.rawValue)
            }
        }

        public static func isDivider(_ id: String) -> Bool { return id.hasPrefix("divider:") }

        fileprivate static func isValidDividerIdentifier(_ id: String) -> Bool {
            guard Self.isDivider(id) else { return false }
            let suffix = id.dropFirst("divider:".count)
            return !suffix.isEmpty && suffix.utf8.count <= 64 && suffix.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45 || byte == 95
            }
        }

        public mutating func setTab(_ tab: Tab, visible: Bool) {
            guard tab != .chats && tab != .settings else { return }
            self.tabsCustomized = true
            self.tabs.removeAll { $0 == tab.rawValue }
            if visible { self.tabs.insert(tab.rawValue, at: max(0, self.tabs.count - 1)) }
            self.normalize()
        }

        public mutating func toggleMenuItem(_ id: String) {
            if Self.isDivider(id) { self.menu.removeAll { $0 == id }; return }
            guard MenuItem(rawValue: id) != nil else { return }
            if self.menu.contains(id) {
                guard self.barMode != .hide || id != MenuItem.settings.rawValue else { return }
                self.menu.removeAll { $0 == id }
                self.hiddenMenu.insert(id, at: 0)
            } else {
                self.hiddenMenu.removeAll { $0 == id }
                self.menu.append(id)
            }
            self.normalize()
        }

        public mutating func addDivider() {
            guard self.menu.count < 100 else { return }
            self.menu.append("divider:" + UUID().uuidString)
        }

        public func visibleTabs(contacts: Bool, calls: Bool, news: Bool) -> [Tab] {
            if self.tabsCustomized { return self.tabs.compactMap(Tab.init(rawValue:)) }
            return ([contacts ? Tab.contacts : nil, calls ? .calls : nil, news ? .news : nil, .chats, .settings]).compactMap { $0 }
        }

        /// A two-column screen needs room for both panes; enabling it never scales a phone UI down.
        public func usesTabletLayout(availableWidth: Double, systemIsRegular: Bool) -> Bool {
            switch self.tabletMode {
            case .automatic: return systemIsRegular
            case .on: return availableWidth >= 700.0
            case .off: return false
            }
        }
    }

    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults
    private let lock = NSRecursiveLock()
    private var cachedConfiguration: Configuration?

    /// Injectable defaults make persistence and migrations testable without the application bundle.
    public init(defaults: UserDefaults, legacyDefaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults ?? defaults
    }

    public var configuration: Configuration {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let value = self.cachedConfiguration { return value }
        if let string = self.defaults.string(forKey: Self.storageKey), let data = string.data(using: .utf8), let value = try? JSONDecoder().decode(Configuration.self, from: data) {
            self.cachedConfiguration = value
            return value
        }
        var result = Configuration()
        // Legacy Swiftgram preferences live in standard defaults. Only explicit values migrate.
        if let hidden = self.legacyDefaults.object(forKey: "hideTabBar") as? Bool { result.barMode = hidden ? .hide : .floating }
        if let names = self.legacyDefaults.object(forKey: "showTabNames") as? Bool { result.hideLabels = !names }
        result.normalize()
        self.cachedConfiguration = result
        return result
    }

    /// A single validated backup value; no tab or menu controller is serialized.
    public var configurationJSON: String {
        let data = try? JSONEncoder().encode(self.configuration)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    @discardableResult public func restoreConfigurationJSON(_ string: String) -> Bool {
        guard let value = Self.decodeValidatedConfigurationJSON(string) else { return false }
        self.update { $0 = value }
        return true
    }

    /// Pure strict backup validation. Unlike legacy disk decoding, this never repairs invalid input.
    public static func isValidConfigurationJSON(_ string: String) -> Bool {
        return Self.decodeValidatedConfigurationJSON(string) != nil
    }

    private struct StrictConfiguration: Decodable {
        let barMode: BarMode
        let tabletMode: TabletMode
        let hideLabels: Bool
        let sidebar: Bool
        let immersiveSidebar: Bool
        let tabsCustomized: Bool
        let tabs: [String]
        let menu: [String]
        let hiddenMenu: [String]
    }

    private static func decodeValidatedConfigurationJSON(_ string: String) -> Configuration? {
        guard string.utf8.count <= 32768, let data = string.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any],
            Set(dictionary.keys) == Set(["barMode", "tabletMode", "hideLabels", "sidebar", "immersiveSidebar", "tabsCustomized", "tabs", "menu", "hiddenMenu"]),
            let value = try? JSONDecoder().decode(StrictConfiguration.self, from: data) else { return nil }
        guard value.tabs.count <= Tab.allCases.count, value.tabs.count >= 2,
            Set(value.tabs).count == value.tabs.count,
            value.tabs.allSatisfy({ Tab(rawValue: $0) != nil }),
            value.tabs.contains(Tab.chats.rawValue), value.tabs.contains(Tab.settings.rawValue),
            value.menu.count <= 100, value.hiddenMenu.count <= MenuItem.allCases.count else { return nil }
        let identifiers = value.menu + value.hiddenMenu
        guard Set(identifiers).count == identifiers.count,
            value.hiddenMenu.allSatisfy({ MenuItem(rawValue: $0) != nil }),
            value.menu.allSatisfy({ id in
                if MenuItem(rawValue: id) != nil { return true }
                return Configuration.isValidDividerIdentifier(id)
            }),
            Set(identifiers.filter { !Configuration.isDivider($0) }) == Set(MenuItem.allCases.map { $0.rawValue }),
            value.barMode != .hide || value.menu.contains(MenuItem.settings.rawValue) else { return nil }
        var result = Configuration()
        result.barMode = value.barMode
        result.tabletMode = value.tabletMode
        result.hideLabels = value.hideLabels
        result.sidebar = value.sidebar
        result.immersiveSidebar = value.immersiveSidebar
        result.tabsCustomized = value.tabsCustomized
        result.tabs = value.tabs
        result.menu = value.menu
        result.hiddenMenu = value.hiddenMenu
        return result
    }

    public func update(_ body: (inout Configuration) -> Void) {
        self.lock.lock()
        var value = self.configuration
        body(&value)
        value.normalize()
        // Foundation observers may reenter synchronously during defaults.set; they see this value.
        self.cachedConfiguration = value
        if let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) { self.defaults.set(string, forKey: Self.storageKey) }
        self.lock.unlock()
        NotificationCenter.default.post(name: ayuSettingsDidChangeNotification, object: nil)
    }

    public func reset() { self.update { $0 = Configuration() } }
}
