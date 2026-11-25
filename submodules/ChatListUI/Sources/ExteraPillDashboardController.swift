import AccountContext
import Display
import Foundation
import SGSimpleSettings
import SwiftSignalKit
import TelegramPresentationData
import UIKit

/// Standalone live pill display. Keeping this out of the chat list's custom header preserves its
/// story/search/folder geometry. The settings module supplies the configuration editor.
public func exteraPillDashboardController(context: AccountContext, edit: ((ViewController, ExteraPillSpec?) -> Void)? = nil, transfer: ((ViewController) -> Void)? = nil) -> ViewController {
    return ExteraPillDashboardController(context: context, edit: edit, transfer: transfer)
}

private final class ExteraPillDashboardController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let editPill: ((ViewController, ExteraPillSpec?) -> Void)?
    private let transfer: ((ViewController) -> Void)?
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let refreshControl = UIRefreshControl()
    private var specs: [ExteraPillSpec] = []
    private var observers: [NSObjectProtocol] = []
    private var lease: UUID?
    private var visible = false
    private var presentationData: PresentationData
    private var presentationDisposable: Disposable?

    init(context: AccountContext, edit: ((ViewController, ExteraPillSpec?) -> Void)?, transfer: ((ViewController) -> Void)?) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.editPill = edit
        self.transfer = transfer
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        self.updateNavigationText()
        self.presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.presentationData = data
            self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: data), transition: .immediate)
            self.updateNavigationText()
            if self.isViewLoaded { self.applyTheme(); self.tableView.reloadData() }
        })
        // Store notifications can fire inside UITableView move/delete or switch callbacks. Finish
        // that UIKit transaction before reloading rows or recalculating their automatic heights.
        self.observe(ExteraPillSettings.didChange, action: { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        })
        self.observe(ExteraPillRuntime.didChange, action: { [weak self] in
            DispatchQueue.main.async { self?.updateValues() }
        })
        self.observe(UIApplication.didEnterBackgroundNotification, action: { [weak self] in self?.stop() })
        self.observe(UIApplication.didBecomeActiveNotification, action: { [weak self] in self?.start() })
    }

    required init(coder: NSCoder) { preconditionFailure() }

    private var languageCode: String { self.presentationData.strings.baseLanguageCode }

    private func text(_ english: String, _ russian: String) -> String {
        return exteraPillText(self.languageCode, english, russian)
    }

    private func updateNavigationText() {
        self.title = self.text("HTTP Pills", "HTTP-плашки")
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        var buttons = [UIBarButtonItem(title: self.isViewLoaded && self.tableView.isEditing ? self.presentationData.strings.Common_Done : self.presentationData.strings.Common_Edit, style: .plain, target: self, action: #selector(self.editPressed))]
        if self.editPill != nil {
            let add = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(self.addPressed))
            add.accessibilityLabel = self.text("Add pill", "Добавить плашку")
            buttons.insert(add, at: 0)
        }
        self.navigationItem.rightBarButtonItems = buttons
    }

    deinit {
        self.presentationDisposable?.dispose()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
        if let lease = self.lease { ExteraPillRuntime.shared.release(lease) }
    }

    private func observe(_ name: Notification.Name, action: @escaping () -> Void) {
        self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: { _ in action() }))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 90
        self.tableView.contentInsetAdjustmentBehavior = .never
        self.refreshControl.addTarget(self, action: #selector(self.refreshPressed), for: .valueChanged)
        self.tableView.refreshControl = self.refreshControl
        self.view.insertSubview(self.tableView, at: 0)
        self.applyTheme()
        self.reload()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let insets = layout.insets(options: [.input])
        transition.updateFrame(view: self.tableView, frame: CGRect(x: layout.safeInsets.left, y: 0, width: max(0, layout.size.width - layout.safeInsets.left - layout.safeInsets.right), height: layout.size.height))
        self.tableView.contentInset = UIEdgeInsets(top: self.navigationLayout(layout: layout).navigationFrame.maxY, left: 0, bottom: insets.bottom, right: 0)
        self.tableView.scrollIndicatorInsets = self.tableView.contentInset
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.visible = true
        self.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.visible = false
        self.stop()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.visible = false
        self.stop()
    }

    private func start() {
        guard self.visible, self.lease == nil, UIApplication.shared.applicationState != .background else { return }
        self.lease = ExteraPillRuntime.shared.acquire()
        self.updateValues()
    }

    private func stop() {
        if let lease = self.lease {
            self.lease = nil
            ExteraPillRuntime.shared.release(lease)
        }
        self.refreshControl.endRefreshing()
    }

    private func applyTheme() {
        let theme = self.presentationData.theme
        self.view.backgroundColor = theme.list.blocksBackgroundColor
        self.tableView.backgroundColor = theme.list.blocksBackgroundColor
        self.tableView.separatorColor = theme.list.itemBlocksSeparatorColor
        self.tableView.tintColor = theme.list.itemAccentColor
    }

    private func reload() {
        self.specs = ExteraPillSettings.shared.pills
        if self.isViewLoaded { self.tableView.reloadData() }
    }

    private func updateValues() {
        guard self.isViewLoaded, self.visible else { return }
        for case let cell as ExteraPillCell in self.tableView.visibleCells {
            guard let indexPath = self.tableView.indexPath(for: cell), indexPath.section == 0, indexPath.row < self.specs.count else { continue }
            self.configure(cell, spec: self.specs[indexPath.row])
        }
        if !self.tableView.isEditing {
            UIView.performWithoutAnimation {
                self.tableView.beginUpdates()
                self.tableView.endUpdates()
            }
        }
        if !self.specs.contains(where: { ExteraPillRuntime.shared.value(for: $0.id).isRefreshing }) {
            self.refreshControl.endRefreshing()
        }
    }

    @objc private func addPressed() {
        guard self.specs.count < ExteraPillSettings.maximumPills else { self.showError(exteraPillErrorDescription(.limitReached, languageCode: self.languageCode)); return }
        self.editPill?(self, nil)
    }

    @objc private func editPressed() {
        self.tableView.setEditing(!self.tableView.isEditing, animated: true)
        self.updateNavigationText()
    }

    @objc private func refreshPressed() { ExteraPillRuntime.shared.refresh(); self.updateValues() }

    func numberOfSections(in tableView: UITableView) -> Int { return self.transfer == nil ? 1 : 2 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return section == 0 ? self.specs.count : 1 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? self.text("Live Dashboard", "Панель данных") : nil
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return self.text("Exports contain the configured URLs, including any query tokens. Review before sharing.", "Экспорт содержит настроенные URL, включая токены в параметрах запроса. Проверьте их перед отправкой.") }
        if self.editPill == nil {
            return self.text("Tap a value to refresh. Configure pills in Settings → exteraGram → HTTP Pills. Use Edit to reorder or delete. Values refresh while this dashboard is visible.", "Нажмите на значение для обновления. Настройка плашек: Настройки → exteraGram → HTTP-плашки. Кнопка «Изменить» позволяет менять порядок и удалять плашки. Данные обновляются, пока эта панель открыта.")
        }
        return self.specs.isEmpty ? self.text("Add a pill to display a value from an HTTP JSON endpoint.", "Добавьте плашку для отображения значения из HTTP-источника JSON.") : self.text("Tap a value to refresh. Tap its row to edit. Use Edit to reorder or delete. Values refresh while this dashboard is visible; stale values show their last update. Percent formatting treats 0.25 as 25%.", "Нажмите на значение для обновления, на строку — для настройки. Кнопка «Изменить» позволяет менять порядок и удалять плашки. Данные обновляются, пока эта панель открыта; у сохранённых значений указано время обновления. Формат процентов отображает 0,25 как 25%.")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = self.text("Import / Export Pills", "Импорт / экспорт плашек")
            cell.textLabel?.textColor = self.presentationData.theme.list.itemAccentColor
            cell.backgroundColor = self.presentationData.theme.list.itemBlocksBackgroundColor
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        let cell = (tableView.dequeueReusableCell(withIdentifier: "pill") as? ExteraPillCell) ?? ExteraPillCell(reuseIdentifier: "pill")
        self.configure(cell, spec: self.specs[indexPath.row])
        return cell
    }

    private func configure(_ cell: ExteraPillCell, spec: ExteraPillSpec) {
        let value = ExteraPillRuntime.shared.value(for: spec.id)
        var status = spec.enabled ? self.text("Not refreshed", "Ещё не обновлялось") : self.text("Disabled", "Отключено")
        if spec.enabled {
            if let error = value.error { status = exteraPillErrorDescription(error, languageCode: self.languageCode) }
            if let date = value.updatedAt {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: exteraPillLanguageCode(self.languageCode))
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                let dateText = formatter.string(from: date)
                status = value.error == nil ? self.text("Updated \(dateText)", "Обновлено: \(dateText)") : self.text("\(status) · Last updated \(dateText)", "\(status) · Последнее обновление: \(dateText)")
            }
            if value.isRefreshing { status = self.text("Refreshing…", "Обновление…") }
        }
        cell.apply(spec: spec, value: spec.enabled ? value.text ?? "—" : "—", status: status, theme: self.presentationData.theme, languageCode: self.languageCode)
        cell.selectionStyle = self.editPill == nil ? .none : .default
        cell.refresh = { ExteraPillRuntime.shared.refresh(spec.id) }
        cell.toggle = { [weak self] enabled in
            var updated = spec
            updated.enabled = enabled
            do { try ExteraPillSettings.shared.upsert(updated) }
            catch {
                guard let self else { return }
                self.showError(self.text("The pill could not be saved.", "Не удалось сохранить плашку."))
            }
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 { self.editPill?(self, self.specs[indexPath.row]) }
        else { self.transfer?(self) }
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { return indexPath.section == 0 }
    func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        return self.text("Delete", "Удалить")
    }
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { return indexPath.section == 0 }
    func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath, toProposedIndexPath proposedDestinationIndexPath: IndexPath) -> IndexPath {
        return proposedDestinationIndexPath.section == 0 ? proposedDestinationIndexPath : IndexPath(row: max(0, self.specs.count - 1), section: 0)
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        var specs = self.specs
        let moved = specs.remove(at: sourceIndexPath.row)
        specs.insert(moved, at: destinationIndexPath.row)
        self.save(specs)
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        var specs = self.specs
        specs.remove(at: indexPath.row)
        self.save(specs)
    }

    private func save(_ specs: [ExteraPillSpec]) {
        do {
            try ExteraPillSettings.shared.replace(specs)
            self.specs = specs
        }
        catch { self.reload(); self.showError(self.text("The pills could not be saved.", "Не удалось сохранить плашки.")) }
    }

    private func showError(_ message: String) {
        guard self.viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: self.text("HTTP Pills", "HTTP-плашки"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.presentationData.strings.Common_OK, style: .default))
        self.present(alert, animated: true)
    }
}

private final class ExteraPillCell: UITableViewCell {
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let valueButton = UIButton(type: .system)
    private let enabledSwitch = UISwitch()
    var refresh: (() -> Void)?
    var toggle: ((Bool) -> Void)?

    init(reuseIdentifier: String) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        self.nameLabel.font = .preferredFont(forTextStyle: .body)
        self.nameLabel.adjustsFontForContentSizeCategory = true
        self.nameLabel.numberOfLines = 0
        self.statusLabel.font = .preferredFont(forTextStyle: .caption1)
        self.statusLabel.adjustsFontForContentSizeCategory = true
        self.statusLabel.numberOfLines = 0
        self.valueButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        self.valueButton.titleLabel?.adjustsFontForContentSizeCategory = true
        self.valueButton.titleLabel?.numberOfLines = 0
        if #available(iOS 15.0, *) {
            var configuration = UIButton.Configuration.plain()
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
            self.valueButton.configuration = configuration
        }
        self.valueButton.layer.cornerRadius = 16
        self.valueButton.addTarget(self, action: #selector(self.refreshPressed), for: .touchUpInside)
        self.enabledSwitch.addTarget(self, action: #selector(self.switchChanged), for: .valueChanged)
        self.accessoryView = self.enabledSwitch
        let stack = UIStackView(arrangedSubviews: [self.nameLabel, self.valueButton, self.statusLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { preconditionFailure() }

    func apply(spec: ExteraPillSpec, value: String, status: String, theme: PresentationTheme, languageCode: String) {
        self.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.nameLabel.text = spec.label
        self.nameLabel.textColor = theme.list.itemPrimaryTextColor
        self.statusLabel.text = status
        self.statusLabel.textColor = theme.list.itemSecondaryTextColor
        self.valueButton.setTitle(value, for: .normal)
        self.valueButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
        self.valueButton.backgroundColor = theme.list.itemAccentColor.withAlphaComponent(0.12)
        self.valueButton.isEnabled = spec.enabled
        self.valueButton.accessibilityLabel = "\(spec.label): \(value)"
        self.valueButton.accessibilityHint = exteraPillText(languageCode, "Refresh value", "Обновить значение")
        self.enabledSwitch.isOn = spec.enabled
        self.enabledSwitch.onTintColor = theme.list.itemAccentColor
        self.enabledSwitch.accessibilityLabel = exteraPillText(languageCode, "Enable \(spec.label)", "Включить: \(spec.label)")
    }

    @objc private func refreshPressed() { self.refresh?() }
    @objc private func switchChanged() { self.toggle?(self.enabledSwitch.isOn) }
}
