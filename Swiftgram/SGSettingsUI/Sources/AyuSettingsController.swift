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
    case confirmations
}

private enum AyuBoolSetting: String {
    case ghostMode
    case hideReadMessages
    case hideReadStories
    case hideOnline
    case hideTyping
    case automaticOffline
    case onlinePulseOnSend
    case markReadAfterAction
    case useScheduledMessages
    case suggestGhostModeBeforeViewingStory
    case displayGhostStatus
    case saveDeletedMessages
    case saveMessagesHistory
    case saveForBots
    case saveReadDate
    case saveLocalOnline
    case showDeletedMarker
    case semiTransparentDeletedMessages
    case disableAds
    case disableOpenLinkWarning
    case hideNotificationBadge
    case hideFolderCounters
    case copyUsernameAsLink
    case hidePremiumStatuses
    case hideGroupReactions
    case hideChannelReactions
    case simpleQuotesAndReplies
    case disableCustomBackgrounds
    case disableSimilarChannels
    case confirmSticker
    case confirmGif
    case confirmVoice
    case confirmRound
}

private enum AyuOneFromManySetting: String {
    case sendWithoutSound
    case deletedMark
    case deletedMarkColor
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
    case .trashBin:
        title = i18n("Ayu.DeletedMarkTrashBin", lang)
    case .text:
        title = i18n("Ayu.DeletedMarkTextStyle", lang)
    case .cross:
        title = i18n("Ayu.DeletedMarkCross", lang)
    case .compact:
        title = i18n("Ayu.DeletedMarkCompact", lang)
    case .eyeCrossed:
        title = i18n("Ayu.DeletedMarkEyeCrossed", lang)
    }
    return "\(value.text(lang: lang)) · \(title)"
}

private func deletedMarkColorTitle(_ value: AyuCustomizationSettings.DeletedMarkColor, lang: String) -> String {
    switch value {
    case .red:
        return i18n("Ayu.DeletedMarkColorRed", lang)
    case .orange:
        return i18n("Ayu.DeletedMarkColorOrange", lang)
    case .gray:
        return i18n("Ayu.DeletedMarkColorGray", lang)
    case .purple:
        return i18n("Ayu.DeletedMarkColorPurple", lang)
    case .theme:
        return i18n("Ayu.DeletedMarkColorTheme", lang)
    }
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
    entries.append(.toggle(id: id.count, section: .ghostEssentials, settingName: .hideReadMessages, value: ghost.value(.hideReadMessages), text: i18n("Ayu.DontReadMessages", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .ghostEssentials, settingName: .hideReadStories, value: ghost.value(.hideReadStories), text: i18n("Ayu.DontReadStories", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .ghostEssentials, settingName: .hideOnline, value: ghost.value(.hideOnline), text: i18n("Ayu.DontSendOnlinePackets", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .ghostEssentials, settingName: .hideTyping, value: ghost.value(.hideTyping), text: i18n("Ayu.DontSendUploadProgress", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .ghostEssentials, settingName: .automaticOffline, value: ghost.value(.automaticOffline), text: i18n("Ayu.SendOfflinePacketAfterOnline", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .ghostEssentials, settingName: .onlinePulseOnSend, value: ghost.value(.onlinePulseOnSend), text: i18n("Ayu.OnlinePulseOnSend", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .ghostEssentials, text: i18n("Ayu.GhostModeDescription", lang)))

    entries.append(.toggle(id: id.count, section: .ghostOther, settingName: .markReadAfterAction, value: ghost.markReadAfterAction, text: i18n("Ayu.MarkReadAfterAction", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .ghostOther, text: i18n("Ayu.MarkReadAfterActionDescription", lang)))
    entries.append(.toggle(id: id.count, section: .ghostOther, settingName: .useScheduledMessages, value: ghost.useScheduledMessages, text: i18n("Ayu.UseScheduledMessages", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .ghostOther, text: i18n("Ayu.UseScheduledMessagesDescription", lang)))
    entries.append(.oneFromManySelector(id: id.count, section: .ghostOther, settingName: .sendWithoutSound, text: i18n("Ayu.SendWithoutSoundByDefault", lang), value: sendWithoutSoundTitle(ghost.sendWithoutSound, lang: lang), enabled: true))
    entries.append(.notice(id: id.count, section: .ghostOther, text: i18n("Ayu.SendWithoutSoundByDefaultDescription", lang)))
    entries.append(.toggle(id: id.count, section: .ghostOther, settingName: .suggestGhostModeBeforeViewingStory, value: ghost.suggestGhostModeBeforeViewingStory, text: i18n("Ayu.SuggestGhostModeBeforeViewingStory", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .ghostOther, text: i18n("Ayu.SuggestGhostModeBeforeViewingStoryDescription", lang)))
    entries.append(.toggle(id: id.count, section: .ghostOther, settingName: .displayGhostStatus, value: ghost.displayGhostStatus, text: i18n("Ayu.DisplayGhostStatus", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .ghostOther, text: i18n("Ayu.DisplayGhostStatusDescription", lang)))

    entries.append(.header(id: id.count, section: .spyEssentials, text: i18n("Ayu.SpyEssentialsHeader", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .spyEssentials, settingName: .saveDeletedMessages, value: save.saveDeletedMessages, text: i18n("Ayu.SaveDeletedMessages", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .spyEssentials, settingName: .saveMessagesHistory, value: save.saveMessagesHistory, text: i18n("Ayu.SaveMessagesHistory", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .spyEssentials, settingName: .saveForBots, value: save.saveForBots, text: i18n("Ayu.MessageSavingSaveForBots", lang), enabled: save.saveDeletedMessages || save.saveMessagesHistory))
    entries.append(.toggle(id: id.count, section: .spyEssentials, settingName: .saveReadDate, value: save.saveReadDate, text: i18n("Ayu.SpySaveReadMarks", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .spyEssentials, text: i18n("Ayu.SpySaveReadMarksDescription", lang)))
    entries.append(.toggle(id: id.count, section: .spyEssentials, settingName: .saveLocalOnline, value: save.saveLocalOnline, text: i18n("Ayu.SpySaveLocalOnline", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .spyEssentials, text: i18n("Ayu.SpySaveLocalOnlineDescription", lang)))

    entries.append(.header(id: id.count, section: .customization, text: i18n("Ayu.CustomizationHeader", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .customization, settingName: .showDeletedMarker, value: customization.showDeletedMarker, text: i18n("Ayu.ShowDeletedMarker", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .customization, settingName: .deletedMark, text: i18n("Ayu.DeletedMarkText", lang), value: deletedMarkTitle(customization.deletedMark, lang: lang), enabled: customization.showDeletedMarker))
    entries.append(.oneFromManySelector(id: id.count, section: .customization, settingName: .deletedMarkColor, text: i18n("Ayu.DeletedMarkColorText", lang), value: deletedMarkColorTitle(customization.deletedMarkColor, lang: lang), enabled: customization.showDeletedMarker))
    entries.append(.toggle(id: id.count, section: .customization, settingName: .semiTransparentDeletedMessages, value: customization.semiTransparentDeletedMessages, text: i18n("Ayu.SemiTransparentDeletedMessages", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .customization, settingName: .disableCustomBackgrounds, value: customization.disableCustomBackgrounds, text: i18n("Ayu.DisableCustomBackgrounds", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .customization, settingName: .simpleQuotesAndReplies, value: customization.simpleQuotesAndReplies, text: i18n("Ayu.SimpleQuotesAndReplies", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .customization, settingName: .hideChannelReactions, value: customization.hideChannelReactions, text: i18n("Ayu.HideChannelReactions", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .customization, settingName: .hideGroupReactions, value: customization.hideGroupReactions, text: i18n("Ayu.HideGroupReactions", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .customization, settingName: .hidePremiumStatuses, value: customization.hidePremiumStatuses, text: i18n("Ayu.HidePremiumStatuses", lang), enabled: true))

    entries.append(.header(id: id.count, section: .usefulFeatures, text: i18n("Ayu.QoLTogglesHeader", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .usefulFeatures, settingName: .disableAds, value: customization.disableAds, text: i18n("Ayu.DisableAds", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .usefulFeatures, settingName: .disableOpenLinkWarning, value: customization.disableOpenLinkWarning, text: i18n("Ayu.DisableOpenLinkWarning", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .usefulFeatures, settingName: .copyUsernameAsLink, value: customization.copyUsernameAsLink, text: i18n("Ayu.CopyUsernameAsLink", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .usefulFeatures, settingName: .disableSimilarChannels, value: customization.disableSimilarChannels, text: i18n("Ayu.DisableSimilarChannels", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .usefulFeatures, settingName: .hideFolderCounters, value: customization.hideFolderCounters, text: i18n("Ayu.HideNotificationCounters", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .usefulFeatures, settingName: .hideNotificationBadge, value: customization.hideNotificationBadge, text: i18n("Ayu.HideNotificationBadge", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .usefulFeatures, text: i18n("Ayu.HideNotificationBadgeDescription", lang)))

    let confirmations = AyuSendConfirmations.shared
    entries.append(.header(id: id.count, section: .confirmations, text: i18n("Ayu.ConfirmationsTitle", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .confirmations, settingName: .confirmSticker, value: confirmations.isEnabled(.sticker), text: i18n("Ayu.StickerConfirmation", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .confirmations, settingName: .confirmGif, value: confirmations.isEnabled(.gif), text: i18n("Ayu.GIFConfirmation", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .confirmations, settingName: .confirmVoice, value: confirmations.isEnabled(.voice), text: i18n("Ayu.VoiceConfirmation", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .confirmations, settingName: .confirmRound, value: confirmations.isEnabled(.round), text: i18n("Ayu.RoundConfirmation", lang), enabled: true))

    return entries
}

public func ayuSettingsController(context: AccountContext) -> ViewController {
    var presentOneFromManyImpl: ((AyuOneFromManySetting, [SGOneFromManyOption]) -> Void)?
    let updatePromise = ValuePromise(true, ignoreRepeated: false)

    let arguments = SGItemListArguments<AyuBoolSetting, AyuSliderSetting, AyuOneFromManySetting, AyuDisclosureLink, AnyHashable>(
        context: context,
        setBoolValue: { setting, value in
            let ghost = AyuGhostSettings.shared
            let wasHidingOnline = ghost.suppressOnlineStatus
            switch setting {
            case .ghostMode:
                ghost.setGhostModeActive(value)
            case .hideReadMessages:
                ghost.set(.hideReadMessages, value)
            case .hideReadStories:
                ghost.set(.hideReadStories, value)
            case .hideOnline:
                ghost.set(.hideOnline, value)
            case .hideTyping:
                ghost.set(.hideTyping, value)
            case .automaticOffline:
                ghost.set(.automaticOffline, value)
            case .onlinePulseOnSend:
                ghost.set(.onlinePulseOnSend, value)
            case .markReadAfterAction:
                ghost.markReadAfterAction = value
            case .useScheduledMessages:
                ghost.useScheduledMessages = value
            case .suggestGhostModeBeforeViewingStory:
                ghost.suggestGhostModeBeforeViewingStory = value
            case .displayGhostStatus:
                ghost.displayGhostStatus = value
            case .saveDeletedMessages:
                AyuSaveSettings.shared.saveDeletedMessages = value
            case .saveMessagesHistory:
                AyuSaveSettings.shared.saveMessagesHistory = value
            case .saveForBots:
                AyuSaveSettings.shared.saveForBots = value
            case .saveReadDate:
                AyuSaveSettings.shared.saveReadDate = value
            case .saveLocalOnline:
                AyuSaveSettings.shared.saveLocalOnline = value
            case .showDeletedMarker:
                AyuCustomizationSettings.shared.showDeletedMarker = value
            case .semiTransparentDeletedMessages:
                AyuCustomizationSettings.shared.semiTransparentDeletedMessages = value
            case .disableAds:
                AyuCustomizationSettings.shared.disableAds = value
            case .disableOpenLinkWarning:
                AyuCustomizationSettings.shared.disableOpenLinkWarning = value
            case .hideNotificationBadge:
                AyuCustomizationSettings.shared.hideNotificationBadge = value
            case .hideFolderCounters:
                AyuCustomizationSettings.shared.hideFolderCounters = value
            case .copyUsernameAsLink:
                AyuCustomizationSettings.shared.copyUsernameAsLink = value
            case .hidePremiumStatuses:
                AyuCustomizationSettings.shared.hidePremiumStatuses = value
            case .hideGroupReactions:
                AyuCustomizationSettings.shared.hideGroupReactions = value
            case .hideChannelReactions:
                AyuCustomizationSettings.shared.hideChannelReactions = value
            case .simpleQuotesAndReplies:
                AyuCustomizationSettings.shared.simpleQuotesAndReplies = value
            case .disableCustomBackgrounds:
                AyuCustomizationSettings.shared.disableCustomBackgrounds = value
            case .disableSimilarChannels:
                AyuCustomizationSettings.shared.disableSimilarChannels = value
            case .confirmSticker:
                AyuSendConfirmations.shared.setEnabled(.sticker, value)
            case .confirmGif:
                AyuSendConfirmations.shared.setEnabled(.gif, value)
            case .confirmVoice:
                AyuSendConfirmations.shared.setEnabled(.voice, value)
            case .confirmRound:
                AyuSendConfirmations.shared.setEnabled(.round, value)
            }
            if !wasHidingOnline && ghost.suppressOnlineStatus {
                AyuGhostLastSeen.shared.recordNow()
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
            case .deletedMarkColor:
                for value in AyuCustomizationSettings.DeletedMarkColor.allCases {
                    options.append(SGOneFromManyOption(title: deletedMarkColorTitle(value, lang: lang), isSelected: AyuCustomizationSettings.shared.deletedMarkColor == value, action: {
                        AyuCustomizationSettings.shared.deletedMarkColor = value
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
