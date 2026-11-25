import AVFoundation
import TelegramAudio
import XCTest

/// Pure snapshots and activation policy: never configure the test process's AVAudioSession.
final class RecordingMicrophoneInputTests: XCTestCase {
    private func port(_ type: AVAudioSession.Port, _ uid: String) -> AudioSessionRoutePort {
        return AudioSessionRoutePort(portType: type, uid: uid, name: uid)
    }

    func testWiredBluetoothAndUSBAreInputsOnlyWhenReportedByAvailableInputs() {
        let ports = [self.port(.builtInMic, "phone"), self.port(.headsetMic, "wired"), self.port(.bluetoothHFP, "hfp"), self.port(.bluetoothLE, "le"), self.port(.usbAudio, "usb")]
        let result = recordingMicrophonePorts(route: AudioSessionRoute(outputs: [], inputs: [], availableInputs: ports))!
        XCTAssertEqual(result.map { $0.uid }, ["phone", "wired", "hfp", "le", "usb"])
        XCTAssertEqual(result.map { $0.kind }, [.builtin, .headset, .headset, .headset, .headset])
        XCTAssertEqual(result.map { $0.name }, ports.map { $0.name })
    }

    func testOutputHeadphonesAndA2DPDoNotCreateAnAccessoryMicrophone() {
        let outputs = [self.port(.headphones, "headphones"), self.port(.bluetoothA2DP, "a2dp"), self.port(.builtInSpeaker, "speaker")]
        let result = recordingMicrophonePorts(route: AudioSessionRoute(outputs: outputs, inputs: [], availableInputs: [self.port(.builtInMic, "phone")]))!
        XCTAssertEqual(result.map { $0.uid }, ["phone"])
        XCTAssertEqual(result.map { $0.kind }, [.builtin])
        let unsupported = recordingMicrophonePorts(route: AudioSessionRoute(outputs: [], inputs: [], availableInputs: outputs))!
        XCTAssertEqual(unsupported.map { $0.kind }, [.other, .other, .other])
    }

    func testUnknownInventoryDoesNotPromoteCurrentOrOutputPortsToAvailable() {
        let route = AudioSessionRoute(outputs: [self.port(.bluetoothHFP, "hfp")], inputs: [self.port(.headsetMic, "stale")], availableInputs: nil)
        XCTAssertNil(recordingMicrophonePorts(route: route))
        XCTAssertEqual(recordingMicrophonePorts(route: AudioSessionRoute(outputs: route.outputs, inputs: route.inputs, availableInputs: [])), [])
    }

    func testOnlyAnActivatedRecordingHolderCanApplyThePreference() {
        for type in [ManagedAudioSessionType.voiceMessageRecording(beginWithTone: false, pauseMusicOnRecording: true), .record(speaker: true, video: false, withOthers: true), .record(speaker: false, video: true, withOthers: true)] {
            XCTAssertTrue(recordingMicrophonePreferenceApplies(type: type, sessionActivated: true, hasRecordingHolder: true, callKitActive: false))
            XCTAssertFalse(recordingMicrophonePreferenceApplies(type: type, sessionActivated: false, hasRecordingHolder: true, callKitActive: false))
            XCTAssertFalse(recordingMicrophonePreferenceApplies(type: type, sessionActivated: true, hasRecordingHolder: false, callKitActive: false))
            XCTAssertFalse(recordingMicrophonePreferenceApplies(type: type, sessionActivated: true, hasRecordingHolder: true, callKitActive: true))
        }
    }

    func testCallsAndPlaybackNeverApplyTheRecordingPreference() {
        for type in [ManagedAudioSessionType.voiceCall, .videoCall, .ambient, .play(mixWithOthers: false), .play(mixWithOthers: true), .playWithPossiblePortOverride] {
            XCTAssertFalse(recordingMicrophonePreferenceApplies(type: type, sessionActivated: true, hasRecordingHolder: true, callKitActive: false))
        }
        XCTAssertFalse(recordingMicrophonePreferenceApplies(type: nil, sessionActivated: true, hasRecordingHolder: true, callKitActive: false))
    }
}
