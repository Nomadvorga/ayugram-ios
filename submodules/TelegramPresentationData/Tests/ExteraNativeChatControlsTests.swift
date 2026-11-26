import Foundation
import TelegramPresentationData
import TelegramUIPreferences
import UIKit
import XCTest

final class ExteraNativeChatControlsTests: XCTestCase {
    func testFontSliderIncludesEveryNativeSizeInDisplayOrder() {
        let sizes = ExteraNativeChatControls.fontSizes
        XCTAssertEqual(Set(sizes), Set(PresentationFontSize.allCases))
        let values = sizes.map { $0.baseDisplaySize }
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(Set(values).count, sizes.count)
    }

    func testChangingChatFontPreservesSystemFontAndIndependentListSize() {
        var before = PresentationThemeSettings.defaultSettings
        before.listsFontSize = .extraLargeX2
        before.chatBubbleSettings.serifMessageFont = true
        let after = ExteraNativeChatControls.withFontSize(.small, settings: before)
        XCTAssertEqual(after.fontSize, .small)
        XCTAssertEqual(after.listsFontSize, before.listsFontSize)
        XCTAssertEqual(after.useSystemFont, before.useSystemFont)
        XCTAssertEqual(after.chatBubbleSettings, before.chatBubbleSettings)
        XCTAssertEqual(after.currentModeTheme, before.currentModeTheme)
    }

    func testSquareAndSeventeenPointCornersReachNativeRenderer() {
        for radius in ExteraNativeChatControls.bubbleRadiusRange {
            let settings = ExteraNativeChatControls.withBubbleRadius(radius, settings: .defaultSettings)
            let corners = PresentationChatBubbleCorners(settings: settings.chatBubbleSettings)
            XCTAssertEqual(corners.mainRadius, CGFloat(radius))
            XCTAssertEqual(corners.auxiliaryRadius, CGFloat(radius / 2))
        }
        let chat = makeDefaultPresentationTheme(reference: .dayClassic, serviceBackgroundColor: nil).chat
        let neighbors: [MessageBubbleImageNeighbors] = [.none, .top(side: false), .top(side: true), .bottom, .both, .side, .extracted]
        for incoming in [false, true] {
            for neighbors in neighbors {
                var endpointImages: [Data] = []
                for radius in [0, 17] {
                    let image = messageBubbleImage(maxCornerRadius: CGFloat(radius), minCornerRadius: CGFloat(radius / 2), incoming: incoming, fillColor: .red, strokeColor: .clear, neighbors: neighbors, theme: chat, wallpaper: .color(0xffffff), knockout: false)
                    XCTAssertGreaterThan(image.size.width, 0)
                    XCTAssertGreaterThan(image.size.height, 0)
                    if let data = image.pngData() { endpointImages.append(data) } else { XCTFail("Missing radius \(radius) raster") }
                }
                XCTAssertEqual(endpointImages.count, 2)
                if endpointImages.count == 2 { XCTAssertNotEqual(endpointImages[0], endpointImages[1]) }
            }
        }
    }

    func testRadiusClampsBeforeInt32Conversion() {
        XCTAssertEqual(ExteraNativeChatControls.withBubbleRadius(Int.min, settings: .defaultSettings).chatBubbleSettings.mainRadius, 0)
        XCTAssertEqual(ExteraNativeChatControls.withBubbleRadius(Int.max, settings: .defaultSettings).chatBubbleSettings.mainRadius, 17)
    }

    func testSquareCornerActionBackgroundsHaveNonEmptyImages() {
        let corners = PresentationChatBubbleCorners(settings: ExteraNativeChatControls.withBubbleRadius(0, settings: .defaultSettings).chatBubbleSettings)
        for position in [MessageBubbleActionButtonPosition.middle, .bottomLeft, .bottomRight, .bottomSingle] {
            for stroke in [UIColor.clear, UIColor.black] {
                let image = messageBubbleActionButtonImage(color: .red, strokeColor: stroke, position: position, bubbleCorners: corners)
                XCTAssertGreaterThan(image.size.width, 0)
                XCTAssertGreaterThan(image.size.height, 0)
                XCTAssertNotNil(image.pngData())
            }
        }
    }

    func testCornerMutationPreservesBubbleFreeThemeAndTypographyChoices() {
        var before = PresentationThemeSettings.defaultSettings
        before.chatBubbleSettings.bubbleMode = false
        before.chatBubbleSettings.bubblelessTheme = .builtin(.neutral)
        before.chatBubbleSettings.bubblelessAutomaticTheme = .builtin(.neutralNight)
        before.chatBubbleSettings.serifMessageFont = true
        before.chatBubbleSettings.mergeBubbleCorners = false
        before.currentModeAutomaticThemeSwitchSetting.trigger = .timeBased(setting: .manual(fromSeconds: 79200, toSeconds: 32400))
        let after = ExteraNativeChatControls.withBubbleRadius(0, settings: before)
        XCTAssertFalse(after.chatBubbleSettings.bubbleMode)
        XCTAssertFalse(after.chatBubbleSettings.mergeBubbleCorners)
        XCTAssertTrue(after.chatBubbleSettings.serifMessageFont)
        XCTAssertEqual(after.currentModeTheme, before.currentModeTheme)
        XCTAssertEqual(after.currentModeAutomaticThemeSwitchSetting, before.currentModeAutomaticThemeSwitchSetting)
        XCTAssertEqual(after.fontSize, before.fontSize)
        XCTAssertEqual(after.listsFontSize, before.listsFontSize)
    }
}
