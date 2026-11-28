import Foundation
import UIKit

/// Native contract for Screenshot Privacy 1.4.2.
///
/// iOS has no public equivalent of Android's FLAG_SECURE: an application cannot
/// delete a screenshot that the system already saved, nor can it receive the
/// screenshot gesture before the frame is captured. This adapter therefore
/// implements the honest iOS mapping: a privacy shield that can be shown while
/// the screen is being captured/recorded, or toggled manually before a capture.
/// It never claims to block, sanitize or delete system screenshots.
@MainActor
final class AyuScreenshotPrivacyAdapter: AyuNativePluginAdapter {
    private(set) var isEnabled = false
    private var manualMode = false
    private var observations: [NSObjectProtocol] = []
    private weak var shield: UIView?
    private weak var presenter: UIViewController?
    private var shieldActionTarget: AyuShieldActionTarget?
    override var actionTitle: String? { self.isEnabled ? (self.manualMode ? "Выключить режим скриншота" : "Режим скриншота") : nil }

    init(defaults: UserDefaults, reportError: @escaping (String?) -> Void) {
        super.init(pluginID: "screenshot_privacy", defaults: defaults, reportError: reportError)
    }

    private var automatic: Bool { self.integerValue("capture_mode", default: 0) == 0 }

    override func enable() throws {
        self.isEnabled = true
        self.reportError(nil)
        AyuNativePluginRuntime.shared.screenshotPrivacy = self
        let center = NotificationCenter.default
        self.observations.append(center.addObserver(forName: UIApplication.userDidTakeScreenshotNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenshotTaken() }
        })
        self.observations.append(center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        self.observations.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.removeShield() }
        })
        self.refresh()
    }

    override func disable() {
        self.isEnabled = false
        self.manualMode = false
        for observation in self.observations { NotificationCenter.default.removeObserver(observation) }
        self.observations.removeAll()
        self.removeShield()
        if AyuNativePluginRuntime.shared.screenshotPrivacy === self {
            AyuNativePluginRuntime.shared.screenshotPrivacy = nil
        }
    }

    override func settings() throws -> [AyuPluginSetting] {
        var rows: [AyuPluginSetting] = [
            self.staticRow("Header", "Screenshot Privacy"),
            self.staticRow("Divider", self.automatic
                ? "Автоматически: щит появляется, пока iOS сообщает о записи экрана."
                : "Только вручную: обычные снимки не трогаются, щит включается кнопкой ниже."),
            self.staticRow("Header", "Режим работы"),
            self.selectorRow("capture_mode", "Когда замазывать", subtext: "Как в оригинале: автоматически или только вручную",
                             items: ["Автоматически", "Только вручную"], value: self.integerValue("capture_mode", default: 0)),
        ]
        rows.append(self.textRow(self.manualMode ? "Выключить режим скриншота" : "Режим скриншота",
                                 subtext: "Закрывает интерфейс щитом, пока вы не выключите", action: "screenshot_privacy.toggle"))
        rows.append(self.staticRow("Header", "Что скрывать"))
        rows.append(self.staticRow("Divider", "Оригинал замазывает имена, аватарки, время и шапку на самом снимке. iOS не даёт изменить уже сохранённый файл и не сообщает о снимке до кадра, поэтому здесь скрывается весь экран до снимка, а не отдельные элементы."))
        rows.append(self.staticRow("Divider", "Ограничение платформы: это не Android FLAG_SECURE. Приложение не может удалить системный скриншот или гарантировать, что он не попадёт в галерею."))
        return rows
    }

    override func set(_ row: AyuPluginSetting, value: AyuBridgeValue) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        guard let key = row.key else { throw AyuPluginService.Failure.operation("INVALID_SETTING") }
        guard key == "capture_mode", let index = value.integer, (0...1).contains(index) else {
            throw AyuPluginService.Failure.operation(key == "capture_mode" ? "INVALID_SETTING_INDEX" : "INVALID_SETTING")
        }
        try self.setValue(value, for: key)
        self.refresh()
    }

    override func activate(_ row: AyuPluginSetting, presenter: UIViewController?, completion: @escaping () -> Void) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        guard row.descriptor["native_action"].string == "screenshot_privacy.toggle" else { completion(); return }
        self.presenter = presenter
        self.manualMode.toggle()
        self.refresh()
        AyuNativePluginRuntime.shared.showMessage(self.manualMode ? "Режим скриншота включён" : "Режим скриншота выключен",
                                                  style: self.manualMode ? "success" : "simple")
        completion()
    }

    override func open(from presenter: UIViewController) {
        guard self.isEnabled else { return }
        self.presenter = presenter
        self.manualMode.toggle()
        self.refresh()
    }

    func refresh() {
        guard self.isEnabled else { self.removeShield(); return }
        let captureActive = self.automatic && UIScreen.screens.contains(where: { $0.isCaptured })
        if captureActive || self.manualMode { self.installShield() } else { self.removeShield() }
    }

    private func screenshotTaken() {
        guard self.isEnabled else { return }
        // The screenshot is already in Photos. Explain the platform limit once.
        AyuNativePluginRuntime.shared.showMessage("Скриншот уже сохранён системой. iOS не позволяет удалить его; включите режим скриншота заранее.", style: "error")
    }

    private func installShield() {
        guard self.shield == nil else { return }
        let presenter = self.presenter ?? AyuNativePluginRuntime.shared.presenter?()
        guard let presenter, let host = presenter.viewIfLoaded?.window ?? presenter.viewIfLoaded, host.window != nil else { return }
        let shield = UIView()
        shield.backgroundColor = .black
        shield.translatesAutoresizingMaskIntoConstraints = false
        shield.isUserInteractionEnabled = true
        let label = UILabel()
        label.text = "Содержимое скрыто\nРежим скриншота"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        shield.addSubview(label)
        if self.manualMode {
            let target = AyuShieldActionTarget { [weak self] in
                guard let self else { return }
                self.manualMode = false
                self.removeShield()
            }
            self.shieldActionTarget = target
            let button = UIButton(type: .system)
            button.setTitle("Показать содержимое", for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            button.addTarget(target, action: #selector(AyuShieldActionTarget.invoke), for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            shield.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 20),
                button.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
            ])
        }
        host.addSubview(shield)
        NSLayoutConstraint.activate([
            shield.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            shield.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            shield.topAnchor.constraint(equalTo: host.topAnchor),
            shield.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            label.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: shield.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: shield.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: shield.trailingAnchor, constant: -24),
        ])
        self.shield = shield
    }

    private func removeShield() {
        self.shield?.removeFromSuperview()
        self.shield = nil
        self.shieldActionTarget = nil
    }
}

@MainActor
private final class AyuShieldActionTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) {
        self.action = action
    }
    @objc func invoke() {
        self.action()
    }
}
