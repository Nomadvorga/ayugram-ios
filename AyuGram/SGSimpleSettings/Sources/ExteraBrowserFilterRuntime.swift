import Foundation

public struct ExteraBrowserFilterStatus {
    public var updating: Bool = false
    public var fetchedAt: Date?
    public var expiresAt: Date?
    public var ruleCount: Int = 0
    public var unsupportedRules: Int = 0
    public var cosmeticRules: Int = 0
    public var omittedRules: Int = 0
    public var message: String?
    public var cached: Bool = false
}

private struct ExteraBrowserFilterCache: Codable {
    var converterVersion: Int
    var url: String
    var fetchedAt: Date
    var expiresAt: Date
    var eTag: String?
    var lastModified: String?
    var conversion: ExteraBrowserConversion
}

/// Main-queue owner of subscription state. Disk I/O and bounded ABP conversion run on one worker.
/// Cached rules are available offline; a failed update never removes the last successful version.
public final class ExteraBrowserFilterRuntime: @unchecked Sendable {
    public static let shared = ExteraBrowserFilterRuntime()
    public static let didChangeNotification = Notification.Name("ExteraBrowserFilterRuntimeDidChange")
    private let worker = DispatchQueue(label: "exteragram.browser.filters", qos: .utility)
    private var settingsObserver: NSObjectProtocol?
    private var loaded = false
    private var loading = false
    private var caches: [String: ExteraBrowserFilterCache] = [:]
    private var states: [String: ExteraBrowserFilterStatus] = [:]
    private var jobs: [String: Job] = [:]
    private var pending: [String] = []
    private var retryAfter: [String: Date] = [:]
    private var customText: String?
    private var customRules: [ExteraBrowserContentRule] = []
    private var customToken = UUID()
    private var rules: [ExteraBrowserContentRule] = []
    private var sourceVersion: UInt64 = 0
    private var cacheDirectory: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("exteragram-browser-filters-v1", isDirectory: true)
    }

    private final class Job {
        let subscription: ExteraBrowserSubscription
        let token = UUID()
        var request: ExteraBrowserFilterDownload?
        init(_ subscription: ExteraBrowserSubscription) { self.subscription = subscription }
    }

    private init() {}

    /// Call on the main queue when a browser or the subscription editor opens. Never delays navigation.
    public func start() {
        precondition(Thread.isMainThread)
        if self.settingsObserver == nil {
            self.settingsObserver = NotificationCenter.default.addObserver(forName: ExteraBrowserFilters.didChangeNotification, object: nil, queue: .main, using: { [weak self] _ in self?.reconcile() })
        }
        guard !self.loading else { return }
        if self.loaded { self.reconcile(); return }
        self.loading = true
        let subscriptions = ExteraBrowserFilters.shared.subscriptions
        let directory = self.cacheDirectory
        self.worker.async {
            var caches: [String: ExteraBrowserFilterCache] = [:]
            // Only remove our own UUID cache/temp files; unrelated browser caches are untouched.
            let retained = Set(subscriptions.map { $0.id + ".json" })
            if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in files where !retained.contains(file.lastPathComponent) {
                    let prefix = String(file.lastPathComponent.prefix(36))
                    if UUID(uuidString: prefix) != nil && ["json", "tmp"].contains(file.pathExtension) { try? FileManager.default.removeItem(at: file) }
                }
            }
            for subscription in subscriptions {
                let url = directory.appendingPathComponent(subscription.id + ".json")
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 12 * 1024 * 1024,
                   let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(ExteraBrowserFilterCache.self, from: data),
                   cache.converterVersion == ExteraBrowserABPConverter.version, cache.url == subscription.url,
                   cache.conversion.rules.count <= ExteraBrowserFilters.maximumRulesPerList {
                    caches[subscription.id] = cache
                }
            }
            DispatchQueue.main.async {
                self.loading = false
                self.loaded = true
                let current = ExteraBrowserFilters.shared.subscriptions
                for (id, cache) in caches where current.contains(where: { $0.id == id && $0.url == cache.url }) { self.caches[id] = cache }
                self.reconcile()
            }
        }
    }

    /// In-memory snapshot for BrowserAdBlocker. Ordering is blocks first, then all list allow rules.
    public var currentRules: [ExteraBrowserContentRule] {
        precondition(Thread.isMainThread)
        return self.rules
    }

    public var revision: UInt64 {
        precondition(Thread.isMainThread)
        return self.sourceVersion
    }

    public func status(id: String) -> ExteraBrowserFilterStatus {
        precondition(Thread.isMainThread)
        var state = self.states[id] ?? ExteraBrowserFilterStatus()
        if let cache = self.caches[id] {
            state.cached = true
            state.fetchedAt = cache.fetchedAt
            state.expiresAt = cache.expiresAt
            state.ruleCount = cache.conversion.rules.count
            state.unsupportedRules = cache.conversion.unsupportedRules
            state.cosmeticRules = cache.conversion.cosmeticRules
            state.omittedRules = cache.conversion.omittedRules
        }
        return state
    }

    public func update(id: String? = nil) {
        precondition(Thread.isMainThread)
        self.start()
        guard self.loaded else {
            // Loading caches is short and asynchronous; schedule the explicit request after it.
            self.worker.async { DispatchQueue.main.async { self.update(id: id) } }
            return
        }
        let subscriptions = ExteraBrowserFilters.shared.subscriptions.filter { $0.enabled && (id == nil || $0.id == id) }
        // A manual update also retries WebKit compilation, including a previously failed source.
        self.sourceVersion &+= 1
        if ExteraBrowserSettings.shared.adBlockingEnabled { NotificationCenter.default.post(name: ExteraBrowserSettings.didChangeNotification, object: nil) }
        for subscription in subscriptions {
            self.retryAfter.removeValue(forKey: subscription.id)
            self.enqueue(subscription)
        }
        self.pump()
    }

    public func cancel(id: String? = nil) {
        precondition(Thread.isMainThread)
        let identifiers = id.map { [$0] } ?? Array(Set(Array(self.jobs.keys) + self.pending))
        for identifier in identifiers {
            self.pending.removeAll { $0 == identifier }
            let job = self.jobs.removeValue(forKey: identifier)
            job?.request?.cancel()
            self.states[identifier] = self.makeStatus(updating: false, message: ExteraBrowserFilterError.cancelled.localizedDescription)
            self.retryAfter[identifier] = Date().addingTimeInterval(3600)
        }
        self.notify()
        self.pump()
    }

    /// WebKit lives in BrowserUI; report its compiler failure in the shared settings status.
    public func reportCompilationError(_ message: String?) {
        precondition(Thread.isMainThread)
        guard self.compilationError != message else { return }
        self.compilationError = message
        self.notify()
    }

    public private(set) var compilationError: String?
    public private(set) var customRulesError: String?

    private func reconcile() {
        guard self.loaded else { return }
        let subscriptions = ExteraBrowserFilters.shared.subscriptions
        let identifiers = Set(subscriptions.map { $0.id })
        self.states = self.states.filter { identifiers.contains($0.key) }
        self.retryAfter = self.retryAfter.filter { identifiers.contains($0.key) }
        for (id, job) in Array(self.jobs) where !subscriptions.contains(where: { $0 == job.subscription && $0.enabled }) {
            self.jobs.removeValue(forKey: id)?.request?.cancel()
            self.states.removeValue(forKey: id)
        }
        self.pending.removeAll { id in !subscriptions.contains(where: { $0.id == id && $0.enabled }) }
        for (id, cache) in Array(self.caches) where !subscriptions.contains(where: { $0.id == id && $0.url == cache.url }) {
            self.caches.removeValue(forKey: id)
            self.states.removeValue(forKey: id)
            self.retryAfter.removeValue(forKey: id)
            let file = self.cacheDirectory.appendingPathComponent(id + ".json")
            self.worker.async { try? FileManager.default.removeItem(at: file) }
        }
        let text = ExteraBrowserFilters.shared.customRules
        if text != self.customText {
            self.customText = text
            self.customRules = []
            let token = UUID()
            self.customToken = token
            self.worker.async {
                let result = Result { try ExteraBrowserABPConverter.convert(text, limit: ExteraBrowserFilters.maximumCustomRules) }
                DispatchQueue.main.async {
                    guard self.customToken == token, ExteraBrowserFilters.shared.customRules == text else { return }
                    switch result {
                    case let .success(conversion): self.customRules = conversion.rules; self.customRulesError = nil
                    case let .failure(error): self.customRulesError = error.localizedDescription
                    }
                    self.rebuild()
                    self.notify()
                }
            }
        }
        self.rebuild()
        if ExteraBrowserFilters.shared.automaticUpdates && ExteraBrowserSettings.shared.adBlockingEnabled {
            for subscription in subscriptions where subscription.enabled {
                if (self.caches[subscription.id]?.expiresAt ?? .distantPast) <= Date(), (self.retryAfter[subscription.id] ?? .distantPast) <= Date() { self.enqueue(subscription) }
            }
        }
        self.notify()
        self.pump()
    }

    private func enqueue(_ subscription: ExteraBrowserSubscription) {
        guard self.jobs[subscription.id] == nil, !self.pending.contains(subscription.id) else { return }
        self.pending.append(subscription.id)
        self.states[subscription.id] = self.makeStatus(updating: true, message: "Queued for update…")
        self.notify()
    }

    private func pump() {
        while self.jobs.count < 2 && !self.pending.isEmpty {
            let id = self.pending.removeFirst()
            guard let subscription = ExteraBrowserFilters.shared.subscriptions.first(where: { $0.id == id && $0.enabled }) else { continue }
            let job = Job(subscription)
            self.jobs[id] = job
            self.states[id] = self.makeStatus(updating: true, message: "Downloading filter list…")
            let cache = self.caches[id]
            let request = ExteraBrowserFilterDownload(subscription: subscription, eTag: cache?.eTag, lastModified: cache?.lastModified, completion: { [weak self, weak job] result in
                guard let self, let job, self.jobs[id]?.token == job.token else { return }
                switch result {
                case let .failure(error): self.finish(job, error: error)
                case let .success(response): self.convert(response, job: job)
                }
            })
            job.request = request
            request.start()
        }
    }

    private func convert(_ response: ExteraBrowserFilterResponse, job: Job) {
        let id = job.subscription.id
        let old = self.caches[id]
        self.states[id] = self.makeStatus(updating: true, message: "Converting supported network filters…")
        self.notify()
        self.worker.async {
            let result: Result<ExteraBrowserFilterCache, Error> = Result {
                let now = Date()
                if response.notModified {
                    guard var cache = old else { throw ExteraBrowserFilterError.invalid("The server returned an unchanged list, but no cached version exists. Try updating again.") }
                    cache.fetchedAt = now
                    cache.expiresAt = now.addingTimeInterval(cache.conversion.expires)
                    return cache
                }
                guard var text = String(data: response.data, encoding: .utf8) else { throw ExteraBrowserFilterError.invalid("The filter list is not valid UTF-8 text.") }
                if text.hasPrefix("\u{feff}") { text.removeFirst() }
                let start = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100).lowercased()
                guard !start.hasPrefix("<"), !start.hasPrefix("{"), !start.hasPrefix("<!doctype") else { throw ExteraBrowserFilterError.invalid("The URL returned a web page or JSON instead of an ABP text filter list.") }
                let conversion = try ExteraBrowserABPConverter.convert(text)
                guard !conversion.rules.isEmpty else { throw ExteraBrowserFilterError.invalid("This list contains no supported network filters. Cosmetic rules, scriptlets and advanced ABP options are not supported.") }
                return ExteraBrowserFilterCache(converterVersion: ExteraBrowserABPConverter.version, url: job.subscription.url, fetchedAt: now, expiresAt: now.addingTimeInterval(conversion.expires), eTag: response.eTag, lastModified: response.lastModified, conversion: conversion)
            }
            DispatchQueue.main.async {
                guard self.isCurrent(job) else { return }
                switch result {
                case let .success(cache): self.persist(cache, job: job)
                case let .failure(error): self.finish(job, error: error)
                }
            }
        }
    }

    private func persist(_ cache: ExteraBrowserFilterCache, job: Job) {
        let directory = self.cacheDirectory
        let temporary = directory.appendingPathComponent(job.subscription.id + "." + job.token.uuidString + ".tmp")
        let destination = directory.appendingPathComponent(job.subscription.id + ".json")
        self.worker.async {
            let result: Result<Void, Error> = Result {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(cache)
                guard data.count <= 12 * 1024 * 1024 else { throw ExteraBrowserFilterError.storage }
                try data.write(to: temporary, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            DispatchQueue.main.async {
                guard self.isCurrent(job) else { self.worker.async { try? FileManager.default.removeItem(at: temporary) }; return }
                do {
                    try result.get()
                    // Rename is the only file operation on main; check the edit token immediately
                    // before publishing both cache file and memory, with no asynchronous gap.
                    let published = try ExteraBrowserFilters.shared.publishIfCurrent(job.subscription) {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            let _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                        } else {
                            try FileManager.default.moveItem(at: temporary, to: destination)
                        }
                        self.caches[job.subscription.id] = cache
                    }
                    guard published else { self.worker.async { try? FileManager.default.removeItem(at: temporary) }; return }
                    self.finish(job, error: nil)
                    self.rebuild()
                    self.notify()
                } catch {
                    self.worker.async { try? FileManager.default.removeItem(at: temporary) }
                    self.finish(job, error: ExteraBrowserFilterError.storage)
                }
            }
        }
    }

    private func isCurrent(_ job: Job) -> Bool {
        return self.jobs[job.subscription.id]?.token == job.token && ExteraBrowserFilters.shared.subscriptions.contains(job.subscription) && job.subscription.enabled
    }

    private func finish(_ job: Job, error: Error?) {
        guard self.isCurrent(job) else { return }
        self.jobs.removeValue(forKey: job.subscription.id)
        self.states[job.subscription.id] = self.makeStatus(updating: false, message: error?.localizedDescription)
        self.retryAfter[job.subscription.id] = error == nil ? nil : Date().addingTimeInterval(3600)
        self.notify()
        self.pump()
    }

    private func rebuild() {
        let subscriptions = ExteraBrowserFilters.shared.subscriptions
        var rules = subscriptions.filter { $0.enabled }.flatMap { item -> [ExteraBrowserContentRule] in
            guard let cache = self.caches[item.id], cache.url == item.url else { return [] }
            return cache.conversion.rules
        }
        rules += self.customRules
        rules = rules.filter { $0.action.type == "block" } + rules.filter { $0.action.type == "ignore-previous-rules" }
        guard rules != self.rules else { return }
        self.rules = rules
        self.sourceVersion &+= 1
        self.compilationError = nil
        if ExteraBrowserSettings.shared.adBlockingEnabled { NotificationCenter.default.post(name: ExteraBrowserSettings.didChangeNotification, object: nil) }
    }

    private func makeStatus(updating: Bool, message: String?) -> ExteraBrowserFilterStatus {
        var result = ExteraBrowserFilterStatus()
        result.updating = updating
        result.message = message
        return result
    }

    private func notify() { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
}

private struct ExteraBrowserFilterResponse {
    var data: Data
    var notModified: Bool
    var eTag: String?
    var lastModified: String?
}

/// Enforces response bounds while receiving data, not after an unbounded data-task allocation.
private final class ExteraBrowserFilterDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let subscription: ExteraBrowserSubscription
    private let eTag: String?
    private let lastModified: String?
    private var completion: ((Result<ExteraBrowserFilterResponse, ExteraBrowserFilterError>) -> Void)?
    private var session: URLSession?
    private var data = Data()
    private var response: HTTPURLResponse?
    private var redirects = 0
    private static let maximumBytes = 6 * 1024 * 1024

    init(subscription: ExteraBrowserSubscription, eTag: String?, lastModified: String?, completion: @escaping (Result<ExteraBrowserFilterResponse, ExteraBrowserFilterError>) -> Void) {
        self.subscription = subscription
        self.eTag = eTag
        self.lastModified = lastModified
        self.completion = completion
        super.init()
    }

    func start() {
        guard let url = ExteraBrowserSubscription.requestURL(self.subscription.url) else { self.finish(.failure(.invalid("Use an HTTPS filter-list URL without credentials or a fragment."))); return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        var request = URLRequest(url: url)
        request.setValue("text/plain, application/octet-stream;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("exteraGram-iOS/FilterSubscriptions", forHTTPHeaderField: "User-Agent")
        if let eTag = self.eTag, eTag.utf8.count <= 1024, !eTag.contains(where: { $0.isNewline }) { request.setValue(eTag, forHTTPHeaderField: "If-None-Match") }
        if let modified = self.lastModified, modified.utf8.count <= 1024, !modified.contains(where: { $0.isNewline }) { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        self.session?.dataTask(with: request).resume()
    }

    func cancel() {
        self.completion = nil
        self.session?.invalidateAndCancel()
        self.session = nil
        self.data.removeAll()
    }

    private func finish(_ result: Result<ExteraBrowserFilterResponse, ExteraBrowserFilterError>) {
        let completion = self.completion
        self.completion = nil
        self.session?.invalidateAndCancel()
        self.session = nil
        self.data.removeAll()
        completion?(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        self.redirects += 1
        guard self.completion != nil, self.redirects <= 3, let url = request.url, ExteraBrowserSubscription.requestURL(url.absoluteString) != nil else {
            completionHandler(nil)
            self.finish(.failure(.invalid("The filter URL redirected too many times or to a non-HTTPS address.")))
            return
        }
        var request = request
        // Cross-origin redirects may reach public CDNs, but never carry conditional tokens or cookies.
        if url.host?.lowercased() != response.url?.host?.lowercased() {
            request.setValue(nil, forHTTPHeaderField: "If-None-Match")
            request.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
        }
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard self.completion != nil else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) || response.statusCode == 304 else {
            completionHandler(.cancel); self.finish(.failure(.status((response as? HTTPURLResponse)?.statusCode ?? 0))); return
        }
        guard response.expectedContentLength <= Int64(Self.maximumBytes) else { completionHandler(.cancel); self.finish(.failure(.tooLarge)); return }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.completion != nil else { return }
        guard data.count <= Self.maximumBytes - self.data.count else { self.finish(.failure(.tooLarge)); return }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard self.completion != nil else { return }
        guard error == nil, let response = self.response else { self.finish(.failure(.network)); return }
        self.finish(.success(ExteraBrowserFilterResponse(data: self.data, notModified: response.statusCode == 304, eTag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"))))
    }
}
