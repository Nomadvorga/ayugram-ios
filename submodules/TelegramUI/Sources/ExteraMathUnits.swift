import Foundation

// Port of inline/units/Measures.kt and inline/rates/Currencies.kt.
// Copyright exteraGram, 2022–2026; GPL-3.0-or-later with the upstream
// ADDITIONAL_TERMS.md (see docs/third-party). US liquid measures, 30-day
// months and 365-day years deliberately match Android's fixed conversions.
enum ExteraMathUnits {
    enum Kind: Equatable { case length, mass, volume, area, temperature, speed, duration, currency }

    struct Unit: Equatable {
        let code: String
        let english: String
        let russian: String
        let kind: Kind
        let scale: Double
        let offset: Double
        let counterpart: String?

        func label(_ russian: Bool) -> String { return russian ? self.russian : self.english }
    }

    private struct Catalog {
        var units: [String: Unit] = [:]
        var words: [String: String] = [:]

        mutating func add(_ code: String, _ english: String, _ russian: String, _ kind: Kind, _ scale: Double, _ counterpart: String?, _ forms: String, offset: Double = 0) {
            self.units[code] = Unit(code: code, english: english, russian: russian, kind: kind, scale: scale, offset: offset, counterpart: counterpart)
            for word in forms.split(separator: "|") { self.words[String(word)] = code }
        }
    }

    private static let catalog: Catalog = {
        var c = Catalog()
        c.add("mm", "mm", "мм", .length, 0.001, "in", "mm|мм|миллиметр|миллиметра|миллиметров|миллиметрах|millimeter|millimeters|millimetre|millimetres")
        c.add("cm", "cm", "см", .length, 0.01, "in", "cm|см|сантиметр|сантиметра|сантиметров|сантиметрах|centimeter|centimeters|centimetre|centimetres")
        c.add("m", "m", "м", .length, 1, "ft", "m|м|метр|метра|метров|метрах|meter|meters|metre|metres")
        c.add("km", "km", "км", .length, 1000, "mi", "km|км|километр|километра|километров|километрах|kilometer|kilometers|kilometre|kilometres")
        c.add("in", "in", "in", .length, 0.0254, "cm", "inch|inches|дюйм|дюйма|дюймов|дюймах")
        c.add("ft", "ft", "ft", .length, 0.3048, "m", "ft|foot|feet|фут|фута|футов|футах")
        c.add("yd", "yd", "yd", .length, 0.9144, "m", "yd|yard|yards|ярд|ярда|ярдов|ярдах")
        c.add("mi", "mi", "mi", .length, 1609.344, "km", "mi|mile|miles|миля|мили|миль|милях")
        c.add("mg", "mg", "мг", .mass, 0.000001, nil, "mg|мг|миллиграмм|миллиграмма|миллиграммов|milligram|milligrams")
        c.add("g", "g", "г", .mass, 0.001, "oz", "g|г|гр|грамм|грамма|граммов|граммах|gram|grams|gramme|grammes")
        c.add("kg", "kg", "кг", .mass, 1, "lb", "kg|кг|килограмм|килограмма|килограммов|килограммах|kilogram|kilograms|kilo|kilos")
        c.add("t", "t", "т", .mass, 1000, "lb", "t|т|тонна|тонны|тонн|тоннах|tonne|tonnes")
        c.add("oz", "oz", "oz", .mass, 0.028349523125, "g", "oz|ounce|ounces|унция|унции|унций|унциях")
        c.add("lb", "lb", "lb", .mass, 0.45359237, "kg", "lb|lbs|pound|pounds|фунт|фунта|фунтов|футах")
        c.add("ml", "ml", "мл", .volume, 0.001, "floz", "ml|мл|миллилитр|миллилитра|миллилитров|миллилитрах|milliliter|milliliters|millilitre|millilitres")
        c.add("l", "l", "л", .volume, 1, "gal", "l|л|литр|литра|литров|литрах|liter|liters|litre|litres")
        c.add("floz", "fl oz", "fl oz", .volume, 0.0295735295625, "ml", "floz|fl oz")
        c.add("gal", "gal", "gal", .volume, 3.785411784, "l", "gal|gallon|gallons|галлон|галлона|галлонов|галлонах")
        c.add("m2", "m²", "м²", .area, 1, "ft2", "m2|m²|м2|м²|sqm")
        c.add("km2", "km²", "км²", .area, 1_000_000, "mi2", "km2|km²|км2|км²")
        c.add("ha", "ha", "га", .area, 10000, "acre", "ha|га|гектар|гектара|гектаров|гектарах|hectare|hectares")
        c.add("ft2", "ft²", "ft²", .area, 0.09290304, "m2", "ft2|ft²|sqft")
        c.add("mi2", "mi²", "mi²", .area, 2_589_988.110336, "km2", "mi2|mi²")
        c.add("acre", "ac", "ac", .area, 4046.8564224, "ha", "ac|acre|acres|акр|акра|акров|акрах")
        c.add("kmh", "km/h", "км/ч", .speed, 1 / 3.6, "mph", "kmh|kph|km/h|км/ч")
        c.add("ms", "m/s", "м/с", .speed, 1, "kmh", "mps|m/s|м/с")
        c.add("mph", "mph", "mph", .speed, 0.44704, "kmh", "mph")
        c.add("knot", "kn", "уз", .speed, 1852 / 3600, "kmh", "knot|knots|узел|узла|узлов|узлах")
        c.add("C", "°C", "°C", .temperature, 1, "F", "celsius|цельсий|цельсия|цельсию|цельсиях|°c|°с|℃", offset: 273.15)
        c.add("F", "°F", "°F", .temperature, 5 / 9, "C", "fahrenheit|фаренгейт|фаренгейта|фаренгейту|фаренгейтах|°f|°ф|℉", offset: 273.15 - 32 * 5 / 9)
        c.add("K", "K", "K", .temperature, 1, "C", "kelvin|kelvins|кельвин|кельвина|кельвинов|кельвинах|°k|°к")
        c.add("msec", "ms", "мс", .duration, 0.001, nil, "ms|мс|millisecond|milliseconds|миллисекунда|миллисекунды|миллисекунд")
        c.add("s", "s", "с", .duration, 1, nil, "s|sec|secs|second|seconds|с|сек|секунда|секунды|секунд|секундах|секунду")
        c.add("min", "min", "мин", .duration, 60, nil, "min|mins|minute|minutes|мин|минута|минуты|минут|минутах|минуту")
        c.add("h", "h", "ч", .duration, 3600, nil, "h|hr|hrs|hour|hours|ч|час|часа|часов|часах")
        c.add("d", "d", "д", .duration, 86400, nil, "d|day|days|д|дн|день|дня|дней|днях|сут|сутки|суток")
        c.add("w", "w", "нед", .duration, 604800, nil, "w|wk|week|weeks|нед|неделя|недели|недель|неделях|неделю")
        c.add("mo", "mo", "мес", .duration, 2592000, nil, "mo|month|months|мес|месяц|месяца|месяцев|месяцах")
        c.add("y", "y", "г.", .duration, 31536000, nil, "y|yr|yrs|year|years|год|года|лет|годах")
        return c
    }()

    static func measure(_ word: String) -> Unit? {
        return self.catalog.words[word].flatMap { self.catalog.units[$0] }
    }

    private static let currencyAliases: [String: String] = {
        var aliases: [String: String] = [:]
        let groups: [(String, String)] = [
            ("USD", "$|dollar|dollars|buck|bucks|доллар|доллара|долларов|доллары|долларах|долл|бакс|бакса|баксов"),
            ("EUR", "€|euro|euros|евро"), ("RUB", "₽|ruble|rubles|rouble|roubles|рубль|рубля|рублей|рубли|рублях|руб|р"),
            ("GBP", "£|фунт|фунта|фунтов|фунты|фунтах"), ("JPY", "¥|yen|иена|иены|иен|йена|йены|йен"), ("KZT", "₸|tenge|тенге"),
            ("UAH", "₴|hryvnia|hryvnias|гривна|гривны|гривен|гривнах|грн"), ("TRY", "₺|lira|liras|лира|лиры|лир"),
            ("INR", "₹|rupee|rupees|рупия|рупии|рупий"), ("ILS", "₪|shekel|shekels|шекель|шекеля|шекелей"),
            ("KRW", "₩"), ("GEL", "₾|lari|лари"), ("AZN", "₼"), ("AMD", "֏|dram|drams|драм|драмов"),
            ("VND", "₫"), ("THB", "฿|baht|бат|бата|батов"), ("PHP", "₱"), ("NGN", "₦"),
            ("BTC", "₿|bitcoin|bitcoins|биткоин|биткоина|биткоинов|биткойн"),
            ("ETH", "ethereum|ether|эфириум|эфириума|эфириумов"),
            ("GRAM", "ton|toncoin|toncoins|тон|тона|тонов|тонкоин|тонкоина|тонкоинов"),
            ("CNY", "yuan|юань|юаня|юаней"), ("PLN", "zloty|zlotys|zł|злотый|злотых"),
            ("CZK", "kč"), ("CHF", "franc|francs|франк|франка|франков"),
            ("AED", "dirham|dirhams|дирхам|дирхама|дирхамов"), ("USDT", "tether"),
            ("UZS", "сум|сумов|сумы"), ("KGS", "som|сом|сомов")
        ]
        for (code, words) in groups {
            for word in words.split(separator: "|") { aliases[String(word)] = code }
        }
        return aliases
    }()

    static let supportedCurrencyCodes: Set<String> = Set(("AED AFN ALL AMD AOA ARS AUD AWG AZN BAM BBD BDT BHD BIF BMD BND BOB BRL BSD BTN BWP BYN BZD CAD CDF CHF CLP CNY COP CRC CUP CVE CZK DJF DKK DOP DZD EGP ETB EUR FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HUF IDR ILS INR IQD IRR ISK JMD JOD JPY KES KGS KHR KMF KRW KWD KYD KZT LAK LBP LKR LRD LSL LYD MAD MDL MGA MKD MMK MNT MOP MRU MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK NPR NZD OMR PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SDG SEK SGD SHP SLE SLL SOS SRD SSP STN SYP SZL THB TJS TMT TND TOP TRY TTD TWD TZS UAH UGX USD UYU UZS VES VND VUV WST XAF XCD XOF XPF YER ZAR ZMW BTC ETH SOL USDT GRAM").split(separator: " ").map(String.init))

    static func currencyCode(_ word: String) -> String? {
        let code = self.currencyAliases[word.lowercased()] ?? word.uppercased()
        return self.supportedCurrencyCodes.contains(code) ? code : nil
    }

    static func currency(_ word: String) -> Unit? {
        guard let code = self.currencyCode(word) else { return nil }
        let symbols = ["USD": "$", "EUR": "€", "RUB": "₽", "GBP": "£", "JPY": "¥", "KZT": "₸", "UAH": "₴", "TRY": "₺", "INR": "₹", "ILS": "₪", "KRW": "₩", "GEL": "₾", "AZN": "₼", "AMD": "֏", "VND": "₫", "THB": "฿", "PHP": "₱", "NGN": "₦"]
        let label = self.currencyAliases[word] != nil ? symbols[code] ?? code : code
        return Unit(code: code, english: label, russian: label, kind: .currency, scale: 1, offset: 0, counterpart: nil)
    }

    static func currencySymbol(_ character: Character) -> Unit? {
        guard "$€₽£¥₸₴₺₹₪₩₾₼֏₫฿₱₦₿".contains(character) else { return nil }
        return self.currency(String(character))
    }

    static func implicitTarget(_ unit: Unit, value: Double, imperial: Bool, localCurrency: String) -> Unit? {
        if unit.kind == .currency {
            let code = unit.code == localCurrency ? "USD" : localCurrency
            return code == unit.code ? nil : self.currency(code)
        }
        let ladders: [(Bool, [String])] = [
            (false, ["mm", "cm", "m", "km"]), (false, ["mg", "g", "kg", "t"]),
            (false, ["ml", "l"]), (false, ["m2", "ha", "km2"]),
            (true, ["in", "ft", "mi"]), (true, ["oz", "lb"]),
            (true, ["floz", "gal"]), (true, ["ft2", "acre", "mi2"])
        ]
        if let ladder = ladders.first(where: { $0.0 == imperial && $0.1.contains(unit.code) }) {
            let base = abs(value * unit.scale)
            for code in ladder.1.reversed() {
                if let target = self.catalog.units[code], code != unit.code, base / target.scale >= 0.1, base / target.scale < 1000 { return target }
            }
            if let index = ladder.1.firstIndex(of: unit.code), index > 0, let smaller = self.catalog.units[ladder.1[index - 1]], base / smaller.scale >= 1, base / smaller.scale < 100000 { return smaller }
        }
        return unit.counterpart.flatMap { self.catalog.units[$0] }
    }

    static func duration(_ seconds: Double, options: ExteraMathEngine.Options, russian: Bool) -> String? {
        guard seconds.isFinite, abs(seconds) < 1e12 else { return nil }
        var remaining = abs(seconds)
        var parts: [String] = []
        if remaining >= 60 { remaining = floor(remaining + 0.5) }
        var plain = options
        plain.grouping = false
        for code in ["d", "h", "min", "s"] {
            guard let unit = self.catalog.units[code] else { return nil }
            let amount = code == "s" ? remaining : floor(remaining / unit.scale)
            if amount > 0 || code == "s" && parts.isEmpty() {
                guard let value = ExteraMathEngine.format(amount, options: plain) else { return nil }
                parts.append(value + "\u{00a0}" + unit.label(russian))
                remaining -= amount * unit.scale
            }
        }
        return (seconds < 0 ? "-" : "") + parts.joined(separator: " ")
    }

    static func money(_ value: Double, code: String, options: ExteraMathEngine.Options) -> String? {
        guard value.isFinite, abs(value) < 1e12, value == 0 || abs(value) >= 1e-9 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        let digits = formatter.maximumFractionDigits
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = ["BTC", "ETH", "SOL", "USDT", "GRAM"].contains(code) ? 8 : digits
        formatter.roundingMode = .halfUp
        if value != 0 && abs(value) < 0.5 * pow(10, -Double(formatter.maximumFractionDigits)) {
            formatter.usesSignificantDigits = true
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 6
        }
        formatter.usesGroupingSeparator = options.grouping
        formatter.groupingSeparator = "\u{00a0}"
        formatter.groupingSize = 3
        formatter.decimalSeparator = options.decimalSeparator
        guard let text = formatter.string(from: NSNumber(value: value == 0 ? 0 : value)), text.count <= 24 else { return nil }
        return text
    }

    static func measureNumber(_ value: Double, options: ExteraMathEngine.Options) -> String? {
        guard value.isFinite, abs(value) < 1e12, value == 0 || abs(value) >= 1e-9 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.roundingMode = .halfUp
        formatter.minimumFractionDigits = 0
        if abs(value) >= 1 {
            formatter.maximumFractionDigits = 2
        } else {
            formatter.usesSignificantDigits = true
            formatter.minimumSignificantDigits = 1
            formatter.maximumSignificantDigits = 3
        }
        formatter.usesGroupingSeparator = options.grouping
        formatter.groupingSeparator = "\u{00a0}"
        formatter.groupingSize = 3
        formatter.decimalSeparator = options.decimalSeparator
        guard let text = formatter.string(from: NSNumber(value: value == 0 ? 0 : value)), text.count <= 24 else { return nil }
        return text
    }
}
