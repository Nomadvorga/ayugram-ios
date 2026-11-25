import Foundation

/// Media playback and round-video camera preferences ported from exteraGram.
public final class ExteraMediaSettings: @unchecked Sendable {
    public static let shared = ExteraMediaSettings()
    public static let doubleTapSeekDurations: [Int] = [5, 10, 15, 30]

    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: [
            "extera.media.doubleTapSeekDuration": 10,
            "extera.media.preferOriginalQuality": false,
            "extera.media.pauseOnMinimizeVideo": true,
            "extera.media.pauseOnMinimizeVoice": false,
            "extera.media.pauseOnMinimizeRound": false,
            "extera.media.askVideoMessagesCamera": false,
            // Preserve AyuGram's existing camera memory by default.
            "extera.media.rememberLastUsedCamera": true
        ])
    }

    /// Seconds skipped by a double tap in the video gallery (5, 10, 15 or 30).
    public var doubleTapSeekDuration: Int {
        get {
            let value = self.store.int("extera.media.doubleTapSeekDuration")
            return Self.doubleTapSeekDurations.contains(value) ? value : 10
        }
        set {
            self.store.setInt(Self.doubleTapSeekDurations.contains(newValue) ? newValue : 10, "extera.media.doubleTapSeekDuration")
        }
    }

    /// Play the uploaded original instead of an adaptive video representation in the gallery.
    public var preferOriginalQuality: Bool {
        get { return self.store.bool("extera.media.preferOriginalQuality") }
        set { self.store.setBool(newValue, "extera.media.preferOriginalQuality") }
    }

    /// Pause gallery videos when the application enters the background.
    public var pauseOnMinimizeVideo: Bool {
        get { return self.store.bool("extera.media.pauseOnMinimizeVideo") }
        set { self.store.setBool(newValue, "extera.media.pauseOnMinimizeVideo") }
    }

    /// Pause voice messages when the application enters the background.
    public var pauseOnMinimizeVoice: Bool {
        get { return self.store.bool("extera.media.pauseOnMinimizeVoice") }
        set { self.store.setBool(newValue, "extera.media.pauseOnMinimizeVoice") }
    }

    /// Pause round video messages when the application enters the background.
    public var pauseOnMinimizeRound: Bool {
        get { return self.store.bool("extera.media.pauseOnMinimizeRound") }
        set { self.store.setBool(newValue, "extera.media.pauseOnMinimizeRound") }
    }

    /// Reuse the last round-video camera stored by AyuCameraSettings.
    public var rememberLastUsedCamera: Bool {
        get { return self.store.bool("extera.media.rememberLastUsedCamera") }
        set { self.store.setBool(newValue, "extera.media.rememberLastUsedCamera") }
    }

    /// 0 = front, 1 = rear, 2 = ask before starting a recording.
    /// The explicit front/rear choices share the previous default-camera preference.
    public var videoMessagesCamera: Int {
        get {
            if self.store.bool("extera.media.askVideoMessagesCamera") { return 2 }
            return SGSimpleSettings.shared.startTelescopeWithRearCam ? 1 : 0
        }
        set {
            self.store.setBool(newValue == 2, "extera.media.askVideoMessagesCamera")
            if newValue == 0 || newValue == 1 {
                SGSimpleSettings.shared.startTelescopeWithRearCam = newValue == 1
            }
        }
    }
}
