import AccountContext
import CoreLocation
import Display
import SGSimpleSettings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// Actual search-field consumer and settings preview share selection, order and boundary policy.
final class ExteraPillStackView: UIView, UIGestureRecognizerDelegate {
    private let context: AccountContext
    private let provider: ExteraPillBuiltinProvider
    private let content = UIView()
    private let storageRing = ExteraPillStorageRing()
    private var phoneDisposable: Disposable?
    private let label = UILabel()
    private let entryTimeIcon = UIImageView(image: UIImage(systemName: "eye.fill"))
    private var observers: [NSObjectProtocol] = []
    private var layout = ExteraPillStackLayout()
    private var specs: [ExteraPillSpec] = []
    private var ids: [String] = []
    private var selected: String?
    private var runningSignature: String?
    private var lease: UUID?
    private var refreshTimer: Timer?
    private var language = "en"
    var hostVisible = false { didSet {
        if self.hostVisible && !oldValue { exteraEntryStatusDialogsAppeared(account: self.context.account) }
        self.updateRunning()
    } }
    var inventoryChanged: (() -> Void)?
    var hasItems: Bool { !self.ids.isEmpty }

    init(context: AccountContext) {
        self.context = context; self.provider = ExteraPillBuiltinProvider(context: context)
        super.init(frame: .zero)
        self.clipsToBounds = true; self.layer.cornerRadius = 14
        self.label.font = .systemFont(ofSize: 13, weight: .semibold)
        self.label.textAlignment = .center; self.label.lineBreakMode = .byTruncatingTail
        self.addSubview(self.content); self.content.addSubview(self.label)
        self.entryTimeIcon.contentMode = .scaleAspectFit; self.entryTimeIcon.isHidden = true
        self.content.addSubview(self.entryTimeIcon)
        self.content.addSubview(self.storageRing); self.storageRing.isHidden = true
        self.provider.storageProgress = { [weak self] value in
            self?.storageRing.isHidden = value == nil
            if let value { self?.storageRing.setProgress(value) }
        }
        self.phoneDisposable = (context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)) |> deliverOnMainQueue).start(next: { [weak self] peer in
            if case let .user(user)? = peer {
                self?.provider.updatePhone(user.phone ?? "")
                self?.runningSignature = nil; self?.updateRunning()
            }
        })
        self.isAccessibilityElement = true; self.accessibilityTraits = [.button, .adjustable]
        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapped)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.panned(_:)))
        pan.delegate = self; self.addGestureRecognizer(pan)
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
        self.panDisplayLink?.invalidate()
        self.provider.stop(); self.phoneDisposable?.dispose()
        self.refreshTimer?.invalidate()
        if let lease = self.lease { ExteraPillRuntime.shared.release(lease) }
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        self.content.bounds = CGRect(origin: .zero, size: self.bounds.size)
        self.content.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        let entryTime = self.selected == ExteraBuiltinPill.entryTime.id
        self.entryTimeIcon.isHidden = !entryTime
        if entryTime || self.selected == ExteraBuiltinPill.storage.id {
            let width = min(max(0, self.bounds.width - 44), self.label.sizeThatFits(self.bounds.size).width)
            let spacing: CGFloat = width > 0 ? 4 : 0
            let left = floor((self.bounds.width - 20 - spacing - width) / 2)
            self.entryTimeIcon.frame = CGRect(x: left, y: floor((self.bounds.height - 20) / 2), width: 20, height: 20)
            self.storageRing.frame = CGRect(x: left + 2, y: floor((self.bounds.height - 16) / 2), width: 16, height: 16)
            self.label.frame = CGRect(x: left + 20 + spacing, y: 0, width: width, height: self.bounds.height)
        } else {
            self.label.frame = self.bounds.insetBy(dx: 8, dy: 0)
        }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); self.updateRunning() }
    func apply(theme: PresentationTheme, language: String) {
        let changed = self.language != language
        self.language = language; self.provider.language = language
        self.label.textColor = theme.list.itemPrimaryTextColor
        self.entryTimeIcon.tintColor = theme.list.itemPrimaryTextColor
        self.storageRing.tintColor = theme.list.itemPrimaryTextColor
        self.backgroundColor = theme.list.itemAccentColor.withAlphaComponent(0.10)
        self.accessibilityHint = self.text("Swipe up or down to change widget. Hold for options.", "Смахните вверх или вниз для смены виджета. Удерживайте для настроек.")
        if changed { self.runningSignature = nil; self.updateRunning() }
    }
    private func text(_ en: String, _ ru: String) -> String { exteraPillText(self.language, en, ru) }
    private func setText(_ text: String) {
        self.label.text = text
        if let selected = self.selected { self.rememberedText[selected] = text }
        self.accessibilityLabel = self.selected == ExteraBuiltinPill.entryTime.id ? ExteraBuiltinPill.entryTime.title(self.language) + (text.isEmpty ? "" : " · " + text) : text
        self.setNeedsLayout()
    }
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
        self.cancelPan()
        self.runningSignature = nil; self.provider.stop()
        self.refreshTimer?.invalidate(); self.refreshTimer = nil
        if let lease = self.lease { self.lease = nil; ExteraPillRuntime.shared.release(lease) }
    }
    private func updateRunning(force: Bool = false) {
        guard self.hostVisible, self.window != nil, !self.isHidden, UIApplication.shared.applicationState == .active, let selected = self.selected else { self.stop(); return }
        let store = ExteraPillStackSettings.shared
        let account = self.context.account.id.int64
        let custom = self.specs.first { ExteraPillStackLayout.customId($0.id) == selected }
        let signature = selected + ".\(store.allowsWeather(source: self.provider.weatherSource, account: account)).\(self.provider.weatherSource).\(store.allowed("rates", account: account)).\(custom.map { store.allowsCustom($0, account: account) } ?? false).\(ExteraBuiltinPill.from(id: selected).map { store.target($0, account: account) } ?? "").\(ExteraBuiltinPill.from(id: selected).map { self.provider.currency(for: $0) } ?? "").\(store.weather(account: account)).\(TimeZone.current.identifier).\(store.entryTimeAutoRefresh(account: account)).\(self.language).\(String(describing: custom))"
        guard force || self.runningSignature != signature else { self.updateCustomValue(); return }
        self.stop(); self.runningSignature = signature
        if let kind = ExteraBuiltinPill.from(id: selected) {
            self.provider.start(kind, force: force)
            if kind != .proxy && (kind != .entryTime || store.entryTimeAutoRefresh(account: account)) {
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
    private var panIncoming: UIView?
    private var panNext: String?
    private var panDistance: CGFloat = 0
    private var panDisplayLink: CADisplayLink?
    private var panStart: CFTimeInterval = 0
    private var panFrom: CGFloat = 0
    private var panTo: CGFloat = 0
    private var panDuration: Double = 0
    private var panCommit = false
    private var rememberedText: [String: String] = [:]

    private func cancelPan() {
        self.panDisplayLink?.invalidate(); self.panDisplayLink = nil
        self.panIncoming?.removeFromSuperview(); self.panIncoming = nil
        self.panNext = nil; self.panDistance = 0
        self.content.transform = .identity; self.content.alpha = 1
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard self.ids.count > 1 else { return }
        switch gesture.state {
        case .began:
            self.panDisplayLink?.invalidate(); self.panDisplayLink = nil
            gesture.setTranslation(CGPoint(x: 0, y: self.panDistance), in: self)
        case .changed:
            self.drawPan(gesture.translation(in: self).y)
        case .ended, .cancelled, .failed:
            let distance = self.panDistance
            let commit = gesture.state == .ended && ExteraPillGestureFrame.commits(distance: Double(distance), height: Double(self.bounds.height), hasNeighbor: self.panNext != nil)
            if UIAccessibility.isReduceMotionEnabled {
                let next = commit ? self.panNext : nil
                self.cancelPan(); if let next { self.selectAfterPan(next) }; return
            }
            self.panCommit = commit
            self.panFrom = distance
            self.panTo = commit ? (distance < 0 ? -self.bounds.height : self.bounds.height) : 0
            self.panDuration = commit ? 0.25 : 0.20
            self.panStart = CACurrentMediaTime()
            let proxy = ExteraPillWeakDisplayLink(target: self, selector: #selector(self.advancePan))
            let link = CADisplayLink(target: proxy, selector: #selector(ExteraPillWeakDisplayLink.tick(_:)))
            self.panDisplayLink = link; link.add(to: .main, forMode: .common)
        default: break
        }
    }
    private func drawPan(_ distance: CGFloat) {
        let next = self.layout.next(from: self.selected, direction: distance < 0 ? 1 : -1, ids: self.ids)
        let candidate = next == self.selected ? nil : next
        if candidate != self.panNext {
            self.panIncoming?.removeFromSuperview(); self.panIncoming = nil
            self.panNext = candidate
            if let candidate {
                // Render remembered content only. Neighbor preview owns no provider/lease.
                let preview = UIView(frame: self.bounds)
                let label = UILabel(frame: self.bounds.insetBy(dx: 8, dy: 0))
                label.font = self.label.font; label.textColor = self.label.textColor
                label.textAlignment = .center; label.lineBreakMode = .byTruncatingTail
                label.text = self.rememberedText[candidate] ?? ExteraBuiltinPill.from(id: candidate)?.title(self.language) ?? self.specs.first(where: { ExteraPillStackLayout.customId($0.id) == candidate })?.label
                if candidate == ExteraBuiltinPill.entryTime.id {
                    let eye = UIImageView(image: UIImage(systemName: "eye.fill")); eye.tintColor = self.entryTimeIcon.tintColor; eye.contentMode = .scaleAspectFit
                    eye.frame = CGRect(x: floor((self.bounds.width - 20) / 2), y: floor((self.bounds.height - 20) / 2), width: 20, height: 20)
                    // Manual Entry Time always re-enters collapsed.
                    label.text = ""; preview.addSubview(eye)
                }
                preview.addSubview(label); self.addSubview(preview); self.panIncoming = preview
            }
        }
        self.panDistance = distance
        let frame = ExteraPillGestureFrame.frame(distance: Double(distance), height: Double(self.bounds.height), hasNeighbor: candidate != nil)
        self.content.transform = CGAffineTransform(translationX: 0, y: CGFloat(frame.outgoingY)).scaledBy(x: CGFloat(frame.outgoingScale), y: CGFloat(frame.outgoingScale))
        self.content.alpha = CGFloat(frame.outgoingAlpha)
        self.panIncoming?.transform = CGAffineTransform(translationX: 0, y: CGFloat(frame.incomingY)).scaledBy(x: CGFloat(frame.incomingScale), y: CGFloat(frame.incomingScale))
        self.panIncoming?.alpha = CGFloat(frame.incomingAlpha)
    }
    @objc private func advancePan() {
        let time = min(1, max(0, (CACurrentMediaTime() - self.panStart) / self.panDuration))
        let progress: Double
        if self.panCommit {
            // Invert cubic x(t) by bisection, then evaluate y(t).
            var low = 0.0, high = 1.0
            for _ in 0 ..< 18 {
                let t = (low + high) / 2
                let x = 3 * (1 - t) * (1 - t) * t * 0.23 + 3 * (1 - t) * t * t * 0.32 + t * t * t
                if x < time { low = t } else { high = t }
            }
            let t = (low + high) / 2
            progress = 1 - pow(1 - t, 3)
        } else {
            // Android ValueAnimator default AccelerateDecelerateInterpolator.
            progress = (cos((time + 1) * .pi) / 2) + 0.5
        }
        self.drawPan(self.panFrom + (self.panTo - self.panFrom) * CGFloat(progress))
        if time >= 1 {
            let next = self.panCommit ? self.panNext : nil
            self.cancelPan()
            if let next { self.selectAfterPan(next) }
        }
    }
    private func selectAfterPan(_ next: String) {
        self.stop(); self.selected = next; self.accessibilityValue = nil
        ExteraPillStackSettings.shared.update(custom: self.specs) { $0.selected = next }
        self.updateRunning(); self.setNeedsLayout()
    }

    private func step(_ direction: Int) {
        guard let next = self.layout.next(from: self.selected, direction: direction, ids: self.ids), next != self.selected else { return }
        let outgoing = UIAccessibility.isReduceMotionEnabled ? nil : self.content.snapshotView(afterScreenUpdates: false)
        if let outgoing { outgoing.frame = self.bounds; self.addSubview(outgoing) }
        self.stop(); self.selected = next
        self.accessibilityValue = nil
        ExteraPillStackSettings.shared.update(custom: self.specs) { $0.selected = next }
        self.updateRunning()
        self.setNeedsLayout(); self.layoutIfNeeded()
        if let outgoing {
            self.content.transform = CGAffineTransform(translationX: 0, y: direction > 0 ? self.bounds.height : -self.bounds.height)
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                outgoing.transform = CGAffineTransform(translationX: 0, y: direction > 0 ? -self.bounds.height : self.bounds.height)
                self.content.transform = .identity
            }, completion: { _ in outgoing.removeFromSuperview() })
        }
    }
    override func accessibilityIncrement() { self.step(1) }
    override func accessibilityDecrement() { self.step(-1) }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return self.ids.count > 1 && abs(velocity.y) > abs(velocity.x)
    }
    @objc private func tapped() {
        if self.selected == ExteraBuiltinPill.entryTime.id {
            guard self.hostVisible, self.window != nil, UIApplication.shared.applicationState == .active else { return }
            self.provider.entryTimeTapped()
        } else { self.openOptions() }
    }
    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) { if gesture.state == .began { self.openOptions(longPress: true) } }
    private var controller: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder { if let controller = current as? UIViewController { return controller }; responder = current.next }
        return nil
    }
    private func openOptions(longPress: Bool = false) {
        guard let selected = self.selected, let controller = self.controller else { return }
        let kind = ExteraBuiltinPill.from(id: selected)
        if kind == .entryTime { self.openEntryTimeOptions(controller: controller); return }
        if longPress, kind == .proxy || kind == .storage {
            let sheet = UIAlertController(title: kind?.title(self.language), message: nil, preferredStyle: .actionSheet)
            if kind == .storage {
                sheet.addAction(UIAlertAction(title: self.text("Storage Usage", "Использование памяти"), style: .default) { [weak self] _ in
                    guard let self else { return }; self.context.sharedContext.openStorageUsage(context: self.context)
                })
                sheet.addAction(UIAlertAction(title: self.text("Refresh", "Обновить"), style: .default) { [weak self] _ in self?.updateRunning(force: true) })
            }
            sheet.addAction(UIAlertAction(title: self.text("Settings", "Настройки"), style: .default) { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                (controller.navigationController as? NavigationController)?.pushViewController(exteraPillDashboardController(context: self.context))
            })
            sheet.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
            sheet.popoverPresentationController?.sourceView = self; sheet.popoverPresentationController?.sourceRect = self.bounds
            controller.present(sheet, animated: true); return
        }
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
        if kind == .weather {
            let source = self.provider.weatherSource
            let mode = store.weather(account: account)
            let location = mode.current ? self.text("current location", "текущая геопозиция") : self.text("selected map coordinates", "выбранные координаты на карте")
            message = self.text("Uses Telegram weather bot @\(source). Sends \(location) for this account while selected. You can revoke access below.", "Использует погодного бота Telegram @\(source). Передаёт \(location) от этого аккаунта, пока выбран виджет. Разрешение можно отозвать ниже.")

        } else if kind != nil {
            message = self.text("Exchange rate, not a wallet balance. Requests api.coinbase.com without account data. GRAM means TON. Target: ", "Обменный курс. Запрос к api.coinbase.com без данных аккаунта. GRAM означает TON. Валюта: ") + (kind.map { store.target($0, account: account) } ?? "AUTO")
        } else {
            let spec = self.specs.first { ExteraPillStackLayout.customId($0.id) == selected }
            let host = spec.flatMap { URLComponents(string: $0.url)?.host } ?? "HTTP"
            message = self.text("Allow requests to \(host) while this custom widget is selected in search? The configured URL and query parameters are sent to its endpoint. Other hidden endpoints will not be requested by this stack.", "Разрешить запросы к \(host), пока эта HTTP-плашка выбрана в поиске? Сервер получит настроенный URL и его параметры. Скрытые источники этим stack не запрашиваются.")
        }
        let sheet = UIAlertController(title: kind?.title(self.language) ?? "HTTP", message: message, preferredStyle: .actionSheet)
        do {
            sheet.addAction(UIAlertAction(title: allowed ? self.text("Refresh", "Обновить") : self.text("Allow Requests", "Разрешить запросы"), style: .default, handler: { [weak self] _ in
                guard let self, self.hostVisible, self.selected == selected else { return }
                if kind == .weather, store.weather(account: account).current, self.provider.locationAuthorizationStatus == .notDetermined {
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
                sheet.addAction(UIAlertAction(title: self.text("Weather Settings", "Настройки погоды"), style: .default, handler: { [weak self, weak controller] _ in
                    guard let self, let controller else { return }
                    controller.present(ExteraPillWeatherSettingsController(account: account, language: self.language), animated: true)
                }))
            }
            if let kind, [.gram, .btc, .usd].contains(kind) {
                sheet.addAction(UIAlertAction(title: self.text("Target Currency", "Валюта курса"), style: .default, handler: { [weak self, weak controller] _ in
                    guard let self, let controller else { return }
                    let sheet = UIAlertController(title: self.text("Target Currency", "Валюта курса"), message: nil, preferredStyle: .actionSheet)
                    for code in ExteraPillCurrency.targets(for: kind) {
                        sheet.addAction(UIAlertAction(title: code + (store.target(kind, account: account) == code ? " ✓" : ""), style: .default) { _ in store.setTarget(code, kind: kind, account: account) })
                    }
                    sheet.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
                    sheet.popoverPresentationController?.sourceView = self; sheet.popoverPresentationController?.sourceRect = self.bounds
                    controller.present(sheet, animated: true)
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
    private func openEntryTimeOptions(controller: UIViewController) {
        let store = ExteraPillStackSettings.shared, account = self.context.account.id.int64
        let enabled = store.entryTimeAutoRefresh(account: account)
        let sheet = UIAlertController(title: ExteraBuiltinPill.entryTime.title(self.language), message: self.text("Shows this account's server-reported online or last seen status. Tap to check; with Auto-Refresh off, the result is shown for 3 seconds.", "Показывает статус и время последнего присутствия этого аккаунта с сервера Telegram. Нажмите для проверки; без автообновления результат виден 3 секунды."), preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: self.text("Auto-Refresh", "Автообновление") + " · " + (enabled ? self.text("On", "Вкл.") : self.text("Off", "Выкл.")), style: .default) { _ in
            store.setEntryTimeAutoRefresh(!enabled, account: account)
        })
        sheet.addAction(UIAlertAction(title: self.text("Refresh", "Обновить"), style: .default) { [weak self] _ in
            guard let self, self.hostVisible, self.selected == ExteraBuiltinPill.entryTime.id else { return }
            self.provider.entryTimeTapped()
        })
        sheet.addAction(UIAlertAction(title: self.text("Settings", "Настройки"), style: .default) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            (controller.navigationController as? NavigationController)?.pushViewController(exteraPillDashboardController(context: self.context))
        })
        sheet.addAction(UIAlertAction(title: self.text("Cancel", "Отмена"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = self; sheet.popoverPresentationController?.sourceRect = self.bounds
        controller.present(sheet, animated: true)
    }
}
