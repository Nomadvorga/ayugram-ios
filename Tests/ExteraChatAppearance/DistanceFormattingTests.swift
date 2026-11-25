import Dispatch
import Foundation
import MapKit
import SGSimpleSettings
import TelegramPresentationData
import TelegramStringFormatting
import XCTest

final class DistanceFormattingTests: XCTestCase {
    override func tearDown() {
        ExteraChatAppearanceSettings.shared.distanceUnit = .automatic
        UserDefaults(suiteName: APP_GROUP_IDENTIFIER)?.removePersistentDomain(forName: APP_GROUP_IDENTIFIER)
        super.tearDown()
    }

    private func expected(strings: PresentationStrings, distance: Double, style: MKDistanceFormatter.DistanceUnitStyle, units: MKDistanceFormatter.Units) -> String {
        let formatter = MKDistanceFormatter()
        formatter.locale = localeWithStrings(strings)
        formatter.unitStyle = style
        formatter.units = units
        return formatter.string(fromDistance: distance)
    }

    func testBothCachedFormattersApplyEverySelectionIncludingResetToAutomatic() {
        let strings = PresentationStrings(baseLanguageCode: "en")
        let selections: [(ExteraChatAppearanceSettings.DistanceUnit, MKDistanceFormatter.Units)] = [
            (.kilometers, .metric), (.miles, .imperial), (.automatic, .default), (.miles, .imperial), (.kilometers, .metric)
        ]
        for (setting, units) in selections {
            ExteraChatAppearanceSettings.shared.distanceUnit = setting
            XCTAssertEqual(stringForDistance(strings: strings, distance: 16093.44), self.expected(strings: strings, distance: 16093.44, style: .full, units: units))
            XCTAssertEqual(shortStringForDistance(strings: strings, distance: 16093), self.expected(strings: strings, distance: 16093, style: .abbreviated, units: units))
        }
        ExteraChatAppearanceSettings.shared.distanceUnit = .miles
        let miles = stringForDistance(strings: strings, distance: 16093.44)
        ExteraChatAppearanceSettings.shared.distanceUnit = .kilometers
        XCTAssertNotEqual(miles, stringForDistance(strings: strings, distance: 16093.44))
    }

    func testProximityPickerUsesThePersistedOverride() {
        for language in ["en", "ru", "de"] {
            let strings = PresentationStrings(baseLanguageCode: language)
            ExteraChatAppearanceSettings.shared.distanceUnit = .miles
            XCTAssertFalse(usesMetricDistanceUnits(strings: strings))
            ExteraChatAppearanceSettings.shared.distanceUnit = .kilometers
            XCTAssertTrue(usesMetricDistanceUnits(strings: strings))
        }
    }

    func testConcurrentConsumersDoNotMixCachedFormatterLocales() {
        ExteraChatAppearanceSettings.shared.distanceUnit = .kilometers
        let cases = ["en", "ru", "de"].map { language -> (PresentationStrings, String, String) in
            let strings = PresentationStrings(baseLanguageCode: language)
            return (strings, self.expected(strings: strings, distance: 12345, style: .full, units: .metric), self.expected(strings: strings, distance: 12345, style: .abbreviated, units: .metric))
        }
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let (strings, full, short) = cases[index % cases.count]
            XCTAssertEqual(stringForDistance(strings: strings, distance: 12345), full)
            XCTAssertEqual(shortStringForDistance(strings: strings, distance: 12345), short)
        }
    }
}
