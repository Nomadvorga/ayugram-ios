import Foundation

/// Fine-grained animation choices. Native EnergyUsageSettings remains authoritative for the
/// battery threshold, video/GIF autoplay and the legacy sticker/emoji/effects upper bounds.
public final class ExteraEnergySettings: @unchecked Sendable {
    public enum Feature: String, CaseIterable {
        case stickerKeyboard, stickerChat
        case emojiKeyboard, emojiReactions, emojiChat
        case wallpaper, topicSidebar, spoilers, blur, liquidGlass, scale, deletion
        case calls, particles

        public var group: Group? {
            return Group.allCases.first(where: { $0.features.contains(self) })
        }

        public var involvesMotion: Bool {
            switch self {
            case .blur, .liquidGlass, .topicSidebar: return false
            default: return true
            }
        }
    }

    public enum Group: String, CaseIterable {
        case stickers, emoji, chat

        public var features: [Feature] {
            switch self {
            case .stickers: return [.stickerKeyboard, .stickerChat]
            case .emoji: return [.emojiKeyboard, .emojiReactions, .emojiChat]
            case .chat: return [.wallpaper, .topicSidebar, .spoilers, .blur, .liquidGlass, .scale, .deletion]
            }
        }
    }

    public struct GroupState: Equatable {
        public let selected: Int
        public let total: Int
        /// Android's mixed group stays on when at least one child is selected (e.g. 6/7).
        public var isOn: Bool { return self.selected != 0 }

        public init(group: Group, selectedFeatures: Set<Feature>) {
            self.selected = group.features.filter { selectedFeatures.contains($0) }.count
            self.total = group.features.count
        }
    }

    public static let shared = ExteraEnergySettings()
    public static let followSystemKey = "extera.energy.followSystem"
    public static func key(for feature: Feature) -> String { return "extera.energy.\(feature.rawValue)" }
    public static var booleanKeys: [String] { return [Self.followSystemKey] + Feature.allCases.map { Self.key(for: $0) } }
    private let store = AyuSettingsStore.shared

    private init() {
        var defaults: [String: Any] = [Self.followSystemKey: false]
        for feature in Feature.allCases { defaults[Self.key(for: feature)] = true }
        self.store.register(defaults: defaults)
    }

    public var followSystem: Bool {
        get { return self.store.bool(Self.followSystemKey) }
        set { self.store.setBool(newValue, Self.followSystemKey) }
    }

    public func isEnabled(_ feature: Feature) -> Bool { return self.store.bool(Self.key(for: feature)) }

    public func setEnabled(_ feature: Feature, _ value: Bool) {
        self.store.setBool(value, Self.key(for: feature))
    }

    public func setGroup(_ group: Group, _ value: Bool) {
        self.store.performBatchUpdates {
            for feature in group.features { self.setEnabled(feature, value) }
        }
    }

    public var selectedFeatures: Set<Feature> {
        return Set(Feature.allCases.filter { self.isEnabled($0) })
    }

    /// iOS's native slider reserves <=4 for Never and >=96 for Always. Reuse those sentinels
    /// rather than introducing a second persisted threshold. Unknown battery level is not zero.
    /// Low Power Mode remains a safety upper bound, even when the battery slider is set to Never.
    public static func savingActive(threshold: Int32, followSystem: Bool, batteryLevel: Float?, systemLowPower: Bool) -> Bool {
        if systemLowPower { return true }
        if followSystem || threshold <= 4 { return false }
        if threshold >= 96 { return true }
        guard let batteryLevel, batteryLevel.isFinite, batteryLevel >= 0.0, batteryLevel <= 1.0 else { return false }
        return batteryLevel <= Float(threshold) / 100.0
    }

    /// Preferences can only restrict the native policy. Accessibility and system-saving gates
    /// cannot be overridden by enabling a child or a whole group.
    public static func allows(_ feature: Feature, selected: Bool, nativeEnabled: Bool, savingActive: Bool, reduceMotion: Bool, reduceTransparency: Bool) -> Bool {
        guard selected && nativeEnabled && !savingActive else { return false }
        if feature.involvesMotion && reduceMotion { return false }
        if (feature == .blur || feature == .liquidGlass) && reduceTransparency { return false }
        return true
    }
}
