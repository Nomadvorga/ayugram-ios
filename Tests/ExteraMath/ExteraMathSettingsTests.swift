import Foundation
import XCTest

// Production settings/store compiled unchanged in the host test target. Never use
// the application's real app-group preferences from the isolated XCTest process.
let APP_GROUP_IDENTIFIER = "ExteraMathSettingsTests.\(UUID().uuidString)"

final class ExteraMathSettingsTests: XCTestCase {
    func testMeasureSystemMigrationPreservesExplicitLegacyValues() {
        XCTAssertEqual(ExteraMathSettings.measureSystem(rawValue: "", legacyImperial: nil), .auto)
        XCTAssertEqual(ExteraMathSettings.measureSystem(rawValue: "", legacyImperial: false), .metric)
        XCTAssertEqual(ExteraMathSettings.measureSystem(rawValue: "", legacyImperial: true), .imperial)
        XCTAssertEqual(ExteraMathSettings.measureSystem(rawValue: "invalid", legacyImperial: true), .imperial)
        XCTAssertEqual(ExteraMathSettings.measureSystem(rawValue: "auto", legacyImperial: true), .auto)
        XCTAssertEqual(ExteraMathSettings.measureSystem(rawValue: "metric", legacyImperial: true), .metric)
        XCTAssertEqual(ExteraMathSettings.measureSystem(rawValue: "imperial", legacyImperial: false), .imperial)
    }

    func testAutomaticMeasurementsFollowRegionAndExplicitChoicesOverrideIt() {
        let us = Locale(identifier: "en_US")
        let france = Locale(identifier: "fr_FR")
        XCTAssertTrue(ExteraMathSettings.usesImperial(.auto, locale: us))
        XCTAssertFalse(ExteraMathSettings.usesImperial(.auto, locale: france))
        XCTAssertFalse(ExteraMathSettings.usesImperial(.auto, locale: Locale(identifier: "en_GB")))
        XCTAssertTrue(ExteraMathSettings.usesImperial(.auto, locale: Locale(identifier: "en_LR")))
        XCTAssertTrue(ExteraMathSettings.usesImperial(.auto, locale: Locale(identifier: "my_MM")))
        XCTAssertFalse(ExteraMathSettings.usesImperial(.metric, locale: us))
        XCTAssertTrue(ExteraMathSettings.usesImperial(.imperial, locale: france))
    }

    func testLegacyFacadeAndPersistedKeyStayConsistent() {
        let settings = ExteraMathSettings.shared
        let previous = settings.inlineMeasureSystem
        defer { settings.inlineMeasureSystem = previous }
        settings.inlineImperial = true
        XCTAssertEqual(settings.inlineMeasureSystem, .imperial)
        XCTAssertEqual(AyuSettingsStore.shared.userDefaults.string(forKey: "extera.inlineMeasureSystem"), "imperial")
        XCTAssertTrue(AyuSettingsStore.shared.userDefaults.bool(forKey: "extera.inlineImperial"))
        settings.inlineImperial = false
        XCTAssertEqual(settings.inlineMeasureSystem, .metric)
        XCTAssertFalse(AyuSettingsStore.shared.userDefaults.bool(forKey: "extera.inlineImperial"))
        settings.inlineMeasureSystem = .auto
        XCTAssertEqual(settings.inlineImperial, ExteraMathSettings.usesImperial(.auto, locale: .current))
    }

    func testRuntimeOptionsReadIndependentFlagsAndHelpCanPreviewDisabledFeatures() {
        let settings = ExteraMathSettings.shared
        let previous = (settings.inlineResults, settings.inlineMathResult, settings.inlineUnits, settings.inlineCurrencies, settings.inlineTimeZones, settings.inlineDigitGrouping, settings.inlineAngleUnit, settings.inlineMeasureSystem, settings.inlineTargetCurrency)
        defer {
            settings.inlineResults = previous.0
            settings.inlineMathResult = previous.1
            settings.inlineUnits = previous.2
            settings.inlineCurrencies = previous.3
            settings.inlineTimeZones = previous.4
            settings.inlineDigitGrouping = previous.5
            settings.inlineAngleUnit = previous.6
            settings.inlineMeasureSystem = previous.7
            settings.inlineTargetCurrency = previous.8
        }
        settings.inlineResults = false
        settings.inlineMathResult = false
        settings.inlineUnits = false
        settings.inlineCurrencies = false
        settings.inlineTimeZones = false
        settings.inlineDigitGrouping = false
        settings.inlineAngleUnit = .radians
        settings.inlineMeasureSystem = .imperial
        settings.inlineTargetCurrency = "EUR"
        let runtime = ExteraMathEngine.Options(settings: settings)
        XCTAssertFalse(runtime.arithmetic)
        XCTAssertFalse(runtime.units)
        XCTAssertFalse(runtime.currencies)
        XCTAssertFalse(runtime.timeZones)
        XCTAssertFalse(runtime.grouping)
        XCTAssertFalse(runtime.degrees)
        XCTAssertTrue(runtime.imperial)
        XCTAssertEqual(runtime.localCurrency, "EUR")
        let help = ExteraMathEngine.Options(settings: settings, preview: true)
        XCTAssertTrue(help.arithmetic && help.units && help.currencies && help.timeZones)
        XCTAssertFalse(help.degrees)
        XCTAssertFalse(help.grouping)
        XCTAssertTrue(help.imperial)
        XCTAssertNotNil(ExteraMathEngine.suggestion(in: "2+2=", caret: 4, options: help))
        XCTAssertNil(ExteraMathEngine.suggestion(in: "2+2=", caret: 4, options: runtime))
    }
}
