import Foundation
import UIKit

/// Shared by chat attachments, the document picker and the installed-plugin list.
/// Loading this screen inspects metadata only; execution requires a separate action.
@MainActor public final class AyuPluginDetailViewController: UITableViewController {
    private struct Row {
        let title: String
        var detail: String? = nil
        var icon: String? = nil
        var color: UIColor? = nil
        var enabled = true
        var action: (() -> Void)? = nil
    }
    private struct Section {
        var title: String? = nil
        var footer: String? = nil
        let rows: [Row]
    }

    private let service: AyuPluginService
    private let fileName: String?
    private let installedID: String?
    private var sourceURL: URL?
    private var stagedURL: URL?
    private var preview: AyuPluginImportPreview?
    private var installedAfterImport = false
    private var loading = false
    private var operationRunning = false
    private var failureMessage: String?
    private var sections: [Section] = []
    private var inspection: Task<Void, Never>?
    /// The attachment owner uses this to cancel its resource subscription.
    public var cancelSourceRequest: (() -> Void)?

    public init(fileName: String, service: AyuPluginService? = nil) {
        self.fileName = fileName
        self.installedID = nil
        self.service = service ?? .shared
        self.loading = true
        super.init(style: .insetGrouped)
        self.title = "Плагин"
    }

    public convenience init(sourceURL: URL, service: AyuPluginService? = nil) {
        self.init(fileName: sourceURL.lastPathComponent, service: service)
        self.sourceURL = sourceURL
    }

    public init(plugin: AyuInstalledPlugin, service: AyuPluginService? = nil) {
        self.fileName = nil
        self.installedID = plugin.id
        self.service = service ?? .shared
        super.init(style: .insetGrouped)
        self.title = plugin.name
    }

    required init?(coder: NSCoder) { return nil }

    isolated deinit {
        self.inspection?.cancel()
        self.cancelSourceRequest?()
        NotificationCenter.default.removeObserver(self)
        if let stagedURL = self.stagedURL {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: stagedURL.deletingLastPathComponent()) }
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 64
        self.tableView.cellLayoutMarginsFollowReadableWidth = true
        NotificationCenter.default.addObserver(self, selector: #selector(self.serviceChanged(_:)), name: AyuPluginService.didChange, object: self.service)
        if self.navigationController?.viewControllers.first === self {
            self.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(self.closePressed))
        }
        self.rebuild()
        if let sourceURL = self.sourceURL { self.loadPlugin(from: sourceURL) }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if self.isBeingDismissed || self.isMovingFromParent || self.navigationController?.isBeingDismissed == true {
            self.inspection?.cancel()
            self.cancelSourceRequest?()
            self.cancelSourceRequest = nil
        }
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AyuNativePluginRuntime.shared.feedbackPresenter = { [weak self] in
            guard let self else { return nil }
            var presenter = self.navigationController?.topViewController ?? self
            var depth = 0
            while let presented = presenter.presentedViewController, !presented.isBeingDismissed, depth < 8 {
                presenter = (presented as? UINavigationController)?.topViewController ?? presented
                depth += 1
            }
            return presenter
        }
    }

    /// The URL may be Telegram's extensionless cache file; fileName is the document name.
    public func loadPlugin(from url: URL) {
        guard self.preview == nil, self.installedID == nil, self.inspection == nil else { return }
        self.sourceURL = url
        self.loading = true
        self.failureMessage = nil
        if self.isViewLoaded { self.rebuild() }
        self.inspection = Task { [weak self] in
            guard let self else { return }
            do {
                let stagedURL: URL
                if let existing = self.stagedURL { stagedURL = existing }
                else {
                    let fileName = self.fileName ?? url.lastPathComponent
                    stagedURL = try await Task.detached(priority: .utility) { try Self.stage(url, fileName: fileName) }.value
                    self.stagedURL = stagedURL
                }
                try Task.checkCancellation()
                let preview = try await self.service.previewPlugin(from: stagedURL)
                guard !Task.isCancelled else { self.inspection = nil; return }
                self.preview = preview
            } catch {
                guard !Task.isCancelled else { self.inspection = nil; return }
                self.failureMessage = AyuPluginAlerts.message(error)
            }
            self.loading = false
            self.inspection = nil
            self.rebuild()
        }
    }

    public func sourceUnavailable() {
        guard self.preview == nil, self.inspection == nil else { return }
        self.loading = false
        self.failureMessage = "Не удалось загрузить вложение. Закройте окно, загрузите файл в чате и откройте его снова."
        if self.isViewLoaded { self.rebuild() }
    }

    private var installed: AyuInstalledPlugin? {
        guard let id = self.installedID ?? self.preview?.plugin.id else { return nil }
        return self.service.plugins.first { $0.id == id }
    }

    @objc private func serviceChanged(_ notification: Notification) { self.rebuild() }
    @objc private func closePressed() { guard !self.operationRunning else { return }; self.dismiss(animated: true) }

    private func rebuild() {
        guard self.isViewLoaded else { return }
        var result: [Section] = []
        let installed = self.installed
        let candidate = self.installedID != nil || self.installedAfterImport ? installed : self.preview?.plugin
        let busy = self.operationRunning || installed?.isBusy == true
        self.navigationItem.leftBarButtonItem?.isEnabled = !busy
        self.isModalInPresentation = busy
        self.navigationController?.isModalInPresentation = busy

        if let plugin = candidate {
            self.title = plugin.name
            let author = self.preview?.author ?? plugin.author ?? ""
            let description = self.preview?.description ?? plugin.description ?? ""
            result.append(Section(rows: [Row(title: plugin.name, detail: (["Версия " + plugin.version] + (author.isEmpty ? [] : [author])).joined(separator: " · "), icon: "puzzlepiece.extension.fill")]))
            if !description.isEmpty {
                result.append(Section(title: "О плагине", rows: [Row(title: description)]))
            }
            var information = [Row(title: "Идентификатор", detail: plugin.id), Row(title: "Версия", detail: plugin.version)]
            if !author.isEmpty { information.append(Row(title: "Автор", detail: author)) }
            if let installed, !self.installedAfterImport, self.installedID == nil {
                information.append(Row(title: "Установленная версия", detail: installed.version))
            }
            result.append(Section(title: "Информация", rows: information))
            let requirements = self.preview?.requirements ?? plugin.requirements ?? []
            var requirementRows = [Row(title: plugin.nativeAdapter == nil ? "Среда Python и поддерживаемые API iOS" : "Нативный адаптер iOS", detail: plugin.blockers.isEmpty ? "Известных блокировок не обнаружено" : "Обнаружены неподдерживаемые требования", icon: "checklist")]
            requirementRows.append(contentsOf: requirements.prefix(64).map { Row(title: $0) })
            result.append(Section(title: "Требования", footer: "Проверка совместимости не гарантирует работу всех функций плагина.", rows: requirementRows))
            if !plugin.blockers.isEmpty {
                result.append(Section(title: "Ограничения совместимости", footer: "Файл можно сохранить, но включение недоступно, пока эти требования не поддерживаются.", rows: plugin.blockers.prefix(64).map { Row(title: $0, icon: "exclamationmark.triangle", color: .systemOrange) }))
            }

            if self.installedID == nil, !self.installedAfterImport, let preview = self.preview {
                let title = installed == nil ? "Установить плагин" : (installed?.version == plugin.version ? "Переустановить плагин" : "Обновить плагин")
                result.insert(Section(footer: installed == nil ? "После установки плагин останется выключенным. Включить его можно отдельным действием." : "Сохранённые настройки останутся. Перед заменой выключите установленный плагин; повторное включение требует вашего согласия.", rows: [Row(title: busy ? "Установка…" : title, icon: "square.and.arrow.down", color: .systemBlue, enabled: !busy && installed?.isEnabled != true, action: { [weak self] in self?.confirmInstall(preview) })]), at: 1)
            }
            if let installed {
                result.append(self.installedActions(installed, busy: busy))
            }
        } else if self.loading {
            result.append(Section(footer: "Загружаем файл, читаем метаданные и проверяем требования. Код плагина не запускается.", rows: [Row(title: "Проверка плагина…", detail: self.fileName, icon: "doc.text.magnifyingglass")]))
        } else if self.installedID != nil {
            result.append(Section(rows: [Row(title: "Плагин удалён", icon: "trash")]))
        }
        if let message = self.failureMessage {
            result.insert(Section(title: "Не удалось выполнить действие", rows: [Row(title: message, icon: "exclamationmark.circle", color: .systemRed)]), at: min(1, result.count))
            if let sourceURL = self.sourceURL, self.preview == nil {
                result.append(Section(rows: [Row(title: "Повторить проверку", icon: "arrow.clockwise", color: .systemBlue, action: { [weak self] in self?.loadPlugin(from: sourceURL) })]))
            }
        }
        result.append(Section(rows: [Row(title: "Все плагины", icon: "square.grid.2x2", color: .systemBlue, enabled: !busy, action: { [weak self] in self?.openManager() })]))
        self.sections = result
        self.tableView.reloadData()
    }

    private func installedActions(_ plugin: AyuInstalledPlugin, busy: Bool) -> Section {
        var rows = [Row(title: plugin.status, icon: plugin.isEnabled ? "checkmark.circle.fill" : "pause.circle", color: plugin.isEnabled ? .systemGreen : .secondaryLabel)]
        if let error = plugin.error { rows.append(Row(title: error, icon: "exclamationmark.circle", color: .systemRed)) }
        if plugin.isEnabled {
            if let title = self.service.nativeActionTitle(for: plugin.id) {
                rows.append(Row(title: title, icon: "arrow.up.forward.app", color: .systemBlue, enabled: !busy, action: { [weak self] in
                    guard let self else { return }
                    do { try self.service.openNativePlugin(plugin.id, from: self) }
                    catch { self.show(error) }
                }))
            }
            rows.append(Row(title: "Настройки плагина", icon: "slider.horizontal.3", color: .systemBlue, enabled: !busy, action: { [weak self] in
                guard let self else { return }
                self.navigationController?.pushViewController(AyuPluginSettingsViewController(service: self.service, plugin: plugin), animated: true)
            }))
            rows.append(Row(title: "Выключить", icon: "power", color: .systemBlue, enabled: !busy, action: { [weak self] in
                self?.run { [weak self] in try await self?.service.disable(plugin.id) }
            }))
            if plugin.nativeAdapter == nil {
                rows.append(Row(title: "Предпросмотр интерфейса", icon: "rectangle.on.rectangle", color: .systemBlue, enabled: !busy, action: { [weak self] in
                    guard let self else { return }
                    self.navigationController?.pushViewController(AyuPluginPreviewViewController(service: self.service, plugin: plugin), animated: true)
                }))
            }
        } else if plugin.blockers.isEmpty {
            rows.append(Row(title: "Включить плагин…", icon: "power", color: .systemBlue, enabled: !busy, action: { [weak self] in self?.confirmEnable(plugin) }))
        }
        rows.append(Row(title: "Удалить плагин", icon: "trash", color: .systemRed, enabled: !busy, action: { [weak self] in self?.confirmDelete(plugin) }))
        return Section(title: self.installedAfterImport ? "Плагин установлен" : "Установленный плагин", rows: rows)
    }

    private func confirmInstall(_ preview: AyuPluginImportPreview) {
        guard !self.operationRunning, self.installed?.isBusy != true, self.installed?.isEnabled != true, let stagedURL = self.stagedURL else { return }
        let replacingExisting = self.installed != nil
        let install = { [weak self] in
            self?.run { [weak self] in
                guard let self else { return }
                try await self.service.importPlugin(from: stagedURL, replacingExisting: replacingExisting, expectedSHA256: preview.sourceSHA256)
                self.installedAfterImport = true
            }
        }
        if let installed = self.installed {
            let alert = UIAlertController(title: "Заменить установленный плагин?", message: "«\(installed.name)» \(installed.version) → \(preview.plugin.version). Настройки сохранятся. Плагин останется выключенным.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            alert.addAction(UIAlertAction(title: "Заменить", style: .default) { _ in install() })
            self.present(alert, animated: true)
        } else { install() }
    }

    private func confirmEnable(_ plugin: AyuInstalledPlugin) {
        let isNative = plugin.nativeAdapter != nil
        let message = isNative
            ? "Функции включатся через нативный адаптер iOS после проверки исходника. После перезапуска приложения плагин потребуется включить снова."
            : "Python-код получит права приложения, включая доступ к данным и сети. Включайте только плагин, автору которого доверяете. После перезапуска приложения плагин потребуется включить снова."
        let alert = UIAlertController(title: isNative ? "Включить плагин?" : "Доверять коду плагина?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: isNative ? "Включить" : "Доверяю, включить", style: .default) { [weak self] _ in
            self?.run { [weak self] in try await self?.service.enable(plugin.id) }
        })
        self.present(alert, animated: true)
    }

    private func confirmDelete(_ plugin: AyuInstalledPlugin) {
        let alert = UIAlertController(title: "Удалить плагин?", message: "Будут удалены локальная копия кода и настройки плагина «\(plugin.name)».", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in
            self?.run { [weak self] in
                guard let self else { return }
                try await self.service.delete(plugin.id)
                if self.installedID != nil { self.navigationController?.popViewController(animated: true) }
                else { self.installedAfterImport = false }
            }
        })
        self.present(alert, animated: true)
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !self.operationRunning else { return }
        self.operationRunning = true
        self.failureMessage = nil
        self.rebuild()
        Task {
            do { try await work() }
            catch { self.failureMessage = AyuPluginAlerts.message(error) }
            self.operationRunning = false
            self.rebuild()
        }
    }

    private func show(_ error: Error) {
        self.failureMessage = AyuPluginAlerts.message(error)
        self.rebuild()
    }

    private func openManager() {
        guard let navigationController = self.navigationController else { return }
        if let manager = navigationController.viewControllers.first(where: { $0 is AyuPluginManagerViewController }) {
            navigationController.popToViewController(manager, animated: true)
        } else {
            navigationController.pushViewController(AyuPluginManagerViewController(service: self.service), animated: true)
        }
    }

    /// Copy only a bounded regular UTF-8 attachment, never execute it or trust its path extension.
    nonisolated private static func stage(_ url: URL, fileName: String) throws -> URL {
        guard (fileName as NSString).pathExtension.lowercased() == "plugin" else { throw AyuPluginService.Failure.source }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let flags = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard flags.isRegularFile == true, flags.isSymbolicLink != true else { throw AyuPluginService.Failure.source }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: AyuPluginService.maximumSourceBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= AyuPluginService.maximumSourceBytes, String(data: data, encoding: .utf8) != nil else { throw AyuPluginService.Failure.source }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AyuPluginPreview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let destination = directory.appendingPathComponent("preview.plugin")
        do { try data.write(to: destination, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw AyuPluginService.Failure.storage }
        return destination
    }

    public override func numberOfSections(in tableView: UITableView) -> Int { self.sections.count }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { self.sections[section].rows.count }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { self.sections[section].title }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { self.sections[section].footer }

    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = self.sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = row.title
        cell.textLabel?.numberOfLines = 0
        let isTitle = indexPath.section == 0 && (self.preview != nil || self.installedID != nil)
        cell.textLabel?.font = .preferredFont(forTextStyle: isTitle ? .headline : .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.text = row.detail
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .subheadline)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.imageView?.image = row.icon.flatMap { UIImage(systemName: $0) }
        if isTitle {
            cell.imageView?.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
            cell.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16)
            cell.textLabel?.font = .preferredFont(forTextStyle: .title2)
        }
        cell.imageView?.tintColor = row.color ?? .systemBlue
        cell.textLabel?.textColor = row.enabled ? row.color ?? .label : .secondaryLabel
        cell.selectionStyle = row.action == nil || !row.enabled ? .none : .default
        cell.accessoryType = row.action != nil && row.enabled ? .disclosureIndicator : .none
        if row.action != nil && !row.enabled { cell.accessibilityTraits.insert(.notEnabled) }
        if self.loading && indexPath.section == 0 {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        }
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = self.sections[indexPath.section].rows[indexPath.row]
        guard row.enabled else { return }
        row.action?()
    }
}
