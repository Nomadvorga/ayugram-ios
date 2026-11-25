import Foundation

public enum ExteraSpeechLanguageSelection: Equatable, Sendable {
    case disabled
    case automatic
    case locale(String)
}

/// A value snapshot used to reject a queued start/result after speech preferences change.
public struct ExteraSpeechConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    public let localeIdentifier: String
    public let onDeviceOnly: Bool
    public let useManagedOfflineModel: Bool

    public init(isEnabled: Bool, localeIdentifier: String, onDeviceOnly: Bool, useManagedOfflineModel: Bool) {
        self.isEnabled = isEnabled
        self.localeIdentifier = localeIdentifier
        self.onDeviceOnly = onDeviceOnly
        self.useManagedOfflineModel = useManagedOfflineModel
    }

    public var selection: ExteraSpeechLanguageSelection {
        if !self.isEnabled { return .disabled }
        return self.localeIdentifier.isEmpty ? .automatic : .locale(self.localeIdentifier)
    }
}

/// Apple speech preferences. The existing language/on-device keys remain authoritative,
/// including for backup restoration and users upgrading from the original Apple path.
public final class ExteraSpeechSettings: @unchecked Sendable {
    public static let shared = ExteraSpeechSettings()
    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: [
            "extera.speech.isEnabled": true,
            "extera.speech.useManagedOfflineModel": false
        ])
    }

    public var isEnabled: Bool {
        get { return self.store.bool("extera.speech.isEnabled") }
        set { self.store.setBool(newValue, "extera.speech.isEnabled") }
    }

    /// Explicit opt-in to SpeechAnalyzer and installed/reserved Apple assets (iOS 26+).
    /// Never falls back to server recognition or downloads assets during transcription.
    public var useManagedOfflineModel: Bool {
        get { return self.store.bool("extera.speech.useManagedOfflineModel") }
        set { self.store.setBool(newValue, "extera.speech.useManagedOfflineModel") }
    }

    public var configuration: ExteraSpeechConfiguration {
        let legacy = ExteraTranslationSettings.shared
        return ExteraSpeechConfiguration(isEnabled: self.isEnabled, localeIdentifier: legacy.appleSpeechLocaleIdentifier,
            onDeviceOnly: legacy.appleSpeechOnDeviceOnly, useManagedOfflineModel: self.useManagedOfflineModel)
    }

    public var languageSelection: ExteraSpeechLanguageSelection {
        get { return self.configuration.selection }
        set {
            self.store.performBatchUpdates {
                switch newValue {
                case .disabled:
                    // Keep the previous language and offline preference for a later re-enable.
                    self.isEnabled = false
                case .automatic:
                    ExteraTranslationSettings.shared.appleSpeechLocaleIdentifier = ""
                    self.useManagedOfflineModel = false
                    self.isEnabled = true
                case let .locale(identifier):
                    let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !identifier.isEmpty else { return }
                    ExteraTranslationSettings.shared.appleSpeechLocaleIdentifier = identifier
                    self.useManagedOfflineModel = false
                    self.isEnabled = true
                }
            }
        }
    }

    /// Called only after an installed, reserved model was verified by the model manager.
    public func selectManagedOfflineModel(localeIdentifier: String) {
        self.store.performBatchUpdates {
            ExteraTranslationSettings.shared.appleSpeechLocaleIdentifier = localeIdentifier
            ExteraTranslationSettings.shared.appleSpeechOnDeviceOnly = true
            self.useManagedOfflineModel = true
            self.isEnabled = true
            SGSimpleSettings.shared.transcriptionBackend = SGSimpleSettings.TranscriptionBackend.apple.rawValue
        }
    }
}
