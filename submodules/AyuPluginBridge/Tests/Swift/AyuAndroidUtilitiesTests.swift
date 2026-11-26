import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

final class AyuAndroidUtilitiesTests: XCTestCase {
    private let utilitiesClass = "org.telegram.messenger.AndroidUtilities"

    func testDPAndDPF2UseNativePointUnits() throws {
        let adapter = try XCTUnwrap(AyuPluginApplicationBridge().classRegistry().adapters[self.utilitiesClass])
        let dp = try XCTUnwrap(adapter.staticMethods["dp"])
        let dpf2 = try XCTUnwrap(adapter.staticMethods["dpf2"])
        let context = self.context()

        XCTAssertEqual(try dp([.number(1.2)], context), .value(.integer(2)))
        XCTAssertEqual(try dp([.number(-1.2)], context), .value(.integer(-1)))
        XCTAssertEqual(try dp([.number(-2)], context), .value(.integer(-2)))
        XCTAssertEqual(try dp([.number(-0.2)], context), .value(.integer(0)))
        XCTAssertEqual(try dp([.number(100_000)], context), .value(.integer(100_000)))
        XCTAssertEqual(try dp([.number(-100_000)], context), .value(.integer(-100_000)))

        XCTAssertEqual(try dpf2([.number(1.2)], context), .value(.number(1.2)))
        XCTAssertEqual(try dpf2([.number(-1.2)], context), .value(.number(-1.2)))
        XCTAssertEqual(try dpf2([.number(100_000)], context), .value(.number(100_000)))
        XCTAssertEqual(try dpf2([.number(-100_000)], context), .value(.number(-100_000)))
    }

    func testDPAndDPF2RejectInvalidArgumentsAndUnboundedValues() throws {
        let adapter = try XCTUnwrap(AyuPluginApplicationBridge().classRegistry().adapters[self.utilitiesClass])
        let dp = try XCTUnwrap(adapter.staticMethods["dp"])
        let dpf2 = try XCTUnwrap(adapter.staticMethods["dpf2"])
        let context = self.context()
        let invalidArguments: [[AyuBridgeValue]] = [
            [],
            [.number(1), .number(2)],
            [.string("1")],
            [.bool(true)],
            [.number(Double.nan)],
            [.number(Double.infinity)],
            [.number(-Double.infinity)],
            [.number(100_000.1)],
            [.number(-100_000.1)],
        ]

        for arguments in invalidArguments {
            XCTAssertThrowsError(try dp(arguments, context), "dp accepted arguments: \(arguments)")
            XCTAssertThrowsError(try dpf2(arguments, context), "dpf2 accepted arguments: \(arguments)")
        }
    }

    private func context() -> AyuBridgeAdapterContext {
        AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("synthetic callback")
        }, resolve: { _ in
            throw AyuBridgeFailure.unsupported("synthetic reference")
        })
    }
}
