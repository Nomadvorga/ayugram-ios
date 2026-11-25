import Foundation
#if canImport(SGSimpleSettings)
import SGSimpleSettings
#endif

public extension ExteraMathEngine.Options {
    /// Keep settings examples and composer conversions on the same preference policy.
    /// Help remains readable when a feature or the master switch is disabled.
    init(settings: ExteraMathSettings, preview: Bool = false) {
        self.init(
            degrees: settings.inlineAngleUnit == .degrees,
            grouping: settings.inlineDigitGrouping,
            decimalSeparator: Locale.current.decimalSeparator ?? ".",
            units: preview || settings.inlineUnits,
            currencies: preview || settings.inlineCurrencies,
            timeZones: preview || settings.inlineTimeZones,
            arithmetic: preview || settings.inlineMathResult,
            imperial: settings.resolvedImperial,
            localCurrency: settings.resolvedTargetCurrency,
            currencyRates: ExteraMathCurrencyRequest.cached()
        )
    }
}
