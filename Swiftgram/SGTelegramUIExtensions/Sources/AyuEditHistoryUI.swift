import Foundation
import UIKit
import Display
import Postbox
import TelegramCore
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
