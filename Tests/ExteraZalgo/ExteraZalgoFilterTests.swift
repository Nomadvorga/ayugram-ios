import XCTest

final class ExteraZalgoFilterTests: XCTestCase {
    func testSettingsLivePreviewSampleIsCleanedCompletely() {
        let sample = "Z̷͍͌ā̸̜l̸̞̂g̷͍̝o̶̩̓"
        XCTAssertEqual(ExteraZalgoFilter.clean(sample), "Zalgo")
    }

    func testOrdinarySingleCombiningAccentIsPreserved() {
        XCTAssertEqual(ExteraZalgoFilter.clean("Cafe\u{0301}"), "Cafe\u{0301}")
    }

    func testIsolatedTwoMarkClusterIsPreserved() {
        XCTAssertEqual(ExteraZalgoFilter.clean("a\u{0323}\u{0302}"), "a\u{0323}\u{0302}")
    }

    func testLongRunOfMarkedLettersIsCleaned() {
        XCTAssertEqual(ExteraZalgoFilter.clean("A\u{0338}B\u{0338}C\u{0338}D\u{0338}"), "ABCD")
    }

    func testLongRunOfNormalAccentsIsPreserved() {
        let text = "e\u{0301}e\u{0301}e\u{0301}e\u{0301}"
        XCTAssertEqual(Array(ExteraZalgoFilter.clean(text).unicodeScalars), Array(text.unicodeScalars))
    }

    func testTwoUncomposableMarksAreRemovedTogether() {
        XCTAssertEqual(ExteraZalgoFilter.clean("Z\u{034C}\u{034D}"), "Z")
    }

    func testScriptsAndEmojiRemainIntactNextToZalgo() {
        let normal = "مُحَمَّد हिन्दी שָׁלוֹם ❤️ 1️⃣ 👩🏽‍💻"
        XCTAssertEqual(ExteraZalgoFilter.clean(normal + " Z̷͍͌ā̸̜l̸̞̂g̷͍̝o̶̩̓"), normal + " Zalgo")
    }

    func testLeadingMarksAreRemoved() {
        XCTAssertEqual(ExteraZalgoFilter.clean("\u{0300}\u{034D}text"), "text")
    }

    func testCleanTextIsIdempotent() {
        let source = "Cafe\u{0301} Z̷͍͌ā̸̜l̸̞̂g̷͍̝o̶̩̓"
        let cleaned = ExteraZalgoFilter.clean(source)
        XCTAssertEqual(cleaned, "Cafe\u{0301} Zalgo")
        XCTAssertEqual(ExteraZalgoFilter.clean(cleaned), cleaned)
    }

    func testOneLargeStackIsCleanedWithoutLosingItsBase() {
        XCTAssertEqual(ExteraZalgoFilter.clean("x\u{0338}\u{030C}\u{034F}\u{0300}"), "x")
    }
}
