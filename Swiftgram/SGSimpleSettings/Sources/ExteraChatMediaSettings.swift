import Foundation

/// Playback audio mixing is independent of recording input and recording/music policy.
public final class ExteraChatMediaSettings {
    public static let shared = ExteraChatMediaSettings()
    public static let pauseOtherAudioKey = "extera.chatMedia.pauseOtherAudio"
    private let store = AyuSettingsStore.shared

    private init() {
        // Preserve native exclusive audible playback by default.
        self.store.register(defaults: [Self.pauseOtherAudioKey: true])
    }

    public var pauseOtherAudio: Bool {
        get { return self.store.bool(Self.pauseOtherAudioKey) }
        set { self.store.setBool(newValue, Self.pauseOtherAudioKey) }
    }

    public static func mixesPlayback(requestedMixing: Bool, pauseOtherAudio: Bool) -> Bool {
        return requestedMixing || !pauseOtherAudio
    }
}
