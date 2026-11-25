import Foundation
import XCTest

#if canImport(SGSimpleSettings)
import SGSimpleSettings
#else
// The direct-source host target needs only these application storage bindings.
let APP_GROUP_IDENTIFIER = "ExteraNavigationTests." + UUID().uuidString
let ayuSettingsDidChangeNotification = Notification.Name("ExteraNavigationTestsDidChange")
final class SGSimpleSettings { static let shared = SGSimpleSettings() }
#endif

final class ExteraNavigationSettingsTests: XCTestCase {
    typealias Settings = ExteraNavigationSettings

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { self.lock.lock(); self.count += 1; self.lock.unlock() }
        var value: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.count }
    }

    private final class ReentrantDefaults: UserDefaults, @unchecked Sendable {
        var willWrite: (() -> Void)?
        override func set(_ value: Any?, forKey defaultName: String) {
            self.willWrite?()
            super.set(value, forKey: defaultName)
        }
    }

    private func storage() -> (UserDefaults, String) {
        let name = "ExteraNavigationTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    func testDefaultsAndLegacyTabFlagsDoNotEnableFeed() {
        let config = Settings.Configuration()
        XCTAssertFalse(config.tabs.contains("feed"))
        XCTAssertEqual(config.visibleTabs(contacts: false, calls: true, news: false), [.calls, .chats, .settings])
        XCTAssertEqual(config.visibleTabs(contacts: true, calls: false, news: true), [.contacts, .news, .chats, .settings])
    }

    func testCustomizedOrderIsStableAcrossLegacyAccountUpdates() {
        var config = Settings.Configuration()
        config.tabs = ["settings", "feed", "chats", "contacts"]
        config.tabsCustomized = true
        config.normalize()
        XCTAssertEqual(config.visibleTabs(contacts: false, calls: true, news: true), [.settings, .feed, .chats, .contacts])
        config.setTab(.feed, visible: false)
        XCTAssertEqual(config.tabs, ["settings", "chats", "contacts"])
        config.setTab(.feed, visible: true)
        XCTAssertEqual(config.tabs, ["settings", "chats", "feed", "contacts"])
        config.setTab(.chats, visible: false)
        config.setTab(.settings, visible: false)
        XCTAssertTrue(config.tabs.contains("chats"))
        XCTAssertTrue(config.tabs.contains("settings"))
    }

    func testNormalizationRemovesUnknownTabsAndDuplicatesAndRestoresEscapeRoutes() {
        var config = Settings.Configuration()
        config.tabs = ["feed", "plugins", "feed"]
        config.normalize()
        XCTAssertEqual(config.tabs, ["feed", "chats", "settings"])
    }

    func testMenuHidingShowingAndDividerIdentity() {
        var config = Settings.Configuration()
        config.toggleMenuItem("archive")
        XCTAssertFalse(config.menu.contains("archive"))
        XCTAssertEqual(config.hiddenMenu.first, "archive")
        config.toggleMenuItem("archive")
        XCTAssertEqual(config.menu.last, "archive")
        XCTAssertFalse(config.hiddenMenu.contains("archive"))
        config.addDivider()
        let divider = config.menu.last!
        config.addDivider()
        XCTAssertNotEqual(config.menu.last, divider)
        config.toggleMenuItem(divider)
        XCTAssertFalse(config.menu.contains(divider))
        XCTAssertFalse(config.hiddenMenu.contains(divider))
    }

    func testHiddenBarKeepsSettingsInMenu() {
        var config = Settings.Configuration()
        config.toggleMenuItem("settings")
        XCTAssertFalse(config.menu.contains("settings"))
        config.barMode = .hide
        config.normalize()
        XCTAssertTrue(config.menu.contains("settings"))
        XCTAssertFalse(config.hiddenMenu.contains("settings"))
        config.toggleMenuItem("settings")
        XCTAssertTrue(config.menu.contains("settings"))
    }

    func testMenuLimitKeepsSettingsAndBackupRoundTripValid() throws {
        var config = Settings.Configuration()
        config.menu = (0 ..< 99).map { "divider:\($0)" } + ["profile"]
        config.barMode = .hide
        config.normalize()
        XCTAssertEqual(config.menu.count, 100)
        XCTAssertEqual(config.menu.last, "settings")
        XCTAssertTrue(config.hiddenMenu.contains("profile"))
        let before = config
        config.addDivider()
        XCTAssertEqual(config, before)
        XCTAssertTrue(Settings.isValidConfigurationJSON(String(data: try JSONEncoder().encode(config), encoding: .utf8)!))
    }

    func testUnsupportedMenuItemsAreRemovedAndEverySupportedItemAppearsExactlyOnce() {
        var config = Settings.Configuration()
        config.menu = ["profile", "profile", "plugins", "exit", "divider:a", "divider:a"]
        config.hiddenMenu = ["profile", "ghost", "ghost", "divider:b"]
        config.normalize()
        XCTAssertEqual(config.menu, ["profile", "divider:a"])
        XCTAssertEqual(config.hiddenMenu.first, "ghost")
        let items = (config.menu + config.hiddenMenu).filter { !Settings.Configuration.isDivider($0) }
        XCTAssertEqual(Set(items), Set(Settings.MenuItem.allCases.map { $0.rawValue }))
        XCTAssertEqual(items.count, Settings.MenuItem.allCases.count)
    }

    func testTabletModeRespondsToActualAvailableWidth() {
        var config = Settings.Configuration()
        XCTAssertTrue(config.usesTabletLayout(availableWidth: 1024, systemIsRegular: true))
        XCTAssertFalse(config.usesTabletLayout(availableWidth: 600, systemIsRegular: false))
        config.tabletMode = .on
        XCTAssertFalse(config.usesTabletLayout(availableWidth: 699, systemIsRegular: false))
        XCTAssertTrue(config.usesTabletLayout(availableWidth: 700, systemIsRegular: false))
        config.tabletMode = .off
        XCTAssertFalse(config.usesTabletLayout(availableWidth: 1366, systemIsRegular: true))
    }

    func testPersistenceAcrossInstancesAndCompoundChangePublishesOnce() {
        let (defaults, name) = self.storage()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        let count = Counter()
        let observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { _ in count.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        settings.update {
            $0.setTab(.feed, visible: true)
            $0.hideLabels = true
            $0.barMode = .hide
            $0.tabletMode = .off
            $0.menu = ["savedMessages", "settings", "divider:persist", "profile"]
        }
        XCTAssertEqual(count.value, 1)
        let reloaded = Settings(defaults: defaults).configuration
        XCTAssertEqual(reloaded, settings.configuration)
        XCTAssertTrue(reloaded.tabs.contains("feed"))
        XCTAssertEqual(Array(reloaded.menu.prefix(3)), ["savedMessages", "settings", "divider:persist"])
        XCTAssertNotNil(defaults.string(forKey: Settings.storageKey))
    }

    func testLegacyMigrationUsesSeparateStandardDomainAndNewConfigurationWins() {
        let (defaults, name) = self.storage()
        let (legacy, legacyName) = self.storage()
        defer { defaults.removePersistentDomain(forName: name); legacy.removePersistentDomain(forName: legacyName) }
        legacy.set(true, forKey: "hideTabBar")
        legacy.set(false, forKey: "showTabNames")
        let settings = Settings(defaults: defaults, legacyDefaults: legacy)
        XCTAssertEqual(settings.configuration.barMode, .hide)
        XCTAssertTrue(settings.configuration.hideLabels)
        settings.update { $0.barMode = .show; $0.hideLabels = false }
        XCTAssertEqual(Settings(defaults: defaults, legacyDefaults: legacy).configuration.barMode, .show)
        XCTAssertFalse(settings.configuration.hideLabels)
    }

    func testLegacyDiskDecodingSanitizesFutureEnumsUnknownItemsAndMissingFields() throws {
        let (defaults, name) = self.storage()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("{\"barMode\":99,\"tabletMode\":99,\"tabsCustomized\":true,\"tabs\":[\"feed\",\"plugins\"],\"menu\":[\"exit\",\"profile\"]}", forKey: Settings.storageKey)
        let settings = Settings(defaults: defaults)
        XCTAssertEqual(settings.configuration.barMode, .floating)
        XCTAssertEqual(settings.configuration.tabletMode, .automatic)
        XCTAssertEqual(settings.configuration.tabs, ["feed", "chats", "settings"])
        XCTAssertEqual(settings.configuration.menu, ["profile"])
        let saved = settings.configuration
        XCTAssertFalse(settings.restoreConfigurationJSON("this is not JSON"))
        XCTAssertEqual(settings.configuration, saved)
        XCTAssertEqual(try JSONDecoder().decode(Settings.Configuration.self, from: Data(settings.configurationJSON.utf8)), saved)
        settings.reset()
        XCTAssertEqual(settings.configuration, Settings.Configuration())
    }

    func testStrictBackupValidatorRejectsMalformedFieldsWithoutRepairing() throws {
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings.Configuration())) as! [String: Any]
        let malformed: [(String, Any)] = [
            ("barMode", 99), ("barMode", true), ("barMode", "2"),
            ("tabletMode", -1), ("hideLabels", 1), ("sidebar", "false"),
            ("tabs", ["feed", "settings"]), ("tabs", ["chats", "settings", "chats"]),
            ("tabs", ["chats", "settings", "plugins"]), ("tabs", [1, 2]),
            ("menu", Array(repeating: "divider:a", count: 101)),
            ("menu", ["profile", "exit"]), ("menu", ["profile", "divider:"]),
            ("menu", ["profile", "divider:bad id"]), ("menu", ["profile", "divider:" + String(repeating: "a", count: 65)]),
            ("hiddenMenu", ["divider:bad"]), ("hiddenMenu", ["ghost", "ghost"])
        ]
        for (key, invalid) in malformed {
            var object = base
            object[key] = invalid
            let json = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            XCTAssertFalse(Settings.isValidConfigurationJSON(json), "accepted invalid \(key): \(invalid)")
        }
        var missing = base
        missing.removeValue(forKey: "hideLabels")
        XCTAssertFalse(Settings.isValidConfigurationJSON(String(data: try JSONSerialization.data(withJSONObject: missing), encoding: .utf8)!))
        var unknown = base
        unknown["plugins"] = false
        XCTAssertFalse(Settings.isValidConfigurationJSON(String(data: try JSONSerialization.data(withJSONObject: unknown), encoding: .utf8)!))
        XCTAssertFalse(Settings.isValidConfigurationJSON("{}"))
        XCTAssertFalse(Settings.isValidConfigurationJSON("[]"))
        XCTAssertFalse(Settings.isValidConfigurationJSON(String(repeating: " ", count: 32769)))
    }

    func testStrictBackupRoundTripAndRestoreUpdatesCachedValue() {
        let (defaults, name) = self.storage()
        defer { defaults.removePersistentDomain(forName: name) }
        let source = Settings(defaults: defaults)
        source.update { $0.setTab(.feed, visible: true); $0.sidebar = true; $0.addDivider() }
        let json = source.configurationJSON
        XCTAssertTrue(Settings.isValidConfigurationJSON(json))
        source.reset()
        XCTAssertFalse(source.configuration.tabs.contains("feed"))
        XCTAssertTrue(source.restoreConfigurationJSON(json))
        XCTAssertTrue(source.configuration.tabs.contains("feed"))
        XCTAssertTrue(source.configuration.sidebar)
        let before = source.configuration
        XCTAssertFalse(source.restoreConfigurationJSON("{\"tabs\":[\"feed\"]}"))
        XCTAssertEqual(source.configuration, before)
    }

    func testCacheIsStableUntilAnOwnedWrite() {
        let (defaults, name) = self.storage()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        let first = settings.configuration
        defaults.set("not JSON", forKey: Settings.storageKey)
        XCTAssertEqual(settings.configuration, first)
        settings.update { $0.hideLabels = true }
        XCTAssertTrue(settings.configuration.hideLabels)
        XCTAssertTrue(Settings(defaults: defaults).configuration.hideLabels)
    }

    func testReentrantDefaultsObserverSeesPublishedConfiguration() {
        let name = "ExteraNavigationTests." + UUID().uuidString
        let defaults = ReentrantDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.configuration.hideLabels)
        let observations = Counter()
        defaults.willWrite = {
            observations.increment()
            XCTAssertTrue(settings.configuration.hideLabels)
            XCTAssertTrue(settings.configuration.tabs.contains("feed"))
        }
        settings.update { $0.hideLabels = true; $0.setTab(.feed, visible: true) }
        XCTAssertEqual(observations.value, 1)
        defaults.willWrite = nil
    }

    func testConcurrentCompoundWritesKeepEveryDivider() {
        let (defaults, name) = self.storage()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        let originalCount = settings.configuration.menu.count
        DispatchQueue.concurrentPerform(iterations: 64) { _ in settings.update { $0.addDivider() } }
        let config = settings.configuration
        XCTAssertEqual(config.menu.count, originalCount + 64)
        XCTAssertEqual(Set(config.menu).count, config.menu.count)
        XCTAssertEqual(Settings(defaults: defaults).configuration, config)
        XCTAssertTrue(Settings.isValidConfigurationJSON(settings.configurationJSON))
    }
}
