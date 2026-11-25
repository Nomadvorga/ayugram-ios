import Foundation
import XCTest
#if canImport(TelegramCore)
@testable import TelegramCore
#endif

final class AyuExplicitReadQueueTests: XCTestCase {
    func testCoalescesMonotonicallyWithinOnePeer() {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        XCTAssertEqual(queue.enqueue(peerId: 10, maxId: 5), .queued)
        let id = queue.intents.first?.id
        XCTAssertEqual(queue.enqueue(peerId: 10, maxId: 3), .coalesced)
        XCTAssertEqual(queue.enqueue(peerId: 10, maxId: 9), .coalesced)
        XCTAssertEqual(queue.intents.count, 1)
        XCTAssertEqual(queue.intents.first?.maxId, 9)
        XCTAssertEqual(queue.intents.first?.id, id)
    }

    func testQueueBoundRejectsWithoutEvictingAcceptedWork() {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        for peer in 1 ... AyuExplicitReadQueue.capacity {
            XCTAssertEqual(queue.enqueue(peerId: Int64(peer), maxId: 1), .queued)
        }
        let accepted = queue.intents
        XCTAssertEqual(queue.enqueue(peerId: 2000, maxId: 1), .queueFull)
        XCTAssertEqual(queue.intents, accepted)
        XCTAssertEqual(queue.enqueue(peerId: 1, maxId: 2), .coalesced)
        XCTAssertEqual(queue.intents.count, AyuExplicitReadQueue.capacity)
        XCTAssertEqual(queue.failures.last?.code, "LOCAL_QUEUE_FULL")
    }

    func testRejectsUnboundedOrInvalidMessageIds() {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let ids: [Int32] = [-1, 0, Int32.max - 1, Int32.max]
        for id in ids {
            XCTAssertEqual(queue.enqueue(peerId: 10, maxId: id), .invalidInput)
        }
        XCTAssertTrue(queue.intents.isEmpty)
        XCTAssertEqual(queue.failures.count, 4)
    }

    func testOlderSuccessDoesNotLoseNewerMaxId() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let _ = queue.enqueue(peerId: 10, maxId: 5)
        let sent = try XCTUnwrap(queue.intents.first)
        let _ = queue.enqueue(peerId: 10, maxId: 8)
        queue.finish(sent, result: .success, now: 100)
        XCTAssertEqual(queue.intents.first?.maxId, 8)
        let latest = try XCTUnwrap(queue.intents.first)
        queue.finish(latest, result: .success, now: 101)
        XCTAssertTrue(queue.intents.isEmpty)
    }

    func testLateCompletionCannotConsumeReplacementIntent() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let _ = queue.enqueue(peerId: 10, maxId: 5)
        let sent = try XCTUnwrap(queue.intents.first)
        queue.finish(sent, result: .success, now: 100)
        let _ = queue.enqueue(peerId: 10, maxId: 8)
        queue.finish(sent, result: .rejected("PEER_ID_INVALID"), now: 100)
        XCTAssertEqual(queue.intents.first?.maxId, 8)
        XCTAssertTrue(queue.failures.isEmpty)
    }

    func testOlderRejectionPreservesNewerAction() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let _ = queue.enqueue(peerId: 10, maxId: 5)
        let sent = try XCTUnwrap(queue.intents.first)
        let _ = queue.enqueue(peerId: 10, maxId: 8)
        queue.finish(sent, result: .rejected("MSG_ID_INVALID"), now: 100)
        XCTAssertEqual(queue.intents.first?.maxId, 8)
        XCTAssertTrue(queue.failures.isEmpty)
    }

    func testFloodWaitSurvivesSerializationAndCoalescing() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let _ = queue.enqueue(peerId: 10, maxId: 5)
        let sent = try XCTUnwrap(queue.intents.first)
        queue.finish(sent, result: .retry(after: 3600), now: 100)
        let data = try JSONEncoder().encode(queue)
        var restored = try JSONDecoder().decode(AyuExplicitReadQueue.self, from: data)
        XCTAssertEqual(restored, queue)
        XCTAssertEqual(restored.enqueue(peerId: 10, maxId: 8), .coalesced)
        XCTAssertEqual(restored.intents.first?.retryAt, 3700)
        XCTAssertEqual(restored.intents.first?.attempts, 1)
    }

    func testTransientErrorsBackOffForeverWithoutEviction() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let _ = queue.enqueue(peerId: 10, maxId: 5)
        for index in 1 ... 40 {
            let sent = try XCTUnwrap(queue.intents.first)
            queue.finish(sent, result: .retry(after: nil), now: Double(index * 1000))
            XCTAssertEqual(queue.intents.count, 1)
            XCTAssertEqual(queue.intents.first?.attempts, min(16, index))
            XCTAssertEqual(queue.intents.first?.retryAt, Double(index * 1000) + AyuExplicitReadQueue.backoff(attempts: index))
        }
        XCTAssertEqual(AyuExplicitReadQueue.backoff(attempts: 1), 1)
        XCTAssertEqual(AyuExplicitReadQueue.backoff(attempts: 2), 2)
        XCTAssertEqual(AyuExplicitReadQueue.backoff(attempts: 40), 300)
        XCTAssertTrue(queue.failures.isEmpty)
    }

    func testOnlyKnownServerRejectionsAreTerminal() {
        for text in ["PEER_ID_INVALID", "CHAT_ID_INVALID", "CHANNEL_INVALID", "CHANNEL_PRIVATE", "MSG_ID_INVALID", "INPUT_USER_DEACTIVATED"] {
            XCTAssertEqual(AyuExplicitReadQueue.classifyError(code: 400, text: text), .rejected(text))
            XCTAssertEqual(AyuExplicitReadQueue.classifyError(code: 500, text: text), .retry(after: nil))
        }
        let transient: [(Int32, String)] = [(400, "NEW_SERVER_ERROR"), (401, "AUTH_KEY_UNREGISTERED"), (500, "INTERNAL"), (-1000, "offline"), (420, "FLOOD_WAIT_bad")]
        for (code, text) in transient {
            XCTAssertEqual(AyuExplicitReadQueue.classifyError(code: code, text: text), .retry(after: nil))
        }
        XCTAssertEqual(AyuExplicitReadQueue.classifyError(code: 420, text: "FLOOD_WAIT_120"), .retry(after: 120))
        XCTAssertEqual(AyuExplicitReadQueue.classifyError(code: 420, text: "FLOOD_PREMIUM_WAIT_3600"), .retry(after: 3600))
    }

    func testTerminalFailureIsPersistedUntilAcknowledged() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let _ = queue.enqueue(peerId: 10, maxId: 5)
        let sent = try XCTUnwrap(queue.intents.first)
        queue.finish(sent, result: .rejected("CHANNEL_PRIVATE"), now: 100)
        XCTAssertTrue(queue.intents.isEmpty)
        var restored = try JSONDecoder().decode(AyuExplicitReadQueue.self, from: JSONEncoder().encode(queue))
        let failure = try XCTUnwrap(restored.failures.first)
        XCTAssertEqual(failure.peerIdValue, 10)
        XCTAssertEqual(failure.maxId, 5)
        XCTAssertEqual(failure.code, "CHANNEL_PRIVATE")
        restored.acknowledgeFailures(ids: [failure.id])
        XCTAssertTrue(restored.failures.isEmpty)
    }

    func testLogoutClearsWorkAndFailuresAndRejectsLateCallbacks() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let _ = queue.enqueue(peerId: 10, maxId: 5)
        let sent = try XCTUnwrap(queue.intents.first)
        queue.recordFailure(peerId: 10, maxId: 5, code: "LOCAL_QUEUE_FULL")
        queue.close()
        queue.finish(sent, result: .retry(after: nil), now: 100)
        XCTAssertEqual(queue.enqueue(peerId: 10, maxId: 8), .loggedOut)
        XCTAssertTrue(queue.closed)
        XCTAssertTrue(queue.intents.isEmpty)
        XCTAssertTrue(queue.failures.isEmpty)
        let restored = try JSONDecoder().decode(AyuExplicitReadQueue.self, from: JSONEncoder().encode(queue))
        XCTAssertEqual(restored, queue)
    }

    func testFailureHistoryIsBoundedAndAcknowledgementIsSelective() {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        for id in 1 ... 100 { queue.recordFailure(peerId: Int64(id), maxId: 5, code: "LOCAL_QUEUE_FULL") }
        XCTAssertEqual(queue.failures.count, AyuExplicitReadQueue.failureCapacity)
        let kept = queue.failures.last!
        queue.acknowledgeFailures(ids: Set(queue.failures.dropLast().map(\.id)))
        XCTAssertEqual(queue.failures, [kept])
    }

    func testLegacyQueueDecodesWithoutInventingServerConfirmation() throws {
        let data = Data("""
        {"ownerId":1,"revision":3,"closed":false,"intents":[{"id":"old","peerId":10,"maxId":5,"attempts":2,"retryAt":123}],"failures":[]}
        """.utf8)
        let value = try JSONDecoder().decode(AyuExplicitReadQueue.self, from: data)
        XCTAssertEqual(value.intents.first?.id, "old")
        XCTAssertTrue(value.receipts.isEmpty)
        XCTAssertEqual(AyuReadHistorySnapshot(value).pending.first?.retryAt, 123)
    }

    func testOnlyServerSuccessProducesConfirmedReceiptAndPersistsIt() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let _ = queue.enqueue(peerId: 10, maxId: 5)
        XCTAssertTrue(queue.receipts.isEmpty)
        let sent = try XCTUnwrap(queue.intents.first)
        queue.finish(sent, result: .retry(after: nil), now: 100)
        XCTAssertTrue(queue.receipts.isEmpty)
        queue.finish(sent, result: .success, now: 102)
        let restored = try JSONDecoder().decode(AyuExplicitReadQueue.self, from: JSONEncoder().encode(queue))
        XCTAssertEqual(restored.receipts.first?.status, .confirmed)
        XCTAssertEqual(restored.receipts.first?.maxId, 5)
        XCTAssertEqual(restored.receipts.first?.timestamp, 102)
    }

    func testStaleCancelCannotRemoveHigherCoalescedRead() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let _ = queue.enqueue(peerId: 10, maxId: 5)
        let selected = try XCTUnwrap(queue.intents.first)
        let _ = queue.enqueue(peerId: 10, maxId: 8)
        XCTAssertEqual(queue.cancel(id: selected.id, maxId: selected.maxId, now: 100), .stale)
        XCTAssertEqual(queue.intents.first?.maxId, 8)
        XCTAssertTrue(queue.receipts.isEmpty)
    }

    func testCancelIsPersistedAsUncertainAndLateResultCannotResurrectIt() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let _ = queue.enqueue(peerId: 10, maxId: 5)
        let sent = try XCTUnwrap(queue.intents.first)
        XCTAssertEqual(queue.cancel(id: sent.id, maxId: 5, now: 100), .applied)
        queue.finish(sent, result: .success, now: 101)
        XCTAssertTrue(queue.intents.isEmpty)
        XCTAssertEqual(queue.receipts.map(\.status), [.cancelled])
        let restored = try JSONDecoder().decode(AyuExplicitReadQueue.self, from: JSONEncoder().encode(queue))
        XCTAssertEqual(restored, queue)
    }

    func testExplicitRetryDoesNotBypassFloodWaitAndInvalidatesOldAttempt() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let _ = queue.enqueue(peerId: 10, maxId: 5)
        let sent = try XCTUnwrap(queue.intents.first)
        queue.finish(sent, result: .retry(after: 100), now: 100)
        XCTAssertEqual(queue.retryPending(id: sent.id, maxId: 5, now: 199), .waitingForRetry)
        XCTAssertEqual(queue.retryPending(id: sent.id, maxId: 5, now: 200), .applied)
        XCTAssertNotEqual(queue.intents.first?.id, sent.id)
        queue.finish(sent, result: .success, now: 201)
        XCTAssertEqual(queue.intents.first?.maxId, 5)
        XCTAssertTrue(queue.receipts.isEmpty)
    }

    func testExplicitFailureRetryKeepsExactBoundAndConsumesOnlySelectedError() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        queue.recordFailure(peerId: 10, maxId: 5, code: "CHANNEL_PRIVATE")
        queue.recordFailure(peerId: 11, maxId: 8, code: "CHANNEL_PRIVATE")
        let failure = try XCTUnwrap(queue.failures.first)
        XCTAssertEqual(queue.retryFailure(id: failure.id), .applied)
        XCTAssertEqual(queue.intents.first?.peerId, 10)
        XCTAssertEqual(queue.intents.first?.maxId, 5)
        XCTAssertEqual(queue.failures.map(\.peerIdValue), [11])
        XCTAssertEqual(queue.retryFailure(id: failure.id), .stale)
    }

    func testUnknownOrUnsupportedRangeCannotBeRetriedAsNewReadAll() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        queue.recordFailure(peerId: 10, maxId: 0, code: "LOCAL_READ_BOUND_UNAVAILABLE")
        queue.recordFailure(peerId: 11, maxId: Int32.max - 1, code: "LOCAL_QUEUE_FULL")
        queue.recordFailure(peerId: 12, maxId: 8, code: "LOCAL_UNSUPPORTED_PEER")
        for failure in queue.failures { XCTAssertEqual(queue.retryFailure(id: failure.id), .invalidInput) }
        XCTAssertTrue(queue.intents.isEmpty)
        XCTAssertEqual(queue.failures.count, 3)
    }

    func testPermanentErrorsRemainReachableBeyondLocalHistoryLimit() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        for peer in 1 ... AyuExplicitReadQueue.capacity {
            let _ = queue.enqueue(peerId: Int64(peer), maxId: 5)
            let sent = try XCTUnwrap(queue.intents.first)
            queue.finish(sent, result: .rejected("CHANNEL_PRIVATE"), now: 100)
        }
        XCTAssertEqual(queue.failures.count, AyuExplicitReadQueue.capacity)
        XCTAssertEqual(queue.enqueue(peerId: 2000, maxId: 5), .queueFull)
        let selected = try XCTUnwrap(queue.failures.first)
        XCTAssertEqual(queue.retryFailure(id: selected.id), .applied)
        XCTAssertEqual(queue.intents.count, 1)
        XCTAssertEqual(queue.failures.filter { !$0.code.hasPrefix("LOCAL_") }.count, AyuExplicitReadQueue.capacity - 1)
    }

    func testLogoutClearsReceiptsAndMakesAllControlsInert() throws {
        var queue = AyuExplicitReadQueue(ownerId: 1)
        let _ = queue.enqueue(peerId: 10, maxId: 5)
        let selected = try XCTUnwrap(queue.intents.first)
        queue.recordFailure(peerId: 11, maxId: 8, code: "CHANNEL_PRIVATE")
        let failure = try XCTUnwrap(queue.failures.first)
        queue.close()
        XCTAssertEqual(queue.cancel(id: selected.id, maxId: 5, now: 100), .loggedOut)
        XCTAssertEqual(queue.retryPending(id: selected.id, maxId: 5, now: 100), .loggedOut)
        XCTAssertEqual(queue.retryFailure(id: failure.id), .loggedOut)
        XCTAssertTrue(queue.receipts.isEmpty)
        XCTAssertTrue(queue.failures.isEmpty)
    }
}
