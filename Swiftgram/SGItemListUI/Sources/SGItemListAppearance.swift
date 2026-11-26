import UIKit

/// Explicit presentation inputs for the opt-in renderer. No preferences are read here.
public struct SGExteraAppearance: Equatable {
    public enum ControlStyle: Int, Equatable {
        case classic = 0
        case material = 1
    }

    public enum SeparatorStyle: Equatable {
        case line
        case fullWidth
        case none
    }

    public var controlStyle: ControlStyle
    public var sectionRadius: CGFloat
    public var separateHeaders: Bool
    public var separatorStyle: SeparatorStyle

    public init(controlStyle: ControlStyle = .material, sectionRadius: CGFloat = 22.0, separateHeaders: Bool = true, separatorStyle: SeparatorStyle = .line) {
        self.controlStyle = controlStyle
        self.sectionRadius = sectionRadius
        self.separateHeaders = separateHeaders
        self.separatorStyle = separatorStyle
    }

    var radius: CGFloat { return self.sectionRadius.isFinite ? max(0.0, min(64.0, self.sectionRadius)) : 22.0 }
}

/// A raw integer scale. Labels are supplied by the host, including the unit's leading space.
public struct SGItemListRangeConfiguration: Equatable {
    public var value: Int32
    public var minimum: Int32
    public var maximum: Int32
    public var step: Int32
    public var title: String
    public var minimumLabel: String
    public var maximumLabel: String
    public var unitSuffix: String

    public init(value: Int32, minimum: Int32, maximum: Int32, step: Int32 = 1, title: String, minimumLabel: String, maximumLabel: String, unitSuffix: String = "") {
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.title = title
        self.minimumLabel = minimumLabel
        self.maximumLabel = maximumLabel
        self.unitSuffix = unitSuffix
    }

    var lower: Int64 { return Int64(min(self.minimum, self.maximum)) }
    var upper: Int64 { return Int64(max(self.minimum, self.maximum)) }
    var stride: Int64 { return max(1, Int64(self.step)) }

    func normalized(_ value: Int64) -> Int32 {
        let clamped = max(self.lower, min(self.upper, value))
        if clamped == self.upper { return Int32(self.upper) }
        let steps = Int64((Double(clamped - self.lower) / Double(self.stride)).rounded())
        return Int32(min(self.upper, self.lower + steps * self.stride))
    }

    func text(value: Int32) -> String { return String(value) + self.unitSuffix }
}

/// Shared host-level glass policy; virtualized rows never allocate blur views.
public struct SGItemListGlassConfiguration: Equatable {
    public enum Border: Equatable {
        case none
        case line
        case highlights
    }

    public var enabled: Bool
    public var forceBlur: Bool
    public var border: Border

    public init(enabled: Bool = false, forceBlur: Bool = false, border: Border = .none) {
        self.enabled = enabled
        self.forceBlur = forceBlur
        self.border = border
    }

    /// Reduce Transparency takes precedence over every visual preference.
    public func usesBlur(nativeAllowsBlur: Bool, themeAllowsBlur: Bool, effectsAllowed: Bool, reduceTransparency: Bool) -> Bool {
        return self.enabled && nativeAllowsBlur && effectsAllowed && (themeAllowsBlur || self.forceBlur) && !reduceTransparency
    }
}
