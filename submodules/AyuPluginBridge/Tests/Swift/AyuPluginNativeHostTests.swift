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

    private func construct(_ host: AyuPluginNativeHost, _ name: String, _ args: [AyuBridgeValue] = [], owner: String = "alpha") async throws -> AyuBridgeValue {
        try await self.call(host, "java.construct", owner: owner, arguments: ["class_name": .string(name), "args": .array(args)])
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

    func testViewPropertyAnimatorIsAnOwnedNativeDescriptorWithoutFrameCallbacks() async throws {
        let host = self.host()
        try await self.authorize(host)
        let view = try await self.construct(host, "android.view.View")
        let animator = try await self.invoke(host, view["result"], "animate")
        XCTAssertEqual(animator["result"]["$class"], .string("android.view.ViewPropertyAnimator"))

        let alpha = try await self.invoke(host, animator["result"], "alpha", [.number(0.25)])
        XCTAssertEqual(alpha["result"], animator["result"])
        let scale = try await self.invoke(host, animator["result"], "scaleX", [.number(1.1)])
        XCTAssertEqual(scale["result"], animator["result"])
        let duration = try await self.invoke(host, animator["result"], "setDuration", [.integer(240)])
        XCTAssertEqual(duration["result"], animator["result"])

        let interpolator = try await self.construct(host, "android.view.animation.OvershootInterpolator", [.number(1.2)])
        let configured = try await self.invoke(host, animator["result"], "setInterpolator", [interpolator["result"]])
        XCTAssertEqual(configured["result"], animator["result"])
        let unsupported = try await self.invoke(host, animator["result"], "setListener", [])
        XCTAssertEqual(unsupported["error"]["code"], .string("UNSUPPORTED_API"))
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
        let readTextGravity = try await self.invoke(host, text["result"], "getGravity")
        XCTAssertEqual(readTextGravity["result"], .integer(17))
        let invalid = try await self.invoke(host, text["result"], "setGravity", [.integer(112)])
        XCTAssertEqual(invalid["error"]["code"], .string("INVALID_ARGUMENTS"))

        let linear = try await self.construct(host, "android.widget.LinearLayout")
        let linearGravity = try await self.invoke(host, linear["result"], "setGravity", [.integer(8_388_611)])
        XCTAssertEqual(linearGravity["result"], .null)
        let readLinearGravity = try await self.invoke(host, linear["result"], "getGravity")
        XCTAssertEqual(readLinearGravity["result"], .integer(8_388_611))
        _ = try await self.invoke(host, linear["result"], "setOrientation", [.integer(0)])
        let orientation = try await self.invoke(host, linear["result"], "getOrientation")
        XCTAssertEqual(orientation["result"], .integer(0))

        let image = try await self.construct(host, "android.widget.ImageView")
        let wrongClass = try await self.invoke(host, image["result"], "setGravity", [.integer(17)])
        XCTAssertEqual(wrongClass["error"]["code"], .string("UNSUPPORTED_API"))
        let wrongGravityRead = try await self.invoke(host, image["result"], "getGravity")
        XCTAssertEqual(wrongGravityRead["error"]["code"], .string("UNSUPPORTED_API"))
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

    func testScrollViewFillViewportAndBoundedVerticalScrolling() async throws {
        let host = self.host()
        try await self.authorize(host)
        let scroll = try await self.construct(host, "android.widget.ScrollView")
        let child = try await self.construct(host, "android.widget.FrameLayout")
        let shortParams = try await self.construct(host, "android.widget.FrameLayout$LayoutParams", [.integer(-1), .integer(40)])
        _ = try await self.invoke(host, scroll["result"], "addView", [child["result"], shortParams["result"]])

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        let attached = XCTestExpectation(description: "scroll operation container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachmentResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachmentResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": scroll["result"]])
        let nativeScroll = try XCTUnwrap(container.subviews.first?.subviews.compactMap { $0 as? UIScrollView }.first)

        _ = try await self.invoke(host, scroll["result"], "setVerticalScrollBarEnabled", [.bool(false)])
        _ = try await self.invoke(host, scroll["result"], "getHeight")
        XCTAssertFalse(nativeScroll.showsVerticalScrollIndicator)
        _ = try await self.invoke(host, scroll["result"], "setVerticalScrollBarEnabled", [.bool(true)])
        _ = try await self.invoke(host, scroll["result"], "getHeight")
        XCTAssertTrue(nativeScroll.showsVerticalScrollIndicator)
        let overscrollNever = try await self.invoke(host, scroll["result"], "setOverScrollMode", [.integer(2)])
        XCTAssertEqual(overscrollNever["error"], .null)
        _ = try await self.invoke(host, scroll["result"], "getHeight")
        XCTAssertFalse(nativeScroll.bounces)
        let unsupportedOverscroll = try await self.invoke(host, scroll["result"], "setOverScrollMode", [.integer(0)])
        XCTAssertEqual(unsupportedOverscroll["error"]["code"], .string("UNSUPPORTED_API"))
        let clipToPadding = try await self.invoke(host, scroll["result"], "setClipToPadding", [.bool(true)])
        XCTAssertEqual(clipToPadding["error"], .null)
        _ = try await self.invoke(host, scroll["result"], "getHeight")
        XCTAssertTrue(nativeScroll.clipsToBounds)
        let clipToPaddingFalse = try await self.invoke(host, scroll["result"], "setClipToPadding", [.bool(false)])
        XCTAssertEqual(clipToPaddingFalse["error"]["code"], .string("UNSUPPORTED_API"))
        let clipToPaddingWrongType = try await self.invoke(host, scroll["result"], "setClipToPadding", [.integer(1)])
        XCTAssertEqual(clipToPaddingWrongType["error"]["code"], .string("INVALID_ARGUMENTS"))

        let initialFillViewport = try await self.invoke(host, scroll["result"], "isFillViewport")
        XCTAssertEqual(initialFillViewport["result"], .bool(false))
        let initialChildHeight = try await self.invoke(host, child["result"], "getHeight")
        XCTAssertEqual(initialChildHeight["result"], .integer(40))
        _ = try await self.invoke(host, scroll["result"], "setFillViewport", [.bool(true)])
        let enabledFillViewport = try await self.invoke(host, scroll["result"], "isFillViewport")
        XCTAssertEqual(enabledFillViewport["result"], .bool(true))
        let filledChildHeight = try await self.invoke(host, child["result"], "getHeight")
        XCTAssertEqual(filledChildHeight["result"], .integer(180))

        _ = try await self.invoke(host, scroll["result"], "setFillViewport", [.bool(false)])
        let tallParams = try await self.construct(host, "android.widget.FrameLayout$LayoutParams", [.integer(-1), .integer(420)])
        _ = try await self.invoke(host, child["result"], "setLayoutParams", [tallParams["result"]])
        let tallChildHeight = try await self.invoke(host, child["result"], "getHeight")
        XCTAssertEqual(tallChildHeight["result"], .integer(420))

        _ = try await self.invoke(host, scroll["result"], "scrollTo", [.integer(0), .integer(100)])
        let scrolledTo = try await self.invoke(host, scroll["result"], "getScrollY")
        XCTAssertEqual(scrolledTo["result"], .integer(100))
        _ = try await self.invoke(host, scroll["result"], "scrollBy", [.integer(0), .integer(50)])
        let scrolledBy = try await self.invoke(host, scroll["result"], "getScrollY")
        XCTAssertEqual(scrolledBy["result"], .integer(150))
        _ = try await self.invoke(host, scroll["result"], "scrollBy", [.integer(0), .integer(Int64(Int32.max))])
        let scrollByClampedToBottom = try await self.invoke(host, scroll["result"], "getScrollY")
        XCTAssertEqual(scrollByClampedToBottom["result"], .integer(240))
        _ = try await self.invoke(host, scroll["result"], "scrollBy", [.integer(0), .integer(-500)])
        let clampedToTop = try await self.invoke(host, scroll["result"], "getScrollY")
        XCTAssertEqual(clampedToTop["result"], .integer(0))
        _ = try await self.invoke(host, scroll["result"], "scrollTo", [.integer(0), .integer(-50)])
        let negativeScrollToClampedToTop = try await self.invoke(host, scroll["result"], "getScrollY")
        XCTAssertEqual(negativeScrollToClampedToTop["result"], .integer(0))
        _ = try await self.invoke(host, scroll["result"], "scrollTo", [.integer(0), .integer(Int64(Int32.max))])
        let clampedToBottom = try await self.invoke(host, scroll["result"], "getScrollY")
        XCTAssertEqual(clampedToBottom["result"], .integer(240))
        let horizontalOffset = try await self.invoke(host, scroll["result"], "getScrollX")
        XCTAssertEqual(horizontalOffset["result"], .integer(0))

        let horizontal = try await self.invoke(host, scroll["result"], "scrollTo", [.integer(1), .integer(10)])
        XCTAssertEqual(horizontal["error"]["code"], .string("UNSUPPORTED_API"))
        let wrongOverscrollType = try await self.invoke(host, scroll["result"], "setOverScrollMode", [.bool(false)])
        XCTAssertEqual(wrongOverscrollType["error"]["code"], .string("INVALID_ARGUMENTS"))
        let wrongType = try await self.invoke(host, scroll["result"], "setFillViewport", [.integer(1)])
        XCTAssertEqual(wrongType["error"]["code"], .string("INVALID_ARGUMENTS"))
        let smoothScroll = try await self.invoke(host, scroll["result"], "smoothScrollTo", [.integer(0), .integer(60)])
        XCTAssertEqual(smoothScroll["error"], .null)
    }

    func testHorizontalScrollViewFillViewportAndBoundedHorizontalScrolling() async throws {
        let host = self.host()
        try await self.authorize(host)
        let scroll = try await self.construct(host, "android.widget.HorizontalScrollView")
        let child = try await self.construct(host, "android.widget.FrameLayout")
        let wrapParams = try await self.construct(host, "android.widget.FrameLayout$LayoutParams", [.integer(-2), .integer(-1)])
        _ = try await self.invoke(host, scroll["result"], "addView", [child["result"], wrapParams["result"]])
        let secondChild = try await self.construct(host, "android.widget.FrameLayout")
        let secondChildRejected = try await self.invoke(host, scroll["result"], "addView", [secondChild["result"]])
        XCTAssertEqual(secondChildRejected["error"]["code"], .string("INVALID_STATE"))

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        let attached = XCTestExpectation(description: "horizontal scroll operation container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachmentResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachmentResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": scroll["result"]])
        let nativeScroll = try XCTUnwrap(container.subviews.first?.subviews.compactMap { $0 as? UIScrollView }.first)

        let initialFillViewport = try await self.invoke(host, scroll["result"], "isFillViewport")
        XCTAssertEqual(initialFillViewport["result"], .bool(false))
        _ = try await self.invoke(host, scroll["result"], "setFillViewport", [.bool(true)])
        let enabledFillViewport = try await self.invoke(host, scroll["result"], "isFillViewport")
        XCTAssertEqual(enabledFillViewport["result"], .bool(true))
        let filledChildWidth = try await self.invoke(host, child["result"], "getWidth")
        XCTAssertEqual(filledChildWidth["result"], .integer(240))

        _ = try await self.invoke(host, scroll["result"], "setFillViewport", [.bool(false)])
        let wideParams = try await self.construct(host, "android.widget.FrameLayout$LayoutParams", [.integer(420), .integer(-1)])
        _ = try await self.invoke(host, child["result"], "setLayoutParams", [wideParams["result"]])
        let wideChildWidth = try await self.invoke(host, child["result"], "getWidth")
        XCTAssertEqual(wideChildWidth["result"], .integer(420))

        _ = try await self.invoke(host, scroll["result"], "setHorizontalScrollBarEnabled", [.bool(false)])
        _ = try await self.invoke(host, scroll["result"], "getHeight")
        XCTAssertFalse(nativeScroll.showsHorizontalScrollIndicator)
        _ = try await self.invoke(host, scroll["result"], "setHorizontalScrollBarEnabled", [.bool(true)])
        _ = try await self.invoke(host, scroll["result"], "getHeight")
        XCTAssertTrue(nativeScroll.showsHorizontalScrollIndicator)

        _ = try await self.invoke(host, scroll["result"], "scrollTo", [.integer(80), .integer(0)])
        let scrolledTo = try await self.invoke(host, scroll["result"], "getScrollX")
        XCTAssertEqual(scrolledTo["result"], .integer(80))
        _ = try await self.invoke(host, scroll["result"], "scrollBy", [.integer(50), .integer(0)])
        let scrolledBy = try await self.invoke(host, scroll["result"], "getScrollX")
        XCTAssertEqual(scrolledBy["result"], .integer(130))
        _ = try await self.invoke(host, scroll["result"], "scrollBy", [.integer(-500), .integer(0)])
        let clampedToLeadingEdge = try await self.invoke(host, scroll["result"], "getScrollX")
        XCTAssertEqual(clampedToLeadingEdge["result"], .integer(0))
        _ = try await self.invoke(host, scroll["result"], "scrollTo", [.integer(Int64(Int32.max)), .integer(0)])
        let clampedToTrailingEdge = try await self.invoke(host, scroll["result"], "getScrollX")
        XCTAssertEqual(clampedToTrailingEdge["result"], .integer(180))
        let verticalOffset = try await self.invoke(host, scroll["result"], "getScrollY")
        XCTAssertEqual(verticalOffset["result"], .integer(0))

        let verticalRequest = try await self.invoke(host, scroll["result"], "scrollTo", [.integer(10), .integer(1)])
        XCTAssertEqual(verticalRequest["error"]["code"], .string("UNSUPPORTED_API"))
        let wrongScrollbarType = try await self.invoke(host, scroll["result"], "setHorizontalScrollBarEnabled", [.integer(0)])
        XCTAssertEqual(wrongScrollbarType["error"]["code"], .string("INVALID_ARGUMENTS"))
        let wrongScrollbarAxis = try await self.invoke(host, scroll["result"], "setVerticalScrollBarEnabled", [.bool(false)])
        XCTAssertEqual(wrongScrollbarAxis["error"]["code"], .string("UNSUPPORTED_API"))
        let smoothScroll = try await self.invoke(host, scroll["result"], "smoothScrollTo", [.integer(60), .integer(0)])
        XCTAssertEqual(smoothScroll["error"], .null)
    }

    func testProgressBarSupportsOnlyAuditedIndeterminateAndHorizontalSubsets() async throws {
        let contextAdapter = AyuBridgeClassAdapter(name: "android.content.Context", constructor: { args, _ in
            guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Expected no fixture arguments") }
            return [:]
        })
        let registry = try AyuBridgeClassRegistry.standard.adding([contextAdapter])
        let host = self.host(registry: registry)
        try await self.authorize(host)
        let context = try await self.construct(host, "android.content.Context")

        let indeterminate = try await self.construct(host, "android.widget.ProgressBar", [context["result"]])
        XCTAssertEqual(indeterminate["error"], .null)
        let unsupportedProgress = try await self.invoke(host, indeterminate["result"], "setProgress", [.integer(1)])
        XCTAssertEqual(unsupportedProgress["error"]["code"], .string("UNSUPPORTED_API"))

        let horizontal = try await self.construct(host, "android.widget.ProgressBar", [context["result"], .null, .integer(0x0101_0078)])
        XCTAssertEqual(horizontal["error"], .null)
        let wrongStyle = try await self.construct(host, "android.widget.ProgressBar", [context["result"], .null, .integer(0)])
        XCTAssertEqual(wrongStyle["error"]["code"], .string("UNSUPPORTED_API"))
        let wrongConstructor = try await self.construct(host, "android.widget.ProgressBar", [context["result"], .string("attributes")])
        XCTAssertEqual(wrongConstructor["error"]["code"], .string("UNSUPPORTED_API"))

        let initialMaximum = try await self.invoke(host, horizontal["result"], "getMax")
        XCTAssertEqual(initialMaximum["result"], .integer(100))
        let initialProgress = try await self.invoke(host, horizontal["result"], "getProgress")
        XCTAssertEqual(initialProgress["result"], .integer(0))
        _ = try await self.invoke(host, horizontal["result"], "setMax", [.integer(4)])
        _ = try await self.invoke(host, horizontal["result"], "setProgress", [.integer(2)])
        let boundedProgress = try await self.invoke(host, horizontal["result"], "getProgress")
        XCTAssertEqual(boundedProgress["result"], .integer(2))
        _ = try await self.invoke(host, horizontal["result"], "setProgress", [.integer(9)])
        let clampedProgress = try await self.invoke(host, horizontal["result"], "getProgress")
        XCTAssertEqual(clampedProgress["result"], .integer(4))
        _ = try await self.invoke(host, horizontal["result"], "setProgress", [.integer(2)])
        _ = try await self.invoke(host, horizontal["result"], "setMax", [.integer(1)])
        let progressClampedAfterMaximumChange = try await self.invoke(host, horizontal["result"], "getProgress")
        XCTAssertEqual(progressClampedAfterMaximumChange["result"], .integer(1))
        _ = try await self.invoke(host, horizontal["result"], "setMax", [.integer(4)])
        _ = try await self.invoke(host, horizontal["result"], "setProgress", [.integer(2)])

        let tint = try await self.invoke(host, self.classTarget("android.content.res.ColorStateList"), "valueOf", [.integer(-65_536)])
        _ = try await self.invoke(host, horizontal["result"], "setProgressTintList", [tint["result"]])
        let wrongTint = try await self.invoke(host, horizontal["result"], "setProgressTintList", [.integer(-65_536)])
        XCTAssertEqual(wrongTint["error"]["code"], .string("UNSUPPORTED_API"))
        let negativeProgress = try await self.invoke(host, horizontal["result"], "setProgress", [.integer(-1)])
        XCTAssertEqual(negativeProgress["error"]["code"], .string("INVALID_ARGUMENTS"))

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 24))
        let attached = XCTestExpectation(description: "progress bar container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachmentResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachmentResult, .completed)
        _ = try await self.invoke(host, horizontal["result"], "setFrame", [.integer(0), .integer(0), .integer(120), .integer(24)])
        _ = try await self.call(host, "ui.mount", arguments: ["target": horizontal["result"]])
        _ = try await self.invoke(host, horizontal["result"], "getHeight")
        let nativeProgress = try XCTUnwrap(container.subviews.first?.subviews.compactMap { $0 as? UIProgressView }.first)
        XCTAssertEqual(nativeProgress.progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(nativeProgress.progressTintColor?.cgColor.components?.first ?? 0, 1, accuracy: 0.001)
        _ = try await self.invoke(host, horizontal["result"], "setVisibility", [.integer(8)])
        _ = try await self.invoke(host, horizontal["result"], "getHeight")
        XCTAssertTrue(container.subviews.first?.isHidden ?? false)
    }

    func testCheckBoxSupportsAuditedTextStateTintAndGenerationBoundListener() async throws {
        let delivered = XCTestExpectation(description: "checked-change callbacks are delivered asynchronously")
        delivered.expectedFulfillmentCount = 2
        let recorded = AyuBridgeTestCallbackBox()
        let contextAdapter = AyuBridgeClassAdapter(name: "android.content.Context", constructor: { args, _ in
            guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Expected no fixture arguments") }
            return [:]
        })
        let registry = try AyuBridgeClassRegistry.standard.adding([contextAdapter])
        let host = self.host(registry: registry, callback: { owner, callbackID, arguments in
            if recorded.store(owner: owner, callbackID: callbackID, arguments: arguments) <= 2 {
                delivered.fulfill()
            }
        })
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", arguments: ["generation": .string("checkbox-generation")])
        let context = try await self.construct(host, "android.content.Context")
        let checkBox = try await self.construct(host, "android.widget.CheckBox", [context["result"]])
        XCTAssertEqual(checkBox["error"], .null)

        let initialChecked = try await self.invoke(host, checkBox["result"], "isChecked")
        XCTAssertEqual(initialChecked["result"], .bool(false))
        _ = try await self.invoke(host, checkBox["result"], "setText", [.string("Remember selection")])
        let text = try await self.invoke(host, checkBox["result"], "getText")
        XCTAssertEqual(text["result"], .string("Remember selection"))
        _ = try await self.invoke(host, checkBox["result"], "setTextSize", [.number(15)])
        _ = try await self.invoke(host, checkBox["result"], "setTextColor", [.integer(-1)])
        _ = try await self.invoke(host, checkBox["result"], "setPadding", [.integer(6), .integer(8), .integer(6), .integer(8)])

        let tint = try await self.invoke(host, self.classTarget("android.content.res.ColorStateList"), "valueOf", [.integer(-65_536)])
        _ = try await self.invoke(host, checkBox["result"], "setButtonTintList", [tint["result"]])
        let wrongTint = try await self.invoke(host, checkBox["result"], "setButtonTintList", [.integer(-65_536)])
        XCTAssertEqual(wrongTint["error"]["code"], .string("UNSUPPORTED_API"))

        let listener = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("android.widget.CompoundButton$OnCheckedChangeListener")]),
            "callbacks": .object(["onCheckedChanged": .object(["$callback": .string("checkbox-changed")])]),
        ])
        XCTAssertEqual(listener["error"], .null)
        _ = try await self.invoke(host, checkBox["result"], "setOnCheckedChangeListener", [listener["result"]])
        _ = try await self.invoke(host, checkBox["result"], "setChecked", [.bool(true)])
        let checked = try await self.invoke(host, checkBox["result"], "isChecked")
        XCTAssertEqual(checked["result"], .bool(true))

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 220, height: 48))
        let attached = XCTestExpectation(description: "checkbox container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachedResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachedResult, .completed)
        _ = try await self.invoke(host, checkBox["result"], "setFrame", [.integer(0), .integer(0), .integer(220), .integer(48)])
        _ = try await self.call(host, "ui.mount", arguments: ["target": checkBox["result"]])
        _ = try await self.invoke(host, checkBox["result"], "getHeight")
        let nativeButton = try XCTUnwrap(container.subviews.first?.subviews.compactMap { $0 as? UIButton }.first)
        XCTAssertEqual(nativeButton.currentTitle, "Remember selection")
        XCTAssertEqual(nativeButton.tintColor?.cgColor.components?.first ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(nativeButton.isSelected)

        nativeButton.sendActions(for: .touchUpInside)
        let unchecked = try await self.invoke(host, checkBox["result"], "isChecked")
        XCTAssertEqual(unchecked["result"], .bool(false))
        XCTAssertFalse(nativeButton.isSelected)

        let deliveredResult = await XCTWaiter.fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(deliveredResult, .completed)
        XCTAssertEqual(recorded.owner, "alpha")
        XCTAssertEqual(recorded.callbackID, "checkbox-changed")
        XCTAssertEqual(recorded.arguments, [checkBox["result"], .bool(false)])

        let unsupportedProgress = try await self.invoke(host, checkBox["result"], "setProgress", [.integer(1)])
        XCTAssertEqual(unsupportedProgress["error"]["code"], .string("UNSUPPORTED_API"))
        let wrongConstructor = try await self.construct(host, "android.widget.CheckBox")
        XCTAssertEqual(wrongConstructor["error"]["code"], .string("UNSUPPORTED_API"))
        let unsupportedCheckedRead = try await self.invoke(host, self.classTarget("android.widget.TextView"), "isChecked")
        XCTAssertEqual(unsupportedCheckedRead["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testViewConfigurationAndAuditedHapticSubsetAreBounded() async throws {
        let contextAdapter = AyuBridgeClassAdapter(name: "android.content.Context", constructor: { args, _ in
            guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Expected no fixture arguments") }
            return [:]
        })
        let registry = try AyuBridgeClassRegistry.standard.adding([contextAdapter])
        let host = self.host(registry: registry)
        try await self.authorize(host)

        let longPress = try await self.call(host, "java.member", arguments: [
            "target": self.classTarget("android.view.HapticFeedbackConstants"),
            "name": .string("LONG_PRESS"),
        ])
        XCTAssertEqual(longPress["result"]["value"], .integer(0))
        let clockTick = try await self.call(host, "java.member", arguments: [
            "target": self.classTarget("android.view.HapticFeedbackConstants"),
            "name": .string("CLOCK_TICK"),
        ])
        XCTAssertEqual(clockTick["result"]["value"], .integer(4))

        let context = try await self.construct(host, "android.content.Context")
        let configuration = try await self.invoke(host, self.classTarget("android.view.ViewConfiguration"), "get", [context["result"]])
        XCTAssertEqual(configuration["error"], .null)
        let touchSlop = try await self.invoke(host, configuration["result"], "getScaledTouchSlop")
        XCTAssertEqual(touchSlop["result"], .integer(8))
        let touchSlopWrongArity = try await self.invoke(host, configuration["result"], "getScaledTouchSlop", [.integer(1)])
        XCTAssertEqual(touchSlopWrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
        let longPressTimeout = try await self.invoke(host, self.classTarget("android.view.ViewConfiguration"), "getLongPressTimeout")
        XCTAssertEqual(longPressTimeout["result"], .integer(500))
        let longPressTimeoutWrongArity = try await self.invoke(host, self.classTarget("android.view.ViewConfiguration"), "getLongPressTimeout", [.integer(1)])
        XCTAssertEqual(longPressTimeoutWrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
        let uri = try await self.invoke(host, self.classTarget("android.net.Uri"), "parse", [.string("https://example.invalid/")])
        let wrongContext = try await self.invoke(host, self.classTarget("android.view.ViewConfiguration"), "get", [uri["result"]])
        XCTAssertEqual(wrongContext["error"]["code"], .string("UNSUPPORTED_API"))
        let unsupportedConfigurationConstructor = try await self.construct(host, "android.view.ViewConfiguration")
        XCTAssertEqual(unsupportedConfigurationConstructor["error"]["code"], .string("UNSUPPORTED_API"))

        let view = try await self.construct(host, "android.widget.FrameLayout")
        let longPressFeedback = try await self.invoke(host, view["result"], "performHapticFeedback", [longPress["result"]["value"]])
        XCTAssertEqual(longPressFeedback["result"], .bool(true))
        let clockTickFeedback = try await self.invoke(host, view["result"], "performHapticFeedback", [clockTick["result"]["value"]])
        XCTAssertEqual(clockTickFeedback["result"], .bool(true))
        let unsupportedFeedback = try await self.invoke(host, view["result"], "performHapticFeedback", [.integer(1)])
        XCTAssertEqual(unsupportedFeedback["error"]["code"], .string("UNSUPPORTED_API"))
        let wrongFeedbackType = try await self.invoke(host, view["result"], "performHapticFeedback", [.string("LONG_PRESS")])
        XCTAssertEqual(wrongFeedbackType["error"]["code"], .string("INVALID_ARGUMENTS"))
        let unsupportedFlagsOverload = try await self.invoke(host, view["result"], "performHapticFeedback", [.integer(0), .integer(0)])
        XCTAssertEqual(unsupportedFlagsOverload["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testSystemClockUptimeMillisRoutesAsBoundedStaticCall() async throws {
        let host = self.host()
        try await self.authorize(host)
        let clock = self.classTarget("android.os.SystemClock")
        let uptime = try await self.invoke(host, clock, "uptimeMillis")
        guard let milliseconds = uptime["result"].integer else {
            return XCTFail("SystemClock.uptimeMillis must return an integer")
        }
        XCTAssertGreaterThanOrEqual(milliseconds, 0)

        let wrongArity = try await self.invoke(host, clock, "uptimeMillis", [.integer(0)])
        XCTAssertEqual(wrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
        let unsupportedMethod = try await self.invoke(host, clock, "elapsedRealtime")
        XCTAssertEqual(unsupportedMethod["error"]["code"], .string("UNSUPPORTED_API"))
        let unsupportedConstructor = try await self.construct(host, "android.os.SystemClock")
        XCTAssertEqual(unsupportedConstructor["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testViewMeasureSpecUsesOnlyStandardSignedThirtyTwoBitEncodings() async throws {
        let host = self.host()
        try await self.authorize(host)
        let target = self.classTarget("android.view.View$MeasureSpec")

        let exactly = try await self.call(host, "java.member", arguments: [
            "target": target, "name": .string("EXACTLY"),
        ])
        XCTAssertEqual(exactly["result"]["value"], .integer(1_073_741_824))
        let atMost = try await self.call(host, "java.member", arguments: [
            "target": target, "name": .string("AT_MOST"),
        ])
        XCTAssertEqual(atMost["result"]["value"], .integer(Int64(Int32.min)))
        let modeMask = try await self.call(host, "java.member", arguments: [
            "target": target, "name": .string("MODE_MASK"),
        ])
        XCTAssertEqual(modeMask["result"]["value"], .integer(-1_073_741_824))

        let exactSpec = try await self.invoke(host, target, "makeMeasureSpec", [.integer(36), exactly["result"]["value"]])
        XCTAssertEqual(exactSpec["result"], .integer(1_073_741_860))
        let exactMode = try await self.invoke(host, target, "getMode", [exactSpec["result"]])
        XCTAssertEqual(exactMode["result"], exactly["result"]["value"])
        let exactSize = try await self.invoke(host, target, "getSize", [exactSpec["result"]])
        XCTAssertEqual(exactSize["result"], .integer(36))

        let atMostSpec = try await self.invoke(host, target, "makeMeasureSpec", [.integer(17), atMost["result"]["value"]])
        XCTAssertEqual(atMostSpec["result"], .integer(-2_147_483_631))
        let atMostMode = try await self.invoke(host, target, "getMode", [atMostSpec["result"]])
        XCTAssertEqual(atMostMode["result"], atMost["result"]["value"])
        let atMostSize = try await self.invoke(host, target, "getSize", [atMostSpec["result"]])
        XCTAssertEqual(atMostSize["result"], .integer(17))

        let negativeSize = try await self.invoke(host, target, "makeMeasureSpec", [.integer(-1), exactly["result"]["value"]])
        XCTAssertEqual(negativeSize["error"]["code"], .string("INVALID_ARGUMENTS"))
        let oversizedSize = try await self.invoke(host, target, "makeMeasureSpec", [.integer(1_073_741_824), exactly["result"]["value"]])
        XCTAssertEqual(oversizedSize["error"]["code"], .string("INVALID_ARGUMENTS"))
        let invalidMode = try await self.invoke(host, target, "makeMeasureSpec", [.integer(1), .integer(-1)])
        XCTAssertEqual(invalidMode["error"]["code"], .string("INVALID_ARGUMENTS"))
        let outOfRangeSpec = try await self.invoke(host, target, "getMode", [.integer(2_147_483_648)])
        XCTAssertEqual(outOfRangeSpec["error"]["code"], .string("INVALID_ARGUMENTS"))
        let unsupportedConstructor = try await self.construct(host, "android.view.View$MeasureSpec")
        XCTAssertEqual(unsupportedConstructor["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testFocusableAndSelectedExposeOnlyBoundedBridgeState() async throws {
        let host = self.host()
        try await self.authorize(host)
        let view = try await self.construct(host, "android.widget.FrameLayout")

        let initialFocusable = try await self.invoke(host, view["result"], "isFocusable")
        XCTAssertEqual(initialFocusable["result"], .bool(false))
        let initialSelected = try await self.invoke(host, view["result"], "isSelected")
        XCTAssertEqual(initialSelected["result"], .bool(false))

        _ = try await self.invoke(host, view["result"], "setFocusable", [.bool(true)])
        let focusable = try await self.invoke(host, view["result"], "isFocusable")
        XCTAssertEqual(focusable["result"], .bool(true))
        _ = try await self.invoke(host, view["result"], "setSelected", [.bool(true)])
        let selected = try await self.invoke(host, view["result"], "isSelected")
        XCTAssertEqual(selected["result"], .bool(true))

        let invalidFocusable = try await self.invoke(host, view["result"], "setFocusable", [.integer(1)])
        XCTAssertEqual(invalidFocusable["error"]["code"], .string("INVALID_ARGUMENTS"))
        let unsupportedFocusQuery = try await self.invoke(host, view["result"], "hasFocus")
        XCTAssertEqual(unsupportedFocusQuery["error"]["code"], .string("UNSUPPORTED_API"))
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

    func testViewPostUsesOrderedAsynchronousRunnableCallbacksAndValidatesOverloads() async throws {
        let delivered = XCTestExpectation(description: "View Runnable callbacks delivered in posting order")
        delivered.expectedFulfillmentCount = 2
        let order = AyuBridgeTestCallbackOrderBox()
        let host = self.host(callback: { _, callbackID, _ in
            order.append(callbackID)
            delivered.fulfill()
        })
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", arguments: ["generation": .string("view-post-generation")])

        let first = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("java.lang.Runnable")]),
            "callbacks": .object(["run": .object(["$callback": .string("view-post-first")])]),
        ])
        let second = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("java.lang.Runnable")]),
            "callbacks": .object(["run": .object(["$callback": .string("view-post-second")])]),
        ])
        let view = try await self.construct(host, "android.widget.FrameLayout")

        let missingRunnable = try await self.invoke(host, view["result"], "post")
        XCTAssertEqual(missingRunnable["error"]["code"], .string("INVALID_ARGUMENTS"))
        let missingDelay = try await self.invoke(host, view["result"], "postDelayed", [first["result"]])
        XCTAssertEqual(missingDelay["error"]["code"], .string("INVALID_ARGUMENTS"))
        let negativeDelay = try await self.invoke(host, view["result"], "postDelayed", [first["result"], .integer(-1)])
        XCTAssertEqual(negativeDelay["error"]["code"], .string("INVALID_ARGUMENTS"))
        let excessiveDelay = try await self.invoke(host, view["result"], "postDelayed", [first["result"], .integer(60_001)])
        XCTAssertEqual(excessiveDelay["error"]["code"], .string("INVALID_ARGUMENTS"))

        let posted = try await self.invoke(host, view["result"], "post", [first["result"]])
        XCTAssertEqual(posted["result"], .bool(true))
        let delayed = try await self.invoke(host, view["result"], "postDelayed", [second["result"], .integer(5)])
        XCTAssertEqual(delayed["result"], .bool(true))
        let waitResult = await XCTWaiter.fulfillment(of: [delivered], timeout: 1.0)
        XCTAssertEqual(waitResult, .completed)
        XCTAssertEqual(order.values, ["view-post-first", "view-post-second"])
    }

    func testViewPostDelayedCallbackIsRevokedOnGenerationUnload() async throws {
        let callback = XCTestExpectation(description: "unloaded View callback must not run")
        callback.isInverted = true
        var limits = AyuPluginBridgeLimits()
        limits.callbacksPerPlugin = 1
        let host = self.host(limits: limits, callback: { _, _, _ in callback.fulfill() })
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", arguments: ["generation": .string("view-post-old-generation")])
        let runnable = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("java.lang.Runnable")]),
            "callbacks": .object(["run": .object(["$callback": .string("view-post-stale")])]),
        ])
        let view = try await self.construct(host, "android.widget.TextView")
        let scheduled = try await self.invoke(host, view["result"], "postDelayed", [runnable["result"], .integer(60_000)])
        XCTAssertEqual(scheduled["result"], .bool(true))
        let overLimit = try await self.invoke(host, view["result"], "post", [runnable["result"]])
        XCTAssertEqual(overLimit["error"]["code"], .string("RESOURCE_LIMIT"))

        _ = try await self.call(host, "plugin.deactivate", arguments: ["generation": .string("view-post-old-generation")])
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", arguments: ["generation": .string("view-post-new-generation")])
        let waitResult = await XCTWaiter.fulfillment(of: [callback], timeout: 0.1)
        XCTAssertEqual(waitResult, .completed)
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

    func testTextWatcherReceivesBoundedUTF16EditsAndCanBeRemoved() async throws {
        let delivered = XCTestExpectation(description: "TextWatcher callbacks are delivered asynchronously")
        delivered.expectedFulfillmentCount = 6
        let recorded = AyuBridgeTestTextWatcherBox()
        let host = self.host(callback: { _, callbackID, arguments in
            recorded.append(callbackID: callbackID, arguments: arguments)
            if recorded.count <= 6 { delivered.fulfill() }
        })
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", arguments: ["generation": .string("watcher-generation")])

        let editText = try await self.construct(host, "android.widget.EditText")
        _ = try await self.invoke(host, editText["result"], "setText", [.string("A😀B")])
        let watcher = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("android.text.TextWatcher")]),
            "callbacks": .object([
                "beforeTextChanged": .object(["$callback": .string("watcher-before")]),
                "onTextChanged": .object(["$callback": .string("watcher-changed")]),
                "afterTextChanged": .object(["$callback": .string("watcher-after")]),
            ]),
        ])
        let secondWatcher = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("android.text.TextWatcher")]),
            "callbacks": .object([
                "beforeTextChanged": .object(["$callback": .string("second-before")]),
                "onTextChanged": .object(["$callback": .string("second-changed")]),
                "afterTextChanged": .object(["$callback": .string("second-after")]),
            ]),
        ])
        let add = try await self.invoke(host, editText["result"], "addTextChangedListener", [watcher["result"]])
        XCTAssertEqual(add["error"], .null)
        let addSecond = try await self.invoke(host, editText["result"], "addTextChangedListener", [secondWatcher["result"]])
        XCTAssertEqual(addSecond["error"], .null)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 48))
        let attached = XCTestExpectation(description: "TextWatcher field mounted")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachedResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachedResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": editText["result"]])
        _ = try await self.invoke(host, editText["result"], "getText")
        let field = try XCTUnwrap(container.subviews.first?.subviews.compactMap { $0 as? UITextField }.first)
        field.text = "A😺B"
        field.sendActions(for: .editingChanged)

        let deliveredResult = await XCTWaiter.fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(deliveredResult, .completed)
        XCTAssertEqual(recorded.arguments(for: "watcher-before"), [.string("A😀B"), .integer(1), .integer(2), .integer(2)])
        XCTAssertEqual(recorded.arguments(for: "watcher-changed"), [.string("A😺B"), .integer(1), .integer(2), .integer(2)])
        XCTAssertEqual(recorded.arguments(for: "watcher-after"), [.string("A😺B")])
        XCTAssertEqual(recorded.callbackIDs, [
            "watcher-before", "second-before", "watcher-changed", "second-changed", "watcher-after", "second-after",
        ])

        let prematureRelease = try await self.call(host, "java.release", arguments: ["target": watcher["result"]])
        XCTAssertEqual(prematureRelease["error"]["code"], .string("INVALID_STATE"))
        let remove = try await self.invoke(host, editText["result"], "removeTextChangedListener", [watcher["result"]])
        XCTAssertEqual(remove["error"], .null)
        _ = try await self.invoke(host, editText["result"], "getText") // flush listener removal
        let released = try await self.call(host, "java.release", arguments: ["target": watcher["result"]])
        XCTAssertEqual(released["result"], .null)
        let afterRemoval = XCTestExpectation(description: "remaining watcher continues after peer removal")
        afterRemoval.expectedFulfillmentCount = 3
        recorded.setOnAppend { afterRemoval.fulfill() }
        field.text = "A😺B!"
        field.sendActions(for: .editingChanged)
        let afterRemovalResult = await XCTWaiter.fulfillment(of: [afterRemoval], timeout: 1)
        XCTAssertEqual(afterRemovalResult, .completed)
        XCTAssertEqual(Array(recorded.callbackIDs.suffix(3)), ["second-before", "second-changed", "second-after"])
        let removeSecond = try await self.invoke(host, editText["result"], "removeTextChangedListener", [secondWatcher["result"]])
        XCTAssertEqual(removeSecond["error"], .null)
        _ = try await self.invoke(host, editText["result"], "getText")
        let releaseSecond = try await self.call(host, "java.release", arguments: ["target": secondWatcher["result"]])
        XCTAssertEqual(releaseSecond["result"], .null)
    }

    func testViewContentDescriptionIsBoundedAndCanBeCleared() async throws {
        let host = self.host()
        try await self.authorize(host)
        let imageView = try await self.construct(host, "android.widget.ImageView")
        let description = try await self.invoke(host, imageView["result"], "setContentDescription", [.string("Open attachment")])
        XCTAssertEqual(description["error"], .null)
        let read = try await self.invoke(host, imageView["result"], "getContentDescription")
        XCTAssertEqual(read["result"], .string("Open attachment"))

        let cleared = try await self.invoke(host, imageView["result"], "setContentDescription", [.null])
        XCTAssertEqual(cleared["error"], .null)
        let readCleared = try await self.invoke(host, imageView["result"], "getContentDescription")
        XCTAssertEqual(readCleared["result"], .null)

        let unsupportedOverload = try await self.invoke(host, imageView["result"], "setContentDescription", [.string("one"), .string("two")])
        XCTAssertEqual(unsupportedOverload["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testImageViewColorFilterSupportsOnlySRCINAndClear() async throws {
        let host = self.host()
        try await self.authorize(host)
        let image = try await self.construct(host, "android.widget.ImageView")
        let tint = try await self.invoke(host, image["result"], "setColorFilter", [.integer(-1)])
        XCTAssertEqual(tint["error"], .null)

        let filter = try await self.invoke(host, image["result"], "getColorFilter")
        XCTAssertEqual(filter["result"]["$class"], .string("android.graphics.PorterDuffColorFilter"))
        let filterColor = try await self.invoke(host, filter["result"], "getColor")
        XCTAssertEqual(filterColor["result"], .integer(-1))
        let filterMode = try await self.invoke(host, filter["result"], "getMode")
        XCTAssertEqual(filterMode["result"]["$class"], .string("android.graphics.PorterDuff$Mode"))

        let modes = self.classTarget("android.graphics.PorterDuff$Mode")
        let srcIn = try await self.call(host, "java.member", arguments: ["target": modes, "name": .string("SRC_IN")])
        let twoArgumentTint = try await self.invoke(host, image["result"], "setColorFilter", [.integer(0xFF00_FF00), srcIn["result"]["value"]])
        XCTAssertEqual(twoArgumentTint["error"], .null)
        let twoArgumentFilter = try await self.invoke(host, image["result"], "getColorFilter")
        let twoArgumentColor = try await self.invoke(host, twoArgumentFilter["result"], "getColor")
        XCTAssertEqual(twoArgumentColor["result"], .integer(0xFF00_FF00))

        let constructed = try await self.call(host, "java.construct", arguments: [
            "class_name": .string("android.graphics.PorterDuffColorFilter"),
            "args": .array([.integer(0xFFFF_0000), srcIn["result"]["value"]]),
        ])
        XCTAssertEqual(constructed["result"]["$class"], .string("android.graphics.PorterDuffColorFilter"))
        let objectTint = try await self.invoke(host, image["result"], "setColorFilter", [constructed["result"]])
        XCTAssertEqual(objectTint["error"], .null)
        let objectFilter = try await self.invoke(host, image["result"], "getColorFilter")
        let objectColor = try await self.invoke(host, objectFilter["result"], "getColor")
        XCTAssertEqual(objectColor["result"], .integer(0xFFFF_0000))

        let clear = try await self.invoke(host, image["result"], "clearColorFilter")
        XCTAssertEqual(clear["error"], .null)
        let clearedFilter = try await self.invoke(host, image["result"], "getColorFilter")
        XCTAssertEqual(clearedFilter["result"], .null)

        let wrongClass = try await self.invoke(host, image["result"], "setColorFilter", [.string("not a filter")])
        XCTAssertEqual(wrongClass["error"]["code"], .string("INVALID_HANDLE"))
        let unsupported = try await self.invoke(host, image["result"], "setColorFilter", [.integer(Int64(UInt32.max) + 1)])
        XCTAssertEqual(unsupported["error"]["code"], .string("INVALID_ARGUMENTS"))
        let paintStyles = self.classTarget("android.graphics.Paint$Style")
        let wrongMode = try await self.call(host, "java.member", arguments: ["target": paintStyles, "name": .string("FILL")])
        let unsupportedMode = try await self.invoke(host, image["result"], "setColorFilter", [.integer(-1), wrongMode["result"]["value"]])
        XCTAssertEqual(unsupportedMode["error"]["code"], .string("UNSUPPORTED_API"))
        let wrongArity = try await self.invoke(host, image["result"], "setColorFilter", [.integer(-1), srcIn["result"]["value"], .integer(0)])
        XCTAssertEqual(wrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testImageButtonUsesBoundedImageViewSubsetAndRetainsType() async throws {
        let host = self.host()
        try await self.authorize(host)
        let button = try await self.construct(host, "android.widget.ImageButton")
        XCTAssertEqual(button["result"]["$class"], .string("android.widget.ImageButton"))

        let asImageView = try await self.call(host, "java.cast", arguments: [
            "class_name": .string("android.widget.ImageView"), "value": button["result"],
        ])
        XCTAssertEqual(asImageView["result"], button["result"])
        let asTextView = try await self.call(host, "java.cast", arguments: [
            "class_name": .string("android.widget.TextView"), "value": button["result"],
        ])
        XCTAssertEqual(asTextView["error"]["code"], .string("UNSUPPORTED_API"))

        let scaleClass = self.classTarget("android.widget.ImageView$ScaleType")
        let centerInside = try await self.call(host, "java.member", arguments: ["target": scaleClass, "name": .string("CENTER_INSIDE")])
        let setScale = try await self.invoke(host, button["result"], "setScaleType", [centerInside["result"]["value"]])
        XCTAssertEqual(setScale["error"], .null)
        let setTint = try await self.invoke(host, button["result"], "setColorFilter", [.integer(-1)])
        XCTAssertEqual(setTint["error"], .null)
        let clearImage = try await self.invoke(host, button["result"], "setImageResource", [.integer(0)])
        XCTAssertEqual(clearImage["error"], .null)
        let wrongMember = try await self.invoke(host, button["result"], "setText", [.string("not a text widget")])
        XCTAssertEqual(wrongMember["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testEditTextFocusSubsetFailsClosedUntilAttachedAndEnabled() async throws {
        let host = self.host()
        try await self.authorize(host)
        let editText = try await self.construct(host, "android.widget.EditText")

        let initiallyFocused = try await self.invoke(host, editText["result"], "hasFocus")
        XCTAssertEqual(initiallyFocused["result"], .bool(false))
        let detachedRequest = try await self.invoke(host, editText["result"], "requestFocus")
        XCTAssertEqual(detachedRequest["result"], .bool(false))
        let clear = try await self.invoke(host, editText["result"], "clearFocus")
        XCTAssertEqual(clear["error"], .null)
        let afterClear = try await self.invoke(host, editText["result"], "hasFocus")
        XCTAssertEqual(afterClear["result"], .bool(false))

        let textView = try await self.construct(host, "android.widget.TextView")
        let unsupported = try await self.invoke(host, textView["result"], "requestFocus")
        XCTAssertEqual(unsupported["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testEditTextSelectionUsesBoundedUTF16Offsets() async throws {
        let host = self.host()
        try await self.authorize(host)
        let editText = try await self.construct(host, "android.widget.EditText")
        _ = try await self.invoke(host, editText["result"], "setText", [.string("A😀B")])

        let end = try await self.invoke(host, editText["result"], "setSelection", [.integer(4)])
        XCTAssertEqual(end["error"], .null)
        let selectionStart = try await self.invoke(host, editText["result"], "getSelectionStart")
        let selectionEnd = try await self.invoke(host, editText["result"], "getSelectionEnd")
        XCTAssertEqual(selectionStart["result"], .integer(4))
        XCTAssertEqual(selectionEnd["result"], .integer(4))

        let beforeEmoji = try await self.invoke(host, editText["result"], "setSelection", [.integer(1)])
        XCTAssertEqual(beforeEmoji["error"], .null)
        let movedStart = try await self.invoke(host, editText["result"], "getSelectionStart")
        XCTAssertEqual(movedStart["result"], .integer(1))

        let negative = try await self.invoke(host, editText["result"], "setSelection", [.integer(-1)])
        XCTAssertEqual(negative["error"]["code"], .string("INVALID_ARGUMENTS"))
        let beyondEnd = try await self.invoke(host, editText["result"], "setSelection", [.integer(5)])
        XCTAssertEqual(beyondEnd["error"]["code"], .string("INVALID_ARGUMENTS"))
        let unsupportedTextView = try await self.construct(host, "android.widget.TextView")
        let unsupportedSelection = try await self.invoke(host, unsupportedTextView["result"], "setSelection", [.integer(0)])
        XCTAssertEqual(unsupportedSelection["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testViewParentAndChildOrderQueriesUseOwnedHandles() async throws {
        let host = self.host()
        try await self.authorize(host)
        let parent = try await self.construct(host, "android.widget.FrameLayout")
        let first = try await self.construct(host, "android.widget.TextView")
        let second = try await self.construct(host, "android.widget.TextView")
        let inserted = try await self.construct(host, "android.widget.EditText")

        _ = try await self.invoke(host, parent["result"], "addView", [first["result"]])
        _ = try await self.invoke(host, parent["result"], "addView", [second["result"]])
        _ = try await self.invoke(host, parent["result"], "addView", [inserted["result"], .integer(1)])

        let count = try await self.invoke(host, parent["result"], "getChildCount")
        XCTAssertEqual(count["result"], .integer(3))
        let firstChild = try await self.invoke(host, parent["result"], "getChildAt", [.integer(0)])
        let insertedChild = try await self.invoke(host, parent["result"], "getChildAt", [.integer(1)])
        let lastChild = try await self.invoke(host, parent["result"], "getChildAt", [.integer(2)])
        XCTAssertEqual(firstChild["result"]["$handle"], first["result"]["$handle"])
        XCTAssertEqual(insertedChild["result"]["$handle"], inserted["result"]["$handle"])
        XCTAssertEqual(lastChild["result"]["$handle"], second["result"]["$handle"])
        let outOfRange = try await self.invoke(host, parent["result"], "getChildAt", [.integer(3)])
        XCTAssertEqual(outOfRange["result"], .null)

        let childParent = try await self.invoke(host, inserted["result"], "getParent")
        XCTAssertEqual(childParent["result"]["$handle"], parent["result"]["$handle"])
        let typedParent = try await self.call(host, "java.cast", arguments: [
            "class_name": .string("android.view.ViewParent"), "value": childParent["result"],
        ])
        XCTAssertEqual(typedParent["result"]["$handle"], parent["result"]["$handle"])

        _ = try await self.invoke(host, parent["result"], "removeView", [inserted["result"]])
        let detachedParent = try await self.invoke(host, inserted["result"], "getParent")
        XCTAssertEqual(detachedParent["result"], .null)
        let clear = try await self.invoke(host, parent["result"], "removeAllViews")
        XCTAssertEqual(clear["error"], .null)
        let emptyCount = try await self.invoke(host, parent["result"], "getChildCount")
        XCTAssertEqual(emptyCount["result"], .integer(0))
        let rootParent = try await self.invoke(host, parent["result"], "getParent")
        XCTAssertEqual(rootParent["result"], .null)
    }

    func testViewReleaseAndBringToFrontKeepHierarchyQueriesConsistent() async throws {
        let host = self.host()
        try await self.authorize(host)
        let parent = try await self.construct(host, "android.widget.FrameLayout")
        let first = try await self.construct(host, "android.widget.TextView")
        let second = try await self.construct(host, "android.widget.TextView")
        _ = try await self.invoke(host, parent["result"], "addView", [first["result"]])
        _ = try await self.invoke(host, parent["result"], "addView", [second["result"]])

        _ = try await self.invoke(host, first["result"], "bringToFront")
        let front = try await self.invoke(host, parent["result"], "getChildAt", [.integer(1)])
        XCTAssertEqual(front["result"]["$handle"], first["result"]["$handle"])

        let release = try await self.call(host, "java.release", arguments: ["target": second["result"]])
        XCTAssertEqual(release["error"], .null)
        let count = try await self.invoke(host, parent["result"], "getChildCount")
        XCTAssertEqual(count["result"], .integer(1))
        let remaining = try await self.invoke(host, parent["result"], "getChildAt", [.integer(0)])
        XCTAssertEqual(remaining["result"]["$handle"], first["result"]["$handle"])

        _ = try await self.invoke(host, first["result"], "unmount")
        let unmountedCount = try await self.invoke(host, parent["result"], "getChildCount")
        XCTAssertEqual(unmountedCount["result"], .integer(0))
        let noParent = try await self.invoke(host, first["result"], "getParent")
        XCTAssertEqual(noParent["result"], .null)
    }

    func testViewAttachmentAndPaddingQueriesAreBoundedSnapshots() async throws {
        let host = self.host()
        try await self.authorize(host)
        let view = try await self.construct(host, "android.view.View")
        _ = try await self.invoke(host, view["result"], "setPadding", [.integer(3), .integer(5), .integer(7), .integer(11)])
        let left = try await self.invoke(host, view["result"], "getPaddingLeft")
        let top = try await self.invoke(host, view["result"], "getPaddingTop")
        let right = try await self.invoke(host, view["result"], "getPaddingRight")
        let bottom = try await self.invoke(host, view["result"], "getPaddingBottom")
        XCTAssertEqual(left["result"], .number(3))
        XCTAssertEqual(top["result"], .number(5))
        XCTAssertEqual(right["result"], .number(7))
        XCTAssertEqual(bottom["result"], .number(11))
        let attached = try await self.invoke(host, view["result"], "isAttachedToWindow")
        XCTAssertEqual(attached["result"], .bool(false))
        let wrongArity = try await self.invoke(host, view["result"], "isAttachedToWindow", [.bool(true)])
        XCTAssertEqual(wrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testLayoutParamsReadbackIsOwnedAndPreservesDeclaredSubtype() async throws {
        let host = self.host()
        try await self.authorize(host)
        let parent = try await self.construct(host, "android.widget.FrameLayout")
        let child = try await self.construct(host, "android.widget.TextView")
        let missing = try await self.invoke(host, child["result"], "getLayoutParams")
        XCTAssertEqual(missing["result"], .null)

        let params = try await self.construct(host, "android.widget.FrameLayout$LayoutParams", [.integer(-1), .integer(48)])
        _ = try await self.invoke(host, params["result"], "setMargins", [.integer(2), .integer(3), .integer(4), .integer(5)])
        _ = try await self.invoke(host, child["result"], "setLayoutParams", [params["result"]])
        let readback = try await self.invoke(host, child["result"], "getLayoutParams")
        XCTAssertEqual(readback["result"]["$class"], .string("android.widget.FrameLayout$LayoutParams"))
        XCTAssertEqual(readback["result"]["$handle"], params["result"]["$handle"], "A live assigned layout object preserves its owned identity")
        let width = try await self.call(host, "java.get_field", arguments: ["target": readback["result"], "name": .string("width")])
        XCTAssertEqual(width["result"], .number(-1))

        _ = try await self.invoke(host, parent["result"], "addView", [child["result"], params["result"]])
        let insertedParams = try await self.invoke(host, child["result"], "getLayoutParams")
        XCTAssertEqual(insertedParams["result"]["$class"], .string("android.widget.FrameLayout$LayoutParams"))
        XCTAssertEqual(insertedParams["result"]["$handle"], params["result"]["$handle"])
        let wrongArity = try await self.invoke(host, child["result"], "getLayoutParams", [.integer(0)])
        XCTAssertEqual(wrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testViewMinimumHeightClickableAndRequestLayoutUseBoundedNativeState() async throws {
        let host = self.host()
        try await self.authorize(host)
        let parent = try await self.construct(host, "android.widget.FrameLayout")
        let child = try await self.construct(host, "android.widget.TextView")
        _ = try await self.invoke(host, child["result"], "setText", [.string("row")])
        let params = try await self.construct(host, "android.widget.FrameLayout$LayoutParams", [.integer(-2), .integer(-2)])
        _ = try await self.invoke(host, parent["result"], "addView", [child["result"], params["result"]])
        _ = try await self.invoke(host, child["result"], "setId", [.integer(42)])
        _ = try await self.invoke(host, child["result"], "setMinimumWidth", [.integer(72)])
        _ = try await self.invoke(host, child["result"], "setMinimumHeight", [.integer(52)])
        _ = try await self.invoke(host, child["result"], "setClickable", [.bool(true)])
        _ = try await self.invoke(host, child["result"], "requestLayout")
        _ = try await self.invoke(host, child["result"], "invalidate")
        let invalidationArity = try await self.invoke(host, child["result"], "invalidate", [.integer(0)])
        XCTAssertEqual(invalidationArity["error"]["code"], .string("INVALID_ARGUMENTS"))

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 180, height: 100))
        let attached = XCTestExpectation(description: "layout API test container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachedResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1.0)
        XCTAssertEqual(attachedResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": parent["result"]])
        let identifier = try await self.invoke(host, child["result"], "getId")
        XCTAssertEqual(identifier["result"], .integer(42))
        let minimumWidth = try await self.invoke(host, child["result"], "getMinimumWidth")
        XCTAssertEqual(minimumWidth["result"], .integer(72))
        let minimumHeight = try await self.invoke(host, child["result"], "getMinimumHeight")
        XCTAssertEqual(minimumHeight["result"], .integer(52))
        let clickable = try await self.invoke(host, child["result"], "isClickable")
        XCTAssertEqual(clickable["result"], .bool(true))
        let scaleX = try await self.invoke(host, child["result"], "getScaleX")
        XCTAssertEqual(scaleX["result"], .number(1))
        let scaleY = try await self.invoke(host, child["result"], "getScaleY")
        XCTAssertEqual(scaleY["result"], .number(1))
        _ = try await self.invoke(host, child["result"], "setElevation", [.number(8)])
        let elevation = try await self.invoke(host, child["result"], "getElevation")
        XCTAssertEqual(elevation["result"], .number(8))
        let shown = try await self.invoke(host, child["result"], "isShown")
        XCTAssertEqual(shown["result"], .bool(true))
        let height = try await self.invoke(host, child["result"], "getHeight")
        XCTAssertEqual(height["result"], .number(52))

        _ = try await self.call(host, "java.set_field", arguments: [
            "target": params["result"], "name": .string("height"), "value": .integer(70),
        ])
        let changedHeight = try await self.invoke(host, child["result"], "getHeight")
        XCTAssertEqual(changedHeight["result"], .number(70))
        _ = try await self.call(host, "java.set_field", arguments: [
            "target": params["result"], "name": .string("height"), "value": .integer(-2),
        ])
        let restoredHeight = try await self.invoke(host, child["result"], "getHeight")
        XCTAssertEqual(restoredHeight["result"], .number(52))
        let nativeParent = try XCTUnwrap(container.subviews.first)
        let nativeChild = try XCTUnwrap(nativeParent.subviews.first)
        XCTAssertEqual(nativeChild.layer.zPosition, 8)
        let clipping = try await self.invoke(host, parent["result"], "setClipChildren", [.bool(true)])
        XCTAssertEqual(clipping["error"], .null)
        _ = try await self.invoke(host, parent["result"], "getHeight")
        XCTAssertTrue(nativeParent.clipsToBounds)
        let clipState = try await self.invoke(host, parent["result"], "getClipChildren")
        XCTAssertEqual(clipState["result"], .bool(true))
        _ = try await self.invoke(host, parent["result"], "setClipChildren", [.bool(false)])
        _ = try await self.invoke(host, parent["result"], "getHeight")
        XCTAssertFalse(nativeParent.clipsToBounds)
        let invalidElevation = try await self.invoke(host, child["result"], "setElevation", [.number(-0.5)])
        XCTAssertEqual(invalidElevation["error"]["code"], .string("INVALID_ARGUMENTS"))
        let invalidClipType = try await self.invoke(host, child["result"], "setClipChildren", [.bool(false)])
        XCTAssertEqual(invalidClipType["error"]["code"], .string("UNSUPPORTED_API"))
        XCTAssertGreaterThanOrEqual(nativeChild.sizeThatFits(CGSize(width: 160, height: 80)).width, 72)
        XCTAssertEqual(nativeChild.sizeThatFits(CGSize(width: 160, height: 80)).height, 52)
        XCTAssertTrue(nativeChild.gestureRecognizers?.isEmpty ?? true, "Clickability alone does not install a callback recognizer")

        let proxy = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("android.view.View$OnClickListener")]),
            "callbacks": .object(["onClick": .object(["$callback": .string("minimum-height-click")])]),
        ])
        _ = try await self.invoke(host, child["result"], "setOnClickListener", [proxy["result"]])
        _ = try await self.invoke(host, child["result"], "getHeight")
        let clickRecognizer = try XCTUnwrap(nativeChild.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first)
        XCTAssertTrue(clickRecognizer.isEnabled)

        _ = try await self.invoke(host, child["result"], "setClickable", [.bool(false)])
        _ = try await self.invoke(host, child["result"], "requestLayout")
        let noLongerClickable = try await self.invoke(host, child["result"], "isClickable")
        XCTAssertEqual(noLongerClickable["result"], .bool(false))
        let clickedState = try await self.invoke(host, child["result"], "getHeight")
        XCTAssertEqual(clickedState["result"], .number(52))
        XCTAssertFalse(clickRecognizer.isEnabled)

        let badClickable = try await self.invoke(host, child["result"], "setClickable", [.integer(1)])
        XCTAssertEqual(badClickable["error"]["code"], .string("INVALID_ARGUMENTS"))
        let badMinimum = try await self.invoke(host, child["result"], "setMinimumHeight", [.integer(-1)])
        XCTAssertEqual(badMinimum["error"]["code"], .string("INVALID_ARGUMENTS"))
        let badWidth = try await self.invoke(host, child["result"], "setMinimumWidth", [.integer(100_001)])
        XCTAssertEqual(badWidth["error"]["code"], .string("INVALID_ARGUMENTS"))
        let badID = try await self.invoke(host, child["result"], "setId", [.integer(Int64(Int32.max) + 1)])
        XCTAssertEqual(badID["error"]["code"], .string("INVALID_ARGUMENTS"))
        _ = try await self.invoke(host, child["result"], "setVisibility", [.integer(4)])
        let invisible = try await self.invoke(host, child["result"], "isShown")
        XCTAssertEqual(invisible["result"], .bool(false))
        _ = try await self.invoke(host, child["result"], "setVisibility", [.integer(0)])
        _ = try await self.invoke(host, child["result"], "setRotation", [.number(45)])
        let rotation = try await self.invoke(host, child["result"], "getRotation")
        XCTAssertEqual(rotation["result"], .number(45))
        XCTAssertEqual(atan2(nativeChild.transform.b, nativeChild.transform.a), .pi / 4, accuracy: 0.001)
        let invalidRotation = try await self.invoke(host, child["result"], "setRotation", [.number(360_001)])
        XCTAssertEqual(invalidRotation["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testViewRootAndDefaultTagAccessAreOwnerScopedAndBounded() async throws {
        let host = self.host()
        try await self.authorize(host)
        let root = try await self.construct(host, "android.widget.FrameLayout")
        let child = try await self.construct(host, "android.widget.LinearLayout")
        let leaf = try await self.construct(host, "android.widget.TextView")
        _ = try await self.invoke(host, root["result"], "addView", [child["result"]])
        _ = try await self.invoke(host, child["result"], "addView", [leaf["result"]])
        _ = try await self.invoke(host, root["result"], "setId", [.integer(100)])
        _ = try await self.invoke(host, child["result"], "setId", [.integer(200)])
        _ = try await self.invoke(host, leaf["result"], "setId", [.integer(300)])

        let rootOfLeaf = try await self.invoke(host, leaf["result"], "getRootView")
        XCTAssertEqual(rootOfLeaf["result"]["$handle"], root["result"]["$handle"])
        XCTAssertEqual(rootOfLeaf["result"]["$class"], .string("android.widget.FrameLayout"))
        let rootOfDetached = try await self.invoke(host, root["result"], "getRootView")
        XCTAssertEqual(rootOfDetached["result"], root["result"])
        let foundChild = try await self.invoke(host, root["result"], "findViewById", [.integer(200)])
        XCTAssertEqual(foundChild["result"]["$handle"], child["result"]["$handle"])
        let foundSelf = try await self.invoke(host, leaf["result"], "findViewById", [.integer(300)])
        XCTAssertEqual(foundSelf["result"]["$handle"], leaf["result"]["$handle"])
        let missingView = try await self.invoke(host, root["result"], "findViewById", [.integer(999)])
        XCTAssertEqual(missingView["result"], .null)
        let invalidLookup = try await self.invoke(host, root["result"], "findViewById", [.integer(Int64(Int32.max) + 1)])
        XCTAssertEqual(invalidLookup["error"]["code"], .string("INVALID_ARGUMENTS"))

        let absentTag = try await self.invoke(host, leaf["result"], "getTag")
        XCTAssertEqual(absentTag["result"], .null)
        let setStringTag = try await self.invoke(host, leaf["result"], "setTag", [.string("cached-entry")])
        XCTAssertEqual(setStringTag["result"], .null)
        let stringTag = try await self.invoke(host, leaf["result"], "getTag")
        XCTAssertEqual(stringTag["result"], .string("cached-entry"))

        let javaString = try await self.construct(host, "java.lang.String", [.string("owned-tag")])
        _ = try await self.invoke(host, leaf["result"], "setTag", [javaString["result"]])
        let objectTag = try await self.invoke(host, leaf["result"], "getTag")
        XCTAssertEqual(objectTag["result"], javaString["result"])
        let objectValue = try await self.invoke(host, objectTag["result"], "toString")
        XCTAssertEqual(objectValue["result"], .string("owned-tag"))

        let wrongArity = try await self.invoke(host, leaf["result"], "setTag", [.string("key"), .string("value")])
        XCTAssertEqual(wrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
        let unsupportedValue = try await self.invoke(host, leaf["result"], "setTag", [.array([.integer(1)])])
        XCTAssertEqual(unsupportedValue["error"]["code"], .string("INVALID_ARGUMENTS"))
        let callbackTag = try await self.invoke(host, leaf["result"], "setTag", [.object(["$callback": .string("view-tag-callback")])])
        XCTAssertEqual(callbackTag["error"]["code"], .string("INVALID_ARGUMENTS"))
        let runnable = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("java.lang.Runnable")]),
            "callbacks": .object(["run": .object(["$callback": .string("view-tag-runnable")])]),
        ])
        let callbackProxyTag = try await self.invoke(host, leaf["result"], "setTag", [runnable["result"]])
        XCTAssertEqual(callbackProxyTag["error"]["code"], .string("INVALID_ARGUMENTS"))
        let tooLong = try await self.invoke(host, leaf["result"], "setTag", [.string(String(repeating: "x", count: 65_537))])
        XCTAssertEqual(tooLong["error"]["code"], .string("RESOURCE_LIMIT"))

        _ = try await self.invoke(host, leaf["result"], "setTag", [.null])
        let clearedTag = try await self.invoke(host, leaf["result"], "getTag")
        XCTAssertEqual(clearedTag["result"], .null)

        try await self.authorize(host, owner: "bravo")
        let foreignTag = try await self.construct(host, "java.lang.String", [.string("foreign")], owner: "bravo")
        let rejectedForeignTag = try await self.invoke(host, leaf["result"], "setTag", [foreignTag["result"]])
        XCTAssertEqual(rejectedForeignTag["error"]["code"], .string("INVALID_HANDLE"))
    }

    func testViewBackgroundAcceptsOwnedColorDrawableOnly() async throws {
        let host = self.host()
        try await self.authorize(host)
        let textView = try await self.construct(host, "android.widget.TextView")
        let colorDrawable = try await self.construct(host, "android.graphics.drawable.ColorDrawable", [.integer(-16_777_216)])
        let applied = try await self.invoke(host, textView["result"], "setBackground", [colorDrawable["result"]])
        XCTAssertEqual(applied["result"], .null)

        let wrongDrawable = try await self.construct(host, "android.content.Intent")
        let unsupported = try await self.invoke(host, textView["result"], "setBackground", [wrongDrawable["result"]])
        XCTAssertEqual(unsupported["error"]["code"], .string("UNSUPPORTED_API"))

        let cleared = try await self.invoke(host, textView["result"], "setBackground", [.null])
        XCTAssertEqual(cleared["result"], .null)
    }

    func testViewBackgroundAcceptsSolidGradientDrawableSubset() async throws {
        let host = self.host()
        try await self.authorize(host)
        let textView = try await self.construct(host, "android.widget.TextView")
        let gradient = try await self.construct(host, "android.graphics.drawable.GradientDrawable")
        let setColor = try await self.invoke(host, gradient["result"], "setColor", [.integer(-65_536)])
        XCTAssertEqual(setColor["result"], gradient["result"])
        let setCornerRadius = try await self.invoke(host, gradient["result"], "setCornerRadius", [.number(12.5)])
        XCTAssertEqual(setCornerRadius["result"], gradient["result"])
        let setStroke = try await self.invoke(host, gradient["result"], "setStroke", [.integer(2), .integer(-1)])
        XCTAssertEqual(setStroke["result"], gradient["result"])
        let setBackground = try await self.invoke(host, textView["result"], "setBackground", [gradient["result"]])
        XCTAssertEqual(setBackground["result"], .null)

        let unsupportedShape = try await self.invoke(host, gradient["result"], "setShape", [.integer(2)])
        XCTAssertEqual(unsupportedShape["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testClipToOutlineTracksSupportedBackgroundShapeAndCanBeDisabled() async throws {
        let host = self.host()
        try await self.authorize(host)
        let parent = try await self.construct(host, "android.widget.FrameLayout")
        let child = try await self.construct(host, "android.widget.TextView")
        _ = try await self.invoke(host, parent["result"], "addView", [child["result"]])
        let gradient = try await self.construct(host, "android.graphics.drawable.GradientDrawable")
        _ = try await self.invoke(host, gradient["result"], "setColor", [.integer(-65_536)])
        _ = try await self.invoke(host, gradient["result"], "setCornerRadius", [.number(12)])
        _ = try await self.invoke(host, parent["result"], "setBackground", [gradient["result"]])
        let enabled = try await self.invoke(host, parent["result"], "setClipToOutline", [.bool(true)])
        XCTAssertEqual(enabled["error"], .null)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        let attached = XCTestExpectation(description: "clip outline test container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachmentResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachmentResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": parent["result"]])
        _ = try await self.invoke(host, parent["result"], "getWidth")
        let nativeParent = try XCTUnwrap(container.subviews.first)
        let mask = try XCTUnwrap(nativeParent.layer.mask as? CAShapeLayer)
        let maskPath = try XCTUnwrap(mask.path)
        XCTAssertEqual(maskPath.boundingBox.width, nativeParent.bounds.width, accuracy: 0.001)
        XCTAssertEqual(maskPath.boundingBox.height, nativeParent.bounds.height, accuracy: 0.001)
        let enabledState = try await self.invoke(host, parent["result"], "getClipToOutline")
        XCTAssertEqual(enabledState["result"], .bool(true))

        let outlineClass = self.classTarget("android.view.ViewOutlineProvider")
        let registeredOutlineClass = try await self.call(host, "java.class", arguments: ["class_name": .string("android.view.ViewOutlineProvider")])
        XCTAssertEqual(registeredOutlineClass["error"], .null)
        let outlineIsEnum = try await self.invoke(host, registeredOutlineClass["result"], "isEnum")
        XCTAssertEqual(outlineIsEnum["result"], .bool(true))
        let backgroundProvider = try await self.call(host, "java.member", arguments: ["target": outlineClass, "name": .string("BACKGROUND")])
        XCTAssertEqual(backgroundProvider["result"]["value"]["$class"], .string("android.view.ViewOutlineProvider"))
        let providerState = try await self.invoke(host, parent["result"], "getOutlineProvider")
        XCTAssertEqual(providerState["result"], backgroundProvider["result"]["value"])
        let clearProvider = try await self.invoke(host, parent["result"], "setOutlineProvider", [.null])
        XCTAssertEqual(clearProvider["error"], .null)
        let clearedProvider = try await self.invoke(host, parent["result"], "getOutlineProvider")
        XCTAssertEqual(clearedProvider["result"], .null)
        _ = try await self.invoke(host, parent["result"], "getWidth")
        XCTAssertNil(nativeParent.layer.mask, "A null outline provider disables outline clipping")
        _ = try await self.invoke(host, parent["result"], "setOutlineProvider", [backgroundProvider["result"]["value"]])
        _ = try await self.invoke(host, parent["result"], "getWidth")
        XCTAssertNotNil(nativeParent.layer.mask, "The background outline provider restores clipping")
        let wrongProvider = try await self.invoke(host, parent["result"], "setOutlineProvider", [.string("custom")])
        XCTAssertNotEqual(wrongProvider["error"], .null)

        let disabled = try await self.invoke(host, parent["result"], "setClipToOutline", [.bool(false)])
        XCTAssertEqual(disabled["error"], .null)
        _ = try await self.invoke(host, parent["result"], "getWidth")
        XCTAssertNil(nativeParent.layer.mask)
        let disabledState = try await self.invoke(host, parent["result"], "getClipToOutline")
        XCTAssertEqual(disabledState["result"], .bool(false))

        let badValue = try await self.invoke(host, parent["result"], "setClipToOutline", [.integer(1)])
        XCTAssertEqual(badValue["error"]["code"], .string("INVALID_ARGUMENTS"))
        _ = try await self.invoke(host, parent["result"], "setClipToOutline", [.bool(true)])
        _ = try await self.invoke(host, parent["result"], "setBackground", [.null])
        _ = try await self.invoke(host, parent["result"], "getWidth")
        XCTAssertNil(nativeParent.layer.mask, "A background-less view has no outline to clip to")
    }

    func testImageViewClearingDoesNotClaimResourceDrawableSupport() async throws {
        let host = self.host()
        try await self.authorize(host)
        let image = try await self.construct(host, "android.widget.ImageView")
        let clearDrawable = try await self.invoke(host, image["result"], "setImageDrawable", [.null])
        XCTAssertEqual(clearDrawable["error"], .null)
        let clearResource = try await self.invoke(host, image["result"], "setImageResource", [.integer(0)])
        XCTAssertEqual(clearResource["error"], .null)

        let drawable = try await self.construct(host, "android.graphics.drawable.ColorDrawable", [.integer(-1)])
        let unsupportedDrawable = try await self.invoke(host, image["result"], "setImageDrawable", [drawable["result"]])
        XCTAssertEqual(unsupportedDrawable["error"]["code"], .string("UNSUPPORTED_API"))
        let unsupportedResource = try await self.invoke(host, image["result"], "setImageResource", [.integer(1)])
        XCTAssertEqual(unsupportedResource["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testViewGetBackgroundReturnsOwnedSupportedDrawableSnapshots() async throws {
        let host = self.host()
        try await self.authorize(host)
        let view = try await self.construct(host, "android.widget.FrameLayout")
        let empty = try await self.invoke(host, view["result"], "getBackground")
        XCTAssertEqual(empty["result"], .null)

        let drawableAliasValue = try await self.construct(host, "android.graphics.drawable.ColorDrawable", [.integer(-65_536)])
        let drawableAlias = try await self.invoke(host, view["result"], "setBackgroundDrawable", [drawableAliasValue["result"]])
        XCTAssertEqual(drawableAlias["error"], .null)
        let drawableAliasReadback = try await self.invoke(host, view["result"], "getBackground")
        XCTAssertEqual(drawableAliasReadback["result"], drawableAliasValue["result"])
        _ = try await self.invoke(host, view["result"], "setBackgroundDrawable", [.null])

        let setColor = try await self.invoke(host, view["result"], "setBackgroundColor", [.integer(-65_536)])
        XCTAssertEqual(setColor["error"], .null)
        let background = try await self.invoke(host, view["result"], "getBackground")
        XCTAssertEqual(background["result"]["$class"], .string("android.graphics.drawable.ColorDrawable"))
        let color = try await self.invoke(host, background["result"], "getColor")
        XCTAssertEqual(color["result"], .integer(-65_536))

        let setDrawableColor = try await self.invoke(host, background["result"], "setColor", [.integer(-16_777_216)])
        XCTAssertEqual(setDrawableColor["error"], .null)
        let sameBackground = try await self.invoke(host, view["result"], "getBackground")
        XCTAssertEqual(sameBackground["result"], background["result"])
        let updatedColor = try await self.invoke(host, sameBackground["result"], "getColor")
        XCTAssertEqual(updatedColor["result"], .integer(-16_777_216))
        let releaseAttachedDrawable = try await self.call(host, "java.release", arguments: ["target": background["result"]])
        XCTAssertEqual(releaseAttachedDrawable["error"]["code"], .string("INVALID_STATE"))

        let clear = try await self.invoke(host, view["result"], "setBackground", [.null])
        XCTAssertEqual(clear["error"], .null)
        let afterClear = try await self.invoke(host, view["result"], "getBackground")
        XCTAssertEqual(afterClear["result"], .null)
        let releaseDrawable = try await self.call(host, "java.release", arguments: ["target": background["result"]])
        XCTAssertEqual(releaseDrawable["error"], .null)

        let wrongArity = try await self.invoke(host, view["result"], "getBackground", [.integer(0)])
        XCTAssertEqual(wrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testViewContextAndResourcesForwardOnlyThroughOwnedContextAdapter() async throws {
        let contextAdapter = AyuBridgeClassAdapter(name: "android.content.Context",
            constructor: { args, _ in
                guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Expected no fixture arguments") }
                return ["fixture": .string("context")]
            },
            methods: ["getResources": { state, args, _ in
                guard args.isEmpty, state["fixture"] == .string("context") else {
                    throw AyuBridgeFailure("invalid_arguments", "Invalid fixture context")
                }
                return .instance(className: "android.content.res.Resources", state: ["fixture": .string("resources")])
            }],
            validateState: { state in
                guard state == ["fixture": .string("context")] else {
                    throw AyuBridgeFailure("invalid_arguments", "Invalid fixture context state")
                }
            })
        let resourcesAdapter = AyuBridgeClassAdapter(name: "android.content.res.Resources", validateState: { state in
            guard state == ["fixture": .string("resources")] else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid fixture resources state")
            }
        })
        let registry = try AyuBridgeClassRegistry.standard.adding([contextAdapter, resourcesAdapter])
        let host = self.host(registry: registry)
        try await self.authorize(host)
        let context = try await self.construct(host, "android.content.Context")
        let view = try await self.construct(host, "android.widget.FrameLayout", [context["result"]])

        let returnedContext = try await self.invoke(host, view["result"], "getContext")
        XCTAssertEqual(returnedContext["result"], context["result"])
        let resources = try await self.invoke(host, view["result"], "getResources")
        XCTAssertEqual(resources["result"]["$class"], .string("android.content.res.Resources"))
        let sameResources = try await self.invoke(host, view["result"], "getResources")
        XCTAssertEqual(sameResources["result"], resources["result"])
        let releaseBoundContext = try await self.call(host, "java.release", arguments: ["target": context["result"]])
        XCTAssertEqual(releaseBoundContext["error"]["code"], .string("INVALID_STATE"))
        let releaseBoundResources = try await self.call(host, "java.release", arguments: ["target": resources["result"]])
        XCTAssertEqual(releaseBoundResources["error"]["code"], .string("INVALID_STATE"))

        let contextless = try await self.construct(host, "android.widget.TextView")
        let noContext = try await self.invoke(host, contextless["result"], "getContext")
        XCTAssertEqual(noContext["result"], .null)
        let noResources = try await self.invoke(host, contextless["result"], "getResources")
        XCTAssertEqual(noResources["error"]["code"], .string("UNSUPPORTED_API"))

        let wrongContext = try await self.invoke(host, contextless["result"], "getContext", [.integer(0)])
        XCTAssertEqual(wrongContext["error"]["code"], .string("INVALID_ARGUMENTS"))

        _ = try await self.call(host, "java.release", arguments: ["target": view["result"]])
        let releaseResources = try await self.call(host, "java.release", arguments: ["target": resources["result"]])
        XCTAssertEqual(releaseResources["error"], .null)
    }

    func testDrawableMutationRefreshesEveryStillReferencingViewOnly() async throws {
        let host = self.host()
        try await self.authorize(host)
        try await self.authorize(host, owner: "bravo")

        let alphaRoot = try await self.construct(host, "android.widget.FrameLayout")
        let alphaFirst = try await self.construct(host, "android.widget.TextView")
        let alphaSecond = try await self.construct(host, "android.widget.TextView")
        for (view, x) in [(alphaFirst["result"], 0), (alphaSecond["result"], 100)] {
            _ = try await self.invoke(host, alphaRoot["result"], "addView", [view])
            _ = try await self.invoke(host, view, "setFrame", [.integer(Int64(x)), .integer(0), .integer(80), .integer(40)])
        }
        let alphaDrawable = try await self.construct(host, "android.graphics.drawable.ColorDrawable", [.integer(-16_777_216)])
        _ = try await self.invoke(host, alphaFirst["result"], "setBackground", [alphaDrawable["result"]])
        _ = try await self.invoke(host, alphaSecond["result"], "setBackground", [alphaDrawable["result"]])

        let bravoRoot = try await self.construct(host, "android.widget.FrameLayout", owner: "bravo")
        let bravoView = try await self.construct(host, "android.widget.TextView", owner: "bravo")
        _ = try await self.invoke(host, bravoRoot["result"], "addView", [bravoView["result"]], owner: "bravo")
        _ = try await self.invoke(host, bravoView["result"], "setFrame", [.integer(0), .integer(0), .integer(80), .integer(40)], owner: "bravo")
        let bravoDrawable = try await self.construct(host, "android.graphics.drawable.ColorDrawable", [.integer(-16_776_961)], owner: "bravo")
        _ = try await self.invoke(host, bravoView["result"], "setBackground", [bravoDrawable["result"]], owner: "bravo")

        let alphaContainer = UIView(frame: CGRect(x: 0, y: 0, width: 220, height: 60))
        let bravoContainer = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 60))
        let alphaAttached = XCTestExpectation(description: "alpha container attached")
        let bravoAttached = XCTestExpectation(description: "bravo container attached")
        host.setMountContainer(alphaContainer, pluginID: "alpha") { alphaAttached.fulfill() }
        host.setMountContainer(bravoContainer, pluginID: "bravo") { bravoAttached.fulfill() }
        let attached = await XCTWaiter.fulfillment(of: [alphaAttached, bravoAttached], timeout: 1.0)
        XCTAssertEqual(attached, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": alphaRoot["result"]])
        _ = try await self.call(host, "ui.mount", owner: "bravo", arguments: ["target": bravoRoot["result"]])

        _ = try await self.invoke(host, alphaDrawable["result"], "setColor", [.integer(-65_536)])
        _ = try await self.invoke(host, alphaFirst["result"], "getWidth")
        _ = try await self.invoke(host, alphaSecond["result"], "getWidth")
        _ = try await self.invoke(host, bravoView["result"], "getWidth", owner: "bravo")

        let alphaNativeRoot = try XCTUnwrap(alphaContainer.subviews.first)
        let firstNativeView = try XCTUnwrap(alphaNativeRoot.subviews.first { $0.frame == CGRect(x: 0, y: 0, width: 80, height: 40) })
        let secondNativeView = try XCTUnwrap(alphaNativeRoot.subviews.first { $0.frame == CGRect(x: 100, y: 0, width: 80, height: 40) })
        let bravoNativeRoot = try XCTUnwrap(bravoContainer.subviews.first)
        let bravoNativeView = try XCTUnwrap(bravoNativeRoot.subviews.first { $0.frame == CGRect(x: 0, y: 0, width: 80, height: 40) })
        let red = UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        let bravoBlue = UIColor(red: 0, green: 0, blue: 1, alpha: 1)
        XCTAssertTrue(firstNativeView.backgroundColor?.isEqual(red) == true)
        XCTAssertTrue(secondNativeView.backgroundColor?.isEqual(red) == true)
        XCTAssertTrue(bravoNativeView.backgroundColor?.isEqual(bravoBlue) == true)

        _ = try await self.invoke(host, alphaFirst["result"], "setBackground", [.null])
        _ = try await self.invoke(host, alphaDrawable["result"], "setColor", [.integer(-16_776_961)])
        _ = try await self.invoke(host, alphaFirst["result"], "getWidth")
        _ = try await self.invoke(host, alphaSecond["result"], "getWidth")
        XCTAssertTrue(firstNativeView.backgroundColor?.isEqual(UIColor.clear) == true)
        XCTAssertTrue(secondNativeView.backgroundColor?.isEqual(bravoBlue) == true)

        _ = try await self.call(host, "plugin.deactivate")
        try await self.authorize(host)
        let freshView = try await self.construct(host, "android.widget.TextView")
        let freshContainer = UIView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
        let freshAttached = XCTestExpectation(description: "new-generation container attached")
        host.setMountContainer(freshContainer, pluginID: "alpha") { freshAttached.fulfill() }
        let freshAttachResult = await XCTWaiter.fulfillment(of: [freshAttached], timeout: 1.0)
        XCTAssertEqual(freshAttachResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": freshView["result"]])
        let freshDrawable = try await self.construct(host, "android.graphics.drawable.ColorDrawable", [.integer(-16_777_216)])
        _ = try await self.invoke(host, freshView["result"], "setBackground", [freshDrawable["result"]])
        _ = try await self.invoke(host, freshView["result"], "getWidth")
        let staleMutation = try await self.invoke(host, alphaDrawable["result"], "setColor", [.integer(-65_536)])
        XCTAssertEqual(staleMutation["error"]["code"], .string("INVALID_HANDLE"))
        _ = try await self.invoke(host, freshView["result"], "getWidth")
        XCTAssertTrue(freshContainer.subviews.first?.backgroundColor?.isEqual(UIColor.black) == true)
    }

    func testOvalGradientBackgroundUsesEllipsePathOnRectangularView() async throws {
        let host = self.host()
        try await self.authorize(host)
        let root = try await self.construct(host, "android.widget.FrameLayout")
        let first = try await self.construct(host, "android.widget.TextView")
        let second = try await self.construct(host, "android.widget.TextView")
        for (view, x) in [(first["result"], 10), (second["result"], 150)] {
            _ = try await self.invoke(host, root["result"], "addView", [view])
            _ = try await self.invoke(host, view, "setFrame", [.integer(Int64(x)), .integer(10), .integer(120), .integer(40)])
        }
        let oval = try await self.construct(host, "android.graphics.drawable.GradientDrawable")
        _ = try await self.invoke(host, oval["result"], "setColor", [.integer(-65_536)])
        _ = try await self.invoke(host, oval["result"], "setShape", [.integer(1)])
        _ = try await self.invoke(host, first["result"], "setBackground", [oval["result"]])
        _ = try await self.invoke(host, second["result"], "setBackground", [oval["result"]])

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 280, height: 70))
        let attached = XCTestExpectation(description: "oval test container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachedResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1.0)
        XCTAssertEqual(attachedResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": root["result"]])
        _ = try await self.invoke(host, first["result"], "getWidth")
        _ = try await self.invoke(host, second["result"], "getWidth")

        let nativeRoot = try XCTUnwrap(container.subviews.first)
        for frame in [CGRect(x: 10, y: 10, width: 120, height: 40), CGRect(x: 150, y: 10, width: 120, height: 40)] {
            let nativeView = try XCTUnwrap(nativeRoot.subviews.first { $0.frame == frame })
            XCTAssertEqual(nativeView.layer.cornerRadius, 0, "An oval must not be implemented as a capsule corner radius")
            let ellipseLayer = try XCTUnwrap(nativeView.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.path != nil })
            XCTAssertEqual(try XCTUnwrap(ellipseLayer.path).boundingBoxOfPath, CGRect(origin: .zero, size: frame.size))
            XCTAssertFalse(try XCTUnwrap(ellipseLayer.path).contains(CGPoint(x: 30, y: 1)),
                "This point is inside a capsule but outside the required ellipse")
        }

        _ = try await self.invoke(host, oval["result"], "setColor", [.integer(-16_776_961)])
        _ = try await self.invoke(host, first["result"], "getWidth")
        _ = try await self.invoke(host, second["result"], "getWidth")
        for frame in [CGRect(x: 10, y: 10, width: 120, height: 40), CGRect(x: 150, y: 10, width: 120, height: 40)] {
            let nativeView = try XCTUnwrap(nativeRoot.subviews.first { $0.frame == frame })
            let ellipseLayer = try XCTUnwrap(nativeView.layer.sublayers?.compactMap { $0 as? CAShapeLayer }.first { $0.path != nil })
            XCTAssertTrue(UIColor(cgColor: try XCTUnwrap(ellipseLayer.fillColor)).isEqual(UIColor(red: 0, green: 0, blue: 1, alpha: 1)))
        }
    }

    func testTextViewMaxLinesAndTruncateAtOnlyAcceptBoundedModes() async throws {
        let host = self.host()
        try await self.authorize(host)
        let textView = try await self.construct(host, "android.widget.TextView")
        let setMaxLines = try await self.invoke(host, textView["result"], "setMaxLines", [.integer(3)])
        XCTAssertEqual(setMaxLines["result"], .null)

        let truncateAtClass = self.classTarget("android.text.TextUtils$TruncateAt")
        let endMember = try await self.call(host, "java.member", arguments: [
            "target": truncateAtClass, "name": .string("END")
        ])
        XCTAssertEqual(endMember["result"]["kind"], .string("field"))
        let setEllipsize = try await self.invoke(host, textView["result"], "setEllipsize", [endMember["result"]["value"]])
        XCTAssertEqual(setEllipsize["result"], .null)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 80))
        let attached = XCTestExpectation(description: "TextView truncation test container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachedResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachedResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": textView["result"]])
        _ = try await self.invoke(host, textView["result"], "getWidth")
        let label = try XCTUnwrap(container.subviews.first?.subviews.first as? UILabel)
        XCTAssertEqual(label.numberOfLines, 3)
        XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)

        let nullEllipsize = try await self.invoke(host, textView["result"], "setEllipsize", [.null])
        XCTAssertEqual(nullEllipsize["result"], .null)
        _ = try await self.invoke(host, textView["result"], "getWidth")
        XCTAssertEqual(label.lineBreakMode, .byWordWrapping)

        let oversized = try await self.invoke(host, textView["result"], "setMaxLines", [.integer(65)])
        XCTAssertEqual(oversized["error"]["code"], .string("INVALID_ARGUMENTS"))
        let wrongEnum = try await self.construct(host, "android.content.Intent")
        let rejected = try await self.invoke(host, textView["result"], "setEllipsize", [wrongEnum["result"]])
        XCTAssertEqual(rejected["error"]["code"], .string("UNSUPPORTED_API"))
        let editText = try await self.construct(host, "android.widget.EditText")
        let editLines = try await self.invoke(host, editText["result"], "setMaxLines", [.integer(2)])
        XCTAssertEqual(editLines["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testTextUtilsIsEmptyAndInputTypeConstantsAreExplicitlyBounded() async throws {
        let host = self.host()
        try await self.authorize(host)
        let textUtils = self.classTarget("android.text.TextUtils")
        let member = try await self.call(host, "java.member", arguments: ["target": textUtils, "name": .string("isEmpty")])
        XCTAssertEqual(member["result"]["kind"], .string("method"))
        let emptyNull = try await self.invoke(host, textUtils, "isEmpty", [.null])
        XCTAssertEqual(emptyNull["result"], .bool(true))
        let emptyString = try await self.invoke(host, textUtils, "isEmpty", [.string("")])
        XCTAssertEqual(emptyString["result"], .bool(true))
        let nonemptyString = try await self.invoke(host, textUtils, "isEmpty", [.string("text")])
        XCTAssertEqual(nonemptyString["result"], .bool(false))
        let wrongType = try await self.invoke(host, textUtils, "isEmpty", [.integer(1)])
        XCTAssertEqual(wrongType["error"]["code"], .string("INVALID_ARGUMENTS"))
        let tooLarge = try await self.invoke(host, textUtils, "isEmpty", [.string(String(repeating: "x", count: 65_537))])
        XCTAssertEqual(tooLarge["error"]["code"], .string("RESOURCE_LIMIT"))
        let emptySpannable = try await self.construct(host, "android.text.SpannableString", [.string("")])
        let spannableEmpty = try await self.invoke(host, textUtils, "isEmpty", [emptySpannable["result"]])
        XCTAssertEqual(spannableEmpty["result"], .bool(true))
        let nonemptyBuilder = try await self.construct(host, "android.text.SpannableStringBuilder", [.string("😀")])
        let spannableNonempty = try await self.invoke(host, textUtils, "isEmpty", [nonemptyBuilder["result"]])
        XCTAssertEqual(spannableNonempty["result"], .bool(false))

        let inputType = self.classTarget("android.text.InputType")
        let password = try await self.call(host, "java.member", arguments: ["target": inputType, "name": .string("TYPE_TEXT_VARIATION_PASSWORD")])
        XCTAssertEqual(password["result"]["value"], .integer(0x80))
        let multiline = try await self.call(host, "java.member", arguments: ["target": inputType, "name": .string("TYPE_TEXT_FLAG_MULTI_LINE")])
        XCTAssertEqual(multiline["result"]["value"], .integer(0x2_0000))
    }

    func testTextViewTextSizeSupportsBoundedPixelAndDensityIndependentUnits() async throws {
        let host = self.host()
        try await self.authorize(host)
        let textView = try await self.construct(host, "android.widget.TextView")
        let setDIP = try await self.invoke(host, textView["result"], "setTextSize", [.integer(1), .number(22.5)])
        XCTAssertEqual(setDIP["result"], .null)
        let setSP = try await self.invoke(host, textView["result"], "setTextSize", [.integer(2), .number(19)])
        XCTAssertEqual(setSP["result"], .null)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 80))
        let attached = XCTestExpectation(description: "TextView unit-size test container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachedResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachedResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": textView["result"]])
        _ = try await self.invoke(host, textView["result"], "getWidth")
        let label = try XCTUnwrap(container.subviews.first?.subviews.first as? UILabel)
        XCTAssertEqual(label.font.pointSize, UIFontMetrics.default.scaledValue(for: 19, compatibleWith: label.traitCollection), accuracy: 0.001)

        let setPixels = try await self.invoke(host, textView["result"], "setTextSize", [.integer(0), .number(36)])
        XCTAssertEqual(setPixels["result"], .null)
        _ = try await self.invoke(host, textView["result"], "getWidth")
        let scale = max(UIScreen.main.scale, 1)
        XCTAssertEqual(label.font.pointSize, 36 / scale, accuracy: 0.001)

        let unsupportedUnit = try await self.invoke(host, textView["result"], "setTextSize", [.integer(3), .number(12)])
        XCTAssertEqual(unsupportedUnit["error"]["code"], .string("UNSUPPORTED_API"))
        let wrongSize = try await self.invoke(host, textView["result"], "setTextSize", [.integer(1), .number(0)])
        XCTAssertEqual(wrongSize["error"]["code"], .string("INVALID_ARGUMENTS"))
        let wrongArity = try await self.invoke(host, textView["result"], "setTextSize", [.integer(1), .number(12), .number(13)])
        XCTAssertEqual(wrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testImageViewScaleTypeAndEditTextInputTypeMapOnlyBoundedValues() async throws {
        let host = self.host()
        try await self.authorize(host)
        let image = try await self.construct(host, "android.widget.ImageView")
        let scaleTypeClass = self.classTarget("android.widget.ImageView$ScaleType")
        let scaleType = try await self.call(host, "java.member", arguments: ["target": scaleTypeClass, "name": .string("CENTER_CROP")])
        XCTAssertEqual(scaleType["result"]["kind"], .string("field"))
        let appliedScale = try await self.invoke(host, image["result"], "setScaleType", [scaleType["result"]["value"]])
        XCTAssertEqual(appliedScale["result"], .null)
        let matrix = try await self.call(host, "java.member", arguments: ["target": scaleTypeClass, "name": .string("MATRIX")])
        XCTAssertEqual(matrix["error"], .null)
        let unavailableScale = try await self.call(host, "java.member", arguments: ["target": scaleTypeClass, "name": .string("FIT_START")])
        XCTAssertEqual(unavailableScale["error"]["code"], .string("UNSUPPORTED_API"))

        let editText = try await self.construct(host, "android.widget.EditText")
        let password = try await self.invoke(host, editText["result"], "setInputType", [.integer(0x81)])
        XCTAssertEqual(password["result"], .null)
        let multiline = try await self.invoke(host, editText["result"], "setInputType", [.integer(0x2_0001)])
        XCTAssertEqual(multiline["error"]["code"], .string("UNSUPPORTED_API"))
        let textView = try await self.construct(host, "android.widget.TextView")
        let wrongClass = try await self.invoke(host, textView["result"], "setInputType", [.integer(1)])
        XCTAssertEqual(wrongClass["error"]["code"], .string("UNSUPPORTED_API"))

        let root = try await self.construct(host, "android.widget.FrameLayout")
        _ = try await self.invoke(host, root["result"], "addView", [image["result"]])
        _ = try await self.invoke(host, root["result"], "addView", [editText["result"]])

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let attached = XCTestExpectation(description: "image and edit controls attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachedResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachedResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": root["result"]])
        _ = try await self.invoke(host, root["result"], "getChildCount")
        func descendants(of view: UIView) -> [UIView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        let nativeViews = descendants(of: container)
        let imageView = try XCTUnwrap(nativeViews.first { $0 is UIImageView } as? UIImageView)
        XCTAssertEqual(imageView.contentMode, .scaleAspectFill)
        let matrixScale = try await self.invoke(host, image["result"], "setScaleType", [matrix["result"]["value"]])
        XCTAssertEqual(matrixScale["error"], .null)
        _ = try await self.invoke(host, image["result"], "getWidth")
        XCTAssertEqual(imageView.contentMode, .topLeft)
        let nativeTextField = try XCTUnwrap(nativeViews.first { $0 is UITextField } as? UITextField)
        XCTAssertTrue(nativeTextField.isSecureTextEntry)
    }

    func testViewGroupsSupportBoundedIndexAndLayoutParamsAddViewOverloads() async throws {
        let host = self.host()
        try await self.authorize(host)
        let parent = try await self.construct(host, "android.widget.FrameLayout")
        let first = try await self.construct(host, "android.widget.TextView")
        let middle = try await self.construct(host, "android.widget.TextView")
        let last = try await self.construct(host, "android.widget.TextView")
        let inserted = try await self.construct(host, "android.widget.TextView")
        for (view, text) in [(first, "first"), (middle, "middle"), (last, "last"), (inserted, "inserted")] {
            _ = try await self.invoke(host, view["result"], "setText", [.string(text)])
        }
        let addFirst = try await self.invoke(host, parent["result"], "addView", [first["result"]])
        XCTAssertEqual(addFirst["result"], .null)
        let addLast = try await self.invoke(host, parent["result"], "addView", [last["result"]])
        XCTAssertEqual(addLast["result"], .null)
        let insertMiddle = try await self.invoke(host, parent["result"], "addView", [middle["result"], .integer(1)])
        XCTAssertEqual(insertMiddle["result"], .null)
        let params = try await self.construct(host, "android.widget.FrameLayout$LayoutParams", [.integer(-1), .integer(-2)])
        let insertWithParams = try await self.invoke(host, parent["result"], "addView", [inserted["result"], .integer(1), params["result"]])
        XCTAssertEqual(insertWithParams["result"], .null)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 80))
        let attached = XCTestExpectation(description: "indexed view group attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachedResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachedResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": parent["result"]])
        _ = try await self.invoke(host, parent["result"], "getChildCount")
        let root = try XCTUnwrap(container.subviews.first)
        let labels = root.subviews.compactMap { $0.subviews.compactMap { $0 as? UILabel }.first?.text }
        XCTAssertEqual(labels, ["first", "inserted", "middle", "last"])

        let outOfRangeChild = try await self.construct(host, "android.widget.TextView")
        let outOfRange = try await self.invoke(host, parent["result"], "addView", [outOfRangeChild["result"], .integer(5)])
        XCTAssertEqual(outOfRange["error"]["code"], .string("INVALID_ARGUMENTS"))
        let badIndexChild = try await self.construct(host, "android.widget.TextView")
        let badIndex = try await self.invoke(host, parent["result"], "addView", [badIndexChild["result"], .integer(-2), params["result"]])
        XCTAssertEqual(badIndex["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testByteBufferWrapAcceptsOnlyOwnedBoundedByteArrays() async throws {
        let host = self.host()
        try await self.authorize(host)
        let arrayResult = try await self.call(host, "java.array", arguments: [
            "component": .string("byte"), "values": .array([.integer(-1), .integer(2), .integer(127)])
        ])
        XCTAssertEqual(arrayResult["error"], .null)
        let byteBuffer = self.classTarget("java.nio.ByteBuffer")
        let wrapped = try await self.invoke(host, byteBuffer, "wrap", [arrayResult["result"]])
        XCTAssertEqual(wrapped["error"], .null)
        XCTAssertEqual(wrapped["result"]["$class"], .string("java.nio.ByteBuffer"))
        let capacity = try await self.invoke(host, wrapped["result"], "capacity")
        XCTAssertEqual(capacity["result"], .integer(3))
        let firstByte = try await self.invoke(host, wrapped["result"], "get")
        XCTAssertEqual(firstByte["result"], .integer(-1))
        let absoluteByte = try await self.invoke(host, wrapped["result"], "get", [.integer(2)])
        XCTAssertEqual(absoluteByte["result"], .integer(127))

        let exhausted = try await self.invoke(host, wrapped["result"], "get")
        XCTAssertEqual(exhausted["result"], .integer(2))
        let overflow = try await self.invoke(host, wrapped["result"], "get")
        XCTAssertEqual(overflow["error"]["code"], .string("INVALID_STATE"))
        let wrongOverload = try await self.invoke(host, byteBuffer, "wrap", [arrayResult["result"], .integer(0), .integer(1)])
        XCTAssertEqual(wrongOverload["error"]["code"], .string("UNSUPPORTED_API"))
        let nonArray = try await self.construct(host, "android.content.Intent")
        let wrongType = try await self.invoke(host, byteBuffer, "wrap", [nonArray["result"]])
        XCTAssertNotNil(wrongType["error"]["code"].string)
    }

    func testClassForNameResolvesOnlyExactRegisteredClasses() async throws {
        let host = self.host()
        try await self.authorize(host)
        let classClass = self.classTarget("java.lang.Class")
        let forNameMember = try await self.call(host, "java.member", arguments: [
            "target": classClass, "name": .string("forName")
        ])
        XCTAssertEqual(forNameMember["result"]["kind"], .string("method"))

        let loaded = try await self.invoke(host, classClass, "forName", [.string("android.widget.TextView")])
        XCTAssertEqual(loaded["result"]["$class"], .string("android.widget.TextView"))
        let className = try await self.invoke(host, loaded["result"], "getName")
        XCTAssertEqual(className["result"], .string("android.widget.TextView"))
        let method = try await self.invoke(host, loaded["result"], "getDeclaredMethod", [.string("setText")])
        XCTAssertEqual(method["result"]["$class"], .string("java.lang.reflect.Method"))

        let unknown = try await self.invoke(host, classClass, "forName", [.string("java.lang.Runtime")])
        XCTAssertEqual(unknown["error"]["code"], .string("UNSUPPORTED_API"))
        let malformed = try await self.invoke(host, classClass, "forName", [.string("android.widget.TextView"), .bool(true)])
        XCTAssertEqual(malformed["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testClassIntrospectionIsBoundedToRegisteredMetadata() async throws {
        let host = self.host()
        try await self.authorize(host)
        let classClass = self.classTarget("java.lang.Class")

        let textView = try await self.invoke(host, classClass, "forName", [.string("android.widget.TextView")])
        let simpleName = try await self.invoke(host, textView["result"], "getSimpleName")
        let packageName = try await self.invoke(host, textView["result"], "getPackageName")
        let isPrimitive = try await self.invoke(host, textView["result"], "isPrimitive")
        let isArray = try await self.invoke(host, textView["result"], "isArray")
        let isInterface = try await self.invoke(host, textView["result"], "isInterface")
        XCTAssertEqual(simpleName["result"], .string("TextView"))
        XCTAssertEqual(packageName["result"], .string("android.widget"))
        XCTAssertEqual(isPrimitive["result"], .bool(false))
        XCTAssertEqual(isArray["result"], .bool(false))
        XCTAssertEqual(isInterface["result"], .bool(false))

        let runnable = try await self.invoke(host, classClass, "forName", [.string("java.lang.Runnable")])
        let runnableIsInterface = try await self.invoke(host, runnable["result"], "isInterface")
        XCTAssertEqual(runnableIsInterface["result"], .bool(true))
        let charSequence = try await self.invoke(host, classClass, "forName", [.string("java.lang.CharSequence")])
        let charSequenceIsInterface = try await self.invoke(host, charSequence["result"], "isInterface")
        XCTAssertEqual(charSequenceIsInterface["result"], .bool(true))
        let spanned = try await self.invoke(host, classClass, "forName", [.string("android.text.Spanned")])
        let inclusiveExclusive = try await self.call(host, "java.member", arguments: ["target": spanned["result"], "name": .string("SPAN_INCLUSIVE_EXCLUSIVE")])
        let inclusiveInclusive = try await self.call(host, "java.member", arguments: ["target": spanned["result"], "name": .string("SPAN_INCLUSIVE_INCLUSIVE")])
        let exclusiveInclusive = try await self.call(host, "java.member", arguments: ["target": spanned["result"], "name": .string("SPAN_EXCLUSIVE_INCLUSIVE")])
        let exclusiveExclusive = try await self.call(host, "java.member", arguments: ["target": spanned["result"], "name": .string("SPAN_EXCLUSIVE_EXCLUSIVE")])
        XCTAssertEqual(inclusiveExclusive["result"]["value"], .integer(17))
        XCTAssertEqual(inclusiveInclusive["result"]["value"], .integer(18))
        XCTAssertEqual(exclusiveInclusive["result"]["value"], .integer(34))
        XCTAssertEqual(exclusiveExclusive["result"]["value"], .integer(33))
        let updateAppearance = try await self.invoke(host, classClass, "forName", [.string("android.text.style.UpdateAppearance")])
        let updateAppearanceIsInterface = try await self.invoke(host, updateAppearance["result"], "isInterface")
        XCTAssertEqual(updateAppearanceIsInterface["result"], .bool(true))
        let paintStyle = try await self.invoke(host, classClass, "forName", [.string("android.graphics.Paint$Style")])
        let paintStyleIsEnum = try await self.invoke(host, paintStyle["result"], "isEnum")
        XCTAssertEqual(paintStyleIsEnum["result"], .bool(true))

        let primitiveClass = self.classTarget("int")
        let primitiveIsPrimitive = try await self.invoke(host, primitiveClass, "isPrimitive")
        XCTAssertEqual(primitiveIsPrimitive["result"], .bool(true))
        let array = try await self.call(host, "java.array", arguments: [
            "component": .string("int"), "values": .array([.integer(1), .integer(2)])
        ])
        let arrayClass = try await self.invoke(host, array["result"], "getClass")
        let arrayIsArray = try await self.invoke(host, arrayClass["result"], "isArray")
        let arraySimpleName = try await self.invoke(host, arrayClass["result"], "getSimpleName")
        XCTAssertEqual(arrayIsArray["result"], .bool(true))
        XCTAssertEqual(arraySimpleName["result"], .string("int[]"))
        let component = try await self.invoke(host, arrayClass["result"], "getComponentType")
        XCTAssertEqual(component["result"]["$class"], .string("int"))
        let componentName = try await self.invoke(host, component["result"], "getName")
        XCTAssertEqual(componentName["result"], .string("int"))
        let classMethods = try await self.invoke(host, classClass, "getDeclaredMethods")
        let classMethodReferences = try XCTUnwrap(classMethods["result"].array)
        var classMethodNames = Set<String>()
        for reference in classMethodReferences {
            let name = try await self.invoke(host, reference, "getName")
            if let value = name["result"].string { classMethodNames.insert(value) }
        }
        XCTAssertTrue(classMethodNames.contains("getName"))
        XCTAssertTrue(classMethodNames.contains("getComponentType"))
        XCTAssertFalse(classMethodNames.contains("getClass"))

        let badNameArity = try await self.invoke(host, textView["result"], "getName", [.string("extra")])
        XCTAssertEqual(badNameArity["error"]["code"], .string("INVALID_ARGUMENTS"))
        let badMethodArity = try await self.invoke(host, textView["result"], "getDeclaredMethod", [.string("setText"), .string("java.lang.String")])
        XCTAssertEqual(badMethodArity["error"]["code"], .string("INVALID_ARGUMENTS"))
        let badMethodsArity = try await self.invoke(host, textView["result"], "getDeclaredMethods", [.bool(true)])
        XCTAssertEqual(badMethodsArity["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testReflectArrayCreatesAndAccessesBoundedPrimitiveAndObjectArrays() async throws {
        let host = self.host()
        try await self.authorize(host)
        let arrayClass = self.classTarget("java.lang.reflect.Array")
        let byteClass = self.classTarget("java.lang.Byte")
        let byteType = try await self.call(host, "java.member", arguments: [
            "target": byteClass, "name": .string("TYPE"),
        ])
        XCTAssertEqual(byteType["result"]["value"], .object(["$java_class": .string("byte")]))

        let bytes = try await self.invoke(host, arrayClass, "newInstance", [byteType["result"]["value"], .integer(3)])
        XCTAssertEqual(bytes["result"]["$class"], .string("[B"))
        let byteCount = try await self.invoke(host, arrayClass, "getLength", [bytes["result"]])
        XCTAssertEqual(byteCount["result"], .integer(3))
        let initialByte = try await self.invoke(host, arrayClass, "getByte", [bytes["result"], .integer(1)])
        XCTAssertEqual(initialByte["result"], .integer(0))
        let writeByte = try await self.invoke(host, arrayClass, "setByte", [bytes["result"], .integer(1), .integer(-128)])
        XCTAssertNil(writeByte["error"]["code"].string)
        let readByte = try await self.invoke(host, arrayClass, "get", [bytes["result"], .integer(1)])
        XCTAssertEqual(readByte["result"], .integer(-128))

        let charSequenceClass = self.classTarget("java.lang.CharSequence")
        let strings = try await self.invoke(host, arrayClass, "newInstance", [charSequenceClass, .integer(2)])
        XCTAssertEqual(strings["result"]["$class"], .string("[Ljava.lang.CharSequence;"))
        let writeString = try await self.invoke(host, arrayClass, "set", [strings["result"], .integer(0), .string("portable")])
        XCTAssertNil(writeString["error"]["code"].string)
        let readString = try await self.invoke(host, arrayClass, "get", [strings["result"], .integer(0)])
        XCTAssertEqual(readString["result"], .string("portable"))
        let arrayMetadata = try await self.invoke(host, strings["result"], "getClass")
        let isArray = try await self.invoke(host, arrayMetadata["result"], "isArray")
        XCTAssertEqual(isArray["result"], .bool(true))
        let component = try await self.invoke(host, arrayMetadata["result"], "getComponentType")
        XCTAssertEqual(component["result"]["$class"], .string("java.lang.CharSequence"))
    }

    func testReflectArrayRejectsInvalidTypesRangesAndUnownedReferences() async throws {
        let host = self.host()
        try await self.authorize(host)
        let arrayClass = self.classTarget("java.lang.reflect.Array")
        let byteType = try await self.call(host, "java.member", arguments: [
            "target": self.classTarget("java.lang.Byte"), "name": .string("TYPE"),
        ])
        let bytes = try await self.invoke(host, arrayClass, "newInstance", [byteType["result"]["value"], .integer(1)])

        let wrongPrimitiveGetter = try await self.invoke(host, arrayClass, "getInt", [bytes["result"], .integer(0)])
        XCTAssertEqual(wrongPrimitiveGetter["error"]["code"], .string("INVALID_ARGUMENTS"))
        let wrongPrimitiveSetter = try await self.invoke(host, arrayClass, "setBoolean", [bytes["result"], .integer(0), .bool(true)])
        XCTAssertEqual(wrongPrimitiveSetter["error"]["code"], .string("INVALID_ARGUMENTS"))
        let byteOverflow = try await self.invoke(host, arrayClass, "setByte", [bytes["result"], .integer(0), .integer(128)])
        XCTAssertEqual(byteOverflow["error"]["code"], .string("INVALID_ARGUMENTS"))
        let outOfBounds = try await self.invoke(host, arrayClass, "get", [bytes["result"], .integer(1)])
        XCTAssertEqual(outOfBounds["error"]["code"], .string("INVALID_ARGUMENTS"))
        let unsupportedMethod = try await self.invoke(host, arrayClass, "getShorts", [bytes["result"], .integer(0)])
        XCTAssertEqual(unsupportedMethod["error"]["code"], .string("UNSUPPORTED_API"))
        let wrongArity = try await self.invoke(host, arrayClass, "getLength", [bytes["result"], .integer(0)])
        XCTAssertEqual(wrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))

        let negativeLength = try await self.invoke(host, arrayClass, "newInstance", [byteType["result"]["value"], .integer(-1)])
        XCTAssertEqual(negativeLength["error"]["code"], .string("INVALID_ARGUMENTS"))
        let voidComponent = try await self.invoke(host, arrayClass, "newInstance", [.object(["$java_class": .string("void")]), .integer(0)])
        XCTAssertEqual(voidComponent["error"]["code"], .string("UNSUPPORTED_API"))
        let nestedComponent = try await self.invoke(host, arrayClass, "newInstance", [.object(["$java_class": .string("[B")]), .integer(0)])
        XCTAssertEqual(nestedComponent["error"]["code"], .string("UNSUPPORTED_API"))
        let unknownComponent = try await self.invoke(host, arrayClass, "newInstance", [.object(["$java_class": .string("java.lang.Runtime")]), .integer(0)])
        XCTAssertEqual(unknownComponent["error"]["code"], .string("UNSUPPORTED_API"))

        let foreignHost = self.host()
        try await self.authorize(foreignHost, owner: "beta")
        let foreignArray = try await self.invoke(foreignHost, self.classTarget("java.lang.reflect.Array"), "newInstance", [byteType["result"]["value"], .integer(1)], owner: "beta")
        let foreignRead = try await self.invoke(host, arrayClass, "get", [foreignArray["result"], .integer(0)])
        XCTAssertEqual(foreignRead["error"]["code"], .string("INVALID_HANDLE"))
    }

    func testReflectArrayEnforcesAggregateElementAndEncodedByteQuotas() async throws {
        var limits = AyuPluginBridgeLimits()
        limits.arrayElementsPerPlugin = 4
        limits.arrayBytesPerPlugin = 256
        let host = self.host(limits: limits)
        try await self.authorize(host)
        let arrayClass = self.classTarget("java.lang.reflect.Array")
        let intClass = self.classTarget("int")
        let first = try await self.invoke(host, arrayClass, "newInstance", [intClass, .integer(3)])
        XCTAssertNil(first["error"]["code"].string)
        let elementOverflow = try await self.invoke(host, arrayClass, "newInstance", [intClass, .integer(2)])
        XCTAssertEqual(elementOverflow["error"]["code"], .string("RESOURCE_LIMIT"))

        var byteLimits = AyuPluginBridgeLimits()
        byteLimits.arrayElementsPerPlugin = 4
        byteLimits.arrayBytesPerPlugin = 8
        let byteHost = self.host(limits: byteLimits)
        try await self.authorize(byteHost)
        let boolClass = self.classTarget("boolean")
        let byteOverflow = try await self.invoke(byteHost, arrayClass, "newInstance", [boolClass, .integer(4)])
        XCTAssertEqual(byteOverflow["error"]["code"], .string("RESOURCE_LIMIT"))

        var mutationLimits = AyuPluginBridgeLimits()
        mutationLimits.arrayBytesPerPlugin = 64
        let mutationHost = self.host(limits: mutationLimits)
        try await self.authorize(mutationHost)
        let objectArray = try await self.invoke(mutationHost, arrayClass, "newInstance", [self.classTarget("java.lang.String"), .integer(1)])
        XCTAssertNil(objectArray["error"]["code"].string)
        let oversizedWrite = try await self.invoke(mutationHost, arrayClass, "set", [objectArray["result"], .integer(0), .string(String(repeating: "x", count: 100))])
        XCTAssertEqual(oversizedWrite["error"]["code"], .string("RESOURCE_LIMIT"))
        let retainedNull = try await self.invoke(mutationHost, arrayClass, "get", [objectArray["result"], .integer(0)])
        XCTAssertEqual(retainedNull["result"], .null)

        let smallWrite = try await self.invoke(mutationHost, arrayClass, "set", [objectArray["result"], .integer(0), .string("tiny")])
        XCTAssertNil(smallWrite["error"]["code"].string)
        let aggregateOverflow = try await self.invoke(mutationHost, arrayClass, "newInstance", [self.classTarget("int"), .integer(0)])
        XCTAssertEqual(aggregateOverflow["error"]["code"], .string("RESOURCE_LIMIT"))
        _ = try await self.call(mutationHost, "java.release", arguments: ["target": objectArray["result"]])
        let releasedCapacity = try await self.invoke(mutationHost, arrayClass, "newInstance", [self.classTarget("int"), .integer(0)])
        XCTAssertNil(releasedCapacity["error"]["code"].string)
    }

    func testTypedObjectArraysKeepComponentMetadataAndOwnerChecks() async throws {
        let host = self.host()
        try await self.authorize(host)
        let array = try await self.call(host, "java.array", arguments: [
            "component": .string("java.lang.CharSequence"),
            "values": .array([.string("first"), .null]),
        ])
        XCTAssertEqual(array["error"], .null)
        XCTAssertEqual(array["result"]["$class"], .string("[Ljava.lang.CharSequence;"))
        let first = try await self.call(host, "java.get_item", arguments: ["target": array["result"], "index": .integer(0)])
        XCTAssertEqual(first["result"], .string("first"))
        let arrayClass = try await self.invoke(host, array["result"], "getClass")
        let isArray = try await self.invoke(host, arrayClass["result"], "isArray")
        XCTAssertEqual(isArray["result"], .bool(true))
        let simpleName = try await self.invoke(host, arrayClass["result"], "getSimpleName")
        XCTAssertEqual(simpleName["result"], .string("CharSequence[]"))
        let component = try await self.invoke(host, arrayClass["result"], "getComponentType")
        let componentName = try await self.invoke(host, component["result"], "getName")
        XCTAssertEqual(componentName["result"], .string("java.lang.CharSequence"))

        let wrong = try await self.call(host, "java.array", arguments: [
            "component": .string("java.lang.CharSequence"),
            "values": .array([.integer(1)]),
        ])
        XCTAssertEqual(wrong["error"]["code"], .string("INVALID_ARGUMENTS"))

        try await self.authorize(host, owner: "bravo")
        let foreign = try await self.construct(host, "java.lang.Object", owner: "bravo")
        let wrongOwner = try await self.call(host, "java.array", arguments: [
            "component": .string("java.lang.Object"), "values": .array([foreign]),
        ])
        XCTAssertNotEqual(wrongOwner["error"], .null)

        let spannable = try await self.construct(host, "android.text.SpannableString", [.string("owned text")])
        let charSequences = try await self.call(host, "java.array", arguments: [
            "component": .string("java.lang.CharSequence"), "values": .array([spannable["result"]]),
        ])
        XCTAssertEqual(charSequences["error"], .null)
        let cast = try await self.call(host, "java.cast", arguments: [
            "class_name": .string("java.lang.CharSequence"), "value": spannable["result"],
        ])
        XCTAssertEqual(cast["result"], spannable["result"])

        let frame = try await self.construct(host, "android.widget.FrameLayout")
        let textView = try await self.construct(host, "android.widget.TextView")
        let asView = try await self.call(host, "java.cast", arguments: [
            "class_name": .string("android.view.View"), "value": textView["result"],
        ])
        XCTAssertEqual(asView["result"], textView["result"])
        let asViewGroup = try await self.call(host, "java.cast", arguments: [
            "class_name": .string("android.view.ViewGroup"), "value": frame["result"],
        ])
        XCTAssertEqual(asViewGroup["result"], frame["result"])
        let views = try await self.call(host, "java.array", arguments: [
            "component": .string("android.view.View"), "values": .array([textView["result"], frame["result"]]),
        ])
        XCTAssertEqual(views["error"], .null)
        let viewGroups = try await self.call(host, "java.array", arguments: [
            "component": .string("android.view.ViewGroup"), "values": .array([frame["result"]]),
        ])
        XCTAssertEqual(viewGroups["error"], .null)
        let notAGroup = try await self.call(host, "java.cast", arguments: [
            "class_name": .string("android.view.ViewGroup"), "value": textView["result"],
        ])
        XCTAssertEqual(notAGroup["error"]["code"], .string("UNSUPPORTED_API"))
        let invalidGroupArray = try await self.call(host, "java.array", arguments: [
            "component": .string("android.view.ViewGroup"), "values": .array([textView["result"]]),
        ])
        XCTAssertEqual(invalidGroupArray["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testSpannableHostPreservesOwnedSpanRangesWithoutClaimingTextRendering() async throws {
        let host = self.host()
        try await self.authorize(host)
        let builder = try await self.construct(host, "android.text.SpannableStringBuilder", [.string("abc")])
        let span = try await self.construct(host, "android.text.style.StyleSpan", [.integer(1)])
        let castSpan = try await self.call(host, "java.cast", arguments: [
            "class_name": .string("android.text.style.CharacterStyle"), "value": span["result"],
        ])
        XCTAssertEqual(castSpan["result"], span["result"])
        let spanArray = try await self.call(host, "java.array", arguments: [
            "component": .string("android.text.style.UpdateAppearance"), "values": .array([span["result"]]),
        ])
        XCTAssertEqual(spanArray["result"]["$class"], .string("[Landroid.text.style.UpdateAppearance;"))
        let applied = try await self.invoke(host, builder["result"], "setSpan", [span["result"], .integer(0), .integer(3), .integer(33)])
        XCTAssertEqual(applied["error"], .null)
        let start = try await self.invoke(host, builder["result"], "getSpanStart", [span["result"]])
        let end = try await self.invoke(host, builder["result"], "getSpanEnd", [span["result"]])
        XCTAssertEqual(start["result"], .integer(0))
        XCTAssertEqual(end["result"], .integer(3))

        let found = try await self.invoke(host, builder["result"], "getSpans", [
            .integer(0), .integer(3), .object(["$java_class": .string("android.text.style.StyleSpan")]),
        ])
        XCTAssertEqual(found["result"], .array([span["result"]]))

        let supplementary = try await self.construct(host, "android.text.SpannableStringBuilder", [.string("A😀B")])
        let splitSurrogate = try await self.invoke(host, supplementary["result"], "setSpan", [
            span["result"], .integer(2), .integer(3), .integer(33),
        ])
        XCTAssertEqual(splitSurrogate["error"]["code"], .string("UNSUPPORTED_API"))

        _ = try await self.invoke(host, builder["result"], "replace", [.integer(1), .integer(2), .string("XYZ")])
        let length = try await self.invoke(host, builder["result"], "length")
        let shiftedEnd = try await self.invoke(host, builder["result"], "getSpanEnd", [span["result"]])
        XCTAssertEqual(length["result"], .integer(5))
        XCTAssertEqual(shiftedEnd["result"], .integer(5))
        let subSequence = try await self.invoke(host, builder["result"], "subSequence", [.integer(1), .integer(4)])
        XCTAssertEqual(subSequence["result"], .string("XYZ"))

        let textView = try await self.construct(host, "android.widget.TextView")
        let plainText = try await self.invoke(host, textView["result"], "setText", [builder["result"]])
        XCTAssertEqual(plainText["error"], .null)
        let displayed = try await self.invoke(host, textView["result"], "getText")
        XCTAssertEqual(displayed["result"], .string("aXYZc"), "Text is flattened; Android span rendering is not implied")
        let editText = try await self.construct(host, "android.widget.EditText")
        let plainHint = try await self.invoke(host, editText["result"], "setHint", [builder["result"]])
        XCTAssertEqual(plainHint["error"], .null)
    }

    func testUrlEncoderAndScannerAreExposedAsBoundedValueAdapters() async throws {
        let host = self.host()
        try await self.authorize(host)
        let capabilities = try await self.call(host, "runtime.capabilities")
        let classes = Set(capabilities["result"]["classes"].array?.compactMap(\.string) ?? [])
        XCTAssertTrue(classes.contains("java.lang.String"))
        XCTAssertTrue(classes.contains("java.lang.Float"))
        XCTAssertTrue(classes.contains("java.lang.Object"))
        XCTAssertTrue(classes.contains("java.lang.CharSequence"))
        XCTAssertTrue(classes.contains("android.text.Spanned"))
        XCTAssertTrue(classes.contains("android.text.SpannableString"))
        XCTAssertTrue(classes.contains("android.text.SpannableStringBuilder"))
        XCTAssertTrue(classes.contains("android.text.style.StyleSpan"))
        XCTAssertTrue(classes.contains("java.lang.ref.WeakReference"))
        XCTAssertTrue(classes.contains("android.content.res.ColorStateList"))
        XCTAssertTrue(classes.contains("java.net.URL"))
        XCTAssertTrue(classes.contains("java.net.URLEncoder"))
        XCTAssertTrue(classes.contains("java.util.Scanner"))
        XCTAssertTrue(classes.contains("java.io.ByteArrayOutputStream"))
        XCTAssertTrue(classes.contains("java.util.Collections"))

        let url = try await self.construct(host, "java.net.URL", [.string("https://example.com/path")])
        let hostName = try await self.invoke(host, url["result"], "getHost")
        XCTAssertEqual(hostName["result"], .string("example.com"))
        let urlEncoder = try await self.invoke(host, self.classTarget("java.net.URLEncoder"), "encode", [.string("a b"), .string("UTF-8")])
        XCTAssertEqual(urlEncoder["result"], .string("a+b"))

        let scanner = try await self.construct(host, "java.util.Scanner", [.string("one two")])
        let first = try await self.invoke(host, scanner["result"], "next")
        XCTAssertEqual(first["result"], .string("one"))
        let unsupportedReader = try await self.invoke(host, scanner["result"], "useDelimiter", [.string(",")])
        XCTAssertEqual(unsupportedReader["error"]["code"], .string("UNSUPPORTED_API"))

        let float = try await self.construct(host, "java.lang.Float", [.number(1.1)])
        let floatValue = try await self.invoke(host, float["result"], "floatValue")
        XCTAssertEqual(floatValue["result"], .number(Double(Float(1.1))))
        let output = try await self.construct(host, "java.io.ByteArrayOutputStream", [.integer(8)])
        _ = try await self.invoke(host, output["result"], "write", [.integer(255)])
        let bytes = try await self.invoke(host, output["result"], "toByteArray")
        XCTAssertEqual(bytes["result"], .array([.integer(-1)]))
        let singleton = try await self.invoke(host, self.classTarget("java.util.Collections"), "singletonList", [.string("item")])
        XCTAssertEqual(singleton["result"]["$class"], .string("java.util.Collections$SingletonList"))
        let singletonItem = try await self.invoke(host, singleton["result"], "get", [.integer(0)])
        XCTAssertEqual(singletonItem["result"], .string("item"))

        let object = try await self.construct(host, "java.lang.Object")
        let weak = try await self.construct(host, "java.lang.ref.WeakReference", [object["result"]])
        let liveTarget = try await self.invoke(host, weak["result"], "get")
        XCTAssertEqual(liveTarget["result"], object["result"])
        _ = try await self.call(host, "java.release", arguments: ["target": object["result"]])
        let releasedTarget = try await self.invoke(host, weak["result"], "get")
        XCTAssertEqual(releasedTarget["result"], .null)

        let color = AyuBridgeValue.integer(Int64(Int32(bitPattern: 0x8012_34AB)))
        let colorList = try await self.invoke(host, self.classTarget("android.content.res.ColorStateList"), "valueOf", [color])
        let defaultColor = try await self.invoke(host, colorList["result"], "getDefaultColor")
        XCTAssertEqual(defaultColor["result"], color)
        let stateful = try await self.invoke(host, colorList["result"], "isStateful")
        XCTAssertEqual(stateful["result"], .bool(false))
        let stateArray = try await self.call(host, "java.array", arguments: ["component": .string("int"), "values": .array([.integer(1)])])
        let stateColor = try await self.invoke(host, colorList["result"], "getColorForState", [stateArray["result"], .integer(-1)])
        XCTAssertEqual(stateColor["result"], color)
    }

    func testTextViewAlignmentAndViewEnabledStateUseNativeControls() async throws {
        let host = self.host()
        try await self.authorize(host)
        let textView = try await self.construct(host, "android.widget.TextView")
        let initialEnabled = try await self.invoke(host, textView["result"], "isEnabled")
        XCTAssertEqual(initialEnabled["result"], .bool(true))
        let disable = try await self.invoke(host, textView["result"], "setEnabled", [.bool(false)])
        XCTAssertEqual(disable["result"], .null)
        let disabled = try await self.invoke(host, textView["result"], "isEnabled")
        XCTAssertEqual(disabled["result"], .bool(false))
        let enable = try await self.invoke(host, textView["result"], "setEnabled", [.bool(true)])
        XCTAssertEqual(enable["result"], .null)

        let invalidEnabled = try await self.invoke(host, textView["result"], "setEnabled", [.integer(1)])
        XCTAssertEqual(invalidEnabled["error"]["code"], .string("INVALID_ARGUMENTS"))
        let setAlignment = try await self.invoke(host, textView["result"], "setTextAlignment", [.integer(4)])
        XCTAssertEqual(setAlignment["result"], .null)
        let invalidAlignment = try await self.invoke(host, textView["result"], "setTextAlignment", [.integer(7)])
        XCTAssertEqual(invalidAlignment["error"]["code"], .string("INVALID_ARGUMENTS"))

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 80))
        let attached = XCTestExpectation(description: "TextView alignment test container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachedResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachedResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": textView["result"]])
        _ = try await self.invoke(host, textView["result"], "getWidth")
        let label = try XCTUnwrap(container.subviews.first?.subviews.first as? UILabel)
        XCTAssertEqual(label.textAlignment, .center)
        let enabledAfterMount = try await self.invoke(host, textView["result"], "isEnabled")
        XCTAssertEqual(enabledAfterMount["result"], .bool(true))

        let editText = try await self.construct(host, "android.widget.EditText")
        let alignment = try await self.invoke(host, editText["result"], "setTextAlignment", [.integer(4)])
        XCTAssertEqual(alignment["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testEditTextGetTextReturnsAnOwnedJavaString() async throws {
        let host = self.host()
        try await self.authorize(host)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 48))
        let attached = XCTestExpectation(description: "EditText string test container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachedResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachedResult, .completed)

        let editText = try await self.construct(host, "android.widget.EditText")
        _ = try await self.call(host, "ui.mount", arguments: ["target": editText["result"]])
        _ = try await self.invoke(host, editText["result"], "setText", [.string("typed 😀")])
        let text = try await self.invoke(host, editText["result"], "getText")
        XCTAssertEqual(text["result"]["$class"], .string("java.lang.String"))
        let stringValue = try await self.invoke(host, text["result"], "toString")
        let stringLength = try await self.invoke(host, text["result"], "length")
        XCTAssertEqual(stringValue["result"], .string("typed 😀"))
        XCTAssertEqual(stringLength["result"], .integer(8))
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

    func testCustomAdapterMethodsAppearInDeclaredReflection() async throws {
        let adapter = AyuBridgeClassAdapter(name: "example.ReflectiveAdapter", constructor: { _, _ in [:] },
            staticMethods: ["staticOperation": { _, _ in .value(.null) }],
            methods: ["instanceOperation": { _, _, _ in .value(.null) }])
        let host = self.host(registry: try .standard.adding([adapter]))
        try await self.authorize(host)

        let target = self.classTarget("example.ReflectiveAdapter")
        let instanceMethod = try await self.invoke(host, target, "getDeclaredMethod", [.string("instanceOperation")])
        XCTAssertEqual(instanceMethod["result"]["$class"], .string("java.lang.reflect.Method"))
        let instanceMethodName = try await self.invoke(host, instanceMethod["result"], "getName")
        XCTAssertEqual(instanceMethodName["result"], .string("instanceOperation"))

        let staticMethod = try await self.invoke(host, target, "getDeclaredMethod", [.string("staticOperation")])
        XCTAssertEqual(staticMethod["result"]["$class"], .string("java.lang.reflect.Method"))

        let allMethods = try await self.invoke(host, target, "getDeclaredMethods")
        let references = try XCTUnwrap(allMethods["result"].array)
        var names = Set<String>()
        for reference in references {
            let name = try await self.invoke(host, reference, "getName")
            if let value = name["result"].string { names.insert(value) }
        }
        XCTAssertTrue(names.contains("instanceOperation"))
        XCTAssertTrue(names.contains("staticOperation"))
    }

    func testFailedDeclaredMethodsReflectionRollsBackHandlesAtLowObjectQuota() async throws {
        let adapter = AyuBridgeClassAdapter(name: "example.QuotaReflectiveAdapter", constructor: { _, _ in [:] },
            methods: [
                "firstOperation": { _, _, _ in .value(.null) },
                "secondOperation": { _, _, _ in .value(.null) },
            ])
        var limits = AyuPluginBridgeLimits()
        limits.objectsPerPlugin = 1
        let host = self.host(limits: limits, registry: try .standard.adding([adapter]))
        try await self.authorize(host)

        let reflection = try await self.invoke(host, self.classTarget("example.QuotaReflectiveAdapter"), "getDeclaredMethods")
        XCTAssertEqual(reflection["error"]["code"], .string("RESOURCE_LIMIT"))

        // If the first Method handle escaped the failed response, this allocation
        // would consume the only object slot and fail too.
        let object = try await self.construct(host, "example.QuotaReflectiveAdapter")
        XCTAssertNotNil(object["result"]["$handle"].string)
    }

    func testOversizedDeclaredMethodsResponseRollsBackReflectionHandles() async throws {
        var methods: [String: AyuBridgeClassAdapter.InstanceMethod] = [:]
        for index in 0..<40 {
            methods["operation\(index)"] = { _, _, _ in .value(.null) }
        }
        let adapter = AyuBridgeClassAdapter(name: "example.LargeReflectiveAdapter",
            constructor: { _, _ in [:] }, methods: methods)
        var limits = AyuPluginBridgeLimits()
        limits.objectsPerPlugin = methods.count
        limits.responseBytes = 4096
        let host = self.host(limits: limits, registry: try .standard.adding([adapter]))
        try await self.authorize(host)

        let reflection = try await self.invoke(host, self.classTarget("example.LargeReflectiveAdapter"), "getDeclaredMethods")
        XCTAssertEqual(reflection["error"]["code"], .string("RESOURCE_LIMIT"))

        // Forty method handles fit the object quota but the array does not fit
        // the response quota. The failed response must leave the slot free.
        let object = try await self.construct(host, "example.LargeReflectiveAdapter")
        XCTAssertNotNil(object["result"]["$handle"].string)
    }

    func testJavaAndReflectArrayRejectAnOversizedSingleArray() async throws {
        var limits = AyuPluginBridgeLimits()
        limits.arrayElementsPerPlugin = 4
        limits.arrayBytesPerPlugin = 64
        let host = self.host(limits: limits)
        try await self.authorize(host)

        let javaArray = try await self.call(host, "java.array", arguments: [
            "component": .string("int"),
            "values": .array([.integer(1), .integer(2), .integer(3), .integer(4), .integer(5)]),
        ])
        XCTAssertEqual(javaArray["error"]["code"], .string("RESOURCE_LIMIT"))

        let reflectArray = try await self.invoke(host, self.classTarget("java.lang.reflect.Array"), "newInstance", [
            .object(["$java_class": .string("int")]), .integer(5),
        ])
        XCTAssertEqual(reflectArray["error"]["code"], .string("RESOURCE_LIMIT"))

        let byteArray = try await self.call(host, "java.array", arguments: [
            "component": .string("java.lang.String"),
            "values": .array([.string(String(repeating: "x", count: 100))]),
        ])
        XCTAssertEqual(byteArray["error"]["code"], .string("RESOURCE_LIMIT"))
    }

    func testEditTextAndCheckBoxAreAssignableToTextViewAndCompoundButtonArrays() async throws {
        let contextAdapter = AyuBridgeClassAdapter(name: "android.content.Context", constructor: { args, _ in
            guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Expected no fixture arguments") }
            return [:]
        })
        let host = self.host(registry: try .standard.adding([contextAdapter]))
        try await self.authorize(host)
        let context = try await self.construct(host, "android.content.Context")
        let editText = try await self.construct(host, "android.widget.EditText")
        let checkBox = try await self.construct(host, "android.widget.CheckBox", [context["result"]])

        let editAsText = try await self.call(host, "java.cast", arguments: [
            "class_name": .string("android.widget.TextView"), "value": editText["result"],
        ])
        XCTAssertEqual(editAsText["result"], editText["result"])
        let checkAsText = try await self.call(host, "java.cast", arguments: [
            "class_name": .string("android.widget.TextView"), "value": checkBox["result"],
        ])
        XCTAssertEqual(checkAsText["result"], checkBox["result"])
        let checkAsCompoundButton = try await self.call(host, "java.cast", arguments: [
            "class_name": .string("android.widget.CompoundButton"), "value": checkBox["result"],
        ])
        XCTAssertEqual(checkAsCompoundButton["result"], checkBox["result"])

        let textArray = try await self.call(host, "java.array", arguments: [
            "component": .string("android.widget.TextView"),
            "values": .array([editText["result"], checkBox["result"]]),
        ])
        XCTAssertEqual(textArray["error"], .null)
        let buttonArray = try await self.call(host, "java.array", arguments: [
            "component": .string("android.widget.CompoundButton"),
            "values": .array([checkBox["result"]]),
        ])
        XCTAssertEqual(buttonArray["error"], .null)

        let textClass = try await self.invoke(host, self.classTarget("java.lang.Class"), "forName", [.string("android.widget.TextView")])
        let classAsTextArrayItem = try await self.call(host, "java.array", arguments: [
            "component": .string("android.widget.TextView"),
            "values": .array([textClass["result"]]),
        ])
        XCTAssertEqual(classAsTextArrayItem["error"]["code"], .string("INVALID_ARGUMENTS"))

        let reflectTextArray = try await self.invoke(host, self.classTarget("java.lang.reflect.Array"), "newInstance", [
            textClass["result"], .integer(2),
        ])
        let setEditText = try await self.invoke(host, self.classTarget("java.lang.reflect.Array"), "set", [
            reflectTextArray["result"], .integer(0), editText["result"],
        ])
        XCTAssertEqual(setEditText["error"], .null)
        let setCheckBox = try await self.invoke(host, self.classTarget("java.lang.reflect.Array"), "set", [
            reflectTextArray["result"], .integer(1), checkBox["result"],
        ])
        XCTAssertEqual(setCheckBox["error"], .null)
        let setClass = try await self.invoke(host, self.classTarget("java.lang.reflect.Array"), "set", [
            reflectTextArray["result"], .integer(0), textClass["result"],
        ])
        XCTAssertEqual(setClass["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testViewPropertyAnimatorAdvertises3DPropertiesAndSupportsNativeLifecycle() async throws {
        let callbackOrder = AyuBridgeTestCallbackOrderBox()
        let firstEnd = XCTestExpectation(description: "first animator end action")
        let secondEnd = XCTestExpectation(description: "second animator end action")
        let canceledEnd = XCTestExpectation(description: "canceled animator end action")
        canceledEnd.isInverted = true
        let host = self.host(callback: { _, callbackID, _ in
            callbackOrder.append(callbackID)
            switch callbackID {
            case "animator-end-first": firstEnd.fulfill()
            case "animator-end-second": secondEnd.fulfill()
            case "animator-end-canceled": canceledEnd.fulfill()
            default: break
            }
        })
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", arguments: ["generation": .string("animator-generation")])

        let viewClass = self.classTarget("android.view.View")
        let viewMethods = ["setRotationX", "setRotationY", "getRotationX", "getRotationY",
                           "setPivotX", "setPivotY", "getPivotX", "getPivotY", "setCameraDistance", "getCameraDistance"]
        for method in viewMethods {
            let reflected = try await self.invoke(host, viewClass, "getDeclaredMethod", [.string(method)])
            XCTAssertEqual(reflected["result"]["$class"], .string("java.lang.reflect.Method"), method)
        }
        let viewDeclared = try await self.invoke(host, viewClass, "getDeclaredMethods")
        let viewMethodReferences = try XCTUnwrap(viewDeclared["result"].array)
        var viewMethodNames = Set<String>()
        for reference in viewMethodReferences {
            let name = try await self.invoke(host, reference, "getName")
            if let value = name["result"].string { viewMethodNames.insert(value) }
        }
        XCTAssertTrue(viewMethodNames.isSuperset(of: viewMethods))

        let animatorClass = self.classTarget("android.view.ViewPropertyAnimator")
        for method in ["rotationX", "rotationY"] {
            let reflected = try await self.invoke(host, animatorClass, "getDeclaredMethod", [.string(method)])
            XCTAssertEqual(reflected["result"]["$class"], .string("java.lang.reflect.Method"), method)
        }
        let advertised = try await self.invoke(host, animatorClass, "getDeclaredMethods")
        let advertisedReferences = try XCTUnwrap(advertised["result"].array)
        var advertisedNames = Set<String>()
        for reference in advertisedReferences {
            let name = try await self.invoke(host, reference, "getName")
            if let value = name["result"].string { advertisedNames.insert(value) }
        }
        XCTAssertTrue(advertisedNames.isSuperset(of: ["rotationX", "rotationY"]))

        let view = try await self.construct(host, "android.view.View")
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 80))
        let attached = XCTestExpectation(description: "animator test container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachedResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachedResult, .completed)
        _ = try await self.call(host, "ui.mount", arguments: ["target": view["result"]])
        _ = try await self.invoke(host, view["result"], "setFrame", [.integer(0), .integer(0), .integer(120), .integer(80)])
        _ = try await self.invoke(host, view["result"], "getWidth")
        _ = try await self.invoke(host, view["result"], "setRotationX", [.number(22)])
        _ = try await self.invoke(host, view["result"], "setRotationY", [.number(-13)])
        _ = try await self.invoke(host, view["result"], "setPivotX", [.number(17)])
        _ = try await self.invoke(host, view["result"], "setPivotY", [.number(29)])
        _ = try await self.invoke(host, view["result"], "setCameraDistance", [.number(6400)])
        let rotationX = try await self.invoke(host, view["result"], "getRotationX")
        let rotationY = try await self.invoke(host, view["result"], "getRotationY")
        let pivotX = try await self.invoke(host, view["result"], "getPivotX")
        let pivotY = try await self.invoke(host, view["result"], "getPivotY")
        let cameraDistance = try await self.invoke(host, view["result"], "getCameraDistance")
        XCTAssertEqual(rotationX["result"], .number(22))
        XCTAssertEqual(rotationY["result"], .number(-13))
        XCTAssertEqual(pivotX["result"], .number(17))
        XCTAssertEqual(pivotY["result"], .number(29))
        XCTAssertEqual(cameraDistance["result"], .number(6400))

        let animator = try await self.invoke(host, view["result"], "animate")
        let firstRunnable = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("java.lang.Runnable")]),
            "callbacks": .object(["run": .object(["$callback": .string("animator-end-first")])]),
        ])
        _ = try await self.invoke(host, animator["result"], "rotationX", [.number(45)])
        _ = try await self.invoke(host, animator["result"], "rotationY", [.number(30)])
        _ = try await self.invoke(host, animator["result"], "setDuration", [.integer(40)])
        _ = try await self.invoke(host, animator["result"], "withEndAction", [firstRunnable["result"]])
        let firstStart = try await self.invoke(host, animator["result"], "start")
        XCTAssertEqual(firstStart["result"], .null)
        let firstEndResult = await XCTWaiter.fulfillment(of: [firstEnd], timeout: 1)
        XCTAssertEqual(firstEndResult, .completed)

        let finalRotationX = try await self.invoke(host, view["result"], "getRotationX")
        let finalRotationY = try await self.invoke(host, view["result"], "getRotationY")
        XCTAssertEqual(finalRotationX["result"], .number(45))
        XCTAssertEqual(finalRotationY["result"], .number(30))

        let secondRunnable = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("java.lang.Runnable")]),
            "callbacks": .object(["run": .object(["$callback": .string("animator-end-second")])]),
        ])
        _ = try await self.invoke(host, animator["result"], "rotationX", [.number(5)])
        _ = try await self.invoke(host, animator["result"], "setDuration", [.integer(40)])
        _ = try await self.invoke(host, animator["result"], "withEndAction", [secondRunnable["result"]])
        let secondStart = try await self.invoke(host, animator["result"], "start")
        XCTAssertEqual(secondStart["result"], .null)
        let secondEndResult = await XCTWaiter.fulfillment(of: [secondEnd], timeout: 1)
        XCTAssertEqual(secondEndResult, .completed)

        let canceledRunnable = try await self.call(host, "java.proxy", arguments: [
            "interfaces": .array([.string("java.lang.Runnable")]),
            "callbacks": .object(["run": .object(["$callback": .string("animator-end-canceled")])]),
        ])
        _ = try await self.invoke(host, animator["result"], "translationX", [.number(40)])
        _ = try await self.invoke(host, animator["result"], "setStartDelay", [.integer(200)])
        _ = try await self.invoke(host, animator["result"], "withEndAction", [canceledRunnable["result"]])
        let delayedStart = try await self.invoke(host, animator["result"], "start")
        XCTAssertEqual(delayedStart["result"], .null)
        _ = try await self.invoke(host, view["result"], "getWidth")
        let canceled = try await self.invoke(host, animator["result"], "cancel")
        XCTAssertEqual(canceled["result"], .null)
        let canceledEndResult = await XCTWaiter.fulfillment(of: [canceledEnd], timeout: 0.35)
        XCTAssertEqual(canceledEndResult, .completed)
        XCTAssertEqual(callbackOrder.values, ["animator-end-first", "animator-end-second"])
    }

    func testUITransactionsRejectDirectOnlyViewMethodsBeforeEnqueue() async throws {
        let host = self.host()
        try await self.authorize(host)
        let textView = try await self.construct(host, "android.widget.TextView")
        let editText = try await self.construct(host, "android.widget.EditText")
        _ = try await self.call(host, "plugin.activate", arguments: ["generation": .string("transaction-generation")])

        let accepted = try await self.call(host, "ui.transaction", arguments: [
            "commands": .array([.object([
                "target": textView["result"],
                "method": .string("setAlpha"),
                "args": .array([.number(0.25)]),
            ])]),
        ])
        XCTAssertEqual(accepted["error"], .null)

        let directOnly: [(AyuBridgeValue, String)] = [
            (editText["result"], "requestFocus"),
            (editText["result"], "setSelection"),
            (textView["result"], "findViewById"),
            (textView["result"], "post"),
            (textView["result"], "postDelayed"),
            (textView["result"], "setTag"),
        ]
        for (target, method) in directOnly {
            let result = try await self.call(host, "ui.transaction", arguments: [
                "commands": .array([.object([
                    "target": target,
                    "method": .string(method),
                    "args": .array([]),
                ])]),
            ])
            XCTAssertEqual(result["error"]["code"], .string("UNSUPPORTED_API"), method)
        }

        // The separate invocation routes remain available; only the batch
        // command path rejects methods the UIKit applier cannot dispatch.
        let focused = try await self.invoke(host, editText["result"], "requestFocus")
        XCTAssertEqual(focused["result"], .bool(false))
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

private final class AyuBridgeTestCallbackOrderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { self.lock.lock(); defer { self.lock.unlock() }; return self.stored }
    func append(_ value: String) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.stored.append(value)
    }
}

private final class AyuBridgeTestTextWatcherBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(String, [AyuBridgeValue])] = []
    private var appendHandler: (() -> Void)?
    var count: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.stored.count }
    var callbackIDs: [String] {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.stored.map(\.0)
    }
    func append(callbackID: String, arguments: [AyuBridgeValue]) {
        self.lock.lock()
        self.stored.append((callbackID, arguments))
        let handler = self.appendHandler
        self.lock.unlock()
        handler?()
    }
    func setOnAppend(_ handler: @escaping () -> Void) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.appendHandler = handler
    }
    func arguments(for callbackID: String) -> [AyuBridgeValue]? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.stored.first(where: { $0.0 == callbackID })?.1
    }
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
