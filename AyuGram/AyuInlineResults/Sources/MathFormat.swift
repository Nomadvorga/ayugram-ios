// Ported from exteraGram for Android (com.exteragram.messenger.inline.math), GPL v3 or later, © exteraGram.

import Foundation

enum MathFormat {
    static let noBreakSpace: Character = "\u{00A0}"
    static let maxExactInteger: Double = 9007199254740992.0

    private static let significantDigits = 12
    private static let maxAbsolute = 1e12
    private static let minAbsolute = 1e-9
    private static let maxLength = 24
    private static let moneySignificantDigits = 6
    private static let measureFractionDigits = 2
    private static let measureSignificantDigits = 3

    static func format(_ value: Double, decimalSeparator: Character, grouping: Bool = false) -> String? {
        if value.isNaN || value.isInfinite {
            return nil
        }
        let magnitude = abs(value)
        if magnitude >= maxAbsolute {
            return nil
        }
        if magnitude != 0.0 && magnitude < minAbsolute {
            return nil
        }
        guard let decimal = self.decimal(value) else {
            return nil
        }
        let text = self.plain(self.round(decimal, significant: significantDigits))
        return self.finish(grouping ? self.group(text) : text, decimalSeparator: decimalSeparator)
    }

    static func formatMoney(_ value: Double, fractionDigits: Int, decimalSeparator: Character, grouping: Bool = true) -> String? {
        if value.isNaN || value.isInfinite {
            return nil
        }
        let magnitude = abs(value)
        if magnitude >= maxAbsolute {
            return nil
        }
        guard let decimal = self.decimal(value) else {
            return nil
        }
        if fractionDigits >= 0 {
            let rounded = self.round(decimal, scale: fractionDigits)
            if !rounded.isZero || magnitude == 0.0 {
                var text = self.plain(rounded)
                if let point = text.firstIndex(of: ".") {
                    let fraction = text.distance(from: point, to: text.endIndex) - 1
                    if fraction < fractionDigits {
                        text += String(repeating: "0", count: fractionDigits - fraction)
                    }
                }
                return self.finish(grouping ? self.group(text) : text, decimalSeparator: decimalSeparator)
            }
        }
        if magnitude != 0.0 && magnitude < minAbsolute {
            return nil
        }
        let integerDigits = self.exponent(decimal) + 1
        let text = self.plain(self.round(decimal, significant: max(moneySignificantDigits, integerDigits)))
        return self.finish(grouping ? self.group(text) : text, decimalSeparator: decimalSeparator)
    }

    static func formatMeasure(_ value: Double, decimalSeparator: Character, grouping: Bool) -> String? {
        if value.isNaN || value.isInfinite {
            return nil
        }
        let magnitude = abs(value)
        if magnitude >= maxAbsolute {
            return nil
        }
        if magnitude != 0.0 && magnitude < minAbsolute {
            return nil
        }
        guard let decimal = self.decimal(value) else {
            return nil
        }
        let rounded: Decimal
        if magnitude >= 1.0 {
            rounded = self.round(decimal, scale: measureFractionDigits)
        } else {
            rounded = self.round(decimal, significant: measureSignificantDigits)
        }
        let text = self.plain(rounded)
        return self.finish(grouping ? self.group(text) : text, decimalSeparator: decimalSeparator)
    }

    static func formatBase(_ value: Double, radix: Int) -> String? {
        if value.isNaN || value.isInfinite || value != floor(value) || abs(value) > maxExactInteger {
            return nil
        }
        let integer = Int64(value)
        let prefix: String
        switch radix {
        case 2:
            prefix = "0b"
        case 8:
            prefix = "0o"
        case 16:
            prefix = "0x"
        default:
            prefix = ""
        }
        let digits = String(integer.magnitude, radix: radix).uppercased()
        return (integer < 0 ? "-" : "") + prefix + digits
    }

    // The shortest decimal that reads back as the same Double, like BigDecimal.valueOf.
    private static func decimal(_ value: Double) -> Decimal? {
        return Decimal(string: "\(value)", locale: Locale(identifier: "en_US_POSIX"))
    }

    // Digits after the point; a negative scale rounds to tens, hundreds and so on. Halves round away from zero.
    private static func round(_ value: Decimal, scale: Int) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, .plain)
        return result
    }

    private static func round(_ value: Decimal, significant digits: Int) -> Decimal {
        if value.isZero {
            return value
        }
        return self.round(value, scale: digits - 1 - self.exponent(value))
    }

    // Power of ten of the leading digit: 2 for 123.4, -3 for 0.0012.
    private static func exponent(_ value: Decimal) -> Int {
        if value.isZero {
            return 0
        }
        let text = self.plain(value)
        let digits = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
        let parts = digits.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = parts[0].drop(while: { $0 == "0" })
        if !whole.isEmpty {
            return whole.count - 1
        }
        let fraction = parts.count > 1 ? parts[1] : Substring()
        return -(fraction.prefix(while: { $0 == "0" }).count + 1)
    }

    // Plain notation with "." as the point and no trailing zeros.
    private static func plain(_ value: Decimal) -> String {
        var source = value
        var text = NSDecimalString(&source, Locale(identifier: "en_US_POSIX"))
        if text.contains(".") {
            while text.hasSuffix("0") {
                text.removeLast()
            }
            if text.hasSuffix(".") {
                text.removeLast()
            }
        }
        return text
    }

    private static func group(_ plain: String) -> String {
        let characters = Array(plain)
        let start = characters.first == "-" ? 1 : 0
        let point = characters.firstIndex(of: ".") ?? characters.count
        if point - start <= 3 {
            return plain
        }
        var grouped = String(characters[0 ..< start])
        for index in start ..< point {
            if index > start && (point - index) % 3 == 0 {
                grouped.append(noBreakSpace)
            }
            grouped.append(characters[index])
        }
        grouped.append(contentsOf: characters[point...])
        return grouped
    }

    private static func finish(_ plain: String, decimalSeparator: Character) -> String? {
        let text = plain == "-0" ? "0" : plain
        if text.count > maxLength {
            return nil
        }
        if decimalSeparator == "." {
            return text
        }
        return String(text.map { $0 == "." ? decimalSeparator : $0 })
    }
}
