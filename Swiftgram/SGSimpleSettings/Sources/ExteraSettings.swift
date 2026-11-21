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
        case forceSnow
        case centerTitle
        case singleCornerRadius
        case avatarCorners
        case chatListTitle
    }

    public enum ChatListTitle: Int, CaseIterable {
        case ayuGram = 0
        case fullName = 1
        case firstName = 2
        case chats = 3
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
            ExteraSettings.key(.forceSnow): false,
            ExteraSettings.key(.centerTitle): false,
            ExteraSettings.key(.singleCornerRadius): false,
            ExteraSettings.key(.avatarCorners): 28,
            ExteraSettings.key(.chatListTitle): ChatListTitle.ayuGram.rawValue,
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

    public var centerTitle: Bool {
        return self.value(.centerTitle)
    }

    public var singleCornerRadius: Bool {
        return self.value(.singleCornerRadius)
    }

    public var avatarCorners: Int {
        get { return min(28, max(0, self.store.int(ExteraSettings.key(.avatarCorners)))) }
        set {
            let value = min(28, max(0, newValue))
            if value != self.avatarCorners {
                self.store.setInt(value, ExteraSettings.key(.avatarCorners))
            }
        }
    }

    // Stateless geometry: caller applies it only when settings, scope or size change.
    public func avatarCornerRadius(forDiameter diameter: Double, isForum: Bool = false) -> Double {
        if isForum && !self.singleCornerRadius {
            return floor(max(0.0, diameter) * 0.25)
        }
        return floor(max(0.0, diameter) * 0.5 * Double(self.avatarCorners) / 28.0)
    }

    public var chatListTitle: ChatListTitle {
        get { return ChatListTitle(rawValue: self.store.int(ExteraSettings.key(.chatListTitle))) ?? .ayuGram }
        set {
            if newValue != self.chatListTitle {
                self.store.setInt(newValue.rawValue, ExteraSettings.key(.chatListTitle))
            }
        }
    }

    public func chatListTitleText(firstName: String, lastName: String, chatsTitle: String) -> String {
        switch self.chatListTitle {
        case .ayuGram:
            return "AyuGram"
        case .chats:
            return chatsTitle
        case .fullName:
            let name = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
            return name.isEmpty ? "AyuGram" : name
        case .firstName:
            return firstName.isEmpty ? "AyuGram" : firstName
        }
    }

    public var forceSnow: Bool {
        return self.value(.forceSnow)
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
