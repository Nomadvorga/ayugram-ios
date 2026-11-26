import Foundation

enum ExteraZalgoFilter {
    private struct Cluster {
        let scalars: [Unicode.Scalar]

        var marks: [Unicode.Scalar] {
            return self.scalars.filter(ExteraZalgoFilter.isZalgoMark)
        }

        var hasBase: Bool {
            return self.scalars.contains { !ExteraZalgoFilter.isCombiningMark($0) }
        }
    }

    static func clean(_ text: String) -> String {
        var clusters: [Cluster] = []
        var current: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            if !Self.isCombiningMark(scalar), !current.isEmpty {
                clusters.append(Cluster(scalars: current))
                current.removeAll(keepingCapacity: true)
            }
            current.append(scalar)
        }
        if !current.isEmpty {
            clusters.append(Cluster(scalars: current))
        }

        var removeMarks = [Bool](repeating: false, count: clusters.count)
        for (index, cluster) in clusters.enumerated() {
            let marks = cluster.marks
            guard !marks.isEmpty else { continue }
            let hasOverlay = marks.contains(where: Self.isOverlayMark)
            // Keep normal decomposed letters such as a + dot-below + circumflex
            // when Foundation can compose them back to one Unicode scalar.
            let remainsUncomposed = String(String.UnicodeScalarView(cluster.scalars))
                .precomposedStringWithCanonicalMapping
                .unicodeScalars
                .contains(where: Self.isZalgoMark)
            if !cluster.hasBase || hasOverlay || marks.count >= 3 || (marks.count >= 2 && remainsUncomposed) {
                removeMarks[index] = true
            }
        }

        var result = String.UnicodeScalarView()
        var changed = false
        for (index, cluster) in clusters.enumerated() {
            for scalar in cluster.scalars {
                if removeMarks[index] && Self.isZalgoMark(scalar) {
                    changed = true
                } else {
                    result.append(scalar)
                }
            }
        }
        return changed ? String(result) : text
    }

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private static func isZalgoMark(_ scalar: Unicode.Scalar) -> Bool {
        // Do not treat script-specific vowel signs or emoji variation selectors
        // as decorative marks. U+20E3 is the emoji keycap enclosure.
        guard Self.isCombiningMark(scalar), scalar.value != 0x20E3 else { return false }
        switch scalar.value {
        case 0x0300 ... 0x036F, 0x0488 ... 0x0489, 0x1AB0 ... 0x1AFF,
             0x1DC0 ... 0x1DFF, 0x20D0 ... 0x20FF, 0xFE20 ... 0xFE2F:
            return true
        default:
            return false
        }
    }

    private static func isOverlayMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0334 ... 0x0338, 0x0488 ... 0x0489, 0x20D0 ... 0x20FF, 0xFE20 ... 0xFE2F:
            return true
        default:
            return false
        }
    }
}
