import AccountContext
import Foundation
import SGSimpleSettings

/// The bubble owns this bridge from consent through the local summary write.
/// Policy changes invalidate both transport and an already queued store commit.
final class ExteraAISummaryBridge {
    let plan: ExteraAISummaryPlan
    private let context: AccountContext
    private let lock = NSLock()
    private var active = true
    private var request: ExteraAIRequest?
    private var observer: NSObjectProtocol?
    private var completion: ((Result<String, ExteraAIError>) -> Void)?

    init(context: AccountContext, plan: ExteraAISummaryPlan) {
        self.context = context
        self.plan = plan
        self.observer = NotificationCenter.default.addObserver(forName: ExteraAISettings.didChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
            guard let self else { return }
            if !self.policyMatches { self.cancel(notify: true) }
        })
    }

    deinit { self.cancel() }

    private var policyMatches: Bool {
        return self.plan.matches(configuration: ExteraAISettings.shared.configuration, isPremium: self.context.isPremium)
    }

    var isActive: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.active && self.policyMatches
    }

    func start(completion: @escaping (Result<String, ExteraAIError>) -> Void) throws {
        guard self.isActive else { throw ExteraAIError.cancelled }
        self.completion = completion
        let key = try ExteraAISettings.shared.apiKey(serviceId: self.plan.service.id)
        self.request = try self.plan.generate(apiKey: key, completion: { [weak self] result in
            guard let self else { return }
            guard self.isActive else { self.cancel(notify: true); return }
            self.request = nil
            self.completion?(result)
        })
    }

    /// Called inside the Postbox transaction. Cancellation and the write are
    /// serialized, so disposing queued work cannot later publish a stale result.
    func commitIfActive(_ body: () -> Void) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.active && self.policyMatches else { return false }
        body()
        return true
    }

    func cancel(notify: Bool = false) {
        self.lock.lock()
        let wasActive = self.active
        self.active = false
        self.lock.unlock()
        guard wasActive else { return }
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
        self.observer = nil
        self.request?.cancel()
        self.request = nil
        let completion = self.completion
        self.completion = nil
        if notify { DispatchQueue.main.async { completion?(.failure(.cancelled)) } }
    }
}
