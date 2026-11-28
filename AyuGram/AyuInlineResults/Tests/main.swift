// Host check for the inline results engine. Not part of the app:
//   swiftc -o /tmp/ayu-inline-tests AyuGram/AyuInlineResults/Sources/*.swift AyuGram/AyuInlineResults/Tests/*.swift && /tmp/ayu-inline-tests

import Foundation

var passed = 0
var failures: [String] = []

func check(_ label: String, _ expected: String?, _ actual: String?) {
    if expected == actual {
        passed += 1
    } else {
        failures.append("\(label)\n      expected: \(expected ?? "<none>")\n      actual:   \(actual ?? "<none>")")
    }
}

func runFormatTests() {
    let nbsp = "\u{00A0}"
    check("format 4", "4", MathFormat.format(4.0, decimalSeparator: "."))
    check("format 0.1+0.2", "0.3", MathFormat.format(0.1 + 0.2, decimalSeparator: "."))
    check("format 1/3", "0.333333333333", MathFormat.format(1.0 / 3.0, decimalSeparator: "."))
    check("format 2/3 comma", "0,666666666667", MathFormat.format(2.0 / 3.0, decimalSeparator: ","))
    check("format -0", "0", MathFormat.format(-0.0, decimalSeparator: "."))
    check("format 1e-5", "0.00001", MathFormat.format(1e-5, decimalSeparator: "."))
    check("format 1e-10", nil, MathFormat.format(1e-10, decimalSeparator: "."))
    check("format 1e12", nil, MathFormat.format(1e12, decimalSeparator: "."))
    check("format 999999999999", "999999999999", MathFormat.format(999999999999.0, decimalSeparator: "."))
    check("format grouped", "1\(nbsp)234\(nbsp)567.891", MathFormat.format(1234567.891, decimalSeparator: ".", grouping: true))
    check("format grouped negative", "-12\(nbsp)345", MathFormat.format(-12345.0, decimalSeparator: ".", grouping: true))
    check("format 123456789012.6", "123456789013", MathFormat.format(123456789012.6, decimalSeparator: "."))
    check("format nan", nil, MathFormat.format(Double.nan, decimalSeparator: "."))

    check("money 12.5", "12.50", MathFormat.formatMoney(12.5, fractionDigits: 2, decimalSeparator: ".", grouping: false))
    check("money 12", "12", MathFormat.formatMoney(12.0, fractionDigits: 2, decimalSeparator: ".", grouping: false))
    check("money 12.345", "12.35", MathFormat.formatMoney(12.345, fractionDigits: 2, decimalSeparator: ".", grouping: false))
    check("money -12.345", "-12.35", MathFormat.formatMoney(-12.345, fractionDigits: 2, decimalSeparator: ".", grouping: false))
    check("money 0.001234", "0.001234", MathFormat.formatMoney(0.001234, fractionDigits: 2, decimalSeparator: ".", grouping: false))
    check("money 0.0012345678", "0.00123457", MathFormat.formatMoney(0.0012345678, fractionDigits: 2, decimalSeparator: ".", grouping: false))
    check("money 0", "0", MathFormat.formatMoney(0.0, fractionDigits: 2, decimalSeparator: ".", grouping: false))
    check("money grouped", "1\(nbsp)234\(nbsp)567,80", MathFormat.formatMoney(1234567.8, fractionDigits: 2, decimalSeparator: ","))
    check("money 0 digits", "1235", MathFormat.formatMoney(1234.5, fractionDigits: 0, decimalSeparator: ".", grouping: false))
    check("money any digits", "1234.5", MathFormat.formatMoney(1234.5, fractionDigits: -1, decimalSeparator: ".", grouping: false))
    check("money any digits long", "1234568", MathFormat.formatMoney(1234567.891, fractionDigits: -1, decimalSeparator: ".", grouping: false))

    check("measure 3.14159", "3.14", MathFormat.formatMeasure(3.14159, decimalSeparator: ".", grouping: false))
    check("measure 0.012345", "0.0123", MathFormat.formatMeasure(0.012345, decimalSeparator: ".", grouping: false))
    check("measure 16.0934", "16.09", MathFormat.formatMeasure(16.0934, decimalSeparator: ".", grouping: false))
    check("measure 100", "100", MathFormat.formatMeasure(100.0, decimalSeparator: ".", grouping: false))

    check("base hex", "0xFF", MathFormat.formatBase(255.0, radix: 16))
    check("base bin negative", "-0b101", MathFormat.formatBase(-5.0, radix: 2))
    check("base 36", "ZZ", MathFormat.formatBase(1295.0, radix: 36))
    check("base fraction", nil, MathFormat.formatBase(1.5, radix: 16))
}

func runOperatorTests() {
    check("5!", "120", MathOperators.postfixFor("!").flatMap { MathFormat.format($0.apply(5.0), decimalSeparator: ".") })
    check("171!", nil, MathOperators.postfixFor("!").flatMap { MathFormat.format($0.apply(171.0), decimalSeparator: ".") })
    check("round 2.5", "3", MathOperators.functionFor("round").flatMap { MathFormat.format($0.apply([2.5]), decimalSeparator: ".") })
    check("round -2.5", "-2", MathOperators.functionFor("round").flatMap { MathFormat.format($0.apply([-2.5]), decimalSeparator: ".") })
    check("max", "40", MathOperators.functionFor("max").flatMap { MathFormat.format($0.apply([12.0, 40.0, 7.0]), decimalSeparator: ".") })
    check("2300 - 15%", "1955", MathOperators.infixFor("-").flatMap { MathFormat.format($0.apply(2300.0, 0.15, true), decimalSeparator: ".") })
    check("symbol ×", "×", MathOperators.matchSymbol(mathCharacters("2×3"), at: 1))
    check("symbol none", nil, MathOperators.matchSymbol(mathCharacters("2a3"), at: 1))
    check("strip 0x", "ff", MathOperators.stripRadixPrefix("0xff", radix: 16))
    check("superscript is not a digit", "false", String(Character("²").isMathDigit))
    check("π is a letter", "true", String(Character("π").isMathLetter))
    check("symbol chars", "true", String(MathOperators.symbolChars.isSuperset(of: ["+", "−", "√", "%", "!", "(", ")", ";", "^"])))
}

// Helpers with the same shapes as the Kotlin ones in exteraGram's MathExpressionTests.kt, so that the
// generated Vectors.swift reads like the original.

var currentSection = ""

func section(_ name: String) {
    currentSection = name
}

func visible(_ text: String?) -> String? {
    return text?.replacingOccurrences(of: "\u{00A0}", with: " ")
}

func result(_ expression: String, _ separator: Character) -> String? {
    var options = MathOptions()
    options.decimalSeparator = separator
    options.grouping = false
    guard let evaluated = MathExpression.evaluate(expression, options: options), evaluated.hasOperation else {
        return nil
    }
    return MathExpression.format(evaluated)
}

func expr(_ expression: String, _ expected: String?, _ separator: Character = ".") {
    check("[\(currentSection)] evaluate(\"\(expression)\", '\(separator)')", expected, result(expression, separator))
}

func ghost(_ text: String, _ caret: Int, _ expected: String?, _ separator: Character = ".") {
    var options = MathOptions()
    options.decimalSeparator = separator
    options.grouping = false
    check("[\(currentSection)] suggestionAt(\"\(text)\", \(caret))", expected, MathExpression.suggestionAt(text, caret: caret, options: options)?.value)
}

func ghost(_ text: String, _ expected: String?, _ separator: Character = ".") {
    ghost(text, text.unicodeScalars.count, expected, separator)
}

func inserted(_ text: String, _ expected: String?) {
    var options = MathOptions()
    options.grouping = false
    check("[\(currentSection)] insertText(\"\(text)\")", expected, MathExpression.suggestionAt(text, caret: text.unicodeScalars.count, options: options)?.insertText)
}

final class FakeRates: CurrencyRates {
    private let usd: [String: Double]
    private let supported: Set<String>

    init(_ usd: [String: Double], _ supported: Set<String>) {
        self.usd = usd
        self.supported = supported
    }

    func supports(_ code: String) -> Bool {
        return self.supported.contains(code)
    }

    func rate(from: String, to: String) -> Double? {
        guard let fromUsd = self.usd[from], let toUsd = self.usd[to] else {
            return nil
        }
        return fromUsd / toUsd
    }
}

let usdRates: [String: Double] = [
    "USD": 1.0,
    "EUR": 1.25,
    "RUB": 0.0125,
    "JPY": 0.008,
    "TRY": 0.025,
    "KZT": 0.002,
    "VND": 0.00004,
    "BTC": 100000.0
]

let rates = FakeRates(usdRates, Set(usdRates.keys).union(["GBP"]))
let offline = FakeRates([:], Set(usdRates.keys))

let fullRates = FakeRates(
    ["USD": 1.0, "EUR": 1.25, "RUB": 0.0125, "GBP": 1.5, "XTR": 0.02, "GRAM": 5.0],
    ["USD", "EUR", "RUB", "GBP", "XTR", "GRAM"]
)

func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, in zone: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

let moscow = TimeZone(identifier: "Europe/Moscow")!
let winter = moment(2026, 1, 15, 12, in: moscow)
let summer = moment(2026, 7, 15, 12, in: moscow)

let placeNames: [String: String] = [
    "осло": "Europe/Oslo", "oslo": "Europe/Oslo", "стокгольм": "Europe/Stockholm", "вена": "Europe/Vienna",
    "норвегия": "Europe/Oslo", "китай": "Asia/Shanghai", "филиппины": "Asia/Manila", "кипр": "Asia/Nicosia",
    "севастополь": "Europe/Simferopol", "sao paulo": "America/Sao_Paulo"
]

func fullOptions(
    arithmetic: Bool = true, currencies: Bool = true, units: Bool = true, zones: Bool = true, degrees: Bool = true, grouping: Bool = true,
    imperial: Bool = false, local: TimeZone = moscow, now: Date = winter, places: ((String) -> String?)? = { placeNames[$0] }
) -> MathOptions {
    return MathOptions(
        decimalSeparator: ".", rates: currencies ? fullRates : nil, localCurrency: currencies ? "RUB" : nil,
        arithmetic: arithmetic, units: units, degrees: degrees, grouping: grouping,
        timeZones: zones ? TimeZoneOptions(local: local, now: now, places: places) : nil, imperial: imperial
    )
}

func full(_ text: String, _ expected: String?, _ options: MathOptions = fullOptions()) {
    let suggestion = MathExpression.suggestionAt(text, caret: text.unicodeScalars.count, options: options)
    check("[\(currentSection)] full(\"\(text)\")", expected, visible(suggestion?.value))
}

func money(_ text: String, _ expected: String?, local: String? = "RUB", source: CurrencyRates = rates, arithmetic: Bool = true) {
    let options = MathOptions(decimalSeparator: ".", rates: source, localCurrency: local, arithmetic: arithmetic)
    let suggestion = MathExpression.suggestionAt(text, caret: text.unicodeScalars.count, options: options)
    check("[\(currentSection)] money(\"\(text)\", \(local ?? "nil"))", expected, visible(suggestion?.value))
}

func moneyText(_ value: Double, _ fractionDigits: Int, _ separator: Character = ".") -> String? {
    return visible(MathFormat.formatMoney(value, fractionDigits: fractionDigits, decimalSeparator: separator))
}

runFormatTests()
runOperatorTests()
runVectorTests()
runRatesTests()
runZonePlacesTests()
runSessionTests()

for failure in failures {
    print("FAIL  \(failure)")
}
print("\(passed) passed, \(failures.count) failed")
exit(failures.isEmpty ? 0 : 1)
