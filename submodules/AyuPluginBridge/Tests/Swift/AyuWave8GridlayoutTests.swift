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

/// The class as a plugin drives it through the host: `GridLayout(ctx)`, `spec`, `LayoutParams`, counts.
@MainActor
final class AyuWave8GridlayoutHostTests: XCTestCase {
    private let grid = "android.widget.GridLayout"
    private let params = "android.widget.GridLayout$LayoutParams"

    private func cell(_ session: AyuMemberTestHost, _ layout: AyuBridgeValue, side: Int64, margins: [Int64]) async throws -> AyuBridgeValue {
        _ = try await session.call("java.set_field", ["target": layout, "name": .string("width"), "value": .integer(side)])
        _ = try await session.call("java.set_field", ["target": layout, "name": .string("height"), "value": .integer(side)])
        _ = try await session.invoke(layout, "setMargins", margins.map(AyuBridgeValue.integer))
        let view = try await session.construct("android.widget.TextView")
        _ = try await session.invoke(view, "setLayoutParams", [layout])
        return view
    }

    private func frame(_ session: AyuMemberTestHost, _ view: AyuBridgeValue) async throws -> [AyuBridgeValue] {
        var result: [AyuBridgeValue] = []
        for getter in ["getX", "getY", "getWidth", "getHeight"] { result.append(try await session.invoke(view, getter)) }
        return result
    }

    func testCellsWithExplicitSpecsAreLaidOutAndTheGridWrapsThem() async throws {
        let session = try await AyuMemberTestHost()
        let root = try await session.construct("android.widget.FrameLayout")
        let grid = try await session.construct(self.grid)
        ayuExpect(try await session.invoke(grid, "getColumnCount"), .integer(-2_147_483_648))
        ayuExpect(try await session.invoke(grid, "getAlignmentMode"), .integer(1))
        ayuExpect(try await session.invoke(grid, "setColumnCount", [.integer(2)]), .null)
        ayuExpect(try await session.invoke(grid, "setRowCount", [.integer(2)]), .null)
        ayuExpect(try await session.field(self.grid, "ALIGN_BOUNDS"), .integer(0))
        _ = try await session.invoke(grid, "setAlignmentMode", [.integer(0)])
        var cells: [AyuBridgeValue] = []
        for row in 0..<2 {
            for column in 0..<2 {
                let rowSpec = try await session.invokeStatic(self.grid, "spec", [.integer(Int64(row))])
                let columnSpec = try await session.invokeStatic(self.grid, "spec", [.integer(Int64(column))])
                let view = try await self.cell(session, try await session.construct(self.params, [rowSpec, columnSpec]), side: 40, margins: [2, 2, 2, 2])
                _ = try await session.invoke(grid, "addView", [view])
                cells.append(view)
            }
        }
        _ = try await session.invoke(root, "addView", [grid])
        _ = try await session.mount(root, size: CGSize(width: 300, height: 300))
        ayuExpect(try await session.invoke(grid, "getColumnCount"), .integer(2))
        ayuExpect(try await session.invoke(grid, "getRowCount"), .integer(2))
        ayuExpect(try await session.invoke(grid, "getAlignmentMode"), .integer(0))
        ayuExpect(try await session.invoke(grid, "getChildCount"), .integer(4))
        let size: [AyuBridgeValue] = [.integer(40), .integer(40)]
        // Added without LayoutParams, the grid fills the frame (FrameLayout's default); its cells stay at the top-left.
        ayuExpect(.array(try await self.frame(session, grid)), .array([.integer(0), .integer(0), .integer(300), .integer(300)]))
        let wrap = try await session.construct("android.widget.FrameLayout$LayoutParams", [.integer(-2), .integer(-2)])
        _ = try await session.invoke(grid, "setLayoutParams", [wrap])
        ayuExpect(.array(try await self.frame(session, grid)), .array([.integer(0), .integer(0), .integer(88), .integer(88)]))
        ayuExpect(.array(try await self.frame(session, cells[0])), .array([.integer(2), .integer(2)] + size))
        ayuExpect(.array(try await self.frame(session, cells[1])), .array([.integer(46), .integer(2)] + size))
        ayuExpect(.array(try await self.frame(session, cells[2])), .array([.integer(2), .integer(46)] + size))
        ayuExpect(.array(try await self.frame(session, cells[3])), .array([.integer(46), .integer(46)] + size))
    }

    func testCellsWithoutSpecsFlowAlongTheColumnCount() async throws {
        let session = try await AyuMemberTestHost()
        let grid = try await session.construct(self.grid)
        _ = try await session.invoke(grid, "setColumnCount", [.integer(3)])
        var cells: [AyuBridgeValue] = []
        for index in 0..<5 {
            // Sudoku-style: a 2 point gap after the last column, none elsewhere.
            let view = try await self.cell(session, try await session.construct(self.params), side: 30, margins: [0, 0, index % 3 == 2 ? 2 : 0, 0])
            _ = try await session.invoke(grid, "addView", [view])
            cells.append(view)
        }
        _ = try await session.mount(grid, size: CGSize(width: 200, height: 200))
        ayuExpect(.array(try await self.frame(session, cells[2])), .array([.integer(60), .integer(0), .integer(30), .integer(30)]))
        ayuExpect(.array(try await self.frame(session, cells[3])), .array([.integer(0), .integer(30), .integer(30), .integer(30)]))
        ayuExpect(.array(try await self.frame(session, cells[4])), .array([.integer(30), .integer(30), .integer(30), .integer(30)]))
    }

    func testWhatTheGridDoesNotModelIsRefused() async throws {
        let session = try await AyuMemberTestHost()
        let grid = try await session.construct(self.grid)
        var code = await session.failure { try await session.invokeStatic(self.grid, "spec", [.integer(0), .integer(2)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.invoke(grid, "setOrientation", [.integer(1)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.construct(self.params, [.integer(40), .integer(40)]) }
        XCTAssertNotNil(code)
        code = await session.failure { try await session.invoke(grid, "setColumnCount", [.integer(0)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        let layout = try await session.construct(self.params)
        code = await session.failure { try await session.call("java.set_field", ["target": layout, "name": .string("gravity"), "value": .integer(17)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        let frame = try await session.construct("android.widget.FrameLayout")
        code = await session.failure { try await session.invoke(frame, "setColumnCount", [.integer(2)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
    }
}

/// A board game shaped like the corpus ones, through the real SDK and its member-aware preflight.
@MainActor
final class AyuWave8GridlayoutEndToEndTests: XCTestCase {
    func testABoardOfCellsIsBuiltAsThePluginsBuildIt() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_wave8_gridlayout", """
        from android.widget import FrameLayout, TextView
        from base_plugin import BasePlugin
        from hook_utils import find_class
        from org.telegram.messenger import ApplicationLoader

        GridLayout = find_class("android.widget.GridLayout")

        \(AyuEndToEnd.recorder)


        class BoardPlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                context = ApplicationLoader.applicationContext
                grid = GridLayout(context); grid.setColumnCount(3); grid.setRowCount(3)
                grid.setAlignmentMode(GridLayout.ALIGN_BOUNDS)
                container = FrameLayout(context); container.addView(grid)
                cells = {}
                for r in range(3):
                    for c in range(3):
                        cell = TextView(context)
                        params = GridLayout.LayoutParams(GridLayout.spec(r), GridLayout.spec(c))
                        params.width = params.height = 40
                        params.setMargins(2, 2, 2, 2)
                        cell.setLayoutParams(params)
                        grid.addView(cell)
                        cells[(r, c)] = cell
                self.record("built", lambda: [grid.getChildCount(), grid.getColumnCount(), grid.getRowCount(), grid.getAlignmentMode(),
                                              GridLayout.ALIGN_MARGINS, GridLayout.UNDEFINED])
                flow = GridLayout.LayoutParams()
                flow.width = 30
                self.record("params", lambda: [flow.width, flow.height, flow.leftMargin, cells[(2, 1)].getLayoutParams().width,
                                               cells[(2, 1)].getLayoutParams().getClass().getName()])
                self.record("spec_class", lambda: GridLayout.spec(1).getClass().getName())
        """))
        func stored(_ key: String) -> AyuBridgeValue { stack.stored(id, key) }
        XCTAssertEqual(stored("built"), .array([.integer(9), .integer(3), .integer(3), .integer(0), .integer(1), .integer(-2_147_483_648)]))
        XCTAssertEqual(stored("params"), .array([.integer(30), .integer(-2), .integer(0), .integer(40), .string("android.widget.GridLayout$LayoutParams")]))
        XCTAssertEqual(stored("spec_class"), .string("android.widget.GridLayout$Spec"))
        await stack.remove(id)
    }
}
