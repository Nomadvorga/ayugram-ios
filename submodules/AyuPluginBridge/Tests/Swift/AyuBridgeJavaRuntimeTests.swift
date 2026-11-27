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
        XCTAssertEqual(try adapter.methods["getString"]?(&state, [.string("k")], context()), .value(.string("v")))
        XCTAssertEqual(try adapter.methods["getInt"]?(&state, [.string("n")], context()), .value(.integer(5)))
        XCTAssertEqual(try adapter.methods["getInt"]?(&state, [.string("missing"), .integer(9)], context()), .value(.integer(9)))
        XCTAssertEqual(try adapter.methods["getString"]?(&state, [.string("missing")], context()), .value(.null))
        XCTAssertEqual(try adapter.methods["isEmpty"]?(&state, [], context()), .value(.bool(false)))
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
        XCTAssertEqual(try adapter.methods["getAction"]?(&state, [], context()), .value(.string("android.intent.action.SEND")))
        _ = try adapter.methods["putExtra"]?(&state, [.string("url"), .string("https://ml.ai")], context())
        XCTAssertEqual(try adapter.methods["getStringExtra"]?(&state, [.string("url")], context()), .value(.string("https://ml.ai")))
        XCTAssertEqual(try adapter.methods["hasExtra"]?(&state, [.string("url")], context()), .value(.bool(true)))
        XCTAssertEqual(try adapter.methods["hasExtra"]?(&state, [.string("nope")], context()), .value(.bool(false)))
        _ = try adapter.methods["addFlags"]?(&state, [.integer(0x1000_0000)], context())
        XCTAssertEqual(try adapter.methods["getFlags"]?(&state, [], context()), .value(.integer(0x1000_0000)))
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
        guard case .instance(let className, var state) = try parse([.string("https://example.com/a%20b/caf%C3%A9?item=first&item=second#details")], context()) else {
            return XCTFail("Uri.parse should return an owned value descriptor")
        }
        XCTAssertEqual(className, "android.net.Uri")
        XCTAssertEqual(try adapter.methods["toString"]?(&state, [], context()), .value(.string("https://example.com/a%20b/caf%C3%A9?item=first&item=second#details")))
        XCTAssertEqual(try adapter.methods["getScheme"]?(&state, [], context()), .value(.string("https")))
        XCTAssertEqual(try adapter.methods["getHost"]?(&state, [], context()), .value(.string("example.com")))
        XCTAssertEqual(try adapter.methods["getPath"]?(&state, [], context()), .value(.string("/a b/café")))
        XCTAssertEqual(try adapter.methods["getEncodedPath"]?(&state, [], context()), .value(.string("/a%20b/caf%C3%A9")))
        XCTAssertEqual(try adapter.methods["getLastPathSegment"]?(&state, [], context()), .value(.string("café")))
        XCTAssertEqual(try adapter.methods["getQueryParameter"]?(&state, [.string("item")], context()), .value(.string("first")))
        XCTAssertEqual(try adapter.methods["getQueryParameter"]?(&state, [.string("missing")], context()), .value(.null))
        XCTAssertEqual(try adapter.methods["getFragment"]?(&state, [], context()), .value(.string("details")))
    }

    func testUriRejectsUnsupportedOverloadsAndOversizedValues() throws {
        let adapter = self.runtimeAdapter("android.net.Uri")
        let parse = try XCTUnwrap(adapter.staticMethods["parse"])
        XCTAssertThrowsError(try parse([], context()))
        XCTAssertThrowsError(try parse([.integer(5)], context()))
        XCTAssertThrowsError(try parse([.string(String(repeating: "x", count: 8_193))], context()))
        guard case .instance(_, var state) = try parse([.string("relative/path")], context()) else {
            return XCTFail("Relative URIs are valid values")
        }
        XCTAssertThrowsError(try adapter.methods["getQueryParameter"]?(&state, [], context()))
        XCTAssertThrowsError(try adapter.methods["getQueryParameter"]?(&state, [.string("")], context()))
    }

    func testColorDrawableAcceptsJavaSignedArgbColors() throws {
        let adapter = self.runtimeAdapter("android.graphics.drawable.ColorDrawable")
        var state = try self.constructor(adapter, [.integer(-16_777_216)])
        XCTAssertEqual(state["color"], .integer(-16_777_216))
        XCTAssertEqual(try adapter.methods["getColor"]?(&state, [], context()), .value(.integer(-16_777_216)))
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
        XCTAssertEqual(adapter.constants["TRANSPARENT"], .integer(0))
        XCTAssertEqual(try adapter.staticMethods["HSVToColor"]?([.array([.number(0), .number(1), .number(1)])], context()), .value(.integer(-65_536)))
        let packed = AyuBridgeValue.integer(Int64(Int32(bitPattern: 0x80FF_1001)))
        XCTAssertEqual(try adapter.staticMethods["alpha"]?([packed], context()), .value(.integer(128)))
        XCTAssertEqual(try adapter.staticMethods["red"]?([packed], context()), .value(.integer(255)))
        XCTAssertEqual(try adapter.staticMethods["green"]?([packed], context()), .value(.integer(16)))
        XCTAssertEqual(try adapter.staticMethods["blue"]?([packed], context()), .value(.integer(1)))
        let namedColors: [String: Int64] = [
            "TeAl": Int64(Int32(bitPattern: 0xFF00_8080)),
            "lime": Int64(Int32(bitPattern: 0xFF00_FF00)),
            "maroon": Int64(Int32(bitPattern: 0xFF80_0000)),
            "navy": Int64(Int32(bitPattern: 0xFF00_0080)),
            "olive": Int64(Int32(bitPattern: 0xFF80_8000)),
            "purple": Int64(Int32(bitPattern: 0xFF80_0080)),
            "silver": Int64(Int32(bitPattern: 0xFFC0_C0C0)),
            "grey": Int64(Int32(bitPattern: 0xFF88_8888)),
            "darkgrey": Int64(Int32(bitPattern: 0xFF44_4444)),
            "lightgrey": Int64(Int32(bitPattern: 0xFFCC_CCCC)),
        ]
        for (name, expected) in namedColors {
            XCTAssertEqual(try adapter.staticMethods["parseColor"]?([.string(name)], context()), .value(.integer(expected)), name)
        }
        XCTAssertThrowsError(try adapter.staticMethods["rgb"]?([.integer(256), .integer(0), .integer(0)], context()))
        XCTAssertThrowsError(try adapter.staticMethods["parseColor"]?([.string("#12345")], context()))
        XCTAssertThrowsError(try adapter.staticMethods["parseColor"]?([.string("Transparent ")], context()))
        XCTAssertThrowsError(try adapter.staticMethods["alpha"]?([.integer(Int64(Int32.min) - 1)], context()))
    }

    func testGradientDrawableKeepsOnlyNativeRenderableStyles() throws {
        let adapter = self.runtimeAdapter("android.graphics.drawable.GradientDrawable")
        var state = try self.constructor(adapter)
        _ = try adapter.methods["setColor"]?(&state, [.integer(-65_536)], context())
        _ = try adapter.methods["setCornerRadius"]?(&state, [.number(12.5)], context())
        _ = try adapter.methods["setShape"]?(&state, [.integer(1)], context())
        _ = try adapter.methods["setStroke"]?(&state, [.integer(2), .integer(-1)], context())
        XCTAssertEqual(state["color"], .integer(-65_536))
        XCTAssertEqual(state["corner_radius"], .number(12.5))
        XCTAssertEqual(state["shape"], .integer(1))
        XCTAssertEqual(state["stroke_width"], .number(2))
        XCTAssertThrowsError(try adapter.methods["setShape"]?(&state, [.integer(2)], context()))
        XCTAssertThrowsError(try adapter.methods["setCornerRadius"]?(&state, [.number(-1)], context()))
    }

    func testTypefaceAndTextTruncationAdaptersExposeOnlyBoundedPresets() throws {
        let typeface = try XCTUnwrap(self.registry.adapters["android.graphics.Typeface"])
        XCTAssertEqual(Set(typeface.constants.keys), ["NORMAL", "BOLD", "ITALIC", "BOLD_ITALIC"])
        XCTAssertEqual(Set(typeface.staticFields.keys), ["DEFAULT", "DEFAULT_BOLD", "SANS_SERIF", "SERIF", "MONOSPACE"])
        XCTAssertNil(typeface.constructor)
        XCTAssertEqual(Set(typeface.staticMethods.keys), ["create", "defaultFromStyle"])

        let truncateAt = try XCTUnwrap(self.registry.adapters["android.text.TextUtils$TruncateAt"])
        XCTAssertNil(truncateAt.constructor)
        XCTAssertTrue(truncateAt.staticMethods.isEmpty)
        XCTAssertEqual(Set(truncateAt.staticFields.keys), ["END", "START", "MIDDLE"])
        for mode in ["END", "START", "MIDDLE"] {
            let reader = try XCTUnwrap(truncateAt.staticFields[mode])
            guard case let .instance(className, state) = try reader(context()) else {
                return XCTFail("TruncateAt preset did not return a bounded enum-like value")
            }
            XCTAssertEqual(className, "android.text.TextUtils$TruncateAt")
            XCTAssertEqual(state, ["mode": .string(mode)])
            XCTAssertNoThrow(try truncateAt.validateState(state))
        }
        XCTAssertThrowsError(try truncateAt.validateState(["mode": .string("MARQUEE")]))
    }

    func testLocaleAdapterExposesBoundedSnapshotsAndCommonReadOnlyFields() throws {
        let adapter = self.runtimeAdapter("java.util.Locale")
        XCTAssertNotNil(adapter.constructor)
        XCTAssertTrue(adapter.constants.isEmpty)
        XCTAssertEqual(Set(adapter.staticFields.keys), [
            "CANADA", "CANADA_FRENCH", "CHINA", "CHINESE", "ENGLISH", "FRANCE", "FRENCH",
            "GERMANY", "GERMAN", "ITALY", "ITALIAN", "JAPAN", "JAPANESE", "KOREA", "KOREAN",
            "ROOT", "SIMPLIFIED_CHINESE", "TAIWAN", "TRADITIONAL_CHINESE", "UK", "US",
        ])
        XCTAssertEqual(Set(adapter.staticMethods.keys), ["getDefault"])

        let defaultLocale = try XCTUnwrap(adapter.staticMethods["getDefault"])
        guard case let .instance(className, defaultState) = try defaultLocale([], context()) else {
            return XCTFail("Locale.getDefault should return an owned locale snapshot")
        }
        XCTAssertEqual(className, "java.util.Locale")
        XCTAssertNoThrow(try adapter.validateState(defaultState))
        XCTAssertThrowsError(try defaultLocale([.string("unexpected")], context()))

        let constructor = try XCTUnwrap(adapter.constructor)
        var french = try constructor([.string("fr"), .string("CA")], context())
        XCTAssertEqual(french["language"], .string("fr"))
        XCTAssertEqual(french["country"], .string("CA"))
        XCTAssertEqual(try adapter.methods["getLanguage"]?(&french, [], context()), .value(.string("fr")))
        XCTAssertEqual(try adapter.methods["getCountry"]?(&french, [], context()), .value(.string("CA")))
        XCTAssertEqual(try adapter.methods["getLanguageTag"]?(&french, [], context()), .value(.string("fr-CA")))
        XCTAssertEqual(try adapter.methods["toString"]?(&french, [], context()), .value(.string("fr_CA")))
        guard case let .instance(presetClass, canadian) = try XCTUnwrap(adapter.staticFields["CANADA"])(context()) else {
            return XCTFail("Locale.CANADA must be an owned Locale instance")
        }
        XCTAssertEqual(presetClass, "java.util.Locale")
        XCTAssertEqual(canadian["identifier"], .string("en_CA"))
        XCTAssertEqual(canadian["language"], .string("en"))
        XCTAssertEqual(canadian["country"], .string("CA"))
        XCTAssertNoThrow(try adapter.validateState(canadian))
        XCTAssertThrowsError(try constructor([.string("en"), .string("US"), .string("POSIX"), .string("extra")], context()))
        let noArguments = try constructor([], context())
        XCTAssertEqual(noArguments["identifier"], .string(Locale.current.identifier))
        let preservedEmptyCountry = try constructor([.string("en"), .string(""), .string("POSIX")], context())
        XCTAssertEqual(preservedEmptyCountry["identifier"], .string("en__POSIX"))
        XCTAssertEqual(preservedEmptyCountry["variant"], .string("POSIX"))
        XCTAssertThrowsError(try adapter.validateState(["identifier": .string("x")]))
    }

    func testImageScaleTypeAdapterExposesOnlyMappedModes() throws {
        let adapter = try XCTUnwrap(self.registry.adapters["android.widget.ImageView$ScaleType"])
        XCTAssertNil(adapter.constructor)
        XCTAssertEqual(Set(adapter.staticFields.keys), ["CENTER", "FIT_XY", "FIT_CENTER", "CENTER_INSIDE", "CENTER_CROP", "MATRIX"])
        for mode in ["CENTER", "FIT_XY", "FIT_CENTER", "CENTER_INSIDE", "CENTER_CROP", "MATRIX"] {
            let field = try XCTUnwrap(adapter.staticFields[mode])
            guard case let .instance(className, state) = try field(context()) else {
                return XCTFail("ScaleType must resolve to an owned enum-like value")
            }
            XCTAssertEqual(className, "android.widget.ImageView$ScaleType")
            XCTAssertEqual(state, ["mode": .string(mode)])
            XCTAssertNoThrow(try adapter.validateState(state))
        }
        XCTAssertThrowsError(try adapter.validateState(["mode": .string("FIT_START")]))
    }

    func testInterpolatorsMatchBoundedAndroidValueFormulas() throws {
        let linear = try XCTUnwrap(self.registry.adapters["android.view.animation.LinearInterpolator"])
        let decelerate = try XCTUnwrap(self.registry.adapters["android.view.animation.DecelerateInterpolator"])
        let overshoot = try XCTUnwrap(self.registry.adapters["android.view.animation.OvershootInterpolator"])

        let linearConstructor = try XCTUnwrap(linear.constructor)
        var linearState = try linearConstructor([], context())
        let linearInterpolation = try XCTUnwrap(linear.methods["getInterpolation"])
        for input in [0.0, 0.37, 1.0] {
            XCTAssertEqual(try linearInterpolation(&linearState, [.number(input)], context()), .value(.number(input)))
        }
        XCTAssertNoThrow(try linear.validateState(linearState))

        let decelerateConstructor = try XCTUnwrap(decelerate.constructor)
        var defaultDecelerateState = try decelerateConstructor([], context())
        let decelerateInterpolation = try XCTUnwrap(decelerate.methods["getInterpolation"])
        XCTAssertEqual(defaultDecelerateState["parameter"], .number(1))
        XCTAssertEqual(try decelerateInterpolation(&defaultDecelerateState, [.number(0)], context()), .value(.number(0)))
        XCTAssertEqual(try decelerateInterpolation(&defaultDecelerateState, [.number(0.5)], context()), .value(.number(0.75)))
        XCTAssertEqual(try decelerateInterpolation(&defaultDecelerateState, [.number(1)], context()), .value(.number(1)))

        var zeroFactorState = try decelerateConstructor([.number(0)], context())
        XCTAssertEqual(try decelerateInterpolation(&zeroFactorState, [.number(0.5)], context()), .value(.number(0)))
        var maximumFactorState = try decelerateConstructor([.number(10)], context())
        let maximumFactorExpected: Double = 1 - pow(0.75, 20.0)
        XCTAssertEqual(try decelerateInterpolation(&maximumFactorState, [.number(0.25)], context()), .value(.number(maximumFactorExpected)))
        XCTAssertEqual(try decelerateInterpolation(&maximumFactorState, [.number(1)], context()), .value(.number(1)))
        XCTAssertNoThrow(try decelerate.validateState(zeroFactorState))
        XCTAssertNoThrow(try decelerate.validateState(maximumFactorState))

        let overshootConstructor = try XCTUnwrap(overshoot.constructor)
        var defaultOvershootState = try overshootConstructor([], context())
        let overshootInterpolation = try XCTUnwrap(overshoot.methods["getInterpolation"])
        XCTAssertEqual(defaultOvershootState["parameter"], .number(2))
        XCTAssertEqual(try overshootInterpolation(&defaultOvershootState, [.number(0)], context()), .value(.number(0)))
        XCTAssertEqual(try overshootInterpolation(&defaultOvershootState, [.number(0.5)], context()), .value(.number(1.125)))
        XCTAssertEqual(try overshootInterpolation(&defaultOvershootState, [.number(1)], context()), .value(.number(1)))

        var zeroTensionState = try overshootConstructor([.number(0)], context())
        XCTAssertEqual(try overshootInterpolation(&zeroTensionState, [.number(0.5)], context()), .value(.number(0.875)))
        var maximumTensionState = try overshootConstructor([.number(10)], context())
        let maximumTensionExpected = pow(0.5, 2) * ((10 + 1) * -0.5 + 10) + 1
        XCTAssertEqual(try overshootInterpolation(&maximumTensionState, [.number(0.5)], context()), .value(.number(maximumTensionExpected)))
        XCTAssertEqual(try overshootInterpolation(&maximumTensionState, [.number(1)], context()), .value(.number(1)))
        XCTAssertNoThrow(try overshoot.validateState(zeroTensionState))
        XCTAssertNoThrow(try overshoot.validateState(maximumTensionState))

        XCTAssertThrowsError(try linearConstructor([.number(0.5)], context()))
        XCTAssertThrowsError(try linearConstructor([.number(0.5), .number(0.5)], context()))
        let invalidParameters: [AyuBridgeValue] = [.null, .number(-0.01), .number(10.01), .number(.infinity), .number(.nan), .string("1"), .bool(true)]
        for invalidParameter in invalidParameters {
            XCTAssertThrowsError(try decelerateConstructor([invalidParameter], context()))
            XCTAssertThrowsError(try overshootConstructor([invalidParameter], context()))
        }
        XCTAssertThrowsError(try decelerateConstructor([.number(1), .number(2)], context()))
        XCTAssertThrowsError(try overshootConstructor([.number(1), .number(2)], context()))

        let invalidInputs: [AyuBridgeValue] = [.null, .number(-0.01), .number(1.01), .number(.infinity), .number(.nan), .string("0.5"), .bool(false)]
        for invalidInput in invalidInputs {
            XCTAssertThrowsError(try linearInterpolation(&linearState, [invalidInput], context()))
            XCTAssertThrowsError(try decelerateInterpolation(&defaultDecelerateState, [invalidInput], context()))
            XCTAssertThrowsError(try overshootInterpolation(&defaultOvershootState, [invalidInput], context()))
        }
        XCTAssertThrowsError(try linearInterpolation(&linearState, [], context()))
        XCTAssertThrowsError(try decelerateInterpolation(&defaultDecelerateState, [.number(0.5), .number(0.5)], context()))
        XCTAssertThrowsError(try overshootInterpolation(&defaultOvershootState, [], context()))

        let invalidStates: [[String: AyuBridgeValue]] = [
            [:], ["parameter": .number(-1)], ["parameter": .number(10.01)],
            ["parameter": .number(.infinity)], ["parameter": .string("2")],
            ["parameter": .number(1), "extra": .bool(false)],
        ]
        for invalidState in invalidStates {
            XCTAssertThrowsError(try linear.validateState(invalidState))
            XCTAssertThrowsError(try decelerate.validateState(invalidState))
            XCTAssertThrowsError(try overshoot.validateState(invalidState))
            var mutableInvalidState = invalidState
            XCTAssertThrowsError(try linearInterpolation(&mutableInvalidState, [.number(0.5)], context()))
            mutableInvalidState = invalidState
            XCTAssertThrowsError(try decelerateInterpolation(&mutableInvalidState, [.number(0.5)], context()))
            mutableInvalidState = invalidState
            XCTAssertThrowsError(try overshootInterpolation(&mutableInvalidState, [.number(0.5)], context()))
        }
        XCTAssertNoThrow(try decelerate.validateState(["parameter": .number(0)]))
        XCTAssertNoThrow(try decelerate.validateState(["parameter": .number(10)]))
        XCTAssertNoThrow(try overshoot.validateState(["parameter": .number(0)]))
        XCTAssertNoThrow(try overshoot.validateState(["parameter": .number(10)]))
    }

    func testValueAnimatorOnlyExposesNativeAnimationGate() throws {
        let animator = try XCTUnwrap(self.registry.adapters["android.animation.ValueAnimator"])
        XCTAssertEqual(Set(animator.staticMethods.keys), ["areAnimatorsEnabled"])
        XCTAssertEqual(try animator.staticMethods["areAnimatorsEnabled"]?([], context(animationPreference: true)), .value(.bool(true)))
        XCTAssertEqual(try animator.staticMethods["areAnimatorsEnabled"]?([], context(animationPreference: false)), .value(.bool(false)))
        XCTAssertThrowsError(try animator.staticMethods["areAnimatorsEnabled"]?([.bool(true)], context()))
        XCTAssertNil(animator.constructor)
    }

    func testRectAndRectFExposeBoundedGeometryValues() throws {
        let rect = try XCTUnwrap(self.registry.adapters["android.graphics.Rect"])
        XCTAssertEqual(Set(rect.readableFields), ["left", "top", "right", "bottom"])
        XCTAssertEqual(rect.writableFields, rect.readableFields)
        let constructor = try XCTUnwrap(rect.constructor)
        var state = try constructor([.integer(-3), .integer(1), .integer(8), .integer(10)], context())
        XCTAssertEqual(state["left"], .integer(-3))
        XCTAssertEqual(try rect.methods["width"]?(&state, [], context()), .value(.integer(11)))
        XCTAssertEqual(try rect.methods["height"]?(&state, [], context()), .value(.integer(9)))
        XCTAssertEqual(try rect.methods["centerX"]?(&state, [], context()), .value(.integer(2)))
        XCTAssertEqual(try rect.methods["centerY"]?(&state, [], context()), .value(.integer(5)))
        var overflowingCenter = try constructor([.integer(Int64(Int32.max)), .integer(Int64(Int32.max)), .integer(Int64(Int32.max)), .integer(Int64(Int32.max))], context())
        XCTAssertEqual(try rect.methods["centerX"]?(&overflowingCenter, [], context()), .value(.integer(-1)))
        _ = try rect.methods["offset"]?(&overflowingCenter, [.integer(1), .integer(0)], context())
        XCTAssertEqual(overflowingCenter["left"], .integer(Int64(Int32.min)))
        _ = try rect.methods["setEmpty"]?(&state, [], context())
        XCTAssertEqual(state, ["left": .integer(0), "top": .integer(0), "right": .integer(0), "bottom": .integer(0)])
        XCTAssertEqual(try rect.methods["isEmpty"]?(&state, [], context()), .value(.bool(true)))
        XCTAssertThrowsError(try constructor([.number(1.5), .integer(0), .integer(2), .integer(3)], context()))
        XCTAssertThrowsError(try constructor([.integer(Int64(Int32.max) + 1), .integer(0), .integer(2), .integer(3)], context()))

        let rectF = try XCTUnwrap(self.registry.adapters["android.graphics.RectF"])
        let floatConstructor = try XCTUnwrap(rectF.constructor)
        var floatState = try floatConstructor([.number(0.5), .number(1.25), .number(10.5), .number(8.25)], context())
        XCTAssertEqual(try rectF.methods["width"]?(&floatState, [], context()), .value(.number(10)))
        XCTAssertEqual(try rectF.methods["height"]?(&floatState, [], context()), .value(.number(7)))
        XCTAssertEqual(try rectF.methods["centerX"]?(&floatState, [], context()), .value(.number(5.5)))
        XCTAssertEqual(try rectF.methods["centerY"]?(&floatState, [], context()), .value(.number(4.75)))
        _ = try rectF.methods["set"]?(&floatState, [.number(1), .number(2), .number(3), .number(4)], context())
        XCTAssertEqual(floatState, ["left": .number(1), "top": .number(2), "right": .number(3), "bottom": .number(4)])
        XCTAssertThrowsError(try floatConstructor([.number(.infinity), .number(0), .number(1), .number(1)], context()))
        XCTAssertThrowsError(try rectF.methods["set"]?(&floatState, [.number(1), .number(2)], context()))
    }

    func testRectangleCopiesTransformContainmentAndIntersectionAreBounded() throws {
        let rect = try XCTUnwrap(self.registry.adapters["android.graphics.Rect"])
        let constructor = try XCTUnwrap(rect.constructor)
        let copyState: [String: AyuBridgeValue] = ["left": .integer(-2), "top": .integer(4), "right": .integer(5), "bottom": .integer(12)]
        let copy: AyuBridgeValue = .object(["$handle": .string("rect-copy"), "$class": .string(rect.name)])
        let adapterContext = AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("callback")
        }, resolve: { reference in
            guard reference.object?["$handle"] == .string("rect-copy") else {
                throw AyuBridgeFailure("invalid_handle", "Unknown test rectangle")
            }
            return AyuBridgeAdapterSnapshot(className: rect.name, state: copyState)
        })
        var state = try constructor([.integer(1), .integer(2), .integer(8), .integer(10)], adapterContext)
        _ = try rect.methods["set"]?(&state, [copy], adapterContext)
        XCTAssertEqual(state, ["left": .integer(-2), "top": .integer(4), "right": .integer(5), "bottom": .integer(12)])
        XCTAssertEqual(try rect.methods["contains"]?(&state, [.integer(0), .integer(5)], adapterContext), .value(.bool(true)))
        XCTAssertEqual(try rect.methods["contains"]?(&state, [.integer(5), .integer(5)], adapterContext), .value(.bool(false)))
        XCTAssertEqual(try rect.methods["contains"]?(&state, [.integer(-1), .integer(5), .integer(4), .integer(11)], adapterContext), .value(.bool(true)))
        XCTAssertEqual(try rect.methods["contains"]?(&state, [copy], adapterContext), .value(.bool(true)))
        XCTAssertEqual(try rect.methods["contains"]?(&state, [.integer(1), .integer(6), .integer(1), .integer(6)], adapterContext), .value(.bool(true)))
        XCTAssertEqual(try rect.methods["exactCenterX"]?(&state, [], adapterContext), .value(.number(1.5)))
        XCTAssertEqual(try rect.methods["exactCenterY"]?(&state, [], adapterContext), .value(.number(8)))

        _ = try rect.methods["offset"]?(&state, [.integer(3), .integer(-2)], adapterContext)
        XCTAssertEqual(state, ["left": .integer(1), "top": .integer(2), "right": .integer(8), "bottom": .integer(10)])
        _ = try rect.methods["inset"]?(&state, [.integer(1), .integer(2)], adapterContext)
        XCTAssertEqual(state, ["left": .integer(2), "top": .integer(4), "right": .integer(7), "bottom": .integer(8)])
        _ = try rect.methods["offsetTo"]?(&state, [.integer(-3), .integer(6)], adapterContext)
        XCTAssertEqual(state, ["left": .integer(-3), "top": .integer(6), "right": .integer(2), "bottom": .integer(10)])

        let beforeNoIntersection = state
        XCTAssertEqual(try rect.methods["intersect"]?(&state, [.integer(5), .integer(5), .integer(9), .integer(9)], adapterContext), .value(.bool(false)))
        XCTAssertEqual(state, beforeNoIntersection)
        XCTAssertEqual(try rect.methods["intersect"]?(&state, [.integer(0), .integer(8), .integer(7), .integer(14)], adapterContext), .value(.bool(true)))
        XCTAssertEqual(state, ["left": .integer(0), "top": .integer(8), "right": .integer(2), "bottom": .integer(10)])
        _ = try rect.methods["union"]?(&state, [.integer(4), .integer(5)], adapterContext)
        XCTAssertEqual(state, ["left": .integer(0), "top": .integer(5), "right": .integer(4), "bottom": .integer(10)])

        var reversed = try constructor([.integer(8), .integer(7), .integer(1), .integer(-2)], adapterContext)
        _ = try rect.methods["sort"]?(&reversed, [], adapterContext)
        XCTAssertEqual(reversed, ["left": .integer(1), "top": .integer(-2), "right": .integer(8), "bottom": .integer(7)])
        XCTAssertThrowsError(try rect.methods["set"]?(&state, [.object(["$java_class": .string("android.graphics.RectF")])], adapterContext))

        let rectF = try XCTUnwrap(self.registry.adapters["android.graphics.RectF"])
        var floatState = try XCTUnwrap(rectF.constructor)([.integer(0), .integer(1), .integer(8), .integer(9)], adapterContext)
        XCTAssertNoThrow(try rectF.methods["offset"]?(&floatState, [.integer(2), .integer(-1)], adapterContext))
        XCTAssertEqual(floatState, ["left": .number(2), "top": .number(0), "right": .number(10), "bottom": .number(8)])
    }

    func testPaintPreservesBoundedStyleAndColorStateWithoutClaimingRendering() throws {
        let paint = try XCTUnwrap(self.registry.adapters["android.graphics.Paint"])
        XCTAssertEqual(paint.constants, ["ANTI_ALIAS_FLAG": .integer(1), "FILTER_BITMAP_FLAG": .integer(2), "DITHER_FLAG": .integer(4)])
        let constructor = try XCTUnwrap(paint.constructor)
        var state = try constructor([], context())
        XCTAssertEqual(state["flags"], .integer(0))
        XCTAssertEqual(state["color"], .integer(-16_777_216))
        XCTAssertEqual(state["style"], .string("FILL"))
        XCTAssertThrowsError(try constructor([.integer(8)], context()))
        let flagged = try constructor([.integer(3)], context())
        XCTAssertEqual(flagged["anti_alias"], .bool(true))
        XCTAssertEqual(flagged["filter_bitmap"], .bool(true))
        XCTAssertThrowsError(try constructor([.integer(-1)], context()))

        let styleReference: AyuBridgeValue = .object(["$handle": .string("paint-style")])
        let capReference: AyuBridgeValue = .object(["$handle": .string("paint-cap")])
        let joinReference: AyuBridgeValue = .object(["$handle": .string("paint-join")])
        let copiedPaint: AyuBridgeValue = .object(["$handle": .string("paint-copy")])
        let copiedState: [String: AyuBridgeValue] = [
            "flags": .integer(1), "color": .integer(-1), "stroke_width": .number(3), "text_size": .number(14),
            "style": .string("STROKE"), "cap": .string("ROUND"), "join": .string("BEVEL"),
            "anti_alias": .bool(true), "filter_bitmap": .bool(false), "dither": .bool(false),
        ]
        let adapterContext = AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("callback")
        }, resolve: { reference in
            guard let handle = reference.object?["$handle"]?.string else { throw AyuBridgeFailure("invalid_handle", "Unknown test reference") }
            switch handle {
            case "paint-style": return AyuBridgeAdapterSnapshot(className: "android.graphics.Paint$Style", state: ["value": .string("STROKE")])
            case "paint-cap": return AyuBridgeAdapterSnapshot(className: "android.graphics.Paint$Cap", state: ["value": .string("ROUND")])
            case "paint-join": return AyuBridgeAdapterSnapshot(className: "android.graphics.Paint$Join", state: ["value": .string("BEVEL")])
            case "paint-copy": return AyuBridgeAdapterSnapshot(className: paint.name, state: copiedState)
            default: throw AyuBridgeFailure("invalid_handle", "Unknown test reference")
            }
        })

        _ = try paint.methods["setColor"]?(&state, [.integer(-1)], adapterContext)
        XCTAssertEqual(try paint.methods["getColor"]?(&state, [], adapterContext), .value(.integer(-1)))
        _ = try paint.methods["setAlpha"]?(&state, [.integer(128)], adapterContext)
        XCTAssertEqual(try paint.methods["getAlpha"]?(&state, [], adapterContext), .value(.integer(128)))
        XCTAssertEqual(state["color"], .integer(Int64(Int32(bitPattern: 0x80FF_FFFF))))
        XCTAssertThrowsError(try paint.methods["setAlpha"]?(&state, [.integer(256)], adapterContext))
        _ = try paint.methods["setARGB"]?(&state, [.integer(255), .integer(128), .integer(64), .integer(32)], adapterContext)
        XCTAssertEqual(try paint.methods["getColor"]?(&state, [], adapterContext), .value(.integer(Int64(Int32(bitPattern: 0xFF80_4020)))))
        XCTAssertThrowsError(try paint.methods["setARGB"]?(&state, [.integer(256), .integer(0), .integer(0), .integer(0)], adapterContext))
        XCTAssertThrowsError(try paint.methods["setARGB"]?(&state, [.integer(0), .integer(0), .integer(0)], adapterContext))
        _ = try paint.methods["setColor"]?(&state, [.integer(-1)], adapterContext)

        _ = try paint.methods["setStyle"]?(&state, [styleReference], adapterContext)
        _ = try paint.methods["setStrokeCap"]?(&state, [capReference], adapterContext)
        _ = try paint.methods["setStrokeJoin"]?(&state, [joinReference], adapterContext)
        XCTAssertEqual(state["style"], .string("STROKE"))
        XCTAssertEqual(state["cap"], .string("ROUND"))
        XCTAssertEqual(state["join"], .string("BEVEL"))
        let getStyle = try XCTUnwrap(paint.methods["getStyle"])
        guard case let .instance(styleClass, styleState) = try getStyle(&state, [], adapterContext) else {
            return XCTFail("Paint.getStyle should return a Paint.Style value")
        }
        XCTAssertEqual(styleClass, "android.graphics.Paint$Style")
        XCTAssertEqual(styleState, ["value": .string("STROKE")])

        _ = try paint.methods["setStrokeWidth"]?(&state, [.number(2.5)], adapterContext)
        _ = try paint.methods["setTextSize"]?(&state, [.integer(18)], adapterContext)
        XCTAssertEqual(try paint.methods["getStrokeWidth"]?(&state, [], adapterContext), .value(.number(2.5)))
        XCTAssertEqual(try paint.methods["getTextSize"]?(&state, [], adapterContext), .value(.number(18)))
        XCTAssertThrowsError(try paint.methods["setStrokeWidth"]?(&state, [.number(.infinity)], adapterContext))
        XCTAssertThrowsError(try paint.methods["setStyle"]?(&state, [.integer(1)], adapterContext))

        _ = try paint.methods["setAntiAlias"]?(&state, [.bool(true)], adapterContext)
        _ = try paint.methods["setFilterBitmap"]?(&state, [.bool(true)], adapterContext)
        _ = try paint.methods["setDither"]?(&state, [.bool(true)], adapterContext)
        XCTAssertEqual(try paint.methods["getFlags"]?(&state, [], adapterContext), .value(.integer(7)))
        XCTAssertEqual(try paint.methods["isDither"]?(&state, [], adapterContext), .value(.bool(true)))
        _ = try paint.methods["set"]?(&state, [copiedPaint], adapterContext)
        XCTAssertEqual(state, copiedState)
        _ = try paint.methods["reset"]?(&state, [], adapterContext)
        XCTAssertEqual(state, try constructor([], context()))
        XCTAssertNil(paint.methods["setShader"], "Shader methods must remain explicitly unsupported")

        let style = try XCTUnwrap(self.registry.adapters["android.graphics.Paint$Style"])
        XCTAssertEqual(Set(style.staticFields.keys), Set(["FILL", "STROKE", "FILL_AND_STROKE"]))
        let roundCap = try XCTUnwrap(self.registry.adapters["android.graphics.Paint$Cap"])
        XCTAssertEqual(Set(roundCap.staticFields.keys), Set(["BUTT", "ROUND", "SQUARE"]))
        let joins = try XCTUnwrap(self.registry.adapters["android.graphics.Paint$Join"])
        XCTAssertEqual(Set(joins.staticFields.keys), Set(["MITER", "ROUND", "BEVEL"]))
    }

    func testPathKeepsBoundedMoveLineAndCloseCommandsWithoutCanvasRendering() throws {
        let path = try XCTUnwrap(self.registry.adapters["android.graphics.Path"])
        let constructor = try XCTUnwrap(path.constructor)
        let copiedState = try constructor([], context())
        let copiedPath: AyuBridgeValue = .object(["$handle": .string("path-copy")])
        let adapterContext = AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("callback")
        }, resolve: { reference in
            guard reference.object?["$handle"] == .string("path-copy") else {
                throw AyuBridgeFailure("invalid_handle", "Unknown test path")
            }
            return AyuBridgeAdapterSnapshot(className: path.name, state: copiedState)
        })
        var state = try constructor([], adapterContext)
        XCTAssertEqual(try path.methods["isEmpty"]?(&state, [], adapterContext), .value(.bool(true)))
        _ = try path.methods["lineTo"]?(&state, [.number(3), .number(4)], adapterContext)
        XCTAssertEqual(state["commands"], .array([
            .object(["op": .string("move"), "x": .number(0), "y": .number(0)]),
            .object(["op": .string("line"), "x": .number(3), "y": .number(4)]),
        ]))
        XCTAssertEqual(try path.methods["isEmpty"]?(&state, [], adapterContext), .value(.bool(false)))
        _ = try path.methods["reset"]?(&state, [], adapterContext)
        _ = try path.methods["moveTo"]?(&state, [.number(2), .number(5)], adapterContext)
        XCTAssertEqual(try path.methods["isEmpty"]?(&state, [], adapterContext), .value(.bool(false)))
        _ = try path.methods["lineTo"]?(&state, [.integer(8), .integer(9)], adapterContext)
        _ = try path.methods["close"]?(&state, [], adapterContext)
        XCTAssertEqual(state["commands"]?.array?.last, .object(["op": .string("close")]))
        _ = try path.methods["lineTo"]?(&state, [.integer(11), .integer(12)], adapterContext)
        XCTAssertEqual(Array(state["commands"]?.array?.suffix(2) ?? []), [
            .object(["op": .string("move"), "x": .number(2), "y": .number(5)]),
            .object(["op": .string("line"), "x": .number(11), "y": .number(12)]),
        ])
        _ = try path.methods["set"]?(&state, [copiedPath], adapterContext)
        XCTAssertEqual(state, copiedState)
        _ = try path.methods["rewind"]?(&state, [], adapterContext)
        XCTAssertEqual(state, copiedState)
        XCTAssertThrowsError(try path.methods["lineTo"]?(&state, [.number(.infinity), .number(0)], adapterContext))
        XCTAssertThrowsError(try path.methods["moveTo"]?(&state, [.number(0)], adapterContext))
        XCTAssertNil(path.methods["quadTo"], "Unimplemented Path overloads must stay unavailable")
    }

    func testMatrixImplementsBoundedAffinePreAndPostTransforms() throws {
        let matrix = try XCTUnwrap(self.registry.adapters["android.graphics.Matrix"])
        let constructor = try XCTUnwrap(matrix.constructor)
        let adapterContext = context()
        var state = try constructor([], adapterContext)
        XCTAssertEqual(try matrix.methods["isIdentity"]?(&state, [], adapterContext), .value(.bool(true)))
        _ = try matrix.methods["postTranslate"]?(&state, [.integer(2), .integer(3)], adapterContext)
        _ = try matrix.methods["postScale"]?(&state, [.number(4), .number(5)], adapterContext)
        XCTAssertEqual(state["values"], .array([.number(4), .number(0), .number(8), .number(0), .number(5), .number(15), .number(0), .number(0), .number(1)]))
        _ = try matrix.methods["preTranslate"]?(&state, [.integer(1), .integer(1)], adapterContext)
        XCTAssertEqual(state["values"], .array([.number(4), .number(0), .number(12), .number(0), .number(5), .number(20), .number(0), .number(0), .number(1)]))
        _ = try matrix.methods["preScale"]?(&state, [.integer(2), .integer(3)], adapterContext)
        XCTAssertEqual(state["values"], .array([.number(8), .number(0), .number(12), .number(0), .number(15), .number(20), .number(0), .number(0), .number(1)]))
        XCTAssertEqual(try matrix.methods["isIdentity"]?(&state, [], adapterContext), .value(.bool(false)))

        _ = try matrix.methods["setTranslate"]?(&state, [.number(-3.5), .integer(9)], adapterContext)
        XCTAssertEqual(state["values"], .array([.number(1), .number(0), .number(-3.5), .number(0), .number(1), .number(9), .number(0), .number(0), .number(1)]))
        _ = try matrix.methods["setScale"]?(&state, [.integer(2), .number(0.5)], adapterContext)
        XCTAssertEqual(state["values"], .array([.number(2), .number(0), .number(0), .number(0), .number(0.5), .number(0), .number(0), .number(0), .number(1)]))
        _ = try matrix.methods["reset"]?(&state, [], adapterContext)
        XCTAssertEqual(try matrix.methods["isIdentity"]?(&state, [], adapterContext), .value(.bool(true)))
        XCTAssertThrowsError(try matrix.methods["postScale"]?(&state, [.number(.infinity), .number(1)], adapterContext))
        XCTAssertThrowsError(try matrix.methods["postTranslate"]?(&state, [.number(1)], adapterContext))
        XCTAssertNil(matrix.methods["mapPoints"], "Array-mutating mapping overloads must remain unavailable")
    }

    func testByteBufferWrapAndCursorOperationsAreBounded() throws {
        let adapter = try XCTUnwrap(self.registry.adapters["java.nio.ByteBuffer"])
        XCTAssertNil(adapter.constructor)
        XCTAssertEqual(Set(adapter.staticMethods.keys), ["wrap"])
        let wrap = try XCTUnwrap(adapter.staticMethods["wrap"])
        let adapterContext = AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("callback")
        }, resolve: { reference in
            guard reference.object?["$handle"]?.string == "bytes" else { throw AyuBridgeFailure("invalid_handle", "Unknown test array") }
            return AyuBridgeAdapterSnapshot(className: "[B", state: [
                "component": .string("byte"), "values": .array([.integer(-1), .integer(2), .integer(127)]),
            ])
        })
        let byteArray: AyuBridgeValue = .object(["$handle": .string("bytes"), "$class": .string("[B")])
        guard case let .instance(className, initial) = try wrap([byteArray], adapterContext) else {
            return XCTFail("ByteBuffer.wrap must return a bounded owned adapter instance")
        }
        XCTAssertEqual(className, "java.nio.ByteBuffer")
        XCTAssertNoThrow(try adapter.validateState(initial))

        var state = initial
        XCTAssertEqual(try adapter.methods["capacity"]?(&state, [], context()), .value(.integer(3)))
        XCTAssertEqual(try adapter.methods["get"]?(&state, [], context()), .value(.integer(-1)))
        XCTAssertEqual(state["position"], .integer(1))
        _ = try adapter.methods["mark"]?(&state, [], context())
        _ = try adapter.methods["put"]?(&state, [.integer(7)], context())
        XCTAssertEqual(state["position"], .integer(2))
        XCTAssertEqual(try adapter.methods["get"]?(&state, [.integer(1)], context()), .value(.integer(7)))
        _ = try adapter.methods["reset"]?(&state, [], context())
        XCTAssertEqual(state["position"], .integer(1))
        _ = try adapter.methods["flip"]?(&state, [], context())
        XCTAssertEqual(state["limit"], .integer(1))
        XCTAssertEqual(state["position"], .integer(0))
        XCTAssertEqual(try adapter.methods["remaining"]?(&state, [], context()), .value(.integer(1)))
        XCTAssertEqual(try adapter.methods["hasRemaining"]?(&state, [], context()), .value(.bool(true)))

        XCTAssertThrowsError(try adapter.methods["put"]?(&state, [.integer(128)], context()))
        XCTAssertThrowsError(try adapter.methods["get"]?(&state, [.integer(1)], context()))
        XCTAssertThrowsError(try adapter.methods["reset"]?(&state, [], context()))
        XCTAssertThrowsError(try wrap([byteArray, .integer(0), .integer(2)], adapterContext))
        XCTAssertThrowsError(try wrap([.integer(0)], adapterContext))
    }

    // View

    func testViewVisibilityAndTransforms() throws {
        let adapter = self.runtimeAdapter("android.view.View")
        var state: [String: AyuBridgeValue] = [:]
        _ = try adapter.methods["setVisibility"]?(&state, [.integer(8)], context())
        XCTAssertEqual(try adapter.methods["getVisibility"]?(&state, [], context()), .value(.integer(8)))
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
        var state = try self.constructor(adapter, [.integer(0), .integer(10), .integer(20)])
        XCTAssertEqual(try adapter.methods["getAction"]?(&state, [], context()), .value(.integer(0)))
        XCTAssertEqual(try adapter.methods["getX"]?(&state, [], context()), .value(.number(10)))
        XCTAssertEqual(try adapter.methods["getPointerCount"]?(&state, [], context()), .value(.integer(1)))
        XCTAssertThrowsError(try self.constructor(adapter, [.integer(9), .integer(10), .integer(20)]))
        XCTAssertThrowsError(try self.constructor(adapter, [.integer(0), .integer(10)]))
    }

    func testPaintAlphaEditsColorChannelOnly() throws {
        let adapter = self.runtimeAdapter("android.graphics.Paint")
        var state = try self.constructor(adapter)
        let partiallyTransparentRed = Int64(Int32(bitPattern: 0x80FF_0000))
        _ = try adapter.methods["setColor"]?(&state, [.integer(partiallyTransparentRed)], context())
        _ = try adapter.methods["setAlpha"]?(&state, [.integer(255)], context())
        XCTAssertEqual(state["color"], .integer(-65_536))
        _ = try adapter.methods["setAlpha"]?(&state, [.integer(64)], context())
        XCTAssertEqual(state["color"], .integer(0x40FF_0000))
        XCTAssertThrowsError(try adapter.methods["setAlpha"]?(&state, [.integer(256)], context()))
        XCTAssertNoThrow(try adapter.methods["setColor"]?(&state, [.integer(-1)], context()))
        XCTAssertThrowsError(try adapter.methods["setColor"]?(&state, [.integer(Int64(Int32.max) + 1)], context()))
    }

    func testCanvasRecordsPathOps() throws {
        let adapter = self.runtimeAdapter("android.graphics.Canvas")
        var state = try self.constructor(adapter)
        // Android's drawCircle(cx, cy, radius, paint). The recorded op holds the geometry only.
        let paint: AyuBridgeValue = .object(["$handle": .string("paint"), "$class": .string("android.graphics.Paint")])
        XCTAssertThrowsError(try adapter.methods["drawCircle"]?(&state, [.integer(5), .number(6.5), .integer(2)], context()))
        _ = try adapter.methods["drawCircle"]?(&state, [.integer(5), .number(6.5), .integer(2), paint], context())
        _ = try adapter.methods["drawLine"]?(&state, [.integer(0), .integer(0), .integer(3), .integer(4)], context())
        let path = state["path"]?.array ?? []
        XCTAssertEqual(path.count, 2)
        XCTAssertEqual(path[0], .object(["op": .string("circle"), "x": .number(5), "y": .number(6.5), "radius": .number(2)]))
        XCTAssertEqual(path[1], .object(["op": .string("line"), "x0": .number(0), "y0": .number(0), "x1": .number(3), "y1": .number(4)]))
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
        for name in ["android.os.Bundle", "android.os.SystemClock", "android.content.Intent", "android.net.Uri", "android.graphics.Color", "android.graphics.Paint", "android.graphics.Paint$Cap", "android.graphics.Paint$Join", "android.graphics.Paint$Style", "android.graphics.Path", "android.graphics.Matrix", "android.graphics.Rect", "android.graphics.RectF", "android.graphics.Typeface", "android.text.TextUtils$TruncateAt", "android.text.Spanned", "android.text.SpannableString", "android.text.SpannableStringBuilder", "android.text.style.StyleSpan", "android.text.style.UnderlineSpan", "android.text.style.StrikethroughSpan", "android.text.style.TypefaceSpan", "android.text.style.ForegroundColorSpan", "android.text.style.CharacterStyle", "android.text.style.MetricAffectingSpan", "android.text.style.UpdateAppearance", "android.text.style.UpdateLayout", "android.widget.ImageView$ScaleType", "android.graphics.drawable.ColorDrawable", "android.graphics.drawable.GradientDrawable", "android.view.MotionEvent", "android.os.Handler", "java.lang.String", "java.lang.Float", "java.lang.Object", "java.lang.CharSequence", "java.lang.ref.WeakReference", "android.content.res.ColorStateList", "java.net.URL", "java.net.URLEncoder", "java.util.Scanner", "java.io.ByteArrayOutputStream", "java.util.Collections", "java.util.Collections$SingletonList"] {
            XCTAssertNotNil(self.registry.adapters[name], name)
        }
        for name in ["android.graphics.Canvas", "android.widget.ScrollView", "android.widget.CheckBox"] {
            XCTAssertNil(self.registry.adapters[name], name)
        }
    }

    func testSystemClockExposesOnlyMonotonicUptimeMilliseconds() throws {
        let adapter = self.runtimeAdapter("android.os.SystemClock")
        XCTAssertNil(adapter.constructor)
        XCTAssertEqual(Set(adapter.staticMethods.keys), ["uptimeMillis"])
        let uptimeMillis = try XCTUnwrap(adapter.staticMethods["uptimeMillis"])
        let firstResult = try uptimeMillis([], context())
        let secondResult = try uptimeMillis([], context())
        guard case let .value(.integer(first)) = firstResult,
              case let .value(.integer(second)) = secondResult else {
            return XCTFail("uptimeMillis must return an integer")
        }
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertGreaterThanOrEqual(second, first)
        XCTAssertThrowsError(try uptimeMillis([.integer(0)], context()))
    }

    func testJavaStringUsesUtf16LengthAndBoundedOperations() throws {
        let adapter = self.runtimeAdapter("java.lang.String")
        let constructor = try XCTUnwrap(adapter.constructor)
        var state = try constructor([.string("A😀B")], context())
        XCTAssertEqual(try adapter.methods["length"]?(&state, [], context()), .value(.integer(4)))
        XCTAssertEqual(try adapter.methods["isEmpty"]?(&state, [], context()), .value(.bool(false)))
        XCTAssertEqual(try adapter.methods["toString"]?(&state, [], context()), .value(.string("A😀B")))
        XCTAssertEqual(try adapter.methods["contains"]?(&state, [.string("😀")], context()), .value(.bool(true)))
        XCTAssertEqual(try adapter.methods["startsWith"]?(&state, [.string("A")], context()), .value(.bool(true)))
        XCTAssertEqual(try adapter.methods["endsWith"]?(&state, [.string("B")], context()), .value(.bool(true)))
        XCTAssertEqual(try adapter.methods["compareTo"]?(&state, [.string("A😀C")], context()), .value(.integer(-1)))
        var hashed = try constructor([.string("abc")], context())
        XCTAssertEqual(try adapter.methods["hashCode"]?(&hashed, [], context()), .value(.integer(96_354)))
        var padded = try constructor([.string("\u{0009} text \u{0020}")], context())
        XCTAssertEqual(try adapter.methods["trim"]?(&padded, [], context()), .value(.string("text")))
        XCTAssertEqual(try adapter.methods["equals"]?(&state, [.string("A😀B")], context()), .value(.bool(true)))
        XCTAssertEqual(try adapter.methods["equals"]?(&state, [.string("other")], context()), .value(.bool(false)))
        XCTAssertEqual(try adapter.methods["concat"]?(&state, [.string("!")], context()), .value(.string("A😀B!")))
        XCTAssertEqual(try adapter.methods["substring"]?(&state, [.integer(1), .integer(3)], context()), .value(.string("😀")))
        XCTAssertThrowsError(try adapter.methods["substring"]?(&state, [.integer(2), .integer(3)], context()))
        XCTAssertEqual(try adapter.staticMethods["valueOf"]?([.null], context()), .value(.string("null")))
        XCTAssertEqual(try adapter.staticMethods["valueOf"]?([.integer(Int64.max)], context()), .value(.string(String(Int64.max))))
        XCTAssertThrowsError(try adapter.staticMethods["valueOf"]?([.number(1.5)], context()))
        XCTAssertThrowsError(try constructor([.string(String(repeating: "x", count: 65_537))], context()))
        var maximumString = try constructor([.string(String(repeating: "x", count: 65_536))], context())
        XCTAssertThrowsError(try adapter.methods["concat"]?(&maximumString, [.string("y")], context()))
        XCTAssertThrowsError(try constructor([.integer(1)], context()))
        XCTAssertThrowsError(try adapter.methods["substring"]?(&state, [.integer(-1)], context()))

        var composed = try constructor([.string("é")], context())
        let decomposedText = String(decoding: [UInt16(0x0065), 0x0301], as: UTF16.self)
        XCTAssertEqual(try adapter.methods["equals"]?(&composed, [.string(decomposedText)], context()), .value(.bool(false)))
        XCTAssertEqual(try adapter.methods["contains"]?(&composed, [.string(decomposedText)], context()), .value(.bool(false)))
        XCTAssertEqual(try adapter.methods["startsWith"]?(&composed, [.string(decomposedText)], context()), .value(.bool(false)))
        XCTAssertEqual(try adapter.methods["endsWith"]?(&composed, [.string(decomposedText)], context()), .value(.bool(false)))
        XCTAssertEqual(try adapter.methods["compareTo"]?(&composed, [.string(decomposedText)], context()), .value(.integer(132)))

        var repeatedPrefix = try constructor([.string(String(repeating: "a", count: 5_000) + "b")], context())
        XCTAssertEqual(try adapter.methods["contains"]?(&repeatedPrefix, [.string(String(repeating: "a", count: 2_500) + "b")], context()), .value(.bool(true)))
    }

    func testFloatAdapterRoundsToFiniteIEEE754SinglePrecision() throws {
        let adapter = self.runtimeAdapter("java.lang.Float")
        XCTAssertEqual(adapter.constants["TYPE"], .object(["$java_class": .string("float")]))
        XCTAssertEqual(adapter.constants["MIN_VALUE"], .number(Double(Float.leastNonzeroMagnitude)))
        let constructor = try XCTUnwrap(adapter.constructor)
        var state = try constructor([.number(1.1)], context())
        XCTAssertEqual(state["value"], .number(Double(Float(1.1))))
        XCTAssertEqual(try adapter.methods["floatValue"]?(&state, [], context()), .value(.number(Double(Float(1.1)))))
        XCTAssertEqual(try adapter.staticMethods["parseFloat"]?([.string("-2.5")], context()), .value(.number(-2.5)))
        let valueOf = try XCTUnwrap(adapter.staticMethods["valueOf"])
        guard case let .instance(className, boxed) = try valueOf([.integer(7)], context()) else {
            return XCTFail("Float.valueOf must return an owned Float snapshot")
        }
        XCTAssertEqual(className, "java.lang.Float")
        XCTAssertEqual(boxed["value"], .number(7))
        XCTAssertNoThrow(try adapter.validateState(boxed))
        XCTAssertThrowsError(try constructor([.number(.infinity)], context()))
        XCTAssertThrowsError(try constructor([.string("NaN")], context()))
        // Float.parseFloat accepts Java's hexadecimal floating-point literals.
        XCTAssertEqual(try constructor([.string("0x1.0p2")], context())["value"], .number(4))
        XCTAssertNil(adapter.methods["toString"], "Float formatting is not claimed")
    }

    func testObjectAndWeakReferenceExposeOnlyTheBoundedHandleSubset() throws {
        let object = self.runtimeAdapter("java.lang.Object")
        XCTAssertEqual(try self.constructor(object), [:])
        XCTAssertNil(object.methods["equals"], "Object identity methods are not emulated")

        let weak = self.runtimeAdapter("java.lang.ref.WeakReference")
        let targetHandle = "00000000-0000-0000-0000-000000000001"
        let target: AyuBridgeValue = .object(["$handle": .string(targetHandle), "$class": .string("java.lang.Object")])
        let targetContext = AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("callback")
        }, resolve: { reference in
            guard reference == target else { throw AyuBridgeFailure("invalid_handle", "Target was released") }
            return AyuBridgeAdapterSnapshot(className: "java.lang.Object", state: [:])
        })
        let constructor = try XCTUnwrap(weak.constructor)
        var state = try constructor([target], targetContext)
        XCTAssertEqual(state, ["target_handle": .string(targetHandle), "target_class": .string("java.lang.Object")])
        XCTAssertNoThrow(try weak.validateState(state))
        XCTAssertEqual(try weak.methods["get"]?(&state, [], targetContext), .value(target))
        XCTAssertEqual(try weak.methods["isEnqueued"]?(&state, [], targetContext), .value(.bool(false)))
        let releasedContext = AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("callback")
        }, resolve: { _ in throw AyuBridgeFailure("invalid_handle", "Target was released") })
        XCTAssertEqual(try weak.methods["get"]?(&state, [], releasedContext), .value(.null))
        _ = try weak.methods["clear"]?(&state, [], targetContext)
        XCTAssertNoThrow(try weak.validateState(state))
        XCTAssertEqual(try weak.methods["get"]?(&state, [], targetContext), .value(.null))
        XCTAssertEqual(try constructor([.null], context()), ["target_handle": .null, "target_class": .null])
        XCTAssertThrowsError(try constructor([.string("not a reference")], context()))
    }

    func testSpannableAdaptersKeepBoundedTextAndSpanRanges() throws {
        let spanned = self.runtimeAdapter("android.text.Spanned")
        XCTAssertEqual(spanned.constants["SPAN_INCLUSIVE_EXCLUSIVE"], .integer(17))
        XCTAssertEqual(spanned.constants["SPAN_EXCLUSIVE_EXCLUSIVE"], .integer(33))
        XCTAssertEqual(spanned.constants["SPAN_INCLUSIVE_INCLUSIVE"], .integer(18))
        XCTAssertEqual(spanned.constants["SPAN_EXCLUSIVE_INCLUSIVE"], .integer(34))

        let styleSpan = self.runtimeAdapter("android.text.style.StyleSpan")
        let styleConstructor = try XCTUnwrap(styleSpan.constructor)
        var bold = try styleConstructor([.integer(1)], context())
        XCTAssertEqual(try styleSpan.methods["getStyle"]?(&bold, [], context()), .value(.integer(1)))
        XCTAssertThrowsError(try styleConstructor([.integer(4)], context()))

        let span: AyuBridgeValue = .object(["$handle": .string("span-1"), "$class": .string(styleSpan.name)])
        let boldState = bold
        let spanContext = AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("callback")
        }, resolve: { reference in
            guard reference == span else { throw AyuBridgeFailure("invalid_handle", "Unknown span") }
            return AyuBridgeAdapterSnapshot(className: styleSpan.name, state: boldState)
        })

        let builder = self.runtimeAdapter("android.text.SpannableStringBuilder")
        let builderConstructor = try XCTUnwrap(builder.constructor)
        var state = try builderConstructor([.string("abc")], context())
        XCTAssertEqual(state["text"], .string("abc"))
        _ = try builder.methods["setSpan"]?(&state, [span, .integer(0), .integer(3), .integer(33)], spanContext)
        XCTAssertEqual(try builder.methods["getSpanStart"]?(&state, [span], spanContext), .value(.integer(0)))
        XCTAssertEqual(try builder.methods["getSpanEnd"]?(&state, [span], spanContext), .value(.integer(3)))
        XCTAssertEqual(try builder.methods["getSpanFlags"]?(&state, [span], spanContext), .value(.integer(33)))

        let styleClass: AyuBridgeValue = .object(["$java_class": .string(styleSpan.name)])
        XCTAssertEqual(try builder.methods["getSpans"]?(&state, [.integer(0), .integer(3), styleClass], spanContext), .value(.array([span])))
        XCTAssertEqual(try builder.methods["getSpans"]?(&state, [.integer(0), .integer(3), .object(["$java_class": .string("java.lang.Object")])], spanContext), .value(.array([span])))

        _ = try builder.methods["replace"]?(&state, [.integer(1), .integer(2), .string("XYZ")], spanContext)
        XCTAssertEqual(state["text"], .string("aXYZc"))
        XCTAssertEqual(try builder.methods["getSpanEnd"]?(&state, [span], spanContext), .value(.integer(5)))
        _ = try builder.methods["delete"]?(&state, [.integer(1), .integer(4)], spanContext)
        XCTAssertEqual(state["text"], .string("ac"))
        XCTAssertEqual(try builder.methods["getSpanEnd"]?(&state, [span], spanContext), .value(.integer(2)))
        _ = try builder.methods["append"]?(&state, [.string("!")], spanContext)
        XCTAssertEqual(state["text"], .string("ac!"))
        XCTAssertEqual(try builder.methods["subSequence"]?(&state, [.integer(1), .integer(3)], spanContext), .value(.string("c!")))
        XCTAssertEqual(builder.receiverMethods, ["append", "replace", "delete"])
        XCTAssertNoThrow(try builder.validateState(state))
        var invalidState = state
        invalidState["spans"] = .array([.object(["span": span, "start": .integer(0), "end": .integer(99), "flags": .integer(33)])])
        XCTAssertThrowsError(try builder.validateState(invalidState))
        XCTAssertEqual(try builder.methods["removeSpan"]?(&state, [span], spanContext), .value(.null))
        XCTAssertEqual(state["spans"], .array([]))

        var supplementary = try builderConstructor([.string("A😀B")], context())
        XCTAssertEqual(try builder.methods["length"]?(&supplementary, [], context()), .value(.integer(4)))
        XCTAssertThrowsError(try builder.methods["subSequence"]?(&supplementary, [.integer(2), .integer(3)], context()))
        XCTAssertThrowsError(try builder.methods["delete"]?(&supplementary, [.integer(2), .integer(3)], context()))

        let immutable = self.runtimeAdapter("android.text.SpannableString")
        XCTAssertNil(immutable.methods["append"])
        XCTAssertThrowsError(try immutable.constructor?([], context()))
        XCTAssertThrowsError(try builder.methods["setSpan"]?(&state, [.object(["$handle": .string("other"), "$class": .string("java.lang.Object")]), .integer(0), .integer(1), .integer(33)], spanContext))
    }

    func testColorStateListValueOfIsAStatelessArgbSnapshot() throws {
        let adapter = self.runtimeAdapter("android.content.res.ColorStateList")
        let color = AyuBridgeValue.integer(Int64(Int32(bitPattern: 0x8012_34AB)))
        let valueOf = try XCTUnwrap(adapter.staticMethods["valueOf"])
        guard case .instance(let className, var state) = try valueOf([color], context()) else {
            return XCTFail("ColorStateList.valueOf must create a typed owned value")
        }
        XCTAssertEqual(className, adapter.name)
        XCTAssertNoThrow(try adapter.validateState(state))
        XCTAssertEqual(try adapter.methods["getDefaultColor"]?(&state, [], context()), .value(color))
        XCTAssertEqual(try adapter.methods["isStateful"]?(&state, [], context()), .value(.bool(false)))
        let states: AyuBridgeValue = .object(["$handle": .string("states"), "$class": .string("[I")])
        let arrayContext = AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("callback")
        }, resolve: { reference in
            guard reference == states else { throw AyuBridgeFailure("invalid_handle", "Unknown int array") }
            return AyuBridgeAdapterSnapshot(className: "[I", state: ["component": .string("int"), "values": .array([.integer(1)])])
        })
        XCTAssertEqual(try adapter.methods["getColorForState"]?(&state, [states, .integer(-1)], arrayContext), .value(color))
        XCTAssertThrowsError(try valueOf([.integer(Int64(UInt32.max))], context()))
        XCTAssertNil(adapter.constructor, "Array-backed state specifications are not implemented")
    }

    func testByteArrayOutputStreamAndSingletonListStayInMemoryAndBounded() throws {
        let output = self.runtimeAdapter("java.io.ByteArrayOutputStream")
        let constructor = try XCTUnwrap(output.constructor)
        var state = try constructor([.integer(16)], context())
        _ = try output.methods["write"]?(&state, [.integer(255)], context())
        XCTAssertEqual(try output.methods["size"]?(&state, [], context()), .value(.integer(1)))
        XCTAssertEqual(try output.methods["toByteArray"]?(&state, [], context()), .value(.array([.integer(-1)])))
        _ = try output.methods["write"]?(&state, [.integer(127)], context())
        XCTAssertEqual(try output.methods["toByteArray"]?(&state, [], context()), .value(.array([.integer(-1), .integer(127)])))
        let byteArray: AyuBridgeValue = .object(["$handle": .string("bytes"), "$class": .string("[B")])
        let adapterContext = AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("callback")
        }, resolve: { reference in
            guard reference.object?["$handle"]?.string == "bytes" else { throw AyuBridgeFailure("invalid_handle", "Unknown test array") }
            return AyuBridgeAdapterSnapshot(className: "[B", state: [
                "component": .string("byte"), "values": .array([.integer(-2), .integer(3), .integer(4)]),
            ])
        })
        _ = try output.methods["write"]?(&state, [byteArray, .integer(1), .integer(2)], adapterContext)
        XCTAssertEqual(try output.methods["toByteArray"]?(&state, [], context()), .value(.array([.integer(-1), .integer(127), .integer(3), .integer(4)])))
        XCTAssertThrowsError(try output.methods["write"]?(&state, [byteArray, .integer(3), .integer(1)], adapterContext))
        XCTAssertThrowsError(try output.methods["write"]?(&state, [.array([.integer(1), .integer(2)])], context()))
        _ = try output.methods["reset"]?(&state, [], context())
        XCTAssertEqual(try output.methods["size"]?(&state, [], context()), .value(.integer(0)))
        XCTAssertThrowsError(try constructor([.integer(65_537)], context()))

        let collections = self.runtimeAdapter("java.util.Collections")
        let singletonList = try XCTUnwrap(collections.staticMethods["singletonList"])
        guard case .instance(let className, var listState) = try singletonList([.string("item")], context()) else {
            return XCTFail("Collections.singletonList must return an owned read-only value")
        }
        XCTAssertEqual(className, "java.util.Collections$SingletonList")
        let singleton = self.runtimeAdapter(className)
        XCTAssertEqual(try singleton.methods["size"]?(&listState, [], context()), .value(.integer(1)))
        XCTAssertEqual(try singleton.methods["get"]?(&listState, [.integer(0)], context()), .value(.string("item")))
        XCTAssertEqual(try singleton.methods["toArray"]?(&listState, [], context()), .value(.array([.string("item")])))
        XCTAssertThrowsError(try singleton.methods["get"]?(&listState, [.integer(1)], context()))
        XCTAssertNil(singleton.methods["add"], "SingletonList mutation is not exposed")
    }

    func testUrlParserAndFormEncoderAreBoundedAndDoNotPerformIO() throws {
        let url = self.runtimeAdapter("java.net.URL")
        let constructor = try XCTUnwrap(url.constructor)
        var state = try constructor([.string("https://example.com:8443/a%20b?q=x%2By#frag")], context())
        XCTAssertEqual(try url.methods["getProtocol"]?(&state, [], context()), .value(.string("https")))
        XCTAssertEqual(try url.methods["getHost"]?(&state, [], context()), .value(.string("example.com")))
        XCTAssertEqual(try url.methods["getPort"]?(&state, [], context()), .value(.integer(8443)))
        XCTAssertEqual(try url.methods["getDefaultPort"]?(&state, [], context()), .value(.integer(443)))
        XCTAssertEqual(try url.methods["getPath"]?(&state, [], context()), .value(.string("/a%20b")))
        XCTAssertEqual(try url.methods["getQuery"]?(&state, [], context()), .value(.string("q=x%2By")))
        XCTAssertEqual(try url.methods["getRef"]?(&state, [], context()), .value(.string("frag")))
        XCTAssertEqual(try url.methods["getFile"]?(&state, [], context()), .value(.string("/a%20b?q=x%2By")))
        XCTAssertEqual(try url.methods["toExternalForm"]?(&state, [], context()), .value(.string("https://example.com:8443/a%20b?q=x%2By#frag")))
        XCTAssertThrowsError(try constructor([.string("relative/path")], context()))
        XCTAssertThrowsError(try constructor([.string("file:///private/data")], context()))
        XCTAssertThrowsError(try constructor([.string("https://user:pass@example.com/")], context()))
        var oversizedURLState = state
        oversizedURLState["query"] = .string(String(repeating: "q", count: 8_193))
        XCTAssertThrowsError(try url.validateState(oversizedURLState))
        XCTAssertNil(url.methods["openConnection"], "URL parsing must not imply network access")

        let encoder = self.runtimeAdapter("java.net.URLEncoder")
        XCTAssertEqual(try encoder.staticMethods["encode"]?([.string("a b+c/é"), .string("UTF-8")], context()),
                       .value(.string("a+b%2Bc%2F%C3%A9")))
        XCTAssertEqual(try encoder.staticMethods["encode"]?([.string("x_y.*-~")], context()),
                       .value(.string("x_y.*-%7E")))
        XCTAssertThrowsError(try encoder.staticMethods["encode"]?([.string("x"), .string("UTF-16")], context()))
        XCTAssertThrowsError(try encoder.staticMethods["encode"]?([.string(String(repeating: "é", count: 22_000))], context()))
    }

    func testScannerOnlyConsumesBoundedInMemoryText() throws {
        let adapter = self.runtimeAdapter("java.util.Scanner")
        let constructor = try XCTUnwrap(adapter.constructor)
        var state = try constructor([.string(" 12 blue\r\n-7 true")], context())
        XCTAssertEqual(try adapter.methods["hasNext"]?(&state, [], context()), .value(.bool(true)))
        XCTAssertEqual(try adapter.methods["hasNextInt"]?(&state, [], context()), .value(.bool(true)))
        XCTAssertEqual(try adapter.methods["nextInt"]?(&state, [], context()), .value(.integer(12)))
        XCTAssertEqual(try adapter.methods["hasNextInt"]?(&state, [], context()), .value(.bool(false)))
        XCTAssertThrowsError(try adapter.methods["nextInt"]?(&state, [], context()))
        XCTAssertEqual(try adapter.methods["next"]?(&state, [], context()), .value(.string("blue")))
        XCTAssertEqual(try adapter.methods["nextLine"]?(&state, [], context()), .value(.string("")))
        XCTAssertEqual(try adapter.methods["nextLong"]?(&state, [], context()), .value(.integer(-7)))
        XCTAssertEqual(try adapter.methods["hasNextBoolean"]?(&state, [], context()), .value(.bool(true)))
        XCTAssertEqual(try adapter.methods["nextBoolean"]?(&state, [], context()), .value(.bool(true)))
        XCTAssertEqual(try adapter.methods["hasNext"]?(&state, [], context()), .value(.bool(false)))
        XCTAssertThrowsError(try constructor([], context()))
        XCTAssertNil(adapter.methods["useDelimiter"], "Regex delimiter overloads remain unsupported")
        XCTAssertNil(adapter.methods["close"], "The adapter owns no file, stream or network resource")
    }

    private func callHandlerPost(with reference: AyuBridgeValue) throws {
        let handler = self.runtimeAdapter("android.os.Handler")
        var state = try self.constructor(handler)
        _ = try handler.methods["post"]?(&state, [reference], context())
    }

    private func context(animationPreference: Bool = true) -> AyuBridgeAdapterContext {
        AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in throw AyuBridgeFailure.unsupported("callback") },
            resolve: { reference in
                AyuBridgeAdapterSnapshot(className: reference.object?["$java_class"]?.string ?? "unknown", state: reference.object ?? [:])
            }, readAnimationPreference: { animationPreference })
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
