import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

@MainActor
final class AyuBridgeViewMembersTests: XCTestCase {
    private let textView = "android.widget.TextView"
    private let editText = "android.widget.EditText"
    private let linearLayout = "android.widget.LinearLayout"
    private let frameLayout = "android.widget.FrameLayout"
    private let progressBar = "android.widget.ProgressBar"

    private func layoutParams(_ session: AyuMemberTestHost, _ className: String, _ width: Double, _ height: Double, weight: Double? = nil) async throws -> AyuBridgeValue {
        try await session.construct(className + "$LayoutParams", [.number(width), .number(height)] + (weight.map { [.number($0)] } ?? []))
    }

    func testLineAndLetterSpacingAreDrawnAndReadBack() async throws {
        let session = try await AyuMemberTestHost()
        let text = try await session.construct(self.textView)
        _ = try await session.invoke(text, "setText", [.string("one\ntwo\nthree")])
        _ = try await session.invoke(text, "setTextSize", [.integer(1), .number(20)])
        let native = try await session.mount(text)
        let label = try XCTUnwrap(native.label)
        let unbounded = CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        let plain = label.sizeThatFits(unbounded)
        ayuExpect(try await session.invoke(text, "getLineSpacingExtra"), .number(0))
        ayuExpect(try await session.invoke(text, "getLineSpacingMultiplier"), .number(1))
        ayuExpect(try await session.invoke(text, "getLetterSpacing"), .number(0))

        // Android adds the extra after every line but the last: two gaps for three lines.
        ayuExpect(try await session.invoke(text, "setLineSpacing", [.number(6), .number(1)]), .null)
        try await session.flush(text)
        XCTAssertEqual(label.sizeThatFits(unbounded).height, plain.height + 12, accuracy: 1)
        ayuExpect(try await session.invoke(text, "getLineSpacingExtra"), .number(6))
        _ = try await session.invoke(text, "setLineSpacing", [.integer(0), .number(1.5)])
        try await session.flush(text)
        XCTAssertEqual(label.sizeThatFits(unbounded).height, plain.height + 2 * label.font.lineHeight * 0.5, accuracy: 1)
        ayuExpect(try await session.invoke(text, "getLineSpacingMultiplier"), .number(1.5))

        // The spacing survives a new text, size, color and typeface.
        _ = try await session.invoke(text, "setText", [.string("a\nb\nc\nd")])
        _ = try await session.invoke(text, "setTextColor", [.integer(-65536)])
        try await session.flush(text)
        let paragraph = try XCTUnwrap(label.attributedText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.lineSpacing, label.font.lineHeight * 0.5, accuracy: 0.01)
        XCTAssertEqual(label.text, "a\nb\nc\nd")
        XCTAssertEqual(label.numberOfLines, 0)

        // Letter spacing is in ems of the text size.
        _ = try await session.invoke(text, "setLineSpacing", [.number(0), .number(1)])
        _ = try await session.invoke(text, "setText", [.string("wide")])
        try await session.flush(text)
        let narrow = label.sizeThatFits(unbounded).width
        XCTAssertNil(label.attributedText?.attribute(.kern, at: 0, effectiveRange: nil))
        _ = try await session.invoke(text, "setLetterSpacing", [.number(0.1)])
        try await session.flush(text)
        XCTAssertEqual(label.attributedText?.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(label.sizeThatFits(unbounded).width, narrow + 4 * 2, accuracy: 2.5)
        ayuExpect(try await session.invoke(text, "getLetterSpacing"), .number(0.1))
        _ = try await session.invoke(text, "setTextSize", [.integer(1), .number(10)])
        try await session.flush(text)
        XCTAssertEqual(label.attributedText?.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat ?? 0, 1, accuracy: 0.001)
        _ = try await session.invoke(text, "setLetterSpacing", [.number(0)])
        try await session.flush(text)
        XCTAssertNil(label.attributedText?.attribute(.kern, at: 0, effectiveRange: nil))

        // A negative extra shortens the lines.
        _ = try await session.invoke(text, "setText", [.string("one\ntwo\nthree")])
        _ = try await session.invoke(text, "setLineSpacing", [.number(-2), .number(1)])
        try await session.flush(text)
        XCTAssertLessThan(label.sizeThatFits(unbounded).height, 3 * label.font.lineHeight)

        var code = await session.failure { try await session.invoke(text, "setLineSpacing", [.number(1)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        code = await session.failure { try await session.invoke(text, "setLineSpacing", [.number(1), .number(-1)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        code = await session.failure { try await session.invoke(text, "setLetterSpacing", [.string("wide")]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        code = await session.failure { try await session.invoke(text, "getLetterSpacing", [.integer(1)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
    }

    func testIncludeFontPaddingIsStateOnlyAndEditTextTakesLetterSpacing() async throws {
        let session = try await AyuMemberTestHost()
        let text = try await session.construct(self.textView)
        ayuExpect(try await session.invoke(text, "getIncludeFontPadding"), .bool(true))
        ayuExpect(try await session.invoke(text, "setIncludeFontPadding", [.bool(false)]), .null)
        ayuExpect(try await session.invoke(text, "getIncludeFontPadding"), .bool(false))
        let code = await session.failure { try await session.invoke(text, "setIncludeFontPadding", [.integer(0)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")

        let edit = try await session.construct(self.editText)
        _ = try await session.invoke(edit, "setTextSize", [.integer(1), .number(20)])
        _ = try await session.invoke(edit, "setLetterSpacing", [.number(0.05)])
        let native = try await session.mount(edit)
        XCTAssertEqual(try XCTUnwrap(native.textField).defaultTextAttributes[.kern] as? CGFloat ?? 0, 1, accuracy: 0.001)
        ayuExpect(try await session.invoke(edit, "setLineSpacing", [.number(4), .number(1)]), .null)
        ayuExpect(try await session.invoke(edit, "setIncludeFontPadding", [.bool(true)]), .null)
    }

    func testPixelMinimumsOfTextViews() async throws {
        let session = try await AyuMemberTestHost()
        let root = try await session.construct(self.linearLayout)
        let text = try await session.construct(self.textView)
        _ = try await session.invoke(text, "setText", [.string("x")])
        _ = try await session.invoke(root, "addView", [text, try await self.layoutParams(session, self.linearLayout, -2, -2)])
        _ = try await session.mount(root)
        let naturalWidth = try await session.invoke(text, "getWidth").number ?? 0
        let naturalHeight = try await session.invoke(text, "getHeight").number ?? 0
        XCTAssertLessThan(naturalWidth, 60)
        ayuExpect(try await session.invoke(text, "getMinHeight"), .integer(-1))
        ayuExpect(try await session.invoke(text, "getMinWidth"), .integer(-1))

        _ = try await session.invoke(text, "setMinHeight", [.integer(80)])
        _ = try await session.invoke(text, "setMinWidth", [.integer(120)])
        ayuExpect(try await session.invoke(text, "getWidth"), .number(120))
        ayuExpect(try await session.invoke(text, "getHeight"), .number(80))
        ayuExpect(try await session.invoke(text, "getMinHeight"), .integer(80))
        ayuExpect(try await session.invoke(text, "getMinWidth"), .integer(120))
        // The View minimum is a separate property and is unchanged.
        ayuExpect(try await session.invoke(text, "getMinimumHeight"), .integer(0))

        // A minimum in lines replaces the pixel minimum, as the pixel minimum replaced the lines.
        _ = try await session.invoke(text, "setMinLines", [.integer(2)])
        let twoLines = try await session.invoke(text, "getHeight").number ?? 0
        XCTAssertLessThan(twoLines, 80)
        XCTAssertGreaterThan(twoLines, naturalHeight)
        _ = try await session.invoke(text, "setMinHeight", [.integer(0)])
        ayuExpect(try await session.invoke(text, "getHeight"), .number(naturalHeight))

        let edit = try await session.construct(self.editText)
        _ = try await session.invoke(root, "addView", [edit, try await self.layoutParams(session, self.linearLayout, -2, -2)])
        _ = try await session.invoke(edit, "setMinHeight", [.integer(64)])
        ayuExpect(try await session.invoke(edit, "getHeight"), .number(64))
        let code = await session.failure { try await session.invoke(root, "setMinHeight", [.integer(10)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
    }

    func testSelectableTextIsShownInASelectableCopy() async throws {
        let session = try await AyuMemberTestHost()
        let text = try await session.construct(self.textView)
        _ = try await session.invoke(text, "setText", [.string("select me")])
        let native = try await session.mount(text)
        let label = try XCTUnwrap(native.label)
        ayuExpect(try await session.invoke(text, "isTextSelectable"), .bool(false))
        XCTAssertNil(native.subviews.first { $0 is UITextView })

        ayuExpect(try await session.invoke(text, "setTextIsSelectable", [.bool(true)]), .null)
        try await session.flush(text)
        let copy = try XCTUnwrap(native.subviews.compactMap { $0 as? UITextView }.first)
        XCTAssertTrue(copy.isSelectable)
        XCTAssertFalse(copy.isEditable)
        XCTAssertFalse(copy.isScrollEnabled)
        XCTAssertEqual(copy.text, "select me")
        XCTAssertEqual(copy.frame, label.frame)
        XCTAssertTrue(label.isHidden)
        ayuExpect(try await session.invoke(text, "isTextSelectable"), .bool(true))
        // The copy follows the text and still reports it.
        _ = try await session.invoke(text, "setText", [.string("changed")])
        try await session.flush(text)
        XCTAssertEqual(copy.text, "changed")
        ayuExpect(try await session.invoke(text, "getText"), .string("changed"))

        _ = try await session.invoke(text, "setTextIsSelectable", [.bool(false)])
        try await session.flush(text)
        XCTAssertNil(native.subviews.first { $0 is UITextView })
        XCTAssertFalse(label.isHidden)
        let edit = try await session.construct(self.editText)
        let code = await session.failure { try await session.invoke(edit, "setTextIsSelectable", [.bool(true)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
    }

    func testLongClickListenerOnEveryViewClass() async throws {
        let session = try await AyuMemberTestHost()
        let frame = try await session.construct(self.frameLayout)
        let native = try await session.mount(frame)
        ayuExpect(try await session.invoke(frame, "isLongClickable"), .bool(false))
        let listener = try await session.proxy("android.view.View$OnLongClickListener", ["onLongClick": "long-1"])
        ayuExpect(try await session.invoke(frame, "setOnLongClickListener", [listener]), .null)
        try await session.flush(frame)
        // A listener makes the view long-clickable.
        ayuExpect(try await session.invoke(frame, "isLongClickable"), .bool(true))
        let recognizer = try XCTUnwrap(native.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first)
        XCTAssertEqual(recognizer.minimumPressDuration, 0.5)
        XCTAssertFalse(recognizer.cancelsTouchesInView)

        native.membersPerformLongClick()
        var delivered = await session.deliveredCallbacks(count: 1)
        XCTAssertEqual(delivered.map(\.id), ["long-1"])
        XCTAssertEqual(delivered.first?.arguments, [frame])
        // Only the start of the gesture is a long click: an idle recognizer reports nothing.
        native.membersLongPressed(recognizer)

        // A disabled or no longer long-clickable view does not report it.
        _ = try await session.invoke(frame, "setEnabled", [.bool(false)])
        try await session.flush(frame)
        native.membersPerformLongClick()
        _ = try await session.invoke(frame, "setEnabled", [.bool(true)])
        _ = try await session.invoke(frame, "setLongClickable", [.bool(false)])
        try await session.flush(frame)
        ayuExpect(try await session.invoke(frame, "isLongClickable"), .bool(false))
        XCTAssertNil(native.gestureRecognizers?.first { $0 is UILongPressGestureRecognizer })
        _ = try await session.invoke(frame, "setLongClickable", [.bool(true)])
        try await session.flush(frame)
        XCTAssertNotNil(native.gestureRecognizers?.first { $0 is UILongPressGestureRecognizer })
        native.membersPerformLongClick()
        delivered = await session.deliveredCallbacks(count: 2)
        XCTAssertEqual(delivered.map(\.id), ["long-1", "long-1"])

        // A click listener set afterwards waits for the long press to fail.
        _ = try await session.invoke(frame, "setOnClickListener", [.object(["$callback": .string("click-1")])])
        try await session.flush(frame)
        XCTAssertNotNil(native.gestureRecognizers?.first { $0 is UITapGestureRecognizer })

        ayuExpect(try await session.invoke(frame, "setOnLongClickListener", [.null]), .null)
        try await session.flush(frame)
        XCTAssertNil(native.gestureRecognizers?.first { $0 is UILongPressGestureRecognizer })

        // A plain callable is accepted like a proxy, on every view class.
        for className in ["android.view.View", self.textView, self.editText, self.linearLayout, "android.widget.ImageView", "android.widget.ScrollView"] {
            let view = try await session.construct(className)
            ayuExpect(try await session.invoke(view, "setOnLongClickListener", [.object(["$callback": .string("long-2")])]), .null, className)
        }
        let code = await session.failure { try await session.invoke(frame, "setLongClickable", [.integer(1)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
    }

    func testEditTextFocusMembers() async throws {
        let session = try await AyuMemberTestHost()
        let edit = try await session.construct(self.editText)
        _ = try await session.invoke(edit, "setText", [.string("focus")])
        let native = try await session.mount(edit)
        let field = try XCTUnwrap(native.textField)
        ayuExpect(try await session.invoke(edit, "isCursorVisible"), .bool(true))
        ayuExpect(try await session.invoke(edit, "setCursorVisible", [.bool(false)]), .null)
        try await session.flush(edit)
        XCTAssertEqual(field.tintColor, .clear)
        ayuExpect(try await session.invoke(edit, "isCursorVisible"), .bool(false))
        _ = try await session.invoke(edit, "setCursorVisible", [.bool(true)])
        try await session.flush(edit)
        XCTAssertNotEqual(field.tintColor, .clear)

        let listener = try await session.proxy("android.view.View$OnFocusChangeListener", ["onFocusChange": "focus-1"])
        ayuExpect(try await session.invoke(edit, "setOnFocusChangeListener", [listener]), .null)
        ayuExpect(try await session.invoke(edit, "setSelectAllOnFocus", [.bool(true)]), .null)
        try await session.flush(edit)
        XCTAssertTrue(field.allTargets.contains(native))
        XCTAssertTrue(native.members.selectAllOnFocus)
        native.membersEditingBegan()
        native.membersEditingEnded()
        let delivered = await session.deliveredCallbacks(count: 2)
        XCTAssertEqual(delivered.map(\.id), ["focus-1", "focus-1"])
        XCTAssertEqual(delivered.map(\.arguments), [[edit, .bool(true)], [edit, .bool(false)]])
        ayuExpect(try await session.invoke(edit, "setOnFocusChangeListener", [.null]), .null)
        try await session.flush(edit)
        native.membersEditingBegan()
        XCTAssertNil(native.members.focusCallback)

        let text = try await session.construct(self.textView)
        for (method, argument) in [("setSelectAllOnFocus", AyuBridgeValue.bool(true)), ("setCursorVisible", .bool(true)), ("setOnFocusChangeListener", .null)] {
            let code = await session.failure { try await session.invoke(text, method, [argument]) }
            XCTAssertEqual(code, "UNSUPPORTED_API", method)
        }
    }

    func testWeightSumDividesTheRemainingSpace() async throws {
        let session = try await AyuMemberTestHost()
        let root = try await session.construct(self.linearLayout)
        _ = try await session.invoke(root, "setOrientation", [.integer(0)])
        let child = try await session.construct("android.view.View")
        _ = try await session.invoke(root, "addView", [child, try await self.layoutParams(session, self.linearLayout, 0, 20, weight: 1)])
        _ = try await session.mount(root, size: CGSize(width: 200, height: 100))
        ayuExpect(try await session.invoke(child, "getWidth"), .number(200))
        ayuExpect(try await session.invoke(root, "getWeightSum"), .number(0))
        // One of four parts of the free 200 points.
        ayuExpect(try await session.invoke(root, "setWeightSum", [.number(4)]), .null)
        ayuExpect(try await session.invoke(child, "getWidth"), .number(50))
        ayuExpect(try await session.invoke(root, "getWeightSum"), .number(4))
        // Zero or less is the sum of the children's weights again.
        _ = try await session.invoke(root, "setWeightSum", [.number(-3)])
        ayuExpect(try await session.invoke(child, "getWidth"), .number(200))
        ayuExpect(try await session.invoke(root, "getWeightSum"), .number(0))
        XCTAssertEqual(AyuBridgeLinearLayoutWeights.distribute(remaining: 90, weights: [1, 2], weightSum: 9), [10, 20])
        XCTAssertEqual(AyuBridgeLinearLayoutWeights.distribute(remaining: 90, weights: [1, 2]), [30, 60])
        let frame = try await session.construct(self.frameLayout)
        let code = await session.failure { try await session.invoke(frame, "setWeightSum", [.number(1)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
    }

    func testProgressBarIndeterminateModeAndTints() async throws {
        let session = try await AyuMemberTestHost()
        let horizontal = try await session.construct(self.progressBar, [.null, .null, .integer(0x0101_0078)])
        let native = try await session.mount(horizontal, size: CGSize(width: 200, height: 20))
        let progress = try XCTUnwrap(native.progressBar)
        _ = try await session.invoke(horizontal, "setProgress", [.integer(50)])
        try await session.flush(horizontal)
        XCTAssertEqual(progress.progress, 0.5)
        ayuExpect(try await session.invoke(horizontal, "isIndeterminate"), .bool(false))

        ayuExpect(try await session.invoke(horizontal, "setIndeterminate", [.bool(true)]), .null)
        try await session.flush(horizontal)
        ayuExpect(try await session.invoke(horizontal, "isIndeterminate"), .bool(true))
        XCTAssertTrue(native.members.indeterminate)
        XCTAssertEqual(progress.progress, 0)
        let bar = try XCTUnwrap(progress.layer.sublayers?.last)
        XCTAssertEqual(bar.bounds.width, 80, accuracy: 0.01)
        XCTAssertEqual((bar.animation(forKey: "travel") as? CABasicAnimation)?.repeatCount, .infinity)
        // The value is kept but not shown while indeterminate.
        _ = try await session.invoke(horizontal, "setProgress", [.integer(80)])
        try await session.flush(horizontal)
        XCTAssertEqual(progress.progress, 0)
        ayuExpect(try await session.invoke(horizontal, "getProgress"), .integer(80))
        let red = try await session.invokeStatic("android.content.res.ColorStateList", "valueOf", [.integer(-65536)])
        _ = try await session.invoke(horizontal, "setIndeterminateTintList", [red])
        try await session.flush(horizontal)
        XCTAssertEqual(bar.backgroundColor, UIColor(red: 1, green: 0, blue: 0, alpha: 1).cgColor)

        _ = try await session.invoke(horizontal, "setIndeterminate", [.bool(false)])
        try await session.flush(horizontal)
        XCTAssertFalse(native.members.indeterminate)
        XCTAssertEqual(progress.progress, 0.8, accuracy: 0.001)
        ayuExpect(try await session.invoke(horizontal, "isIndeterminate"), .bool(false))
        _ = try await session.invoke(horizontal, "setProgressBackgroundTintList", [red])
        try await session.flush(horizontal)
        XCTAssertEqual(progress.trackTintColor, UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        _ = try await session.invoke(horizontal, "setProgressBackgroundTintList", [.null])
        try await session.flush(horizontal)
        XCTAssertNil(progress.trackTintColor)
        var code = await session.failure { try await session.invoke(horizontal, "setIndeterminateTintList", [.integer(-1)]) }
        XCTAssertNotNil(code)
        code = await session.failure { try await session.invoke(horizontal, "setIndeterminate", [.integer(1)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
    }

    func testCircularProgressBarStaysIndeterminateAndTakesATint() async throws {
        let session = try await AyuMemberTestHost()
        let circular = try await session.construct(self.progressBar, [.null])
        let native = try await session.mount(circular, size: CGSize(width: 60, height: 60))
        let indicator = try XCTUnwrap(native.indeterminateProgressBar)
        let original = indicator.color
        // The default style is indeterminate only: Android ignores the call.
        ayuExpect(try await session.invoke(circular, "setIndeterminate", [.bool(false)]), .null)
        try await session.flush(circular)
        ayuExpect(try await session.invoke(circular, "isIndeterminate"), .bool(true))
        XCTAssertTrue(indicator.isAnimating)
        let green = try await session.invokeStatic("android.content.res.ColorStateList", "valueOf", [.integer(-16711936)])
        _ = try await session.invoke(circular, "setIndeterminateTintList", [green])
        try await session.flush(circular)
        XCTAssertEqual(indicator.color, UIColor(red: 0, green: 1, blue: 0, alpha: 1))
        _ = try await session.invoke(circular, "setIndeterminateTintList", [.null])
        try await session.flush(circular)
        XCTAssertEqual(indicator.color, original)
        let text = try await session.construct(self.textView)
        let code = await session.failure { try await session.invoke(text, "setIndeterminate", [.bool(true)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
    }

    func testCapabilitiesPublishTheMembersPerClassAndTheListenerInterfaces() async throws {
        let session = try await AyuMemberTestHost()
        let capabilities = try await session.call("runtime.capabilities", owner: "inspector", pluginID: "$runtime")
        func methods(_ name: String) -> Set<String> { Set(capabilities["members"]["classes"][name]["methods"].array?.compactMap(\.string) ?? []) }
        let textMembers: Set<String> = ["setIncludeFontPadding", "getIncludeFontPadding", "setLineSpacing", "setLetterSpacing", "getLetterSpacing",
                                        "setMinHeight", "setMinWidth", "setTypeface", "getTypeface"]
        XCTAssertTrue(textMembers.union(["setTextIsSelectable", "setOnLongClickListener", "setLongClickable", "isLongClickable"]).isSubset(of: methods(self.textView)))
        XCTAssertTrue(textMembers.union(["setSelectAllOnFocus", "setCursorVisible", "setOnFocusChangeListener", "setOnLongClickListener"]).isSubset(of: methods(self.editText)))
        XCTAssertFalse(methods(self.editText).contains("setTextIsSelectable"))
        XCTAssertTrue(methods(self.frameLayout).isDisjoint(with: textMembers.union(["setWeightSum", "setIndeterminate", "setSelectAllOnFocus"])))
        XCTAssertTrue(methods(self.frameLayout).isSuperset(of: ["setOnLongClickListener", "setLongClickable"]))
        XCTAssertTrue(methods(self.linearLayout).isSuperset(of: ["setWeightSum", "getWeightSum", "setOnLongClickListener"]))
        XCTAssertTrue(methods(self.progressBar).isSuperset(of: ["setIndeterminate", "isIndeterminate", "setIndeterminateTintList", "setProgressBackgroundTintList"]))
        XCTAssertFalse(methods(self.textView).contains("setIndeterminate"))
        XCTAssertEqual(capabilities["proxy_interfaces"]["android.view.View$OnLongClickListener"], .array([.string("onLongClick")]))
        XCTAssertEqual(capabilities["proxy_interfaces"]["android.view.View$OnFocusChangeListener"], .array([.string("onFocusChange")]))
        let classes = Set(capabilities["classes"].array?.compactMap(\.string) ?? [])
        XCTAssertTrue(classes.isSuperset(of: ["android.view.View$OnLongClickListener", "android.view.View$OnFocusChangeListener",
                                              "android.graphics.drawable.GradientDrawable$Orientation", "android.graphics.drawable.ShapeDrawable",
                                              "android.graphics.drawable.RippleDrawable"]))
        // The members are direct calls only: a UI transaction refuses them.
        let text = try await session.construct(self.textView)
        let code = await session.failure {
            try await session.call("ui.transaction", ["commands": .array([.object(["target": text, "method": .string("setLineSpacing"), "args": .array([.number(1), .number(1)])])])])
        }
        XCTAssertEqual(code, "UNSUPPORTED_API")
    }
}
