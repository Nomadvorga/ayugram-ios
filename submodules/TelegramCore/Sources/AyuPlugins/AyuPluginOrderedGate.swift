import Foundation

/// Runs asynchronous steps one at a time, in the order they were added, on whatever thread adds
/// a step or finishes the previous one. A step ends when it calls `done` (once; later calls are
/// ignored), from any thread, during the step or after it returned. Nothing ever waits: a step
/// added while another runs is stored and `add` returns.
///
/// The plugin hook points use it so that traffic which waits for a plugin's answer is not
/// overtaken by traffic that does not (`Foundation` only: `Tests/TelegramTL` executes it).
final class AyuPluginOrderedGate {
    typealias Step = (_ done: @escaping () -> Void) -> Void

    private let lock = NSLock()
    private var pending: [Step] = []
    private var running = false
    private let busyChanged: ((Bool) -> Void)?

    /// `busyChanged` is called with true when the gate takes its first step and with false when
    /// it runs dry, never while the gate's lock is held.
    init(busyChanged: ((Bool) -> Void)? = nil) {
        self.busyChanged = busyChanged
    }

    var isBusy: Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.running
    }

    func add(_ step: @escaping Step) {
        self.lock.lock()
        if self.running {
            self.pending.append(step)
            self.lock.unlock()
            return
        }
        self.running = true
        self.lock.unlock()
        self.busyChanged?(true)
        self.run(step)
    }

    private final class Completion {
        private let lock = NSLock()
        private var finished = false
        private var detached = false

        /// True when the step's caller has already returned, so the gate must be advanced here.
        func finish() -> Bool {
            self.lock.lock(); defer { self.lock.unlock() }
            if self.finished { return false }
            self.finished = true
            return self.detached
        }

        /// True when the step finished before it returned.
        func detach() -> Bool {
            self.lock.lock(); defer { self.lock.unlock() }
            self.detached = true
            return self.finished
        }
    }

    private func next() -> Step? {
        self.lock.lock()
        if self.pending.isEmpty {
            self.running = false
            self.lock.unlock()
            self.busyChanged?(false)
            return nil
        }
        let step = self.pending.removeFirst()
        self.lock.unlock()
        return step
    }

    /// A loop, not recursion: a run of steps that finish synchronously costs no stack.
    private func run(_ first: @escaping Step) {
        var current: Step? = first
        while let step = current {
            let completion = Completion()
            step {
                if completion.finish(), let next = self.next() {
                    self.run(next)
                }
            }
            current = completion.detach() ? self.next() : nil
        }
    }
}
