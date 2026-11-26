import Foundation
import XCTest

let APP_GROUP_IDENTIFIER = "ExteraNativeChatTests.\(UUID().uuidString)"

final class ExteraChatMediaSettingsTests: XCTestCase {
    func testDefaultPreservesNativeExclusivePlayback() {
        XCTAssertTrue(ExteraChatMediaSettings.shared.pauseOtherAudio)
    }

    override func tearDown() {
        ExteraChatMediaSettings.shared.pauseOtherAudio = true
        AyuSettingsStore.shared.userDefaults.removePersistentDomain(forName: APP_GROUP_IDENTIFIER)
        super.tearDown()
    }

    func testPlaybackMixingPreservesExplicitNativeMixRequests() {
        for pauses in [false, true] {
            XCTAssertTrue(ExteraChatMediaSettings.mixesPlayback(requestedMixing: true, pauseOtherAudio: pauses))
        }
        XCTAssertTrue(ExteraChatMediaSettings.mixesPlayback(requestedMixing: false, pauseOtherAudio: false))
        XCTAssertFalse(ExteraChatMediaSettings.mixesPlayback(requestedMixing: false, pauseOtherAudio: true))
    }

    func testSettingPersistsToAppGroupAndPublishesAfterWrite() {
        let settings = ExteraChatMediaSettings.shared
        var values: [Bool] = []
        let observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { _ in
            values.append(settings.pauseOtherAudio)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        settings.pauseOtherAudio = false
        XCTAssertEqual(values, [false])
        let reopened = UserDefaults(suiteName: APP_GROUP_IDENTIFIER)!
        XCTAssertEqual(reopened.persistentDomain(forName: APP_GROUP_IDENTIFIER)?[ExteraChatMediaSettings.pauseOtherAudioKey] as? Bool, false)
        settings.pauseOtherAudio = true
        XCTAssertEqual(values, [false, true])
    }
}
