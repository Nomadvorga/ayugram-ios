import Foundation

// Native port of exteraGram's inline calculator, based on
// com.exteragram.messenger.inline.math (Copyright exteraGram, 2022–2026).
// Parsing is explicit: no expression runtime, JavaScript or plugins. Currency
// rates are supplied separately; this engine never performs network requests.

/// A deterministic, bounded calculator that can also supply composer suggestions.
public enum ExteraMathEngine {
    public struct Options {
        public var degrees: Bool
        public var grouping: Bool
        public var decimalSeparator: String
        public var units: Bool
        public var currencies: Bool
        public var timeZones: Bool
        public var arithmetic: Bool
        public var imperial: Bool
        public var localCurrency: String
        public var localTimeZone: TimeZone
        public var now: Date
        public var currencyRates: ExteraMathCurrencySnapshot?

        public init(degrees: Bool = true, grouping: Bool = true, decimalSeparator: String = ".", units: Bool = true, currencies: Bool = true, timeZones: Bool = true, arithmetic: Bool = true, imperial: Bool = false, localCurrency: String = "USD", localTimeZone: TimeZone = .current, now: Date = Date(), currencyRates: ExteraMathCurrencySnapshot? = nil) {
            self.degrees = degrees
            self.grouping = grouping
            self.decimalSeparator = decimalSeparator == "," ? "," : "."
            self.units = units
            self.currencies = currencies
            self.timeZones = timeZones
            self.arithmetic = arithmetic
            self.imperial = imperial
            self.localCurrency = ExteraMathUnits.currencyCode(localCurrency) ?? "USD"
            self.localTimeZone = localTimeZone
            self.now = now
            self.currencyRates = currencyRates
        }
    }

    public struct Result {
        public let value: Double
        public let formatted: String
        public let hasOperation: Bool
        public let unit: String?
    }

    public struct Suggestion: Equatable {
        public let expression: String
        public let value: String
        /// UTF-16 offset, matching ChatTextInputState's flat selection coordinates.
        public let insertAt: Int
        public let insertText: String
        /// A validated currency expression awaiting real rates. Never insert/copy it.
        public var isPendingCurrency: Bool = false
        public var currencyRateDate: Date? = nil
    }

    /// Supports arithmetic, relative percentages, functions, superscripts, radix
    /// literals/conversions, dimension-aware measures, temperatures and currencies.
    /// Invalid, nonfinite, excessively small or large results return nil.
    public static func evaluate(_ expression: String, options: Options = Options()) -> Result? {
        guard expression.utf16.count <= 512 else { return nil }
        do {
            let parser = try Parser(expression, options: options)
            let operand = try parser.parse()
            guard !parser.needsCurrencyRates, let formatted = parser.format(operand) else { return nil }
            return Result(value: operand.value, formatted: formatted, hasOperation: parser.hasOperation, unit: operand.unit?.code)
        } catch {
            return nil
        }
    }

    /// Offers a result for an expression occupying the current line, immediately
    /// before `=` at a collapsed caret. Existing text after the caret is preserved.
    public static func suggestion(in text: String, caret: Int, options: Options = Options()) -> Suggestion? {
        let source = text as NSString
        guard caret > 1, caret <= source.length, source.character(at: caret - 1) == 61 else { return nil }
        // A result already to the right of the caret must not be duplicated.
        let suffixEnd = min(source.length, caret + 513)
        let tail = source.substring(with: NSRange(location: caret, length: suffixEnd - caret)).trimmingCharacters(in: .whitespaces)
        if let first = tail.first, first.isNumber || first == "." || first == "," { return nil }
        // Bound the backward search to one accepted expression, even in a very
        // large pasted draft. Repeated layout must not split/copy the whole draft.
        let searchStart = max(0, caret - 514)
        let searchRange = NSRange(location: searchStart, length: caret - 1 - searchStart)
        let newline = source.rangeOfCharacter(from: .newlines, options: .backwards, range: searchRange)
        let lineStart = newline.location == NSNotFound ? searchStart : NSMaxRange(newline)
        guard lineStart != searchStart || searchStart == 0 else { return nil }
        let line = source.substring(with: NSRange(location: lineStart, length: caret - 1 - lineStart))
        let expression = line.trimmingCharacters(in: .whitespaces)
        guard !expression.isEmpty, expression.utf16.count <= 512 else { return nil }
        // Preserve the upstream date guard: a date is not an arithmetic request.
        if expression.range(of: #"^(?:[0-9]{1,2}([/\.])[0-9]{1,2}\1(?:[0-9]{2}|[0-9]{4})|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2})$"#, options: .regularExpression) != nil {
            return nil
        }
        if options.timeZones, let value = ExteraMathTimeZones.convert(expression, local: options.localTimeZone, now: options.now) {
            return Suggestion(expression: expression, value: value, insertAt: caret, insertText: " " + value)
        }
        do {
            let parser = try Parser(expression, options: options)
            let operand = try parser.parse()
            guard parser.hasOperation, operand.unit != nil || options.arithmetic else { return nil }
            if parser.needsCurrencyRates {
                return Suggestion(expression: expression, value: "…", insertAt: caret, insertText: "", isPendingCurrency: true)
            }
            guard let value = parser.format(operand) else { return nil }
            return Suggestion(expression: expression, value: value, insertAt: caret, insertText: " " + value, currencyRateDate: parser.usesCurrencyRates ? options.currencyRates?.date : nil)
        } catch {
            return nil
        }
    }

    static func format(_ value: Double, options: Options) -> String? {
        let magnitude = abs(value)
        guard value.isFinite, magnitude < 1e12, magnitude == 0 || magnitude >= 1e-9 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 1
        formatter.maximumSignificantDigits = 12
        formatter.usesGroupingSeparator = options.grouping
        formatter.groupingSeparator = "\u{00a0}"
        formatter.groupingSize = 3
        formatter.decimalSeparator = options.decimalSeparator
        formatter.maximumFractionDigits = 20
        guard let text = formatter.string(from: NSNumber(value: value == 0 ? 0 : value)), text.count <= 24 else { return nil }
        return text
    }

    private enum ParseError: Error { case invalid }
    private enum Token: Equatable {
        case number(Double)
        case name(String)
        case digits(String)
        case unit(ExteraMathUnits.Unit)
        case symbol(Character)
        case end
    }
    private struct Operand {
        var value: Double
        var percent: Bool = false
        var unit: ExteraMathUnits.Unit? = nil
    }

    private final class Parser {
        private let options: Options
        private var tokens: [Token] = []
        private var index = 0
        private var depth = 0
        fileprivate var hasOperation = false
        fileprivate var needsCurrencyRates = false
        fileprivate var usesCurrencyRates = false
        private var base = 10
        private var explicitTarget = false
        private var breakdown = false
        private var expanded = false
        private var russian = false

        init(_ expression: String, options: Options) throws {
            self.options = options
            self.russian = expression.range(of: "[а-яА-ЯёЁ]", options: .regularExpression) != nil
            let originalCharacters = Array(expression)
            let characters = Array(expression.lowercased().replacingOccurrences(of: "ё", with: "е"))
            var offset = 0
            while offset < characters.count {
                guard self.tokens.count < 256 else { throw ParseError.invalid }
                let c = characters[offset]
                if c.isWhitespace {
                    offset += 1
                } else if c == "\u{fe0f}" {
                    offset += 1
                } else if c == ",", case .digits? = self.tokens.last {
                    self.tokens.append(.symbol(";"))
                    offset += 1
                } else if options.currencies, let unit = ExteraMathUnits.currencySymbol(c) {
                    self.tokens.append(.unit(unit))
                    offset += 1
                } else if Self.isDigit(c) || c == "." || (c == "," && offset + 1 < characters.count && Self.isDigit(characters[offset + 1])) {
                    if c == "0", offset + 2 < characters.count, let radix = Self.prefixRadix(characters[offset + 1]) {
                        let start = offset + 2
                        offset = start
                        while offset < characters.count && (Self.isDigit(characters[offset]) || characters[offset].isLetter) { offset += 1 }
                        let value = try Self.parseDigits(String(characters[start..<offset]), radix: radix)
                        self.tokens.append(.number(value))
                        self.expanded = true
                        continue
                    }
                    let start = offset
                    while offset < characters.count && Self.isDigit(characters[offset]) { offset += 1 }
                    // Accept our own grouped output when copied back into an expression.
                    // Nonbreaking separators and complete groups of three qualify.
                    // Ordinary spaces only join digits before a recognized amount unit.
                    if (1...3).contains(offset - start) {
                        while offset + 3 < characters.count,
                              characters[offset] == "\u{00a0}" || characters[offset] == "\u{202f}",
                              Self.isDigit(characters[offset + 1]), Self.isDigit(characters[offset + 2]), Self.isDigit(characters[offset + 3]),
                              offset + 4 == characters.count || !Self.isDigit(characters[offset + 4]) {
                            offset += 4
                        }
                        if options.units || options.currencies {
                            var grouped = offset
                            while grouped + 3 < characters.count,
                                  characters[grouped] == " ",
                                  Self.isDigit(characters[grouped + 1]), Self.isDigit(characters[grouped + 2]), Self.isDigit(characters[grouped + 3]),
                                  grouped + 4 == characters.count || !Self.isDigit(characters[grouped + 4]) {
                                grouped += 4
                            }
                            if grouped > offset && Self.isAmount(at: grouped, in: characters, options: options) { offset = grouped }
                        }
                    }
                    let integerEnd = offset
                    if offset + 1 < characters.count && (characters[offset] == "." || characters[offset] == ",") && Self.isDigit(characters[offset + 1]) {
                        let comma = characters[offset] == ","
                        offset += 1
                        let fractionStart = offset
                        while offset < characters.count && Self.isDigit(characters[offset]) { offset += 1 }
                        // Upstream declines ambiguous comma thousands notation.
                        if comma, offset - fractionStart == 3, (1...3).contains(integerEnd - start), characters[start] != "0" { throw ParseError.invalid }
                    }
                    // Scientific notation must have exponent digits; `e` alone is a constant.
                    if offset < characters.count && characters[offset] == "e" {
                        var exponent = offset + 1
                        if exponent < characters.count && (characters[exponent] == "+" || characters[exponent] == "-") { exponent += 1 }
                        let digits = exponent
                        while exponent < characters.count && Self.isDigit(characters[exponent]) { exponent += 1 }
                        if exponent > digits { offset = exponent }
                    }
                    let literal = String(characters[start..<offset].filter { $0 != " " && $0 != "\u{00a0}" && $0 != "\u{202f}" }).replacingOccurrences(of: ",", with: ".")
                    guard let value = Double(literal), value.isFinite else { throw ParseError.invalid }
                    self.tokens.append(.number(value))
                } else if options.units && (c == "°" || c == "℃" || c == "℉") {
                    var alias = String(c)
                    offset += 1
                    if c == "°" {
                        while offset < characters.count && characters[offset].isWhitespace { offset += 1 }
                        guard offset < characters.count else { throw ParseError.invalid }
                        alias += String(characters[offset])
                        offset += 1
                    }
                    guard let unit = ExteraMathUnits.measure(alias) else { throw ParseError.invalid }
                    self.tokens.append(.unit(unit))
                } else if "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻".contains(c) {
                    self.tokens.append(.symbol("^"))
                    if c == "⁺" || c == "⁻" {
                        self.tokens.append(.symbol(c == "⁺" ? "+" : "-"))
                        offset += 1
                    }
                    var digits = ""
                    let superscripts = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
                    while offset < characters.count, let digit = superscripts.firstIndex(of: characters[offset]) {
                        digits += String(digit)
                        offset += 1
                    }
                    guard let value = Double(digits) else { throw ParseError.invalid }
                    self.tokens.append(.number(value))
                } else if c.isLetter {
                    let start = offset
                    while offset < characters.count && (characters[offset].isLetter || Self.isDigit(characters[offset])) { offset += 1 }
                    var name = String(characters[start..<offset])
                    if name == "dec" {
                        var next = offset
                        while next < characters.count && characters[next].isWhitespace { next += 1 }
                        if next < characters.count && characters[next] == "(" {
                            self.tokens.append(.name(name))
                            self.tokens.append(.symbol("("))
                            offset = next + 1
                            while offset < characters.count && characters[offset].isWhitespace { offset += 1 }
                            let from = offset
                            while offset < characters.count && (Self.isDigit(characters[offset]) || characters[offset].isLetter) { offset += 1 }
                            self.tokens.append(.digits(String(characters[from..<offset])))
                            continue
                        }
                    }
                    if options.units {
                        // Longest compound wins over the standalone length/mass word.
                        var next = offset
                        while next < characters.count && characters[next].isWhitespace { next += 1 }
                        let separator = next < characters.count && characters[next] == "/" ? "/" : " "
                        if separator == "/" { next += 1 }
                        let from = next
                        while next < characters.count && characters[next].isLetter { next += 1 }
                        let compound = name + separator + String(characters[from..<next])
                        if from < next, let unit = ExteraMathUnits.measure(compound) {
                            self.tokens.append(.unit(unit))
                            offset = next
                            continue
                        }
                        if offset < characters.count && characters[offset] == "²", ExteraMathUnits.measure(name + "²") != nil {
                            name += "²"
                            offset += 1
                        }
                    }
                    // `in` is the conversion marker; inches use inch/inches, as upstream.
                    var next = offset
                    while next < characters.count && characters[next].isWhitespace { next += 1 }
                    let call = next < characters.count && characters[next] == "("
                    if ["to", "in", "в"].contains(name) {
                        self.tokens.append(.name("to"))
                    } else if call {
                        self.tokens.append(.name(name))
                    } else if options.currencies, let unit = ExteraMathUnits.currency(name),
                              (originalCharacters.count == characters.count && String(originalCharacters[start..<offset]) == name.uppercased()
                               || self.tokens.contains(where: { if case let .unit(unit) = $0 { return unit.kind == .currency }; return false })) {
                        // Resolve ambiguous gram/pound words as currency when an
                        // explicit uppercase code or another currency gives context.
                        self.tokens.append(.unit(unit))
                    } else if options.units, let unit = ExteraMathUnits.measure(name) {
                        self.tokens.append(.unit(unit))
                    } else if options.currencies, let unit = ExteraMathUnits.currency(name) {
                        self.tokens.append(.unit(unit))
                    } else {
                        self.tokens.append(.name(name))
                    }
                } else {
                    let normalized: Character
                    switch c {
                    case "−": normalized = "-"
                    case "×": normalized = "*"
                    case "÷": normalized = "/"
                    case ",": normalized = ";"
                    default: normalized = c
                    }
                    guard "+-*/^()%!√;".contains(normalized) else { throw ParseError.invalid }
                    self.tokens.append(.symbol(normalized))
                    offset += 1
                }
            }
            self.tokens.append(.end)
        }

        private static func isDigit(_ c: Character) -> Bool {
            return c >= "0" && c <= "9"
        }

        private static func isAmount(at offset: Int, in characters: [Character], options: Options) -> Bool {
            var index = offset
            while index < characters.count && characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { return false }
            if options.currencies && ExteraMathUnits.currencySymbol(characters[index]) != nil { return true }
            if options.units && "°℃℉".contains(characters[index]) { return true }
            let start = index
            while index < characters.count && (characters[index].isLetter || Self.isDigit(characters[index])) { index += 1 }
            let word = String(characters[start..<index])
            return options.units && ExteraMathUnits.measure(word) != nil || options.currencies && ExteraMathUnits.currency(word) != nil
        }

        private var current: Token { return self.tokens[self.index] }

        private func consume(_ token: Token) -> Bool {
            guard self.current == token else { return false }
            self.index += 1
            return true
        }

        private func require(_ token: Token) throws {
            guard self.consume(token) else { throw ParseError.invalid }
        }

        func parse() throws -> Operand {
            var value = try self.conversion()
            try self.require(.end)
            if let unit = value.unit {
                if unit.kind == .duration && ["d", "h", "min", "s"].contains(unit.code) && !self.explicitTarget {
                    self.breakdown = true
                    if let text = ExteraMathUnits.duration(value.value * unit.scale, options: self.options, russian: self.russian), let plain = ExteraMathEngine.format(value.value, options: self.options) {
                        self.hasOperation = self.hasOperation || text != plain + "\u{00a0}" + unit.label(self.russian)
                    }
                } else if !self.hasOperation, let target = ExteraMathUnits.implicitTarget(unit, value: value.value, imperial: self.options.imperial, localCurrency: self.options.localCurrency) {
                    value = try self.convert(value, to: target)
                }
            }
            self.hasOperation = self.hasOperation || self.expanded
            return value
        }

        func format(_ operand: Operand) -> String? {
            if self.base != 10 {
                guard operand.unit == nil, operand.value.isFinite, abs(operand.value) <= 9_007_199_254_740_991, operand.value.rounded(.towardZero) == operand.value else { return nil }
                let prefix = self.base == 2 ? "0b" : self.base == 8 ? "0o" : "0x"
                return (operand.value < 0 ? "-" : "") + prefix + String(Int64(abs(operand.value)), radix: self.base).uppercased()
            }
            guard let unit = operand.unit else { return ExteraMathEngine.format(operand.value, options: self.options) }
            if self.breakdown { return ExteraMathUnits.duration(operand.value * unit.scale, options: self.options, russian: self.russian) }
            let number: String?
            if unit.kind == .currency { number = ExteraMathUnits.money(operand.value, code: unit.code, options: self.options) }
            else { number = ExteraMathUnits.measureNumber(operand.value, options: self.options) }
            return number.map { $0 + "\u{00a0}" + unit.label(self.russian) }
        }

        private func conversion() throws -> Operand {
            var value = try self.expression(0)
            while self.consume(.name("to")) {
                if case let .name(name) = self.current, let radix = Self.bases[name] {
                    guard value.unit == nil else { throw ParseError.invalid }
                    self.base = radix
                    self.index += 1
                    self.hasOperation = true
                } else {
                    guard case let .unit(unit) = self.current else { throw ParseError.invalid }
                    self.index += 1
                    value = try self.convert(value, to: unit)
                    self.explicitTarget = true
                }
            }
            return value
        }

        private func convertedValue(_ value: Double, from: ExteraMathUnits.Unit, to: ExteraMathUnits.Unit) throws -> Double {
            guard from.kind == to.kind else { throw ParseError.invalid }
            if from.code == to.code { return value }
            if from.kind == .currency {
                self.usesCurrencyRates = true
                guard let rate = self.options.currencyRates?.rate(from: from.code, to: to.code, now: self.options.now) else {
                    // Continue checking syntax/dimensions, but never expose this value.
                    // The only UI result of missing rates is a non-insertable ellipsis.
                    self.needsCurrencyRates = true
                    return value
                }
                return value * rate
            }
            return (value * from.scale + from.offset - to.offset) / to.scale
        }

        private func convert(_ operand: Operand, to target: ExteraMathUnits.Unit) throws -> Operand {
            guard let unit = operand.unit else { throw ParseError.invalid }
            self.hasOperation = true
            return Operand(value: try self.convertedValue(operand.value, from: unit, to: target), unit: target)
        }

        private static let bases = ["bin": 2, "oct": 8, "hex": 16, "dec": 10]

        private static func prefixRadix(_ character: Character) -> Int? {
            switch character { case "b": return 2; case "o": return 8; case "x": return 16; default: return nil }
        }

        private static func parseDigits(_ text: String, radix: Int) throws -> Double {
            guard !text.isEmpty, (2...36).contains(radix) else { throw ParseError.invalid }
            var value: Int64 = 0
            for character in text {
                guard let scalar = character.asciiValue else { throw ParseError.invalid }
                let digit = scalar >= 97 ? Int(scalar) - 87 : Int(scalar) - 48
                guard digit >= 0, digit < radix, value <= (9_007_199_254_740_991 - Int64(digit)) / Int64(radix) else { throw ParseError.invalid }
                value = value * Int64(radix) + Int64(digit)
            }
            return Double(value)
        }

        // Pratt parsing gives power right associativity and binds it tighter than unary minus.
        private func expression(_ minimumPrecedence: Int) throws -> Operand {
            self.depth += 1
            defer { self.depth -= 1 }
            guard self.depth <= 32 else { throw ParseError.invalid }
            var left = try self.unary()
            while true {
                let op: Character
                let precedence: Int
                switch self.current {
                case .symbol("+"): op = "+"; precedence = 10
                case .symbol("-"): op = "-"; precedence = 10
                case .symbol("*"): op = "*"; precedence = 20
                case .symbol("/"): op = "/"; precedence = 20
                case .symbol("^"): op = "^"; precedence = 40
                case .name("of"), .name("от"):
                    guard left.percent else { throw ParseError.invalid }
                    op = "*"; precedence = 20
                default: return left
                }
                if precedence < minimumPrecedence { return left }
                self.index += 1
                let right = try self.expression(op == "^" ? precedence : precedence + 1)
                var rightValue = right.value
                let unit: ExteraMathUnits.Unit?
                if left.unit == nil && right.unit == nil {
                    unit = nil
                } else {
                    switch op {
                    case "+", "-":
                        if let leftUnit = left.unit, let rightUnit = right.unit {
                            rightValue = try self.convertedValue(rightValue, from: rightUnit, to: leftUnit)
                        }
                        unit = left.unit ?? right.unit
                    case "*":
                        guard left.unit == nil || right.unit == nil else { throw ParseError.invalid }
                        unit = left.unit ?? right.unit
                    case "/":
                        guard let leftUnit = left.unit else { throw ParseError.invalid }
                        if let rightUnit = right.unit {
                            rightValue = try self.convertedValue(rightValue, from: rightUnit, to: leftUnit)
                            unit = nil
                        } else { unit = leftUnit }
                    default: throw ParseError.invalid
                    }
                }
                let value: Double
                switch op {
                case "+": value = left.value + (right.percent ? left.value * rightValue : rightValue)
                case "-": value = left.value - (right.percent ? left.value * rightValue : rightValue)
                case "*": value = left.value * rightValue
                case "/":
                    guard rightValue != 0 else { throw ParseError.invalid }
                    value = left.value / rightValue
                default: value = pow(left.value, rightValue)
                }
                guard value.isFinite else { throw ParseError.invalid }
                left = Operand(value: value, unit: unit)
                self.hasOperation = true
            }
        }

        private func unary() throws -> Operand {
            if self.consume(.symbol("-")) {
                var value = try self.expression(30)
                value.value = -value.value
                return value
            } else if self.consume(.symbol("+")) {
                return try self.expression(30)
            } else if self.consume(.symbol("√")) {
                let value = try self.expression(40)
                guard value.value >= 0, value.unit == nil else { throw ParseError.invalid }
                self.hasOperation = true
                return Operand(value: sqrt(value.value))
            }
            var prefixUnit: ExteraMathUnits.Unit?
            if case let .unit(unit) = self.current, unit.kind == .currency {
                prefixUnit = unit
                self.index += 1
            }
            var value = try self.primary()
            while true {
                if self.consume(.symbol("%")) {
                    guard value.unit == nil else { throw ParseError.invalid }
                    value = Operand(value: value.value / 100, percent: true)
                } else if self.consume(.symbol("!")) {
                    guard value.unit == nil else { throw ParseError.invalid }
                    value = Operand(value: try Self.factorial(value.value))
                } else if case let .unit(unit) = self.current {
                    guard value.unit == nil, !value.percent else { throw ParseError.invalid }
                    self.index += 1
                    value.unit = unit
                    continue
                } else if case let .name(name) = self.current, let multiplier = Self.multipliers[name] {
                    guard value.unit == nil else { throw ParseError.invalid }
                    self.index += 1
                    value = Operand(value: value.value * multiplier)
                    guard value.value.isFinite else { throw ParseError.invalid }
                    self.expanded = true
                    continue
                } else {
                    if let prefixUnit {
                        guard value.unit == nil, !value.percent else { throw ParseError.invalid }
                        value.unit = prefixUnit
                    }
                    return value
                }
                guard value.value.isFinite else { throw ParseError.invalid }
                self.hasOperation = true
            }
        }

        private static let multipliers: [String: Double] = [
            "k": 1e3, "к": 1e3, "thousand": 1e3, "тыс": 1e3,
            "kk": 1e6, "кк": 1e6, "million": 1e6, "млн": 1e6,
            "kkk": 1e9, "ккк": 1e9, "billion": 1e9, "млрд": 1e9
        ]

        private func primary() throws -> Operand {
            if case let .number(value) = self.current {
                self.index += 1
                return Operand(value: value)
            }
            if self.consume(.symbol("(")) {
                let value = try self.conversion()
                try self.require(.symbol(")"))
                // Upstream parentheses intentionally clear the relative-percent marker.
                return Operand(value: value.value, unit: value.unit)
            }
            guard case let .name(name) = self.current else { throw ParseError.invalid }
            self.index += 1
            if name == "pi" || name == "π" { return Operand(value: .pi) }
            if name == "e" { return Operand(value: exp(1)) }
            if let radix = Self.bases[name] {
                let whole = self.index == 1
                try self.require(.symbol("("))
                let value: Double
                if name == "dec" {
                    guard case let .digits(digits) = self.current else { throw ParseError.invalid }
                    self.index += 1
                    let from: Int
                    if self.consume(.symbol(";")) {
                        let base = try self.expression(0)
                        guard base.unit == nil, base.value >= 2, base.value <= 36, base.value.rounded(.towardZero) == base.value else { throw ParseError.invalid }
                        from = Int(base.value)
                    } else {
                        let chars = Array(digits)
                        from = chars.count > 2 && chars[0] == "0" ? Self.prefixRadix(chars[1]) ?? 10 : 10
                    }
                    let chars = Array(digits)
                    let stripped = chars.count > 2 && chars[0] == "0" && Self.prefixRadix(chars[1]) == from ? String(chars.dropFirst(2)) : digits
                    value = try Self.parseDigits(stripped, radix: from)
                } else {
                    let operand = try self.expression(0)
                    guard operand.unit == nil else { throw ParseError.invalid }
                    value = operand.value
                }
                try self.require(.symbol(")"))
                if name != "dec" {
                    guard whole, self.current == .end else { throw ParseError.invalid }
                    self.base = radix
                }
                self.hasOperation = true
                return Operand(value: value)
            }
            try self.require(.symbol("("))
            var arguments: [Double] = []
            if !self.consume(.symbol(")")) {
                let argument = try self.expression(0)
                guard argument.unit == nil else { throw ParseError.invalid }
                arguments.append(argument.value)
                while self.consume(.symbol(";")) {
                    let argument = try self.expression(0)
                    guard argument.unit == nil else { throw ParseError.invalid }
                    arguments.append(argument.value)
                }
                try self.require(.symbol(")"))
            }
            let value = try self.function(name, arguments)
            guard value.isFinite else { throw ParseError.invalid }
            self.hasOperation = true
            return Operand(value: value)
        }

        private static func factorial(_ value: Double) throws -> Double {
            guard value >= 0, value <= 170, value.rounded(.down) == value else { throw ParseError.invalid }
            if value < 2 { return 1 }
            return (2...Int(value)).reduce(1.0) { $0 * Double($1) }
        }

        private func function(_ name: String, _ args: [Double]) throws -> Double {
            if name == "min", let value = args.min() { return value }
            if name == "max", let value = args.max() { return value }
            if name == "atan2", args.count == 2 {
                let result = atan2(args[0], args[1])
                return self.options.degrees ? result * 180 / .pi : result
            }
            guard args.count == 1 else { throw ParseError.invalid }
            let x = args[0]
            let angle = self.options.degrees ? x * .pi / 180 : x
            switch name {
            case "sqrt": return sqrt(x)
            case "cbrt": return cbrt(x)
            case "abs": return abs(x)
            case "sign": return x == 0 ? 0 : (x < 0 ? -1 : 1)
            case "round": return floor(x + 0.5)
            case "floor": return floor(x)
            case "ceil": return ceil(x)
            case "fact": return try Self.factorial(x)
            case "log": return log10(x)
            case "log2": return log2(x)
            case "ln": return log(x)
            case "exp": return exp(x)
            case "sin", "cos", "tan":
                let result: Double
                if name == "sin" { result = sin(angle) }
                else if name == "cos" { result = cos(angle) }
                else {
                    guard abs(cos(angle)) >= 1e-12 else { throw ParseError.invalid }
                    result = tan(angle)
                }
                return abs(result) < 1e-12 ? 0 : result
            case "asin", "acos", "atan":
                let result: Double
                if name == "asin" { result = asin(x) }
                else if name == "acos" { result = acos(x) }
                else { result = atan(x) }
                return self.options.degrees ? result * 180 / .pi : result
            case "sinh": return sinh(x)
            case "cosh": return cosh(x)
            case "tanh": return tanh(x)
            default: throw ParseError.invalid
            }
        }
    }
}
