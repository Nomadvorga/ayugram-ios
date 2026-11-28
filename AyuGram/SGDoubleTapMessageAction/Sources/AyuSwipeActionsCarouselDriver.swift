import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import SGSimpleSettings
import TelegramCore
import ChatControllerInteraction
import ChatMessageItemCommon
import ChatMessageSwipeToReplyNode

// exteraGram "Swipe Actions" in a message row: one swipe of one message. With several actions it shows them as
// a column of bubbles above the list and follows the finger through them; with one it leaves the row's own
// bubble alone.
final class AyuSwipeActionsCarouselDriver {
    // The actions this message can take, in the user's order.
    let actions: [ExteraSettings.DoubleTapAction]

    private let makeNode: (ChatMessageSwipeToReplyNode.Action) -> ChatMessageSwipeToReplyNode
    private var carousel: AyuSwipeActionsCarousel?
    private let feedback = HapticFeedback()

    private final class Bubble {
        let node: ASDisplayNode
        let content: ChatMessageSwipeToReplyNode
        var scale: CGFloat = 1.0
        var alpha: CGFloat = 1.0

        init(node: ASDisplayNode, content: ChatMessageSwipeToReplyNode) {
            self.node = node
            self.content = content
        }
    }

    private static let bubbleSize = CGSize(width: 33.0, height: 33.0)
    // Android: bubbles of 32 dp every 36 dp.
    private static let bubbleStep: CGFloat = 37.0

    private var containerNode: ASDisplayNode?
    private var bubbles: [Int: Bubble] = [:]
    private var laidOutSlot: Int = 0

    init(message: EngineRawMessage, canSetupReply: ChatControllerInteractionSwipeAction, makeNode: @escaping (ChatMessageSwipeToReplyNode.Action) -> ChatMessageSwipeToReplyNode) {
        self.actions = ayuAvailableSwipeActions(message: message, canSetupReply: canSetupReply)
        self.makeNode = makeNode
    }

    // The action a release performs now.
    var selectedAction: ExteraSettings.DoubleTapAction? {
        let index = self.carousel?.selected ?? 0
        return index < self.actions.count ? self.actions[index] : nil
    }

    // What the row's own bubble shows: the action of a plain swipe.
    var primaryNodeAction: ChatMessageSwipeToReplyNode.Action {
        return AyuSwipeActionsCarouselDriver.nodeAction(self.actions.first ?? .reply)
    }

    private static func nodeAction(_ action: ExteraSettings.DoubleTapAction) -> ChatMessageSwipeToReplyNode.Action {
        if action == .reply {
            return .reply
        }
        return action.menuIconName.map { .icon($0) } ?? .reply
    }

    // Called for every move of the swipe, after the row has placed `primaryNode` and set its progress.
    // `trigger` is how far the row has to be dragged for the swipe to count.
    func update(itemNode: ASDisplayNode, primaryNode: ChatMessageSwipeToReplyNode, recognizer: UIGestureRecognizer, translationX: CGFloat, trigger: CGFloat, progress: CGFloat) {
        guard self.actions.count > 1 else {
            return
        }
        guard let containerNode = self.container(for: itemNode), let hostView = containerNode.view.superview else {
            return
        }
        if self.carousel == nil {
            let settings = ExteraSettings.shared
            self.carousel = AyuSwipeActionsCarousel(count: self.actions.count, looped: settings.swipeActionsLoop, reversed: settings.swipeActionsReversed, trigger: trigger)
        }
        guard var carousel = self.carousel else {
            return
        }

        // The column takes the place of the row's bubble.
        primaryNode.isHidden = true
        let center = itemNode.view.convert(primaryNode.layer.position, to: containerNode.view)

        if carousel.direction == 0 {
            var visibleFrame = containerNode.bounds
            if let listNode = AyuSwipeActionsCarouselDriver.listNode(of: itemNode) {
                visibleFrame = listNode.view.convert(listNode.bounds, to: hostView)
                let insets = listNode.insets
                // A chat's list is turned upside down, and its insets with it.
                visibleFrame = visibleFrame.inset(by: listNode.rotated ? UIEdgeInsets(top: insets.bottom, left: 0.0, bottom: insets.top, right: 0.0) : UIEdgeInsets(top: insets.top, left: 0.0, bottom: insets.bottom, right: 0.0))
            }
            carousel.chooseDirection(centerY: center.y - visibleFrame.minY, height: visibleFrame.height)
        }

        let finger = recognizer.location(in: containerNode.view)
        let moved = carousel.update(offsetX: translationX, x: finger.x, y: finger.y)
        self.carousel = carousel
        if moved {
            self.feedback.tap()
        }

        self.layout(carousel: carousel, center: center, progress: progress, animated: moved)
    }

    // Called when the swipe ends or is cancelled.
    func finish() {
        guard let containerNode = self.containerNode else {
            return
        }
        self.containerNode = nil
        for (_, bubble) in self.bubbles {
            bubble.node.layer.animateAlpha(from: bubble.alpha, to: 0.0, duration: 0.3, removeOnCompletion: false)
            bubble.node.layer.animateScale(from: bubble.scale, to: 0.2 * bubble.scale, duration: 0.3, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false)
        }
        self.bubbles.removeAll()
        Queue.mainQueue().after(0.3) {
            containerNode.removeFromSupernode()
        }
    }

    private static func listNode(of itemNode: ASDisplayNode) -> ListViewImpl? {
        var current = itemNode.supernode
        while let node = current {
            if let listNode = node as? ListViewImpl {
                return listNode
            }
            current = node.supernode
        }
        return nil
    }

    // The bubbles stand above the list, not in the row: they reach over the rows next to it.
    private func container(for itemNode: ASDisplayNode) -> ASDisplayNode? {
        if let containerNode = self.containerNode {
            return containerNode
        }
        guard let listNode = AyuSwipeActionsCarouselDriver.listNode(of: itemNode), let hostNode = listNode.supernode else {
            return nil
        }
        let containerNode = ASDisplayNode()
        containerNode.isUserInteractionEnabled = false
        containerNode.frame = hostNode.bounds
        hostNode.insertSubnode(containerNode, aboveSubnode: listNode)
        self.containerNode = containerNode
        return containerNode
    }

    private func layout(carousel: AyuSwipeActionsCarousel, center: CGPoint, progress: CGFloat, animated: Bool) {
        guard let containerNode = self.containerNode else {
            return
        }
        let slot = carousel.slot
        let step = AyuSwipeActionsCarouselDriver.bubbleStep * CGFloat(carousel.direction < 0 ? -1 : 1)
        let shift = CGFloat(slot - self.laidOutSlot) * step
        self.laidOutSlot = slot
        let transition: ContainedViewLayoutTransition = .animated(duration: 0.35, curve: .spring)
        let fade: ContainedViewLayoutTransition = .animated(duration: 0.28, curve: .easeInOut)

        // The picked action and, while the finger goes through the list, its neighbours.
        var targets: [Int: (scale: CGFloat, alpha: CGFloat)] = [:]
        if let visibleSlots = carousel.visibleSlots(carriage: CGFloat(slot)) {
            for visibleSlot in visibleSlots {
                let isPicked = visibleSlot == slot
                let live: CGFloat = isPicked || carousel.isScrubbing ? 1.0 : 0.0
                if let target = AyuSwipeActionsCarousel.bubble(distance: abs(CGFloat(visibleSlot - slot)), live: live, easedLive: live) {
                    targets[visibleSlot] = target
                }
            }
        }

        for (bubbleSlot, bubble) in self.bubbles where targets[bubbleSlot] == nil {
            self.bubbles.removeValue(forKey: bubbleSlot)
            bubble.node.position = CGPoint(x: center.x, y: center.y + CGFloat(bubbleSlot - slot) * step)
            if shift != 0.0 {
                transition.animatePositionAdditive(node: bubble.node, offset: CGPoint(x: 0.0, y: shift))
            }
            let node = bubble.node
            fade.updateAlpha(node: node, alpha: 0.0, completion: { [weak node] _ in
                node?.removeFromSupernode()
            })
        }

        for (targetSlot, target) in targets {
            let position = CGPoint(x: center.x, y: center.y + CGFloat(targetSlot - slot) * step)
            if let bubble = self.bubbles[targetSlot] {
                bubble.node.position = position
                bubble.content.updateProgress(progress)
                if animated && shift != 0.0 {
                    transition.animatePositionAdditive(node: bubble.node, offset: CGPoint(x: 0.0, y: shift))
                }
                if bubble.scale != target.scale {
                    bubble.scale = target.scale
                    transition.updateTransformScale(node: bubble.node, scale: target.scale, beginWithCurrentState: true)
                }
                if bubble.alpha != target.alpha {
                    bubble.alpha = target.alpha
                    fade.updateAlpha(node: bubble.node, alpha: target.alpha, beginWithCurrentState: true)
                }
            } else {
                let content = self.makeNode(AyuSwipeActionsCarouselDriver.nodeAction(self.actions[carousel.actionIndex(slot: targetSlot)]))
                content.frame = CGRect(origin: CGPoint(), size: AyuSwipeActionsCarouselDriver.bubbleSize)
                let node = ASDisplayNode()
                node.bounds = CGRect(origin: CGPoint(), size: AyuSwipeActionsCarouselDriver.bubbleSize)
                node.position = position
                node.addSubnode(content)
                containerNode.addSubnode(node)

                let bubble = Bubble(node: node, content: content)
                bubble.scale = target.scale
                bubble.alpha = target.alpha
                self.bubbles[targetSlot] = bubble

                content.updateProgress(progress)
                if self.bubbles.count > 1 {
                    // A bubble that appears already filled does not replay the fill.
                    AyuSwipeActionsCarouselDriver.removeAnimations(content.layer)
                }
                node.transform = CATransform3DMakeScale(target.scale, target.scale, 1.0)
                node.alpha = target.alpha
                if self.bubbles.count > 1 {
                    node.layer.animateAlpha(from: 0.0, to: target.alpha, duration: 0.28)
                    if animated && shift != 0.0 {
                        transition.animatePositionAdditive(node: node, offset: CGPoint(x: 0.0, y: shift))
                    }
                }
            }
        }
    }

    private static func removeAnimations(_ layer: CALayer) {
        layer.removeAllAnimations()
        for sublayer in layer.sublayers ?? [] {
            removeAnimations(sublayer)
        }
    }
}

// Which of the user's swipe actions this message can take. `canSetupReply` is the stock answer for Reply.
// The others are checked again, in full, when they run.
func ayuAvailableSwipeActions(message: EngineRawMessage, canSetupReply: ChatControllerInteractionSwipeAction) -> [ExteraSettings.DoubleTapAction] {
    let isPlainCloudMessage = message.adAttribute == nil && message.id.namespace == Namespaces.Message.Cloud
    return ExteraSettings.shared.swipeActions.filter { action in
        switch action {
        case .disable:
            return false
        case .reply:
            if case .reply = canSetupReply {
                return true
            } else {
                return false
            }
        case .reactions:
            return isPlainCloudMessage && canAddMessageReactions(message: EngineMessage(message))
        case .edit:
            return isPlainCloudMessage && !message.flags.contains(.Incoming)
        case .copy, .forward, .save, .repeat, .delete, .translate:
            return isPlainCloudMessage
        }
    }
}
