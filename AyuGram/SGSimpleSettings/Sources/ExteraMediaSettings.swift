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
            "extera.media.zoomSlider": true,
            "extera.media.staticZoom": false,
            "extera.media.unmuteWithVolumeButtons": false,
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

    /// Show a zoom control below the live round-video camera preview.
    public var zoomSlider: Bool {
        get { return self.store.bool("extera.media.zoomSlider") }
        set { self.store.setBool(newValue, "extera.media.zoomSlider") }
    }

    /// Keep the current round-video zoom when a pinch or slider gesture ends.
    /// The value belongs to the active lens and recording session, not a persisted startup zoom.
    public var staticZoom: Bool {
        get { return self.store.bool("extera.media.staticZoom") }
        set { self.store.setBool(newValue, "extera.media.staticZoom") }
    }

    /// iOS adaptation: an observed system-volume change unmutes an actively playing gallery video.
    /// Public APIs cannot consume hardware volume keys or identify their event source.
    public var unmuteWithVolumeButtons: Bool {
        get { return self.store.bool("extera.media.unmuteWithVolumeButtons") }
        set { self.store.setBool(newValue, "extera.media.unmuteWithVolumeButtons") }
    }

    /// Ignore initial/no-op observations, invalid samples and changes to zero volume.
    public static func shouldUnmuteVideo(previousVolume: Float, volume: Float) -> Bool {
        return previousVolume.isFinite && volume.isFinite
            && (0.0 ... 1.0).contains(previousVolume) && (0.0 ... 1.0).contains(volume)
            && volume > 0.0 && abs(volume - previousVolume) > 0.0001
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
