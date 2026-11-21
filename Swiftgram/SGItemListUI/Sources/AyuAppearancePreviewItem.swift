import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AyuSnowEffect

public enum AyuAppearancePreviewKind: Equatable {
    case avatar(value: Int32, title: String, square: String, circle: String)
    case chatList(title: String, centered: Bool, snow: Bool)
}

/// A native adjustable avatar preview or a chat-list header preview.
public final class AyuAppearancePreviewItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let kind: AyuAppearancePreviewKind
    public let sectionId: Int32
    let updated: (Int32) -> Void

    public init(theme: PresentationTheme, sectionId: Int32, kind: AyuAppearancePreviewKind, updated: @escaping (Int32) -> Void) {
        self.theme = theme
        self.sectionId = sectionId
        self.kind = kind
        self.updated = updated
    }

    public func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = AyuAppearancePreviewItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async {
                completion(node, { (nil, { _ in apply() }) })
            }
        }
    }

    public func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? AyuAppearancePreviewItemNode else { return }
            let makeLayout = node.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self)))
                Queue.mainQueue().async { completion(layout, { _ in apply() }) }
            }
        }
    }
}

private final class AyuAppearancePreviewItemNode: ListViewItemNode {
    private let backgroundNode = ASDisplayNode()
    private let topStripeNode = ASDisplayNode()
    private let bottomStripeNode = ASDisplayNode()
    private let maskNode = ASImageNode()
    // UIKit objects are created lazily in the main-thread apply pass.
    private lazy var titleLabel = UILabel()
    private lazy var valueLabel = UILabel()
    private lazy var squareLabel = UILabel()
    private lazy var circleLabel = UILabel()
    private lazy var preview = UIView()
    private lazy var avatarLayer = CALayer()
    private lazy var onlineOuterLayer = CALayer()
    private lazy var onlineInnerLayer = CALayer()
    private lazy var skeletonLayers = (0 ..< 4).map { _ in CALayer() }
    private lazy var menuLayers = (0 ..< 3).map { _ in CALayer() }
    private lazy var headerLabel = UILabel()
    private lazy var slider = UISlider()
    private lazy var snowView = AyuSnowView(style: .header)
    private var contentCreated = false
    private var item: AyuAppearancePreviewItem?
    private var displayedValue: Int32 = 28
    private var previewFrame = CGRect.zero

    override var visibility: ListViewItemNodeVisibility {
        didSet { self.updateSnowVisibility() }
    }

    init() {
        super.init(layerBacked: false)
        for node in [self.backgroundNode, self.topStripeNode, self.bottomStripeNode] {
            node.isLayerBacked = true
            self.addSubnode(node)
        }
        self.addSubnode(self.maskNode)
    }

    private func createContentIfNeeded() {
        guard !self.contentCreated else { return }
        self.contentCreated = true
        for label in [self.titleLabel, self.valueLabel, self.squareLabel, self.circleLabel] {
            self.view.addSubview(label)
        }
        self.view.addSubview(self.slider)
        self.view.addSubview(self.preview)
        self.preview.isUserInteractionEnabled = false
        self.preview.layer.cornerRadius = 12.0
        self.preview.layer.borderWidth = UIScreenPixel
        self.preview.clipsToBounds = true
        self.preview.layer.addSublayer(self.avatarLayer)
        for layer in self.skeletonLayers + self.menuLayers {
            self.preview.layer.addSublayer(layer)
        }
        self.preview.layer.addSublayer(self.onlineOuterLayer)
        self.preview.layer.addSublayer(self.onlineInnerLayer)
        self.preview.addSubview(self.headerLabel)
        self.preview.addSubview(self.snowView)
        self.slider.minimumValue = 0.0
        self.slider.maximumValue = 28.0
        self.slider.addTarget(self, action: #selector(self.sliderChanged), for: .valueChanged)
        self.titleLabel.font = Font.semibold(15.0)
        self.valueLabel.font = Font.semibold(13.0)
        self.valueLabel.textAlignment = .right
        self.squareLabel.font = Font.regular(13.0)
        self.circleLabel.font = Font.regular(13.0)
        self.circleLabel.textAlignment = .right
        self.headerLabel.font = Font.semibold(20.0)
        self.headerLabel.lineBreakMode = .byTruncatingTail
        self.headerLabel.isAccessibilityElement = true
    }

    @objc private func sliderChanged() {
        let value = Int32(self.slider.value.rounded())
        guard value != self.displayedValue else { return }
        self.displayedValue = value
        // Update the mock before the model signal round-trip, without implicit layer animation.
        self.updateAvatar(value: value)
        self.item?.updated(value)
    }

    private func updateAvatar(value: Int32) {
        guard let item = self.item, case let .avatar(_, _, square, circle) = item.kind else { return }
        let value = max(0, min(28, value))
        self.valueLabel.text = value == 0 ? square : value == 28 ? circle : String(value)
        self.slider.accessibilityValue = self.valueLabel.text
        let radius = CGFloat(value)
        let squareness = 1.0 - radius / 28.0
        let outer = 7.0 + squareness * 2.0
        let inner = 5.0 + squareness
        let xOffset = 8.0 + (outer / sqrt(2.0) - 8.0) * squareness
        let yOffset = 7.5 + (outer / sqrt(2.0) - 7.5) * squareness
        let center = CGPoint(x: self.avatarLayer.frame.maxX - xOffset, y: self.avatarLayer.frame.maxY - yOffset)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.avatarLayer.cornerRadius = radius
        self.onlineOuterLayer.frame = CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2.0, height: outer * 2.0)
        self.onlineOuterLayer.cornerRadius = outer
        self.onlineInnerLayer.frame = CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2.0, height: inner * 2.0)
        self.onlineInnerLayer.cornerRadius = inner
        CATransaction.commit()
    }

    private func updateSnowVisibility() {
        guard self.contentCreated else { return }
        let enabled: Bool
        if let item = self.item, case let .chatList(_, _, snow) = item.kind {
            enabled = snow
        } else {
            enabled = false
        }
        switch self.visibility {
        case .none:
            self.snowView.isActive = false
        case let .visible(fraction, rect):
            self.snowView.isActive = enabled && fraction > 0.0 && rect.intersects(self.previewFrame)
        }
        // AyuSnowView also gates on window/scene activation, reduce motion and power mode.
    }

    func asyncLayout() -> (AyuAppearancePreviewItem, ListViewItemLayoutParams, ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params, neighbors in
            let isAvatar: Bool
            switch item.kind {
            case .avatar: isAvatar = true
            case .chatList: isAvatar = false
            }
            let contentSize = CGSize(width: params.width, height: isAvatar ? 210.0 : 100.0)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            return (layout, { [weak self] in
                guard let self else { return }
                self.item = item
                self.createContentIfNeeded()
                self.backgroundNode.backgroundColor = item.theme.list.itemBlocksBackgroundColor
                self.topStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor
                self.bottomStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor
                let hasCorners = itemListHasRoundedBlockLayout(params)
                let hasTopCorners: Bool
                switch neighbors.top {
                case .sameSection(false):
                    hasTopCorners = false
                    self.topStripeNode.isHidden = true
                default:
                    hasTopCorners = true
                    self.topStripeNode.isHidden = hasCorners
                }
                let hasBottomCorners: Bool
                let bottomInset: CGFloat
                let bottomOffset: CGFloat
                switch neighbors.bottom {
                case .sameSection(false):
                    hasBottomCorners = false
                    bottomInset = params.leftInset + 16.0
                    bottomOffset = -UIScreenPixel
                    self.bottomStripeNode.isHidden = false
                default:
                    hasBottomCorners = true
                    bottomInset = 0.0
                    bottomOffset = 0.0
                    self.bottomStripeNode.isHidden = hasCorners
                }
                self.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.theme, top: hasTopCorners, bottom: hasBottomCorners, glass: true) : nil
                self.backgroundNode.frame = CGRect(x: 0.0, y: -min(insets.top, UIScreenPixel), width: params.width, height: contentSize.height + min(insets.top, UIScreenPixel) + min(insets.bottom, UIScreenPixel))
                self.maskNode.frame = self.backgroundNode.frame.inset(by: UIEdgeInsets(top: 0.0, left: params.leftInset, bottom: 0.0, right: params.rightInset))
                self.topStripeNode.frame = CGRect(x: 0.0, y: -min(insets.top, UIScreenPixel), width: layout.size.width, height: UIScreenPixel)
                self.bottomStripeNode.frame = CGRect(x: bottomInset, y: contentSize.height + bottomOffset, width: max(0.0, params.width - bottomInset - params.rightInset - 16.0), height: UIScreenPixel)
                let x = params.leftInset + 21.0
                let width = max(0.0, params.width - x - params.rightInset - 21.0)
                self.previewFrame = CGRect(x: x, y: isAvatar ? 112.0 : 18.0, width: width, height: isAvatar ? 80.0 : 64.0)
                self.preview.frame = self.previewFrame
                self.preview.backgroundColor = item.theme.list.itemBlocksBackgroundColor
                self.preview.layer.borderColor = item.theme.list.itemBlocksSeparatorColor.cgColor
                self.headerLabel.textColor = item.theme.list.itemPrimaryTextColor
                self.snowView.color = item.theme.list.itemAccentColor
                self.snowView.frame = self.preview.bounds
                self.titleLabel.textColor = item.theme.list.itemAccentColor
                self.valueLabel.textColor = item.theme.list.itemAccentColor
                self.squareLabel.textColor = item.theme.list.itemSecondaryTextColor
                self.circleLabel.textColor = item.theme.list.itemSecondaryTextColor
                self.slider.minimumTrackTintColor = item.theme.list.itemAccentColor
                self.slider.maximumTrackTintColor = item.theme.list.itemSwitchColors.frameColor
                let avatarControls: [UIView] = [self.titleLabel, self.valueLabel, self.squareLabel, self.circleLabel, self.slider]
                for control in avatarControls {
                    control.isHidden = !isAvatar
                }
                self.headerLabel.isHidden = isAvatar
                self.avatarLayer.isHidden = !isAvatar
                self.onlineOuterLayer.isHidden = !isAvatar
                self.onlineInnerLayer.isHidden = !isAvatar
                for layer in self.skeletonLayers { layer.isHidden = !isAvatar }
                for layer in self.menuLayers { layer.isHidden = isAvatar }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                switch item.kind {
                case let .avatar(value, title, square, circle):
                    self.titleLabel.text = title
                    self.squareLabel.text = square
                    self.circleLabel.text = circle
                    self.titleLabel.frame = CGRect(x: x, y: 15.0, width: width * 0.7, height: 22.0)
                    self.valueLabel.frame = CGRect(x: x + width * 0.7, y: 15.0, width: width * 0.3, height: 22.0)
                    self.squareLabel.frame = CGRect(x: x, y: 44.0, width: width * 0.5, height: 20.0)
                    self.circleLabel.frame = CGRect(x: x + width * 0.5, y: 44.0, width: width * 0.5, height: 20.0)
                    self.slider.frame = CGRect(x: x, y: 65.0, width: width, height: 44.0)
                    self.slider.accessibilityLabel = title
                    self.displayedValue = max(0, min(28, value))
                    self.slider.setValue(Float(self.displayedValue), animated: false)
                    self.avatarLayer.frame = CGRect(x: 14.0, y: 12.0, width: 56.0, height: 56.0)
                    self.avatarLayer.backgroundColor = item.theme.list.itemAccentColor.withAlphaComponent(0.25).cgColor
                    self.onlineOuterLayer.backgroundColor = item.theme.list.itemBlocksBackgroundColor.cgColor
                    self.onlineInnerLayer.backgroundColor = item.theme.list.itemAccentColor.cgColor
                    let textWidth = max(0.0, width - 104.0)
                    let rects = [CGRect(x: 84.0, y: 17.0, width: textWidth * 0.72, height: 8.0), CGRect(x: 84.0, y: 36.0, width: textWidth, height: 7.0), CGRect(x: 84.0, y: 54.0, width: textWidth * 0.6, height: 7.0), CGRect(x: max(84.0, width - 46.0), y: 17.0, width: 30.0, height: 6.0)]
                    for (index, layer) in self.skeletonLayers.enumerated() {
                        layer.frame = rects[index]
                        layer.cornerRadius = 3.5
                        layer.backgroundColor = item.theme.list.itemSecondaryTextColor.withAlphaComponent(index == 0 ? 0.35 : 0.18).cgColor
                    }
                    self.updateAvatar(value: self.displayedValue)
                case let .chatList(title, centered, _):
                    self.headerLabel.text = title
                    self.headerLabel.textAlignment = centered ? .center : .left
                    // Symmetric reserved space keeps centered text on the header axis.
                    self.headerLabel.frame = CGRect(x: centered ? 38.0 : 18.0, y: 16.0, width: max(0.0, width - (centered ? 76.0 : 56.0)), height: 32.0)
                    for (index, layer) in self.menuLayers.enumerated() {
                        layer.frame = CGRect(x: width - 23.0, y: 23.0 + CGFloat(index) * 7.0, width: 3.0, height: 3.0)
                        layer.cornerRadius = 1.5
                        layer.backgroundColor = item.theme.list.itemPrimaryTextColor.cgColor
                    }
                }
                CATransaction.commit()
                self.updateSnowVisibility()
            })
        }
    }
}
