import Foundation

public struct ExteraPillValue {
    public var text: String?
    public var updatedAt: Date?
    public var error: ExteraPillError?
    public var isRefreshing: Bool = false

    public init(text: String? = nil, updatedAt: Date? = nil, error: ExteraPillError? = nil) {
        self.text = text
        self.updatedAt = updatedAt
        self.error = error
    }
}

/// Shared foreground-only scheduler. All public methods and notifications run on the main thread.
/// Each visible host acquires a lease, releases it on disappearance/background, and observes didChange.
/// Only formatted successes are cached in memory (24 × 128 characters), never response bodies.
public final class ExteraPillRuntime {
    public static let shared = ExteraPillRuntime()
    public static let didChange = Notification.Name("ExteraPillValuesDidChange")

    private struct Pending {
        let token: UUID
        let request: ExteraPillRequest
    }

    private var specs: [ExteraPillSpec] = []
    private var values: [UUID: ExteraPillValue] = [:]
    private var pending: [UUID: Pending] = [:]
    private var due: [UUID: Date] = [:]
    private var lastAttempt: [UUID: Date] = [:]
    private var leases = Set<UUID>()
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?

    private init() {
        self.specs = ExteraPillSettings.shared.pills
        self.observer = NotificationCenter.default.addObserver(forName: ExteraPillSettings.didChange, object: nil, queue: .main, using: { [weak self] _ in
            self?.reload()
        })
    }

    deinit {
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
        self.timer?.cancel()
        for item in self.pending.values { item.request.cancel() }
    }

    public func acquire() -> UUID {
        precondition(Thread.isMainThread)
        let lease = UUID()
        self.leases.insert(lease)
        if self.timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 5.0, repeating: 5.0, leeway: .seconds(1))
            timer.setEventHandler(handler: { [weak self] in self?.schedule() })
            self.timer = timer
            timer.resume()
        }
        self.schedule()
        return lease
    }

    public func release(_ lease: UUID) {
        precondition(Thread.isMainThread)
        self.leases.remove(lease)
        guard self.leases.isEmpty else { return }
        self.timer?.cancel()
        self.timer = nil
        let requests = self.pending
        self.pending.removeAll()
        for (id, item) in requests {
            item.request.cancel()
            self.values[id]?.isRefreshing = false
            self.due.removeValue(forKey: id)
        }
        self.notify()
    }

    public func value(for id: UUID) -> ExteraPillValue {
        precondition(Thread.isMainThread)
        var value = self.values[id] ?? ExteraPillValue()
        if let updated = value.updatedAt, Date().timeIntervalSince(updated) > 86400 {
            value.text = nil
        }
        return value
    }

    /// Tap/pull-to-refresh is throttled and coalesced with existing requests.
    public func refresh(_ id: UUID? = nil) {
        precondition(Thread.isMainThread)
        guard !self.leases.isEmpty else { return }
        for spec in self.specs where spec.enabled && (id == nil || spec.id == id) {
            guard self.pending[spec.id] == nil else { continue }
            if let attempted = self.lastAttempt[spec.id], Date().timeIntervalSince(attempted) < 3 { continue }
            self.due[spec.id] = .distantPast
        }
        self.schedule()
    }

    private func reload() {
        let updated = ExteraPillSettings.shared.pills
        for spec in self.specs where !updated.contains(spec) {
            self.pending.removeValue(forKey: spec.id)?.request.cancel()
            self.values.removeValue(forKey: spec.id)
            self.due.removeValue(forKey: spec.id)
            self.lastAttempt.removeValue(forKey: spec.id)
        }
        self.specs = updated
        self.notify()
        self.schedule()
    }

    private func schedule() {
        guard !self.leases.isEmpty else { return }
        let now = Date()
        var started = false
        // Serve never-fetched/oldest-due pills first so slow endpoints cannot starve later rows.
        let candidates = self.specs.enumerated().filter { $0.element.enabled }.sorted { lhs, rhs in
            let left = self.due[lhs.element.id] ?? .distantPast
            let right = self.due[rhs.element.id] ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left < right
        }
        for candidate in candidates {
            let spec = candidate.element
            guard self.pending.count < 3 else { break }
            guard self.pending[spec.id] == nil else { continue }
            if let due = self.due[spec.id], due > now { continue }
            let token = UUID()
            self.lastAttempt[spec.id] = now
            let request = ExteraPillRequest(spec: spec, completion: { [weak self] result in
                guard let self, self.pending[spec.id]?.token == token else { return }
                self.pending.removeValue(forKey: spec.id)
                var value = self.values[spec.id] ?? ExteraPillValue()
                value.isRefreshing = false
                switch result {
                case let .success(text):
                    value.text = text
                    value.updatedAt = Date()
                    value.error = nil
                case let .failure(error):
                    value.error = error
                }
                self.values[spec.id] = value
                self.due[spec.id] = spec.refresh == 0 ? .distantFuture : Date().addingTimeInterval(Double(spec.refresh))
                self.notify()
                self.schedule()
            })
            self.pending[spec.id] = Pending(token: token, request: request)
            started = true
            var value = self.values[spec.id] ?? ExteraPillValue()
            value.isRefreshing = true
            self.values[spec.id] = value
            request.start()
        }
        if started { self.notify() }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// Uses streaming delegates to enforce the cap before buffering an entire response. Session delegates
/// execute on main; parsing runs off-main, and generation tokens discard obsolete completions.
private final class ExteraPillRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumBytes = 512 * 1024
    private let spec: ExteraPillSpec
    private var completion: ((Result<String, ExteraPillError>) -> Void)?
    private var session: URLSession?
    private var data = Data()
    private var redirects = 0

    init(spec: ExteraPillSpec, completion: @escaping (Result<String, ExteraPillError>) -> Void) {
        self.spec = spec
        self.completion = completion
        super.init()
    }

    func start() {
        guard let url = ExteraPillSpec.requestURL(self.spec.url) else {
            self.finish(.failure(.invalidConfiguration))
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("exteraGram-iOS/CustomPill", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request).resume()
    }

    func cancel() {
        self.completion = nil
        self.session?.invalidateAndCancel()
        self.session = nil
        self.data.removeAll()
    }

    private func finish(_ result: Result<String, ExteraPillError>) {
        let completion = self.completion
        self.completion = nil
        self.session?.invalidateAndCancel()
        self.session = nil
        self.data.removeAll()
        completion?(result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard self.completion != nil else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode) else {
            completionHandler(.cancel)
            self.finish(.failure(.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)))
            return
        }
        guard response.expectedContentLength <= Int64(Self.maximumBytes) else {
            completionHandler(.cancel)
            self.finish(.failure(.responseTooLarge))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.completion != nil else { return }
        guard data.count <= Self.maximumBytes - self.data.count else {
            self.finish(.failure(.responseTooLarge))
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        self.redirects += 1
        // Keep query tokens on their configured origin, and never downgrade transport security.
        guard self.completion != nil, self.redirects <= 3,
              let original = URLComponents(string: self.spec.url), let url = request.url,
              ExteraPillSpec.requestURL(url.absoluteString) != nil,
              let next = URLComponents(url: url, resolvingAgainstBaseURL: false),
              original.scheme?.lowercased() == next.scheme?.lowercased(),
              original.host?.lowercased() == next.host?.lowercased(), original.port == next.port else {
            completionHandler(nil)
            self.finish(.failure(.network))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard self.completion != nil else { return }
        guard error == nil else { self.finish(.failure(.network)); return }
        let data = self.data
        let spec = self.spec
        self.data.removeAll()
        session.finishTasksAndInvalidate()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<String, ExteraPillError>
            do {
                let root: Any
                do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
                catch { throw ExteraPillError.invalidJSON }
                let value = try ExteraPillJSONPath.resolve(root, path: spec.jsonPath)
                result = .success(try ExteraPillFormatting.render(value, spec: spec))
            } catch let error as ExteraPillError { result = .failure(error) }
            catch { result = .failure(.invalidJSON) }
            DispatchQueue.main.async { self?.finish(result) }
        }
    }
}
