import AyuPluginBridge
import AccountContext
import ContextUI
import Foundation
import PeerInfoScreen
import SwiftSignalKit
import TelegramCore
import UIKit

/// One invocation owns exactly one visible context menu. The weak controller
/// identity keeps plugin rows out of a replacement menu; a click is revalidated
/// by the bridge against the visible screen and account.
@MainActor
final class AyuPluginMessageMenuInvocation {
    weak var chatController: ChatControllerImpl?
    weak var contextController: ContextController?
    let context: AyuPluginMenuContext
    let peerID: EnginePeer.Id
    let accountID: AccountRecordId

    init(chatController: ChatControllerImpl, contextController: ContextController? = nil, context: AyuPluginMenuContext, peerID: EnginePeer.Id, accountID: AccountRecordId) {
        self.chatController = chatController; self.contextController = contextController
        self.context = context; self.peerID = peerID; self.accountID = accountID
    }

    func isScreenCurrent() -> Bool {
        guard let chat = self.chatController, chat.viewIfLoaded?.window != nil,
              let peer = chat.chatLocation.peerId, peer == self.peerID else { return false }
        return AyuTelegramPluginApplicationBinding.current?.isCurrentPluginMenuContext(self.context, accountID: self.accountID, peerID: peer) == true
    }

    func isCurrentMenu() -> Bool {
        guard self.isScreenCurrent(), let chat = self.chatController,
              let menu = self.contextController, chat.currentContextController === menu else { return false }
        return true
    }

    static func dialogID(for peerID: EnginePeer.Id) -> Int64? {
        let value = peerID.id._internalGetInt64Value()
        guard value > 0 else { return nil }
        switch peerID.namespace {
        case Namespaces.Peer.CloudUser:
            return value
        case Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel:
            return -value
        default:
            return nil
        }
    }
}

@MainActor
enum AyuPluginMessageContextMenu {
    /// `menus.add` and `menus.register` rows of the pressed message, through the
    /// helper every plugin menu uses.
    static func appending(to signal: Signal<ContextController.Items, NoError>, invocation: AyuPluginMessageMenuInvocation) -> Signal<ContextController.Items, NoError> {
        guard let messageID = Int32(exactly: invocation.context.messageID) else { return signal }
        let request = AyuPluginMenuRequest(kind: .messageContextMenu, accountKey: invocation.accountID.int64,
            peer: AyuPluginMenuRequest.Peer(namespace: invocation.peerID.namespace._internalGetInt32Value(), id: invocation.peerID.id._internalGetInt64Value()),
            messageID: messageID)
        return AyuPluginContextMenu.appending(to: signal, request: request, isPresented: { invocation.isCurrentMenu() })
    }
}
