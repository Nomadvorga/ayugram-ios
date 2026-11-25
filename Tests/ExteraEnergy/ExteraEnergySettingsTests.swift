import Foundation
import XCTest

let APP_GROUP_IDENTIFIER = "ExteraEnergyTests.\(UUID().uuidString)"

final class ExteraEnergySettingsTests: XCTestCase {
    private typealias Settings = ExteraEnergySettings

    override func setUp() {
        super.setUp()
        for feature in Settings.Feature.allCases { Settings.shared.setEnabled(feature, true) }
        Settings.shared.followSystem = false
    }

    override func tearDown() {
        AyuSettingsStore.shared.userDefaults.removePersistentDomain(forName: APP_GROUP_IDENTIFIER)
        super.tearDown()
    }

    func testReferenceGroupsAreDisjointAndHaveTwoThreeSevenChildren() {
        XCTAssertEqual(Settings.Group.stickers.features, [.stickerKeyboard, .stickerChat])
        XCTAssertEqual(Settings.Group.emoji.features, [.emojiKeyboard, .emojiReactions, .emojiChat])
        XCTAssertEqual(Settings.Group.chat.features, [.wallpaper, .topicSidebar, .spoilers, .blur, .liquidGlass, .scale, .deletion])
        let children = Settings.Group.allCases.flatMap { $0.features }
        XCTAssertEqual(Set(children).count, children.count)
        XCTAssertNil(Settings.Feature.calls.group)
        XCTAssertNil(Settings.Feature.particles.group)
    }

    func testMixedChatMasterForEverySubset() {
        let children = Settings.Group.chat.features
        for mask in 0 ..< (1 << children.count) {
            let selected = Set(children.enumerated().compactMap { (mask & (1 << $0.offset)) == 0 ? nil : $0.element })
            let state = Settings.GroupState(group: .chat, selectedFeatures: selected)
            XCTAssertEqual(state.selected, selected.count)
            XCTAssertEqual(state.total, 7)
            XCTAssertEqual(state.isOn, mask != 0)
        }
        Settings.shared.setEnabled(.scale, false)
        let mixed = Settings.GroupState(group: .chat, selectedFeatures: Settings.shared.selectedFeatures)
        XCTAssertEqual(mixed.selected, 6)
        XCTAssertTrue(mixed.isOn)
    }

    func testGroupWritePersistsChildrenWithoutChangingOtherSurfaces() {
        Settings.shared.setGroup(.emoji, false)
        let reopened = UserDefaults(suiteName: APP_GROUP_IDENTIFIER)!
        for feature in Settings.Group.emoji.features {
            XCTAssertFalse(Settings.shared.isEnabled(feature))
            XCTAssertEqual(reopened.persistentDomain(forName: APP_GROUP_IDENTIFIER)?[Settings.key(for: feature)] as? Bool, false)
        }
        for feature in Settings.Group.stickers.features + Settings.Group.chat.features {
            XCTAssertTrue(Settings.shared.isEnabled(feature))
        }
        Settings.shared.setEnabled(.emojiReactions, true)
        XCTAssertFalse(Settings.shared.isEnabled(.emojiKeyboard))
        XCTAssertFalse(Settings.shared.isEnabled(.emojiChat))
        XCTAssertTrue(Settings.shared.isEnabled(.emojiReactions))
    }

    func testGroupPublishesOneConsistentNotification() {
        var snapshots: [Set<Settings.Feature>] = []
        let observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { _ in
            snapshots.append(Settings.shared.selectedFeatures)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        Settings.shared.setGroup(.chat, false)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(Set(Settings.Group.chat.features).isDisjoint(with: snapshots[0]))
    }

    func testEveryBackupKeyIsUniqueAndBoolean() {
        XCTAssertEqual(Set(Settings.booleanKeys).count, Settings.Feature.allCases.count + 1)
        XCTAssertEqual(Settings.followSystemKey, "extera.energy.followSystem")
        for feature in Settings.Feature.allCases {
            Settings.shared.setEnabled(feature, false)
            XCTAssertEqual(AyuSettingsStore.shared.userDefaults.object(forKey: Settings.key(for: feature)) as? Bool, false)
        }
    }

    func testNativeSentinelsAndThresholdBoundary() {
        XCTAssertFalse(Settings.savingActive(threshold: 4, followSystem: false, batteryLevel: 0, systemLowPower: false))
        XCTAssertTrue(Settings.savingActive(threshold: 96, followSystem: false, batteryLevel: nil, systemLowPower: false))
        XCTAssertTrue(Settings.savingActive(threshold: 15, followSystem: false, batteryLevel: 0.15, systemLowPower: false))
        XCTAssertFalse(Settings.savingActive(threshold: 15, followSystem: false, batteryLevel: 0.151, systemLowPower: false))
        XCTAssertTrue(Settings.savingActive(threshold: 95, followSystem: false, batteryLevel: 0.95, systemLowPower: false))
    }

    func testFollowSystemTemporarilyReplacesBatteryTrigger() {
        XCTAssertFalse(Settings.savingActive(threshold: 96, followSystem: true, batteryLevel: 0.01, systemLowPower: false))
        XCTAssertTrue(Settings.savingActive(threshold: 4, followSystem: true, batteryLevel: 1, systemLowPower: true))
        XCTAssertTrue(Settings.savingActive(threshold: 96, followSystem: false, batteryLevel: 1, systemLowPower: false))
    }

    func testSystemLowPowerAlwaysWinsIncludingNever() {
        for follows in [false, true] {
            for threshold in [Int32(0), 4, 15, 96, 100] {
                XCTAssertTrue(Settings.savingActive(threshold: threshold, followSystem: follows, batteryLevel: nil, systemLowPower: true))
            }
        }
    }

    func testUnknownAndInvalidBatteryAreNotAnEmptyBattery() {
        let invalid: [Float?] = [nil, -1, -Float.infinity, Float.infinity, Float.nan, 1.01]
        for level in invalid {
            XCTAssertFalse(Settings.savingActive(threshold: 15, followSystem: false, batteryLevel: level, systemLowPower: false))
        }
    }

    func testNativeSavingAndAccessibilityCannotBeOverriddenBySelection() {
        for feature in Settings.Feature.allCases {
            XCTAssertFalse(Settings.allows(feature, selected: true, nativeEnabled: false, savingActive: false, reduceMotion: false, reduceTransparency: false))
            XCTAssertFalse(Settings.allows(feature, selected: true, nativeEnabled: true, savingActive: true, reduceMotion: false, reduceTransparency: false))
            XCTAssertFalse(Settings.allows(feature, selected: false, nativeEnabled: true, savingActive: false, reduceMotion: false, reduceTransparency: false))
            XCTAssertEqual(Settings.allows(feature, selected: true, nativeEnabled: true, savingActive: false, reduceMotion: true, reduceTransparency: false), !feature.involvesMotion)
            XCTAssertEqual(Settings.allows(feature, selected: true, nativeEnabled: true, savingActive: false, reduceMotion: false, reduceTransparency: true), feature != .blur && feature != .liquidGlass)
        }
    }

    func testPolicyDoesNotEraseSavedSelections() {
        Settings.shared.setEnabled(.scale, false)
        let before = Settings.shared.selectedFeatures
        for feature in Settings.Feature.allCases {
            _ = Settings.allows(feature, selected: Settings.shared.isEnabled(feature), nativeEnabled: true, savingActive: true, reduceMotion: true, reduceTransparency: true)
        }
        XCTAssertEqual(Settings.shared.selectedFeatures, before)
    }
}
