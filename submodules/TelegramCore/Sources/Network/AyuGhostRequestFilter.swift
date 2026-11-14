import Foundation
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
