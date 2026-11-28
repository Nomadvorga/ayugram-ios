// Ported from exteraGram for Android (com.exteragram.messenger.inline.InlineResults), GPL v3 or later, © exteraGram.

import Foundation

// The user's inline results settings, as plain values.
public struct InlineResultsConfiguration: Equatable {
    public var calculator: Bool
    public var currencies: Bool
    public var units: Bool
    public var timeZones: Bool
    public var degrees: Bool
    public var grouping: Bool
    public var imperial: Bool
    public var decimalSeparator: Character
    // App language code, for place names.
    public var language: String

    public init(calculator: Bool = true, currencies: Bool = true, units: Bool = true, timeZones: Bool = false, degrees: Bool = true, grouping: Bool = true, imperial: Bool = false, decimalSeparator: Character = ".", language: String = "en") {
        self.calculator = calculator
        self.currencies = currencies
        self.units = units
        self.timeZones = timeZones
        self.degrees = degrees
        self.grouping = grouping
        self.imperial = imperial
        self.decimalSeparator = decimalSeparator
        self.language = language
    }

    public var isEnabled: Bool {
        return self.calculator || self.currencies || self.units || self.timeZones
    }
}

// `insertAt` is a UTF-16 offset, the unit of NSRange and UITextView.
public struct InlineMathSuggestion: Equatable {
    public let insertAt: Int
    public let insertText: String
    public let value: String
}

public final class InlineResultsEngine {
    public struct Environment {
        // App config `stars_usd_sell_rate_x1000` of the current account, 0 when unknown.
        public var starsUsdSellRate1000: () -> Double
        // The "default currency" setting, empty for automatic.
        public var targetCurrency: () -> String
        public var currentAccount: () -> Int64
        // Currency of the account's phone number country, see `localCurrency(countries:localeCountry:)`.
        public var accountCurrency: (Int64) -> String?

        public init(starsUsdSellRate1000: @escaping () -> Double, targetCurrency: @escaping () -> String, currentAccount: @escaping () -> Int64, accountCurrency: @escaping (Int64) -> String?) {
            self.starsUsdSellRate1000 = starsUsdSellRate1000
            self.targetCurrency = targetCurrency
            self.currentAccount = currentAccount
            self.accountCurrency = accountCurrency
        }
    }

    private static let imperialRegions: Set<String> = ["US", "LR", "MM"]

    private let rates: InlineRates
    var now: Date?
    var localZone: TimeZone?
    var places: ((String, String) -> String?) = { InlineZonePlaces.shared.lookup($0, locale: $1) }

    // `onRatesUpdated` runs on the main queue when exchange rates arrive: the suggestion may have changed.
    public init(environment: Environment, onRatesUpdated: @escaping () -> Void) {
        self.rates = InlineRates(environment: InlineRates.Environment(
            now: { Int64(Date().timeIntervalSince1970 * 1000.0) },
            uptime: { ProcessInfo.processInfo.systemUptime },
            starsUsdSellRate1000: environment.starsUsdSellRate1000,
            targetCurrency: environment.targetCurrency,
            currentAccount: environment.currentAccount,
            accountCurrency: environment.accountCurrency
        ), onUpdated: onRatesUpdated)
    }

    init(rates: InlineRates) {
        self.rates = rates
    }

    public static func isImperial(regionCode: String?) -> Bool {
        return regionCode.map { self.imperialRegions.contains($0.uppercased()) } ?? false
    }

    public static func decimalSeparator(language: String) -> Character {
        return Locale(identifier: language).decimalSeparator?.first ?? "."
    }

    // `countries` are the ISO region codes sharing the account's calling code, in the phone table's order.
    public static func localCurrency(countries: [String], localeCountry: String?) -> String? {
        return ExchangeRates.localCurrency(countries: countries, localeCountry: localeCountry)
    }

    // The ISO region codes that share the calling code of a phone number, in the order of the table.
    // `table` is the text of the app's PhoneCountries.txt: one "code;region;pattern;name" per line.
    public static func countries(forPhone phone: String, phoneCountries table: String) -> [String] {
        let digits = String(String.UnicodeScalarView(phone.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }))
        if digits.isEmpty {
            return []
        }
        var regions: [String: [String]] = [:]
        var longest = 0
        for line in table.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2, !fields[0].isEmpty, fields[0].unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }), !fields[1].isEmpty else {
                continue
            }
            let code = String(fields[0])
            regions[code, default: []].append(String(fields[1]))
            longest = max(longest, code.count)
        }
        var length = min(longest, digits.count)
        while length >= 1 {
            if let found = regions[String(digits.prefix(length))] {
                return found
            }
            length -= 1
        }
        return []
    }

    // Call when the answer of `Environment.accountCurrency` has changed, for example once the phone number is known.
    public func invalidateAccountCurrency() {
        self.rates.invalidateLocalCurrency()
    }

    // Starts collecting place names in the background, so the first time zone lookup has them.
    public func prepare(_ configuration: InlineResultsConfiguration) {
        if configuration.timeZones {
            InlineZonePlaces.shared.prepare(locale: configuration.language)
        }
    }

    private func options(_ configuration: InlineResultsConfiguration) -> MathOptions {
        var zones: TimeZoneOptions?
        if configuration.timeZones {
            let language = configuration.language
            let places = self.places
            zones = TimeZoneOptions(local: self.localZone ?? TimeZone.current, now: self.now, places: { places($0, language) })
        }
        return MathOptions(
            decimalSeparator: configuration.decimalSeparator,
            rates: configuration.currencies ? self.rates : nil,
            localCurrency: configuration.currencies ? self.rates.localCurrency() : nil,
            arithmetic: configuration.calculator,
            units: configuration.units,
            degrees: configuration.degrees,
            grouping: configuration.grouping,
            timeZones: zones,
            imperial: configuration.imperial
        )
    }

    // The result for the expression that ends with "=" right before the caret (a UTF-16 offset).
    public func suggestion(in text: String, caret: Int, configuration: InlineResultsConfiguration) -> InlineMathSuggestion? {
        let utf16 = text.utf16
        guard configuration.isEnabled, caret >= 2, caret <= utf16.count else {
            return nil
        }
        let caretIndex = utf16.index(utf16.startIndex, offsetBy: caret)
        guard utf16[utf16.index(before: caretIndex)] == 0x3D, let scalarIndex = caretIndex.samePosition(in: text.unicodeScalars) else {
            return nil
        }
        let scalarCaret = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: scalarIndex)
        guard let found = MathExpression.suggestionAt(text, caret: scalarCaret, options: self.options(configuration)) else {
            return nil
        }
        return InlineMathSuggestion(insertAt: caret, insertText: found.insertText, value: found.value)
    }
}

// What the message field does with a suggestion: Space inserts it, Backspace right after takes it back.
public final class InlineMathSession {
    public struct Edit: Equatable {
        public let range: NSRange
        public let replacement: String
        // Where the caret goes after the edit.
        public let caret: Int
        let isCommit: Bool
    }

    private let engine: InlineResultsEngine
    public private(set) var suggestion: InlineMathSuggestion?
    private var undoRange: NSRange?
    private var suppressedAt: Int?
    private var isApplying = false

    public init(engine: InlineResultsEngine) {
        self.engine = engine
    }

    // For changes the session did not make itself.
    public func textDidChange() {
        if self.isApplying {
            return
        }
        self.undoRange = nil
        self.suppressedAt = nil
    }

    public func selectionDidChange(_ selection: NSRange) {
        if self.isApplying {
            return
        }
        if selection.location != self.suppressedAt {
            self.suppressedAt = nil
        }
        if let undoRange = self.undoRange, selection.length != 0 || selection.location != NSMaxRange(undoRange) {
            self.undoRange = nil
        }
    }

    public func reset() {
        self.suggestion = nil
        self.undoRange = nil
        self.suppressedAt = nil
    }

    // For a suggestion the field could not show: Space must stay a space.
    public func dismissSuggestion() {
        self.suggestion = nil
    }

    // `configuration` is nil while the feature is switched off. The suggestion is offered only at the end of
    // a paragraph, where it can be shown after the caret without moving any text.
    @discardableResult
    public func refresh(text: String, selection: NSRange, isActive: Bool, hasMarkedText: Bool, configuration: InlineResultsConfiguration?) -> InlineMathSuggestion? {
        self.suggestion = nil
        guard let configuration, self.suppressedAt == nil, isActive, !hasMarkedText, selection.length == 0, selection.location > 0 else {
            return nil
        }
        let utf16 = text.utf16
        if selection.location < utf16.count {
            let next = utf16[utf16.index(utf16.startIndex, offsetBy: selection.location)]
            if next != 0x0A {
                return nil
            }
        }
        self.suggestion = self.engine.suggestion(in: text, caret: selection.location, configuration: configuration)
        return self.suggestion
    }

    // The edit to make instead of the one the keyboard asks for, or nil to let the keyboard's edit through.
    public func edit(forReplacing range: NSRange, with replacement: String, selection: NSRange) -> Edit? {
        guard selection.length == 0 else {
            return nil
        }
        if replacement == " " || replacement == "\t" {
            guard let suggestion = self.suggestion, range.length == 0, range.location == suggestion.insertAt, selection.location == suggestion.insertAt else {
                return nil
            }
            return Edit(range: NSRange(location: suggestion.insertAt, length: 0), replacement: suggestion.insertText, caret: suggestion.insertAt + suggestion.insertText.utf16.count, isCommit: true)
        }
        if replacement.isEmpty, range.length > 0, let undoRange = self.undoRange {
            guard NSMaxRange(range) == NSMaxRange(undoRange), selection.location == NSMaxRange(undoRange), range.location >= undoRange.location else {
                return nil
            }
            return Edit(range: undoRange, replacement: "", caret: undoRange.location, isCommit: false)
        }
        return nil
    }

    // `apply` changes the text and the caret; the change notifications it causes are not treated as typing.
    public func perform(_ edit: Edit, apply: (Edit) -> Void) {
        self.isApplying = true
        apply(edit)
        self.isApplying = false
        self.suggestion = nil
        if edit.isCommit {
            self.undoRange = NSRange(location: edit.range.location, length: edit.replacement.utf16.count)
        } else {
            self.undoRange = nil
            self.suppressedAt = edit.caret
        }
    }
}
