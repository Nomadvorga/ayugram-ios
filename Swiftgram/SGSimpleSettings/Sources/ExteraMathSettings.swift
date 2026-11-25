import Foundation

/// Preferences for the native inline calculator. Settings UI can write these directly;
/// the input-context factory reads the current values on every composer update.
/// This lives in SGSimpleSettings so TelegramUI and SGSettingsUI share the store.
public final class ExteraMathSettings: @unchecked Sendable {
    public enum AngleUnit: String {
        case degrees
        case radians
    }

    public static let shared = ExteraMathSettings()

    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: [
            "extera.inlineResults": true,
            "extera.inlineMathResult": true,
            "extera.inlineDigitGrouping": true,
            "extera.inlineAngleUnit": AngleUnit.degrees.rawValue,
            "extera.inlineUnits": true,
            "extera.inlineCurrencies": true,
            "extera.inlineTimeZones": true,
            "extera.inlineImperial": false,
            "extera.inlineTargetCurrency": "auto",
        ])
    }

    /// Master switch for native inline results. Defaults to true, as on exteraGram.
    public var inlineResults: Bool {
        get { return self.store.bool("extera.inlineResults") }
        set { self.store.setBool(newValue, "extera.inlineResults") }
    }

    /// Enables arithmetic suggestions after `=`. Defaults to true.
    public var inlineMathResult: Bool {
        get { return self.store.bool("extera.inlineMathResult") }
        set { self.store.setBool(newValue, "extera.inlineMathResult") }
    }

    /// Groups result digits with nonbreaking spaces. Defaults to true.
    public var inlineDigitGrouping: Bool {
        get { return self.store.bool("extera.inlineDigitGrouping") }
        set { self.store.setBool(newValue, "extera.inlineDigitGrouping") }
    }

    /// Applies to trigonometric arguments and inverse-trigonometric results.
    /// Defaults to degrees. Persisted as `degrees` or `radians`.
    public var inlineAngleUnit: AngleUnit {
        get {
            return AngleUnit(rawValue: self.store.string("extera.inlineAngleUnit")) ?? .degrees
        }
        set { self.store.setString(newValue.rawValue, "extera.inlineAngleUnit") }
    }

    public var inlineUnits: Bool {
        get { return self.store.bool("extera.inlineUnits") }
        set { self.store.setBool(newValue, "extera.inlineUnits") }
    }

    /// Enables rate-backed results; the endpoint receives no draft or amounts.
    public var inlineCurrencies: Bool {
        get { return self.store.bool("extera.inlineCurrencies") }
        set { self.store.setBool(newValue, "extera.inlineCurrencies") }
    }

    public var inlineTimeZones: Bool {
        get { return self.store.bool("extera.inlineTimeZones") }
        set { self.store.setBool(newValue, "extera.inlineTimeZones") }
    }

    /// Choose imperial counterparts for implicit unit conversions.
    public var inlineImperial: Bool {
        get { return self.store.bool("extera.inlineImperial") }
        set { self.store.setBool(newValue, "extera.inlineImperial") }
    }

    /// ISO currency code (or GRAM/BTC/ETH/SOL/USDT), or `auto` for device locale.
    /// Unsupported codes are safely resolved to USD by the engine.
    public var inlineTargetCurrency: String {
        get { return self.store.string("extera.inlineTargetCurrency") }
        set {
            let code = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard code.lowercased() == "auto" || (3...4).contains(code.count) && code.unicodeScalars.allSatisfy({ (65...90).contains(Int($0.value)) || (97...122).contains(Int($0.value)) }) else { return }
            self.store.setString(code.lowercased() == "auto" ? "auto" : code.uppercased(), "extera.inlineTargetCurrency")
        }
    }

    public var resolvedTargetCurrency: String {
        let value = self.inlineTargetCurrency
        return value == "auto" ? Locale.current.currencyCode ?? "USD" : value
    }
}
