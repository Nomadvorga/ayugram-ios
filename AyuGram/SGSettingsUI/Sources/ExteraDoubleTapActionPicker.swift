import AccountContext
import Foundation
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramPresentationData
import UIKit

/// Reference 85's centered, scrollable action dialog. Selection writes only after
/// an explicit row tap; Cancel, backdrop and accessibility escape leave it intact.
func exteraDoubleTapActionPicker(context: AccountContext, incoming: Bool, selected: ExteraChatSettings.DoubleTapAction, selectedAction: @escaping (ExteraChatSettings.DoubleTapAction) -> Void) -> UIViewController {
    return ExteraDoubleTapActionPicker(context: context, incoming: incoming, selected: selected, selectedAction: selectedAction)
}

private final class ExteraDoubleTapActionPicker: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let incoming: Bool
    private let selected: ExteraChatSettings.DoubleTapAction
    private let selectedAction: (ExteraChatSettings.DoubleTapAction) -> Void
    private let actions: [ExteraChatSettings.DoubleTapAction]
    private var data: PresentationData
    private var presentationDisposable: Disposable?
    private let backdrop = UIButton(type: .custom)
    private let card = UIView()
    private let heading = UILabel()
    private let table = UITableView(frame: .zero, style: .plain)
    private let cancel = UIButton(type: .system)
    private var didChoose = false

    private func iconRole(for action: ExteraChatSettings.DoubleTapAction) -> ExteraUIIconRole? {
        guard self.incoming else { return nil }
        switch action {
        case .disabled: return .disabled
        case .reaction: return .doubleTapReactions
        case .reply: return .doubleTapReply
        case .copy: return .copy
        case .forward: return .doubleTapForward
        case .save: return .saved
        case .repeatMessage: return .repeatAction
        case .delete: return .delete
        case .translate: return .translate
        case .read: return .readUntil
        case .inherit, .edit: return nil
        }
    }

    init(context: AccountContext, incoming: Bool, selected: ExteraChatSettings.DoubleTapAction, selectedAction: @escaping (ExteraChatSettings.DoubleTapAction) -> Void) {
        self.incoming = incoming
        self.selected = selected
        self.selectedAction = selectedAction
        self.actions = ExteraChatSettings.DoubleTapAction.allCases.filter {
            incoming ? ($0 != .inherit && $0 != .edit) : ($0 != .read)
        }
        self.data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
        self.presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.data = data
            if self.isViewLoaded { self.updatePresentation() }
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.presentationDisposable?.dispose() }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.accessibilityViewIsModal = true
        self.backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        self.backdrop.isAccessibilityElement = false
        self.backdrop.addTarget(self, action: #selector(self.cancelPressed), for: .touchUpInside)
        self.view.addSubview(self.backdrop)
        self.view.addSubview(self.card)
        self.card.layer.cornerRadius = 24
        self.card.clipsToBounds = true
        self.heading.numberOfLines = 0
        self.heading.accessibilityTraits = .header
        self.card.addSubview(self.heading)
        self.table.dataSource = self
        self.table.delegate = self
        self.table.separatorStyle = .none
        self.table.contentInsetAdjustmentBehavior = .never
        self.table.backgroundColor = .clear
        self.table.register(UITableViewCell.self, forCellReuseIdentifier: "action")
        self.card.addSubview(self.table)
        self.cancel.addTarget(self, action: #selector(self.cancelPressed), for: .touchUpInside)
        self.card.addSubview(self.cancel)
        self.updatePresentation()
    }

    private func updatePresentation() {
        let theme = self.data.theme
        let language = self.data.strings.baseLanguageCode
        self.card.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.heading.text = i18n(self.incoming ? "Extera.DoubleTapPicker.Incoming" : "Extera.DoubleTapPicker.Outgoing", language)
        self.heading.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 20, weight: .semibold))
        self.heading.textColor = theme.list.itemPrimaryTextColor
        self.cancel.setTitle(self.data.strings.Common_Cancel, for: .normal)
        self.cancel.setTitleColor(theme.list.itemAccentColor, for: .normal)
        self.cancel.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        self.table.rowHeight = max(50, UIFont.preferredFont(forTextStyle: .body).lineHeight + 22)
        self.table.reloadData()
        self.view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.backdrop.frame = self.view.bounds
        let safe = self.view.bounds.inset(by: self.view.safeAreaInsets)
        let width = max(0, min(420, safe.width - 32))
        let titleHeight = self.heading.sizeThatFits(CGSize(width: max(0, width - 48), height: .greatestFiniteMagnitude)).height
        let headerHeight = titleHeight + 38
        let footerHeight: CGFloat = 60
        let height = max(0, min(safe.height - 32, headerHeight + CGFloat(self.actions.count) * self.table.rowHeight + footerHeight))
        self.card.frame = CGRect(x: safe.midX - width / 2, y: safe.midY - height / 2, width: width, height: height)
        self.heading.frame = CGRect(x: 24, y: 20, width: max(0, width - 48), height: titleHeight)
        self.table.frame = CGRect(x: 8, y: headerHeight, width: max(0, width - 16), height: max(0, height - headerHeight - footerHeight))
        self.table.isScrollEnabled = self.table.contentSize.height > self.table.bounds.height
        self.cancel.frame = CGRect(x: max(0, width - 132), y: height - footerHeight, width: 112, height: footerHeight)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return self.actions.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let action = self.actions[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "action", for: indexPath)
        let key: String
        let symbol: String
        switch action {
        case .inherit: key = "Extera.DoubleTapAction.Inherit"; symbol = "arrow.turn.down.right"
        case .disabled: key = "Extera.DoubleTapAction.Disabled"; symbol = "nosign"
        case .reaction: key = "Extera.DoubleTapAction.Reaction"; symbol = "heart"
        case .reply: key = "Extera.DoubleTapAction.Reply"; symbol = "arrowshape.turn.up.left"
        case .copy: key = "Extera.DoubleTapAction.Copy"; symbol = "doc.on.doc"
        case .forward: key = "Extera.DoubleTapAction.Forward"; symbol = "arrowshape.turn.up.right"
        case .edit: key = "Extera.DoubleTapAction.Edit"; symbol = "pencil"
        case .save: key = "Extera.DoubleTapAction.Save"; symbol = "bookmark"
        case .repeatMessage: key = "Ayu.RepeatMessage"; symbol = "plus.message"
        case .delete: key = "Extera.DoubleTapAction.Delete"; symbol = "trash"
        case .translate: key = "Extera.DoubleTapAction.Translate"; symbol = "character.bubble"
        case .read: key = "Extera.DoubleTapAction.Read"; symbol = "eye"
        }
        var content = cell.defaultContentConfiguration()
        content.text = i18n(key, self.data.strings.baseLanguageCode)
        content.textProperties.color = self.data.theme.list.itemPrimaryTextColor
        content.textProperties.font = UIFont.preferredFont(forTextStyle: .body)
        let fallback = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 23, weight: .regular))
        content.image = self.iconRole(for: action).flatMap { role in
            ExteraUIIconProvider.current.image(for: role, fallback: fallback)
        } ?? fallback
        content.imageProperties.tintColor = self.data.theme.list.itemSecondaryTextColor
        content.imageToTextPadding = 24
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        cell.accessibilityTraits = action == self.selected ? [.button, .selected] : .button
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !self.didChoose else { return }
        self.didChoose = true
        let action = self.actions[indexPath.row]
        let selectedAction = self.selectedAction
        self.dismiss(animated: true, completion: { selectedAction(action) })
    }

    @objc private func cancelPressed() { self.dismiss(animated: true) }
    override func accessibilityPerformEscape() -> Bool { self.cancelPressed(); return true }
}
