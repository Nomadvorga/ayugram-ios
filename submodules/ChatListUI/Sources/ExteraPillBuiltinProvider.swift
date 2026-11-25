import AccountContext
import CoreLocation
import Foundation
import SGSimpleSettings
import SwiftSignalKit
import TelegramCore
import Weather

/// One account and one selected widget per host. No hidden providers, detached requests or global
/// weather/account caches. Remote sources require a separately recorded, account-specific grant.
final class ExteraPillBuiltinProvider: NSObject, CLLocationManagerDelegate {
    let context: AccountContext
    var language = "en"
    var changed: ((String) -> Void)?
    private var generation = ExteraPillProviderGeneration()
    private let disposable = MetaDisposable()
    private var request: ExteraPillRateRequest?
    private var locationAuthorization: CLLocationManager?
    private lazy var authorizationManager = CLLocationManager()
    private var cache: [ExteraBuiltinPill: (String, Date, String)] = [:]
    private var authorizationAction: (() -> Void)?
    var accountId: Int64 { self.context.account.id.int64 }
    var currency: String { ExteraPillStackSettings.shared.currency(account: self.accountId) }
    var locationAuthorizationStatus: CLAuthorizationStatus { self.authorizationManager.authorizationStatus }
    var weatherSource: String { self.context.currentAppConfiguration.with { $0.data?["weather_search_username"] as? String } ?? "izweatherbot" }

    init(context: AccountContext) { self.context = context; super.init() }
    deinit { self.disposable.dispose(); self.request?.cancel() }
    func text(_ en: String, _ ru: String) -> String { exteraPillText(self.language, en, ru) }
    func stop() {
        self.generation.cancel(); self.disposable.set(nil)
        self.request?.cancel(); self.request = nil
        self.locationAuthorization?.delegate = nil; self.locationAuthorization = nil
        self.authorizationAction = nil
    }
    func start(_ kind: ExteraBuiltinPill, force: Bool = false) {
        self.stop()
        let ticket = self.generation.begin(kind.id)
        let publish: (String) -> Void = { [weak self] value in
            guard let self, self.generation.accepts(ticket) else { return }
            self.changed?(value)
        }
        let granted: (String) -> Bool = { ExteraPillStackSettings.shared.allowed($0, account: self.accountId) }
        if kind == .weather && !ExteraPillStackSettings.shared.allowsWeather(source: self.weatherSource, account: self.accountId) {
            publish(self.text("Weather · Tap to allow", "Погода · Разрешить")); return
        }
        if [.gram, .btc, .usd].contains(kind) && !granted("rates") {
            publish(kind.title(self.language) + self.text(" · Tap to allow", " · Разрешить")); return
        }
        let ttl: TimeInterval = kind == .weather ? 1200 : (kind == .storage ? 180 : 300)
        let cacheKey = self.currency + "." + self.language + "." + (kind == .weather ? self.weatherSource : "")
        let weatherAuthorized = kind != .weather || [.authorizedAlways, .authorizedWhenInUse].contains(self.locationAuthorizationStatus)
        if kind != .proxy, weatherAuthorized, !force, let cached = self.cache[kind], cached.2 == cacheKey, Date().timeIntervalSince(cached.1) < ttl {
            publish(cached.0); return
        }
        let success: (String) -> Void = { [weak self] value in
            guard let self, self.generation.accepts(ticket) else { return }
            self.cache[kind] = (value, Date(), cacheKey); publish(value)
        }
        publish(kind.title(self.language) + " …")
        switch kind {
        case .weather:
            self.disposable.set((Weather.getWeatherData(context: self.context, load: true) |> deliverOnMainQueue).start(next: { [weak self] state in
                guard let self else { return }
                switch state {
                case let .loaded(data):
                    guard data.temperature.isFinite, (-150 ... 100).contains(data.temperature) else { publish(self.text("Weather · Invalid source data", "Погода · Ошибка источника")); return }
                    success("\(String(data.emoji.prefix(8))) \(Int(data.temperature.rounded()))°C")
                case .fetching: break
                case .notDetermined: publish(self.text("Weather · Allow location", "Погода · Геопозиция"))
                case .notAllowed: publish(self.text("Weather · Location denied", "Погода · Нет доступа"))
                case .none, .notPreloaded: publish(self.text("Weather · Unavailable", "Погода · Недоступно"))
                }
            }))
        case .gram, .btc, .usd:
            let base = kind == .gram ? "TON" : (kind == .btc ? "BTC" : "USD")
            let target = self.currency
            let request = ExteraPillRateRequest { [weak self] result in
                guard let self, self.generation.accepts(ticket) else { return }
                do {
                    let value = try ExteraPillExchangeRate.value(data: result.get(), base: base, target: target, locale: Locale(identifier: exteraPillLanguageCode(self.language)))
                    success(kind.title(self.language) + " " + value)
                } catch {
                    publish(kind.title(self.language) + self.text(" · Rate unavailable", " · Курс недоступен"))
                }
            }
            self.request = request; request.start()
        case .storage:
            self.disposable.set((self.context.engine.resources.collectStorageUsageStats() |> deliverOnMainQueue).start(next: { stats in
                let bytes = stats.totalStats.categories.values.reduce(Int64(0)) { $0 + $1.size }
                success(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }))
        case .proxy:
            self.disposable.set((self.context.account.networkState |> deliverOnMainQueue).start(next: { [weak self] state in
                guard let self else { return }
                switch state {
                case let .online(proxy), let .updating(proxy):
                    if let proxy, proxy.hasConnectionIssues {
                        publish(self.text("Proxy · Connection issues", "Прокси · Проблемы соединения"))
                    } else {
                        publish(proxy == nil ? self.text("Proxy · Off", "Прокси · Выкл.") : self.text("Proxy · Connected", "Прокси · Подключён"))
                    }
                case let .connecting(proxy):
                    publish(proxy == nil ? self.text("Proxy · Off", "Прокси · Выкл.") : self.text("Proxy · Connecting", "Прокси · Подключение"))
                case .waitingForNetwork: publish(self.text("Proxy · No network", "Прокси · Нет сети"))
                }
            }))
        case .entryTime:
            publish(self.text("Entry Time · Unavailable", "Время захода · Недоступно"))
        }
    }
    /// Called only after the user accepted the weather source explanation.
    func requestLocationAuthorization(completion: @escaping () -> Void) {
        let manager = self.authorizationManager
        self.locationAuthorization = manager; self.authorizationAction = completion
        manager.delegate = self; manager.requestWhenInUseAuthorization()
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined, manager === self.locationAuthorization else { return }
        let action = self.authorizationAction
        self.authorizationAction = nil; manager.delegate = nil; self.locationAuthorization = nil
        action?()
    }
}

/// Bounded, ephemeral request to the same rates source used by Android. No cookies, credentials,
/// account identifiers or location, and no redirects to another origin.
private final class ExteraPillRateRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var completion: ((Result<Data, Error>) -> Void)?
    private var session: URLSession?
    private var body = Data()
    init(completion: @escaping (Result<Data, Error>) -> Void) { self.completion = completion }
    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        session.dataTask(with: URL(string: "https://api.coinbase.com/v2/exchange-rates?currency=USD")!).resume()
    }
    func cancel() { self.completion = nil; self.session?.invalidateAndCancel(); self.session = nil; self.body.removeAll() }
    private func finish(_ result: Result<Data, Error>) {
        let completion = self.completion; self.cancel(); completion?(result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.expectedContentLength <= 512 * 1024 else {
            completionHandler(.cancel); self.finish(.failure(ExteraPillError.network)); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= 512 * 1024 - self.body.count else { self.finish(.failure(ExteraPillError.responseTooLarge)); return }
        self.body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); self.finish(.failure(ExteraPillError.network))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { self.finish(.failure(error)) } else { self.finish(.success(self.body)) }
    }
}
