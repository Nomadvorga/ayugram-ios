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

private let ayuMessageSendingFunctions: Set<String> = [
    "messages.sendMessage",
    "messages.sendMedia",
    "messages.sendMultiMedia",
    "messages.forwardMessages",
    "messages.sendInlineBotResult",
]

func ayuGhostShouldDrop(_ functionName: String) -> Bool {
    let settings = AyuGhostSettings.shared
    if ayuReadMessageFunctions.contains(functionName) {
        return !settings.sendReadMessagePackets
    }
    if ayuReadStoryFunctions.contains(functionName) {
        return !settings.sendReadStoryPackets
    }
    if ayuTypingFunctions.contains(functionName) {
        return !settings.sendUploadProgress
    }
    return false
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
    if settings.sendOnlinePackets || !settings.sendOfflinePacketAfterOnline {
        return
    }
    let _ = network.request(Api.functions.account.updateStatus(offline: .boolTrue)).start()
}

// Replying gives the read state away anyway, so with markReadAfterAction the chat is
// marked as read on the server once a message is sent to it.
func ayuMarkReadAfterAction(account: Account, peerId: PeerId) {
    let settings = AyuGhostSettings.shared
    if settings.sendReadMessagePackets || !settings.markReadAfterAction {
        return
    }
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
            return network.request(Api.functions.channels.readHistory(channel: inputChannel, maxId: Int32.max - 1), ayuBypassGhost: true)
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
            return network.request(Api.functions.messages.readHistory(peer: inputPeer, maxId: Int32.max - 1), ayuBypassGhost: true)
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
