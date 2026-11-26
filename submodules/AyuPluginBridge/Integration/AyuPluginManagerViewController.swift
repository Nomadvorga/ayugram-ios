import UIKit
import UniformTypeIdentifiers

@MainActor public final class AyuPluginManagerViewController: UITableViewController, UIDocumentPickerDelegate {
    private enum BatchOperation: Equatable { case enable, importDisabled }
    private let service: AyuPluginService
    private var batchSelecting = false
    private var batchRunning = false
    private var batchOperation: BatchOperation?
    private var batchCancellationRequested = false
    private var batchProgress: (completed: Int, total: Int)?
    private var selectedPluginIDs: [String] = []
    private var latestBatchLogURL: URL?
    private var latestBatchLogRefreshGeneration = 0
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
        Task {
            do { try await self.service.prepare(); self.refreshLatestBatchLog() }
            catch { self.show(error) }
            self.tableView.reloadData()
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func serviceChanged(_ notification: Notification) {
        self.tableView.reloadData()
        self.refreshLatestBatchLog()
    }
    private func refreshLatestBatchLog() {
        self.latestBatchLogRefreshGeneration += 1
        let generation = self.latestBatchLogRefreshGeneration
        Task { @MainActor in
            let url = try? await self.service.latestBatchLog()
            guard generation == self.latestBatchLogRefreshGeneration else { return }
            self.latestBatchLogURL = url ?? nil
            self.tableView.reloadRows(at: [IndexPath(row: 3, section: 0)], with: .none)
        }
    }
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
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 4 : (section == 1 ? self.nativePlugins.count : self.pythonPlugins.count) }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 1: return "Нативные адаптеры"
        case 2: return "Python-плагины"
        default: return nil
        }
    }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            if self.batchSelecting { return "Выберите установленные плагины в нужном порядке, затем подтвердите последовательное включение. Импорт не запускает плагины." }
            return "Установка не включает плагины автоматически. Выберите несколько установленных плагинов для последовательного включения или откройте последний отчёт."
        case 1: return "Функции этих плагинов обслуживают нативные адаптеры iOS. Python-код и Android-хуки не запускаются."
        case 2: return self.service.startupError ?? (self.service.plugins.isEmpty ? "Плагинов пока нет. Откройте файл .plugin в чате или импортируйте его здесь." : "Python-плагины включаются только с вашего согласия и не запускаются автоматически.")
        default: return nil
        }
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        if indexPath.section == 0 {
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = "Импортировать .plugin"; cell.imageView?.image = UIImage(systemName: "square.and.arrow.down")
            case 1:
                if self.batchSelecting {
                    let available = self.service.plugins.filter { !$0.isBusy }.count
                    let allSelected = available > 0 && self.selectedPluginIDs.count == available
                    cell.textLabel?.text = allSelected ? "Очистить выбор" : "Выбрать все доступные (\(available))"
                    cell.imageView?.image = UIImage(systemName: allSelected ? "xmark.circle" : "checkmark.circle")
                    cell.textLabel?.textColor = .systemBlue
                } else {
                    cell.textLabel?.text = "Выбрать плагины для серии…"
                    cell.imageView?.image = UIImage(systemName: "checklist")
                }
            case 2:
                if self.batchRunning {
                    let progress = self.batchProgress.map { "\($0.completed) из \($0.total)" } ?? "Подготовка…"
                    let operation = self.batchOperation == .importDisabled ? "Импорт выключенными" : "Включение серии"
                    cell.textLabel?.text = self.batchCancellationRequested ? "Остановка после текущего файла" : operation + " · " + progress
                    cell.imageView?.image = UIImage(systemName: self.batchCancellationRequested ? "hourglass" : "arrow.trianglehead.2.clockwise.rotate.90")
                    cell.textLabel?.textColor = self.batchCancellationRequested ? .secondaryLabel : .systemBlue
                    cell.accessoryType = self.batchCancellationRequested ? .none : .disclosureIndicator
                } else if self.batchSelecting {
                    cell.textLabel?.text = self.selectedPluginIDs.isEmpty ? "Отменить выбор" : "Включить выбранные (\(self.selectedPluginIDs.count))"
                    cell.imageView?.image = UIImage(systemName: self.selectedPluginIDs.isEmpty ? "xmark.circle" : "power")
                    cell.textLabel?.textColor = .systemBlue
                    cell.accessoryType = .disclosureIndicator
                } else {
                    cell.textLabel?.text = ""
                }
            default:
                cell.textLabel?.text = "Последний отчёт серии"
                cell.imageView?.image = UIImage(systemName: "doc.text.magnifyingglass")
                if let url = self.latestBatchLogURL {
                    cell.detailTextLabel?.text = url.lastPathComponent
                    cell.detailTextLabel?.numberOfLines = 2
                    cell.accessoryType = .disclosureIndicator
                } else {
                    cell.detailTextLabel?.text = "Отчёт появится после первой серии"
                    cell.accessoryType = .none
                }
            }
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.font = .preferredFont(forTextStyle: .body)
            cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.selectionStyle = indexPath.row != 3 || self.latestBatchLogURL != nil ? .default : .none
            return cell
        }
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
        let selected = self.selectedPluginIDs.contains(plugin.id)
        cell.accessoryType = self.batchSelecting ? (selected ? .checkmark : .none) : .disclosureIndicator
        cell.selectionStyle = plugin.isBusy || self.batchRunning ? .none : .default
        if self.batchSelecting { cell.accessibilityLabel = "\(plugin.name), \(selected ? "выбран" : "не выбран")" }
        cell.textLabel?.isEnabled = !plugin.isBusy
        return cell
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            switch indexPath.row {
            case 0:
                guard !self.batchRunning, !self.batchSelecting else { return }
                self.importPressed()
            case 1:
                guard !self.batchRunning else { return }
                if self.batchSelecting {
                    let available = self.service.plugins.filter { !$0.isBusy }
                    if self.selectedPluginIDs.count == available.count {
                        self.selectedPluginIDs.removeAll()
                    } else {
                        guard available.count <= AyuPluginCapacity.maximumInstalledPlugins else {
                            self.show(AyuPluginService.Failure.operation("RESOURCE_LIMIT")); return
                        }
                        self.selectedPluginIDs = available.map(\.id)
                    }
                    self.tableView.reloadData()
                } else {
                    self.batchSelecting = true
                    self.selectedPluginIDs.removeAll()
                    self.tableView.allowsMultipleSelection = true
                    self.tableView.reloadData()
                }
            case 2:
                if self.batchRunning {
                    guard !self.batchCancellationRequested else { return }
                    self.batchCancellationRequested = true
                    self.tableView.reloadRows(at: [IndexPath(row: 2, section: 0)], with: .none)
                } else if self.batchSelecting {
                    if self.selectedPluginIDs.isEmpty { self.finishBatchUI() }
                    else { self.confirmBatch() }
                }
            case 3: self.showLatestReport()
            default: break
            }
            return
        }
        guard !self.batchRunning, let plugin = self.plugin(at: indexPath), !plugin.isBusy else { return }
        if self.batchSelecting {
            if self.selectedPluginIDs.contains(plugin.id) {
                self.selectedPluginIDs.removeAll { $0 == plugin.id }
                tableView.deselectRow(at: indexPath, animated: true)
            } else if self.selectedPluginIDs.count < AyuPluginCapacity.maximumInstalledPlugins {
                self.selectedPluginIDs.append(plugin.id)
            }
            tableView.cellForRow(at: indexPath)?.accessoryType = self.selectedPluginIDs.contains(plugin.id) ? .checkmark : .none
            tableView.reloadRows(at: [IndexPath(row: 1, section: 0), IndexPath(row: 2, section: 0)], with: .none)
            return
        }
        self.openDetail(AyuPluginDetailViewController(plugin: plugin, service: self.service))
    }
    @objc private func importPressed() {
        guard !self.batchRunning, !self.batchSelecting else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType(filenameExtension: "plugin") ?? .data], asCopy: true)
        picker.allowsMultipleSelection = true; picker.delegate = self; self.present(picker, animated: true)
    }
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !self.batchRunning, !urls.isEmpty else { return }
        // Dismiss the picker before opening the preview; selection never installs code.
        controller.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            if urls.count == 1, let url = urls.first {
                self.openDetail(AyuPluginDetailViewController(sourceURL: url, service: self.service))
            } else {
                self.confirmImportBatch(urls)
            }
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

    private func confirmImportBatch(_ urls: [URL]) {
        guard urls.count <= AyuPluginCapacity.maximumInstalledPlugins else {
            self.show(AyuPluginService.Failure.operation("RESOURCE_LIMIT")); return
        }
        let alert = UIAlertController(title: "Установить выбранные файлы?", message: "Будет проверено и установлено до \(urls.count) плагинов. Все они останутся выключенными; запуск требует отдельного выбора и подтверждения доверия. Ошибка одного файла не остановит остальные. Повторные ID и существующие плагины будут пропущены без замены.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Установить выключенными", style: .default) { [weak self] _ in self?.runImportBatch(urls) })
        self.present(alert, animated: true)
    }

    private func runImportBatch(_ urls: [URL]) {
        guard !self.batchRunning, !urls.isEmpty else { return }
        self.batchRunning = true; self.batchOperation = .importDisabled; self.batchCancellationRequested = false; self.batchProgress = (0, urls.count)
        self.tableView.reloadData()
        Task { @MainActor in
            do {
                let summary = try await self.service.importBatch(from: urls,
                    isCancelled: { [weak self] in self?.batchCancellationRequested ?? true },
                    progress: { [weak self] completed, total in
                        self?.batchProgress = (completed, total)
                        self?.tableView.reloadRows(at: [IndexPath(row: 2, section: 0)], with: .none)
                    })
                self.finishBatchUI()
                let message = "Installed disabled: \(summary.succeeded) · Failed: \(summary.failed) · Skipped: \(summary.skipped) · Not attempted: \(summary.cancelled)\n\nReport: \(summary.logPath)"
                self.showBatchCompletion(title: "Import batch finished", message: message)
            } catch {
                self.finishBatchUI()
                self.show(error)
            }
        }
    }

    private func confirmBatch() {
        guard !self.batchRunning, !self.selectedPluginIDs.isEmpty else { return }
        let orderedIDs = self.selectedPluginIDs.filter { id in self.service.plugins.contains(where: { $0.id == id }) }
        let pythonCount = orderedIDs.filter { id in self.service.plugins.first(where: { $0.id == id })?.nativeAdapter == nil }.count
        let message = "Включить \(orderedIDs.count) установленных плагинов последовательно? Ошибка одного не остановит остальные.\(pythonCount > 0 ? " Python-код работает с правами приложения; продолжая, вы доверяете выбранным Python-плагинам." : "")"
        let alert = UIAlertController(title: "Включить выбранные плагины?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Доверяю, включить", style: .default) { [weak self] _ in self?.runBatch(orderedIDs) })
        self.present(alert, animated: true)
    }

    private func runBatch(_ ids: [String]) {
        guard !self.batchRunning, !ids.isEmpty else { return }
        self.batchRunning = true; self.batchOperation = .enable; self.batchCancellationRequested = false; self.batchProgress = (0, ids.count)
        self.tableView.allowsMultipleSelection = false
        self.tableView.reloadData()
        Task { @MainActor in
            do {
                let summary = try await self.service.enableBatch(ids,
                    isCancelled: { [weak self] in self?.batchCancellationRequested ?? true },
                    progress: { [weak self] completed, total in
                        self?.batchProgress = (completed, total)
                        self?.tableView.reloadRows(at: [IndexPath(row: 2, section: 0)], with: .none)
                    })
                self.finishBatchUI()
                let message = "Успешно: \(summary.succeeded) · Ошибки: \(summary.failed) · Пропущено: \(summary.skipped) · Не запущено после остановки: \(summary.cancelled)\n\nОтчёт: \(summary.logPath)"
                self.showBatchCompletion(title: "Серия завершена", message: message)
            } catch {
                self.finishBatchUI()
                self.show(error)
            }
        }
    }

    private func finishBatchUI() {
        self.batchRunning = false; self.batchOperation = nil; self.batchCancellationRequested = false; self.batchProgress = nil
        self.batchSelecting = false; self.selectedPluginIDs.removeAll()
        self.tableView.allowsMultipleSelection = false
        self.tableView.reloadData()
        self.refreshLatestBatchLog()
    }

    private func showBatchCompletion(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Открыть отчёт", style: .default) { [weak self] _ in self?.showLatestReport() })
        alert.addAction(UIAlertAction(title: "Готово", style: .cancel))
        self.presentManaged(alert)
    }

    private func showLatestReport() {
        Task { @MainActor in
            let url: URL?
            if let cachedURL = self.latestBatchLogURL {
                url = cachedURL
            } else {
                url = try? await self.service.latestBatchLog()
                self.latestBatchLogURL = url
            }
            guard let url else {
                self.show(AyuPluginService.Failure.storage); return
            }
            guard let data = try? await self.service.batchLogData(at: url), let text = String(data: data, encoding: .utf8) else {
                self.show(AyuPluginService.Failure.storage); return
            }
            let alert = UIAlertController(title: "Отчёт серии", message: "\(url.lastPathComponent)\n\nПоделитесь только этим автоматически сформированным, ограниченным и очищенным журналом.", preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "Просмотреть", style: .default) { [weak self] _ in
                self?.openReport(AyuPluginBatchReportViewController(text: text, path: url.lastPathComponent, reportURL: url))
            })
            alert.addAction(UIAlertAction(title: "Поделиться отчётом", style: .default) { [weak self, weak alert] _ in
                guard let self else { return }
                alert?.dismiss(animated: true) {
                    let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    if let popover = share.popoverPresentationController {
                        popover.sourceView = self.tableView
                        popover.sourceRect = self.tableView.rectForRow(at: IndexPath(row: 3, section: 0))
                    }
                    self.present(share, animated: true)
                }
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            if let popover = alert.popoverPresentationController {
                popover.sourceView = self.tableView
                popover.sourceRect = self.tableView.rectForRow(at: IndexPath(row: 3, section: 0))
            }
            self.present(alert, animated: true)
        }
    }

    private func openReport(_ controller: UIViewController) {
        if let navigationController = self.navigationController { navigationController.pushViewController(controller, animated: true) }
        else { self.presentManaged(UINavigationController(rootViewController: controller)) }
    }
}

@MainActor private final class AyuPluginBatchReportViewController: UIViewController {
    private let text: String
    private let path: String
    private let reportURL: URL
    init(text: String, path: String, reportURL: URL) { self.text = text; self.path = path; self.reportURL = reportURL; super.init(nibName: nil, bundle: nil); self.title = "Отчёт серии" }
    required init?(coder: NSCoder) { return nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground
        let pathLabel = UILabel(); pathLabel.text = self.path; pathLabel.font = .preferredFont(forTextStyle: .caption1)
        pathLabel.textColor = .secondaryLabel; pathLabel.numberOfLines = 3
        let content = UITextView(); content.text = self.text; content.isEditable = false; content.isSelectable = true
        content.font = .monospacedSystemFont(ofSize: 12, weight: .regular); content.adjustsFontForContentSizeCategory = true
        pathLabel.translatesAutoresizingMaskIntoConstraints = false; content.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(pathLabel); self.view.addSubview(content)
        NSLayoutConstraint.activate([
            pathLabel.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 12),
            pathLabel.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 16),
            pathLabel.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -8),
            content.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor)
        ])
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(self.shareReport))
    }
    @objc private func shareReport() {
        let activity = UIActivityViewController(activityItems: [self.reportURL], applicationActivities: nil)
        if let popover = activity.popoverPresentationController { popover.barButtonItem = self.navigationItem.rightBarButtonItem }
        self.present(activity, animated: true)
    }
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
