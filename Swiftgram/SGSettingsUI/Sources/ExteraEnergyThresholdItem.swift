import Display
import Foundation
import ItemListUI
import SGItemListUI
import SwiftSignalKit
import TelegramPresentationData
import UIKit

/// Page-local threshold control. Uses the existing native 4/96 Never/Always sentinels.
final class ExteraEnergyThresholdItem: ListViewItem, ItemListItem {
    let sectionId: ItemListSectionId = 0
    let theme: PresentationTheme
    let value: Int32
    let active: Bool
    let enabled: Bool
    let title: String
    let status: String
    let never: String
    let always: String
    let updated: (Int32) -> Void

    init(theme: PresentationTheme, value: Int32, active: Bool, enabled: Bool, title: String, status: String, never: String, always: String, updated: @escaping (Int32) -> Void) {
        self.theme = theme
        self.value = value
        self.active = active
        self.enabled = enabled
        self.title = title
        self.status = status
        self.never = never
        self.always = always
        self.updated = updated
    }

    fileprivate func metrics(contentWidth: CGFloat) -> (title: CGFloat, status: CGFloat, labels: CGFloat, total: CGFloat) {
        func height(_ text: String, width: CGFloat, style: UIFont.TextStyle) -> CGFloat {
            let font = UIFont.preferredFont(forTextStyle: style)
            return ceil(max(font.lineHeight, (text as NSString).boundingRect(with: CGSize(width: max(1.0, width), height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: [.font: font], context: nil).height))
        }
        let title = height(self.title, width: contentWidth, style: .headline)
        let status = height(self.status, width: contentWidth, style: .subheadline)
        let value = self.value <= 4 ? self.never : self.value >= 96 ? self.always : "\(self.value)%"
        let labels = [self.never, self.always, value].map { height($0, width: contentWidth / 3.0, style: .footnote) }.max() ?? 0.0
        return (title, status, labels, title + status + labels + 96.0)
    }

    private func layout(params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors) -> ListViewItemNodeLayout {
        let neighbors = itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self))
        let width = max(1.0, params.width - max(13.0, params.leftInset) - max(13.0, params.rightInset) - 40.0)
        var insets = itemListNeighborsGroupedInsets(neighbors, params)
        // The local slider is its own card; the following SG row owns its own rounded card.
        insets.bottom = max(insets.bottom, 8.0)
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: self.metrics(contentWidth: width).total), insets: insets)
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        let layout = self.layout(params: params, neighbors: neighbors)
        Queue.mainQueue().async {
            let node = ExteraEnergyThresholdNode()
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { (nil, { _ in node.apply(item: self, params: params, size: layout.contentSize) }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        let layout = self.layout(params: params, neighbors: neighbors)
        Queue.mainQueue().async {
            guard let node = node() as? ExteraEnergyThresholdNode else { return }
            completion(layout, { _ in node.apply(item: self, params: params, size: layout.contentSize) })
        }
    }
}

private final class ExteraEnergyThresholdNode: ListViewItemNode {
    private let card = UIView()
    private let title = UILabel()
    private let status = UILabel()
    private let never = UILabel()
    private let always = UILabel()
    private let value = UILabel()
    private let slider = UISlider()
    private var item: ExteraEnergyThresholdItem?

    init() {
        super.init(layerBacked: false)
        self.view.addSubview(self.card)
        for label in [self.title, self.status, self.never, self.always, self.value] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            self.card.addSubview(label)
        }
        self.title.numberOfLines = 0
        self.value.textAlignment = .center
        self.always.textAlignment = .right
        self.card.addSubview(self.slider)
        self.slider.minimumValue = 4
        self.slider.maximumValue = 96
        self.slider.isContinuous = false
        self.slider.addTarget(self, action: #selector(self.changed), for: .valueChanged)
    }

    func apply(item: ExteraEnergyThresholdItem, params: ListViewItemLayoutParams, size: CGSize) {
        self.item = item
        let left = max(13.0, params.leftInset)
        let right = max(13.0, params.rightInset)
        let width = max(0.0, size.width - left - right)
        self.card.frame = CGRect(x: left, y: 0.0, width: width, height: size.height)
        self.card.backgroundColor = SGItemListVisualStyle.extera.cardColor(theme: item.theme)
        self.card.layer.cornerRadius = 22.0
        self.title.text = item.title
        self.title.font = .preferredFont(forTextStyle: .headline)
        self.title.textColor = item.theme.list.itemAccentColor
        let metrics = item.metrics(contentWidth: max(1.0, width - 40.0))
        let titleHeight = metrics.title
        self.title.frame = CGRect(x: 20.0, y: 14.0, width: max(0.0, width - 40.0), height: titleHeight)
        self.status.text = item.status
        self.status.font = .preferredFont(forTextStyle: .subheadline)
        self.status.textColor = item.active ? item.theme.list.itemAccentColor : item.theme.list.itemSecondaryTextColor
        self.status.frame = CGRect(x: 20.0, y: self.title.frame.maxY + 4.0, width: max(0.0, width - 40.0), height: metrics.status)
        self.never.text = item.never
        self.always.text = item.always
        self.value.text = item.value <= 4 ? item.never : item.value >= 96 ? item.always : "\(item.value)%"
        for label in [self.never, self.always, self.value] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = item.theme.list.itemSecondaryTextColor
            label.alpha = item.enabled ? 1.0 : 0.5
        }
        let labelHeight = metrics.labels
        let labelY = self.status.frame.maxY + 16.0
        let third = max(0.0, (width - 40.0) / 3.0)
        self.never.frame = CGRect(x: 20.0, y: labelY, width: third, height: labelHeight)
        self.value.frame = CGRect(x: 20.0 + third, y: labelY, width: third, height: labelHeight)
        self.always.frame = CGRect(x: 20.0 + third * 2.0, y: labelY, width: third, height: labelHeight)
        self.slider.frame = CGRect(x: 20.0, y: labelY + labelHeight + 6.0, width: max(0.0, width - 40.0), height: 44.0)
        self.slider.value = Float(max(4, min(96, item.value)))
        self.slider.tintColor = item.theme.list.itemAccentColor
        self.slider.isEnabled = item.enabled
        self.slider.accessibilityLabel = item.title
        self.slider.accessibilityValue = self.value.text
    }

    @objc private func changed() {
        guard let item = self.item, item.enabled else { return }
        item.updated(Int32(self.slider.value.rounded()))
    }
}
