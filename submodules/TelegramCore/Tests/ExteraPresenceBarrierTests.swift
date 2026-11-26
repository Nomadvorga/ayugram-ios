import MtProtoKit
import SwiftSignalKit
import TelegramApi
import XCTest
@testable import TelegramCore

final class ExteraPresenceBarrierTests: StateSyncTestCase {
    func testTwoPendingOperationsMustBothFinishBeforeReader() {
        var finishA: (() -> Void)?
        var finishB: (() -> Void)?
        let a = ayuTrackedPresence(network: self.network, operation: Signal<Api.Bool, MTRpcError> { subscriber in
            finishA = { subscriber.putCompletion() }; return EmptyDisposable
        }).start()
        let b = ayuTrackedPresence(network: self.network, operation: Signal<Api.Bool, MTRpcError> { subscriber in
            finishB = { subscriber.putCompletion() }; return EmptyDisposable
        }).start()
        let early = self.expectation(description: "no read before both operations finish"); early.isInverted = true
        let earlyRead = exteraPresenceBarrier(network: self.network).start(next: { _ in early.fulfill() })
        finishA?(); a.dispose()
        self.wait(for: [early], timeout: 0.15)
        earlyRead.dispose()
        let ready = self.expectation(description: "read after final completion and settle delay")
        let start = ProcessInfo.processInfo.systemUptime
        let read = exteraPresenceBarrier(network: self.network).start(next: { _ in
            XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.09)
            ready.fulfill()
        })
        finishB?()
        self.wait(for: [ready], timeout: 2)
        read.dispose(); b.dispose()
        finishA = nil; finishB = nil
    }

    func testCancellationReleasesBarrierWithoutCreatingRequests() {
        let pending = ayuTrackedPresence(network: self.network, operation: Signal<Api.Bool, MTRpcError>.never()).start()
        let ready = self.expectation(description: "cancel releases read")
        let read = exteraPresenceBarrier(network: self.network).start(next: { _ in ready.fulfill() })
        pending.dispose()
        self.wait(for: [ready], timeout: 2)
        read.dispose()
        // Both operations above are synthetic signals. Neither can send a network
        // presence packet or introduce a read-history/read-contents request.
    }
}
