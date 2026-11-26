import AccountContext
import Display
import SGSimpleSettings
import SwiftSignalKit
import TelegramPresentationData
import UIKit

public func exteraPillDashboardController(context: AccountContext, edit: ((ViewController, ExteraPillSpec?) -> Void)? = nil, transfer: ((ViewController) -> Void)? = nil) -> ViewController {
    ExteraPillStackController(context: context, edit: edit, transfer: transfer)
}

private final class ExteraPillStackController: ViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let context: AccountContext
    private let editPill: ((ViewController, ExteraPillSpec?) -> Void)?
    private let transfer: ((ViewController) -> Void)?
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let search = UISearchBar()
    private let preview: ExteraPillStackView
    private var data: PresentationData
    private var presentation: Disposable?
    private var observers: [NSObjectProtocol] = []
    private var layout = ExteraPillStackLayout()
    private var custom: [ExteraPillSpec] = []
    private var query = ""

    init(context: AccountContext, edit: ((ViewController, ExteraPillSpec?) -> Void)?, transfer: ((ViewController) -> Void)?) {
        self.context = context; self.editPill = edit; self.transfer = transfer
        self.data = context.sharedContext.currentPresentationData.with { $0 }
        self.preview = ExteraPillStackView(context: context)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.data))
        self.title = "Pill Stack"
        self.presentation = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }; self.data = data
            self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: data), transition: .immediate)
            if self.isViewLoaded { self.applyTheme(); self.reload(); self.table.reloadData() }
        })
        for name in [ExteraPillSettings.didChange, ExteraPillStackSettings.didChange] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in DispatchQueue.main.async { self?.reload() } })
        }
    }
    required init(coder: NSCoder) { preconditionFailure() }
    deinit { self.presentation?.dispose(); for observer in self.observers { NotificationCenter.default.removeObserver(observer) } }
    private func text(_ en: String, _ ru: String) -> String { exteraPillText(self.data.strings.baseLanguageCode, en, ru) }
    override func viewDidLoad() {
        super.viewDidLoad()
        self.table.dataSource = self; self.table.delegate = self
        self.table.rowHeight = UITableView.automaticDimension; self.table.estimatedRowHeight = 56
        self.table.contentInsetAdjustmentBehavior = .never
        self.table.allowsSelectionDuringEditing = true; self.table.setEditing(true, animated: false)
        self.search.delegate = self; self.search.searchBarStyle = .minimal
        self.search.frame = CGRect(x: 0, y: 0, width: 320, height: 56)
        self.table.tableHeaderView = self.search
        self.view.insertSubview(self.table, at: 0)
        self.applyTheme(); self.reload()
    }
    private func applyTheme() {
        self.view.backgroundColor = self.data.theme.list.blocksBackgroundColor
        self.table.backgroundColor = self.data.theme.list.blocksBackgroundColor
        self.table.separatorColor = self.data.theme.list.itemBlocksSeparatorColor
        self.table.tintColor = self.data.theme.list.itemAccentColor
        self.search.placeholder = self.text("Find widget", "Найти виджет")
        self.search.searchTextField.textColor = self.data.theme.list.itemPrimaryTextColor
        self.preview.apply(theme: self.data.theme, language: self.data.strings.baseLanguageCode)
    }
    private func reload() {
        let custom = ExteraPillSettings.shared.pills
        let layout = ExteraPillStackSettings.shared.layout.normalized(custom: custom)
        let changed = self.custom != custom || self.layout.visible != layout.visible || self.layout.hidden != layout.hidden || self.layout.infiniteScrolling != layout.infiniteScrolling
        self.custom = custom; self.layout = layout
        self.navigationItem.rightBarButtonItem = layout.visible.isEmpty ? nil : UIBarButtonItem(title: self.text("Reset", "Сбросить"), style: .plain, target: self, action: #selector(self.resetStack))
        // A swipe only changes selection. Keep its preview cell and animation alive.
        if self.isViewLoaded && changed { self.table.reloadData() }
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        transition.updateFrame(view: self.table, frame: CGRect(x: layout.safeInsets.left, y: 0, width: layout.size.width - layout.safeInsets.left - layout.safeInsets.right, height: layout.size.height))
        self.table.contentInset = UIEdgeInsets(top: self.navigationLayout(layout: layout).navigationFrame.maxY, left: 0, bottom: layout.insets(options: [.input]).bottom, right: 0)
        self.table.scrollIndicatorInsets = self.table.contentInset
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); self.preview.hostVisible = true }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); self.preview.hostVisible = false }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { self.query = searchText; self.table.reloadData() }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    private func title(_ id: String) -> String {
        ExteraBuiltinPill.from(id: id)?.title(self.data.strings.baseLanguageCode) ?? self.custom.first(where: { ExteraPillStackLayout.customId($0.id) == id })?.label ?? id
    }
    private func ids(_ section: Int) -> [String] {
        let ids = section == 2 ? self.layout.visible : self.layout.hidden
        return self.query.isEmpty ? ids : ids.filter { self.title($0).localizedCaseInsensitiveContains(self.query) }
    }
    func numberOfSections(in tableView: UITableView) -> Int { 5 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 2 || section == 3 ? self.ids(section).count : 1 }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return self.text("Search Stack", "Виджеты в поиске")
        case 1: return self.text("Settings", "Настройки")
        case 2: return self.layout.visible.isEmpty ? nil : self.text("Visible Widgets", "Видимые виджеты")
        case 3: return self.text("Hidden Widgets", "Скрытые виджеты")
        default: return "HTTP"
        }
    }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return self.text("Swipe the preview up/down, as in the Chats search field. Tap for source, permissions and actions.", "Смахните превью вверх или вниз, как в поиске чатов. Нажмите для просмотра источника, разрешений и действий.") }
        if section == 3 { return self.text("Tap to show or hide. Drag handles reorder widgets, including between sections. Clear search to reorder. New and imported HTTP widgets start hidden; requests in search need separate permission for this account.", "Нажмите, чтобы показать или скрыть. Перетаскивайте за ручки для изменения порядка и секции. Очистите поиск для перестановки. Новые и импортированные HTTP-плашки скрыты; запросы в поиске требуют отдельного разрешения для аккаунта.") }
        return nil
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = self.data.theme.list.itemBlocksBackgroundColor
        cell.textLabel?.textColor = self.data.theme.list.itemPrimaryTextColor
        cell.detailTextLabel?.textColor = self.data.theme.list.itemSecondaryTextColor
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            if self.preview.hasItems {
                self.preview.translatesAutoresizingMaskIntoConstraints = false; cell.contentView.addSubview(self.preview)
                NSLayoutConstraint.activate([self.preview.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor), self.preview.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor), self.preview.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10), self.preview.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10), self.preview.heightAnchor.constraint(equalToConstant: 32)])
            } else { cell.textLabel?.text = self.text("All widgets are hidden", "Все виджеты скрыты") }
        } else if indexPath.section == 1 {
            cell.textLabel?.text = self.text("Infinite Scrolling", "Бесконечная прокрутка")
            let toggle = UISwitch(); toggle.isOn = self.layout.infiniteScrolling; toggle.onTintColor = self.data.theme.list.itemAccentColor
            toggle.addTarget(self, action: #selector(self.infiniteChanged(_:)), for: .valueChanged); cell.accessoryView = toggle
        } else if indexPath.section == 4 {
            cell.textLabel?.text = self.text("Custom HTTP Widgets", "HTTP-плашки")
            cell.detailTextLabel?.text = self.text("Endpoints, formats, refresh, import and export", "Источники, форматы, обновление, импорт и экспорт")
            cell.accessoryType = .disclosureIndicator
        } else {
            let id = self.ids(indexPath.section)[indexPath.row]
            let kind = ExteraBuiltinPill.from(id: id)
            cell.textLabel?.text = self.title(id)
            cell.imageView?.image = exteraPillWidgetIcon(kind)
            if kind == .entryTime { cell.detailTextLabel?.text = self.text("This account’s server status", "Статус этого аккаунта с сервера") }
            if kind == .gram { cell.detailTextLabel?.text = self.text("TON exchange rate", "Обменный курс TON") }
            if let spec = self.custom.first(where: { ExteraPillStackLayout.customId($0.id) == id }), !spec.enabled { cell.detailTextLabel?.text = self.text("Disabled in HTTP settings", "Отключена в настройках HTTP") }
            cell.accessibilityHint = indexPath.section == 2 ? self.text("Tap to hide", "Нажмите, чтобы скрыть") : self.text("Tap to show", "Нажмите, чтобы показать")
            cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: self.text("Move up", "Выше"), actionHandler: { [weak self] _ in self?.moveBy(id, section: indexPath.section, delta: -1); return true }), UIAccessibilityCustomAction(name: self.text("Move down", "Ниже"), actionHandler: { [weak self] _ in self?.moveBy(id, section: indexPath.section, delta: 1); return true })]
        }
        return cell
    }
    @objc private func resetStack() {
        self.saveLayout { layout in
            let infinite = layout.infiniteScrolling
            layout = ExteraPillStackLayout().normalized(custom: self.custom)
            layout.infiniteScrolling = infinite
        }
    }
    @objc private func infiniteChanged(_ sender: UISwitch) { self.saveLayout { $0.infiniteScrolling = sender.isOn } }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 2 || indexPath.section == 3 {
            let id = self.ids(indexPath.section)[indexPath.row]
            self.saveLayout { $0.setVisible(id, indexPath.section == 3) }
        } else if indexPath.section == 4 {
            (self.navigationController as? NavigationController)?.pushViewController(exteraHTTPPillDashboardController(context: self.context, edit: self.editPill, transfer: self.transfer))
        }
    }
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { indexPath.section == 2 || indexPath.section == 3 }
    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { self.query.isEmpty && (indexPath.section == 2 || indexPath.section == 3) }
    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        (proposedDestinationIndexPath.section == 2 || proposedDestinationIndexPath.section == 3) ? proposedDestinationIndexPath : sourceIndexPath
    }
    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let id = self.ids(sourceIndexPath.section)[sourceIndexPath.row]
        var target = self.ids(destinationIndexPath.section); target.removeAll { $0 == id }
        let before = destinationIndexPath.row < target.count ? target[destinationIndexPath.row] : nil
        self.saveLayout { $0.move(id, visible: destinationIndexPath.section == 2, before: before) }
    }
    private func moveBy(_ id: String, section: Int, delta: Int) {
        let ids = self.ids(section)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + delta) else { return }
        let remaining = ids.filter { $0 != id }; let destination = index + delta
        let before = destination < remaining.count ? remaining[destination] : nil
        self.saveLayout { $0.move(id, visible: section == 2, before: before) }
    }
    private func saveLayout(_ update: (inout ExteraPillStackLayout) -> Void) {
        ExteraPillStackSettings.shared.update(custom: self.custom, update)
        // UITableView queries its data source before the asynchronous notification reload.
        self.layout = ExteraPillStackSettings.shared.layout.normalized(custom: self.custom)
        DispatchQueue.main.async { [weak self] in self?.table.reloadData() }
    }
}

private func exteraPillWidgetIcon(_ kind: ExteraBuiltinPill?) -> UIImage {
    let colors: [UIColor] = [.systemBlue, .systemCyan, .systemOrange, .systemGreen, .systemBlue, .systemGreen, .systemGray]
    let color = kind.flatMap { ExteraBuiltinPill.allCases.firstIndex(of: $0) }.map { colors[$0] } ?? .systemBlue
    return UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { _ in
        color.setFill(); UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 30, height: 30), cornerRadius: 8).fill()
        let symbol = UIImage(systemName: kind?.symbol ?? "network", withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))?.withTintColor(.white, renderingMode: .alwaysOriginal)
        if let symbol { symbol.draw(in: CGRect(x: (30 - symbol.size.width) / 2, y: (30 - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)) }
    }.withRenderingMode(.alwaysOriginal)
}
