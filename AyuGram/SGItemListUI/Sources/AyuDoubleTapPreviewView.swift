import UIKit
import Display
import TelegramPresentationData

/// A decorative example of the incoming/outgoing double-tap actions, with no chat data or gestures.
final class AyuDoubleTapPreviewView: UIView {
    private let incomingBubble = CAShapeLayer()
    private let outgoingBubble = CAShapeLayer()
    private let incomingIcon = UIImageView()
    private let outgoingIcon = UIImageView()
    private var incomingSymbol: String?
    private var outgoingSymbol: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
        self.accessibilityElementsHidden = true
        self.layer.addSublayer(self.incomingBubble)
        self.layer.addSublayer(self.outgoingBubble)
        for icon in [self.incomingIcon, self.outgoingIcon] {
            icon.contentMode = .scaleAspectFit
            icon.isAccessibilityElement = false
            self.addSubview(icon)
        }
        for bubble in [self.incomingBubble, self.outgoingBubble] {
            bubble.lineWidth = 0.75
            bubble.lineJoin = .round
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The parent sets the frame. All geometry below is relative to this view's bounds.
    func update(theme: PresentationTheme, visualStyle: SGItemListVisualStyle, incomingSymbol: String, outgoingSymbol: String) {
        if self.incomingSymbol != incomingSymbol {
            self.incomingSymbol = incomingSymbol
            self.incomingIcon.image = sgItemListSymbolImage(named: incomingSymbol)
        }
        if self.outgoingSymbol != outgoingSymbol {
            self.outgoingSymbol = outgoingSymbol
            self.outgoingIcon.image = sgItemListSymbolImage(named: outgoingSymbol)
        }
        let surface = visualStyle.cardColor(theme: theme)
        let fill = surface.mixedWith(theme.list.itemPrimaryTextColor, alpha: theme.overallDarkAppearance ? 0.045 : 0.025)
        let stroke = theme.list.itemSecondaryTextColor.withAlphaComponent(theme.overallDarkAppearance ? 0.3 : 0.22)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bubble in [self.incomingBubble, self.outgoingBubble] {
            bubble.fillColor = fill.cgColor
            bubble.strokeColor = stroke.cgColor
        }
        CATransaction.commit()
        self.incomingIcon.tintColor = theme.list.itemSecondaryTextColor
        self.outgoingIcon.tintColor = theme.list.itemSecondaryTextColor
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0.0, self.bounds.width)
        let scale = min(1.0, max(0.0, self.bounds.height) / 190.0)
        let inset = min(30.0, width * 0.08)
        let tail = min(7.0, width * 0.02)
        let bubbleWidth = min(150.0, max(0.0, width - inset * 2.0 - tail))
        let bubbleHeight = 64.0 * scale
        // These frames include the tail; the 150pt rectangular bodies stay inside the safe band.
        let incomingFrame = CGRect(x: inset - tail, y: 14.0 * scale, width: bubbleWidth + tail, height: bubbleHeight)
        let outgoingFrame = CGRect(x: width - inset - bubbleWidth, y: 94.0 * scale, width: bubbleWidth + tail, height: bubbleHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.incomingBubble.frame = incomingFrame
        self.outgoingBubble.frame = outgoingFrame
        self.incomingBubble.path = Self.bubblePath(size: incomingFrame.size, tail: tail, outgoing: false)
        self.outgoingBubble.path = Self.bubblePath(size: outgoingFrame.size, tail: tail, outgoing: true)
        CATransaction.commit()
        let iconSide = min(24.0 * scale, bubbleWidth * 0.5)
        self.incomingIcon.frame = CGRect(x: incomingFrame.minX + tail + (bubbleWidth - iconSide) / 2.0, y: incomingFrame.midY - iconSide / 2.0, width: iconSide, height: iconSide)
        self.outgoingIcon.frame = CGRect(x: outgoingFrame.minX + (bubbleWidth - iconSide) / 2.0, y: outgoingFrame.midY - iconSide / 2.0, width: iconSide, height: iconSide)
    }

    /// Closed cubic/quadratic outline; the outgoing path mirrors the complete incoming shape.
    private static func bubblePath(size: CGSize, tail: CGFloat, outgoing: Bool) -> CGPath {
        let path = UIBezierPath()
        let left = min(tail, size.width)
        let right = max(left, size.width)
        let bottom = max(0.0, size.height)
        let radius = min(20.0, min((right - left) / 2.0, bottom / 2.0))
        path.move(to: CGPoint(x: left + radius, y: 0.0))
        path.addLine(to: CGPoint(x: right - radius, y: 0.0))
        path.addQuadCurve(to: CGPoint(x: right, y: radius), controlPoint: CGPoint(x: right, y: 0.0))
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), controlPoint: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addCurve(to: CGPoint(x: 0.0, y: bottom), controlPoint1: CGPoint(x: left + radius * 0.35, y: bottom), controlPoint2: CGPoint(x: left * 0.4, y: bottom))
        path.addCurve(to: CGPoint(x: left, y: bottom - radius * 0.7), controlPoint1: CGPoint(x: left, y: bottom - radius * 0.2), controlPoint2: CGPoint(x: left, y: bottom - radius * 0.35))
        path.addLine(to: CGPoint(x: left, y: radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: 0.0), controlPoint: CGPoint(x: left, y: 0.0))
        path.close()
        if outgoing {
            path.apply(CGAffineTransform(a: -1.0, b: 0.0, c: 0.0, d: 1.0, tx: size.width, ty: 0.0))
        }
        return path.cgPath
    }
}
