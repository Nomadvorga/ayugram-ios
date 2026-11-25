import UIKit
import UniformTypeIdentifiers

@MainActor public final class AyuPluginManagerViewController: UITableViewController, UIDocumentPickerDelegate {
    private let service: AyuPluginService
    public init(service: AyuPluginService? = nil) {
        // Resolve the actor-isolated singleton here, not in a nonisolated default argument.
        self.service = service ?? .shared
        super.init(style: .insetGrouped)
        self.title = "Плагины"
    }
    required init?(coder: NSCoder) { return nil }
    public override func viewDidLoad() {
        super.viewDidLoad()
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 64
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(self.importPressed))
        NotificationCenter.default.addObserver(self, selector: #selector(self.serviceChanged(_:)), name: AyuPluginService.didChange, object: self.service)
        AyuNativePluginRuntime.shared.feedbackPresenter = { [weak self] in
            guard let self else { return nil }
            var top: UIViewController = self.navigationController?.topViewController ?? self
            var depth = 0
            while let presented = top.presentedViewController, !presented.isBeingDismissed, depth < 8 {
                top = (presented as? UINavigationController)?.topViewController ?? presented
                depth += 1
            }
            return top
        }
        Task { do { try await self.service.prepare() } catch { self.show(error) }; self.tableView.reloadData() }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func serviceChanged(_ notification: Notification) { self.tableView.reloadData() }
    public override func numberOfSections(in tableView: UITableView) -> Int { return 3 }
    private var nativePlugins: [AyuInstalledPlugin] { self.service.plugins.filter { $0.nativeAdapter != nil } }
    private var pythonPlugins: [AyuInstalledPlugin] { self.service.plugins.filter { $0.nativeAdapter == nil } }
    private func plugin(at indexPath: IndexPath) -> AyuInstalledPlugin? {
        switch indexPath.section {
        case 1: return indexPath.row < self.nativePlugins.count ? self.nativePlugins[indexPath.row] : nil
        case 2: return indexPath.row < self.pythonPlugins.count ? self.pythonPlugins[indexPath.row] : nil
        default: return nil
        }
    }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : (section == 1 ? self.nativePlugins.count : self.pythonPlugins.count) }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 1: return "Нативные адаптеры"
        case 2: return "Python-плагины"
        default: return nil
        }
    }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return "Выберите файл .plugin, чтобы посмотреть описание, требования и доступные действия. Установка не включает плагин автоматически."
        case 1: return "Функции этих плагинов обслуживают нативные адаптеры iOS. Python-код и Android-хуки не запускаются."
        case 2: return self.service.startupError ?? (self.service.plugins.isEmpty ? "Плагинов пока нет. Откройте файл .plugin в чате или импортируйте его здесь." : "Python-плагины включаются только с вашего согласия и не запускаются автоматически.")
        default: return nil
        }
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0 { cell.textLabel?.text = "Импортировать .plugin"; cell.imageView?.image = UIImage(systemName: "square.and.arrow.down"); return cell }
        let plugin: AyuInstalledPlugin
        switch indexPath.section {
        case 1: plugin = self.nativePlugins[indexPath.row]
        default: plugin = self.pythonPlugins[indexPath.row]
        }
        cell.textLabel?.text = plugin.name
        cell.textLabel?.font = .preferredFont(forTextStyle: .headline)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.text = plugin.version + " · " + plugin.status
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        cell.imageView?.image = UIImage(systemName: "puzzlepiece.extension")
        cell.imageView?.tintColor = plugin.isEnabled ? .systemGreen : .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = plugin.isBusy ? .none : .default
        cell.textLabel?.isEnabled = !plugin.isBusy
        return cell
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 { self.importPressed(); return }
        guard let plugin = self.plugin(at: indexPath), !plugin.isBusy else { return }
        self.openDetail(AyuPluginDetailViewController(plugin: plugin, service: self.service))
    }
    @objc private func importPressed() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "plugin") ?? .data], asCopy: true)
        picker.allowsMultipleSelection = false; picker.delegate = self; self.present(picker, animated: true)
    }
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // Dismiss the picker before opening the preview; selection never installs code.
        controller.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.openDetail(AyuPluginDetailViewController(sourceURL: url, service: self.service))
        }
    }
    private func openDetail(_ controller: AyuPluginDetailViewController) {
        if let navigationController = self.navigationController {
            navigationController.pushViewController(controller, animated: true)
        } else {
            let navigationController = UINavigationController(rootViewController: controller)
            navigationController.overrideUserInterfaceStyle = self.overrideUserInterfaceStyle
            self.presentManaged(navigationController)
        }
    }
    private func presentManaged(_ controller: UIViewController) {
        if let current = self.presentedViewController { current.dismiss(animated: true) { [weak self] in self?.present(controller, animated: true) } }
        else { self.present(controller, animated: true) }
    }
    private func show(_ error: Error) { self.presentManaged(AyuPluginAlerts.error(error)) }
}

@MainActor enum AyuPluginAlerts {
    static func message(_ error: Error) -> String {
        return (error as? AyuPluginService.Failure)?.localizedDescription ?? "Операция не выполнена. Исходный код и данные плагина не выводятся в ошибку."
    }
    static func error(_ error: Error) -> UIAlertController {
        let alert = UIAlertController(title: "Не удалось выполнить действие", message: self.message(error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Понятно", style: .default)); return alert
    }
}

@MainActor final class AyuPluginSettingsViewController: UITableViewController {
    private let service: AyuPluginService
    private let plugin: AyuInstalledPlugin
    private let subpageCallback: String?
    private var rows: [AyuPluginSetting] = []
    private var loading = false
    private var reloadRequested = false
    private var pendingReloadGeneration: String?
    init(service: AyuPluginService, plugin: AyuInstalledPlugin, subpageCallback: String? = nil, title: String = "Настройки плагина") {
        self.service = service; self.plugin = plugin; self.subpageCallback = subpageCallback
        super.init(style: .insetGrouped); self.title = title
    }
    required init?(coder: NSCoder) { return nil }
    isolated deinit { NotificationCenter.default.removeObserver(self) }
    override func viewDidLoad() {
        super.viewDidLoad()
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 64
        NotificationCenter.default.addObserver(self, selector: #selector(self.settingsChanged(_:)), name: AyuPluginNativeHost.settingsDidChange, object: self.service.host)
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.reload()
    }
    @objc private func settingsChanged(_ notification: Notification) {
        guard let owner = notification.userInfo?["pluginID"] as? String, owner == self.plugin.id,
              let generation = notification.userInfo?["generation"] as? String,
              self.service.shouldReloadSettings(pluginID: owner, generation: generation) else { return }
        self.pendingReloadGeneration = generation
        self.reload()
    }
    private func reload() {
        guard !self.loading else { self.reloadRequested = true; return }
        // Recheck a queued notification after a save/read: its plugin may have
        // been disabled or replaced while that operation was suspended.
        if let generation = self.pendingReloadGeneration {
            self.pendingReloadGeneration = nil
            guard self.service.shouldReloadSettings(pluginID: self.plugin.id, generation: generation) else {
                self.reloadRequested = false
                return
            }
        }
        self.reloadRequested = false
        self.loading = true
        self.tableView.isUserInteractionEnabled = false
        Task {
            do {
                if let callback = self.subpageCallback {
                    self.rows = try await self.service.subpage(pluginID: self.plugin.id, callbackID: callback)
                } else {
                    self.rows = try await self.service.settings(self.plugin.id)
                }
            } catch { self.present(AyuPluginAlerts.error(error), animated: true) }
            self.finishRowOperation()
        }
    }
    private func finishRowOperation() {
        self.loading = false
        self.tableView.isUserInteractionEnabled = true
        self.tableView.reloadData()
        if self.reloadRequested {
            self.reloadRequested = false
            self.reload()
        }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { self.rows.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { self.rows.isEmpty ? (self.loading ? "Загрузка…" : "Плагин не предоставил настройки.") : nil }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = self.rows[indexPath.row], cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = row.text; cell.detailTextLabel?.text = String((row.descriptor["subtext"].string ?? "").prefix(512))
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.font = .preferredFont(forTextStyle: .body); cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.textLabel?.adjustsFontForContentSizeCategory = true; cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.isEnabled = row.descriptor["enabled"] != .bool(false)
        if row.descriptor["destructive"] == .bool(true) { cell.textLabel?.textColor = .systemRed }
        else if row.descriptor["accent"] == .bool(true) { cell.textLabel?.textColor = .systemBlue }
        cell.selectionStyle = ["Header", "Divider", "Switch"].contains(row.type) ? .none : .default
        if row.type == "Header" { cell.textLabel?.font = .preferredFont(forTextStyle: .headline) }
        else if row.type == "Switch" {
            let toggle = UISwitch(); toggle.isOn = row.value == .bool(true); toggle.tag = indexPath.row
            toggle.isEnabled = row.descriptor["enabled"] != .bool(false)
            toggle.addTarget(self, action: #selector(self.switchChanged(_:)), for: .valueChanged); cell.accessoryView = toggle
        } else if row.type == "Selector", let index = row.value.integer, let items = row.descriptor["items"].array, index >= 0, index < Int64(items.count) { cell.detailTextLabel?.text = items[Int(index)].string; cell.accessoryType = .disclosureIndicator }
        else if row.type == "Input", row.descriptor["multiline"] == .bool(true) { cell.detailTextLabel?.text = "Многострочный ввод пока не поддерживается"; cell.selectionStyle = .none }
        else if row.type == "Input" { cell.detailTextLabel?.text = row.isSecret ? (row.value.string?.isEmpty == false ? "Сохранено" : "Не задано") : String((row.value.string ?? "").prefix(128)); cell.accessoryType = .disclosureIndicator }
        else if !["Text", "Divider", "Header"].contains(row.type) { cell.detailTextLabel?.text = "Этот тип настройки не поддерживается"; cell.selectionStyle = .none }
        return cell
    }
    @objc private func switchChanged(_ sender: UISwitch) { guard self.rows.indices.contains(sender.tag) else { return }; self.save(sender.tag, .bool(sender.isOn)) }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !self.loading, self.rows.indices.contains(indexPath.row) else { return }
        let row = self.rows[indexPath.row]; guard row.descriptor["enabled"] != .bool(false), !(row.type == "Input" && row.descriptor["multiline"] == .bool(true)) else { return }
        if let callback = row.descriptor["create_sub_fragment"]["$callback"].string {
            let page = AyuPluginSettingsViewController(service: self.service, plugin: self.plugin, subpageCallback: callback, title: row.text)
            self.navigationController?.pushViewController(page, animated: true)
            return
        }
        if row.type == "Text" {
            self.service.activate(row, pluginID: self.plugin.id, presenter: self) { [weak self] in self?.reload() }
            return
        }
        if row.type == "Input" {
            let alert = UIAlertController(title: row.text, message: nil, preferredStyle: .alert)
            alert.addTextField { field in field.isSecureTextEntry = row.isSecret; field.text = row.value.string; field.placeholder = String((row.descriptor["hint"].string ?? "").prefix(128)); field.autocorrectionType = .no; field.autocapitalizationType = .none }
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] _ in self?.save(indexPath.row, .string(alert?.textFields?.first?.text ?? "")) }); self.present(alert, animated: true)
        } else if row.type == "Selector", let items = row.descriptor["items"].array, items.count <= 128 {
            let alert = UIAlertController(title: row.text, message: nil, preferredStyle: .actionSheet)
            for (index, item) in items.enumerated() { alert.addAction(UIAlertAction(title: String((item.string ?? "—").prefix(128)), style: .default) { [weak self] _ in self?.save(indexPath.row, .integer(Int64(index))) }) }
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel)); alert.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath) ?? tableView; self.present(alert, animated: true)
        }
    }
    private func save(_ index: Int, _ value: AyuBridgeValue) {
        guard self.rows.indices.contains(index), !self.loading else { self.tableView.reloadData(); return }
        self.loading = true; self.tableView.isUserInteractionEnabled = false
        let row = self.rows[index]
        Task {
            do {
                try await self.service.set(row, value: value, pluginID: self.plugin.id)
                self.rows[index].value = value
            } catch { self.present(AyuPluginAlerts.error(error), animated: true) }
            self.finishRowOperation()
        }
    }
}

@MainActor final class AyuPluginPreviewViewController: UIViewController {
    private let service: AyuPluginService
    private let plugin: AyuInstalledPlugin
    private let surface = UIView()
    init(service: AyuPluginService, plugin: AyuInstalledPlugin) { self.service = service; self.plugin = plugin; super.init(nibName: nil, bundle: nil); self.title = "Предпросмотр" }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad(); self.view.backgroundColor = .systemBackground
        let note = UILabel(); note.text = "Интерфейс плагина доступен только на этом экране. Глобальный overlay не подключён."; note.numberOfLines = 0; note.font = .preferredFont(forTextStyle: .footnote)
        note.translatesAutoresizingMaskIntoConstraints = false; self.surface.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(note); self.view.addSubview(self.surface)
        NSLayoutConstraint.activate([note.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 16), note.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 16), note.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -16), self.surface.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 12), self.surface.leadingAnchor.constraint(equalTo: self.view.leadingAnchor), self.surface.trailingAnchor.constraint(equalTo: self.view.trailingAnchor), self.surface.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor)])
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); self.service.mount(self.surface, pluginID: self.plugin.id) }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); self.service.mount(nil, pluginID: self.plugin.id) }
}
