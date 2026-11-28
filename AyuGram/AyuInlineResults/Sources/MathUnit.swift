// Ported from exteraGram for Android (com.exteragram.messenger.inline.math), GPL v3 or later, © exteraGram.

import Foundation

enum UnitKind {
    case currency
    case length
    case mass
    case volume
    case area
    case temperature
    case speed
    case duration
}

final class MathUnit {
    let code: String
    let label: String
    let kind: UnitKind
    let scale: Double
    let offset: Double
    let russianLabel: String

    init(code: String, label: String, kind: UnitKind = .currency, scale: Double = 1.0, offset: Double = 0.0, russianLabel: String? = nil) {
        self.code = code
        self.label = label
        self.kind = kind
        self.scale = scale
        self.offset = offset
        self.russianLabel = russianLabel ?? label
    }

    func label(russian: Bool) -> String {
        return russian ? self.russianLabel : self.label
    }

    func toBase(_ value: Double) -> Double {
        return value * self.scale + self.offset
    }

    func fromBase(_ value: Double) -> Double {
        return (value - self.offset) / self.scale
    }
}
