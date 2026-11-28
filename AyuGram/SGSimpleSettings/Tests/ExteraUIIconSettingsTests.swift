import Foundation
import SGSimpleSettings
import XCTest

final class ExteraUIIconSettingsTests: XCTestCase {
    func testUnknownAndMalformedPreferenceUsesNative() {
        XCTAssertEqual(ExteraUIIconPack.normalized(nil), .native)
        XCTAssertEqual(ExteraUIIconPack.normalized(""), .native)
        XCTAssertEqual(ExteraUIIconPack.normalized("base.future"), .native)
        XCTAssertEqual(ExteraUIIconPack.normalized("base.solar"), .solar)
        XCTAssertEqual(ExteraUIIconPack.normalized("base.remix"), .remix)
        let name = "ExteraUIIconSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["base.solar"], forKey: ExteraUIIconSettings.storageKey)
        XCTAssertEqual(ExteraUIIconSettings(defaults: defaults).pack, .native)
    }

    func testSelectionSurvivesNewSettingsInstanceAndNativeReset() {
        let name = "ExteraUIIconSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ExteraUIIconSettings(defaults: defaults)
        XCTAssertEqual(settings.pack, .native)
        settings.select(.solar)
        XCTAssertEqual(ExteraUIIconSettings(defaults: defaults).pack, .solar)
        settings.select(.remix)
        XCTAssertEqual(ExteraUIIconSettings(defaults: defaults).pack, .remix)
        settings.select(.native)
        XCTAssertEqual(ExteraUIIconSettings(defaults: defaults).pack, .native)
        XCTAssertEqual(defaults.string(forKey: ExteraUIIconSettings.storageKey), "base.default")
    }
}
