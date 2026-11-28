import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Pure data-model checks for the virtual text layout subset; no simulator view
/// tree or device-specific rendering assumptions are required.
final class AyuBridgeUIExpansionTests: XCTestCase {
    func testMinimumLinesContributeBoundedIntrinsicHeight() throws {
        var options = AyuBridgeTextLayoutOptions()
        try options.setMinimumLines(.integer(3), supportsMultiline: true)
        XCTAssertEqual(options.minimumLines, 3)
        XCTAssertEqual(options.minimumHeight(lineHeight: 18), 54)
        XCTAssertEqual(options.minimumHeight(lineHeight: 0), 0)
        XCTAssertEqual(options.minimumHeight(lineHeight: .infinity), 0)

        try options.setMinimumLines(.integer(0), supportsMultiline: true)
        XCTAssertEqual(options.minimumHeight(lineHeight: 18), 0)
    }

    func testSingleLineClampsMinimumHeightAndCanBeReversed() throws {
        var options = AyuBridgeTextLayoutOptions()
        try options.setMinimumLines(.integer(4), supportsMultiline: true)
        try options.setSingleLine(.bool(true), supportsMultiline: true)
        XCTAssertEqual(options.numberOfLines, 1)
        XCTAssertEqual(options.minimumHeight(lineHeight: 20), 20)

        try options.setSingleLine(.bool(false), supportsMultiline: true)
        XCTAssertEqual(options.numberOfLines, 0)
        XCTAssertEqual(options.minimumHeight(lineHeight: 20), 80)
    }

    func testSingleLineAcceptsOnlyBooleanOrZeroAndOne() throws {
        var options = AyuBridgeTextLayoutOptions()
        try options.setSingleLine(.number(1), supportsMultiline: true)
        XCTAssertTrue(options.isSingleLine)
        try options.setSingleLine(.integer(0), supportsMultiline: true)
        XCTAssertFalse(options.isSingleLine)

        XCTAssertThrowsError(try options.setSingleLine(.number(2), supportsMultiline: true))
        XCTAssertThrowsError(try options.setSingleLine(.number(.nan), supportsMultiline: true))
        XCTAssertThrowsError(try options.setSingleLine(.string("false"), supportsMultiline: true))
    }

    func testTextFieldRejectsUnrepresentableMultilineOptions() throws {
        var options = AyuBridgeTextLayoutOptions()
        try options.setSingleLine(.bool(true), supportsMultiline: false)
        XCTAssertThrowsError(try options.setSingleLine(.bool(false), supportsMultiline: false))
        XCTAssertThrowsError(try options.setMinimumLines(.integer(2), supportsMultiline: false))
    }

    func testMinimumLineCountIsIntegralAndBounded() throws {
        var options = AyuBridgeTextLayoutOptions()
        try options.setMinimumLines(.number(64), supportsMultiline: true)
        XCTAssertEqual(options.minimumLines, 64)
        for invalid in [AyuBridgeValue.integer(-1), .number(65), .number(1.5), .number(.infinity), .string("2")] {
            XCTAssertThrowsError(try options.setMinimumLines(invalid, supportsMultiline: true))
        }
    }

    func testGravityParsesSupportedCombinedAlignmentAndComputesOffsets() throws {
        let centered = try AyuBridgeViewGravity(.integer(17))
        XCTAssertEqual(centered.horizontal, .center)
        XCTAssertEqual(centered.vertical, .center)
        XCTAssertEqual(centered.horizontalOffset(available: 200, extent: 40, direction: .leftToRight), 80)
        XCTAssertEqual(centered.verticalOffset(available: 100, extent: 20), 40)

        let start = try AyuBridgeViewGravity(.integer(8_388_611 | 16))
        XCTAssertEqual(start.horizontalOffset(available: 200, extent: 40, direction: .leftToRight), 0)
        XCTAssertEqual(start.horizontalOffset(available: 200, extent: 40, direction: .rightToLeft), 160)
        XCTAssertEqual(start.verticalOffset(available: 100, extent: 20), 40)

        let end = try AyuBridgeViewGravity(.integer(8_388_613))
        XCTAssertEqual(end.horizontalOffset(available: 200, extent: 40, direction: .leftToRight), 160)
        XCTAssertEqual(end.horizontalOffset(available: 200, extent: 40, direction: .rightToLeft), 0)
    }

    func testGravityRejectsFillClipConflictsAndNonIntegralValues() {
        for invalid in [AyuBridgeValue.integer(-1), .integer(4), .integer(8), .integer(112),
                        .integer(8_388_608), .integer(3 | 5), .number(1.5), .number(.infinity)] {
            XCTAssertThrowsError(try AyuBridgeViewGravity(invalid))
        }
    }

    func testLinearLayoutWeightDistributionUsesOnlyPositiveShares() {
        XCTAssertEqual(AyuBridgeLinearLayoutWeights.distribute(remaining: 120, weights: [1, 2, 0]), [40, 80, 0])
        XCTAssertEqual(AyuBridgeLinearLayoutWeights.distribute(remaining: -10, weights: [1, 2]), [0, 0])
        XCTAssertEqual(AyuBridgeLinearLayoutWeights.distribute(remaining: .infinity, weights: [1, 2]), [0, 0])
        XCTAssertEqual(AyuBridgeLinearLayoutWeights.distribute(remaining: 50, weights: [0, 0]), [0, 0])
    }
}
