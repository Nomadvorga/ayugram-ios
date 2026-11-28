// Ported from exteraGram for Android (com.exteragram.messenger.proxy.IpAddressInfoController), GPL v3 or later,
// © exteraGram.

import Foundation

// What the ipwho.is service tells about an IP address.
struct AyuIpAddressInfo: Equatable {
    let ip: String
    let country: String
    let countryCode: String
    let region: String
    let city: String
    let isp: String
    let organization: String
    let domain: String
    let timezone: String

    // "Country, region, city" without the parts that are missing.
    var location: String {
        return [self.country, self.region, self.city].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func request(ipAddress: String) -> URLRequest? {
        guard let encoded = ipAddress.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")), let url = URL(string: "https://ipwho.is/" + encoded) else {
            return nil
        }
        return URLRequest(url: url, timeoutInterval: 4.0)
    }

    static func parse(ipAddress: String, response: Data) -> AyuIpAddressInfo? {
        guard let json = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any], (json["success"] as? Bool) == true else {
            return nil
        }
        let connection = json["connection"] as? [String: Any]
        let timezone = json["timezone"] as? [String: Any]
        func string(_ value: Any?) -> String {
            return (value as? String) ?? ""
        }
        return AyuIpAddressInfo(
            ip: (json["ip"] as? String) ?? ipAddress,
            country: string(json["country"]),
            countryCode: string(json["country_code"]),
            region: string(json["region"]),
            city: string(json["city"]),
            isp: string(connection?["isp"]),
            organization: string(connection?["org"]),
            domain: string(connection?["domain"]),
            timezone: string(timezone?["id"])
        )
    }

    // The public IP address a link points at ("http://8.8.8.8:53/x", "8.8.8.8", "[2001:db8::1]"); nil for a
    // host name and for addresses of the device's own network.
    static func extractIpAddress(_ link: String) -> String? {
        if link.isEmpty {
            return nil
        }
        var host = URLComponents(string: link)?.host
        if host == nil || !link.contains("://") {
            host = URLComponents(string: "http://" + link)?.host ?? host
        }
        guard var host, !host.isEmpty else {
            return nil
        }
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count > 2 {
            host = String(host.dropFirst().dropLast())
        }

        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else {
                return nil
            }
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            let isUnspecified = bytes.allSatisfy { $0 == 0 }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
            let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            let isSiteLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0
            let isMulticast = bytes[0] == 0xff
            if isUnspecified || isLoopback || isLinkLocal || isSiteLocal || isMulticast {
                return nil
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: buffer)
        }

        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
        }
        var octets: [Int] = []
        for part in parts {
            guard (1 ... 3).contains(part.count), part.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }), let value = Int(part), value <= 255 else {
                return nil
            }
            octets.append(value)
        }
        let isUnspecified = octets == [0, 0, 0, 0]
        let isLoopback = octets[0] == 127
        let isLinkLocal = octets[0] == 169 && octets[1] == 254
        let isSiteLocal = octets[0] == 10 || (octets[0] == 172 && (16 ... 31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168)
        let isMulticast = (224 ... 239).contains(octets[0])
        if isUnspecified || isLoopback || isLinkLocal || isSiteLocal || isMulticast {
            return nil
        }
        return octets.map { "\($0)" }.joined(separator: ".")
    }
}
