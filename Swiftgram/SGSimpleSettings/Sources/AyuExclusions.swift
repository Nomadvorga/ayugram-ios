import Foundation

// Per-chat overrides of the ghost mode and saving settings ("Read Exclusion",
// "Typing Exclusion" and "Saving Exclusion" in AyuGram for Android).
// Peers are keyed by their 64-bit PeerId value.
public final class AyuExclusions: @unchecked Sendable {
    public static let shared = AyuExclusions()

    public enum Kind: String, CaseIterable {
        case read
        case typing
        case saving
    }

    public enum Mode: Int, CaseIterable {
        case `default` = 0
        case never = 1
        case always = 2
    }

    private let store = AyuSettingsStore.shared

    private init() {
    }

    private func key(_ kind: Kind) -> String {
        return "ayu.exclusions.\(kind.rawValue)"
    }

    public func hasAny(_ kind: Kind) -> Bool {
        return !self.store.intDictionary(self.key(kind)).isEmpty
    }

    public func mode(_ kind: Kind, peerId: Int64) -> Mode {
        guard let rawValue = self.store.intDictionary(self.key(kind))[String(peerId)] else {
            return .default
        }
        return Mode(rawValue: rawValue) ?? .default
    }

    public func setMode(_ mode: Mode, kind: Kind, peerId: Int64) {
        var entries = self.store.intDictionary(self.key(kind))
        if mode == .default {
            entries.removeValue(forKey: String(peerId))
        } else {
            entries[String(peerId)] = mode.rawValue
        }
        self.store.setIntDictionary(entries, self.key(kind))
    }
}
