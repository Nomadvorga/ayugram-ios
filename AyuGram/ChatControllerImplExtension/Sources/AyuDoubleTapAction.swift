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

// exteraGram "Swipe Actions": the action a swipe on a message row picked. The actions themselves are the ones
// double tap performs (`performExteraMessageAction`).
extension ChatControllerImpl {
    func ayuPerformDoubleTapAction(message: Message, rawAction: Int) {
        guard let action = ExteraChatSettings.DoubleTapAction(rawValue: rawAction) else {
            return
        }
        let state = self.presentationInterfaceState
        guard case .standard = state.mode, state.chatLocation.peerId?.namespace != Namespaces.Peer.SecretChat else {
            return
        }
        if message.ayuDeletedDate != nil || message.containsSecretMedia {
            return
        }
        if message.media.contains(where: { $0 is TelegramMediaAction || $0 is TelegramMediaExpiredContent }) {
            return
        }
        let _ = self.performExteraMessageAction(action, message: message)
    }
}
