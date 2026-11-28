import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

@MainActor
final class AyuWave5ViewsTests: XCTestCase {
    private let textView = "android.widget.TextView"

    func testShadowLayerIsDrawnByTheLabelAndReadBack() async throws {
        let session = try await AyuMemberTestHost()
        let text = try await session.construct(self.textView)
        _ = try await session.invoke(text, "setText", [.string("shadow")])
        let native = try await session.mount(text)
        let label = try XCTUnwrap(native.label)
        XCTAssertEqual(label.layer.shadowOpacity, 0)
        ayuExpect(try await session.invoke(text, "getShadowRadius"), .number(0))
        ayuExpect(try await session.invoke(text, "getShadowColor"), .integer(0))

        ayuExpect(try await session.invoke(text, "setShadowLayer", [.number(4), .number(1.5), .number(-2), .integer(-0x8000_0000 + 0xFF0000)]), .null)
        try await session.flush(text)
        XCTAssertEqual(label.layer.shadowOpacity, 1)
        XCTAssertEqual(label.layer.shadowRadius, 0.57735 * 4 + 0.5, accuracy: 0.001)
        XCTAssertEqual(label.layer.shadowOffset, CGSize(width: 1.5, height: -2))
        let components = try XCTUnwrap(label.layer.shadowColor?.components)
        XCTAssertEqual(components.count, 4)
        XCTAssertEqual(components[0], 1, accuracy: 0.001)
        XCTAssertEqual(components[1], 0, accuracy: 0.001)
        XCTAssertEqual(components[3], 128.0 / 255, accuracy: 0.001)
        ayuExpect(try await session.invoke(text, "getShadowRadius"), .number(4))
        ayuExpect(try await session.invoke(text, "getShadowDx"), .number(1.5))
        ayuExpect(try await session.invoke(text, "getShadowDy"), .number(-2))
        ayuExpect(try await session.invoke(text, "getShadowColor"), .integer(-0x8000_0000 + 0xFF0000))

        // The selectable copy that replaces the label draws the same shadow.
        _ = try await session.invoke(text, "setTextIsSelectable", [.bool(true)])
        try await session.flush(text)
        let copy = try XCTUnwrap(native.subviews.compactMap { $0 as? UITextView }.first)
        XCTAssertEqual(copy.layer.shadowOpacity, 1)
        XCTAssertEqual(copy.layer.shadowOffset, CGSize(width: 1.5, height: -2))

        // A zero radius removes the shadow, as on Android.
        _ = try await session.invoke(text, "setShadowLayer", [.integer(0), .integer(0), .integer(0), .integer(0)])
        try await session.flush(text)
        XCTAssertEqual(label.layer.shadowOpacity, 0)
        XCTAssertEqual(copy.layer.shadowOpacity, 0)

        var code = await session.failure { try await session.invoke(text, "setShadowLayer", [.number(1), .number(0), .number(0)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        code = await session.failure { try await session.invoke(text, "setShadowLayer", [.string("big"), .number(0), .number(0), .integer(0)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        let edit = try await session.construct("android.widget.EditText")
        code = await session.failure { try await session.invoke(edit, "setShadowLayer", [.number(1), .number(0), .number(0), .integer(-1)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
    }

    func testLocationFillsAJavaIntArrayWithTheOffsetFromTheRoot() async throws {
        let session = try await AyuMemberTestHost()
        let frame = try await session.construct("android.widget.FrameLayout")
        let child = try await session.construct("android.view.View")
        let params = try await session.construct("android.widget.FrameLayout$LayoutParams", [.integer(40), .integer(30)])
        _ = try await session.invoke(params, "setMargins", [.integer(12), .integer(34), .integer(0), .integer(0)])
        _ = try await session.invoke(frame, "addView", [child, params])
        let native = try await session.mount(frame)
        let nativeChild = try XCTUnwrap(native.bridgeChildren.first)
        var root: UIView = native
        while let parent = root.superview { root = parent }
        let expected = nativeChild.convert(CGPoint.zero, to: root)
        XCTAssertEqual(nativeChild.frame.origin, CGPoint(x: 12, y: 34))

        for method in ["getLocationInWindow", "getLocationOnScreen"] {
            let location = try await session.array("int", [.integer(0), .integer(0)])
            ayuExpect(try await session.invoke(child, method, [location]), .null)
            ayuExpect(try await session.call("java.get_item", ["target": location, "index": .integer(0)]), .integer(Int64(expected.x.rounded())), method)
            ayuExpect(try await session.call("java.get_item", ["target": location, "index": .integer(1)]), .integer(Int64(expected.y.rounded())), method)
        }
        // A Python list is passed by value, as with Chaquopy: accepted, nothing to fill.
        ayuExpect(try await session.invoke(child, "getLocationInWindow", [.array([.integer(0), .integer(0)])]), .null)
        var code = await session.failure { try await session.invoke(child, "getLocationInWindow", [.array([.integer(0)])]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        let floats = try await session.array("float", [.number(0), .number(0)])
        code = await session.failure { try await session.invoke(child, "getLocationOnScreen", [floats]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        code = await session.failure { try await session.invoke(child, "getLocationOnScreen") }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
    }

    func testFontPaddingFlagDoesNotChangeTheMeasuredText() async throws {
        let session = try await AyuMemberTestHost()
        let text = try await session.construct(self.textView)
        _ = try await session.invoke(text, "setText", [.string("padding")])
        let native = try await session.mount(text)
        let label = try XCTUnwrap(native.label)
        let before = label.sizeThatFits(CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
        // UIKit measures a line from ascent to descent: there is no font padding to remove.
        XCTAssertEqual(before.height, label.font.lineHeight, accuracy: 1)
        ayuExpect(try await session.invoke(text, "setIncludeFontPadding", [.bool(false)]), .null)
        try await session.flush(text)
        XCTAssertEqual(label.sizeThatFits(CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)), before)
        ayuExpect(try await session.invoke(text, "getIncludeFontPadding"), .bool(false))
    }

    func testCapabilitiesPublishTheShadowMembersForTextViewOnly() async throws {
        let session = try await AyuMemberTestHost()
        let capabilities = try await session.call("runtime.capabilities", owner: "inspector", pluginID: "$runtime")
        func methods(_ name: String) -> Set<String> { Set(capabilities["members"]["classes"][name]["methods"].array?.compactMap(\.string) ?? []) }
        let shadow: Set<String> = ["setShadowLayer", "getShadowRadius", "getShadowDx", "getShadowDy", "getShadowColor"]
        XCTAssertTrue(shadow.isSubset(of: methods(self.textView)))
        for other in ["android.widget.EditText", "android.widget.CheckBox", "android.widget.FrameLayout", "android.widget.LinearLayout", "android.view.View"] {
            XCTAssertTrue(methods(other).isDisjoint(with: shadow), other)
        }
    }
}
