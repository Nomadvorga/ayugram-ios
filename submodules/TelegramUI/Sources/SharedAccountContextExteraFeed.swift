import AccountContext
import ChatMessageItemCommon
import ContextUI
import Display
import EntityKeyboard
import Foundation
import ReactionSelectionNode
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TopMessageReactions
import UIKit

extension SharedAccountContextImpl {
    public func openExteraFeedReplies(context: AccountContext, messageId: EngineMessage.Id, controller: ViewController) -> Disposable {
        guard let navigationController = controller.navigationController as? NavigationController else { return EmptyDisposable }
        return ChatControllerImpl.openMessageReplies(context: context, navigationController: navigationController, present: { [weak controller] c, a in
            controller?.present(c, in: .window(.root), with: a)
        }, messageId: messageId, isChannelPost: true, atMessage: nil, displayModalProgress: true).start()
    }

    public func updateExteraFeedReaction(context: AccountContext, messageId: EngineMessage.Id, reaction: UpdateMessageReaction) -> Disposable {
        // Stars require the chat's payment flow; never enqueue them as an ordinary reaction.
        guard reaction.reaction != .stars else { return EmptyDisposable }
        return (context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
        |> mapToSignal { message -> Signal<Never, NoError> in
            guard let message, canAddMessageReactions(message: message) else { return .complete() }
            return peerMessageAllowedReactions(context: context, message: message._asMessage())
            |> take(1)
            |> mapToSignal { allowed, _ -> Signal<Never, NoError> in
                let selected = message.effectiveReactions(isTags: false)?.filter(\.isSelected).map(\.value) ?? []
                if selected.contains(reaction.reaction) {
                    context.engine.messages.setMessageReactions(ids: [messageId], reactions: selected.filter { $0 != reaction.reaction && $0 != .stars }.map(exteraFeedUpdateReaction))
                    return .complete()
                }
                guard let allowed else { return .complete() }
                if case let .set(values) = allowed, !values.contains(reaction.reaction) { return .complete() }
                // The engine enforces the account's reaction count and updates album siblings.
                context.engine.messages.addMessageReactions(ids: [messageId], reactions: [reaction])
                return .complete()
            }
        }).startStandalone()
    }

    public func presentExteraFeedReactionMenu(context: AccountContext, messageId: EngineMessage.Id, sourceView: UIView, controller: ViewController) -> Disposable {
        return (context.engine.data.get(TelegramEngine.EngineData.Item.Messages.Message(id: messageId))
        |> mapToSignal { message -> Signal<(EngineMessage, [ReactionItem]), NoError> in
            guard let message, canAddMessageReactions(message: message) else { return .complete() }
            return topMessageReactions(context: context, message: message._asMessage(), subPeerId: nil)
            |> map { (message, $0) }
        } |> deliverOnMainQueue).start(next: { [weak self, weak controller, weak sourceView] message, reactions in
            guard let self, let controller, let sourceView, sourceView.window != nil else { return }
            let presentationData = self.currentPresentationData.with { $0 }
            var items = ContextController.Items(content: .list([
                .action(ContextMenuActionItem(text: presentationData.strings.MediaPlayer_ContextMenu_ShowInChat, icon: { _ in nil }, action: { [weak self] _, completion in
                    completion(.default)
                    self?.navigateToChat(accountId: context.account.id, peerId: messageId.peerId, messageId: messageId)
                }))
            ]))
            items.context = context
            items.animationCache = context.animationCache
            items.reactionItems = reactions.map { .reaction(item: $0, icon: .none) }
            items.selectedReactionItems = Set(message.effectiveReactions(isTags: false)?.filter(\.isSelected).map(\.value) ?? [])
            // As in broadcast chat, custom reactions explicitly permitted by the channel
            // are available to every subscriber, and expansion contains only permitted items.
            items.alwaysAllowPremiumReactions = true
            if reactions.count > 16 {
                let mapped = reactions.map { EmojiComponentReactionItem(reaction: $0.reaction.rawValue, file: $0.stillAnimation) }
                items.getEmojiContent = { cache, renderer in
                    return EmojiPagerContentComponent.emojiInputData(context: context, animationCache: cache, animationRenderer: renderer, isStandalone: false, subject: .reaction(onlyTop: true), hasTrending: false, topReactionItems: mapped, areUnicodeEmojiEnabled: false, areCustomEmojiEnabled: false, chatPeerId: messageId.peerId, selectedItems: Set())
                }
            }
            let menu = makeContextController(presentationData: presentationData, source: .reference(ChatControllerContextReferenceContentSource(controller: controller, sourceView: sourceView, insets: .zero)), items: .single(items), gesture: nil)
            menu.reactionSelected = { [weak self, weak menu] reaction, _ in
                menu?.dismiss(completion: {})
                guard let self else { return }
                if reaction.reaction == .stars {
                    self.navigateToChat(accountId: context.account.id, peerId: messageId.peerId, messageId: messageId)
                } else {
                    let _ = self.updateExteraFeedReaction(context: context, messageId: messageId, reaction: reaction)
                }
            }
            controller.present(menu, in: .window(.root))
        })
    }
}

private func exteraFeedUpdateReaction(_ reaction: MessageReaction.Reaction) -> UpdateMessageReaction {
    switch reaction {
    case let .builtin(value): return .builtin(value)
    case let .custom(fileId): return .custom(fileId: fileId, file: nil)
    case .stars: return .stars
    }
}
