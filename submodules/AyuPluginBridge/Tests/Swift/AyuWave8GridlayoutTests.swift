import CoreGraphics
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Frames are hand-computed from AOSP `GridLayout` (horizontal, span 1, no weights).
final class AyuWave8GridlayoutTests: XCTestCase {
    private typealias Child = AyuBridgeGridLayout.Child
    private typealias Cell = AyuBridgeGridLayout.Cell

    private func square(_ side: CGFloat, row: Int? = nil, column: Int? = nil, margin: CGFloat = 0) -> Child {
        Child(row: row, column: column, size: CGSize(width: side, height: side), left: margin, top: margin, right: margin, bottom: margin)
    }

    func testExplicitSpecsWithUniformMarginsInTwoColumns() throws {
        var children: [Child] = []
        for row in 0..<2 { for column in 0..<2 { children.append(self.square(40, row: row, column: column, margin: 2)) } }
        for mode in [AyuBridgeGridLayout.AlignmentMode.margins, .bounds] {
            let placement = try XCTUnwrap(AyuBridgeGridLayout.place(children, rowCount: 2, columnCount: 2, alignmentMode: mode))
            XCTAssertEqual(placement.size, CGSize(width: 88, height: 88))
            XCTAssertEqual(placement.frames, [CGRect(x: 2, y: 2, width: 40, height: 40), CGRect(x: 46, y: 2, width: 40, height: 40),
                                              CGRect(x: 2, y: 46, width: 40, height: 40), CGRect(x: 46, y: 46, width: 40, height: 40)])
        }
    }

    func testUndefinedSpecsFlowIntoThreeColumnsWithUnequalMargins() throws {
        // Sudoku-style: right margin 2 after the last column of a block, bottom margin 2 under row 0.
        var children: [Child] = []
        for index in 0..<7 {
            var child = self.square(30)
            child.right = index % 3 == 2 ? 2 : 1
            child.bottom = index < 3 ? 2 : 1
            children.append(child)
        }
        children[4].size = CGSize(width: 50, height: 10)
        XCTAssertEqual(AyuBridgeGridLayout.cells(children, rowCount: 3, columnCount: 3),
                       [Cell(row: 0, column: 0), Cell(row: 0, column: 1), Cell(row: 0, column: 2), Cell(row: 1, column: 0),
                        Cell(row: 1, column: 1), Cell(row: 1, column: 2), Cell(row: 2, column: 0)])
        let placement = try XCTUnwrap(AyuBridgeGridLayout.place(children, rowCount: 3, columnCount: 3))
        // Columns 31, 51, 32; rows 32, 31, 31.
        XCTAssertEqual(placement.size, CGSize(width: 114, height: 94))
        XCTAssertEqual(placement.frames, [CGRect(x: 0, y: 0, width: 30, height: 30), CGRect(x: 31, y: 0, width: 30, height: 30),
                                          CGRect(x: 82, y: 0, width: 30, height: 30), CGRect(x: 0, y: 32, width: 30, height: 30),
                                          CGRect(x: 31, y: 32, width: 50, height: 10), CGRect(x: 82, y: 32, width: 30, height: 30),
                                          CGRect(x: 0, y: 63, width: 30, height: 30)])
    }

    func testAlignBoundsSharesTheLargestMarginOfAColumn() throws {
        var first = self.square(20, row: 0, column: 0)
        first.left = 6
        let second = self.square(20, row: 1, column: 0)
        let margins = try XCTUnwrap(AyuBridgeGridLayout.place([first, second], rowCount: nil, columnCount: nil, alignmentMode: .margins))
        XCTAssertEqual(margins.frames.map(\.minX), [6, 0])
        let bounds = try XCTUnwrap(AyuBridgeGridLayout.place([first, second], rowCount: nil, columnCount: nil, alignmentMode: .bounds))
        XCTAssertEqual(bounds.frames.map(\.minX), [6, 6])
        XCTAssertEqual(bounds.size, CGSize(width: 26, height: 40))
    }

    func testMixedSpecsSkipOccupiedCellsAndUndefinedCountsMakeOneRow() {
        let taken = [self.square(10, row: 0, column: 1), self.square(10), self.square(10), self.square(10)]
        XCTAssertEqual(AyuBridgeGridLayout.cells(taken, rowCount: nil, columnCount: 2),
                       [Cell(row: 0, column: 1), Cell(row: 1, column: 0), Cell(row: 1, column: 1), Cell(row: 2, column: 0)])
        XCTAssertEqual(AyuBridgeGridLayout.cells([self.square(10), self.square(10), self.square(10)], rowCount: nil, columnCount: nil),
                       [Cell(row: 0, column: 0), Cell(row: 0, column: 1), Cell(row: 0, column: 2)])
    }

    func testIndicesOutsideADefinedCountAreRefusedAsOnAndroid() {
        XCTAssertNil(AyuBridgeGridLayout.place([self.square(10, row: 0, column: 2)], rowCount: 2, columnCount: 2))
        XCTAssertNil(AyuBridgeGridLayout.place([self.square(10, row: 2, column: 0)], rowCount: 2, columnCount: 2))
        XCTAssertNil(AyuBridgeGridLayout.place([self.square(10), self.square(10), self.square(10)], rowCount: 1, columnCount: 2))
    }
}
