import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Synthetic native tests only. No interpreter, account, attachment or network service.
/// Async transport keeps main free while the host marshals UIKit work to main.
@MainActor
final class AyuPluginNativeHostTests: XCTestCase {
    private func host(limits: AyuPluginBridgeLimits = AyuPluginBridgeLimits(), callback: @escaping AyuPluginNativeHost.CallbackSink = { _, _, _ in }) -> AyuPluginNativeHost {
        let defaults = UserDefaults(suiteName: "AyuPluginBridgeTests." + UUID().uuidString)!
        return AyuPluginNativeHost(defaults: defaults, limits: limits, trustedOwner: { "alpha" }, callback: callback)
    }

    private func call(_ host: AyuPluginNativeHost, _ operation: String, owner: String = "alpha", claimedOwner: String? = nil, arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        let request: AyuBridgeValue = .object(["version": .integer(1), "id": .string("17"), "plugin_id": .string(claimedOwner ?? owner), "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        let response: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: host.dispatch(text, owner: owner))
            }
        }
        return try JSONDecoder().decode(AyuBridgeValue.self, from: Data(response.utf8))
    }

    private func authorize(_ host: AyuPluginNativeHost, owner: String = "alpha") async throws {
        let result = try await self.call(host, "plugin.authorize", owner: owner, arguments: ["metadata": .object(["id": .string(owner)]), "classes": .array([]), "requirements": .array([]), "imports": .array([])])
        XCTAssertEqual(result["result"], .bool(true))
    }

    func testInt64WireRoundTripIsExact() throws {
        let original = AyuBridgeValue.integer(Int64.max - 7)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(AyuBridgeValue.self, from: encoded), original)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "9223372036854775800")
    }

    func testBootstrapAndOwnerMismatch() async throws {
        let host = self.host()
        let bootstrap = try await self.call(host, "runtime.capabilities", claimedOwner: "$runtime")
        XCTAssertNotNil(bootstrap["result"]["classes"].array)
        let mismatch = try await self.call(host, "settings.get", claimedOwner: "bravo", arguments: ["key": .string("enabled")])
        XCTAssertEqual(mismatch["error"]["code"], .string("OWNER_MISMATCH"))
        XCTAssertEqual(mismatch["id"], .string("17"))
        XCTAssertNil(mismatch.object?["result"])
    }

    func testSettingsIsolationAndPersistenceAcrossDetach() async throws {
        let host = self.host()
        try await self.authorize(host)
        try await self.authorize(host, owner: "bravo")
        let saved = AyuBridgeValue.integer(Int64.min + 12)
        let write = try await self.call(host, "settings.set", arguments: ["key": .string("account"), "value": saved])
        XCTAssertEqual(write["result"], .null)
        let other = try await self.call(host, "settings.get", owner: "bravo", arguments: ["key": .string("account"), "default": .string("unset")])
        XCTAssertEqual(other["result"], .string("unset"))
        _ = try await self.call(host, "plugin.deactivate")
        try await self.authorize(host)
        let read = try await self.call(host, "settings.get", arguments: ["key": .string("account")])
        XCTAssertEqual(read["result"], saved)
    }

    func testUnknownMethodAndForeignHandleFail() async throws {
        let host = self.host()
        try await self.authorize(host)
        try await self.authorize(host, owner: "bravo")
        let created = try await self.call(host, "java.construct", arguments: ["class_name": .string("android.widget.TextView"), "args": .array([]), "kwargs": .object([:])])
        let target = created["result"]
        let unknown = try await self.call(host, "java.invoke", arguments: ["target": target, "name": .string("nonexistentMethod"), "args": .array([])])
        XCTAssertEqual(unknown["error"]["code"], .string("UNSUPPORTED_API"))
        let foreign = try await self.call(host, "java.invoke", owner: "bravo", arguments: ["target": target, "name": .string("getAlpha"), "args": .array([])])
        XCTAssertEqual(foreign["error"]["code"], .string("INVALID_HANDLE"))
        _ = try await self.call(host, "plugin.deactivate")
        try await self.authorize(host)
        let stale = try await self.call(host, "java.invoke", arguments: ["target": target, "name": .string("getAlpha"), "args": .array([])])
        XCTAssertEqual(stale["error"]["code"], .string("INVALID_HANDLE"))
    }

    func testObjectAndSettingsQuotas() async throws {
        var limits = AyuPluginBridgeLimits()
        limits.objectsPerPlugin = 1
        limits.settingsBytesPerPlugin = 64
        let host = self.host(limits: limits)
        try await self.authorize(host)
        let args: [String: AyuBridgeValue] = ["class_name": .string("android.widget.FrameLayout$LayoutParams"), "args": .array([.integer(10), .integer(20)])]
        let first = try await self.call(host, "java.construct", arguments: args)
        XCTAssertNotNil(first["result"]["$handle"].string)
        let second = try await self.call(host, "java.construct", arguments: args)
        XCTAssertEqual(second["error"]["code"], .string("RESOURCE_LIMIT"))
        let huge = try await self.call(host, "settings.set", arguments: ["key": .string("large"), "value": .string(String(repeating: "x", count: 256))])
        XCTAssertEqual(huge["error"]["code"], .string("RESOURCE_LIMIT"))
    }

    func testUnloadRevokesScheduledCallback() async throws {
        let callback = XCTestExpectation(description: "unloaded callback must not enter")
        callback.isInverted = true
        let host = self.host(callback: { _, _, _ in callback.fulfill() })
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", arguments: ["generation": .string("synthetic-generation")])
        let scheduled = try await self.call(host, "scheduler.schedule", arguments: ["queue": .string("main"), "delay_ms": .integer(100), "callback": .object(["$callback": .string("callback-old")])])
        XCTAssertNotNil(scheduled["result"].string)
        _ = try await self.call(host, "plugin.deactivate", arguments: ["generation": .string("synthetic-generation")])
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", arguments: ["generation": .string("new-generation")])
        let result = await XCTWaiter.fulfillment(of: [callback], timeout: 0.25)
        XCTAssertEqual(result, .completed)
    }

    func testNativeArrayPreservesInt64AndBounds() async throws {
        let host = self.host()
        try await self.authorize(host)
        let created = try await self.call(host, "java.array", arguments: ["component": .string("long"), "values": .array([.integer(Int64.max)])])
        let value = try await self.call(host, "java.get_item", arguments: ["target": created["result"], "index": .integer(0)])
        XCTAssertEqual(value["result"], .integer(Int64.max))
        let outOfRange = try await self.call(host, "java.get_item", arguments: ["target": created["result"], "index": .integer(1)])
        XCTAssertEqual(outOfRange["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testDuplicateKeysAndDepthAreRejected() throws {
        XCTAssertThrowsError(try AyuBridgeJSONValidation.validate(Data("{\"a\":1,\"\\u0061\":2}".utf8)))
        let deep = String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)
        XCTAssertThrowsError(try AyuBridgeJSONValidation.validate(Data(deep.utf8)))
    }

    func testCallbackGateCancellationAndGeneration() {
        let gate = AyuBridgeCallbackGate()
        let old = UUID(); let new = UUID()
        gate.activate(owner: "alpha", generation: old)
        gate.register(token: "job", owner: "alpha")
        XCTAssertTrue(gate.reserve(owner: "alpha", generation: old, limit: 1))
        XCTAssertFalse(gate.reserve(owner: "alpha", generation: old, limit: 1))
        gate.cancel(token: "job", owner: "bravo")
        XCTAssertTrue(gate.enter(owner: "alpha", generation: old, token: "job"))
        gate.finish(owner: "alpha")
        gate.register(token: "cancelled", owner: "alpha")
        gate.cancel(token: "cancelled", owner: "alpha")
        XCTAssertFalse(gate.enter(owner: "alpha", generation: old, token: "cancelled"))
        gate.revoke(owner: "alpha"); gate.activate(owner: "alpha", generation: new)
        XCTAssertFalse(gate.enter(owner: "alpha", generation: old, token: nil))
    }
}
