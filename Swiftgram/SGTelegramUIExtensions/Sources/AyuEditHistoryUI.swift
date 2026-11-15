import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
import AccountContext
import ContextUI
import SGStrings
import ChatControllerInteraction
import ChatPresentationInterfaceState

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
func ayuMakeReadUntilContextMenuAction(context: AccountContext, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem? {
    if !message.flags.contains(.Incoming) || message.id.namespace != Namespaces.Message.Cloud || !ayuIsReadStateHidden(peerId: message.id.peerId) {
        return nil
    }
    let lang = chatPresentationInterfaceState.strings.baseLanguageCode
    return .action(ContextMenuActionItem(text: i18n("Ayu.ReadUntilMenuText", lang), icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Read"), color: theme.actionSheet.primaryTextColor)
    }, action: { _, f in
        ayuReadHistoryOnServer(account: context.account, peerId: message.id.peerId, maxId: message.id.id)
        f(.default)
    }))
}

// "Repeat": sends a copy of the message to the same chat, without the forward header.
func ayuMakeRepeatMessageContextMenuAction(context: AccountContext, chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> ContextMenuItem? {
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

// "Delete Date" for kept deleted messages and "Read Date" saved locally for outgoing ones.
func ayuMakeMessageDatesContextMenuItems(chatPresentationInterfaceState: ChatPresentationInterfaceState, message: EngineRawMessage) -> [ContextMenuItem] {
    let lang = chatPresentationInterfaceState.strings.baseLanguageCode
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    let makeItem: (String, Int32) -> ContextMenuItem = { title, date in
        let text = "\(title): \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(date))))"
        return .action(ContextMenuActionItem(text: text, textFont: .small, icon: { _ in
            return nil
        }, action: { _, f in
            f(.default)
        }))
    }
    var items: [ContextMenuItem] = []
    if let deletedDate = message.ayuDeletedDate {
        items.append(makeItem(i18n("Ayu.DeleteDateMenuText", lang), deletedDate))
    }
    if !message.flags.contains(.Incoming), message.id.peerId.namespace == Namespaces.Peer.CloudUser, let readDate = AyuReadDates.shared.readDate(messageId: message.id) {
        items.append(makeItem(i18n("Ayu.ReadDateMenuText", lang), readDate))
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
