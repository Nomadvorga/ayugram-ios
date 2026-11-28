import UIKit

/// The engine banner's row. It remembers where it was last touched, as Android's `TextCheckCell`
/// does, so that the colour can spread from there.
final class AyuPluginBannerCell: UITableViewCell {
    var lastTouchX: CGFloat?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.lastTouchX = touches.first?.location(in: self).x ?? self.lastTouchX
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.lastTouchX = touches.first?.location(in: self).x ?? self.lastTouchX
        super.touchesEnded(touches, with: event)
    }
}

/// A background that takes a new colour as a circle growing from a point, the way Android's
/// `TextCheckCell.setBackgroundColorAnimated` paints it: centred on the touch at mid-height and
/// reaching 40 pt past the far side in 240 ms.
@MainActor final class AyuPluginRippleView: UIView {
    static let duration: CFTimeInterval = 0.24
    /// The colour the view has or is growing into.
    private(set) var color: UIColor
    /// The circle that is growing now, in this view's coordinates.
    private(set) var spreading: (center: CGPoint, radius: CGFloat)?
    private var ripple: CAShapeLayer?

    init(color: UIColor) {
        self.color = color
        super.init(frame: .zero)
        self.backgroundColor = color
        self.clipsToBounds = true
        self.isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { return nil }

    static func circle(in size: CGSize, from x: CGFloat) -> (center: CGPoint, radius: CGFloat) {
        (CGPoint(x: x, y: size.height / 2), max(x, size.width - x) + 40)
    }

    static func circleLayer(center: CGPoint, radius: CGFloat, fill: CGColor) -> CAShapeLayer {
        let circle = CAShapeLayer()
        circle.fillColor = fill
        circle.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius), transform: nil)
        circle.position = center
        return circle
    }

    /// Grows a circle that is already in a layer tree from nothing; `finished` runs when it has.
    static func grow(_ circle: CAShapeLayer, finished: @escaping () -> Void) {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0
        grow.toValue = 1
        grow.duration = Self.duration
        // Android `CubicBezierInterpolator.EASE_OUT`.
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock(finished)
        circle.add(grow, forKey: "grow")
        CATransaction.commit()
    }

    /// Without `x` the colour changes at once. A ripple still growing ends at its colour first.
    func set(_ color: UIColor, from x: CGFloat?) {
        self.settle()
        self.color = color
        guard let x, !self.bounds.isEmpty else { self.backgroundColor = color; return }
        let circle = Self.circle(in: self.bounds.size, from: x)
        let ripple = Self.circleLayer(center: circle.center, radius: circle.radius, fill: color.resolvedColor(with: self.traitCollection).cgColor)
        self.layer.addSublayer(ripple)
        self.ripple = ripple
        self.spreading = circle
        Self.grow(ripple) { [weak self, weak ripple] in
            guard let self, let ripple, self.ripple === ripple else { return }
            self.settle()
        }
    }

    private func settle() {
        self.backgroundColor = self.color
        self.ripple?.removeFromSuperlayer()
        self.ripple = nil
        self.spreading = nil
    }
}

/// The banner's switch. Android's `Switch.setOverrideColorProgress` paints the track and the thumb
/// in the new state's colours inside the banner's growing circle and in the old state's outside
/// it, while the thumb slides. Here a second switch in the new colours lies over this one, cut to
/// that circle, and this one keeps the old colours until the circle has grown.
@MainActor final class AyuPluginRippleSwitch: UISwitch {
    typealias Look = (track: UIColor, thumb: UIColor)
    /// The track and the thumb of each state. A change ends a circle that is growing.
    var looks: (on: Look, off: Look) { didSet { self.settle() } }
    /// The switch in the new colours, while the circle grows.
    private(set) var overlay: UISwitch?

    init(isOn: Bool, on: Look, off: Look) {
        self.looks = (on, off)
        super.init(frame: .zero)
        self.isOn = isOn
        self.settle()
    }

    required init?(coder: NSCoder) { return nil }

    private static func paint(_ toggle: UISwitch, on: UIColor, off: UIColor, thumb: UIColor) {
        toggle.onTintColor = on
        toggle.thumbTintColor = thumb
        // UIKit gives the off track no colour of its own; the capsule behind it is that track.
        toggle.backgroundColor = off
        toggle.layer.cornerRadius = toggle.bounds.height / 2
    }

    /// Shows the colours of the state the switch is in.
    func settle() {
        self.overlay?.removeFromSuperview()
        self.overlay = nil
        Self.paint(self, on: self.looks.on.track, off: self.looks.off.track, thumb: (self.isOn ? self.looks.on : self.looks.off).thumb)
    }

    /// Slides to `value`, taking its colours where the circle growing in `ripple` has reached.
    func setOn(_ value: Bool, following ripple: AyuPluginRippleView?) {
        self.settle()
        guard value != self.isOn, let ripple, let circle = ripple.spreading else {
            self.setOn(value, animated: true)
            self.settle()
            return
        }
        let old = self.isOn ? self.looks.on : self.looks.off, new = value ? self.looks.on : self.looks.off
        let overlay = UISwitch()
        overlay.frame = self.bounds
        overlay.isOn = self.isOn
        overlay.isUserInteractionEnabled = false
        overlay.isAccessibilityElement = false
        Self.paint(overlay, on: new.track, off: new.track, thumb: new.thumb)
        Self.paint(self, on: old.track, off: old.track, thumb: old.thumb)
        let mask = AyuPluginRippleView.circleLayer(center: ripple.convert(circle.center, to: self), radius: circle.radius, fill: UIColor.black.cgColor)
        overlay.layer.mask = mask
        self.addSubview(overlay)
        self.overlay = overlay
        AyuPluginRippleView.grow(mask) { [weak self, weak overlay] in
            guard let self, let overlay, self.overlay === overlay else { return }
            self.settle()
        }
        overlay.setOn(value, animated: true)
        self.setOn(value, animated: true)
    }
}
