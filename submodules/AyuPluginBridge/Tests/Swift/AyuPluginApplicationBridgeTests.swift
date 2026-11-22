import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Synthetic native regressions, no account login, interpreter or network.
/// Source-only until executed with the iOS test runner; a build is not a test run.
@MainActor final class AyuPluginApplicationBridgeTests: XCTestCase {
    private func host(_ provider: AyuPluginHostProvider, registry: AyuBridgeClassRegistry = .standard, limits: AyuPluginBridgeLimits = AyuPluginBridgeLimits(), callback: @escaping AyuPluginNativeHost.CallbackSink = { _, _, _ in }) -> AyuPluginNativeHost {
        AyuPluginNativeHost(defaults: UserDefaults(suiteName: "AyuApplicationBridgeTests." + UUID().uuidString)!, provider: provider, classRegistry: registry, limits: limits, trustedOwner: { "alpha" }, callback: callback)
    }
    private func call(_ host: AyuPluginNativeHost, _ operation: String, owner: String = "alpha", _ arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        let body: AyuBridgeValue = .object(["version": .integer(1), "id": .string("23"), "plugin_id": .string(owner), "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        let result = await Task.detached { host.dispatch(text, owner: owner) }.value
        return try JSONDecoder().decode(AyuBridgeValue.self, from: Data(result.utf8))
    }
    private func authorize(_ host: AyuPluginNativeHost, owner: String = "alpha") async throws {
        let response = try await self.call(host, "plugin.authorize", owner: owner)
        XCTAssertEqual(response["result"], .bool(true))
    }
    private func client(_ host: AyuPluginNativeHost, _ name: String, kwargs: [String: AyuBridgeValue] = [:], owner: String = "alpha") async throws -> AyuBridgeValue {
        try await self.call(host, "client.call", owner: owner, ["name": .string(name), "args": .array([]), "kwargs": .object(kwargs)])
    }
    private func invoke(_ host: AyuPluginNativeHost, _ target: AyuBridgeValue, _ method: String, owner: String = "alpha") async throws -> AyuBridgeValue {
        try await self.call(host, "java.invoke", owner: owner, ["target": target, "name": .string(method), "args": .array([])])
    }

    func testUnboundApplicationFailsClosedAndDoesNotInventClients() async throws {
        let provider = AyuPluginApplicationBridge()
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let missing = try await self.client(host, "get_selected_account")
        XCTAssertEqual(missing["error"]["code"], .string("ACCOUNT_UNAVAILABLE"))
        let noScreen = try await self.client(host, "get_last_fragment")
        XCTAssertEqual(noScreen["result"], .null)
        let unsupported = try await self.client(host, "get_messages_controller")
        XCTAssertEqual(unsupported["error"]["code"], .string("UNSUPPORTED_API"))
        let noPresentation = try await self.call(host, "ui.present", ["kind": .string("alert"), "config": .object(["title": .string("Synthetic")])])
        XCTAssertEqual(noPresentation["error"]["code"], .string("SCREEN_UNAVAILABLE"))
    }

    func testSelectedAccountStaticFieldIsLiveAndOwnedConfigHasExactInt64UserID() async throws {
        let provider = AyuPluginApplicationBridge()
        let first = AyuPluginAccountSnapshot(index: 7, identity: UUID(), userID: Int64.max - 7, firstName: "Synthetic")
        let second = AyuPluginAccountSnapshot(index: 9, identity: UUID(), userID: 42)
        provider.updateAccounts([first, second], selected: 7)
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let target: AyuBridgeValue = .object(["class_name": .string("org.telegram.messenger.UserConfig")])
        let initial = try await self.call(host, "java.member", ["target": target, "name": .string("selectedAccount")])
        XCTAssertEqual(initial["result"]["value"], .integer(7))
        let config = try await self.client(host, "get_user_config")
        XCTAssertNotNil(config["result"]["$handle"].string)
        let userID = try await self.invoke(host, config["result"], "getClientUserId")
        XCTAssertEqual(userID["result"], .integer(Int64.max - 7))
        provider.updateAccounts([first, second], selected: 9)
        let updated = try await self.call(host, "java.get_private_field", ["target": target, "name": .string("selectedAccount")])
        XCTAssertEqual(updated["result"], .integer(9))
        let stillFirst = try await self.invoke(host, config["result"], "getClientUserId")
        XCTAssertEqual(stillFirst["result"], .integer(first.userID))
    }

    func testLogoutSlotIdentityAndPluginOwnershipRejectOldConfig() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 3, identity: UUID(), userID: 11)], selected: 3)
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host); try await self.authorize(host, owner: "bravo")
        let config = try await self.client(host, "get_user_config")
        let foreign = try await self.invoke(host, config["result"], "getClientUserId", owner: "bravo")
        XCTAssertEqual(foreign["error"]["code"], .string("INVALID_HANDLE"))
        provider.updateAccounts([], selected: nil)
        let removed = try await self.invoke(host, config["result"], "getClientUserId")
        XCTAssertEqual(removed["error"]["code"], .string("ACCOUNT_UNAVAILABLE"))
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 3, identity: UUID(), userID: 12)], selected: 3)
        let replaced = try await self.invoke(host, config["result"], "getClientUserId")
        XCTAssertEqual(replaced["error"]["code"], .string("INVALID_HANDLE"))
    }

    func testProfileIsNarrowReadOnlyAndClientOptionsAreStrict() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 13, firstName: "A", lastName: "B", username: "synthetic")], selected: 0)
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let config = try await self.client(host, "get_user_config")
        let profile = try await self.invoke(host, config["result"], "getCurrentUser")
        let first = try await self.call(host, "java.get_field", ["target": profile["result"], "name": .string("first_name")])
        XCTAssertEqual(first["result"], .string("A"))
        for field in ["phone", "access_hash", "accountIdentity"] {
            let rejected = try await self.call(host, "java.get_private_field", ["target": profile["result"], "name": .string(field)])
            XCTAssertEqual(rejected["error"]["code"], .string("UNSUPPORTED_API"))
        }
        let write = try await self.call(host, "java.set_field", ["target": profile["result"], "name": .string("id"), "value": .integer(99)])
        XCTAssertEqual(write["error"]["code"], .string("UNSUPPORTED_API"))
        let malformed = try await self.client(host, "get_user_config", kwargs: ["account": .bool(true)])
        XCTAssertEqual(malformed["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testDynamicStaticFieldsRejectAmbiguityAndMalformedResults() async throws {
        let name = "example.Dynamic"
        XCTAssertThrowsError(try AyuBridgeClassRegistry([AyuBridgeClassAdapter(name: name, constants: ["value": .integer(1)], staticFields: ["value": { _ in .value(.null) }])]))
        XCTAssertThrowsError(try AyuBridgeClassRegistry([AyuBridgeClassAdapter(name: name, staticMethods: ["value": { _, _ in .value(.null) }], staticFields: ["value": { _ in .value(.null) }])]))
        let registry = try AyuBridgeClassRegistry.standard.adding([AyuBridgeClassAdapter(name: name, staticFields: ["bad": { _ in .value(.object(["$handle": .string("forged"), "$class": .string(name)])) }])])
        let host = self.host(AyuUnsupportedPluginHostProvider(), registry: registry)
        try await self.authorize(host)
        for operation in ["java.member", "java.get_field"] {
            let rejected = try await self.call(host, operation, ["target": .object(["class_name": .string(name)]), "name": .string("bad")])
            XCTAssertEqual(rejected["error"]["code"], .string("INVALID_HANDLE"))
        }
    }

    func testProviderCannotForgeHandlesAndEffectsCommitOnlyAfterResultValidation() async throws {
        let effects = AyuTestProviderEffects()
        let provider = AyuPreparedTestProvider(effects: effects)
        let host = self.host(provider)
        try await self.authorize(host)
        let bad = try await self.client(host, "bad")
        XCTAssertEqual(bad["error"]["code"], .string("INVALID_HANDLE"))
        XCTAssertEqual(effects.counts, [0, 1])
        let good = try await self.client(host, "good")
        XCTAssertEqual(good["result"]["$class"], .string("java.lang.Long"))
        XCTAssertNotNil(good["result"]["$handle"].string)
        XCTAssertEqual(effects.counts, [1, 1])
        let value = try await self.invoke(host, good["result"], "longValue")
        XCTAssertEqual(value["result"], .integer(Int64.max))
    }
}

private final class AyuTestProviderEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [0, 0]
    var counts: [Int] { self.lock.lock(); defer { self.lock.unlock() }; return self.values }
    func add(_ index: Int) { self.lock.lock(); self.values[index] += 1; self.lock.unlock() }
}
private final class AyuPreparedTestProvider: AyuPluginHostProvider, Sendable {
    let capabilities = ["client.call"]
    let effects: AyuTestProviderEffects
    init(effects: AyuTestProviderEffects) { self.effects = effects }
    func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue { throw AyuBridgeFailure.unsupported(operation) }
    func prepareCall(pluginID: String, operation: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        let result: AyuBridgeAdapterResult = arguments["name"]?.string == "good" ? .instance(className: "java.lang.Long", state: ["value": .integer(Int64.max)]) : .value(.object(["$handle": .string("invented"), "$class": .string("java.lang.Long")]))
        return AyuBridgeProviderResult(result, rollback: { self.effects.add(1) }, commit: { _ in self.effects.add(0) })
    }
    func detach(pluginID: String) {}
}
