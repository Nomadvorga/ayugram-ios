import CoreText
import Foundation
import UIKit

/// Android `Paint.hasGlyph(String)` (`libs/hwui/jni/Paint.cpp`) answered by CoreText's font cascade.
enum AyuBridgeGlyphCoverage {
    /// Longer than any sequence Unicode defines as one glyph, so a longer string is several glyphs on both platforms.
    static let maximumScalars = 64

    private struct Layout {
        var glyphs: [CGGlyph] = []
        var isMissing = false
        var isColor = false
    }

    static func hasGlyph(_ string: String, typeface: AyuBridgeTypefaceValue) -> Bool {
        let scalars = Array(string.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= Self.maximumScalars else { return false }
        let font = typeface.font(size: 12)
        // Android first asks its fonts for every base and variation selector pair.
        for index in scalars.indices.dropFirst() where Self.isVariationSelector(scalars[index]) {
            guard Self.hasVariation(base: scalars[index - 1], selector: scalars[index], font: font) else { return false }
            if scalars.count == 2 { return true }
        }
        let layout = Self.layout(string, font: font)
        if layout.glyphs.count != 1 && scalars.count > 1 { return false }
        if layout.glyphs.isEmpty || layout.isMissing { return false }
        if scalars.count == 2, scalars.allSatisfy(Self.isRegionalIndicator) {
            // A font may draw every unassigned pair with one placeholder flag: ZZ is reserved, so its glyph is that one.
            let unknown = Self.layout("\u{1F1FF}\u{1F1FF}", font: font)
            if unknown.glyphs.count != 1 || unknown.isMissing { return true }
            return unknown.glyphs[0] != layout.glyphs[0]
        }
        return true
    }

    private static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
    }

    private static func isRegionalIndicator(_ scalar: Unicode.Scalar) -> Bool {
        (0x1F1E6...0x1F1FF).contains(scalar.value)
    }

    /// iOS fonts carry no variation-sequence table: CoreText itself honours the two presentation
    /// selectors by choosing a colour or a text font, so a pair counts when that choice was possible.
    private static func hasVariation(base: Unicode.Scalar, selector: Unicode.Scalar, font: UIFont) -> Bool {
        guard selector.value == 0xFE0E || selector.value == 0xFE0F, base.properties.isEmoji else { return false }
        var pair = String.UnicodeScalarView()
        pair.append(base)
        pair.append(selector)
        let layout = Self.layout(String(pair), font: font)
        return layout.glyphs.count == 1 && !layout.isMissing && layout.isColor == (selector.value == 0xFE0F)
    }

    private static func layout(_ text: String, font: UIFont) -> Layout {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var result = Layout()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            var space: CGGlyph = 0
            if let attribute = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String],
               CFGetTypeID(attribute as CFTypeRef) == CTFontGetTypeID() {
                let runFont = attribute as! CTFont
                // CoreText draws a character no font covers with the Last Resort font instead of glyph 0.
                if CTFontCopyPostScriptName(runFont) as String == "LastResort" { result.isMissing = true }
                if CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs) { result.isColor = true }
                var character: UniChar = 0x20
                CTFontGetGlyphsForCharacters(runFont, &character, &space, 1)
            }
            for (glyph, advance) in zip(glyphs, advances) {
                if glyph == 0 { result.isMissing = true }
                // As Android, a zero-width space glyph is a placeholder a ligature left behind; 0xFFFF is CoreText's deleted glyph.
                if glyph == 0xFFFF || (space != 0 && glyph == space && advance.width == 0) { continue }
                result.glyphs.append(glyph)
            }
        }
        return result
    }
}
