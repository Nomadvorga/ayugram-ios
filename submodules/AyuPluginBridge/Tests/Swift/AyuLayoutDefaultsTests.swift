import CoreGraphics
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// What Android decides when a plugin says nothing: the orientation of a new `LinearLayout`, the
/// LayoutParams a parent generates for a child added without any, and `MATCH_PARENT` under a wrapping parent.
@MainActor
final class AyuLayoutDefaultsTests: XCTestCase {
    private let linear = "android.widget.LinearLayout"
    private let frame = "android.widget.FrameLayout"

    private func box(_ session: AyuMemberTestHost, _ width: Int64, _ height: Int64, in parent: AyuBridgeValue, params: String) async throws -> AyuBridgeValue {
        let view = try await session.construct("android.view.View")
        _ = try await session.invoke(parent, "addView", [view, try await session.construct(params + "$LayoutParams", [.integer(width), .integer(height)])])
        return view
    }

    private func rect(_ session: AyuMemberTestHost, _ view: AyuBridgeValue) async throws -> AyuBridgeValue {
        var result: [AyuBridgeValue] = []
        for getter in ["getX", "getY", "getWidth", "getHeight"] { result.append(try await session.invoke(view, getter)) }
        return .array(result)
    }

    private func params(_ session: AyuMemberTestHost, _ view: AyuBridgeValue) async throws -> AyuBridgeValue {
        let layout = try await session.invoke(view, "getLayoutParams")
        guard layout != .null else { return .null }
        var result: [AyuBridgeValue] = [try await session.invoke(try await session.invoke(layout, "getClass"), "getName")]
        for name in ["width", "height"] { result.append(try await session.call("java.get_field", ["target": layout, "name": .string(name)])) }
        return .array(result)
    }

    func testANewLinearLayoutIsHorizontal() async throws {
        let session = try await AyuMemberTestHost()
        let row = try await session.construct(self.linear)
        ayuExpect(try await session.invoke(row, "getOrientation"), .integer(0))
        let first = try await self.box(session, 30, 20, in: row, params: self.linear)
        let second = try await self.box(session, 50, 20, in: row, params: self.linear)
        _ = try await session.mount(row, size: CGSize(width: 200, height: 100))
        ayuExpect(try await self.rect(session, first), .array([.integer(0), .integer(0), .integer(30), .integer(20)]))
        ayuExpect(try await self.rect(session, second), .array([.integer(30), .integer(0), .integer(50), .integer(20)]))
        _ = try await session.invoke(row, "setOrientation", [.integer(1)])
        ayuExpect(try await self.rect(session, second), .array([.integer(0), .integer(20), .integer(50), .integer(20)]))
    }

    func testAChildAddedWithoutLayoutParamsGetsTheParentsDefaults() async throws {
        let session = try await AyuMemberTestHost()
        let root = try await session.construct(self.frame)
        let column = try await session.construct(self.linear)
        _ = try await session.invoke(column, "setOrientation", [.integer(1)])
        let line = try await session.construct("android.widget.TextView")
        _ = try await session.invoke(line, "setText", [.string("line")])
        ayuExpect(try await self.params(session, line), .null)
        _ = try await session.invoke(column, "addView", [line])
        let row = try await session.construct(self.linear)
        _ = try await session.invoke(column, "addView", [row, .integer(0)])
        let word = try await session.construct("android.widget.TextView")
        _ = try await session.invoke(word, "setText", [.string("word")])
        _ = try await session.invoke(row, "addView", [word])
        _ = try await session.invoke(root, "addView", [column])
        _ = try await session.mount(root, size: CGSize(width: 200, height: 120))

        // FrameLayout: MATCH_PARENT both ways. Vertical LinearLayout: full width, content height. Horizontal: content size.
        ayuExpect(try await self.params(session, column), .array([.string("android.widget.FrameLayout$LayoutParams"), .integer(-1), .integer(-1)]))
        ayuExpect(try await self.params(session, line), .array([.string("android.widget.LinearLayout$LayoutParams"), .integer(-1), .integer(-2)]))
        ayuExpect(try await self.params(session, row), .array([.string("android.widget.LinearLayout$LayoutParams"), .integer(-1), .integer(-2)]))
        ayuExpect(try await self.params(session, word), .array([.string("android.widget.LinearLayout$LayoutParams"), .integer(-2), .integer(-2)]))
        ayuExpect(try await self.rect(session, column), .array([.integer(0), .integer(0), .integer(200), .integer(120)]))
        ayuExpect(try await session.invoke(line, "getWidth"), .integer(200))
        ayuExpect(try await session.invoke(row, "getWidth"), .integer(200))
        let wordWidth = try await session.invoke(word, "getWidth")
        XCTAssertLessThan(wordWidth.number ?? 200, 100, "\(wordWidth)")
        XCTAssertGreaterThan(wordWidth.number ?? 0, 0, "\(wordWidth)")

        // LayoutParams the child already has are kept.
        let fixed = try await session.construct("android.view.View")
        _ = try await session.invoke(fixed, "setLayoutParams", [try await session.construct("android.widget.LinearLayout$LayoutParams", [.integer(40), .integer(10)])])
        _ = try await session.invoke(column, "addView", [fixed])
        ayuExpect(try await session.invoke(fixed, "getWidth"), .integer(40))
    }

    func testMatchParentUnderAWrappingParentTakesTheContentSize() async throws {
        let session = try await AyuMemberTestHost()
        let root = try await session.construct(self.frame)
        let wrapper = try await session.construct(self.frame)
        _ = try await session.invoke(root, "addView", [wrapper, try await session.construct(self.frame + "$LayoutParams", [.integer(-2), .integer(-2)])])
        _ = try await self.box(session, 50, 40, in: wrapper, params: self.frame)
        let filler = try await session.construct("android.view.View")
        _ = try await session.invoke(wrapper, "addView", [filler])
        _ = try await session.mount(root, size: CGSize(width: 200, height: 120))
        // The wrapper wraps its fixed child; the MATCH_PARENT one is then stretched to the wrapper.
        ayuExpect(try await self.rect(session, wrapper), .array([.integer(0), .integer(0), .integer(50), .integer(40)]))
        ayuExpect(try await self.rect(session, filler), .array([.integer(0), .integer(0), .integer(50), .integer(40)]))
    }

    func testAScrollViewChildWithoutLayoutParamsKeepsItsContentHeight() async throws {
        let session = try await AyuMemberTestHost()
        let scroll = try await session.construct("android.widget.ScrollView")
        let column = try await session.construct(self.linear)
        _ = try await session.invoke(column, "setOrientation", [.integer(1)])
        for _ in 0..<5 { _ = try await self.box(session, 20, 60, in: column, params: self.linear) }
        _ = try await session.invoke(scroll, "addView", [column])
        _ = try await session.mount(scroll, size: CGSize(width: 200, height: 120))
        ayuExpect(try await self.rect(session, column), .array([.integer(0), .integer(0), .integer(200), .integer(300)]))
    }

    func testPaddingIsPartOfTheMeasuredSize() async throws {
        let session = try await AyuMemberTestHost()
        let root = try await session.construct(self.frame)
        func wrapped(_ view: AyuBridgeValue) async throws {
            _ = try await session.invoke(root, "addView", [view, try await session.construct(self.frame + "$LayoutParams", [.integer(-2), .integer(-2)])])
        }
        let plain = try await session.construct("android.widget.TextView")
        let padded = try await session.construct("android.widget.TextView")
        for text in [plain, padded] { _ = try await session.invoke(text, "setText", [.string("padded")]); try await wrapped(text) }
        _ = try await session.invoke(padded, "setPadding", [.integer(20), .integer(10), .integer(20), .integer(6)])

        let column = try await session.construct(self.linear)
        _ = try await session.invoke(column, "setOrientation", [.integer(1)])
        _ = try await session.invoke(column, "setPadding", [.integer(8), .integer(4), .integer(8), .integer(4)])
        let inner = try await self.box(session, 50, 40, in: column, params: self.linear)
        try await wrapped(column)

        // A minimum bounds the padded size: it does not add to the padding.
        let minimum = try await session.construct(self.frame)
        _ = try await session.invoke(minimum, "setPadding", [.integer(20), .integer(0), .integer(20), .integer(0)])
        _ = try await session.invoke(minimum, "setMinimumWidth", [.integer(100)])
        _ = try await self.box(session, 30, 10, in: minimum, params: self.frame)
        try await wrapped(minimum)

        _ = try await session.mount(root, size: CGSize(width: 300, height: 200))
        let plainWidth = try await session.invoke(plain, "getWidth").number ?? 0
        let plainHeight = try await session.invoke(plain, "getHeight").number ?? 0
        XCTAssertGreaterThan(plainWidth, 0)
        ayuExpect(try await session.invoke(padded, "getWidth"), .number(plainWidth + 40))
        ayuExpect(try await session.invoke(padded, "getHeight"), .number(plainHeight + 16))
        ayuExpect(try await self.rect(session, column), .array([.integer(0), .integer(0), .integer(66), .integer(48)]))
        ayuExpect(try await self.rect(session, inner), .array([.integer(8), .integer(4), .integer(50), .integer(40)]))
        ayuExpect(try await session.invoke(minimum, "getWidth"), .integer(100))
    }
}
