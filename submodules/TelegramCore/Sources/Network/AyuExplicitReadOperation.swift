import Foundation
import Postbox
import SwiftSignalKit

/// One bounded outbox row per account, under its own operation-log tag. Keeping
/// peers inside this row makes both the total bound and coalescing transactional.
final class AyuExplicitReadOperation: PostboxCoding {
    static let peerId = PeerId(0)
    let value: AyuExplicitReadQueue

    init(_ value: AyuExplicitReadQueue) {
        self.value = value
    }

    init(decoder: PostboxDecoder) {
        if let data = decoder.decodeDataForKey("q"), let value = try? JSONDecoder().decode(AyuExplicitReadQueue.self, from: data) {
            self.value = value
        } else {
            // A corrupt authorization record must never invent permission to send.
            var value = AyuExplicitReadQueue(ownerId: 0)
            value.close()
            self.value = value
        }
    }

    func encode(_ encoder: PostboxEncoder) {
        // All values originate in the bounded queue; nonfinite dates are excluded
        // by its callers. Encoding failure must not overwrite a durable intent.
        guard let data = try? JSONEncoder().encode(self.value) else {
            preconditionFailure("Invalid explicit-read outbox")
        }
        encoder.encodeData(data, forKey: "q")
    }
}

func ayuExplicitReadQueue(transaction: Transaction, ownerId: PeerId) -> AyuExplicitReadQueue {
    var result = AyuExplicitReadQueue(ownerId: ownerId.toInt64())
    transaction.operationLogEnumerateEntries(peerId: AyuExplicitReadOperation.peerId, tag: OperationLogTags.AyuExplicitRead, { entry in
        if let operation = entry.contents as? AyuExplicitReadOperation { result = operation.value }
        return false
    })
    return result
}

func updateAyuExplicitReadQueue(transaction: Transaction, ownerId: PeerId, _ update: (inout AyuExplicitReadQueue) -> Void) {
    var localIndex: Int32?
    var value = AyuExplicitReadQueue(ownerId: ownerId.toInt64())
    transaction.operationLogEnumerateEntries(peerId: AyuExplicitReadOperation.peerId, tag: OperationLogTags.AyuExplicitRead, { entry in
        localIndex = entry.tagLocalIndex
        if let operation = entry.contents as? AyuExplicitReadOperation { value = operation.value }
        return false
    })
    let previous = value
    update(&value)
    guard previous != value || localIndex == nil else { return }
    value.advanceRevision()
    if let localIndex {
        transaction.operationLogUpdateEntry(peerId: AyuExplicitReadOperation.peerId, tag: OperationLogTags.AyuExplicitRead, tagLocalIndex: localIndex, { _ in
            PeerOperationLogEntryUpdate(mergedIndex: .none, contents: .update(AyuExplicitReadOperation(value)))
        })
    } else {
        transaction.operationLogAddEntry(peerId: AyuExplicitReadOperation.peerId, tag: OperationLogTags.AyuExplicitRead, tagLocalIndex: .automatic, tagMergedIndex: .automatic, contents: AyuExplicitReadOperation(value))
    }
}

func enqueueAyuExplicitRead(transaction: Transaction, ownerId: PeerId, peerId: PeerId, maxId: Int32) -> AyuReadHistoryEnqueueResult {
    guard let state = transaction.getState() as? AuthorizedAccountState, state.peerId == ownerId else { return .loggedOut }
    var result: AyuReadHistoryEnqueueResult = .loggedOut
    updateAyuExplicitReadQueue(transaction: transaction, ownerId: ownerId, { value in
        guard value.ownerId == ownerId.toInt64(), !value.closed else { return }
        guard [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(peerId.namespace) else {
            value.recordFailure(peerId: peerId.toInt64(), maxId: maxId, code: "LOCAL_UNSUPPORTED_PEER")
            result = .invalidInput
            return
        }
        var boundedMaxId = maxId
        if maxId >= Int32.max - 1 {
            // Freeze "read all" at enqueue time. Replaying a sentinel after an
            // offline interval would also read messages received after the action.
            boundedMaxId = ayuKnownReadHistoryBound(transaction: transaction, peerId: peerId)
            guard boundedMaxId > 0, boundedMaxId < Int32.max - 1 else {
                value.recordFailure(peerId: peerId.toInt64(), maxId: 0, code: "LOCAL_READ_BOUND_UNAVAILABLE")
                result = .invalidInput
                return
            }
        }
        result = value.enqueue(peerId: peerId.toInt64(), maxId: boundedMaxId)
    })
    return result
}

private func ayuKnownReadHistoryBound(transaction: Transaction, peerId: PeerId) -> Int32 {
    var bound = transaction.getTopPeerMessageId(peerId: peerId, namespace: Namespaces.Message.Cloud)?.id ?? 0
    if bound >= Int32.max - 1 { bound = 0 }
    for (namespace, state) in transaction.getPeerReadStates(peerId) ?? [] where namespace == Namespaces.Message.Cloud {
        if case let .idBased(incoming, _, known, _, _) = state {
            for id in [incoming, known] where id > 0 && id < Int32.max - 1 {
                bound = max(bound, id)
            }
        }
    }
    return bound > 0 && bound < Int32.max - 1 ? bound : 0
}

/// Read-only preparation for a confirmation: capture bounds before showing UI.
/// Unknown bounds stay zero and cannot become read-all sentinels on retry.
public func ayuReadHistoryKnownBounds(account: Account, peerIdValues: [Int64]) -> Signal<[AyuReadHistoryRequest], NoError> {
    let ownerId = account.peerId
    return account.postbox.transaction { transaction in
        ayuReadHistoryKnownBounds(transaction: transaction, ownerId: ownerId, peerIdValues: peerIdValues)
    }
}

func ayuReadHistoryKnownBounds(transaction: Transaction, ownerId: PeerId, peerIdValues: [Int64]) -> [AyuReadHistoryRequest] {
    let value = ayuExplicitReadQueue(transaction: transaction, ownerId: ownerId)
    guard let state = transaction.getState() as? AuthorizedAccountState, state.peerId == ownerId,
          value.ownerId == ownerId.toInt64(), !value.closed else { return [] }
    return peerIdValues.map { id in
        AyuReadHistoryRequest(peerIdValue: id, maxId: ayuKnownReadHistoryBound(transaction: transaction, peerId: PeerId(id)))
    }
}

/// This signal is observational: subscribing never creates or retries a read.
public func ayuReadHistoryState(account: Account) -> Signal<AyuReadHistorySnapshot, NoError> {
    return ayuReadHistoryState(postbox: account.postbox, ownerId: account.peerId)
}

func ayuReadHistoryState(postbox: Postbox, ownerId: PeerId) -> Signal<AyuReadHistorySnapshot, NoError> {
    let ownerId = ownerId.toInt64()
    return postbox.mergedOperationLogView(tag: OperationLogTags.AyuExplicitRead, filterByPeerId: AyuExplicitReadOperation.peerId, limit: 1)
    |> map { view -> AyuReadHistorySnapshot in
        if let operation = view.entries.first?.contents as? AyuExplicitReadOperation, operation.value.ownerId == ownerId {
            return AyuReadHistorySnapshot(operation.value)
        }
        var value = AyuExplicitReadQueue(ownerId: ownerId)
        if !view.entries.isEmpty { value.close() }
        return AyuReadHistorySnapshot(value)
    }
    |> distinctUntilChanged
}

func controlAyuReadHistory(transaction: Transaction, ownerId: PeerId, action: AyuReadHistoryControl, now: Double) -> AyuReadHistoryControlResult {
    guard let state = transaction.getState() as? AuthorizedAccountState, state.peerId == ownerId else { return .loggedOut }
    var result: AyuReadHistoryControlResult = .loggedOut
    updateAyuExplicitReadQueue(transaction: transaction, ownerId: ownerId, { value in
        guard value.ownerId == ownerId.toInt64(), !value.closed else { return }
        switch action {
        case let .cancel(id, maxId): result = value.cancel(id: id, maxId: maxId, now: now)
        case let .retryPending(id, maxId): result = value.retryPending(id: id, maxId: maxId, now: now)
        case let .retryFailure(id):
            guard let failure = value.failures.first(where: { $0.id == id }) else { result = .stale; return }
            let peerId = PeerId(failure.peerIdValue)
            guard [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(peerId.namespace) else { result = .invalidInput; return }
            result = value.retryFailure(id: id)
        case let .dismissFailure(id):
            guard value.failures.contains(where: { $0.id == id }) else { result = .stale; return }
            value.acknowledgeFailures(ids: [id])
            result = .applied
        }
    })
    return result
}

/// An explicit button action only. Exact identity/bound validation prevents a
/// stale alert from cancelling/retrying a newer intent or expanding its scope.
public func ayuControlReadHistory(account: Account, action: AyuReadHistoryControl) -> Signal<AyuReadHistoryControlResult, NoError> {
    let ownerId = account.peerId
    return account.postbox.transaction { transaction in
        controlAyuReadHistory(transaction: transaction, ownerId: ownerId, action: action, now: Date().timeIntervalSince1970)
    }
}

/// Persisted terminal errors for this account only. UI may show/acknowledge these
/// after relaunch; the runner never silently converts them into successful reads.
public func ayuReadHistoryFailures(account: Account) -> Signal<[AyuReadHistoryFailure], NoError> {
    let ownerId = account.peerId.toInt64()
    return account.postbox.mergedOperationLogView(tag: OperationLogTags.AyuExplicitRead, filterByPeerId: AyuExplicitReadOperation.peerId, limit: 1)
    |> map { view -> [AyuReadHistoryFailure] in
        guard let operation = view.entries.first?.contents as? AyuExplicitReadOperation, operation.value.ownerId == ownerId else { return [] }
        return operation.value.failures
    }
    |> distinctUntilChanged
}

public func ayuAcknowledgeReadHistoryFailures(account: Account, ids: Set<String>) -> Signal<Never, NoError> {
    let ownerId = account.peerId
    return account.postbox.transaction { transaction -> Void in
        updateAyuExplicitReadQueue(transaction: transaction, ownerId: ownerId, { value in
            guard value.ownerId == ownerId.toInt64() else { return }
            value.acknowledgeFailures(ids: ids)
        })
    } |> ignoreValues
}
