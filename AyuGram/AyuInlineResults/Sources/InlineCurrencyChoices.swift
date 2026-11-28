// Ported from exteraGram for Android (InlineResultsPreferencesActivity, the default currency list), GPL v3 or later, © exteraGram.

import Foundation

public enum InlineCurrencyChoices {
    private static let cryptoNames: [(String, String)] = [
        (Currencies.gram, "Gram"),
        ("BTC", "Bitcoin"),
        ("ETH", "Ethereum"),
        ("SOL", "Solana"),
        ("USDT", "Tether")
    ]

    public static func isSupported(_ code: String) -> Bool {
        let code = InlineRates.normalize(code)
        return code == Currencies.stars || ExchangeRates.isSupportedCurrency(code == Currencies.gram ? ExchangeRates.gram : code)
    }

    // Money by its name in the given language, then crypto. The codes are the ones the setting stores.
    public static func all(locale: Locale) -> [(code: String, title: String)] {
        var fiat: [(code: String, name: String)] = []
        for code in ExchangeRates.fiatCurrencies {
            var name = locale.localizedString(forCurrencyCode: code) ?? code
            name = name.prefix(1).capitalized(with: locale) + name.dropFirst()
            fiat.append((code, name))
        }
        fiat.sort { $0.name.compare($1.name, locale: locale) == .orderedAscending }
        return (fiat + self.cryptoNames.map { (code: $0.0, name: $0.1) }).map { (code: $0.code, title: "\($0.name) — \($0.code)") }
    }
}
