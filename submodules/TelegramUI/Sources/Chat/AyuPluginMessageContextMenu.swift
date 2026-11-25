import AyuPluginBridge
import AccountContext
import ContextUI
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

/// One invocation owns exactly one visible context menu. The weak controller
/// identity prevents a delayed Python callback from acting on a replacement menu.
@MainActor
final class AyuPluginMessageMenuInvocation {
    weak var chatController: ChatControllerImpl?
    weak var contextController: ContextController?
    let context: AyuPluginMenuContext
    let peerID: PeerId
    let accountID: AccountRecordId
    private var actionStarted = false

    init(chatController: ChatControllerImpl, contextController: ContextController? = nil, context: AyuPluginMenuContext, peerID: PeerId, accountID: AccountRecordId) {
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

    func beginAction() -> Bool {
        guard self.isCurrentMenu() else { return false }
        self.actionStarted = true
        return true
    }

    /// Own dismissal may clear the current pointer. Nil is accepted only after
    /// this action began; any different menu controller means replacement.
    func isCurrentAction() -> Bool {
        guard self.isScreenCurrent(), self.actionStarted, let chat = self.chatController else { return false }
        return chat.currentContextController == nil || chat.currentContextController === self.contextController
    }

    static func dialogID(for peerID: PeerId) -> Int64? {
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
    static func appending(to signal: Signal<ContextController.Items, NoError>, invocation: AyuPluginMessageMenuInvocation) -> Signal<ContextController.Items, NoError> {
        return signal |> mapToSignal { items in
            return Signal<ContextController.Items, NoError> { subscriber in
                let task = Task { @MainActor in
                    guard invocation.isScreenCurrent() else {
                        subscriber.putCompletion()
                        return
                    }
                    // Do not hold native Telegram actions behind serialized Python
                    // condition callbacks. Publish the original menu immediately;
                    // if conditions later allow plugin rows, ContextController
                    // accepts the updated item list as a subsequent signal value.
                    subscriber.putNext(items)
                    let pluginItems = await AyuPluginMenuBridge.shared.items(context: invocation.context, isCurrent: {
                        invocation.isCurrentMenu()
                    })
                    guard !Task.isCancelled, invocation.isCurrentMenu() else {
                        subscriber.putCompletion()
                        return
                    }
                    var updated = items
                    if case var .list(existing) = updated.content, !pluginItems.isEmpty {
                        if !existing.isEmpty { existing.append(.separator) }
                        existing.append(contentsOf: pluginItems.map { item in
                            let identifier = item.itemID ?? item.token
                            let iconName = item.symbolName
                            return .action(ContextMenuActionItem(id: identifier, text: item.text, icon: { theme in
                                guard let iconName, let image = UIImage(systemName: iconName) else { return nil }
                                return image.withTintColor(theme.actionSheet.primaryTextColor, renderingMode: .alwaysOriginal)
                            }, action: { _, dismiss in
                                guard invocation.beginAction() else { return }
                                dismiss(.dismissWithoutContent)
                                Task { @MainActor in
                                    await AyuPluginMenuBridge.shared.perform(token: item.token, context: invocation.context, isCurrent: {
                                        invocation.isCurrentAction()
                                    })
                                }
                            }))
                        })
                        updated.content = .list(existing)
                        subscriber.putNext(updated)
                    }
                    subscriber.putCompletion()
                }
                return ActionDisposable { task.cancel() }
            }
        }
    }
}
