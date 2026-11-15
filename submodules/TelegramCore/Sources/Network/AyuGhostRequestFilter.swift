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

func ayuGhostRequestSucceeded(_ functionName: String, network: Network) {
    guard ayuMessageSendingFunctions.contains(functionName) else {
        return
    }
    let settings = AyuGhostSettings.shared
    // The server shows a sender online anyway; with the pulse it is for 0.2 s only.
    if settings.pulseOnlineOnSend {
        let _ = network.request(Api.functions.account.updateStatus(offline: .boolFalse)).start()
        Queue.mainQueue().after(0.2) {
            if AyuGhostSettings.shared.suppressOnlineStatus {
                let _ = network.request(Api.functions.account.updateStatus(offline: .boolTrue)).start()
                AyuGhostLastSeen.shared.recordNow()
            }
        }
    } else if settings.sendAutomaticOffline {
        let _ = network.request(Api.functions.account.updateStatus(offline: .boolTrue)).start()
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

// Marks the chat as read on the server up to maxId, past ghost mode ("Read Message" in AyuGram).
public func ayuReadHistoryOnServer(account: Account, peerId: PeerId, maxId: Int32) {
    let network = account.network
    let stateManager = account.stateManager
    let _ = (account.postbox.transaction { transaction -> Peer? in
        return transaction.getPeer(peerId)
    }
    |> mapToSignal { peer -> Signal<Void, NoError> in
        guard let peer else {
            return .complete()
        }
        if peerId.namespace == Namespaces.Peer.CloudChannel {
            guard let inputChannel = apiInputChannel(peer) else {
                return .complete()
            }
            return network.request(Api.functions.channels.readHistory(channel: inputChannel, maxId: maxId), ayuBypassGhost: true)
            |> `catch` { _ -> Signal<Api.Bool, NoError> in
                return .single(.boolFalse)
            }
            |> mapToSignal { _ -> Signal<Void, NoError> in
                return .complete()
            }
        } else if peerId.namespace == Namespaces.Peer.CloudUser || peerId.namespace == Namespaces.Peer.CloudGroup {
            guard let inputPeer = apiInputPeer(peer) else {
                return .complete()
            }
            return network.request(Api.functions.messages.readHistory(peer: inputPeer, maxId: maxId), ayuBypassGhost: true)
            |> map(Optional.init)
            |> `catch` { _ -> Signal<Api.messages.AffectedMessages?, NoError> in
                return .single(nil)
            }
            |> mapToSignal { result -> Signal<Void, NoError> in
                if let result {
                    switch result {
                    case let .affectedMessages(affectedMessagesData):
                        stateManager?.addUpdateGroups([.updatePts(pts: affectedMessagesData.pts, ptsCount: affectedMessagesData.ptsCount)])
                    }
                }
                return .complete()
            }
        } else {
            return .complete()
        }
    }).start()
}
