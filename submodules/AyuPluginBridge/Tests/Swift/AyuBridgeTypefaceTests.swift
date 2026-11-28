import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

final class AyuBridgeTypefaceRuntimeTests: XCTestCase {
    private var adapter: AyuBridgeClassAdapter!
    private let typefaceName = "android.graphics.Typeface"

    override func setUpWithError() throws {
        self.adapter = try XCTUnwrap(AyuBridgeClassRegistry.standard.adapters[self.typefaceName])
    }

    private func state(_ result: AyuBridgeAdapterResult, file: StaticString = #filePath, line: UInt = #line) throws -> AyuBridgeTypefaceValue {
        guard case let .instance(className, state) = result else { XCTFail("not a Typeface", file: file, line: line); throw AyuBridgeFailure.unsupported("result") }
        XCTAssertEqual(className, self.typefaceName, file: file, line: line)
        XCTAssertNoThrow(try self.adapter.validateState(state), file: file, line: line)
        return try AyuBridgeTypefaceValue(state: state)
    }

    private func create(_ args: [AyuBridgeValue], objects: [String: AyuBridgeAdapterSnapshot] = [:]) throws -> AyuBridgeTypefaceValue {
        try self.state(try XCTUnwrap(self.adapter.staticMethods["create"])(args, .memberTests(objects)))
    }

    private func reference(_ value: AyuBridgeTypefaceValue) -> (AyuBridgeValue, [String: AyuBridgeAdapterSnapshot]) {
        (.object(["$handle": .string("t"), "$class": .string(self.typefaceName)]), ["t": AyuBridgeAdapterSnapshot(className: self.typefaceName, state: value.state)])
    }

    func testAndroidConstantsAndPresets() throws {
        XCTAssertNil(self.adapter.constructor)
        XCTAssertEqual(self.adapter.constants, ["NORMAL": .integer(0), "BOLD": .integer(1), "ITALIC": .integer(2), "BOLD_ITALIC": .integer(3)])
        XCTAssertEqual(Set(self.adapter.staticFields.keys), ["DEFAULT", "DEFAULT_BOLD", "SANS_SERIF", "SERIF", "MONOSPACE"])
        let expected: [String: (AyuBridgeTypefaceValue.Design, Int64, Int64)] = [
            "DEFAULT": (.sans, 400, 0), "DEFAULT_BOLD": (.sans, 700, 1), "SANS_SERIF": (.sans, 400, 0), "SERIF": (.serif, 400, 0), "MONOSPACE": (.monospace, 400, 0),
        ]
        for (name, (design, weight, style)) in expected {
            let value = try self.state(try XCTUnwrap(self.adapter.staticFields[name])(.memberTests()))
            XCTAssertEqual(value.design, design, name)
            XCTAssertEqual(value.weight, weight, name)
            XCTAssertEqual(value.style, style, name)
            XCTAssertEqual(self.adapter.results[name], self.typefaceName)
        }
    }

    func testCreateFromFamilyNameUsesTheFamilyWeightAsTheBaseOfBold() throws {
        let medium = try self.create([.string("sans-serif-medium"), .integer(0)])
        XCTAssertEqual([medium.baseWeight, medium.weight, medium.style], [500, 500, 0])
        // Android adds 300 to the family's base weight for a bold style.
        let mediumBold = try self.create([.string("sans-serif-medium"), .integer(1)])
        XCTAssertEqual([mediumBold.baseWeight, mediumBold.weight, mediumBold.style], [500, 800, 1])
        let black = try self.create([.string("sans-serif-black"), .integer(3)])
        XCTAssertEqual([black.weight, black.style], [1000, 3])
        XCTAssertTrue(black.isItalic)
        XCTAssertEqual(try self.create([.string("monospace"), .integer(0)]).design, .monospace)
        XCTAssertEqual(try self.create([.string("serif"), .integer(2)]).design, .serif)
        XCTAssertEqual(try self.create([.string("sans-serif-condensed"), .integer(0)]).design, .condensed)
        XCTAssertEqual(try self.create([.string("sans-serif-light"), .integer(0)]).weight, 300)
        XCTAssertEqual(try self.create([.string("sans-serif-thin"), .integer(0)]).weight, 100)
        // An unknown family and a null family are the default typeface.
        XCTAssertEqual(try self.create([.string("no-such-family"), .integer(0)]), .default)
        XCTAssertEqual(try self.create([.null, .integer(1)]), AyuBridgeTypefaceValue.default.styled(1))
        // A style outside 0...3 is NORMAL.
        XCTAssertEqual(try self.create([.string("sans-serif"), .integer(9)]), .default)
        for family in ["cursive", "casual", "serif-monospace", "sans-serif-smallcaps"] {
            XCTAssertThrowsError(try self.create([.string(family), .integer(0)])) { XCTAssertEqual(($0 as? AyuBridgeFailure)?.code, "UNSUPPORTED_API") }
        }
        XCTAssertThrowsError(try self.create([.string("sans-serif")]))
        XCTAssertThrowsError(try self.create([.string("sans-serif"), .string("bold")]))
    }

    func testCreateFromTypefaceIsRelativeAndWeightedIsAbsolute() throws {
        let (bold, objects) = self.reference(AyuBridgeTypefaceValue.default.styled(1))
        // The same style returns the family unchanged; another style starts again from the base weight.
        XCTAssertEqual(try self.create([bold, .integer(1)], objects: objects), AyuBridgeTypefaceValue.default.styled(1))
        let italic = try self.create([bold, .integer(2)], objects: objects)
        XCTAssertEqual([italic.weight, italic.style], [400, 2])

        let weighted = try self.create([.null, .integer(500), .bool(false)])
        XCTAssertEqual([weighted.baseWeight, weighted.weight, weighted.style], [400, 500, 0])
        let heavy = try self.create([.null, .integer(600), .bool(true)])
        XCTAssertEqual([heavy.weight, heavy.style], [600, 3])
        // A bold of an absolute weight is still relative to the family's base weight.
        let (reference, weightedObjects) = self.reference(weighted)
        XCTAssertEqual(try self.create([reference, .integer(1)], objects: weightedObjects).weight, 700)
        for weight in [Int64(0), 1001, -5] {
            XCTAssertThrowsError(try self.create([.null, .integer(weight), .bool(false)])) { XCTAssertEqual(($0 as? AyuBridgeFailure)?.code, "INVALID_ARGUMENTS") }
        }
        XCTAssertThrowsError(try self.create([.null, .integer(500), .integer(1)]))
        let foreign: AyuBridgeValue = .object(["$handle": .string("x"), "$class": .string("android.graphics.Paint")])
        XCTAssertThrowsError(try self.create([foreign, .integer(0)], objects: ["x": AyuBridgeAdapterSnapshot(className: "android.graphics.Paint", state: [:])]))
    }

    func testGettersAndDefaultFromStyle() throws {
        let value = try AyuBridgeTypefaceValue.default.weighted(650, italic: true)
        var state = value.state
        let context = AyuBridgeAdapterContext.memberTests()
        XCTAssertEqual(try XCTUnwrap(self.adapter.methods["getStyle"])(&state, [], context), .value(.integer(3)))
        XCTAssertEqual(try XCTUnwrap(self.adapter.methods["getWeight"])(&state, [], context), .value(.integer(650)))
        XCTAssertEqual(try XCTUnwrap(self.adapter.methods["isBold"])(&state, [], context), .value(.bool(true)))
        XCTAssertEqual(try XCTUnwrap(self.adapter.methods["isItalic"])(&state, [], context), .value(.bool(true)))
        XCTAssertThrowsError(try XCTUnwrap(self.adapter.methods["getStyle"])(&state, [.integer(1)], context))
        let defaults = try XCTUnwrap(self.adapter.staticMethods["defaultFromStyle"])
        XCTAssertEqual(try self.state(defaults([.integer(1)], context)), AyuBridgeTypefaceValue.default.styled(1))
        XCTAssertEqual(try self.state(defaults([.integer(2)], context)).style, 2)
        XCTAssertThrowsError(try defaults([.integer(4)], context))
        for invalid: [String: AyuBridgeValue] in [["style": .integer(1)], ["family": .string("cursive"), "base": .integer(400), "weight": .integer(400), "style": .integer(0)],
                                                 ["family": .string("serif"), "base": .integer(400), "weight": .integer(0), "style": .integer(0)]] {
            XCTAssertThrowsError(try self.adapter.validateState(invalid))
        }
    }

    func testTelegramAssetNamesMapToSystemTypefaces() throws {
        let expected: [String: (AyuBridgeTypefaceValue.Design, Int64, Bool)] = [
            "fonts/rmedium.ttf": (.sans, 500, false), "fonts/rregular.ttf": (.sans, 400, false), "fonts/ritalic.ttf": (.sans, 400, true),
            "fonts/rmediumitalic.ttf": (.sans, 500, true), "fonts/rextrabold.ttf": (.sans, 800, false), "fonts/rmono.ttf": (.monospace, 400, false),
            "fonts/rcondensedbold.ttf": (.condensed, 700, false), "fonts/mw_bold.ttf": (.serif, 700, false), "fonts/nunito_extrabold.ttf": (.rounded, 800, false),
        ]
        for (path, (design, weight, italic)) in expected {
            let value = try self.state(AyuBridgeJavaRuntime.androidUtilitiesGetTypeface([.string(path)], .memberTests()))
            XCTAssertEqual(value.design, design, path)
            XCTAssertEqual(value.weight, weight, path)
            XCTAssertEqual(value.isItalic, italic, path)
        }
        // Android returns null for an asset it cannot load.
        XCTAssertEqual(try AyuBridgeJavaRuntime.androidUtilitiesGetTypeface([.string("fonts/absent.ttf")], .memberTests()), .value(.null))
        XCTAssertThrowsError(try AyuBridgeJavaRuntime.androidUtilitiesGetTypeface([], .memberTests()))
        // Telegram's "bold" is the medium weight, whose API style is not bold.
        let bold = try self.state(AyuBridgeJavaRuntime.androidUtilitiesBold([], .memberTests()))
        XCTAssertEqual([bold.weight, bold.style], [500, 0])
        XCTAssertThrowsError(try AyuBridgeJavaRuntime.androidUtilitiesBold([.integer(1)], .memberTests()))
    }

    @MainActor func testFontsFollowWeightDesignAndItalic() throws {
        XCTAssertNil(AyuBridgeTypefaceValue(packed: 0))
        XCTAssertNil(AyuBridgeTypefaceValue(packed: 3))
        let medium = try XCTUnwrap(AyuBridgeTypefaceValue(packed: try AyuBridgeTypefaceValue.family("sans-serif-medium").packed))
        XCTAssertEqual(medium.font(size: 17).pointSize, 17)
        XCTAssertEqual(medium.font(size: 17).ayuTestWeight, UIFont.systemFont(ofSize: 17, weight: .medium).ayuTestWeight, accuracy: 0.001)
        XCTAssertFalse(medium.font(size: 17).fontDescriptor.symbolicTraits.contains(.traitItalic))
        let weights: [(Int64, UIFont.Weight)] = [(100, .ultraLight), (200, .thin), (300, .light), (400, .regular), (500, .medium), (600, .semibold),
                                                 (700, .bold), (800, .heavy), (900, .black), (1000, .black), (449, .regular), (450, .medium)]
        for (weight, expected) in weights {
            let font = try AyuBridgeTypefaceValue.default.weighted(weight, italic: false).font(size: 20)
            XCTAssertEqual(font.ayuTestWeight, UIFont.systemFont(ofSize: 20, weight: expected).ayuTestWeight, accuracy: 0.001, "\(weight)")
        }
        let boldItalic = AyuBridgeTypefaceValue.default.styled(3).font(size: 14)
        XCTAssertTrue(boldItalic.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertTrue(boldItalic.fontDescriptor.symbolicTraits.contains(.traitBold))
        let mono = try AyuBridgeTypefaceValue.family("monospace").font(size: 14)
        XCTAssertTrue(mono.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        let serif = try AyuBridgeTypefaceValue.family("serif").font(size: 14)
        XCTAssertNotEqual(serif.familyName, UIFont.systemFont(ofSize: 14).familyName)
        let rounded = try XCTUnwrap(AyuBridgeTypefaceValue.asset("fonts/nunito_extrabold.ttf")).font(size: 14)
        XCTAssertNotEqual(rounded.fontName, UIFont.systemFont(ofSize: 14, weight: .heavy).fontName)
        let condensed = try AyuBridgeTypefaceValue.family("sans-serif-condensed").font(size: 14)
        XCTAssertLessThan(("Condensed width" as NSString).size(withAttributes: [.font: condensed]).width,
                          ("Condensed width" as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 14)]).width)
    }
}

@MainActor
final class AyuBridgeTypefaceNativeHostTests: XCTestCase {
    private let typeface = "android.graphics.Typeface"

    func testSetTypefaceOverloadsApplyTheFontAndKeepTheTextSize() async throws {
        let session = try await AyuMemberTestHost()
        let textView = try await session.construct("android.widget.TextView")
        _ = try await session.invoke(textView, "setTextSize", [.integer(1), .number(22)])
        let native = try await session.mount(textView)
        let label = try XCTUnwrap(native.label)
        ayuExpect(try await session.invoke(textView, "getTypeface"), .null)

        let medium = try await session.invokeStatic(self.typeface, "create", [.string("sans-serif-medium"), .integer(0)])
        XCTAssertEqual(medium["$class"], .string(self.typeface))
        ayuExpect(try await session.invoke(textView, "setTypeface", [medium]), .null)
        try await session.flush(textView)
        XCTAssertEqual(label.font.pointSize, 22)
        XCTAssertEqual(label.font.ayuTestWeight, UIFont.systemFont(ofSize: 22, weight: .medium).ayuTestWeight, accuracy: 0.001)
        // The object that was set comes back.
        ayuExpect(try await session.invoke(textView, "getTypeface"), medium)

        // A style above zero sets Typeface.create(tf, style): another object, 300 heavier than the medium family.
        _ = try await session.invoke(textView, "setTypeface", [medium, .integer(3)])
        try await session.flush(textView)
        XCTAssertTrue(label.font.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertEqual(label.font.ayuTestWeight, UIFont.systemFont(ofSize: 22, weight: .heavy).ayuTestWeight, accuracy: 0.001)
        let styled = try await session.invoke(textView, "getTypeface")
        XCTAssertNotEqual(styled, medium)
        ayuExpect(try await session.invoke(styled, "getStyle"), .integer(3))
        ayuExpect(try await session.invoke(styled, "getWeight"), .integer(800))
        ayuExpect(try await session.invoke(textView, "getTypeface"), styled)

        // Style zero keeps the typeface as it is; a null typeface with a style is the default of that style.
        _ = try await session.invoke(textView, "setTypeface", [medium, .integer(0)])
        ayuExpect(try await session.invoke(textView, "getTypeface"), medium)
        _ = try await session.invoke(textView, "setTypeface", [.null, .integer(1)])
        try await session.flush(textView)
        XCTAssertTrue(label.font.fontDescriptor.symbolicTraits.contains(.traitBold))
        ayuExpect(try await session.invoke(try await session.invoke(textView, "getTypeface"), "isBold"), .bool(true))

        // The text size changes without losing the typeface.
        _ = try await session.invoke(textView, "setTypeface", [try await session.field(self.typeface, "MONOSPACE")])
        _ = try await session.invoke(textView, "setTextSize", [.integer(1), .number(13)])
        try await session.flush(textView)
        XCTAssertEqual(label.font.pointSize, 13)
        XCTAssertTrue(label.font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))

        // Null resets to the default typeface.
        _ = try await session.invoke(textView, "setTypeface", [.null])
        try await session.flush(textView)
        ayuExpect(try await session.invoke(textView, "getTypeface"), .null)
        XCTAssertEqual(label.font.fontName, UIFont.systemFont(ofSize: 13).fontName)
        _ = try await session.invoke(textView, "setTypeface", [.null, .integer(0)])
        ayuExpect(try await session.invoke(textView, "getTypeface"), .null)
    }

    func testTypefaceArgumentsAreValidatedAndScopedToTextViews() async throws {
        let session = try await AyuMemberTestHost()
        let textView = try await session.construct("android.widget.TextView")
        let bold = try await session.field(self.typeface, "DEFAULT_BOLD")
        var code = await session.failure { try await session.invoke(textView, "setTypeface") }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        code = await session.failure { try await session.invoke(textView, "setTypeface", [.integer(1)]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.invoke(textView, "setTypeface", [bold, .integer(4)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        code = await session.failure { try await session.invoke(textView, "setTypeface", [bold, .string("bold")]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        code = await session.failure { try await session.invoke(textView, "setTypeface", [bold, .integer(1), .integer(2)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        let paint = try await session.construct("android.graphics.Paint")
        code = await session.failure { try await session.invoke(textView, "setTypeface", [paint]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.construct(self.typeface, [.string("sans-serif")]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await session.failure { try await session.invoke(textView, "getTypeface", [.integer(1)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")

        let editText = try await session.construct("android.widget.EditText")
        _ = try await session.invoke(editText, "setTypeface", [bold])
        ayuExpect(try await session.invoke(editText, "getTypeface"), bold)
        let frame = try await session.construct("android.widget.FrameLayout")
        for method in ["setTypeface", "getTypeface"] {
            code = await session.failure { try await session.invoke(frame, method, method == "setTypeface" ? [bold] : []) }
            XCTAssertEqual(code, "UNSUPPORTED_API", method)
        }
        // A released Typeface is no longer the object a view returns; an equal one is.
        _ = try await session.invoke(textView, "setTypeface", [bold])
        _ = try await session.call("java.release", ["target": bold])
        let replacement = try await session.invoke(textView, "getTypeface")
        XCTAssertNotEqual(replacement, bold)
        ayuExpect(try await session.invoke(replacement, "getWeight"), .integer(700))
    }

    func testPaintKeepsItsTypeface() async throws {
        let session = try await AyuMemberTestHost()
        let paint = try await session.construct("android.graphics.Paint")
        ayuExpect(try await session.invoke(paint, "getTypeface"), .null)
        let serif = try await session.invokeStatic(self.typeface, "create", [.string("serif"), .integer(1)])
        let returned = try await session.invoke(paint, "setTypeface", [serif])
        XCTAssertEqual(returned["$class"], .string(self.typeface))
        let read = try await session.invoke(paint, "getTypeface")
        ayuExpect(try await session.invoke(read, "getWeight"), .integer(700))
        ayuExpect(try await session.invoke(read, "getStyle"), .integer(1))
        // A copy carries the typeface, a reset drops it, null clears it.
        let copy = try await session.construct("android.graphics.Paint", [paint])
        ayuExpect(try await session.invoke(try await session.invoke(copy, "getTypeface"), "getWeight"), .integer(700))
        _ = try await session.invoke(copy, "reset")
        ayuExpect(try await session.invoke(copy, "getTypeface"), .null)
        ayuExpect(try await session.invoke(paint, "setTypeface", [.null]), .null)
        ayuExpect(try await session.invoke(paint, "getTypeface"), .null)
        let code = await session.failure { try await session.invoke(paint, "setTypeface", [paint]) }
        XCTAssertEqual(code, "UNSUPPORTED_API")
    }
}
