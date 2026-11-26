import UIKit
import XCTest
@testable import SGItemListUI

final class SGItemListAppearanceTests: XCTestCase {
    private enum Section: Int32, SGItemListSection { case first = 0 }
    private typealias Entry = SGItemListUIEntry<Section, String, String, String, String, String>

    func testForceBlurNeverBypassesEnergyOrAccessibility() {
        for enabled in [false, true] {
            for force in [false, true] {
                for theme in [false, true] {
                    for energy in [false, true] {
                        for accessibility in [false, true] {
                            let configuration = SGItemListGlassConfiguration(enabled: enabled, forceBlur: force)
                            for native in [false, true] {
                                let result = configuration.usesBlur(nativeAllowsBlur: native, themeAllowsBlur: theme, effectsAllowed: energy, reduceTransparency: accessibility)
                                if !enabled || !native || !energy || accessibility { XCTAssertFalse(result) }
                                if enabled && native && energy && !accessibility { XCTAssertEqual(result, theme || force) }
                            }
                        }
                    }
                }
            }
        }
    }

    func testSectionRadiusHandlesInvalidAndExtremeInputs() {
        XCTAssertEqual(SGExteraAppearance().radius, 22.0)
        XCTAssertEqual(SGExteraAppearance(sectionRadius: -.infinity).radius, 22.0)
        XCTAssertEqual(SGExteraAppearance(sectionRadius: .nan).radius, 22.0)
        XCTAssertEqual(SGExteraAppearance(sectionRadius: -1.0).radius, 0.0)
        XCTAssertEqual(SGExteraAppearance(sectionRadius: 1000.0).radius, 64.0)
    }

    func testStyleTilesFitNarrowAndWideCardsWithMinimumTouchWidth() {
        let widths: [CGFloat] = [88.0, 96.0, 128.0, 192.0, 320.0, 736.0]
        for width in widths {
            let geometry = SGAppearanceStyleControl.tileGeometry(width: width)
            XCTAssertGreaterThanOrEqual(geometry.width, 44.0)
            XCTAssertGreaterThanOrEqual(geometry.inset, 0.0)
            XCTAssertGreaterThanOrEqual(geometry.gap, 0.0)
            XCTAssertLessThanOrEqual(geometry.inset + geometry.width * 2.0 + geometry.gap, width)
            XCTAssertGreaterThanOrEqual(SGAppearanceStyleControl.height(width: width), 96.0)
        }
    }

    func testAppearanceChangesInvalidateUnchangedRowsWithoutChangingIdentity() {
        let entries: [Entry] = [
            .header(id: 1, section: .first, text: "Section", badge: nil),
            .toggle(id: 2, section: .first, settingName: "toggle", value: true, text: "Value", enabled: true),
            .settingsPreview(id: 3, section: .first, kind: .stickerShapes(value: 0, options: ["A", "B", "C"]), sliderSetting: nil, selectionSetting: nil)
        ]
        for entry in entries {
            let original = SGStyledItemListEntry(entry: entry, appearance: SGExteraAppearance())
            let changed = SGStyledItemListEntry(entry: entry, appearance: SGExteraAppearance(sectionRadius: 0.0, separateHeaders: false))
            XCTAssertEqual(original.stableId, changed.stableId)
            XCTAssertEqual(original.section, changed.section)
            XCTAssertNotEqual(original, changed)
            XCTAssertEqual(original, SGStyledItemListEntry(entry: entry, appearance: SGExteraAppearance()))
        }
    }

    func testRawRangeHandlesReversedBoundsStepsAndInt32Limits() {
        let configuration = SGItemListRangeConfiguration(value: 0, minimum: 20, maximum: -10, step: 7, title: "Radius", minimumLabel: "Off", maximumLabel: "Max")
        XCTAssertEqual(configuration.normalized(-100), -10)
        XCTAssertEqual(configuration.normalized(0), -3)
        XCTAssertEqual(configuration.normalized(19), 18)
        XCTAssertEqual(configuration.normalized(20), 20)
        XCTAssertEqual(configuration.normalized(100), 20)
        for raw in Int64(-100) ... 100 {
            let value = configuration.normalized(raw)
            XCTAssertEqual(configuration.normalized(Int64(value)), value)
        }
        let full = SGItemListRangeConfiguration(value: 0, minimum: .min, maximum: .max, step: .max, title: "", minimumLabel: "", maximumLabel: "")
        XCTAssertEqual(full.normalized(Int64.min), Int32.min)
        XCTAssertEqual(full.normalized(Int64.max), Int32.max)
        let zeroStep = SGItemListRangeConfiguration(value: 0, minimum: 0, maximum: 64, step: 0, title: "", minimumLabel: "", maximumLabel: "")
        XCTAssertEqual(zeroStep.normalized(31), 31)
    }

    func testRawRangeAccessibilityCanReachAnUnalignedMaximumAndReturn() {
        // These tests use no PresentationStrings or persisted settings in the test process.
        // Control configuration via a theme belongs to the app's runtime frame checks.
        let configuration = SGItemListRangeConfiguration(value: 98, minimum: 0, maximum: 100, step: 7, title: "", minimumLabel: "", maximumLabel: "")
        let end = configuration.normalized(105)
        XCTAssertEqual(end, 100)
        let offset = Int64(end) - configuration.lower
        let previous = Int64(end) - offset % configuration.stride
        XCTAssertEqual(configuration.normalized(previous), 98)
    }
}
