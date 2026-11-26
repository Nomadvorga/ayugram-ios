import CoreFoundation
import Foundation

public struct ExteraPillWeather: Codable, Equatable {
    public var current = true
    public var latitude = 55.7558
    public var longitude = 37.6173
    public var address = ""
    public init() {}
    public var valid: Bool {
        self.latitude.isFinite && self.longitude.isFinite && (-90 ... 90).contains(self.latitude) && (-180 ... 180).contains(self.longitude) && self.address.count <= 512
    }
    public static func temperature(_ celsius: Double, timezone: String) -> String {
        let fahrenheit = timezone.hasPrefix("US/") || ["America/Nassau", "America/Belize", "America/Cayman", "Pacific/Palau"].contains(timezone)
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        // Java Math.round: floor(x + 0.5), including negative half values.
        return String(Int(floor(value + 0.5))) + (fahrenheit ? "°F" : "°C")
    }
}

public enum ExteraPillCurrency {
    public static let fiat: [String] = /*FIAT*/
    private static let countries: [String: [String]] = /*COUNTRIES*/
    private static let exponents: [String: Int] = /*EXPONENTS*/
    public static func targets(for kind: ExteraBuiltinPill) -> [String] {
        let values = ["AUTO"] + self.fiat.filter { kind != .usd || $0 != "USD" }
        let pinned = ["AUTO", "USD", "EUR"].filter { values.contains($0) }
        return pinned + values.filter { !pinned.contains($0) }
    }
    public static func resolve(_ selection: String, phone: String, region: String? = (Locale.current as NSLocale).object(forKey: .countryCode) as? String) -> String {
        let allowed = Set(self.fiat + ["TON", "BTC", "ETH", "SOL"])
        let selection = selection.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard selection == "AUTO" else { return allowed.contains(selection) ? selection : "USD" }
        let digits = String(phone.filter { $0 >= "0" && $0 <= "9" })
        // APK findCallingCodeInfo uses the first matching 1...3-digit calling code.
        let candidates = (1 ... 3).compactMap { length -> [String]? in
            guard digits.count >= length else { return nil }
            return self.countries[String(digits.prefix(length))]
        }.first ?? []
        guard let country = candidates.first(where: { $0 == region?.uppercased() }) ?? candidates.first,
              !country.hasPrefix("_") else { return "USD" }
        let currency = (Locale(identifier: "en_" + country) as NSLocale).object(forKey: .currencyCode) as? String ?? "USD"
        return allowed.contains(currency) ? currency : "USD"
    }
    public static func price(data: Data, base: String, target: String) throws -> String {
        guard data.count <= 512 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["data"] as? [String: Any], content["currency"] as? String == "USD",
              let rates = content["rates"] as? [String: Any] else { throw ExteraPillError.invalidConfiguration }
        func number(_ code: String) throws -> Decimal {
            if code == "USD" { return 1 }
            guard let string = rates[code] as? String, string.utf8.count <= 128,
                  let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN, value > 0 else { throw ExteraPillError.invalidConfiguration }
            return value
        }
        func divide(_ lhs: Decimal, _ rhs: Decimal, scale: Int) throws -> Decimal {
            var a = lhs, b = rhs, result = Decimal(), rounded = Decimal()
            let status = NSDecimalDivide(&result, &a, &b, .plain)
            guard status == .noError || status == .lossOfPrecision else { throw ExteraPillError.invalidConfiguration }
            NSDecimalRound(&rounded, &result, scale, .plain)
            return rounded
        }
        // Reproduce APK reciprocal rounding before dividing baseUSD / targetUSD.
        let baseUSD = try divide(1, number(base), scale: 16)
        let targetUSD = try divide(1, number(target), scale: 16)
        var value = try divide(baseUSD, targetUSD, scale: 12)
        let digits = self.exponents[target] ?? 0
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, digits, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal; formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = digits; formatter.maximumFractionDigits = digits
        guard let text = formatter.string(from: NSDecimalNumber(decimal: rounded)) else { throw ExteraPillError.invalidConfiguration }
        let overrides: [String: (String, Bool)] = ["USD": ("$", false), "RUB": ("₽", true), "KZT": ("₸", true), "TRY": ("₺", true), "UAH": ("₴", true), "PLN": ("zł", true), "CNY": ("CN¥", false), "BYN": ("Br", true), "ILS": ("₪", false), "CZK": ("Kč", true), "INR": ("₹", false)]
        if let (symbol, suffix) = overrides[target] { return suffix ? text + " " + symbol : symbol + text }
        let currencyFormatter = NumberFormatter()
        currencyFormatter.locale = Locale(identifier: "en_US"); currencyFormatter.numberStyle = .currency; currencyFormatter.currencyCode = target
        let symbol = currencyFormatter.currencySymbol ?? target
        if symbol == target || ["$", "kr", "Fr", "₩"].contains(symbol) { return text + " " + target }
        return symbol + text
    }
}

public struct ExteraPillGestureFrame {
    public let outgoingY: Double
    public let incomingY: Double
    public let outgoingAlpha: Double
    public let incomingAlpha: Double
    public let outgoingScale: Double
    public let incomingScale: Double
    public static func frame(distance: Double, height: Double, hasNeighbor: Bool) -> Self {
        let height = max(height, 1), p = abs(distance) / height, sign = distance < 0 ? -1.0 : 1.0
        if !hasNeighbor {
            return Self(outgoingY: sign * height * (1 - 1 / (p * 0.18 + 1)), incomingY: 0, outgoingAlpha: 1, incomingAlpha: 0, outgoingScale: 1, incomingScale: 0.8)
        }
        let progress = min(p, 1)
        return Self(outgoingY: sign * height * progress, incomingY: -sign * height * (1 - progress), outgoingAlpha: 1 - progress, incomingAlpha: progress, outgoingScale: 1 - progress * 0.2, incomingScale: 0.8 + progress * 0.2)
    }
    public static func commits(distance: Double, height: Double, hasNeighbor: Bool) -> Bool {
        hasNeighbor && height > 0 && abs(distance) > height * 0.25
    }
}
