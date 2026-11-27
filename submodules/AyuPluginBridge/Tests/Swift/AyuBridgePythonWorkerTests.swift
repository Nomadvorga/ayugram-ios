import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Worker-model regressions: thread identity, join/timeout, generation-based
/// revocation, CPU accounting, main-thread sync-wait guard. No interpreter.
final class AyuBridgePythonWorkerTests: XCTestCase {
    func testThreadIdentityIsPerNameAndStable() {
        let workers = AyuBridgePythonWorkers()
        let expectation = self.expectation(description: "worker ran")
        let observedName = AyuTestBox<String?>(nil)
        workers.run(pluginID: "p", threadName: "downloader", body: { name in
            observedName.value = name
            expectation.fulfill()
        }, completion: { _ in })
        self.waitForExpectations(timeout: 5)
        XCTAssertEqual(observedName.value, "downloader")
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
        let release = DispatchSemaphore(value: 0)
        workers.run(pluginID: "p", threadName: "busy", body: { _ in release.wait() }, completion: { _ in })
        defer { release.signal() }
        // join refuses the main thread, which is where XCTest runs this method.
        let joined = self.expectation(description: "joined off main")
        let failures = AyuTestBox<(quick: Error?, missing: Error?, busy: Error?)>((nil, nil, nil))
        DispatchQueue.global().async {
            var quick: Error?, missing: Error?, busy: Error?
            do { try workers.join(pluginID: "p", threadName: "quick", timeout: 2) } catch { quick = error }
            do { try workers.join(pluginID: "p", threadName: "missing", timeout: 0.2) } catch { missing = error }
            do { try workers.join(pluginID: "p", threadName: "busy", timeout: 0.2) } catch { busy = error }
            failures.value = (quick, missing, busy)
            joined.fulfill()
        }
        self.wait(for: [joined], timeout: 5)
        XCTAssertNil(failures.value.quick)
        XCTAssertNil(failures.value.missing, "A worker that was never started has nothing to wait for")
        XCTAssertEqual(failures.value.busy as? AyuBridgeWorkerError, .joinTimedOut("p.busy"))
    }

    func testJoinFromMainThreadIsRejectedNotWaited() throws {
        let workers = AyuBridgePythonWorkers()
        XCTAssertThrowsError(try workers.join(pluginID: "p", threadName: "a", timeout: 5)) { error in
            XCTAssertEqual(error as? AyuBridgeWorkerError, .mainThreadSyncWaitForbidden)
        }
    }

    func testUnloadDropsCallbacksOfOldGeneration() throws {
        let workers = AyuBridgePythonWorkers()
        // Work queued behind a running job belongs to the generation that unload ends.
        let gate = DispatchSemaphore(value: 0)
        let running = self.expectation(description: "first job running")
        workers.run(pluginID: "p", threadName: "late", body: { _ in running.fulfill(); gate.wait() }, completion: { _ in })
        self.wait(for: [running], timeout: 5)
        let delivered = self.expectation(description: "never")
        delivered.isInverted = true
        let finished = self.expectation(description: "completion failed")
        workers.run(pluginID: "p", threadName: "late", body: { _ in delivered.fulfill() }, completion: { result in
            if case let .failure(error) = result, error as? AyuBridgeWorkerError == .pluginUnloaded("p") { finished.fulfill() }
        })
        workers.unload(pluginID: "p")
        gate.signal()
        self.wait(for: [finished], timeout: 5)
        self.wait(for: [delivered], timeout: 0.3)
    }

    func testCompletionAfterUnloadIsDropped() {
        let workers = AyuBridgePythonWorkers()
        let dropped = self.expectation(description: "dropped")
        dropped.isInverted = true
        workers.completion(pluginID: "p") { dropped.fulfill() }
        workers.unload(pluginID: "p")
        self.waitForExpectations(timeout: 0.5)
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
        workers.run(pluginID: "p", threadName: "heavy", body: { _ in Thread.sleep(forTimeInterval: 0.01) }, completion: { result in
            if case let .failure(error) = result { XCTAssertEqual(error as? AyuBridgeWorkerError, .budgetExhausted("p")); failed.fulfill() }
        })
        self.waitForExpectations(timeout: 5)
    }
}
