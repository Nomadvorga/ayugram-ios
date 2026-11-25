import Foundation
import SGSimpleSettings
import Postbox
import TelegramCore


func sgDoubleTapMessageAction(incoming: Bool, message: Message) -> ExteraChatSettings.DoubleTapAction {
    return ExteraChatSettings.shared.effectiveDoubleTapAction(incoming: incoming)
}

func sgHandleDoubleTapMessageAction(incoming: Bool, message: Message, editAction: () -> Void, defaultAction: () -> Void) {
    switch sgDoubleTapMessageAction(incoming: incoming, message: message) {
    case .disabled:
        break
    case .inherit, .reaction:
        defaultAction()
    default:
        // The legacy edit callback is the controller-owned action entry point. Route custom
        // gestures through it even when a message cannot receive reactions (e.g. Saved Messages).
        editAction()
    }
}
