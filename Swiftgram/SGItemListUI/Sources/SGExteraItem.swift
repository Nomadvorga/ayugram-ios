import UIKit
import AsyncDisplayKit
import Display
import ItemListUI
import Markdown
import SwiftSignalKit
import TelegramPresentationData

/// Unknown symbols and systems before SF Symbols still render a usable text row.
func sgItemListSymbolImage(named name: String) -> UIImage? {
    if #available(iOS 13.0, *) {
        return UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24.0, weight: .regular))?.withRenderingMode(.alwaysTemplate)
    } else {
        return nil
    }
}

/// Opt-in rendering for existing SG entries. Native callers keep Telegram's own items.
public enum SGItemListVisualStyle: Equatable {
    case native
    case extera

    /// Use this for the controller's list background as well as its opaque navigation surface.
    public func backgroundColor(theme: PresentationTheme) -> UIColor {
        return theme.list.blocksBackgroundColor.withAlphaComponent(1.0)
    }

    public func cardColor(theme: PresentationTheme) -> UIColor {
        switch self {
        case .native:
            return theme.list.itemBlocksBackgroundColor
        case .extera:
            // White text over the black theme gives ~#181818, while tinted themes keep their hue.
            if theme.overallDarkAppearance {
                return self.backgroundColor(theme: theme).mixedWith(theme.list.itemPrimaryTextColor, alpha: 0.095).withAlphaComponent(1.0)
            } else {
                return theme.list.itemBlocksBackgroundColor.withAlphaComponent(1.0)
            }
        }
    }
}

/// Native fallback and extera rendering share the same reusable node and discrete control.
func sgSegmentedSelectorItem(presentationData: ItemListPresentationData, sectionId: ItemListSectionId, visualStyle: SGItemListVisualStyle, appearance: SGExteraAppearance = SGExteraAppearance(), value: Int, options: [String], enabled: Bool, updated: @escaping (Int) -> Void) -> ListViewItem {
    return SGExteraItem(presentationData: presentationData, sectionId: sectionId, visualStyle: visualStyle, appearance: appearance, title: "", content: .segmentedSelector(value: value, options: options), enabled: enabled, segmentedValueUpdated: updated)
}

/// Extera-rendered toggle row for settings entries that are not SGItemListUIEntry values.
public func sgExteraToggleItem(presentationData: ItemListPresentationData, sectionId: ItemListSectionId, appearance: SGExteraAppearance = SGExteraAppearance(), title: String, value: Bool, enabled: Bool = true, animationIdentity: AnyHashable, updated: @escaping (Bool) -> Void) -> ListViewItem {
    return SGExteraItem(presentationData: presentationData, sectionId: sectionId, appearance: appearance, title: title, content: .toggle(value), enabled: enabled, animationIdentity: animationIdentity, toggle: updated)
}

func sgSettingsPreviewItem(presentationData: ItemListPresentationData, sectionId: ItemListSectionId, visualStyle: SGItemListVisualStyle, appearance: SGExteraAppearance = SGExteraAppearance(), kind: SGSettingsPreviewKind, sliderUpdated: ((Int32) -> Void)?, selectionUpdated: ((Int) -> Void)?) -> ListViewItem {
    return SGExteraItem(presentationData: presentationData, sectionId: sectionId, visualStyle: visualStyle, appearance: appearance, title: "", content: .settingsPreview(kind), segmentedValueUpdated: selectionUpdated, sliderValueUpdated: sliderUpdated)
}

func sgAppearanceStyleItem(presentationData: ItemListPresentationData, sectionId: ItemListSectionId, visualStyle: SGItemListVisualStyle, appearance: SGExteraAppearance, value: Int, options: [String], enabled: Bool, updated: @escaping (Int) -> Void) -> ListViewItem {
    return SGExteraItem(presentationData: presentationData, sectionId: sectionId, visualStyle: visualStyle, appearance: appearance, title: "", content: .appearanceStyle(value: value, options: options), enabled: enabled, segmentedValueUpdated: updated)
}

func sgValueSliderItem(presentationData: ItemListPresentationData, sectionId: ItemListSectionId, visualStyle: SGItemListVisualStyle, appearance: SGExteraAppearance, configuration: SGItemListRangeConfiguration, interactionIdentity: AnyHashable, enabled: Bool, updated: @escaping (Int32) -> Void) -> ListViewItem {
    return SGExteraItem(presentationData: presentationData, sectionId: sectionId, visualStyle: visualStyle, appearance: appearance, title: "", content: .valueSlider(configuration), enabled: enabled, interactionIdentity: interactionIdentity, sliderValueUpdated: updated)
}

extension SGItemListUIEntry {
    func exteraItem(presentationData: ItemListPresentationData, arguments: SGItemListArguments<BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>) -> ListViewItem? {
        switch self {
        case let .header(_, _, text, badge):
            return SGExteraItem(presentationData: presentationData, sectionId: self.section, appearance: arguments.exteraAppearance, title: text, content: .header(badge))
        case let .notice(_, _, text):
            return SGExteraItem(presentationData: presentationData, sectionId: self.section, appearance: arguments.exteraAppearance, title: text, content: .notice)
        case let .toggle(_, _, setting, value, text, enabled):
            return SGExteraItem(presentationData: presentationData, sectionId: self.section, appearance: arguments.exteraAppearance, title: text, content: .toggle(value), enabled: enabled, animationIdentity: AnyHashable(self.stableId), toggle: { arguments.setBoolValue(setting, $0) })
        case let .toggleSubtitle(_, _, setting, value, text, subtitle, enabled):
            return SGExteraItem(presentationData: presentationData, sectionId: self.section, appearance: arguments.exteraAppearance, title: text, subtitle: subtitle, content: .toggle(value), enabled: enabled, animationIdentity: AnyHashable(self.stableId), toggle: { arguments.setBoolValue(setting, $0) })
        case let .expandableToggle(_, _, setting, value, text, selectedCount, totalCount, isExpanded, enabled):
            return SGExteraItem(presentationData: presentationData, sectionId: self.section, appearance: arguments.exteraAppearance, title: text, content: .expandableToggle(value: value, expanded: isExpanded, count: "\(selectedCount)/\(totalCount)"), enabled: enabled, animationIdentity: AnyHashable(self.stableId), action: {
                arguments.setExpanded(setting, !isExpanded)
            }, toggle: { arguments.setBoolValue(setting, $0) })
        case let .checkbox(_, _, setting, value, text, enabled):
            return SGExteraItem(presentationData: presentationData, sectionId: self.section, appearance: arguments.exteraAppearance, title: text, content: .checkbox(value), enabled: enabled, action: { arguments.setBoolValue(setting, !value) })
        case let .disclosure(_, _, link, text):
            return SGExteraItem(presentationData: presentationData, sectionId: self.section, appearance: arguments.exteraAppearance, title: text, content: .disclosure, action: { arguments.openDisclosureLink(link) })
        case let .disclosureSubtitle(_, _, link, text, subtitle, iconName):
            return SGExteraItem(presentationData: presentationData, sectionId: self.section, appearance: arguments.exteraAppearance, title: text, subtitle: subtitle, icon: sgItemListSymbolImage(named: iconName), content: .disclosure, action: { arguments.openDisclosureLink(link) })
        case let .oneFromManySelector(_, _, setting, text, value, enabled):
            return SGExteraItem(presentationData: presentationData, sectionId: self.section, appearance: arguments.exteraAppearance, title: text, content: .selector(value), enabled: enabled, tag: SGOneFromManyTag(setting: setting), action: {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                arguments.setOneFromManyValue(setting)
            })
        case let .segmentedSelector(_, _, setting, value, options, enabled):
            return sgSegmentedSelectorItem(presentationData: presentationData, sectionId: self.section, visualStyle: .extera, appearance: arguments.exteraAppearance, value: value, options: options, enabled: enabled, updated: { index in
                arguments.setSegmentedValue(setting, index)
            })
        case let .action(_, _, action, text, kind):
            return SGExteraItem(presentationData: presentationData, sectionId: self.section, appearance: arguments.exteraAppearance, title: text, content: .action(kind), enabled: kind != .disabled, action: {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                arguments.action(action)
            })
        case let .appearancePreview(_, _, kind, _):
            if case let .doubleTap(incomingSymbol, outgoingSymbol) = kind {
                return SGExteraItem(presentationData: presentationData, sectionId: self.section, appearance: arguments.exteraAppearance, title: "", content: .doubleTap(incomingSymbol: incomingSymbol, outgoingSymbol: outgoingSymbol))
            }
            return nil
        case .percentageSlider, .peerColorDisclosurePreview, .searchInput, .settingsPreview, .appearanceStyle, .valueSlider:
            return nil
        }
    }
}

private enum SGExteraContent {
    case header(String?)
    case notice
    case toggle(Bool)
    case expandableToggle(value: Bool, expanded: Bool, count: String)
    case checkbox(Bool)
    case disclosure
    case selector(String)
    case action(ItemListActionKind)
    case doubleTap(incomingSymbol: String, outgoingSymbol: String)
    case segmentedSelector(value: Int, options: [String])
    case settingsPreview(SGSettingsPreviewKind)
    case appearanceStyle(value: Int, options: [String])
    case valueSlider(SGItemListRangeConfiguration)

    var isCard: Bool {
        switch self {
        case .header, .notice: return false
        default: return true
        }
    }

    var isCheckbox: Bool {
        if case .checkbox = self { return true }
        return false
    }

    var toggleValue: Bool? {
        switch self {
        case let .toggle(value), let .expandableToggle(value, _, _): return value
        default: return nil
        }
    }

    var isPreview: Bool {
        if case .doubleTap = self { return true }
        return false
    }

    var isSegmented: Bool {
        if case .segmentedSelector = self { return true }
        return false
    }

    var isSettingsPreview: Bool {
        if case .settingsPreview = self { return true }
        return false
    }

    var isHeader: Bool {
        if case .header = self { return true }
        return false
    }

    var isStyleControl: Bool {
        if case .appearanceStyle = self { return true }
        return false
    }

    var isRangeControl: Bool {
        if case .valueSlider = self { return true }
        return false
    }

    var hasEmbeddedControl: Bool {
        return self.isSegmented || self.isSettingsPreview || self.isStyleControl || self.isRangeControl
    }

}

/// Every fact used to join cards or indent a neighbour's separator belongs in this descriptor.
private struct SGExteraNeighbor: Equatable, ItemListNeighborFacet {
    let sectionId: ItemListSectionId
    let visualStyle: SGItemListVisualStyle
    let appearance: SGExteraAppearance
    let isCard: Bool
    let isCheckbox: Bool
    let isTextItem: Bool
    let isHeader: Bool
    var isAlwaysPlain: Bool { return !self.isCard }
    var requestsNoInset: Bool { return false }
    var hasActiveRevealOptions: Bool { return false }
}

private final class SGExteraItem: ListViewItem, ItemListItem {
    let presentationData: ItemListPresentationData
    let sectionId: ItemListSectionId
    let visualStyle: SGItemListVisualStyle
    let appearance: SGExteraAppearance
    let title: String
    let subtitle: String?
    let icon: UIImage?
    let content: SGExteraContent
    let enabled: Bool
    let tag: ItemListItemTag?
    let animationIdentity: AnyHashable?
    let action: (() -> Void)?
    let toggle: ((Bool) -> Void)?
    let segmentedValueUpdated: ((Int) -> Void)?
    let sliderValueUpdated: ((Int32) -> Void)?
    let interactionIdentity: AnyHashable?

    var isCard: Bool {
        if case .header = self.content { return self.visualStyle == .extera && !self.appearance.separateHeaders }
        return self.content.isCard
    }
    var isAlwaysPlain: Bool { return !self.isCard }
    var approximateHeight: CGFloat {
        if case .appearanceStyle = self.content { return SGAppearanceStyleControl.height(width: 320.0) }
        if case .valueSlider = self.content { return SGItemListRangeControl.height(baseSize: self.presentationData.fontSize.itemListBaseFontSize) }
        if case let .settingsPreview(kind) = self.content {
            return SGSettingsPreviewGeometry.height(kind: kind, width: 320.0, baseSize: self.presentationData.fontSize.itemListBaseFontSize)
        }
        return self.content.isPreview ? 190.0 : (self.content.isSegmented ? 80.0 : 54.0)
    }
    var neighborDescriptor: AnyEquatable {
        let isText: Bool
        if case .notice = self.content { isText = true } else { isText = false }
        let isHeader: Bool
        if case .header = self.content { isHeader = true } else { isHeader = false }
        return AnyEquatable(SGExteraNeighbor(sectionId: self.sectionId, visualStyle: self.visualStyle, appearance: self.appearance, isCard: self.isCard, isCheckbox: self.content.isCheckbox, isTextItem: isText, isHeader: isHeader))
    }

    init(presentationData: ItemListPresentationData, sectionId: ItemListSectionId, visualStyle: SGItemListVisualStyle = .extera, appearance: SGExteraAppearance = SGExteraAppearance(), title: String, subtitle: String? = nil, icon: UIImage? = nil, content: SGExteraContent, enabled: Bool = true, interactionIdentity: AnyHashable? = nil, animationIdentity: AnyHashable? = nil, tag: ItemListItemTag? = nil, action: (() -> Void)? = nil, toggle: ((Bool) -> Void)? = nil, segmentedValueUpdated: ((Int) -> Void)? = nil, sliderValueUpdated: ((Int32) -> Void)? = nil) {
        self.presentationData = presentationData
        self.sectionId = sectionId
        self.visualStyle = visualStyle
        self.appearance = appearance
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content
        self.enabled = enabled
        self.tag = tag
        self.animationIdentity = animationIdentity
        self.action = action
        self.toggle = toggle
        self.segmentedValueUpdated = segmentedValueUpdated
        self.sliderValueUpdated = sliderValueUpdated
        self.interactionIdentity = interactionIdentity
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = SGExteraItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, neighbors)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            Queue.mainQueue().async { completion(node, { (nil, { _ in apply() }) }) }
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? SGExteraItemNode else { return }
            let makeLayout = node.asyncLayout()
            async {
                let (layout, apply) = makeLayout(self, params, neighbors)
                Queue.mainQueue().async { completion(layout, { _ in apply() }) }
            }
        }
    }
}

/// UIKit children are allocated once, on main. The ListView owns this node's frame.
final class SGExteraItemNode: ListViewItemNode, SGOneFromManySourceNode {
    private lazy var surface = UIView()
    private lazy var titleLabel = UILabel()
    private lazy var subtitleLabel = UILabel()
    private lazy var valueLabel = UILabel()
    private lazy var badgeLabel = UILabel()
    private lazy var iconView = UIImageView()
    private var doubleTapPreview: AyuDoubleTapPreviewView?
    private var segmentedControl: SGDiscreteSelectorControl?
    private var settingsPreview: SGSettingsPreviewView?
    private var styleControl: SGAppearanceStyleControl?
    private var rangeControl: SGItemListRangeControl?
    private lazy var rowButton = UIButton(type: .custom)
    private lazy var toggleButton = UIButton(type: .custom)
    private lazy var separator = UIView()
    private lazy var verticalSeparator = UIView()
    private lazy var arrowLayer = CAShapeLayer()
    private lazy var trackLayer = CAShapeLayer()
    private lazy var thumbLayer = CAShapeLayer()
    private lazy var checkLayer = CAShapeLayer()
    private lazy var markLayer = CAShapeLayer()
    private var created = false
    private var item: SGExteraItem?
    private var hasContextMenu = false

    var tag: ItemListItemTag? { return self.item?.tag }
    var oneFromManySourceView: UIView { return self.valueLabel }

    init() {
        super.init(layerBacked: false)
    }

    private func createContent() {
        guard !self.created else { return }
        self.created = true
        self.view.addSubview(self.surface)
        self.surface.isUserInteractionEnabled = false
        self.surface.clipsToBounds = true
        if #available(iOS 13.0, *) { self.surface.layer.cornerCurve = .continuous }
        for label in [self.titleLabel, self.subtitleLabel, self.valueLabel, self.badgeLabel] {
            self.surface.addSubview(label)
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.isAccessibilityElement = false
        }
        self.surface.addSubview(self.iconView)
        self.iconView.contentMode = .scaleAspectFit
        self.iconView.isAccessibilityElement = false
        self.surface.addSubview(self.separator)
        self.surface.addSubview(self.verticalSeparator)
        for layer in [self.arrowLayer, self.checkLayer, self.markLayer] { self.surface.layer.addSublayer(layer) }
        self.view.addSubview(self.rowButton)
        self.view.addSubview(self.toggleButton)
        // iOS 27 can skip touch delivery to a completely contentless layer. Keep a
        // transparent image on the activation surface (see repository CLAUDE.md).
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1.0
        let activationImage = UIGraphicsImageRenderer(size: CGSize(width: 1.0, height: 1.0), format: format).image { context in
            context.cgContext.clear(CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0))
        }
        self.rowButton.setBackgroundImage(activationImage, for: .normal)
        self.toggleButton.layer.addSublayer(self.trackLayer)
        self.toggleButton.layer.addSublayer(self.thumbLayer)
        self.rowButton.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
        self.toggleButton.addTarget(self, action: #selector(self.togglePressed), for: .touchUpInside)
        self.rowButton.addTarget(self, action: #selector(self.touchDown), for: [.touchDown, .touchDragEnter])
        self.rowButton.addTarget(self, action: #selector(self.touchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        self.badgeLabel.textAlignment = .center
        self.badgeLabel.layer.cornerRadius = 5.0
        self.badgeLabel.clipsToBounds = true
        self.arrowLayer.lineWidth = 1.5
        self.arrowLayer.lineCap = .round
        self.arrowLayer.lineJoin = .round
        self.arrowLayer.fillColor = UIColor.clear.cgColor
        self.markLayer.lineWidth = 2.0
        self.markLayer.lineCap = .round
        self.markLayer.lineJoin = .round
        self.markLayer.fillColor = UIColor.clear.cgColor
    }

    func updateHasContextMenu(hasContextMenu value: Bool) {
        self.hasContextMenu = value
        self.valueLabel.alpha = (self.item?.enabled == false ? 0.45 : 1.0) * (value ? 0.55 : 1.0)
    }

    func displayHighlight() {
        guard self.created else { return }
        self.touchDown()
        UIView.animate(withDuration: 0.25, animations: { self.touchUp() })
    }

    @objc private func touchDown() {
        guard let item = self.item, item.enabled, item.content.isCard else { return }
        self.surface.backgroundColor = item.visualStyle.cardColor(theme: item.presentationData.theme).mixedWith(item.presentationData.theme.list.itemPrimaryTextColor, alpha: 0.06)
    }

    @objc private func touchUp() {
        guard let item = self.item else { return }
        self.surface.backgroundColor = item.isCard ? item.visualStyle.cardColor(theme: item.presentationData.theme) : .clear
    }

    @objc private func pressed() {
        guard let item = self.item, item.enabled else { return }
        if case let .toggle(value) = item.content {
            item.toggle?(!value)
        } else {
            item.action?()
        }
    }

    @objc private func togglePressed() {
        guard let item = self.item, item.enabled, let value = item.content.toggleValue else { return }
        item.toggle?(!value)
    }

    fileprivate func asyncLayout() -> (SGExteraItem, ListViewItemLayoutParams, ListViewItemNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { [weak self] item, params, neighbors in
            let theme = item.presentationData.theme
            let baseSize = item.presentationData.fontSize.itemListBaseFontSize
            let isCard = item.isCard
            let previous = neighbors.previous?.base(SGExteraNeighbor.self)
            let next = neighbors.next?.base(SGExteraNeighbor.self)
            let topFacet = neighbors.previous?.base(ItemListNeighborFacet.self)
            let bottomFacet = neighbors.next?.base(ItemListNeighborFacet.self)
            let joinsTop: Bool
            let joinsBottom: Bool
            if item.visualStyle == .native {
                joinsTop = isCard && topFacet?.sectionId == item.sectionId && topFacet?.isAlwaysPlain == false
                joinsBottom = isCard && bottomFacet?.sectionId == item.sectionId && bottomFacet?.isAlwaysPlain == false
            } else {
                joinsTop = isCard && previous?.visualStyle == .extera && previous?.appearance == item.appearance && previous?.isCard == true && previous?.sectionId == item.sectionId
                joinsBottom = isCard && next?.visualStyle == .extera && next?.appearance == item.appearance && next?.isCard == true && next?.sectionId == item.sectionId
            }
            // ItemListController reserves a minimum 16pt band and larger safe/Duo/iPad insets.
            // Never draw under its side overlays just to shave three points off the reference margin.
            let left = max(13.0, params.leftInset)
            let right = max(13.0, params.rightInset)
            let width = max(1.0, params.width - left - right)
            let textInset: CGFloat = isCard ? 22.0 : 13.0
            let iconSize: CGFloat = 24.0
            let titleX: CGFloat = item.content.isCheckbox ? 106.0 : textInset + (item.icon == nil ? 0.0 : iconSize + 22.0)
            let titleFont: UIFont
            let textColor: UIColor
            var value: String?
            var badge: String?
            var accessoryWidth: CGFloat = 0.0
            switch item.content {
            case let .header(text):
                titleFont = Font.medium(baseSize * 0.82)
                textColor = theme.list.itemAccentColor
                badge = text
            case .notice:
                titleFont = Font.regular(baseSize * 0.82)
                textColor = theme.list.itemSecondaryTextColor
            case .toggle:
                titleFont = Font.regular(baseSize)
                textColor = theme.list.itemPrimaryTextColor
                accessoryWidth = 70.0
            case let .expandableToggle(_, _, count):
                titleFont = Font.regular(baseSize)
                textColor = theme.list.itemPrimaryTextColor
                value = count
                accessoryWidth = 112.0
            case let .selector(text):
                titleFont = Font.regular(baseSize)
                textColor = theme.list.itemPrimaryTextColor
                value = text
            case .disclosure:
                titleFont = Font.regular(baseSize)
                textColor = theme.list.itemPrimaryTextColor
                accessoryWidth = 18.0
            case let .action(kind):
                titleFont = Font.regular(baseSize)
                switch kind {
                case .generic: textColor = theme.list.itemAccentColor
                case .destructive: textColor = theme.list.itemDestructiveColor
                case .neutral: textColor = theme.list.itemPrimaryTextColor
                case .disabled: textColor = theme.list.itemDisabledTextColor
                }
            case .checkbox, .doubleTap, .segmentedSelector, .settingsPreview, .appearanceStyle, .valueSlider:
                titleFont = Font.regular(baseSize)
                textColor = theme.list.itemPrimaryTextColor
            }
            let valueFont = Font.regular(baseSize)
            let subtitleFont = Font.regular(baseSize * 0.82)
            let badgeFont = Font.semibold(baseSize * 0.65)
            let titleLineLimit = !isCard || item.content.isHeader || item.content.isCheckbox || baseSize > 22.0 ? 0 : 1
            let subtitleLineLimit = baseSize > 22.0 ? 0 : 2
            let attributedTitle: NSAttributedString
            if case .notice = item.content {
                attributedTitle = parseMarkdownIntoAttributedString(item.title, attributes: MarkdownAttributes(body: MarkdownAttributeSet(font: titleFont, textColor: textColor), bold: MarkdownAttributeSet(font: Font.semibold(titleFont.pointSize), textColor: textColor), link: MarkdownAttributeSet(font: titleFont, textColor: theme.list.itemAccentColor), linkAttribute: { _ in nil }))
            } else {
                attributedTitle = NSAttributedString(string: item.title, attributes: [.font: titleFont, .foregroundColor: textColor])
            }
            func measure(_ text: NSAttributedString, width: CGFloat, font: UIFont, lineLimit: Int) -> CGSize {
                guard text.length != 0 else { return .zero }
                let constrainedWidth = max(1.0, width)
                let constrainedHeight = lineLimit == 0 ? 10000.0 : ceil(font.lineHeight * CGFloat(lineLimit))
                let options: NSStringDrawingOptions = lineLimit == 0 ? [.usesLineFragmentOrigin, .usesFontLeading] : [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
                let rect = text.boundingRect(with: CGSize(width: constrainedWidth, height: constrainedHeight), options: options, context: nil)
                return CGSize(width: min(constrainedWidth, ceil(rect.width)), height: min(constrainedHeight, ceil(rect.height)))
            }
            let badgeSize = badge.map { measure(NSAttributedString(string: $0, attributes: [.font: badgeFont]), width: width * 0.3, font: badgeFont, lineLimit: 1) } ?? .zero
            let badgeWidth = badge == nil ? 0.0 : badgeSize.width + 16.0
            let valueLimit = max(1.0, (width - titleX - textInset - accessoryWidth) * 0.45)
            let valueSize = value.map { measure(NSAttributedString(string: $0, attributes: [.font: valueFont]), width: valueLimit, font: valueFont, lineLimit: 1) } ?? .zero
            let valueWidth = value == nil ? 0.0 : valueSize.width + 12.0
            let titleWidth = max(1.0, width - titleX - textInset - accessoryWidth - valueWidth - badgeWidth)
            let titleSize = measure(attributedTitle, width: titleWidth, font: titleFont, lineLimit: titleLineLimit)
            let subtitleText = item.subtitle.map { NSAttributedString(string: $0, attributes: [.font: subtitleFont, .foregroundColor: theme.list.itemSecondaryTextColor]) }
            let subtitleSize = subtitleText.map { measure($0, width: titleWidth, font: subtitleFont, lineLimit: subtitleLineLimit) } ?? .zero
            let textHeight = titleSize.height + (subtitleText == nil ? 0.0 : 5.0 + subtitleSize.height)
            let height: CGFloat
            let topInset: CGFloat
            let bottomInset: CGFloat
            switch item.content {
            case .header:
                height = max(38.0, titleSize.height + 20.0)
                topInset = params.isStandalone || joinsTop ? 0.0 : (neighbors.previous == nil ? 8.0 : 22.0)
                bottomInset = isCard && neighbors.next == nil && !params.isStandalone ? 24.0 : 0.0
            case .notice:
                height = titleSize.height + 20.0
                topInset = 0.0
                bottomInset = neighbors.next == nil && !params.isStandalone ? 20.0 : 0.0
            default:
                if case let .segmentedSelector(_, options) = item.content {
                    height = SGDiscreteSelectorControl.height(options: options, width: max(1.0, width - 44.0), baseSize: baseSize)
                } else if case let .settingsPreview(kind) = item.content {
                    height = SGSettingsPreviewGeometry.height(kind: kind, width: width, baseSize: baseSize)
                } else if case .appearanceStyle = item.content {
                    height = SGAppearanceStyleControl.height(width: width)
                } else if case .valueSlider = item.content {
                    height = SGItemListRangeControl.height(baseSize: baseSize)
                } else {
                    height = item.content.isPreview ? 190.0 : max(54.0, max(textHeight, valueSize.height) + 22.0)
                }
                let followsHeader = previous?.isHeader == true && previous?.appearance == item.appearance && previous?.sectionId == item.sectionId
                topInset = params.isStandalone || joinsTop || followsHeader ? 0.0 : 12.0
                bottomInset = neighbors.next == nil && !params.isStandalone ? 24.0 : 0.0
            }
            let insets = item.visualStyle == .native ? itemListNeighborsGroupedInsets(itemListNeighbors(item: item, topFacet: topFacet, bottomFacet: bottomFacet), params) : UIEdgeInsets(top: topInset, left: 0.0, bottom: bottomInset, right: 0.0)
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: insets)
            return (layout, { [weak self] in
                guard let self else { return }
                let animateToggle: Bool
                if let previousItem = self.item,
                   let animationIdentity = item.animationIdentity,
                   previousItem.animationIdentity == animationIdentity,
                   let previousValue = previousItem.content.toggleValue,
                   let currentValue = item.content.toggleValue,
                   previousValue != currentValue {
                    animateToggle = !UIAccessibility.isReduceMotionEnabled
                } else {
                    animateToggle = false
                }
                self.createContent()
                self.item = item
                self.view.isAccessibilityElement = false
                self.surface.frame = CGRect(x: left, y: 0.0, width: width, height: height)
                self.surface.backgroundColor = isCard ? item.visualStyle.cardColor(theme: theme).withAlphaComponent(1.0) : .clear
                self.surface.layer.cornerRadius = isCard ? (item.visualStyle == .extera ? item.appearance.radius : 11.0) : 0.0
                var corners: CACornerMask = []
                if !joinsTop { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
                if !joinsBottom { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
                self.surface.layer.maskedCorners = corners
                self.settingsPreview?.isHidden = !item.content.isSettingsPreview
                if !item.content.isSettingsPreview {
                    self.settingsPreview?.sliderUpdated = nil
                    self.settingsPreview?.selectionUpdated = nil
                }
                if case let .settingsPreview(kind) = item.content {
                    let preview: SGSettingsPreviewView
                    if let current = self.settingsPreview {
                        preview = current
                    } else {
                        preview = SGSettingsPreviewView(frame: .zero)
                        self.settingsPreview = preview
                        self.view.addSubview(preview)
                    }
                    preview.frame = self.surface.frame
                    preview.layer.cornerRadius = self.surface.layer.cornerRadius
                    preview.layer.maskedCorners = corners
                    if #available(iOS 13.0, *) { preview.layer.cornerCurve = .continuous }
                    preview.sliderUpdated = item.sliderValueUpdated == nil ? nil : { [weak self] value in
                        self?.item?.sliderValueUpdated?(value)
                    }
                    preview.selectionUpdated = item.segmentedValueUpdated == nil ? nil : { [weak self] value in
                        self?.item?.segmentedValueUpdated?(value)
                    }
                    preview.update(kind: kind, theme: theme, style: item.visualStyle, baseSize: baseSize)
                }
                self.doubleTapPreview?.isHidden = !item.content.isPreview
                if case let .doubleTap(incomingSymbol, outgoingSymbol) = item.content {
                    let preview: AyuDoubleTapPreviewView
                    if let current = self.doubleTapPreview {
                        preview = current
                    } else {
                        preview = AyuDoubleTapPreviewView(frame: .zero)
                        self.doubleTapPreview = preview
                        self.surface.insertSubview(preview, at: 0)
                    }
                    preview.frame = self.surface.bounds
                    preview.update(theme: theme, visualStyle: .extera, incomingSymbol: incomingSymbol, outgoingSymbol: outgoingSymbol)
                }
                self.segmentedControl?.isHidden = !item.content.isSegmented
                if case let .segmentedSelector(value, options) = item.content {
                    let control: SGDiscreteSelectorControl
                    if let current = self.segmentedControl {
                        control = current
                    } else {
                        control = SGDiscreteSelectorControl(frame: .zero)
                        self.segmentedControl = control
                        self.view.addSubview(control)
                    }
                    control.frame = CGRect(x: left + 22.0, y: 0.0, width: max(1.0, width - 44.0), height: height)
                    control.valueChanged = { [weak self] index in
                        guard let item = self?.item, item.enabled else { return }
                        item.segmentedValueUpdated?(index)
                    }
                    control.update(theme: theme, visualStyle: item.visualStyle, baseSize: baseSize, value: value, options: options, enabled: item.enabled)
                }
                self.styleControl?.isHidden = !item.content.isStyleControl
                self.rangeControl?.isHidden = !item.content.isRangeControl
                if !item.content.isStyleControl { self.styleControl?.updated = nil }
                if !item.content.isRangeControl {
                    self.rangeControl?.updated = nil
                    self.rangeControl?.cancelTracking(with: nil)
                }
                if case let .appearanceStyle(value, options) = item.content {
                    let control: SGAppearanceStyleControl
                    if let current = self.styleControl {
                        control = current
                    } else {
                        control = SGAppearanceStyleControl(frame: .zero)
                        self.styleControl = control
                        self.view.addSubview(control)
                    }
                    control.frame = self.surface.frame
                    control.updated = { [weak self] value in
                        guard let item = self?.item, item.enabled else { return }
                        item.segmentedValueUpdated?(value)
                    }
                    control.update(value: value, options: options, enabled: item.enabled, theme: theme, visualStyle: item.visualStyle)
                }
                if case let .valueSlider(configuration) = item.content {
                    let control: SGItemListRangeControl
                    if let current = self.rangeControl {
                        control = current
                    } else {
                        control = SGItemListRangeControl(frame: .zero)
                        self.rangeControl = control
                        self.view.addSubview(control)
                    }
                    control.frame = CGRect(x: left + 22.0, y: 0.0, width: max(1.0, width - 44.0), height: height)
                    control.updated = { [weak self] value in
                        guard let item = self?.item, item.enabled else { return }
                        item.sliderValueUpdated?(value)
                    }
                    control.update(configuration: configuration, interactionIdentity: item.interactionIdentity, theme: theme, visualStyle: item.visualStyle, baseSize: baseSize, enabled: item.enabled)
                }
                // The card remains opaque even when its controls are disabled.
                for label in [self.titleLabel, self.subtitleLabel, self.badgeLabel] {
                    label.alpha = item.enabled ? 1.0 : 0.45
                }
                self.iconView.image = item.icon
                self.iconView.isHidden = item.icon == nil
                self.iconView.tintColor = theme.list.itemSecondaryTextColor
                self.iconView.alpha = item.enabled ? 1.0 : 0.45
                self.iconView.frame = CGRect(x: textInset, y: floor((height - iconSize) / 2.0), width: iconSize, height: iconSize)
                self.titleLabel.attributedText = attributedTitle
                self.titleLabel.numberOfLines = titleLineLimit
                self.titleLabel.lineBreakMode = titleLineLimit == 0 ? .byWordWrapping : .byTruncatingTail
                self.titleLabel.frame = CGRect(x: titleX, y: floor((height - textHeight) / 2.0), width: titleWidth, height: titleSize.height)
                self.subtitleLabel.attributedText = subtitleText
                self.subtitleLabel.numberOfLines = subtitleLineLimit
                self.subtitleLabel.lineBreakMode = subtitleLineLimit == 0 ? .byWordWrapping : .byTruncatingTail
                self.subtitleLabel.frame = CGRect(x: titleX, y: self.titleLabel.frame.maxY + 5.0, width: titleWidth, height: subtitleSize.height)
                self.subtitleLabel.isHidden = subtitleText == nil
                self.valueLabel.font = valueFont
                self.valueLabel.numberOfLines = 1
                self.valueLabel.lineBreakMode = .byTruncatingTail
                self.valueLabel.text = value
                self.valueLabel.textColor = theme.list.itemAccentColor
                if case .expandableToggle = item.content { self.valueLabel.textColor = theme.list.itemPrimaryTextColor }
                self.valueLabel.textAlignment = .right
                self.valueLabel.frame = CGRect(x: width - textInset - accessoryWidth - valueSize.width, y: floor((height - valueSize.height) / 2.0), width: valueSize.width, height: valueSize.height)
                self.valueLabel.isHidden = value == nil
                self.valueLabel.alpha = (item.enabled ? 1.0 : 0.45) * (self.hasContextMenu ? 0.55 : 1.0)
                self.badgeLabel.text = badge
                self.badgeLabel.font = badgeFont
                self.badgeLabel.numberOfLines = 1
                self.badgeLabel.lineBreakMode = .byTruncatingTail
                self.badgeLabel.textColor = theme.list.itemCheckColors.foregroundColor
                self.badgeLabel.backgroundColor = theme.list.itemAccentColor
                self.badgeLabel.frame = CGRect(x: min(width - textInset - badgeWidth, self.titleLabel.frame.minX + titleSize.width + 8.0), y: floor((height - badgeSize.height - 6.0) / 2.0), width: max(0.0, badgeWidth - 4.0), height: badgeSize.height + 6.0)
                self.badgeLabel.isHidden = badge == nil
                let edgeSeparator = item.content.isPreview || item.content.isSettingsPreview || item.content.isStyleControl || item.content.isRangeControl || (item.visualStyle == .extera && item.appearance.separatorStyle == .fullWidth)
                let separatorX: CGFloat = edgeSeparator ? 0.0 : (item.content.isCheckbox && next?.isCheckbox == true ? 106.0 : (item.icon == nil ? 22.0 : titleX))
                // A settings illustration lives above the surface to receive control touches.
                // Keep the separator in the node so it remains visible above that illustration.
                if item.content.hasEmbeddedControl {
                    self.view.addSubview(self.separator)
                } else if self.separator.superview !== self.surface {
                    self.surface.addSubview(self.separator)
                }
                self.separator.frame = CGRect(x: separatorX, y: height - UIScreenPixel, width: max(0.0, width - separatorX), height: UIScreenPixel)
                if item.content.hasEmbeddedControl { self.separator.frame.origin.x += left }
                self.separator.backgroundColor = item.visualStyle.backgroundColor(theme: theme).mixedWith(theme.list.itemPrimaryTextColor, alpha: theme.overallDarkAppearance ? 0.025 : 0.1)
                self.separator.isHidden = !joinsBottom || (item.visualStyle == .extera && (item.appearance.separatorStyle == .none || item.content.isHeader))
                self.rowButton.frame = CGRect(x: left, y: 0.0, width: width, height: height)
                self.rowButton.isEnabled = item.enabled
                self.rowButton.isHidden = item.content.isPreview || item.content.hasEmbeddedControl
                self.rowButton.isUserInteractionEnabled = isCard && (item.action != nil || item.toggle != nil) && !self.rowButton.isHidden
                self.rowButton.isAccessibilityElement = !self.rowButton.isHidden
                self.rowButton.accessibilityLabel = [attributedTitle.string, item.subtitle, badge].compactMap { $0 }.joined(separator: ", ")
                self.rowButton.accessibilityValue = value
                self.rowButton.accessibilityHint = nil
                self.rowButton.accessibilityTraits = isCard ? .button : .staticText
                if case .header = item.content { self.rowButton.accessibilityTraits = .header }
                if !item.enabled { self.rowButton.accessibilityTraits.insert(.notEnabled) }
                if case let .checkbox(checked) = item.content, checked { self.rowButton.accessibilityTraits.insert(.selected) }
                self.toggleButton.isHidden = item.content.toggleValue == nil
                self.toggleButton.isEnabled = item.enabled
                self.toggleButton.alpha = item.enabled ? 1.0 : 0.45
                self.toggleButton.frame = CGRect(x: left + width - 72.0, y: floor((height - 44.0) / 2.0), width: 66.0, height: 44.0)
                self.toggleButton.accessibilityLabel = item.title
                self.toggleButton.accessibilityHint = item.presentationData.strings.VoiceOver_Common_SwitchHint
                self.toggleButton.accessibilityTraits = item.enabled ? .button : [.button, .notEnabled]
                self.toggleButton.isAccessibilityElement = false
                self.arrowLayer.isHidden = true
                self.verticalSeparator.isHidden = true
                self.checkLayer.isHidden = true
                self.markLayer.isHidden = true
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for layer in [self.arrowLayer, self.checkLayer, self.markLayer] {
                    layer.opacity = item.enabled ? 1.0 : 0.45
                }
                if let toggleValue = item.content.toggleValue {
                    let state = toggleValue ? item.presentationData.strings.VoiceOver_Common_On : item.presentationData.strings.VoiceOver_Common_Off
                    self.toggleButton.accessibilityValue = state
                    self.updateToggle(value: toggleValue, theme: theme, style: item.appearance.controlStyle, animated: animateToggle)
                    switch item.content {
                    case let .expandableToggle(_, expanded, _):
                        // Expansion and the setting itself are distinct accessibility elements and touch targets.
                        self.rowButton.frame.size.width = max(0.0, width - 78.0)
                        self.toggleButton.isAccessibilityElement = true
                        self.rowButton.accessibilityTraits = .button
                        self.rowButton.accessibilityHint = expanded ? item.presentationData.strings.VoiceOver_Common_Collapse : item.presentationData.strings.VoiceOver_Common_Expand
                        if !item.enabled { self.rowButton.accessibilityTraits.insert(.notEnabled) }
                        self.verticalSeparator.isHidden = false
                        self.verticalSeparator.backgroundColor = self.separator.backgroundColor
                        self.verticalSeparator.frame = CGRect(x: width - 81.0, y: floor((height - 24.0) / 2.0), width: UIScreenPixel, height: 24.0)
                        self.updateArrow(x: width - 104.0, y: height / 2.0, expanded: expanded, disclosure: false, color: theme.list.itemPrimaryTextColor)
                    default:
                        self.rowButton.accessibilityValue = state
                        self.rowButton.accessibilityHint = item.presentationData.strings.VoiceOver_Common_SwitchHint
                    }
                }
                if case .disclosure = item.content {
                    self.updateArrow(x: width - 26.0, y: height / 2.0, expanded: false, disclosure: true, color: theme.list.itemSecondaryTextColor)
                }
                if case let .checkbox(checked) = item.content {
                    self.checkLayer.isHidden = false
                    self.checkLayer.path = UIBezierPath(ovalIn: CGRect(x: 66.0, y: height / 2.0 - 10.0, width: 20.0, height: 20.0)).cgPath
                    self.checkLayer.fillColor = checked ? theme.list.itemAccentColor.cgColor : UIColor.clear.cgColor
                    self.checkLayer.strokeColor = checked ? theme.list.itemAccentColor.cgColor : theme.list.itemSecondaryTextColor.cgColor
                    self.checkLayer.lineWidth = 1.8
                    self.markLayer.isHidden = !checked
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: 71.0, y: height / 2.0))
                    path.addLine(to: CGPoint(x: 75.0, y: height / 2.0 + 4.0))
                    path.addLine(to: CGPoint(x: 82.0, y: height / 2.0 - 4.0))
                    self.markLayer.path = path.cgPath
                    self.markLayer.strokeColor = theme.list.itemCheckColors.foregroundColor.cgColor
                }
                CATransaction.commit()
                if item.content.isSettingsPreview, let preview = self.settingsPreview {
                    self.view.accessibilityElements = [preview]
                } else if item.content.isPreview {
                    self.view.accessibilityElements = []
                } else if item.content.isSegmented, let control = self.segmentedControl {
                    self.view.accessibilityElements = [control]
                } else if item.content.isStyleControl, let control = self.styleControl {
                    self.view.accessibilityElements = [control]
                } else if item.content.isRangeControl, let control = self.rangeControl {
                    self.view.accessibilityElements = [control]
                } else {
                    self.view.accessibilityElements = self.toggleButton.isAccessibilityElement ? [self.rowButton, self.toggleButton] : [self.rowButton]
                }
            })
        }
    }

    private func updateArrow(x: CGFloat, y: CGFloat, expanded: Bool, disclosure: Bool, color: UIColor) {
        let path = UIBezierPath()
        if disclosure {
            path.move(to: CGPoint(x: x - 2.0, y: y - 4.0))
            path.addLine(to: CGPoint(x: x + 2.0, y: y))
            path.addLine(to: CGPoint(x: x - 2.0, y: y + 4.0))
        } else {
            let direction: CGFloat = expanded ? -1.0 : 1.0
            path.move(to: CGPoint(x: x - 5.0, y: y - 2.0 * direction))
            path.addLine(to: CGPoint(x: x, y: y + 2.0 * direction))
            path.addLine(to: CGPoint(x: x + 5.0, y: y - 2.0 * direction))
        }
        self.arrowLayer.isHidden = false
        self.arrowLayer.path = path.cgPath
        self.arrowLayer.strokeColor = color.cgColor
    }

    private func updateToggle(value: Bool, theme: PresentationTheme, style: SGExteraAppearance.ControlStyle, animated: Bool) {
        let rect = CGRect(x: 10.0, y: 8.0, width: 46.0, height: 28.0)
        let trackPath = UIBezierPath(roundedRect: rect, cornerRadius: 14.0).cgPath
        let oldTrackPath = self.trackLayer.presentation()?.path ?? self.trackLayer.path
        let oldTrackFill = self.trackLayer.presentation()?.fillColor ?? self.trackLayer.fillColor
        let oldTrackLineWidth = self.trackLayer.presentation()?.lineWidth ?? self.trackLayer.lineWidth
        let oldThumbPath = self.thumbLayer.presentation()?.path ?? self.thumbLayer.path
        let oldThumbFill = self.thumbLayer.presentation()?.fillColor ?? self.thumbLayer.fillColor
        self.trackLayer.path = trackPath
        self.trackLayer.lineWidth = value || style == .classic ? 0.0 : 1.8
        self.trackLayer.fillColor = value ? theme.list.itemAccentColor.cgColor : theme.list.itemPrimaryTextColor.withAlphaComponent(theme.overallDarkAppearance ? 0.14 : 0.08).cgColor
        self.trackLayer.strokeColor = theme.list.itemSecondaryTextColor.cgColor
        let diameter: CGFloat = style == .classic ? 23.0 : (value ? 21.0 : 14.0)
        let centerX: CGFloat = value ? rect.maxX - 14.0 : rect.minX + 14.0
        let thumbPath = UIBezierPath(ovalIn: CGRect(x: centerX - diameter / 2.0, y: rect.midY - diameter / 2.0, width: diameter, height: diameter)).cgPath
        self.thumbLayer.path = thumbPath
        self.thumbLayer.fillColor = style == .classic ? theme.list.itemCheckColors.foregroundColor.cgColor : (value ? SGItemListVisualStyle.extera.cardColor(theme: theme).cgColor : theme.list.itemSecondaryTextColor.cgColor)

        guard animated else { return }
        let duration: CFTimeInterval = 0.24
        let timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if let oldTrackPath {
            self.addToggleAnimation(layer: self.trackLayer, keyPath: "path", from: oldTrackPath, to: trackPath, duration: duration, timingFunction: timingFunction)
        }
        if let oldTrackFill, let trackFill = self.trackLayer.fillColor {
            self.addToggleAnimation(layer: self.trackLayer, keyPath: "fillColor", from: oldTrackFill, to: trackFill, duration: duration, timingFunction: timingFunction)
        }
        self.addToggleAnimation(layer: self.trackLayer, keyPath: "lineWidth", from: oldTrackLineWidth, to: self.trackLayer.lineWidth, duration: duration, timingFunction: timingFunction)
        if let oldThumbPath {
            self.addToggleAnimation(layer: self.thumbLayer, keyPath: "path", from: oldThumbPath, to: thumbPath, duration: duration, timingFunction: timingFunction)
        }
        if let oldThumbFill, let thumbFill = self.thumbLayer.fillColor {
            self.addToggleAnimation(layer: self.thumbLayer, keyPath: "fillColor", from: oldThumbFill, to: thumbFill, duration: duration, timingFunction: timingFunction)
        }
    }

    private func addToggleAnimation(layer: CALayer, keyPath: String, from: Any, to: Any, duration: CFTimeInterval, timingFunction: CAMediaTimingFunction) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timingFunction
        layer.add(animation, forKey: "exteraToggle.\(keyPath)")
    }
}
