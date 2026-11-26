import XCTest
@testable import SGSimpleSettings

final class ExteraStyleSettingsTests: XCTestCase {
    func testSectionRadiusClampsWithoutOverflow() {
        XCTAssertEqual(ExteraStyleSettings.normalizedSectionRadius(Int.min), 0)
        XCTAssertEqual(ExteraStyleSettings.normalizedSectionRadius(Int.max), 64)
        XCTAssertEqual(ExteraStyleSettings.normalizedSectionRadius(20), 20)
    }

    func testBackupKeyGroupsAreDisjointAndComplete() {
        let keys = ExteraStyleSettings.booleanKeys + ExteraStyleSettings.integerKeys + ExteraStyleSettings.stringKeys
        XCTAssertEqual(keys.count, 7)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(Set(ExteraStyleSettings.integerKeys), [ExteraStyleSettings.controlStyleKey, ExteraStyleSettings.sectionRadiusKey])
        XCTAssertEqual(ExteraStyleSettings.ControlStyle.classic.rawValue, 0)
        XCTAssertEqual(ExteraStyleSettings.ControlStyle.material.rawValue, 1)
    }
}
