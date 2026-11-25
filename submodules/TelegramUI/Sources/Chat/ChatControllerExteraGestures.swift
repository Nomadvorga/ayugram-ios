import Foundation
import AccountContext
import ChatControllerInteraction
import ChatMessageItemCommon
import ChatPresentationInterfaceState
import SGSimpleSettings
import SGSettingsUI
import SwiftSignalKit
import TelegramCore
import TranslateUI

extension ChatControllerImpl {
    /// The existing reply eligibility rules, shared by swipe and double tap. The swipe
    /// preference is checked by the caller so disabling it does not disable double-tap Reply.
    func exteraReplyAction(for message: EngineRawMessage) -> ChatControllerInteractionSwipeAction {
        if Namespaces.Message.allEphemeral.contains(message.id.namespace) {
            if !message.flags.contains(.Incoming) {
                return .none
            }
        } else {
            if message.adAttribute != nil {
                return .none
            }
            if !message.flags.contains(.Incoming) && !message.flags.intersection([.Failed, .Sending, .Unsent]).isEmpty {
                return .none
            }
        }
        if case let .replyThread(thread) = self.chatLocation {
            if thread.effectiveMessageId == message.id {
                return .none
            }
            if thread.peerId == self.context.account.peerId && thread.threadId != self.context.account.peerId.toInt64() {
                return .none
            }
        }
        if case .peer = self.chatLocation, let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, channel.isForumOrMonoForum, message.threadId == nil {
            return .none
        }
        if case let .customChatContents(contents) = self.presentationInterfaceState.subject {
            switch contents.kind {
            case .quickReplyMessageInput, .welcomeMessages:
                return .none
            case .businessLinkSetup, .hashTagSearch:
                break
            }
        }
        if !canSendMessagesToChat(self.presentationInterfaceState) && (self.presentationInterfaceState.copyProtectionEnabled || message.isCopyProtected()) {
            return .none
        }
        return canReplyInChat(self.presentationInterfaceState, accountPeerId: self.context.account.peerId) ? .reply : .none
    }

    /// Returns false only for the normal quick-reaction path. Explicit picker reactions
    /// never call this method, so changing double tap cannot intercept a picker selection.
    func performExteraDoubleTapAction(_ message: EngineRawMessage) -> Bool {
        let action = ExteraChatSettings.shared.effectiveDoubleTapAction(incoming: message.effectivelyIncoming(self.context.account.peerId))
        switch action {
        case .inherit, .reaction:
            return false
        case .disabled:
            return true
        default:
            break
        }
        guard self.isNodeLoaded, self.presentationInterfaceState.interfaceState.selectionState == nil, message.adAttribute == nil else {
            return true
        }
        switch action {
        case .read:
            // Explicit user action may pass ghost mode, just like “Read Message”
            // in the context menu. Never read beyond the tapped incoming message.
            guard message.flags.contains(.Incoming), message.id.namespace == Namespaces.Message.Cloud else {
                return true
            }
            self.push(ayuReadHistoryController(context: self.context, peerId: message.id.peerId, requests: [AyuReadHistoryRequest(peerIdValue: message.id.peerId.toInt64(), maxId: message.id.id)]))
        case .reply:
            if case .reply = self.exteraReplyAction(for: message) {
                self.interfaceInteraction?.setupReplyMessage(message.id, nil, { _, completion in completion() })
            }
        case .edit:
            guard !self.presentAccountFrozenInfoIfNeeded(delay: true) else {
                return true
            }
            if canEditMessage(context: self.context, limitsConfiguration: self.context.currentLimitsConfiguration.with { EngineConfiguration.Limits($0) }, message: message) {
                self.interfaceInteraction?.setupEditMessage(message.id, { _ in })
            }
        case .copy:
            guard !self.presentationInterfaceState.copyProtectionEnabled, !message.isCopyProtected(), !message.text.isEmpty else {
                return true
            }
            self.controllerInteraction?.copyText(message.text)
        case .forward, .save:
            guard !self.presentationInterfaceState.copyProtectionEnabled, !message.isCopyProtected(), message.id.peerId.namespace != Namespaces.Peer.SecretChat else {
                return true
            }
            // Ask the same rights service as the selection toolbar before exposing forwarding.
            self.messageContextDisposable.set((self.context.sharedContext.chatAvailableMessageActions(engine: self.context.engine, accountPeerId: self.context.account.peerId, messageIds: Set([message.id]), keepUpdated: false)
            |> deliverOnMainQueue).startStrict(next: { [weak self] actions in
                guard let self, self.isNodeLoaded, actions.options.contains(.forward), !self.presentationInterfaceState.copyProtectionEnabled else {
                    return
                }
                self.interfaceInteraction?.forwardMessages([message], action == .save ? "forwardMessagesToCloud" : nil)
            }))
        case .delete:
            // The existing service-message and pending-send handlers can delete immediately.
            // A double tap must always lead to confirmation, so leave those cases to their
            // existing menus and keep the regular message's delete options/undo flow here.
            guard message.flags.intersection([.Failed, .Sending, .Unsent]).isEmpty,
                  !Namespaces.Message.allEphemeral.contains(message.id.namespace),
                  !message.media.contains(where: { $0 is TelegramMediaAction }) else {
                return true
            }
            self.interfaceInteraction?.deleteMessages([message], nil, { _ in })
        case .repeatMessage:
            guard exteraCanRepeatMessage(context: self.context, state: self.presentationInterfaceState, messages: [message]) else { return true }
            self.messageContextDisposable.set((self.context.sharedContext.chatAvailableMessageActions(engine: self.context.engine, accountPeerId: self.context.account.peerId, messageIds: Set([message.id]), keepUpdated: false)
            |> deliverOnMainQueue).startStrict(next: { [weak self] actions in
                guard let self, self.isNodeLoaded, actions.options.contains(.forward), let interaction = self.controllerInteraction else { return }
                exteraRepeatMessages(context: self.context, state: self.presentationInterfaceState, messages: [message], interaction: interaction)
            }))
        case .translate:
            if !message.text.isEmpty {
                let canCopy = !self.presentationInterfaceState.copyProtectionEnabled && !message.isCopyProtected()
                presentTranslateScreen(
                    context: self.context,
                    text: message.text,
                    entities: message.textEntitiesAttribute?.entities ?? [],
                    canCopy: canCopy,
                    fromLanguage: nil,
                    display: { [weak self] controller in
                        self?.push(controller)
                    }
                )
            }
        case .inherit, .reaction, .disabled:
            break
        }
        return true
    }
}
