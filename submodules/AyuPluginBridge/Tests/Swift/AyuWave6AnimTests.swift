import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// AOSP interpolator formula vectors for the value-only adapters.
final class AyuWave6AnimTests: XCTestCase {
    private func context() -> AyuBridgeAdapterContext {
        AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in throw AyuBridgeFailure.unsupported("callback") },
            resolve: { reference in
                AyuBridgeAdapterSnapshot(className: reference.object?["$java_class"]?.string ?? "unknown", state: reference.object ?? [:])
            }, readAnimationPreference: { true })
    }

    private func value(_ name: String, _ args: [AyuBridgeValue], _ input: Double) throws -> Double {
        let adapter = try XCTUnwrap(AyuBridgeClassRegistry.standard.adapters["android.view.animation." + name])
        var state = try XCTUnwrap(adapter.constructor)(args, self.context())
        XCTAssertNoThrow(try adapter.validateState(state))
        guard case let .value(result) = try XCTUnwrap(adapter.methods["getInterpolation"])(&state, [.number(input)], self.context()),
              let number = result.number else {
            XCTFail("getInterpolation must return a number")
            return .nan
        }
        return number
    }

    func testAccelerateDecelerate() throws {
        XCTAssertEqual(try self.value("AccelerateDecelerateInterpolator", [], 0), 0, accuracy: 1e-12)
        XCTAssertEqual(try self.value("AccelerateDecelerateInterpolator", [], 0.25), 0.14644660940672627, accuracy: 1e-12)
        XCTAssertEqual(try self.value("AccelerateDecelerateInterpolator", [], 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try self.value("AccelerateDecelerateInterpolator", [], 1), 1, accuracy: 1e-12)
    }

    func testAccelerate() throws {
        XCTAssertEqual(try self.value("AccelerateInterpolator", [], 0.5), 0.25, accuracy: 1e-12)
        XCTAssertEqual(try self.value("AccelerateInterpolator", [.number(2)], 0.5), 0.0625, accuracy: 1e-12)
        XCTAssertEqual(try self.value("AccelerateInterpolator", [.number(1.5)], 1), 1, accuracy: 1e-12)
    }

    func testAnticipate() throws {
        XCTAssertEqual(try self.value("AnticipateInterpolator", [], 0.5), -0.125, accuracy: 1e-12)
        XCTAssertEqual(try self.value("AnticipateInterpolator", [.number(1)], 0.5), 0, accuracy: 1e-12)
        XCTAssertEqual(try self.value("AnticipateInterpolator", [], 1), 1, accuracy: 1e-12)
    }

    func testAnticipateOvershoot() throws {
        XCTAssertEqual(try self.value("AnticipateOvershootInterpolator", [], 0), 0, accuracy: 1e-12)
        XCTAssertEqual(try self.value("AnticipateOvershootInterpolator", [], 0.25), -0.125, accuracy: 1e-12)
        XCTAssertEqual(try self.value("AnticipateOvershootInterpolator", [], 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try self.value("AnticipateOvershootInterpolator", [], 0.75), 1.125, accuracy: 1e-12)
        XCTAssertEqual(try self.value("AnticipateOvershootInterpolator", [], 1), 1, accuracy: 1e-12)
    }

    func testBounce() throws {
        XCTAssertEqual(try self.value("BounceInterpolator", [], 0), 0, accuracy: 1e-12)
        XCTAssertEqual(try self.value("BounceInterpolator", [], 0.25), 0.63011538, accuracy: 1e-8)
        XCTAssertEqual(try self.value("BounceInterpolator", [], 0.5), 0.7015927368, accuracy: 1e-8)
        XCTAssertEqual(try self.value("BounceInterpolator", [], 1), 1.00005448, accuracy: 1e-8)
    }

    func testParameterlessInterpolatorsRejectArguments() throws {
        let adapter = try XCTUnwrap(AyuBridgeClassRegistry.standard.adapters["android.view.animation.BounceInterpolator"])
        XCTAssertThrowsError(try XCTUnwrap(adapter.constructor)([.number(1)], self.context()))
    }
}
