// Ported from exteraGram for Android (com.exteragram.messenger.inline.InlineRates), GPL v3 or later, © exteraGram.

import Foundation

final class InlineRates: CurrencyRates {
    static let retryInterval: TimeInterval = 30.0
    static let refreshInterval: TimeInterval = 5.0 * 60.0
    static let maxAge: Int64 = 24 * 60 * 60 * 1000
    static let starsRateScale = 100_000.0

    struct Environment {
        // Wall clock milliseconds, compared with the age of the stored rates.
        var now: () -> Int64
        // Monotonic seconds, used to space out the downloads.
        var uptime: () -> TimeInterval
        // App config `stars_usd_sell_rate_x1000` of the current account; Android falls back to 2000.
        var starsUsdSellRate1000: () -> Double
        // The user's "default currency" setting, empty when not chosen.
        var targetCurrency: () -> String
        var currentAccount: () -> Int64
        // Currency of the account's phone number country, see `ExchangeRates.localCurrency`.
        var accountCurrency: (Int64) -> String?
    }

    static func normalize(_ code: String) -> String {
        return code == ExchangeRates.gram ? Currencies.gram : code
    }

    private static func rateCode(_ code: String) -> String {
        return code == Currencies.gram ? ExchangeRates.gram : code
    }

    private let store: ExchangeRatesStore
    private let environment: Environment
    private let onUpdated: () -> Void

    private let lock = NSLock()
    private var requesting = false
    private var requestedAt: TimeInterval?
    private var localAccount: Int64?
    private var localCurrencyValue: String?

    // `onUpdated` runs where the store delivers its callbacks (the main queue for the shared store).
    init(store: ExchangeRatesStore = .shared, environment: Environment, onUpdated: @escaping () -> Void) {
        self.store = store
        self.environment = environment
        self.onUpdated = onUpdated
    }

    func supports(_ code: String) -> Bool {
        return code == Currencies.stars || ExchangeRates.isSupportedCurrency(InlineRates.rateCode(code))
    }

    func rate(from: String, to: String) -> Double? {
        guard let fromUsd = self.usdRate(from), let toUsd = self.usdRate(to) else {
            return nil
        }
        return toUsd == 0.0 ? nil : fromUsd / toUsd
    }

    private func usdRate(_ code: String) -> Double? {
        if code == Currencies.stars {
            let rate = self.environment.starsUsdSellRate1000()
            return rate > 0.0 ? rate / InlineRates.starsRateScale : nil
        }
        guard let state = self.store.peekCached(), self.environment.now() - state.time <= InlineRates.maxAge else {
            self.request(InlineRates.retryInterval)
            return nil
        }
        guard let rate = state.usdRate(InlineRates.rateCode(code)) else {
            self.request(InlineRates.retryInterval)
            return nil
        }
        self.request(InlineRates.refreshInterval)
        return rate
    }

    func localCurrency() -> String? {
        let target = InlineRates.normalize(self.environment.targetCurrency())
        if self.supports(target) {
            return target
        }
        let account = self.environment.currentAccount()
        self.lock.lock()
        defer { self.lock.unlock() }
        if account != self.localAccount {
            self.localAccount = account
            self.localCurrencyValue = self.environment.accountCurrency(account)
        }
        return self.localCurrencyValue
    }

    // The account's currency is looked up again on the next use.
    func invalidateLocalCurrency() {
        self.lock.lock()
        self.localAccount = nil
        self.localCurrencyValue = nil
        self.lock.unlock()
    }

    private func request(_ interval: TimeInterval) {
        let now = self.environment.uptime()
        self.lock.lock()
        if self.requesting {
            self.lock.unlock()
            return
        }
        if let requestedAt = self.requestedAt, now - requestedAt < interval {
            self.lock.unlock()
            return
        }
        self.requesting = true
        self.requestedAt = now
        self.lock.unlock()

        self.store.fetch { [weak self] _ in
            guard let self else {
                return
            }
            self.lock.lock()
            self.requesting = false
            self.lock.unlock()
            self.onUpdated()
        }
    }
}
