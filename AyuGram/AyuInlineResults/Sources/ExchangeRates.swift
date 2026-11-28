// Ported from exteraGram for Android (com.exteragram.messenger.utils.network.ExchangeRates), GPL v3 or later, © exteraGram.

import Foundation

struct ExchangeRatesState: Codable, Equatable {
    // Price of one unit of each currency in US dollars.
    let usdRates: [String: Double]
    // Wall clock milliseconds of the download.
    let time: Int64

    func usdRate(_ currency: String) -> Double? {
        return self.usdRates[ExchangeRates.normalize(currency)]
    }
}

enum ExchangeRates {
    static let usd = "USD"
    static let gram = "TON"

    static let fiatCurrencies: [String] = [
        "AED", "AFN", "ALL", "AMD", "AOA", "ARS", "AUD", "AWG", "AZN", "BAM", "BBD", "BDT", "BHD", "BIF",
        "BMD", "BND", "BOB", "BRL", "BSD", "BTN", "BWP", "BYN", "BZD", "CAD", "CDF", "CHF", "CLP", "CNY",
        "COP", "CRC", "CUP", "CVE", "CZK", "DJF", "DKK", "DOP", "DZD", "EGP", "ETB", "EUR", "FJD", "FKP", "GBP",
        "GEL", "GHS", "GIP", "GMD", "GNF", "GTQ", "GYD", "HKD", "HNL", "HTG", "HUF", "IDR", "ILS", "INR",
        "IQD", "IRR", "ISK", "JMD", "JOD", "JPY", "KES", "KGS", "KHR", "KMF", "KRW", "KWD", "KYD", "KZT",
        "LAK", "LBP", "LKR", "LRD", "LSL", "LYD", "MAD", "MDL", "MGA", "MKD", "MMK", "MNT", "MOP", "MRU",
        "MUR", "MVR", "MWK", "MXN", "MYR", "MZN", "NAD", "NGN", "NIO", "NOK", "NPR", "NZD", "OMR", "PAB",
        "PEN", "PGK", "PHP", "PKR", "PLN", "PYG", "QAR", "RON", "RSD", "RUB", "RWF", "SAR", "SBD", "SCR",
        "SDG", "SEK", "SGD", "SHP", "SOS", "SRD", "SSP", "SYP", "SZL", "THB", "TJS", "TMT", "TND", "TOP",
        "TRY", "TTD", "TWD", "TZS", "UAH", "UGX", "USD", "UYU", "UZS", "VES", "VND", "VUV", "WST", "XAF", "XCD",
        "XOF", "XPF", "YER", "ZAR", "ZMW"
    ]

    static let currencies: Set<String> = Set(fiatCurrencies).union([gram, "BTC", "ETH", "SOL", "USDT"])

    static let url = URL(string: "https://api.coinbase.com/v2/exchange-rates?currency=USD")!

    static func normalize(_ currency: String?) -> String {
        guard let currency else {
            return ""
        }
        return currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func isSupportedCurrency(_ currency: String?) -> Bool {
        return self.currencies.contains(self.normalize(currency))
    }

    // `countries` are the ISO region codes sharing the account's calling code, in the phone table's order;
    // the device region wins when it is one of them.
    static func localCurrency(countries: [String], localeCountry: String?) -> String? {
        guard var country = countries.first else {
            return nil
        }
        if let localeCountry, !localeCountry.isEmpty {
            if let match = countries.first(where: { $0.caseInsensitiveCompare(localeCountry) == .orderedSame }) {
                country = match
            }
        }
        if country.isEmpty || country.hasPrefix("_") {
            return nil
        }
        guard let code = NSLocale(localeIdentifier: "und_" + country.uppercased()).currencyCode else {
            return nil
        }
        let currency = self.normalize(code)
        return self.currencies.contains(currency) ? currency : nil
    }

    static func parseState(_ data: Data, time: Int64) -> ExchangeRatesState? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let body = root["data"] as? [String: Any],
              let rates = body["rates"] as? [String: Any] else {
            return nil
        }
        var usdRates: [String: Double] = [:]
        for code in self.currencies {
            if let rate = self.parseUsdRate(code, rates: rates) {
                usdRates[code] = rate
            }
        }
        if usdRates.isEmpty {
            return nil
        }
        return ExchangeRatesState(usdRates: usdRates, time: time)
    }

    private static func parseUsdRate(_ currency: String, rates: [String: Any]) -> Double? {
        if currency == self.usd {
            return 1.0
        }
        let text: String
        if let value = rates[currency] as? String {
            text = value
        } else if let value = rates[currency] as? NSNumber {
            text = value.stringValue
        } else {
            return nil
        }
        guard self.isDecimalLiteral(text), let rate = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !rate.isZero, !rate.isNaN else {
            return nil
        }
        var quotient = Decimal(1) / rate
        var rounded = Decimal()
        NSDecimalRound(&rounded, &quotient, 16, .plain)
        guard !rounded.isNaN else {
            return nil
        }
        return Double(NSDecimalString(&rounded, Locale(identifier: "en_US_POSIX")))
    }

    // Decimal(string:) reads a valid prefix and drops the rest; BigDecimal rejects such text.
    private static func isDecimalLiteral(_ text: String) -> Bool {
        var scalars = Substring(text).unicodeScalars
        func digits() -> Int {
            var count = 0
            while let first = scalars.first, first.value >= 48, first.value <= 57 {
                scalars.removeFirst()
                count += 1
            }
            return count
        }
        func sign() {
            if let first = scalars.first, first == "+" || first == "-" {
                scalars.removeFirst()
            }
        }
        sign()
        var mantissa = digits()
        if scalars.first == "." {
            scalars.removeFirst()
            mantissa += digits()
        }
        if mantissa == 0 {
            return false
        }
        if let first = scalars.first, first == "e" || first == "E" {
            scalars.removeFirst()
            sign()
            if digits() == 0 {
                return false
            }
        }
        return scalars.isEmpty
    }
}

// One download at a time, at most one every five minutes; the last good answer is kept on disk.
final class ExchangeRatesStore {
    static let cacheTtl: Int64 = 5 * 60 * 1000
    static let cacheKey = "extera.exchangeRatesCache"
    static let timestampKey = "extera.exchangeRatesTimestamp"

    struct Environment {
        var now: () -> Int64
        var read: (String) -> Data?
        var write: (String, Data) -> Void
        var download: (@escaping (Data?) -> Void) -> Void
        var deliver: (@escaping () -> Void) -> Void

        static var live: Environment {
            return Environment(
                now: { Int64(Date().timeIntervalSince1970 * 1000.0) },
                read: { UserDefaults.standard.data(forKey: $0) },
                write: { UserDefaults.standard.set($1, forKey: $0) },
                download: { completion in
                    var request = URLRequest(url: ExchangeRates.url)
                    request.timeoutInterval = 15.0
                    URLSession.shared.dataTask(with: request) { data, response, error in
                        guard error == nil, let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
                            completion(nil)
                            return
                        }
                        completion(data)
                    }.resume()
                },
                deliver: { DispatchQueue.main.async(execute: $0) }
            )
        }
    }

    static let shared = ExchangeRatesStore(environment: .live)

    private let environment: Environment
    private let lock = NSLock()
    private var cacheValue: ExchangeRatesState?
    private var didReadCache = false
    private var lastRequested: Int64?
    private var pending: [(ExchangeRatesState?) -> Void]?

    init(environment: Environment) {
        self.environment = environment
    }

    // Memory only: never touches the disk.
    func peekCached() -> ExchangeRatesState? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cacheValue
    }

    @discardableResult
    func getCached() -> ExchangeRatesState? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.lockedCached()
    }

    private func lockedCached() -> ExchangeRatesState? {
        if self.cacheValue == nil && !self.didReadCache {
            self.didReadCache = true
            if let data = self.environment.read(ExchangeRatesStore.cacheKey) {
                self.cacheValue = try? JSONDecoder().decode(ExchangeRatesState.self, from: data)
            }
        }
        return self.cacheValue
    }

    private func lockedShouldRequest() -> Bool {
        var last = self.lastRequested
        if last == nil, let data = self.environment.read(ExchangeRatesStore.timestampKey), let text = String(data: data, encoding: .utf8) {
            last = Int64(text)
        }
        guard let last else {
            return true
        }
        return self.environment.now() - last >= ExchangeRatesStore.cacheTtl
    }

    // The callback gets the newest state known, which is the stored one when the download fails.
    func fetch(_ callback: @escaping (ExchangeRatesState?) -> Void) {
        self.lock.lock()
        if self.pending != nil {
            self.pending?.append(callback)
            self.lock.unlock()
            return
        }
        let cached = self.lockedCached()
        if !self.lockedShouldRequest() {
            self.lock.unlock()
            self.environment.deliver {
                callback(cached)
            }
            return
        }
        self.pending = [callback]
        self.lock.unlock()

        self.environment.download { [weak self] data in
            guard let self else {
                return
            }
            let now = self.environment.now()
            let state = data.flatMap { ExchangeRates.parseState($0, time: now) }

            self.lock.lock()
            if let state {
                self.lastRequested = now
                self.cacheValue = state
                self.environment.write(ExchangeRatesStore.timestampKey, Data(String(now).utf8))
                if let encoded = try? JSONEncoder().encode(state) {
                    self.environment.write(ExchangeRatesStore.cacheKey, encoded)
                }
            }
            let result = state ?? self.cacheValue
            let callbacks = self.pending ?? []
            self.pending = nil
            self.lock.unlock()

            self.environment.deliver {
                for callback in callbacks {
                    callback(result)
                }
            }
        }
    }
}
