import Foundation

public enum VoskSpeechError: Error, Equatable {
    case disabled, unsupportedLanguage, notInstalled, busy, cancelled, timedOut
    case downloadFailed, integrityFailed, unsafeArchive, invalidModel, recognitionFailed
    case storageFailure
}

/// Shared cancellation/deadline state also checked inside bounded disk/PCM loops.
final class VoskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let deadline: TimeInterval?

    init(timeout: TimeInterval? = nil) {
        self.deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
    }

    func cancel() {
        self.lock.lock()
        self.stopped = true
        self.lock.unlock()
    }

    func check() throws {
        self.lock.lock()
        let stopped = self.stopped
        self.lock.unlock()
        if stopped { throw VoskSpeechError.cancelled }
        if let deadline = self.deadline, ProcessInfo.processInfo.systemUptime >= deadline { throw VoskSpeechError.timedOut }
    }
}

extension FileHandle {
    func voskRead(count: Int) throws -> Data {
        let result = try self.read(upToCount: count) ?? Data()
        guard result.count == count else { throw VoskSpeechError.unsafeArchive }
        return result
    }
}
