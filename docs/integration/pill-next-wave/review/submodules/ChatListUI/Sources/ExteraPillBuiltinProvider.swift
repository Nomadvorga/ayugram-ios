import AccountContext
import CoreLocation
import Foundation
import Postbox
import TelegramUIPreferences
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
    private var entryTimeHideTimer: Timer?
    private var entryTimeStatus: ExteraPillEntryStatus?
    private var entryTimeExpanded = false
    private var entryTimeRequestInFlight = false
    private var selectedKind: ExteraBuiltinPill?
    private var proxyStatuses: ProxyServersStatuses?
    private var entryEvents: Disposable?
    private var eventRefresh: DispatchWorkItem?
    var storageProgress: ((Double?) -> Void)?
    private var cachedStorageProgress: Double?
    private var phoneNumber = ""
    func updatePhone(_ value: String) { self.phoneNumber = value }
    var accountId: Int64 { self.context.account.id.int64 }
    var currency: String { self.currency(for: self.selectedKind ?? .gram) }
    func currency(for kind: ExteraBuiltinPill) -> String {
        ExteraPillCurrency.resolve(ExteraPillStackSettings.shared.target(kind, account: self.accountId), phone: self.phoneNumber)
    }
    var locationAuthorizationStatus: CLAuthorizationStatus { self.authorizationManager.authorizationStatus }
    var weatherSource: String { self.context.currentAppConfiguration.with { $0.data?["weather_search_username"] as? String } ?? "izweatherbot" }

    init(context: AccountContext) { self.context = context; super.init() }
    deinit { self.disposable.dispose(); self.entryEvents?.dispose(); self.eventRefresh?.cancel(); self.request?.cancel(); self.entryTimeHideTimer?.invalidate() }
    func text(_ en: String, _ ru: String) -> String { exteraPillText(self.language, en, ru) }
    func stop() {
        self.generation.cancel(); self.disposable.set(nil)
        self.proxyStatuses = nil; self.entryEvents?.dispose(); self.entryEvents = nil
        self.eventRefresh?.cancel(); self.eventRefresh = nil
        self.storageProgress?(nil)
        self.request?.cancel(); self.request = nil
        self.locationAuthorization?.delegate = nil; self.locationAuthorization = nil
        self.authorizationAction = nil
        self.entryTimeHideTimer?.invalidate(); self.entryTimeHideTimer = nil
        self.entryTimeExpanded = false; self.entryTimeRequestInFlight = false; self.selectedKind = nil
    }
    func start(_ kind: ExteraBuiltinPill, force: Bool = false) {
        self.stop()
        self.selectedKind = kind
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
        let weatherSettings = ExteraPillStackSettings.shared.weather(account: self.accountId)
        let cacheKey = self.currency + "." + self.language + "." + (kind == .weather ? self.weatherSource + String(describing: weatherSettings) + TimeZone.current.identifier : "")
        let weatherAuthorized = kind != .weather || !weatherSettings.current || [.authorizedAlways, .authorizedWhenInUse].contains(self.locationAuthorizationStatus)
        if kind != .proxy, kind != .entryTime, weatherAuthorized, !force, let cached = self.cache[kind], cached.2 == cacheKey, Date().timeIntervalSince(cached.1) < ttl {
            if kind == .storage { self.storageProgress?(self.cachedStorageProgress) }
            publish(cached.0); return
        }
        let success: (String) -> Void = { [weak self] value in
            guard let self, self.generation.accepts(ticket) else { return }
            self.cache[kind] = (value, Date(), cacheKey); publish(value)
        }
        if kind == .entryTime, !force, !ExteraPillStackSettings.shared.entryTimeAutoRefresh(account: self.accountId) {
            publish(""); return
        }
        if kind == .entryTime {
            let cached = ExteraPillStackSettings.shared.entryTimeAutoRefresh(account: self.accountId) ? self.entryTimeStatus : nil
            publish(cached.map { self.entryTimeText($0) } ?? "…")
        } else { publish(kind.title(self.language) + " …") }
        switch kind {
        case .weather:
            let weather: Signal<WeatherDataState, NoError>
            if weatherSettings.current {
                guard CLLocationManager.locationServicesEnabled() else { publish(self.text("Enable Location Services", "Включите службы геопозиции")); return }
                weather = Weather.getWeatherData(context: self.context, load: true)
            }
            else {
                weather = Weather.requestWeatherData(context: self.context, location: CLLocationCoordinate2D(latitude: weatherSettings.latitude, longitude: weatherSettings.longitude))
                |> map { $0.map { WeatherDataState.loaded($0) } ?? .none }
            }
            self.disposable.set((weather |> deliverOnMainQueue).start(next: { [weak self] state in
                guard let self else { return }
                switch state {
                case let .loaded(data):
                    guard data.temperature.isFinite, (-150 ... 100).contains(data.temperature) else { publish(self.text("Weather · Invalid source data", "Погода · Ошибка источника")); return }
                    success("\(String(data.emoji.prefix(8))) " + ExteraPillWeather.temperature(data.temperature, timezone: TimeZone.current.identifier))
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
                    let value = try ExteraPillCurrency.price(data: result.get(), base: base, target: target)
                    success(value)
                } catch {
                    publish(kind.title(self.language) + self.text(" · Rate unavailable", " · Курс недоступен"))
                }
            }
            self.request = request; request.start()
        case .storage:
            self.disposable.set((exteraPillStorageUsage(context: self.context) |> deliverOnMainQueue).start(next: { [weak self] stats in
                guard let self, self.generation.accepts(ticket) else { return }
                self.cachedStorageProgress = stats.occupiedFraction
                self.storageProgress?(stats.occupiedFraction)
                success(ByteCountFormatter.string(fromByteCount: stats.cacheBytes, countStyle: .file))
            }))
        case .proxy:
            let settings = self.context.sharedContext.accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
            |> map { data -> ProxySettings in
                data.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self) ?? .defaultSettings
            }
            let statuses = ProxyServersStatuses(network: self.context.account.network, servers: settings |> map { $0.effectiveActiveServer.map { [$0] } ?? [] })
            self.proxyStatuses = statuses
            self.disposable.set((combineLatest(settings, statuses.statuses(), self.context.account.networkState) |> deliverOnMainQueue).start(next: { [weak self] settings, statuses, state in
                guard let self else { return }
                guard let active = settings.effectiveActiveServer else { publish(self.text("Proxy", "Прокси")); return }
                switch state {
                case .online, .updating:
                    if case let .available(seconds)? = statuses[active], seconds.isFinite, seconds > 0 {
                        publish("\(min(9999, max(0, Int(min(seconds * 1000, 9999))))) " + self.text("ms", "мс"))
                    } else { publish(self.text("Connected", "Подключён")) }
                case .connecting, .waitingForNetwork: publish(self.text("Connecting", "Подключение"))
                }
            }))
        case .entryTime:
            if ExteraPillStackSettings.shared.entryTimeAutoRefresh(account: self.accountId) {
                self.entryEvents = exteraPresenceEvents(account: self.context.account).start(next: { [weak self] fetch in
                    guard let self, self.generation.accepts(ticket) else { return }
                    self.eventRefresh?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, !self.entryTimeRequestInFlight else { return }
                        self.start(.entryTime, force: true)
                    }
                    self.eventRefresh = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + (fetch ? 0 : 0.25), execute: work)
                })
            }
            if !force, let cached = exteraCachedEntryStatusOnAttach(account: self.context.account) {
                self.entryTimeStatus = cached; publish(self.entryTimeText(cached)); return
            }
            self.entryTimeRequestInFlight = true
            self.disposable.set((exteraRequestAccountEntryStatus(account: self.context.account) |> deliverOnMainQueue).start(next: { [weak self] status in
                guard let self, self.generation.accepts(ticket) else { return }
                self.entryTimeRequestInFlight = false
                if let status { self.entryTimeStatus = status }
                publish(self.entryTimeStatus.map { self.entryTimeText($0) } ?? self.text("Status unavailable", "Статус недоступен"))
                self.entryTimeExpanded = true
                if !ExteraPillStackSettings.shared.entryTimeAutoRefresh(account: self.accountId) {
                    self.entryTimeHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                        guard let self, self.generation.accepts(ticket) else { return }
                        self.entryTimeExpanded = false; self.entryTimeHideTimer = nil; publish("")
                    }
                }
            }))
        }
    }
    /// Non-periodic APK mode ignores repeated taps while the result is expanded or loading.
    func entryTimeTapped() {
        guard self.selectedKind == .entryTime, !self.entryTimeRequestInFlight,
              !self.entryTimeExpanded || ExteraPillStackSettings.shared.entryTimeAutoRefresh(account: self.accountId) else { return }
        self.start(.entryTime, force: true)
    }
    private func entryTimeText(_ status: ExteraPillEntryStatus) -> String {
        let now = self.context.account.network.getApproximateRemoteTimestamp()
        switch status.presentation(serverNow: now) {
        case .online: return self.text("Online", "В сети")
        case .longAgo: return self.text("A long time ago", "Был(а) давно")
        case let .lastSeen(timestamp):
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: exteraPillLanguageCode(self.language))
            formatter.timeStyle = .short
            formatter.dateStyle = Calendar.current.isDate(date, inSameDayAs: Date(timeIntervalSince1970: TimeInterval(now))) ? .none : .short
            return formatter.string(from: date)
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
