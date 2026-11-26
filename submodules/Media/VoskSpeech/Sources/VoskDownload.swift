import Foundation

/// URLSession owns the temporary download. Move it into private staging before
/// returning; no model data is buffered in memory or published as installed.
final class VoskDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let model: VoskModelDescriptor
    private let target: URL
    private let cancellation: VoskCancellation
    private let progress: (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var finished = false
    private var requestedCancellation = false

    init(model: VoskModelDescriptor, target: URL, cancellation: VoskCancellation, progress: @escaping (Double) -> Void) {
        self.model = model
        self.target = target
        self.cancellation = cancellation
        self.progress = progress
    }

    func run() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.lock.lock()
                if self.requestedCancellation {
                    self.lock.unlock()
                    continuation.resume(throwing: VoskSpeechError.cancelled)
                    return
                }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.requestCachePolicy = .reloadIgnoringLocalCacheData
                config.urlCache = nil
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: self.model.url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let task = session.downloadTask(with: request)
                self.task = task
                self.lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    func cancel() {
        self.cancellation.cancel()
        self.lock.lock()
        self.requestedCancellation = true
        let task = self.task
        self.lock.unlock()
        task?.cancel()
    }

    private func complete(_ error: Error?) {
        self.lock.lock()
        guard !self.finished else { self.lock.unlock(); return }
        self.finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        self.lock.unlock()
        session?.finishTasksAndInvalidate()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https", request.url?.host == "alphacephei.com" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        do {
            try self.cancellation.check()
            guard totalBytesWritten <= self.model.archiveBytes,
                  totalBytesExpectedToWrite < 0 || totalBytesExpectedToWrite == self.model.archiveBytes else { throw VoskSpeechError.integrityFailed }
            self.progress(min(1, Double(totalBytesWritten) / Double(self.model.archiveBytes)))
        } catch {
            downloadTask.cancel()
            self.complete(error)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try self.cancellation.check()
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https", response.url?.host == "alphacephei.com" else { throw VoskSpeechError.downloadFailed }
            let bytes = try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber
            guard bytes?.int64Value == self.model.archiveBytes else { throw VoskSpeechError.integrityFailed }
            try FileManager.default.moveItem(at: location, to: self.target)
            try self.cancellation.check()
            self.complete(nil)
        } catch { self.complete(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            self.complete((error as NSError).code == NSURLErrorCancelled ? VoskSpeechError.cancelled : VoskSpeechError.downloadFailed)
        }
    }
}
