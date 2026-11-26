import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi
import SGSimpleSettings

private let ayuReadMessageFunctions: Set<String> = [
    "messages.readHistory",
    "channels.readHistory",
    "messages.readDiscussion",
    "messages.readEncryptedHistory",
    "messages.readMessageContents",
    "channels.readMessageContents",
]

private let ayuReadStoryFunctions: Set<String> = [
    "stories.readStories",
    "stories.incrementStoryViews",
]

private let ayuTypingFunctions: Set<String> = [
    "messages.setTyping",
    "messages.setEncryptedTyping",
]

private let ayuAdFunctions: Set<String> = [
    "messages.getSponsoredMessages",
    "contacts.getSponsoredPeers",
]

private let ayuMessageSendingFunctions: Set<String> = [
    "messages.sendMessage",
    "messages.sendMedia",
    "messages.sendMultiMedia",
    "messages.forwardMessages",
    "messages.sendInlineBotResult",
]

func ayuGhostShouldDrop(_ description: FunctionDescription) -> Bool {
    let settings = AyuGhostSettings.shared
    let functionName = description.name
    if ayuReadMessageFunctions.contains(functionName) {
        return ayuShouldDrop(kind: .read, droppedByDefault: settings.suppressReadMessages, description: description)
    }
    if ayuReadStoryFunctions.contains(functionName) {
        return settings.suppressStoryViews
    }
    if ayuTypingFunctions.contains(functionName) {
        if ayuIsTypingRequiredByTelegram(description) {
            return false
        }
        return ayuShouldDrop(kind: .typing, droppedByDefault: settings.suppressTyping, description: description)
    }
    if ayuAdFunctions.contains(functionName) {
        return AyuCustomizationSettings.shared.disableAds
    }
    if functionName == "account.updateStatus", settings.suppressOnlineStatus {
        return ayuIsOnlineStatusUpdate(description)
    }
    return false
}

// An online packet from anywhere but the presence manager and the send pulse, which bypass the filter.
private func ayuIsOnlineStatusUpdate(_ description: FunctionDescription) -> Bool {
    for (name, parameter) in description.parameters where name == "offline" {
        if let offline = parameter.value as? Api.Bool, case .boolFalse = offline {
            return true
        }
    }
    return false
}

// Speaking in a group call and emoji interactions are not typing: hiding them breaks calls and animations.
private func ayuIsTypingRequiredByTelegram(_ description: FunctionDescription) -> Bool {
    for (name, parameter) in description.parameters where name == "action" {
        guard let action = parameter.value as? Api.SendMessageAction else {
            return false
        }
        switch action {
        case .speakingInGroupCallAction, .sendMessageEmojiInteraction, .sendMessageEmojiInteractionSeen:
            return true
        default:
            return false
        }
    }
    return false
}

// Read state pushes are replaced by confirming the queued operation locally: neither readHistory nor the
// validation that would bring the server's unread state back is sent.
func ayuSuppressesReadState(peerId: PeerId) -> Bool {
    switch AyuExclusions.shared.mode(.read, peerId: peerId.toInt64()) {
    case .never:
        return true
    case .always:
        return false
    case .default:
        return AyuGhostSettings.shared.suppressReadMessages
    }
}

func ayuSuppressesTyping(peerId: PeerId) -> Bool {
    switch AyuExclusions.shared.mode(.typing, peerId: peerId.toInt64()) {
    case .never:
        return true
    case .always:
        return false
    case .default:
        return AyuGhostSettings.shared.suppressTyping
    }
}

private func ayuShouldDrop(kind: AyuExclusions.Kind, droppedByDefault: Bool, description: FunctionDescription) -> Bool {
    let exclusions = AyuExclusions.shared
    // Describing the parameters decodes the request, so it is done only when some chat has an exclusion.
    if exclusions.hasAny(kind), let peerId = ayuRequestPeerId(description) {
        switch exclusions.mode(kind, peerId: peerId.toInt64()) {
        case .never:
            return true
        case .always:
            return false
        case .default:
            break
        }
    }
    return droppedByDefault
}

private func ayuRequestPeerId(_ description: FunctionDescription) -> PeerId? {
    for (name, parameter) in description.parameters {
        if name == "peer", let inputPeer = parameter.value as? Api.InputPeer {
            switch inputPeer {
            case let .inputPeerUser(inputPeerUserData):
                return PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(inputPeerUserData.userId))
            case let .inputPeerChat(inputPeerChatData):
                return PeerId(namespace: Namespaces.Peer.CloudGroup, id: PeerId.Id._internalFromInt64Value(inputPeerChatData.chatId))
            case let .inputPeerChannel(inputPeerChannelData):
                return PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(inputPeerChannelData.channelId))
            default:
                return nil
            }
        }
        if name == "channel", let inputChannel = parameter.value as? Api.InputChannel {
            if case let .inputChannel(inputChannelData) = inputChannel {
                return PeerId(namespace: Namespaces.Peer.CloudChannel, id: PeerId.Id._internalFromInt64Value(inputChannelData.channelId))
            }
            return nil
        }
    }
    return nil
}

// Only results that carry no server state are faked. messages.AffectedMessages holds pts,
// so those requests fail instead; every caller already treats a failure as "done".
func ayuGhostDroppedRequestResult<T>(_ type: T.Type) -> Signal<T, MTRpcError> {
    if T.self == Api.Bool.self, let value = Api.Bool.boolTrue as? T {
        return .single(value)
    }
    if T.self == [Int32].self, let value = [Int32]() as? T {
        return .single(value)
    }
    return .fail(MTRpcError(errorCode: 400, errorDescription: "AYU_GHOST_DROPPED"))
}

func ayuGhostRequestSucceeded(_ description: FunctionDescription, network: Network) {
    guard ayuMessageSendingFunctions.contains(description.name) else {
        return
    }
    let settings = AyuGhostSettings.shared
    guard settings.suppressOnlineStatus else {
        return
    }
    // Scheduling a message does not make the sender online. Never emit a pulse for it,
    // including when the ghost preferences changed while the request was in flight.
    for (name, parameter) in description.parameters where name == "scheduleDate" {
        if let _ = parameter.value as? Int32 {
            return
        }
    }
    ayuPresenceUpdated(network: network)
    // The server shows a sender online anyway; with the pulse it is for 0.2 s only.
    if settings.pulseOnlineOnSend {
        let _ = ayuTrackedPresence(network: network, operation: ayuPresencePulse(network: network)).start()
    } else if settings.sendAutomaticOffline {
        let _ = ayuTrackedPresence(network: network, operation: network.request(Api.functions.account.updateStatus(offline: .boolTrue))).start()
        AyuGhostLastSeen.shared.recordNow()
    }
}

// Replying gives the read state away anyway, so with markReadAfterAction the chat is
// marked as read on the server once a message is sent to it.
func ayuMarkReadAfterAction(account: Account, peerId: PeerId) {
    if !ayuSuppressesReadState(peerId: peerId) || !AyuGhostSettings.shared.markReadAfterAction {
        return
    }
    ayuReadHistoryOnServer(account: account, peerId: peerId, maxId: Int32.max - 1)
}

// Whether a chat's read state is kept from the server, so "Read Message" is offered for it.
public func ayuIsReadStateHidden(peerId: PeerId) -> Bool {
    return ayuSuppressesReadState(peerId: peerId)
}

/// Persist an explicitly authorized read past ghost mode. Completion confirms
/// enqueue, not delivery. Network retry belongs to the authorized Account runner;
/// terminal errors are observable through ayuReadHistoryFailures(account:).
/// A read-all sentinel is frozen at the highest currently known cloud message id;
/// it cannot read future arrivals when retried. Completion is on the main queue.
public func ayuReadHistoryOnServer(account: Account, peerId: PeerId, maxId: Int32, completion: ((AyuReadHistoryEnqueueResult) -> Void)? = nil) {
    let ownerId = account.peerId
    let _ = (account.postbox.transaction { transaction in
        enqueueAyuExplicitRead(transaction: transaction, ownerId: ownerId, peerId: peerId, maxId: maxId)
    } |> deliverOnMainQueue).start(next: { result in completion?(result) })
}
