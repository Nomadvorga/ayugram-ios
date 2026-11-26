import AccountContext
import Display
import SGSimpleSettings
import SwiftSignalKit
import TelegramPresentationData
import UIKit

final class ExteraUIIconPackEditorController: ViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let context: AccountContext
    private var pack: ExteraCustomUIIconPack
    private var preview: ExteraUIIconPackImport?
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let search = UISearchBar()
    private let filter = UISegmentedControl(items: ["All", "Replaced", "Not replaced"])
    private var rows: [String] = []
    private var observer: NSObjectProtocol?
    private var disposable: Disposable?
    private lazy var actions = ExteraUIIconPackActions(context: self.context, owner: self)
    private var data: PresentationData { return self.context.sharedContext.currentPresentationData.with { $0 } }
    private func text(_ key: String, _ en: String, _ ru: String) -> String { return exteraUIIconText(context, key, en, ru) }

    init(context: AccountContext, pack: ExteraCustomUIIconPack) {
        self.context = context; self.pack = pack
        let data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)))
        self.observer = NotificationCenter.default.addObserver(forName: ExteraUIIconSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.preview == nil, let updated = ExteraUIIconPackStore.shared.snapshot.all.first(where: { $0.id == self.pack.id }) else { return }
            self.pack = updated; self.reload()
        }
        self.disposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.setNavigationBarPresentationData(NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)), animated: false)
            if self.isNodeLoaded { self.reload() }
        })
    }
    convenience init(context: AccountContext, preview: ExteraUIIconPackImport) { self.init(context: context, pack: preview.pack); self.preview = preview }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; self.disposable?.dispose() }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode(); self.displayNodeDidLoad()
        self.view.addSubview(table)
        table.dataSource = self; table.delegate = self
        table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 58
        table.contentInsetAdjustmentBehavior = .never
        table.keyboardDismissMode = .onDrag
        search.delegate = self; search.autocapitalizationType = .none
        filter.selectedSegmentIndex = 0; filter.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 108))
        header.addSubview(search); header.addSubview(filter); table.tableHeaderView = header
        self.reload()
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        table.frame = CGRect(origin: .zero, size: layout.size)
        table.contentInset = UIEdgeInsets(top: navigationLayout(layout: layout).navigationFrame.maxY, left: layout.safeInsets.left, bottom: layout.insets(options: [.input]).bottom, right: layout.safeInsets.right)
        table.scrollIndicatorInsets = table.contentInset
        search.frame = CGRect(x: 8, y: 0, width: layout.size.width - 16, height: 56)
        filter.frame = CGRect(x: 16, y: 64, width: layout.size.width - 32, height: 32)
    }
    @objc private func filterChanged() { self.reload() }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { self.reload() }
    private func reload() {
        title = pack.name
        guard self.isNodeLoaded else { return }
        let theme = data.theme
        table.backgroundColor = theme.list.blocksBackgroundColor; table.separatorColor = theme.list.itemBlocksSeparatorColor
        table.tintColor = theme.list.itemAccentColor; search.barTintColor = theme.list.blocksBackgroundColor
        search.placeholder = text("SearchResource", "Search resource name", "Поиск по имени ресурса")
        for (i, label) in [text("All", "All", "Все"), text("Replaced", "Replaced", "Заменённые"), text("NotReplaced", "Not replaced", "Без замены")].enumerated() { filter.setTitle(label, forSegmentAt: i) }
        let keys = Set(ExteraUIIconCatalog.androidResources).union(ExteraUIIconRole.allCases.map { $0.androidResource }).union(pack.icons.keys)
        let query = (search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        rows = keys.filter { key in
            (query.isEmpty || key.localizedCaseInsensitiveContains(query)) && (filter.selectedSegmentIndex == 0 || (pack.icons[key] != nil) == (filter.selectedSegmentIndex == 1))
        }.sorted()
        table.reloadData()
    }
    func numberOfSections(in tableView: UITableView) -> Int { return 2 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return section == 0 ? (preview == nil ? 4 : 1) : rows.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return section == 0 ? pack.author + " · " + pack.version : text("Resources", "Resources", "Ресурсы") + " (\(rows.count))"
    }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return nil }
        if let preview {
            return text("ImportPreview", "Review the icons before installing. A pack with the same ID will be updated.", "Проверьте иконки перед установкой. Набор с таким ID будет обновлён.") + "\n" + pack.id + "\nSHA-256: " + preview.archiveSHA256
        }
        return text("EditorInfo", "Tap a resource to replace it. Reset removes this pack’s override. Add another Android resource name to retain icons beyond the supported iOS roles.", "Нажмите ресурс для замены. Сброс удаляет замену из этого набора. Можно добавить другое имя Android-ресурса, даже если оно пока не используется в iOS.")
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let theme = data.theme
        cell.backgroundColor = theme.list.itemBlocksBackgroundColor; cell.textLabel?.textColor = theme.list.itemPrimaryTextColor
        cell.detailTextLabel?.textColor = theme.list.itemSecondaryTextColor; cell.tintColor = theme.list.itemAccentColor
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 2
        if indexPath.section == 0 {
            let labels = preview == nil ? [text("PackDetails", "Pack details", "Сведения о наборе"), text("AddResource", "Add resource", "Добавить ресурс"), text("Export", "Export .icons", "Экспорт .icons"), text("DeletePack", "Delete pack", "Удалить набор")] : [text("Install", "Install / update", "Установить / обновить")]
            cell.textLabel?.text = labels[indexPath.row]; cell.textLabel?.textColor = indexPath.row == 3 ? theme.list.itemDestructiveColor : theme.list.itemAccentColor
        } else {
            let key = rows[indexPath.row]
            cell.textLabel?.text = key
            if let path = pack.icons[key] {
                cell.detailTextLabel?.text = path
                if let preview, let bytes = preview.files[path] { cell.imageView?.image = try? ExteraUIIconRendering.image(data: bytes, path: path) }
                else { cell.imageView?.image = ExteraUIIconRendering.image(pack: pack, path: path) }
            } else {
                cell.detailTextLabel?.text = text("Inherited", "Inherited", "Из следующего слоя")
                cell.imageView?.image = ExteraUIIconProvider.current.image(androidResource: key)
            }
            cell.accessoryType = preview == nil ? .disclosureIndicator : .none
        }
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        table.deselectRow(at: indexPath, animated: true)
        if let preview {
            guard indexPath.section == 0 else { return }
            actions.run({ try ExteraUIIconPackStore.shared.install(preview, enable: true) }, done: { [weak self] _ in
                guard let self else { return }; self.preview = nil; self.reload()
            })
            return
        }
        if indexPath.section == 1 { self.resource(rows[indexPath.row], source: table.cellForRow(at: indexPath)); return }
        switch indexPath.row {
        case 0: actions.details(pack)
        case 1:
            let alert = UIAlertController(title: text("AddResource", "Add resource", "Добавить ресурс"), message: "Android drawable", preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "msg_copy"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
            alert.addAction(UIAlertAction(title: text("Cancel", "Cancel", "Отмена"), style: .cancel))
            alert.addAction(UIAlertAction(title: text("ChooseImage", "Choose image", "Выбрать изображение"), style: .default) { [weak self, weak alert] _ in
                guard let self, let key = alert?.textFields?.first?.text, key.range(of: #"^[A-Za-z0-9_]{1,256}$"#, options: .regularExpression) != nil else { return }
                self.actions.chooseImage(pack: self.pack.id, resource: key)
            }); present(alert, animated: true)
        case 2: actions.export(pack)
        default:
            let alert = UIAlertController(title: text("DeletePack", "Delete pack", "Удалить набор"), message: pack.name, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: text("Cancel", "Cancel", "Отмена"), style: .cancel))
            alert.addAction(UIAlertAction(title: text("Delete", "Delete", "Удалить"), style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.actions.run({ try ExteraUIIconPackStore.shared.delete(self.pack.id) }, done: { [weak self] _ in let _ = self?.navigationController?.popViewController(animated: true) })
            }); present(alert, animated: true)
        }
    }
    private func resource(_ key: String, source: UIView?) {
        let alert = UIAlertController(title: key, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: text("Replace", "Replace image", "Заменить изображение"), style: .default) { [weak self] _ in
            guard let self else { return }; self.actions.chooseImage(pack: self.pack.id, resource: key)
        })
        if pack.icons[key] != nil {
            alert.addAction(UIAlertAction(title: text("Reset", "Reset", "Сбросить"), style: .destructive) { [weak self] _ in
                guard let self else { return }; self.actions.run({ try ExteraUIIconPackStore.shared.edit(self.pack.id, resource: key) }, done: { _ in })
            })
        }
        alert.addAction(UIAlertAction(title: text("Cancel", "Cancel", "Отмена"), style: .cancel))
        alert.popoverPresentationController?.sourceView = source ?? view
        alert.popoverPresentationController?.sourceRect = (source ?? view).bounds
        present(alert, animated: true)
    }
}
