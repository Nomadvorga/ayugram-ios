import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// `org.telegram.ui.Components.EditTextBoldCursor`: Telegram's `EditText` subclass. It is an
/// `EditText` in every member and adds its cursor and line; its hint members are not provided.
@MainActor
final class AyuEditTextBoldCursorTests: XCTestCase {
    private let boldCursor = "org.telegram.ui.Components.EditTextBoldCursor"
    private let frame = "android.widget.FrameLayout"

    func testItIsAnEditTextInEveryMember() async throws {
        let session = try await AyuMemberTestHost()
        let root = try await session.construct(self.frame)
        let field = try await session.construct(self.boldCursor)
        let plain = try await session.construct("android.widget.EditText")
        for view in [field, plain] {
            _ = try await session.invoke(view, "setHint", [.string("Password")])
            _ = try await session.invoke(view, "setInputType", [.integer(0x81)])
            _ = try await session.invoke(view, "setSingleLine", [.bool(true)])
            _ = try await session.invoke(view, "setTextColor", [.integer(-16_777_216)])
            _ = try await session.invoke(view, "setHintTextColor", [.integer(-7_829_368)])
            _ = try await session.invoke(view, "setTextSize", [.integer(18)])
            _ = try await session.invoke(view, "setPadding", [.integer(8), .integer(4), .integer(8), .integer(4)])
            _ = try await session.invoke(view, "setCursorVisible", [.bool(true)])
            _ = try await session.invoke(view, "setText", [.string("secret")])
            _ = try await session.invoke(root, "addView", [view, try await session.construct(self.frame + "$LayoutParams", [.integer(-1), .integer(-2)])])
        }
        let mounted = try await session.mount(root, size: CGSize(width: 320, height: 200))
        let native = try XCTUnwrap(mounted.bridgeChildren.first)
        let reference = try XCTUnwrap(mounted.bridgeChildren.last)

        // A text field, laid out and read exactly like the EditText beside it.
        let textField = try XCTUnwrap(native.textField)
        XCTAssertNil(native.label)
        XCTAssertEqual(textField.text, "secret")
        XCTAssertTrue(textField.isSecureTextEntry)
        XCTAssertEqual(textField.placeholder ?? textField.attributedPlaceholder?.string, "Password")
        XCTAssertEqual(textField.font?.pointSize, 18)
        XCTAssertEqual(native.frame.size, reference.frame.size)
        XCTAssertGreaterThanOrEqual(native.frame.height, 36)
        ayuExpect(try await session.invoke(try await session.invoke(field, "getText"), "toString"), .string("secret"))
        ayuExpect(try await session.invoke(field, "isCursorVisible"), .bool(true))
        ayuExpect(try await session.invoke(field, "getPaddingLeft"), .integer(8))
        ayuExpect(try await session.invoke(field, "hasFocus"), .bool(false))
        _ = try await session.invoke(field, "setSelection", [.integer(2)])
        ayuExpect(try await session.invoke(field, "getSelectionStart"), .integer(2))

        // What an EditText refuses it refuses too, and its own members are not provided.
        let multiline = await session.failure { try await session.invoke(field, "setInputType", [.integer(0x2_0001)]) }
        XCTAssertEqual(multiline, "UNSUPPORTED_API")
        for (method, arguments) in [("setHintText", [AyuBridgeValue.string("x")]), ("setHintColor", [.integer(1)]), ("setMaxLines", [.integer(5)])] {
            let refused = await session.failure { try await session.invoke(field, method, arguments) }
            XCTAssertEqual(refused, "UNSUPPORTED_API", method)
        }
        // The cursor and line members are its own: a plain EditText has none of them.
        for (method, arguments) in [("setLineColors", [AyuBridgeValue.integer(1), .integer(2), .integer(3)]), ("setCursorColor", [.integer(1)]),
                                    ("setCursorSize", [.integer(20)]), ("setCursorWidth", [.number(1.5)]), ("getCursorColor", [])] {
            let refused = await session.failure { try await session.invoke(plain, method, arguments) }
            XCTAssertEqual(refused, "UNSUPPORTED_API", method)
        }
    }

    private func mounted(_ session: AyuMemberTestHost, _ field: AyuBridgeValue, height: Int64 = 48) async throws -> (AyuBridgeView, AyuBridgeBoldCursorField) {
        let root = try await session.construct(self.frame)
        _ = try await session.invoke(field, "setPadding", [.integer(10), .integer(6), .integer(10), .integer(6)])
        _ = try await session.invoke(field, "setText", [.string("secret")])
        _ = try await session.invoke(root, "addView", [field, try await session.construct(self.frame + "$LayoutParams", [.integer(-1), .integer(height)])])
        let mounted = try await session.mount(root, size: CGSize(width: 320, height: 200))
        let view = try XCTUnwrap(mounted.bridgeChildren.first)
        return (view, try XCTUnwrap(view.textField as? AyuBridgeBoldCursorField))
    }

    private func components(_ color: CGColor?) -> [Int] {
        (color?.components ?? []).map { Int(($0 * 255).rounded()) }
    }

    func testTheCursorIsTelegramsBarWithItsColourWidthAndSize() async throws {
        let session = try await AyuMemberTestHost()
        let field = try await session.construct(self.boldCursor)
        let (_, native) = try await self.mounted(session, field)

        // Android's defaults: 2 dp by dp(24) in 0xff54a1db, centred on the caret position.
        ayuExpect(try await session.invoke(field, "getCursorColor"), .integer(Int64(Int32(bitPattern: 0xff54_a1db))))
        XCTAssertEqual(self.components(native.tintColor.cgColor), [0x54, 0xa1, 0xdb, 255])
        let system = (native as UITextField).font?.lineHeight ?? 0
        var caret = native.caretRect(for: native.beginningOfDocument)
        XCTAssertEqual(caret.size, CGSize(width: 2, height: 24))
        XCTAssertLessThan(abs(caret.midY - native.bounds.midY), max(2, system / 4), "\(caret) in \(native.bounds)")

        _ = try await session.invoke(field, "setCursorColor", [.integer(0xff11_2233)])
        _ = try await session.invoke(field, "setCursorSize", [.integer(30)])
        _ = try await session.invoke(field, "setCursorWidth", [.number(1.5)])
        try await session.flush(field)
        ayuExpect(try await session.invoke(field, "getCursorColor"), .integer(Int64(Int32(bitPattern: 0xff11_2233))))
        XCTAssertEqual(self.components(native.tintColor.cgColor), [0x11, 0x22, 0x33, 255])
        let middle = caret.midY
        caret = native.caretRect(for: native.endOfDocument)
        XCTAssertEqual(caret.size, CGSize(width: 1.5, height: 30))
        XCTAssertEqual(caret.midY, middle, accuracy: 1)

        // Hiding the cursor keeps its colour for when it is shown again.
        _ = try await session.invoke(field, "setCursorVisible", [.bool(false)])
        try await session.flush(field)
        XCTAssertEqual(native.tintColor.cgColor.alpha, 0)
        _ = try await session.invoke(field, "setCursorVisible", [.bool(true)])
        try await session.flush(field)
        XCTAssertEqual(self.components(native.tintColor.cgColor), [0x11, 0x22, 0x33, 255])

        for (method, arguments) in [("setCursorColor", [AyuBridgeValue.string("red")]), ("setCursorColor", [.integer(1 << 40)]), ("setCursorSize", [.integer(-1)]),
                                    ("setCursorWidth", [.number(-1)]), ("setLineColors", [.integer(1), .integer(2)]), ("setLineColors", [.integer(1), .integer(2), .string("x")])] {
            let refused = await session.failure { try await session.invoke(field, method, arguments) }
            XCTAssertEqual(refused, "INVALID_ARGUMENTS", method)
        }
    }

    func testSetLineColorsDrawsTheLineUnderTheTextAndTheActiveOneWhileFocused() async throws {
        let session = try await AyuMemberTestHost()
        let field = try await session.construct(self.boldCursor)
        let (view, native) = try await self.mounted(session, field)
        XCTAssertFalse(native.lineVisible)
        XCTAssertNil(native.line.superlayer)

        _ = try await session.invoke(field, "setLineColors", [.integer(0xff80_8080), .integer(0xff33_66cc), .integer(0xffff_0000)])
        try await session.flush(field)
        view.layoutIfNeeded()
        // One point of the line colour across the whole view (padding included), ending 2 above the bottom.
        XCTAssertTrue(native.line.superlayer === view.layer)
        XCTAssertEqual(native.line.frame, CGRect(x: 0, y: view.bounds.height - 3, width: view.bounds.width, height: 1))
        XCTAssertEqual(self.components(native.line.backgroundColor), [0x80, 0x80, 0x80, 255])
        XCTAssertEqual(self.components(native.activeLine.backgroundColor), [0x33, 0x66, 0xcc, 255])
        XCTAssertEqual(native.activeLine.frame.height, 0)
        XCTAssertGreaterThan(view.bounds.width, native.frame.width)

        // Focused: two points of the active colour over it; unfocused: it thins out again.
        native.setLineActive(true, animated: false)
        XCTAssertEqual(native.activeLine.frame, CGRect(x: 0, y: view.bounds.height - 4, width: view.bounds.width, height: 2))
        view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(native.activeLine.frame.height, 2, "A layout pass keeps the state")
        native.setLineActive(false, animated: false)
        XCTAssertEqual(native.activeLine.frame.height, 0)

        // Android draws no line for the colour 0.
        _ = try await session.invoke(field, "setLineColors", [.integer(0), .integer(0xff33_66cc), .integer(0)])
        try await session.flush(field)
        XCTAssertTrue(native.line.isHidden)
        XCTAssertTrue(native.activeLine.isHidden)
    }
}
