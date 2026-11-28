import Foundation

/// Worker-thread execution model for plugins: named worker threads with
/// thread-local identity, join/timeout semantics, generation-based callback
/// revocation on unload, per-plugin CPU accounting, and marshalling of
/// completions back to the main dispatch context without any synchronous
/// main-thread wait (which would deadlock against the host).

public enum AyuBridgeWorkerError: Error, Equatable, Sendable {
    case pluginUnloaded(String)
    case joinTimedOut(String)
    case queueShutDown
    case budgetExhausted(String)
    case mainThreadSyncWaitForbidden
}

/// Per-plugin CPU budget: wall time spent executing the plugin's work on its
/// workers. The host top-up policy lives beside the existing bridge limits.
public final class AyuBridgeCPUBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var usedSeconds: Double = 0
    public let limitSeconds: Double

    public init(limitSeconds: Double) { self.limitSeconds = limitSeconds }

    public func consumed() -> Double {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.usedSeconds
    }

    /// Charges measured work; returns false when the charge crosses the limit
    /// (the charge is still recorded so repeated crossings stay visible).
    public func charge(seconds: Double) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        self.usedSeconds += max(0, seconds)
        return self.usedSeconds <= self.limitSeconds
    }

    public func isExhausted() -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.usedSeconds >= self.limitSeconds
    }
}

/// One dispatch queue per (plugin, thread name), so Python's
/// `threading.current_thread().name` identity holds per worker. The host owns
/// revocation: unload bumps the plugin's generation and every queued callback
/// of an older generation is dropped, never delivered.
public final class AyuBridgePythonWorkers: @unchecked Sendable {
    private struct Queue {
        let queue: DispatchQueue
        let name: String
    }

    private let lock = NSLock()
    private var queues: [String: [Queue]] = [:]
    private var generation: [String: Int64] = [:]
    private var budgets: [String: AyuBridgeCPUBudget] = [:]
    private let defaultBudgetSeconds: Double

    public init(defaultBudgetSeconds: Double = 10.0) { self.defaultBudgetSeconds = defaultBudgetSeconds }

    /// Runs `body` on a named worker of the plugin, serially per name. The body
    /// receives its thread identity and must never wait synchronously on the
    /// main thread; completions are marshalled with `completion`.
    @discardableResult
    public func run(pluginID: String, threadName: String, body: @escaping @Sendable (String) throws -> Void,
                    completion: @escaping @Sendable (Result<Void, Error>) -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem {}
        let queue = self.queueOrCreate(pluginID: pluginID, name: threadName)
        let generation = self.currentGeneration(pluginID: pluginID)
        let budget = self.budgetOrCreate(pluginID: pluginID)
        queue.queue.async { [weak self] in
            guard let self, self.currentGeneration(pluginID: pluginID) == generation else {
                completion(.failure(AyuBridgeWorkerError.pluginUnloaded(pluginID)))
                return
            }
            let started = Date()
            do {
                try body(threadName)
                let charged = budget.charge(seconds: Date().timeIntervalSince(started))
                if !charged { throw AyuBridgeWorkerError.budgetExhausted(pluginID) }
                completion(.success(()))
            } catch {
                _ = budget.charge(seconds: Date().timeIntervalSince(started))
                completion(.failure(error))
            }
            _ = item
        }
        return item
    }

    /// Marshals a result back to the main dispatch context asynchronously. The
    /// generation check drops results of an unloaded plugin.
    public func completion(pluginID: String, _ result: @escaping @Sendable () -> Void) {
        let generation = self.currentGeneration(pluginID: pluginID)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentGeneration(pluginID: pluginID) == generation else { return }
            result()
        }
    }

    /// Joins a worker's queue with a timeout, off the main thread. Calling this
    /// on the main thread is a deadlock guard rejection, not a wait.
    public func join(pluginID: String, threadName: String, timeout: TimeInterval) throws {
        if DispatchContext.isMainThread() { throw AyuBridgeWorkerError.mainThreadSyncWaitForbidden }
        let semaphore = DispatchSemaphore(value: 0)
        self.lock.lock()
        let queue = self.queues[pluginID]?.first { $0.name == threadName }
        self.lock.unlock()
        guard let queue else { return }
        queue.queue.async { semaphore.signal() }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw AyuBridgeWorkerError.joinTimedOut("\(pluginID).\(threadName)")
        }
    }

    /// Unload: bumps the generation and drops the plugin's queues. Queued work
    /// of the old generation fails with `pluginUnloaded`, its callbacks are
    /// never delivered.
    public func unload(pluginID: String) {
        self.lock.lock()
        self.generation[pluginID, default: 0] += 1
        let queues = self.queues.removeValue(forKey: pluginID) ?? []
        self.budgets.removeValue(forKey: pluginID)
        self.lock.unlock()
        for entry in queues { entry.queue.async(flags: .barrier) {} }
    }

    public func workerCount(pluginID: String) -> Int {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.queues[pluginID]?.count ?? 0
    }

    public func budget(pluginID: String) -> AyuBridgeCPUBudget {
        self.budgetOrCreate(pluginID: pluginID)
    }

    private func queueOrCreate(pluginID: String, name: String) -> Queue {
        self.lock.lock(); defer { self.lock.unlock() }
        if let existing = self.queues[pluginID]?.first(where: { $0.name == name }) { return existing }
        let queue = Queue(queue: DispatchQueue(label: "plugin.\(pluginID).\(name)", qos: .utility), name: name)
        self.queues[pluginID, default: []].append(queue)
        return queue
    }

    private func currentGeneration(pluginID: String) -> Int64 {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.generation[pluginID, default: 0]
    }

    private func budgetOrCreate(pluginID: String) -> AyuBridgeCPUBudget {
        self.lock.lock(); defer { self.lock.unlock() }
        if let existing = self.budgets[pluginID] { return existing }
        let budget = AyuBridgeCPUBudget(limitSeconds: self.defaultBudgetSeconds)
        self.budgets[pluginID] = budget
        return budget
    }
}

enum DispatchContext {
    static func isMainThread() -> Bool { Thread.isMainThread }
}
