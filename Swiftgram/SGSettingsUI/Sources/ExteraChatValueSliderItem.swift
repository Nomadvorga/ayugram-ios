import Display
import ItemListUI
import SGItemListUI
import SwiftSignalKit
import TelegramPresentationData
import UIKit

/// Discrete values supplied by native preferences; no shadow slider storage.
final class ExteraChatValueSliderItem: ListViewItem, ItemListItem {
    let sectionId: Int32
    let theme: PresentationTheme
    let title: String
    let values: [String]
    let selected: Int
    let enabled: Bool
    let updated: (Int) -> Void

    init(sectionId: Int32, theme: PresentationTheme, title: String, values: [String], selected: Int, enabled: Bool, updated: @escaping (Int) -> Void) {
        precondition(!values.isEmpty)
        self.sectionId = sectionId
        self.theme = theme
        self.title = title
        self.values = values
        self.selected = max(0, min(values.count - 1, selected))
        self.enabled = enabled
        self.updated = updated
    }

    private func layout(_ params: ListViewItemLayoutParams, _ neighbors: ListViewItemNeighbors) -> ListViewItemNodeLayout {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let width = max(1.0, params.width - max(13.0, params.leftInset) - max(13.0, params.rightInset) - 40.0)
        let height = self.values.map { value in
            ceil(((self.title + ": " + value) as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: [.font: font], context: nil).height)
        }.max() ?? font.lineHeight
        let neighbors = itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self))
        var insets = itemListNeighborsGroupedInsets(neighbors, params)
        insets.bottom = max(8.0, insets.bottom)
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: max(font.lineHeight, height) + 80.0), insets: insets)
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        let layout = self.layout(params, neighbors)
        Queue.mainQueue().async {
            let node = ExteraChatValueSliderNode()
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { (nil, { _ in node.apply(self, params: params, size: layout.contentSize) }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        let layout = self.layout(params, neighbors)
        Queue.mainQueue().async {
            guard let node = node() as? ExteraChatValueSliderNode else { return }
            completion(layout, { _ in node.apply(self, params: params, size: layout.contentSize) })
        }
    }
}

private final class ExteraChatValueSliderNode: ListViewItemNode {
    private let card = UIView()
    private let label = UILabel()
    private let slider = ExteraDiscreteSlider()
    private var item: ExteraChatValueSliderItem?
    private var displayedIndex = 0

    init() {
        super.init(layerBacked: false)
        self.view.addSubview(self.card)
        self.card.layer.cornerRadius = 22.0
        self.card.addSubview(self.label)
        self.card.addSubview(self.slider)
        self.label.font = .preferredFont(forTextStyle: .subheadline)
        self.label.adjustsFontForContentSizeCategory = true
        self.label.numberOfLines = 0
        self.slider.isContinuous = true
        self.slider.addTarget(self, action: #selector(self.changed), for: .valueChanged)
    }

    @objc private func changed() {
        guard let item, item.enabled else { return }
        let index = max(0, min(item.values.count - 1, Int(self.slider.value.rounded())))
        let previous = self.displayedIndex
        self.displayedIndex = index
        self.slider.value = Float(index)
        self.slider.accessibilityValue = item.values[index]
        self.label.text = item.title + ": " + item.values[index]
        if index != previous { item.updated(index) }
    }

    func apply(_ item: ExteraChatValueSliderItem, params: ListViewItemLayoutParams, size: CGSize) {
        self.item = item
        let left = max(13.0, params.leftInset)
        let width = max(0.0, size.width - left - max(13.0, params.rightInset))
        self.card.frame = CGRect(x: left, y: 0, width: width, height: size.height)
        self.card.backgroundColor = SGItemListVisualStyle.extera.cardColor(theme: item.theme)
        self.label.textColor = item.enabled ? item.theme.list.itemPrimaryTextColor : item.theme.list.itemDisabledTextColor
        if !self.slider.isTracking || !item.enabled { self.displayedIndex = item.selected }
        self.label.text = item.title + ": " + item.values[self.displayedIndex]
        let labelHeight = max(self.label.font.lineHeight, self.label.sizeThatFits(CGSize(width: max(1.0, width - 40.0), height: .greatestFiniteMagnitude)).height)
        self.label.frame = CGRect(x: 20, y: 12, width: max(0, width - 40), height: ceil(labelHeight))
        self.slider.frame = CGRect(x: 20, y: self.label.frame.maxY + 8, width: max(0, width - 40), height: 44)
        self.slider.minimumValue = 0
        self.slider.maximumValue = Float(item.values.count - 1)
        // Preserve the finger's active position while the shared preferences publish.
        if !self.slider.isTracking || !item.enabled { self.slider.value = Float(item.selected) }
        self.slider.isEnabled = item.enabled
        self.slider.minimumTrackTintColor = item.theme.list.itemAccentColor
        self.slider.maximumTrackTintColor = item.theme.list.itemSecondaryTextColor.withAlphaComponent(0.25)
        self.slider.accessibilityLabel = item.title
        self.slider.accessibilityValue = item.values[self.displayedIndex]
    }
}

private final class ExteraDiscreteSlider: UISlider {
    override func accessibilityIncrement() { self.adjust(by: 1) }
    override func accessibilityDecrement() { self.adjust(by: -1) }

    private func adjust(by step: Float) {
        guard self.isEnabled else { return }
        self.value = max(self.minimumValue, min(self.maximumValue, self.value.rounded() + step))
        self.sendActions(for: .valueChanged)
    }
}
