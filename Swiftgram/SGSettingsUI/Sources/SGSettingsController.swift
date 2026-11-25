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
import SettingsUI
import PromptUI
import TranslateUI

private enum SGControllerSection: Int32, SGItemListSection {
    case search
    case categories
    case translation
    case general
    case speedBoost
    case storage
    case profileGeneral
    case archive
    case sending
    case avatarCorners
    case appearance
    case tabs
    case folders
    case chatList
    case accountColors
    case other
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
    case showTranslateButton
    case showTranslateChatButton
    case disableNotificationDelay
    case relativeLastSeen
    case hideArchiveFolder
    case archiveOnPull
    case disableUnarchiveSwipe
    case uploadSpeedBoost
    case sendLargePhotos
    case sendWithReturnKey
    case hideAccountInNotifications
    case forceSnow
    case centerTitle
    case singleCornerRadius
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
    case wideChannelPosts
    case hideRecordingButton
    case disableSnapDeletionEffect
    case disableSendAsButton
    case disableGalleryCamera
    case disableGalleryCameraPreview
    case disableScrollToNextChannel
    case disableScrollToNextTopic
    case hidePhoneInSettings
    case stickerTime
    case forceEmojiTab
    case defaultEmojisFirst
    case showIdAndDc
    case showRegDate
    case showCreationDate
    case confirmCalls
    case warnOnStoriesOpen
    case storyStealthMode
    case swipeForVideoPIP
    case enableVoipTcp
    case nyStyleSnow
    case nyStyleLightning
    case tabBarSearchEnabled
    case videoControlsInFooter
    case lyricsInPlayer
    case hideSponsoredMessages
    case filterZalgoText
    case commaAfterMention
    case combinedMediaViewer
    // MARK: AyuGram
    case ayuGhostMode
    case ayuDontReadMessages
    case ayuDontReadStories
    case ayuDontSendOnline
    case ayuDontSendTyping
    case ayuOfflineAfterSending
    case ayuSaveDeletedMessages
    case ayuSaveMessagesHistory
}

private enum SGOneFromManySetting: String {
    case chatListTitle
    case downloadSpeedBoost
    case allChatsTitle
    case translationProvider
    case translationTargetLanguage
    case doNotTranslateLanguages
    case showIdAndDc
    case customSavePath
}

private enum SGSliderSetting: String {
    case avatarCorners
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
            return [.translation, .general, .speedBoost, .storage, .profileGeneral, .archive]
        case .appearance:
            return [.avatarCorners, .appearance, .tabs, .folders, .chatList, .accountColors]
        case .chats:
            return [.chats, .gestures, .stickers, .sending]
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

private func chatListTitleOption(_ value: ExteraSettings.ChatListTitle, lang: String) -> String {
    switch value {
    case .ayuGram: return "AyuGram"
    case .fullName: return i18n("Extera.ActionBarTitleFullName", lang)
    case .firstName: return i18n("Extera.ActionBarTitleName", lang)
    case .chats: return i18n("Extera.ActionBarTitleChats", lang)
    }
}

private struct SGSettingsControllerState: Equatable {
    var searchQuery: String?
}

private typealias SGControllerEntry = SGItemListUIEntry<SGControllerSection, SGBoolSetting, SGSliderSetting, SGOneFromManySetting, SGDisclosureLink, AnyHashable>

private func SGControllerEntries(presentationData: PresentationData, callListSettings: CallListSettings, experimentalUISettings: ExperimentalUISettings, translationSettings: TranslationSettings, nameColors: PeerNameColors, state: SGSettingsControllerState, previewTitle: String, category: SGSettingsCategory?) -> [SGControllerEntry] {
    let allEntries = SGControllerAllEntries(presentationData: presentationData, callListSettings: callListSettings, experimentalUISettings: experimentalUISettings, translationSettings: translationSettings, nameColors: nameColors, state: state, previewTitle: previewTitle)
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

private func SGControllerAllEntries(presentationData: PresentationData, callListSettings: CallListSettings, experimentalUISettings: ExperimentalUISettings, translationSettings: TranslationSettings, nameColors: PeerNameColors, state: SGSettingsControllerState, previewTitle: String) -> [SGControllerEntry] {
    let lang = presentationData.strings.baseLanguageCode
    let strings = presentationData.strings
    let settings = SGSimpleSettings.shared
    var entries: [SGControllerEntry] = []
    let id = SGItemListCounter()

    entries.append(.searchInput(id: id.count, section: .search, title: NSAttributedString(string: "🔍"), text: state.searchQuery ?? "", placeholder: strings.Common_Search))

    // Translate Messages: exteraGram's block, backed by Telegram's TranslationSettings.
    entries.append(.header(id: id.count, section: .translation, text: i18n("Extera.TranslateMessages", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .translation, settingName: .showTranslateButton, value: translationSettings.showTranslate, text: i18n("Extera.ShowTranslateButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .translation, settingName: .showTranslateChatButton, value: translationSettings.translateChats, text: i18n("Extera.ShowTranslateChatButton", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .translation, settingName: .translationProvider, text: i18n("Extera.TranslationProvider", lang), value: translationProviderTitle(settings.translationBackendEnum, lang: lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .translation, settingName: .translationTargetLanguage, text: i18n("Extera.TranslationTarget", lang), value: translationTargetTitle(strings: strings, lang: lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .translation, settingName: .doNotTranslateLanguages, text: i18n("Extera.DoNotTranslate", lang), value: doNotTranslateTitle(settings: translationSettings, strings: strings, lang: lang), enabled: true))
    entries.append(.notice(id: id.count, section: .translation, text: i18n("Extera.TranslateMessagesInfo1", lang)))

    // General.
    entries.append(.header(id: id.count, section: .general, text: i18n("Extera.General", lang).uppercased(), badge: nil))
    entries.append(.toggleSubtitle(id: id.count, section: .general, settingName: .disableNumberRounding, value: ExteraSettings.shared.disableNumberRounding, text: i18n("Extera.DisableNumberRounding", lang), subtitle: "1.23K → 1,234", enabled: true))
    entries.append(.toggleSubtitle(id: id.count, section: .general, settingName: .formatTimeWithSeconds, value: settings.secondsInMessages, text: i18n("Extera.FormatTimeWithSeconds", lang), subtitle: "12:34 → 12:34:56", enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .inAppVibration, value: ExteraSettings.shared.inAppVibration, text: i18n("Extera.InAppVibration", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .disableNotificationDelay, value: ExteraSettings.shared.disableNotificationDelay, text: i18n("Extera.DisableNotificationDelay", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .filterZalgo, value: ExteraSettings.shared.filterZalgo, text: i18n("Extera.FilterZalgo", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .general, text: i18n("Extera.FilterZalgoInfo", lang, ExteraSettings.shared.filteredText("Z̷͍͌ā̸̜l̸̞̂g̷͍̝o̶̩̓", force: true))))

    // Download speed boost.
    entries.append(.header(id: id.count, section: .speedBoost, text: i18n("Extera.DownloadSpeedBoost", lang).uppercased(), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .speedBoost, settingName: .downloadSpeedBoost, text: i18n("Extera.DownloadSpeedBoost", lang), value: downloadSpeedBoostTitle(settings.downloadSpeedBoost, lang: lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .speedBoost, settingName: .uploadSpeedBoost, value: settings.uploadSpeedBoost, text: i18n("Extera.UploadSpeedBoost", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .speedBoost, text: i18n("Extera.SpeedBoostInfo", lang)))

    // Storage: on iOS saved media lands in a named album instead of a directory.
    entries.append(.header(id: id.count, section: .storage, text: i18n("Extera.StorageSettings", lang).uppercased(), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .storage, settingName: .customSavePath, text: i18n("Extera.CustomSavePath", lang), value: ExteraSettings.shared.saveFolderName, enabled: true))
    entries.append(.notice(id: id.count, section: .storage, text: i18n("Extera.CustomSavePathInfo", lang, ExteraSettings.shared.saveFolderName)))

    // Profile.
    entries.append(.header(id: id.count, section: .profileGeneral, text: i18n("Extera.Profile", lang).uppercased(), badge: nil))
    entries.append(.toggleSubtitle(id: id.count, section: .profileGeneral, settingName: .relativeLastSeen, value: ExteraSettings.shared.relativeLastSeen, text: i18n("Extera.RelativeLastSeen", lang), subtitle: i18n("Extera.RelativeLastSeenInfo", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .profileGeneral, settingName: .hidePhoneNumber, value: settings.hidePhoneInSettings, text: i18n("Extera.HidePhoneNumber", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .profileGeneral, settingName: .showIdAndDc, text: i18n("Extera.ShowIdAndDc", lang), value: showIdAndDcTitle(ExteraSettings.shared.showIdAndDc, lang: lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profileGeneral, text: i18n("Extera.ShowIdAndDcInfo", lang)))

    // Archived chats.
    entries.append(.header(id: id.count, section: .archive, text: i18n("Extera.ArchivedChats", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .archive, settingName: .hideArchiveFolder, value: ExteraSettings.shared.hideArchiveFolder, text: i18n("Extera.HideArchiveFolder", lang), enabled: true))
    if !ExteraSettings.shared.hideArchiveFolder {
        entries.append(.toggle(id: id.count, section: .archive, settingName: .archiveOnPull, value: ExteraSettings.shared.archiveOnPull, text: i18n("Extera.ArchiveOnPull", lang), enabled: true))
    }
    entries.append(.toggle(id: id.count, section: .archive, settingName: .disableUnarchiveSwipe, value: ExteraSettings.shared.disableUnarchiveSwipe, text: i18n("Extera.DisableUnarchiveSwipe", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .archive, text: i18n("Extera.DisableUnarchiveSwipeInfo", lang)))

    entries.append(.header(id: id.count, section: .sending, text: strings.NetworkUsageSettings_MediaImageDataSection.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .sending, settingName: .sendLargePhotos, value: settings.sendLargePhotos, text: i18n("Settings.Photo.SendLarge", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .sending, text: i18n("Settings.Photo.SendLarge.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .sending, settingName: .sendWithReturnKey, value: settings.sendWithReturnKey, text: i18n("Settings.SendWithReturnKey", lang), enabled: true))

    // Appearance: exteraGram's avatar shape comes before the Chat List section.
    entries.append(.appearancePreview(id: id.count, section: .avatarCorners, kind: .avatar(value: Int32(ExteraSettings.shared.avatarCorners), title: i18n("Extera.AvatarCorners", lang), square: i18n("Extera.AvatarSquare", lang), circle: i18n("Extera.AvatarCircle", lang)), settingName: .avatarCorners))
    entries.append(.toggle(id: id.count, section: .avatarCorners, settingName: .singleCornerRadius, value: ExteraSettings.shared.singleCornerRadius, text: i18n("Extera.SingleCornerRadius", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .avatarCorners, text: i18n("Extera.SingleCornerRadiusInfo", lang)))

    // Appearance: Chat List settings follow the avatar preview, as in AyuGram.
    entries.append(.header(id: id.count, section: .chatList, text: i18n("Extera.ListOfChats", lang).uppercased(), badge: nil))
    entries.append(.appearancePreview(id: id.count, section: .chatList, kind: .chatList(title: previewTitle, centered: ExteraSettings.shared.centerTitle, snow: ExteraSettings.shared.forceSnow), settingName: nil))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .forceSnow, value: ExteraSettings.shared.forceSnow, text: i18n("Extera.ForceSnow", lang, "Force Snow"), enabled: true))
    entries.append(.notice(id: id.count, section: .chatList, text: i18n("Extera.ForceSnowInfo", lang)))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .centerTitle, value: ExteraSettings.shared.centerTitle, text: i18n("Extera.CenterTitle", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .hideStories, value: settings.hideStories, text: i18n("Extera.HideStories", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .hideAllChats, value: settings.allChatsHidden, text: i18n("Extera.HideAllChats", lang, strings.ChatList_Tabs_AllChats), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .compactChatList, value: settings.compactChatList, text: i18n("Settings.CompactChatList", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .chatList, settingName: .chatListTitle, text: i18n("Extera.ActionBarTitle", lang), value: chatListTitleOption(ExteraSettings.shared.chatListTitle, lang: lang), enabled: true))

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

    entries.append(.header(id: id.count, section: .other, text: strings.Appearance_Other.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .other, settingName: .lyricsInPlayer, value: SGSimpleSettings.shared.lyricsInPlayer, text: i18n("Settings.LyricsInPlayer", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .hideSponsoredMessages, value: SGSimpleSettings.shared.hideSponsoredMessages, text: i18n("Settings.HideSponsoredMessages", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .commaAfterMention, value: SGSimpleSettings.shared.commaAfterMention, text: i18n("Settings.CommaAfterMention", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .swipeForVideoPIP, value: SGSimpleSettings.shared.videoPIPSwipeDirection == SGSimpleSettings.VideoPIPSwipeDirection.up.rawValue, text: i18n("Settings.swipeForVideoPIP", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .other, text: i18n("Settings.swipeForVideoPIP.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .other, settingName: .bottomButton, value: !SGSimpleSettings.shared.hideChannelBottomButton, text: i18n("Settings.showChannelBottomButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .wideChannelPosts, value: SGSimpleSettings.shared.wideChannelPosts, text: i18n("Settings.wideChannelPosts", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .doubleTapOutgoingEdit, value: SGSimpleSettings.shared.messageDoubleTapActionOutgoing == SGSimpleSettings.MessageDoubleTapAction.edit.rawValue, text: i18n("Settings.messageDoubleTapActionOutgoingEdit", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .recordingButton, value: !SGSimpleSettings.shared.hideRecordingButton, text: i18n("Settings.RecordingButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .snapDeletionEffect, value: !SGSimpleSettings.shared.disableSnapDeletionEffect, text: i18n("Settings.SnapDeletionEffect", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .hideSendAsPeer, value: !SGSimpleSettings.shared.disableSendAsButton, text: i18n("Settings.SendAsButton", lang, strings.Conversation_SendMesageAs), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .hideCameraTile, value: !SGSimpleSettings.shared.disableGalleryCamera, text: i18n("Settings.GalleryCamera", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .cameraTilePreview, value: !SGSimpleSettings.shared.disableGalleryCameraPreview, text: i18n("Settings.GalleryCameraPreview", lang), enabled: !SGSimpleSettings.shared.disableGalleryCamera))
    entries.append(.toggle(id: id.count, section: .other, settingName: .quickTransitions, value: !SGSimpleSettings.shared.disableScrollToNextChannel, text: i18n("Settings.PullToNextChannel", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .quickTransitionsTopics, value: !SGSimpleSettings.shared.disableScrollToNextTopic, text: i18n("Settings.PullToNextTopic", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .hideReactions, value: SGSimpleSettings.shared.hideReactions, text: i18n("Settings.HideReactions", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .sendWithReturnKey, value: SGSimpleSettings.shared.sendWithReturnKey, text: i18n("Settings.SendWithReturnKey", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .forceEmojiTab, value: SGSimpleSettings.shared.forceEmojiTab, text: i18n("Settings.ForceEmojiTab", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .other, settingName: .defaultEmojisFirst, value: SGSimpleSettings.shared.defaultEmojisFirst, text: i18n("Settings.DefaultEmojisFirst", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .other, text: i18n("Settings.DefaultEmojisFirst.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .other, settingName: .hideAccountInNotifications, value: SGSimpleSettings.shared.hideAccountInNotifications, text: i18n("Settings.HideAccountInNotifications", lang), enabled: true))
    entries.append(.header(id: id.count, section: .profiles, text: i18n("Settings.Profiles.Header", lang), badge: nil))
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

private func translationProviderTitle(_ backend: SGSimpleSettings.TranslationBackend, lang: String) -> String {
    switch backend {
    case .default:
        return i18n("Extera.TranslationProviderTelegram", lang)
    case .gtranslate:
        return "Google"
    case .microsoft:
        return "Microsoft"
    case .yandex:
        return "Yandex"
    case .system:
        return i18n("Extera.TranslationProviderApple", lang)
    }
}

private func sgLanguageName(_ code: String, lang: String) -> String {
    var normalized = code
    let rawSuffix = "-raw"
    if normalized.hasSuffix(rawSuffix) {
        normalized = String(normalized.dropLast(rawSuffix.count))
    }
    var localeCode = lang
    if localeCode.hasSuffix(rawSuffix) {
        localeCode = String(localeCode.dropLast(rawSuffix.count))
    }
    if let name = Locale(identifier: localeCode).localizedString(forLanguageCode: normalized) {
        return name.capitalized
    }
    if let name = Locale(identifier: "en").localizedString(forLanguageCode: normalized) {
        return name.capitalized
    }
    return code
}

private func translationTargetTitle(strings: PresentationStrings, lang: String) -> String {
    let code = ExteraSettings.shared.effectiveTranslationTargetLanguage(strings.baseLanguageCode)
    return sgLanguageName(code, lang: lang)
}

private func doNotTranslateTitle(settings: TranslationSettings, strings: PresentationStrings, lang: String) -> String {
    var codes = settings.ignoredLanguages
    if codes == nil {
        var defaults: [String] = [strings.baseLanguageCode]
        for code in systemLanguageCodes() where !defaults.contains(code) {
            defaults.append(code)
        }
        codes = defaults
    }
    var seen = Set<String>()
    var names: [String] = []
    for code in codes ?? [] {
        let normalized = normalizeTranslationLanguage(code)
        if seen.contains(normalized) {
            continue
        }
        seen.insert(normalized)
        names.append(sgLanguageName(code, lang: lang))
    }
    if names.isEmpty {
        return i18n("Extera.DoNotTranslateNone", lang)
    }
    if names.count > 2 {
        return names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
    }
    return names.joined(separator: ", ")
}

private func showIdAndDcTitle(_ value: ExteraSettings.ShowIdAndDc, lang: String) -> String {
    switch value {
    case .hide:
        return i18n("Extera.ShowIdAndDcHide", lang)
    case .telegram:
        return "Telegram API"
    case .bot:
        return "Bot API"
    }
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
        case .forceSnow:
            ExteraSettings.shared.set(.forceSnow, value)
            simplePromise.set(true)
        case .centerTitle:
            ExteraSettings.shared.set(.centerTitle, value)
            simplePromise.set(true)
        case .singleCornerRadius:
            ExteraSettings.shared.set(.singleCornerRadius, value)
            simplePromise.set(true)
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
        case .hidePhoneInSettings:
            settings.hidePhoneInSettings = value
            askForRestart?()
        case .formatTimeWithSeconds:
            settings.secondsInMessages = value
        case .showTranslateButton:
            let _ = updateTranslationSettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
                var updated = current.withUpdatedShowTranslate(value)
                if !updated.showTranslate && !updated.translateChats {
                    updated = updated.withUpdatedIgnoredLanguages(nil)
                }
                return updated
            }).start()
        case .showTranslateChatButton:
            let _ = updateTranslationSettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
                var updated = current.withUpdatedTranslateChats(value)
                if !updated.showTranslate && !updated.translateChats {
                    updated = updated.withUpdatedIgnoredLanguages(nil)
                }
                return updated
            }).start()
        case .disableNotificationDelay:
            ExteraSettings.shared.set(.disableNotificationDelay, value)
        case .relativeLastSeen:
            ExteraSettings.shared.set(.relativeLastSeen, value)
            simplePromise.set(true)
        case .hideArchiveFolder:
            ExteraSettings.shared.set(.hideArchiveFolder, value)
            simplePromise.set(true)
        case .archiveOnPull:
            ExteraSettings.shared.set(.archiveOnPull, value)
        case .disableUnarchiveSwipe:
            ExteraSettings.shared.set(.disableUnarchiveSwipe, value)
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
        case .disableScrollToNextChannel:
            settings.disableScrollToNextChannel = value
        case .quickTransitionsTopics:
            settings.disableScrollToNextTopic = !value
        case .disableScrollToNextTopic:
            settings.disableScrollToNextTopic = value
        case .hideSendAsPeer:
            settings.disableSendAsButton = value
        case .disableSendAsButton:
            settings.disableSendAsButton = value
        case .hideCameraTile:
            settings.disableGalleryCamera = value
            simplePromise.set(true)
        case .disableGalleryCamera:
            settings.disableGalleryCamera = value
            simplePromise.set(true)
        case .cameraTilePreview:
            settings.disableGalleryCameraPreview = !value
        case .disableGalleryCameraPreview:
            settings.disableGalleryCameraPreview = value
        case .recordingButton:
            settings.hideRecordingButton = !value
        case .hideRecordingButton:
            settings.hideRecordingButton = value
        case .snapDeletionEffect:
            settings.disableSnapDeletionEffect = !value
        case .disableSnapDeletionEffect:
            settings.disableSnapDeletionEffect = value
        case .wideChannelPosts:
            settings.wideChannelPosts = value
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
        case .combinedMediaViewer:
            SGSimpleSettings.shared.combinedMediaViewer = value
        case .swipeForVideoPIP:
            SGSimpleSettings.shared.videoPIPSwipeDirection = value ? SGSimpleSettings.VideoPIPSwipeDirection.up.rawValue : SGSimpleSettings.VideoPIPSwipeDirection.down.rawValue
        case .enableVoipTcp:
            let _ = updateExperimentalUISettingsInteractively(accountManager: context.sharedContext.accountManager, { current in
                var current = current
                current.enableVoipTcp = value
                return current
            }).start()
        case .nyStyleSnow:
            ExteraSettings.shared.set(.forceSnow, value)
            simplePromise.set(true)
        case .nyStyleLightning:
            ExteraSettings.shared.set(.forceSnow, value)
            simplePromise.set(true)
        case .tabBarSearchEnabled:
            settings.tabBarSearchEnabled = value
        case .videoControlsInFooter:
            SGSimpleSettings.shared.videoControlsInFooter = value
        case .lyricsInPlayer:
            SGSimpleSettings.shared.lyricsInPlayer = value
        case .hideSponsoredMessages:
            SGSimpleSettings.shared.hideSponsoredMessages = value
        case .filterZalgoText:
            SGSimpleSettings.shared.filterZalgoText = value
        case .commaAfterMention:
            SGSimpleSettings.shared.commaAfterMention = value
        case .ayuGhostMode:
            AyuGhostSettings.shared.setGhostModeActive(value)
        case .ayuDontReadMessages:
            AyuGhostSettings.shared.set(.hideReadMessages, value)
        case .ayuDontReadStories:
            AyuGhostSettings.shared.set(.hideReadStories, value)
        case .ayuDontSendOnline:
            AyuGhostSettings.shared.set(.hideOnline, value)
        case .ayuDontSendTyping:
            AyuGhostSettings.shared.set(.hideTyping, value)
        case .ayuOfflineAfterSending:
            AyuGhostSettings.shared.set(.automaticOffline, value)
        case .ayuSaveDeletedMessages:
            AyuSaveSettings.shared.saveDeletedMessages = value
        case .ayuSaveMessagesHistory:
            AyuSaveSettings.shared.saveMessagesHistory = value
        }
    }, updateSliderValue: { setting, value in
        switch setting {
        case .avatarCorners:
            if ExteraSettings.shared.avatarCorners != Int(value) {
                ExteraSettings.shared.avatarCorners = Int(value)
                simplePromise.set(true)
            }
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
        case .translationProvider:
            for value in SGSimpleSettings.TranslationBackend.allCases {
                options.append(SGOneFromManyOption(title: translationProviderTitle(value, lang: lang), isSelected: SGSimpleSettings.shared.translationBackendEnum == value, action: {
                    SGSimpleSettings.shared.translationBackend = value.rawValue
                    simplePromise.set(true)
                }))
            }
        case .translationTargetLanguage:
            pushControllerImpl?(sgTranslationTargetController(context: context))
            return
        case .doNotTranslateLanguages:
            pushControllerImpl?(translationSettingsController(context: context))
            return
        case .showIdAndDc:
            for value in ExteraSettings.ShowIdAndDc.allCases {
                options.append(SGOneFromManyOption(title: showIdAndDcTitle(value, lang: lang), isSelected: ExteraSettings.shared.showIdAndDc == value, action: {
                    ExteraSettings.shared.showIdAndDc = value
                    simplePromise.set(true)
                }))
            }
        case .customSavePath:
            let controller = promptController(context: context, text: i18n("Extera.CustomSavePath", lang), value: ExteraSettings.shared.customSavePath, placeholder: ExteraSettings.defaultSaveFolderName, apply: { value in
                let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._ -"))
                let filtered = String(raw.unicodeScalars.filter { allowed.contains($0) })
                if filtered.isEmpty || filtered == "." || filtered == ".." {
                    ExteraSettings.shared.customSavePath = ""
                } else {
                    ExteraSettings.shared.customSavePath = String(filtered.prefix(255))
                }
                simplePromise.set(true)
            })
            presentControllerImpl?(controller, nil)
            return
        case .chatListTitle:
            for value in ExteraSettings.ChatListTitle.allCases {
                options.append(SGOneFromManyOption(title: chatListTitleOption(value, lang: lang), isSelected: ExteraSettings.shared.chatListTitle == value, action: {
                    ExteraSettings.shared.chatListTitle = value
                    simplePromise.set(true)
                }))
            }
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

    let sharedData = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings, ApplicationSpecificSharedDataKeys.experimentalUISettings, ApplicationSpecificSharedDataKeys.translationSettings])
    let signal = combineLatest(
        simplePromise.get(),
        statePromise.get(),
        context.sharedContext.presentationData,
        sharedData,
        context.engine.accountData.observeAvailableColorOptions(scope: .replies),
        context.engine.accountData.observeAvailableColorOptions(scope: .profile),
        context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
    )
    |> map { _, state, presentationData, sharedData, availableReplyColors, availableProfileColors, accountPeer -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let callListSettings: CallListSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.callListSettings]?.get(CallListSettings.self) ?? CallListSettings.defaultSettings
        let experimentalUISettings: ExperimentalUISettings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings]?.get(ExperimentalUISettings.self) ?? ExperimentalUISettings.defaultSettings
        let translationSettings: TranslationSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.translationSettings]?.get(TranslationSettings.self) ?? TranslationSettings.defaultSettings
        let nameColors = PeerNameColors.with(availableReplyColors: availableReplyColors, availableProfileColors: availableProfileColors)
        let firstName: String
        let lastName: String
        if let accountPeer, case let .user(user) = accountPeer {
            firstName = user.firstName ?? ""
            lastName = user.lastName ?? ""
        } else {
            firstName = ""
            lastName = ""
        }
        let previewTitle = ExteraSettings.shared.chatListTitleText(firstName: firstName, lastName: lastName, chatsTitle: presentationData.strings.DialogList_Title)
        let entries = SGControllerEntries(presentationData: presentationData, callListSettings: callListSettings, experimentalUISettings: experimentalUISettings, translationSettings: translationSettings, nameColors: nameColors, state: state, previewTitle: previewTitle, category: category)
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
