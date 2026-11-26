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
        XCTAssertEqual(Set(solarNames).count, Set(ExteraUIIconRole.allCases.map { $0.androidResource }).count)
        XCTAssertTrue(Set(solarNames).isDisjoint(with: remixNames))
        XCTAssertEqual(solar.assetName(for: .settings), "ExteraUI_solar_msg_settings")
        XCTAssertEqual(remix.assetName(for: .copy), "ExteraUI_remix_msg_copy")
    }

    func testUnmappedNavigationActionKeepsNativeGlyph() {
        let fallback = UIImage()
        XCTAssertTrue(ExteraUIIconProvider(pack: .solar).navigationImage(id: "futureAction", fallback: fallback) === fallback)
    }

    func testIncomingDoubleTapUsesExactAndroidResourceKeys() {
        XCTAssertEqual(ExteraUIIconRole.incomingDoubleTapActions.map { $0.androidResource }, [
            "msg_block", "msg_reactions2", "menu_reply", "msg_copy", "msg_forward",
            "msg_saved", "msg_repeat", "msg_delete", "msg_translate", "msg_view_file"
        ])
    }

    func testStaticRendererRejectsActiveAndUnsupportedSVG() {
        for svg in ["<svg><script>alert(1)</script></svg>", "<svg><image href='https://example.com/x'/></svg>", "<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg>&x;</svg>", "<svg><path d='M0 0' onclick='x()'/></svg>", "<svg><path d='M0 0' fill='url(https://example.com/x)'/></svg>"] {
            XCTAssertThrowsError(try ExteraUIIconRendering.image(data: Data(svg.utf8), path: "icon.svg"))
        }
    }

    func testStaticRendererDrawsStrokesArcsAndVectorDrawable() throws {
        let svg = "<svg viewBox='0 0 24 24'><g transform='translate(1 1)'><path d='M2 12 A8 8 0 1 1 18 12 S12 20 2 12 Z' fill='none' stroke='#fff' stroke-width='2'/></g></svg>"
        let image = try ExteraUIIconRendering.image(data: Data(svg.utf8), path: "icon.svg")
        XCTAssertEqual(image.size, CGSize(width: 24, height: 24))
        XCTAssertEqual(image.cgImage?.width, 72)
        XCTAssertEqual(image.renderingMode, .alwaysTemplate)
        let vector = "<vector xmlns:android='http://schemas.android.com/apk/res/android' android:viewportWidth='24' android:viewportHeight='24'><path android:pathData='M2,2 L22,2 L12,22 Z' android:fillColor='#ffffffff' android:fillType='evenOdd'/></vector>"
        XCTAssertNoThrow(try ExteraUIIconRendering.image(data: Data(vector.utf8), path: "icon.xml"))
        XCTAssertThrowsError(try ExteraUIIconRendering.image(data: Data("<svg><path d='M0 0 A1e-300 1e-300 0 0 1 24 24'/></svg>".utf8), path: "icon.svg"))
    }
}
