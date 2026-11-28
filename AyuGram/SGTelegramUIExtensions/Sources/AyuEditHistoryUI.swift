import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import AccountContext
import ContextUI
import SGStrings
import SGSimpleSettings
import SGSettingsUI
import ChatControllerInteraction
import ChatPresentationInterfaceState
import ChatMessageItemCommon

// MARK: AyuGram
func ayuMakeEditHistoryContextMenuAction(controllerInteraction: ChatControllerInteraction, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem? {
    let history = message.ayuEditHistory
    if history.isEmpty {
        return nil
    }
    let lang = chatPresentationInterfaceState.strings.baseLanguageCode
    let isDark = chatPresentationInterfaceState.theme.overallDarkAppearance
    return .action(ContextMenuActionItem(text: i18n("Ayu.EditsHistoryTitle", lang), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Edit"), color: theme.actionSheet.primaryTextColor)
    }, action: { _, f in
        if let rootController = controllerInteraction.navigationController()?.view.window?.rootViewController {
            let currentDate = (message.attributes.first(where: { $0 is EditedMessageAttribute }) as? EditedMessageAttribute)?.date ?? message.timestamp
            var versions = history.map { AyuEditHistoryViewController.Version(date: $0.date, text: $0.text) }
            versions.append(AyuEditHistoryViewController.Version(date: currentDate, text: message.text))
            let controller = AyuEditHistoryViewController(
                title: i18n("Ayu.EditsHistoryTitle", lang),
                currentLabel: i18n("Ayu.EditsHistoryCurrent", lang),
                copyLabel: chatPresentationInterfaceState.strings.Conversation_ContextMenuCopy,
                versions: versions.reversed()
            )
            let navigationController = UINavigationController(rootViewController: controller)
            navigationController.overrideUserInterfaceStyle = isDark ? .dark : .light
            rootController.present(navigationController, animated: true)
        }
        f(.default)
    }))
}

// "Read Message": with the chat's read receipts hidden, marks it as read on the server up to this message.
func ayuMakeReadUntilContextMenuAction(context: AccountContext, controllerInteraction: ChatControllerInteraction, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem? {
    if !message.flags.contains(.Incoming) || message.id.namespace != Namespaces.Message.Cloud || !ayuIsReadStateHidden(peerId: message.id.peerId) {
        return nil
    }
    let lang = chatPresentationInterfaceState.strings.baseLanguageCode
    return .action(ContextMenuActionItem(text: i18n("Ayu.ReadUntilMenuText", lang), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Read"), color: theme.actionSheet.primaryTextColor)
    }, action: { _, f in
        guard let navigation = controllerInteraction.navigationController() else { f(.default); return }
        f(.default)
        navigation.pushViewController(ayuReadHistoryController(context: context, peerId: message.id.peerId, requests: [AyuReadHistoryRequest(peerIdValue: message.id.peerId.toInt64(), maxId: message.id.id)]))
    }))
}

// Available even after read hiding was disabled or the selected message became
// outgoing: reopening status never enqueues a read and survives app relaunch.
func ayuMakeReadStatusContextMenuAction(context: AccountContext, controllerInteraction: ChatControllerInteraction, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem? {
    guard message.id.namespace == Namespaces.Message.Cloud else { return nil }
    let lang = chatPresentationInterfaceState.strings.baseLanguageCode
    let localizedTitle = i18n("Ayu.ReadStatus.Title", lang)
    return .action(ContextMenuActionItem(text: localizedTitle == "Ayu.ReadStatus.Title" ? "Read Receipts" : localizedTitle, icon: { theme in
        generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Read"), color: theme.actionSheet.primaryTextColor)
    }, action: { _, f in
        guard let navigation = controllerInteraction.navigationController() else { f(.default); return }
        f(.default)
        navigation.pushViewController(ayuReadHistoryController(context: context, peerId: message.id.peerId))
    }))
}

// "Repeat": sends a copy of the message to the same chat, without the forward header.
func ayuMakeRepeatMessageContextMenuAction(context: AccountContext, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem? {
    if !ExteraSettings.shared.showRepeatButton {
        return nil
    }
    if message.id.namespace != Namespaces.Message.Cloud || message.ayuDeletedDate != nil || !canSendMessagesToChat(chatPresentationInterfaceState) || chatPresentationInterfaceState.copyProtectionEnabled || message.isCopyProtected() {
        return nil
    }
    if message.media.contains(where: { $0 is TelegramMediaAction || $0 is TelegramMediaExpiredContent }) {
        return nil
    }
    let lang = chatPresentationInterfaceState.strings.baseLanguageCode
    return .action(ContextMenuActionItem(text: i18n("Ayu.RepeatMessage", lang), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Resend"), color: theme.actionSheet.primaryTextColor)
    }, action: { _, f in
        let _ = enqueueMessages(account: context.account, peerId: message.id.peerId, messages: [.forward(source: message.id, threadId: chatPresentationInterfaceState.chatLocation.threadId, grouping: .auto, attributes: [ForwardOptionsMessageAttribute(hideNames: true, hideCaptions: false)], correlationId: nil)]).start()
        f(.default)
    }))
}

// "Clear from Cache" (exteraGram): removes the downloaded file of the message from the local cache, so that it goes back to the not downloaded state.
func ayuMakeClearFromCacheContextMenuAction(context: AccountContext, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem? {
    if !ExteraSettings.shared.showClearButton {
        return nil
    }
    if message.id.namespace != Namespaces.Message.Cloud || message.id.peerId.namespace == Namespaces.Peer.SecretChat || message.ayuDeletedDate != nil {
        return nil
    }
    if message.containsSecretMedia || message.attributes.contains(where: { $0 is AutoclearTimeoutMessageAttribute }) {
        return nil
    }
    guard let file = message.media.first(where: { $0 is TelegramMediaFile }) as? TelegramMediaFile else {
        return nil
    }
    if file.isSticker || file.isAnimatedSticker || file.isCustomEmoji || file.isVoice || file.isInstantVideo {
        return nil
    }
    let resourceId = file.resource.id
    if context.account.postbox.mediaBox.completedResourcePath(id: resourceId) == nil {
        return nil
    }
    let lang = chatPresentationInterfaceState.strings.baseLanguageCode
    return .action(ContextMenuActionItem(text: i18n("Extera.ClearFromCache", lang), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Clear"), color: theme.actionSheet.primaryTextColor)
    }, action: { _, f in
        let _ = context.engine.resources.removeCachedResources(ids: [EngineMediaResource.Id(resourceId)], force: true, notify: true).start()
        f(.default)
    }))
}

// "History" (exteraGram): opens the search of the chat restricted to the author of the message. Groups only, in the normal chat mode.
func ayuMakeMessageHistoryContextMenuAction(chatPresentationInterfaceState: ChatPresentationInterfaceState, interfaceInteraction: ChatPanelInterfaceInteraction, message: EngineRawMessage) -> ContextMenuItem? {
    if !ExteraSettings.shared.showHistoryButton {
        return nil
    }
    guard case .standard(.default) = chatPresentationInterfaceState.mode else {
        return nil
    }
    switch chatPresentationInterfaceState.subject {
    case .none, .message:
        break
    default:
        return nil
    }
    switch chatPresentationInterfaceState.chatLocation {
    case .peer:
        break
    case let .replyThread(replyThreadMessage):
        // As on Android, not for the message the thread (comments, topic) starts with.
        if message.id == replyThreadMessage.effectiveTopId {
            return nil
        }
    case .customChatContents:
        return nil
    }
    guard let chatPeer = chatPresentationInterfaceState.renderedPeer?.peer else {
        return nil
    }
    var isGroup = chatPeer is TelegramGroup
    if let channel = chatPeer as? TelegramChannel, case .group = channel.info {
        isGroup = true
    }
    if !isGroup {
        return nil
    }
    guard let author = message.author else {
        return nil
    }
    let lang = chatPresentationInterfaceState.strings.baseLanguageCode
    return .action(ContextMenuActionItem(text: i18n("Extera.MessageHistory", lang), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Time"), color: theme.actionSheet.primaryTextColor)
    }, action: { [weak interfaceInteraction] _, f in
        f(.dismissWithoutContent)
        interfaceInteraction?.beginMessageSearch(.member(author), "")
    }))
}

// "Shadow Ban" for the author of a message in a group.
func ayuMakeShadowBanContextMenuAction(context: AccountContext, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem? {
    guard let authorId = message.author?.id, authorId.namespace == Namespaces.Peer.CloudUser, authorId != context.account.peerId, authorId != message.id.peerId else {
        return nil
    }
    let lang = chatPresentationInterfaceState.strings.baseLanguageCode
    let isBanned = AyuShadowBan.shared.isBanned(peerId: authorId.toInt64())
    return .action(ContextMenuActionItem(text: i18n(isBanned ? "Ayu.FiltersQuickUnshadowBan" : "Ayu.FiltersQuickShadowBan", lang), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: isBanned ? "Chat/Context Menu/Unmute" : "Chat/Context Menu/Muted"), color: theme.actionSheet.primaryTextColor)
    }, action: { _, f in
        AyuShadowBan.shared.setBanned(!isBanned, peerId: authorId.toInt64())
        f(.default)
    }))
}

// "Delete Date" for kept deleted messages and "Read Date" saved locally for outgoing ones.
func ayuMakeMessageDatesContextMenuItems(chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> [ContextMenuItem] {
    let lang = chatPresentationInterfaceState.strings.baseLanguageCode
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    let makeItem: (String, Int32, String) -> ContextMenuItem = { title, date, iconName in
        let text = "\(title): \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(date))))"
        return .action(ContextMenuActionItem(text: text, textFont: .small, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: iconName), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
        }))
    }
    var items: [ContextMenuItem] = []
    if let deletedDate = message.ayuDeletedDate {
        items.append(makeItem(i18n("Ayu.DeleteDateMenuText", lang), deletedDate, "Chat/Context Menu/Delete"))
    }
    if !message.flags.contains(.Incoming), message.id.peerId.namespace == Namespaces.Peer.CloudUser, let readDate = AyuReadDates.shared.readDate(messageId: message.id) {
        items.append(makeItem(i18n("Ayu.ReadDateMenuText", lang), readDate, "Chat/Context Menu/Read"))
    }
    return items
}

final class AyuEditHistoryViewController: UITableViewController {
    struct Version {
        let date: Int32
        let text: String
    }

    private let currentLabel: String
    private let copyLabel: String
    // Newest first.
    private let versions: [Version]
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    init(title: String, currentLabel: String, copyLabel: String, versions: [Version]) {
        self.currentLabel = currentLabel
        self.copyLabel = copyLabel
        self.versions = versions
        super.init(style: .insetGrouped)
        self.title = title
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(self.donePressed))
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "version")
    }

    @objc private func donePressed() {
        self.dismiss(animated: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        return self.versions.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let date = self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(self.versions[section].date)))
        return section == 0 ? "\(self.currentLabel) · \(date)" : date
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "version", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = self.versions[indexPath.section].text
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let text = self.versions[indexPath.section].text
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { _ in
            return UIMenu(children: [
                UIAction(title: self.copyLabel, image: UIImage(systemName: "doc.on.doc"), handler: { _ in
                    UIPasteboard.general.string = text
                })
            ])
        })
    }
}
