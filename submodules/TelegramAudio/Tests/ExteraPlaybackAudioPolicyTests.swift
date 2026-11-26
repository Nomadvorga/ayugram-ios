import TelegramAudio
import XCTest

final class ExteraPlaybackAudioPolicyTests: XCTestCase {
    func testAudiblePlaybackMayMixWithoutChangingItsOutputType() {
        XCTAssertEqual(ManagedAudioSessionType.play(mixWithOthers: false).exteraMixesPlaybackWithOtherAudio(pauseOtherAudio: true), false)
        XCTAssertEqual(ManagedAudioSessionType.play(mixWithOthers: false).exteraMixesPlaybackWithOtherAudio(pauseOtherAudio: false), true)
        XCTAssertEqual(ManagedAudioSessionType.playWithPossiblePortOverride.exteraMixesPlaybackWithOtherAudio(pauseOtherAudio: false), true)
        XCTAssertEqual(ManagedAudioSessionType.playWithPossiblePortOverride.exteraMixesPlaybackWithOtherAudio(pauseOtherAudio: true), false)
    }

    func testNativeMixRequestWinsInBothPreferenceStates() {
        for value in [false, true] {
            XCTAssertEqual(ManagedAudioSessionType.play(mixWithOthers: true).exteraMixesPlaybackWithOtherAudio(pauseOtherAudio: value), true)
        }
    }

    func testRecordingCallsAndAmbientKeepTheirExistingPolicy() {
        let types: [ManagedAudioSessionType] = [.ambient, .voiceCall, .videoCall,
            .record(speaker: false, video: false, withOthers: false),
            .record(speaker: true, video: false, withOthers: true),
            .record(speaker: false, video: true, withOthers: true)]
        for type in types {
            for value in [false, true] {
                XCTAssertNil(type.exteraMixesPlaybackWithOtherAudio(pauseOtherAudio: value))
            }
        }
    }
}
