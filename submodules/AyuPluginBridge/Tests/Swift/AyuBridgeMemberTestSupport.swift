import Foundation
import UIKit
import XCTest
@testable import AyuPluginBridge

/// One authorized plugin session (`alpha`) on a native host, with the Java operations the
/// member tests use. Results are unwrapped; a host error is thrown as `AyuBridgeFailure`.
@MainActor
final class AyuMemberTestHost {
    let host: AyuPluginNativeHost
    let callbacks = AyuTestBox<[(id: String, arguments: [AyuBridgeValue])]>([])
    private var container: UIView?

    init(provider: AyuPluginHostProvider = AyuUnsupportedPluginHostProvider(), registry: AyuBridgeClassRegistry = .standard) async throws {
        let callbacks = self.callbacks
        self.host = AyuPluginNativeHost(defaults: UserDefaults(suiteName: "AyuBridgeMemberTests." + UUID().uuidString)!, provider: provider,
            classRegistry: registry, trustedOwner: { "alpha" }, callback: { _, id, arguments in callbacks.update { $0.append((id, arguments)) } })
        ayuExpect(try await self.call("plugin.authorize", ["metadata": .object(["id": .string("alpha")]), "classes": .array([]),
                                                               "requirements": .array([]), "imports": .array([])]), .bool(true))
        ayuExpect(try await self.call("plugin.activate", ["metadata": .object(["id": .string("alpha")]), "generation": .string("g1")]), .null)
    }

    func call(_ operation: String, _ arguments: [String: AyuBridgeValue] = [:], owner: String = "alpha", pluginID: String = "alpha") async throws -> AyuBridgeValue {
        let body: AyuBridgeValue = .object(["version": .integer(1), "id": .string("7"), "plugin_id": .string(pluginID), "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        let host = self.host
        let answer = await Task.detached(priority: .userInitiated) { host.dispatch(text, owner: owner) }.value
        let response = try JSONDecoder().decode(AyuBridgeValue.self, from: Data(answer.utf8))
        if let code = response["error"]["code"].string { throw AyuBridgeFailure(code, response["error"]["message"].string ?? "") }
        return response["result"]
    }

    static func type(_ name: String) -> AyuBridgeValue { .object(["class_name": .string(name)]) }

    func construct(_ name: String, _ args: [AyuBridgeValue] = []) async throws -> AyuBridgeValue {
        try await self.call("java.construct", ["class_name": .string(name), "args": .array(args)])
    }

    func invoke(_ target: AyuBridgeValue, _ method: String, _ args: [AyuBridgeValue] = []) async throws -> AyuBridgeValue {
        try await self.call("java.invoke", ["target": target, "name": .string(method), "args": .array(args)])
    }

    func invokeStatic(_ className: String, _ method: String, _ args: [AyuBridgeValue] = []) async throws -> AyuBridgeValue {
        try await self.invoke(Self.type(className), method, args)
    }

    /// A static field or constant of a class.
    func field(_ className: String, _ name: String) async throws -> AyuBridgeValue {
        let member = try await self.call("java.member", ["target": Self.type(className), "name": .string(name)])
        XCTAssertEqual(member["kind"], .string("field"), name)
        return member["value"]
    }

    func array(_ component: String, _ values: [AyuBridgeValue]) async throws -> AyuBridgeValue {
        try await self.call("java.array", ["component": .string(component), "values": .array(values)])
    }

    func proxy(_ interface: String, _ callbacks: [String: String]) async throws -> AyuBridgeValue {
        try await self.call("java.proxy", ["interfaces": .array([.string(interface)]),
                                         "callbacks": .object(callbacks.mapValues { .object(["$callback": .string($0)]) })])
    }

    /// The code of the failure a call ends with, or nil when it succeeds.
    func failure(_ body: () async throws -> AyuBridgeValue) async -> String? {
        do { _ = try await body(); return nil } catch let error as AyuBridgeFailure { return error.code } catch { return "\(error)" }
    }

    /// Mounts `view` as the plugin's root in a container of `size` and returns its native view.
    func mount(_ view: AyuBridgeValue, size: CGSize = CGSize(width: 240, height: 160)) async throws -> AyuBridgeView {
        let container = UIView(frame: CGRect(origin: .zero, size: size))
        self.container = container
        let attached = XCTestExpectation(description: "mount container attached")
        self.host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let waited = await XCTWaiter.fulfillment(of: [attached], timeout: 2)
        XCTAssertEqual(waited, .completed)
        _ = try await self.call("ui.mount", ["target": view])
        try await self.flush(view)
        return try XCTUnwrap(container.subviews.first as? AyuBridgeView)
    }

    /// Applies every queued UI command and lays the hierarchy out.
    func flush(_ view: AyuBridgeValue) async throws {
        _ = try await self.invoke(view, "getWidth")
    }

    /// Waits until the host worker has handed over the callbacks queued so far.
    func deliveredCallbacks(count: Int, timeout: TimeInterval = 2) async -> [(id: String, arguments: [AyuBridgeValue])] {
        let deadline = Date().addingTimeInterval(timeout)
        while self.callbacks.value.count < count, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return self.callbacks.value
    }
}

/// `XCTAssertEqual` whose first argument may be awaited: it is evaluated before the call.
/// A whole floating-point result is decoded as an integer here, so numbers compare by value.
func ayuExpect(_ value: AyuBridgeValue, _ expected: AyuBridgeValue, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    if case let .number(number) = expected, let actual = value.number {
        XCTAssertEqual(actual, number, accuracy: 1e-9, message, file: file, line: line)
    } else {
        XCTAssertEqual(value, expected, message, file: file, line: line)
    }
}

extension AyuBridgeAdapterContext {
    /// A context whose references resolve from `objects`, keyed by handle.
    static func memberTests(_ objects: [String: AyuBridgeAdapterSnapshot] = [:]) -> AyuBridgeAdapterContext {
        AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in throw AyuBridgeFailure.unsupported("callback") }, resolve: { reference in
            guard let handle = reference.object?["$handle"]?.string, let snapshot = objects[handle] else {
                throw AyuBridgeFailure("invalid_handle", "Unknown test reference")
            }
            return snapshot
        })
    }
}

extension UIFont {
    /// The weight trait of the font's descriptor.
    var ayuTestWeight: CGFloat {
        let traits = self.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }
}
