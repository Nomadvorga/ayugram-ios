import Foundation

/// One explicitly confirmed upload. An ephemeral session has no shared cookies/cache.
/// Backgrounding or closing the utility cancels it; no automatic retry uploads a photo twice.
final class ExteraImageSearchUpload: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lifecycleLock = NSLock()
    private var session: URLSession?
    private var task: URLSessionUploadTask?
    private var received = Data()
    private var responseURL: URL?
    private let provider: ExteraImageSearchProvider
    private let completion: (Result<URL, Error>) -> Void
    private var finished = false

    init(jpeg: Data, provider: ExteraImageSearchProvider, completion: @escaping (Result<URL, Error>) -> Void) {
        self.provider = provider
        self.completion = completion
        super.init()
        do {
            let (request, body) = try ExteraImageSearchProtocol.upload(jpeg: jpeg, boundary: "ExteraImage-" + UUID().uuidString)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForResource = 60.0
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.uploadTask(with: request, from: body)
            self.task = task
            task.resume()
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }

    func cancel() {
        self.lifecycleLock.lock()
        let session = self.session
        self.lifecycleLock.unlock()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ExteraImageSearchProtocol.isUploadURL(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200 ... 299).contains(response.statusCode),
              let url = response.url, ExteraImageSearchProtocol.isUploadURL(url),
              response.expectedContentLength <= Int64(ExteraImageSearchProtocol.maximumResponseBytes) else {
            completionHandler(.cancel)
            return
        }
        self.responseURL = url
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= ExteraImageSearchProtocol.maximumResponseBytes - self.received.count else {
            dataTask.cancel()
            return
        }
        self.received.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !self.finished else { return }
        self.finished = true
        let result: Result<URL, Error>
        if let error {
            result = .failure(error)
        } else if let responseURL = self.responseURL {
            result = Result { try ExteraImageSearchProtocol.resultURL(data: self.received, responseURL: responseURL, provider: self.provider) }
        } else {
            result = .failure(ExteraImageSearchProtocol.SearchError.failedRequest)
        }
        self.received.removeAll()
        self.lifecycleLock.lock()
        self.task = nil
        self.session = nil
        self.lifecycleLock.unlock()
        session.finishTasksAndInvalidate()
        DispatchQueue.main.async { self.completion(result) }
    }
}
