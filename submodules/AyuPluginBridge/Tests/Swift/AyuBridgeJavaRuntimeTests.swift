import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Facade regressions for local utility models and explicitly integrated
/// adapters. Visual view APIs are exercised through the native host tests.
/// No interpreter, no account.
final class AyuBridgeJavaRuntimeTests: XCTestCase {
    private var registry: AyuBridgeClassRegistry!

    override func setUpWithError() throws {
        self.registry = .standard
    }

    // Bundle

    func testBundleRoundTripAndDefaults() throws {
        let adapter = self.runtimeAdapter("android.os.Bundle")
        XCTAssertNotNil(adapter)
        var state = try self.constructor(adapter)
        _ = try adapter.methods["putString"]?(&state, [.string("k"), .string("v")], context())
        _ = try adapter.methods["putInt"]?(&state, [.string("n"), .integer(5)], context())
        XCTAssertEqual(try adapter.methods["getString"]?(state, [.string("k")], context()), .value(.string("v")))
        XCTAssertEqual(try adapter.methods["getInt"]?(state, [.string("n")], context()), .value(.integer(5)))
        XCTAssertEqual(try adapter.methods["getInt"]?(state, [.string("missing"), .integer(9)], context()), .value(.integer(9)))
        XCTAssertEqual(try adapter.methods["getString"]?(state, [.string("missing")], context()), .value(.null))
        XCTAssertEqual(try adapter.methods["isEmpty"]?(state, [], context()), .value(.bool(false)))
    }

    func testBundleRejectsWrongTypes() throws {
        let adapter = self.runtimeAdapter("android.os.Bundle")
        var state = try self.constructor(adapter)
        XCTAssertThrowsError(try adapter.methods["putInt"]?(&state, [.string("k"), .string("5")], context()))
        XCTAssertThrowsError(try adapter.methods["putString"]?(&state, [.string("k"), .integer(5)], context()))
    }

    // Intent

    func testIntentActionExtrasFlags() throws {
        let adapter = self.runtimeAdapter("android.content.Intent")
        var state = try self.constructor(adapter, [.string("android.intent.action.SEND")])
        XCTAssertEqual(try adapter.methods["getAction"]?(state, [], context()), .value(.string("android.intent.action.SEND")))
        _ = try adapter.methods["putExtra"]?(&state, [.string("url"), .string("https://ml.ai")], context())
        XCTAssertEqual(try adapter.methods["getStringExtra"]?(state, [.string("url")], context()), .value(.string("https://ml.ai")))
        XCTAssertEqual(try adapter.methods["hasExtra"]?(state, [.string("url")], context()), .value(.bool(true)))
        XCTAssertEqual(try adapter.methods["hasExtra"]?(state, [.string("nope")], context()), .value(.bool(false)))
        _ = try adapter.methods["addFlags"]?(&state, [.integer(0x1000_0000)], context())
        XCTAssertEqual(try adapter.methods["getFlags"]?(state, [], context()), .value(.integer(0x1000_0000)))
        XCTAssertThrowsError(try self.constructor(adapter, [.integer(1)]))
    }

    func testIntentPutExtraOverloadCountIsExplicit() throws {
        let adapter = self.runtimeAdapter("android.content.Intent")
        var state = try self.constructor(adapter)
        XCTAssertThrowsError(try adapter.methods["putExtra"]?(&state, [.string("k")], context()))
        XCTAssertThrowsError(try adapter.methods["putExtra"]?(&state, [.string("k"), .string("v"), .integer(3)], context()))
    }

    // Uri

    func testUriParseAndReadCommonComponentsWithoutOpeningIt() throws {
        let adapter = self.runtimeAdapter("android.net.Uri")
        let parse = try XCTUnwrap(adapter.staticMethods["parse"])
        guard case let .instance(className, state) = try parse([.string("https://example.com/a%20b/caf%C3%A9?item=first&item=second#details")], context()) else {
            return XCTFail("Uri.parse should return an owned value descriptor")
        }
        XCTAssertEqual(className, "android.net.Uri")
        XCTAssertEqual(try adapter.methods["toString"]?(state, [], context()), .value(.string("https://example.com/a%20b/caf%C3%A9?item=first&item=second#details")))
        XCTAssertEqual(try adapter.methods["getScheme"]?(state, [], context()), .value(.string("https")))
        XCTAssertEqual(try adapter.methods["getHost"]?(state, [], context()), .value(.string("example.com")))
        XCTAssertEqual(try adapter.methods["getPath"]?(state, [], context()), .value(.string("/a b/café")))
        XCTAssertEqual(try adapter.methods["getEncodedPath"]?(state, [], context()), .value(.string("/a%20b/caf%C3%A9")))
        XCTAssertEqual(try adapter.methods["getLastPathSegment"]?(state, [], context()), .value(.string("café")))
        XCTAssertEqual(try adapter.methods["getQueryParameter"]?(state, [.string("item")], context()), .value(.string("first")))
        XCTAssertEqual(try adapter.methods["getQueryParameter"]?(state, [.string("missing")], context()), .value(.null))
        XCTAssertEqual(try adapter.methods["getFragment"]?(state, [], context()), .value(.string("details")))
    }

    func testUriRejectsUnsupportedOverloadsAndOversizedValues() throws {
        let adapter = self.runtimeAdapter("android.net.Uri")
        let parse = try XCTUnwrap(adapter.staticMethods["parse"])
        XCTAssertThrowsError(try parse([], context()))
        XCTAssertThrowsError(try parse([.integer(5)], context()))
        XCTAssertThrowsError(try parse([.string(String(repeating: "x", count: 8_193))], context()))
        guard case let .instance(_, state) = try parse([.string("relative/path")], context()) else {
            return XCTFail("Relative URIs are valid values")
        }
        XCTAssertThrowsError(try adapter.methods["getQueryParameter"]?(state, [], context()))
        XCTAssertThrowsError(try adapter.methods["getQueryParameter"]?(state, [.string("")], context()))
    }

    func testColorDrawableAcceptsJavaSignedArgbColors() throws {
        let adapter = self.runtimeAdapter("android.graphics.drawable.ColorDrawable")
        var state = try self.constructor(adapter, [.integer(-16_777_216)])
        XCTAssertEqual(state["color"], .integer(-16_777_216))
        XCTAssertEqual(try adapter.methods["getColor"]?(state, [], context()), .value(.integer(-16_777_216)))
        _ = try adapter.methods["setColor"]?(&state, [.integer(0xFFFF_FFFF)], context())
        XCTAssertEqual(state["color"], .integer(0xFFFF_FFFF))
        XCTAssertThrowsError(try self.constructor(adapter, [.integer(Int64(Int32.min) - 1)]))
        XCTAssertThrowsError(try self.constructor(adapter, [.integer(0x1_0000_0000)]))
    }

    func testColorFactoriesReturnSignedArgbValues() throws {
        let adapter = self.runtimeAdapter("android.graphics.Color")
        XCTAssertEqual(try adapter.staticMethods["argb"]?([.integer(128), .integer(255), .integer(16), .integer(1)], context()), .value(.integer(Int64(Int32(bitPattern: 0x80FF_1001)))))
        XCTAssertEqual(try adapter.staticMethods["rgb"]?([.integer(255), .integer(255), .integer(255)], context()), .value(.integer(-1)))
        XCTAssertEqual(try adapter.staticMethods["parseColor"]?([.string("#112233")], context()), .value(.integer(Int64(Int32(bitPattern: 0xFF11_2233)))))
        XCTAssertEqual(try adapter.staticMethods["parseColor"]?([.string("transparent")], context()), .value(.integer(0)))
        XCTAssertEqual(try adapter.staticMethods["HSVToColor"]?([.array([.number(0), .number(1), .number(1)])], context()), .value(.integer(-65_536)))
        XCTAssertThrowsError(try adapter.staticMethods["rgb"]?([.integer(256), .integer(0), .integer(0)], context()))
        XCTAssertThrowsError(try adapter.staticMethods["parseColor"]?([.string("#12345")], context()))
    }

    // View

    func testViewVisibilityAndTransforms() throws {
        let adapter = self.runtimeAdapter("android.view.View")
        var state: [String: AyuBridgeValue] = [:]
        _ = try adapter.methods["setVisibility"]?(&state, [.integer(8)], context())
        XCTAssertEqual(try adapter.methods["getVisibility"]?(state, [], context()), .value(.integer(8)))
        XCTAssertThrowsError(try adapter.methods["setVisibility"]?(&state, [.integer(3)], context()))
        _ = try adapter.methods["setAlpha"]?(&state, [.number(0.5)], context())
        XCTAssertThrowsError(try adapter.methods["setAlpha"]?(&state, [.number(1.5)], context()))
        _ = try adapter.methods["setTranslationY"]?(&state, [.integer(12)], context())
        XCTAssertEqual(state["translation_y"], .number(12))
        _ = try adapter.methods["setPadding"]?(&state, [.integer(1), .integer(2), .integer(3), .integer(4)], context())
        XCTAssertEqual(state["padding"], .object(["left": .number(1), "top": .number(2), "right": .number(3), "bottom": .number(4)]))
        XCTAssertThrowsError(try adapter.methods["setPadding"]?(&state, [.integer(1), .integer(2), .integer(3)], context()))
    }

    // MotionEvent / Paint / Canvas

    func testMotionEventModel() throws {
        let adapter = self.runtimeAdapter("android.view.MotionEvent")
        let state = try self.constructor(adapter, [.integer(0), .integer(10), .integer(20)])
        XCTAssertEqual(try adapter.methods["getAction"]?(state, [], context()), .value(.integer(0)))
        XCTAssertEqual(try adapter.methods["getX"]?(state, [], context()), .value(.number(10)))
        XCTAssertEqual(try adapter.methods["getPointerCount"]?(state, [], context()), .value(.integer(1)))
        XCTAssertThrowsError(try self.constructor(adapter, [.integer(9), .integer(10), .integer(20)]))
        XCTAssertThrowsError(try self.constructor(adapter, [.integer(0), .integer(10)]))
    }

    func testPaintAlphaEditsColorChannelOnly() throws {
        let adapter = self.runtimeAdapter("android.graphics.Paint")
        var state = try self.constructor(adapter)
        _ = try adapter.methods["setColor"]?(&state, [.integer(0x80FF_0000)], context())
        _ = try adapter.methods["setAlpha"]?(&state, [.integer(255)], context())
        XCTAssertEqual(state["color"], .integer(0xFFFF_0000))
        _ = try adapter.methods["setAlpha"]?(&state, [.integer(64)], context())
        XCTAssertEqual(state["color"], .integer(0x40FF_0000))
        XCTAssertThrowsError(try adapter.methods["setAlpha"]?(&state, [.integer(256)], context()))
        XCTAssertThrowsError(try adapter.methods["setColor"]?(&state, [.integer(-1)], context()))
    }

    func testCanvasRecordsPathOps() throws {
        let adapter = self.runtimeAdapter("android.graphics.Canvas")
        var state = try self.constructor(adapter)
        _ = try adapter.methods["drawCircle"]?(&state, [.integer(5), .number(6.5), .integer(2)], context())
        _ = try adapter.methods["drawLine"]?(&state, [.integer(0), .integer(0), .integer(3), .integer(4)], context())
        let path = state["path"]?.array ?? []
        XCTAssertEqual(path.count, 2)
        XCTAssertEqual(path[0], .object(["op": .string("circle"), "x": .number(5), "y": .number(6.5), "radius": .number(2)]))
        XCTAssertThrowsError(try adapter.methods["drawRect"]?(&state, [.integer(0), .integer(0), .integer(1)], context()))
    }

    // Handler / Runnable

    func testHandlerRejectsNonRunnable() {
        XCTAssertThrowsError(try self.callHandlerPost(with: .object(["$java_class": .string("int")])))
    }

    func testHandlerCancellationIsExplicitlyUnsupported() throws {
        let handler = self.runtimeAdapter("android.os.Handler")
        var state = try self.constructor(handler)
        XCTAssertThrowsError(try handler.methods["removeCallbacks"]?(&state, [.null], context()))
    }

    func testRegistryValidatesRuntimeAdapters() {
        XCTAssertFalse(self.registry.adapters.isEmpty)
        for name in ["android.os.Bundle", "android.content.Intent", "android.net.Uri", "android.graphics.Color", "android.graphics.drawable.ColorDrawable", "android.view.MotionEvent", "android.os.Handler"] {
            XCTAssertNotNil(self.registry.adapters[name], name)
        }
        for name in ["android.graphics.Canvas", "android.graphics.Paint", "android.widget.ScrollView", "android.widget.CheckBox"] {
            XCTAssertNil(self.registry.adapters[name], name)
        }
    }

    private func callHandlerPost(with reference: AyuBridgeValue) throws {
        let handler = self.runtimeAdapter("android.os.Handler")
        var state = try self.constructor(handler)
        _ = try handler.methods["post"]?(&state, [reference], context())
    }

    private func context() -> AyuBridgeAdapterContext {
        AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in throw AyuBridgeFailure.unsupported("callback") },
            resolve: { reference in
                AyuBridgeAdapterSnapshot(className: reference.object?["$java_class"]?.string ?? "unknown", state: reference.object ?? [:])
            })
    }

    private func constructor(_ adapter: AyuBridgeClassAdapter, _ args: [AyuBridgeValue] = []) throws -> [String: AyuBridgeValue] {
        guard let constructor = adapter.constructor else {
            XCTFail("Adapter has no constructor: \(adapter.name)")
            return [:]
        }
        return try constructor(args, context())
    }

    private func runtimeAdapter(_ name: String) -> AyuBridgeClassAdapter {
        guard let adapter = self.registry.adapters[name] ?? AyuBridgeJavaRuntime.adapters.first(where: { $0.name == name }) else {
            fatalError("Missing adapter: \(name)")
        }
        return adapter
    }
}
