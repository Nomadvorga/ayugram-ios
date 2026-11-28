import UIKit
import Display
import TelegramPresentationData

/// Opt-in menu/navigation backdrop. Add controls above it as siblings in the host.
/// The parent owns its frame; one effect view is reused and opacity is never animated.
public final class SGItemListGlassSurfaceView: UIView {
    private var effectView: UIVisualEffectView?
    private let tint = UIView()
    private let outline = CAShapeLayer()
    private let highlight = CAShapeLayer()
    private var theme: PresentationTheme?
    private var configuration = SGItemListGlassConfiguration()
    private var themeAllowsBlur = true
    private var nativeAllowsBlur = false
    private var effectsAllowed = false
    private var blurIsDark: Bool?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.accessibilityElementsHidden = true
        self.clipsToBounds = true
        self.addSubview(self.tint)
        for layer in [self.outline, self.highlight] {
            self.layer.addSublayer(layer)
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = UIScreenPixel
        }
        self.highlight.lineCap = .round
        if #available(iOS 13.0, *) { self.layer.cornerCurve = .continuous }
        NotificationCenter.default.addObserver(self, selector: #selector(self.transparencyChanged), name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    public func update(theme: PresentationTheme, configuration: SGItemListGlassConfiguration, nativeAllowsBlur: Bool, effectsAllowed: Bool, themeAllowsBlur: Bool = true, cornerRadius: CGFloat = 22.0) {
        self.theme = theme
        self.configuration = configuration
        self.themeAllowsBlur = themeAllowsBlur
        self.effectsAllowed = effectsAllowed
        self.nativeAllowsBlur = nativeAllowsBlur
        self.layer.cornerRadius = cornerRadius.isFinite ? max(0.0, min(64.0, cornerRadius)) : 22.0
        self.applyAppearance()
    }

    @objc private func transparencyChanged() { self.applyAppearance() }

    private func applyAppearance() {
        guard let theme = self.theme else { return }
        let blurred = self.configuration.usesBlur(nativeAllowsBlur: self.nativeAllowsBlur, themeAllowsBlur: self.themeAllowsBlur, effectsAllowed: self.effectsAllowed, reduceTransparency: UIAccessibility.isReduceTransparencyEnabled)
        if blurred {
            let effect: UIVisualEffectView
            if let current = self.effectView {
                effect = current
            } else {
                effect = UIVisualEffectView(effect: nil)
                effect.isUserInteractionEnabled = false
                self.effectView = effect
                self.insertSubview(effect, belowSubview: self.tint)
            }
            if self.blurIsDark != theme.overallDarkAppearance {
                effect.effect = UIBlurEffect(style: theme.overallDarkAppearance ? .dark : .light)
                self.blurIsDark = theme.overallDarkAppearance
            }
        } else {
            self.effectView?.effect = nil
            self.blurIsDark = nil
        }
        self.effectView?.isHidden = !blurred
        let card = SGItemListVisualStyle.extera.cardColor(theme: theme)
        self.backgroundColor = blurred ? .clear : card.withAlphaComponent(1.0)
        self.tint.backgroundColor = blurred ? card.withAlphaComponent(theme.overallDarkAppearance ? 0.62 : 0.7) : .clear
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.outline.isHidden = self.configuration.border == .none
        self.highlight.isHidden = self.configuration.border != .highlights
        self.outline.strokeColor = theme.list.itemPrimaryTextColor.withAlphaComponent(self.configuration.border == .highlights ? 0.1 : 0.2).cgColor
        self.highlight.strokeColor = theme.list.itemPrimaryTextColor.withAlphaComponent(0.36).cgColor
        CATransaction.commit()
        self.setNeedsLayout()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        self.effectView?.frame = self.bounds
        self.tint.frame = self.bounds
        let rect = self.bounds.insetBy(dx: UIScreenPixel / 2.0, dy: UIScreenPixel / 2.0)
        let safeRect = CGRect(x: rect.minX, y: rect.minY, width: max(0.0, rect.width), height: max(0.0, rect.height))
        let radius = min(self.layer.cornerRadius, min(safeRect.width, safeRect.height) / 2.0)
        let highlight = UIBezierPath()
        highlight.move(to: CGPoint(x: safeRect.minX + radius, y: safeRect.minY))
        highlight.addLine(to: CGPoint(x: max(safeRect.minX + radius, safeRect.midX), y: safeRect.minY))
        highlight.move(to: CGPoint(x: safeRect.midX, y: safeRect.maxY))
        highlight.addLine(to: CGPoint(x: safeRect.maxX - radius, y: safeRect.maxY))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.outline.path = UIBezierPath(roundedRect: safeRect, cornerRadius: radius).cgPath
        self.highlight.path = highlight.cgPath
        CATransaction.commit()
    }
}
