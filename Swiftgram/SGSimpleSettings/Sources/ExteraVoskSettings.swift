import Foundation

public struct ExteraVoskConfiguration: Equatable, Sendable {
    public let isSelected: Bool
    public let isEnabled: Bool
    /// "none", "auto", or an exact Android catalogue language code.
    public let language: String

    public init(isSelected: Bool, isEnabled: Bool, language: String) {
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.language = language
    }
}

/// Independent Vosk preferences. Restoring these never installs model files.
public final class ExteraVoskSettings: @unchecked Sendable {
    public static let shared = ExteraVoskSettings()
    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: ["extera.vosk.isSelected": false, "extera.vosk.language": "none"])
    }

    public var isSelected: Bool {
        get { self.store.bool("extera.vosk.isSelected") }
        set { self.store.setBool(newValue, "extera.vosk.isSelected") }
    }

    public var language: String {
        get { self.store.string("extera.vosk.language") }
        set { self.store.setString(newValue, "extera.vosk.language") }
    }

    public var configuration: ExteraVoskConfiguration {
        ExteraVoskConfiguration(isSelected: self.isSelected, isEnabled: ExteraSpeechSettings.shared.isEnabled, language: self.language)
    }

    /// The caller verifies installation before selecting an explicit language.
    /// Automatic resolves only installed chat/app models, without downloading.
    public func select(language: String) {
        self.store.performBatchUpdates {
            self.language = language
            self.isSelected = true
            ExteraSpeechSettings.shared.isEnabled = language != "none"
        }
    }

    public func clearDeletedSelection(language: String) {
        self.store.performBatchUpdates {
            if self.language == language {
                self.language = "none"
                if self.isSelected { ExteraSpeechSettings.shared.isEnabled = false }
            }
        }
    }
}
