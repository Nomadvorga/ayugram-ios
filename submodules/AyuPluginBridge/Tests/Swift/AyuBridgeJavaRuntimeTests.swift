import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Facade regressions for Intent/Bundle/View/MotionEvent/Paint/Canvas/Drawable/
/// Runnable/Handler adapters: state round-trips, unsupported overloads, and
/// registry validation. No interpreter, no account.
final class AyuBridgeJavaRuntimeTests: XCTestCase {
    private var registry: AyuBridgeClassRegistry!

    override func setUpWithError() throws {
        self.registry = try AyuBridgeClassRegistry(AyuBridgeJavaValues.adapters).adding(AyuBridgeJavaRuntime.adapters)
    }

    // Bundle

    func testBundleRoundTripAndDefaults() throws {
        let adapter = self.registry.adapters["android.os.Bundle"]
        XCTAssertNotNil(adapter)
        var state = try adapter?.constructor([], context())
        _ = try adapter?.methods["putString"]?(&state, [.string("k"), .string("v")], context())
        _ = try adapter?.methods["putInt"]?(&state, [.string("n"), .integer(5)], context())
        XCTAssertEqual(try adapter?.methods["getString"]?(state, [.string("k")], context()), .value(.string("v")))
        XCTAssertEqual(try adapter?.methods["getInt"]?(state, [.string("n")], context()), .value(.integer(5)))
        XCTAssertEqual(try adapter?.methods["getInt"]?(state, [.string("missing"), .integer(9)], context()), .value(.integer(9)))
        XCTAssertEqual(try adapter?.methods["getString"]?(state, [.string("missing")], context()), .value(.null))
        XCTAssertEqual(try adapter?.methods["isEmpty"]?(state, [], context()), .value(.bool(false)))
    }

    func testBundleRejectsWrongTypes() throws {
        let adapter = self.registry.adapters["android.os.Bundle"]
        var state = try adapter?.constructor([], context())
        XCTAssertThrowsError(try adapter?.methods["putInt"]?(&state, [.string("k"), .string("5")], context()))
        XCTAssertThrowsError(try adapter?.methods["putString"]?(&state, [.string("k"), .integer(5)], context()))
    }

    // Intent

    func testIntentActionExtrasFlags() throws {
        let adapter = self.registry.adapters["android.content.Intent"]
        var state = try adapter?.constructor([.string("android.intent.action.SEND")], context())
        XCTAssertEqual(try adapter?.methods["getAction"]?(state, [], context()), .value(.string("android.intent.action.SEND")))
        _ = try adapter?.methods["putExtra"]?(&state, [.string("url"), .string("https://ml.ai")], context())
        XCTAssertEqual(try adapter?.methods["getStringExtra"]?(state, [.string("url")], context()), .value(.string("https://ml.ai")))
        XCTAssertEqual(try adapter?.methods["hasExtra"]?(state, [.string("url")], context()), .value(.bool(true)))
        XCTAssertEqual(try adapter?.methods["hasExtra"]?(state, [.string("nope")], context()), .value(.bool(false)))
        _ = try adapter?.methods["addFlags"]?(&state, [.integer(0x1000_0000)], context())
        XCTAssertEqual(try adapter?.methods["getFlags"]?(state, [], context()), .value(.integer(0x1000_0000)))
        XCTAssertEqual(try adapter?.constructor([.integer(1)], context()).count, nil, "constructor must reject non-string action")
    }

    func testIntentPutExtraOverloadCountIsExplicit() throws {
        let adapter = self.registry.adapters["android.content.Intent"]
        var state = try adapter?.constructor([], context())
        XCTAssertThrowsError(try adapter?.methods["putExtra"]?(&state, [.string("k")], context()))
        XCTAssertThrowsError(try adapter?.methods["putExtra"]?(&state, [.string("k"), .string("v"), .integer(3)], context()))
    }

    // View

    func testViewVisibilityAndTransforms() throws {
        let adapter = self.registry.adapters["android.view.View"]
        var state: [String: AyuBridgeValue] = [:]
        _ = try adapter?.methods["setVisibility"]?(&state, [.integer(8)], context())
        XCTAssertEqual(try adapter?.methods["getVisibility"]?(state, [], context()), .value(.integer(8)))
        XCTAssertThrowsError(try adapter?.methods["setVisibility"]?(&state, [.integer(3)], context()))
        _ = try adapter?.methods["setAlpha"]?(&state, [.double(0.5)], context())
        XCTAssertThrowsError(try adapter?.methods["setAlpha"]?(&state, [.double(1.5)], context()))
        _ = try adapter?.methods["setTranslationY"]?(&state, [.integer(12)], context())
        XCTAssertEqual(state["translation_y"], .double(12))
        _ = try adapter?.methods["setPadding"]?(&state, [.integer(1), .integer(2), .integer(3), .integer(4)], context())
        XCTAssertEqual(state["padding"], .object(["left": .double(1), "top": .double(2), "right": .double(3), "bottom": .double(4)]))
        XCTAssertThrowsError(try adapter?.methods["setPadding"]?(&state, [.integer(1), .integer(2), .integer(3)], context()))
    }

    // MotionEvent / Paint / Canvas

    func testMotionEventModel() throws {
        let adapter = self.registry.adapters["android.view.MotionEvent"]
        let state = try adapter?.constructor([.integer(0), .integer(10), .integer(20)], context())
        XCTAssertEqual(try adapter?.methods["getAction"]?(state ?? [:], [], context()), .value(.integer(0)))
        XCTAssertEqual(try adapter?.methods["getX"]?(state ?? [:], [], context()), .value(.double(10)))
        XCTAssertEqual(try adapter?.methods["getPointerCount"]?(state ?? [:], [], context()), .value(.integer(1)))
        XCTAssertThrowsError(try adapter?.constructor([.integer(9), .integer(10), .integer(20)], context()))
        XCTAssertThrowsError(try adapter?.constructor([.integer(0), .integer(10)], context()))
    }

    func testPaintAlphaEditsColorChannelOnly() throws {
        let adapter = self.registry.adapters["android.graphics.Paint"]
        var state = try adapter?.constructor([], context())
        _ = try adapter?.methods["setColor"]?(&state, [.integer(0x80FF_0000)], context())
        _ = try adapter?.methods["setAlpha"]?(&state, [.integer(255)], context())
        XCTAssertEqual(state?["color"], .integer(0xFFFF_0000))
        _ = try adapter?.methods["setAlpha"]?(&state, [.integer(64)], context())
        XCTAssertEqual(state?["color"], .integer(0x40FF_0000))
        XCTAssertThrowsError(try adapter?.methods["setAlpha"]?(&state, [.integer(256)], context()))
        XCTAssertThrowsError(try adapter?.methods["setColor"]?(&state, [.integer(-1)], context()))
    }

    func testCanvasRecordsPathOps() throws {
        let adapter = self.registry.adapters["android.graphics.Canvas"]
        var state = try adapter?.constructor([], context())
        _ = try adapter?.methods["drawCircle"]?(&state, [.integer(5), .double(6.5), .integer(2)], context())
        _ = try adapter?.methods["drawLine"]?(&state, [.integer(0), .integer(0), .integer(3), .integer(4)], context())
        let path = state?["path"]?.array ?? []
        XCTAssertEqual(path.count, 2)
        XCTAssertEqual(path[0], .object(["op": .string("circle"), "x": .double(5), "y": .double(6.5), "radius": .double(2)]))
        XCTAssertThrowsError(try adapter?.methods["drawRect"]?(&state, [.integer(0), .integer(0), .integer(1)], context()))
    }

    // Handler / Runnable

    func testHandlerRejectsNonRunnable() {
        XCTAssertThrowsError(try self.callHandlerPost(with: .object(["$java_class": .string("int")])))
    }

    func testRegistryValidatesRuntimeAdapters() {
        XCTAssertFalse(self.registry.adapters.isEmpty)
        for name in ["android.os.Bundle", "android.content.Intent", "android.view.View", "android.view.ViewGroup.LayoutParams",
                     "android.view.MotionEvent", "android.graphics.Paint", "android.graphics.Canvas",
                     "android.graphics.drawable.ColorDrawable", "java.lang.Runnable", "android.os.Handler"] {
            XCTAssertNotNil(self.registry.adapters[name], name)
        }
    }

    private func callHandlerPost(with reference: AyuBridgeValue) throws {
        let handler = self.registry.adapters["android.os.Handler"]
        var state = try handler?.constructor([], context())
        _ = try handler?.methods["post"]?(&state, [reference], context())
    }

    private func context() -> AyuBridgeAdapterContext {
        AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in throw AyuBridgeFailure.unsupported("callback") },
            resolve: { reference in
                AyuBridgeAdapterSnapshot(className: reference.object?["$java_class"]?.string ?? "unknown", state: reference.object ?? [:])
            })
    }
}
