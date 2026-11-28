import Foundation

/// Device-wide chat-list, location presentation and recording input preferences.
public final class ExteraChatAppearanceSettings: @unchecked Sendable {
    public enum SwipeAction: String, CaseIterable {
        case folder, pin, read, archive, mute, delete
    }

    public enum DistanceUnit: String, CaseIterable {
        case automatic, kilometers, miles

        public func usesMetricSystem(locale: Locale) -> Bool {
            switch self {
            case .automatic:
                if #available(iOS 16.0, macOS 13.0, *) {
                    return locale.region?.identifier != "GB" && locale.measurementSystem == .metric
                } else {
                    return locale.regionCode != "GB" && locale.usesMetricSystem
                }
            case .kilometers: return true
            case .miles: return false
            }
        }
    }

    public enum Microphone: String, CaseIterable {
        case automatic, builtin, headset
    }

    public struct MicrophonePort: Equatable {
        public enum Kind: Equatable { case builtin, headset, other }
        public let uid: String
        public let name: String
        public let kind: Kind

        public init(uid: String, name: String, kind: Kind) {
            self.uid = uid
            self.name = name
            self.kind = kind
        }
    }

    public static let shared = ExteraChatAppearanceSettings()
    public static let swipeActionKey = "extera.chatAppearance.swipeAction"
    public static let distanceUnitKey = "extera.chatAppearance.distanceUnit"
    public static let microphoneKey = "extera.chatAppearance.microphone"
    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: [Self.swipeActionKey: SwipeAction.archive.rawValue, Self.distanceUnitKey: DistanceUnit.automatic.rawValue, Self.microphoneKey: Microphone.automatic.rawValue])
    }

    public var swipeAction: SwipeAction {
        get { return SwipeAction(rawValue: self.store.string(Self.swipeActionKey)) ?? .archive }
        set { self.store.setString(newValue.rawValue, Self.swipeActionKey) }
    }

    public var distanceUnit: DistanceUnit {
        get { return DistanceUnit(rawValue: self.store.string(Self.distanceUnitKey)) ?? .automatic }
        set { self.store.setString(newValue.rawValue, Self.distanceUnitKey) }
    }

    public var microphone: Microphone {
        get { return Microphone(rawValue: self.store.string(Self.microphoneKey)) ?? .automatic }
        set { self.store.setString(newValue.rawValue, Self.microphoneKey) }
    }

    /// Only actual input ports make an explicit choice available. An output-only pair of
    /// headphones is not a microphone. An empty/unknown input list always allows automatic.
    public static func microphoneOptions(inputs: [MicrophonePort]) -> [Microphone] {
        return Microphone.allCases.filter { choice in
            switch choice {
            case .automatic: return true
            case .builtin: return inputs.contains(where: { $0.kind == .builtin })
            case .headset: return inputs.contains(where: { $0.kind == .headset })
            }
        }
    }

    /// Nil means clear the application's preferred input and let iOS decide. Keep an already
    /// active matching accessory when several are available, otherwise use iOS's input order.
    /// The existing system-microphone debug override retains precedence over app preferences.
    public static func preferredRecordingInput(microphone: Microphone, inputs: [MicrophonePort], currentInputUIDs: [String], respectsSystemInput: Bool = false) -> MicrophonePort? {
        guard !respectsSystemInput, microphone != .automatic else { return nil }
        let candidates = inputs.filter { port in
            switch microphone {
            case .automatic: return false
            case .builtin: return port.kind == .builtin
            case .headset: return port.kind == .headset
            }
        }
        return candidates.first(where: { currentInputUIDs.contains($0.uid) }) ?? candidates.first
    }

    /// Full leftward swipes execute the last right-edge option. Only promote an action offered by the
    /// row, retaining all other actions and leaving unavailable choices on the native fallback.
    public static func prioritizeSwipe<Key: Equatable>(left: [Key], right: [Key], preferred: Key?) -> (left: [Key], right: [Key]) {
        guard let preferred, left.contains(preferred) || right.contains(preferred) else { return (left, right) }
        return (left.filter { $0 != preferred }, right.filter { $0 != preferred } + [preferred])
    }
}
