import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// `ui.layout_params`: argument validation, ownership and quota through the host, and the
/// placement the layout engine gives a child that carries the parameters.
@MainActor
final class AyuBridgeLayoutParamsTests: XCTestCase {
    private static let frame = "android.widget.FrameLayout$LayoutParams"
    private static let linear = "android.widget.LinearLayout$LayoutParams"
    nonisolated private static let leftToRight = AyuBridgeLayoutParams.Environment(isRightToLeft: false, screenScale: 3)
    nonisolated private static let rightToLeft = AyuBridgeLayoutParams.Environment(isRightToLeft: true, screenScale: 2)

    private func request(_ arguments: [String: AyuBridgeValue], _ environment: AyuBridgeLayoutParams.Environment? = nil) throws -> AyuBridgeLayoutParams.Request {
        try AyuBridgeLayoutParams.request(arguments) { environment ?? Self.leftToRight }
    }

    private func code(_ arguments: [String: AyuBridgeValue]) -> String? {
        do { _ = try self.request(arguments); return nil }
        catch { return (error as? AyuBridgeFailure)?.code }
    }

    func testSizesWeightAndMarginsAreStoredInPoints() throws {
        let frame = try self.request(["kind": .string("frame"), "width": .integer(-1), "height": .number(40.5)])
        XCTAssertEqual(frame, AyuBridgeLayoutParams.Request(className: Self.frame, fields: ["width": .number(-1), "height": .number(41)]))

        let linear = try self.request(["kind": .string("linear"), "width": .integer(0), "height": .integer(-2), "weight": .number(1.5),
                                       "gravity": .integer(17), "margins": .array([.number(0.5), .number(-0.5), .integer(8), .integer(-4)])])
        XCTAssertEqual(linear.className, Self.linear)
        XCTAssertEqual(linear.fields, ["width": .number(0), "height": .number(-2), "weight": .number(1.5), "gravity": .integer(17),
                                       "margins": .array([.number(1), .number(0), .number(8), .number(-4)])])
        XCTAssertEqual(try self.request(["kind": .string("linear"), "width": .integer(1), "height": .integer(1)]).fields["weight"], .number(0))
    }

    func testEnvironmentIsReadOnlyForRelativeOrPixelMargins() throws {
        var reads = 0
        _ = try AyuBridgeLayoutParams.request(["kind": .string("frame"), "width": .integer(1), "height": .integer(1), "gravity": .integer(0x0080_0003),
                                               "margins": .array([.integer(1), .integer(2), .integer(3), .integer(4)])]) { reads += 1; return Self.rightToLeft }
        XCTAssertEqual(reads, 0)
        _ = try AyuBridgeLayoutParams.request(["kind": .string("frame"), "width": .integer(1), "height": .integer(1), "relative": .bool(true)]) { reads += 1; return Self.rightToLeft }
        XCTAssertEqual(reads, 1)
    }

    func testRelativeResolvesStartAndEndForTheInterfaceDirection() throws {
        let arguments: [String: AyuBridgeValue] = ["kind": .string("frame"), "width": .integer(40), "height": .integer(40), "relative": .bool(true),
            "gravity": .integer(0x0080_0033), "margins": .array([.integer(1), .integer(2), .integer(3), .integer(4)])]
        let leftToRight = try self.request(arguments)
        XCTAssertEqual(leftToRight.fields["gravity"], .integer(0x33))
        XCTAssertEqual(leftToRight.fields["margins"], .array([.number(1), .number(2), .number(3), .number(4)]))
        let rightToLeft = try self.request(arguments, Self.rightToLeft)
        XCTAssertEqual(rightToLeft.fields["gravity"], .integer(0x35))
        XCTAssertEqual(rightToLeft.fields["margins"], .array([.number(3), .number(2), .number(1), .number(4)]))

        var end = arguments
        end["gravity"] = .integer(0x0080_0005)
        XCTAssertEqual(try self.request(end, Self.rightToLeft).fields["gravity"], .integer(3))
        // Without `relative` the flags are kept as given and the margins stay left and right.
        var absolute = arguments
        absolute["relative"] = nil
        let kept = try self.request(absolute, Self.rightToLeft)
        XCTAssertEqual(kept.fields["gravity"], .integer(0x0080_0033))
        XCTAssertEqual(kept.fields["margins"], .array([.number(1), .number(2), .number(3), .number(4)]))
    }

    func testPixelMarginsAreDividedByTheScreenScale() throws {
        let arguments: [String: AyuBridgeValue] = ["kind": .string("frame"), "width": .integer(-1), "height": .integer(-2), "margins_in_pixels": .bool(true),
            "margins": .array([.integer(3), .integer(6), .integer(-9), .integer(1)])]
        XCTAssertEqual(try self.request(arguments).fields["margins"], .array([.number(1), .number(2), .number(-3), .number(1.0 / 3.0)]))
        var relative = arguments
        relative["relative"] = .bool(true)
        XCTAssertEqual(try self.request(relative, Self.rightToLeft).fields["margins"], .array([.number(-4.5), .number(3), .number(1.5), .number(0.5)]))
        XCTAssertEqual(self.code(arguments.merging(["margins": .array([.integer(1)])]) { $1 }), "INVALID_ARGUMENTS")
        do {
            _ = try self.request(arguments, AyuBridgeLayoutParams.Environment(isRightToLeft: false, screenScale: 0))
            XCTFail("A missing screen scale must not produce margins")
        } catch { XCTAssertEqual((error as? AyuBridgeFailure)?.code, "SCREEN_UNAVAILABLE") }
    }

    func testMalformedArgumentsAreRejected() {
        let base: [String: AyuBridgeValue] = ["kind": .string("frame"), "width": .integer(-1), "height": .integer(-2)]
        func with(_ key: String, _ value: AyuBridgeValue?) -> [String: AyuBridgeValue] { var copy = base; copy[key] = value; return copy }
        XCTAssertNil(self.code(base))
        let malformed: [[String: AyuBridgeValue]] = [
            with("kind", nil), with("kind", .string("relative")), with("width", nil), with("height", .string("-1")),
            with("width", .integer(-3)), with("width", .number(-1.5)), with("height", .integer(100_001)),
            with("weight", .number(1)), with("padding", .integer(1)),
            with("gravity", .number(17.5)), with("gravity", .string("17")), with("gravity", .integer(-2)),
            with("gravity", .integer(2)), with("gravity", .integer(0x60)), with("gravity", .integer(0x100)),
            with("margins", .array([.integer(1), .integer(2), .integer(3)])), with("margins", .integer(4)),
            with("margins", .array([.integer(1), .integer(2), .integer(3), .integer(100_001)])),
            with("margins", .array([.integer(1), .integer(2), .integer(3), .string("4")])),
            with("relative", .bool(false)), with("margins_in_pixels", .integer(1)),
        ]
        for arguments in malformed { XCTAssertEqual(self.code(arguments), "INVALID_ARGUMENTS", "\(arguments)") }
        var linear = base
        linear["kind"] = .string("linear")
        for weight in [AyuBridgeValue.number(-1), .number(100_001), .string("1")] {
            linear["weight"] = weight
            XCTAssertEqual(self.code(linear), "INVALID_ARGUMENTS")
        }
        // Clip flags are valid Android gravity the engine does not serve.
        for clip: Int64 in [0x08, 0x80, 0x0100_0000, 0x1000_0011] { XCTAssertEqual(self.code(with("gravity", .integer(clip))), "UNSUPPORTED_API") }
        // -1 is Android's unspecified gravity: no gravity is stored.
        XCTAssertNil(try? self.request(with("gravity", .integer(-1))).fields["gravity"])
    }

    func testFramePlacementFollowsAndroid() {
        let container = CGSize(width: 200, height: 100), size = CGSize(width: 40, height: 20)
        let margins: AyuBridgeLayoutParams.Margins = (10, 6, 4, 2)
        func origin(_ gravity: Int64?) -> CGPoint { AyuBridgeLayoutParams.frameOrigin(gravity: gravity, container: container, size: size, margins: margins) }
        XCTAssertEqual(origin(nil), CGPoint(x: 10, y: 6))
        XCTAssertEqual(origin(0), CGPoint(x: 10, y: 6))
        XCTAssertEqual(origin(17), CGPoint(x: 86, y: 44))
        XCTAssertEqual(origin(0x55), CGPoint(x: 156, y: 78))
        XCTAssertEqual(origin(0x31), CGPoint(x: 86, y: 6))
        XCTAssertEqual(origin(0x15), CGPoint(x: 156, y: 44))
        // Fill is not a position: FrameLayout falls back to left and top.
        XCTAssertEqual(origin(0x77), CGPoint(x: 10, y: 6))
        // A stored START/END is left/right: only `relative` parameters follow the interface direction.
        XCTAssertEqual(origin(0x0080_0003), CGPoint(x: 10, y: 6))
        XCTAssertEqual(origin(0x0080_0005), CGPoint(x: 156, y: 6))
        XCTAssertEqual(AyuBridgeLayoutParams.absoluteGravity(0x0080_0013, rightToLeft: true), 0x15)
        XCTAssertEqual(AyuBridgeLayoutParams.absoluteGravity(0x0080_0001, rightToLeft: true), 0x01)
        XCTAssertEqual(AyuBridgeLayoutParams.absoluteGravity(0x55, rightToLeft: true), 0x55)
    }

    func testLinearAndScrollPlacementFollowAndroid() {
        // The horizontal pass ignores the top margin of a child whose gravity has no vertical part.
        XCTAssertEqual(AyuBridgeLayoutParams.verticalOrigin(gravity: 0, container: 100, extent: 20, top: 6, bottom: 2, linear: true), 0)
        XCTAssertEqual(AyuBridgeLayoutParams.verticalOrigin(gravity: 0x30, container: 100, extent: 20, top: 6, bottom: 2, linear: true), 6)
        XCTAssertEqual(AyuBridgeLayoutParams.verticalOrigin(gravity: 0x10, container: 100, extent: 20, top: 6, bottom: 2, linear: true), 44)
        XCTAssertEqual(AyuBridgeLayoutParams.verticalOrigin(gravity: 0x50, container: 100, extent: 20, top: 6, bottom: 2, linear: true), 78)
        XCTAssertEqual(AyuBridgeLayoutParams.verticalOrigin(gravity: 0, container: 100, extent: 20, top: 6, bottom: 2), 6)

        let margins: AyuBridgeLayoutParams.Margins = (10, 6, 4, 2)
        let viewport = CGSize(width: 200, height: 100)
        XCTAssertEqual(AyuBridgeLayoutParams.scrollOrigin(gravity: 17, vertical: true, container: viewport, size: CGSize(width: 40, height: 20), margins: margins), CGPoint(x: 86, y: 44))
        XCTAssertEqual(AyuBridgeLayoutParams.scrollOrigin(gravity: 17, vertical: true, container: viewport, size: CGSize(width: 40, height: 300), margins: margins), CGPoint(x: 86, y: 6))
        XCTAssertEqual(AyuBridgeLayoutParams.scrollOrigin(gravity: 17, vertical: false, container: viewport, size: CGSize(width: 400, height: 20), margins: margins), CGPoint(x: 10, y: 44))
        XCTAssertEqual(AyuBridgeLayoutParams.scrollOrigin(gravity: nil, vertical: true, container: viewport, size: CGSize(width: 40, height: 20), margins: margins), CGPoint(x: 10, y: 6))
    }

    // MARK: - Through the host

    private func host(limits: AyuPluginBridgeLimits = AyuPluginBridgeLimits()) -> AyuPluginNativeHost {
        AyuPluginNativeHost(defaults: UserDefaults(suiteName: "AyuBridgeLayoutParamsTests." + UUID().uuidString)!, limits: limits,
            trustedOwner: { "alpha" }, callback: { _, _, _ in })
    }

    private func call(_ host: AyuPluginNativeHost, _ operation: String, owner: String = "alpha", _ arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        let request = AyuBridgeValue.object(["version": .integer(1), "id": .string("1"), "plugin_id": .string(owner),
            "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        let response: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: host.dispatch(text, owner: owner)) }
        }
        return try JSONDecoder().decode(AyuBridgeValue.self, from: Data(response.utf8))
    }

    private func authorize(_ host: AyuPluginNativeHost, owner: String = "alpha") async throws {
        let result = try await self.call(host, "plugin.authorize", owner: owner, ["metadata": .object(["id": .string(owner)]), "classes": .array([]),
            "requirements": .array([]), "imports": .array([])])
        XCTAssertEqual(result["result"], .bool(true))
    }

    private func view(_ host: AyuPluginNativeHost, _ name: String) async throws -> AyuBridgeValue {
        let made = try await self.call(host, "java.construct", ["class_name": .string("android.widget." + name), "args": .array([])])
        return try XCTUnwrap(made["result"].object.map(AyuBridgeValue.object))
    }

    private func invoke(_ host: AyuPluginNativeHost, _ target: AyuBridgeValue, _ name: String, _ args: [AyuBridgeValue] = []) async throws -> AyuBridgeValue {
        try await self.call(host, "java.invoke", ["target": target, "name": .string(name), "args": .array(args)])
    }

    private func params(_ host: AyuPluginNativeHost, _ kind: String, _ width: Int64, _ height: Int64, _ rest: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        var arguments = rest
        arguments["kind"] = .string(kind); arguments["width"] = .integer(width); arguments["height"] = .integer(height)
        let made = try await self.call(host, "ui.layout_params", arguments)
        XCTAssertNil(made["error"].object, "\(made)")
        return made["result"]
    }

    private func mount(_ host: AyuPluginNativeHost, _ root: AyuBridgeValue, size: CGSize) async throws -> UIView {
        let container = UIView(frame: CGRect(origin: .zero, size: size))
        let attached = XCTestExpectation(description: "mount container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [attached], timeout: 1.0)
        XCTAssertEqual(result, .completed)
        let mounted = try await self.call(host, "ui.mount", ["target": root])
        XCTAssertEqual(mounted["result"], .null)
        return container
    }

    private func frame(_ host: AyuPluginNativeHost, _ view: AyuBridgeValue) async throws -> CGRect {
        var values: [Double] = []
        for method in ["getX", "getY", "getWidth", "getHeight"] {
            let read = try await self.invoke(host, view, method)
            values.append(try XCTUnwrap(read["result"].number, "\(read)"))
        }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    func testOperationIsDeclaredOwnedAndBounded() async throws {
        var limits = AyuPluginBridgeLimits()
        limits.objectsPerPlugin = 2
        let host = self.host(limits: limits)
        let unauthorized = try await self.call(host, "ui.layout_params", ["kind": .string("frame"), "width": .integer(-1), "height": .integer(-1)])
        XCTAssertEqual(unauthorized["error"]["code"], .string("UNAUTHORIZED"))
        try await self.authorize(host)
        try await self.authorize(host, owner: "beta")
        let capabilities = try await self.call(host, "runtime.capabilities")
        XCTAssertEqual(capabilities["result"]["operations"].array?.contains(.string("ui.layout_params")), true)

        let frame = try await self.params(host, "frame", -1, 48, ["gravity": .integer(17)])
        XCTAssertEqual(frame["$class"], .string(Self.frame))
        let linear = try await self.params(host, "linear", -1, -2, ["weight": .number(1)])
        XCTAssertEqual(linear["$class"], .string(Self.linear))
        let gravity = try await self.call(host, "java.get_field", ["target": frame, "name": .string("gravity")])
        XCTAssertEqual(gravity["result"], .integer(17))
        let foreign = try await self.call(host, "java.get_field", owner: "beta", ["target": frame, "name": .string("gravity")])
        XCTAssertEqual(foreign["error"]["code"], .string("INVALID_HANDLE"))
        let overQuota = try await self.call(host, "ui.layout_params", ["kind": .string("frame"), "width": .integer(-1), "height": .integer(-1)])
        XCTAssertEqual(overQuota["error"]["code"], .string("RESOURCE_LIMIT"))
        let malformed = try await self.call(host, "ui.layout_params", ["kind": .string("frame"), "width": .integer(-1)])
        XCTAssertEqual(malformed["error"]["code"], .string("INVALID_ARGUMENTS"))
        let clipped = try await self.call(host, "ui.layout_params", ["kind": .string("frame"), "width": .integer(-1), "height": .integer(-1), "gravity": .integer(0x88)])
        XCTAssertEqual(clipped["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testFrameChildrenAreLaidOutByGravityAndMargins() async throws {
        let host = self.host()
        try await self.authorize(host)
        let root = try await self.view(host, "FrameLayout")
        let centered = try await self.view(host, "FrameLayout"), corner = try await self.view(host, "FrameLayout"), plain = try await self.view(host, "FrameLayout")
        let margins = AyuBridgeValue.array([.integer(10), .integer(6), .integer(4), .integer(2)])
        let centeredParams = try await self.params(host, "frame", 40, 20, ["gravity": .integer(17), "margins": margins])
        let cornerParams = try await self.params(host, "frame", 40, 20, ["gravity": .integer(0x55), "margins": margins])
        let plainParams = try await self.params(host, "frame", -1, 20, ["margins": margins])
        for (child, layout) in [(centered, centeredParams), (corner, cornerParams), (plain, plainParams)] {
            let added = try await self.invoke(host, root, "addView", [child, layout])
            XCTAssertEqual(added["result"], .null, "\(added)")
        }
        let linearParams = try await self.params(host, "linear", -1, -1)
        let mismatch = try await self.invoke(host, root, "addView", [try await self.view(host, "FrameLayout"), linearParams])
        XCTAssertEqual(mismatch["error"]["code"], .string("INVALID_ARGUMENTS"))
        _ = try await self.mount(host, root, size: CGSize(width: 200, height: 100))

        let centeredFrame = try await self.frame(host, centered)
        XCTAssertEqual(centeredFrame, CGRect(x: 86, y: 44, width: 40, height: 20))
        let cornerFrame = try await self.frame(host, corner)
        XCTAssertEqual(cornerFrame, CGRect(x: 156, y: 78, width: 40, height: 20))
        let plainFrame = try await self.frame(host, plain)
        XCTAssertEqual(plainFrame, CGRect(x: 10, y: 6, width: 186, height: 20))

        // Fields of the owned parameters reach the attached view, as `setMargins` does.
        let moved = try await self.call(host, "java.set_field", ["target": centeredParams, "name": .string("gravity"), "value": .integer(0x33)])
        XCTAssertEqual(moved["result"], .null)
        let widened = try await self.call(host, "java.set_field", ["target": centeredParams, "name": .string("leftMargin"), "value": .integer(30)])
        XCTAssertEqual(widened["result"], .null)
        let movedFrame = try await self.frame(host, centered)
        XCTAssertEqual(movedFrame, CGRect(x: 30, y: 6, width: 40, height: 20))
        let leftMargin = try await self.call(host, "java.get_field", ["target": centeredParams, "name": .string("leftMargin")])
        XCTAssertEqual(leftMargin["result"].number, 30)
        let unset = try await self.call(host, "java.get_field", ["target": plainParams, "name": .string("gravity")])
        XCTAssertEqual(unset["result"], .integer(-1))
        let badGravity = try await self.call(host, "java.set_field", ["target": centeredParams, "name": .string("gravity"), "value": .integer(0x100)])
        XCTAssertEqual(badGravity["error"]["code"], .string("INVALID_ARGUMENTS"))
        let badMargin = try await self.call(host, "java.set_field", ["target": centeredParams, "name": .string("topMargin"), "value": .string("6")])
        XCTAssertEqual(badMargin["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testLinearChildrenUseTheirOwnGravityAndWeight() async throws {
        let host = self.host()
        try await self.authorize(host)
        let root = try await self.view(host, "LinearLayout")
        let vertical = try await self.invoke(host, root, "setOrientation", [.integer(1)])
        XCTAssertEqual(vertical["result"], .null)
        let fixed = try await self.view(host, "FrameLayout"), flexible = try await self.view(host, "FrameLayout"), heavier = try await self.view(host, "FrameLayout")
        let fixedParams = try await self.params(host, "linear", 40, 20, ["gravity": .integer(5), "margins": .array([.integer(0), .integer(0), .integer(8), .integer(0)])])
        let flexibleParams = try await self.params(host, "linear", 40, 0, ["weight": .number(1), "gravity": .integer(1)])
        let heavierParams = try await self.params(host, "linear", -1, 0, ["weight": .number(3)])
        for (child, layout) in [(fixed, fixedParams), (flexible, flexibleParams), (heavier, heavierParams)] {
            let added = try await self.invoke(host, root, "addView", [child, layout])
            XCTAssertEqual(added["result"], .null, "\(added)")
        }
        let frameParams = try await self.params(host, "frame", -1, -1)
        let mismatch = try await self.invoke(host, root, "addView", [try await self.view(host, "FrameLayout"), frameParams])
        XCTAssertEqual(mismatch["error"]["code"], .string("INVALID_ARGUMENTS"))
        _ = try await self.mount(host, root, size: CGSize(width: 200, height: 100))

        let fixedFrame = try await self.frame(host, fixed)
        XCTAssertEqual(fixedFrame, CGRect(x: 152, y: 0, width: 40, height: 20))
        let flexibleFrame = try await self.frame(host, flexible)
        XCTAssertEqual(flexibleFrame, CGRect(x: 80, y: 20, width: 40, height: 20))
        let heavierFrame = try await self.frame(host, heavier)
        XCTAssertEqual(heavierFrame, CGRect(x: 0, y: 40, width: 200, height: 60))
    }
}
