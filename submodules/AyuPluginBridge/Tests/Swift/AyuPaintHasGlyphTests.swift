import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// `Paint.hasGlyph(String)`: Android's rule (one glyph, none missing) over CoreText's font cascade.
final class AyuPaintHasGlyphTests: XCTestCase {
    private func has(_ text: String, _ typeface: AyuBridgeTypefaceValue = .default) -> Bool {
        AyuBridgeGlyphCoverage.hasGlyph(text, typeface: typeface)
    }

    func testASingleCharacterIsCoveredWhenAFontDrawsIt() {
        for text in ["A", "я", "中", "✓", "→", "😀", " "] {
            XCTAssertTrue(self.has(text), text)
        }
        // An unassigned code point and a private-use one are drawn by no font.
        for text in ["\u{0378}", "\u{E000}", "\u{10FFFD}"] {
            XCTAssertFalse(self.has(text), text)
        }
        XCTAssertFalse(self.has(""))
    }

    func testSeveralCharactersAreCoveredOnlyAsOneGlyph() {
        XCTAssertFalse(self.has("AB"))
        XCTAssertFalse(self.has("A😀"))
        XCTAssertFalse(self.has("A\u{0378}"))
        // Sequences the emoji font draws as one glyph: a flag, a ZWJ family, a skin tone, a keycap.
        XCTAssertTrue(self.has("\u{1F1FA}\u{1F1F8}"))
        XCTAssertTrue(self.has("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"))
        XCTAssertTrue(self.has("\u{1F44D}\u{1F3FD}"))
        XCTAssertTrue(self.has("a\u{0301}"))
        // No flag exists for an unassigned pair of regional indicators.
        XCTAssertFalse(self.has("\u{1F1FF}\u{1F1FF}"))
        XCTAssertFalse(self.has(String(repeating: "A", count: AyuBridgeGlyphCoverage.maximumScalars + 1)))
    }

    func testAVariationSelectorNeedsThePresentationItAsksFor() {
        // The emoji presentation of a text-default character, and the text presentation of the same one.
        XCTAssertTrue(self.has("\u{2764}\u{FE0F}"))
        XCTAssertTrue(self.has("\u{2764}\u{FE0E}"))
        // A letter has no emoji presentation; a selector with no base is no pair.
        XCTAssertFalse(self.has("A\u{FE0F}"))
        XCTAssertFalse(self.has("A\u{FE0E}"))
        XCTAssertFalse(self.has("\u{4E2D}\u{E0100}"))
    }

    func testEveryTypefaceFallsBackToTheSameSystemFonts() throws {
        let serif = try AyuBridgeTypefaceValue.family("serif"), mono = try AyuBridgeTypefaceValue.family("monospace")
        for typeface in [serif, mono, AyuBridgeTypefaceValue.default.styled(3)] {
            XCTAssertTrue(self.has("A", typeface))
            XCTAssertTrue(self.has("😀", typeface))
            XCTAssertFalse(self.has("\u{0378}", typeface))
        }
    }

    func testThePaintAnswersWithItsTypeface() async throws {
        let session = try await AyuMemberTestHost()
        let paint = try await session.construct("android.graphics.Paint")
        ayuExpect(try await session.invoke(paint, "hasGlyph", [.string("✓")]), .bool(true))
        ayuExpect(try await session.invoke(paint, "hasGlyph", [.string("\u{0378}")]), .bool(false))
        let typeface = try await session.invokeStatic("android.graphics.Typeface", "create", [.string("sans-serif"), .integer(0)])
        _ = try await session.invoke(paint, "setTypeface", [typeface])
        ayuExpect(try await session.invoke(paint, "hasGlyph", [.string("😀")]), .bool(true))
        ayuExpect(try await session.invoke(paint, "hasGlyph", [.string("ab")]), .bool(false))
        var code = await session.failure { try await session.invoke(paint, "hasGlyph") }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        code = await session.failure { try await session.invoke(paint, "hasGlyph", [.null]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        code = await session.failure { try await session.invoke(paint, "hasGlyph", [.integer(65)]) }
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
    }
}

@MainActor
final class AyuPaintHasGlyphEndToEndTests: XCTestCase {
    func testAPluginPicksASymbolTheDeviceCanDraw() async throws {
        let stack = try AyuEndToEnd.shared()
        let source = AyuEndToEnd.source(id: "e2e_has_glyph", """
        from base_plugin import BasePlugin
        \(AyuEndToEnd.recorder)


        def ui_glyph(symbol, fallback):
            from android.graphics import Paint, Typeface
            paint = Paint()
            paint.setTypeface(Typeface.create("sans-serif", 0))
            return symbol if bool(paint.hasGlyph(symbol)) else fallback


        class GlyphPlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                self.record("glyphs", lambda: [ui_glyph("\\u2713", "v"), ui_glyph("\\u0378", "?"), ui_glyph("\\U0001F600", ":)"), ui_glyph("ok", "-")])
        """)
        let preview = try await stack.preview(source)
        XCTAssertEqual(preview.plugin.blockers, [], "the path has no static blocker")
        let id = try await stack.start(source)
        XCTAssertEqual(stack.stored(id, "glyphs"), .array([.string("\u{2713}"), .string("?"), .string("\u{1F600}"), .string("-")]))
        await stack.remove(id)
    }
}
