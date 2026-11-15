import Foundation

// "Send Confirmations" of AyuGram: ask before sending these kinds of messages.
public final class AyuSendConfirmations: @unchecked Sendable {
    public static let shared = AyuSendConfirmations()

    public enum Kind: String, CaseIterable {
        case sticker
        case gif
        case voice
        case round
    }

    private let store = AyuSettingsStore.shared

    private init() {
        var defaults: [String: Any] = [:]
        for kind in Kind.allCases {
            defaults[AyuSendConfirmations.key(kind)] = false
        }
        self.store.register(defaults: defaults)
    }

    private static func key(_ kind: Kind) -> String {
        return "ayu.confirm.\(kind.rawValue)"
    }

    public func isEnabled(_ kind: Kind) -> Bool {
        return self.store.bool(AyuSendConfirmations.key(kind))
    }

    public func setEnabled(_ kind: Kind, _ value: Bool) {
        self.store.setBool(value, AyuSendConfirmations.key(kind))
    }
}
