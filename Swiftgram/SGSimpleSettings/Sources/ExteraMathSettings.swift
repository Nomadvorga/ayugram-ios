import Foundation

/// Preferences for the native inline calculator. Settings UI can write these directly;
/// the input-context factory reads the current values on every composer update.
/// This lives in SGSimpleSettings so TelegramUI and SGSettingsUI share the store.
public final class ExteraMathSettings: @unchecked Sendable {
    public enum AngleUnit: String {
        case degrees
        case radians
    }

    public enum MeasureSystem: String, CaseIterable {
        case auto
        case metric
        case imperial
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
        if MeasureSystem(rawValue: self.store.string("extera.inlineMeasureSystem")) == nil {
            let legacy = self.store.userDefaults.persistentDomain(forName: APP_GROUP_IDENTIFIER)?["extera.inlineImperial"] as? Bool
            let system = Self.measureSystem(rawValue: "", legacyImperial: legacy)
            self.store.setString(system.rawValue, "extera.inlineMeasureSystem")
        }
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

    /// Empty/unrecognised new values retain the old boolean's explicit preference.
    /// An old false becomes metric, preserving pre-migration conversion behaviour.
    /// New installations with no persisted legacy key start in automatic mode.
    public var inlineMeasureSystem: MeasureSystem {
        get {
            return MeasureSystem(rawValue: self.store.string("extera.inlineMeasureSystem")) ?? .auto
        }
        set {
            self.store.performBatchUpdates {
                self.store.setString(newValue.rawValue, "extera.inlineMeasureSystem")
                self.store.setBool(Self.usesImperial(newValue, locale: .current), "extera.inlineImperial")
            }
        }
    }

    /// Pure migration policy, also used by compatibility tests.
    public static func measureSystem(rawValue: String, legacyImperial: Bool?) -> MeasureSystem {
        if let value = MeasureSystem(rawValue: rawValue) { return value }
        if let legacyImperial { return legacyImperial ? .imperial : .metric }
        return .auto
    }

    public static func usesImperial(_ system: MeasureSystem, locale: Locale) -> Bool {
        switch system {
        case .auto:
            // Same regions as Android InlineResults.isImperial(). The UK uses
            // mixed measures and is deliberately metric in this preference.
            let region: String?
            if #available(iOS 16.0, macOS 13.0, *) { region = locale.region?.identifier }
            else { region = locale.regionCode }
            return region.map { ["US", "LR", "MM"].contains($0) } ?? false
        case .metric: return false
        case .imperial: return true
        }
    }

    public var resolvedImperial: Bool {
        return Self.usesImperial(self.inlineMeasureSystem, locale: .current)
    }

    /// Source-compatible facade for old callers/backups. Writes select an explicit system.
    public var inlineImperial: Bool {
        get { return self.resolvedImperial }
        set { self.inlineMeasureSystem = newValue ? .imperial : .metric }
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
