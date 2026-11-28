import Foundation
import QuartzCore
import UIKit

/// Drawables a view background can be: `GradientDrawable` with gradients and per-corner radii,
/// and the `ShapeDrawable`/`RippleDrawable` values Telegram's `Theme` factories return.
/// The adapter state of the first two is the style object of a `setBackgroundStyle` UI command.
enum AyuBridgeDrawables {
    static let gradientName = "android.graphics.drawable.GradientDrawable"
    static let orientationName = "android.graphics.drawable.GradientDrawable$Orientation"
    static let shapeName = "android.graphics.drawable.ShapeDrawable"
    static let rippleName = "android.graphics.drawable.RippleDrawable"
    static let orientations = ["TOP_BOTTOM", "TR_BL", "RIGHT_LEFT", "BR_TL", "BOTTOM_TOP", "BL_TR", "LEFT_RIGHT", "TL_BR"]
    private static let baseKeys: Set<String> = ["color", "shape", "corner_radius", "stroke_width", "stroke_color"]
    private static let gradientKeys: Set<String> = ["colors", "gradient_type", "orientation", "corner_radii", "gradient_radius", "center_x", "center_y", "alpha"]

    static func isBackgroundClass(_ name: String) -> Bool { name == gradientName || name == shapeName || name == rippleName }

    /// The style a view draws for an owned drawable, or nil when its class is no background drawable.
    static func backgroundStyle(className: String, state: [String: AyuBridgeValue]) -> [String: AyuBridgeValue]? {
        switch className {
        case gradientName, shapeName: return state
        case rippleName:
            var style = state["content"]?.object ?? ["color": .integer(0), "shape": .integer(0), "corner_radius": .number(0)]
            style["ripple_color"] = state["ripple_color"]
            style["ripple_mask"] = state["mask"]
            return style
        default: return nil
        }
    }

    static func color(_ value: AyuBridgeValue, _ what: String) throws -> Int64 {
        guard let color = value.integer, (Int64(Int32.min)...Int64(UInt32.max)).contains(color) else {
            throw AyuBridgeFailure("invalid_arguments", "Expected \(what)")
        }
        return Int64(Int32(truncatingIfNeeded: color))
    }

    /// A Java `int[]`/`float[]` argument: a JSON list or an owned primitive array; nil for null.
    static func list(_ value: AyuBridgeValue, context: AyuBridgeAdapterContext) throws -> [AyuBridgeValue]? {
        if value == .null { return nil }
        if let values = value.array { return values }
        let snapshot = try context.snapshot(of: value)
        guard ["[I", "[F", "[D", "[J"].contains(snapshot.className), let values = snapshot.state["values"]?.array else {
            throw AyuBridgeFailure("invalid_arguments", "Expected a primitive array")
        }
        return values
    }

    private static func radius(_ value: AyuBridgeValue) throws -> Double {
        guard let radius = value.number, radius.isFinite, (0...100_000).contains(radius) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid corner radius")
        }
        return radius
    }

    static func cornerRadii(_ values: [AyuBridgeValue]) throws -> AyuBridgeValue {
        // Android reads eight values (x and y radius of four corners) and throws for fewer.
        guard values.count >= 8 else { throw AyuBridgeFailure("invalid_arguments", "Corner radii need 8 values") }
        return .array(try values.prefix(8).map { .number(try Self.radius($0)) })
    }

    static func validateShape(_ state: [String: AyuBridgeValue], allowed: Set<String>, className: String) throws {
        guard Set(state.keys).isSubset(of: allowed), let color = state["color"], let shape = state["shape"]?.integer, [0, 1].contains(shape),
              let radius = state["corner_radius"]?.number, radius.isFinite, (0...100_000).contains(radius) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid \(className) state")
        }
        _ = try Self.color(color, "ARGB color")
        if let radii = state["corner_radii"] {
            guard let values = radii.array, values.count == 8 else { throw AyuBridgeFailure("invalid_arguments", "Invalid \(className) state") }
            for value in values { _ = try Self.radius(value) }
        }
    }

    static func validateGradient(_ state: [String: AyuBridgeValue]) throws {
        try Self.validateShape(state, allowed: Self.baseKeys.union(Self.gradientKeys), className: Self.gradientName)
        guard let width = state["stroke_width"]?.number, width.isFinite, (0...100_000).contains(width), let stroke = state["stroke_color"] else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid GradientDrawable state")
        }
        _ = try Self.color(stroke, "stroke ARGB color")
        if let colors = state["colors"] {
            guard let values = colors.array, (2...16).contains(values.count) else { throw AyuBridgeFailure("invalid_arguments", "Invalid GradientDrawable colors") }
            for value in values { _ = try Self.color(value, "gradient ARGB color") }
        }
        if let type = state["gradient_type"] { guard let value = type.integer, (0...2).contains(value) else { throw AyuBridgeFailure("invalid_arguments", "Invalid gradient type") } }
        if let orientation = state["orientation"] { guard let value = orientation.string, Self.orientations.contains(value) else { throw AyuBridgeFailure("invalid_arguments", "Invalid gradient orientation") } }
        if let radius = state["gradient_radius"] { guard let value = radius.number, value.isFinite, (0...100_000).contains(value) else { throw AyuBridgeFailure("invalid_arguments", "Invalid gradient radius") } }
        for key in ["center_x", "center_y"] {
            if let center = state[key] { guard let value = center.number, value.isFinite, abs(value) <= 100 else { throw AyuBridgeFailure("invalid_arguments", "Invalid gradient center") } }
        }
        if let alpha = state["alpha"] { guard let value = alpha.integer, (0...255).contains(value) else { throw AyuBridgeFailure("invalid_arguments", "Invalid drawable alpha") } }
    }

    static func validateRipple(_ state: [String: AyuBridgeValue]) throws {
        guard Set(state.keys) == ["ripple_color", "content", "mask"], let color = state["ripple_color"], let mask = state["mask"]?.object,
              let kind = mask["kind"]?.string, ["rect", "round_rect", "circle"].contains(kind),
              Set(mask.keys).isSubset(of: ["kind", "radius", "radii", "bounded"]) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid RippleDrawable state")
        }
        _ = try Self.color(color, "ripple ARGB color")
        if let radius = mask["radius"] { guard let value = radius.number, value.isFinite, (-2...100_000).contains(value) else { throw AyuBridgeFailure("invalid_arguments", "Invalid RippleDrawable state") } }
        if let radii = mask["radii"] { guard let values = radii.array, values.count == 8 else { throw AyuBridgeFailure("invalid_arguments", "Invalid RippleDrawable state") }; for value in values { _ = try Self.radius(value) } }
        if let bounded = mask["bounded"] { guard bounded.bool != nil else { throw AyuBridgeFailure("invalid_arguments", "Invalid RippleDrawable state") } }
        if let content = state["content"], content != .null {
            guard let shape = content.object else { throw AyuBridgeFailure("invalid_arguments", "Invalid RippleDrawable state") }
            try Self.validateShape(shape, allowed: ["color", "shape", "corner_radius", "corner_radii", "stroke_width", "stroke_color"], className: Self.rippleName)
        }
    }

    private static func rippleLayer(_ value: AyuBridgeValue, context: AyuBridgeAdapterContext) throws -> [String: AyuBridgeValue]? {
        if value == .null { return nil }
        let snapshot = try context.snapshot(of: value)
        let state = snapshot.state
        switch snapshot.className {
        case "android.graphics.drawable.ColorDrawable":
            guard let color = state["color"]?.integer else { throw AyuBridgeFailure.unsupported("RippleDrawable layer") }
            return Self.shape(color: color, radius: 0)
        case gradientName, shapeName:
            // Only what the pressed-highlight renderer draws under a ripple: a solid shape, optionally stroked.
            guard state["colors"] == nil, (state["alpha"]?.integer ?? 255) == 255, let color = state["color"], let shape = state["shape"] else {
                throw AyuBridgeFailure.unsupported("RippleDrawable layer with a gradient or alpha")
            }
            var layer: [String: AyuBridgeValue] = ["color": color, "shape": shape, "corner_radius": state["corner_radius"] ?? .number(0)]
            if let radii = state["corner_radii"] { layer["corner_radii"] = radii }
            if let width = state["stroke_width"]?.number, width > 0 {
                layer["stroke_width"] = .number(width)
                layer["stroke_color"] = state["stroke_color"] ?? .integer(0)
            }
            return layer
        default:
            throw AyuBridgeFailure.unsupported("RippleDrawable layer " + snapshot.className)
        }
    }

    /// `RippleDrawable(ColorStateList color, Drawable content, Drawable mask)`. Without a mask Android clips
    /// the ripple to the content, and without either it is an unbounded circle.
    static func rippleState(_ args: [AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> [String: AyuBridgeValue] {
        guard args.count == 3 else { throw AyuBridgeFailure("invalid_arguments", "RippleDrawable takes a ColorStateList, a content and a mask") }
        guard args[0] != .null else { throw AyuBridgeFailure("invalid_arguments", "RippleDrawable color must not be null") }
        let colors = try context.snapshot(of: args[0])
        guard colors.className == "android.content.res.ColorStateList", let color = colors.state["color"]?.integer else {
            throw AyuBridgeFailure.unsupported("RippleDrawable ColorStateList")
        }
        let content = try Self.rippleLayer(args[1], context: context)
        var mask: [String: AyuBridgeValue] = ["kind": .string("circle"), "radius": .number(-1), "bounded": .bool(false)]
        if let outline = try Self.rippleLayer(args[2], context: context) ?? content {
            guard outline["shape"]?.integer == 0 else { throw AyuBridgeFailure.unsupported("RippleDrawable oval mask") }
            if let radii = outline["corner_radii"] {
                mask = ["kind": .string("round_rect"), "radii": radii]
            } else if let radius = outline["corner_radius"]?.number, radius > 0 {
                mask = ["kind": .string("round_rect"), "radius": .number(radius)]
            } else {
                mask = ["kind": .string("rect")]
            }
        }
        return ["ripple_color": .integer(color), "content": content.map(AyuBridgeValue.object) ?? .null, "mask": .object(mask)]
    }

    // MARK: Telegram `Theme` drawable factories

    private static func dimension(_ value: AyuBridgeValue, _ what: String) throws -> Double {
        guard let number = value.number, number.isFinite, (-100_000...100_000).contains(number) else {
            throw AyuBridgeFailure("invalid_arguments", "Expected \(what)")
        }
        return number
    }

    private static func shape(color: Int64, radius: Double) -> [String: AyuBridgeValue] {
        ["color": .integer(color), "shape": .integer(0), "corner_radius": .number(max(0, radius))]
    }

    private static func ripple(color: Int64, content: [String: AyuBridgeValue]?, mask: [String: AyuBridgeValue]) -> AyuBridgeAdapterResult {
        .instance(className: Self.rippleName, state: ["ripple_color": .integer(color), "content": content.map(AyuBridgeValue.object) ?? .null, "mask": .object(mask)])
    }

    /// `Theme.createSelectorDrawable(color[, maskType[, radius]])`: a ripple without content.
    /// Mask types follow `Theme.RIPPLE_MASK_*`; a type Android has no branch for is an unbounded ripple.
    static func selector(_ args: [AyuBridgeValue]) throws -> AyuBridgeAdapterResult {
        guard (1...3).contains(args.count) else { throw AyuBridgeFailure("invalid_arguments", "createSelectorDrawable takes a color, a mask type and a radius") }
        let color = try Self.color(args[0], "ripple ARGB color")
        var maskType: Int64 = 1
        if args.count >= 2 {
            guard let value = args[1].integer else { throw AyuBridgeFailure("invalid_arguments", "Expected a ripple mask type") }
            maskType = value
        }
        let radius = args.count == 3 ? try Self.dimension(args[2], "ripple radius") : -1
        let mask: [String: AyuBridgeValue]
        switch maskType {
        case 1: mask = ["kind": .string("circle"), "radius": .number(radius <= 0 ? 20 : radius), "bounded": .bool(false)]
        case 2, 4: mask = ["kind": .string("rect")]
        case 3: mask = ["kind": .string("circle"), "radius": .number(-2), "bounded": .bool(true)]
        case 6: mask = ["kind": .string("circle"), "radius": .number(radius <= 0 ? 20 : radius), "bounded": .bool(true)]
        case 7: mask = ["kind": .string("round_rect"), "radius": .number(radius <= 0 ? 6 : radius)]
        default: mask = ["kind": .string("circle"), "radius": .number(-1), "bounded": .bool(false)]
        }
        return Self.ripple(color: color, content: nil, mask: mask)
    }

    /// `Theme.createSimpleSelectorRoundRectDrawable(rad, defaultColor, pressedColor[, maskColor])` and the
    /// four-corner form `(leftTop, rightTop, rightBottom, leftBottom, defaultColor, pressedColor, maskColor)`.
    static func simpleSelectorRoundRect(_ args: [AyuBridgeValue]) throws -> AyuBridgeAdapterResult {
        if args.count == 7 {
            let corners = try args.prefix(4).map { max(0, try Self.dimension($0, "corner radius")) }
            let radii: AyuBridgeValue = .array(corners.flatMap { [AyuBridgeValue.number($0), .number($0)] })
            var content = Self.shape(color: try Self.color(args[4], "ARGB color"), radius: 0)
            content["corner_radii"] = radii
            _ = try Self.color(args[6], "mask ARGB color")
            return Self.ripple(color: try Self.color(args[5], "pressed ARGB color"), content: content, mask: ["kind": .string("round_rect"), "radii": radii])
        }
        guard args.count == 3 || args.count == 4 else {
            throw AyuBridgeFailure("invalid_arguments", "createSimpleSelectorRoundRectDrawable takes a radius and two or three colors")
        }
        let radius = max(0, try Self.dimension(args[0], "corner radius"))
        if args.count == 4 { _ = try Self.color(args[3], "mask ARGB color") }
        return Self.ripple(color: try Self.color(args[2], "pressed ARGB color"),
                           content: Self.shape(color: try Self.color(args[1], "ARGB color"), radius: radius),
                           mask: ["kind": .string("round_rect"), "radius": .number(radius)])
    }

    /// `Theme.createRoundRectDrawable(rad, defaultColor)`.
    static func roundRect(_ args: [AyuBridgeValue]) throws -> AyuBridgeAdapterResult {
        guard args.count == 2 else { throw AyuBridgeFailure("invalid_arguments", "createRoundRectDrawable takes a radius and a color") }
        return .instance(className: Self.shapeName, state: Self.shape(color: try Self.color(args[1], "ARGB color"), radius: try Self.dimension(args[0], "corner radius")))
    }

    /// `Theme.getSelectorDrawable(color, whiteBackground)`: over an opaque row background or bare.
    static func listSelector(color: Int64, background: Int64?) -> AyuBridgeAdapterResult {
        Self.ripple(color: color, content: background.map { Self.shape(color: $0, radius: 0) }, mask: ["kind": .string("rect")])
    }
}

extension AyuBridgeJavaRuntime {
    /// Adapters of classes this file family adds to the standard registry.
    static var memberAdapters: [AyuBridgeClassAdapter] { [gradientOrientation, shapeDrawable, rippleDrawable] }

    private static func gradientUpdate(_ count: Int, _ body: @escaping @Sendable (inout [String: AyuBridgeValue], [AyuBridgeValue], AyuBridgeAdapterContext) throws -> Void) -> AyuBridgeClassAdapter.InstanceMethod {
        { state, args, context in
            guard args.count == count else { throw AyuBridgeFailure("invalid_arguments", "Wrong argument count") }
            var updated = state
            try body(&updated, args, context)
            state = updated
            return .instance(className: AyuBridgeDrawables.gradientName, state: updated)
        }
    }

    private static func gradientNumber(_ value: AyuBridgeValue, _ range: ClosedRange<Double>, _ what: String) throws -> Double {
        guard let number = value.number, number.isFinite, range.contains(number) else { throw AyuBridgeFailure("invalid_arguments", "Invalid \(what)") }
        return number
    }

    private static func gradientColors(_ value: AyuBridgeValue, context: AyuBridgeAdapterContext) throws -> AyuBridgeValue? {
        guard let values = try AyuBridgeDrawables.list(value, context: context) else { return nil }
        // Android builds its shader from at least two colors and fails to draw with fewer.
        guard (2...16).contains(values.count) else { throw AyuBridgeFailure("invalid_arguments", "A gradient needs 2 to 16 colors") }
        return .array(try values.map { .integer(try AyuBridgeDrawables.color($0, "gradient ARGB color")) })
    }

    private static func gradientOrientationName(_ value: AyuBridgeValue, context: AyuBridgeAdapterContext) throws -> String {
        let snapshot = try context.snapshot(of: value)
        guard snapshot.className == AyuBridgeDrawables.orientationName, let name = snapshot.state["value"]?.string,
              AyuBridgeDrawables.orientations.contains(name) else { throw AyuBridgeFailure.unsupported("GradientDrawable.Orientation value") }
        return name
    }

    static var gradientDrawable: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.graphics.drawable.GradientDrawable",
            constants: ["RECTANGLE": .integer(0), "OVAL": .integer(1)],
            constructor: { args, context in
                var state: [String: AyuBridgeValue] = ["color": .integer(0), "shape": .integer(0), "corner_radius": .number(0), "stroke_width": .number(0), "stroke_color": .integer(0)]
                if args.isEmpty { return state }
                guard args.count == 2 else { throw AyuBridgeFailure.unsupported("GradientDrawable constructor overload") }
                state["orientation"] = .string(try Self.gradientOrientationName(args[0], context: context))
                if let colors = try Self.gradientColors(args[1], context: context) { state["colors"] = colors }
                return state
            },
            methods: [
                "setColor": Self.gradientUpdate(1) { state, args, _ in
                    // A solid color replaces the gradient colors, and the reverse.
                    state["color"] = .integer(try AyuBridgeDrawables.color(args[0], "ARGB color")); state["colors"] = nil
                },
                "setColors": Self.gradientUpdate(1) { state, args, context in
                    state["colors"] = try Self.gradientColors(args[0], context: context)
                    state["color"] = .integer(0)
                },
                "setCornerRadius": Self.gradientUpdate(1) { state, args, _ in
                    state["corner_radius"] = .number(try Self.gradientNumber(args[0], 0...100_000, "corner radius")); state["corner_radii"] = nil
                },
                "setCornerRadii": Self.gradientUpdate(1) { state, args, context in
                    state["corner_radii"] = try AyuBridgeDrawables.list(args[0], context: context).map(AyuBridgeDrawables.cornerRadii)
                    if state["corner_radii"] == nil { state["corner_radius"] = .number(0) }
                },
                "setShape": Self.gradientUpdate(1) { state, args, _ in
                    guard let shape = args[0].integer, [0, 1].contains(shape) else { throw AyuBridgeFailure.unsupported("GradientDrawable.setShape") }
                    state["shape"] = .integer(shape)
                },
                "setStroke": Self.gradientUpdate(2) { state, args, _ in
                    state["stroke_width"] = .number(try Self.gradientNumber(args[0], 0...100_000, "stroke width"))
                    state["stroke_color"] = .integer(try AyuBridgeDrawables.color(args[1], "stroke ARGB color"))
                },
                "setGradientType": Self.gradientUpdate(1) { state, args, _ in
                    guard let type = args[0].integer, (0...2).contains(type) else { throw AyuBridgeFailure("invalid_arguments", "Invalid gradient type") }
                    state["gradient_type"] = .integer(type)
                },
                "setOrientation": Self.gradientUpdate(1) { state, args, context in
                    state["orientation"] = .string(try Self.gradientOrientationName(args[0], context: context))
                },
                "setGradientRadius": Self.gradientUpdate(1) { state, args, _ in
                    state["gradient_radius"] = .number(try Self.gradientNumber(args[0], 0...100_000, "gradient radius"))
                },
                "setGradientCenter": Self.gradientUpdate(2) { state, args, _ in
                    state["center_x"] = .number(try Self.gradientNumber(args[0], -100...100, "gradient center"))
                    state["center_y"] = .number(try Self.gradientNumber(args[1], -100...100, "gradient center"))
                },
                "setAlpha": Self.gradientUpdate(1) { state, args, _ in
                    guard let alpha = args[0].integer, (0...255).contains(alpha) else { throw AyuBridgeFailure("invalid_arguments", "Drawable alpha must be in 0...255") }
                    state["alpha"] = alpha == 255 ? nil : .integer(alpha)
                },
            ], receiverMethods: ["setColor", "setColors", "setCornerRadius", "setCornerRadii", "setShape", "setStroke", "setGradientType", "setOrientation", "setGradientRadius", "setGradientCenter", "setAlpha"],
               validateState: { try AyuBridgeDrawables.validateGradient($0) })
    }

    static var gradientOrientation: AyuBridgeClassAdapter {
        let name = "android.graphics.drawable.GradientDrawable$Orientation"
        let values = AyuBridgeDrawables.orientations
        return AyuBridgeClassAdapter(name: "android.graphics.drawable.GradientDrawable$Orientation",
            staticFields: [
                "TOP_BOTTOM": { _ in .instance(className: name, state: ["value": .string("TOP_BOTTOM")]) },
                "TR_BL": { _ in .instance(className: name, state: ["value": .string("TR_BL")]) },
                "RIGHT_LEFT": { _ in .instance(className: name, state: ["value": .string("RIGHT_LEFT")]) },
                "BR_TL": { _ in .instance(className: name, state: ["value": .string("BR_TL")]) },
                "BOTTOM_TOP": { _ in .instance(className: name, state: ["value": .string("BOTTOM_TOP")]) },
                "BL_TR": { _ in .instance(className: name, state: ["value": .string("BL_TR")]) },
                "LEFT_RIGHT": { _ in .instance(className: name, state: ["value": .string("LEFT_RIGHT")]) },
                "TL_BR": { _ in .instance(className: name, state: ["value": .string("TL_BR")]) },
            ],
            methods: [
                "name": { state, args, _ in
                    guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Enum.name takes no arguments") }
                    return .value(state["value"] ?? .null)
                },
                "ordinal": { state, args, _ in
                    guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Enum.ordinal takes no arguments") }
                    return .value(.integer(Int64(values.firstIndex(of: state["value"]?.string ?? "") ?? 0)))
                },
            ],
            results: [
                "TOP_BOTTOM": "android.graphics.drawable.GradientDrawable$Orientation", "TR_BL": "android.graphics.drawable.GradientDrawable$Orientation",
                "RIGHT_LEFT": "android.graphics.drawable.GradientDrawable$Orientation", "BR_TL": "android.graphics.drawable.GradientDrawable$Orientation",
                "BOTTOM_TOP": "android.graphics.drawable.GradientDrawable$Orientation", "BL_TR": "android.graphics.drawable.GradientDrawable$Orientation",
                "LEFT_RIGHT": "android.graphics.drawable.GradientDrawable$Orientation", "TL_BR": "android.graphics.drawable.GradientDrawable$Orientation",
            ],
            validateState: { state in
                guard state.count == 1, let value = state["value"]?.string, values.contains(value) else {
                    throw AyuBridgeFailure("invalid_arguments", "Invalid GradientDrawable.Orientation state")
                }
            })
    }

    /// Values only: created by Telegram's `Theme` factories and accepted as a view background.
    static var shapeDrawable: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.graphics.drawable.ShapeDrawable", validateState: { state in
            try AyuBridgeDrawables.validateShape(state, allowed: ["color", "shape", "corner_radius", "corner_radii"], className: AyuBridgeDrawables.shapeName)
        })
    }

    static var rippleDrawable: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.graphics.drawable.RippleDrawable",
            constructor: { try AyuBridgeDrawables.rippleState($0, context: $1) },
            validateState: { try AyuBridgeDrawables.validateRipple($0) })
    }
}

/// The part of a background style the plain color/radius/stroke path of `AyuBridgeView` cannot
/// draw: gradients, per-corner radii, drawable alpha and the pressed highlight of a ripple.
struct AyuBridgeDrawableStyle: Equatable {
    struct Ripple: Equatable {
        var color: UIColor
        var kind: String
        var radius: CGFloat
        var radii: [CGFloat]?
        var bounded: Bool
    }

    var color: UIColor
    var colors: [UIColor]?
    var gradientType: Int
    var orientation: String
    var gradientRadius: CGFloat
    var center: CGPoint
    var oval: Bool
    var cornerRadius: CGFloat
    var cornerRadii: [CGFloat]?
    var strokeWidth: CGFloat
    var strokeColor: UIColor
    var ripple: Ripple?

    private static func color(_ raw: Int64, alpha: Int64 = 255) -> UIColor {
        let bits = UInt32(truncatingIfNeeded: raw)
        // Android's `modulateAlpha` of the paint alpha by the drawable alpha.
        let scale = alpha + (alpha >> 7)
        let modulated = Int64(bits >> 24) * scale >> 8
        return UIColor(red: CGFloat((bits >> 16) & 255) / 255, green: CGFloat((bits >> 8) & 255) / 255,
                       blue: CGFloat(bits & 255) / 255, alpha: CGFloat(modulated) / 255)
    }

    /// Nil when the plain path draws the style completely.
    init?(style: [String: AyuBridgeValue]) {
        let alpha = style["alpha"]?.integer ?? 255
        let colors = style["colors"]?.array?.compactMap(\.integer)
        let radii = style["corner_radii"]?.array?.compactMap(\.number).map { CGFloat($0) }
        guard colors != nil || radii != nil || alpha != 255 || style["ripple_color"] != nil else { return nil }
        self.color = Self.color(style["color"]?.integer ?? 0, alpha: alpha)
        self.colors = colors.map { $0.map { Self.color($0, alpha: alpha) } }
        self.gradientType = Int(style["gradient_type"]?.integer ?? 0)
        self.orientation = style["orientation"]?.string ?? "TOP_BOTTOM"
        // Android's default radius of a radial gradient is half a pixel.
        self.gradientRadius = CGFloat(style["gradient_radius"]?.number ?? 0.5)
        self.center = CGPoint(x: style["center_x"]?.number ?? 0.5, y: style["center_y"]?.number ?? 0.5)
        self.oval = style["shape"]?.integer == 1
        self.cornerRadius = CGFloat(style["corner_radius"]?.number ?? 0)
        self.cornerRadii = radii?.count == 8 ? radii : nil
        self.strokeWidth = CGFloat(style["stroke_width"]?.number ?? 0)
        self.strokeColor = Self.color(style["stroke_color"]?.integer ?? 0, alpha: alpha)
        if let rippleColor = style["ripple_color"]?.integer, let mask = style["ripple_mask"]?.object {
            // Android draws a ripple at no more than half opacity.
            let bits = UInt32(truncatingIfNeeded: rippleColor)
            let capped = bits >> 24 > 128 ? (bits & 0x00FF_FFFF) | 0x8000_0000 : bits
            self.ripple = Ripple(color: Self.color(Int64(capped)), kind: mask["kind"]?.string ?? "rect",
                                 radius: CGFloat(mask["radius"]?.number ?? 0),
                                 radii: mask["radii"]?.array?.compactMap(\.number).map { CGFloat($0) },
                                 bounded: mask["bounded"]?.bool ?? true)
        }
    }

    /// A rectangle with one elliptical radius per corner, as `Path.addRoundRect(rect, radii, CW)`.
    static func roundedPath(_ rect: CGRect, radii: [CGFloat]) -> CGPath {
        var values = radii.count == 8 ? radii.map { max(0, $0) } : Array(repeating: 0, count: 8)
        // Radii that overlap on a side are scaled down together.
        let horizontal = max(values[0] + values[2], values[6] + values[4]), vertical = max(values[1] + values[7], values[3] + values[5])
        let scale = min(1, horizontal > 0 ? rect.width / horizontal : 1, vertical > 0 ? rect.height / vertical : 1)
        values = values.map { $0 * scale }
        let kappa: CGFloat = 0.552_284_749_8
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + values[0], y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - values[2], y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + values[3]),
                      control1: CGPoint(x: rect.maxX - values[2] * (1 - kappa), y: rect.minY),
                      control2: CGPoint(x: rect.maxX, y: rect.minY + values[3] * (1 - kappa)))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - values[5]))
        path.addCurve(to: CGPoint(x: rect.maxX - values[4], y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: rect.maxY - values[5] * (1 - kappa)),
                      control2: CGPoint(x: rect.maxX - values[4] * (1 - kappa), y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + values[6], y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - values[7]),
                      control1: CGPoint(x: rect.minX + values[6] * (1 - kappa), y: rect.maxY),
                      control2: CGPoint(x: rect.minX, y: rect.maxY - values[7] * (1 - kappa)))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + values[1]))
        path.addCurve(to: CGPoint(x: rect.minX + values[0], y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.minY + values[1] * (1 - kappa)),
                      control2: CGPoint(x: rect.minX + values[0] * (1 - kappa), y: rect.minY))
        path.closeSubpath()
        return path
    }

    /// The outline of the drawable in `rect`, which is also what `setClipToOutline` clips to.
    func outline(in rect: CGRect) -> CGPath {
        if self.oval { return CGPath(ellipseIn: rect, transform: nil) }
        if let radii = self.cornerRadii { return Self.roundedPath(rect, radii: radii) }
        let radius = min(max(0, self.cornerRadius), min(rect.width, rect.height) / 2)
        return UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
    }

    /// Where the pressed highlight is drawn, in the view's coordinates.
    func highlight(in bounds: CGRect) -> CGPath? {
        guard let ripple = self.ripple else { return nil }
        switch ripple.kind {
        case "round_rect":
            if let radii = ripple.radii { return Self.roundedPath(bounds, radii: radii) }
            let radius = min(max(0, ripple.radius), min(bounds.width, bounds.height) / 2)
            return UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
        case "circle":
            let radius: CGFloat
            if ripple.radius == -1 { radius = (bounds.width * bounds.width + bounds.height * bounds.height).squareRoot() / 2 }
            else if ripple.radius == -2 { radius = max(bounds.width, bounds.height) / 2 }
            else { radius = ripple.radius }
            let circle = CGRect(x: bounds.midX - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2)
            // A bounded mask is clipped to the drawable bounds by the layer that draws it.
            return CGPath(ellipseIn: circle, transform: nil)
        default:
            return CGPath(rect: bounds, transform: nil)
        }
    }

    /// Start and end of a linear gradient in unit coordinates, as `GradientDrawable.ensureValidRect` places them.
    var linearPoints: (CGPoint, CGPoint) {
        switch self.orientation {
        case "TR_BL": return (CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1))
        case "RIGHT_LEFT": return (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
        case "BR_TL": return (CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 0))
        case "BOTTOM_TOP": return (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
        case "BL_TR": return (CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0))
        case "LEFT_RIGHT": return (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
        case "TL_BR": return (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1))
        default: return (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
        }
    }
}

/// Layers of one view's extended background. Main-only; the view lays it out with its bounds.
@MainActor final class AyuBridgeDrawableRenderer {
    private(set) var style: AyuBridgeDrawableStyle
    let container = CALayer()
    private let fill = CAGradientLayer()
    private let fillMask = CAShapeLayer()
    private let stroke = CAShapeLayer()
    private let highlight = CAShapeLayer()
    private(set) var isPressed = false

    init(style: AyuBridgeDrawableStyle) {
        self.style = style
        self.fill.mask = self.fillMask
        self.stroke.fillColor = nil
        self.highlight.opacity = 0
        for layer in [self.fill, self.stroke, self.highlight] as [CALayer] { self.container.addSublayer(layer) }
    }

    func update(style: AyuBridgeDrawableStyle, bounds: CGRect) {
        self.style = style
        self.layout(bounds: bounds)
    }

    func layout(bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.container.frame = bounds
        let rect = CGRect(origin: .zero, size: bounds.size)
        let style = self.style
        self.fill.frame = rect
        self.fillMask.frame = rect
        self.fillMask.path = style.outline(in: rect)
        if let colors = style.colors {
            self.fill.backgroundColor = nil
            self.fill.colors = colors.map(\.cgColor)
            switch style.gradientType {
            case 1:
                self.fill.type = .radial
                self.fill.startPoint = style.center
                let radius = max(style.gradientRadius, 0.001)
                self.fill.endPoint = CGPoint(x: style.center.x + (rect.width > 0 ? radius / rect.width : 0),
                                             y: style.center.y + (rect.height > 0 ? radius / rect.height : 0))
            case 2:
                // A sweep starts at three o'clock.
                self.fill.type = .conic
                self.fill.startPoint = style.center
                self.fill.endPoint = CGPoint(x: style.center.x + 0.5, y: style.center.y)
            default:
                self.fill.type = .axial
                (self.fill.startPoint, self.fill.endPoint) = style.linearPoints
            }
        } else {
            self.fill.colors = nil
            self.fill.backgroundColor = style.color.cgColor
        }
        self.stroke.frame = rect
        if style.strokeWidth > 0 {
            // Android strokes along the outline inset by half the stroke width.
            let inset = min(style.strokeWidth / 2, min(rect.width, rect.height) / 2)
            self.stroke.path = style.outline(in: rect.insetBy(dx: inset, dy: inset))
            self.stroke.strokeColor = style.strokeColor.cgColor
            self.stroke.lineWidth = style.strokeWidth
            self.stroke.isHidden = false
        } else {
            self.stroke.isHidden = true
        }
        self.highlight.frame = rect
        self.highlight.path = style.highlight(in: rect)
        self.highlight.fillColor = style.ripple?.color.cgColor
        self.highlight.masksToBounds = style.ripple?.bounded ?? true
        if style.ripple == nil { self.highlight.opacity = 0; self.isPressed = false }
        CATransaction.commit()
    }

    /// The pressed state of a ripple: its color over the mask, faded in and out natively.
    func setPressed(_ pressed: Bool) {
        guard self.style.ripple != nil, pressed != self.isPressed else { return }
        self.isPressed = pressed
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = self.highlight.presentation()?.opacity ?? self.highlight.opacity
        animation.toValue = pressed ? 1 : 0
        animation.duration = pressed ? 0.1 : 0.25
        self.highlight.opacity = pressed ? 1 : 0
        self.highlight.add(animation, forKey: "pressed")
    }
}
