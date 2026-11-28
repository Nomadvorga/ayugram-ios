import Foundation

private final class RatesWorld {
    var wall: Int64 = 1_800_000_000_000
    var uptime: TimeInterval = 1000.0
    var disk: [String: Data] = [:]
    var response: Data?
    var downloads = 0
    var held: [(Data?) -> Void]?
    var updates = 0
    var stars = 2000.0
    var target = ""
    var account: Int64 = 1
    var accountCurrencies: [Int64: String] = [1: "RUB", 2: "KZT"]
    var accountLookups = 0

    func advance(_ seconds: TimeInterval) {
        self.wall += Int64(seconds * 1000.0)
        self.uptime += seconds
    }

    func makeStore() -> ExchangeRatesStore {
        return ExchangeRatesStore(environment: ExchangeRatesStore.Environment(
            now: { self.wall },
            read: { self.disk[$0] },
            write: { self.disk[$0] = $1 },
            download: { completion in
                self.downloads += 1
                if self.held != nil {
                    self.held?.append(completion)
                } else {
                    completion(self.response)
                }
            },
            deliver: { $0() }
        ))
    }

    func makeRates(_ store: ExchangeRatesStore) -> InlineRates {
        return InlineRates(store: store, environment: InlineRates.Environment(
            now: { self.wall },
            uptime: { self.uptime },
            starsUsdSellRate1000: { self.stars },
            targetCurrency: { self.target },
            currentAccount: { self.account },
            accountCurrency: {
                self.accountLookups += 1
                return self.accountCurrencies[$0]
            }
        ), onUpdated: { self.updates += 1 })
    }
}

private func text(_ value: Double?) -> String? {
    return value.map { "\($0)" }
}

private let coinbase = Data("""
{"data":{"currency":"USD","rates":{"EUR":"0.8","RUB":"80","TON":"0.25","BTC":"0.00001","JPY":"160.0","GBP":"0","KZT":"12abc","UAH":40,"DOGE":"5","TRY":"3e1","PLN":""}}}
""".utf8)

// Real names from the system's time zone database.
func runZonePlacesTests() {
    let index = InlineZonePlaces.build(locale: "de")
    check("places oslo", "Europe/Oslo", index["oslo"])
    check("places осло", "Europe/Oslo", index["осло"])
    check("places норвегия", "Europe/Oslo", index["норвегия"])
    check("places app language", "Europe/Vienna", index["wien"])
    check("places country with a primary zone", "Europe/Berlin", index["germany"])
    check("places accents kept", "America/Sao_Paulo", index["são paulo"])
    check("places accents stripped", "America/Sao_Paulo", index["sao paulo"])
    check("places hyphen", "America/Port-au-Prince", index["port au prince"])
    check("places china", "Asia/Shanghai", index["китай"])
    check("places country without a primary zone", nil, index["russia"])
    check("places short names dropped", nil, index["us"])
    check("places english only without the app language", nil, InlineZonePlaces.build(locale: nil)["wien"])

    let options = fullOptions(places: { index[$0] })
    full("12:00 в осло=", "10:00", options)
    full("12:00 в норвегии=", "10:00", options)
    full("12:00 in stockholm=", "10:00", options)
    full("12:00 в китае=", "17:00", options)
    full("12:00 на филиппинах=", "17:00", options)

    let english = InlineCurrencyChoices.all(locale: Locale(identifier: "en"))
    check("choices count", "152", "\(english.count)")
    check("choices first", "Afghan Afghani — AFN", english.first?.title)
    check("choices crypto last", "GRAM,BTC,ETH,SOL,USDT", english.suffix(5).map { $0.code }.joined(separator: ","))
    check("choices gram title", "Gram — GRAM", english.first(where: { $0.code == "GRAM" })?.title)
    check("choices russian capitalised", "Российский рубль — RUB", InlineCurrencyChoices.all(locale: Locale(identifier: "ru")).first(where: { $0.code == "RUB" })?.title)
    check("choices supported", "true,true,true,false,false", ["EUR", "GRAM", "XTR", "", "DOGE"].map { "\(InlineCurrencyChoices.isSupported($0))" }.joined(separator: ","))

    let places = InlineZonePlaces()
    check("places first lookup only starts the build", nil, places.lookup("oslo", locale: "en"))
    var found: String?
    for _ in 0 ..< 200 where found == nil {
        Thread.sleep(forTimeInterval: 0.01)
        found = places.lookup("oslo", locale: "en")
    }
    check("places lookup after the build", "Europe/Oslo", found)
}

func runRatesTests() {
    // Parsing: a rate is the price of one dollar, the state keeps the price of one unit in dollars.
    let state = ExchangeRates.parseState(coinbase, time: 5)
    check("rates USD", "1.0", text(state?.usdRate("USD")))
    check("rates EUR", "1.25", text(state?.usdRate("EUR")))
    check("rates RUB", "0.0125", text(state?.usdRate("RUB")))
    check("rates TON", "4.0", text(state?.usdRate("TON")))
    check("rates BTC", "100000.0", text(state?.usdRate("BTC")))
    check("rates JPY", "0.00625", text(state?.usdRate("JPY")))
    check("rates lower case and spaces", "1.25", text(state?.usdRate(" eur ")))
    check("rates zero is dropped", nil, text(state?.usdRate("GBP")))
    check("rates malformed is dropped", nil, text(state?.usdRate("KZT")))
    check("rates empty is dropped", nil, text(state?.usdRate("PLN")))
    check("rates number", "0.025", text(state?.usdRate("UAH")))
    check("rates exponent", "0.0333333333333333", text(state?.usdRate("TRY")))
    check("rates unknown currency", nil, text(state?.usdRate("DOGE")))
    check("rates time", "5", state.map { "\($0.time)" })
    check("rates not json", nil, ExchangeRates.parseState(Data("oops".utf8), time: 5).map { _ in "state" })
    check("rates no rates", nil, ExchangeRates.parseState(Data("{\"data\":{}}".utf8), time: 5).map { _ in "state" })
    check("rates 1/3 keeps 16 places", "0.3333333333333333", text(ExchangeRates.parseState(Data("{\"data\":{\"rates\":{\"EUR\":\"3\"}}}".utf8), time: 5)?.usdRate("EUR")))

    check("supported TON", "true", "\(ExchangeRates.isSupportedCurrency("ton"))")
    check("supported XTR", "false", "\(ExchangeRates.isSupportedCurrency("XTR"))")
    check("supported count", "152", "\(ExchangeRates.currencies.count)")

    check("local RU", "RUB", ExchangeRates.localCurrency(countries: ["RU", "KZ"], localeCountry: "US"))
    check("local KZ by device region", "KZT", ExchangeRates.localCurrency(countries: ["RU", "KZ"], localeCountry: "kz"))
    check("local lower case", "EUR", ExchangeRates.localCurrency(countries: ["de"], localeCountry: nil))
    check("local none", nil, ExchangeRates.localCurrency(countries: [], localeCountry: "US"))
    check("local placeholder", nil, ExchangeRates.localCurrency(countries: ["_A"], localeCountry: nil))
    check("local no currency", nil, ExchangeRates.localCurrency(countries: ["AQ"], localeCountry: nil))
    check("local unknown region", nil, ExchangeRates.localCurrency(countries: ["ZZ"], localeCountry: nil))

    // Store: one download per five minutes, the answer is kept on disk.
    do {
        let world = RatesWorld()
        world.response = coinbase
        let store = world.makeStore()
        check("store starts empty", nil, text(store.peekCached()?.usdRate("EUR")))
        var got: [String?] = []
        store.fetch { got.append(text($0?.usdRate("EUR"))) }
        check("store downloads", "1", "\(world.downloads)")
        check("store delivers", "1.25", got.last ?? nil)
        check("store keeps in memory", "1.25", text(store.peekCached()?.usdRate("EUR")))
        world.advance(299.0)
        store.fetch { got.append(text($0?.usdRate("EUR"))) }
        check("store fresh: no download", "1", "\(world.downloads)")
        check("store fresh: cached answer", "2", "\(got.count)")
        world.advance(1.0)
        world.response = nil
        store.fetch { got.append(text($0?.usdRate("EUR"))) }
        check("store stale: downloads", "2", "\(world.downloads)")
        check("store failure: old answer", "1.25", got.last ?? nil)
        store.fetch { _ in }
        check("store failure: retried at once", "3", "\(world.downloads)")

        let second = world.makeStore()
        check("second store: memory empty", nil, text(second.peekCached()?.usdRate("EUR")))
        check("second store: reads disk", "1.25", text(second.getCached()?.usdRate("EUR")))
        check("second store: time kept", "1800000000000", second.peekCached().map { "\($0.time)" })

        world.held = []
        var joined = 0
        second.fetch { _ in joined += 1 }
        second.fetch { _ in joined += 1 }
        check("store joins a running download", "4", "\(world.downloads)")
        let held = world.held ?? []
        world.held = nil
        held.forEach { $0(coinbase) }
        check("store answers every waiter", "2", "\(joined)")

        let third = world.makeStore()
        var fresh: String?
        third.fetch { fresh = text($0?.usdRate("EUR")) }
        check("third store: saved time prevents a download", "4", "\(world.downloads)")
        check("third store: answer from disk", "1.25", fresh)
    }

    // InlineRates: nothing until the first download lands, then cross rates.
    do {
        let world = RatesWorld()
        world.response = coinbase
        world.held = []
        let store = world.makeStore()
        let rates = world.makeRates(store)
        check("inline supports EUR", "true", "\(rates.supports("EUR"))")
        check("inline supports GRAM", "true", "\(rates.supports(Currencies.gram))")
        check("inline supports stars", "true", "\(rates.supports(Currencies.stars))")
        check("inline supports DOGE", "false", "\(rates.supports("DOGE"))")

        check("inline cold", nil, text(rates.rate(from: "EUR", to: "RUB")))
        check("inline cold: one download", "1", "\(world.downloads)")
        check("inline cold again", nil, text(rates.rate(from: "EUR", to: "RUB")))
        check("inline cold again: still one", "1", "\(world.downloads)")
        check("inline stars need no download", "1.0", text(rates.rate(from: Currencies.stars, to: Currencies.stars)))
        let held = world.held ?? []
        world.held = nil
        held.forEach { $0(coinbase) }
        check("inline update signalled", "1", "\(world.updates)")
        check("inline EUR to RUB", "100.0", text(rates.rate(from: "EUR", to: "RUB")))
        check("inline GRAM to USD", "4.0", text(rates.rate(from: Currencies.gram, to: "USD")))
        check("inline stars to USD", "0.02", text(rates.rate(from: Currencies.stars, to: "USD")))
        check("inline USD to stars", "50.0", text(rates.rate(from: "USD", to: Currencies.stars)))
        world.stars = 0.0
        check("inline stars without a rate", nil, text(rates.rate(from: Currencies.stars, to: "USD")))
        world.stars = 2000.0
        check("inline warm: no download yet", "1", "\(world.downloads)")

        // A missing currency asks again after 30 seconds, not before.
        world.advance(29.0)
        check("inline missing currency", nil, text(rates.rate(from: "GBP", to: "USD")))
        check("inline missing: throttled", "1", "\(world.downloads)")
        world.advance(1.0)
        check("inline missing after 30 s", nil, text(rates.rate(from: "GBP", to: "USD")))
        check("inline missing after 30 s: store still fresh", "1", "\(world.downloads)")
        check("inline missing after 30 s: update signalled", "2", "\(world.updates)")

        // Known currencies refresh every five minutes.
        world.advance(300.0)
        world.held = []
        check("inline refresh returns the old rate first", "100.0", text(rates.rate(from: "EUR", to: "RUB")))
        check("inline refresh downloaded", "2", "\(world.downloads)")
        let refresh = world.held ?? []
        world.held = nil
        refresh.forEach { $0(Data("{\"data\":{\"rates\":{\"EUR\":\"0.5\",\"RUB\":\"100\"}}}".utf8)) }
        check("inline refresh signalled", "3", "\(world.updates)")
        check("inline refreshed rate", "200.0", text(rates.rate(from: "EUR", to: "RUB")))

        // Rates older than a day are not used.
        world.response = nil
        world.advance(24.0 * 3600.0 + 1.0)
        check("inline too old", nil, text(rates.rate(from: "EUR", to: "RUB")))

        check("inline local by account", "RUB", rates.localCurrency())
        check("inline local cached", "RUB", rates.localCurrency())
        check("inline local looked up once", "1", "\(world.accountLookups)")
        world.account = 2
        check("inline local other account", "KZT", rates.localCurrency())
        world.target = "TON"
        check("inline local target", Currencies.gram, rates.localCurrency())
        world.target = "XTR"
        check("inline local target stars", "XTR", rates.localCurrency())
        world.target = "DOGE"
        check("inline local unsupported target", "KZT", rates.localCurrency())
    }
}
