import AccountContext
import AsyncDisplayKit
import ChatControllerInteraction
import ChatMessageItem
import ChatMessageItemView
import ChatPresentationInterfaceState
import ContextUI
import Display
import Foundation
import ImageIO
import PresentationDataUtils
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

// Native iOS counterparts of exteraGram's non-plugin message actions.
// The Android implementation is in ChatActivity / MessageDetailsPopupWrapper.
private func exteraMenuText(_ key: String, fallback: String, state: ChatPresentationInterfaceState) -> String {
    let text = i18n(key, state.strings.baseLanguageCode)
    return text == key ? fallback : text
}

func exteraCopyPhotoContextMenuAction(context: AccountContext, state: ChatPresentationInterfaceState, message: EngineRawMessage, interaction: ChatControllerInteraction, resourceAvailable: Bool) -> ContextMenuItem? {
    guard ExteraMenuSettings.shared.showCopyPhotoButton, resourceAvailable,
          !state.copyProtectionEnabled, !state.myCopyProtectionEnabled, !message.isCopyProtected(), !message.containsSecretMedia,
          !message.media.contains(where: { $0 is TelegramMediaPaidContent || $0 is TelegramMediaExpiredContent }),
          let image = message.effectiveMedia.compactMap({ $0 as? TelegramMediaImage }).first,
          let representation = largestImageRepresentation(image.representations) else {
        return nil
    }
    return .action(ContextMenuActionItem(id: "extera.copyPhoto", text: exteraMenuText("Extera.CopyPhoto", fallback: "Copy Photo", state: state), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor)
    }, action: { _, dismiss in
        dismiss(.default)
        let _ = (context.engine.resources.data(resource: EngineMediaResource(representation.resource), incremental: false)
        |> take(1)
        |> mapToSignal { data -> Signal<(String, Data)?, NoError> in
            return Signal { subscriber in
                let image: (String, Data)?
                if data.isComplete, let bytes = try? Data(contentsOf: URL(fileURLWithPath: data.path), options: .mappedIfSafe),
                   let source = CGImageSourceCreateWithData(bytes as CFData, nil), let type = CGImageSourceGetType(source) {
                    image = (type as String, bytes)
                } else {
                    image = nil
                }
                subscriber.putNext(image)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            |> runOn(Queue.concurrentDefaultQueue())
        }
        |> deliverOnMainQueue).startStandalone(next: { data in
            guard let (type, bytes) = data else {
                return
            }
            // Keep the original encoded image. Assigning UIImage here makes
            // UIKit decode and re-encode a full-resolution photo on the main queue.
            UIPasteboard.general.setItems([[type: bytes]])
            interaction.displayUndo(.copy(text: state.strings.Conversation_ImageCopied))
        })
    }))
}

func exteraClearMessageCacheContextMenuAction(context: AccountContext, state: ChatPresentationInterfaceState, message: EngineRawMessage, resourceAvailable: Bool) -> ContextMenuItem? {
    guard ExteraMenuSettings.shared.showClearButton, resourceAvailable,
          message.id.namespace == Namespaces.Message.Cloud, !message.containsSecretMedia,
          message.effectiveMedia.contains(where: { $0 is TelegramMediaImage || $0 is TelegramMediaFile }) else {
        return nil
    }
    return .action(ContextMenuActionItem(text: state.strings.Conversation_ClearCache, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Clear"), color: theme.contextMenu.primaryColor)
    }, action: { _, dismiss in
        dismiss(.default)
        // The storage engine updates resource status and the cache index together;
        // deleting the file directly leaves the download button stale.
        let _ = context.engine.resources.clearStorage(messages: [EngineMessage(message)]).startStandalone()
    }))
}

func exteraAuthorHistoryContextMenuAction(state: ChatPresentationInterfaceState, message: EngineRawMessage, interaction: ChatPanelInterfaceInteraction) -> ContextMenuItem? {
    guard ExteraMenuSettings.shared.showHistoryButton, message.id.namespace == Namespaces.Message.Cloud,
          let peer = state.renderedPeer?.peer, let author = message.author else {
        return nil
    }
    if let channel = peer as? TelegramChannel {
        guard case .group = channel.info else { return nil }
    } else if !(peer is TelegramGroup) {
        return nil
    }
    return .action(ContextMenuActionItem(text: exteraMenuText("Extera.MessageHistory", fallback: "Message History", state: state), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Search"), color: theme.contextMenu.primaryColor)
    }, action: { controller, dismiss in
        let beginSearch = { interaction.beginMessageSearch(.member(author), "") }
        if let controller {
            controller.dismiss(completion: beginSearch)
        } else {
            dismiss(.default)
            beginSearch()
        }
    }))
}

// Direct repetition must respect the same content permissions as an ordinary
// send. Restrictive states do not offer this shortcut.
func exteraCanRepeatMessage(context: AccountContext, state: ChatPresentationInterfaceState, messages: [EngineRawMessage]) -> Bool {
    guard !context.isFrozen, canSendMessagesToChat(state), !state.isPremiumRequiredForMessaging,
          state.sendPaidMessageStars == nil, state.slowmodeState == nil,
          !state.copyProtectionEnabled, !state.myCopyProtectionEnabled,
          state.chatLocation.peerId != context.account.peerId,
          let peer = state.renderedPeer?.peer else {
        return false
    }
    if state.threadData?.isClosed == true || state.isGeneralThreadClosed == true {
        return false
    }
    if let channel = peer as? TelegramChannel {
        guard case .group = channel.info, !channel.isMonoForum else { return false }
        if channel.isForumOrMonoForum && state.chatLocation.threadId == nil {
            return false
        }
    }
    let isBanned: (TelegramChatBannedRightsFlags) -> Bool = { rights in
        if let channel = peer as? TelegramChannel {
            return channel.hasBannedPermission(rights, ignoreDefault: canBypassRestrictions(chatPresentationInterfaceState: state)) != nil
        } else if let group = peer as? TelegramGroup {
            return group.hasBannedPermission(rights)
        }
        return false
    }
    for message in messages {
        guard message.id.namespace == Namespaces.Message.Cloud, message.ayuDeletedDate == nil,
              state.chatLocation.peerId == message.id.peerId,
              !message.isCopyProtected(), !message.containsSecretMedia,
              !message.flags.isSending, !message.flags.contains(.Failed) else {
            return false
        }
        if (!message.text.isEmpty || message.attributes.contains(where: { $0 is RichTextMessageAttribute })) && isBanned(.banSendText) {
            return false
        }
        for media in message.media {
            if media is TelegramMediaAction || media is TelegramMediaExpiredContent || media is TelegramMediaPaidContent || media is TelegramMediaStory {
                return false
            } else if media is TelegramMediaImage {
                if isBanned(.banSendMedia) || isBanned(.banSendPhotos) { return false }
            } else if let file = media as? TelegramMediaFile {
                let rights: TelegramChatBannedRightsFlags
                if file.isSticker { rights = .banSendStickers }
                else if file.isAnimated { rights = .banSendGifs }
                else if file.isInstantVideo { rights = .banSendInstantVideos }
                else if file.isVoice { rights = .banSendVoice }
                else if file.isMusic { rights = .banSendMusic }
                else if file.isVideo { rights = .banSendVideos }
                else { rights = .banSendFiles }
                if isBanned(.banSendMedia) || isBanned(rights) { return false }
            } else if media is TelegramMediaPoll {
                if isBanned(.banSendPolls) { return false }
            } else if media is TelegramMediaGame {
                if isBanned(.banSendGames) || isBanned(.banSendText) { return false }
            } else if let map = media as? TelegramMediaMap, map.liveBroadcastingTimeout != nil {
                return false
            } else if isBanned(.banSendText) {
                // Contacts, static locations and link previews still
                // require permission to send message content.
                return false
            }
        }
    }
    return !messages.isEmpty
}

func exteraRepeatMessageContextMenuAction(context: AccountContext, state: ChatPresentationInterfaceState, messages: [EngineRawMessage], interaction: ChatControllerInteraction, canForward: Bool) -> ContextMenuItem? {
    guard ExteraMenuSettings.shared.showRepeatMessageButton, canForward,
          exteraCanRepeatMessage(context: context, state: state, messages: messages) else {
        return nil
    }
    return .action(ContextMenuActionItem(text: i18n("Ayu.RepeatMessage", state.strings.baseLanguageCode), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Resend"), color: theme.contextMenu.primaryColor)
    }, action: { _, dismiss in
        dismiss(.default)
        exteraRepeatMessages(context: context, state: state, messages: messages, interaction: interaction)
    }))
}

/// Shared by the context menu and the explicit Repeat double-tap action.
func exteraRepeatMessages(context: AccountContext, state: ChatPresentationInterfaceState, messages: [EngineRawMessage], interaction: ChatControllerInteraction) {
        guard exteraCanRepeatMessage(context: context, state: state, messages: messages), let firstMessage = messages.first else { return }
        let outgoing: [EnqueueMessage] = messages.sorted(by: { $0.id < $1.id }).map { message in
            return .forward(source: message.id, threadId: state.chatLocation.threadId, grouping: .auto, attributes: [ForwardOptionsMessageAttribute(hideNames: true, hideCaptions: false)], correlationId: nil)
        }
        let send = {
            guard !context.isFrozen else { return }
            let _ = enqueueMessages(account: context.account, peerId: firstMessage.id.peerId, messages: outgoing).startStandalone()
        }
        var confirmationKey: String?
        for message in messages {
            for media in message.media {
                if let file = media as? TelegramMediaFile {
                    if file.isSticker, AyuSendConfirmations.shared.isEnabled(.sticker) { confirmationKey = "Ayu.ConfirmationSticker" }
                    else if file.isAnimated, AyuSendConfirmations.shared.isEnabled(.gif) { confirmationKey = "Ayu.ConfirmationGIF" }
                    else if file.isVoice, AyuSendConfirmations.shared.isEnabled(.voice) { confirmationKey = "Ayu.ConfirmationVoice" }
                    else if file.isInstantVideo, AyuSendConfirmations.shared.isEnabled(.round) { confirmationKey = "Ayu.ConfirmationRound" }
                }
            }
        }
        if let confirmationKey {
            let alert = textAlertController(context: context, title: nil, text: i18n(confirmationKey, state.strings.baseLanguageCode), actions: [
                TextAlertAction(type: .genericAction, title: state.strings.Common_No, action: {}),
                TextAlertAction(type: .defaultAction, title: state.strings.Common_Yes, action: send),
            ])
            Queue.mainQueue().after(0.2) { interaction.presentController(alert, nil) }
        } else {
            send()
        }
}

func exteraMessageDetailsContextMenuAction(state: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem? {
    guard ExteraMenuSettings.shared.showDetailsButton, !message.containsSecretMedia else { return nil }
    let canCopy = !state.copyProtectionEnabled && !state.myCopyProtectionEnabled && !message.isCopyProtected()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: state.strings.baseLanguageCode)
    formatter.dateStyle = .medium
    formatter.timeStyle = .medium
    let formatDate: (Int32) -> String = { formatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }
    var fields: [(String, String)] = [("ID", "\(message.id.id)"), ("Chat ID", "\(message.id.peerId.toInt64())"), ("Date", formatDate(message.timestamp))]
    if let author = message.author {
        fields.append(("Author", "\(EnginePeer(author).compactDisplayTitle) (\(author.id.toInt64()))"))
    }
    if let forwardInfo = message.forwardInfo {
        fields.append(("Forwarded Date", formatDate(forwardInfo.date)))
    }
    for attribute in message.attributes {
        if let edited = attribute as? EditedMessageAttribute, !edited.isHidden {
            fields.append(("Edited Date", formatDate(edited.date)))
        } else if let views = attribute as? ViewCountMessageAttribute {
            fields.append(("Views", "\(views.count)"))
        } else if let forwards = attribute as? ForwardCountMessageAttribute {
            fields.append(("Forwards", "\(forwards.count)"))
        }
    }
    if let date = message.ayuDeletedDate { fields.append(("Deleted Date", formatDate(date))) }
    if !message.flags.contains(.Incoming), let date = AyuReadDates.shared.readDate(messageId: message.id) {
        fields.append(("Read Date", formatDate(date)))
    }
    for media in message.effectiveMedia {
        if let file = media as? TelegramMediaFile {
            if let name = file.fileName { fields.append(("File Name", name)) }
            fields.append(("MIME Type", file.mimeType))
            if let size = file.size { fields.append(("File Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
            if let dimensions = file.dimensions { fields.append(("Resolution", "\(dimensions.width) × \(dimensions.height)")) }
            if let duration = file.duration { fields.append(("Duration", "\(duration) s")) }
        } else if let image = media as? TelegramMediaImage, let representation = largestImageRepresentation(image.representations) {
            fields.append(("Resolution", "\(representation.dimensions.width) × \(representation.dimensions.height)"))
        }
    }
    let items: [ContextMenuItem] = fields.map { label, value in
        let labelKey = "Extera.MessageDetails." + label.replacingOccurrences(of: " ", with: "")
        let action: ((ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void)?
        if canCopy {
            action = { _, dismiss in
                UIPasteboard.general.string = value
                dismiss(.default)
            }
        } else {
            action = nil
        }
        return .action(ContextMenuActionItem(text: "\(exteraMenuText(labelKey, fallback: label, state: state)): \(value)", textLayout: .multiline, icon: { theme in
            return canCopy ? generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor) : nil
        }, action: action))
    }
    return .action(ContextMenuActionItem(text: exteraMenuText("Extera.Details", fallback: "Details", state: state), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Info"), color: theme.contextMenu.primaryColor)
    }, action: { controller, _ in
        var detailItems: [ContextMenuItem] = [.action(ContextMenuActionItem(text: state.strings.Common_Back, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.contextMenu.primaryColor)
        }, iconPosition: .left, action: { controller, _ in controller?.popItems() })), .separator]
        detailItems.append(contentsOf: items)
        controller?.pushItems(items: .single(ContextController.Items(content: .list(detailItems))))
    }))
}

func exteraMessageImageExportContextMenuAction(state: ChatPresentationInterfaceState, message: EngineRawMessage, sourceNode: ChatMessageItemView?, interaction: ChatControllerInteraction, canForward: Bool) -> ContextMenuItem? {
    guard ExteraMenuSettings.shared.showMessageImageExportButton, canForward,
          !state.copyProtectionEnabled, !state.myCopyProtectionEnabled,
          !message.isCopyProtected(), !message.containsSecretMedia,
          message.id.peerId.namespace != Namespaces.Peer.SecretChat,
          message.id.namespace == Namespaces.Message.Cloud, message.groupingKey == nil,
          !message.media.contains(where: { $0 is TelegramMediaPaidContent || $0 is TelegramMediaExpiredContent }),
          let sourceNode, sourceNode.isNodeLoaded, sourceNode.view.window != nil,
          let item = sourceNode.item, item.message.id == message.id,
          item.message.stableId == message.stableId, item.additionalContent == nil,
          case .message = item.content else {
        return nil
    }
    return .action(ContextMenuActionItem(text: exteraMenuText("Extera.ExportMessageImage", fallback: "Export Image", state: state), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Save"), color: theme.contextMenu.primaryColor)
    }, action: { [weak sourceNode] controller, dismiss in
        let output: ExteraMessageImageExport.Output
        do {
            guard let sourceNode else {
                dismiss(.default)
                return
            }
            // Capture the live, extracted message tree before dismissal restores it
            // to the rotated history. The helper rechecks identity, permissions,
            // visibility and allocation limits, including the bound message.
            output = try ExteraMessageImageExport.capture(node: sourceNode, message: message, allowExport: canForward && !state.copyProtectionEnabled && !state.myCopyProtectionEnabled, backgroundColor: state.theme.chatList.backgroundColor)
        } catch {
            dismiss(.default)
            interaction.displayUndo(.info(title: nil, text: exteraMenuText("Extera.MessageImageExportUnavailable", fallback: "This message cannot be exported. Keep the entire message visible and try again.", state: state), timeout: nil, customUndoText: nil))
            return
        }
        // Capture only the bitmap in the dismissal completion. Output also owns
        // PNG data, which the UIImage share path does not need to retain.
        let image = output.image
        let presentShare = {
            guard let rootController = interaction.navigationController()?.view.window?.rootViewController else { return }
            var presenter = rootController
            while let presented = presenter.presentedViewController { presenter = presented }
            let shareController = UIActivityViewController(activityItems: [image], applicationActivities: nil)
            if let popover = shareController.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1.0, height: 1.0)
            }
            presenter.present(shareController, animated: true)
        }
        if let controller {
            controller.dismiss(completion: presentShare)
        } else {
            dismiss(.default)
            Queue.mainQueue().after(0.2, presentShare)
        }
    }))
}

/// Reuse actions already admitted by Telegram's permission checks. Identifiers
/// are assigned only to ordinary actions; countdown-delete rows stay intact.
func exteraGroupMessageContextMenuActions(_ items: inout [ContextMenuItem]) {
    guard ExteraMenuSettings.shared.groupMessageMenu else { return }
    let actionCount = items.reduce(0) { count, item in
        if case .action = item { return count + 1 }
        return count
    }
    guard actionCount > 5 else { return }
    let order = ["extera.group.reply", "extera.group.delete", "extera.group.copy", "extera.copyPhoto", "extera.group.edit", "extera.group.link", "extera.group.forward"]
    let available = items.compactMap { item -> ContextMenuActionItem? in
        if case let .action(action) = item { return action }
        return nil
    }
    var grouped: [ContextMenuActionItem] = []
    for id in order {
        if id == "extera.copyPhoto", grouped.contains(where: { $0.id == AnyHashable("extera.group.copy") }) {
            continue
        }
        if let item = available.first(where: { $0.id == AnyHashable(id) }) {
            grouped.append(item)
        }
    }
    guard grouped.count >= 2 else { return }
    let ids = Set(grouped.compactMap(\.id))
    items.removeAll(where: { item in
        if case let .action(action) = item, let id = action.id { return ids.contains(id) }
        return false
    })
    // Reference 56: ordinary actions form the bottom row. Keep informational
    // content and all other permission-filtered actions above it.
    var normalized: [ContextMenuItem] = []
    for item in items {
        if case .separator = item {
            guard let previous = normalized.last else { continue }
            if case .separator = previous { continue }
        }
        normalized.append(item)
    }
    if let last = normalized.last, case .separator = last { normalized.removeLast() }
    if !normalized.isEmpty { normalized.append(.separator) }
    normalized.append(.custom(ExteraQuickActionsItem(actions: grouped), false))
    items = normalized
}

private final class ExteraQuickActionsItem: ContextMenuCustomItem {
    let actions: [ContextMenuActionItem]

    init(actions: [ContextMenuActionItem]) {
        self.actions = actions
    }

    func node(presentationData: PresentationData, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) -> ContextMenuCustomNode {
        return ExteraQuickActionsNode(actions: self.actions, presentationData: presentationData, getController: getController, actionSelected: actionSelected)
    }
}

private final class ExteraQuickActionsNode: ASDisplayNode, ContextMenuCustomNode, ContextActionNodeProtocol {
    private let buttons: [ExteraQuickActionButton]

    var isActionEnabled: Bool { return false }
    var needsPadding: Bool { return false }

    init(actions: [ContextMenuActionItem], presentationData: PresentationData, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) {
        self.buttons = actions.map { ExteraQuickActionButton(action: $0, getController: getController, actionSelected: actionSelected) }
        super.init()
        for button in self.buttons { self.addSubnode(button) }
        self.updateTheme(presentationData: presentationData)
    }

    func updateLayout(constrainedWidth: CGFloat, constrainedHeight: CGFloat) -> (CGSize, (CGSize, ContainedViewLayoutTransition) -> Void) {
        let width = min(constrainedWidth, max(240.0, CGFloat(self.buttons.count) * 48.0))
        return (CGSize(width: width, height: 56.0), { [weak self] size, transition in
            guard let self else { return }
            let buttonWidth = size.width / CGFloat(self.buttons.count)
            for (index, button) in self.buttons.enumerated() {
                transition.updateFrame(node: button, frame: CGRect(x: CGFloat(index) * buttonWidth, y: 0.0, width: buttonWidth, height: size.height))
            }
        })
    }

    func updateTheme(presentationData: PresentationData) {
        self.backgroundColor = presentationData.theme.contextMenu.itemBackgroundColor
        for button in self.buttons { button.updateTheme(presentationData: presentationData) }
    }

    func canBeHighlighted() -> Bool { return false }
    func updateIsHighlighted(isHighlighted: Bool) {}
    func setIsHighlighted(_ value: Bool) {}
    func performAction() {}

    func actionNode(at point: CGPoint) -> ContextActionNodeProtocol {
        if let button = self.buttons.first(where: { $0.frame.contains(point) }) { return button }
        return self
    }
}

private final class ExteraQuickActionButton: HighlightTrackingButtonNode, ContextActionNodeProtocol {
    private let actionItem: ContextMenuActionItem
    private let getController: () -> ContextControllerProtocol?
    private let actionSelected: (ContextMenuActionResult) -> Void

    var isActionEnabled: Bool { return self.actionItem.action != nil }

    init(action: ContextMenuActionItem, getController: @escaping () -> ContextControllerProtocol?, actionSelected: @escaping (ContextMenuActionResult) -> Void) {
        self.actionItem = action
        self.getController = getController
        self.actionSelected = actionSelected
        super.init()
        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
        self.accessibilityLabel = action.text
        self.addTarget(self, action: #selector(self.pressed), forControlEvents: .touchUpInside)
        self.highligthedChanged = { [weak self] value in self?.setIsHighlighted(value) }
    }

    func updateTheme(presentationData: PresentationData) {
        self.setImage(self.actionItem.icon(presentationData.theme), for: .normal)
    }

    @objc private func pressed() { self.performAction() }

    func setIsHighlighted(_ value: Bool) { self.alpha = value ? 0.4 : 1.0 }

    func performAction() {
        self.actionItem.action?(ContextMenuActionItem.Action(controller: self.getController(), dismissWithResult: self.actionSelected, updateAction: { _, _ in }))
    }

    func actionNode(at point: CGPoint) -> ContextActionNodeProtocol { return self }
}
