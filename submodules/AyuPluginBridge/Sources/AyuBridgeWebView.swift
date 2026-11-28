import Foundation
import WebKit

/// `android.webkit.WebSettings` subset with Android's defaults.
struct AyuBridgeWebSettings: Equatable {
    var javaScriptEnabled = false
    var domStorageEnabled = false
    var userAgent: String?
}

/// `android.webkit.WebView` behaviour over `WKWebView`. Not yet published as a host class:
/// the bridge registry does not declare `android.webkit.*`, so preflight keeps the blockers.
@MainActor
final class AyuBridgeWebView: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private(set) var settings = AyuBridgeWebSettings()
    private(set) var destroyed = false
    /// `WebViewClient.onPageStarted` / `onPageFinished(view, url)`.
    var onPageStarted: ((String) -> Void)?
    var onPageFinished: ((String) -> Void)?
    /// `WebViewClient.shouldOverrideUrlLoading`: true cancels the navigation.
    var shouldOverrideUrlLoading: ((String) -> Bool)?
    private var hostLoads = 0
    /// Android shows the history URL (default `about:blank`), not the base URL, for a data load.
    private var dataLoad: (base: URL, history: String)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        self.webView.navigationDelegate = self
    }

    func setJavaScriptEnabled(_ enabled: Bool) { self.settings.javaScriptEnabled = enabled }
    /// WebKit has no switch for DOM storage: the value is kept, storage stays available.
    func setDomStorageEnabled(_ enabled: Bool) { self.settings.domStorageEnabled = enabled }
    func setUserAgentString(_ value: String?) {
        let agent = (value?.isEmpty ?? true) ? nil : value
        self.settings.userAgent = agent
        self.webView.customUserAgent = agent
    }

    func loadUrl(_ url: String) throws {
        guard !self.destroyed else { return }
        // Android runs a `javascript:` URL in the current page; that path is not served here.
        guard !url.lowercased().hasPrefix("javascript:") else { throw AyuBridgeFailure.unsupported("WebView.loadUrl javascript: scheme") }
        guard let target = URL(string: url) else { throw AyuBridgeFailure("invalid_arguments", "Invalid WebView URL") }
        self.hostLoads += 1
        self.dataLoad = nil
        self.webView.load(URLRequest(url: target))
    }

    func loadData(_ data: String, mimeType: String?, encoding: String?) {
        guard !self.destroyed else { return }
        let bytes = encoding?.lowercased() == "base64" ? (Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? Data()) : Data(data.utf8)
        self.load(bytes, mimeType: mimeType, encoding: "utf-8", baseURL: nil)
    }

    func loadDataWithBaseURL(_ baseURL: String?, data: String, mimeType: String?, encoding: String?, historyURL: String? = nil) {
        guard !self.destroyed else { return }
        let base = baseURL.flatMap { URL(string: $0) } ?? URL(string: "about:blank")!
        self.load(Data(data.utf8), mimeType: mimeType, encoding: "utf-8", baseURL: base)
        self.dataLoad = (base, (historyURL?.isEmpty ?? true) ? "about:blank" : historyURL!)
    }

    private func load(_ data: Data, mimeType: String?, encoding: String, baseURL: URL?) {
        self.hostLoads += 1
        self.dataLoad = nil
        self.webView.load(data, mimeType: mimeType ?? "text/html", characterEncodingName: encoding, baseURL: baseURL ?? URL(string: "about:blank")!)
    }

    func getUrl() -> String? {
        guard !self.destroyed else { return nil }
        if let dataLoad = self.dataLoad, self.webView.url == nil || self.webView.url == dataLoad.base { return dataLoad.history }
        return self.webView.url?.absoluteString
    }
    func stopLoading() { if !self.destroyed { self.webView.stopLoading() } }

    func destroy() {
        guard !self.destroyed else { return }
        self.destroyed = true
        self.webView.stopLoading()
        self.webView.navigationDelegate = nil
        self.webView.removeFromSuperview()
        self.onPageStarted = nil; self.onPageFinished = nil; self.shouldOverrideUrlLoading = nil
    }

    /// `ValueCallback.onReceiveValue` gets the JSON text of the result, `"null"` for undefined,
    /// for a script that throws and while JavaScript is disabled. Nothing is delivered after `destroy()`.
    func evaluateJavascript(_ script: String, callback: ((String) -> Void)?) {
        guard !self.destroyed else { return }
        guard self.settings.javaScriptEnabled else {
            if let callback { DispatchQueue.main.async { callback("null") } }
            return
        }
        self.webView.evaluateJavaScript(Self.wrappedScript(script)) { value, _ in
            callback?(Self.resultText(value))
        }
    }

    /// Indirect eval keeps Android's global scope and completion value; the JSON text is built in the page.
    static func wrappedScript(_ script: String) -> String {
        let literal = (try? JSONSerialization.data(withJSONObject: script, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return "(function(){var r=(0,eval)(" + literal + ");var t=JSON.stringify(r);return t===undefined?'null':t})()"
    }

    static func resultText(_ value: Any?) -> String {
        guard let text = value as? String, !text.isEmpty else { return "null" }
        return text
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = self.settings.javaScriptEnabled
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        // Android does not ask the client about a load the app itself started.
        if mainFrame, self.hostLoads > 0 {
            self.hostLoads -= 1
            decisionHandler(.allow, preferences)
            return
        }
        if mainFrame, let url = navigationAction.request.url?.absoluteString, self.shouldOverrideUrlLoading?(url) == true {
            decisionHandler(.cancel, preferences)
            return
        }
        decisionHandler(.allow, preferences)
    }

    /// Methods `invoke` serves for `android.webkit.WebView` and `invokeSettings` for `android.webkit.WebSettings`;
    /// the host's member tables must list exactly these.
    static let hostMethods: Set<String> = ["loadUrl", "loadData", "loadDataWithBaseURL", "getUrl", "stopLoading", "destroy", "evaluateJavascript"]
    static let settingsMethods: Set<String> = ["setJavaScriptEnabled", "getJavaScriptEnabled", "setDomStorageEnabled", "getDomStorageEnabled", "setUserAgentString"]

    private static func text(_ value: AyuBridgeValue, nullable: Bool, _ name: String) throws -> String? {
        if case .string(let text) = value { return text }
        if nullable, case .null = value { return nil }
        throw AyuBridgeFailure("invalid_arguments", name + " expects a string")
    }

    /// One entry point for the host's view-method dispatch. `callback` is the `ValueCallback` sink
    /// (nil for a null callback); it runs on the main thread.
    func invoke(_ method: String, _ args: [AyuBridgeValue], callback: ((String) -> Void)? = nil) throws -> AyuBridgeValue {
        func count(_ expected: Int) throws {
            guard args.count == expected else { throw AyuBridgeFailure("invalid_arguments", "WebView.\(method) takes \(expected) arguments") }
        }
        switch method {
        case "loadUrl":
            try count(1)
            try self.loadUrl(try Self.text(args[0], nullable: false, method)!)
        case "loadData":
            try count(3)
            self.loadData(try Self.text(args[0], nullable: false, method)!, mimeType: try Self.text(args[1], nullable: true, method), encoding: try Self.text(args[2], nullable: true, method))
        case "loadDataWithBaseURL":
            try count(5)
            self.loadDataWithBaseURL(try Self.text(args[0], nullable: true, method), data: try Self.text(args[1], nullable: false, method)!, mimeType: try Self.text(args[2], nullable: true, method), encoding: try Self.text(args[3], nullable: true, method), historyURL: try Self.text(args[4], nullable: true, method))
        case "getUrl":
            try count(0)
            return self.getUrl().map(AyuBridgeValue.string) ?? .null
        case "stopLoading":
            try count(0)
            self.stopLoading()
        case "destroy":
            try count(0)
            self.destroy()
        case "evaluateJavascript":
            try count(2)
            self.evaluateJavascript(try Self.text(args[0], nullable: false, method)!, callback: callback)
        default:
            throw AyuBridgeFailure.unsupported("android.webkit.WebView." + method)
        }
        return .null
    }

    func invokeSettings(_ method: String, _ args: [AyuBridgeValue]) throws -> AyuBridgeValue {
        func flag() throws -> Bool {
            guard args.count == 1, case .bool(let value) = args[0] else { throw AyuBridgeFailure("invalid_arguments", "WebSettings.\(method) expects a boolean") }
            return value
        }
        switch method {
        case "setJavaScriptEnabled": self.setJavaScriptEnabled(try flag())
        case "setDomStorageEnabled": self.setDomStorageEnabled(try flag())
        case "getJavaScriptEnabled", "getDomStorageEnabled":
            guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "WebSettings.\(method) takes no arguments") }
            return .bool(method == "getJavaScriptEnabled" ? self.settings.javaScriptEnabled : self.settings.domStorageEnabled)
        case "setUserAgentString":
            guard args.count == 1 else { throw AyuBridgeFailure("invalid_arguments", "WebSettings.setUserAgentString takes 1 argument") }
            self.setUserAgentString(try Self.text(args[0], nullable: true, method))
        default:
            throw AyuBridgeFailure.unsupported("android.webkit.WebSettings." + method)
        }
        return .null
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        self.onPageStarted?(webView.url?.absoluteString ?? "about:blank")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.onPageFinished?(webView.url?.absoluteString ?? "about:blank")
    }
}
