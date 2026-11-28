import UIKit
import Display
import TelegramPresentationData

/// A labelled scale with discrete stops, rather than a continuous slider or a popup selector.
final class SGDiscreteSelectorControl: UIControl {
    private let trackLayer = CAShapeLayer()
    private let activeLayer = CAShapeLayer()
    private let stopsLayer = CAShapeLayer()
    private let markerGapLayer = CAShapeLayer()
    private let markerLayer = CAShapeLayer()
    private var labels: [UILabel] = []
    private var options: [String] = []
    private var baseSize: CGFloat = 17.0
    private var theme: PresentationTheme?
    private var visualStyle: SGItemListVisualStyle = .native
    private var startPoint = CGPoint.zero
    private var dragging = false
    private var cancelledForScroll = false
    private var trackY: CGFloat = 51.0
    private var pendingSelectionAnimationFrom: Int?
    private(set) var selectedIndex = 0
    var valueChanged: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isAccessibilityElement = true
        self.accessibilityTraits = .adjustable
        for layer in [self.trackLayer, self.activeLayer, self.stopsLayer, self.markerGapLayer, self.markerLayer] {
            self.layer.addSublayer(layer)
        }
        for layer in [self.trackLayer, self.activeLayer] {
            layer.lineWidth = 8.0
            layer.lineCap = .round
            layer.fillColor = UIColor.clear.cgColor
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func metrics(options: [String], width: CGFloat, baseSize: CGFloat) -> (font: UIFont, labelHeight: CGFloat, trackY: CGFloat, height: CGFloat) {
        let font = Font.regular(baseSize * 0.82)
        let columnWidth = max(1.0, width / CGFloat(max(1, options.count)) - 4.0)
        let maxHeight = baseSize > 22.0 ? 10000.0 : ceil(font.lineHeight * 2.0)
        let labelHeight = options.reduce(ceil(font.lineHeight)) { height, text in
            let rect = (text as NSString).boundingRect(with: CGSize(width: columnWidth, height: maxHeight), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], attributes: [.font: font], context: nil)
            return max(height, min(maxHeight, ceil(rect.height)))
        }
        let trackY = 16.0 + labelHeight + 18.0
        return (font, labelHeight, trackY, max(80.0, trackY + 27.0))
    }

    static func height(options: [String], width: CGFloat, baseSize: CGFloat) -> CGFloat {
        return Self.metrics(options: options, width: width, baseSize: baseSize).height
    }

    static func progressFraction(index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return 0.0 }
        return CGFloat(max(0, min(count - 1, index))) / CGFloat(count - 1)
    }

    /// Applying model state never emits a callback and never changes this control's frame.
    func update(theme: PresentationTheme, visualStyle: SGItemListVisualStyle, baseSize: CGFloat, value: Int, options: [String], enabled: Bool) {
        let optionsChanged = self.options != options
        let previousIndex = self.selectedIndex
        self.options = options
        self.theme = theme
        self.visualStyle = visualStyle
        self.baseSize = baseSize
        // A signal round-trip must not rewind a finger already dragging over the next stop.
        if optionsChanged || !self.isTracking || !enabled {
            self.selectedIndex = max(0, min(max(0, options.count - 1), value))
            if previousIndex != self.selectedIndex {
                self.pendingSelectionAnimationFrom = !optionsChanged && !self.dragging && !UIAccessibility.isReduceMotionEnabled ? previousIndex : nil
            } else if optionsChanged {
                self.pendingSelectionAnimationFrom = nil
            }
        }
        while self.labels.count > options.count {
            self.labels.removeLast().removeFromSuperview()
        }
        while self.labels.count < options.count {
            let label = UILabel()
            label.isAccessibilityElement = false
            label.isUserInteractionEnabled = false
            self.labels.append(label)
            self.addSubview(label)
        }
        for (index, label) in self.labels.enumerated() {
            label.text = options[index]
        }
        self.isEnabled = enabled && options.count > 1
        self.isUserInteractionEnabled = self.isEnabled
        self.alpha = enabled ? 1.0 : 0.45
        self.accessibilityLabel = options.joined(separator: ", ")
        self.updateAccessibility()
        self.setNeedsLayout()
    }

    private func updateAccessibility() {
        self.accessibilityValue = self.options.indices.contains(self.selectedIndex) ? self.options[self.selectedIndex] : nil
        self.accessibilityTraits = self.isEnabled ? .adjustable : [.adjustable, .notEnabled]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let theme = self.theme else { return }
        let width = max(0.0, self.bounds.width)
        let metrics = Self.metrics(options: self.options, width: width, baseSize: self.baseSize)
        self.trackY = metrics.trackY
        let columnWidth = width / CGFloat(max(1, self.labels.count))
        for (index, label) in self.labels.enumerated() {
            label.font = metrics.font
            label.numberOfLines = self.baseSize > 22.0 ? 0 : 2
            label.lineBreakMode = self.baseSize > 22.0 ? .byWordWrapping : .byTruncatingTail
            label.textAlignment = self.labels.count == 1 ? .center : (index == 0 ? .left : (index == self.labels.count - 1 ? .right : .center))
            label.textColor = index == self.selectedIndex ? theme.list.itemAccentColor : theme.list.itemSecondaryTextColor
            label.frame = CGRect(x: CGFloat(index) * columnWidth + (index == 0 ? 0.0 : 2.0), y: 16.0, width: max(0.0, columnWidth - 4.0), height: metrics.labelHeight)
            if self.labels.count == 1 {
                label.frame = CGRect(x: 0.0, y: 16.0, width: width, height: metrics.labelHeight)
            } else if index == self.labels.count - 1 {
                label.frame.origin.x = width - label.frame.width
            }
        }
        let startX = min(3.0, width / 2.0)
        let endX = max(startX, width - startX)
        func stopX(_ index: Int) -> CGFloat {
            return self.options.count > 1 ? startX + (endX - startX) * CGFloat(index) / CGFloat(self.options.count - 1) : width / 2.0
        }
        let track = UIBezierPath()
        if self.options.count > 1 {
            track.move(to: CGPoint(x: startX, y: metrics.trackY))
            track.addLine(to: CGPoint(x: endX, y: metrics.trackY))
        }
        let selectedX = stopX(self.selectedIndex)
        let selectedFraction = Self.progressFraction(index: self.selectedIndex, count: self.options.count)
        let previousIndex = self.pendingSelectionAnimationFrom.map { max(0, min(max(0, self.options.count - 1), $0)) }
        let previousX = previousIndex.map(stopX)
        let activePath = track.cgPath
        let markerPath = UIBezierPath(roundedRect: CGRect(x: selectedX - 1.75, y: metrics.trackY - 13.0, width: 3.5, height: 26.0), cornerRadius: 1.75).cgPath
        let markerGapPath = UIBezierPath(roundedRect: CGRect(x: selectedX - 6.0, y: metrics.trackY - 7.0, width: 12.0, height: 14.0), cornerRadius: 3.0).cgPath
        let stops = UIBezierPath()
        for index in self.options.indices where index != self.selectedIndex {
            stops.append(UIBezierPath(ovalIn: CGRect(x: stopX(index) - 2.0, y: metrics.trackY - 2.0, width: 4.0, height: 4.0)))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.trackLayer.path = track.cgPath
        self.trackLayer.strokeColor = theme.list.itemSecondaryTextColor.withAlphaComponent(0.65).cgColor
        self.activeLayer.path = activePath
        self.activeLayer.strokeColor = theme.list.itemAccentColor.cgColor
        self.activeLayer.strokeEnd = selectedFraction
        self.stopsLayer.path = stops.cgPath
        self.stopsLayer.fillColor = self.visualStyle.cardColor(theme: theme).withAlphaComponent(1.0).cgColor
        self.markerGapLayer.path = markerGapPath
        self.markerGapLayer.fillColor = self.visualStyle.cardColor(theme: theme).withAlphaComponent(1.0).cgColor
        self.markerLayer.path = markerPath
        self.markerLayer.fillColor = theme.list.itemAccentColor.cgColor
        self.markerLayer.isHidden = self.options.isEmpty
        self.markerGapLayer.isHidden = self.options.isEmpty
        if let previousIndex, let previousX, previousIndex != self.selectedIndex, !UIAccessibility.isReduceMotionEnabled {
            let progressAnimation = CABasicAnimation(keyPath: "strokeEnd")
            progressAnimation.fromValue = self.activeLayer.presentation()?.strokeEnd ?? Self.progressFraction(index: previousIndex, count: self.options.count)
            progressAnimation.toValue = selectedFraction
            progressAnimation.duration = 0.22
            progressAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.activeLayer.add(progressAnimation, forKey: "selectorProgress")

            let previousMarkerPath = UIBezierPath(roundedRect: CGRect(x: previousX - 1.75, y: metrics.trackY - 13.0, width: 3.5, height: 26.0), cornerRadius: 1.75).cgPath
            let markerAnimation = CABasicAnimation(keyPath: "path")
            markerAnimation.fromValue = self.markerLayer.presentation()?.path ?? previousMarkerPath
            markerAnimation.toValue = markerPath
            markerAnimation.duration = 0.22
            markerAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.markerLayer.add(markerAnimation, forKey: "selectorMarker")

            let previousGapPath = UIBezierPath(roundedRect: CGRect(x: previousX - 6.0, y: metrics.trackY - 7.0, width: 12.0, height: 14.0), cornerRadius: 3.0).cgPath
            let gapAnimation = CABasicAnimation(keyPath: "path")
            gapAnimation.fromValue = self.markerGapLayer.presentation()?.path ?? previousGapPath
            gapAnimation.toValue = markerGapPath
            gapAnimation.duration = 0.22
            gapAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.markerGapLayer.add(gapAnimation, forKey: "selectorGap")
        }
        CATransaction.commit()
        self.pendingSelectionAnimationFrom = nil
    }

    private func index(at point: CGPoint) -> Int {
        guard self.options.count > 1 else { return 0 }
        let width = max(1.0, self.bounds.width)
        let index: Int
        if point.y < self.trackY - 15.0 {
            // Long edge labels still select their own stop throughout their label column.
            index = Int(floor(max(0.0, min(width, point.x)) / width * CGFloat(self.options.count)))
        } else {
            let inset = min(3.0, width / 2.0)
            let fraction = max(0.0, min(1.0, (point.x - inset) / max(1.0, width - inset * 2.0)))
            index = Int((fraction * CGFloat(self.options.count - 1)).rounded())
        }
        return max(0, min(self.options.count - 1, index))
    }

    private func select(_ index: Int) {
        guard self.isEnabled, self.options.indices.contains(index), index != self.selectedIndex else { return }
        let previousIndex = self.selectedIndex
        self.selectedIndex = index
        self.pendingSelectionAnimationFrom = !self.dragging && !UIAccessibility.isReduceMotionEnabled ? previousIndex : nil
        self.updateAccessibility()
        self.setNeedsLayout()
        self.valueChanged?(index)
        self.sendActions(for: .valueChanged)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard self.isEnabled else { return false }
        self.startPoint = touch.location(in: self)
        self.dragging = false
        self.cancelledForScroll = false
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        if !self.dragging {
            let dx = abs(point.x - self.startPoint.x)
            let dy = abs(point.y - self.startPoint.y)
            if dy > 6.0 && dy > dx {
                self.cancelledForScroll = true
                return false
            }
            guard dx > 4.0 else { return true }
            self.dragging = true
        }
        self.select(self.index(at: point))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch, !self.cancelledForScroll {
            let point = touch.location(in: self)
            if self.dragging || self.bounds.contains(point) { self.select(self.index(at: point)) }
        }
        self.dragging = false
    }

    override func cancelTracking(with event: UIEvent?) {
        self.dragging = false
    }

    override func accessibilityIncrement() {
        self.select(self.selectedIndex + 1)
    }

    override func accessibilityDecrement() {
        self.select(self.selectedIndex - 1)
    }
}
