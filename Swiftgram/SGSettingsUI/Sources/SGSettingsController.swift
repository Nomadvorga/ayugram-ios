// MARK: AyuGram
// The exteraGram tab: exteraGram's preferences first in every category, then the few Swiftgram features kept.
import SGSimpleSettings
import SGStrings

import SGItemListUI
import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI

private enum SGControllerSection: Int32, SGItemListSection {
    case search
    case categories
    case general
    case speedBoost
    case sending
    case appearance
    case tabs
    case folders
    case chatList
    case accountColors
    case chats
    case gestures
    case stickers
    case profiles
    case stories
}

private enum SGBoolSetting: String {
    case inAppVibration
    case disableNumberRounding
    case replaceEditedWithIcon
    case hideShareButton
    case disableGreetingSticker
    case filterZalgo
    case hidePhoneNumber
    case formatTimeWithSeconds
    case uploadSpeedBoost
    case sendLargePhotos
    case sendWithReturnKey
    case hideAccountInNotifications
    case hideStories
    case showNavigationBar
    case hideNavigationBarLabels
    case showContactsTab
    case showCallsTab
    case tabBarSearch
    case wideTabBar
    case hideAllChats
    case foldersAtBottom
    case compactFolderNames
    case rememberLastFolder
    case compactChatList
    case widePosts
    case bottomButton
    case quickTransitions
    case quickTransitionsTopics
    case hideSendAsPeer
    case hideCameraTile
    case cameraTilePreview
    case recordingButton
    case snapDeletionEffect
    case hideReactions
    case doubleTapOutgoingEdit
    case stickerTime
    case forceEmojiTab
    case defaultEmojisFirst
    case showIdAndDc
    case showRegDate
    case showCreationDate
    case confirmCalls
    case warnOnStoriesOpen
    case storyStealthMode
}

private enum SGOneFromManySetting: String {
    case downloadSpeedBoost
    case allChatsTitle
}

private enum SGSliderSetting: String {
    case accountColorsSaturation
}

private enum SGDisclosureLink: String {
    case categoryGeneral
    case categoryAppearance
    case categoryChats
    case categoryOther
}

public enum SGSettingsCategory {
    case general
    case appearance
    case chats
    case other

    fileprivate var sections: Set<SGControllerSection> {
        switch self {
        case .general:
            return [.general, .speedBoost, .sending]
        case .appearance:
            return [.appearance, .tabs, .folders, .chatList, .accountColors]
        case .chats:
            return [.chats, .gestures, .stickers]
        case .other:
            return [.profiles, .stories]
        }
    }

    fileprivate var titleKey: String {
        switch self {
        case .general:
            return "Ayu.CategoryGeneral"
        case .appearance:
            return "Ayu.CategoryAppearance"
        case .chats:
            return "Ayu.CategoryChats"
        case .other:
            return "Ayu.CategoryOther"
        }
    }
}

private struct SGSettingsControllerState: Equatable {
    var searchQuery: String?
}

private typealias SGControllerEntry = SGItemListUIEntry<SGControllerSection, SGBoolSetting, SGSliderSetting, SGOneFromManySetting, SGDisclosureLink, AnyHashable>

private func SGControllerEntries(presentationData: PresentationData, callListSettings: CallListSettings, experimentalUISettings: ExperimentalUISettings, nameColors: PeerNameColors, state: SGSettingsControllerState, category: SGSettingsCategory?) -> [SGControllerEntry] {
    let allEntries = SGControllerAllEntries(presentationData: presentationData, callListSettings: callListSettings, experimentalUISettings: experimentalUISettings, nameColors: nameColors, state: state)
    if let category {
        return allEntries.filter { entry in
            return category.sections.contains(where: { $0.rawValue == entry.section })
        }
    }
    if let searchQuery = state.searchQuery, !searchQuery.isEmpty {
        return allEntries
    }
    let lang = presentationData.strings.baseLanguageCode
    let id = SGItemListCounter()
    var entries: [SGControllerEntry] = allEntries.filter { $0.section == SGControllerSection.search.rawValue }
    id.increment(entries.count)
    entries.append(.header(id: id.count, section: .categories, text: i18n("Extera.Categories", lang).uppercased(), badge: nil))
    entries.append(.disclosure(id: id.count, section: .categories, link: .categoryGeneral, text: i18n("Ayu.CategoryGeneral", lang)))
    entries.append(.disclosure(id: id.count, section: .categories, link: .categoryAppearance, text: i18n("Ayu.CategoryAppearance", lang)))
    entries.append(.disclosure(id: id.count, section: .categories, link: .categoryChats, text: i18n("Ayu.CategoryChats", lang)))
    entries.append(.disclosure(id: id.count, section: .categories, link: .categoryOther, text: i18n("Ayu.CategoryOther", lang)))
    return entries
}

private func SGControllerAllEntries(presentationData: PresentationData, callListSettings: CallListSettings, experimentalUISettings: ExperimentalUISettings, nameColors: PeerNameColors, state: SGSettingsControllerState) -> [SGControllerEntry] {
    let lang = presentationData.strings.baseLanguageCode
    let strings = presentationData.strings
    let settings = SGSimpleSettings.shared
    var entries: [SGControllerEntry] = []
    let id = SGItemListCounter()

    entries.append(.searchInput(id: id.count, section: .search, title: NSAttributedString(string: "🔍"), text: state.searchQuery ?? "", placeholder: strings.Common_Search))

    // General: exteraGram first, then sending.
    entries.append(.oneFromManySelector(id: id.count, section: .speedBoost, settingName: .downloadSpeedBoost, text: i18n("Extera.DownloadSpeedBoost", lang), value: downloadSpeedBoostTitle(settings.downloadSpeedBoost, lang: lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .speedBoost, settingName: .uploadSpeedBoost, value: settings.uploadSpeedBoost, text: i18n("Extera.UploadSpeedBoost", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .speedBoost, text: i18n("Extera.SpeedBoostInfo", lang)))

    entries.append(.toggle(id: id.count, section: .general, settingName: .inAppVibration, value: ExteraSettings.shared.inAppVibration, text: i18n("Extera.InAppVibration", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .disableNumberRounding, value: ExteraSettings.shared.disableNumberRounding, text: i18n("Extera.DisableNumberRounding", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .formatTimeWithSeconds, value: settings.secondsInMessages, text: i18n("Extera.FormatTimeWithSeconds", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .hidePhoneNumber, value: settings.hidePhoneInSettings, text: i18n("Extera.HidePhoneNumber", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .hideAccountInNotifications, value: settings.hideAccountInNotifications, text: i18n("Settings.HideAccountInNotifications", lang), enabled: true))

    entries.append(.header(id: id.count, section: .sending, text: strings.NetworkUsageSettings_MediaImageDataSection.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .sending, settingName: .sendLargePhotos, value: settings.sendLargePhotos, text: i18n("Settings.Photo.SendLarge", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .sending, text: i18n("Settings.Photo.SendLarge.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .sending, settingName: .sendWithReturnKey, value: settings.sendWithReturnKey, text: i18n("Settings.SendWithReturnKey", lang), enabled: true))

    // Appearance: exteraGram first, then the navigation bar, folders, chat list and name colors.
    entries.append(.header(id: id.count, section: .appearance, text: i18n("Extera.Appearance", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .hideStories, value: settings.hideStories, text: i18n("Extera.HideStories", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .hideAllChats, value: settings.allChatsHidden, text: i18n("Extera.HideAllChats", lang, strings.ChatList_Tabs_AllChats), enabled: true))

    entries.append(.header(id: id.count, section: .tabs, text: i18n("Extera.BottomNavigationBarMode", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .showNavigationBar, value: !settings.hideTabBar, text: i18n("Extera.BottomNavigationBarMode", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .hideNavigationBarLabels, value: !settings.showTabNames, text: i18n("Extera.HideNavigationBarLabels", lang), enabled: !settings.hideTabBar))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .showContactsTab, value: callListSettings.showContactsTab, text: i18n("Extera.ShowContactsTab", lang), enabled: !settings.hideTabBar))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .showCallsTab, value: callListSettings.showTab, text: strings.CallSettings_TabIcon, enabled: !settings.hideTabBar))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .tabBarSearch, value: settings.tabBarSearchEnabled, text: i18n("Settings.Tabs.SearchButton", lang), enabled: !settings.hideTabBar))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .wideTabBar, value: settings.wideTabBar, text: i18n("Settings.Tabs.WideTabBar", lang), enabled: !settings.hideTabBar))
    entries.append(.notice(id: id.count, section: .tabs, text: i18n("Settings.Tabs.WideTabBar.Notice", lang)))

    entries.append(.header(id: id.count, section: .folders, text: strings.Settings_ChatFolders.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .folders, settingName: .foldersAtBottom, value: experimentalUISettings.foldersTabAtBottom, text: i18n("Settings.Folders.BottomTab", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .folders, settingName: .compactFolderNames, value: settings.compactFolderNames, text: i18n("Settings.Folders.CompactNames", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .folders, settingName: .allChatsTitle, text: i18n("Settings.Folders.AllChatsTitle", lang), value: i18n("Settings.Folders.AllChatsTitle.\(settings.allChatsTitleLengthOverride)", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .folders, settingName: .rememberLastFolder, value: settings.rememberLastFolder, text: i18n("Settings.Folders.RememberLast", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .folders, text: i18n("Settings.Folders.RememberLast.Notice", lang)))

    entries.append(.header(id: id.count, section: .chatList, text: i18n("Extera.ListOfChats", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .compactChatList, value: settings.compactChatList, text: i18n("Settings.CompactChatList", lang), enabled: true))

    entries.append(.header(id: id.count, section: .accountColors, text: i18n("Settings.CustomColors.Header", lang), badge: nil))
    entries.append(.header(id: id.count, section: .accountColors, text: i18n("Settings.CustomColors.Saturation", lang), badge: nil))
    let accountColorsSaturation = settings.accountColorsSaturation
    entries.append(.percentageSlider(id: id.count, section: .accountColors, settingName: .accountColorsSaturation, value: accountColorsSaturation))
    let previewName = "\(strings.UserInfo_FirstNamePlaceholder) \(strings.UserInfo_LastNamePlaceholder)"
    if accountColorsSaturation == 0 {
        entries.append(.peerColorDisclosurePreview(id: id.count, section: .accountColors, name: previewName, color: presentationData.theme.chat.message.incoming.accentTextColor))
    } else {
        for index in nameColors.displayOrder.prefix(3) {
            let colors = nameColors.get(PeerNameColor(rawValue: index), dark: presentationData.theme.overallDarkAppearance)
            entries.append(.peerColorDisclosurePreview(id: id.count, section: .accountColors, name: previewName, color: colors.main))
        }
    }
    entries.append(.notice(id: id.count, section: .accountColors, text: i18n("Settings.CustomColors.Saturation.Notice", lang)))

    // Chats: exteraGram first, then gestures and stickers.
    entries.append(.header(id: id.count, section: .chats, text: i18n("Ayu.CategoryChats", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .replaceEditedWithIcon, value: ExteraSettings.shared.replaceEditedWithIcon, text: i18n("Extera.ReplaceEditedWithIcon", lang, strings.Conversation_MessageEditedLabel), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .hideShareButton, value: ExteraSettings.shared.hideShareButton, text: i18n("Extera.HideShareButton", lang, strings.Conversation_ContextMenuShare), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .disableGreetingSticker, value: ExteraSettings.shared.disableGreetingSticker, text: i18n("Extera.DisableGreetingSticker", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .filterZalgo, value: ExteraSettings.shared.filterZalgo, text: i18n("Extera.FilterZalgo", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .chats, text: i18n("Extera.FilterZalgoInfo", lang, "Zalgo")))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .widePosts, value: settings.wideChannelPosts, text: i18n("Extera.WidePosts", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .bottomButton, value: !settings.hideChannelBottomButton, text: i18n("Extera.BottomButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .quickTransitions, value: !settings.disableScrollToNextChannel, text: i18n("Extera.QuickTransitions", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .quickTransitionsTopics, value: !settings.disableScrollToNextTopic, text: i18n("Settings.PullToNextTopic", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .hideCameraTile, value: settings.disableGalleryCamera, text: i18n("Extera.HideCameraTile", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .cameraTilePreview, value: !settings.disableGalleryCameraPreview, text: i18n("Settings.GalleryCameraPreview", lang), enabled: !settings.disableGalleryCamera))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .recordingButton, value: !settings.hideRecordingButton, text: i18n("Settings.RecordingButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .snapDeletionEffect, value: !settings.disableSnapDeletionEffect, text: i18n("Settings.SnapDeletionEffect", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .hideReactions, value: settings.hideReactions, text: i18n("Settings.HideReactions", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .hideSendAsPeer, value: settings.disableSendAsButton, text: i18n("Extera.HideSendAsPeer", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .chats, text: i18n("Extera.HideSendAsPeerInfo", lang)))

    entries.append(.header(id: id.count, section: .gestures, text: i18n("Extera.Gestures", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .gestures, settingName: .doubleTapOutgoingEdit, value: settings.messageDoubleTapActionOutgoing == SGSimpleSettings.MessageDoubleTapAction.edit.rawValue, text: i18n("Extera.DoubleTapOutgoingEdit", lang), enabled: true))

    entries.append(.header(id: id.count, section: .stickers, text: strings.StickerPacksSettings_Title.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .stickers, settingName: .stickerTime, value: settings.stickerTimestamp, text: i18n("Extera.StickerTimeMode", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .stickers, settingName: .forceEmojiTab, value: settings.forceEmojiTab, text: i18n("Settings.ForceEmojiTab", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .stickers, settingName: .defaultEmojisFirst, value: settings.defaultEmojisFirst, text: i18n("Settings.DefaultEmojisFirst", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .stickers, text: i18n("Settings.DefaultEmojisFirst.Notice", lang)))

    // Other: profiles and stories.
    entries.append(.header(id: id.count, section: .profiles, text: i18n("Settings.Profiles.Header", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showIdAndDc, value: settings.showProfileId, text: i18n("Extera.ShowIdAndDc", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Extera.ShowIdAndDcInfo", lang)))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showRegDate, value: settings.showRegDate, text: i18n("Settings.ShowRegDate", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Extera.RegDateInfo", lang)))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showCreationDate, value: settings.showCreationDate, text: i18n("Settings.ShowCreationDate", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Settings.ShowCreationDate.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .confirmCalls, value: settings.confirmCalls, text: i18n("Settings.CallConfirmation", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Settings.CallConfirmation.Notice", lang)))

    entries.append(.header(id: id.count, section: .stories, text: strings.AutoDownloadSettings_Stories.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .stories, settingName: .warnOnStoriesOpen, value: settings.warnOnStoriesOpen, text: i18n("Settings.Stories.WarnBeforeView", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .stories, settingName: .storyStealthMode, value: settings.storyStealthMode, text: strings.Story_StealthMode_Title, enabled: true))
    entries.append(.notice(id: id.count, section: .stories, text: strings.Story_StealthMode_ControlText))

    return filterSGItemListUIEntrires(entries: entries, by: state.searchQuery)
}

private func downloadSpeedBoostTitle(_ value: String, lang: String) -> String {
    switch value {
    case SGSimpleSettings.DownloadSpeedBoostValues.maximum.rawValue:
        return i18n("Extera.Ultra", lang)
    case SGSimpleSettings.DownloadSpeedBoostValues.medium.rawValue:
        return i18n("Extera.SpeedBoostMedium", lang)
    default:
        return i18n("Extera.SpeedBoostOff", lang)
    }
}

public func sgSettingsController(context: AccountContext, category: SGSettingsCategory? = nil) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    var presentOneFromManyImpl: ((SGOneFromManySetting, [SGOneFromManyOption]) -> Void)?
    var askForRestart: (() -> Void)?

    let initialState = SGSettingsControllerState()
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((SGSettingsControllerState) -> SGSettingsControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let simplePromise = ValuePromise(true, ignoreRepeated: false)

    let arguments = SGItemListArguments<SGBoolSetting, SGSliderSetting, SGOneFromManySetting, SGDisclosureLink, AnyHashable>(
        context: context,
        setBoolValue: { setting, value in
        let settings = SGSimpleSettings.shared
        switch setting {
        case .inAppVibration:
            ExteraSettings.shared.set(.inAppVibration, value)
        case .disableNumberRounding:
            ExteraSettings.shared.set(.disableNumberRounding, value)
        case .replaceEditedWithIcon:
            ExteraSettings.shared.set(.replaceEditedWithIcon, value)
        case .hideShareButton:
            ExteraSettings.shared.set(.hideShareButton, value)
        case .disableGreetingSticker:
            ExteraSettings.shared.set(.disableGreetingSticker, value)
        case .filterZalgo:
            ExteraSettings.shared.set(.filterZalgo, value)
        case .hidePhoneNumber:
            settings.hidePhoneInSettings = value
            askForRestart?()
        case .formatTimeWithSeconds:
            settings.secondsInMessages = value
        case .uploadSpeedBoost:
            settings.uploadSpeedBoost = value
        case .sendLargePhotos:
            settings.sendLargePhotos = value
        case .sendWithReturnKey:
            settings.sendWithReturnKey = value
        case .hideAccountInNotifications:
            settings.hideAccountInNotifications = value
            settings.synchronizeShared()
        case .hideStories:
            settings.hideStories = value
        case .showNavigationBar:
            settings.hideTabBar = !value
            simplePromise.set(true)
            askForRestart?()
        case .hideNavigationBarLabels:
            settings.showTabNames = !value
            askForRestart?()
        case .showContactsTab:
            let _ = updateCallListSettingsInteractively(accountManager: context.sharedContext.accountManager, { $0.withUpdatedShowContactsTab(value) }).start()
        case .showCallsTab:
            let _ = updateCallListSettingsInteractively(accountManager: context.sharedContext.accountManager, { $0.withUpdatedShowTab(value) }).start()
        case .tabBarSearch:
            settings.tabBarSearchEnabled = value
        case .wideTabBar:
            settings.wideTabBar = value
            askForRestart?()
        case .hideAllChats:
            settings.allChatsHidden = value
            askForRestart?()
        case .foldersAtBottom:
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
                var current = current
                current.foldersTabAtBottom = value
                return current
            }).start()
        case .compactFolderNames:
            settings.compactFolderNames = value
            askForRestart?()
        case .rememberLastFolder:
            settings.rememberLastFolder = value
        case .compactChatList:
            settings.compactChatList = value
            askForRestart?()
        case .widePosts:
            settings.wideChannelPosts = value
        case .bottomButton:
            settings.hideChannelBottomButton = !value
        case .quickTransitions:
            settings.disableScrollToNextChannel = !value
        case .quickTransitionsTopics:
            settings.disableScrollToNextTopic = !value
        case .hideSendAsPeer:
            settings.disableSendAsButton = value
        case .hideCameraTile:
            settings.disableGalleryCamera = value
            simplePromise.set(true)
        case .cameraTilePreview:
            settings.disableGalleryCameraPreview = !value
        case .recordingButton:
            settings.hideRecordingButton = !value
        case .snapDeletionEffect:
            settings.disableSnapDeletionEffect = !value
        case .hideReactions:
            settings.hideReactions = value
        case .doubleTapOutgoingEdit:
            settings.messageDoubleTapActionOutgoing = value ? SGSimpleSettings.MessageDoubleTapAction.edit.rawValue : SGSimpleSettings.MessageDoubleTapAction.default.rawValue
        case .stickerTime:
            settings.stickerTimestamp = value
        case .forceEmojiTab:
            settings.forceEmojiTab = value
        case .defaultEmojisFirst:
            settings.defaultEmojisFirst = value
        case .showIdAndDc:
            settings.showProfileId = value
            settings.showDC = value
        case .showRegDate:
            settings.showRegDate = value
        case .showCreationDate:
            settings.showCreationDate = value
        case .confirmCalls:
            settings.confirmCalls = value
        case .warnOnStoriesOpen:
            settings.warnOnStoriesOpen = value
        case .storyStealthMode:
            settings.storyStealthMode = value
        }
    }, updateSliderValue: { setting, value in
        switch setting {
        case .accountColorsSaturation:
            if SGSimpleSettings.shared.accountColorsSaturation != value {
                SGSimpleSettings.shared.accountColorsSaturation = value
                simplePromise.set(true)
            }
        }
    }, setOneFromManyValue: { setting in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        var options: [SGOneFromManyOption] = []
        switch setting {
        case .downloadSpeedBoost:
            for value in SGSimpleSettings.DownloadSpeedBoostValues.allCases {
                options.append(SGOneFromManyOption(title: downloadSpeedBoostTitle(value.rawValue, lang: lang), isSelected: SGSimpleSettings.shared.downloadSpeedBoost == value.rawValue, action: {
                    SGSimpleSettings.shared.downloadSpeedBoost = value.rawValue
                    simplePromise.set(true)
                    let _ = updateNetworkSettingsInteractively(postbox: context.account.postbox, network: context.account.network, { settings in
                        var settings = settings
                        settings.useExperimentalDownload = value != SGSimpleSettings.DownloadSpeedBoostValues.none
                        return settings
                    }).start(completed: {
                        Queue.mainQueue().async {
                            askForRestart?()
                        }
                    })
                }))
            }
        case .allChatsTitle:
            for value in SGSimpleSettings.AllChatsTitleLengthOverride.allCases {
                let title: String
                switch value {
                case .short:
                    title = "\"\(presentationData.strings.ChatList_Tabs_All)\""
                case .long:
                    title = "\"\(presentationData.strings.ChatList_Tabs_AllChats)\""
                default:
                    title = i18n("Settings.Folders.AllChatsTitle.none", lang)
                }
                options.append(SGOneFromManyOption(title: title, isSelected: SGSimpleSettings.shared.allChatsTitleLengthOverride == value.rawValue, action: {
                    SGSimpleSettings.shared.allChatsTitleLengthOverride = value.rawValue
                    simplePromise.set(true)
                }))
            }
        }
        presentOneFromManyImpl?(setting, options)
    }, openDisclosureLink: { link in
        switch link {
        case .categoryGeneral:
            pushControllerImpl?(sgSettingsController(context: context, category: .general))
        case .categoryAppearance:
            pushControllerImpl?(sgSettingsController(context: context, category: .appearance))
        case .categoryChats:
            pushControllerImpl?(sgSettingsController(context: context, category: .chats))
        case .categoryOther:
            pushControllerImpl?(sgSettingsController(context: context, category: .other))
        }
    }, searchInput: { searchQuery in
        updateState { state in
            var updatedState = state
            updatedState.searchQuery = searchQuery
            return updatedState
        }
    })

    let sharedData = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings, ApplicationSpecificSharedDataKeys.experimentalUISettings])
    let signal = combineLatest(
        simplePromise.get(),
        statePromise.get(),
        context.sharedContext.presentationData,
        sharedData,
        context.engine.accountData.observeAvailableColorOptions(scope: .replies),
        context.engine.accountData.observeAvailableColorOptions(scope: .profile)
    )
    |> map { _, state, presentationData, sharedData, availableReplyColors, availableProfileColors -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let callListSettings: CallListSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.callListSettings]?.get(CallListSettings.self) ?? CallListSettings.defaultSettings
        let experimentalUISettings: ExperimentalUISettings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
        let nameColors = PeerNameColors.with(availableReplyColors: availableReplyColors, availableProfileColors: availableProfileColors)
        let entries = SGControllerEntries(presentationData: presentationData, callListSettings: callListSettings, experimentalUISettings: experimentalUISettings, nameColors: nameColors, state: state, category: category)
        let title = category.flatMap { i18n($0.titleKey, presentationData.strings.baseLanguageCode) } ?? "exteraGram"
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentOneFromManyImpl = { [weak controller] setting, options in
        guard let controller else {
            return
        }
        sgPresentOneFromManySelector(controller: controller, setting: setting, presentationData: context.sharedContext.currentPresentationData.with { $0 }, options: options)
    }
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    askForRestart = { [weak context] in
        guard let context else {
            return
        }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        presentControllerImpl?(
            UndoOverlayController(
                presentationData: presentationData,
                content: .info(title: nil,
                    text: i18n("Common.RestartRequired", presentationData.strings.baseLanguageCode),
                    timeout: nil,
                    customUndoText: i18n("Common.RestartNow", presentationData.strings.baseLanguageCode)
                ),
                elevatedLayout: false,
                action: { action in if action == .undo { exit(0) }; return true }
            ),
            nil
        )
    }
    return controller
}
