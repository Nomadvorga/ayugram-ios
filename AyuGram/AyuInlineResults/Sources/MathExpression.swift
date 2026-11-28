// Ported from exteraGram for Android (com.exteragram.messenger.inline.math), GPL v3 or later, © exteraGram.

import Foundation

struct MathOptions {
    var decimalSeparator: Character = "."
    var rates: CurrencyRates? = nil
    var localCurrency: String? = nil
    var arithmetic: Bool = true
    var units: Bool = false
    var degrees: Bool = false
    var grouping: Bool = true
    var timeZones: TimeZoneOptions? = nil
    var imperial: Bool = false
}

struct MathResult {
    let value: Double
    let hasOperation: Bool
    let decimalSeparator: Character
    let unit: MathUnit?
    let russian: Bool
    let breakdown: Bool
    let grouping: Bool
    let base: Int
}

// `insertAt` counts Unicode scalars from the start of the text, like the caret passed to `suggestionAt`.
struct MathSuggestion {
    let insertAt: Int
    let insertText: String
    let value: String
}

enum MathExpression {
    private static let maxScan = 64
    private static let maxDepth = 32
    private static let trigEpsilon = 1e-12

    private static let variationSelector: Character = "\u{FE0F}"
    private static let superscriptDigits: [Character] = mathCharacters("⁰¹²³⁴⁵⁶⁷⁸⁹")

    private struct MathParseError: Error {
    }

    private enum TokenType {
        case number
        case symbol
        case leftParen
        case rightParen
        case identifier
        case argumentSeparator
        case unit
        case conversion
        case of
        case digits
        case end
    }

    private final class Token {
        let type: TokenType
        let number: Double
        let text: String
        let units: [MathUnit]
        var unit: MathUnit?

        init(_ type: TokenType, number: Double = 0.0, text: String = "", units: [MathUnit] = []) {
            self.type = type
            self.number = number
            self.text = text
            self.units = units
            self.unit = units.first
        }
    }

    private struct Operand {
        let value: Double
        let isPercent: Bool
        var unit: MathUnit? = nil
    }

    static func evaluate(_ expression: String, options: MathOptions = MathOptions()) -> MathResult? {
        return self.evaluate(mathCharacters(expression), options: options)
    }

    static func evaluate(_ expression: [Character], options: MathOptions = MathOptions()) -> MathResult? {
        return try? Parser(source: expression, options: options).parse()
    }

    static func format(_ result: MathResult) -> String? {
        if result.base != 10 {
            return MathFormat.formatBase(result.value, radix: result.base)
        }
        guard let unit = result.unit else {
            return MathFormat.format(result.value, decimalSeparator: result.decimalSeparator, grouping: result.grouping)
        }
        let number: String?
        if unit.kind == .currency {
            number = MathFormat.formatMoney(result.value, fractionDigits: Currencies.fractionDigits(unit.code), decimalSeparator: result.decimalSeparator, grouping: result.grouping)
        } else if result.breakdown {
            return Measures.formatDuration(unit.toBase(result.value), decimalSeparator: result.decimalSeparator, russian: result.russian)
        } else {
            number = MathFormat.formatMeasure(result.value, decimalSeparator: result.decimalSeparator, grouping: result.grouping)
        }
        guard let number else {
            return nil
        }
        return "\(number)\(MathFormat.noBreakSpace)\(unit.label(russian: result.russian))"
    }

    static func suggestionAt(_ text: String, caret: Int, options: MathOptions) -> MathSuggestion? {
        return self.suggestionAt(mathCharacters(text), caret: caret, options: options)
    }

    static func suggestionAt(_ text: [Character], caret: Int, options: MathOptions) -> MathSuggestion? {
        if caret <= 1 || caret > text.count || text[caret - 1] != "=" {
            return nil
        }
        var after = caret
        while after < text.count && isBlank(text[after]) {
            after += 1
        }
        if after < text.count {
            let next = text[after]
            if next.isMathDigit || next == "." || next == "," {
                return nil
            }
        }
        let equals = caret - 1
        if let zones = options.timeZones, let time = TimeZones.valueAt(text, equalsIndex: equals, options: zones) {
            return suggestion(text, caret: caret, value: time)
        }
        guard var start = expressionStart(text, equalsIndex: equals) else {
            return nil
        }
        while true {
            if !looksLikeDate(text, from: start, to: equals) {
                if let result = evaluate(Array(text[start ..< equals]), options: options) {
                    if !result.hasOperation || (result.unit == nil && !options.arithmetic) {
                        return nil
                    }
                    guard let value = format(result) else {
                        return nil
                    }
                    return suggestion(text, caret: caret, value: value)
                }
            }
            guard let next = nextCandidate(text, from: start, end: equals) else {
                return nil
            }
            start = next
        }
    }

    private static func suggestion(_ text: [Character], caret: Int, value: String) -> MathSuggestion {
        let spaced = isBlank(text[caret - 2])
        return MathSuggestion(insertAt: caret, insertText: spaced ? " \(value)" : value, value: value)
    }

    private static func looksLikeDate(_ text: [Character], from: Int, to: Int) -> Bool {
        var start = from
        var end = to
        while start < end && isBlank(text[start]) {
            start += 1
        }
        while end > start && isBlank(text[end - 1]) {
            end -= 1
        }
        if end - start < 6 {
            return false
        }
        var groups: [Int] = []
        var separator: Character = " "
        var digits = 0
        for index in start ..< end {
            let c = text[index]
            if c.isMathDigit {
                digits += 1
                continue
            }
            if c != "/" && c != "." && c != "-" {
                return false
            }
            if separator == " " {
                separator = c
            } else if separator != c {
                return false
            }
            if digits == 0 || groups.count == 2 {
                return false
            }
            groups.append(digits)
            digits = 0
        }
        if digits == 0 || groups.count != 2 {
            return false
        }
        groups.append(digits)
        switch separator {
        case "/", ".":
            return groups[0] <= 2 && groups[1] <= 2 && (groups[2] == 2 || groups[2] == 4)
        case "-":
            return groups[0] == 4 && groups[1] <= 2 && groups[2] <= 2
        default:
            return false
        }
    }

    private static func nextCandidate(_ text: [Character], from: Int, end: Int) -> Int? {
        var index = from
        var previous: Character = " "
        while index < end {
            let c = text[index]
            index += 1
            if c == "(" {
                return index
            }
            if isBlank(c) {
                while index < end && isBlank(text[index]) {
                    index += 1
                }
                if index >= end {
                    return nil
                }
                if c == MathFormat.noBreakSpace && previous.isMathDigit && text[index].isMathDigit {
                    continue
                }
                return index
            }
            previous = c
        }
        return nil
    }

    private static func expressionStart(_ text: [Character], equalsIndex: Int) -> Int? {
        let limit = max(0, equalsIndex - maxScan)
        var index = equalsIndex - 1
        while index >= limit && isExpressionChar(text[index]) {
            index -= 1
        }
        var start = index + 1
        while start < equalsIndex && isBlank(text[start]) {
            start += 1
        }
        if start >= equalsIndex {
            return nil
        }
        if start > 0 {
            let before = text[start - 1]
            if before.isMathLetter {
                while start < equalsIndex && !isBlank(text[start]) {
                    start += 1
                }
                while start < equalsIndex && isBlank(text[start]) {
                    start += 1
                }
                if start >= equalsIndex {
                    return nil
                }
            } else if before.isMathDigit || before == "_" {
                return nil
            }
        }
        return start
    }

    private static func isBlank(_ c: Character) -> Bool {
        return c == " " || c == "\t" || c == MathFormat.noBreakSpace
    }

    private static func isWordChar(_ c: Character) -> Bool {
        return c.isMathLetter || c.isMathDigit
    }

    private static func isSuperscript(_ c: Character) -> Bool {
        return superscriptDigits.contains(c) || c == "⁺" || c == "⁻"
    }

    private static func isExpressionChar(_ c: Character) -> Bool {
        return c.isMathDigit || c.isMathLetter || c == "." || c == "," || isBlank(c) ||
            c == "°" || c == "℃" || c == "℉" || c == variationSelector || isSuperscript(c) ||
            MathOperators.symbolChars.contains(c) || Currencies.symbolChars.contains(c)
    }

    // Character.digit(c, radix): the value of a digit or a Latin letter, or nil when it is not a digit of that radix.
    private static func digit(_ c: Character, radix: Int) -> Int? {
        guard let scalar = c.unicodeScalars.first else {
            return nil
        }
        let value: Int
        if c.isMathDigit, let number = c.wholeNumberValue {
            value = number
        } else if scalar.value >= 0x61 && scalar.value <= 0x7A {
            value = Int(scalar.value) - 0x61 + 10
        } else if scalar.value >= 0x41 && scalar.value <= 0x5A {
            value = Int(scalar.value) - 0x41 + 10
        } else {
            return nil
        }
        return value < radix ? value : nil
    }

    private final class Parser {
        private let source: [Character]
        private let options: MathOptions

        private var tokens: [Token] = []
        private var position = 0
        private var depth = 0
        private var hasOperation = false
        private var expanded = false
        private var explicitTarget = false
        private var base = 10
        private var separator: Character?
        private let russian: Bool

        private let error = MathParseError()

        init(source: [Character], options: MathOptions) {
            self.source = source
            self.options = options
            self.russian = source.contains(where: { c in
                guard let value = c.unicodeScalars.first?.value else {
                    return false
                }
                return (value >= 0x410 && value <= 0x44F) || value == 0x451 || value == 0x401
            })
        }

        func parse() throws -> MathResult {
            try self.tokenize()
            self.resolveUnits()
            var result = try self.parseConversion()
            try self.expect(.end)
            var breakdown = false
            if let unit = result.unit {
                if unit.kind == .duration {
                    breakdown = !self.explicitTarget && Measures.canBreakDown(unit)
                    if !self.hasOperation && breakdown {
                        self.hasOperation = Measures.breaksDown(result.value, unit: unit)
                    }
                } else if !self.hasOperation {
                    if let target = self.implicitTarget(unit, value: result.value) {
                        result = try self.convert(result, target: target)
                    }
                }
            }
            if self.expanded {
                self.hasOperation = true
            }
            return MathResult(
                value: result.value, hasOperation: self.hasOperation, decimalSeparator: self.separator ?? self.options.decimalSeparator,
                unit: result.unit, russian: self.russian, breakdown: breakdown, grouping: self.options.grouping, base: self.base
            )
        }

        private func implicitTarget(_ unit: MathUnit, value: Double) -> MathUnit? {
            if unit.kind != .currency {
                return Measures.implicitTarget(unit, value: value, imperial: self.options.imperial)
            }
            let local = self.options.localCurrency ?? Currencies.fallback
            let target = local == unit.code ? Currencies.fallback : local
            return target == unit.code ? nil : Currencies.unit(target)
        }

        private func substring(_ from: Int, _ to: Int) -> String {
            return String(self.source[from ..< to])
        }

        private func tokenize() throws {
            let source = self.source
            var index = 0
            while index < source.count {
                let c = source[index]
                if isBlank(c) || c == variationSelector {
                    index += 1
                    continue
                }
                if c.isMathDigit || ((c == "." || c == ",") && index + 1 < source.count && source[index + 1].isMathDigit) {
                    index = try self.readNumber(index)
                    continue
                }
                if isSuperscript(c) {
                    index = try self.readSuperscript(index)
                    continue
                }
                if c == "(" {
                    self.tokens.append(Token(.leftParen))
                    index += 1
                    continue
                }
                if c == ")" {
                    self.tokens.append(Token(.rightParen))
                    index += 1
                    continue
                }
                if c == MathOperators.argumentSeparator || (c == "," && (index + 1 == source.count || isBlank(source[index + 1]))) {
                    self.tokens.append(Token(.argumentSeparator))
                    index += 1
                    continue
                }
                if c == "°" {
                    index = try self.readTemperature(index)
                    continue
                }
                if c.isMathLetter {
                    let from = index
                    index = self.unitWordEnd(index)
                    index = self.addWord(self.substring(from, index), end: index)
                    continue
                }
                var unit: MathUnit? = self.options.units ? Measures.symbol(c) : nil
                if unit == nil, let rates = self.options.rates {
                    unit = Currencies.symbol(c, rates: rates)
                }
                if let unit {
                    self.tokens.append(Token(.unit, units: [unit]))
                    index += 1
                    continue
                }
                guard let symbol = MathOperators.matchSymbol(source, at: index) else {
                    throw self.error
                }
                self.tokens.append(Token(.symbol, text: symbol))
                index += symbol.unicodeScalars.count
            }
            self.tokens.append(Token(.end))
        }

        private func resolveUnits() {
            var kinds = Set<UnitKind>()
            for token in self.tokens {
                if token.type == .unit && token.units.count == 1 {
                    kinds.insert(token.units[0].kind)
                }
            }
            for token in self.tokens {
                if token.type == .unit && token.units.count > 1 {
                    token.unit = token.units.first(where: { kinds.contains($0.kind) }) ?? token.units[0]
                }
            }
        }

        private func wordEnd(_ from: Int) -> Int {
            var index = from
            while index < self.source.count && isWordChar(self.source[index]) {
                index += 1
            }
            return index
        }

        private func unitWordEnd(_ from: Int) -> Int {
            let end = self.wordEnd(from)
            if self.options.units && end < self.source.count && self.source[end] == "²" && Measures.word(self.substring(from, end + 1)) != nil {
                return end + 1
            }
            return end
        }

        private func skipBlanks(_ from: Int) -> Int {
            var index = from
            while index < self.source.count && isBlank(self.source[index]) {
                index += 1
            }
            return index
        }

        private func readTemperature(_ from: Int) throws -> Int {
            if !self.options.units {
                throw self.error
            }
            let index = self.skipBlanks(from + 1)
            if index >= self.source.count || (index + 1 < self.source.count && isWordChar(self.source[index + 1])) {
                throw self.error
            }
            guard let unit = Measures.temperature(self.source[index]) else {
                throw self.error
            }
            self.tokens.append(Token(.unit, units: [unit]))
            return index + 1
        }

        private func addWord(_ word: String, end: Int) -> Int {
            let source = self.source
            let name = word.lowercased()
            if MathOperators.percentOf.contains(name) {
                self.tokens.append(Token(.of))
                return end
            }
            let rates = self.options.rates
            if Currencies.isConversion(word) {
                self.tokens.append(Token(.conversion))
                return end
            }
            let next = self.skipBlanks(end)
            let call = next < source.count && source[next] == "("
            if call && name == MathOperators.decimal {
                self.tokens.append(Token(.identifier, text: name))
                self.tokens.append(Token(.leftParen))
                let from = self.skipBlanks(next + 1)
                let to = self.wordEnd(from)
                if to > from {
                    self.tokens.append(Token(.digits, text: self.substring(from, to)))
                }
                return to
            }
            if !call {
                if self.options.units {
                    let compound = self.readCompound(word, end: end)
                    if compound >= 0 {
                        return compound
                    }
                }
                let reserved = MathOperators.constants[name] != nil || MathOperators.bases[name] != nil || MathOperators.functionFor(name) != nil
                var candidates: [MathUnit] = []
                if let rates, !reserved, let unit = Currencies.word(word, rates: rates) {
                    candidates.append(unit)
                }
                if self.options.units, let unit = Measures.word(word) {
                    candidates.append(unit)
                }
                if !candidates.isEmpty {
                    self.tokens.append(Token(.unit, units: candidates))
                    let abbreviated = end < source.count && source[end] == "." && (end + 1 == source.count || !source[end + 1].isMathDigit)
                    return abbreviated ? end + 1 : end
                }
            }
            self.tokens.append(Token(.identifier, text: name))
            return end
        }

        private func readCompound(_ first: String, end: Int) -> Int {
            let source = self.source
            let slash = end < source.count && source[end] == "/"
            let from = slash ? end + 1 : self.skipBlanks(end)
            if from >= source.count || !source[from].isMathLetter || (!slash && from == end) {
                return -1
            }
            let to = self.wordEnd(from)
            guard let unit = Measures.compound(first, separator: slash ? "/" : " ", self.substring(from, to)) else {
                return -1
            }
            self.tokens.append(Token(.unit, units: [unit]))
            return to
        }

        private func readNumber(_ from: Int) throws -> Int {
            let source = self.source
            let radix = source[from] == "0" && from + 2 < source.count ? MathOperators.radixFor(source[from + 1]) : 0
            if radix != 0 && digit(source[from + 2], radix: radix) != nil {
                let end = self.wordEnd(from + 2)
                self.tokens.append(Token(.number, number: try self.parseDigits(self.substring(from + 2, end), radix: radix)))
                self.expanded = true
                return end
            }
            var end = try self.scanNumber(from, grouping: false)
            if self.options.rates != nil || self.options.units {
                let grouped = try self.scanNumber(from, grouping: true)
                if grouped > end && self.isAmountAt(grouped) {
                    end = grouped
                }
            }
            var literal = ""
            for index in from ..< end {
                let c = source[index]
                if !isBlank(c) {
                    literal.append(c == "," ? "." : c)
                }
            }
            guard literal.unicodeScalars.allSatisfy({ $0.isASCII }), var number = Double(literal) else {
                throw self.error
            }
            let glued = end < source.count && source[end].isMathLetter
            let wordStart = glued ? end : self.skipBlanks(end)
            if wordStart > end || glued {
                if wordStart < source.count && source[wordStart].isMathLetter {
                    let wordEnd = self.wordEnd(wordStart)
                    let word = self.substring(wordStart, wordEnd).lowercased()
                    if let multiplier = MathOperators.multipliers[word], glued || !MathOperators.gluedMultipliers.contains(word) {
                        number *= multiplier
                        self.expanded = true
                        if wordEnd < source.count && source[wordEnd] == "." && (wordEnd + 1 == source.count || !source[wordEnd + 1].isMathDigit) {
                            end = wordEnd + 1
                        } else {
                            end = wordEnd
                        }
                    }
                }
            }
            self.tokens.append(Token(.number, number: number))
            return end
        }

        private func readSuperscript(_ from: Int) throws -> Int {
            let source = self.source
            var end = from
            let sign: String?
            switch source[end] {
            case "⁺":
                sign = "+"
            case "⁻":
                sign = "-"
            default:
                sign = nil
            }
            if sign != nil {
                end += 1
            }
            let digitsStart = end
            var number = 0.0
            while end < source.count {
                guard let digit = superscriptDigits.firstIndex(of: source[end]) else {
                    break
                }
                number = number * 10.0 + Double(digit)
                end += 1
            }
            if end == digitsStart || (end < source.count && isSuperscript(source[end])) {
                throw self.error
            }
            self.tokens.append(Token(.symbol, text: "^"))
            if let sign {
                self.tokens.append(Token(.symbol, text: sign))
            }
            self.tokens.append(Token(.number, number: number))
            return end
        }

        private func scanNumber(_ from: Int, grouping: Bool) throws -> Int {
            let source = self.source
            var index = from
            let integerStart = index
            while index < source.count && source[index].isMathDigit {
                index += 1
            }
            var integerDigits = index - integerStart
            if integerDigits >= 1 && integerDigits <= 3 {
                while index + 3 < source.count && self.isGroupSeparator(source[index], spaces: grouping) && self.isDigitGroup(index + 1) {
                    index += 4
                    integerDigits += 3
                }
            }
            var fractionDigits = 0
            let current: Character = index < source.count ? source[index] : " "
            if (current == "." || current == ",") && index + 1 < source.count && source[index + 1].isMathDigit {
                index += 1
                let fractionStart = index
                while index < source.count && source[index].isMathDigit {
                    index += 1
                }
                fractionDigits = index - fractionStart
                if current == "," && fractionDigits == 3 && integerDigits >= 1 && integerDigits <= 3 && source[integerStart] != "0" {
                    throw self.error
                }
                if self.separator == nil {
                    self.separator = current
                }
            }
            if integerDigits == 0 && fractionDigits == 0 {
                throw self.error
            }
            return index
        }

        private func isGroupSeparator(_ c: Character, spaces: Bool) -> Bool {
            return c == MathFormat.noBreakSpace || (spaces && isBlank(c))
        }

        private func isAmountAt(_ end: Int) -> Bool {
            let source = self.source
            if self.tokens.last?.type == .unit {
                return true
            }
            let index = self.skipBlanks(end)
            if index == source.count {
                return false
            }
            let c = source[index]
            if let rates = self.options.rates, Currencies.symbol(c, rates: rates) != nil {
                return true
            }
            if self.options.units && (c == "°" || Measures.symbol(c) != nil) {
                return true
            }
            if !c.isMathLetter {
                return false
            }
            let word = self.substring(index, self.unitWordEnd(index))
            if let rates = self.options.rates, Currencies.word(word, rates: rates) != nil {
                return true
            }
            return self.options.units && Measures.word(word) != nil
        }

        private func isDigitGroup(_ at: Int) -> Bool {
            let source = self.source
            return source[at].isMathDigit && source[at + 1].isMathDigit && source[at + 2].isMathDigit &&
                (at + 3 == source.count || !source[at + 3].isMathDigit)
        }

        private func peek() -> Token {
            return self.tokens[self.position]
        }

        private func next() -> Token {
            let token = self.tokens[self.position]
            self.position += 1
            return token
        }

        @discardableResult
        private func expect(_ type: TokenType) throws -> Token {
            // Never read past the closing `.end` token.
            guard self.position < self.tokens.count else {
                throw self.error
            }
            let token = self.next()
            if token.type != type {
                throw self.error
            }
            return token
        }

        private func parseExpression(_ minPrecedence: Int) throws -> Operand {
            self.depth += 1
            defer {
                self.depth -= 1
            }
            if self.depth > maxDepth {
                throw self.error
            }
            var left = try self.parseUnary()
            while true {
                let token = self.peek()
                if token.type == .of {
                    if !left.isPercent || MathOperators.precedenceMultiplicative < minPrecedence {
                        break
                    }
                    _ = self.next()
                    let right = try self.parseExpression(MathOperators.precedenceMultiplicative + 1)
                    if right.isPercent {
                        throw self.error
                    }
                    self.hasOperation = true
                    left = Operand(value: left.value * right.value, isPercent: false, unit: right.unit)
                    continue
                }
                if token.type != .symbol {
                    break
                }
                guard let op = MathOperators.infixFor(token.text) else {
                    break
                }
                if op.precedence < minPrecedence {
                    break
                }
                _ = self.next()
                let right = try self.parseExpression(op.rightAssociative ? op.precedence : op.precedence + 1)
                self.hasOperation = true
                left = try self.combine(op, left, right)
            }
            return left
        }

        private func parseConversion() throws -> Operand {
            var operand = try self.parseExpression(0)
            while self.peek().type == .conversion {
                _ = self.next()
                guard self.position < self.tokens.count else {
                    throw self.error
                }
                let target = self.next()
                if target.type == .identifier, let radix = MathOperators.bases[target.text] {
                    guard operand.unit == nil, self.position < self.tokens.count, self.peek().type == .end else {
                        throw self.error
                    }
                    self.base = radix
                    self.hasOperation = true
                    continue
                }
                guard target.type == .unit, let unit = target.unit else {
                    throw self.error
                }
                operand = try self.convert(operand, target: unit)
                self.explicitTarget = true
            }
            return operand
        }

        private func convert(_ operand: Operand, target: MathUnit) throws -> Operand {
            guard let unit = operand.unit else {
                throw self.error
            }
            self.hasOperation = true
            return Operand(value: try self.convertValue(operand.value, from: unit, to: target), isPercent: false, unit: target)
        }

        private func convertValue(_ value: Double, from: MathUnit, to: MathUnit) throws -> Double {
            if from.code == to.code {
                return value
            }
            if from.kind != to.kind {
                throw self.error
            }
            if from.kind == .currency {
                guard let rate = self.options.rates?.rate(from: from.code, to: to.code) else {
                    throw self.error
                }
                return value * rate
            }
            return to.fromBase(from.toBase(value))
        }

        private func combine(_ op: InfixOperator, _ left: Operand, _ right: Operand) throws -> Operand {
            let leftUnit = left.unit
            let rightUnit = right.unit
            if leftUnit == nil && rightUnit == nil {
                return Operand(value: op.apply(left.value, right.value, right.isPercent), isPercent: false)
            }
            var rightValue = right.value
            let unit: MathUnit?
            switch op.units {
            case .same:
                if let leftUnit, let rightUnit {
                    rightValue = try self.convertValue(rightValue, from: rightUnit, to: leftUnit)
                }
                unit = leftUnit ?? rightUnit
            case .scale:
                if leftUnit != nil && rightUnit != nil {
                    throw self.error
                }
                unit = leftUnit ?? rightUnit
            case .ratio:
                guard let leftUnit else {
                    throw self.error
                }
                if let rightUnit {
                    rightValue = try self.convertValue(rightValue, from: rightUnit, to: leftUnit)
                    unit = nil
                } else {
                    unit = leftUnit
                }
            case .none:
                throw self.error
            }
            return Operand(value: op.apply(left.value, rightValue, right.isPercent), isPercent: false, unit: unit)
        }

        private func parseUnary() throws -> Operand {
            let token = self.peek()
            if token.type == .unit {
                guard let unit = token.unit, unit.kind == .currency else {
                    throw self.error
                }
                _ = self.next()
                let operand = try self.parsePostfix()
                if operand.unit != nil || operand.isPercent {
                    throw self.error
                }
                return Operand(value: operand.value, isPercent: false, unit: unit)
            }
            if token.type == .symbol, let op = MathOperators.prefixFor(token.text) {
                _ = self.next()
                let operand = try self.parseExpression(op.precedence)
                if op.operation {
                    if operand.unit != nil {
                        throw self.error
                    }
                    self.hasOperation = true
                }
                return Operand(value: op.apply(operand.value), isPercent: operand.isPercent, unit: operand.unit)
            }
            return try self.parsePostfix()
        }

        private func parsePostfix() throws -> Operand {
            let primary = try self.parsePrimary()
            var value = primary.value
            var unit = primary.unit
            var isPercent = false
            while true {
                let token = self.peek()
                if token.type == .unit {
                    if unit != nil || isPercent {
                        throw self.error
                    }
                    _ = self.next()
                    unit = token.unit
                    continue
                }
                if token.type != .symbol {
                    break
                }
                guard let op = MathOperators.postfixFor(token.text) else {
                    break
                }
                if unit != nil {
                    throw self.error
                }
                _ = self.next()
                value = op.apply(value)
                self.hasOperation = true
                isPercent = op.percent
            }
            return Operand(value: value, isPercent: isPercent, unit: unit)
        }

        private func parsePrimary() throws -> Operand {
            if self.peek().type == .end {
                throw self.error
            }
            let token = self.next()
            switch token.type {
            case .number:
                return Operand(value: token.number, isPercent: false)
            case .leftParen:
                let inner = try self.parseConversion()
                try self.expect(.rightParen)
                return Operand(value: inner.value, isPercent: false, unit: inner.unit)
            case .identifier:
                return Operand(value: try self.parseIdentifier(token.text), isPercent: false)
            default:
                throw self.error
            }
        }

        private func parseIdentifier(_ name: String) throws -> Double {
            if let constant = MathOperators.constants[name] {
                return constant
            }
            if let radix = MathOperators.bases[name] {
                return try self.parseBase(name, radix: radix)
            }
            guard let function = MathOperators.functionFor(name) else {
                throw self.error
            }
            try self.expect(.leftParen)
            var values: [Double] = []
            if self.peek().type != .rightParen {
                values.append(try self.parseArgument())
                while self.peek().type == .argumentSeparator {
                    _ = self.next()
                    values.append(try self.parseArgument())
                }
            }
            try self.expect(.rightParen)
            if !function.arity.contains(values.count) {
                throw self.error
            }
            self.hasOperation = true
            let degrees = self.options.degrees && function.angle != .none
            if degrees && function.angle == .argument {
                values = values.map { $0 / 180.0 * Double.pi }
            }
            let value = function.apply(values)
            if function.angle == .argument && abs(value) < trigEpsilon {
                return 0.0
            }
            if degrees && function.angle == .result {
                return value * 180.0 / Double.pi
            }
            return value
        }

        private func parseBase(_ name: String, radix: Int) throws -> Double {
            let whole = self.position == 1
            try self.expect(.leftParen)
            let value: Double
            if name == MathOperators.decimal {
                let digits = try self.expect(.digits).text
                if self.peek().type == .argumentSeparator {
                    _ = self.next()
                    let from = try self.parseArgument()
                    guard from.isFinite, from == floor(from), from >= Double(MathOperators.minRadix), from <= Double(MathOperators.maxRadix) else {
                        throw self.error
                    }
                    value = try self.parseDigits(MathOperators.stripRadixPrefix(digits, radix: Int(from)), radix: Int(from))
                } else {
                    let characters = mathCharacters(digits)
                    let prefix = characters.count > 2 && characters[0] == "0" ? MathOperators.radixFor(characters[1]) : 0
                    if prefix != 0 {
                        value = try self.parseDigits(String(characters[2...]), radix: prefix)
                    } else {
                        value = try self.parseDigits(digits, radix: 10)
                    }
                }
            } else {
                value = try self.parseArgument()
            }
            try self.expect(.rightParen)
            if name != MathOperators.decimal {
                if !whole || self.peek().type != .end {
                    throw self.error
                }
                self.base = radix
            }
            self.hasOperation = true
            return value
        }

        private func parseDigits(_ digits: String, radix: Int) throws -> Double {
            if digits.isEmpty {
                throw self.error
            }
            var value: Int64 = 0
            for c in mathCharacters(digits) {
                guard let digit = digit(c, radix: radix) else {
                    throw self.error
                }
                value = value * Int64(radix) + Int64(digit)
                if Double(value) > MathFormat.maxExactInteger {
                    throw self.error
                }
            }
            return Double(value)
        }

        private func parseArgument() throws -> Double {
            let argument = try self.parseExpression(0)
            if argument.unit != nil {
                throw self.error
            }
            return argument.value
        }
    }
}
