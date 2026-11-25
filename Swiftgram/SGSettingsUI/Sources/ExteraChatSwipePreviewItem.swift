import Display
import ItemListUI
import SGItemListUI
import SGSimpleSettings
import SwiftSignalKit
import TelegramPresentationData
import UIKit

/// A real discrete wheel: scrolling commits the same preference that the chat-list runtime reads.
final class ExteraChatSwipePreviewItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let sectionId: Int32
    let value: ExteraChatAppearanceSettings.SwipeAction
    let titles: [String]
    let updated: (ExteraChatAppearanceSettings.SwipeAction) -> Void

    init(theme: PresentationTheme, sectionId: Int32, value: ExteraChatAppearanceSettings.SwipeAction, titles: [String], updated: @escaping (ExteraChatAppearanceSettings.SwipeAction) -> Void) {
        self.theme = theme
        self.sectionId = sectionId
        self.value = value
        self.titles = titles
        self.updated = updated
    }

    private func layout(_ params: ListViewItemLayoutParams, _ neighbors: ListViewItemNeighbors) -> ListViewItemNodeLayout {
        let neighbors = itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self))
        let height = max(156.0, UIFont.preferredFont(forTextStyle: .body).lineHeight * 6.0)
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height), insets: itemListNeighborsGroupedInsets(neighbors, params))
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        let layout = self.layout(params, neighbors)
        Queue.mainQueue().async {
            let node = ExteraChatSwipePreviewNode()
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { (nil, { _ in node.apply(item: self, params: params, size: layout.contentSize) }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        let layout = self.layout(params, neighbors)
        Queue.mainQueue().async {
            guard let node = node() as? ExteraChatSwipePreviewNode else { return }
            completion(layout, { _ in node.apply(item: self, params: params, size: layout.contentSize) })
        }
    }
}

private final class ExteraChatSwipePreviewNode: ListViewItemNode, UIPickerViewDelegate, UIPickerViewDataSource {
    private let card = UIView()
    private let preview = ExteraChatSwipeDrawing(frame: .zero)
    private let picker = UIPickerView(frame: .zero)
    private var item: ExteraChatSwipePreviewItem?
    private let actions = ExteraChatAppearanceSettings.SwipeAction.allCases

    init() {
        super.init(layerBacked: false)
        self.view.addSubview(self.card)
        self.card.addSubview(self.preview)
        self.card.addSubview(self.picker)
        self.card.layer.cornerRadius = 22.0
        self.picker.delegate = self
        self.picker.dataSource = self
        self.preview.isAccessibilityElement = false
    }

    func apply(item: ExteraChatSwipePreviewItem, params: ListViewItemLayoutParams, size: CGSize) {
        let needsReload = self.item?.theme !== item.theme || self.item?.titles != item.titles
        self.item = item
        let left = max(13.0, params.leftInset)
        let width = max(1.0, params.width - left - max(13.0, params.rightInset))
        self.card.frame = CGRect(x: left, y: 0.0, width: width, height: size.height)
        self.card.backgroundColor = SGItemListVisualStyle.extera.cardColor(theme: item.theme)
        self.preview.frame = CGRect(x: 14.0, y: (size.height - 70.0) * 0.5, width: max(1.0, width * 0.46 - 20.0), height: 70.0)
        self.picker.frame = CGRect(x: width * 0.46, y: 0.0, width: width * 0.54 - 10.0, height: size.height)
        if needsReload { self.picker.reloadAllComponents() }
        let selectedRow = self.actions.firstIndex(of: item.value) ?? 3
        if self.picker.selectedRow(inComponent: 0) != selectedRow {
            self.picker.selectRow(selectedRow, inComponent: 0, animated: false)
        }
        self.preview.update(theme: item.theme, action: item.value)
    }

    func numberOfComponents(in pickerView: UIPickerView) -> Int { return 1 }
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int { return self.actions.count }
    func pickerView(_ pickerView: UIPickerView, rowHeightForComponent component: Int) -> CGFloat { return max(44.0, UIFont.preferredFont(forTextStyle: .body).lineHeight * 2.0) }

    func pickerView(_ pickerView: UIPickerView, viewForRow row: Int, forComponent component: Int, reusing view: UIView?) -> UIView {
        let label = (view as? UILabel) ?? UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        label.textAlignment = .center
        label.textColor = self.item?.theme.list.itemPrimaryTextColor
        if let titles = self.item?.titles, titles.indices.contains(row) {
            label.text = titles[row]
        } else {
            label.text = nil
        }
        return label
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        guard let item = self.item, self.actions.indices.contains(row) else { return }
        let action = self.actions[row]
        self.preview.update(theme: item.theme, action: action)
        if action != item.value { item.updated(action) }
    }
}

private final class ExteraChatSwipeDrawing: UIView {
    private var theme: PresentationTheme?
    private var action: ExteraChatAppearanceSettings.SwipeAction = .archive

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isOpaque = false
    }

    required init?(coder: NSCoder) { preconditionFailure() }

    func update(theme: PresentationTheme, action: ExteraChatAppearanceSettings.SwipeAction) {
        self.theme = theme
        self.action = action
        self.setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let theme = self.theme else { return }
        let accent = self.action == .delete ? theme.list.itemDestructiveColor : theme.list.itemAccentColor
        let width = self.bounds.width
        let shape = UIBezierPath(roundedRect: self.bounds.insetBy(dx: 1.0, dy: 1.0), cornerRadius: 10.0)
        accent.withAlphaComponent(0.8).setFill()
        shape.fill()
        let chatRect = CGRect(x: 1.0, y: 1.0, width: max(0.0, width - 45.0), height: self.bounds.height - 2.0)
        SGItemListVisualStyle.extera.cardColor(theme: theme).setFill()
        UIBezierPath(roundedRect: chatRect, cornerRadius: 10.0).fill()
        theme.list.itemSecondaryTextColor.withAlphaComponent(0.25).setFill()
        UIBezierPath(ovalIn: CGRect(x: 6.0, y: 21.0, width: 22.0, height: 22.0)).fill()
        for line in 0 ..< 2 {
            UIBezierPath(roundedRect: CGRect(x: 34.0, y: 25.0 + CGFloat(line) * 12.0, width: max(0.0, chatRect.width - 42.0) * (line == 0 ? 0.55 : 1.0), height: 5.0), cornerRadius: 2.5).fill()
        }
        let symbol: String
        switch self.action {
        case .folder: symbol = "folder"
        case .pin: symbol = "pin.fill"
        case .read: symbol = "bubble.left.fill"
        case .archive: symbol = "archivebox.fill"
        case .mute: symbol = "bell.slash.fill"
        case .delete: symbol = "trash.fill"
        }
        if #available(iOS 13.0, *) {
            UIImage(systemName: symbol)?.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(x: max(0.0, width - 34.0), y: 24.0, width: 22.0, height: 22.0))
        }
        theme.list.itemSecondaryTextColor.withAlphaComponent(0.15).setStroke()
        shape.lineWidth = 1.0
        shape.stroke()
    }
}
