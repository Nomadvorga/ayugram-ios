import UIKit
import Display
import TelegramPresentationData

private final class SGFolderTabsPreviewView: UIView {
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let separator = UIView()
    private var labels: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isAccessibilityElement = true
        self.accessibilityTraits = .staticText
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.isAccessibilityElement = true
        self.scrollView.accessibilityTraits = .staticText
        self.addSubview(self.scrollView)
        self.stackView.axis = .horizontal
        self.stackView.alignment = .center
        self.scrollView.addSubview(self.stackView)
        self.addSubview(self.separator)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(configuration: SGFolderTabsPreviewConfiguration, theme: PresentationTheme, baseSize: CGFloat) {
        while self.labels.count > configuration.tabs.count {
            self.labels.removeLast().removeFromSuperview()
        }
        while self.labels.count < configuration.tabs.count {
            let label = UILabel()
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            self.labels.append(label)
            self.stackView.addArrangedSubview(label)
        }

        self.stackView.spacing = configuration.compact ? 12.0 : 22.0
        for (index, tab) in configuration.tabs.enumerated() {
            let label = self.labels[index]
            label.text = configuration.displayTitle(for: tab)
            label.font = Font.medium(baseSize * 0.9)
            label.textColor = theme.list.itemPrimaryTextColor
            label.accessibilityLabel = tab.title
        }
        self.scrollView.accessibilityLabel = configuration.tabs.map(\.title).joined(separator: ", ")
        self.separator.backgroundColor = theme.list.itemBlocksSeparatorColor
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = self.bounds.height
        self.scrollView.frame = CGRect(x: 18.0, y: 4.0, width: max(0.0, self.bounds.width - 36.0), height: max(0.0, height - 14.0))
        let stackSize = self.stackView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let contentWidth = max(self.scrollView.bounds.width, stackSize.width)
        self.stackView.frame = CGRect(x: 0.0, y: 0.0, width: contentWidth, height: self.scrollView.bounds.height)
        self.scrollView.contentSize = CGSize(width: contentWidth, height: self.scrollView.bounds.height)
        self.separator.frame = CGRect(x: 18.0, y: height - 1.0, width: max(0.0, self.bounds.width - 36.0), height: UIScreenPixel)
    }
}

/// Integer-only 4...20 control. The marker moves locally before the settings signal returns.
private final class SGStickerSizeControl: UIControl {
    private let track = CAShapeLayer()
    private let active = CAShapeLayer()
    private let gap = CAShapeLayer()
    private let marker = CAShapeLayer()
    private var start = CGPoint.zero
    private var dragging = false
    private var cancelledForScroll = false
    private(set) var value: Int32 = 12
    var updated: ((Int32) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isAccessibilityElement = true
        for layer in [self.track, self.active, self.gap, self.marker] { self.layer.addSublayer(layer) }
        for layer in [self.track, self.active] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 8.0
            layer.lineCap = .round
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(value: Int32, title: String, enabled: Bool, theme: PresentationTheme, style: SGItemListVisualStyle) {
        if !self.isTracking || !enabled { self.value = SGSettingsPreviewGeometry.stickerSize(value) }
        self.isEnabled = enabled
        self.accessibilityLabel = title
        self.accessibilityValue = String(self.value)
        self.accessibilityTraits = enabled ? .adjustable : [.adjustable, .notEnabled]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.track.strokeColor = theme.list.itemSecondaryTextColor.withAlphaComponent(0.45).cgColor
        self.active.strokeColor = theme.list.itemAccentColor.cgColor
        self.gap.fillColor = style.cardColor(theme: theme).withAlphaComponent(1.0).cgColor
        self.marker.fillColor = theme.list.itemAccentColor.cgColor
        CATransaction.commit()
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0.0, self.bounds.width)
        let inset = min(4.0, width / 2.0)
        let y = self.bounds.midY
        let x = inset + max(0.0, width - 2.0 * inset) * CGFloat(self.value - 4) / 16.0
        let track = UIBezierPath()
        track.move(to: CGPoint(x: inset, y: y))
        track.addLine(to: CGPoint(x: width - inset, y: y))
        let active = UIBezierPath()
        if self.value > 4 {
            active.move(to: CGPoint(x: inset, y: y))
            active.addLine(to: CGPoint(x: x, y: y))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.track.path = track.cgPath
        self.active.path = active.cgPath
        self.gap.path = UIBezierPath(roundedRect: CGRect(x: x - 6.0, y: y - 7.0, width: 12.0, height: 14.0), cornerRadius: 3.0).cgPath
        self.marker.path = UIBezierPath(roundedRect: CGRect(x: x - 1.75, y: y - 13.0, width: 3.5, height: 26.0), cornerRadius: 1.75).cgPath
        CATransaction.commit()
    }

    private func select(_ value: Int32) {
        let value = SGSettingsPreviewGeometry.stickerSize(value)
        guard self.isEnabled, value != self.value else { return }
        self.value = value
        self.accessibilityValue = String(value)
        self.setNeedsLayout()
        self.updated?(value)
        self.sendActions(for: .valueChanged)
    }

    private func select(at point: CGPoint) {
        let inset = min(4.0, self.bounds.width / 2.0)
        let fraction = max(0.0, min(1.0, (point.x - inset) / max(1.0, self.bounds.width - inset * 2.0)))
        self.select(Int32((4.0 + fraction * 16.0).rounded()))
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard self.isEnabled else { return false }
        self.start = touch.location(in: self)
        self.dragging = false
        self.cancelledForScroll = false
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
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

    override func cancelTracking(with event: UIEvent?) { self.dragging = false }
    override func accessibilityIncrement() { self.select(self.value + 1) }
    override func accessibilityDecrement() { self.select(self.value - 1) }
}

/// Reuses one illustration, one integer scale and three selectable shape tiles.
final class SGSettingsPreviewView: UIView {
    private let title = UILabel()
    private let badge = UILabel()
    private let small = UILabel()
    private let large = UILabel()
    private let scale = SGStickerSizeControl(frame: .zero)
    private let scene = SGSettingsIllustrationView(frame: .zero)
    private let folderTabs = SGFolderTabsPreviewView(frame: .zero)
    private let tileButtons = (0 ..< 3).map { _ in UIButton(type: .custom) }
    private let tileSurfaces = (0 ..< 3).map { _ in UIView() }
    private let tileShapes = (0 ..< 3).map { _ in UIView() }
    private let tileLabels = (0 ..< 3).map { _ in UILabel() }
    private var kind: SGSettingsPreviewKind?
    private var theme: PresentationTheme?
    private var style: SGItemListVisualStyle = .native
    private var baseSize: CGFloat = 17.0
    var sliderUpdated: ((Int32) -> Void)?
    var selectionUpdated: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.clipsToBounds = true
        self.isAccessibilityElement = false
        for view in [self.title, self.badge, self.small, self.large, self.scale, self.scene, self.folderTabs] as [UIView] { self.addSubview(view) }
        self.badge.textAlignment = .center
        self.badge.layer.cornerRadius = 5.0
        self.badge.clipsToBounds = true
        self.badge.lineBreakMode = .byTruncatingTail
        self.small.lineBreakMode = .byTruncatingTail
        self.large.lineBreakMode = .byTruncatingTail
        self.large.textAlignment = .right
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1.0
        let activationImage = UIGraphicsImageRenderer(size: CGSize(width: 1.0, height: 1.0), format: format).image { $0.cgContext.clear(CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)) }
        for index in 0 ..< 3 {
            let button = self.tileButtons[index]
            button.tag = index
            button.setBackgroundImage(activationImage, for: .normal)
            button.addTarget(self, action: #selector(self.shapePressed(_:)), for: .touchUpInside)
            self.addSubview(button)
            button.addSubview(self.tileSurfaces[index])
            self.tileSurfaces[index].addSubview(self.tileShapes[index])
            button.addSubview(self.tileLabels[index])
            self.tileSurfaces[index].isUserInteractionEnabled = false
            self.tileSurfaces[index].layer.cornerRadius = 12.0
            self.tileLabels[index].isUserInteractionEnabled = false
            self.tileLabels[index].numberOfLines = 2
            self.tileLabels[index].textAlignment = .center
            self.tileLabels[index].lineBreakMode = .byTruncatingTail
        }
        self.scale.updated = { [weak self] size in
            guard let self, case var .sticker(configuration)? = self.kind else { return }
            configuration.size = size
            self.kind = .sticker(configuration)
            self.updateStickerLabels(configuration)
            if let theme = self.theme { self.scene.update(kind: .sticker(configuration), theme: theme, baseSize: self.baseSize) }
            self.scene.setNeedsLayout()
            self.sliderUpdated?(size)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateStickerLabels(_ configuration: SGStickerPreviewConfiguration) {
        self.badge.text = SGSettingsPreviewGeometry.stickerSize(configuration.size) == 20 ? configuration.largeBadge : String(SGSettingsPreviewGeometry.stickerSize(configuration.size))
        self.scale.accessibilityValue = self.badge.text
        self.small.textColor = configuration.size <= 4 ? self.theme?.list.itemAccentColor : self.theme?.list.itemSecondaryTextColor
        self.large.textColor = configuration.size >= 20 ? self.theme?.list.itemAccentColor : self.theme?.list.itemSecondaryTextColor
        self.setNeedsLayout()
    }

    func update(kind: SGSettingsPreviewKind, theme: PresentationTheme, style: SGItemListVisualStyle, baseSize: CGFloat) {
        var effectiveKind = kind
        if case var .sticker(configuration) = kind, self.scale.isTracking, self.sliderUpdated != nil {
            configuration.size = self.scale.value
            effectiveKind = .sticker(configuration)
        }
        self.kind = effectiveKind
        self.theme = theme
        self.style = style
        self.baseSize = baseSize
        self.title.font = Font.medium(baseSize * 0.94)
        self.title.textColor = theme.list.itemAccentColor
        self.title.numberOfLines = 1
        self.title.lineBreakMode = .byTruncatingTail
        self.badge.font = Font.semibold(baseSize * 0.76)
        self.badge.textColor = theme.list.itemAccentColor
        self.badge.backgroundColor = theme.list.itemAccentColor.withAlphaComponent(0.14)
        self.small.font = Font.regular(baseSize * 0.82)
        self.large.font = self.small.font
        let isSticker: Bool
        let isShapes: Bool
        let isFolderTabs: Bool
        if case .sticker = effectiveKind { isSticker = true } else { isSticker = false }
        if case .stickerShapes = effectiveKind { isShapes = true } else { isShapes = false }
        if case .folderTabs = effectiveKind { isFolderTabs = true } else { isFolderTabs = false }
        // Do not briefly hide the scale during a model echo: UIKit can cancel its active touch.
        for view in [self.title, self.badge, self.small, self.large, self.scale] as [UIView] { view.isHidden = !isSticker }
        for button in self.tileButtons { button.isHidden = !isShapes }
        self.scene.isHidden = isShapes || isFolderTabs
        self.folderTabs.isHidden = !isFolderTabs
        switch effectiveKind {
        case let .sticker(configuration):
            self.title.text = configuration.title
            self.small.text = configuration.smallLabel
            self.large.text = configuration.largeLabel
            self.scale.update(value: configuration.size, title: configuration.title, enabled: self.sliderUpdated != nil, theme: theme, style: style)
            self.updateStickerLabels(configuration)
            self.scene.update(kind: effectiveKind, theme: theme, baseSize: baseSize)
            self.accessibilityElements = [self.scale]
        case let .stickerShapes(value, options):
            for index in 0 ..< 3 {
                let selected = index == max(0, min(2, value))
                let button = self.tileButtons[index]
                button.isEnabled = self.selectionUpdated != nil && index < options.count
                button.accessibilityLabel = index < options.count ? options[index] : nil
                button.accessibilityTraits = selected ? [.button, .selected] : .button
                if !button.isEnabled { button.accessibilityTraits.insert(.notEnabled) }
                self.tileLabels[index].text = button.accessibilityLabel
                self.tileLabels[index].font = selected ? Font.semibold(baseSize * 0.82) : Font.regular(baseSize * 0.82)
                self.tileLabels[index].textColor = selected ? theme.list.itemAccentColor : theme.list.itemPrimaryTextColor
                self.tileSurfaces[index].backgroundColor = style.cardColor(theme: theme).mixedWith(theme.list.itemPrimaryTextColor, alpha: 0.04)
                self.tileSurfaces[index].layer.borderWidth = selected ? 2.0 : UIScreenPixel
                self.tileSurfaces[index].layer.borderColor = (selected ? theme.list.itemAccentColor : theme.list.itemSecondaryTextColor.withAlphaComponent(0.3)).cgColor
                self.tileShapes[index].backgroundColor = theme.list.itemPrimaryTextColor.withAlphaComponent(0.1)
                self.tileShapes[index].layer.cornerRadius = index == 0 ? 0.0 : (index == 1 ? 6.0 : 20.0)
            }
            self.accessibilityElements = self.tileButtons
        case .message:
            self.scene.update(kind: effectiveKind, theme: theme, baseSize: baseSize)
            self.accessibilityElements = []
        case let .folderTabs(configuration):
            self.folderTabs.update(configuration: configuration, theme: theme, baseSize: baseSize)
            self.accessibilityElements = [self.folderTabs]
        }
        self.setNeedsLayout()
    }

    @objc private func shapePressed(_ button: UIButton) {
        guard button.isEnabled, case let .stickerShapes(value, options)? = self.kind, button.tag < options.count, button.tag != max(0, min(2, value)), let theme = self.theme else { return }
        self.update(kind: .stickerShapes(value: button.tag, options: options), theme: theme, style: self.style, baseSize: self.baseSize)
        self.selectionUpdated?(button.tag)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let kind = self.kind else { return }
        let width = max(0.0, self.bounds.width)
        switch kind {
        case .sticker:
            let headerHeight = SGSettingsPreviewGeometry.stickerHeaderHeight(baseSize: self.baseSize)
            let interiorWidth = max(0.0, width - 44.0)
            let badgeWidth = min(interiorWidth * 0.42, ceil(self.badge.intrinsicContentSize.width) + 12.0)
            let titleWidth = min(max(0.0, interiorWidth - badgeWidth - 8.0), ceil(self.title.intrinsicContentSize.width))
            self.title.frame = CGRect(x: 22.0, y: 18.0, width: titleWidth, height: ceil(self.title.font.lineHeight) + 4.0)
            self.badge.frame = CGRect(x: self.title.frame.maxX + 8.0, y: 18.0, width: badgeWidth, height: ceil(self.badge.font.lineHeight) + 6.0)
            let labelHeight = ceil(self.small.font.lineHeight) + 4.0
            self.small.frame = CGRect(x: 22.0, y: headerHeight - 56.0 - labelHeight, width: interiorWidth / 2.0, height: labelHeight)
            self.large.frame = CGRect(x: width / 2.0, y: self.small.frame.minY, width: interiorWidth / 2.0, height: labelHeight)
            self.scale.frame = CGRect(x: 22.0, y: headerHeight - 56.0, width: interiorWidth, height: 44.0)
            self.scene.frame = CGRect(x: 0.0, y: headerHeight, width: width, height: max(0.0, self.bounds.height - headerHeight))
        case .stickerShapes:
            let tileWidth = max(0.0, (width - 44.0 - 32.0) / 3.0)
            let tileHeight = min(88.0, tileWidth * 0.85)
            for index in 0 ..< 3 {
                self.tileButtons[index].frame = CGRect(x: 22.0 + CGFloat(index) * (tileWidth + 16.0), y: 12.0, width: tileWidth, height: max(0.0, self.bounds.height - 24.0))
                self.tileSurfaces[index].frame = CGRect(x: 0.0, y: 0.0, width: tileWidth, height: tileHeight)
                self.tileShapes[index].frame = self.tileSurfaces[index].bounds.insetBy(dx: min(10.0, tileWidth * 0.1), dy: min(10.0, tileHeight * 0.1))
                self.tileLabels[index].frame = CGRect(x: 0.0, y: tileHeight + 12.0, width: tileWidth, height: max(0.0, self.tileButtons[index].bounds.height - tileHeight - 12.0))
            }
        case .message:
            self.scene.frame = self.bounds
        case .folderTabs:
            self.folderTabs.frame = self.bounds
        }
    }
}
