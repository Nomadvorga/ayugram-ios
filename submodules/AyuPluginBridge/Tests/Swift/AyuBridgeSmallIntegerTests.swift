import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

final class AyuBridgeSmallIntegerTests: XCTestCase {
    private var registry: AyuBridgeClassRegistry!

    override func setUpWithError() throws {
        self.registry = .standard
    }

    func testByteSupportsOnlyBoundedByteWrapperSubset() throws {
        let adapter = try XCTUnwrap(self.registry.adapters["java.lang.Byte"])
        XCTAssertEqual(adapter.constants, [
            "MIN_VALUE": .integer(-128), "MAX_VALUE": .integer(127),
            "TYPE": .object(["$java_class": .string("byte")]),
        ])
        XCTAssertEqual(Set(adapter.staticMethods.keys), ["parseByte", "valueOf", "toString"])
        XCTAssertEqual(Set(adapter.methods.keys), ["byteValue", "shortValue", "intValue", "longValue", "toString"])

        let constructor = try XCTUnwrap(adapter.constructor)
        for (input, expected) in [(Int64(-128), Int64(-128)), (Int64(127), Int64(127))] {
            let state = try constructor([.integer(input)], self.context())
            XCTAssertEqual(state, ["value": .integer(expected)])
            XCTAssertNoThrow(try adapter.validateState(state))
        }
        XCTAssertEqual(try constructor([.string("-128")], self.context()), ["value": .integer(-128)])

        let parseByte = try XCTUnwrap(adapter.staticMethods["parseByte"])
        XCTAssertEqual(try parseByte([.string("127")], self.context()), .value(.integer(127)))
        XCTAssertEqual(try parseByte([.string("-128")], self.context()), .value(.integer(-128)))
        guard case let .instance(className, boxed) = try XCTUnwrap(adapter.staticMethods["valueOf"])([.integer(-128)], self.context()) else {
            return XCTFail("Byte.valueOf should return an owned Byte wrapper")
        }
        XCTAssertEqual(className, "java.lang.Byte")
        XCTAssertEqual(boxed, ["value": .integer(-128)])

        XCTAssertThrowsError(try constructor([], self.context()))
        XCTAssertThrowsError(try constructor([.integer(-129)], self.context()))
        XCTAssertThrowsError(try constructor([.integer(128)], self.context()))
        XCTAssertThrowsError(try constructor([.integer(1), .integer(2)], self.context()))
        XCTAssertThrowsError(try constructor([.number(1)], self.context()))
        XCTAssertThrowsError(try constructor([.bool(true)], self.context()))
        XCTAssertThrowsError(try parseByte([], self.context()))
        XCTAssertThrowsError(try parseByte([.integer(1)], self.context()))
        XCTAssertThrowsError(try parseByte([.string("128")], self.context()))
        XCTAssertThrowsError(try parseByte([.string("-129")], self.context()))
        XCTAssertThrowsError(try parseByte([.string("1"), .string("extra")], self.context()))
        XCTAssertThrowsError(try adapter.staticMethods["valueOf"]?([], self.context()))
        XCTAssertThrowsError(try adapter.staticMethods["valueOf"]?([.integer(0), .integer(1)], self.context()))
        XCTAssertThrowsError(try adapter.staticMethods["toString"]?([.string("not a byte")], self.context()))
    }

    func testShortSupportsOnlyBoundedShortWrapperSubset() throws {
        let adapter = try XCTUnwrap(self.registry.adapters["java.lang.Short"])
        XCTAssertEqual(adapter.constants, [
            "MIN_VALUE": .integer(-32_768), "MAX_VALUE": .integer(32_767),
            "TYPE": .object(["$java_class": .string("short")]),
        ])
        XCTAssertEqual(Set(adapter.staticMethods.keys), ["parseShort", "valueOf", "toString"])
        XCTAssertEqual(Set(adapter.methods.keys), ["byteValue", "shortValue", "intValue", "longValue", "toString"])

        let constructor = try XCTUnwrap(adapter.constructor)
        for (input, expected) in [(Int64(-32_768), Int64(-32_768)), (Int64(32_767), Int64(32_767))] {
            let state = try constructor([.integer(input)], self.context())
            XCTAssertEqual(state, ["value": .integer(expected)])
            XCTAssertNoThrow(try adapter.validateState(state))
        }
        XCTAssertEqual(try constructor([.string("32767")], self.context()), ["value": .integer(32_767)])

        let parseShort = try XCTUnwrap(adapter.staticMethods["parseShort"])
        XCTAssertEqual(try parseShort([.string("32767")], self.context()), .value(.integer(32_767)))
        XCTAssertEqual(try parseShort([.string("-32768")], self.context()), .value(.integer(-32_768)))
        guard case let .instance(className, boxed) = try XCTUnwrap(adapter.staticMethods["valueOf"])([.string("-32768")], self.context()) else {
            return XCTFail("Short.valueOf should return an owned Short wrapper")
        }
        XCTAssertEqual(className, "java.lang.Short")
        XCTAssertEqual(boxed, ["value": .integer(-32_768)])

        XCTAssertThrowsError(try constructor([], self.context()))
        XCTAssertThrowsError(try constructor([.integer(-32_769)], self.context()))
        XCTAssertThrowsError(try constructor([.integer(32_768)], self.context()))
        XCTAssertThrowsError(try constructor([.integer(1), .integer(2)], self.context()))
        XCTAssertThrowsError(try constructor([.number(1)], self.context()))
        XCTAssertThrowsError(try parseShort([], self.context()))
        XCTAssertThrowsError(try parseShort([.integer(1)], self.context()))
        XCTAssertThrowsError(try parseShort([.string("32768")], self.context()))
        XCTAssertThrowsError(try parseShort([.string("-32769")], self.context()))
        XCTAssertThrowsError(try parseShort([.string("32767"), .string("extra")], self.context()))
        XCTAssertThrowsError(try adapter.staticMethods["valueOf"]?([], self.context()))
        XCTAssertThrowsError(try adapter.staticMethods["valueOf"]?([.integer(0), .integer(1)], self.context()))
    }

    func testSmallIntegerStateValidationRequiresExactSignedRangeAndShape() throws {
        let byte = try XCTUnwrap(self.registry.adapters["java.lang.Byte"])
        XCTAssertNoThrow(try byte.validateState(["value": .integer(-128)]))
        XCTAssertNoThrow(try byte.validateState(["value": .integer(127)]))
        XCTAssertThrowsError(try byte.validateState(["value": .integer(-129)]))
        XCTAssertThrowsError(try byte.validateState(["value": .integer(128)]))
        XCTAssertThrowsError(try byte.validateState(["value": .string("1")]))
        XCTAssertThrowsError(try byte.validateState(["value": .integer(1), "extra": .null]))
        XCTAssertThrowsError(try byte.validateState([:]))

        let short = try XCTUnwrap(self.registry.adapters["java.lang.Short"])
        XCTAssertNoThrow(try short.validateState(["value": .integer(-32_768)]))
        XCTAssertNoThrow(try short.validateState(["value": .integer(32_767)]))
        XCTAssertThrowsError(try short.validateState(["value": .integer(-32_769)]))
        XCTAssertThrowsError(try short.validateState(["value": .integer(32_768)]))
        XCTAssertThrowsError(try short.validateState(["value": .bool(false)]))
        XCTAssertThrowsError(try short.validateState(["value": .integer(1), "extra": .null]))
        XCTAssertThrowsError(try short.validateState([:]))
    }

    func testByteAndShortValueMethodsUseSignedJavaNarrowing() throws {
        let int = try XCTUnwrap(self.registry.adapters["java.lang.Integer"])
        let intState = try XCTUnwrap(int.constructor)([.integer(65_535)], self.context())
        XCTAssertEqual(try int.methods["byteValue"]?(intState, [], self.context()), .value(.integer(-1)))
        XCTAssertEqual(try int.methods["shortValue"]?(intState, [], self.context()), .value(.integer(-1)))
        XCTAssertThrowsError(try int.methods["byteValue"]?(intState, [.integer(0)], self.context()))

        let long = try XCTUnwrap(self.registry.adapters["java.lang.Long"])
        let longState = try XCTUnwrap(long.constructor)([.integer(Int64.max)], self.context())
        XCTAssertEqual(try long.methods["byteValue"]?(longState, [], self.context()), .value(.integer(-1)))
        XCTAssertEqual(try long.methods["shortValue"]?(longState, [], self.context()), .value(.integer(-1)))

        let byte = try XCTUnwrap(self.registry.adapters["java.lang.Byte"])
        let byteState = try XCTUnwrap(byte.constructor)([.integer(-128)], self.context())
        XCTAssertEqual(try byte.methods["byteValue"]?(byteState, [], self.context()), .value(.integer(-128)))
        XCTAssertEqual(try byte.methods["shortValue"]?(byteState, [], self.context()), .value(.integer(-128)))
        XCTAssertEqual(try byte.methods["intValue"]?(byteState, [], self.context()), .value(.integer(-128)))
        XCTAssertEqual(try byte.methods["longValue"]?(byteState, [], self.context()), .value(.integer(-128)))

        let short = try XCTUnwrap(self.registry.adapters["java.lang.Short"])
        let shortState = try XCTUnwrap(short.constructor)([.integer(32_767)], self.context())
        XCTAssertEqual(try short.methods["byteValue"]?(shortState, [], self.context()), .value(.integer(-1)))
        XCTAssertEqual(try short.methods["shortValue"]?(shortState, [], self.context()), .value(.integer(32_767)))
        XCTAssertEqual(try short.methods["intValue"]?(shortState, [], self.context()), .value(.integer(32_767)))
        XCTAssertEqual(try short.methods["longValue"]?(shortState, [], self.context()), .value(.integer(32_767)))
    }

    func testIntegerHelperUsesExplicitParseMethodNames() throws {
        let integer = try XCTUnwrap(self.registry.adapters["java.lang.Integer"])
        let long = try XCTUnwrap(self.registry.adapters["java.lang.Long"])
        XCTAssertEqual(Set(integer.staticMethods.keys), ["parseInt", "valueOf", "toString"])
        XCTAssertEqual(Set(long.staticMethods.keys), ["parseLong", "valueOf", "toString"])
        XCTAssertEqual(try integer.staticMethods["parseInt"]?([.string("2147483647")], self.context()), .value(.integer(Int64(Int32.max))))
        XCTAssertEqual(try long.staticMethods["parseLong"]?([.string("9223372036854775807")], self.context()), .value(.integer(Int64.max)))
        XCTAssertNil(integer.staticMethods["parseLong"])
        XCTAssertNil(long.staticMethods["parseInt"])
    }

    private func context() -> AyuBridgeAdapterContext {
        AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("callback")
        }, resolve: { _ in
            throw AyuBridgeFailure.unsupported("reference")
        })
    }
}
