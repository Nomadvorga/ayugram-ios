import Foundation
import UIKit
import WebKit

/// Native contract for SandBox 1.0.0.
///
/// The Android plugin draws its game with `GAME_HTML`, a self-contained
/// canvas/JavaScript document embedded in the plugin source. Android loads
/// those exact bytes into a WebView. The iOS route does the same: the pinned
/// `.plugin` source is already verified by SHA-256 before this adapter exists,
/// the `GAME_HTML` string literal is extracted from those verified bytes, and
/// it is rendered in a full-screen `WKWebView` with the same base URL and
/// polling contract. No game logic is reimplemented here.
@MainActor
final class AyuSandBoxAdapter: AyuNativePluginAdapter {
    private(set) var isEnabled = false
    var commandEnabled: Bool { self.isEnabled && self.boolValue("enabled", default: true) }
    override var actionTitle: String? { self.isEnabled ? "Открыть песочницу" : nil }

    // Audited source constants: GRID_WIDTHS[1] = 150, SPEED_STEPS[0] = ×1.
    static let defaultGridWidth = 150
    static let defaultSpeed = 1

    init(defaults: UserDefaults, reportError: @escaping (String?) -> Void) {
        super.init(pluginID: "sand_box", defaults: defaults, reportError: reportError)
    }

    override func enable() throws {
        self.isEnabled = true
        self.reportError(nil)
        AyuNativePluginRuntime.shared.sandBox = self
    }

    override func disable() {
        self.isEnabled = false
        if AyuNativePluginRuntime.shared.sandBox === self { AyuNativePluginRuntime.shared.sandBox = nil }
    }

    override func settings() throws -> [AyuPluginSetting] {
        return [
            self.staticRow("Header", "SandBox"),
            self.textRow("Открыть песочницу", subtext: "Полноэкранная игра из оригинального GAME_HTML плагина", action: "sand_box.open"),
            self.staticRow("Divider", "Команда .sand в поле ввода открывает игру вместо отправки сообщения."),
            self.staticRow("Divider", "Палитра, пауза, скорость, демо-сцена и сохранение сцены — родные элементы плагина внутри игры."),
        ]
    }

    override func set(_ row: AyuPluginSetting, value: AyuBridgeValue) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        throw AyuPluginService.Failure.operation("INVALID_SETTING")
    }

    override func activate(_ row: AyuPluginSetting, presenter: UIViewController?, completion: @escaping () -> Void) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        if row.descriptor["native_action"].string == "sand_box.open" {
            guard let presenter else { throw AyuPluginService.Failure.inactive }
            self.open(from: presenter)
        }
        completion()
    }

    override func open(from presenter: UIViewController) {
        guard self.isEnabled else { return }
        guard let source = self.verifiedSource, let html = Self.gameHTML(from: source) else {
            // Fail loudly instead of showing an empty game surface.
            self.reportError("SandBox: проверенный исходник не содержит GAME_HTML. Игра не открыта.")
            let alert = UIAlertController(
                title: "SandBox",
                message: "Не удалось прочитать GAME_HTML из проверенного исходника плагина. Переустановите SandBox 1.0.0 без изменений файла.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            presenter.present(alert, animated: true)
            return
        }
        let controller = AyuSandBoxWebViewController(html: html)
        controller.modalPresentationStyle = .fullScreen
        controller.modalPresentationCapturesStatusBarAppearance = true
        presenter.present(controller, animated: true)
    }

    /// Extracts the audited triple-quoted `GAME_HTML` literal from the pinned
    /// plugin source and applies the same two substitutions Android performs.
    /// The literal has no escapes or nested triple quotes; anything else is
    /// refused so a modified plugin can never inject host code.
    static func gameHTML(from source: String) -> String? {
        let marker = "GAME_HTML = \"\"\""
        guard let opening = source.range(of: marker) else { return nil }
        guard source.range(of: marker, range: opening.upperBound..<source.endIndex) == nil else { return nil }
        guard let closing = source.range(of: "\"\"\"", range: opening.upperBound..<source.endIndex) else { return nil }
        let literal = String(source[opening.upperBound..<closing.lowerBound])
        guard literal.hasPrefix("<!DOCTYPE html>"), literal.hasSuffix("</html>"),
              !literal.contains("\\"), !literal.contains("\"\"\"") else { return nil }
        return literal
            .replacingOccurrences(of: "__GW__", with: String(Self.defaultGridWidth))
            .replacingOccurrences(of: "__SP__", with: String(Self.defaultSpeed))
    }
}

/// Full-screen host for the original game document. Mirrors the Android build:
/// JavaScript and DOM storage on, `https://localhost/` base URL, dark frame,
/// `window.__ev` polled every 300 ms, `sand://close` dismisses the screen.
@MainActor
final class AyuSandBoxWebViewController: UIViewController {
    private static let background = UIColor(red: 16.0 / 255.0, green: 16.0 / 255.0, blue: 20.0 / 255.0, alpha: 1.0)
    private static let pollScript = "window.__ev && window.__ev.length ? JSON.stringify(window.__ev.splice(0)) : '[]'"

    private let html: String
    private var webView: WKWebView?
    private var pollTimer: Timer?
    private var closed = false

    init(html: String) {
        self.html = html
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = Self.background

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.suppressesIncrementalRendering = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = Self.background
        webView.scrollView.backgroundColor = Self.background
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: self.view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
        ])
        self.webView = webView
        webView.loadHTMLString(self.html, baseURL: URL(string: "https://localhost/"))
        self.startPolling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.verifyLoaded()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        self.stopPolling()
        self.webView?.stopLoading()
    }

    private func startPolling() {
        let timer = Timer(timeInterval: 0.3, target: self, selector: #selector(self.pollTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.pollTimer = timer
    }

    private func stopPolling() {
        self.pollTimer?.invalidate()
        self.pollTimer = nil
    }

    @objc private func pollTick() {
        guard !self.closed, let webView = self.webView else { return }
        webView.evaluateJavaScript(Self.pollScript) { [weak self] result, _ in
            guard let text = result as? String else { return }
            Task { @MainActor in self?.handle(events: text) }
        }
    }

    private func handle(events text: String) {
        guard !self.closed, text != "null", text != "[]" else { return }
        guard let data = text.data(using: .utf8),
              let events = try? JSONDecoder().decode([String].self, from: data) else { return }
        if events.contains(where: { $0.hasPrefix("sand://close") }) {
            self.close()
        }
    }

    /// The document exposes a canvas and the event queue once its script ran.
    /// Without them the screen must not pretend the game started.
    private func verifyLoaded() {
        guard !self.closed, let webView = self.webView else { return }
        webView.evaluateJavaScript("document.getElementById('cv') !== null && window.__ev !== undefined") { [weak self] result, _ in
            let loaded: Bool
            if let value = result as? Bool {
                loaded = value
            } else if let value = result as? NSNumber {
                loaded = value.boolValue
            } else {
                loaded = false
            }
            guard !loaded else { return }
            Task { @MainActor in self?.showFailure() }
        }
    }

    private func showFailure() {
        guard !self.closed, self.presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "SandBox",
            message: "Игра не загрузилась. Проверьте, что исходник плагина не изменён, и попробуйте снова.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Закрыть", style: .default, handler: { [weak self] _ in
            Task { @MainActor in self?.close() }
        }))
        self.present(alert, animated: true)
    }

    private func close() {
        guard !self.closed else { return }
        self.closed = true
        self.stopPolling()
        self.webView?.stopLoading()
        self.dismiss(animated: true)
    }
}
