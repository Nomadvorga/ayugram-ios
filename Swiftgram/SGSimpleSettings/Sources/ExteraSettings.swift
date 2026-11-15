import Foundation

// MARK: AyuGram
// exteraGram's preferences that have no Swiftgram counterpart. Read from memory on hot paths.
public final class ExteraSettings {
    public static let shared = ExteraSettings()

    public enum Keys: String, CaseIterable {
        case disableNumberRounding
        case inAppVibration
        case replaceEditedWithIcon
        case hideShareButton
        case disableGreetingSticker
        case filterZalgo
    }

    private let store = AyuSettingsStore.shared

    private static func key(_ key: Keys) -> String {
        return "extera.\(key.rawValue)"
    }

    private init() {
        self.store.register(defaults: [
            ExteraSettings.key(.disableNumberRounding): false,
            ExteraSettings.key(.inAppVibration): true,
            ExteraSettings.key(.replaceEditedWithIcon): false,
            ExteraSettings.key(.hideShareButton): false,
            ExteraSettings.key(.disableGreetingSticker): false,
            ExteraSettings.key(.filterZalgo): false,
        ])
    }

    public func value(_ key: Keys) -> Bool {
        return self.store.bool(ExteraSettings.key(key))
    }

    public func set(_ key: Keys, _ value: Bool) {
        self.store.setBool(value, ExteraSettings.key(key))
    }

    public var disableNumberRounding: Bool {
        return self.value(.disableNumberRounding)
    }

    public var inAppVibration: Bool {
        return self.value(.inAppVibration)
    }

    public var replaceEditedWithIcon: Bool {
        return self.value(.replaceEditedWithIcon)
    }

    public var hideShareButton: Bool {
        return self.value(.hideShareButton)
    }

    public var disableGreetingSticker: Bool {
        return self.value(.disableGreetingSticker)
    }

    public var filterZalgo: Bool {
        return self.value(.filterZalgo)
    }

    // "Filter Zalgo": runs of combining marks beyond what real scripts use are dropped.
    public func filteredText(_ text: String) -> String {
        guard self.filterZalgo else {
            return text
        }
        var result = String.UnicodeScalarView()
        var combiningRun = 0
        var changed = false
        for scalar in text.unicodeScalars {
            let isCombining: Bool
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark:
                isCombining = true
            default:
                isCombining = false
            }
            if isCombining {
                combiningRun += 1
                if combiningRun > 2 {
                    changed = true
                    continue
                }
            } else {
                combiningRun = 0
            }
            result.append(scalar)
        }
        return changed ? String(result) : text
    }
}
