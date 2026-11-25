import Foundation
import XCTest

// Compile together with the unchanged production store and preference model.
let APP_GROUP_IDENTIFIER = "ExteraChatAppearanceTests.\(UUID().uuidString)"

final class ExteraChatAppearanceSettingsTests: XCTestCase {
    private typealias Settings = ExteraChatAppearanceSettings

    override func setUp() {
        super.setUp()
        _ = Settings.shared
        // Reset the production cache as well as disk between tests. Unknown values exercise
        // the compatibility fallback and avoid depending on XCTest's execution order.
        AyuSettingsStore.shared.setString("unknown", Settings.swipeActionKey)
        AyuSettingsStore.shared.setString("unknown", Settings.distanceUnitKey)
        AyuSettingsStore.shared.setString("unknown", Settings.microphoneKey)
    }

    override func tearDown() {
        AyuSettingsStore.shared.userDefaults.removePersistentDomain(forName: APP_GROUP_IDENTIFIER)
        super.tearDown()
    }

    func testUnknownStoredValuesUseNativeDefaults() {
        XCTAssertEqual(Settings.shared.swipeAction, .archive)
        XCTAssertEqual(Settings.shared.distanceUnit, .automatic)
        XCTAssertEqual(Settings.shared.microphone, .automatic)
        // Registration supplies defaults without migrating or writing a selection.
        AyuSettingsStore.shared.userDefaults.removePersistentDomain(forName: APP_GROUP_IDENTIFIER)
        XCTAssertEqual(AyuSettingsStore.shared.userDefaults.string(forKey: Settings.swipeActionKey), "archive")
        XCTAssertEqual(AyuSettingsStore.shared.userDefaults.string(forKey: Settings.distanceUnitKey), "automatic")
        XCTAssertEqual(AyuSettingsStore.shared.userDefaults.string(forKey: Settings.microphoneKey), "automatic")
    }

    func testEverySelectionPersistsToTheAppGroupSuite() {
        for action in Settings.SwipeAction.allCases {
            Settings.shared.swipeAction = action
            XCTAssertEqual(Settings.shared.swipeAction, action)
            let reopened = UserDefaults(suiteName: APP_GROUP_IDENTIFIER)!
            XCTAssertEqual(reopened.persistentDomain(forName: APP_GROUP_IDENTIFIER)?[Settings.swipeActionKey] as? String, action.rawValue)
        }
        for unit in Settings.DistanceUnit.allCases {
            Settings.shared.distanceUnit = unit
            XCTAssertEqual(Settings.shared.distanceUnit, unit)
            let reopened = UserDefaults(suiteName: APP_GROUP_IDENTIFIER)!
            XCTAssertEqual(reopened.persistentDomain(forName: APP_GROUP_IDENTIFIER)?[Settings.distanceUnitKey] as? String, unit.rawValue)
        }
        for microphone in Settings.Microphone.allCases {
            Settings.shared.microphone = microphone
            XCTAssertEqual(Settings.shared.microphone, microphone)
            let reopened = UserDefaults(suiteName: APP_GROUP_IDENTIFIER)!
            XCTAssertEqual(reopened.persistentDomain(forName: APP_GROUP_IDENTIFIER)?[Settings.microphoneKey] as? String, microphone.rawValue)
        }
    }

    func testConsumersAreNotifiedAfterPreferenceWritesAreReadable() {
        let changed = expectation(description: "Each distinct preference write notifies its consumers")
        changed.expectedFulfillmentCount = 3
        changed.assertForOverFulfill = true
        let observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { _ in
            XCTAssertEqual(Settings.shared.swipeAction, .mute)
            changed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        Settings.shared.swipeAction = .mute
        Settings.shared.swipeAction = .mute
        Settings.shared.distanceUnit = .miles
        Settings.shared.distanceUnit = .miles
        Settings.shared.microphone = .headset
        Settings.shared.microphone = .headset
        wait(for: [changed], timeout: 1.0)
        XCTAssertEqual(Settings.shared.distanceUnit, .miles)
        XCTAssertEqual(Settings.shared.microphone, .headset)
    }

    func testPromotingReadOrPinMovesItFromLeftToFullLeftwardSwipe() {
        for preferred in ["read", "pin", "unpin"] {
            let result = Settings.prioritizeSwipe(left: ["read", preferred], right: ["mute", "delete", "archive"], preferred: preferred)
            XCTAssertEqual(result.right, ["mute", "delete", "archive", preferred])
            XCTAssertFalse(result.left.contains(preferred))
            XCTAssertEqual(result.right.filter { $0 == preferred }.count, 1)
        }
    }

    func testPromotingExistingRightActionKeepsItsExactNativeKey() {
        for state in ["archive", "unarchive", "mute", "unmute", "delete", "folder"] {
            let result = Settings.prioritizeSwipe(left: ["read", "pin"], right: [state, "other"], preferred: state)
            XCTAssertEqual(result.left, ["read", "pin"])
            XCTAssertEqual(result.right, ["other", state])
        }
    }

    func testUnavailableActionPreservesNativeFallbackIncludingEmptyRows() {
        // Saved Messages cannot archive; deletion/unarchive may be disabled; a forum can lack read.
        for unavailable in ["archive", "delete", "unarchive", "read"] {
            let fallback = Settings.prioritizeSwipe(left: ["pin"], right: ["mute"], preferred: unavailable)
            XCTAssertEqual(fallback.left, ["pin"])
            XCTAssertEqual(fallback.right, ["mute"])
            let empty = Settings.prioritizeSwipe(left: [String](), right: [], preferred: unavailable)
            XCTAssertTrue(empty.left.isEmpty)
            XCTAssertTrue(empty.right.isEmpty)
        }
        let unchanged = Settings.prioritizeSwipe(left: [1, 2], right: [3, 4], preferred: nil)
        XCTAssertEqual(unchanged.left, [1, 2])
        XCTAssertEqual(unchanged.right, [3, 4])
    }

    func testPromotionIsIdempotentAndRetainsEveryOtherActionInOrder() {
        let actions = ["read", "pin", "mute", "delete", "archive", "folder"]
        for mask in 0 ..< (1 << actions.count) {
            let available = actions.enumerated().filter { mask & (1 << $0.offset) != 0 }.map { $0.element }
            let left = Array(available.prefix(2))
            let right = Array(available.dropFirst(2))
            for preferred in actions {
                let result = Settings.prioritizeSwipe(left: left, right: right, preferred: preferred)
                XCTAssertEqual(Set(result.left + result.right), Set(available))
                XCTAssertEqual(result.left.count + result.right.count, available.count)
                XCTAssertEqual(result.left.filter { $0 != preferred }, left.filter { $0 != preferred })
                XCTAssertEqual(result.right.filter { $0 != preferred }, right.filter { $0 != preferred })
                if available.contains(preferred) { XCTAssertEqual(result.right.last, preferred) }
                let again = Settings.prioritizeSwipe(left: result.left, right: result.right, preferred: preferred)
                XCTAssertEqual(again.left, result.left)
                XCTAssertEqual(again.right, result.right)
            }
        }
    }

    func testDistanceOverridesAndAutomaticRegionalBehavior() {
        let locales: [(String, Bool)] = [("en_US", false), ("en_GB", false), ("en_GB@calendar=gregorian", false), ("ru_RU", true), ("fr_FR", true), ("en_CA", true)]
        for (identifier, metric) in locales {
            let locale = Locale(identifier: identifier)
            XCTAssertEqual(Settings.DistanceUnit.automatic.usesMetricSystem(locale: locale), metric, identifier)
            XCTAssertTrue(Settings.DistanceUnit.kilometers.usesMetricSystem(locale: locale), identifier)
            XCTAssertFalse(Settings.DistanceUnit.miles.usesMetricSystem(locale: locale), identifier)
        }
    }

    func testMicrophoneOptionsOnlyOfferReportedInputs() {
        let builtin = Settings.MicrophonePort(uid: "phone", name: "Phone", kind: .builtin)
        let wired = Settings.MicrophonePort(uid: "wired", name: "Headset", kind: .headset)
        let outputOnly = Settings.MicrophonePort(uid: "a2dp", name: "Speaker", kind: .other)
        XCTAssertEqual(Settings.microphoneOptions(inputs: []), [.automatic])
        XCTAssertEqual(Settings.microphoneOptions(inputs: [outputOnly]), [.automatic])
        XCTAssertEqual(Settings.microphoneOptions(inputs: [builtin, outputOnly]), [.automatic, .builtin])
        XCTAssertEqual(Settings.microphoneOptions(inputs: [wired]), [.automatic, .headset])
        XCTAssertEqual(Settings.microphoneOptions(inputs: [builtin, wired]), [.automatic, .builtin, .headset])
    }

    func testRecordingMicrophoneSelectionDoesNotUseThePlaybackDevice() {
        let builtin = Settings.MicrophonePort(uid: "phone", name: "Phone", kind: .builtin)
        let accessory = Settings.MicrophonePort(uid: "headset-input", name: "Headset microphone", kind: .headset)
        XCTAssertEqual(Settings.preferredRecordingInput(microphone: .builtin, inputs: [accessory, builtin], currentInputUIDs: [accessory.uid]), builtin)
        XCTAssertEqual(Settings.preferredRecordingInput(microphone: .headset, inputs: [builtin, accessory], currentInputUIDs: ["headphones-output"]), accessory)
        XCTAssertNil(Settings.preferredRecordingInput(microphone: .automatic, inputs: [builtin, accessory], currentInputUIDs: [accessory.uid]))
    }

    func testDisconnectFallsBackToAutomaticAndReconnectReappliesSavedPreference() {
        let builtin = Settings.MicrophonePort(uid: "phone", name: "Phone", kind: .builtin)
        let headset = Settings.MicrophonePort(uid: "wired", name: "Headset", kind: .headset)
        Settings.shared.microphone = .headset
        XCTAssertEqual(Settings.preferredRecordingInput(microphone: Settings.shared.microphone, inputs: [builtin, headset], currentInputUIDs: [builtin.uid]), headset)
        XCTAssertNil(Settings.preferredRecordingInput(microphone: Settings.shared.microphone, inputs: [builtin], currentInputUIDs: [headset.uid]))
        XCTAssertNil(Settings.preferredRecordingInput(microphone: Settings.shared.microphone, inputs: [], currentInputUIDs: [headset.uid]))
        XCTAssertEqual(Settings.shared.microphone, .headset)
        XCTAssertEqual(Settings.preferredRecordingInput(microphone: Settings.shared.microphone, inputs: [builtin, headset], currentInputUIDs: [builtin.uid]), headset)
        XCTAssertNil(Settings.preferredRecordingInput(microphone: .builtin, inputs: [headset], currentInputUIDs: [headset.uid]))
    }

    func testMultipleMicrophonesKeepTheMatchingActiveInput() {
        let wired = Settings.MicrophonePort(uid: "wired", name: "Wired", kind: .headset)
        let bluetooth = Settings.MicrophonePort(uid: "bluetooth", name: "Bluetooth HFP", kind: .headset)
        XCTAssertEqual(Settings.preferredRecordingInput(microphone: .headset, inputs: [wired, bluetooth], currentInputUIDs: [bluetooth.uid]), bluetooth)
        XCTAssertEqual(Settings.preferredRecordingInput(microphone: .headset, inputs: [wired, bluetooth], currentInputUIDs: []), wired)
    }

    func testSystemMicrophoneOverrideNeverPinsAnInput() {
        let builtin = Settings.MicrophonePort(uid: "phone", name: "Phone", kind: .builtin)
        let headset = Settings.MicrophonePort(uid: "wired", name: "Headset", kind: .headset)
        for microphone in Settings.Microphone.allCases {
            XCTAssertNil(Settings.preferredRecordingInput(microphone: microphone, inputs: [builtin, headset], currentInputUIDs: [headset.uid], respectsSystemInput: true))
        }
    }
}
