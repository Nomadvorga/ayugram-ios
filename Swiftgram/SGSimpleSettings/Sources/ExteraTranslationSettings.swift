import Foundation

/// Preferences shared by translation and Apple's voice message recognition.
public final class ExteraTranslationSettings {
    public static let shared = ExteraTranslationSettings()
    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: [
            "extera.appleSpeechLocaleIdentifier": "",
            "extera.appleSpeechOnDeviceOnly": false
        ])
    }

    /// A Speech framework locale identifier (for example, "en-US"). Empty uses the app language.
    public var appleSpeechLocaleIdentifier: String {
        get { return self.store.string("extera.appleSpeechLocaleIdentifier") }
        set {
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value != self.appleSpeechLocaleIdentifier {
                self.store.setString(value, "extera.appleSpeechLocaleIdentifier")
            }
        }
    }

    /// Require recognition on the device; fail when the selected locale has no local model.
    public var appleSpeechOnDeviceOnly: Bool {
        get { return self.store.bool("extera.appleSpeechOnDeviceOnly") }
        set {
            if newValue != self.appleSpeechOnDeviceOnly {
                self.store.setBool(newValue, "extera.appleSpeechOnDeviceOnly")
            }
        }
    }
}
