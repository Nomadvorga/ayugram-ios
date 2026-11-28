import Foundation
import CFNetwork
import Network
import SwiftSignalKit
import SGSimpleSettings

// MARK: AyuGram
// exteraGram "Disable proxy" on VPN / mobile data / Wi-Fi. The saved proxy settings stay as they are:
// while one of the chosen conditions holds, the active server is simply not handed to the network.
final class AyuProxyAutoDisable {
    static let shared = AyuProxyAutoDisable()

    private let queue = DispatchQueue(label: "ayu.proxy-auto-disable")
    private let monitor = NWPathMonitor()
    private let value = ValuePromise<Bool>(false, ignoreRepeated: true)
    private var settingsObserver: NSObjectProtocol?

    private init() {
        self.monitor.pathUpdateHandler = { [weak self] path in
            self?.value.set(AyuProxyAutoDisable.isDisabled(path: path))
        }
        self.monitor.start(queue: self.queue)
        self.value.set(self.isDisabledNow)

        self.settingsObserver = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil, using: { [weak self] _ in
            guard let self else {
                return
            }
            self.queue.async {
                self.value.set(self.isDisabledNow)
            }
        })
    }

    var isDisabledNow: Bool {
        return AyuProxyAutoDisable.isDisabled(path: self.monitor.currentPath)
    }

    var isDisabled: Signal<Bool, NoError> {
        return self.value.get()
    }

    private static func isDisabled(path: NWPath) -> Bool {
        let conditions = ExteraSettings.shared.doNotUseProxy
        if conditions.isEmpty {
            return false
        }
        if conditions.contains(.vpn) && self.isVpnActive() {
            return true
        }
        guard path.status == .satisfied else {
            return false
        }
        // Same split as Reachability: anything that is not cellular counts as Wi-Fi.
        if path.usesInterfaceType(.cellular) {
            return conditions.contains(.mobileData)
        } else {
            return conditions.contains(.wifi)
        }
    }

    // A VPN shows up as a scoped tunnel interface in the system proxy settings; there is no public API for it.
    private static func isVpnActive() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any], let scoped = settings["__SCOPED__"] as? [String: Any] else {
            return false
        }
        let prefixes = ["utun", "tun", "tap", "ppp", "ipsec"]
        for name in scoped.keys {
            if prefixes.contains(where: { name.hasPrefix($0) }) {
                return true
            }
        }
        return false
    }
}

public func ayuProxyAutoDisabledSignal() -> Signal<Bool, NoError> {
    return AyuProxyAutoDisable.shared.isDisabled
}

// For use with `|>` on a signal of the proxy server that the saved settings select.
public func ayuProxyAutoDisabled(_ signal: Signal<ProxyServerSettings?, NoError>) -> Signal<ProxyServerSettings?, NoError> {
    return combineLatest(signal, AyuProxyAutoDisable.shared.isDisabled)
    |> map { server, isDisabled -> ProxyServerSettings? in
        return isDisabled ? nil : server
    }
}

extension ProxySettings {
    var ayuEffectiveActiveServer: ProxyServerSettings? {
        return AyuProxyAutoDisable.shared.isDisabledNow ? nil : self.effectiveActiveServer
    }
}
