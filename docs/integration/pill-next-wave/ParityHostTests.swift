import Foundation

final class AyuSettingsStore: @unchecked Sendable {
    static let suiteName = "ExteraPillParityTests.\(UUID().uuidString)"
    static let shared = AyuSettingsStore()
    let userDefaults = UserDefaults(suiteName: AyuSettingsStore.suiteName)!
}

@main
private enum ParityHostTests {
    static func main() throws {
        defer { AyuSettingsStore.shared.userDefaults.removePersistentDomain(forName: AyuSettingsStore.suiteName) }
        func expect(_ value: @autoclosure () throws -> Bool, _ text: String) throws {
            if try !value() { throw NSError(domain: text, code: 1) }
        }
        try expect(ExteraPillCurrency.resolve("AUTO", phone: "+79991234567", region: "RU") == "RUB", "Russian account AUTO")
        try expect(ExteraPillCurrency.resolve("AUTO", phone: "+77001234567", region: "KZ") == "KZT", "Shared +7 regional disambiguation")
        try expect(ExteraPillCurrency.resolve("AUTO", phone: "+12025550123", region: "CA") == "CAD", "Shared +1 regional disambiguation")
        try expect(ExteraPillCurrency.resolve("AUTO", phone: "", region: "RU") == "USD", "No phone has USD fallback")
        try expect(ExteraPillCurrency.resolve("ZZZ", phone: "+7999", region: "RU") == "USD", "Unknown explicit currency")
        try expect(Array(ExteraPillCurrency.targets(for: .gram).prefix(3)) == ["AUTO", "USD", "EUR"], "Pinned currency order")
        try expect(!ExteraPillCurrency.targets(for: .usd).contains("USD"), "USD target excluded only for USD pill")
        let json = Data(#"{"data":{"currency":"USD","rates":{"TON":"0.25","BTC":"0.00002","EUR":"0.9","RUB":"90","JPY":"150"}}}"#.utf8)
        try expect(try ExteraPillCurrency.price(data: json, base: "TON", target: "USD") == "$4.00", "TON is exchange rate")
        try expect(try ExteraPillCurrency.price(data: json, base: "BTC", target: "RUB") == "4,500,000.00 ₽", "Reciprocal cross rate and suffix")
        try expect(try ExteraPillCurrency.price(data: json, base: "USD", target: "JPY") == "¥150", "APK currency exponent and symbol")
        try expect(ExteraPillWeather.temperature(-0.5, timezone: "Europe/Moscow") == "0°C", "Java negative-half rounding")
        try expect(ExteraPillWeather.temperature(0, timezone: "US/Eastern") == "32°F", "Literal APK US alias")
        try expect(ExteraPillWeather.temperature(0, timezone: "America/New_York") == "0°C", "APK does not include canonical US timezone")
        try expect(ExteraPillWeather.temperature(10, timezone: "America/Nassau") == "50°F", "Exact listed Fahrenheit timezone")
        let p = ExteraPillGestureFrame.frame(distance: -8, height: 32, hasNeighbor: true)
        try expect(p.outgoingY == -8 && p.incomingY == 24 && p.outgoingAlpha == 0.75 && p.incomingAlpha == 0.25, "Quarter drag geometry")
        try expect(abs(p.outgoingScale - 0.95) < 0.000001 && abs(p.incomingScale - 0.85) < 0.000001, "Quarter drag scale")
        try expect(!ExteraPillGestureFrame.commits(distance: 8, height: 32, hasNeighbor: true), "Strict quarter threshold")
        try expect(ExteraPillGestureFrame.commits(distance: 8.01, height: 32, hasNeighbor: true), "Above quarter commits")
        try expect(!ExteraPillGestureFrame.commits(distance: 80, height: 32, hasNeighbor: false), "Finite boundary never commits")
        let boundary = ExteraPillGestureFrame.frame(distance: 32, height: 32, hasNeighbor: false)
        try expect(abs(boundary.outgoingY - 32 * (1 - 1 / 1.18)) < 0.000001 && boundary.outgoingAlpha == 1, "APK nonlinear resistance")
        let store = ExteraPillStackSettings(userDefaults: AyuSettingsStore.shared.userDefaults)
        try expect(store.target(.gram, account: 1) == "AUTO" && store.weather(account: 1).current, "APK defaults")
        store.setTarget("EUR", kind: .gram, account: 1)
        try expect(store.target(.btc, account: 1) == "AUTO" && store.target(.gram, account: 2) == "AUTO", "Per-pill and account isolation")
        store.setTarget("USD", kind: .usd, account: 1)
        try expect(store.target(.usd, account: 1) == "AUTO", "Forbidden USD retains AUTO")
        print("PASS: next-wave production model fixtures")
    }
}
