import SGSimpleSettings
import Foundation
import UIKit
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChatPresentationInterfaceState
import Pasteboard
import UndoUI

// exteraGram "Double Tap" and "Swipe" actions the message rows hand over. Each one does what the same item of
// the message menu does, and nothing when the menu would not offer it.
extension ChatControllerImpl {
    func ayuPerformDoubleTapAction(message: Message, rawAction: Int) {
        guard let action = ExteraSettings.DoubleTapAction(rawValue: rawAction) else {
            return
        }
        let state = self.presentationInterfaceState
        if state.interfaceState.selectionState != nil {
            return
        }
        guard case .standard = state.mode, state.chatLocation.peerId?.namespace != Namespaces.Peer.SecretChat else {
            return
        }
        if message.ayuDeletedDate != nil || message.containsSecretMedia {
            return
        }
        if message.media.contains(where: { $0 is TelegramMediaAction || $0 is TelegramMediaExpiredContent }) {
            return
        }
        let isCloud = message.id.namespace == Namespaces.Message.Cloud
        let isCopyProtected = state.copyProtectionEnabled || message.isCopyProtected()

        switch action {
        case .disable, .reactions:
            break
        case .edit:
            self.controllerInteraction?.sgStartMessageEdit(message)
        case .reply:
            if isCloud, canReplyInChat(state, accountPeerId: self.context.account.peerId) {
                self.interfaceInteraction?.setupReplyMessage(message.id, nil, { _, completed in
                    completed()
                })
            }
        case .copy:
            if !isCopyProtected, !message.text.isEmpty, !message.media.contains(where: { $0 is TelegramMediaPoll }) {
                storeMessageTextInPasteboard(message.text, entities: message.textEntitiesAttribute?.entities)
                self.controllerInteraction?.displayUndo(.copy(text: self.presentationData.strings.Conversation_MessageCopied))
            }
        case .forward:
            if isCloud, !isCopyProtected {
                self.interfaceInteraction?.forwardMessages([message], nil)
            }
        case .save:
            if isCloud, !isCopyProtected, state.chatLocation.peerId != self.context.account.peerId {
                self.interfaceInteraction?.forwardMessages([message], "forwardMessagesToCloud")
            }
        case .repeat:
            if isCloud, !isCopyProtected, canSendMessagesToChat(state) {
                let _ = enqueueMessages(account: self.context.account, peerId: message.id.peerId, messages: [.forward(source: message.id, threadId: state.chatLocation.threadId, grouping: .auto, attributes: [ForwardOptionsMessageAttribute(hideNames: true, hideCaptions: false)], correlationId: nil)]).startStandalone()
            }
        case .delete:
            self.interfaceInteraction?.deleteMessages([message], nil, { _ in })
        case .translate:
            if !message.text.isEmpty {
                self.controllerInteraction?.performTextSelectionAction(message, !isCopyProtected, NSAttributedString(string: message.text), message.textEntitiesAttribute?.entities, .translate)
            }
        }
    }
}
