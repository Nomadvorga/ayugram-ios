import SGSimpleSettings

public extension ManagedAudioSessionType {
    /// Only audible playback can opt into mixing. Calls, ambient effects and recording
    /// retain their existing category options and microphone/output policy.
    func exteraMixesPlaybackWithOtherAudio(pauseOtherAudio: Bool) -> Bool? {
        switch self {
        case let .play(mixWithOthers):
            return ExteraChatMediaSettings.mixesPlayback(requestedMixing: mixWithOthers, pauseOtherAudio: pauseOtherAudio)
        case .playWithPossiblePortOverride:
            return !pauseOtherAudio
        case .ambient, .record, .voiceCall, .videoCall:
            return nil
        }
    }
}
