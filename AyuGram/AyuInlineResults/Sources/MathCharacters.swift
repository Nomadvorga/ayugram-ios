// Ported from exteraGram for Android (com.exteragram.messenger.inline.math), GPL v3 or later, © exteraGram.

import Foundation

// The parser walks text one Unicode scalar at a time, each held as a single-scalar Character.
// The classes below follow java.lang.Character, which the Android code relies on, not Swift's wider
// `isNumber` / `isLetter` (those also accept superscripts, fractions and letter-like marks).
extension Character {
    var isMathDigit: Bool {
        guard let scalar = self.unicodeScalars.first else {
            return false
        }
        return scalar.properties.generalCategory == .decimalNumber
    }

    var isMathLetter: Bool {
        guard let scalar = self.unicodeScalars.first else {
            return false
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }
}

func mathCharacters(_ text: String) -> [Character] {
    return text.unicodeScalars.map { Character($0) }
}
