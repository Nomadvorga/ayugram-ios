import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

final class AyuBridgeDrawableValueTests: XCTestCase {
    private let gradient = "android.graphics.drawable.GradientDrawable"
    private let orientation = "android.graphics.drawable.GradientDrawable$Orientation"

    private func adapter() throws -> AyuBridgeClassAdapter { try XCTUnwrap(AyuBridgeClassRegistry.standard.adapters[self.gradient]) }

    private func apply(_ method: String, _ args: [AyuBridgeValue], to state: inout [String: AyuBridgeValue],
                       objects: [String: AyuBridgeAdapterSnapshot] = [:]) throws {
        let adapter = try self.adapter()
        let result = try XCTUnwrap(adapter.methods[method])(&state, args, .memberTests(objects))
        XCTAssertEqual(result, .instance(className: self.gradient, state: state), method)
        XCTAssertNoThrow(try adapter.validateState(state), method)
        XCTAssertTrue(adapter.receiverMethods.contains(method), method)
    }

    func testGradientColorsAndSolidColorReplaceEachOther() throws {
        let adapter = try self.adapter()
        var state = try XCTUnwrap(adapter.constructor)([], .memberTests())
        XCTAssertEqual(state, ["color": .integer(0), "shape": .integer(0), "corner_radius": .number(0), "stroke_width": .number(0), "stroke_color": .integer(0)])
        try self.apply("setColor", [.integer(0xFF00_FF00)], to: &state)
        XCTAssertEqual(state["color"], .integer(-16711936))
        try self.apply("setColors", [.array([.integer(-65536), .integer(0xFF00_00FF), .integer(-1)])], to: &state)
        XCTAssertEqual(state["colors"], .array([.integer(-65536), .integer(-16776961), .integer(-1)]))
        XCTAssertEqual(state["color"], .integer(0))
        try self.apply("setColor", [.integer(-1)], to: &state)
        XCTAssertNil(state["colors"])
        // An owned int[] is read like a list; null removes the gradient and the fill.
        let array: AyuBridgeValue = .object(["$handle": .string("a"), "$class": .string("[I")])
        let objects = ["a": AyuBridgeAdapterSnapshot(className: "[I", state: ["component": .string("int"), "values": .array([.integer(1), .integer(2)])])]
        try self.apply("setColors", [array], to: &state, objects: objects)
        XCTAssertEqual(state["colors"], .array([.integer(1), .integer(2)]))
        try self.apply("setColors", [.null], to: &state)
        XCTAssertNil(state["colors"])
        XCTAssertEqual(state["color"], .integer(0))
        for invalid: AyuBridgeValue in [.array([.integer(1)]), .array([]), .array([.integer(1), .string("red")]), .integer(5), .array(Array(repeating: .integer(1), count: 17))] {
            var copy = state
            XCTAssertThrowsError(try XCTUnwrap(adapter.methods["setColors"])(&copy, [invalid], .memberTests()))
        }
    }

    func testCornerRadiiGradientGeometryAndAlpha() throws {
        let adapter = try self.adapter()
        var state = try XCTUnwrap(adapter.constructor)([], .memberTests())
        let radii: [AyuBridgeValue] = [8, 8, 8, 8, 0, 0, 0, 0].map { .number($0) }
        try self.apply("setCornerRadius", [.number(12)], to: &state)
        try self.apply("setCornerRadii", [.array(radii)], to: &state)
        XCTAssertEqual(state["corner_radii"], .array(radii))
        // One radius for all corners drops the array, and a null array drops the radius.
        try self.apply("setCornerRadius", [.integer(4)], to: &state)
        XCTAssertNil(state["corner_radii"])
        try self.apply("setCornerRadii", [.array(radii)], to: &state)
        try self.apply("setCornerRadii", [.null], to: &state)
        XCTAssertNil(state["corner_radii"])
        XCTAssertEqual(state["corner_radius"], .number(0))
        var copy = state
        XCTAssertThrowsError(try XCTUnwrap(adapter.methods["setCornerRadii"])(&copy, [.array(Array(radii.prefix(4)))], .memberTests()))
        XCTAssertThrowsError(try XCTUnwrap(adapter.methods["setCornerRadii"])(&copy, [.array(radii.dropLast() + [.number(-1)])], .memberTests()))

        try self.apply("setGradientType", [.integer(1)], to: &state)
        try self.apply("setGradientRadius", [.number(40)], to: &state)
        try self.apply("setGradientCenter", [.number(0.25), .number(0.75)], to: &state)
        try self.apply("setAlpha", [.integer(128)], to: &state)
        XCTAssertEqual(state["gradient_type"], .integer(1))
        XCTAssertEqual(state["gradient_radius"], .number(40))
        XCTAssertEqual([state["center_x"], state["center_y"]], [.number(0.25), .number(0.75)])
        XCTAssertEqual(state["alpha"], .integer(128))
        try self.apply("setAlpha", [.integer(255)], to: &state)
        XCTAssertNil(state["alpha"])
        XCTAssertThrowsError(try XCTUnwrap(adapter.methods["setGradientType"])(&copy, [.integer(3)], .memberTests()))
        XCTAssertThrowsError(try XCTUnwrap(adapter.methods["setAlpha"])(&copy, [.integer(256)], .memberTests()))
        XCTAssertThrowsError(try XCTUnwrap(adapter.methods["setShape"])(&copy, [.integer(2)], .memberTests()))

        let orientations = try XCTUnwrap(AyuBridgeClassRegistry.standard.adapters[self.orientation])
        XCTAssertEqual(Set(orientations.staticFields.keys), Set(AyuBridgeDrawables.orientations))
        guard case let .instance(_, value) = try XCTUnwrap(orientations.staticFields["BL_TR"])(.memberTests()) else { return XCTFail("no orientation") }
        var orientationState = value
        XCTAssertEqual(try XCTUnwrap(orientations.methods["name"])(&orientationState, [], .memberTests()), .value(.string("BL_TR")))
        XCTAssertEqual(try XCTUnwrap(orientations.methods["ordinal"])(&orientationState, [], .memberTests()), .value(.integer(5)))
        let reference: AyuBridgeValue = .object(["$handle": .string("o"), "$class": .string(self.orientation)])
        let objects = ["o": AyuBridgeAdapterSnapshot(className: self.orientation, state: value)]
        try self.apply("setOrientation", [reference], to: &state, objects: objects)
        XCTAssertEqual(state["orientation"], .string("BL_TR"))
        let constructed = try XCTUnwrap(adapter.constructor)([reference, .array([.integer(-1), .integer(-16777216)])], .memberTests(objects))
        XCTAssertEqual(constructed["orientation"], .string("BL_TR"))
        XCTAssertEqual(constructed["colors"], .array([.integer(-1), .integer(-16777216)]))
        XCTAssertThrowsError(try XCTUnwrap(adapter.constructor)([.integer(1)], .memberTests()))
        XCTAssertThrowsError(try XCTUnwrap(adapter.methods["setOrientation"])(&copy, [.string("BL_TR")], .memberTests()))
    }

    func testStyleGeometryFollowsAndroid() throws {
        // A plain color, radius and stroke need no extended layers.
        XCTAssertNil(AyuBridgeDrawableStyle(style: ["color": .integer(-1), "shape": .integer(0), "corner_radius": .number(8), "stroke_width": .number(1), "stroke_color": .integer(-1)]))
        var style = try XCTUnwrap(AyuBridgeDrawableStyle(style: ["color": .integer(0), "shape": .integer(0), "corner_radius": .number(0),
                                                                  "colors": .array([.integer(-65536), .integer(-16776961)])]))
        let points: [String: (CGPoint, CGPoint)] = [
            "TOP_BOTTOM": (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)), "TR_BL": (CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)),
            "RIGHT_LEFT": (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5)), "BR_TL": (CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0)),
            "BOTTOM_TOP": (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)), "BL_TR": (CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)),
            "LEFT_RIGHT": (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)), "TL_BR": (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)),
        ]
        XCTAssertEqual(style.orientation, "TOP_BOTTOM")
        for (name, expected) in points {
            style.orientation = name
            XCTAssertEqual(style.linearPoints.0, expected.0, name)
            XCTAssertEqual(style.linearPoints.1, expected.1, name)
        }
        XCTAssertEqual(style.gradientRadius, 0.5)
        XCTAssertEqual(style.center, CGPoint(x: 0.5, y: 0.5))

        // Per-corner radii: the rounded corners are cut, the square ones are not.
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        let path = AyuBridgeDrawableStyle.roundedPath(rect, radii: [20, 20, 0, 0, 10, 30, 0, 0])
        XCTAssertEqual(path.boundingBoxOfPath, rect)
        XCTAssertFalse(path.contains(CGPoint(x: 2, y: 2)))
        XCTAssertTrue(path.contains(CGPoint(x: 8, y: 8)))
        XCTAssertTrue(path.contains(CGPoint(x: 98, y: 2)))
        XCTAssertTrue(path.contains(CGPoint(x: 2, y: 58)))
        XCTAssertFalse(path.contains(CGPoint(x: 99, y: 59)))
        XCTAssertTrue(path.contains(CGPoint(x: 92, y: 35)))
        // Radii larger than the rectangle are scaled down together.
        let capsule = AyuBridgeDrawableStyle.roundedPath(rect, radii: Array(repeating: 100, count: 8))
        XCTAssertEqual(capsule.boundingBoxOfPath, rect)
        XCTAssertFalse(capsule.contains(CGPoint(x: 3, y: 3)))
        XCTAssertTrue(capsule.contains(CGPoint(x: 50, y: 1)))

        // The drawable alpha modulates every color as Android's modulateAlpha does.
        let translucent = try XCTUnwrap(AyuBridgeDrawableStyle(style: ["color": .integer(-1), "shape": .integer(1), "corner_radius": .number(0), "alpha": .integer(128)]))
        XCTAssertEqual(translucent.color.cgColor.alpha, CGFloat(255 * 129 >> 8) / 255, accuracy: 0.0001)
        XCTAssertTrue(translucent.oval)
        XCTAssertFalse(translucent.outline(in: rect).contains(CGPoint(x: 1, y: 1)))

        // A ripple is drawn at no more than half opacity, over its mask.
        let ripple = try XCTUnwrap(AyuBridgeDrawableStyle(style: ["color": .integer(0), "shape": .integer(0), "corner_radius": .number(0), "ripple_color": .integer(-16777216),
                                                                   "ripple_mask": .object(["kind": .string("circle"), "radius": .number(-1), "bounded": .bool(false)])]))
        XCTAssertEqual(ripple.ripple?.color.cgColor.alpha ?? 0, 128.0 / 255, accuracy: 0.0001)
        let halfDiagonal = (100.0 * 100 + 60 * 60).squareRoot() / 2
        XCTAssertEqual(try XCTUnwrap(ripple.highlight(in: rect)).boundingBoxOfPath.width, halfDiagonal * 2, accuracy: 0.001)
        var bounded = ripple
        bounded.ripple?.radius = -2
        XCTAssertEqual(try XCTUnwrap(bounded.highlight(in: rect)).boundingBoxOfPath.width, 100, accuracy: 0.001)
        bounded.ripple?.kind = "round_rect"
        bounded.ripple?.radius = 6
        XCTAssertFalse(try XCTUnwrap(bounded.highlight(in: rect)).contains(CGPoint(x: 1, y: 1)))
        bounded.ripple?.kind = "rect"
        XCTAssertTrue(try XCTUnwrap(bounded.highlight(in: rect)).contains(CGPoint(x: 1, y: 1)))
    }

    func testThemeFactoriesBuildAndroidShapes() throws {
        func ripple(_ result: AyuBridgeAdapterResult) throws -> [String: AyuBridgeValue] {
            guard case let .instance(name, state) = result else { XCTFail("no drawable"); return [:] }
            XCTAssertEqual(name, AyuBridgeDrawables.rippleName)
            XCTAssertNoThrow(try AyuBridgeDrawables.validateRipple(state))
            return state
        }
        // createSelectorDrawable(color): RIPPLE_MASK_CIRCLE_20DP, an unbounded circle of 20 dp.
        var state = try ripple(AyuBridgeDrawables.selector([.integer(0x1F00_0000)]))
        XCTAssertEqual(state["ripple_color"], .integer(0x1F00_0000))
        XCTAssertEqual(state["content"], .null)
        XCTAssertEqual(state["mask"], .object(["kind": .string("circle"), "radius": .number(20), "bounded": .bool(false)]))
        state = try ripple(AyuBridgeDrawables.selector([.integer(-1), .integer(1), .integer(32)]))
        XCTAssertEqual(state["mask"]?["radius"], .number(32))
        // RIPPLE_MASK_ALL fills the bounds; 7 is a rounded rectangle of 6 dp or the given radius.
        state = try ripple(AyuBridgeDrawables.selector([.integer(-1), .integer(2)]))
        XCTAssertEqual(state["mask"], .object(["kind": .string("rect")]))
        state = try ripple(AyuBridgeDrawables.selector([.integer(-1), .integer(7)]))
        XCTAssertEqual(state["mask"], .object(["kind": .string("round_rect"), "radius": .number(6)]))
        state = try ripple(AyuBridgeDrawables.selector([.integer(-1), .integer(7), .integer(10)]))
        XCTAssertEqual(state["mask"]?["radius"], .number(10))
        state = try ripple(AyuBridgeDrawables.selector([.integer(-1), .integer(3)]))
        XCTAssertEqual(state["mask"], .object(["kind": .string("circle"), "radius": .number(-2), "bounded": .bool(true)]))
        // A mask type Android has no branch for (and RIPPLE_MASK_CIRCLE_AUTO) is an unbounded ripple of the half diagonal.
        for type in [Int64(0), 5, 16, 18] {
            state = try ripple(AyuBridgeDrawables.selector([.integer(-1), .integer(type)]))
            XCTAssertEqual(state["mask"], .object(["kind": .string("circle"), "radius": .number(-1), "bounded": .bool(false)]), "\(type)")
        }
        XCTAssertThrowsError(try AyuBridgeDrawables.selector([]))
        XCTAssertThrowsError(try AyuBridgeDrawables.selector([.string("red")]))

        state = try ripple(AyuBridgeDrawables.simpleSelectorRoundRect([.integer(8), .integer(-16776961), .integer(0x2000_0000)]))
        XCTAssertEqual(state["ripple_color"], .integer(0x2000_0000))
        XCTAssertEqual(state["content"], .object(["color": .integer(-16776961), "shape": .integer(0), "corner_radius": .number(8)]))
        XCTAssertEqual(state["mask"], .object(["kind": .string("round_rect"), "radius": .number(8)]))
        state = try ripple(AyuBridgeDrawables.simpleSelectorRoundRect([.integer(1), .integer(2), .integer(3), .integer(4), .integer(-1), .integer(5), .integer(6)]))
        XCTAssertEqual(state["content"]?["corner_radii"], .array([1, 1, 2, 2, 3, 3, 4, 4].map { .number($0) }))
        XCTAssertThrowsError(try AyuBridgeDrawables.simpleSelectorRoundRect([.integer(8), .integer(1)]))

        guard case let .instance(name, shape) = try AyuBridgeDrawables.roundRect([.integer(12), .integer(-65536)]) else { return XCTFail("no shape") }
        XCTAssertEqual(name, AyuBridgeDrawables.shapeName)
        XCTAssertEqual(shape, ["color": .integer(-65536), "shape": .integer(0), "corner_radius": .number(12)])
        XCTAssertNoThrow(try XCTUnwrap(AyuBridgeClassRegistry.standard.adapters[name]).validateState(shape))
        XCTAssertThrowsError(try AyuBridgeDrawables.roundRect([.integer(12)]))

        // The style a view draws for a ripple: its content plus the pressed highlight.
        let style = try XCTUnwrap(AyuBridgeDrawables.backgroundStyle(className: AyuBridgeDrawables.rippleName, state: state))
        XCTAssertEqual(style["ripple_color"], .integer(5))
        XCTAssertEqual(style["color"], .integer(-1))
        XCTAssertNil(AyuBridgeDrawables.backgroundStyle(className: "android.graphics.drawable.ColorDrawable", state: [:]))
    }
}

@MainActor
final class AyuBridgeDrawableHostTests: XCTestCase {
    private let gradient = "android.graphics.drawable.GradientDrawable"

    func testGradientBackgroundIsDrawnByItsOwnLayersAndFollowsMutations() async throws {
        let session = try await AyuMemberTestHost()
        let view = try await session.construct("android.widget.FrameLayout")
        let native = try await session.mount(view, size: CGSize(width: 120, height: 80))
        let drawable = try await session.construct(self.gradient)
        _ = try await session.invoke(drawable, "setColor", [.integer(-65536)])
        _ = try await session.invoke(view, "setBackground", [drawable])
        try await session.flush(view)
        // A solid color with one radius stays on the plain path.
        XCTAssertNil(native.members.drawable)
        XCTAssertEqual(native.backgroundColor, UIColor(red: 1, green: 0, blue: 0, alpha: 1))

        let orientation = try await session.field("android.graphics.drawable.GradientDrawable$Orientation", "LEFT_RIGHT")
        let colors = try await session.array("int", [.integer(-65536), .integer(-16776961)])
        ayuExpect(try await session.invoke(drawable, "setColors", [colors]), drawable)
        ayuExpect(try await session.invoke(drawable, "setOrientation", [orientation]), drawable)
        ayuExpect(try await session.invoke(drawable, "setCornerRadii", [.array([10, 10, 10, 10, 0, 0, 0, 0].map { .number($0) })]), drawable)
        try await session.flush(view)
        let renderer = try XCTUnwrap(native.members.drawable)
        XCTAssertTrue(native.layer.sublayers?.first === renderer.container)
        XCTAssertEqual(renderer.container.frame, native.bounds)
        let fill = try XCTUnwrap(renderer.container.sublayers?.first as? CAGradientLayer)
        XCTAssertEqual(fill.colors?.count, 2)
        XCTAssertEqual(fill.type, .axial)
        XCTAssertEqual([fill.startPoint, fill.endPoint], [CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)])
        let outline = try XCTUnwrap((fill.mask as? CAShapeLayer)?.path)
        XCTAssertFalse(outline.contains(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(outline.contains(CGPoint(x: 1, y: 79)))
        // The plain path no longer paints under the layers.
        XCTAssertEqual(native.backgroundColor, .clear)
        // The view keeps returning the object that was set.
        ayuExpect(try await session.invoke(view, "getBackground"), drawable)

        _ = try await session.invoke(drawable, "setGradientType", [.integer(1)])
        _ = try await session.invoke(drawable, "setGradientRadius", [.number(60)])
        try await session.flush(view)
        XCTAssertEqual(fill.type, .radial)
        XCTAssertEqual(fill.endPoint.x, 0.5 + 60.0 / 120, accuracy: 0.0001)
        XCTAssertEqual(fill.endPoint.y, 0.5 + 60.0 / 80, accuracy: 0.0001)
        _ = try await session.invoke(drawable, "setGradientType", [.integer(2)])
        _ = try await session.invoke(drawable, "setStroke", [.integer(2), .integer(-1)])
        try await session.flush(view)
        XCTAssertEqual(fill.type, .conic)
        let stroke = try XCTUnwrap(renderer.container.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
        XCTAssertEqual(stroke.lineWidth, 2)
        XCTAssertFalse(stroke.isHidden)

        // The outline clips to the per-corner path.
        _ = try await session.invoke(view, "setClipToOutline", [.bool(true)])
        try await session.flush(view)
        let clip = try XCTUnwrap((native.layer.mask as? CAShapeLayer)?.path)
        XCTAssertFalse(clip.contains(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(clip.contains(CGPoint(x: 119, y: 79)))

        // A solid color, a plain color and null all leave the extended path.
        _ = try await session.invoke(drawable, "setColor", [.integer(-16711936)])
        _ = try await session.invoke(drawable, "setCornerRadius", [.number(4)])
        try await session.flush(view)
        XCTAssertNil(native.members.drawable)
        XCTAssertNil(renderer.container.superlayer)
        XCTAssertEqual(native.backgroundColor, UIColor(red: 0, green: 1, blue: 0, alpha: 1))
        _ = try await session.invoke(drawable, "setAlpha", [.integer(128)])
        try await session.flush(view)
        XCTAssertNotNil(native.members.drawable)
        _ = try await session.invoke(view, "setBackgroundColor", [.integer(-1)])
        try await session.flush(view)
        XCTAssertNil(native.members.drawable)
        _ = try await session.invoke(view, "setBackground", [drawable])
        _ = try await session.invoke(view, "setBackground", [.null])
        try await session.flush(view)
        XCTAssertNil(native.members.drawable)
        ayuExpect(try await session.invoke(view, "getBackground"), .null)
    }

    func testPressedHighlightOfARipple() throws {
        let style = try XCTUnwrap(AyuBridgeDrawableStyle(style: ["color": .integer(-1), "shape": .integer(0), "corner_radius": .number(6), "ripple_color": .integer(0x2000_0000),
                                                                  "ripple_mask": .object(["kind": .string("round_rect"), "radius": .number(6)])]))
        let renderer = AyuBridgeDrawableRenderer(style: style)
        renderer.layout(bounds: CGRect(x: 0, y: 0, width: 80, height: 40))
        let highlight = try XCTUnwrap(renderer.container.sublayers?.last as? CAShapeLayer)
        XCTAssertEqual(highlight.opacity, 0)
        XCTAssertEqual(highlight.fillColor?.alpha ?? 0, 32.0 / 255, accuracy: 0.0001)
        renderer.setPressed(true)
        XCTAssertTrue(renderer.isPressed)
        XCTAssertEqual(highlight.opacity, 1)
        renderer.setPressed(false)
        XCTAssertEqual(highlight.opacity, 0)
        // A style without a ripple has nothing to press.
        let plain = try XCTUnwrap(AyuBridgeDrawableStyle(style: ["color": .integer(-1), "shape": .integer(0), "corner_radius": .number(0), "alpha": .integer(10)]))
        renderer.update(style: plain, bounds: CGRect(x: 0, y: 0, width: 80, height: 40))
        renderer.setPressed(true)
        XCTAssertFalse(renderer.isPressed)

        // The recognizer that reports presses never takes part in gesture arbitration.
        let recognizer = AyuBridgePressRecognizer()
        XCTAssertFalse(recognizer.cancelsTouchesInView)
        XCTAssertFalse(recognizer.canPrevent(UITapGestureRecognizer()))
        XCTAssertFalse(recognizer.canBePrevented(by: UITapGestureRecognizer()))
    }
}
