import UIKit
import Display
import TelegramPresentationData

/// Raw numeric settings scale, with endpoint labels and a locally updated central value.
final class SGItemListRangeControl: UIControl {
    private let minimumLabel = UILabel()
    private let valueLabel = UILabel()
    private let maximumLabel = UILabel()
    private let track = CAShapeLayer()
    private let active = CAShapeLayer()
    private let gap = CAShapeLayer()
    private let marker = CAShapeLayer()
    private var configuration: SGItemListRangeConfiguration?
    private var interactionIdentity: AnyHashable?
    private var baseSize: CGFloat = 17.0
    private var value: Int32 = 0
    private var start = CGPoint.zero
    private var dragging = false
    private var cancelledForScroll = false
    private var pendingTransitionFromValue: Int32?
    var updated: ((Int32) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isAccessibilityElement = true
        for label in [self.minimumLabel, self.valueLabel, self.maximumLabel] {
            label.numberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.isAccessibilityElement = false
            self.addSubview(label)
        }
        self.valueLabel.textAlignment = .center
        self.maximumLabel.textAlignment = .right
        for layer in [self.track, self.active, self.gap, self.marker] { self.layer.addSublayer(layer) }
        for layer in [self.track, self.active] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 8.0
            layer.lineCap = .round
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func height(baseSize: CGFloat) -> CGFloat {
        return max(80.0, 16.0 + ceil(Font.regular(baseSize * 0.82).lineHeight * 2.0) + 45.0)
    }

    func update(configuration: SGItemListRangeConfiguration, interactionIdentity: AnyHashable?, theme: PresentationTheme, visualStyle: SGItemListVisualStyle, baseSize: CGFloat, enabled: Bool) {
        let rangeChanged = self.interactionIdentity != interactionIdentity || self.configuration?.minimum != configuration.minimum || self.configuration?.maximum != configuration.maximum || self.configuration?.step != configuration.step || self.configuration?.title != configuration.title
        let previousValue = self.value
        let hadConfiguration = self.configuration != nil
        if rangeChanged || !enabled { self.cancelTracking(with: nil) }
        if rangeChanged || !self.isTracking || !enabled { self.value = configuration.normalized(Int64(configuration.value)) }
        if previousValue != self.value {
            self.pendingTransitionFromValue = hadConfiguration && !rangeChanged && !self.dragging && !UIAccessibility.isReduceMotionEnabled ? previousValue : nil
        }
        self.configuration = configuration
        self.interactionIdentity = interactionIdentity
        self.baseSize = baseSize
        self.isEnabled = enabled && configuration.lower < configuration.upper
        self.alpha = enabled ? 1.0 : 0.45
        self.accessibilityLabel = configuration.title
        self.minimumLabel.text = configuration.minimumLabel
        self.maximumLabel.text = configuration.maximumLabel
        for label in [self.minimumLabel, self.valueLabel, self.maximumLabel] { label.font = Font.regular(baseSize * 0.82) }
        self.minimumLabel.textColor = theme.list.itemSecondaryTextColor
        self.maximumLabel.textColor = theme.list.itemSecondaryTextColor
        self.valueLabel.textColor = theme.list.itemAccentColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.track.strokeColor = theme.list.itemSecondaryTextColor.withAlphaComponent(0.45).cgColor
        self.active.strokeColor = theme.list.itemAccentColor.cgColor
        self.gap.fillColor = visualStyle.cardColor(theme: theme).withAlphaComponent(1.0).cgColor
        self.marker.fillColor = theme.list.itemAccentColor.cgColor
        CATransaction.commit()
        self.refreshValue()
    }

    private func refreshValue() {
        self.valueLabel.text = self.configuration?.text(value: self.value)
        self.accessibilityValue = self.valueLabel.text
        self.accessibilityTraits = self.isEnabled ? .adjustable : [.adjustable, .notEnabled]
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let configuration = self.configuration else { return }
        let width = max(0.0, self.bounds.width)
        let column = width / 3.0
        let labelHeight = ceil(Font.regular(self.baseSize * 0.82).lineHeight * 2.0)
        for (index, label) in [self.minimumLabel, self.valueLabel, self.maximumLabel].enumerated() {
            label.frame = CGRect(x: CGFloat(index) * column, y: 16.0, width: max(0.0, column - 2.0), height: labelHeight)
        }
        let y = 16.0 + labelHeight + 18.0
        let inset = min(6.0, width / 2.0)
        let fraction = configuration.fraction(value: self.value)
        let x = inset + max(0.0, width - inset * 2.0) * fraction
        let track = UIBezierPath()
        track.move(to: CGPoint(x: inset, y: y))
        track.addLine(to: CGPoint(x: width - inset, y: y))
        let previousFraction = self.pendingTransitionFromValue.map { configuration.fraction(value: $0) }
        let previousX = previousFraction.map { inset + max(0.0, width - inset * 2.0) * $0 }
        let markerPath = UIBezierPath(roundedRect: CGRect(x: x - 1.75, y: y - 13.0, width: 3.5, height: 26.0), cornerRadius: 1.75).cgPath
        let gapPath = UIBezierPath(roundedRect: CGRect(x: x - 6.0, y: y - 7.0, width: 12.0, height: 14.0), cornerRadius: 3.0).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.track.path = track.cgPath
        self.active.path = track.cgPath
        self.active.strokeEnd = fraction
        self.gap.path = gapPath
        self.marker.path = markerPath
        if let previousFraction, let previousX, previousFraction != fraction {
            let progressAnimation = CABasicAnimation(keyPath: "strokeEnd")
            progressAnimation.fromValue = self.active.presentation()?.strokeEnd ?? previousFraction
            progressAnimation.toValue = fraction
            progressAnimation.duration = 0.22
            progressAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.active.add(progressAnimation, forKey: "rangeProgress")

            let previousMarkerPath = UIBezierPath(roundedRect: CGRect(x: previousX - 1.75, y: y - 13.0, width: 3.5, height: 26.0), cornerRadius: 1.75).cgPath
            let markerAnimation = CABasicAnimation(keyPath: "path")
            markerAnimation.fromValue = self.marker.presentation()?.path ?? previousMarkerPath
            markerAnimation.toValue = markerPath
            markerAnimation.duration = 0.22
            markerAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.marker.add(markerAnimation, forKey: "rangeMarker")

            let previousGapPath = UIBezierPath(roundedRect: CGRect(x: previousX - 6.0, y: y - 7.0, width: 12.0, height: 14.0), cornerRadius: 3.0).cgPath
            let gapAnimation = CABasicAnimation(keyPath: "path")
            gapAnimation.fromValue = self.gap.presentation()?.path ?? previousGapPath
            gapAnimation.toValue = gapPath
            gapAnimation.duration = 0.22
            gapAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.gap.add(gapAnimation, forKey: "rangeGap")
        }
        CATransaction.commit()
        self.pendingTransitionFromValue = nil
    }

    private func select(_ value: Int64) {
        guard self.isEnabled, let configuration = self.configuration else { return }
        let value = configuration.normalized(value)
        guard value != self.value else { return }
        let previousValue = self.value
        self.value = value
        self.pendingTransitionFromValue = !self.dragging && !UIAccessibility.isReduceMotionEnabled ? previousValue : nil
        self.refreshValue()
        self.updated?(value)
        self.sendActions(for: .valueChanged)
    }

    private func select(at point: CGPoint) {
        guard let configuration = self.configuration else { return }
        let inset = min(6.0, self.bounds.width / 2.0)
        let fraction = max(0.0, min(1.0, (point.x - inset) / max(1.0, self.bounds.width - inset * 2.0)))
        self.select(configuration.lower + Int64((Double(configuration.upper - configuration.lower) * Double(fraction)).rounded()))
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard self.isEnabled else { return false }
        self.start = touch.location(in: self)
        self.dragging = false
        self.cancelledForScroll = false
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard !self.cancelledForScroll, self.isEnabled else { return false }
        let point = touch.location(in: self)
        if !self.dragging {
            let dx = abs(point.x - self.start.x)
            let dy = abs(point.y - self.start.y)
            if dy > 6.0 && dy > dx { self.cancelledForScroll = true; return false }
            guard dx > 4.0 else { return true }
            self.dragging = true
        }
        self.select(at: point)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch, !self.cancelledForScroll {
            let point = touch.location(in: self)
            if self.dragging || self.bounds.contains(point) { self.select(at: point) }
        }
        self.dragging = false
    }

    override func cancelTracking(with event: UIEvent?) { self.dragging = false; self.cancelledForScroll = true }
    override func accessibilityIncrement() {
        if let configuration = self.configuration { self.select(Int64(self.value) + configuration.stride) }
    }
    override func accessibilityDecrement() {
        if let configuration = self.configuration {
            let offset = Int64(self.value) - configuration.lower
            let delta = offset % configuration.stride == 0 ? configuration.stride : offset % configuration.stride
            self.select(Int64(self.value) - delta)
        }
    }
}

/// Two vector style choices matching the reference's circular / rounded-square compose button.
final class SGAppearanceStyleControl: UIView {
    private let buttons = (0 ..< 2).map { _ in UIButton(type: .custom) }
    private let drawings = (0 ..< 2).map { _ in CAShapeLayer() }
    private let accents = (0 ..< 2).map { _ in CAShapeLayer() }
    private let icons = (0 ..< 2).map { _ in UIImageView(image: sgItemListSymbolImage(named: "bubble.left.fill")) }
    private var selected = 0
    private var options: [String] = []
    private var accentColor = UIColor.clear
    private var borderColor = UIColor.clear
    var updated: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isAccessibilityElement = false
        for index in 0 ..< 2 {
            let button = self.buttons[index]
            button.tag = index
            button.layer.cornerRadius = 13.0
            button.layer.addSublayer(self.drawings[index])
            button.layer.addSublayer(self.accents[index])
            self.icons[index].contentMode = .scaleAspectFit
            self.icons[index].isUserInteractionEnabled = false
            button.addSubview(self.icons[index])
            button.addTarget(self, action: #selector(self.pressed(_:)), for: .touchUpInside)
            self.addSubview(button)
        }
        self.accessibilityElements = self.buttons
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func tileGeometry(width: CGFloat) -> (inset: CGFloat, gap: CGFloat, width: CGFloat) {
        let width = max(0.0, width)
        let inset = min(22.0, max(0.0, (width - 100.0) / 2.0))
        let gap = min(18.0, max(0.0, width - 88.0 - inset * 2.0))
        return (inset, gap, max(0.0, (width - inset * 2.0 - gap) / 2.0))
    }

    static func height(width: CGFloat) -> CGFloat {
        let tileWidth = self.tileGeometry(width: width).width
        return 32.0 + max(64.0, min(88.0, tileWidth * 0.5))
    }

    func update(value: Int, options: [String], enabled: Bool, theme: PresentationTheme, visualStyle: SGItemListVisualStyle) {
        self.selected = max(0, min(min(1, options.count - 1), value))
        self.options = options
        self.accentColor = theme.list.itemAccentColor
        self.borderColor = theme.list.itemSecondaryTextColor.withAlphaComponent(0.3)
        for index in 0 ..< 2 {
            let button = self.buttons[index]
            button.isEnabled = enabled && index < options.count
            button.isAccessibilityElement = index < options.count
            button.accessibilityLabel = index < options.count ? options[index] : nil
            button.accessibilityTraits = index == self.selected ? [.button, .selected] : .button
            if !button.isEnabled { button.accessibilityTraits.insert(.notEnabled) }
            button.backgroundColor = visualStyle.cardColor(theme: theme).mixedWith(theme.list.itemPrimaryTextColor, alpha: 0.04)
            button.layer.borderWidth = index == self.selected ? 2.0 : UIScreenPixel
            button.layer.borderColor = (index == self.selected ? self.accentColor : self.borderColor).cgColor
            button.alpha = enabled ? 1.0 : 0.45
            self.drawings[index].fillColor = theme.list.itemPrimaryTextColor.withAlphaComponent(0.14).cgColor
            self.accents[index].fillColor = theme.list.itemAccentColor.cgColor
            self.icons[index].tintColor = theme.list.itemCheckColors.foregroundColor
        }
        self.setNeedsLayout()
    }

    @objc private func pressed(_ button: UIButton) {
        guard button.isEnabled, button.tag != self.selected, button.tag < self.options.count else { return }
        self.selected = button.tag
        for (index, current) in self.buttons.enumerated() {
            current.layer.borderWidth = index == self.selected ? 2.0 : UIScreenPixel
            current.layer.borderColor = (index == self.selected ? self.accentColor : self.borderColor).cgColor
            current.accessibilityTraits.remove(.selected)
            if index == self.selected { current.accessibilityTraits.insert(.selected) }
        }
        self.updated?(button.tag)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0.0, self.bounds.width)
        let geometry = Self.tileGeometry(width: width)
        let tileWidth = geometry.width
        let tileHeight = max(0.0, self.bounds.height - 32.0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0 ..< 2 {
            self.buttons[index].frame = CGRect(x: geometry.inset + CGFloat(index) * (tileWidth + geometry.gap), y: 16.0, width: tileWidth, height: tileHeight)
            let scale = min(tileWidth / 160.0, tileHeight / 80.0)
            let drawing = UIBezierPath()
            for row in 0 ..< 2 {
                let y = (12.0 + CGFloat(row) * 35.0) * scale
                drawing.append(UIBezierPath(ovalIn: CGRect(x: 12.0 * scale, y: y, width: 24.0 * scale, height: 24.0 * scale)))
                drawing.append(UIBezierPath(roundedRect: CGRect(x: 45.0 * scale, y: y + 4.0 * scale, width: 43.0 * scale, height: 4.0 * scale), cornerRadius: 2.0 * scale))
                drawing.append(UIBezierPath(roundedRect: CGRect(x: 45.0 * scale, y: y + 15.0 * scale, width: 60.0 * scale, height: 4.0 * scale), cornerRadius: 2.0 * scale))
            }
            self.drawings[index].path = drawing.cgPath
            let compose = CGRect(x: tileWidth - 43.0 * scale, y: tileHeight - 43.0 * scale, width: 33.0 * scale, height: 33.0 * scale)
            self.accents[index].path = UIBezierPath(roundedRect: compose, cornerRadius: (index == 0 ? 16.5 : 10.0) * scale).cgPath
            self.icons[index].frame = compose.insetBy(dx: 8.0 * scale, dy: 8.0 * scale)
        }
        CATransaction.commit()
    }
}
