import AccountContext
import Display
import Foundation
import ItemListUI
import SGItemListUI
import SGSimpleSettings
import SwiftSignalKit
import TelegramPresentationData
import UIKit

private enum ExteraBrowserFilterSection: Int32, SGItemListSection { case lists, actions, info }
private typealias ExteraBrowserFilterEntry = SGItemListUIEntry<ExteraBrowserFilterSection, Int, Int, Int, Int, Int>
private enum ExteraBrowserFilterRow {
    case action(ExteraBrowserFilterSection, String, ItemListActionKind, () -> Void)
    case notice(ExteraBrowserFilterSection, String)
    case toggle(ExteraBrowserFilterSection, String, Bool, (Bool) -> Void)
}

/// Push from browser settings. Downloaded lists are opt-in; bundled protection remains available.
public func exteraBrowserFiltersController(context: AccountContext) -> ViewController {
    ExteraBrowserFilterRuntime.shared.start()
    let title = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode.hasPrefix("ru") ? "Подписки фильтров" : "Filter Subscriptions"
    return ExteraBrowserFiltersPage.make(context: context, title: title, build: { page in
        let settings = ExteraBrowserFilters.shared
        var rows: [ExteraBrowserFilterRow] = settings.subscriptions.map { item in
            let status = ExteraBrowserFilterRuntime.shared.status(id: item.id)
            let suffix = status.updating ? page.text("Updating…", "Обновление…") : (status.cached ? "\(status.ruleCount) " + page.text("rules", "правил") : page.text("Not downloaded", "Не загружен"))
            return .action(.lists, (item.enabled ? "✓ " : "") + item.name + " · " + suffix, .generic, { page.open(item) })
        }
        rows.append(.action(.actions, page.text("Add HTTPS Subscription", "Добавить HTTPS-подписку"), .generic, { page.edit(nil) }))
        rows.append(.action(.actions, page.text("Update Enabled Lists", "Обновить включённые списки"), .generic, { ExteraBrowserFilterRuntime.shared.update() }))
        rows.append(.action(.actions, page.text("Cancel Updates", "Отменить обновления"), .generic, { ExteraBrowserFilterRuntime.shared.cancel() }))
        rows.append(.toggle(.actions, page.text("Update Expired Lists Automatically", "Автообновление устаревших списков"), settings.automaticUpdates, { settings.automaticUpdates = $0 }))
        rows.append(.action(.actions, page.text("Custom Network Filters", "Свои сетевые фильтры"), .generic, { page.openCustom() }))
        rows.append(.notice(.info, page.text("Lists update when the browser or these settings open. Expiry follows the list’s Expires header (6 hours–14 days; default 5 days). Cached rules work offline; failed updates keep the last good version. Automatic retries wait at least one hour. Adding a list downloads it while automatic updates are enabled.", "Списки обновляются при открытии браузера или этих настроек. Срок берётся из Expires (6 часов–14 дней; по умолчанию 5 дней). Кэш работает без сети, ошибка не удаляет прошлую версию. Автоповтор — не раньше чем через час. При включённом автообновлении новый список загружается автоматически.")))
        rows.append(.notice(.info, page.text("Supports a conservative ABP network subset: ||host^, URL anchors, simple wildcards and separators, @@ allow rules, resource types, third-party, match-case and domain restrictions. Top-level documents and frames are not blocked. Your exact-host browser exceptions override all lists.", "Поддерживается ограниченное подмножество сетевых ABP-фильтров: ||host^, якоря URL, простые маски и разделители, исключения @@, типы ресурсов, third-party, match-case и ограничения domain. Документы и фреймы не блокируются. Исключения браузера для точного домена имеют приоритет.")))
        rows.append(.notice(.info, page.text("Downloaded CSS/cosmetic filters, scriptlets, arbitrary regex, redirect/removeparam/CSP rules, metadata redirects, includes and conditional sections are skipped. Unknown options skip the entire rule. WebKit resource and third-party classifications can differ from ABP. This is not uBlock/AdGuard parity. Up to 4 lists, 6 MB per download, 10,000 converted rules per list and 1,000 custom rules. Lists may exceed WebKit’s compilation budget; failures are shown here and bundled protection is used.", "CSS/косметические фильтры подписок, скриптлеты, произвольные регулярные выражения, redirect/removeparam/CSP, перенаправления в метаданных, include и условные секции пропускаются. Неизвестная опция исключает правило целиком. Классификация ресурсов и third-party в WebKit может отличаться от ABP. Это не полный uBlock/AdGuard: до 4 списков, 6 МБ на загрузку, 10 000 преобразованных правил на список и 1 000 своих правил. При превышении лимитов компилятора WebKit ошибка отображается здесь, используется встроенная защита.")))
        if let error = ExteraBrowserFilterRuntime.shared.compilationError { rows.append(.notice(.info, error)) }
        if let error = ExteraBrowserFilterRuntime.shared.customRulesError { rows.append(.notice(.info, error)) }
        return rows
    })
}

private final class ExteraBrowserFiltersPage {
    let context: AccountContext
    weak var controller: ViewController?
    private let refresh = ValuePromise(true, ignoreRepeated: false)
    private var observers: [NSObjectProtocol] = []

    init(context: AccountContext) {
        self.context = context
        for name in [ExteraBrowserFilters.didChangeNotification, ExteraBrowserFilterRuntime.didChangeNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: { [weak self] _ in self?.refresh.set(true) }))
        }
    }

    deinit { for observer in self.observers { NotificationCenter.default.removeObserver(observer) } }

    static func make(context: AccountContext, title: String, build: @escaping (ExteraBrowserFiltersPage) -> [ExteraBrowserFilterRow]) -> ViewController {
        let page = ExteraBrowserFiltersPage(context: context)
        let signal = combineLatest(context.sharedContext.presentationData, page.refresh.get()) |> deliverOnMainQueue |> map { data, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let rows = build(page)
            let entries: [ExteraBrowserFilterEntry] = rows.enumerated().map { index, row in
                switch row {
                case let .action(section, text, kind, _): return .action(id: index, section: section, actionType: index, text: text, kind: kind)
                case let .notice(section, text): return .notice(id: index, section: section, text: text)
                case let .toggle(section, text, value, _): return .toggle(id: index, section: section, settingName: index, value: value, text: text, enabled: true)
                }
            }
            let arguments = SGItemListArguments<Int, Int, Int, Int, Int>(context: context, setBoolValue: { index, value in
                if rows.indices.contains(index), case let .toggle(_, _, _, update) = rows[index] { update(value) }
            }, action: { index in
                if rows.indices.contains(index), case let .action(_, _, _, action) = rows[index] { action() }
            })
            let state = ItemListControllerState(presentationData: ItemListPresentationData(data), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: data.strings.Common_Back))
            return (state, (ItemListNodeState(presentationData: ItemListPresentationData(data), entries: entries, style: .blocks, animateChanges: false), arguments))
        }
        let controller = ItemListController(context: context, state: signal)
        page.controller = controller
        return controller
    }

    func text(_ english: String, _ russian: String) -> String {
        return self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode.hasPrefix("ru") ? russian : english
    }

    private func push(_ controller: ViewController) { (self.controller?.navigationController as? NavigationController)?.pushViewController(controller) }
    private func pop() { let _ = (self.controller?.navigationController as? NavigationController)?.popViewController(animated: true) }

    private func error(_ error: Error) {
        let alert = UIAlertController(title: self.text("Filter Error", "Ошибка фильтров"), message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.text("OK", "ОК"), style: .default))
        self.controller?.present(alert, animated: true)
    }

    func edit(_ item: ExteraBrowserSubscription?) {
        let alert = UIAlertController(title: self.text("HTTPS Filter Subscription", "HTTPS-подписка на фильтры"), message: self.text("Enter the direct URL of an ABP text list. Changing the URL discards the previous cached rules. Updates of an unchanged URL keep the last good cache on failure.", "Введите прямой адрес текстового ABP-списка. Изменение адреса удаляет прежний кэш. При ошибке обновления неизменённого адреса последний рабочий кэш сохраняется."), preferredStyle: .alert)
        alert.addTextField { field in field.placeholder = self.text("Name", "Название"); field.text = item?.name; field.autocapitalizationType = .words }
        alert.addTextField { field in field.placeholder = "https://example.org/filters.txt"; field.text = item?.url; field.keyboardType = .URL; field.autocapitalizationType = .none; field.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: self.text("Save", "Сохранить"), style: .default, handler: { [weak self, weak alert] _ in
            guard let self, let alert else { return }
            let name = (alert.textFields?[0].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = (alert.textFields?[1].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var value = item ?? ExteraBrowserSubscription(name: name, url: url)
            value.name = name; value.url = url
            var subscriptions = ExteraBrowserFilters.shared.subscriptions
            if let item {
                guard let index = subscriptions.firstIndex(where: { $0.id == item.id }), subscriptions[index] == item else { self.error(ExteraBrowserFilterError.invalid("This subscription was edited or deleted. Reopen it before saving.")); return }
                subscriptions[index] = value
            } else { subscriptions.append(value) }
            do { try ExteraBrowserFilters.shared.setSubscriptions(subscriptions) } catch { DispatchQueue.main.async { self.error(error) } }
        }))
        self.controller?.present(alert, animated: true)
    }

    func open(_ item: ExteraBrowserSubscription) {
        self.push(Self.make(context: self.context, title: item.name, build: { page in
            guard let current = ExteraBrowserFilters.shared.subscriptions.first(where: { $0.id == item.id }) else { return [.notice(.info, page.text("Subscription deleted.", "Подписка удалена."))] }
            let state = ExteraBrowserFilterRuntime.shared.status(id: item.id)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium; formatter.timeStyle = .short
            var status = page.text("Converted rules: ", "Преобразовано правил: ") + "\(state.ruleCount)\n" + page.text("Unsupported: ", "Не поддерживается: ") + "\(state.unsupportedRules)\n" + page.text("Cosmetic rules skipped: ", "Пропущено косметических: ") + "\(state.cosmeticRules)\n" + page.text("Over limit: ", "Сверх лимита: ") + "\(state.omittedRules)"
            if let fetched = state.fetchedAt { status += "\n" + page.text("Updated: ", "Обновлено: ") + formatter.string(from: fetched) }
            if let expires = state.expiresAt { status += "\n" + page.text("Expires: ", "Истекает: ") + formatter.string(from: expires) }
            if let message = state.message { status += "\n\n" + message }
            return [
                .notice(.lists, current.url),
                .toggle(.lists, page.text("Enabled", "Включено"), current.enabled, { enabled in
                    var subscriptions = ExteraBrowserFilters.shared.subscriptions
                    guard let index = subscriptions.firstIndex(where: { $0.id == current.id }) else { return }
                    subscriptions[index].enabled = enabled
                    do { try ExteraBrowserFilters.shared.setSubscriptions(subscriptions) } catch { page.error(error) }
                }),
                .action(.actions, page.text("Edit Name and URL", "Изменить название и адрес"), .generic, { page.edit(current) }),
                .action(.actions, page.text("Update Now", "Обновить сейчас"), .generic, {
                    guard current.enabled else { page.error(ExteraBrowserFilterError.invalid(page.text("Enable this subscription before updating it.", "Включите подписку перед обновлением."))); return }
                    ExteraBrowserFilterRuntime.shared.update(id: current.id)
                }),
                .action(.actions, page.text("Cancel Update", "Отменить обновление"), .generic, { ExteraBrowserFilterRuntime.shared.cancel(id: current.id) }),
                .action(.actions, page.text("Delete Subscription", "Удалить подписку"), .destructive, {
                    let alert = UIAlertController(title: page.text("Delete Subscription?", "Удалить подписку?"), message: current.name, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: page.text("Cancel", "Отмена"), style: .cancel))
                    alert.addAction(UIAlertAction(title: page.text("Delete", "Удалить"), style: .destructive, handler: { _ in
                        do { try ExteraBrowserFilters.shared.setSubscriptions(ExteraBrowserFilters.shared.subscriptions.filter { $0.id != current.id }); page.pop() } catch { page.error(error) }
                    }))
                    page.controller?.present(alert, animated: true)
                }),
                .notice(.info, status)
            ]
        }))
    }

    func openCustom() {
        self.push(ExteraBrowserCustomFilterController(context: self.context))
    }
}

private final class ExteraBrowserCustomFilterController: ViewController {
    private let context: AccountContext
    private let editor = UITextView()
    private let status = UILabel()
    private let saveButton = UIButton(type: .system)
    private let container = UIScrollView()
    private var original: String

    init(context: AccountContext) {
        self.context = context
        self.original = ExteraBrowserFilters.shared.customRules
        let data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)))
        self.title = self.text("Custom Filters", "Свои фильтры")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func text(_ english: String, _ russian: String) -> String { return self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode.hasPrefix("ru") ? russian : english }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode()
        self.displayNodeDidLoad()
        let data = self.context.sharedContext.currentPresentationData.with { $0 }
        self.displayNode.backgroundColor = data.theme.list.blocksBackgroundColor
        self.editor.text = self.original
        self.editor.font = UIFont.preferredFont(forTextStyle: .body)
        self.editor.adjustsFontForContentSizeCategory = true
        self.editor.backgroundColor = data.theme.list.itemBlocksBackgroundColor
        self.editor.textColor = data.theme.list.itemPrimaryTextColor
        self.editor.tintColor = data.theme.list.itemAccentColor
        self.editor.layer.cornerRadius = 12
        self.editor.autocorrectionType = .no
        self.editor.autocapitalizationType = .none
        self.editor.smartQuotesType = .no
        self.editor.smartDashesType = .no
        self.editor.accessibilityLabel = self.title
        self.status.numberOfLines = 0
        self.status.font = UIFont.preferredFont(forTextStyle: .footnote)
        self.status.textColor = data.theme.list.itemSecondaryTextColor
        self.status.text = self.text("One ABP network filter per line. Examples:\n||ads.example.org^\n@@||ads.example.org/allowed.js$script\nCosmetic filters and unsupported options are skipped and counted when you save. Unsaved changes are discarded when you leave.", "Один сетевой ABP-фильтр на строку. Примеры:\n||ads.example.org^\n@@||ads.example.org/allowed.js$script\nКосметические фильтры и неподдерживаемые опции пропускаются и подсчитываются при сохранении. Несохранённые изменения удаляются при выходе.")
        self.saveButton.setTitle(self.text("Validate and Save", "Проверить и сохранить"), for: .normal)
        self.saveButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        self.saveButton.addTarget(self, action: #selector(self.save), for: .touchUpInside)
        self.saveButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        let stack = UIStackView(arrangedSubviews: [self.editor, self.status, self.saveButton])
        stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        self.displayNode.view.addSubview(self.container)
        self.container.addSubview(stack)
        self.container.keyboardDismissMode = .interactive
        self.editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.container.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.container.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.container.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.container.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: self.container.frameLayoutGuide.widthAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: self.container.frameLayoutGuide.heightAnchor)
        ])
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY + 8
        let bottom = layout.insets(options: [.input]).bottom + 8
        let side = layout.sideInsets(forBandFrom: top, to: layout.size.height - bottom)
        transition.updateFrame(view: self.container, frame: CGRect(x: side.left + 16, y: top, width: max(0, layout.size.width - side.left - side.right - 32), height: max(0, layout.size.height - top - bottom)))
    }

    @objc private func save() {
        let text = self.editor.text ?? ""
        self.saveButton.isEnabled = false
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try ExteraBrowserABPConverter.convert(text, limit: ExteraBrowserFilters.maximumCustomRules) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.saveButton.isEnabled = true
                do {
                    let conversion = try result.get()
                    guard ExteraBrowserFilters.shared.customRules == self.original else { throw ExteraBrowserFilterError.invalid("Custom filters changed in another editor. Reopen this screen before saving.") }
                    try ExteraBrowserFilters.shared.setCustomRules(text)
                    self.original = text
                    self.status.text = self.text("Saved. Converted: ", "Сохранено. Преобразовано: ") + "\(conversion.rules.count)\n" + self.text("Unsupported: ", "Не поддерживается: ") + "\(conversion.unsupportedRules)\n" + self.text("Cosmetic rules skipped: ", "Пропущено косметических: ") + "\(conversion.cosmeticRules)"
                    self.editor.resignFirstResponder()
                } catch {
                    let alert = UIAlertController(title: self.text("Filter Error", "Ошибка фильтров"), message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: self.text("OK", "ОК"), style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }
}
