import UIKit

/// iOS has neither Android's drawer nor a global main menu. `main_menu` and
/// `drawer_menu` items are therefore rows of the plugin manager: a place that
/// belongs to no chat, which is what their `context` (`account` only) says.
@MainActor final class AyuPluginMainMenuSection: NSObject {
    static let title = "Меню плагинов"
    static let footer = "Пункты, которые включённые плагины добавили в главное меню. Долгое нажатие вызывает дополнительное действие, если оно есть."
    private let bridge: AyuPluginMenuBridge
    private weak var tableView: UITableView?
    private let section: Int
    private var session: AyuPluginMenuSession?
    private var query: Task<Void, Never>?

    init(bridge: AyuPluginMenuBridge = .shared, section: Int) {
        self.bridge = bridge; self.section = section
        super.init()
    }

    var rowCount: Int { self.session?.entries.count ?? 0 }
    var title: String? { self.rowCount == 0 ? nil : Self.title }
    var footer: String? { self.rowCount == 0 ? nil : Self.footer }

    func attach(to tableView: UITableView) {
        self.tableView = tableView
        tableView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:))))
    }

    /// Asks the plugins again; the rows change only when the answer arrives.
    func refresh() {
        self.query?.cancel()
        self.query = Task { @MainActor [weak self] in
            guard let bridge = self?.bridge else { return }
            let session = await bridge.open(AyuPluginMenuRequest(kind: .mainMenu, accountKey: nil), isPresented: { [weak self] in
                self?.tableView?.window != nil
            })
            guard !Task.isCancelled, let self else { return }
            self.session = session
            self.tableView?.reloadData()
        }
    }

    func cell(at row: Int) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        guard let entries = self.session?.entries, entries.indices.contains(row) else { return cell }
        let entry = entries[row]
        cell.textLabel?.text = entry.text
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.detailTextLabel?.text = entry.subtext
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.imageView?.image = entry.icon?.image(color: .label)
        return cell
    }

    func select(_ row: Int) { self.activate(row, longClick: false) }

    private func activate(_ row: Int, longClick: Bool) {
        guard let session = self.session, session.entries.indices.contains(row) else { return }
        session.activate(session.entries[row], longClick: longClick)
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let tableView = self.tableView,
              let indexPath = tableView.indexPathForRow(at: recognizer.location(in: tableView)), indexPath.section == self.section else { return }
        self.activate(indexPath.row, longClick: true)
    }
}
