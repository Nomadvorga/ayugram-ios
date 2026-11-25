import AVFoundation
import SGSimpleSettings

/// Both the successful activation and the current holder matter: a stale recording type must
/// not let a queued route notification change an incoming call's or a player's microphone.
public func recordingMicrophonePreferenceApplies(type: ManagedAudioSessionType?, sessionActivated: Bool, hasRecordingHolder: Bool, callKitActive: Bool) -> Bool {
    return type?.isRecord == true && sessionActivated && hasRecordingHolder && !callKitActive
}

/// Recording input classification is separate from the call's output menu. A2DP, headphones
/// and speakers never qualify just because audio is playing through them. USB inputs include
/// USB-C headsets and external microphones; the UI names the actual accessory.
public func recordingMicrophonePorts(route: AudioSessionRoute) -> [ExteraChatAppearanceSettings.MicrophonePort]? {
    return route.availableInputs?.map { port in
        let kind: ExteraChatAppearanceSettings.MicrophonePort.Kind
        switch port.portType {
        case .builtInMic: kind = .builtin
        case .headsetMic, .bluetoothHFP, .bluetoothLE, .usbAudio: kind = .headset
        default: kind = .other
        }
        return ExteraChatAppearanceSettings.MicrophonePort(uid: port.uid, name: port.name, kind: kind)
    }
}

/// Read-only: the settings page must not activate, recategorize or take the session from a call
/// or a player just to discover ports. Nil means iOS has not reported inputs for this session.
public func currentRecordingMicrophonePorts() -> [ExteraChatAppearanceSettings.MicrophonePort]? {
    return recordingMicrophonePorts(route: AudioSessionRoute(AVAudioSession.sharedInstance()))
}
