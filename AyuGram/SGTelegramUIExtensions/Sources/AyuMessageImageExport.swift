import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import AccountContext
import ContextUI
import SGStrings
import SGSimpleSettings
import ChatControllerInteraction
import ChatPresentationInterfaceState
import ChatMessageItemView

// MARK: AyuGram
// "Share as Image": exteraGram's message export, in its plainest form. The message goes out as a picture of
// what the chat shows of it: the bubble on the chat's wallpaper, as wide as the chat. A message that is partly
// off the screen is cut where the screen cuts it.
func ayuMakeShareAsImageContextMenuAction(controllerInteraction: ChatControllerInteraction, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem? {
    guard ExteraSettings.shared.value(.showShareAsImageButton) else {
        return nil
    }
    // What may not be forwarded or saved is not exported as a picture either.
    if chatPresentationInterfaceState.copyProtectionEnabled || message.isCopyProtected() || message.containsSecretMedia || message.id.peerId.namespace == Namespaces.Peer.SecretChat {
        return nil
    }
    if message.adAttribute != nil {
        return nil
    }
    let messageId = message.id
    return .action(ContextMenuActionItem(text: i18n("Extera.ShareAsImage", chatPresentationInterfaceState.strings.baseLanguageCode), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Image"), color: theme.actionSheet.primaryTextColor)
    }, action: { [weak controllerInteraction] controller, f in
        // The picture is taken of the chat itself, so the menu has to be gone first.
        controller?.dismiss(completion: {
            guard let chatNode = controllerInteraction?.chatControllerNode() as? ChatControllerNode else {
                return
            }
            ayuShareMessageAsImage(chatNode: chatNode, messageId: messageId)
        })
    }))
}

private func ayuShareMessageAsImage(chatNode: ChatControllerNode, messageId: MessageId) {
    var frame = CGRect.null
    chatNode.historyNode.forEachVisibleMessageItemNode { itemNode in
        guard let item = itemNode.item else {
            return
        }
        var isExported = false
        for (message, _) in item.content {
            if message.id == messageId {
                isExported = true
                break
            }
        }
        if isExported {
            frame = frame.union(itemNode.view.convert(itemNode.view.bounds, to: chatNode.view))
        }
    }
    frame = frame.intersection(chatNode.frameForVisibleArea()).integral
    guard !frame.isNull, frame.width > 1.0, frame.height > 1.0 else {
        return
    }

    let image = UIGraphicsImageRenderer(size: frame.size).image { _ in
        chatNode.view.drawHierarchy(in: CGRect(origin: CGPoint(x: -frame.minX, y: -frame.minY), size: chatNode.view.bounds.size), afterScreenUpdates: false)
    }
    guard let presenter = chatNode.view.window?.rootViewController else {
        return
    }
    let share = UIActivityViewController(activityItems: [image], applicationActivities: nil)
    if let popover = share.popoverPresentationController {
        popover.sourceView = chatNode.view
        popover.sourceRect = frame
    }
    var top = presenter
    while let presented = top.presentedViewController {
        top = presented
    }
    top.present(share, animated: true)
}
