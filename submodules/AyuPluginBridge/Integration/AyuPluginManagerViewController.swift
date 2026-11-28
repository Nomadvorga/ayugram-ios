import UIKit
import UniformTypeIdentifiers

/// The plugin list follows exteraGram's `PluginsActivity`: one card per plugin, pinned first and
/// then by name, with a name search. The rows above the list (import, batch enable, report) and
/// the tap that opens a plugin's detail screen are iOS additions; Android's engine switch,
/// catalog and info screen have no counterpart here.
@MainActor public final class AyuPluginManagerViewController: UITableViewController, UIDocumentPickerDelegate, UISearchBarDelegate {
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
    private let pluginMenu = AyuPluginMainMenuSection(section: 3)
    private let pins: AyuPluginPins
    private let defaults: UserDefaults
    /// Android keeps this switch on its plugin engine screen, which iOS does not have.
    private var compact: Bool {
        get { self.defaults.bool(forKey: AyuPluginCell.compactKey) }
        set { self.defaults.set(newValue, forKey: AyuPluginCell.compactKey) }
    }
    /// Android's `ExteraConfig.pluginsEngine`: off until the user turns it on. While it is off the
    /// screen is its switch alone and no plugin runs.
    public nonisolated static let engineKey = "AyuPluginBridge.pluginsEngine"
    /// The stored switch, for the app's other ways into plugins (a plugin file opened in a chat).
    public nonisolated static var isEngineEnabled: Bool { UserDefaults.standard.bool(forKey: Self.engineKey) }
    private var engine: Bool {
        get { self.defaults.bool(forKey: Self.engineKey) }
        set { self.defaults.set(newValue, forKey: Self.engineKey) }
    }
    private var switchingEngine = false
    typealias EngineColors = (on: UIColor, off: UIColor, trackOn: UIColor, trackOff: UIColor, thumbOn: UIColor, thumbOff: UIColor)
    /// Android's built-in themes, as far as they give the banner colours of their own ("Arctic
    /// Blue" has those of "Day").
    public enum EngineTheme: Sendable {
        case classic, day, darkBlue, night
    }
    /// The Android theme the app's theme stands for. Without it light is `classic`, Android's
    /// default, and dark is `darkBlue`, the theme its night mode starts with.
    public var engineTheme: EngineTheme? {
        didSet {
            guard self.engineTheme != oldValue, self.isViewLoaded, let banner = self.tableView.cellForRow(at: IndexPath(row: 0, section: 0)) else { return }
            let colors = self.bannerColors
            banner.backgroundColor = self.engine ? colors.on : colors.off
            (banner.backgroundView as? AyuPluginRippleView)?.set(self.engine ? colors.on : colors.off, from: nil)
            (banner.accessoryView as? AyuPluginRippleSwitch)?.looks = ((colors.trackOn, colors.thumbOn), (colors.trackOff, colors.thumbOff))
        }
    }
    /// Android's colours for the banner of `VIEW_TYPE_CHECKRIPPLE`: `windowBackgroundChecked`,
    /// `windowBackgroundUnchecked`, `switchTrackBlueChecked`, `switchTrackBlue`,
    /// `switchTrackBlueThumbChecked`, `switchTrackBlueThumb`; its text is white.
    static func androidColors(_ theme: EngineTheme) -> EngineColors {
        let rgb: [UInt32]
        switch theme {
        case .classic: rgb = [0x229AF0, 0x96A2AD, 0x1079C4, 0x78828A, 0xFFFFFF, 0xFFFFFF]
        case .day: rgb = [0x229AF0, 0x96A2AD, 0x0084CB, 0x78828A, 0xFFFFFF, 0xFFFFFF]
        case .darkBlue: rgb = [0x4E81AB, 0x1D2733, 0x80D5FF, 0x58626E, 0x4E81AB, 0x1D2733]
        case .night: rgb = [0x2F76AB, 0x1E1E20, 0x77D1FF, 0x68686A, 0x2D82C3, 0x1E1E20]
        }
        let colors = rgb.map { UIColor(red: CGFloat($0 >> 16 & 0xff) / 255, green: CGFloat($0 >> 8 & 0xff) / 255, blue: CGFloat($0 & 0xff) / 255, alpha: 1) }
        return (colors[0], colors[1], colors[2], colors[3], colors[4], colors[5])
    }
    static let engineColors: EngineColors = {
        let light = androidColors(.classic), dark = androidColors(.darkBlue)
        let color = { (light: UIColor, dark: UIColor) in UIColor { $0.userInterfaceStyle == .dark ? dark : light } }
        return (color(light.on, dark.on), color(light.off, dark.off), color(light.trackOn, dark.trackOn), color(light.trackOff, dark.trackOff), color(light.thumbOn, dark.thumbOn), color(light.thumbOff, dark.thumbOff))
    }()
    private var bannerColors: EngineColors { self.engineTheme.map { Self.androidColors($0) } ?? Self.engineColors }
    /// Answers on main with the picture of document `index` of the sticker set named `pack`, or
    /// nil when there is none. The bridge has no Telegram media, so the app supplies this; without
    /// it no card has an icon. Each icon is asked for once while the screen lives.
    public typealias IconProvider = @MainActor (_ pack: String, _ index: Int, _ completion: @escaping @MainActor (UIImage?) -> Void) -> Void
    public var iconProvider: IconProvider? {
        didSet {
            self.iconGeneration += 1
            self.icons = [:]
            if self.isViewLoaded { self.reloadList() }
        }
    }
    /// Answers on main with the colours of `code` written in `language`: UTF-16 ranges and
    /// 0xAARRGGBB. `palette` is Android's colour of each Prism token name in the page's theme; a
    /// token takes the colour of its alias, else of its type, else of the token around it, and a
    /// run without any is left out. The app supplies it from the
    /// Prism engine it uses for code in chats; without it the code page stays plain, as it is on
    /// Android until the colours are ready.
    public typealias CodeHighlighter = @MainActor (_ code: String, _ language: String, _ palette: [String: UInt32], _ completion: @escaping @MainActor ([(range: Range<Int>, argb: UInt32)]) -> Void) -> Void
    public var codeHighlighter: CodeHighlighter?
    /// Answers on main with the picture of the first sticker of the set named `pack` that stands
    /// for `emoji`, or nil. Supplied by the app like `iconProvider`; the empty list asks it for
    /// its picture, once per emoji, and shows the emoji itself meanwhile.
    public typealias PlaceholderProvider = @MainActor (_ pack: String, _ emoji: String, _ completion: @escaping @MainActor (UIImage?) -> Void) -> Void
    public var placeholderProvider: PlaceholderProvider? {
        didSet {
            self.iconGeneration += 1
            self.placeholders = [:]
            if self.isViewLoaded { self.reloadList() }
        }
    }
    /// Makes a view that plays document `index` of the set `pack` in a loop and calls `started`
    /// once it draws, or nil when that sticker does not move. Asked for a card only after
    /// `iconProvider` gave its still picture, which shows until the view draws.
    public typealias IconPlayerProvider = @MainActor (_ pack: String, _ index: Int, _ started: @escaping @MainActor () -> Void) -> UIView?
    public var iconPlayerProvider: IconPlayerProvider? {
        didSet { if self.isViewLoaded { self.reloadList() } }
    }
    /// `iconPlayerProvider` for the empty list's picture: asked once `placeholderProvider` gave it.
    public typealias PlaceholderPlayerProvider = @MainActor (_ pack: String, _ emoji: String, _ started: @escaping @MainActor () -> Void) -> UIView?
    public var placeholderPlayerProvider: PlaceholderPlayerProvider? {
        didSet { if self.isViewLoaded { self.reloadList() } }
    }
    /// A requested icon has an entry; its value is nil until, or unless, a picture arrives.
    private var icons: [AyuPluginIconReference: UIImage?] = [:]
    private var placeholders: [String: UIImage?] = [:]
    private var iconGeneration = 0
    private let searchBar = UISearchBar()
    private var searching = false
    private var query = ""
    private var prepared = false
    private var arranged: (native: [AyuInstalledPlugin], python: [AyuInstalledPlugin])?
    private weak var toast: UIView?
    public init(service: AyuPluginService? = nil, defaults: UserDefaults = .standard) {
        // Resolve the actor-isolated singleton here, not in a nonisolated default argument.
        self.service = service ?? .shared
        self.pins = AyuPluginPins(defaults: defaults)
        self.defaults = defaults
        super.init(style: .insetGrouped)
        self.title = "Плагины"
    }
    required init?(coder: NSCoder) { return nil }
    public override func viewDidLoad() {
        super.viewDidLoad()
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 64
        self.tableView.keyboardDismissMode = .onDrag
        self.tableView.register(AyuPluginCell.self, forCellReuseIdentifier: AyuPluginCell.reuseIdentifier)
        self.tableView.register(AyuPluginEmptyCell.self, forCellReuseIdentifier: AyuPluginEmptyCell.reuseIdentifier)
        self.searchBar.searchBarStyle = .minimal
        self.searchBar.placeholder = "Поиск"
        self.searchBar.autocapitalizationType = .none
        self.searchBar.autocorrectionType = .no
        self.searchBar.delegate = self
        self.searchBar.sizeToFit()
        self.reloadList()
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(self.importPressed))
        NotificationCenter.default.addObserver(self, selector: #selector(self.serviceChanged(_:)), name: AyuPluginService.didChange, object: self.service)
        self.pluginMenu.attach(to: self.tableView)
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
            self.prepared = true
            self.reloadList()
            self.pluginMenu.refresh()
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func serviceChanged(_ notification: Notification) {
        self.reloadList()
        self.refreshLatestBatchLog()
        self.pluginMenu.refresh()
    }
    private func updateSearchBar() {
        let showsSearch = self.engine && (self.searching || !self.service.plugins.isEmpty)
        if showsSearch != (self.tableView.tableHeaderView != nil) { self.tableView.tableHeaderView = showsSearch ? self.searchBar : nil }
    }
    private func reloadList() {
        self.arranged = nil
        self.updateSearchBar()
        self.tableView.reloadData()
    }
    /// Android's `togglePluginsEngine`. Its shutdown is, here, every running plugin disabled; turning
    /// the engine on starts none, because nothing on iOS runs a plugin without being asked.
    @objc private func engineChanged(_ sender: UISwitch) {
        if !self.setEngine(sender.isOn, touchX: nil) { sender.setOn(self.engine, animated: true) }
    }

    /// `touchX` is where the banner was tapped, in its own coordinates; nil when its switch was
    /// flipped. False when the engine cannot change now.
    private func setEngine(_ value: Bool, touchX: CGFloat?) -> Bool {
        guard !self.switchingEngine, !self.batchSelecting, !self.batchRunning, value != self.engine else { return false }
        self.engine = value
        // The switch's own row stays, so its animation is not cut; the rest comes or goes around it.
        if let banner = self.tableView.cellForRow(at: IndexPath(row: 0, section: 0)) {
            let color = self.engine ? self.bannerColors.on : self.bannerColors.off
            banner.backgroundColor = color
            (banner.accessoryView as? AyuPluginRippleSwitch)?.settle()
            // The colour spreads from the touch: the tap, or the switch that was flipped.
            if let ripple = banner.backgroundView as? AyuPluginRippleView {
                let from = touchX.map { CGPoint(x: $0, y: 0) } ?? banner.accessoryView.map { $0.convert(CGPoint(x: $0.bounds.midX, y: 0), to: banner) }
                ripple.set(color, from: from.map { banner.convert($0, to: ripple).x })
            }
        }
        self.arranged = nil
        self.updateSearchBar()
        let before = self.tableView.numberOfRows(inSection: 0), after = self.actionRows.count
        let rows = { (range: Range<Int>) in range.map { IndexPath(row: $0, section: 0) } }
        self.tableView.performBatchUpdates {
            if after > before { self.tableView.insertRows(at: rows(before..<after), with: .fade) }
            if after < before { self.tableView.deleteRows(at: rows(after..<before), with: .fade) }
            self.tableView.reloadSections(IndexSet(1...3), with: .fade)
        }
        guard !self.engine else { return true }
        self.switchingEngine = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failure: Error?
            for plugin in self.service.plugins where plugin.isEnabled {
                do { try await self.service.disable(plugin.id) } catch { failure = error }
            }
            self.switchingEngine = false
            if let failure { self.show(failure) }
        }
        return true
    }
    /// The action rows are absent while a search is open; a batch brings them back.
    private var actionsHidden: Bool { self.searching && !self.batchSelecting && !self.batchRunning }
    /// The action rows on screen, by number: 5 engine switch, 0 import, 1 batch selection, 2 batch
    /// state, 3 last report, 4 compact view. The batch state has a row only while a batch is being
    /// selected or runs; with the engine off only its switch is left.
    private var actionRows: [Int] {
        if self.actionsHidden { return [] }
        if !self.engine { return [5] }
        return self.batchSelecting || self.batchRunning ? [5, 0, 1, 2, 3, 4] : [5, 0, 1, 3, 4]
    }
    @objc private func compactChanged(_ sender: UISwitch) {
        self.compact = sender.isOn
        // Only the cards on screen change, in place: a reload would cut the switch's own animation.
        self.reconfigureVisibleCards { _ in true }
        self.tableView.performBatchUpdates(nil)
    }
    private func reconfigureVisibleCards(where matches: (AyuInstalledPlugin) -> Bool) {
        for case let cell as AyuPluginCell in self.tableView.visibleCells {
            guard let indexPath = self.tableView.indexPath(for: cell), let plugin = self.plugin(at: indexPath), matches(plugin) else { continue }
            self.configure(cell, with: plugin)
        }
    }
    private func icon(for plugin: AyuInstalledPlugin) -> AyuPluginCell.Icon {
        guard let provider = self.iconProvider, let reference = AyuPluginIconReference(plugin.icon) else { return .none }
        if self.icons[reference] == nil {
            if self.icons.count >= AyuPluginCapacity.maximumInstalledPlugins {
                let listed = Set(self.service.plugins.compactMap { AyuPluginIconReference($0.icon) })
                self.icons = self.icons.filter { listed.contains($0.key) }
            }
            self.icons[reference] = .some(nil)
            let generation = self.iconGeneration
            provider(reference.pack, reference.index) { [weak self] image in
                guard let self, self.iconGeneration == generation, let image else { return }
                self.icons[reference] = image
                // The slot is already there, so no row changes its height.
                self.reconfigureVisibleCards { AyuPluginIconReference($0.icon) == reference }
            }
        }
        guard let image = self.icons[reference] ?? nil else { return .pending }
        return .image(image, player: self.iconPlayerProvider.map { provider in { provider(reference.pack, reference.index, $0) } })
    }
    private func actionRow(at indexPath: IndexPath) -> Int? {
        let rows = self.actionRows
        return rows.indices.contains(indexPath.row) ? rows[indexPath.row] : nil
    }
    private func actionRect(_ row: Int) -> CGRect {
        guard let index = self.actionRows.firstIndex(of: row), index < self.tableView.numberOfRows(inSection: 0) else { return .zero }
        return self.tableView.rectForRow(at: IndexPath(row: index, section: 0))
    }
    private func reloadActionRows(_ rows: [Int]) {
        let count = self.tableView.numberOfRows(inSection: 0), shown = self.actionRows
        // A change of the row set is always followed by a full reload; only then do the counts differ.
        guard count == shown.count else { return }
        let paths = rows.compactMap { shown.firstIndex(of: $0) }.map { IndexPath(row: $0, section: 0) }
        if !paths.isEmpty { self.tableView.reloadRows(at: paths, with: .none) }
    }
    private func refreshLatestBatchLog() {
        self.latestBatchLogRefreshGeneration += 1
        let generation = self.latestBatchLogRefreshGeneration
        Task { @MainActor in
            let url = try? await self.service.latestBatchLog()
            guard generation == self.latestBatchLogRefreshGeneration else { return }
            self.latestBatchLogURL = url ?? nil
            self.reloadActionRows([3])
        }
    }
    /// The table asks this first on every reload, so the list is arranged once per reload and
    /// every later question of that pass is answered from the same rows.
    public override func numberOfSections(in tableView: UITableView) -> Int { self.arranged = nil; return 4 }
    private var listed: (native: [AyuInstalledPlugin], python: [AyuInstalledPlugin]) {
        if let arranged = self.arranged { return arranged }
        let all = AyuPluginListOrder.arrange(self.service.plugins, pinned: self.pins.ids, query: self.searching ? self.query : nil)
        let arranged = (native: all.filter { $0.nativeAdapter != nil }, python: all.filter { $0.nativeAdapter == nil })
        self.arranged = arranged
        return arranged
    }
    private var nativePlugins: [AyuInstalledPlugin] { self.listed.native }
    private var pythonPlugins: [AyuInstalledPlugin] { self.listed.python }
    /// One placeholder row closes the Python section when there is nothing to list.
    private var showsEmptyState: Bool { self.prepared && self.nativePlugins.isEmpty && self.pythonPlugins.isEmpty }
    private func indexPath(ofPlugin id: String) -> IndexPath? {
        if let row = self.nativePlugins.firstIndex(where: { $0.id == id }) { return IndexPath(row: row, section: 1) }
        if let row = self.pythonPlugins.firstIndex(where: { $0.id == id }) { return IndexPath(row: row, section: 2) }
        return nil
    }
    private func plugin(at indexPath: IndexPath) -> AyuInstalledPlugin? {
        switch indexPath.section {
        case 1: return indexPath.row < self.nativePlugins.count ? self.nativePlugins[indexPath.row] : nil
        case 2: return indexPath.row < self.pythonPlugins.count ? self.pythonPlugins[indexPath.row] : nil
        default: return nil
        }
    }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if !self.engine && section != 0 { return 0 }
        switch section {
        case 0: return self.actionRows.count
        case 1: return self.nativePlugins.count
        case 2: return self.pythonPlugins.count + (self.showsEmptyState ? 1 : 0)
        default: return self.searching ? 0 : self.pluginMenu.rowCount
        }
    }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if !self.engine { return nil }
        switch section {
        case 1: return self.nativePlugins.isEmpty ? nil : "Нативные адаптеры"
        case 2: return self.pythonPlugins.isEmpty ? nil : "Python-плагины"
        case 3: return self.searching ? nil : self.pluginMenu.title
        default: return nil
        }
    }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if !self.engine { return nil }
        switch section {
        case 0:
            if self.actionsHidden { return nil }
            if self.batchSelecting { return "Выберите установленные плагины в нужном порядке, затем подтвердите последовательное включение. Импорт не запускает плагины." }
            return "Установка не включает плагины автоматически. Выберите несколько установленных плагинов для последовательного включения или откройте последний отчёт."
        case 1: return self.nativePlugins.isEmpty ? nil : "Функции этих плагинов обслуживают нативные адаптеры iOS. Python-код и Android-хуки не запускаются."
        case 3: return self.searching ? nil : self.pluginMenu.footer
        case 2: return self.service.startupError ?? (self.pythonPlugins.isEmpty ? nil : "Python-плагины включаются только с вашего согласия и не запускаются автоматически.")
        default: return nil
        }
    }
    private func configure(_ cell: AyuPluginCell, with plugin: AyuInstalledPlugin) {
        cell.configure(plugin, pinned: self.pins.contains(plugin.id),
            selected: self.batchSelecting ? self.selectedPluginIDs.contains(plugin.id) : nil, locked: self.batchRunning, compact: self.compact,
            icon: self.icon(for: plugin))
        let id = plugin.id
        cell.onAction = { [weak self, weak cell] action in self?.perform(action, pluginID: id, from: cell) }
    }
    private static let placeholderPack = "AnimatedEmojies"
    private func placeholderPlayer(for emoji: String) -> AyuPluginCell.IconPlayer? {
        self.placeholderPlayerProvider.map { provider in { provider(Self.placeholderPack, emoji, $0) } }
    }
    /// Android's `setPlaceholderImage(view, "AnimatedEmojies", emoji, …)` of `PluginsActivity`.
    private func placeholder(for emoji: String) -> UIImage? {
        guard let provider = self.placeholderProvider else { return nil }
        if self.placeholders[emoji] == nil {
            self.placeholders[emoji] = .some(nil)
            let generation = self.iconGeneration
            provider(Self.placeholderPack, emoji) { [weak self] image in
                guard let self, self.iconGeneration == generation, let image else { return }
                self.placeholders[emoji] = image
                for case let cell as AyuPluginEmptyCell in self.tableView.visibleCells { cell.show(image, player: self.placeholderPlayer(for: emoji), for: emoji) }
            }
        }
        return self.placeholders[emoji] ?? nil
    }
    private func emptyCell(for indexPath: IndexPath) -> UITableViewCell {
        guard let cell = self.tableView.dequeueReusableCell(withIdentifier: AyuPluginEmptyCell.reuseIdentifier, for: indexPath) as? AyuPluginEmptyCell else { return UITableViewCell() }
        if self.searching {
            cell.configure(emoji: "🔎", picture: self.placeholder(for: "🔎"), player: self.placeholderPlayer(for: "🔎"), title: nil, message: "Плагины не найдены.", buttonTitle: nil)
        } else {
            cell.configure(emoji: "📂", picture: self.placeholder(for: "📂"), player: self.placeholderPlayer(for: "📂"), title: "Плагинов пока нет", message: "Откройте файл .plugin, .elyx или .eaf в чате или импортируйте его здесь.", buttonTitle: "Импортировать плагин")
            cell.onButton = { [weak self] in self?.importPressed() }
        }
        return cell
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 3 { return self.pluginMenu.cell(at: indexPath.row) }
        if indexPath.section != 0 {
            guard let plugin = self.plugin(at: indexPath),
                  let cell = tableView.dequeueReusableCell(withIdentifier: AyuPluginCell.reuseIdentifier, for: indexPath) as? AyuPluginCell else { return self.emptyCell(for: indexPath) }
            self.configure(cell, with: plugin)
            return cell
        }
        let row = self.actionRow(at: indexPath)
        let cell = row == 5 ? AyuPluginBannerCell(style: .subtitle, reuseIdentifier: nil) : UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        do {
            switch row {
            case nil: break
            case 0:
                cell.textLabel?.text = "Импортировать .plugin, .elyx, .eaf"; cell.imageView?.image = UIImage(systemName: "square.and.arrow.down")
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
            case 5:
                cell.textLabel?.text = "Включить систему плагинов"
                let colors = self.bannerColors
                let toggle = AyuPluginRippleSwitch(isOn: self.engine, on: (colors.trackOn, colors.thumbOn), off: (colors.trackOff, colors.thumbOff))
                toggle.addTarget(self, action: #selector(self.engineChanged(_:)), for: .valueChanged)
                cell.accessoryView = toggle
                cell.backgroundColor = self.engine ? colors.on : colors.off
                cell.backgroundView = AyuPluginRippleView(color: self.engine ? colors.on : colors.off)
                cell.textLabel?.textColor = .white
                let height = cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 56)
                height.priority = UILayoutPriority(999)
                height.isActive = true
            case 4:
                cell.textLabel?.text = "Компактный вид плагинов"
                cell.imageView?.image = UIImage(systemName: "rectangle.compress.vertical")
                let toggle = UISwitch()
                toggle.isOn = self.compact
                toggle.addTarget(self, action: #selector(self.compactChanged(_:)), for: .valueChanged)
                cell.accessoryView = toggle
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
            cell.textLabel?.font = row == 5 ? UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16, weight: .semibold)) : .preferredFont(forTextStyle: .body)
            cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.selectionStyle = row == 4 || row == 5 || (row == 3 && self.latestBatchLogURL == nil) ? .none : .default
        }
        return cell
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 3 { self.pluginMenu.select(indexPath.row); return }
        if indexPath.section == 0 {
            switch self.actionRow(at: indexPath) {
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
                    self.reloadActionRows([2])
                } else if self.batchSelecting {
                    if self.selectedPluginIDs.isEmpty { self.finishBatchUI() }
                    else { self.confirmBatch() }
                }
            case 3: self.showLatestReport()
            case 5:
                // Android flips the engine on a tap anywhere in the banner, not only on its switch.
                guard let banner = tableView.cellForRow(at: indexPath), let toggle = banner.accessoryView as? AyuPluginRippleSwitch else { return }
                if self.setEngine(!self.engine, touchX: (banner as? AyuPluginBannerCell)?.lastTouchX) {
                    // The circle reaches the switch on its way, and recolours it as it passes.
                    toggle.setOn(self.engine, following: banner.backgroundView as? AyuPluginRippleView)
                }
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
            if let cell = tableView.cellForRow(at: indexPath) as? AyuPluginCell { self.configure(cell, with: plugin) }
            self.reloadActionRows([1, 2])
            return
        }
        self.openDetail(AyuPluginDetailViewController(plugin: plugin, service: self.service))
    }
    @objc private func importPressed() {
        guard !self.batchRunning, !self.batchSelecting else { return }
        let types = (["plugin"] + AyuPluginService.packageExtensions).map { UTType(filenameExtension: $0) ?? .data }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
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
    private func openDetail(_ controller: UIViewController) {
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

    private func perform(_ action: AyuPluginCell.Action, pluginID: String, from cell: UIView?) {
        guard !self.batchRunning, !self.batchSelecting, let plugin = self.service.plugins.first(where: { $0.id == pluginID }) else { return }
        switch action {
        case .toggle:
            guard !plugin.isBusy else { return }
            if plugin.isEnabled {
                self.run(onFailure: { [weak self] in self?.toggleFailed(plugin, enabling: false, $0) }) { [service = self.service] in try await service.disable(pluginID) }
            }
            else if plugin.blockers.isEmpty { self.confirmEnable(plugin) }
        case .share:
            guard !plugin.isBusy else { return }
            self.share(plugin, from: cell)
        case .openIn:
            guard !plugin.isBusy else { return }
            self.openSource(plugin, from: cell)
        case .pin:
            self.pins.toggle(pluginID)
            self.reloadList()
            self.tableView.layoutIfNeeded()
            if let indexPath = self.indexPath(ofPlugin: pluginID) { self.tableView.scrollToRow(at: indexPath, at: .top, animated: true) }
        case .settings:
            guard plugin.isEnabled, !plugin.isBusy else { return }
            self.openDetail(AyuPluginSettingsViewController(service: self.service, plugin: plugin))
        case .delete:
            guard !plugin.isBusy else { return }
            self.present(AyuPluginAlerts.deleteConfirmation(for: plugin) { [weak self] in
                guard let self else { return }
                self.run { [service = self.service] in try await service.delete(pluginID) }
            }, animated: true)
        case .copyError:
            guard let error = plugin.error else { return }
            UIPasteboard.general.string = error
            self.showToast("Текст скопирован")
        }
    }

    /// The switch of a card asks for the same consent as the detail screen before anything runs.
    private func confirmEnable(_ plugin: AyuInstalledPlugin) {
        let consent = AyuPluginAlerts.enableConsent(for: plugin)
        let alert = UIAlertController(title: consent.title, message: consent.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: consent.confirm, style: .default) { [weak self] _ in
            guard let self else { return }
            self.run(onFailure: { [weak self] in self?.toggleFailed(plugin, enabling: true, $0) }) { [service = self.service] in try await service.enable(plugin.id) }
        })
        self.present(alert, animated: true)
    }

    private func run(onFailure: (@MainActor (Error) -> Void)? = nil, _ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor [weak self] in
            do { try await work() }
            catch { if let onFailure { onFailure(error) } else { self?.show(error) } }
        }
    }

    /// As on Android, a switch that failed says so in a bulletin whose button copies the reason.
    private func toggleFailed(_ plugin: AyuInstalledPlugin, enabling: Bool, _ error: Error) {
        let notice = AyuPluginAlerts.toggleFailure(plugin, enabling: enabling, error)
        let stored = self.service.plugins.first { $0.id == plugin.id }?.error
        let lines = [notice.title, notice.detail] + (stored.map { $0 == notice.detail ? [] : [$0] } ?? [])
        self.showToast(notice.title, detail: notice.detail, copying: lines.joined(separator: "\n"))
    }

    private func share(_ plugin: AyuInstalledPlugin, from source: UIView?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.presentShare(try await self.service.exportCopy(plugin.id), from: source)
            } catch { self.show(error) }
        }
    }

    /// Offers a copy made by `exportCopy` to other apps and removes it afterwards.
    private func presentShare(_ url: URL, from source: UIView?) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.completionWithItemsHandler = { _, _, _, _ in
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
        if let popover = activity.popoverPresentationController {
            let anchor = source ?? self.tableView
            popover.sourceView = anchor; popover.sourceRect = anchor?.bounds ?? .zero
        }
        self.presentManaged(activity)
    }

    /// Android `openInExternalApp`: the code is shown in the app when the file is text. A package
    /// or a file too large for that goes to the share sheet, where Android asks which app opens it.
    private func openSource(_ plugin: AyuInstalledPlugin, from source: UIView?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await self.service.exportCopy(plugin.id)
                guard let text = await Task.detached(priority: .userInitiated, operation: { AyuPluginSourceViewer.text(at: url) }).value else {
                    self.presentShare(url, from: source)
                    return
                }
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                self.openDetail(AyuPluginSourceViewController(fileName: url.lastPathComponent, text: text, theme: self.engineTheme, highlighter: self.codeHighlighter))
            } catch { self.show(error) }
        }
    }

    private func showToast(_ text: String, detail: String? = nil, copying copied: String? = nil) {
        guard let host = self.view.window ?? self.view.superview else { return }
        self.toast?.removeFromSuperview()
        let toast = AyuPluginBulletinView(text: text, detail: detail, actionTitle: copied == nil ? nil : "Копировать") { [weak self] in
            UIPasteboard.general.string = copied
            self?.showToast("Текст скопирован")
        }
        toast.alpha = 0
        toast.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 16),
            toast.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
        self.toast = toast
        UIAccessibility.post(notification: .announcement, argument: ([text] + (detail.map { [$0] } ?? [])).joined(separator: ". "))
        UIView.animate(withDuration: 0.2) { toast.alpha = 1 }
        // A delayed fade would make the notice transparent to touches for the whole delay.
        Task { @MainActor [weak toast] in
            try? await Task.sleep(nanoseconds: UInt64((toast?.duration ?? 0) * 1_000_000_000))
            guard let toast, toast.superview != nil else { return }
            UIView.animate(withDuration: 0.3, animations: { toast.alpha = 0 }, completion: { _ in toast.removeFromSuperview() })
        }
    }

    public func searchBarShouldBeginEditing(_ searchBar: UISearchBar) -> Bool { !self.batchSelecting && !self.batchRunning }
    public func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(true, animated: true)
        guard !self.searching else { return }
        self.searching = true
        self.reloadList()
    }
    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.query = searchText
        self.reloadList()
    }
    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    public func searchBarCancelButtonClicked(_ searchBar: UISearchBar) { self.endSearch() }
    /// A search left with an empty field is over; one with text stays until it is cancelled.
    public func searchBarTextDidEndEditing(_ searchBar: UISearchBar) { if self.query.isEmpty { self.endSearch() } }
    private func endSearch() {
        guard self.searching else { return }
        self.searching = false
        self.query = ""
        self.searchBar.text = nil
        self.searchBar.setShowsCancelButton(false, animated: true)
        self.searchBar.resignFirstResponder()
        self.reloadList()
    }

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
        Task { @MainActor [self] in
            do {
                let summary = try await self.service.importBatch(from: urls,
                    isCancelled: { [weak self] in self?.batchCancellationRequested ?? true },
                    progress: { [weak self] completed, total in
                        self?.batchProgress = (completed, total)
                        self?.reloadActionRows([2])
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
        Task { @MainActor [self] in
            do {
                let summary = try await self.service.enableBatch(ids,
                    isCancelled: { [weak self] in self?.batchCancellationRequested ?? true },
                    progress: { [weak self] completed, total in
                        self?.batchProgress = (completed, total)
                        self?.reloadActionRows([2])
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
        Task { @MainActor [self] in
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
                        popover.sourceRect = self.actionRect(3)
                    }
                    self.present(share, animated: true)
                }
            })
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
            if let popover = alert.popoverPresentationController {
                popover.sourceView = self.tableView
                popover.sourceRect = self.actionRect(3)
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
    /// The notice for a card switch that could not change its plugin (Android `PluginEnableError`, `PluginDisableError`).
    static func toggleFailure(_ plugin: AyuInstalledPlugin, enabling: Bool, _ error: Error) -> (title: String, detail: String) {
        ((enabling ? "Не удалось включить «" : "Не удалось выключить «") + plugin.name + "».", self.message(error))
    }
    /// What every enable asks first, from the list or from the detail screen.
    static func enableConsent(for plugin: AyuInstalledPlugin) -> (title: String, message: String, confirm: String) {
        if plugin.nativeAdapter != nil {
            return ("Включить плагин?", "Функции включатся через нативный адаптер iOS после проверки исходника. После перезапуска приложения плагин потребуется включить снова.", "Включить")
        }
        return ("Доверять коду плагина?", "Python-код получит права приложения, включая доступ к данным и сети. Включайте только плагин, автору которого доверяете. После перезапуска приложения плагин потребуется включить снова.", "Доверяю, включить")
    }
    static func deleteConfirmation(for plugin: AyuInstalledPlugin, delete: @escaping @MainActor () -> Void) -> UIAlertController {
        let alert = UIAlertController(title: "Удалить плагин?", message: "Будут удалены локальная копия кода и настройки плагина «\(plugin.name)».", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { _ in delete() })
        return alert
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
    /// Android's `targetSettingName`, resolved once after the first rows arrive: the row carrying the
    /// last alias is scrolled to and highlighted; each alias before it opens that row's sub-page.
    private var pendingLinkAlias: [String]
    private var highlightedRow: Int?
    init(service: AyuPluginService, plugin: AyuInstalledPlugin, subpageCallback: String? = nil, title: String = "Настройки плагина", linkAlias: [String] = []) {
        self.service = service; self.plugin = plugin; self.subpageCallback = subpageCallback; self.pendingLinkAlias = linkAlias
        super.init(style: .insetGrouped); self.title = title
    }
    required init?(coder: NSCoder) { return nil }
    isolated deinit { NotificationCenter.default.removeObserver(self) }
    override func viewDidLoad() {
        super.viewDidLoad()
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 64
        NotificationCenter.default.addObserver(self, selector: #selector(self.settingsChanged(_:)), name: AyuPluginNativeHost.settingsDidChange, object: self.service.host)
        // A plugin can open this screen on its own, without the manager below it.
        if self.navigationController?.viewControllers.first === self {
            self.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(self.closePressed))
        }
    }
    @objc private func closePressed() { self.dismiss(animated: true) }
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
            var loaded = false
            do {
                if let callback = self.subpageCallback {
                    self.rows = try await self.service.subpage(pluginID: self.plugin.id, callbackID: callback)
                } else {
                    self.rows = try await self.service.settings(self.plugin.id)
                }
                loaded = true
            } catch { self.pendingLinkAlias = []; self.present(AyuPluginAlerts.error(error), animated: true) }
            self.finishRowOperation()
            if loaded { self.resolveLinkAlias() }
        }
    }
    static func linkAliasRow(_ alias: String, in rows: [AyuPluginSetting]) -> Int? {
        rows.firstIndex { $0.descriptor["link_alias"].string == alias }
    }
    private func resolveLinkAlias() {
        guard let alias = self.pendingLinkAlias.first else { return }
        let rest = Array(self.pendingLinkAlias.dropFirst())
        self.pendingLinkAlias = []
        guard let index = Self.linkAliasRow(alias, in: self.rows) else { self.linkAliasNotFound(); return }
        guard rest.isEmpty else {
            guard let callback = self.rows[index].descriptor["create_sub_fragment"]["$callback"].string else { self.linkAliasNotFound(); return }
            let page = AyuPluginSettingsViewController(service: self.service, plugin: self.plugin, subpageCallback: callback, title: self.rows[index].text, linkAlias: rest)
            self.navigationController?.pushViewController(page, animated: true)
            return
        }
        let indexPath = IndexPath(row: index, section: 0)
        self.highlightedRow = index
        self.tableView.reloadRows(at: [indexPath], with: .none)
        self.tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.highlightedRow == index else { return }
            self.highlightedRow = nil
            self.tableView.reloadData()
        }
    }
    private func linkAliasNotFound() {
        let alert = UIAlertController(title: "Настройка не найдена", message: "У плагина «\(self.plugin.name)» нет настройки, на которую ведёт ссылка.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Понятно", style: .default))
        self.present(alert, animated: true)
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
        if indexPath.row == self.highlightedRow { cell.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.25) }
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
