import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// `StateListDrawable` as a view background: the first entry whose state spec matches the view is shown.
@MainActor
final class AyuStateListDrawableTests: XCTestCase {
    private let stateList = "android.graphics.drawable.StateListDrawable"
    private let pressed: Int64 = 16_842_919
    private let enabled: Int64 = 16_842_910
    private let red: Int64 = -65_536
    private let green: Int64 = -16_711_936
    private let blue: Int64 = -16_776_961

    private func color(_ session: AyuMemberTestHost, _ argb: Int64) async throws -> AyuBridgeValue {
        try await session.construct("android.graphics.drawable.ColorDrawable", [.integer(argb)])
    }

    private func press(_ view: AyuBridgeView, _ down: Bool) throws {
        let recognizers = (view.gestureRecognizers ?? []).compactMap { $0 as? AyuBridgePressRecognizer }
        XCTAssertFalse(recognizers.isEmpty, "a state list watches the touch")
        for recognizer in recognizers { recognizer.onChange?(down) }
    }

    private func shown(_ view: AyuBridgeView) -> Int64 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        view.bridgeBackgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let bits = UInt32(alpha * 255) << 24 | UInt32(red * 255) << 16 | UInt32(green * 255) << 8 | UInt32(blue * 255)
        return Int64(Int32(bitPattern: bits))
    }

    func testTheEntryMatchingTheViewsStateIsShown() async throws {
        let session = try await AyuMemberTestHost()
        let list = try await session.construct(self.stateList)
        ayuExpect(try await session.invoke(list, "addState", [.array([.integer(self.pressed)]), try await self.color(session, self.red)]), .null)
        _ = try await session.invoke(list, "addState", [.array([.integer(-self.enabled)]), try await self.color(session, self.blue)])
        _ = try await session.invoke(list, "addState", [try await session.array("int", []), try await self.color(session, self.green)])
        let target = try await session.construct("android.widget.TextView")
        _ = try await session.invoke(target, "setClickable", [.bool(true)])
        _ = try await session.invoke(target, "setBackground", [list])
        let view = try await session.mount(target)
        XCTAssertEqual(self.shown(view), self.green)
        ayuExpect(try await session.invoke(try await session.invoke(try await session.invoke(target, "getBackground"), "getClass"), "getName"), .string(self.stateList))

        try self.press(view, true)
        XCTAssertEqual(self.shown(view), self.red)
        try self.press(view, false)
        XCTAssertEqual(self.shown(view), self.green)

        // A disabled view is never pressed, and matches the negated enabled state.
        _ = try await session.invoke(target, "setEnabled", [.bool(false)])
        try await session.flush(target)
        XCTAssertEqual(self.shown(view), self.blue)
        try self.press(view, true)
        XCTAssertEqual(self.shown(view), self.blue)
        try self.press(view, false)
        _ = try await session.invoke(target, "setEnabled", [.bool(true)])

        // A plain background replaces the list: touches no longer change it.
        _ = try await session.invoke(target, "setBackgroundColor", [.integer(self.blue)])
        try await session.flush(target)
        XCTAssertTrue((view.gestureRecognizers ?? []).compactMap { $0 as? AyuBridgePressRecognizer }.isEmpty)
        XCTAssertEqual(self.shown(view), self.blue)
    }

    func testTheFirstMatchWinsAndNoMatchDrawsNothing() async throws {
        let session = try await AyuMemberTestHost()
        // The corpus shape: the wildcard first, so the second entry is never reached.
        let list = try await session.construct(self.stateList)
        _ = try await session.invoke(list, "addState", [.array([]), try await self.color(session, self.green)])
        _ = try await session.invoke(list, "addState", [.array([.integer(self.pressed)]), try await self.color(session, self.red)])
        _ = try await session.invoke(list, "addState", [.array([.integer(1)]), .null])
        let target = try await session.construct("android.widget.Button")
        _ = try await session.invoke(target, "setBackground", [list])
        let view = try await session.mount(target)
        XCTAssertNil(view.buttonBackground)
        XCTAssertEqual(self.shown(view), self.green)
        try self.press(view, true)
        XCTAssertEqual(self.shown(view), self.green)
        try self.press(view, false)

        let only = try await session.construct(self.stateList)
        _ = try await session.invoke(only, "addState", [.array([.integer(self.pressed)]), try await self.color(session, self.red)])
        _ = try await session.invoke(target, "setBackground", [only])
        try await session.flush(target)
        XCTAssertEqual(view.bridgeBackgroundColor, .clear)
        try self.press(view, true)
        XCTAssertEqual(self.shown(view), self.red)
        try self.press(view, false)
        XCTAssertEqual(view.bridgeBackgroundColor, .clear)
    }

    func testWhatAStateListCannotHoldIsRefused() async throws {
        let session = try await AyuMemberTestHost()
        let list = try await session.construct(self.stateList)
        var code = await session.failure { try await session.invoke(list, "addState", [.array([]), try await session.construct("android.widget.TextView")]) }
        XCTAssertNotNil(code)
        code = await session.failure { try await session.invoke(list, "addState", [.null, try await self.color(session, self.red)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        code = await session.failure { try await session.invoke(list, "addState", [.array([]), try await session.construct(self.stateList)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.construct(self.stateList, [.integer(1)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        for _ in 0..<16 { _ = try await session.invoke(list, "addState", [.array([]), try await self.color(session, self.red)]) }
        code = await session.failure { try await session.invoke(list, "addState", [.array([]), try await self.color(session, self.red)]) }
        XCTAssertEqual(code, "RESOURCE_LIMIT")
        XCTAssertTrue(AyuBridgeDrawables.stateSpec([], matches: []))
        XCTAssertTrue(AyuBridgeDrawables.stateSpec([5, -6, 0, 7], matches: [5]))
        XCTAssertFalse(AyuBridgeDrawables.stateSpec([5, -6], matches: [5, 6]))
        XCTAssertFalse(AyuBridgeDrawables.stateSpec([5], matches: [6]))
    }
}
