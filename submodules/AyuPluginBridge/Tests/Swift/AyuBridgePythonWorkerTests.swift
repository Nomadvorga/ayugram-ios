import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Worker-model regressions: thread identity, join/timeout, generation-based
/// revocation, CPU accounting, main-thread sync-wait guard. No interpreter.
final class AyuBridgePythonWorkerTests: XCTestCase {
    func testThreadIdentityIsPerNameAndStable() {
        let workers = AyuBridgePythonWorkers()
        let expectation = self.expectation(description: "worker ran")
        var observedName: String?
        workers.run(pluginID: "p", threadName: "downloader", body: { name in
            observedName = name
            expectation.fulfill()
        }, completion: { _ in })
        self.waitForExpectations(timeout: 5)
        XCTAssertEqual(observedName, "downloader")
        XCTAssertEqual(workers.workerCount(pluginID: "p"), 1)
    }

    func testDistinctNamesCreateDistinctQueues() {
        let workers = AyuBridgePythonWorkers()
        let first = self.expectation(description: "first")
        let second = self.expectation(description: "second")
        workers.run(pluginID: "p", threadName: "a", body: { _ in first.fulfill() }, completion: { _ in })
        workers.run(pluginID: "p", threadName: "b", body: { _ in second.fulfill() }, completion: { _ in })
        self.waitForExpectations(timeout: 5)
        XCTAssertEqual(workers.workerCount(pluginID: "p"), 2)
    }

    func testJoinCompletesAndTimesOut() throws {
        let workers = AyuBridgePythonWorkers()
        let done = self.expectation(description: "done")
        workers.run(pluginID: "p", threadName: "quick", body: { _ in done.fulfill() }, completion: { _ in })
        self.waitForExpectations(timeout: 5)
        XCTAssertNoThrow(try workers.join(pluginID: "p", threadName: "quick", timeout: 2))
        XCTAssertThrowsError(try workers.join(pluginID: "p", threadName: "missing", timeout: 0.2)) { error in
            XCTAssertEqual(error as? AyuBridgeWorkerError, .joinTimedOut("p.missing"))
        }
    }

    func testJoinFromMainThreadIsRejectedNotWaited() throws {
        let workers = AyuBridgePythonWorkers()
        XCTAssertThrowsError(try workers.join(pluginID: "p", threadName: "a", timeout: 5)) { error in
            XCTAssertEqual(error as? AyuBridgeWorkerError, .mainThreadSyncWaitForbidden)
        }
    }

    func testUnloadDropsCallbacksOfOldGeneration() throws {
        let workers = AyuBridgePythonWorkers()
        workers.unload(pluginID: "p")
        let delivered = self.expectation(description: "never")
        delivered.isInverted = true
        let finished = self.expectation(description: "completion failed")
        workers.run(pluginID: "p", threadName: "late", body: { _ in }, completion: { result in
            if case .failure = result { finished.fulfill() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { delivered.fulfill() }
        })
        self.waitForExpectations(timeout: 5)
    }

    func testCompletionAfterUnloadIsDropped() {
        let workers = AyuBridgePythonWorkers()
        let group = DispatchGroup()
        group.enter()
        workers.completion(pluginID: "p") { group.leave() }
        workers.unload(pluginID: "p")
        let dropped = self.expectation(description: "dropped")
        dropped.isInverted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { group.leave(); dropped.fulfill() }
        _ = group.wait(timeout: .now() + 2)
        self.waitForExpectations(timeout: 5)
    }

    func testCPUBudgetChargesAndExhausts() {
        let budget = AyuBridgeCPUBudget(limitSeconds: 1.0)
        XCTAssertTrue(budget.charge(seconds: 0.6))
        XCTAssertFalse(budget.isExhausted())
        XCTAssertFalse(budget.charge(seconds: 0.6))
        XCTAssertTrue(budget.isExhausted())
        XCTAssertEqual(budget.consumed(), 1.2, accuracy: 0.0001)
        XCTAssertFalse(budget.charge(seconds: -5), "negative charge must not move the meter backwards")
        XCTAssertEqual(budget.consumed(), 1.2, accuracy: 0.0001)
    }

    func testBudgetExhaustionFailsWork() {
        let workers = AyuBridgePythonWorkers(defaultBudgetSeconds: 0.0)
        let failed = self.expectation(description: "budget failure")
        workers.run(pluginID: "p", threadName: "heavy", body: { _ in }, completion: { result in
            if case let .failure(error) = result { XCTAssertEqual(error as? AyuBridgeWorkerError, .budgetExhausted("p")); failed.fulfill() }
        })
        self.waitForExpectations(timeout: 5)
    }
}
