import Foundation
import SwiftSignalKit

// MARK: AyuGram
// exteraGram's country of a proxy (ProxyController.requestProxyCountry): the server's address is resolved and
// looked up at ipwho.is. Answers are kept while the app runs.
final class AyuProxyCountry {
    static let shared = AyuProxyCountry()

    private let queue = DispatchQueue(label: "app.ayugram.proxyCountry", qos: .utility)
    private let session = URLSession(configuration: .ephemeral)
    private var cache: [String: String] = [:]
    private var pending: [String: [(String?) -> Void]] = [:]

    // "🇩🇪 Germany" for a country code, in the app's language.
    static func title(countryCode: String, languageCode: String) -> String? {
        let code = countryCode.uppercased()
        guard code.count == 2, code.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else {
            return nil
        }
        let flag = String(String.UnicodeScalarView(code.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
        let name = Locale(identifier: languageCode).localizedString(forRegionCode: code) ?? code
        return flag + " " + name
    }

    static func countryCode(response: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any], (json["success"] as? Bool) == true, let code = json["country_code"] as? String, !code.isEmpty else {
            return nil
        }
        return code
    }

    // The first address of a host name, or the host itself when it is an address already.
    private static func resolve(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return nil
        }
        defer {
            freeaddrinfo(result)
        }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    // The country code of a proxy host, on the main queue; nil when it could not be found.
    func countryCode(host: String) -> Signal<String?, NoError> {
        return Signal { subscriber in
            self.queue.async {
                let deliver: (String?) -> Void = { code in
                    DispatchQueue.main.async {
                        subscriber.putNext(code)
                        subscriber.putCompletion()
                    }
                }
                if let cached = self.cache[host] {
                    deliver(cached)
                    return
                }
                if self.pending[host] != nil {
                    self.pending[host]?.append(deliver)
                    return
                }
                self.pending[host] = [deliver]
                let finish: (String?) -> Void = { code in
                    self.queue.async {
                        if let code {
                            self.cache[host] = code
                        }
                        let waiting = self.pending.removeValue(forKey: host) ?? []
                        for completion in waiting {
                            completion(code)
                        }
                    }
                }
                guard let address = AyuProxyCountry.resolve(host), let encoded = address.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")), let url = URL(string: "https://ipwho.is/" + encoded) else {
                    finish(nil)
                    return
                }
                self.session.dataTask(with: URLRequest(url: url, timeoutInterval: 6.0), completionHandler: { data, _, _ in
                    finish(data.flatMap(AyuProxyCountry.countryCode(response:)))
                }).resume()
            }
            return EmptyDisposable
        }
    }
}
