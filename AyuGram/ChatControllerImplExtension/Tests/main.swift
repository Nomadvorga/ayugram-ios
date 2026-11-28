// Host check of the IP address info core. Run from the repository root:
// swiftc -warnings-as-errors -o /tmp/ayu-ipinfo-tests AyuGram/ChatControllerImplExtension/Sources/AyuIpAddressInfoCore.swift AyuGram/ChatControllerImplExtension/Tests/main.swift && /tmp/ayu-ipinfo-tests [live]

import Foundation

var passed = 0
var failed = 0
func check(_ label: String, _ expected: String, _ actual: String) {
    if expected == actual {
        passed += 1
    } else {
        failed += 1
        print("FAILED \(label): expected \(expected), got \(actual)")
    }
}
func extract(_ links: [String]) -> String {
    return links.map { AyuIpAddressInfo.extractIpAddress($0) ?? "nil" }.joined(separator: " ")
}

check("addresses in links", "8.8.8.8 8.8.8.8 1.2.3.4 93.184.216.34", extract(["http://8.8.8.8", "8.8.8.8", "https://1.2.3.4:8443/path?x=1", "tg://93.184.216.34"]))
check("leading zeros are the same address", "8.8.8.8", extract(["http://008.008.8.8"]))
check("host names and broken addresses", "nil nil nil nil nil nil", extract(["https://example.com", "http://1.2.3", "http://256.1.1.1", "http://1.2.3.4.5", "", "http://1234.1.1.1"]))
check("the device's own networks", "nil nil nil nil nil nil nil nil 172.32.0.1", extract(["http://127.0.0.1", "http://10.1.2.3", "http://192.168.1.1", "http://172.16.0.1", "http://172.31.255.255", "http://169.254.1.1", "http://0.0.0.0", "http://224.0.0.1", "http://172.32.0.1"]))
check("IPv6", "2001:4860:4860::8888 2001:4860:4860::8888 nil nil nil nil nil", extract(["http://[2001:4860:4860::8888]:443/", "http://[2001:4860:4860:0:0:0:0:8888]", "http://[::1]", "http://[fe80::1]", "http://[ff02::1]", "http://[::]", "http://[fec0::1]"]))

let answer = #"{"ip":"8.8.8.8","success":true,"type":"IPv4","country":"United States","country_code":"US","region":"California","city":"San Jose","connection":{"asn":15169,"org":"Google LLC","isp":"Google LLC","domain":"google.com"},"timezone":{"id":"America/Los_Angeles","abbr":"PST"}}"#
let info = AyuIpAddressInfo.parse(ipAddress: "8.8.8.8", response: Data(answer.utf8))
check("answer", "8.8.8.8|United States, California, San Jose|US|Google LLC|Google LLC|google.com|America/Los_Angeles", info.map { "\($0.ip)|\($0.location)|\($0.countryCode)|\($0.isp)|\($0.organization)|\($0.domain)|\($0.timezone)" } ?? "nil")
check("missing parts", "1.1.1.1||", AyuIpAddressInfo.parse(ipAddress: "1.1.1.1", response: Data(#"{"success":true}"#.utf8)).map { "\($0.ip)|\($0.location)|\($0.isp)" } ?? "nil")
check("refusals", "nil nil nil", [#"{"ip":"x","success":false,"message":"Invalid IP address"}"#, "<html>", #"{"ip":"8.8.8.8"}"#].map { AyuIpAddressInfo.parse(ipAddress: "8.8.8.8", response: Data($0.utf8)) == nil ? "nil" : "info" }.joined(separator: " "))
check("request", "https://ipwho.is/8.8.8.8 https://ipwho.is/2001:4860:4860::8888", "\(AyuIpAddressInfo.request(ipAddress: "8.8.8.8")?.url?.absoluteString ?? "nil") \(AyuIpAddressInfo.request(ipAddress: "2001:4860:4860::8888")?.url?.absoluteString ?? "nil")")

if CommandLine.arguments.contains("live"), let request = AyuIpAddressInfo.request(ipAddress: "8.8.8.8") {
    let semaphore = DispatchSemaphore(value: 0)
    URLSession(configuration: .ephemeral).dataTask(with: request) { data, _, error in
        print("live: \(data.flatMap { AyuIpAddressInfo.parse(ipAddress: "8.8.8.8", response: $0) }.map { "\($0.location); \($0.isp); \($0.timezone)" } ?? "no info (\(error?.localizedDescription ?? "refused"))")")
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 10.0)
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
