import Foundation
import SGSimpleSettings
@preconcurrency import WebKit

/// Bundled rules plus the supported network subset of HTTPS ABP subscriptions.
/// All methods and WebKit callbacks are serialized on the main queue.
final class BrowserAdBlocker {
    private static var cachedSource: String?
    private static var cachedList: WKContentRuleList?
    private static var pending: [String: [(WKContentRuleList?) -> Void]] = [:]
    private static var sourceExceptions: [String]?
    private static var sourceCache: String?
    private static var sourceRevision: UInt64?
    private static var failedSource: String?
    private static var recentIdentifiers: [String] = []
    private static var observedRevision: UInt64?

    private final class ControllerState {
        var installedList: WKContentRuleList?
        var installedSource: String?
        var requestedSource: String?
        var installedRevision: UInt64?
    }
    // Popups can share their parent's user-content controller. Track the actual
    // installation on that shared controller so either view can disable it.
    private static let controllerStates = NSMapTable<WKUserContentController, ControllerState>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    private let controller: WKUserContentController
    private let state: ControllerState

    init(controller: WKUserContentController) {
        precondition(Thread.isMainThread)
        self.controller = controller
        if let state = Self.controllerStates.object(forKey: controller) {
            self.state = state
        } else {
            let state = ControllerState()
            self.state = state
            Self.controllerStates.setObject(state, forKey: controller)
        }
    }

    /// Compile before allowing navigation. A settings change during compilation is rechecked before
    /// installation, so an old completion cannot restore blocking after it has been disabled.
    func prepare(completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        ExteraBrowserFilterRuntime.shared.start()
        let revision = ExteraBrowserFilterRuntime.shared.revision
        if Self.observedRevision != revision {
            Self.observedRevision = revision
            Self.failedSource = nil
        }
        guard let source = Self.currentSource() else {
            self.removeInstalledList()
            completion()
            return
        }
        if self.state.requestedSource == source && self.state.installedRevision == revision && self.state.installedList != nil {
            completion()
            return
        }
        Self.compile(source: source) { [weak self] list in
            guard let self else {
                completion()
                return
            }
            guard Self.currentSource() == source else {
                self.prepare(completion: completion)
                return
            }
            if let list {
                self.install(list, source: source, requestedSource: source)
                completion()
            } else if let fallback = Self.bundledSource() {
                // A list can exceed WebKit's regex compiler budget even below the rule-count cap.
                // Keep exact-host exceptions and the conservative bundled protection in that case.
                Self.compile(source: fallback) { [weak self] list in
                    guard let self else { completion(); return }
                    guard Self.currentSource() == source else { self.prepare(completion: completion); return }
                    if let list { self.install(list, source: fallback, requestedSource: source) } else { self.removeInstalledList() }
                    completion()
                }
            } else {
                self.removeInstalledList()
                completion()
            }
        }
    }

    private func install(_ list: WKContentRuleList, source: String, requestedSource: String) {
        self.removeInstalledList()
        self.controller.add(list)
        self.state.installedList = list
        self.state.installedSource = source
        self.state.requestedSource = requestedSource
        self.state.installedRevision = ExteraBrowserFilterRuntime.shared.revision
    }

    private func removeInstalledList() {
        if let list = self.state.installedList {
            self.controller.remove(list)
        }
        self.state.installedList = nil
        self.state.installedSource = nil
        self.state.requestedSource = nil
        self.state.installedRevision = nil
    }

    private static func currentSource() -> String? {
        guard ExteraBrowserSettings.shared.adBlockingEnabled else { return nil }
        let hosts = ExteraBrowserSettings.shared.exceptionHosts
        let revision = ExteraBrowserFilterRuntime.shared.revision
        if hosts == self.sourceExceptions, revision == self.sourceRevision, let source = self.sourceCache {
            return source
        }
        guard let source = self.makeSource(hosts: hosts, subscriptions: ExteraBrowserFilterRuntime.shared.currentRules) else { return nil }
        self.sourceExceptions = hosts
        self.sourceRevision = revision
        self.sourceCache = source
        return source
    }

    private static func bundledSource() -> String? {
        return self.makeSource(hosts: ExteraBrowserSettings.shared.exceptionHosts, subscriptions: [])
    }

    private static func makeSource(hosts: [String], subscriptions: [ExteraBrowserContentRule]) -> String? {
        let exceptions = hosts.map { host in
            // Host-only boundary: example.com must never exempt example.com.evil.test or a URL
            // with example.com in its path/query. Exceptions deliberately do not cover subdomains.
            // HTTP(S) URLs are canonicalized with a slash after the authority. WebKit's regex
            // parser rejects alternation and embedded end anchors, including the old ([/?#]|$).
            return "^https?://([^/?#]*@)?" + host.replacingOccurrences(of: ".", with: "\\.") + "\\.?(:[0-9]+)?/"
        }
        // Original conservative rules, targeting dedicated advertising/measurement hosts. Third-party
        // resources only; the top-level document remains available even on a listed host.
        let domains = [
            "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
            "adnxs.com", "adsrvr.org", "pubmatic.com", "rubiconproject.com", "openx.net",
            "criteo.com", "criteo.net", "amazon-adsystem.com", "taboola.com", "outbrain.com",
            "scorecardresearch.com", "quantserve.com", "google-analytics.com"
        ]
        var rules: [[String: Any]] = domains.map { domain in
            let trigger: [String: Any] = [
                "url-filter": "^https?://([a-z0-9-]+\\.)*" + domain.replacingOccurrences(of: ".", with: "\\.") + "\\.?(:[0-9]+)?/",
                "url-filter-is-case-sensitive": false,
                "load-type": ["third-party"],
                "resource-type": ["script", "image", "style-sheet", "font", "raw", "svg-document", "media"]
            ]
            return ["trigger": trigger, "action": ["type": "block"]]
        }
        let cosmeticTrigger: [String: Any] = ["url-filter": "^https?://", "url-filter-is-case-sensitive": false]
        rules.append([
            "trigger": cosmeticTrigger,
            "action": ["type": "css-display-none", "selector": ".adsbygoogle, iframe[id^=\"google_ads_iframe\"]"]
        ])
        if !subscriptions.isEmpty, let data = try? JSONEncoder().encode(subscriptions), let converted = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            rules.append(contentsOf: converted)
        }
        // User exceptions run last and therefore override every bundled and subscription rule,
        // without combining incompatible if-domain/unless-top-url trigger conditions.
        if !exceptions.isEmpty {
            rules.append(["trigger": ["url-filter": "^https?://", "if-top-url": exceptions], "action": ["type": "ignore-previous-rules"]])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func compile(source: String, completion: @escaping (WKContentRuleList?) -> Void) {
        if self.failedSource == source { completion(nil); return }
        if self.cachedSource == source, let list = self.cachedList {
            completion(list)
            return
        }
        if self.pending[source] != nil {
            self.pending[source]?.append(completion)
            return
        }
        guard self.pending.count < 3 else { completion(nil); return }
        self.pending[source] = [completion]
        // A deterministic content hash avoids reusing a stale persisted list after rules/exceptions change.
        var hash: UInt64 = 14695981039346656037
        for byte in source.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let identifier = "exteragram.browser.v2.\(String(hash, radix: 16))"
        self.recentIdentifiers.removeAll { $0 == identifier }
        self.recentIdentifiers.append(identifier)
        self.recentIdentifiers = Array(self.recentIdentifiers.suffix(3))
        guard let store = WKContentRuleListStore.default() else {
            if Self.currentSource() == source { ExteraBrowserFilterRuntime.shared.reportCompilationError("WebKit’s rule-list store is unavailable. Content blocking could not be installed.") }
            self.finish(source: source, list: nil)
            return
        }
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            DispatchQueue.main.async {
                if let list {
                    if Self.currentSource() == source { ExteraBrowserFilterRuntime.shared.reportCompilationError(nil) }
                    self.finish(source: source, list: list)
                } else {
                    store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) { list, error in
                        DispatchQueue.main.async {
                            if list == nil {
                                self.failedSource = source
                                if Self.currentSource() == source {
                                    ExteraBrowserFilterRuntime.shared.reportCompilationError("WebKit could not compile the selected filters. Bundled protection is used where available. Disable or reduce subscriptions and retry. " + (error.map { String($0.localizedDescription.prefix(200)) } ?? ""))
                                }
                            } else if Self.currentSource() == source {
                                ExteraBrowserFilterRuntime.shared.reportCompilationError(nil)
                            }
                            self.finish(source: source, list: list)
                            store.getAvailableContentRuleListIdentifiers { identifiers in
                                DispatchQueue.main.async {
                                    for old in identifiers ?? [] where old.hasPrefix("exteragram.browser.") && !self.recentIdentifiers.contains(old) {
                                        store.removeContentRuleList(forIdentifier: old, completionHandler: { _ in })
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func finish(source: String, list: WKContentRuleList?) {
        if let list {
            self.cachedSource = source
            self.cachedList = list
        }
        let callbacks = self.pending.removeValue(forKey: source) ?? []
        for callback in callbacks { callback(list) }
    }
}
