import Foundation

/// Testable locale matching; opening a catalogue does not reserve or install anything.
public enum ExteraSpeechLocalePolicy {
    public static func normalized(_ identifier: String) -> String {
        return identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    public static func resolve(_ identifier: String, supported: [String], preferred: [String]) -> String? {
        let identifier = identifier.hasSuffix("-raw") ? String(identifier.dropLast(4)) : identifier
        let normalized = self.normalized(identifier)
        let supported = supported.sorted()
        if let exact = supported.first(where: { self.normalized($0) == normalized }) { return exact }
        // Regional/script selections are explicit. Only bare app/predicted language codes
        // can resolve to a regional model; don't change a selected language silently.
        guard !normalized.contains("-"), !normalized.isEmpty else { return nil }
        for candidate in preferred where Locale(identifier: candidate).languageCode == normalized {
            if let exact = supported.first(where: { self.normalized($0) == self.normalized(candidate) }) { return exact }
        }
        return supported.first(where: { Locale(identifier: $0).languageCode == normalized })
    }
}

/// Prevents install/release from racing a managed analysis. Mutated only by the manager actor.
struct ExteraSpeechModelAccess {
    private(set) var maintenance = false
    private(set) var activeLease: UUID?

    mutating func beginMaintenance() -> Bool {
        guard !self.maintenance, self.activeLease == nil else { return false }
        self.maintenance = true
        return true
    }

    mutating func endMaintenance() { self.maintenance = false }

    mutating func beginRecognition() -> UUID? {
        guard !self.maintenance, self.activeLease == nil else { return nil }
        let lease = UUID()
        self.activeLease = lease
        return lease
    }

    mutating func endRecognition(_ lease: UUID) {
        if self.activeLease == lease { self.activeLease = nil }
    }
}

/// SpeechAnalyzer emits phrase ranges; SFSpeechRecognizer emits whole hypotheses.
/// Replace overlapping phrase hypotheses and join their original whitespace, including CJK.
struct ExteraSpeechTranscript {
    private struct Segment {
        let start: Double
        let end: Double
        let text: String
    }
    private var segments: [Segment] = []

    mutating func update(start: Double, end: Double, text: String) {
        guard start.isFinite, end.isFinite, start >= 0.0, end > start,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.segments.removeAll { $0.start < end && $0.end > start }
        self.segments.append(Segment(start: start, end: end, text: text))
        self.segments.sort { $0.start < $1.start }
    }

    var text: String {
        return self.segments.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
