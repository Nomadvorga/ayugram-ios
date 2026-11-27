import Foundation
import XCTest
@testable import AyuPluginBridge

/// The interpreter queue as the delivery queue sees it: it holds what it accepted until the
/// test completes it, and refuses with the runtime's queue-full error while `refusing`.
private final class HeldRuntime: @unchecked Sendable {
    struct Call { let json: String; let owner: String; let completion: AyuPluginDeliveryQueue.Completion }
    let held = AyuTestBox<[Call]>([])
    let accepted = AyuTestBox<[String]>([])
    let offered = AyuTestBox<[String]>([])
    let refusing = AyuTestBox(false)
    let largestHeld = AyuTestBox(0)

    func submit(_ entry: AyuPluginDeliveryQueue.Entry, _ json: String, _ owner: String, _ completion: @escaping AyuPluginDeliveryQueue.Completion) {
        self.offered.update { $0.append(json) }
        guard !self.refusing.value else { completion(nil, AyuPluginDeliveryQueue.overflow()); return }
        self.accepted.update { $0.append(json) }
        var count = 0
        self.held.update { $0.append(Call(json: json, owner: owner, completion: completion)); count = $0.count }
        self.largestHeld.update { $0 = max($0, count) }
    }

    /// Completes the oldest accepted delivery, as the interpreter does.
    @discardableResult func completeNext(_ result: String = "null") -> Bool {
        var call: Call?
        self.held.update { if !$0.isEmpty { call = $0.removeFirst() } }
        call?.completion(result, nil)
        return call != nil
    }

    func completeAll() { while self.completeNext() {} }
}

/// A provider whose calls send callbacks from inside the dispatch and return sized results.
private final class SendingProvider: AyuPluginHostProvider, @unchecked Sendable {
    let capabilities = ["client.call", "telegram.request"]
    func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue { throw AyuBridgeFailure.unsupported(operation) }
    func prepareCall(pluginID: String, operation: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        if let reference = arguments["callback"] {
            let callback = try context.callback(reference)
            let padding = String(repeating: "p", count: Int(arguments["padding"]?.integer ?? 0))
            for index in 0..<(arguments["count"]?.integer ?? 0) {
                if arguments["guaranteed"] == .bool(true) {
                    callback.send([.integer(index), .string(padding)], orOnOverflow: [.string("substitute")])
                } else {
                    callback.send([.integer(index), .string(padding)])
                }
            }
        }
        return AyuBridgeProviderResult(.value(.string(String(repeating: "r", count: Int(arguments["reply"]?.integer ?? 0)))))
    }
    func detach(pluginID: String) {}
}

final class AyuPluginDeliveryQueueTests: XCTestCase {
    private typealias Queue = AyuPluginDeliveryQueue

    private func queue(_ runtime: HeldRuntime, _ configure: (inout Queue.Limits) -> Void = { _ in }) -> Queue {
        var limits = Queue.Limits()
        configure(&limits)
        return Queue(limits: limits) { runtime.submit($0, $1, $2, $3) }
    }

    /// Completion records: `json` then `ok`, `full` or `cancelled`.
    private func record(_ log: AyuTestBox<[String]>, _ name: String) -> Queue.Completion {
        { _, error in
            log.update { $0.append(name + (error == nil ? " ok" : Queue.isQueueFull(error) ? " full" : Queue.isCancelled(error) ? " cancelled" : " failed")) }
        }
    }

    func testBurstIsHandedOverInOrderWithinTheInFlightBound() {
        let runtime = HeldRuntime(), log = AyuTestBox<[String]>([])
        let queue = self.queue(runtime) { $0.inFlight = 4 }
        let names = (0..<300).map { "d\($0)" }
        for name in names { queue.enqueue(owner: "alpha", entry: .callback, json: name, completion: self.record(log, name)) }
        XCTAssertEqual(runtime.accepted.value, Array(names.prefix(4)), "only the in-flight bound is on the interpreter queue")
        runtime.completeAll()
        XCTAssertEqual(runtime.accepted.value, names)
        XCTAssertEqual(log.value, names.map { $0 + " ok" }, "every delivery completed once, in order")
        XCTAssertEqual(runtime.largestHeld.value, 4)
        XCTAssertEqual(queue.counters, Queue.Counters(completed: 300))
    }

    func testPluginsTakeTurnsAndKeepTheirOwnOrder() {
        let runtime = HeldRuntime(), log = AyuTestBox<[String]>([])
        let queue = self.queue(runtime) { $0.inFlight = 1 }
        for index in 0..<4 { queue.enqueue(owner: "alpha", entry: .callback, json: "a\(index)", completion: self.record(log, "a\(index)")) }
        for index in 0..<2 { queue.enqueue(owner: "beta", entry: .event, json: "b\(index)", completion: self.record(log, "b\(index)")) }
        runtime.completeAll()
        XCTAssertEqual(runtime.accepted.value, ["a0", "a1", "b0", "a2", "b1", "a3"])
    }

    func testLargeDeliveryGoesAloneAndSmallOnesShareTheByteBound() {
        let runtime = HeldRuntime(), log = AyuTestBox<[String]>([])
        let queue = self.queue(runtime) { $0.inFlightBytes = 100 }
        let small = [String(repeating: "s", count: 40), String(repeating: "t", count: 40), String(repeating: "u", count: 40)]
        let large = String(repeating: "L", count: 500)
        for json in small + [large] { queue.enqueue(owner: "alpha", entry: .callback, json: json, completion: self.record(log, String(json.prefix(1)))) }
        XCTAssertEqual(runtime.accepted.value, Array(small.prefix(2)))
        runtime.completeNext()
        XCTAssertEqual(runtime.accepted.value, small)
        runtime.completeNext(); runtime.completeNext()
        XCTAssertEqual(runtime.accepted.value.last, large, "sent once nothing else is in flight")
        runtime.completeAll()
        XCTAssertEqual(log.value, ["s ok", "t ok", "u ok", "L ok"])
    }

    func testRefusedDeliveryKeepsItsPlaceUntilTheRuntimeHasRoom() {
        let runtime = HeldRuntime(), log = AyuTestBox<[String]>([])
        let queue = self.queue(runtime)
        queue.enqueue(owner: "alpha", entry: .callback, json: "a0", completion: self.record(log, "a0"))
        runtime.refusing.value = true
        queue.enqueue(owner: "alpha", entry: .callback, json: "a1", completion: self.record(log, "a1"))
        queue.enqueue(owner: "beta", entry: .callback, json: "b0", completion: self.record(log, "b0"))
        queue.enqueue(owner: "alpha", entry: .callback, json: "a2", completion: self.record(log, "a2"))
        XCTAssertEqual(runtime.offered.value, ["a0", "a1"], "after a refusal nothing more is offered")
        XCTAssertEqual(log.value, [], "a refusal is not an outcome")

        // A completion is one of the two events that offer the refused delivery again.
        runtime.completeNext()
        XCTAssertEqual(runtime.offered.value, ["a0", "a1", "a1"])
        XCTAssertEqual(log.value, ["a0 ok"])

        // The other is the runtime reporting room; without it nothing is retried.
        runtime.refusing.value = false
        XCTAssertEqual(runtime.accepted.value, ["a0"])
        queue.capacityAvailable()
        XCTAssertEqual(runtime.accepted.value, ["a0", "a1", "b0", "a2"], "the refused delivery is still first")
        runtime.completeAll()
        XCTAssertEqual(log.value, ["a0 ok", "a1 ok", "b0 ok", "a2 ok"])
        XCTAssertEqual(queue.counters, Queue.Counters(completed: 4, refusals: 2))
    }

    func testCountOverflowIsAnImmediateFailureAndQuotaBackedDeliveriesAreNotCounted() {
        let runtime = HeldRuntime(), log = AyuTestBox<[String]>([])
        let queue = self.queue(runtime) { $0.inFlight = 1; $0.pendingPerPlugin = 2; $0.guaranteedPerPlugin = 3 }
        queue.enqueue(owner: "alpha", entry: .callback, json: "flying", completion: self.record(log, "flying"))
        for index in 0..<3 { queue.enqueue(owner: "alpha", entry: .callback, json: "o\(index)", completion: self.record(log, "o\(index)")) }
        XCTAssertEqual(log.value, ["o2 full"])
        for index in 0..<4 { queue.enqueue(owner: "alpha", entry: .callback, json: "g\(index)", guaranteed: true, completion: self.record(log, "g\(index)")) }
        XCTAssertEqual(log.value, ["o2 full", "g3 full"])
        // Another plugin has its own bounds.
        queue.enqueue(owner: "beta", entry: .callback, json: "other", completion: self.record(log, "other"))
        runtime.completeAll()
        XCTAssertEqual(log.value, ["o2 full", "g3 full", "flying ok", "o0 ok", "other ok", "o1 ok", "g0 ok", "g1 ok", "g2 ok"])
        XCTAssertEqual(queue.counters, Queue.Counters(completed: 7, overflowed: 2))
    }

    func testByteOverflowQueuesTheSubstituteOrFails() {
        let runtime = HeldRuntime(), log = AyuTestBox<[String]>([])
        let queue = self.queue(runtime) { $0.inFlight = 1; $0.pendingBytesPerPlugin = 1000; $0.pendingBytes = 1500; $0.itemBytes = 900; $0.exemptBytes = 16 }
        let big = String(repeating: "B", count: 800)
        queue.enqueue(owner: "alpha", entry: .callback, json: "flying", completion: self.record(log, "flying"))
        queue.enqueue(owner: "alpha", entry: .callback, json: big, guaranteed: true, substitute: { "unused" }, completion: self.record(log, "first"))
        queue.enqueue(owner: "alpha", entry: .callback, json: big, guaranteed: true, substitute: { "substitute" }, completion: self.record(log, "second"))
        queue.enqueue(owner: "alpha", entry: .callback, json: big, guaranteed: true, completion: self.record(log, "third"))
        queue.enqueue(owner: "alpha", entry: .callback, json: big, guaranteed: true, substitute: { String(repeating: "x", count: 17) }, completion: self.record(log, "fourth"))
        // A small quota-backed delivery is bounded by its count, not by bytes.
        queue.enqueue(owner: "alpha", entry: .callback, json: "timer", guaranteed: true, completion: self.record(log, "timer"))
        // Larger than anything the SDK reads: only its substitute can go.
        queue.enqueue(owner: "gamma", entry: .callback, json: String(repeating: "H", count: 901), guaranteed: true, substitute: { "huge" }, completion: self.record(log, "huge"))
        // The bound over all plugins.
        queue.enqueue(owner: "beta", entry: .callback, json: big, completion: self.record(log, "beta"))
        XCTAssertEqual(log.value, ["third full", "fourth full", "beta full"])
        runtime.completeAll()
        XCTAssertEqual(runtime.accepted.value, ["flying", big, "huge", "substitute", "timer"])
        XCTAssertEqual(queue.counters, Queue.Counters(completed: 5, substituted: 2, overflowed: 3))
    }

    func testCancelDropsPendingDeliveriesOfThatPluginOnly() {
        let runtime = HeldRuntime(), log = AyuTestBox<[String]>([])
        let queue = self.queue(runtime) { $0.inFlight = 1 }
        for index in 0..<3 { queue.enqueue(owner: "alpha", entry: .callback, json: "a\(index)", completion: self.record(log, "a\(index)")) }
        queue.enqueue(owner: "beta", entry: .callback, json: "b0", completion: self.record(log, "b0"))
        queue.cancel(owner: "alpha")
        XCTAssertEqual(log.value, ["a1 cancelled", "a2 cancelled"])
        // The next generation of the plugin starts with an empty queue.
        queue.enqueue(owner: "alpha", entry: .callback, json: "new", completion: self.record(log, "new"))
        runtime.completeAll()
        XCTAssertEqual(runtime.accepted.value, ["a0", "b0", "new"])
        XCTAssertEqual(log.value, ["a1 cancelled", "a2 cancelled", "a0 ok", "b0 ok", "new ok"])
    }

    func testRefusedDeliveryOfACancelledPluginIsNotOfferedAgain() {
        let runtime = HeldRuntime(), log = AyuTestBox<[String]>([])
        let queue = self.queue(runtime)
        runtime.refusing.value = true
        queue.enqueue(owner: "alpha", entry: .callback, json: "a0", completion: self.record(log, "a0"))
        queue.cancel(owner: "alpha")
        XCTAssertEqual(log.value, ["a0 cancelled"])
        runtime.refusing.value = false
        queue.capacityAvailable()
        XCTAssertEqual(runtime.accepted.value, [])
    }

    func testRevokedDeliveryIsDiscardedUnsent() {
        let runtime = HeldRuntime(), log = AyuTestBox<[String]>([])
        let queue = self.queue(runtime) { $0.inFlight = 1 }
        let live = AyuTestBox(true)
        queue.enqueue(owner: "alpha", entry: .callback, json: "a0", completion: self.record(log, "a0"))
        queue.enqueue(owner: "alpha", entry: .callback, json: "timer", guaranteed: true, isCurrent: { live.value }, completion: self.record(log, "timer"))
        queue.enqueue(owner: "alpha", entry: .callback, json: "a1", completion: self.record(log, "a1"))
        live.value = false
        runtime.completeAll()
        XCTAssertEqual(runtime.accepted.value, ["a0", "a1"])
        XCTAssertEqual(log.value, ["a0 ok", "timer cancelled", "a1 ok"])
    }

    func testConcurrentProducersLoseNothing() {
        let runtime = HeldRuntime(), log = AyuTestBox<[String]>([])
        let queue = self.queue(runtime) { $0.inFlight = 3; $0.pendingPerPlugin = 4000 }
        let finished = XCTestExpectation(description: "producers")
        finished.expectedFulfillmentCount = 4
        for producer in 0..<4 {
            DispatchQueue.global().async {
                for index in 0..<500 {
                    queue.enqueue(owner: "p\(producer)", entry: .callback, json: "\(producer):\(index)", completion: self.record(log, "\(producer):\(index)"))
                    if index % 7 == 0 { runtime.completeNext() }
                }
                finished.fulfill()
            }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 20), .completed)
        runtime.completeAll()
        XCTAssertEqual(log.value.count, 2000)
        XCTAssertEqual(Set(log.value).count, 2000, "each delivery completed once")
        for producer in 0..<4 {
            let order = runtime.accepted.value.filter { $0.hasPrefix("\(producer):") }
            XCTAssertEqual(order, (0..<500).map { "\(producer):\($0)" }, "order per plugin")
        }
        XCTAssertLessThanOrEqual(runtime.largestHeld.value, 3)
    }

    // MARK: Host side

    private func host(_ limits: AyuPluginBridgeLimits, deliveries: AyuTestBox<[AyuPluginNativeHost.Delivery]>) -> AyuPluginNativeHost {
        let defaults = UserDefaults(suiteName: "AyuPluginBridgeTests." + UUID().uuidString)!
        return AyuPluginNativeHost(defaults: defaults, provider: SendingProvider(), limits: limits, trustedOwner: { "alpha" }, callback: { _, _, _ in },
                                   delivery: { delivery in deliveries.update { $0.append(delivery) } })
    }

    private func call(_ host: AyuPluginNativeHost, _ operation: String, _ arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        let request: AyuBridgeValue = .object(["version": .integer(1), "id": .string("17"), "plugin_id": .string("alpha"), "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let response = await Task.detached { host.dispatch(text, owner: "alpha") }.value
        return try JSONDecoder().decode(AyuBridgeValue.self, from: Data(response.utf8))
    }

    private func activate(_ host: AyuPluginNativeHost) async throws {
        let authorized = try await self.call(host, "plugin.authorize", ["metadata": .object(["id": .string("alpha")]), "classes": .array([]), "requirements": .array([]), "imports": .array([])])
        XCTAssertEqual(authorized["result"], .bool(true))
        _ = try await self.call(host, "plugin.activate", ["generation": .string("generation")])
    }

    private func schedule(_ host: AyuPluginNativeHost, _ callback: String) async throws -> AyuBridgeValue {
        try await self.call(host, "scheduler.schedule", ["queue": .string("pluginsQueue"), "delay_ms": .integer(0), "callback": .object(["$callback": .string(callback)])])
    }

    private func wait(_ deliveries: AyuTestBox<[AyuPluginNativeHost.Delivery]>, count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while deliveries.value.count < count, Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    func testTimerKeepsItsSlotWhileQueuedAndReturnsItAtTheHandOver() async throws {
        var limits = AyuPluginBridgeLimits(); limits.callbacksPerPlugin = 2
        let deliveries = AyuTestBox<[AyuPluginNativeHost.Delivery]>([])
        let host = self.host(limits, deliveries: deliveries)
        try await self.activate(host)
        let first = try await self.schedule(host, "one"), second = try await self.schedule(host, "two")
        let token = try XCTUnwrap(first["result"].string); XCTAssertNotNil(second["result"].string)
        await self.wait(deliveries, count: 2)
        XCTAssertEqual(deliveries.value.map(\.callbackID).sorted(), ["one", "two"])
        XCTAssertTrue(deliveries.value.allSatisfy { $0.guaranteed && !$0.dropped && $0.isCurrent() })
        let one = try XCTUnwrap(deliveries.value.first { $0.callbackID == "one" })

        // Both fired, neither was handed to the interpreter: the plugin is told at the call, nothing is dropped later.
        let refused = try await self.schedule(host, "three")
        XCTAssertEqual(refused["error"]["code"], .string("RESOURCE_LIMIT"))
        // Handed over: the callback about to run can schedule itself again. A refused
        // hand-over repeats `started`.
        one.started(); one.started()
        let accepted = try await self.schedule(host, "three")
        XCTAssertNotNil(accepted["result"].string)
        let full = try await self.schedule(host, "four")
        XCTAssertEqual(full["error"]["code"], .string("RESOURCE_LIMIT"), "one slot was returned, not two")

        // Until it has run it is still current and can be cancelled without an error.
        XCTAssertTrue(one.isCurrent())
        let cancelled = try await self.call(host, "scheduler.cancel", ["token": .string(token)])
        XCTAssertEqual(cancelled["result"], .null)
        XCTAssertFalse(one.isCurrent())
        one.completion()
        let unknown = try await self.call(host, "scheduler.cancel", ["token": .string(token)])
        XCTAssertEqual(unknown["error"]["code"], .string("INVALID_HANDLE"), "nothing of the timer is left after its completion")
    }

    func testStartedRunsAtEachHandOverAndNeverForADiscardedDelivery() {
        let runtime = HeldRuntime(), log = AyuTestBox<[String]>([]), current = AyuTestBox(true)
        let queue = self.queue(runtime) { $0.inFlight = 1 }
        func add(_ name: String, isCurrent: @escaping @Sendable () -> Bool = { true }) {
            queue.enqueue(owner: "alpha", entry: .callback, json: name, guaranteed: true, isCurrent: isCurrent,
                          started: { log.update { $0.append(name + " started") } }, completion: self.record(log, name))
        }
        add("a"); add("b", isCurrent: { current.value }); add("c")
        XCTAssertEqual(log.value, ["a started"], "a pending delivery has not started")
        current.value = false
        runtime.completeNext()
        XCTAssertEqual(log.value, ["a started", "a ok", "b cancelled", "c started"])
        runtime.refusing.value = true
        runtime.completeNext()
        add("d")
        XCTAssertEqual(Array(log.value.suffix(2)), ["c ok", "d started"])
        runtime.refusing.value = false
        queue.capacityAvailable()
        runtime.completeAll()
        XCTAssertEqual(Array(log.value.suffix(3)), ["d started", "d started", "d ok"], "offered again after the refusal, completed once")
    }

    func testExpiredIsItsOwnOutcome() {
        let expired = NSError(domain: Queue.errorDomain, code: Queue.expiredCode)
        XCTAssertTrue(Queue.isExpired(expired))
        XCTAssertFalse(Queue.isCancelled(expired) || Queue.isQueueFull(expired))
        XCTAssertFalse(Queue.isExpired(NSError(domain: Queue.errorDomain, code: 2)), "a handler failure is not an expiry")
        XCTAssertFalse(Queue.isExpired(nil))
    }

    func testTimerCancelledWhileQueuedInTheEmbeddingIsNoLongerCurrent() async throws {
        let deliveries = AyuTestBox<[AyuPluginNativeHost.Delivery]>([])
        let host = self.host(AyuPluginBridgeLimits(), deliveries: deliveries)
        try await self.activate(host)
        let scheduled = try await self.schedule(host, "one")
        let token = try XCTUnwrap(scheduled["result"].string)
        let other = try await self.schedule(host, "two")
        XCTAssertNotNil(other["result"].string)
        await self.wait(deliveries, count: 2)
        let cancelled = try await self.call(host, "scheduler.cancel", ["token": .string(token)])
        XCTAssertEqual(cancelled["result"], .null, "a fired timer that has not run can still be cancelled")
        let one = try XCTUnwrap(deliveries.value.first { $0.callbackID == "one" }), two = try XCTUnwrap(deliveries.value.first { $0.callbackID == "two" })
        XCTAssertFalse(one.isCurrent())
        XCTAssertTrue(two.isCurrent())
        _ = try await self.call(host, "plugin.deactivate", ["generation": .string("generation")])
        XCTAssertFalse(two.isCurrent(), "unload revokes what is still queued")
    }

    func testCallbacksPastTheHandoffBoundAreReportedAndQuotaBackedOnesAreNotBounded() async throws {
        var limits = AyuPluginBridgeLimits(); limits.callbacksPerPlugin = 4
        let deliveries = AyuTestBox<[AyuPluginNativeHost.Delivery]>([])
        let host = self.host(limits, deliveries: deliveries)
        try await self.activate(host)
        // All ten are sent inside one dispatch, so none can leave the host before the last.
        _ = try await self.call(host, "client.call", ["callback": .object(["$callback": .string("listener")]), "count": .integer(10)])
        await self.wait(deliveries, count: 10)
        XCTAssertEqual(deliveries.value.filter(\.dropped).count, 6, "reported, not silently lost")
        XCTAssertEqual(deliveries.value.filter { !$0.dropped }.map { $0.arguments.first }, (0..<4).map { AyuBridgeValue.integer($0) })
        XCTAssertTrue(deliveries.value.allSatisfy { !$0.guaranteed })

        deliveries.value = []
        _ = try await self.call(host, "client.call", ["callback": .object(["$callback": .string("listener")]), "count": .integer(10), "guaranteed": .bool(true)])
        await self.wait(deliveries, count: 10)
        XCTAssertEqual(deliveries.value.map { $0.arguments.first }, (0..<10).map { AyuBridgeValue.integer($0) })
        XCTAssertTrue(deliveries.value.allSatisfy { $0.guaranteed && !$0.dropped && $0.substitute == [.string("substitute")] })
    }

    func testOversizedCallbackIsReplacedByItsSubstituteOrDropped() async throws {
        var limits = AyuPluginBridgeLimits(); limits.responseBytes = 2048; limits.guaranteedCallbackBytes = 4096
        let deliveries = AyuTestBox<[AyuPluginNativeHost.Delivery]>([])
        let host = self.host(limits, deliveries: deliveries)
        try await self.activate(host)
        let reference: AyuBridgeValue = .object(["$callback": .string("listener")])
        _ = try await self.call(host, "client.call", ["callback": reference, "count": .integer(1), "padding": .integer(3000), "guaranteed": .bool(true)])
        _ = try await self.call(host, "client.call", ["callback": reference, "count": .integer(1), "padding": .integer(5000), "guaranteed": .bool(true)])
        _ = try await self.call(host, "client.call", ["callback": reference, "count": .integer(1), "padding": .integer(3000)])
        _ = try await self.call(host, "client.call", ["callback": reference, "count": .integer(1), "padding": .integer(8)])
        await self.wait(deliveries, count: 4)
        XCTAssertEqual(deliveries.value.map(\.dropped), [false, false, true, false], "the oversized plain callback is reported, not delivered")
        XCTAssertEqual(deliveries.value.filter { !$0.dropped }.map { $0.arguments.last?.string?.count }, [3000, 10, 8])
        XCTAssertEqual(deliveries.value[1].arguments, [.string("substitute")])
    }

    func testOnlyTelegramOperationsGetTheTLEnvelope() async throws {
        let deliveries = AyuTestBox<[AyuPluginNativeHost.Delivery]>([])
        let host = self.host(AyuPluginBridgeLimits(), deliveries: deliveries)
        try await self.activate(host)
        func code(_ operation: String, request: Int = 0, reply: Int = 0) async throws -> AyuBridgeValue {
            try await self.call(host, operation, ["filler": .string(String(repeating: "f", count: request)), "reply": .integer(Int64(reply))])["error"]["code"]
        }
        // Requests: 262,144 bytes for ordinary operations, 1,572,864 for `telegram.*`.
        let ordinaryRequest = try await code("client.call", request: 300_000), telegramRequest = try await code("telegram.request", request: 1_500_000)
        let hugeRequest = try await code("telegram.request", request: 1_572_864)
        XCTAssertEqual(ordinaryRequest, .string("RESOURCE_LIMIT"))
        XCTAssertEqual(telegramRequest, .null)
        XCTAssertEqual(hugeRequest, .string("RESOURCE_LIMIT"))
        // Results: 262,144 bytes for ordinary operations, 1,048,576 for `telegram.*`.
        let ordinaryResult = try await code("client.call", reply: 300_000), telegramResult = try await code("telegram.request", reply: 1_000_000)
        let hugeResult = try await code("telegram.request", reply: 1_048_576)
        XCTAssertEqual(ordinaryResult, .string("RESOURCE_LIMIT"))
        XCTAssertEqual(telegramResult, .null)
        XCTAssertEqual(hugeResult, .string("RESOURCE_LIMIT"))
        // The larger result bound does not outlive the dispatch that set it.
        let after = try await code("client.call", reply: 300_000)
        XCTAssertEqual(after, .string("RESOURCE_LIMIT"))
    }

    // MARK: Telegram bounds

    /// A boxed TL object of `bytes` bytes whose base64 is the worst case for an escaping encoder.
    private func boxed(_ bytes: Int) -> Data { Data(repeating: 0xff, count: bytes) }

    func testResponseOfFourMebibytesFitsItsCallbackWhateverItsBytes() throws {
        let bridge = AyuPluginTelegramBridge()
        let largest = bridge.callbackArguments(.response(self.boxed(4_194_304)))
        XCTAssertEqual(largest[1], .null)
        XCTAssertEqual(largest[0]["tl"].string?.utf8.count, 5_592_408)
        // What the relay sends stays inside the 6,000,000 characters the SDK reads.
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        XCTAssertLessThanOrEqual(try encoder.encode(largest).count, AyuPluginBridgeLimits().guaranteedCallbackBytes)
        XCTAssertLessThan(AyuPluginBridgeLimits().guaranteedCallbackBytes + 256, AyuPluginDeliveryQueue.Limits().itemBytes)

        let tooLarge = bridge.callbackArguments(.response(self.boxed(4_194_308)))
        XCTAssertEqual(tooLarge[0], .null)
        XCTAssertEqual(tooLarge[1], AyuPluginTelegramTL.encode(AyuPluginTelegramTL.error(code: 500, text: "RESPONSE_TOO_LARGE")))
    }

    func testInboundValueOfOneMebibyteIsAcceptedAndFitsARequest() throws {
        let bridge = AyuPluginTelegramBridge()
        let largest = AyuPluginTelegramTL.encode(self.boxed(1_048_576))
        XCTAssertEqual(try bridge.inbound(largest, "request").count, 1_048_576)
        XCTAssertEqual(largest["tl"].string?.utf8.count, 1_398_104)
        XCTAssertLessThanOrEqual(1_398_104 + 65_536, AyuPluginBridgeLimits().telegramRequestBytes, "the value and a 64 KiB envelope fit one request")
        XCTAssertThrowsError(try bridge.inbound(AyuPluginTelegramTL.encode(self.boxed(1_048_580)), "request")) {
            XCTAssertEqual(($0 as? AyuBridgeFailure)?.code, "INVALID_ARGUMENTS")
        }
    }
}
