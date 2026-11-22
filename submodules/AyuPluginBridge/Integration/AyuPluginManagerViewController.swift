import UIKit
import UniformTypeIdentifiers

@MainActor public final class AyuPluginManagerViewController: UITableViewController, UIDocumentPickerDelegate {
    private let service: AyuPluginService
    public init(service: AyuPluginService = .shared) { self.service = service; super.init(style: .insetGrouped); self.title = "Плагины" }
    required init?(coder: NSCoder) { return nil }
    public override func viewDidLoad() {
        super.viewDidLoad()
        self.tableView.register(UITableViewCell.self, forCellReuseIdentifier: "plugin")
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(self.importPressed))
        NotificationCenter.default.addObserver(self, selector: #selector(self.serviceChanged(_:)), name: AyuPluginService.didChange, object: self.service)
        Task { do { try await self.service.prepare() } catch { self.show(error) }; self.tableView.reloadData() }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func serviceChanged(_ notification: Notification) { self.tableView.reloadData() }
    public override func numberOfSections(in tableView: UITableView) -> Int { return 2 }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 2 : self.service.plugins.count }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? nil : "Установленные плагины" }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "Импорт не запускает плагин. После перезапуска приложения все плагины выключены. Совместимость Android API ограничена этой сборкой." : self.service.startupError
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0 { cell.textLabel?.text = indexPath.row == 0 ? "Импортировать .plugin" : "Тест моста"; cell.imageView?.image = UIImage(systemName: indexPath.row == 0 ? "square.and.arrow.down" : "testtube.2"); return cell }
        let plugin = self.service.plugins[indexPath.row]
        cell.textLabel?.text = plugin.name + " · " + plugin.version
        cell.detailTextLabel?.text = plugin.status
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = plugin.isBusy ? .none : .default
        cell.textLabel?.isEnabled = !plugin.isBusy
        return cell
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 { if indexPath.row == 0 { self.importPressed() } else { self.run { try await self.service.importBundledTest() } }; return }
        let plugin = self.service.plugins[indexPath.row]
        guard !plugin.isBusy else { return }
        let details = ([plugin.status] + plugin.blockers + [plugin.error].compactMap { $0 }).joined(separator: "\n")
        let sheet = UIAlertController(title: plugin.name, message: details, preferredStyle: .actionSheet)
        if plugin.isEnabled {
            sheet.addAction(UIAlertAction(title: "Выключить", style: .default) { [weak self] _ in self?.run { try await self?.service.disable(plugin.id) } })
            sheet.addAction(UIAlertAction(title: "Настройки", style: .default) { [weak self] _ in guard let self else { return }; self.presentChild(AyuPluginSettingsViewController(service: self.service, plugin: plugin)) })
            if plugin.nativeAdapter == nil {
                sheet.addAction(UIAlertAction(title: "Предпросмотр интерфейса", style: .default) { [weak self] _ in guard let self else { return }; self.presentChild(AyuPluginPreviewViewController(service: self.service, plugin: plugin)) })
            }
        } else if plugin.blockers.isEmpty {
            sheet.addAction(UIAlertAction(title: "Включить…", style: .default) { [weak self] _ in self?.confirmEnable(plugin) })
        }
        sheet.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in self?.confirmDelete(plugin) })
        sheet.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath) ?? tableView
        self.present(sheet, animated: true)
    }
    @objc private func importPressed() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "plugin") ?? .data], asCopy: true)
        picker.allowsMultipleSelection = false; picker.delegate = self; self.present(picker, animated: true)
    }
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }; self.run { try await self.service.importPlugin(from: url) }
    }
    private func confirmEnable(_ plugin: AyuInstalledPlugin) {
        let isNative = plugin.nativeAdapter == AyuAtmosphericPluginAdapter.adapterID
        let message = isNative
            ? "Исходник Atmospheric Snow 1.0.1 проверяется по SHA-256. Эффекты и настройки обслуживает нативный адаптер iOS: Python и Android-хуки не исполняются. Эффекты включатся в интерфейсе приложения и выключатся после его перезапуска."
            : "Python-код плагина получает доступ к контейнеру приложения и предоставленным API аккаунта. SDK не является песочницей Python. Включайте только проверенный код. Плагин будет запущен сейчас и выключен после перезапуска приложения."
        let alert = UIAlertController(title: isNative ? "Включить Atmospheric Snow?" : "Доверять этому плагину?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: isNative ? "Включить эффекты" : "Доверяю и включаю", style: isNative ? .default : .destructive) { [weak self] _ in self?.run { try await self?.service.enable(plugin.id) } })
        self.presentManaged(alert)
    }
    private func confirmDelete(_ plugin: AyuInstalledPlugin) {
        let alert = UIAlertController(title: "Удалить плагин?", message: "Будут удалены локальная копия кода и настройки плагина «\(plugin.name)».", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in self?.run { try await self?.service.delete(plugin.id) } })
        self.presentManaged(alert)
    }
    private func presentChild(_ controller: UIViewController) {
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(self.dismissChild))
        self.presentManaged(UINavigationController(rootViewController: controller))
    }
    private func presentManaged(_ controller: UIViewController) {
        if let current = self.presentedViewController { current.dismiss(animated: true) { [weak self] in self?.present(controller, animated: true) } }
        else { self.present(controller, animated: true) }
    }
    @objc private func dismissChild() { self.dismiss(animated: true) }
    private func run(_ work: @escaping @MainActor () async throws -> Void) { Task { do { try await work() } catch { self.show(error) }; self.tableView.reloadData() } }
    private func show(_ error: Error) { self.presentManaged(AyuPluginAlerts.error(error)) }
}

@MainActor private enum AyuPluginAlerts {
    static func error(_ error: Error) -> UIAlertController {
        let alert = UIAlertController(title: "Не удалось выполнить действие", message: (error as? AyuPluginService.Failure)?.localizedDescription ?? "Операция не выполнена. Исходный код и данные плагина не выводятся в ошибку.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Понятно", style: .default)); return alert
    }
}

@MainActor private final class AyuPluginSettingsViewController: UITableViewController {
    private let service: AyuPluginService
    private let plugin: AyuInstalledPlugin
    private var rows: [AyuPluginSetting] = []
    private var loading = false
    init(service: AyuPluginService, plugin: AyuInstalledPlugin) { self.service = service; self.plugin = plugin; super.init(style: .insetGrouped); self.title = "Настройки плагина" }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() { super.viewDidLoad(); self.reload() }
    private func reload() {
        guard !self.loading else { return }; self.loading = true
        Task { do { self.rows = try await self.service.settings(self.plugin.id) } catch { self.present(AyuPluginAlerts.error(error), animated: true) }; self.loading = false; self.tableView.reloadData() }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { self.rows.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { self.rows.isEmpty ? (self.loading ? "Загрузка…" : "Плагин не предоставил настройки.") : nil }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = self.rows[indexPath.row], cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = row.text; cell.detailTextLabel?.text = String((row.descriptor["subtext"].string ?? "").prefix(512))
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
        let row = self.rows[indexPath.row]; guard row.descriptor["enabled"] != .bool(false), !(row.type == "Input" && row.descriptor["multiline"] == .bool(true)) else { return }
        if row.type == "Text" { self.service.activate(row, pluginID: self.plugin.id); self.reload(); return }
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
        Task { do { try await self.service.set(row, value: value, pluginID: self.plugin.id); self.rows[index].value = value } catch { self.present(AyuPluginAlerts.error(error), animated: true) }; self.loading = false; self.tableView.isUserInteractionEnabled = true; self.tableView.reloadData() }
    }
}

@MainActor private final class AyuPluginPreviewViewController: UIViewController {
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
