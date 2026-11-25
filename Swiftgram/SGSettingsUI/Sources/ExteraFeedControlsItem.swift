import AsyncDisplayKit
import Display
import ItemListUI
import SGSimpleSettings
import SwiftSignalKit
import TelegramPresentationData
import UIKit

/// Horizontal category tabs and category editor rows. Dragging the handle uses
/// ItemListController's native reordering; the eye changes visibility independently.
final class ExteraFeedControlsItem: ListViewItem, ItemListItem {
    enum Content {
        case tabs([ExteraFeedSettings.Category], String?, String)
        case category(ExteraFeedSettings.Category, String, String)
    }

    let theme: PresentationTheme
    let sectionId: ItemListSectionId
    let content: Content
    let selected: (String?) -> Void
    let hidden: () -> Void
    var isAlwaysPlain: Bool { return true }
    var neighborDescriptor: AnyEquatable { return .noNeighborInfluence }

    init(theme: PresentationTheme, sectionId: ItemListSectionId, content: Content, selected: @escaping (String?) -> Void, hidden: @escaping () -> Void = {}) {
        self.theme = theme
        self.sectionId = sectionId
        self.content = content
        self.selected = selected
        self.hidden = hidden
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = ExteraFeedControlsItemNode()
            let layout = node.update(item: self, params: params)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { (nil, { _ in }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? ExteraFeedControlsItemNode else { return }
            completion(node.update(item: self, params: params), { _ in })
        }
    }
}

private final class ExteraFeedControlsItemNode: ListViewItemNode {
    private let scroll = UIScrollView()
    private let title = UIButton(type: .system)
    private let eye = UIButton(type: .system)
    private let handle = UIImageView(image: UIImage(systemName: "line.3.horizontal"))
    private var tabs: [UIButton] = []
    private var ids: [String?] = []
    private var item: ExteraFeedControlsItem?

    init() {
        super.init(layerBacked: false)
        self.view.addSubview(self.scroll)
        self.view.addSubview(self.title)
        self.view.addSubview(self.eye)
        self.view.addSubview(self.handle)
        self.scroll.showsHorizontalScrollIndicator = false
        self.title.contentHorizontalAlignment = .left
        self.title.titleLabel?.font = Font.regular(17.0)
        self.title.titleLabel?.lineBreakMode = .byTruncatingTail
        self.title.addTarget(self, action: #selector(self.openCategory), for: .touchUpInside)
        self.eye.addTarget(self, action: #selector(self.toggleHidden), for: .touchUpInside)
        self.handle.contentMode = .center
    }

    @objc private func openCategory() { self.item?.selected(nil) }
    @objc private func toggleHidden() { self.item?.hidden() }
    @objc private func selectTab(_ sender: UIButton) {
        guard self.ids.indices.contains(sender.tag) else { return }
        self.item?.selected(self.ids[sender.tag])
    }

    override func isReorderable(at point: CGPoint) -> Bool {
        guard let item = self.item, case .category = item.content else { return false }
        return self.handle.frame.insetBy(dx: -8.0, dy: -8.0).contains(point)
    }

    func update(item: ExteraFeedControlsItem, params: ListViewItemLayoutParams) -> ListViewItemNodeLayout {
        self.item = item
        let left = params.leftInset + 16.0
        let width = max(1.0, params.width - left - params.rightInset - 16.0)
        let theme = item.theme
        self.backgroundColor = theme.list.itemBlocksBackgroundColor
        switch item.content {
        case let .category(category, hiddenTitle, visibleTitle):
            self.scroll.isHidden = true
            self.title.isHidden = false
            self.eye.isHidden = false
            self.handle.isHidden = false
            self.title.frame = CGRect(x: left, y: 0.0, width: max(1.0, width - 96.0), height: 52.0)
            self.title.setTitle(category.title, for: .normal)
            self.title.setTitleColor(category.isHidden ? theme.list.itemSecondaryTextColor : theme.list.itemPrimaryTextColor, for: .normal)
            self.eye.setImage(UIImage(systemName: category.isHidden ? "eye.slash" : "eye"), for: .normal)
            self.eye.tintColor = theme.list.itemAccentColor
            self.eye.accessibilityLabel = category.title
            self.eye.accessibilityValue = category.isHidden ? hiddenTitle : visibleTitle
            self.eye.frame = CGRect(x: left + width - 92.0, y: 4.0, width: 44.0, height: 44.0)
            self.handle.tintColor = theme.list.itemSecondaryTextColor
            self.handle.frame = CGRect(x: left + width - 44.0, y: 4.0, width: 44.0, height: 44.0)
        case let .tabs(categories, selected, mainTitle):
            self.scroll.isHidden = false
            self.title.isHidden = true
            self.eye.isHidden = true
            self.handle.isHidden = true
            let previousOffset = self.scroll.contentOffset
            for tab in self.tabs { tab.removeFromSuperview() }
            self.tabs.removeAll()
            self.ids = [nil] + categories.map { Optional($0.id) }
            let titles = [mainTitle] + categories.map(\.title)
            var x: CGFloat = 0.0
            var selectedRect: CGRect?
            for (index, title) in titles.enumerated() {
                let button = UIButton(type: .system)
                button.tag = index
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = Font.medium(15.0)
                button.setTitleColor(theme.list.itemAccentColor, for: .normal)
                let isSelected = self.ids[index] == selected
                button.backgroundColor = isSelected ? theme.list.itemAccentColor.withAlphaComponent(0.15) : .clear
                button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
                button.layer.cornerRadius = 16.0
                let size = button.sizeThatFits(CGSize(width: 10000.0, height: 36.0))
                button.frame = CGRect(x: x, y: 8.0, width: size.width + 24.0, height: 36.0)
                button.addTarget(self, action: #selector(self.selectTab(_:)), for: .touchUpInside)
                self.scroll.addSubview(button)
                self.tabs.append(button)
                if isSelected { selectedRect = button.frame }
                x = button.frame.maxX + 6.0
            }
            self.scroll.frame = CGRect(x: left, y: 0.0, width: width, height: 52.0)
            self.scroll.contentSize = CGSize(width: x, height: 52.0)
            self.scroll.contentOffset = CGPoint(x: max(0.0, min(previousOffset.x, x - width)), y: 0.0)
            if let selectedRect { self.scroll.scrollRectToVisible(selectedRect, animated: false) }
        }
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: 52.0), insets: .zero)
    }
}
