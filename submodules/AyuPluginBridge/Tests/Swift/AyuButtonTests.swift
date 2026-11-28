import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// `android.widget.Button`: a TextView with the defaults of the Material light Button style, and
/// `TextView.setAllCaps`.
@MainActor
final class AyuButtonTests: XCTestCase {
    private let button = "android.widget.Button"
    private let frame = "android.widget.FrameLayout"

    private func wrapped(_ session: AyuMemberTestHost, _ view: AyuBridgeValue, in root: AyuBridgeValue) async throws {
        _ = try await session.invoke(root, "addView", [view, try await session.construct(self.frame + "$LayoutParams", [.integer(-2), .integer(-2)])])
    }

    private func native(_ root: AyuBridgeView, _ index: Int) throws -> AyuBridgeView {
        try XCTUnwrap(root.bridgeChildren.indices.contains(index) ? root.bridgeChildren[index] : nil)
    }

    func testANewButtonHasTheDefaultsOfItsStyle() async throws {
        let session = try await AyuMemberTestHost()
        let root = try await session.construct(self.frame)
        let short = try await session.construct(self.button)
        _ = try await session.invoke(short, "setText", [.string("ok")])
        try await self.wrapped(session, short, in: root)
        let long = try await session.construct(self.button)
        _ = try await session.invoke(long, "setText", [.string("a rather long button label")])
        try await self.wrapped(session, long, in: root)
        let plain = try await session.construct("android.widget.TextView")
        _ = try await session.invoke(plain, "setText", [.string("A RATHER LONG BUTTON LABEL")])
        _ = try await session.invoke(plain, "setTypeface", [try await session.invoke(long, "getTypeface")])
        _ = try await session.invoke(plain, "setTextSize", [.integer(14)])
        try await self.wrapped(session, plain, in: root)
        let mounted = try await session.mount(root, size: CGSize(width: 320, height: 200))

        // The minimum size of the style; the text is centred, shown in capitals and read back as set.
        ayuExpect(try await session.invoke(short, "getWidth"), .integer(88))
        ayuExpect(try await session.invoke(short, "getHeight"), .integer(48))
        ayuExpect(try await session.invoke(short, "getText"), .string("ok"))
        XCTAssertEqual(try self.native(mounted, 0).label?.text, "OK")
        ayuExpect(try await session.invoke(short, "isAllCaps"), .bool(true))
        ayuExpect(try await session.invoke(short, "getGravity"), .integer(17))
        ayuExpect(try await session.invoke(short, "isClickable"), .bool(true))
        ayuExpect(try await session.invoke(short, "getMinimumHeight"), .integer(48))
        ayuExpect(try await session.invoke(short, "getMinimumWidth"), .integer(88))
        ayuExpect(try await session.invoke(short, "getMinHeight"), .integer(48))
        ayuExpect(try await session.invoke(short, "getPaddingLeft"), .integer(12))
        ayuExpect(try await session.invoke(short, "getPaddingTop"), .integer(10))
        ayuExpect(try await session.invoke(try await session.invoke(short, "getTypeface"), "getWeight"), .integer(500))
        XCTAssertEqual(try self.native(mounted, 0).label?.font.pointSize, 14)

        // A longer label: the capitals in the medium face, plus 12 of padding on each side.
        let textWidth = try await session.invoke(plain, "getWidth").number ?? 0
        XCTAssertGreaterThan(textWidth, 88)
        ayuExpect(try await session.invoke(long, "getWidth"), .number(textWidth + 24))

        // The grey background of the style sits inside the drawable's inset.
        let background = try XCTUnwrap(try self.native(mounted, 0).buttonBackground)
        XCTAssertEqual(background.layer.frame, CGRect(x: 4, y: 6, width: 80, height: 36))

        if let directory = ProcessInfo.processInfo.environment["AYU_PLUGIN_TEST_SNAPSHOT_DIR"] {
            // The three views overlap at the origin of the frame; show them side by side.
            let views = [try self.native(mounted, 0), try self.native(mounted, 1)]
            let canvas = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 140))
            canvas.backgroundColor = .white
            let image = UIGraphicsImageRenderer(bounds: canvas.bounds).image { context in
                canvas.layer.render(in: context.cgContext)
                for (index, view) in views.enumerated() {
                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: 16, y: 16 + CGFloat(index) * 60)
                    view.layer.render(in: context.cgContext)
                    context.cgContext.restoreGState()
                }
            }
            try? image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("button-default.png"))
        }

        _ = try await session.invoke(short, "setAllCaps", [.bool(false)])
        try await session.flush(short)
        XCTAssertEqual(try self.native(mounted, 0).label?.text, "ok")
        ayuExpect(try await session.invoke(short, "isAllCaps"), .bool(false))
    }

    func testAPluginsBackgroundReplacesTheDefaultOneAndKeepsThePadding() async throws {
        let session = try await AyuMemberTestHost()
        let root = try await session.construct(self.frame)
        let button = try await session.construct(self.button)
        try await self.wrapped(session, button, in: root)
        let mounted = try await session.mount(root, size: CGSize(width: 320, height: 200))
        let view = try self.native(mounted, 0)
        XCTAssertNotNil(view.buttonBackground)
        _ = try await session.invoke(button, "setBackgroundColor", [.integer(-16_776_961)])
        try await session.flush(button)
        XCTAssertNil(view.buttonBackground)
        // A ColorDrawable has no padding of its own, so the view keeps the one it had.
        ayuExpect(try await session.invoke(button, "getPaddingLeft"), .integer(12))
        ayuExpect(try await session.invoke(button, "getPaddingBottom"), .integer(10))
        _ = try await session.invoke(button, "setPadding", [.integer(0), .integer(0), .integer(0), .integer(0)])
        ayuExpect(try await session.invoke(button, "getWidth"), .integer(88))
        ayuExpect(try await session.invoke(button, "getHeight"), .integer(48))
    }

    /// `AndroidUtilities.shakeView`: four swings of at most 4 points in 300 ms, ending where the view rests.
    func testShakingAViewSwingsItAndEndsAtRest() async throws {
        let offsets = AyuBridgeView.shakeOffsets(steps: 300)
        XCTAssertEqual(offsets.first ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(offsets.last ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(offsets.max() ?? 0, 3.5, accuracy: 0.6)
        XCTAssertEqual(offsets.min() ?? 0, -3.5, accuracy: 0.6)
        let turns = zip(offsets, offsets.dropFirst()).filter { ($0 < 0) != ($1 < 0) && $0 != 0 && $1 != 0 }.count
        XCTAssertEqual(turns, 3, "sin(4 * pi * x) changes sign three times inside the run")

        let session = try await AyuMemberTestHost()
        let text = try await session.construct("android.widget.TextView")
        _ = try await session.invoke(text, "setTranslationX", [.integer(9)])
        let view = try await session.mount(text)
        view.shake()
        let animation = try XCTUnwrap(view.layer.animation(forKey: "ayu.shake") as? CAKeyframeAnimation)
        XCTAssertEqual(animation.duration, 0.3)
        XCTAssertTrue(animation.isAdditive)
        XCTAssertEqual(view.translationX, 0, "Android leaves the translation at zero")
    }

    func testAllCapsOnATextViewAndNowhereElse() async throws {
        let session = try await AyuMemberTestHost()
        let text = try await session.construct("android.widget.TextView")
        _ = try await session.invoke(text, "setText", [.string("Straße one")])
        let view = try await session.mount(text)
        ayuExpect(try await session.invoke(text, "isAllCaps"), .bool(false))
        XCTAssertEqual(view.label?.text, "Straße one")
        _ = try await session.invoke(text, "setAllCaps", [.bool(true)])
        try await session.flush(text)
        XCTAssertEqual(view.label?.text, "Straße one".uppercased(with: Locale.current))
        ayuExpect(try await session.invoke(text, "getText"), .string("Straße one"))
        _ = try await session.invoke(text, "setText", [.string("two")])
        try await session.flush(text)
        XCTAssertEqual(view.label?.text, "TWO")

        let frame = try await session.construct(self.frame)
        var code = await session.failure { try await session.invoke(frame, "setAllCaps", [.bool(true)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.invoke(text, "setAllCaps", [.integer(1)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
    }
}

/// The button factory of the corpus games, through the real SDK and its member-aware preflight.
@MainActor
final class AyuButtonEndToEndTests: XCTestCase {
    func testAGameButtonIsBuiltAsThePluginsBuildIt() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let source = AyuEndToEnd.source(id: "e2e_button", """
        from android.graphics import Color, Typeface
        from android.graphics.drawable import GradientDrawable, StateListDrawable
        from android.widget import Button, LinearLayout
        from base_plugin import BasePlugin
        from org.telegram.messenger import AndroidUtilities, ApplicationLoader
        \(AyuEndToEnd.recorder)


        class ButtonPlugin(Recorder, BasePlugin):
            def _create_button(self, context, text, bg_color):
                button = Button(context)
                button.setText(text)
                button.setTextColor(Color.WHITE)
                button.setTypeface(None, Typeface.BOLD)
                button.setTextSize(12)
                button.setAllCaps(False)
                state_list = StateListDrawable()
                normal = GradientDrawable()
                normal.setColor(bg_color)
                normal.setCornerRadius(AndroidUtilities.dp(6))
                pressed = GradientDrawable()
                pressed.setColor(Color.argb(255, min(255, Color.red(bg_color) + 30), Color.green(bg_color), Color.blue(bg_color)))
                pressed.setCornerRadius(AndroidUtilities.dp(6))
                state_list.addState([16842919], pressed)
                state_list.addState([], normal)
                button.setBackground(state_list)
                button.setPadding(AndroidUtilities.dp(12), AndroidUtilities.dp(6), AndroidUtilities.dp(12), AndroidUtilities.dp(6))
                button.setLayoutParams(LinearLayout.LayoutParams(-2, -2))
                button.setOnClickListener(lambda view: None)
                return button

            def on_plugin_load(self):
                context = ApplicationLoader.applicationContext
                self.record("button", lambda: self._describe(self._create_button(context, "Restart", Color.parseColor("#3A7BD5"))))
                self.record("fresh", lambda: [Button(context).isAllCaps(), Button(context).getMinimumHeight(), Button(context).isClickable()])
                shaken = Button(context)
                self.record("shake", lambda: [AndroidUtilities.shakeView(shaken), AndroidUtilities.shakeView(None), shaken.getTranslationX()])

            def _describe(self, button):
                return [button.getText().toString() if hasattr(button.getText(), "toString") else str(button.getText()),
                        button.isAllCaps(), button.getTypeface().isBold(), button.getPaddingLeft(), button.getPaddingTop(),
                        button.getBackground().getClass().getName(), button.getLayoutParams().width, button.getGravity()]
        """)
        let preview = try await stack.preview(source)
        XCTAssertEqual(preview.plugin.blockers, [], "the path has no static blocker")
        let id = try await stack.start(source)
        XCTAssertEqual(stack.stored(id, "button"), .array([.string("Restart"), .bool(false), .bool(true), .integer(12), .integer(6),
                                                           .string("android.graphics.drawable.StateListDrawable"), .integer(-2), .integer(17)]))
        XCTAssertEqual(stack.stored(id, "fresh"), .array([.bool(true), .integer(48), .bool(true)]))
        XCTAssertEqual(stack.stored(id, "shake"), .array([.null, .null, .number(0)]))
        await stack.remove(id)
    }
}
