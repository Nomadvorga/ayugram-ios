import Foundation
import SGSimpleSettings
import TelegramCore
import ChatControllerInteraction
import ChatMessageSwipeToReplyNode


// exteraGram "Double Tap": the action chosen for incoming or outgoing messages.
// `otherAction` gets the raw value of every action the chat screen performs itself.
func sgHandleDoubleTapMessageAction(incoming: Bool, message: EngineRawMessage, editAction: () -> Void, defaultAction: () -> Void, otherAction: (Int) -> Void) {
    let action = incoming ? ExteraSettings.shared.doubleTapAction : ExteraSettings.shared.doubleTapActionOutgoing
    switch action {
    case .disable:
        break
    case .reactions:
        defaultAction()
    case .edit:
        editAction()
    case .reply, .copy, .forward, .save, .repeat, .delete, .translate:
        otherAction(action.rawValue)
    }
}

// exteraGram "Swipe Actions": whether the swipe to the left may begin on this message. `canSetupReply` is the
// stock answer, which still decides for Reply.
func ayuSwipeMessageAction(message: EngineRawMessage, canSetupReply: ChatControllerInteractionSwipeAction) -> ChatControllerInteractionSwipeAction {
    return ayuAvailableSwipeActions(message: message, canSetupReply: canSetupReply).isEmpty ? .none : .reply
}

// `action` is what the swipe picked; without it the first action the message can take runs.
func ayuPerformSwipeMessageAction(message: EngineRawMessage, controllerInteraction: ChatControllerInteraction, action: ExteraSettings.DoubleTapAction?) {
    guard let action = action ?? ayuAvailableSwipeActions(message: message, canSetupReply: controllerInteraction.canSetupReply(message)).first else {
        return
    }
    switch action {
    case .reply:
        controllerInteraction.setupReply(message.id)
    case .reactions:
        controllerInteraction.updateMessageReaction(message, .default, false, nil)
    case .disable:
        break
    case .copy, .forward, .edit, .save, .repeat, .delete, .translate:
        controllerInteraction.ayuPerformDoubleTapAction(message, action.rawValue)
    }
}
