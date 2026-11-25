import AccountContext
import CoreLocation
import Display
import SGSimpleSettings
import TelegramPresentationData
import UIKit

/// Actual search-field consumer and settings preview share selection, order and boundary policy.
final class ExteraPillStackView: UIView {
    private let context: AccountContext
    private let provider: ExteraPillBuiltinProvider
    private let label = UILabel()
    private var observers: [NSObjectProtocol] = []
    private var layout = ExteraPillStackLayout()
    private var specs: [ExteraPillSpec] = []
    private var ids: [String] = []
    private var selected: String?
    private var runningSignature: String?
    private var lease: UUID?
    private var refreshTimer: Timer?
    private var language = "en"
    var hostVisible = false { didSet { self.updateRunning() } }
    var inventoryChanged: (() -> Void)?
    var hasItems: Bool { !self.ids.isEmpty }

    init(context: AccountContext) {
        self.context = context; self.provider = ExteraPillBuiltinProvider(context: context)
        super.init(frame: .zero)
        self.clipsToBounds = true; self.layer.cornerRadius = 14
        self.label.font = .systemFont(ofSize: 13, weight: .semibold)
        self.label.textAlignment = .center; self.label.lineBreakMode = .byTruncatingTail
        self.addSubview(self.label)
        self.isAccessibilityElement = true; self.accessibilityTraits = [.button, .adjustable]
        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapped)))
        let up = UISwipeGestureRecognizer(target: self, action: #selector(self.swiped(_:))); up.direction = .up; self.addGestureRecognizer(up)
        let down = UISwipeGestureRecognizer(target: self, action: #selector(self.swiped(_:))); down.direction = .down; self.addGestureRecognizer(down)
        self.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:))))
        self.provider.changed = { [weak self] text in self?.setText(text) }
        for name in [ExteraPillStackSettings.didChange, ExteraPillSettings.didChange] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Settings notifications can arrive within UIKit reorder transactions.
                self?.stop()
                DispatchQueue.main.async { self?.reload() }
            })
        }
        self.observers.append(NotificationCenter.default.addObserver(forName: ExteraPillRuntime.didChange, object: nil, queue: .main) { [weak self] _ in self?.updateCustomValue() })
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateRunning() })
        }
        self.reload()
    }
    required init?(coder: NSCoder) { preconditionFailure() }
    deinit {
        self.provider.stop()
        self.refreshTimer?.invalidate()
        if let lease = self.lease { ExteraPillRuntime.shared.release(lease) }
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }
    override func layoutSubviews() { super.layoutSubviews(); self.label.frame = self.bounds.insetBy(dx: 8, dy: 0) }
    override func didMoveToWindow() { super.didMoveToWindow(); self.updateRunning() }
    func apply(theme: PresentationTheme, language: String) {
        let changed = self.language != language
        self.language = language; self.provider.language = language
        self.label.textColor = theme.list.itemPrimaryTextColor
        self.backgroundColor = theme.list.itemAccentColor.withAlphaComponent(0.10)
        self.accessibilityHint = self.text("Swipe up or down to change widget. Hold for options.", "Смахните вверх или вниз для смены виджета. Удерживайте для настроек.")
        if changed { self.runningSignature = nil; self.updateRunning() }
    }
    private func text(_ en: String, _ ru: String) -> String { exteraPillText(self.language, en, ru) }
    private func setText(_ text: String) { self.label.text = text; self.accessibilityLabel = text }
    private func reload() {
        let previous = self.ids
        self.specs = ExteraPillSettings.shared.pills
        self.layout = ExteraPillStackSettings.shared.layout.normalized(custom: self.specs)
        self.ids = self.layout.renderedIds(custom: self.specs)
        self.selected = self.layout.selected.flatMap { self.ids.contains($0) ? $0 : nil } ?? self.ids.first
        // Header visibility belongs to its parent, including search/collapse constraints.
        self.updateRunning()
        if previous != self.ids { self.inventoryChanged?() }
    }
    private func stop() {
        self.runningSignature = nil; self.provider.stop()
        self.refreshTimer?.invalidate(); self.refreshTimer = nil
        if let lease = self.lease { self.lease = nil; ExteraPillRuntime.shared.release(lease) }
    }
    private func updateRunning(force: Bool = false) {
        guard self.hostVisible, self.window != nil, !self.isHidden, UIApplication.shared.applicationState == .active, let selected = self.selected else { self.stop(); return }
        let store = ExteraPillStackSettings.shared
        let account = self.context.account.id.int64
        let custom = self.specs.first { ExteraPillStackLayout.customId($0.id) == selected }
        let signature = selected + ".\(store.allowsWeather(source: self.provider.weatherSource, account: account)).\(self.provider.weatherSource).\(store.allowed("rates", account: account)).\(custom.map { store.allowsCustom($0, account: account) } ?? false).\(store.currency(account: account)).\(self.language).\(String(describing: custom))"
        guard force || self.runningSignature != signature else { self.updateCustomValue(); return }
        self.stop(); self.runningSignature = signature
        if let kind = ExteraBuiltinPill.from(id: selected) {
            self.provider.start(kind, force: force)
            if kind != .proxy && kind != .entryTime {
                self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                    guard let self, self.hostVisible, UIApplication.shared.applicationState == .active else { return }
                    self.provider.start(kind)
                }
            }
        }
        else if let spec = self.specs.first(where: { ExteraPillStackLayout.customId($0.id) == selected }) {
            if store.allowsCustom(spec, account: account) { self.lease = ExteraPillRuntime.shared.acquire(ids: [spec.id]) }
            self.updateCustomValue()
        }
    }
    private func updateCustomValue() {
        guard let selected = self.selected, let spec = self.specs.first(where: { ExteraPillStackLayout.customId($0.id) == selected }) else { return }
        guard ExteraPillStackSettings.shared.allowsCustom(spec, account: self.context.account.id.int64) else { self.setText(spec.label + self.text(" · Tap to allow", " · Разрешить")); return }
        let value = ExteraPillRuntime.shared.value(for: spec.id)
        let status = value.text ?? (value.isRefreshing ? "…" : self.text("Unavailable", "Недоступно"))
        self.setText(spec.label + " " + status)
        self.accessibilityValue = value.error.map { exteraPillErrorDescription($0, languageCode: self.language) }
    }
    private func step(_ direction: Int) {
        guard let next = self.layout.next(from: self.selected, direction: direction, ids: self.ids), next != self.selected else { return }
        let outgoing = UIAccessibility.isReduceMotionEnabled ? nil : self.label.snapshotView(afterScreenUpdates: false)
        if let outgoing { outgoing.frame = self.label.frame; self.addSubview(outgoing) }
        self.stop(); self.selected = next
        self.accessibilityValue = nil
        ExteraPillStackSettings.shared.update(custom: self.specs) { $0.selected = next }
        self.updateRunning()
        if let outgoing {
            self.label.transform = CGAffineTransform(translationX: 0, y: direction > 0 ? self.bounds.height : -self.bounds.height)
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                outgoing.transform = CGAffineTransform(translationX: 0, y: direction > 0 ? -self.bounds.height : self.bounds.height)
                self.label.transform = .identity
            }, completion: { _ in outgoing.removeFromSuperview() })
        }
    }
    override func accessibilityIncrement() { self.step(1) }
    override func accessibilityDecrement() { self.step(-1) }
    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) { self.step(gesture.direction == .up ? 1 : -1) }
    @objc private func tapped() { self.openOptions() }
    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began { self.openOptions() } }
    private var controller: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder { if let controller = current as? UIViewController { return controller }; responder = current.next }
        return nil
    }
    private func openOptions() {
        guard let selected = self.selected, let controller = self.controller else { return }
        let kind = ExteraBuiltinPill.from(id: selected)
        if kind == .proxy {
            (controller.navigationController as? NavigationController)?.pushViewController(self.context.sharedContext.makeProxySettingsController(context: self.context)); return
        }
        if kind == .storage { self.context.sharedContext.openStorageUsage(context: self.context); return }
        let store = ExteraPillStackSettings.shared, account = self.context.account.id.int64
        let grant = kind == .weather ? "weather" : (kind == nil ? selected : "rates")
        let weatherSource = self.provider.weatherSource
        let customSpec = self.specs.first { ExteraPillStackLayout.customId($0.id) == selected }
        let allowed = kind == .weather ? store.allowsWeather(source: weatherSource, account: account) : (customSpec.map { store.allowsCustom($0, account: account) } ?? store.allowed(grant, account: account))
        let message: String
        if kind == .entryTime {
            message = self.text("Unavailable in this version: this widget has no supported data provider.", "Недоступно в этой версии: для этого виджета нет поддерживаемого источника данных.")
        } else if kind == .weather {
            let source = self.provider.weatherSource
            message = self.text("Uses Telegram weather bot @\(source). Your authorized current location is sent to that bot for this account while this widget is selected. You can revoke access below.", "Использует погодного бота Telegram @\(source). Разрешённая текущая геопозиция отправляется боту от этого аккаунта, пока выбран виджет. Разрешение можно отозвать ниже.")
        } else if kind != nil {
            message = self.text("Exchange rate, not a wallet balance. Requests api.coinbase.com without account data. GRAM means TON. Target: ", "Обменный курс. Запрос к api.coinbase.com без данных аккаунта. GRAM означает TON. Валюта: ") + store.currency(account: account)
        } else {
            let spec = self.specs.first { ExteraPillStackLayout.customId($0.id) == selected }
            let host = spec.flatMap { URLComponents(string: $0.url)?.host } ?? "HTTP"
            message = self.text("Allow requests to \(host) while this custom widget is selected in search? The configured URL and query parameters are sent to its endpoint. Other hidden endpoints will not be requested by this stack.", "Разрешить запросы к \(host), пока эта HTTP-плашка выбрана в поиске? Сервер получит настроенный URL и его параметры. Скрытые источники этим stack не запрашиваются.")
        }
        let sheet = UIAlertController(title: kind?.title(self.language) ?? "HTTP", message: message, preferredStyle: .actionSheet)
        if kind != .entryTime {
            sheet.addAction(UIAlertAction(title: allowed ? self.text("Refresh", "Обновить") : self.text("Allow Requests", "Разрешить запросы"), style: .default, handler: { [weak self] _ in
                guard let self, self.hostVisible, self.selected == selected else { return }
                if kind == .weather, self.provider.locationAuthorizationStatus == .notDetermined {
                    self.refreshTimer?.invalidate(); self.refreshTimer = nil
                    self.provider.requestLocationAuthorization { [weak self] in
                        guard let self, self.hostVisible, self.selected == selected else { return }
                        store.allowWeather(source: weatherSource, account: account, value: true)
                        self.runningSignature = nil; self.updateRunning()
                    }
                } else {
                    if !allowed {
                        if let spec = customSpec { store.allowCustom(spec, account: account, value: true) }
                        else if kind == .weather { store.allowWeather(source: weatherSource, account: account, value: true) }
                        else { store.allow(grant, account: account, value: true) }
                    }
                    self.updateRunning(force: true)
                    if kind == nil, let spec = customSpec { ExteraPillRuntime.shared.refresh(spec.id) }
                }
            }))
            if kind == .weather {
                sheet.addAction(UIAlertAction(title: self.text("Location Settings", "Настройки геопозиции"), style: .default, handler: { _ in
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }))
            }
            if let kind, [.gram, .btc, .usd].contains(kind) {
                sheet.addAction(UIAlertAction(title: self.text("Target Currency", "Валюта курса"), style: .default, handler: { [weak self, weak controller] _ in
                    guard let self, let controller else { return }
                    let alert = UIAlertController(title: self.text("ISO Currency Code", "Код валюты ISO"), message: self.text("For example EUR, USD or RUB. Unsupported pairs show Rate unavailable.", "Например EUR, USD или RUB. Для неподдерживаемой пары выводится «Курс недоступен»."), preferredStyle: .alert)
                    alert.addTextField { $0.text = store.currency(account: account); $0.autocapitalizationType = .allCharacters }
                    alert.addAction(UIAlertAction(title: self.text("Save", "Сохранить"), style: .default) { _ in store.setCurrency((alert.textFields?.first?.text ?? "").uppercased(), account: account) })
                    alert.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel)); controller.present(alert, animated: true)
                }))
            }
            if allowed { sheet.addAction(UIAlertAction(title: self.text("Revoke Requests", "Отозвать разрешение"), style: .destructive) { _ in
                if let spec = customSpec { store.allowCustom(spec, account: account, value: false) }
                else if kind == .weather { store.allowWeather(source: weatherSource, account: account, value: false) }
                else { store.allow(grant, account: account, value: false) }
            }) }
        }
        sheet.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = self; sheet.popoverPresentationController?.sourceRect = self.bounds
        controller.present(sheet, animated: true)
    }
}
