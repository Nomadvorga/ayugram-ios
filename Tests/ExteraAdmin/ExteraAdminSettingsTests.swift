import Foundation
import XCTest

#if canImport(SGSimpleSettings)
import SGSimpleSettings
#else
let APP_GROUP_IDENTIFIER = "ExteraAdminTests.Shared." + UUID().uuidString
let ayuSettingsDidChangeNotification = Notification.Name("ExteraAdminTestsDidChange")
#endif

final class ExteraAdminSettingsTests: XCTestCase {
    private final class ReentrantDefaults: UserDefaults, @unchecked Sendable {
        var willWrite: (() -> Void)?
        override func set(_ value: Any?, forKey defaultName: String) {
            self.willWrite?()
            super.set(value, forKey: defaultName)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { self.lock.lock(); self.count += 1; self.lock.unlock() }
        var value: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.count }
    }

    private func storage() -> (UserDefaults, String) {
        let name = "ExteraAdminTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    func testAndroidDefaultIsEnabledWithoutWritingOverExistingSettings() {
        let (defaults, name) = self.storage()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("keep", forKey: "unrelated")
        XCTAssertTrue(ExteraAdminSettings(defaults: defaults).quickAdminShortcuts)
        XCTAssertNil(defaults.object(forKey: ExteraAdminSettings.quickAdminShortcutsKey))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }

    func testFalsePersistsAcrossInstancesAndTrueCanBeRestoredThroughSetter() {
        let (defaults, name) = self.storage()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ExteraAdminSettings(defaults: defaults)
        settings.quickAdminShortcuts = false
        XCTAssertFalse(ExteraAdminSettings(defaults: defaults).quickAdminShortcuts)
        settings.quickAdminShortcuts = true
        XCTAssertTrue(settings.quickAdminShortcuts)
        XCTAssertTrue(ExteraAdminSettings(defaults: defaults).quickAdminShortcuts)
    }

    func testMalformedStoredValuesDoNotBecomeBooleanCoercions() {
        let (defaults, name) = self.storage()
        defer { defaults.removePersistentDomain(forName: name) }
        let invalidValues: [Any] = ["false", "0", 0, 1, [false], ["enabled": false]]
        for value in invalidValues {
            defaults.set(value, forKey: ExteraAdminSettings.quickAdminShortcutsKey)
            XCTAssertTrue(ExteraAdminSettings(defaults: defaults).quickAdminShortcuts)
        }
        defaults.set(false, forKey: ExteraAdminSettings.quickAdminShortcutsKey)
        XCTAssertFalse(ExteraAdminSettings(defaults: defaults).quickAdminShortcuts)
    }

    func testResetPersistsAndroidDefault() {
        let (defaults, name) = self.storage()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ExteraAdminSettings(defaults: defaults)
        settings.quickAdminShortcuts = false
        settings.reset()
        XCTAssertTrue(ExteraAdminSettings(defaults: defaults).quickAdminShortcuts)
    }

    func testFirstWriteOfDefaultPersistsAndRepeatedIdenticalWritesDoNotNotify() {
        let (defaults, name) = self.storage()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ExteraAdminSettings(defaults: defaults)
        let notifications = Counter()
        let observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { _ in notifications.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        settings.quickAdminShortcuts = true
        settings.quickAdminShortcuts = true
        settings.quickAdminShortcuts = false
        settings.quickAdminShortcuts = false
        XCTAssertEqual(notifications.value, 2)
        XCTAssertEqual(defaults.object(forKey: ExteraAdminSettings.quickAdminShortcutsKey) as? Bool, false)
    }

    func testCacheIsPublishedBeforeDefaultsReentersGetter() {
        let name = "ExteraAdminTests.Reentrant." + UUID().uuidString
        let defaults = ReentrantDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ExteraAdminSettings(defaults: defaults)
        XCTAssertTrue(settings.quickAdminShortcuts)
        defaults.willWrite = { XCTAssertFalse(settings.quickAdminShortcuts) }
        settings.quickAdminShortcuts = false
        defaults.willWrite = nil
        XCTAssertFalse(settings.quickAdminShortcuts)
    }

    func testConcurrentSettersLeaveCacheAndPersistentValueInAgreement() {
        let (defaults, name) = self.storage()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ExteraAdminSettings(defaults: defaults)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            settings.quickAdminShortcuts = index.isMultiple(of: 2)
            _ = settings.quickAdminShortcuts
        }
        XCTAssertEqual(settings.quickAdminShortcuts, ExteraAdminSettings(defaults: defaults).quickAdminShortcuts)
    }
}
