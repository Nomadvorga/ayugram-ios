import Foundation
import XCTest
import Postbox
import SwiftSignalKit
import TelegramApi
@testable import TelegramCore

/// The real Postbox/operation-log view and the production runner; only the
/// transport and clock are injected. No account, login or live server is needed.
final class AyuExplicitReadPersistenceTests: StateSyncTestCase {
    private var ownerId: PeerId { StateSyncFixture.accountPeerId }
    private let peerId = StateSyncFixture.userPeerId(910)

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.fixture.seedAccount(state: self.state(pts: 100))
    }

    private func enqueue(maxId: Int32, peerId: PeerId? = nil) -> AyuReadHistoryEnqueueResult? {
        let ownerId = self.ownerId
        let peerId = peerId ?? self.peerId
        return self.fixture.transaction { transaction in
            enqueueAyuExplicitRead(transaction: transaction, ownerId: ownerId, peerId: peerId, maxId: maxId)
        }
    }

    private func stored() -> AyuExplicitReadQueue? {
        let ownerId = self.ownerId
        return self.fixture.transaction { ayuExplicitReadQueue(transaction: $0, ownerId: ownerId) }
    }

    private func startRunner(online: Signal<Bool, NoError> = .single(true), loggedOut: Signal<Bool, NoError> = .single(false), now: @escaping () -> Double = { 100 }, request: @escaping (PeerId, Int32) -> Signal<AyuExplicitReadAttemptResult, NoError>) -> Disposable {
        return managedAyuExplicitReadOperations(postbox: self.fixture.postbox, ownerId: self.ownerId, loggedOut: loggedOut, online: online, now: now, request: request).start()
    }

    func testTransactionCoalescesAndFreezesReadAllBeforeLaterArrivals() throws {
        self.fixture.seedReadState(peerId: self.peerId, maxIncomingReadId: 4, maxOutgoingReadId: 0, maxKnownId: 25, count: 5)
        XCTAssertEqual(self.enqueue(maxId: Int32.max - 1), .queued)
        self.fixture.seedReadState(peerId: self.peerId, maxIncomingReadId: 4, maxOutgoingReadId: 0, maxKnownId: 30, count: 10)
        XCTAssertEqual(try XCTUnwrap(self.stored()).intents.first?.maxId, 25)
        XCTAssertEqual(self.enqueue(maxId: 20), .coalesced)
        XCTAssertEqual(try XCTUnwrap(self.stored()).intents.first?.maxId, 25)
        XCTAssertEqual(self.enqueue(maxId: 29), .coalesced)
        XCTAssertEqual(try XCTUnwrap(self.stored()).intents.first?.maxId, 29)
    }

    func testNoKnownReadAllBoundAndUnsupportedPeersAreObservableLocalFailures() throws {
        XCTAssertEqual(self.enqueue(maxId: Int32.max - 1), .invalidInput)
        XCTAssertEqual(self.enqueue(maxId: 5, peerId: PeerId(namespace: Namespaces.Peer.SecretChat, id: PeerId.Id._internalFromInt64Value(1))), .invalidInput)
        let value = try XCTUnwrap(self.stored())
        XCTAssertTrue(value.intents.isEmpty)
        XCTAssertEqual(value.failures.map(\.code), ["LOCAL_READ_BOUND_UNAVAILABLE", "LOCAL_UNSUPPORTED_PEER"])
    }

    func testNoExplicitIntentMeansNoServerReadEvenWithLocalReadState() {
        self.fixture.seedReadState(peerId: self.peerId, maxIncomingReadId: 25, maxOutgoingReadId: 0, maxKnownId: 25, count: 0)
        let unexpected = self.expectation(description: "ordinary local read must not authorize a bypass")
        unexpected.isInverted = true
        let runner = self.startRunner { _, _ in unexpected.fulfill(); return .single(.success) }
        defer { runner.dispose() }
        self.wait(for: [unexpected], timeout: 0.2)
    }

    func testOfflineQueueResumesAndOldSuccessCannotLoseCoalescedAction() throws {
        XCTAssertEqual(self.enqueue(maxId: 5), .queued)
        let online = ValuePromise(false, ignoreRepeated: true)
        let subscribers = SignalRecorder<Subscriber<AyuExplicitReadAttemptResult, NoError>>()
        let sent = SignalRecorder<Int32>()
        let cancelled = SignalRecorder<Bool>()
        let offline = Atomic<Bool>(value: true)
        let premature = self.expectation(description: "offline runner must preserve work without sending")
        premature.isInverted = true
        let runner = self.startRunner(online: online.get()) { _, maxId in
            return Signal { subscriber in
                if offline.with({ $0 }) { premature.fulfill() }
                sent.record(maxId)
                subscribers.record(subscriber)
                return ActionDisposable { cancelled.record(true) }
            }
        }
        defer { runner.dispose() }
        self.wait(for: [premature], timeout: 0.2)
        let _ = offline.swap(false)
        online.set(true)
        sent.wait { $0 == [5] }
        subscribers.wait { !$0.isEmpty }
        XCTAssertEqual(self.enqueue(maxId: 8), .coalesced)
        online.set(false)
        cancelled.wait { !$0.isEmpty }
        XCTAssertEqual(try XCTUnwrap(self.stored()).intents.first?.maxId, 8)
        subscribers.values.first?.putNext(.success)
        XCTAssertEqual(try XCTUnwrap(self.stored()).intents.first?.maxId, 8)
        runner.dispose()

        let resumed = self.startRunner { _, maxId in sent.record(maxId); return .single(.success) }
        defer { resumed.dispose() }
        sent.wait { $0 == [5, 8] }
        self.fixture.eventually { self.stored()?.intents.isEmpty == true }
    }

    func testFailureDeadlineSurvivesRunnerRestartAndNewEnqueue() throws {
        XCTAssertEqual(self.enqueue(maxId: 5), .queued)
        let clock = Atomic<Double>(value: 100)
        let attempts = SignalRecorder<Int32>()
        let runner = self.startRunner(now: { clock.with { $0 } }) { _, maxId in
            attempts.record(maxId)
            return .single(.retry(after: 3600))
        }
        self.fixture.eventually { self.stored()?.intents.first?.retryAt == 3700 }
        runner.dispose()
        XCTAssertEqual(self.enqueue(maxId: 8), .coalesced)
        XCTAssertEqual(try XCTUnwrap(self.stored()).intents.first?.retryAt, 3700)

        let online = ValuePromise(true, ignoreRepeated: true)
        let premature = self.expectation(description: "no send before persisted flood deadline")
        premature.isInverted = true
        let resumed = self.startRunner(online: online.get(), now: { clock.with { $0 } }) { _, maxId in
            if clock.with({ $0 }) < 3700 { premature.fulfill() }
            attempts.record(maxId)
            return .single(.success)
        }
        defer { resumed.dispose() }
        self.wait(for: [premature], timeout: 0.2)
        let _ = clock.swap(3700)
        online.set(false)
        online.set(true)
        attempts.wait { $0 == [5, 8] }
        self.fixture.eventually { self.stored()?.intents.isEmpty == true }
    }

    func testTerminalErrorPersistsAndEmptyTransportCompletionRetries() throws {
        XCTAssertEqual(self.enqueue(maxId: 5), .queued)
        let rejecting = self.startRunner { _, _ in .single(.rejected("CHANNEL_PRIVATE")) }
        self.fixture.eventually { self.stored()?.failures.first?.code == "CHANNEL_PRIVATE" }
        rejecting.dispose()
        XCTAssertTrue(try XCTUnwrap(self.stored()).intents.isEmpty)

        XCTAssertEqual(self.enqueue(maxId: 8), .queued)
        let empty = self.startRunner { _, _ in .complete() }
        defer { empty.dispose() }
        self.fixture.eventually { self.stored()?.intents.first?.attempts == 1 }
        let value = try XCTUnwrap(self.stored())
        XCTAssertEqual(value.intents.first?.maxId, 8)
        XCTAssertEqual(value.intents.first?.retryAt, 101)
        XCTAssertEqual(value.failures.first?.code, "CHANNEL_PRIVATE")
    }

    func testLogoutCancelsInFlightClearsDurableStateAndRejectsEnqueue() throws {
        XCTAssertEqual(self.enqueue(maxId: 5), .queued)
        let logout = ValuePromise(false, ignoreRepeated: true)
        let sent = SignalRecorder<Bool>()
        let cancelled = SignalRecorder<Bool>()
        let runner = self.startRunner(loggedOut: logout.get()) { _, _ in
            return Signal { _ in
                sent.record(true)
                return ActionDisposable { cancelled.record(true) }
            }
        }
        defer { runner.dispose() }
        sent.wait { !$0.isEmpty }
        logout.set(true)
        cancelled.wait { !$0.isEmpty }
        self.fixture.eventually { self.stored()?.closed == true }
        let value = try XCTUnwrap(self.stored())
        XCTAssertTrue(value.intents.isEmpty)
        XCTAssertTrue(value.failures.isEmpty)
        XCTAssertEqual(self.enqueue(maxId: 8), .loggedOut)
    }

    func testStalledTransportTimesOutAndPersistsBackoff() throws {
        XCTAssertEqual(self.enqueue(maxId: 5), .queued)
        let cancelled = SignalRecorder<Bool>()
        let runner = managedAyuExplicitReadOperations(postbox: self.fixture.postbox, ownerId: self.ownerId, loggedOut: .single(false), online: .single(true), now: { 100 }, attemptTimeout: 0.05, request: { _, _ in
            Signal { _ in ActionDisposable { cancelled.record(true) } }
        }).start()
        defer { runner.dispose() }
        self.fixture.eventually { self.stored()?.intents.first?.attempts == 1 }
        cancelled.wait { !$0.isEmpty }
        XCTAssertEqual(try XCTUnwrap(self.stored()).intents.first?.retryAt, 101)
    }

    func testRealChannelTransportKeepsFalsePendingAndClassifiesServerError() {
        let channel = StateSyncFixture.channelPeerId(911)
        self.fixture.seedChannel(StateSyncFixture.makeChannel(id: channel, accessHash: 1, title: "Explicit"), state: nil)
        XCTAssertEqual(self.enqueue(maxId: 9, peerId: channel), .queued)
        self.makeStateManager()
        self.server.on("channels.readHistory", .result(Api.Bool.boolFalse))
        XCTAssertEqual(self.fixture.wait(pushAyuExplicitRead(postbox: self.fixture.postbox, network: self.network, stateManager: self.stateManager, ownerId: self.ownerId, peerId: channel, maxId: 9)), .retry(after: nil))
        self.server.on("channels.readHistory", .error(code: 400, text: "CHANNEL_PRIVATE"))
        XCTAssertEqual(self.fixture.wait(pushAyuExplicitRead(postbox: self.fixture.postbox, network: self.network, stateManager: self.stateManager, ownerId: self.ownerId, peerId: channel, maxId: 9)), .rejected("CHANNEL_PRIVATE"))
        self.server.on("channels.readHistory", .result(Api.Bool.boolTrue))
        XCTAssertEqual(self.fixture.wait(pushAyuExplicitRead(postbox: self.fixture.postbox, network: self.network, stateManager: self.stateManager, ownerId: self.ownerId, peerId: channel, maxId: 9)), .success)
        XCTAssertEqual(self.server.requestNames, ["channels.readHistory", "channels.readHistory", "channels.readHistory"])
    }

    func testRealTransportCannotBypassWithoutPersistedIntent() {
        self.fixture.seedPeers([StateSyncFixture.makeUser(id: self.peerId, accessHash: 1, firstName: "Explicit")])
        self.makeStateManager()
        XCTAssertEqual(self.fixture.wait(pushAyuExplicitRead(postbox: self.fixture.postbox, network: self.network, stateManager: self.stateManager, ownerId: self.ownerId, peerId: self.peerId, maxId: 5)), .retry(after: nil))
        XCTAssertTrue(self.server.requestNames.isEmpty)
    }

    func testOwnerMismatchNeverSendsOrAdoptsOtherAccountWork() throws {
        XCTAssertEqual(self.enqueue(maxId: 5), .queued)
        let unexpected = self.expectation(description: "foreign owner must never send")
        unexpected.isInverted = true
        let foreignOwner = StateSyncFixture.userPeerId(999)
        let runner = managedAyuExplicitReadOperations(postbox: self.fixture.postbox, ownerId: foreignOwner, loggedOut: .single(false), online: .single(true), request: { _, _ in
            unexpected.fulfill()
            return .single(.success)
        }).start()
        defer { runner.dispose() }
        self.wait(for: [unexpected], timeout: 0.2)
        let peerId = self.peerId
        XCTAssertEqual(self.fixture.transaction { enqueueAyuExplicitRead(transaction: $0, ownerId: foreignOwner, peerId: peerId, maxId: 8) }, .loggedOut)
        XCTAssertEqual(try XCTUnwrap(self.stored()).intents.first?.maxId, 5)
    }

    func testOperationLogSurvivesActualDatabaseCloseAndReopen() throws {
        let path = self.fixture.basePath + "/explicit-read-reopen"
        let ownerId = self.ownerId
        let peerId = self.peerId
        var postbox: Postbox? = try self.openPostbox(at: path)
        let _ = self.fixture.wait(postbox!.transaction { transaction -> Void in
            transaction.setState(AuthorizedAccountState(isTestingEnvironment: false, masterDatacenterId: 2, peerId: ownerId, state: nil, invalidatedChannels: []))
            XCTAssertEqual(enqueueAyuExplicitRead(transaction: transaction, ownerId: ownerId, peerId: peerId, maxId: 15), .queued)
            updateAyuExplicitReadQueue(transaction: transaction, ownerId: ownerId, { value in
                let sent = value.intents[0]
                value.finish(sent, result: .retry(after: 3600), now: 100)
                value.recordFailure(peerId: 10, maxId: 5, code: "CHANNEL_PRIVATE")
                let _ = value.enqueue(peerId: 11, maxId: 8)
                value.finish(value.intents.last!, result: .success, now: 101)
            })
        })
        weak var releasedPostbox = postbox
        postbox = nil
        self.fixture.eventually { releasedPostbox == nil }

        postbox = try self.openPostbox(at: path)
        let restored = try XCTUnwrap(self.fixture.wait(postbox!.transaction { ayuExplicitReadQueue(transaction: $0, ownerId: ownerId) }))
        XCTAssertEqual(restored.intents.first?.maxId, 15)
        XCTAssertEqual(restored.intents.first?.retryAt, 3700)
        XCTAssertEqual(restored.intents.first?.attempts, 1)
        let snapshot = try XCTUnwrap(self.fixture.wait(ayuReadHistoryState(postbox: postbox!, ownerId: ownerId)))
        XCTAssertEqual(snapshot.pending.first?.retryAt, 3700)
        XCTAssertEqual(snapshot.failures.first?.code, "CHANNEL_PRIVATE")
        XCTAssertEqual(snapshot.receipts.first?.status, .confirmed)
        postbox = nil
    }

    func testCancelControlCancelsRunnerAndObservationCannotResend() throws {
        XCTAssertEqual(self.enqueue(maxId: 5), .queued)
        let sent = SignalRecorder<Bool>()
        let cancelled = SignalRecorder<Bool>()
        let runner = self.startRunner { _, _ in
            Signal { _ in
                sent.record(true)
                return ActionDisposable { cancelled.record(true) }
            }
        }
        defer { runner.dispose() }
        sent.wait { !$0.isEmpty }
        let selected = try XCTUnwrap(self.stored()?.intents.first)
        let ownerId = self.ownerId
        XCTAssertEqual(self.fixture.transaction { controlAyuReadHistory(transaction: $0, ownerId: ownerId, action: .cancel(id: selected.id, maxId: 5), now: 100) }, .applied)
        cancelled.wait { !$0.isEmpty }
        let value = try XCTUnwrap(self.stored())
        XCTAssertTrue(value.intents.isEmpty)
        XCTAssertEqual(value.receipts.first?.status, .cancelled)
        runner.dispose()
        let unexpected = self.expectation(description: "relaunch after Cancel must not send")
        unexpected.isInverted = true
        let reopened = self.startRunner { _, _ in unexpected.fulfill(); return .single(.success) }
        defer { reopened.dispose() }
        self.wait(for: [unexpected], timeout: 0.2)
    }

    func testStaleControlsAndForeignOwnerCannotChangeStoredWork() throws {
        XCTAssertEqual(self.enqueue(maxId: 5), .queued)
        let selected = try XCTUnwrap(self.stored()?.intents.first)
        XCTAssertEqual(self.enqueue(maxId: 8), .coalesced)
        let ownerId = self.ownerId
        let foreignOwner = StateSyncFixture.userPeerId(999)
        for action in [AyuReadHistoryControl.cancel(id: selected.id, maxId: 5), .retryPending(id: selected.id, maxId: 5)] {
            XCTAssertEqual(self.fixture.transaction { controlAyuReadHistory(transaction: $0, ownerId: ownerId, action: action, now: 100) }, .stale)
            XCTAssertEqual(self.fixture.transaction { controlAyuReadHistory(transaction: $0, ownerId: foreignOwner, action: action, now: 100) }, .loggedOut)
        }
        XCTAssertEqual(self.stored()?.intents.first?.maxId, 8)
        XCTAssertTrue(try XCTUnwrap(self.stored()).receipts.isEmpty)
    }

    func testRetryPermanentErrorRequiresExplicitControlAndKeepsBound() throws {
        let ownerId = self.ownerId
        self.fixture.transaction { transaction in
            updateAyuExplicitReadQueue(transaction: transaction, ownerId: ownerId, { $0.recordFailure(peerId: 10, maxId: 5, code: "CHANNEL_PRIVATE") })
        }
        let failure = try XCTUnwrap(self.stored()?.failures.first)
        let states = SignalRecorder<AyuReadHistorySnapshot>()
        let observer = ayuReadHistoryState(postbox: self.fixture.postbox, ownerId: ownerId).start(next: { states.record($0) })
        defer { observer.dispose() }
        states.wait { $0.last?.failures.first?.id == failure.id }
        let unexpected = self.expectation(description: "opening status cannot retry permanent errors")
        unexpected.isInverted = true
        let runner = self.startRunner { _, _ in unexpected.fulfill(); return .single(.success) }
        self.wait(for: [unexpected], timeout: 0.2)
        runner.dispose()
        XCTAssertEqual(self.fixture.transaction { controlAyuReadHistory(transaction: $0, ownerId: ownerId, action: .retryFailure(id: failure.id), now: 100) }, .applied)
        XCTAssertEqual(self.stored()?.intents.first?.maxId, 5)
        XCTAssertTrue(try XCTUnwrap(self.stored()).failures.isEmpty)
    }

    func testReadOnlyPreparationAndObservationCannotAuthorizeAndFreezeConfirmationScope() throws {
        self.fixture.seedReadState(peerId: self.peerId, maxIncomingReadId: 4, maxOutgoingReadId: 0, maxKnownId: 25, count: 5)
        let ownerId = self.ownerId
        let peerId = self.peerId
        let captured = try XCTUnwrap(self.fixture.transaction {
            ayuReadHistoryKnownBounds(transaction: $0, ownerId: ownerId, peerIdValues: [peerId.toInt64()])
        })
        let observed = try XCTUnwrap(self.fixture.wait(ayuReadHistoryState(postbox: self.fixture.postbox, ownerId: ownerId)))
        XCTAssertTrue(observed.pending.isEmpty)
        XCTAssertTrue(observed.receipts.isEmpty)
        // A refresh while the confirmation is open must not broaden its range.
        self.fixture.seedReadState(peerId: self.peerId, maxIncomingReadId: 4, maxOutgoingReadId: 0, maxKnownId: 30, count: 10)
        XCTAssertTrue(try XCTUnwrap(self.stored()).intents.isEmpty)
        XCTAssertEqual(captured, [AyuReadHistoryRequest(peerIdValue: peerId.toInt64(), maxId: 25)])
        XCTAssertEqual(self.enqueue(maxId: captured[0].maxId), .queued)
        XCTAssertEqual(self.stored()?.intents.first?.maxId, 25)
    }

    func testStaleFailureSelectionCannotRetryAfterDismissOrLogout() throws {
        let ownerId = self.ownerId
        self.fixture.transaction { transaction in
            updateAyuExplicitReadQueue(transaction: transaction, ownerId: ownerId, { $0.recordFailure(peerId: 10, maxId: 5, code: "CHANNEL_PRIVATE") })
        }
        let failure = try XCTUnwrap(self.stored()?.failures.first)
        XCTAssertEqual(self.fixture.transaction { controlAyuReadHistory(transaction: $0, ownerId: ownerId, action: .dismissFailure(id: failure.id), now: 100) }, .applied)
        XCTAssertEqual(self.fixture.transaction { controlAyuReadHistory(transaction: $0, ownerId: ownerId, action: .retryFailure(id: failure.id), now: 100) }, .stale)
        self.fixture.transaction { transaction in updateAyuExplicitReadQueue(transaction: transaction, ownerId: ownerId, { $0.close() }) }
        XCTAssertEqual(self.fixture.transaction { controlAyuReadHistory(transaction: $0, ownerId: ownerId, action: .retryFailure(id: failure.id), now: 100) }, .loggedOut)
        XCTAssertEqual(self.fixture.transaction { ayuReadHistoryKnownBounds(transaction: $0, ownerId: ownerId, peerIdValues: [10]) }, [])
        XCTAssertTrue(try XCTUnwrap(self.stored()).intents.isEmpty)
    }

    func testServerConfirmationIsRecordedAndObservableAfterPendingDisappears() throws {
        XCTAssertEqual(self.enqueue(maxId: 5), .queued)
        let runner = self.startRunner { _, _ in .single(.success) }
        defer { runner.dispose() }
        self.fixture.eventually { self.stored()?.receipts.first?.status == .confirmed }
        let value = try XCTUnwrap(self.stored())
        XCTAssertTrue(value.intents.isEmpty)
        XCTAssertEqual(AyuReadHistorySnapshot(value).receipts.first?.maxId, 5)
    }

    private func openPostbox(at path: String) throws -> Postbox {
        let parameters = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: false, key: ValueBoxEncryptionParameters.Key(data: Data(count: 32))!, salt: ValueBoxEncryptionParameters.Salt(data: Data(count: 16))!)
        return try XCTUnwrap(self.fixture.wait(Postbox.openPostboxForExplicitReadTest(path: path, parameters: parameters)))
    }
}

private extension Postbox {
    static func openPostboxForExplicitReadTest(path: String, parameters: ValueBoxEncryptionParameters) -> Signal<Postbox, NoError> {
        return openPostbox(basePath: path, seedConfiguration: telegramPostboxSeedConfiguration, encryptionParameters: parameters, timestampForAbsoluteTimeBasedOperations: 100, isMainProcess: true, isTemporary: false, isReadOnly: false, useCopy: false, useCaches: true, removeDatabaseOnError: false)
        |> mapToSignal { result -> Signal<Postbox, NoError> in
            switch result {
            case let .postbox(postbox): return .single(postbox)
            case .upgrading: return .never()
            case .error: return .complete()
            }
        }
    }
}
