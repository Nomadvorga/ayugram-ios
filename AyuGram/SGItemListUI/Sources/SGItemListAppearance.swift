import UIKit
import TelegramPresentationData

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

/// Extera-style, animated switch for settings screens built outside ItemListNode.
/// The drawing matches the toggle rendered by `SGExteraItemNode`.
public final class SGExteraToggleControl: UIControl {
    private let trackLayer = CAShapeLayer()
    private let thumbLayer = CAShapeLayer()
    private var theme: PresentationTheme
    private var style: SGExteraAppearance.ControlStyle

    /// Optional accent override for screens whose active state has a contextual color.
    public var onTintColor: UIColor? {
        didSet { self.updateAppearance(animated: false) }
    }

    public var valueUpdated: ((Bool) -> Void)?

    public private(set) var isOn: Bool {
        didSet { self.updateAccessibilityState() }
    }

    public override var isEnabled: Bool {
        didSet { self.alpha = self.isEnabled ? 1.0 : 0.45 }
    }

    public init(value: Bool, theme: PresentationTheme, style: SGExteraAppearance.ControlStyle = .material) {
        self.theme = theme
        self.style = style
        self.isOn = value
        super.init(frame: .zero)

        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
        self.layer.addSublayer(self.trackLayer)
        self.layer.addSublayer(self.thumbLayer)
        self.addTarget(self, action: #selector(self.activate), for: .touchUpInside)
        self.updateAppearance(animated: false)
        self.updateAccessibilityState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var intrinsicContentSize: CGSize {
        return CGSize(width: 66.0, height: 44.0)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        self.trackLayer.frame = self.bounds
        self.thumbLayer.frame = self.bounds
        self.updateAppearance(animated: false)
    }

    public override func accessibilityActivate() -> Bool {
        guard self.isEnabled else { return false }
        self.toggle()
        return true
    }

    /// Update theme/style when the containing settings screen receives new presentation data.
    public func update(theme: PresentationTheme, style: SGExteraAppearance.ControlStyle, animated: Bool = false) {
        self.theme = theme
        self.style = style
        self.updateAppearance(animated: animated)
    }

    /// Synchronize a value published by the settings model without emitting `.valueChanged`.
    public func setOn(_ value: Bool, animated: Bool) {
        guard value != self.isOn else { return }
        self.isOn = value
        self.updateAppearance(animated: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func activate() {
        guard self.isEnabled else { return }
        self.toggle()
    }

    private func toggle() {
        self.setOn(!self.isOn, animated: true)
        self.valueUpdated?(self.isOn)
        self.sendActions(for: .valueChanged)
    }

    private func updateAccessibilityState() {
        self.accessibilityValue = self.isOn ? NSLocalizedString("On", comment: "Switch state") : NSLocalizedString("Off", comment: "Switch state")
        self.accessibilityTraits = self.isOn ? [.button, .selected] : .button
    }

    private func updateAppearance(animated: Bool) {
        let rect = CGRect(x: 10.0, y: 8.0, width: 46.0, height: 28.0)
        let trackPath = UIBezierPath(roundedRect: rect, cornerRadius: 14.0).cgPath
        let oldTrackPath = self.trackLayer.presentation()?.path ?? self.trackLayer.path
        let oldTrackFill = self.trackLayer.presentation()?.fillColor ?? self.trackLayer.fillColor
        let oldTrackLineWidth = self.trackLayer.presentation()?.lineWidth ?? self.trackLayer.lineWidth
        let oldThumbPath = self.thumbLayer.presentation()?.path ?? self.thumbLayer.path
        let oldThumbFill = self.thumbLayer.presentation()?.fillColor ?? self.thumbLayer.fillColor

        let accent = self.onTintColor ?? self.theme.list.itemAccentColor
        let trackFill = self.isOn ? accent.cgColor : self.theme.list.itemPrimaryTextColor.withAlphaComponent(self.theme.overallDarkAppearance ? 0.14 : 0.08).cgColor
        let lineWidth = self.isOn || self.style == .classic ? 0.0 : 1.8
        let diameter: CGFloat = self.style == .classic ? 23.0 : (self.isOn ? 21.0 : 14.0)
        let centerX = self.isOn ? rect.maxX - 14.0 : rect.minX + 14.0
        let thumbPath = UIBezierPath(ovalIn: CGRect(x: centerX - diameter / 2.0, y: rect.midY - diameter / 2.0, width: diameter, height: diameter)).cgPath
        let thumbFill = self.style == .classic
            ? self.theme.list.itemCheckColors.foregroundColor.cgColor
            : (self.isOn ? SGItemListVisualStyle.extera.cardColor(theme: self.theme).cgColor : self.theme.list.itemSecondaryTextColor.cgColor)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.trackLayer.path = trackPath
        self.trackLayer.lineWidth = lineWidth
        self.trackLayer.fillColor = trackFill
        self.trackLayer.strokeColor = self.theme.list.itemSecondaryTextColor.cgColor
        self.thumbLayer.path = thumbPath
        self.thumbLayer.fillColor = thumbFill
        CATransaction.commit()

        guard animated else { return }
        let duration: CFTimeInterval = 0.24
        let timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if let oldTrackPath { self.addAnimation(layer: self.trackLayer, keyPath: "path", from: oldTrackPath, to: trackPath, duration: duration, timingFunction: timingFunction) }
        if let oldTrackFill { self.addAnimation(layer: self.trackLayer, keyPath: "fillColor", from: oldTrackFill, to: trackFill, duration: duration, timingFunction: timingFunction) }
        self.addAnimation(layer: self.trackLayer, keyPath: "lineWidth", from: oldTrackLineWidth, to: lineWidth, duration: duration, timingFunction: timingFunction)
        if let oldThumbPath { self.addAnimation(layer: self.thumbLayer, keyPath: "path", from: oldThumbPath, to: thumbPath, duration: duration, timingFunction: timingFunction) }
        if let oldThumbFill { self.addAnimation(layer: self.thumbLayer, keyPath: "fillColor", from: oldThumbFill, to: thumbFill, duration: duration, timingFunction: timingFunction) }
    }

    private func addAnimation(layer: CALayer, keyPath: String, from: Any, to: Any, duration: CFTimeInterval, timingFunction: CAMediaTimingFunction) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timingFunction
        layer.add(animation, forKey: "exteraStandaloneToggle.\(keyPath)")
    }
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

    func fraction(value: Int32) -> CGFloat {
        guard self.upper > self.lower else { return 0.0 }
        let normalizedValue = self.normalized(Int64(value))
        return CGFloat(Int64(normalizedValue) - self.lower) / CGFloat(self.upper - self.lower)
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
