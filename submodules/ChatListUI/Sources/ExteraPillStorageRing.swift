import UIKit

final class ExteraPillStorageRing: UIView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        for layer in [self.track, self.arc] {
            layer.fillColor = UIColor.clear.cgColor; layer.lineWidth = 2; layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        self.arc.strokeEnd = 0.05
        self.isUserInteractionEnabled = false
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { preconditionFailure() }
    override func tintColorDidChange() {
        super.tintColorDidChange()
        self.track.strokeColor = self.tintColor.withAlphaComponent(50.0 / 255).cgColor
        self.arc.strokeColor = self.tintColor.cgColor
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(arcCenter: CGPoint(x: self.bounds.midX, y: self.bounds.midY), radius: max(0, min(self.bounds.width, self.bounds.height) / 2 - 1), startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true).cgPath
        self.track.path = path; self.arc.path = path
    }
    func setProgress(_ value: Double) {
        let progress = CGFloat(min(1, max(0.05, value)))
        let previous = self.arc.presentation()?.strokeEnd ?? self.arc.strokeEnd
        self.arc.strokeEnd = progress
        guard !UIAccessibility.isReduceMotionEnabled else { self.arc.removeAllAnimations(); return }
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = previous; animation.toValue = progress; animation.duration = 0.65
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        self.arc.add(animation, forKey: "progress")
    }
}
