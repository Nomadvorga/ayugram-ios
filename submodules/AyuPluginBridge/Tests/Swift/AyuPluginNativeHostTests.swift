import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Synthetic native tests only. No interpreter, account, attachment or network service.
/// Async transport keeps main free while the host marshals UIKit work to main.
@MainActor
final class AyuPluginNativeHostTests: XCTestCase {
    private func host(limits: AyuPluginBridgeLimits = AyuPluginBridgeLimits(), registry: AyuBridgeClassRegistry = .standard, callback: @escaping AyuPluginNativeHost.CallbackSink = { _, _, _ in }) -> AyuPluginNativeHost {
        let defaults = UserDefaults(suiteName: "AyuPluginBridgeTests." + UUID().uuidString)!
        return AyuPluginNativeHost(defaults: defaults, classRegistry: registry, limits: limits, trustedOwner: { "alpha" }, callback: callback)
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

    private func construct(_ host: AyuPluginNativeHost, _ name: String, _ args: [AyuBridgeValue] = []) async throws -> AyuBridgeValue {
        try await self.call(host, "java.construct", arguments: ["class_name": .string(name), "args": .array(args)])
    }
    private func invoke(_ host: AyuPluginNativeHost, _ target: AyuBridgeValue, _ name: String, _ args: [AyuBridgeValue] = [], owner: String = "alpha") async throws -> AyuBridgeValue {
        try await self.call(host, "java.invoke", owner: owner, arguments: ["target": target, "name": .string(name), "args": .array(args)])
    }
    private func classTarget(_ name: String) -> AyuBridgeValue { .object(["class_name": .string(name)]) }

    func testRegistryRejectsCollisionsReservedClassesAndUnsafeConstants() throws {
        let adapter = AyuBridgeClassAdapter(name: "example.Value")
        XCTAssertThrowsError(try AyuBridgeClassRegistry([adapter, adapter]))
        XCTAssertThrowsError(try AyuBridgeClassRegistry.standard.adding([AyuBridgeClassAdapter(name: "java.lang.Long")]))
        XCTAssertThrowsError(try AyuBridgeClassRegistry([AyuBridgeClassAdapter(name: "android.view.View")]))
        XCTAssertThrowsError(try AyuBridgeClassRegistry([AyuBridgeClassAdapter(name: "example.Value", readableFields: [], writableFields: ["value"])]))
        XCTAssertThrowsError(try AyuBridgeClassRegistry([AyuBridgeClassAdapter(name: "example.Value", methods: ["getClass": { _, _, _ in .value(.null) }])]))
        for value in [AyuBridgeValue.number(.infinity), .object(["$callback": .string("invented")]), .object(["$java_class": .string("unknown.Class")])] {
            XCTAssertThrowsError(try AyuBridgeClassRegistry([AyuBridgeClassAdapter(name: "example.Value", constants: ["BAD": value])]))
        }
    }

    func testJavaWrapperFactoriesPreserveInt64AndRejectOverflow() async throws {
        let host = self.host()
        try await self.authorize(host)
        let target = self.classTarget("java.lang.Long")
        let parsed = try await self.invoke(host, target, "parseLong", [.string(String(Int64.max))])
        XCTAssertEqual(parsed["result"], .integer(Int64.max))
        let boxed = try await self.invoke(host, target, "valueOf", [.integer(Int64.min)])
        let unboxed = try await self.invoke(host, boxed["result"], "longValue")
        XCTAssertEqual(unboxed["result"], .integer(Int64.min))
        let truncated = try await self.invoke(host, boxed["result"], "intValue")
        XCTAssertEqual(truncated["result"], .integer(0))
        let overflow = try await self.invoke(host, target, "parseLong", [.string("9223372036854775808")])
        XCTAssertEqual(overflow["error"]["code"], .string("INVALID_ARGUMENTS"))
        let intOverflow = try await self.construct(host, "java.lang.Integer", [.integer(Int64.max)])
        XCTAssertEqual(intOverflow["error"]["code"], .string("INVALID_ARGUMENTS"))
        let constant = try await self.call(host, "java.get_private_field", arguments: ["target": target, "name": .string("TYPE")])
        XCTAssertEqual(constant["result"], .object(["$java_class": .string("long")]))
        let unsupported = try await self.invoke(host, target, "parseLong", [.string("ff"), .integer(16)])
        XCTAssertEqual(unsupported["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testArrayListIndexedAccessCopyAndSelfAppend() async throws {
        let host = self.host()
        try await self.authorize(host)
        let list = try await self.construct(host, "java.util.ArrayList", [.array([.integer(Int64.max), .string("two")])])
        let target = list["result"]
        let first = try await self.call(host, "java.get_item", arguments: ["target": target, "index": .integer(0)])
        XCTAssertEqual(first["result"], .integer(Int64.max))
        _ = try await self.call(host, "java.set_item", arguments: ["target": target, "index": .integer(1), "value": .bool(true)])
        let copy = try await self.construct(host, "java.util.ArrayList", [target])
        _ = try await self.invoke(host, target, "addAll", [target])
        let length = try await self.call(host, "java.length", arguments: ["target": target])
        XCTAssertEqual(length["result"], .integer(4))
        let copied = try await self.invoke(host, copy["result"], "toArray")
        XCTAssertEqual(copied["result"], .array([.integer(Int64.max), .bool(true)]))
        let negative = try await self.invoke(host, target, "get", [.integer(-1)])
        XCTAssertEqual(negative["error"]["code"], .string("INVALID_ARGUMENTS"))
        let hidden = try await self.call(host, "java.get_private_field", arguments: ["target": target, "name": .string("values")])
        XCTAssertEqual(hidden["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testHashMapPreservesTypedKeysAndRejectsMalformedEntryStates() async throws {
        let host = self.host()
        try await self.authorize(host)
        let map = try await self.construct(host, "java.util.HashMap")
        let target = map["result"]
        for (key, value) in [(AyuBridgeValue.integer(1), AyuBridgeValue.string("integer")), (.string("1"), .string("string")), (.bool(true), .integer(Int64.max))] {
            _ = try await self.invoke(host, target, "put", [key, value])
            let read = try await self.invoke(host, target, "get", [key])
            XCTAssertEqual(read["result"], value)
        }
        let size = try await self.invoke(host, target, "size")
        XCTAssertEqual(size["result"], .integer(3))
        let validator = try XCTUnwrap(AyuBridgeClassRegistry.standard.adapters["java.util.HashMap"])
        for entries in [AyuBridgeValue.null, .array([.array([])]), .array([.array([.integer(1)])]), .array([.object([:])])] {
            XCTAssertThrowsError(try validator.validateState(["entries": entries]))
        }
        XCTAssertThrowsError(try AyuBridgeJavaValues.mapEntries(["entries": .array([.array([])])]))
    }

    func testAtomicValueSubsetsAndOverflowWrap() async throws {
        let host = self.host()
        try await self.authorize(host)
        let long = try await self.construct(host, "java.util.concurrent.atomic.AtomicLong", [.integer(Int64.max)])
        let incremented = try await self.invoke(host, long["result"], "incrementAndGet")
        XCTAssertEqual(incremented["result"], .integer(Int64.min))
        let changed = try await self.invoke(host, long["result"], "compareAndSet", [.integer(Int64.min), .integer(7)])
        XCTAssertEqual(changed["result"], .bool(true))
        let bool = try await self.construct(host, "java.util.concurrent.atomic.AtomicBoolean")
        let invalid = try await self.invoke(host, bool["result"], "set", [.integer(1)])
        XCTAssertEqual(invalid["error"]["code"], .string("INVALID_ARGUMENTS"))
        let read = try await self.invoke(host, bool["result"], "get")
        XCTAssertEqual(read["result"], .bool(false))
    }

    func testCustomAdapterStateValidationRollbackAndResultQuotas() async throws {
        let adapter = AyuBridgeClassAdapter(name: "example.Counter", constructor: { _, _ in ["value": .integer(1)] },
            staticMethods: ["badMap": { _, _ in .instance(className: "java.util.HashMap", state: ["entries": .array([.array([])])]) }],
            methods: [
                "invalidState": { state, _, _ in state["value"] = .string("bad"); return .value(.null) },
                "invalidResult": { state, _, _ in state["value"] = .integer(2); return .value(.object(["$handle": .string("forged"), "$class": .string("example.Counter")])) },
                "hugeResult": { state, _, _ in state["value"] = .integer(3); return .value(.string(String(repeating: "x", count: 5000))) },
                "invalidCallback": { state, _, _ in state["value"] = .integer(4); return .value(.object(["$callback": .string("invented")])) }
            ], readableFields: ["value"], writableFields: ["value"], validateState: { state in
                guard Set(state.keys) == ["value"], state["value"]?.integer != nil else { throw AyuBridgeFailure("invalid_arguments", "Invalid counter state") }
            })
        var limits = AyuPluginBridgeLimits(); limits.responseBytes = 4096
        let host = self.host(limits: limits, registry: try .standard.adding([adapter]))
        try await self.authorize(host)
        let object = try await self.construct(host, "example.Counter")
        let target = object["result"]
        for method in ["invalidState", "invalidResult", "hugeResult", "invalidCallback"] {
            let failed = try await self.invoke(host, target, method)
            XCTAssertNotNil(failed["error"]["code"].string)
            let unchanged = try await self.call(host, "java.get_field", arguments: ["target": target, "name": .string("value")])
            XCTAssertEqual(unchanged["result"], .integer(1))
        }
        let malformed = try await self.invoke(host, self.classTarget("example.Counter"), "badMap")
        XCTAssertEqual(malformed["error"]["code"], .string("INVALID_ARGUMENTS"))
        let write = try await self.call(host, "java.set_field", arguments: ["target": target, "name": .string("value"), "value": .string("bad")])
        XCTAssertEqual(write["error"]["code"], .string("INVALID_ARGUMENTS"))
        let unchanged = try await self.call(host, "java.get_field", arguments: ["target": target, "name": .string("value")])
        XCTAssertEqual(unchanged["result"], .integer(1))
    }

    func testAdapterStateQuotaAndForeignAndExpiredReferences() async throws {
        var limits = AyuPluginBridgeLimits(); limits.adapterStateBytesPerPlugin = 64
        let host = self.host(limits: limits)
        try await self.authorize(host)
        try await self.authorize(host, owner: "bravo")
        let list = try await self.construct(host, "java.util.ArrayList")
        let target = list["result"]
        let huge = try await self.invoke(host, target, "add", [.string(String(repeating: "x", count: 100))])
        XCTAssertEqual(huge["error"]["code"], .string("RESOURCE_LIMIT"))
        let unchanged = try await self.invoke(host, target, "size")
        XCTAssertEqual(unchanged["result"], .integer(0))
        let foreign = try await self.invoke(host, target, "size", owner: "bravo")
        XCTAssertEqual(foreign["error"]["code"], .string("INVALID_HANDLE"))
        _ = try await self.call(host, "plugin.deactivate")
        try await self.authorize(host)
        let expired = try await self.invoke(host, target, "size")
        XCTAssertEqual(expired["error"]["code"], .string("INVALID_HANDLE"))
    }

    func testMalformedConstructorAndMethodArgumentsNeverBecomeEmptyOverload() async throws {
        let host = self.host()
        try await self.authorize(host)
        let bad = try await self.call(host, "java.construct", arguments: ["class_name": .string("java.util.ArrayList"), "args": .object([:])])
        XCTAssertEqual(bad["error"]["code"], .string("INVALID_ARGUMENTS"))
        let badKwargs = try await self.call(host, "java.invoke", arguments: ["target": self.classTarget("java.lang.System"), "name": .string("nanoTime"), "kwargs": .array([])])
        XCTAssertEqual(badKwargs["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testAdapterContextCannotEscapeWorkerOrPluginGeneration() async throws {
        let saved = AyuBridgeTestContextBox()
        let adapter = AyuBridgeClassAdapter(name: "example.Context", constructor: { _, context in
            saved.storeOnce(context); return [:]
        }, methods: ["oldState": { _, args, _ in
            guard let context = saved.value else { throw AyuBridgeFailure("invalid_state", "No saved context") }
            return .value(.object(try context.state(of: args.first ?? .null)))
        }])
        let host = self.host(registry: try .standard.adding([adapter]))
        try await self.authorize(host)
        let old = try await self.construct(host, "example.Context")
        let context = try XCTUnwrap(saved.value)
        XCTAssertThrowsError(try context.state(of: old["result"])) { error in
            XCTAssertEqual((error as? AyuBridgeFailure)?.code, "WRONG_QUEUE")
        }
        _ = try await self.call(host, "plugin.deactivate")
        try await self.authorize(host)
        let new = try await self.construct(host, "example.Context")
        let expired = try await self.invoke(host, new["result"], "oldState", [new["result"]])
        XCTAssertEqual(expired["error"]["code"], .string("INVALID_HANDLE"))
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

    func testGravityConstantsAndViewSettersExposeOnlyTheImplementedSubset() async throws {
        let host = self.host()
        try await self.authorize(host)

        let gravity = self.classTarget("android.view.Gravity")
        let center = try await self.call(host, "java.member", arguments: ["target": gravity, "name": .string("CENTER")])
        XCTAssertEqual(center["result"], .object(["kind": .string("field"), "value": .integer(17)]))
        let start = try await self.call(host, "java.get_private_field", arguments: ["target": gravity, "name": .string("START")])
        XCTAssertEqual(start["result"], .integer(8_388_611))
        let unsupportedFill = try await self.call(host, "java.member", arguments: ["target": gravity, "name": .string("FILL")])
        XCTAssertEqual(unsupportedFill["error"]["code"], .string("UNSUPPORTED_API"))

        let text = try await self.construct(host, "android.widget.TextView")
        let textGravity = try await self.invoke(host, text["result"], "setGravity", [.integer(17)])
        XCTAssertEqual(textGravity["result"], .null)
        let invalid = try await self.invoke(host, text["result"], "setGravity", [.integer(112)])
        XCTAssertEqual(invalid["error"]["code"], .string("INVALID_ARGUMENTS"))

        let linear = try await self.construct(host, "android.widget.LinearLayout")
        let linearGravity = try await self.invoke(host, linear["result"], "setGravity", [.integer(8_388_611)])
        XCTAssertEqual(linearGravity["result"], .null)

        let image = try await self.construct(host, "android.widget.ImageView")
        let wrongClass = try await self.invoke(host, image["result"], "setGravity", [.integer(17)])
        XCTAssertEqual(wrongClass["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testLinearLayoutParamsWeightIsTypedBoundedAndParentChecked() async throws {
        let host = self.host()
        try await self.authorize(host)
        let params = try await self.construct(host, "android.widget.LinearLayout$LayoutParams", [.integer(-1), .integer(0), .number(2)])
        XCTAssertNotNil(params["result"]["$handle"].string)
        let weight = try await self.call(host, "java.get_field", arguments: ["target": params["result"], "name": .string("weight")])
        XCTAssertEqual(weight["result"], .integer(2))
        let updatedWeight = try await self.call(host, "java.set_field", arguments: ["target": params["result"], "name": .string("weight"), "value": .number(4)])
        XCTAssertEqual(updatedWeight["result"], .null)
        let readUpdatedWeight = try await self.call(host, "java.get_private_field", arguments: ["target": params["result"], "name": .string("weight")])
        XCTAssertEqual(readUpdatedWeight["result"], .integer(4))
        let negativeWeight = try await self.call(host, "java.set_field", arguments: ["target": params["result"], "name": .string("weight"), "value": .number(-1)])
        XCTAssertEqual(negativeWeight["error"]["code"], .string("INVALID_ARGUMENTS"))

        let badWeight = try await self.construct(host, "android.widget.LinearLayout$LayoutParams", [.integer(-1), .integer(0), .number(-1)])
        XCTAssertEqual(badWeight["error"]["code"], .string("INVALID_ARGUMENTS"))
        let frameParams = try await self.construct(host, "android.widget.FrameLayout$LayoutParams", [.integer(-1), .integer(-1)])
        let linear = try await self.construct(host, "android.widget.LinearLayout")
        let child = try await self.construct(host, "android.widget.TextView")
        let mismatch = try await self.invoke(host, linear["result"], "addView", [child["result"], frameParams["result"]])
        XCTAssertEqual(mismatch["error"]["code"], .string("INVALID_ARGUMENTS"))
        let accepted = try await self.invoke(host, linear["result"], "addView", [child["result"], params["result"]])
        XCTAssertEqual(accepted["result"], .null)
    }

    func testStandardRegistryIntegratesBoundedBundleAndIntentValueAdapters() async throws {
        let host = self.host()
        try await self.authorize(host)
        let capabilities = try await self.call(host, "runtime.capabilities")
        let classes = Set(capabilities["result"]["classes"].array?.compactMap(\.string) ?? [])
        XCTAssertTrue(classes.contains("android.os.Bundle"))
        XCTAssertTrue(classes.contains("android.content.Intent"))
        XCTAssertFalse(classes.contains("android.graphics.Canvas"))

        let bundle = try await self.construct(host, "android.os.Bundle")
        let stored = try await self.invoke(host, bundle["result"], "putString", [.string("token"), .string("synthetic")])
        XCTAssertEqual(stored["result"], .null)
        let value = try await self.invoke(host, bundle["result"], "getString", [.string("token")])
        XCTAssertEqual(value["result"], .string("synthetic"))

        let intent = try await self.construct(host, "android.content.Intent", [.string("local-only")])
        let action = try await self.invoke(host, intent["result"], "getAction")
        XCTAssertEqual(action["result"], .string("local-only"))
        let launch = try await self.invoke(host, intent["result"], "startActivity")
        XCTAssertEqual(launch["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testSameClassAdapterMutatorsReuseTheExistingHandle() async throws {
        let host = self.host()
        try await self.authorize(host)

        let intent = try await self.construct(host, "android.content.Intent", [.string("before")])
        let target = intent["result"]
        let changed = try await self.invoke(host, target, "setAction", [.string("after")])
        XCTAssertEqual(changed["result"]["$handle"], target["$handle"])
        XCTAssertEqual(changed["result"]["$class"], target["$class"])
        let action = try await self.invoke(host, target, "getAction")
        XCTAssertEqual(action["result"], .string("after"))

        let flags = try await self.invoke(host, target, "addFlags", [.integer(0x1000_0000)])
        XCTAssertEqual(flags["result"]["$handle"], target["$handle"])
        let categories = try await self.invoke(host, target, "addCategory", [.string("android.intent.category.DEFAULT")])
        XCTAssertEqual(categories["result"]["$handle"], target["$handle"])
    }

    func testSameClassCopyResultAllocatesNewObjectInsteadOfReplacingReceiver() async throws {
        let copyable = AyuBridgeClassAdapter(name: "example.Copyable", constructor: { _, _ in ["value": .integer(1)] },
            methods: [
                "setValue": { state, args, _ in
                    guard args.count == 1 else { throw AyuBridgeFailure("invalid_arguments", "Expected one value") }
                    state["value"] = args[0]
                    return .instance(className: "example.Copyable", state: state)
                },
                "copy": { state, args, _ in
                    guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Expected no values") }
                    return .instance(className: "example.Copyable", state: state)
                },
            ], readableFields: ["value"], writableFields: ["value"], receiverMethods: ["setValue"], validateState: { state in
                guard Set(state.keys) == ["value"], state["value"]?.integer != nil else {
                    throw AyuBridgeFailure("invalid_arguments", "Invalid copyable state")
                }
            })
        let host = self.host(registry: try .standard.adding([copyable]))
        try await self.authorize(host)

        let original = try await self.construct(host, "example.Copyable")
        let changed = try await self.invoke(host, original["result"], "setValue", [.integer(7)])
        XCTAssertEqual(changed["result"]["$handle"], original["result"]["$handle"])
        let copied = try await self.invoke(host, original["result"], "copy")
        XCTAssertNotEqual(copied["result"]["$handle"], original["result"]["$handle"])
        XCTAssertEqual(copied["result"]["$class"], .string("example.Copyable"))
        let originalValue = try await self.call(host, "java.get_field", arguments: ["target": original["result"], "name": .string("value")])
        let copiedValue = try await self.call(host, "java.get_field", arguments: ["target": copied["result"], "name": .string("value")])
        XCTAssertEqual(originalValue["result"], .integer(7))
        XCTAssertEqual(copiedValue["result"], .integer(7))
    }

    func testPreparedAdapterReservationsRollbackOnEnclosingStateValidationFailure() async throws {
        let reservations = AyuBridgeTestReservationBox()
        let adapter = AyuBridgeClassAdapter(name: "example.Prepared", constructor: { _, _ in ["value": .integer(1)] },
            methods: [
                "invalidSchema": { state, _, _ in
                    state["value"] = .string("invalid")
                    return .prepared(AyuBridgeProviderResult(.value(.null), rollback: { reservations.rollback() }, commit: { _ in reservations.commit() }))
                },
                "foreignReference": { state, _, _ in
                    state["value"] = .object(["$handle": .string("foreign"), "$class": .string("example.Prepared")])
                    return .prepared(AyuBridgeProviderResult(.value(.null), rollback: { reservations.rollback() }, commit: { _ in reservations.commit() }))
                },
                "overQuota": { state, _, _ in
                    state["value"] = .string(String(repeating: "x", count: 512))
                    return .prepared(AyuBridgeProviderResult(.value(.null), rollback: { reservations.rollback() }, commit: { _ in reservations.commit() }))
                },
            ], readableFields: ["value"], validateState: { state in
                guard Set(state.keys) == ["value"], state["value"]?.integer != nil || state["value"]?.string != nil else {
                    throw AyuBridgeFailure("invalid_arguments", "Invalid prepared state")
                }
                if state["value"]?.string == "invalid" { throw AyuBridgeFailure("invalid_arguments", "Invalid prepared value") }
            })
        var limits = AyuPluginBridgeLimits()
        limits.adapterStateBytesPerPlugin = 128
        let host = self.host(limits: limits, registry: try .standard.adding([adapter]))
        try await self.authorize(host)
        let object = try await self.construct(host, "example.Prepared")

        for method in ["invalidSchema", "foreignReference", "overQuota"] {
            let before = reservations.rollbackCount
            let result = try await self.invoke(host, object["result"], method)
            XCTAssertNotNil(result["error"]["code"].string, method)
            XCTAssertEqual(reservations.rollbackCount, before + 1, method)
            let value = try await self.call(host, "java.get_field", arguments: ["target": object["result"], "name": .string("value")])
            XCTAssertEqual(value["result"], .integer(1), method)
        }
        XCTAssertEqual(reservations.commitCount, 0)
    }

    func testScrollViewAcceptsOnlyOneDirectChildAtATime() async throws {
        let host = self.host()
        try await self.authorize(host)

        let scroll = try await self.construct(host, "android.widget.ScrollView")
        let first = try await self.construct(host, "android.widget.TextView")
        let second = try await self.construct(host, "android.widget.TextView")
        let scrollTarget = scroll["result"]

        let mounted = try await self.invoke(host, scrollTarget, "addView", [first["result"]])
        XCTAssertEqual(mounted["result"], .null)
        let count = try await self.invoke(host, scrollTarget, "getChildCount")
        XCTAssertEqual(count["result"], .integer(1))

        let rejected = try await self.invoke(host, scrollTarget, "addView", [second["result"]])
        XCTAssertEqual(rejected["error"]["code"], .string("INVALID_STATE"))

        let removed = try await self.invoke(host, scrollTarget, "removeView", [first["result"]])
        XCTAssertEqual(removed["result"], .null)
        let remounted = try await self.invoke(host, scrollTarget, "addView", [second["result"]])
        XCTAssertEqual(remounted["result"], .null)
        let finalCount = try await self.invoke(host, scrollTarget, "getChildCount")
        XCTAssertEqual(finalCount["result"], .integer(1))
    }

    func testScrollViewMeasuresWrapContentChildrenAndRelayoutsOnDirectChildResize() async throws {
        let host = self.host()
        try await self.authorize(host)
        let scroll = try await self.construct(host, "android.widget.ScrollView")
        let linear = try await self.construct(host, "android.widget.LinearLayout")
        let layout = try await self.construct(host, "android.widget.FrameLayout$LayoutParams", [.integer(-1), .integer(-2)])
        _ = try await self.invoke(host, scroll["result"], "addView", [linear["result"], layout["result"]])

        for index in 0..<20 {
            let row = try await self.construct(host, "android.widget.TextView")
            _ = try await self.invoke(host, row["result"], "setText", [.string("Scrollable row \(index) with intrinsic height")])
            _ = try await self.invoke(host, linear["result"], "addView", [row["result"]])
        }

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        let attached = XCTestExpectation(description: "mount container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachedResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1.0)
        XCTAssertEqual(attachedResult, .completed)
        let mounted = try await self.call(host, "ui.mount", arguments: ["target": scroll["result"]])
        XCTAssertEqual(mounted["result"], .null)

        let intrinsicHeight = try await self.invoke(host, linear["result"], "getHeight")
        XCTAssertGreaterThan(intrinsicHeight["result"].number ?? 0, 180)

        let fixedTall = try await self.construct(host, "android.widget.FrameLayout$LayoutParams", [.integer(-1), .integer(420)])
        _ = try await self.invoke(host, linear["result"], "setLayoutParams", [fixedTall["result"]])
        let tall = try await self.invoke(host, linear["result"], "getHeight")
        XCTAssertEqual(tall["result"], .integer(420))

        let fixedShort = try await self.construct(host, "android.widget.FrameLayout$LayoutParams", [.integer(-1), .integer(260)])
        _ = try await self.invoke(host, linear["result"], "setLayoutParams", [fixedShort["result"]])
        let short = try await self.invoke(host, linear["result"], "getHeight")
        XCTAssertEqual(short["result"], .integer(260))
    }

    func testHandlerPostUsesRunnableProxyAndRemoveCallbacksFailsExplicitly() async throws {
        let callback = XCTestExpectation(description: "handler callback")
        let callbackAgain = XCTestExpectation(description: "handler callback can be posted again")
        let callbackOwner = AyuBridgeTestCallbackBox()
        let host = self.host(callback: { owner, callbackID, arguments in
            if callbackOwner.store(owner: owner, callbackID: callbackID, arguments: arguments) == 1 {
                callback.fulfill()
            } else {
                callbackAgain.fulfill()
            }
        })
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", arguments: ["generation": .string("handler-generation")])

        let runnable = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("java.lang.Runnable")]),
            "callbacks": .object(["run": .object(["$callback": .string("handler-callback")])]),
        ])
        let handler = try await self.construct(host, "android.os.Handler")
        let posted = try await self.invoke(host, handler["result"], "post", [runnable["result"]])
        XCTAssertEqual(posted["result"], .bool(true))
        let waitResult = await XCTWaiter.fulfillment(of: [callback], timeout: 1.0)
        XCTAssertEqual(waitResult, .completed)
        XCTAssertEqual(callbackOwner.owner, "alpha")
        XCTAssertEqual(callbackOwner.callbackID, "handler-callback")
        XCTAssertTrue(callbackOwner.arguments.isEmpty)

        let postedAgain = try await self.invoke(host, handler["result"], "post", [runnable["result"]])
        XCTAssertEqual(postedAgain["result"], .bool(true))
        let secondWaitResult = await XCTWaiter.fulfillment(of: [callbackAgain], timeout: 1.0)
        XCTAssertEqual(secondWaitResult, .completed)

        let cancellation = try await self.invoke(host, handler["result"], "removeCallbacks", [runnable["result"]])
        XCTAssertEqual(cancellation["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testHandlerPendingLimitAndUnloadRevokeDelayedCallback() async throws {
        var limits = AyuPluginBridgeLimits()
        limits.callbacksPerPlugin = 1
        let callback = XCTestExpectation(description: "delayed handler callback must be revoked")
        callback.isInverted = true
        let host = self.host(limits: limits, callback: { _, _, _ in callback.fulfill() })
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", arguments: ["generation": .string("handler-generation")])
        let runnable = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("java.lang.Runnable")]),
            "callbacks": .object(["run": .object(["$callback": .string("handler-callback")])]),
        ])
        let handler = try await self.construct(host, "android.os.Handler")
        let invalidDelay = try await self.invoke(host, handler["result"], "postDelayed", [runnable["result"], .integer(-1)])
        XCTAssertEqual(invalidDelay["error"]["code"], .string("INVALID_ARGUMENTS"))
        let delayed = try await self.invoke(host, handler["result"], "postDelayed", [runnable["result"], .integer(60_000)])
        XCTAssertEqual(delayed["result"], .bool(true))
        let overLimit = try await self.invoke(host, handler["result"], "postDelayed", [runnable["result"], .integer(60_000)])
        XCTAssertEqual(overLimit["error"]["code"], .string("RESOURCE_LIMIT"))

        _ = try await self.call(host, "plugin.deactivate", arguments: ["generation": .string("handler-generation")])
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", arguments: ["generation": .string("new-handler-generation")])
        let waitResult = await XCTWaiter.fulfillment(of: [callback], timeout: 0.1)
        XCTAssertEqual(waitResult, .completed)
    }

    func testSettingsReplacementClearsOnlyOwnerAndPersistsAcrossDetach() async throws {
        let host = self.host()
        try await self.authorize(host)
        try await self.authorize(host, owner: "bravo")
        _ = try await self.call(host, "settings.set", arguments: ["key": .string("old"), "value": .integer(1)])
        _ = try await self.call(host, "settings.set", owner: "bravo", arguments: ["key": .string("keep"), "value": .integer(2)])
        let replacement: AyuBridgeValue = .object(["exactID": .integer(Int64.max)])
        let updated = try await self.call(host, "settings.replace", arguments: ["values": replacement, "reload_settings": .bool(true)])
        XCTAssertEqual(updated["result"], .null)
        let read = try await self.call(host, "settings.all")
        XCTAssertEqual(read["result"], replacement)
        _ = try await self.call(host, "plugin.deactivate")
        try await self.authorize(host)
        let restored = try await self.call(host, "settings.all")
        XCTAssertEqual(restored["result"], replacement)
        _ = try await self.call(host, "settings.replace", arguments: ["values": .object([:]), "reload_settings": .bool(false)])
        let cleared = try await self.call(host, "settings.all")
        XCTAssertEqual(cleared["result"], .object([:]))
        let other = try await self.call(host, "settings.all", owner: "bravo")
        XCTAssertEqual(other["result"], .object(["keep": .integer(2)]))
    }

    func testRejectedSettingsReplacementKeepsCompletePreviousNamespace() async throws {
        var limits = AyuPluginBridgeLimits()
        limits.settingsBytesPerPlugin = 128
        let host = self.host(limits: limits)
        try await self.authorize(host)
        _ = try await self.call(host, "settings.set", arguments: ["key": .string("keep"), "value": .integer(1)])
        let replacements: [AyuBridgeValue] = [
            .object(["huge": .string(String(repeating: "x", count: 256))]),
            .object(["": .integer(1)]),
            .object(["nested": .object(["$reserved": .string("rejected")])]),
        ]
        for values in replacements {
            let response = try await self.call(host, "settings.replace", arguments: ["values": values, "reload_settings": .bool(false)])
            XCTAssertNotNil(response["error"]["code"].string)
            let read = try await self.call(host, "settings.all")
            XCTAssertEqual(read["result"], .object(["keep": .integer(1)]))
        }
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

    func testByteShortAndCharArraysRejectOutOfRangeValues() async throws {
        let host = self.host()
        try await self.authorize(host)
        for (component, values, invalid) in [("byte", [AyuBridgeValue.integer(-128), .integer(127)], AyuBridgeValue.integer(128)),
                                              ("short", [.integer(-32768), .integer(32767)], .integer(32768)),
                                              ("char", [.string("A"), .string("\0")], .string("😀"))] {
            let array = try await self.call(host, "java.array", arguments: ["component": .string(component), "values": .array(values)])
            XCTAssertNotNil(array["result"]["$handle"].string)
            let read = try await self.call(host, "java.get_item", arguments: ["target": array["result"], "index": .integer(0)])
            XCTAssertEqual(read["result"], values[0])
            let rejected = try await self.call(host, "java.set_item", arguments: ["target": array["result"], "index": .integer(0), "value": invalid])
            XCTAssertEqual(rejected["error"]["code"], .string("INVALID_ARGUMENTS"))
        }
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
        XCTAssertTrue(gate.reserve(owner: "alpha", generation: new, limit: 1))
    }
}

private final class AyuBridgeTestContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var context: AyuBridgeAdapterContext?
    var value: AyuBridgeAdapterContext? { self.lock.lock(); defer { self.lock.unlock() }; return self.context }
    func storeOnce(_ value: AyuBridgeAdapterContext) {
        self.lock.lock(); defer { self.lock.unlock() }
        if self.context == nil { self.context = value }
    }
}

private final class AyuBridgeTestCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOwner: String?
    private var storedCallbackID: String?
    private var storedArguments: [AyuBridgeValue] = []

    var owner: String? { self.lock.lock(); defer { self.lock.unlock() }; return self.storedOwner }
    var callbackID: String? { self.lock.lock(); defer { self.lock.unlock() }; return self.storedCallbackID }
    var arguments: [AyuBridgeValue] { self.lock.lock(); defer { self.lock.unlock() }; return self.storedArguments }

    @discardableResult
    func store(owner: String, callbackID: String, arguments: [AyuBridgeValue]) -> Int {
        self.lock.lock(); defer { self.lock.unlock() }
        self.storedOwner = owner
        self.storedCallbackID = callbackID
        self.storedArguments = arguments
        self.count += 1
        return self.count
    }
    private var count = 0
}

private final class AyuBridgeTestReservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRollbackCount = 0
    private var storedCommitCount = 0

    var rollbackCount: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.storedRollbackCount }
    var commitCount: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.storedCommitCount }

    func rollback() {
        self.lock.lock(); defer { self.lock.unlock() }
        self.storedRollbackCount += 1
    }

    func commit() {
        self.lock.lock(); defer { self.lock.unlock() }
        self.storedCommitCount += 1
    }
}
