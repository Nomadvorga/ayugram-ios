import Foundation
import MtProtoKit
import ObjectiveC
import Postbox
import SGSimpleSettings
import SwiftSignalKit
internal import TelegramApi

private let presenceChanged = Notification.Name("ExteraAccountPresenceChanged")
private var presenceKey: UInt8 = 0
private let presenceLock = NSLock()

// Owned by one Network; no registry keyed by phone/account slot and no retained Network.
private final class ExteraPresenceBarrier {
    private let lock = NSRecursiveLock()
    private var count = 0
    let idle = ValuePromise<Bool>(true, ignoreRepeated: true)
    private var status: ExteraPillEntryStatus?
    private var statusUptime: TimeInterval = -.infinity
    private var dialogsUptime: TimeInterval = -.infinity

    func record(_ status: ExteraPillEntryStatus) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.status = status; self.statusUptime = ProcessInfo.processInfo.systemUptime
    }
    func markDialogs() {
        self.lock.lock(); defer { self.lock.unlock() }
        self.dialogsUptime = ProcessInfo.processInfo.systemUptime
    }
    func cachedOnAttach() -> ExteraPillEntryStatus? {
        self.lock.lock(); defer { self.lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        return self.count == 0 && now - self.statusUptime < 6.5 && now - self.dialogsUptime < 6.5 ? self.status : nil
    }

    func begin() {
        self.lock.lock()
        self.count += 1
        self.idle.set(false)
        self.lock.unlock()
    }
    func end() {
        self.lock.lock()
        self.count -= 1
        if self.count == 0 { self.idle.set(true) }
        self.lock.unlock()
    }
}

private func presenceBarrier(_ network: Network) -> ExteraPresenceBarrier {
    presenceLock.lock(); defer { presenceLock.unlock() }
    if let value = objc_getAssociatedObject(network, &presenceKey) as? ExteraPresenceBarrier { return value }
    let value = ExteraPresenceBarrier()
    objc_setAssociatedObject(network, &presenceKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return value
}

// Only wraps presence packets already authorized by the existing ghost/presence owner.
// Cancellation releases waiting readers but does not claim a server status change.
func ayuTrackedPresence(network: Network, operation: Signal<Api.Bool, MTRpcError>) -> Signal<Api.Bool, MTRpcError> {
    return Signal { subscriber in
        let barrier = presenceBarrier(network)
        barrier.begin()
        let once = Atomic<Bool>(value: false)
        let finish: (Bool) -> Void = { notify in
            guard !once.swap(true) else { return }
            barrier.end()
            if notify {
                DispatchQueue.main.async { [weak network] in
                    guard let network else { return }
                    NotificationCenter.default.post(name: presenceChanged, object: network, userInfo: ["fetch": true])
                }
            }
        }
        let disposable = operation.start(next: { subscriber.putNext($0) }, error: {
            finish(true); subscriber.putError($0)
        }, completed: {
            finish(true); subscriber.putCompletion()
        })
        return ActionDisposable { disposable.dispose(); finish(false) }
    }
}

func exteraPresenceBarrier(network: Network) -> Signal<Bool, NoError> {
    // Wait for operations already in flight; read-only when there is no pending operation.
    // Restart the 100 ms settle interval when another presence operation begins.
    return presenceBarrier(network).idle.get()
    |> mapToSignal { idle -> Signal<Bool, NoError> in
        return idle ? (.single(true) |> delay(0.1, queue: .mainQueue())) : .never()
    }
    |> take(1)
}

/// Account scope follows the supplied Network object. Emits on the main queue.
/// true = presence callback/FETCH; false reserved for an external UPDATE event.
public func exteraPresenceEvents(account: Account) -> Signal<Bool, NoError> {
    return Signal { subscriber in
        let observer = NotificationCenter.default.addObserver(forName: presenceChanged, object: nil, queue: .main) { value in
            guard (value.object as? Network) === account.network || value.userInfo?["owner"] as? Int64 == account.peerId.toInt64() else { return }
            subscriber.putNext(value.userInfo?["fetch"] as? Bool ?? false)
        }
        return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
    }
}

func ayuSelfPresenceObserved(peerId: PeerId) {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: presenceChanged, object: nil, userInfo: ["owner": peerId.toInt64(), "fetch": false])
    }
}
func exteraRecordEntryStatus(_ status: ExteraPillEntryStatus, network: Network) { presenceBarrier(network).record(status) }
public func exteraEntryStatusDialogsAppeared(account: Account) { presenceBarrier(account.network).markDialogs() }
public func exteraCachedEntryStatusOnAttach(account: Account) -> ExteraPillEntryStatus? { presenceBarrier(account.network).cachedOnAttach() }

func ayuPresenceUpdated(network: Network) {
    DispatchQueue.main.async { [weak network] in
        guard let network else { return }
        NotificationCenter.default.post(name: presenceChanged, object: network, userInfo: ["fetch": false])
    }
}

// Preserve existing launch + 200 ms pulse timing even if Online fails or has not
// replied yet. A caller that merely reads status never creates this operation.
func ayuPresencePulse(network: Network) -> Signal<Api.Bool, MTRpcError> {
    return Signal { subscriber in
        let requests = DisposableSet()
        let cancelled = Atomic<Bool>(value: false)
        requests.add(network.request(Api.functions.account.updateStatus(offline: .boolFalse), ayuBypassGhost: true).start())
        Queue.mainQueue().after(0.2) {
            guard !cancelled.with({ $0 }) else { return }
            guard AyuGhostSettings.shared.suppressOnlineStatus else { subscriber.putCompletion(); return }
            requests.add(network.request(Api.functions.account.updateStatus(offline: .boolTrue), ayuBypassGhost: true).start(next: {
                subscriber.putNext($0)
            }, error: { subscriber.putError($0) }, completed: { subscriber.putCompletion() }))
            // Retain the existing ghost UI bookkeeping; Entry Time never reads it.
            AyuGhostLastSeen.shared.recordNow()
        }
        return ActionDisposable { _ = cancelled.swap(true); requests.dispose() }
    }
}
