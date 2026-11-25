import Foundation

/// Native in-app browser preferences. Exceptions apply to an exact top-level host, not its subdomains,
/// and override both bundled rules and downloaded subscription rules. Subscription configuration is
/// exposed separately by ExteraBrowserFilters; cache/update state belongs to ExteraBrowserFilterRuntime.
public final class ExteraBrowserSettings: @unchecked Sendable {
    public static let shared = ExteraBrowserSettings()
    public static let didChangeNotification = Notification.Name("ExteraBrowserSettingsDidChange")

    private let store = AyuSettingsStore.shared
    private static let enabledKey = "extera.browser.adBlockingEnabled"
    private static let exceptionsKey = "extera.browser.exceptionHosts"

    private init() {
        self.store.register(defaults: [Self.enabledKey: true, Self.exceptionsKey: "[]"])
    }

    public var adBlockingEnabled: Bool {
        get { return self.store.bool(Self.enabledKey) }
        set {
            guard newValue != self.adBlockingEnabled else { return }
            self.store.setBool(newValue, Self.enabledKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    public var exceptionHosts: [String] {
        get {
            guard let data = self.store.string(Self.exceptionsKey).data(using: .utf8),
                  let hosts = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Array(Set(hosts.compactMap(Self.normalizedHost))).sorted()
        }
        set {
            let hosts = Array(Set(newValue.compactMap(Self.normalizedHost))).sorted()
            guard hosts != self.exceptionHosts,
                  let data = try? JSONEncoder().encode(hosts), let value = String(data: data, encoding: .utf8) else { return }
            self.store.setString(value, Self.exceptionsKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Accept a DNS host or an HTTP(S) URL. Reject wildcards, credentials, ports in bare hosts,
    /// malformed labels and URL-like strings that could accidentally exempt a different site.
    public static func normalizedHost(_ input: String) -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let url: URL?
        if input.contains("://") {
            url = URL(string: input)
        } else {
            guard !input.contains(where: { "/\\:@?#%".contains($0) }) else { return nil }
            url = URL(string: "https://" + input)
        }
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil, var host = url.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 || $0 == 46 }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return nil }
        return host
    }

    public func isExceptionHost(_ host: String) -> Bool {
        guard let host = Self.normalizedHost(host) else { return false }
        return self.exceptionHosts.contains(host)
    }

    /// Returns false without changing preferences when the host is invalid.
    @discardableResult public func setException(_ isException: Bool, forHost host: String) -> Bool {
        guard let host = Self.normalizedHost(host) else { return false }
        var hosts = Set(self.exceptionHosts)
        if isException { hosts.insert(host) } else { hosts.remove(host) }
        self.exceptionHosts = Array(hosts)
        return true
    }
}
