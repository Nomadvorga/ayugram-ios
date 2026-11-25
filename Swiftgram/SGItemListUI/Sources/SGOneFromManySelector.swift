import Foundation
import UIKit
import ContextUI
import Display
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData

public struct SGOneFromManyOption {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    public init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }
}

/// A selector's anchor and highlight contract, shared by native and opt-in SG rows.
protocol SGOneFromManySourceNode: AnyObject, ItemListItemNode {
    var oneFromManySourceView: UIView { get }
    func updateHasContextMenu(hasContextMenu: Bool)
}

extension ItemListDisclosureItemNode: SGOneFromManySourceNode {
    var oneFromManySourceView: UIView { return self.labelNode.view }
}

struct SGOneFromManyTag<Setting: Hashable>: ItemListItemTag {
    let setting: Setting

    func isEqual(to other: ItemListItemTag) -> Bool {
        guard let other = other as? Self else {
            return false
        }
        return self.setting == other.setting
    }
}

public func sgPresentOneFromManySelector<Setting: Hashable>(controller: ItemListController, setting: Setting, presentationData: PresentationData, options: [SGOneFromManyOption]) {
    let targetTag = SGOneFromManyTag(setting: setting)
    var sourceNode: SGOneFromManySourceNode?
    controller.forEachItemNode { node in
        if let node = node as? SGOneFromManySourceNode, node.tag?.isEqual(to: targetTag) == true {
            sourceNode = node
        }
    }
    guard let sourceNode else {
        return
    }

    let items: [ContextMenuItem] = options.map { option in
        return .action(ContextMenuActionItem(text: option.title, icon: { theme in
            if option.isSelected {
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor)
            } else {
                return UIImage()
            }
        }, action: { _, dismiss in
            dismiss(.default)
            option.action()
        }, accessibilityIsSelected: option.isSelected))
    }
    let contextController = makeContextController(
        presentationData: presentationData,
        source: .reference(SGOneFromManyReferenceContentSource(sourceView: sourceNode.oneFromManySourceView)),
        items: .single(ContextController.Items(content: .list(items)))
    )
    sourceNode.updateHasContextMenu(hasContextMenu: true)
    contextController.dismissed = { [weak sourceNode] in
        sourceNode?.updateHasContextMenu(hasContextMenu: false)
    }
    controller.presentInGlobalOverlay(contextController, with: nil)
}

private final class SGOneFromManyReferenceContentSource: ContextReferenceContentSource {
    private let sourceView: UIView

    init(sourceView: UIView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceView, contentAreaInScreenSpace: mainWindowScreenBounds, insets: UIEdgeInsets(top: -4.0, left: 0.0, bottom: -4.0, right: 0.0))
    }
}
