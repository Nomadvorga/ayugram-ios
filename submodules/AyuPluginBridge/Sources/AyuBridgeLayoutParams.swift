import UIKit

/// `ui.layout_params` and the per-child placement rules of `FrameLayout`/`LinearLayout` layout
/// parameters. Stored sizes and margins are native points: Android dp at the density
/// `AndroidUtilities.dp` uses, rounded up as it rounds.
enum AyuBridgeLayoutParams {
    /// Read on main, and only for `relative` or `margins_in_pixels`.
    struct Environment: Sendable {
        let isRightToLeft: Bool
        let screenScale: Double
    }

    struct Request: Equatable {
        let className: String
        let fields: [String: AyuBridgeValue]
    }

    typealias Margins = (left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat)

    static let frameClassName = "android.widget.FrameLayout$LayoutParams"
    static let linearClassName = "android.widget.LinearLayout$LayoutParams"
    /// `ViewGroup.MarginLayoutParams` fields, in the order of the stored `margins` array.
    static let marginFields = ["leftMargin", "topMargin", "rightMargin", "bottomMargin"]
    private static let argumentKeys: Set<String> = ["kind", "width", "height", "weight", "gravity", "margins", "relative", "margins_in_pixels"]
    private static let limit = 100_000.0
    private static let relativeFlag: Int64 = 0x0080_0000
    private static let placementFlags: Int64 = 0x0080_0077
    private static let clipFlags: Int64 = 0x1100_0088

    static func request(_ arguments: [String: AyuBridgeValue], environment: () -> Environment) throws -> Request {
        guard Set(arguments.keys).isSubset(of: self.argumentKeys) else { throw self.invalid("Unknown layout parameter argument") }
        let className: String
        switch arguments["kind"]?.string {
        case "frame": className = self.frameClassName
        case "linear": className = self.linearClassName
        default: throw self.invalid("Layout kind must be frame or linear")
        }
        var fields: [String: AyuBridgeValue] = [
            "width": .number(try self.size(arguments["width"])), "height": .number(try self.size(arguments["height"])),
        ]
        if className == self.linearClassName {
            fields["weight"] = .number(try arguments["weight"].map(self.weight) ?? 0)
        } else if arguments["weight"] != nil {
            throw self.invalid("Frame layout parameters have no weight")
        }
        let relative = try self.flag(arguments["relative"])
        let pixels = try self.flag(arguments["margins_in_pixels"])
        let environment = relative || pixels ? environment() : Environment(isRightToLeft: false, screenScale: 1)
        if let value = arguments["gravity"], let gravity = try self.gravity(value) {
            // `createFrameRelatively` stores the absolute gravity; other factories keep the flags they were given.
            fields["gravity"] = .integer(relative ? self.absoluteGravity(gravity, rightToLeft: environment.isRightToLeft) : gravity)
        }
        if let value = arguments["margins"] {
            guard let values = value.array, values.count == 4 else { throw self.invalid("Four margins are required") }
            var margins = try values.map(self.margin)
            if pixels {
                guard environment.screenScale.isFinite, environment.screenScale > 0 else {
                    throw AyuBridgeFailure("screen_unavailable", "Screen scale is unavailable")
                }
                margins = margins.map { $0 / environment.screenScale }
            } else {
                margins = margins.map { $0.rounded(.up) }
            }
            if relative && environment.isRightToLeft { margins.swapAt(0, 2) }
            fields["margins"] = .array(margins.map(AyuBridgeValue.number))
        }
        return Request(className: className, fields: fields)
    }

    /// A child's Android `Gravity` flags, or nil for `-1`, the value Android reads as unspecified.
    static func gravity(_ value: AyuBridgeValue) throws -> Int64? {
        guard let raw = value.integer else { throw self.invalid("Gravity must be an integer") }
        if raw == -1 { return nil }
        guard raw >= 0, raw & ~(self.placementFlags | self.clipFlags) == 0 else { throw self.invalid("Unknown gravity flags") }
        guard raw & self.clipFlags == 0 else { throw AyuBridgeFailure.unsupported("Gravity clip flags") }
        guard [0, 1, 3, 5, 7].contains(raw & 0x07), [0, 0x10, 0x30, 0x50, 0x70].contains(raw & 0x70) else {
            throw self.invalid("Invalid gravity axis flags")
        }
        return raw
    }

    static func margin(_ value: AyuBridgeValue) throws -> Double {
        guard let number = value.number, number.isFinite, abs(number) <= self.limit else { throw self.invalid("Invalid layout margin") }
        return number
    }

    static func weight(_ value: AyuBridgeValue) throws -> Double {
        guard let weight = value.number, weight.isFinite, (0...self.limit).contains(weight) else { throw self.invalid("Invalid LinearLayout weight") }
        return weight
    }

    /// `Gravity.getAbsoluteGravity`.
    static func absoluteGravity(_ gravity: Int64, rightToLeft: Bool) -> Int64 {
        guard gravity & self.relativeFlag != 0 else { return gravity }
        var result = gravity
        if result & 0x0080_0003 == 0x0080_0003 {
            result = (result & ~0x0080_0003) | (rightToLeft ? 5 : 3)
        } else if result & 0x0080_0005 == 0x0080_0005 {
            result = (result & ~0x0080_0005) | (rightToLeft ? 3 : 5)
        }
        return result & ~self.relativeFlag
    }

    /// `generateDefaultLayoutParams` of the parent, for a child added without LayoutParams.
    static func defaults(parentClassName: String, vertical: Bool) -> Request {
        func fields(_ width: Double, _ height: Double) -> [String: AyuBridgeValue] { ["width": .number(width), "height": .number(height)] }
        switch parentClassName {
        case "android.widget.LinearLayout":
            var result = fields(vertical ? -1 : -2, -2)
            result["weight"] = .number(0)
            return Request(className: self.linearClassName, fields: result)
        case AyuBridgeGridLayout.className:
            return Request(className: AyuBridgeGridLayout.paramsClassName, fields: fields(-2, -2))
        default:
            // FrameLayout, and the scroll views that extend it.
            return Request(className: self.frameClassName, fields: fields(-1, -1))
        }
    }

    static func childGravity(_ parameters: [String: AyuBridgeValue]) -> Int64? { parameters["gravity"]?.integer }

    /// A field as Java reads it: the margins are one stored array, an unset gravity is -1.
    static func field(_ name: String, in fields: [String: AyuBridgeValue]) -> AyuBridgeValue? {
        if let index = self.marginFields.firstIndex(of: name) {
            guard let margins = fields["margins"]?.array, margins.indices.contains(index) else { return .integer(0) }
            return margins[index]
        }
        return name == "gravity" ? fields["gravity"] ?? .integer(-1) : fields[name]
    }

    /// Writes a margin or the gravity; false for any other field name.
    static func setField(_ name: String, value: AyuBridgeValue, in fields: inout [String: AyuBridgeValue]) throws -> Bool {
        if let index = self.marginFields.firstIndex(of: name) {
            var margins = fields["margins"]?.array ?? []
            guard margins.count <= 4 else { throw AyuBridgeFailure("invalid_state", "Stored layout margins are unavailable") }
            margins += Array(repeating: .number(0), count: 4 - margins.count)
            margins[index] = .number(try self.margin(value))
            fields["margins"] = .array(margins)
            return true
        }
        guard name == "gravity" else { return false }
        fields["gravity"] = try self.gravity(value).map(AyuBridgeValue.integer)
        return true
    }

    /// Android lays Telegram's views out left to right whatever the language, so a stored `START`/`END`
    /// is left/right; only `relative` parameters were resolved for the interface direction.
    static func horizontalOrigin(gravity: Int64, container: CGFloat, extent: CGFloat, left: CGFloat, right: CGFloat) -> CGFloat {
        switch self.absoluteGravity(gravity, rightToLeft: false) & 0x07 {
        case 1: return (container - extent) / 2 + left - right
        case 5: return container - extent - right
        default: return left
        }
    }

    /// `linear` is the cross axis of a horizontal `LinearLayout`, which places a child whose gravity
    /// has no vertical part at the top without its top margin.
    static func verticalOrigin(gravity: Int64, container: CGFloat, extent: CGFloat, top: CGFloat, bottom: CGFloat, linear: Bool = false) -> CGFloat {
        switch gravity & 0x70 {
        case 0x10: return (container - extent) / 2 + top - bottom
        case 0x50: return container - extent - bottom
        case 0x30: return top
        default: return linear ? 0 : top
        }
    }

    /// `FrameLayout.layoutChildren`: an unspecified gravity is top-left.
    static func frameOrigin(gravity: Int64?, container: CGSize, size: CGSize, margins: Margins) -> CGPoint {
        guard let gravity else { return CGPoint(x: margins.left, y: margins.top) }
        return CGPoint(
            x: self.horizontalOrigin(gravity: gravity, container: container.width, extent: size.width, left: margins.left, right: margins.right),
            y: self.verticalOrigin(gravity: gravity, container: container.height, extent: size.height, top: margins.top, bottom: margins.bottom))
    }

    /// The child of a scroll view, a `FrameLayout` on Android: frame placement across the scroll axis,
    /// and along it only while the child with its margins is shorter than the viewport.
    static func scrollOrigin(gravity: Int64?, vertical: Bool, container: CGSize, size: CGSize, margins: Margins) -> CGPoint {
        let frame = self.frameOrigin(gravity: gravity, container: container, size: size, margins: margins)
        if vertical {
            return CGPoint(x: frame.x, y: margins.top + size.height + margins.bottom < container.height ? frame.y : margins.top)
        }
        return CGPoint(x: margins.left + size.width + margins.right < container.width ? frame.x : margins.left, y: frame.y)
    }

    private static func size(_ value: AyuBridgeValue?) throws -> Double {
        guard let number = value?.number, number.isFinite, number == -1 || number == -2 || (0...self.limit).contains(number) else {
            throw self.invalid("Invalid layout size")
        }
        return number < 0 ? number : number.rounded(.up)
    }

    private static func flag(_ value: AyuBridgeValue?) throws -> Bool {
        guard let value else { return false }
        guard value == .bool(true) else { throw self.invalid("Layout flags are true or absent") }
        return true
    }

    private static func invalid(_ message: String) -> AyuBridgeFailure { AyuBridgeFailure("invalid_arguments", message) }
}
