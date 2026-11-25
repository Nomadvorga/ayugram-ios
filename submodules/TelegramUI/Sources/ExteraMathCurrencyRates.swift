import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An actual, dated exchange-rate response. Values are currency units per USD,
/// matching Coinbase's payload, so a cross rate is `to / from`.
public struct ExteraMathCurrencySnapshot {
    public let date: Date
    public let unitsPerUSD: [String: Double]

    public init(date: Date, unitsPerUSD: [String: Double]) {
        self.date = date
        var valid: [String: Double] = ["USD": 1]
        for (key, value) in unitsPerUSD {
            let code = key.uppercased() == "TON" ? "GRAM" : key.uppercased()
            if code != "USD", ExteraMathUnits.supportedCurrencyCodes.contains(code), value.isFinite, value > 0 {
                valid[code] = value
            }
        }
        self.unitsPerUSD = valid
    }

    public func rate(from: String, to: String, now: Date = Date()) -> Double? {
        let age = now.timeIntervalSince(self.date)
        guard age >= -300, age <= 86400,
              let source = self.unitsPerUSD[from], let target = self.unitsPerUSD[to] else { return nil }
        let rate = target / source
        return rate.isFinite && rate > 0 ? rate : nil
    }

    static func parse(_ data: Data, date: Date) -> ExteraMathCurrencySnapshot? {
        guard data.count <= 1_048_576,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any], payload["currency"] as? String == "USD",
              let rawRates = payload["rates"] as? [String: String], rawRates.count <= 2000 else { return nil }
        var rates: [String: Double] = [:]
        for (code, string) in rawRates {
            if string.utf8.count <= 64, let value = Double(string), value.isFinite, value > 0 {
                rates[code] = value
            }
        }
        let snapshot = ExteraMathCurrencySnapshot(date: date, unitsPerUSD: rates)
        return snapshot.unitsPerUSD.count > 1 ? snapshot : nil
    }
}

/// The same public USD endpoint as exteraGram Android. The request contains no
/// draft, amount, account or currency query. Cache lifetime matches InlineRates.kt.
/// Call on the main queue; each row owns and cancels its request on edit/dismissal.
final class ExteraMathCurrencyRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let lock = NSLock()
    private static var snapshot: ExteraMathCurrencySnapshot?
    private static var lastFailure: Date?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var rejectedResponse = false
    private var completion: ((ExteraMathCurrencySnapshot?) -> Void)?

    static func cached(now: Date = Date()) -> ExteraMathCurrencySnapshot? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let snapshot = self.snapshot, snapshot.rate(from: "USD", to: "USD", now: now) != nil else { return nil }
        return snapshot
    }

    static func shouldRefresh(now: Date = Date()) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let failure = self.lastFailure, now.timeIntervalSince(failure) < 30 { return false }
        return self.snapshot.map { now.timeIntervalSince($0.date) >= 300 } ?? true
    }

    init(configuration: URLSessionConfiguration = .ephemeral, completion: @escaping (ExteraMathCurrencySnapshot?) -> Void) {
        self.completion = completion
        super.init()
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: URL(string: "https://api.coinbase.com/v2/exchange-rates?currency=USD")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        self.task = session.dataTask(with: request)
        self.task?.resume()
    }

    func cancel() {
        // This and delivery run on main; a response already queued cannot update
        // an edited/dismissed row after this clears its completion.
        self.completion = nil
        self.task?.cancel()
        self.session?.invalidateAndCancel()
        self.session = nil
        self.task = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= 1_048_576 else {
            self.rejectedResponse = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.buffer.count + data.count <= 1_048_576 else {
            self.rejectedResponse = true
            dataTask.cancel()
            return
        }
        self.buffer.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let snapshot = error == nil ? ExteraMathCurrencySnapshot.parse(self.buffer, date: Date()) : nil
        self.buffer = Data()
        session.finishTasksAndInvalidate()
        // Cache mutation is safe on the delegate queue. A cancelled request does
        // not poison the retry throttle for the user's next valid expression.
        Self.lock.lock()
        if let snapshot { Self.snapshot = snapshot; Self.lastFailure = nil }
        else if self.rejectedResponse || (error as NSError?)?.code != NSURLErrorCancelled { Self.lastFailure = Date() }
        Self.lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self, let completion = self.completion else { return }
            self.completion = nil
            self.session = nil
            self.task = nil
            completion(snapshot)
        }
    }
}
