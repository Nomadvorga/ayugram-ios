import AccountContext
import Display
import Foundation
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// Navigation editor; the root tab host consumes this same persisted configuration live.
public func exteraNavigationSettingsController(context: AccountContext) -> ViewController {
    return ExteraNavigationSettingsController(context: context)
}

private final class ExteraNavigationSwitch: UISwitch {
    var update: ((Bool) -> Void)?
    init(value: Bool, update: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        self.isOn = value
        self.update = update
        self.addTarget(self, action: #selector(self.changed), for: .valueChanged)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { self.update?(self.isOn) }
}

private final class ExteraNavigationSettingsController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let settings = ExteraNavigationSettings.shared
    private var observer: NSObjectProtocol?
    private var presentationDisposable: Disposable?
    private var moving = false
    private var configuration: ExteraNavigationSettings.Configuration { return self.settings.configuration }
    private var data: PresentationData { return self.context.sharedContext.currentPresentationData.with { $0 } }
    private var hiddenTabs: [ExteraNavigationSettings.Tab] {
        return ExteraNavigationSettings.Tab.allCases.filter {
            !self.configuration.tabs.contains($0.rawValue) && ($0 != .news || newsFeedApiIsAvailable)
        }
    }

    init(context: AccountContext) {
        self.context = context
        let data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)))
        self.title = self.text("Title", "App Navigation", "Навигация в приложении")
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.counterclockwise"), style: .plain, target: self, action: #selector(self.resetPressed))
        self.navigationItem.rightBarButtonItem?.accessibilityLabel = self.text("Reset", "Reset", "Сбросить")
        self.observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.moving, self.isNodeLoaded else { return }
            self.table.reloadData()
        }
        self.presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.title = self.text("Title", "App Navigation", "Навигация в приложении")
            self.setNavigationBarPresentationData(NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)), animated: false)
            self.updateTheme()
        })
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
        self.presentationDisposable?.dispose()
    }

    private func text(_ key: String, _ english: String, _ russian: String) -> String {
        let fullKey = "Extera.Navigation." + key
        let localized = i18n(fullKey, self.data.strings.baseLanguageCode)
        return localized.isEmpty || localized == fullKey ? (self.data.strings.baseLanguageCode.hasPrefix("ru") ? russian : english) : localized
    }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode()
        self.displayNodeDidLoad()
        self.displayNode.view.addSubview(self.table)
        self.table.dataSource = self
        self.table.delegate = self
        self.table.contentInsetAdjustmentBehavior = .never
        self.table.rowHeight = UITableView.automaticDimension
        self.table.estimatedRowHeight = 52
        self.table.allowsSelectionDuringEditing = true
        self.table.setEditing(true, animated: false)
        self.updateTheme()
    }

    private func updateTheme() {
        guard self.isNodeLoaded else { return }
        self.table.backgroundColor = self.data.theme.list.blocksBackgroundColor
        self.table.separatorColor = self.data.theme.list.itemBlocksSeparatorColor
        self.table.tintColor = self.data.theme.list.itemAccentColor
        self.table.overrideUserInterfaceStyle = self.data.theme.overallDarkAppearance ? .dark : .light
        self.table.reloadData()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.table.frame = CGRect(origin: .zero, size: layout.size)
        let insets = layout.insets(options: [.input])
        self.table.contentInset = UIEdgeInsets(top: self.navigationLayout(layout: layout).navigationFrame.maxY, left: layout.safeInsets.left, bottom: insets.bottom + 16, right: layout.safeInsets.right)
        self.table.scrollIndicatorInsets = self.table.contentInset
    }

    func numberOfSections(in tableView: UITableView) -> Int { return 6 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 3
        case 1: return self.configuration.tabs.count
        case 2: return self.hiddenTabs.count
        case 3: return self.configuration.sidebar ? 2 : 1
        case 4: return self.configuration.menu.count + 1
        default: return self.configuration.hiddenMenu.count
        }
    }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return self.text("General", "General", "Основные")
        case 1: return self.text("VisibleTabs", "Visible Tabs", "Видимые вкладки")
        case 2: return self.hiddenTabs.isEmpty ? nil : self.text("HiddenTabs", "Hidden Tabs", "Скрытые вкладки")
        case 3: return self.text("Title", "App Navigation", "Навигация в приложении")
        case 4: return self.text("MenuItems", "Menu Items", "Элементы меню")
        default: return self.configuration.hiddenMenu.isEmpty ? nil : self.text("HiddenItems", "Hidden Items", "Скрытые элементы")
        }
    }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return self.text("TabletInfo", "On enables two columns where at least 700 points are available. Off uses one column. Auto follows the window layout.", "Вкл. включает две колонки при доступной ширине от 700 точек. Выкл. использует одну колонку. Авто следует размеру окна.")
        case 1: return self.text("TabsInfo", "Tap to hide or show a tab; drag its handle to reorder. Chats and Settings always remain available. Feed is off by default.", "Нажмите, чтобы скрыть или показать вкладку; перетащите ручку для изменения порядка. Чаты и Настройки всегда доступны. Лента по умолчанию выключена.")
        case 3: return self.text("SidebarInfo", "Open the menu using the menu button. With Sidebar enabled, a swipe from the left edge also opens it.", "Откройте меню кнопкой меню. Если включено боковое меню, оно также открывается свайпом от левого края.")
        case 4: return self.text("MenuInfo", "Tap to hide or show an item; drag its handle to reorder. Tap a divider to remove it. Changes apply to the menu and sidebar.", "Нажмите, чтобы скрыть или показать пункт; перетащите ручку для изменения порядка. Нажмите на разделитель, чтобы удалить его. Изменения применяются к меню и боковой панели.")
        default: return nil
        }
    }
    private func tabTitle(_ tab: ExteraNavigationSettings.Tab) -> String {
        switch tab {
        case .contacts: return self.data.strings.Contacts_Title
        case .calls: return self.data.strings.Calls_TabTitle
        case .chats: return self.data.strings.DialogList_Title
        case .settings: return self.data.strings.Settings_Title
        case .feed: return self.text("Feed", "Feed", "Лента")
        case .news: return self.text("News", "News", "Новости")
        }
    }
    private func menuTitle(_ id: String) -> String {
        switch ExteraNavigationSettings.MenuItem(rawValue: id) {
        case .profile: return self.text("Profile", "My Profile", "Мой профиль")
        case .ghost: return self.text("Ghost", "Ghost Mode", "Режим призрака")
        case .archive: return self.text("Archive", "Archived Chats", "Архив чатов")
        case .newGroup: return self.text("NewGroup", "New Group", "Создать группу")
        case .savedMessages: return self.text("SavedMessages", "Saved Messages", "Избранное")
        case .settings: return self.data.strings.Settings_Title
        case .feed: return self.text("Feed", "Feed", "Лента")
        case .wallet: return self.text("Wallet", "Wallet", "Кошелёк")
        case .contacts: return self.data.strings.Contacts_Title
        case .newChannel: return self.text("NewChannel", "New Channel", "Создать канал")
        case .calls: return self.data.strings.Calls_TabTitle
        case .browser: return self.text("Browser", "Browser", "Браузер")
        case .qrCode: return self.text("QRCode", "Scan QR Code", "Сканировать QR-код")
        case nil: return self.text("Divider", "Divider", "Разделитель")
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = self.data.theme.list.itemBlocksBackgroundColor
        cell.textLabel?.textColor = self.data.theme.list.itemPrimaryTextColor
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.textColor = self.data.theme.list.itemAccentColor
        cell.showsReorderControl = self.tableView(tableView, canMoveRowAt: indexPath)
        let config = self.configuration
        switch indexPath.section {
        case 0:
            if indexPath.row == 0 {
                cell.textLabel?.text = self.text("TabletMode", "Tablet Mode", "Планшетный режим")
                cell.detailTextLabel?.text = [self.text("Auto", "Auto", "Автоматически"), self.text("On", "On", "Вкл."), self.text("Off", "Off", "Выкл.")][config.tabletMode.rawValue]
            } else if indexPath.row == 1 {
                cell.textLabel?.text = self.text("BottomBar", "Bottom Navigation Bar", "Нижняя панель навигации")
                cell.detailTextLabel?.text = [self.text("Show", "Show", "Показывать"), self.text("Hide", "Hide", "Скрывать"), self.text("Floating", "Floating", "Плавающая")][config.barMode.rawValue]
            } else {
                cell.textLabel?.text = self.text("HideLabels", "Hide Labels", "Скрыть подписи")
                cell.accessoryView = ExteraNavigationSwitch(value: config.hideLabels, update: { [weak self] value in self?.settings.update { $0.hideLabels = value } })
            }
        case 1:
            if let tab = ExteraNavigationSettings.Tab(rawValue: config.tabs[indexPath.row]) {
                cell.textLabel?.text = self.tabTitle(tab)
                cell.imageView?.image = UIImage(systemName: tab == .chats || tab == .settings ? "lock" : "minus.circle")
            }
        case 2:
            cell.textLabel?.text = self.tabTitle(self.hiddenTabs[indexPath.row])
            cell.imageView?.image = UIImage(systemName: "plus.circle")
        case 3:
            cell.textLabel?.text = indexPath.row == 0 ? self.text("Sidebar", "Sidebar", "Боковое меню") : self.text("Immersive", "Immersive Animation", "Иммерсивная анимация")
            cell.accessoryView = ExteraNavigationSwitch(value: indexPath.row == 0 ? config.sidebar : config.immersiveSidebar, update: { [weak self] value in
                self?.settings.update { if indexPath.row == 0 { $0.sidebar = value } else { $0.immersiveSidebar = value } }
            })
        case 4:
            if indexPath.row == config.menu.count {
                cell.textLabel?.text = self.text("AddDivider", "Add Divider", "Добавить разделитель")
                cell.textLabel?.textColor = self.data.theme.list.itemAccentColor
                cell.imageView?.image = UIImage(systemName: "plus")
                cell.isUserInteractionEnabled = config.menu.count < 100
                if config.menu.count >= 100 { cell.textLabel?.textColor = self.data.theme.list.itemSecondaryTextColor }
            } else { cell.textLabel?.text = self.menuTitle(config.menu[indexPath.row]) }
        default: cell.textLabel?.text = self.menuTitle(config.hiddenMenu[indexPath.row])
        }
        cell.editingAccessoryView = cell.accessoryView
        return cell
    }
    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { return .none }
    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { return false }
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return indexPath.section == 1 || indexPath.section == 5 || (indexPath.section == 4 && indexPath.row < self.configuration.menu.count)
    }
    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        guard proposedDestinationIndexPath.section == sourceIndexPath.section else { return sourceIndexPath }
        return IndexPath(row: min(proposedDestinationIndexPath.row, sourceIndexPath.section == 4 ? self.configuration.menu.count - 1 : tableView.numberOfRows(inSection: sourceIndexPath.section) - 1), section: sourceIndexPath.section)
    }
    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        self.moving = true
        self.settings.update { config in
            switch sourceIndexPath.section {
            case 1: let id = config.tabs.remove(at: sourceIndexPath.row); config.tabs.insert(id, at: destinationIndexPath.row); config.tabsCustomized = true
            case 4: let id = config.menu.remove(at: sourceIndexPath.row); config.menu.insert(id, at: destinationIndexPath.row)
            default: let id = config.hiddenMenu.remove(at: sourceIndexPath.row); config.hiddenMenu.insert(id, at: destinationIndexPath.row)
            }
        }
        self.moving = false
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 0:
            if indexPath.row == 0 { self.select(title: self.text("TabletMode", "Tablet Mode", "Планшетный режим"), labels: [self.text("Auto", "Auto", "Автоматически"), self.text("On", "On", "Вкл."), self.text("Off", "Off", "Выкл.")], selected: self.configuration.tabletMode.rawValue) { value in self.settings.update { $0.tabletMode = ExteraNavigationSettings.TabletMode(rawValue: value) ?? .automatic } } }
            if indexPath.row == 1 { self.select(title: self.text("BottomBar", "Bottom Navigation Bar", "Нижняя панель навигации"), labels: [self.text("Show", "Show", "Показывать"), self.text("Hide", "Hide", "Скрывать"), self.text("Floating", "Floating", "Плавающая")], selected: self.configuration.barMode.rawValue) { value in self.settings.update { $0.barMode = ExteraNavigationSettings.BarMode(rawValue: value) ?? .floating } } }
        case 1: if let tab = ExteraNavigationSettings.Tab(rawValue: self.configuration.tabs[indexPath.row]) { self.settings.update { $0.setTab(tab, visible: false) } }
        case 2: let tab = self.hiddenTabs[indexPath.row]; self.settings.update { $0.setTab(tab, visible: true) }
        case 4:
            if indexPath.row == self.configuration.menu.count { self.settings.update { $0.addDivider() } }
            else { let id = self.configuration.menu[indexPath.row]; self.settings.update { $0.toggleMenuItem(id) } }
        case 5: let id = self.configuration.hiddenMenu[indexPath.row]; self.settings.update { $0.toggleMenuItem(id) }
        default: break
        }
    }
    private func select(title: String, labels: [String], selected: Int, update: @escaping (Int) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        for (index, label) in labels.enumerated() { alert.addAction(UIAlertAction(title: (index == selected ? "✓ " : "") + label, style: .default, handler: { _ in update(index) })) }
        alert.addAction(UIAlertAction(title: self.data.strings.Common_Cancel, style: .cancel))
        self.present(alert, animated: true)
    }
    @objc private func resetPressed() {
        let alert = UIAlertController(title: self.text("Reset", "Reset", "Сбросить"), message: self.text("ResetInfo", "Reset navigation and menu layout?", "Сбросить навигацию и расположение меню?"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.data.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: self.text("Reset", "Reset", "Сбросить"), style: .destructive, handler: { [weak self] _ in self?.settings.reset() }))
        self.present(alert, animated: true)
    }
}
