// MARK: AyuGram
import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import SGSimpleSettings
import SGStrings
import SGItemListUI

// Same sections and order as "AyuGram Preferences" on Android.
private enum AyuControllerSection: Int32, SGItemListSection {
    case ghostEssentials
    case ghostOther
    case spyEssentials
    case customization
    case usefulFeatures
}

private enum AyuBoolSetting: String {
    case ghostMode
    case dontReadMessages
    case dontReadStories
    case dontSendOnline
    case dontSendTyping
    case offlineAutomatically
    case markReadAfterAction
    case useScheduledMessages
    case saveDeletedMessages
    case saveMessagesHistory
    case saveForBots
    case semiTransparentDeletedMessages
    case disableStories
    case showPeerId
    case showMessageSeconds
}

private enum AyuOneFromManySetting: String {
    case sendWithoutSound
    case deletedMark
}

private enum AyuSliderSetting: String {
    case none
}

private enum AyuDisclosureLink: String {
    case none
}

private typealias AyuControllerEntry = SGItemListUIEntry<AyuControllerSection, AyuBoolSetting, AyuSliderSetting, AyuOneFromManySetting, AyuDisclosureLink, AnyHashable>

private func sendWithoutSoundTitle(_ value: AyuGhostSettings.SendWithoutSound, lang: String) -> String {
    switch value {
    case .never:
        return i18n("Ayu.SendWithoutSoundByDefaultNever", lang)
    case .inGhostMode:
        return i18n("Ayu.SendWithoutSoundByDefaultInGhostMode", lang)
    case .always:
        return i18n("Ayu.SendWithoutSoundByDefaultAlways", lang)
    }
}

private func deletedMarkTitle(_ value: AyuCustomizationSettings.DeletedMark, lang: String) -> String {
    let title: String
    switch value {
    case .nothing:
        title = i18n("Ayu.DeletedMarkNothing", lang)
    case .trashBin:
        title = i18n("Ayu.DeletedMarkTrashBin", lang)
    case .cross:
        title = i18n("Ayu.DeletedMarkCross", lang)
    case .eyeCrossed:
        title = i18n("Ayu.DeletedMarkEyeCrossed", lang)
    }
    if let text = value.text {
        return "\(text) \(title)"
    }
    return title
}

private func ayuControllerEntries(presentationData: PresentationData) -> [AyuControllerEntry] {
    let lang = presentationData.strings.baseLanguageCode
    let ghost = AyuGhostSettings.shared
    let save = AyuSaveSettings.shared
    let customization = AyuCustomizationSettings.shared
    let id = SGItemListCounter()
    var entries: [AyuControllerEntry] = []

    entries.append(.header(id: id.count, section: .ghostEssentials, text: i18n("Ayu.GhostEssentialsHeader", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .ghostEssentials, settingName: .ghostMode, value: ghost.isGhostModeActive, text: i18n("Ayu.GhostModeToggle", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .ghostEssentials, settingName: .dontReadMessages, value: !ghost.sendReadMessagePackets, text: i18n("Ayu.DontReadMessages", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .ghostEssentials, settingName: .dontReadStories, value: !ghost.sendReadStoryPackets, text: i18n("Ayu.DontReadStories", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .ghostEssentials, settingName: .dontSendOnline, value: !ghost.sendOnlinePackets, text: i18n("Ayu.DontSendOnlinePackets", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .ghostEssentials, settingName: .dontSendTyping, value: !ghost.sendUploadProgress, text: i18n("Ayu.DontSendUploadProgress", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .ghostEssentials, settingName: .offlineAutomatically, value: ghost.sendOfflinePacketAfterOnline, text: i18n("Ayu.SendOfflinePacketAfterOnline", lang), enabled: true))

    entries.append(.toggle(id: id.count, section: .ghostOther, settingName: .markReadAfterAction, value: ghost.markReadAfterAction, text: i18n("Ayu.MarkReadAfterAction", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .ghostOther, text: i18n("Ayu.MarkReadAfterActionDescription", lang)))
    entries.append(.toggle(id: id.count, section: .ghostOther, settingName: .useScheduledMessages, value: ghost.useScheduledMessages, text: i18n("Ayu.UseScheduledMessages", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .ghostOther, text: i18n("Ayu.UseScheduledMessagesDescription", lang)))
    entries.append(.oneFromManySelector(id: id.count, section: .ghostOther, settingName: .sendWithoutSound, text: i18n("Ayu.SendWithoutSoundByDefault", lang), value: sendWithoutSoundTitle(ghost.sendWithoutSound, lang: lang), enabled: true))
    entries.append(.notice(id: id.count, section: .ghostOther, text: i18n("Ayu.SendWithoutSoundByDefaultDescription", lang)))

    entries.append(.header(id: id.count, section: .spyEssentials, text: i18n("Ayu.SpyEssentialsHeader", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .spyEssentials, settingName: .saveDeletedMessages, value: save.saveDeletedMessages, text: i18n("Ayu.SaveDeletedMessages", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .spyEssentials, settingName: .saveMessagesHistory, value: save.saveMessagesHistory, text: i18n("Ayu.SaveMessagesHistory", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .spyEssentials, settingName: .saveForBots, value: save.saveForBots, text: i18n("Ayu.MessageSavingSaveForBots", lang), enabled: save.saveDeletedMessages || save.saveMessagesHistory))

    entries.append(.header(id: id.count, section: .customization, text: i18n("Ayu.CustomizationHeader", lang), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .customization, settingName: .deletedMark, text: i18n("Ayu.DeletedMarkText", lang), value: deletedMarkTitle(customization.deletedMark, lang: lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .customization, settingName: .semiTransparentDeletedMessages, value: customization.semiTransparentDeletedMessages, text: i18n("Ayu.SemiTransparentDeletedMessages", lang), enabled: true))

    entries.append(.header(id: id.count, section: .usefulFeatures, text: i18n("Ayu.QoLTogglesHeader", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .usefulFeatures, settingName: .disableStories, value: SGSimpleSettings.shared.hideStories, text: i18n("Ayu.DisableStories", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .usefulFeatures, settingName: .showPeerId, value: SGSimpleSettings.shared.showProfileId, text: i18n("Ayu.SettingsShowID", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .usefulFeatures, settingName: .showMessageSeconds, value: SGSimpleSettings.shared.secondsInMessages, text: i18n("Ayu.SettingsShowMessageSeconds", lang), enabled: true))

    return entries
}

public func ayuSettingsController(context: AccountContext) -> ViewController {
    var presentOneFromManyImpl: ((AyuOneFromManySetting, [SGOneFromManyOption]) -> Void)?
    let updatePromise = ValuePromise(true, ignoreRepeated: false)

    let arguments = SGItemListArguments<AyuBoolSetting, AyuSliderSetting, AyuOneFromManySetting, AyuDisclosureLink, AnyHashable>(
        context: context,
        setBoolValue: { setting, value in
            let ghost = AyuGhostSettings.shared
            switch setting {
            case .ghostMode:
                ghost.setGhostModeActive(value)
            case .dontReadMessages:
                ghost.sendReadMessagePackets = !value
            case .dontReadStories:
                ghost.sendReadStoryPackets = !value
            case .dontSendOnline:
                ghost.sendOnlinePackets = !value
            case .dontSendTyping:
                ghost.sendUploadProgress = !value
            case .offlineAutomatically:
                ghost.sendOfflinePacketAfterOnline = value
            case .markReadAfterAction:
                ghost.markReadAfterAction = value
            case .useScheduledMessages:
                ghost.useScheduledMessages = value
            case .saveDeletedMessages:
                AyuSaveSettings.shared.saveDeletedMessages = value
            case .saveMessagesHistory:
                AyuSaveSettings.shared.saveMessagesHistory = value
            case .saveForBots:
                AyuSaveSettings.shared.saveForBots = value
            case .semiTransparentDeletedMessages:
                AyuCustomizationSettings.shared.semiTransparentDeletedMessages = value
            case .disableStories:
                SGSimpleSettings.shared.hideStories = value
            case .showPeerId:
                SGSimpleSettings.shared.showProfileId = value
            case .showMessageSeconds:
                SGSimpleSettings.shared.secondsInMessages = value
            }
            updatePromise.set(true)
        },
        setOneFromManyValue: { setting in
            let lang = context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode
            var options: [SGOneFromManyOption] = []
            switch setting {
            case .sendWithoutSound:
                for value in AyuGhostSettings.SendWithoutSound.allCases {
                    options.append(SGOneFromManyOption(title: sendWithoutSoundTitle(value, lang: lang), isSelected: AyuGhostSettings.shared.sendWithoutSound == value, action: {
                        AyuGhostSettings.shared.sendWithoutSound = value
                        updatePromise.set(true)
                    }))
                }
            case .deletedMark:
                for value in AyuCustomizationSettings.DeletedMark.allCases {
                    options.append(SGOneFromManyOption(title: deletedMarkTitle(value, lang: lang), isSelected: AyuCustomizationSettings.shared.deletedMark == value, action: {
                        AyuCustomizationSettings.shared.deletedMark = value
                        updatePromise.set(true)
                    }))
                }
            }
            presentOneFromManyImpl?(setting, options)
        }
    )

    let signal = combineLatest(updatePromise.get(), context.sharedContext.presentationData)
    |> map { _, presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(i18n("Ayu.AyuPreferences", presentationData.strings.baseLanguageCode)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: ayuControllerEntries(presentationData: presentationData), style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentOneFromManyImpl = { [weak controller] setting, options in
        guard let controller else {
            return
        }
        sgPresentOneFromManySelector(controller: controller, setting: setting, presentationData: context.sharedContext.currentPresentationData.with { $0 }, options: options)
    }
    return controller
}
