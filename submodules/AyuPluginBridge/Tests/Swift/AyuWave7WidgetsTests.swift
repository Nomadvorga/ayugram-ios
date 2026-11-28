import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// `RippleDrawable(ColorStateList, content, mask)` as Android builds it.
@MainActor
final class AyuWave7WidgetsTests: XCTestCase {
    private let ripple = "android.graphics.drawable.RippleDrawable"

    private func tint(_ session: AyuMemberTestHost, _ color: Int64) async throws -> AyuBridgeValue {
        try await session.invokeStatic("android.content.res.ColorStateList", "valueOf", [.integer(color)])
    }

    func testANullMaskClipsTheRippleToItsStrokedContent() async throws {
        let session = try await AyuMemberTestHost()
        let content = try await session.construct("android.graphics.drawable.GradientDrawable")
        _ = try await session.invoke(content, "setColor", [.integer(-16776961)])
        _ = try await session.invoke(content, "setCornerRadius", [.number(12)])
        _ = try await session.invoke(content, "setStroke", [.integer(2), .integer(-65536)])
        let drawable = try await session.construct(self.ripple, [try await self.tint(session, 0x4000_0000), content, .null])
        XCTAssertEqual(drawable["$class"], .string(self.ripple))

        let view = try await session.construct("android.widget.FrameLayout")
        let native = try await session.mount(view, size: CGSize(width: 100, height: 40))
        ayuExpect(try await session.invoke(view, "setBackground", [drawable]), .null)
        try await session.flush(view)
        let style = try XCTUnwrap(native.members.drawable).style
        XCTAssertEqual(style.color, UIColor(red: 0, green: 0, blue: 1, alpha: 1))
        XCTAssertEqual(style.cornerRadius, 12)
        XCTAssertEqual(style.strokeWidth, 2)
        XCTAssertEqual(style.strokeColor, UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(style.ripple?.kind, "round_rect")
        XCTAssertEqual(style.ripple?.radius, 12)
        XCTAssertEqual(style.ripple?.bounded, true)
    }

    func testMaskShapesAndTheUnboundedForm() async throws {
        let session = try await AyuMemberTestHost()
        let view = try await session.construct("android.widget.FrameLayout")
        let native = try await session.mount(view, size: CGSize(width: 100, height: 40))
        let color = try await self.tint(session, 0x2000_0000)

        let mask = try await session.construct("android.graphics.drawable.ColorDrawable", [.integer(-1)])
        _ = try await session.invoke(view, "setBackground", [try await session.construct(self.ripple, [color, .null, mask])])
        try await session.flush(view)
        XCTAssertEqual(native.members.drawable?.style.ripple?.kind, "rect")
        XCTAssertEqual(native.members.drawable?.style.color, UIColor(red: 0, green: 0, blue: 0, alpha: 0))

        _ = try await session.invoke(view, "setBackground", [try await session.construct(self.ripple, [color, .null, .null])])
        try await session.flush(view)
        XCTAssertEqual(native.members.drawable?.style.ripple?.kind, "circle")
        XCTAssertEqual(native.members.drawable?.style.ripple?.bounded, false)
    }

    func testWhatCannotBeDrawnIsRefused() async throws {
        let session = try await AyuMemberTestHost()
        let color = try await self.tint(session, 0x2000_0000)
        let oval = try await session.construct("android.graphics.drawable.GradientDrawable")
        _ = try await session.invoke(oval, "setShape", [.integer(1)])
        let ovalCode = await session.failure { try await session.construct(self.ripple, [color, oval, .null]) }
        XCTAssertEqual(ovalCode, "UNSUPPORTED_API")
        let arity = await session.failure { try await session.construct(self.ripple, [color, .null]) }
        XCTAssertEqual(arity, "INVALID_ARGUMENTS")
        let noColor = await session.failure { try await session.construct(self.ripple, [.null, .null, .null]) }
        XCTAssertEqual(noColor, "INVALID_ARGUMENTS")
    }
}
