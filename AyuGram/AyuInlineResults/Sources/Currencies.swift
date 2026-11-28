// Ported from exteraGram for Android (com.exteragram.messenger.inline.rates), GPL v3 or later, © exteraGram.

import Foundation

protocol CurrencyRates: AnyObject {
    func supports(_ code: String) -> Bool
    func rate(from: String, to: String) -> Double?
}

enum Currencies {
    static let fallback = "USD"
    static let stars = "XTR"
    static let gram = "GRAM"

    private static let symbolList: [(Character, String)] = [
        ("$", "USD"),
        ("€", "EUR"),
        ("₽", "RUB"),
        ("£", "GBP"),
        ("¥", "JPY"),
        ("₸", "KZT"),
        ("₴", "UAH"),
        ("₺", "TRY"),
        ("₹", "INR"),
        ("₪", "ILS"),
        ("₩", "KRW"),
        ("₾", "GEL"),
        ("₼", "AZN"),
        ("֏", "AMD"),
        ("₫", "VND"),
        ("฿", "THB"),
        ("₱", "PHP"),
        ("₦", "NGN"),
        ("₿", "BTC"),
        ("⭐", stars),
        ("★", stars)
    ]

    private static let symbols: [Character: String] = {
        var result: [Character: String] = [:]
        for (symbol, code) in symbolList {
            result[symbol] = code
        }
        return result
    }()

    private static let labels: [String: String] = {
        var result: [String: String] = [:]
        for (symbol, code) in symbolList where code != "BTC" && symbol != "★" {
            result[code] = String(symbol)
        }
        return result
    }()

    private static let lowercaseCodes: Set<String> = [
        "usd", "eur", "rub", "gbp", "kzt", "uah", "byn", "cny", "jpy", "pln", "czk", "aed", "inr", "ils",
        "chf", "cad", "aud", "uzs", "kgs", "azn", "krw", "thb", "vnd", "sgd", "hkd", "brl", "mxn", "sek",
        "huf", "btc", "eth", "usdt", "xtr"
    ]

    private static let conversions: Set<String> = ["в", "to", "in"]

    private static let words: [String: String] = {
        var result: [String: String] = [:]
        func add(_ code: String, _ forms: String...) {
            for form in forms {
                result[form] = code
            }
        }
        add(
            "USD", "доллар", "доллара", "долларов", "доллары", "долларах", "долл",
            "бакс", "бакса", "баксов", "баксы", "баксах", "dollar", "dollars", "buck", "bucks"
        )
        add("EUR", "евро", "euro", "euros")
        add("RUB", "рубль", "рубля", "рублей", "рубли", "рублях", "руб", "р", "ruble", "rubles", "rouble", "roubles")
        add("GBP", "фунт", "фунта", "фунтов", "фунты", "фунтах")
        add("KZT", "тенге", "tenge")
        add("UAH", "гривна", "гривны", "гривен", "гривнах", "грн", "hryvnia", "hryvnias")
        add("CNY", "юань", "юаня", "юаней", "юани", "юанях", "yuan")
        add("JPY", "иена", "иены", "иен", "иенах", "йена", "йены", "йен", "йенах", "yen")
        add("TRY", "лира", "лиры", "лир", "лирах", "lira", "liras")
        add("PLN", "злотый", "злотого", "злотых", "злотые", "zloty", "zlotys", "zł")
        add("CZK", "kč")
        add("INR", "рупия", "рупии", "рупий", "рупиях", "rupee", "rupees")
        add("ILS", "шекель", "шекеля", "шекелей", "шекели", "шекелях", "shekel", "shekels")
        add("CHF", "франк", "франка", "франков", "франки", "франках", "franc", "francs")
        add("AED", "дирхам", "дирхама", "дирхамов", "дирхамы", "дирхамах", "dirham", "dirhams")
        add("THB", "бат", "бата", "батов", "баты", "батах", "baht")
        add("GEL", "лари", "lari")
        add("AMD", "драм", "драмов", "драмы", "драмах", "dram", "drams")
        add("UZS", "сум", "сумов", "сумы", "сумах")
        add("KGS", "сом", "сомов", "сомах", "som")
        add(
            "BTC", "биткоин", "биткоина", "биткоинов", "биткоины", "биткоинах",
            "биткойн", "биткойна", "биткойнов", "биткойны", "биткойнах", "bitcoin", "bitcoins"
        )
        add("ETH", "эфириум", "эфириума", "эфириумов", "эфириумах", "ethereum", "ether")
        add(
            gram, "gram", "grams", "грам", "грама", "грамов", "грамы", "грамах",
            "ton", "тон", "тона", "тонов", "тонах", "toncoin", "toncoins", "тонкоин", "тонкоина", "тонкоинов"
        )
        add("USDT", "tether")
        add(
            stars, "звезда", "звезды", "звёзды", "звезд", "звёзд", "звездах", "звёздах", "звездами", "звёздами",
            "звезду", "star", "stars"
        )
        return result
    }()

    // ISO 4217 minor units that are not 2, and the ISO codes that are not money.
    private static let noMinorUnits: Set<String> = [
        "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"
    ]
    private static let threeMinorUnits: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]
    private static let fourMinorUnits: Set<String> = ["CLF", "UYW"]
    private static let notMoney: Set<String> = [
        "XAU", "XAG", "XPT", "XPD", "XDR", "XBA", "XBB", "XBC", "XBD", "XSU", "XUA", "XTS", "XXX"
    ]

    static let symbolChars: Set<Character> = Set(symbolList.map { $0.0 })

    static func isConversion(_ word: String) -> Bool {
        return conversions.contains(word.lowercased())
    }

    static func symbol(_ character: Character, rates: CurrencyRates) -> MathUnit? {
        guard let code = symbols[character], rates.supports(code) else {
            return nil
        }
        return MathUnit(code: code, label: code == stars ? label(code) : String(character))
    }

    static func word(_ word: String, rates: CurrencyRates) -> MathUnit? {
        let lower = word.lowercased()
        let alias = words[lower]
        let code: String
        if let alias {
            code = alias
        } else if word.unicodeScalars.allSatisfy({ $0.value >= 0x41 && $0.value <= 0x5A }) {
            code = word
        } else if lowercaseCodes.contains(lower) {
            code = lower.uppercased()
        } else {
            return nil
        }
        if !rates.supports(code) {
            return nil
        }
        return MathUnit(code: code, label: alias != nil ? label(code) : code)
    }

    static func unit(_ code: String) -> MathUnit {
        return MathUnit(code: code, label: label(code))
    }

    // Digits after the point for a currency, or -1 when the code is not an ISO 4217 currency (crypto, GRAM).
    static func fractionDigits(_ code: String) -> Int {
        if code == stars {
            return 0
        }
        if noMinorUnits.contains(code) {
            return 0
        }
        if threeMinorUnits.contains(code) {
            return 3
        }
        if fourMinorUnits.contains(code) {
            return 4
        }
        if notMoney.contains(code) || code.unicodeScalars.count != 3 {
            return -1
        }
        if Locale(identifier: "en_US_POSIX").localizedString(forCurrencyCode: code) == nil {
            return -1
        }
        return 2
    }

    private static func label(_ code: String) -> String {
        return labels[code] ?? code
    }
}
