import TelegramPresentationData
import UIKit
import XCTest

final class ExteraUIIconProviderTests: XCTestCase {
    func testNativeReturnsOriginalImageWithoutRepainting() {
        let fallback = UIImage()
        let provider = ExteraUIIconProvider(pack: .native)
        for role in ExteraUIIconRole.allCases {
            XCTAssertNil(provider.assetName(for: role))
            XCTAssertTrue(provider.image(for: role, fallback: fallback) === fallback)
        }
    }

    func testPackSpecificCatalogNamesAreUniqueAndSeparate() {
        let solar = ExteraUIIconProvider(pack: .solar)
        let remix = ExteraUIIconProvider(pack: .remix)
        let solarNames = ExteraUIIconRole.allCases.compactMap { solar.assetName(for: $0) }
        let remixNames = ExteraUIIconRole.allCases.compactMap { remix.assetName(for: $0) }
        XCTAssertEqual(solarNames.count, ExteraUIIconRole.allCases.count)
        XCTAssertEqual(Set(solarNames).count, solarNames.count)
        XCTAssertTrue(Set(solarNames).isDisjoint(with: remixNames))
        XCTAssertEqual(solar.assetName(for: .settings), "ExteraUI_solar_msg_settings")
        XCTAssertEqual(remix.assetName(for: .copy), "ExteraUI_remix_msg_copy")
    }

    func testUnmappedNavigationActionKeepsNativeGlyph() {
        let fallback = UIImage()
        XCTAssertTrue(ExteraUIIconProvider(pack: .solar).navigationImage(id: "futureAction", fallback: fallback) === fallback)
    }
}
