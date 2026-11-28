import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Synthetic regressions for the typed hook registry and capability predicates.
/// No interpreter, no account, no network. Source-only until executed with the
/// iOS test runner; a build is not a test run.
final class AyuBridgeHooksTests: XCTestCase {
    private func capabilities(_ names: [AyuBridgeCapability], chats: [Int64]? = nil) -> AyuBridgeCapabilitySet {
        var scoped = names
        if let chats { scoped.append(AyuBridgeCapability("messages.read", scope: ["chats": .array(chats.map { .integer($0) })])) }
        return AyuBridgeCapabilitySet(scoped)
    }

    func testSubscribeRequiresSendCapability() {
        let registry = AyuBridgeHookRegistry()
        XCTAssertThrowsError(try registry.subscribe(pluginID: "p", point: .messageSendPre, capabilities: self.capabilities([])) { _ in .proceed }) { error in
            XCTAssertEqual(error as? AyuBridgeHookError, .missingCapability(name: "messages.send", reason: "not requested by the plugin"))
        }
        XCTAssertEqual(registry.subscriptionCount(), 0)
    }

    func testMutatingPointsRequireMutateCapability() {
        let registry = AyuBridgeHookRegistry()
        let read = self.capabilities([AyuBridgeCapability("messages.read")])
        for point in [.messageEditPre, .messageDeletePre] as [AyuBridgeHookPoint] {
            XCTAssertThrowsError(try registry.subscribe(pluginID: "p", point: point, capabilities: read) { _ in .proceed })
        }
        let mutate = self.capabilities([AyuBridgeCapability("messages.mutate")])
        _ = try? registry.subscribe(pluginID: "p", point: .messageEditPre, capabilities: mutate) { _ in .proceed }
        XCTAssertEqual(registry.subscriptionCount(), 1)
    }

    func testScreenshotPrivacyClassIsForbiddenByRequest() throws {
        XCTAssertThrowsError(try AyuBridgeCapabilitySet.validateRequest(["screenshot.privacy"])) { error in
            XCTAssertEqual(error as? AyuBridgeCapabilityError, .forbidden(name: "screenshot.privacy", reason: "OS privacy defeating capabilities are not adapter targets"))
        }
        XCTAssertThrowsError(try AyuBridgeCapabilitySet.validateRequest(["screen_capture"]))
        XCTAssertNoThrow(try AyuBridgeCapabilitySet.validateRequest(["messages.read"]))
    }

    func testChatScopePredicateCoversAndDenies() throws {
        let capabilities = self.capabilities([AyuBridgeCapability("messages.read", scope: ["chats": .array([.integer(7), .integer(9)])])])
        try capabilities.check(.messagesRead, chatID: 7)
        XCTAssertThrowsError(try capabilities.check(.messagesRead, chatID: 8)) { error in
            XCTAssertEqual(error as? AyuBridgeCapabilityError, .missing(name: "messages.read", reason: "chat 8 is outside the granted scope"))
        }
        let unscoped = self.capabilities([AyuBridgeCapability("messages.read")])
        try unscoped.check(.messagesRead, chatID: 123)
        try unscoped.check(.messagesRead)
    }

    func testUnknownCapabilityNameIsTyped() {
        let capabilities = AyuBridgeCapabilitySet([AyuBridgeCapability("storage.screenshot")])
        XCTAssertThrowsError(try capabilities.check(.messagesRead)) { error in
            XCTAssertEqual(error as? AyuBridgeCapabilityError, .missing(name: "messages.read", reason: "not requested by the plugin"))
        }
    }

    func testPublishRunsInPriorityOrderAndReplacementChains() throws {
        let registry = AyuBridgeHookRegistry()
        let log = AyuTestBox("")
        _ = try registry.subscribe(pluginID: "late", point: .messageSendPre, priority: 10, capabilities: self.capabilities([AyuBridgeCapability("messages.send")])) { payload in
            log.update { $0.append("x") }
            var updated = payload
            updated["text"] = .string("late saw \(payload["text"]?.string ?? "")")
            return .replace(updated)
        }
        _ = try registry.subscribe(pluginID: "early", point: .messageSendPre, priority: 0, capabilities: self.capabilities([AyuBridgeCapability("messages.send")])) { payload in
            var updated = payload
            updated["text"] = .string("first")
            return .replace(updated)
        }
        let result = try registry.publish(.messageSendPre, payload: ["text": .string("original")])
        XCTAssertEqual(log.value, "x")
        XCTAssertEqual(result.payload["text"], .string("late saw first"))
        XCTAssertNil(result.cancelled)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testCancelStopsChainOnlyForMutatingPoints() throws {
        let registry = AyuBridgeHookRegistry()
        _ = try registry.subscribe(pluginID: "canceller", point: .messageSendPre, capabilities: self.capabilities([AyuBridgeCapability("messages.send")])) { _ in .cancel("blocked") }
        let reached = AyuTestBox(false)
        _ = try registry.subscribe(pluginID: "after", point: .messageSendPre, capabilities: self.capabilities([AyuBridgeCapability("messages.send")])) { _ in reached.value = true; return .proceed }
        let mutating = try registry.publish(.messageSendPre, payload: [:])
        XCTAssertEqual(mutating.cancelled, "blocked")
        XCTAssertFalse(reached.value)

        _ = try registry.subscribe(pluginID: "observer", point: .messageReceived, capabilities: self.capabilities([AyuBridgeCapability("messages.read")])) { _ in .cancel("blocked") }
        let observe = try registry.publish(.messageReceived, payload: [:])
        XCTAssertNil(observe.cancelled)
        XCTAssertEqual(observe.failures["observer"], "observe hooks cannot cancel")
    }

    func testObserveHooksCannotReplace() throws {
        let registry = AyuBridgeHookRegistry()
        _ = try registry.subscribe(pluginID: "observer", point: .messageReceived, capabilities: self.capabilities([AyuBridgeCapability("messages.read")])) { _ in .replace(["text": .string("rewritten")]) }
        let result = try registry.publish(.messageReceived, payload: ["text": .string("original")])
        XCTAssertEqual(result.payload["text"], .string("original"))
        XCTAssertEqual(result.failures["observer"], "observe hooks cannot mutate")
    }

    func testSinkFailureIsIsolatedPerPlugin() throws {
        let registry = AyuBridgeHookRegistry()
        _ = try registry.subscribe(pluginID: "broken", point: .messageReceived, capabilities: self.capabilities([AyuBridgeCapability("messages.read")])) { _ in throw AyuBridgeFailure.unsupported("boom") }
        let ran = AyuTestBox(false)
        _ = try registry.subscribe(pluginID: "healthy", point: .messageReceived, capabilities: self.capabilities([AyuBridgeCapability("messages.read")])) { _ in ran.value = true; return .proceed }
        let result = try registry.publish(.messageReceived, payload: [:])
        XCTAssertTrue(ran.value)
        XCTAssertEqual(result.failures["broken"], "Unsupported API: boom")
        XCTAssertTrue(result.failures.keys.contains("broken"))
        XCTAssertNil(result.failures["healthy"])
    }

    func testRevokeByPluginAndByID() throws {
        let registry = AyuBridgeHookRegistry()
        let first = try registry.subscribe(pluginID: "p", point: .messageReceived, capabilities: self.capabilities([AyuBridgeCapability("messages.read")])) { _ in .proceed }
        _ = try registry.subscribe(pluginID: "q", point: .messageReceived, capabilities: self.capabilities([AyuBridgeCapability("messages.read")])) { _ in .proceed }
        registry.revoke(subscription: first)
        XCTAssertEqual(registry.subscriptionCount(), 1)
        XCTAssertEqual(registry.subscriptionCount(pluginID: "q"), 1)
        registry.revoke(pluginID: "q")
        XCTAssertEqual(registry.subscriptionCount(), 0)
    }

    func testOversizedPayloadThrowsBeforeSinksRun() throws {
        let registry = AyuBridgeHookRegistry(maxPayloadBytes: 64)
        let ran = AyuTestBox(false)
        _ = try registry.subscribe(pluginID: "p", point: .messageReceived, capabilities: self.capabilities([AyuBridgeCapability("messages.read")])) { _ in ran.value = true; return .proceed }
        XCTAssertThrowsError(try registry.publish(.messageReceived, payload: ["text": .string(String(repeating: "a", count: 1024))])) { error in
            guard case let AyuBridgeHookError.payloadTooLarge(size) = error as! AyuBridgeHookError else { return XCTFail("wrong error") }
            XCTAssertGreaterThan(size, 64)
        }
        XCTAssertFalse(ran.value)
    }
}
