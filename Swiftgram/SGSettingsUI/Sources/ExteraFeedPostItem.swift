import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import ItemListUI
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// Hosts the same message item used by News. All original media and entities stay in
/// the bubble: Telegram owns resource fetching, spoilers, progress, video and round video.
final class ExteraFeedPostItem: ListViewItem, ItemListItem {
    let context: AccountContext
    let messages: [EngineMessage]
    let presentationData: PresentationData
    let channel: String
    let metadata: String
    let wide: Bool
    let actions: ChatMessageFeedItemActions
    let pageVisibility: Signal<Bool, NoError>
    let openPost: () -> Void
    let openReactionPicker: (UIView) -> Void
    let sectionId: ItemListSectionId
    var isAlwaysPlain: Bool { return true }
    var neighborDescriptor: AnyEquatable { return .noNeighborInfluence }

    init(context: AccountContext, messages: [EngineMessage], presentationData: PresentationData, channel: String, metadata: String, wide: Bool, sectionId: ItemListSectionId, actions: ChatMessageFeedItemActions, pageVisibility: Signal<Bool, NoError>, openPost: @escaping () -> Void, openReactionPicker: @escaping (UIView) -> Void) {
        self.context = context
        self.messages = messages
        self.presentationData = presentationData
        self.channel = channel
        self.metadata = metadata
        self.wide = wide
        self.sectionId = sectionId
        self.actions = actions
        self.pageVisibility = pageVisibility
        self.openPost = openPost
        self.openReactionPicker = openReactionPicker
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        Queue.mainQueue().async {
            let node = ExteraFeedPostItemNode()
            let layout = node.update(item: self, params: params, synchronousLoads: synchronousLoads)
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { (nil, { _ in }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            guard let node = node() as? ExteraFeedPostItemNode else { return }
            completion(node.update(item: self, params: params, synchronousLoads: false), { _ in })
        }
    }
}

private final class ExteraFeedPostItemNode: ListViewItemNode {
    private let card = ASDisplayNode()
    private let bubbleContainer = ASDisplayNode()
    private var bubble: ListViewItemNode?
    private var bubbleSize = CGSize()
    private let titleButton = UIButton(type: .system)
    private let metadataLabel = UILabel()
    private let reactionButton = UIButton(type: .system)
    private var item: ExteraFeedPostItem?
    private var observers: [NSObjectProtocol] = []
    private var inHierarchy = false
    private var pageVisible = false
    private let visibilityDisposable = MetaDisposable()

    override var visibility: ListViewItemNodeVisibility {
        didSet { self.updateMediaVisibility() }
    }

    init() {
        super.init(layerBacked: false)
        self.addSubnode(self.card)
        self.card.addSubnode(self.bubbleContainer)
        // Chat items are measured for a list rotated by pi, even in a standalone slot.
        self.bubbleContainer.subnodeTransform = CATransform3DMakeRotation(.pi, 0.0, 0.0, 1.0)
        self.card.view.addSubview(self.titleButton)
        self.card.view.addSubview(self.metadataLabel)
        self.card.view.addSubview(self.reactionButton)
        self.titleButton.contentHorizontalAlignment = .left
        self.titleButton.titleLabel?.font = Font.semibold(16.0)
        self.titleButton.titleLabel?.lineBreakMode = .byTruncatingTail
        self.titleButton.addTarget(self, action: #selector(self.openPost), for: .touchUpInside)
        self.metadataLabel.font = Font.regular(12.0)
        self.reactionButton.setTitle("＋", for: .normal)
        self.reactionButton.titleLabel?.font = Font.medium(20.0)
        self.reactionButton.addTarget(self, action: #selector(self.controlPressed), for: .touchUpInside)
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: { [weak self] notification in
                self?.updateMediaVisibility(forceHidden: notification.name == UIApplication.willResignActiveNotification)
            }))
        }
    }

    deinit {
        self.visibilityDisposable.dispose()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func didEnterHierarchy() {
        super.didEnterHierarchy()
        self.inHierarchy = true
        self.updateMediaVisibility()
    }

    override func didExitHierarchy() {
        super.didExitHierarchy()
        self.inHierarchy = false
        self.updateMediaVisibility()
    }

    private func updateMediaVisibility(forceHidden: Bool = false) {
        guard let bubble = self.bubble else { return }
        guard !forceHidden, self.pageVisible, self.inHierarchy, UIApplication.shared.applicationState == .active else {
            bubble.visibility = .none
            return
        }
        switch self.visibility {
        case .none: bubble.visibility = .none
        case let .visible(_, rect):
            let visible = bubble.view.convert(rect, from: self.view).intersection(bubble.bounds)
            bubble.visibility = visible.isNull || visible.isEmpty ? .none : .visible(visible.height / max(1.0, self.bubbleSize.height), visible)
        }
    }

    @objc private func openPost() { self.item?.openPost() }
    @objc private func controlPressed() { self.item?.openReactionPicker(self.reactionButton) }

    func update(item: ExteraFeedPostItem, params: ListViewItemLayoutParams, synchronousLoads: Bool) -> ListViewItemNodeLayout {
        if self.item == nil {
            self.visibilityDisposable.set((item.pageVisibility |> deliverOnMainQueue).start(next: { [weak self] visible in
                self?.pageVisible = visible
                self?.updateMediaVisibility()
            }))
        }
        self.item = item
        let theme = item.presentationData.theme
        let side: CGFloat = item.wide ? 0.0 : 16.0
        let left = params.leftInset + side
        let width = max(1.0, params.width - left - params.rightInset - side)
        self.card.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.card.cornerRadius = item.wide ? 0.0 : 16.0
        self.titleButton.setTitle(item.channel, for: .normal)
        self.titleButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
        self.metadataLabel.text = item.metadata
        self.metadataLabel.textColor = theme.list.itemSecondaryTextColor
        self.titleButton.frame = CGRect(x: 16.0, y: 8.0, width: max(1.0, width - 32.0), height: 30.0)
        self.metadataLabel.frame = CGRect(x: 16.0, y: 38.0, width: max(1.0, width - 32.0), height: 18.0)

        let nativeItem = item.context.sharedContext.makeChatMessageFeedItem(context: item.context, messages: item.messages, presentationData: item.presentationData, accountPeer: nil, actions: item.actions)
        let bubbleParams = ListViewItemLayoutParams(width: width, leftInset: 0.0, rightInset: 0.0, availableHeight: 10000.0, isStandalone: true)
        let neighbors = ListViewItemNeighbors(previous: nil, next: nil)
        if let bubble = self.bubble {
            nativeItem.updateNode(async: { $0() }, node: { bubble }, params: bubbleParams, neighbors: neighbors, animation: .None, completion: { layout, apply in
                bubble.contentSize = layout.contentSize
                bubble.insets = layout.insets
                bubble.frame = CGRect(origin: .zero, size: layout.size)
                self.bubbleSize = layout.size
                apply(ListViewItemApply())
            })
        } else {
            nativeItem.nodeConfiguredForParams(async: { $0() }, params: bubbleParams, synchronousLoads: synchronousLoads, neighbors: neighbors, completion: { node, apply in
                self.bubble = node
                apply().1(ListViewItemApply())
                self.bubbleSize = node.frame.size
                self.bubbleContainer.addSubnode(node)
            })
        }
        self.bubbleContainer.frame = CGRect(origin: CGPoint(x: 0.0, y: 60.0), size: self.bubbleSize)

        self.reactionButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
        self.reactionButton.accessibilityLabel = item.presentationData.strings.Common_More
        let controlsY = 64.0 + self.bubbleSize.height
        self.reactionButton.frame = CGRect(x: 12.0, y: controlsY, width: 44.0, height: 36.0)
        let height = controlsY + 44.0
        self.card.frame = CGRect(x: left, y: 4.0, width: width, height: height)
        self.updateMediaVisibility()
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: height + 8.0), insets: .zero)
    }
}
