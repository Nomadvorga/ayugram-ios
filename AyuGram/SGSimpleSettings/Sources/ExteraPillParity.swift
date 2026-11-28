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
    public static let fiat: [String] = ["AED", "AFN", "ALL", "AMD", "AOA", "ARS", "AUD", "AWG", "AZN", "BAM", "BBD", "BDT", "BHD", "BIF", "BMD", "BND", "BOB", "BRL", "BSD", "BTN", "BWP", "BYN", "BZD", "CAD", "CDF", "CHF", "CLP", "CNY", "COP", "CRC", "CUP", "CVE", "CZK", "DJF", "DKK", "DOP", "DZD", "EGP", "ETB", "EUR", "FJD", "FKP", "GBP", "GEL", "GHS", "GIP", "GMD", "GNF", "GTQ", "GYD", "HKD", "HNL", "HTG", "HUF", "IDR", "ILS", "INR", "IQD", "IRR", "ISK", "JMD", "JOD", "JPY", "KES", "KGS", "KHR", "KMF", "KRW", "KWD", "KYD", "KZT", "LAK", "LBP", "LKR", "LRD", "LSL", "LYD", "MAD", "MDL", "MGA", "MKD", "MMK", "MNT", "MOP", "MRU", "MUR", "MVR", "MWK", "MXN", "MYR", "MZN", "NAD", "NGN", "NIO", "NOK", "NPR", "NZD", "OMR", "PAB", "PEN", "PGK", "PHP", "PKR", "PLN", "PYG", "QAR", "RON", "RSD", "RUB", "RWF", "SAR", "SBD", "SCR", "SDG", "SEK", "SGD", "SHP", "SOS", "SRD", "SSP", "SYP", "SZL", "THB", "TJS", "TMT", "TND", "TOP", "TRY", "TTD", "TWD", "TZS", "UAH", "UGX", "USD", "UYU", "UZS", "VES", "VND", "VUV", "WST", "XAF", "XCD", "XOF", "XPF", "YER", "ZAR", "ZMW"]
    private static let countries: [String: [String]] = ["971":["AE"],"355":["AL"],"374":["AM"],"54":["AR"],"43":["AT"],"61":["AU"],"880":["BD"],"32":["BE"],"359":["BG"],"973":["BH"],"591":["BO"],"55":["BR"],"375":["BY"],"41":["CH"],"225":["CI"],"56":["CL"],"86":["CN"],"57":["CO"],"506":["CR"],"53":["CU"],"357":["CY"],"420":["CZ"],"49":["DE"],"45":["DK"],"213":["DZ"],"372":["EE"],"20":["EG"],"34":["ES"],"358":["FI"],"33":["FR"],"590":["GP"],"594":["GF","GF"],"596":["MQ"],"262":["RE"],"377":["MC"],"689":["PF"],"44":["GB","UK"],"240":["GQ"],"30":["GR"],"502":["GT"],"245":["GW"],"592":["GY"],"852":["HK"],"504":["HN"],"385":["HR"],"36":["HU"],"62":["ID"],"353":["IE"],"972":["IL"],"91":["IN","IN"],"964":["IQ"],"98":["IR"],"354":["IS"],"39":["IT"],"81":["JA","JP"],"962":["JO"],"254":["KE"],"82":["KR"],"965":["KW"],"961":["LB"],"423":["LI"],"94":["LK"],"231":["LR"],"370":["LT"],"352":["LU"],"371":["LV"],"218":["LY"],"212":["MA"],"373":["MD"],"382":["ME"],"261":["MG"],"389":["MK"],"223":["ML"],"853":["MO"],"356":["MT"],"265":["MW"],"52":["MX"],"60":["MY"],"227":["NE"],"234":["NG"],"31":["NL"],"47":["NO"],"64":["NZ"],"968":["OM"],"507":["PA"],"51":["PE"],"63":["PH"],"92":["PK"],"48":["PL"],"351":["PT"],"974":["QA"],"40":["RO"],"7":["RU","KZ"],"966":["SA"],"249":["SD"],"46":["SE"],"65":["SG"],"386":["SI"],"421":["SK"],"503":["SV"],"963":["SY"],"66":["TH"],"216":["TN"],"90":["TR"],"886":["TW"],"255":["TZ"],"380":["UA"],"256":["UG"],"299":["GL"],"27":["ZA"],"593":["EC"],"595":["PY"],"58":["VE"],"505":["NI"],"267":["BW"],"237":["CM"],"236":["CF"],"224":["GN"],"230":["MU"],"221":["SN"],"993":["TM"],"239":["ST"],"93":["AF"],"95":["MM"],"998":["UZ"],"257":["BI"],"268":["SZ"],"238":["CV"],"247":["AC"],"672":["AQ"],"686":["KI"],"378":["SM"],"266":["LS"],"683":["NU"],"994":["AZ"],"222":["MR"],"242":["CG"],"248":["SC"],"856":["LA"],"253":["DJ"],"232":["SL"],"252":["SO"],"678":["VU"],"290":["SH"],"509":["HT"],"688":["TV"],"220":["GM"],"264":["NA"],"599":["AN"],"685":["WS"],"597":["SR"],"297":["AW"],"269":["KM"],"387":["BA"],"243":["CD"],"855":["KH"],"263":["ZW"],"241":["GA"],"682":["CK"],"680":["PW"],"500":["FK"],"960":["MV"],"508":["PM"],"226":["BF"],"681":["WF"],"975":["BT"],"679":["FJ"],"291":["ER"],"850":["KP"],"376":["AD"],"970":["PS"],"350":["GI"],"977":["NP"],"228":["TG"],"251":["ET"],"992":["TJ"],"996":["KG"],"233":["GH"],"260":["ZM"],"674":["NR"],"692":["MH"],"687":["NC"],"677":["SB"],"250":["RW"],"675":["PG"],"235":["TD"],"258":["MZ"],"690":["TK"],"976":["MN"],"229":["BJ"],"298":["FO"],"501":["BZ"],"995":["GE"],"246":["IO"],"691":["FM"],"673":["BN"],"244":["AO"],"676":["TO"],"381":["RS"],"1":["US","AG","AI","AS","BB","BM","BS","CA","DM","DO","GD","GU","JM","KN","KY","LC","MP","MS","PR","SX","TC","TT","VC","VG","VI"],"598":["UY"],"379":["VA"],"84":["VN"],"800":["XT"],"967":["YE"],"888":["FT"]]
    private static let exponents: [String: Int] = ["AED":2,"AFN":2,"ALL":2,"AMD":2,"AOA":0,"ARS":2,"AUD":2,"AWG":0,"AZN":2,"BAM":2,"BBD":0,"BDT":2,"BHD":3,"BIF":0,"BMD":0,"BND":2,"BOB":2,"BRL":2,"BSD":0,"BTN":0,"BWP":0,"BYN":2,"BZD":0,"CAD":2,"CDF":0,"CHF":2,"CLP":0,"CNY":2,"COP":2,"CRC":2,"CUP":0,"CVE":0,"CZK":2,"DJF":0,"DKK":2,"DOP":2,"DZD":2,"EGP":2,"ETB":2,"EUR":2,"FJD":0,"FKP":0,"GBP":2,"GEL":2,"GHS":2,"GIP":0,"GMD":0,"GNF":0,"GTQ":2,"GYD":0,"HKD":2,"HNL":2,"HTG":0,"HUF":2,"IDR":2,"ILS":2,"INR":2,"IQD":3,"IRR":2,"ISK":0,"JMD":2,"JOD":3,"JPY":0,"KES":2,"KGS":2,"KHR":0,"KMF":0,"KRW":0,"KWD":0,"KYD":0,"KZT":2,"LAK":0,"LBP":2,"LKR":2,"LRD":0,"LSL":0,"LYD":0,"MAD":2,"MDL":2,"MGA":0,"MKD":0,"MMK":2,"MNT":2,"MOP":2,"MRU":0,"MUR":2,"MVR":2,"MWK":0,"MXN":2,"MYR":2,"MZN":2,"NAD":0,"NGN":2,"NIO":2,"NOK":2,"NPR":2,"NZD":2,"OMR":0,"PAB":2,"PEN":2,"PGK":0,"PHP":2,"PKR":2,"PLN":2,"PYG":0,"QAR":2,"RON":2,"RSD":2,"RUB":2,"RWF":0,"SAR":2,"SBD":0,"SCR":0,"SDG":0,"SEK":2,"SGD":2,"SHP":0,"SOS":0,"SRD":0,"SSP":0,"SYP":2,"SZL":0,"THB":2,"TJS":2,"TMT":0,"TND":0,"TOP":0,"TRY":2,"TTD":2,"TWD":2,"TZS":2,"UAH":2,"UGX":0,"USD":2,"UYU":2,"UZS":2,"VES":0,"VND":0,"VUV":0,"WST":0,"XAF":0,"XCD":0,"XOF":0,"XPF":0,"YER":2,"ZAR":2,"ZMW":0]
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
        // Coinbase rates are currency units per USD. The APK first converts
        // each to USD per unit at scale 16, then divides at scale 12.
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

public struct ExteraPillCacheUsageSnapshot: Equatable {
    public let resourceBytes: Int64
    public let cacheBytes: Int64
    public let temporaryBytes: Int64

    public init(resourceBytes: Int64, cacheBytes: Int64, temporaryBytes: Int64) {
        self.resourceBytes = resourceBytes
        self.cacheBytes = cacheBytes
        self.temporaryBytes = temporaryBytes
    }
}

public enum ExteraPillCacheAccounting {
    /// Resource and media-cache bytes are account-scoped; the engine's iOS
    /// temporary-directory scan is process-shared and therefore counted once.
    public static func totalBytes(_ snapshots: [ExteraPillCacheUsageSnapshot]) -> Int64 {
        var total: Int64 = 0
        var sharedTemporaryBytes: Int64 = 0
        func append(_ value: Int64) {
            let addition = total.addingReportingOverflow(max(0, value))
            total = addition.overflow ? Int64.max : addition.partialValue
        }
        for snapshot in snapshots {
            append(snapshot.resourceBytes)
            append(snapshot.cacheBytes)
            sharedTemporaryBytes = max(sharedTemporaryBytes, max(0, snapshot.temporaryBytes))
        }
        append(sharedTemporaryBytes)
        return total
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
