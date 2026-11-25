import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class ExteraMathRatesURLProtocol: URLProtocol, @unchecked Sendable {
    static var onStart: ((ExteraMathRatesURLProtocol) -> Void)?
    static var onStop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }
    override func startLoading() { Self.onStart?(self) }
    override func stopLoading() { Self.onStop?() }

    func respond(status: Int = 200, data: Data) {
        let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }
}

// Compile together with the production engine; see README.md for the macOS command.
final class ExteraMathEngineTests: XCTestCase {
    private let plain = ExteraMathEngine.Options(grouping: false)

    func testPrecedenceAndUnary() {
        let cases: [(String, String)] = [
            ("(120 + 80) / 4", "50"), ("1+2*3", "7"),
            ("100/10/2", "5"), ("2^3^2", "512"),
            ("-2^2", "-4"), ("(-2)^2", "4"), ("2^-1+3", "3.5"),
            ("√144 + 2^3", "20"), ("3 × (4 − 2) ÷ 2", "3"),
            ("1e3 / 4", "250"), ("300k / 12", "25000")
        ]
        for (expression, expected) in cases {
            XCTAssertEqual(ExteraMathEngine.evaluate(expression, options: self.plain)?.formatted, expected, expression)
        }
    }

    func testRelativePercentages() {
        let cases: [(String, String)] = [
            ("2300 - 15%", "1955"), ("200 + 10%", "220"),
            ("200 * 10%", "20"), ("200 / 10%", "2000"),
            ("12% of 1200", "144"), ("12% от 1200", "144"),
            ("200 + (10%)", "200.1"), ("50%", "0.5")
        ]
        for (expression, expected) in cases {
            XCTAssertEqual(ExteraMathEngine.evaluate(expression, options: self.plain)?.formatted, expected, expression)
        }
    }

    func testFunctionsAndAngleUnit() {
        XCTAssertEqual(ExteraMathEngine.evaluate("max(12, 40, 7)", options: self.plain)?.formatted, "40")
        XCTAssertEqual(ExteraMathEngine.evaluate("min(12;40;7)", options: self.plain)?.formatted, "7")
        XCTAssertEqual(ExteraMathEngine.evaluate("sin(30)", options: self.plain)?.formatted, "0.5")
        XCTAssertEqual(ExteraMathEngine.evaluate("asin(0.5)", options: self.plain)?.formatted, "30")
        XCTAssertEqual(ExteraMathEngine.evaluate("sin(pi/2)", options: .init(degrees: false, grouping: false))?.formatted, "1")
        XCTAssertEqual(ExteraMathEngine.evaluate("5!", options: self.plain)?.formatted, "120")
        XCTAssertEqual(ExteraMathEngine.evaluate("round(-1.5)", options: self.plain)?.formatted, "-1")
        XCTAssertEqual(ExteraMathEngine.evaluate("log(100) + abs(-2)", options: self.plain)?.formatted, "4")
    }

    func testFormatting() {
        XCTAssertEqual(ExteraMathEngine.evaluate("0.1 + 0.2", options: self.plain)?.formatted, "0.3")
        XCTAssertEqual(ExteraMathEngine.evaluate("1/3", options: self.plain)?.formatted, "0.333333333333")
        XCTAssertEqual(ExteraMathEngine.evaluate("1000+2000")?.formatted, "3\u{00a0}000")
        XCTAssertEqual(ExteraMathEngine.evaluate("3\u{00a0}000*2", options: self.plain)?.formatted, "6000")
        XCTAssertEqual(ExteraMathEngine.evaluate("1\u{202f}000\u{202f}000/2", options: self.plain)?.formatted, "500000")
        XCTAssertEqual(ExteraMathEngine.evaluate("1,5+2", options: .init(grouping: false, decimalSeparator: ","))?.formatted, "3,5")
        XCTAssertEqual(ExteraMathEngine.evaluate("-0", options: self.plain)?.formatted, "0")
    }

    func testMalformedAndBoundedInput() {
        for expression in ["", "2+", "(1+2", "1/0", "sqrt(-1)", "tan(90)", "171!", "(-1)!", "2(3)", "min()", "sin(1;2)", "unknown(2)", "1.2.3", "1e999", "10^12", "10^-10", "1;2", "2 + hello", "1 2+3", "1\u{00a0}23+4"] {
            XCTAssertNil(ExteraMathEngine.evaluate(expression), expression)
        }
        XCTAssertNil(ExteraMathEngine.evaluate(String(repeating: "(", count: 40) + "1+2" + String(repeating: ")", count: 40)))
        XCTAssertNil(ExteraMathEngine.evaluate(String(repeating: "1+", count: 300) + "1"))
    }

    func testSuggestionAndUTF16Caret() {
        let text = "😀 notes\n(120+80)/4 ="
        let suggestion = ExteraMathEngine.suggestion(in: text, caret: (text as NSString).length, options: self.plain)
        XCTAssertEqual(suggestion?.value, "50")
        XCTAssertEqual(suggestion?.insertAt, (text as NSString).length)
        XCTAssertEqual(suggestion?.insertText, " 50")
        for text in ["42=", "hello 2+2=", "@bot 2+2=", "2+=", "12/03/2026=", "2026-11-25=", "2+2 = 4"] {
            XCTAssertNil(ExteraMathEngine.suggestion(in: text, caret: (text as NSString).length, options: self.plain), text)
        }
        XCTAssertNil(ExteraMathEngine.suggestion(in: "2+2= 4", caret: 4, options: self.plain))
        XCTAssertNil(ExteraMathEngine.suggestion(in: "2+2=", caret: 100, options: self.plain))
        XCTAssertEqual(ExteraMathEngine.suggestion(in: "2+2=\nnext", caret: 4, options: self.plain)?.value, "4")
    }

    func testBaseConversionAndExactIntegerLimit() {
        for (expression, expected) in [("hex(255)", "0xFF"), ("bin(10)", "0b1010"), ("oct(64)", "0o100"), ("dec(ff, 16)", "255"), ("dec(ff,16)", "255"), ("dec(0xff)", "255"), ("dec(z;36)", "35"), ("0xff + 1", "256"), ("0b1010 + 0o10", "18"), ("255 to hex", "0xFF"), ("hex(-255)", "-0xFF"), ("hex(9007199254740991)", "0x1FFFFFFFFFFFFF"), ("2³ + 2⁻¹", "8.5")] {
            XCTAssertEqual(ExteraMathEngine.evaluate(expression, options: self.plain)?.formatted, expected, expression)
        }
        for expression in ["hex(1.5)", "hex(9007199254740992)", "0x20000000000000", "0b102", "dec(z;35)", "dec(ff;1)", "dec(ff;37)", "1+hex(2)", "hex(2)+1", "0xffffffffffffffffffffffff", "2⁻"] {
            XCTAssertNil(ExteraMathEngine.evaluate(expression, options: self.plain), expression)
        }
    }

    func testUnitsTemperatureAndDimensionRules() {
        XCTAssertEqual(ExteraMathUnits.measure("фунтах")?.code, "lb")
        XCTAssertEqual(ExteraMathUnits.measure("футах")?.code, "ft")
        XCTAssertEqual(ExteraMathEngine.evaluate("1 m в футах", options: self.plain)?.formatted, "3.28\u{00a0}ft")
        for (expression, expected) in [("5 kg to lb", "11.02\u{00a0}lb"), ("100 km/h to mph", "62.14\u{00a0}mph"), ("1 gal to l", "3.79\u{00a0}l"), ("1 fl oz to ml", "29.57\u{00a0}ml"), ("1 m² to ft2", "10.76\u{00a0}ft²"), ("32°F to °C", "0\u{00a0}°C"), ("0°C to kelvin", "273.15\u{00a0}K"), ("-40 °C to °F", "-40\u{00a0}°F"), ("1 km + 500 m", "1.5\u{00a0}km"), ("5 kg * 2", "10\u{00a0}kg"), ("5 kg / 500 g", "10"), ("5 кг в фунтах", "11.02\u{00a0}lb"), ("200 kg + 10%", "220\u{00a0}kg"), ("12% of 10 kg", "1.2\u{00a0}kg")] {
            XCTAssertEqual(ExteraMathEngine.evaluate(expression, options: self.plain)?.formatted, expected, expression)
        }
        XCTAssertEqual(ExteraMathEngine.evaluate("72°F", options: self.plain)?.unit, "C")
        XCTAssertEqual(ExteraMathEngine.evaluate("10 miles", options: self.plain)?.formatted, "16.09\u{00a0}km")
        XCTAssertEqual(ExteraMathEngine.evaluate("1000 m", options: self.plain)?.formatted, "1\u{00a0}km")
        XCTAssertEqual(ExteraMathEngine.evaluate("5 kg", options: .init(grouping: false, imperial: true))?.unit, "lb")
        XCTAssertEqual(ExteraMathEngine.evaluate("1 000 m to km", options: self.plain)?.formatted, "1\u{00a0}km")
        XCTAssertNil(ExteraMathEngine.evaluate("1,000 m to km", options: self.plain))
        for expression in ["1 kg to m", "1 m + 1 s", "1 m * 1 m", "2 / 1 m", "sqrt(4 kg)", "sin(30 m)", "1 kg ^ 2", "1 kg%", "1 kg!"] {
            XCTAssertNil(ExteraMathEngine.evaluate(expression), expression)
        }
    }

    func testDurationBreakdownAndExplicitTargets() {
        for (expression, expected) in [("90 min", "1\u{00a0}h 30\u{00a0}min"), ("2 h + 45 min", "2\u{00a0}h 45\u{00a0}min"), ("-90 min", "-1\u{00a0}h 30\u{00a0}min"), ("90 min to h", "1.5\u{00a0}h"), ("2 weeks to d", "14\u{00a0}d"), ("1 month to d", "30\u{00a0}d"), ("1 year to d", "365\u{00a0}d"), ("90 мин", "1\u{00a0}ч 30\u{00a0}мин"), ("1000 ms to s", "1\u{00a0}s")] {
            XCTAssertEqual(ExteraMathEngine.evaluate(expression, options: self.plain)?.formatted, expected, expression)
        }
    }

    func testCurrencyRatesCrossRatesExpiryAndPendingResults() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ExteraMathCurrencySnapshot(date: now, unitsPerUSD: ["EUR": 0.8, "RUB": 100, "JPY": 150, "BTC": 0.00002, "TON": 0.25, "BAD": 4, "GBP": -.infinity])
        var options = ExteraMathEngine.Options(grouping: false, localCurrency: "RUB", now: now, currencyRates: snapshot)
        XCTAssertEqual(snapshot.rate(from: "EUR", to: "RUB", now: now), 125)
        XCTAssertEqual(snapshot.rate(from: "GRAM", to: "USD", now: now), 4)
        XCTAssertNil(snapshot.unitsPerUSD["BAD"])
        XCTAssertNil(snapshot.unitsPerUSD["GBP"])
        for (expression, expected) in [("100 dollars to euros", "80\u{00a0}€"), ("100€", "12500\u{00a0}RUB"), ("5k ₽ to $", "50\u{00a0}$"), ("$5k to EUR", "4000\u{00a0}EUR"), ("50$ to GRAM", "12.5\u{00a0}GRAM"), ("1 USD to JPY", "150\u{00a0}JPY"), ("1 USD + 1 EUR", "2.25\u{00a0}USD"), ("5000 рублей в доллары", "50\u{00a0}$"), ("5k ₽", "50\u{00a0}USD")] {
            XCTAssertEqual(ExteraMathEngine.evaluate(expression, options: options)?.formatted, expected, expression)
        }
        options.now = now.addingTimeInterval(86401)
        XCTAssertNil(ExteraMathEngine.evaluate("100 USD to EUR", options: options))
        let pending = ExteraMathEngine.suggestion(in: "100 USD to EUR=", caret: 15, options: options)
        XCTAssertEqual(pending?.isPendingCurrency, true)
        XCTAssertEqual(pending?.insertText, "")
        XCTAssertNil(ExteraMathEngine.suggestion(in: "100 USD to kg=", caret: 14, options: options))
        XCTAssertNil(ExteraMathEngine.evaluate("500 stars to USD", options: options))
        XCTAssertNil(snapshot.rate(from: "USD", to: "EUR", now: now.addingTimeInterval(-301)))
    }

    func testCurrencyResponseValidation() {
        let now = Date()
        let payload = #"{"data":{"currency":"USD","rates":{"EUR":"0.8","RUB":"100","JPY":"NaN","GBP":"0","TON":"0.25"}}}"#.data(using: .utf8)!
        let snapshot = ExteraMathCurrencySnapshot.parse(payload, date: now)
        XCTAssertEqual(snapshot?.rate(from: "EUR", to: "RUB", now: now), 125)
        XCTAssertEqual(snapshot?.unitsPerUSD["GRAM"], 0.25)
        XCTAssertNil(snapshot?.unitsPerUSD["JPY"])
        XCTAssertNil(snapshot?.unitsPerUSD["GBP"])
        for payload in [#"{"data":{"currency":"EUR","rates":{"USD":"1"}}}"#, #"{"data":{"currency":"USD","rates":{}}}"#, "null", "not json"] {
            XCTAssertNil(ExteraMathCurrencySnapshot.parse(payload.data(using: .utf8)!, date: now))
        }
        XCTAssertNil(ExteraMathCurrencySnapshot.parse(Data(repeating: 32, count: 1_048_577), date: now))
    }

    func testCurrencyRequestUsesPublicEndpointAndDeliversRealResponse() {
        let delivered = self.expectation(description: "Validated snapshot delivered on main queue")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExteraMathRatesURLProtocol.self]
        ExteraMathRatesURLProtocol.onStop = nil
        ExteraMathRatesURLProtocol.onStart = { mock in
            XCTAssertEqual(mock.request.url?.absoluteString, "https://api.coinbase.com/v2/exchange-rates?currency=USD")
            XCTAssertNil(mock.request.httpBody)
            mock.respond(data: #"{"data":{"currency":"USD","rates":{"EUR":"0.8","RUB":"100"}}}"#.data(using: .utf8)!)
        }
        let request = ExteraMathCurrencyRequest(configuration: configuration) { snapshot in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(snapshot?.rate(from: "EUR", to: "RUB"), 125)
            delivered.fulfill()
        }
        self.wait(for: [delivered], timeout: 3)
        request.cancel()
        ExteraMathRatesURLProtocol.onStart = nil
    }

    func testCurrencyRequestCancellationStopsTransportAndSuppressesDelivery() {
        let started = self.expectation(description: "Transport started")
        let stopped = self.expectation(description: "Transport cancelled")
        let delivered = self.expectation(description: "Cancelled request cannot deliver")
        delivered.isInverted = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExteraMathRatesURLProtocol.self]
        ExteraMathRatesURLProtocol.onStart = { _ in started.fulfill() }
        ExteraMathRatesURLProtocol.onStop = { stopped.fulfill() }
        let request = ExteraMathCurrencyRequest(configuration: configuration) { _ in delivered.fulfill() }
        self.wait(for: [started], timeout: 3)
        request.cancel()
        self.wait(for: [stopped], timeout: 3)
        self.wait(for: [delivered], timeout: 0.1)
        ExteraMathRatesURLProtocol.onStart = nil
        ExteraMathRatesURLProtocol.onStop = nil
    }

    func testTimeZonesDSTOffsetsMeridiemsAndDayShift() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let winter = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!
        let summer = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!
        for (expression, expected) in [("18:00 utc to tokyo", "03:00 (+1)"), ("18:00 utc", "18:00"), ("12:00 in tokyo", "21:00"), ("6pm est", "11:00 pm"), ("12am", "00:00"), ("12pm", "12:00"), ("now in new york", "07:00"), ("12:00 utc+05:30 to utc", "06:30"), ("12:00 msk-1 to utc", "10:00"), ("12:00 в токио", "21:00"), ("12:00 по москве в токио", "18:00")] {
            // A same-zone conversion is suppressed, as on Android.
            let value = ExteraMathTimeZones.convert(expression, local: utc, now: winter)
            XCTAssertEqual(value, expression == "18:00 utc" ? nil : expected, expression)
        }
        XCTAssertEqual(ExteraMathTimeZones.convert("6pm est", local: utc, now: summer), "10:00 pm")
        for expression in ["25:00 utc", "12:60 utc", "13pm est", "now utc", "now in unknown", "12:00 utc+18:01", "@bot 12:00 in tokyo", "hello 12:00 utc", "12:00"] {
            XCTAssertNil(ExteraMathTimeZones.convert(expression, local: utc, now: winter), expression)
        }
    }

    func testConversionSuggestionsAndIndependentOptions() {
        for text in ["hex(255)=", "5 kg to lb=", "90 min=", "12:00 in tokyo="] {
            XCTAssertNotNil(ExteraMathEngine.suggestion(in: text, caret: (text as NSString).length, options: self.plain), text)
        }
        XCTAssertNil(ExteraMathEngine.suggestion(in: "5 kg to lb=", caret: 11, options: .init(units: false)))
        XCTAssertNil(ExteraMathEngine.suggestion(in: "100€=", caret: 5, options: .init(currencies: false)))
        XCTAssertNil(ExteraMathEngine.suggestion(in: "12:00 in tokyo=", caret: 15, options: .init(timeZones: false)))
        XCTAssertNil(ExteraMathEngine.suggestion(in: "2+2=", caret: 4, options: .init(arithmetic: false)))
        XCTAssertNotNil(ExteraMathEngine.suggestion(in: "90 min=", caret: 7, options: .init(arithmetic: false)))
    }

    static var allTests: [(String, (ExteraMathEngineTests) -> () throws -> Void)] {
        return [
            ("testPrecedenceAndUnary", testPrecedenceAndUnary),
            ("testRelativePercentages", testRelativePercentages),
            ("testFunctionsAndAngleUnit", testFunctionsAndAngleUnit),
            ("testFormatting", testFormatting),
            ("testMalformedAndBoundedInput", testMalformedAndBoundedInput),
            ("testSuggestionAndUTF16Caret", testSuggestionAndUTF16Caret),
            ("testBaseConversionAndExactIntegerLimit", testBaseConversionAndExactIntegerLimit),
            ("testUnitsTemperatureAndDimensionRules", testUnitsTemperatureAndDimensionRules),
            ("testDurationBreakdownAndExplicitTargets", testDurationBreakdownAndExplicitTargets),
            ("testCurrencyRatesCrossRatesExpiryAndPendingResults", testCurrencyRatesCrossRatesExpiryAndPendingResults),
            ("testCurrencyResponseValidation", testCurrencyResponseValidation),
            ("testCurrencyRequestUsesPublicEndpointAndDeliversRealResponse", testCurrencyRequestUsesPublicEndpointAndDeliversRealResponse),
            ("testCurrencyRequestCancellationStopsTransportAndSuppressesDelivery", testCurrencyRequestCancellationStopsTransportAndSuppressesDelivery),
            ("testTimeZonesDSTOffsetsMeridiemsAndDayShift", testTimeZonesDSTOffsetsMeridiemsAndDayShift),
            ("testConversionSuggestionsAndIndependentOptions", testConversionSuggestionsAndIndependentOptions),
        ]
    }
}

#if !SWIFT_PACKAGE
@main
enum ExteraMathTestRunner {
    static func main() {
        XCTMain([testCase(ExteraMathEngineTests.allTests)])
    }
}
#endif
