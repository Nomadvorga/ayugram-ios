import Foundation
import Postbox
import SwiftSignalKit
import MtProtoKit
internal import TelegramApi

private final class AyuExplicitReadRunner {
    private let queue: Queue
    private let postbox: Postbox
    private let ownerId: PeerId
    private let request: (PeerId, Int32) -> Signal<AyuExplicitReadAttemptResult, NoError>
    private let now: () -> Double
    private let attemptTimeout: Double
    private var snapshot: AyuExplicitReadQueue?
    private var authorized = false
    private var online = false
    private var stopped = false
    private let subscriptions = DisposableSet()
    private var timer: SwiftSignalKit.Timer?
    private var active: [Int64: (id: String, attempt: UUID, disposable: MetaDisposable)] = [:]

    init(queue: Queue, postbox: Postbox, ownerId: PeerId, loggedOut: Signal<Bool, NoError>, online: Signal<Bool, NoError>, now: @escaping () -> Double, attemptTimeout: Double, request: @escaping (PeerId, Int32) -> Signal<AyuExplicitReadAttemptResult, NoError>) {
        self.queue = queue
        self.postbox = postbox
        self.ownerId = ownerId
        self.now = now
        self.attemptTimeout = attemptTimeout
        self.request = request
        self.subscriptions.add((postbox.mergedOperationLogView(tag: OperationLogTags.AyuExplicitRead, filterByPeerId: AyuExplicitReadOperation.peerId, limit: 1)
        |> deliverOn(queue)).start(next: { [weak self] view in
            guard let self, !self.stopped else { return }
            self.acceptSnapshot((view.entries.first?.contents as? AyuExplicitReadOperation)?.value)
            self.schedule()
        }))
        self.subscriptions.add((loggedOut |> distinctUntilChanged |> deliverOn(queue)).start(next: { [weak self] loggedOut in
            guard let self, !self.stopped else { return }
            if loggedOut {
                self.stopRequests()
                self.stopped = true
                let ownerId = self.ownerId
                // A persisted closed row also rejects an enqueue transaction that
                // was already queued when logout invalidated the account.
                self.subscriptions.add(self.postbox.transaction { transaction -> Void in
                    updateAyuExplicitReadQueue(transaction: transaction, ownerId: ownerId, { $0.close() })
                }.start())
            } else {
                self.authorized = true
                self.schedule()
            }
        }))
        self.subscriptions.add((online |> distinctUntilChanged |> deliverOn(queue)).start(next: { [weak self] online in
            guard let self, !self.stopped else { return }
            self.online = online
            if !online { self.stopRequests() }
            self.schedule()
        }))
    }

    func dispose() {
        self.stopped = true
        self.stopRequests()
        self.subscriptions.dispose()
    }

    private func stopRequests() {
        self.timer?.invalidate()
        self.timer = nil
        let active = self.active
        self.active.removeAll()
        for value in active.values { value.disposable.dispose() }
    }

    private func acceptSnapshot(_ value: AyuExplicitReadQueue?) {
        // A merged-view notification can overtake an earlier transaction result
        // on this queue. Never replace a newer persisted deadline/maxId with it.
        if let current = self.snapshot, let value, value.revision < current.revision { return }
        self.snapshot = value
    }

    private func schedule() {
        self.timer?.invalidate()
        self.timer = nil
        guard !self.stopped, self.authorized, self.online, let snapshot = self.snapshot else { return }
        guard !snapshot.closed, snapshot.ownerId == self.ownerId.toInt64() else {
            self.stopRequests()
            return
        }
        for (peerId, value) in Array(self.active) {
            if !snapshot.intents.contains(where: { $0.peerId == peerId && $0.id == value.id }) {
                self.active.removeValue(forKey: peerId)
                value.disposable.dispose()
            }
        }
        let timestamp = self.now()
        var nextDeadline: Double?
        for intent in snapshot.intents {
            guard self.active[intent.peerId] == nil else { continue }
            if intent.retryAt > timestamp {
                nextDeadline = min(nextDeadline ?? intent.retryAt, intent.retryAt)
            } else if self.active.count < 4 {
                self.start(intent)
            }
        }
        if self.active.count < 4, let nextDeadline {
            let timer = SwiftSignalKit.Timer(timeout: max(0.05, min(300, nextDeadline - timestamp)), repeat: false, completion: { [weak self] in self?.schedule() }, queue: self.queue)
            self.timer = timer
            timer.start()
        }
    }

    private func start(_ intent: AyuExplicitReadQueue.Intent) {
        let attempt = UUID()
        let disposable = MetaDisposable()
        self.active[intent.peerId] = (intent.id, attempt, disposable)
        let postbox = self.postbox
        let ownerId = self.ownerId
        let now = self.now
        let signal = (self.request(PeerId(intent.peerId), intent.maxId)
        |> then(.single(.retry(after: nil))))
        |> take(1)
        |> timeout(self.attemptTimeout, queue: self.queue, alternate: .single(.retry(after: nil)))
        |> mapToSignal { result -> Signal<AyuExplicitReadQueue, NoError> in
            return postbox.transaction { transaction -> AyuExplicitReadQueue in
                updateAyuExplicitReadQueue(transaction: transaction, ownerId: ownerId, { value in
                    guard value.ownerId == ownerId.toInt64(), !value.closed else { return }
                    guard let state = transaction.getState() as? AuthorizedAccountState, state.peerId == ownerId else { value.close(); return }
                    value.finish(intent, result: result, now: now())
                })
                return ayuExplicitReadQueue(transaction: transaction, ownerId: ownerId)
            }
        }
        disposable.set((signal |> deliverOn(self.queue)).start(next: { [weak self] value in
            guard let self, self.active[intent.peerId]?.attempt == attempt else { return }
            self.active.removeValue(forKey: intent.peerId)?.disposable.dispose()
            self.acceptSnapshot(value)
            self.schedule()
        }))
    }
}

/// Account owns/disposes the returned subscription. No Account or UI is captured
/// by the queue, timers or in-flight work. The injectable transport pins lifecycle
/// and persistence tests without changing either network engine.
func managedAyuExplicitReadOperations(postbox: Postbox, ownerId: PeerId, loggedOut: Signal<Bool, NoError>, online: Signal<Bool, NoError>, now: @escaping () -> Double = { Date().timeIntervalSince1970 }, attemptTimeout: Double = 45, request: @escaping (PeerId, Int32) -> Signal<AyuExplicitReadAttemptResult, NoError>) -> Signal<Never, NoError> {
    return Signal { _ in
        let queue = Queue(name: "AyuExplicitRead")
        let context = QueueLocalObject(queue: queue, generate: {
            AyuExplicitReadRunner(queue: queue, postbox: postbox, ownerId: ownerId, loggedOut: loggedOut, online: online, now: now, attemptTimeout: attemptTimeout, request: request)
        })
        return ActionDisposable { context.with { $0.dispose() } }
    }
}

func pushAyuExplicitRead(postbox: Postbox, network: Network, stateManager: AccountStateManager, ownerId: PeerId, peerId: PeerId, maxId: Int32) -> Signal<AyuExplicitReadAttemptResult, NoError> {
    return postbox.transaction { transaction -> Peer? in
        let value = ayuExplicitReadQueue(transaction: transaction, ownerId: ownerId)
        guard let state = transaction.getState() as? AuthorizedAccountState, state.peerId == ownerId,
              value.ownerId == ownerId.toInt64(), !value.closed,
              value.intents.contains(where: { $0.peerId == peerId.toInt64() && $0.maxId >= maxId }) else { return nil }
        return transaction.getPeer(peerId)
    }
    |> mapToSignal { [weak stateManager] peer -> Signal<AyuExplicitReadAttemptResult, NoError> in
        // Missing local peer/access hash is not a definite server verdict.
        guard let peer else { return .single(.retry(after: nil)) }
        if peerId.namespace == Namespaces.Peer.CloudChannel {
            guard let channel = apiInputChannel(peer) else { return .single(.retry(after: nil)) }
            return network.request(Api.functions.channels.readHistory(channel: channel, maxId: maxId), automaticFloodWait: false, ayuBypassGhost: true)
            |> map { result -> AyuExplicitReadAttemptResult in
                if case .boolTrue = result { return .success }
                return .retry(after: nil)
            }
            |> `catch` { error in .single(AyuExplicitReadQueue.classifyError(code: error.errorCode, text: error.errorDescription ?? "")) }
        } else {
            guard let inputPeer = apiInputPeer(peer) else { return .single(.retry(after: nil)) }
            return network.request(Api.functions.messages.readHistory(peer: inputPeer, maxId: maxId), automaticFloodWait: false, ayuBypassGhost: true)
            |> map { result -> AyuExplicitReadAttemptResult in
                switch result {
                case let .affectedMessages(data):
                    stateManager?.addUpdateGroups([.updatePts(pts: data.pts, ptsCount: data.ptsCount)])
                }
                return .success
            }
            |> `catch` { error in .single(AyuExplicitReadQueue.classifyError(code: error.errorCode, text: error.errorDescription ?? "")) }
        }
    }
}
