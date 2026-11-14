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

    private let defaults: UserDefaults

    private init() {
        self.defaults = UserDefaults(suiteName: APP_GROUP_IDENTIFIER) ?? .standard
    }

    private func key(_ kind: Kind) -> String {
        return "ayu.exclusions.\(kind.rawValue)"
    }

    private func entries(_ kind: Kind) -> [String: Int] {
        return self.defaults.dictionary(forKey: self.key(kind)) as? [String: Int] ?? [:]
    }

    public func hasAny(_ kind: Kind) -> Bool {
        return !self.entries(kind).isEmpty
    }

    public func mode(_ kind: Kind, peerId: Int64) -> Mode {
        guard let rawValue = self.entries(kind)[String(peerId)] else {
            return .default
        }
        return Mode(rawValue: rawValue) ?? .default
    }

    public func setMode(_ mode: Mode, kind: Kind, peerId: Int64) {
        var entries = self.entries(kind)
        if mode == .default {
            entries.removeValue(forKey: String(peerId))
        } else {
            entries[String(peerId)] = mode.rawValue
        }
        self.defaults.set(entries, forKey: self.key(kind))
    }
}
