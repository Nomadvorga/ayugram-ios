// MARK: AyuGram
// The exteraGram tab: exteraGram's preferences first in every category, then the few Swiftgram features kept.
import SGSimpleSettings
import AyuInlineResults
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
import TranslateUI
import AyuAdBlock

private enum SGControllerSection: Int32, SGItemListSection {
    case search
    case categories
    case backup
    case general
    case translation
    case browser
    case speedBoost
    case sending
    case appearance
    case tabs
    case folders
    case chatList
    case accountColors
    case chats
    case aiFeatures
    case messageMenu
    case messageMenuStock
    case inlineResults
    case inlineResultsSettings
    case gestures
    case stickers
    case profiles
    case stories
}

private enum SGBoolSetting: String {
    case inlineResults
    case inlineMathResult
    case inlineCurrencyRates
    case inlineUnitConversion
    case inlineTimeZones
    case inlineDigitGrouping
    case inAppVibration
    case showExteraBadges
    case showSaveMessageButton
    case showSearchImageButton
    case showProxyCountry
    case showShareAsImageButton
    case enableAdBlock
    case telegramAiSummaries
    case telegramAiEditor
    case disableNumberRounding
    case replaceEditedWithIcon
    case hideShareButton
    case disableGreetingSticker
    case filterZalgo
    case removeMessageTail
    case addCommaAfterMention
    case showForwardsCount
    case hideReactionsInPrivateChats
    case showResultsBeforeVoting
    case disableMarkdown
    case relativeLastSeen
    case hideActionBarStatus
    case hideDialogsSearchBar
    case hideKeyboardOnScroll
    case disableUnarchiveSwipe
    case showOnlineStatus
    case archiveOnPull
    case pauseOnMinimizeVoice
    case pauseOnMinimizeRound
    case pauseOnMinimizeVideo
    case senderMiniAvatars
    case replyColors
    case replyEmoji
    case replyBackground
    case preferOriginalQuality
    case showClearButton
    case showHistoryButton
    case showDetailsButton
    case singleCornerRadius
    case tabCounterUnmutedOnly
    case showRepeatButton
    case contextShowReply
    case contextShowPin
    case contextShowSaveMedia
    case contextShowMessageReplies
    case contextShowReport
    case contextShowRestrict
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
    case doubleTapSeekDuration
    case defaultProfileTab
    case stickerShape
    case titleText
    case avatarCorners
    case doubleTapAction
    case doubleTapActionOutgoing
    case videoMessagesCamera
    case swipeAction
    case inlineAngleUnit
    case inlineTargetCurrency
    case inlineMeasureSystem
    case translationProvider
    case translationTarget
}

private enum SGSliderSetting: String {
    case accountColorsSaturation
}

private enum SGSettingsAction: String {
    case exportSettings
    case importSettings
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
            return [.general, .translation, .browser, .speedBoost, .sending]
        case .appearance:
            return [.appearance, .tabs, .folders, .chatList, .accountColors]
        case .chats:
            return [.chats, .aiFeatures, .messageMenu, .messageMenuStock, .inlineResults, .inlineResultsSettings, .gestures, .stickers]
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
    entries.append(.header(id: id.count, section: .backup, text: i18n("Extera.Backup", lang).uppercased(), badge: nil))
    entries.append(.action(id: id.count, section: .backup, actionType: SGSettingsAction.exportSettings, text: i18n("Extera.ExportSettings", lang), kind: .generic))
    entries.append(.action(id: id.count, section: .backup, actionType: SGSettingsAction.importSettings, text: i18n("Extera.ImportSettings", lang), kind: .generic))
    entries.append(.notice(id: id.count, section: .backup, text: i18n("Extera.BackupInfo", lang)))
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
    entries.append(.toggle(id: id.count, section: .general, settingName: .relativeLastSeen, value: ExteraSettings.shared.relativeLastSeen, text: i18n("Extera.RelativeLastSeen", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .formatTimeWithSeconds, value: settings.secondsInMessages, text: i18n("Extera.FormatTimeWithSeconds", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .hidePhoneNumber, value: settings.hidePhoneInSettings, text: i18n("Extera.HidePhoneNumber", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .hideAccountInNotifications, value: settings.hideAccountInNotifications, text: i18n("Settings.HideAccountInNotifications", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .showProxyCountry, value: ExteraSettings.shared.value(.showProxyCountry), text: i18n("Extera.ShowProxyCountry", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .general, text: i18n("Extera.ShowProxyCountryInfo", lang)))

    entries.append(.header(id: id.count, section: .translation, text: strings.Localization_TranslateMessages.uppercased(), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .translation, settingName: .translationProvider, text: i18n("Extera.TranslationProvider", lang), value: translationProviderTitle(settings.translationBackendEnum, lang: lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .translation, settingName: .translationTarget, text: i18n("Extera.TranslationTarget", lang), value: translationTargetTitle(ExteraSettings.shared.targetLang, lang: lang), enabled: true))
    entries.append(.notice(id: id.count, section: .translation, text: i18n("Extera.TranslationProviderInfo", lang)))

    entries.append(.header(id: id.count, section: .browser, text: i18n("Extera.Browser", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .browser, settingName: .enableAdBlock, value: ExteraSettings.shared.value(.enableAdBlock), text: i18n("Extera.AdBlock", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .browser, text: adBlockNotice(lang: lang)))

    entries.append(.header(id: id.count, section: .sending, text: strings.NetworkUsageSettings_MediaImageDataSection.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .sending, settingName: .sendLargePhotos, value: settings.sendLargePhotos, text: i18n("Settings.Photo.SendLarge", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .sending, text: i18n("Settings.Photo.SendLarge.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .sending, settingName: .sendWithReturnKey, value: settings.sendWithReturnKey, text: i18n("Settings.SendWithReturnKey", lang), enabled: true))

    // Appearance: exteraGram first, then the navigation bar, folders, chat list and name colors.
    entries.append(.header(id: id.count, section: .appearance, text: i18n("Extera.Appearance", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .hideStories, value: settings.hideStories, text: i18n("Extera.HideStories", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .hideAllChats, value: settings.allChatsHidden, text: i18n("Extera.HideAllChats", lang, strings.ChatList_Tabs_AllChats), enabled: true))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .hideActionBarStatus, value: ExteraSettings.shared.hideActionBarStatus, text: i18n("Extera.HideActionBarStatus", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .hideDialogsSearchBar, value: ExteraSettings.shared.hideDialogsSearchBar, text: i18n("Extera.HideDialogsSearchBar", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .appearance, settingName: .titleText, text: i18n("Extera.TitleText", lang), value: titleTextTitle(ExteraSettings.shared.titleText, lang: lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .appearance, settingName: .avatarCorners, text: i18n("Extera.AvatarCorners", lang), value: avatarCornersTitle(ExteraSettings.shared.avatarCorners, lang: lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .singleCornerRadius, value: ExteraSettings.shared.singleCornerRadius, text: i18n("Extera.SingleCornerRadius", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .appearance, text: i18n("Extera.SingleCornerRadiusInfo", lang)))

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
    entries.append(.toggle(id: id.count, section: .folders, settingName: .tabCounterUnmutedOnly, value: ExteraSettings.shared.tabCounterUnmutedOnly, text: i18n("Extera.TabCounterUnmutedOnly", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .folders, settingName: .rememberLastFolder, value: settings.rememberLastFolder, text: i18n("Settings.Folders.RememberLast", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .folders, text: i18n("Settings.Folders.RememberLast.Notice", lang)))

    entries.append(.header(id: id.count, section: .chatList, text: i18n("Extera.ListOfChats", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .compactChatList, value: settings.compactChatList, text: i18n("Settings.CompactChatList", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .archiveOnPull, value: ExteraSettings.shared.archiveOnPull, text: i18n("Extera.ArchiveOnPull", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .senderMiniAvatars, value: ExteraSettings.shared.senderMiniAvatars, text: i18n("Extera.SenderMiniAvatars", lang), enabled: true))

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
    entries.append(.toggle(id: id.count, section: .chats, settingName: .removeMessageTail, value: ExteraSettings.shared.removeMessageTail, text: i18n("Extera.RemoveMessageTail", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .addCommaAfterMention, value: ExteraSettings.shared.addCommaAfterMention, text: i18n("Extera.AddCommaAfterMention", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .showForwardsCount, value: ExteraSettings.shared.showForwardsCount, text: i18n("Extera.ShowForwardsCount", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .hideReactionsInPrivateChats, value: ExteraSettings.shared.hideReactionsInPrivateChats, text: i18n("Extera.HideReactionsInPrivateChats", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .disableMarkdown, value: ExteraSettings.shared.disableMarkdown, text: i18n("Extera.DisableMarkdown", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .showResultsBeforeVoting, value: ExteraSettings.shared.showResultsBeforeVoting, text: i18n("Extera.ShowResultsBeforeVoting", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .chats, text: i18n("Extera.ShowResultsBeforeVotingInfo", lang)))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .hideKeyboardOnScroll, value: ExteraSettings.shared.hideKeyboardOnScroll, text: i18n("Extera.HideKeyboardOnScroll", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .showOnlineStatus, value: ExteraSettings.shared.showOnlineStatus, text: i18n("Extera.ShowOnlineStatus", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .pauseOnMinimizeVoice, value: ExteraSettings.shared.pauseOnMinimizeVoice, text: i18n("Extera.PauseOnMinimizeVoice", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .pauseOnMinimizeRound, value: ExteraSettings.shared.pauseOnMinimizeRound, text: i18n("Extera.PauseOnMinimizeRound", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .pauseOnMinimizeVideo, value: ExteraSettings.shared.pauseOnMinimizeVideo, text: i18n("Extera.PauseOnMinimizeVideo", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .chats, text: i18n("Extera.PauseOnMinimizeInfo", lang)))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .replyColors, value: ExteraSettings.shared.replyColors, text: i18n("Extera.ReplyColors", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .replyEmoji, value: ExteraSettings.shared.replyEmoji, text: i18n("Extera.ReplyEmoji", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .replyBackground, value: ExteraSettings.shared.replyBackground, text: i18n("Extera.ReplyBackground", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .chats, settingName: .doubleTapSeekDuration, text: i18n("Extera.DoubleTapSeekDuration", lang), value: strings.MessageTimer_Seconds(Int32(ExteraSettings.shared.doubleTapSeekDuration)), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .preferOriginalQuality, value: ExteraSettings.shared.preferOriginalQuality, text: i18n("Extera.PreferOriginalQuality", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .widePosts, value: settings.wideChannelPosts, text: i18n("Extera.WidePosts", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .bottomButton, value: !settings.hideChannelBottomButton, text: i18n("Extera.BottomButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .quickTransitions, value: !settings.disableScrollToNextChannel, text: i18n("Extera.QuickTransitions", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .quickTransitionsTopics, value: !settings.disableScrollToNextTopic, text: i18n("Settings.PullToNextTopic", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .hideCameraTile, value: settings.disableGalleryCamera, text: i18n("Extera.HideCameraTile", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .cameraTilePreview, value: !settings.disableGalleryCameraPreview, text: i18n("Settings.GalleryCameraPreview", lang), enabled: !settings.disableGalleryCamera))
    entries.append(.oneFromManySelector(id: id.count, section: .chats, settingName: .videoMessagesCamera, text: i18n("Extera.VideoMessagesCamera", lang), value: videoMessagesCameraTitle(ExteraSettings.shared.videoMessagesCamera, lang: lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .recordingButton, value: !settings.hideRecordingButton, text: i18n("Settings.RecordingButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .snapDeletionEffect, value: !settings.disableSnapDeletionEffect, text: i18n("Settings.SnapDeletionEffect", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .hideReactions, value: settings.hideReactions, text: i18n("Settings.HideReactions", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .hideSendAsPeer, value: settings.disableSendAsButton, text: i18n("Extera.HideSendAsPeer", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .chats, text: i18n("Extera.HideSendAsPeerInfo", lang)))

    entries.append(.header(id: id.count, section: .aiFeatures, text: i18n("Extera.AIFeatures", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .aiFeatures, settingName: .telegramAiEditor, value: ExteraSettings.shared.value(.telegramAiEditor), text: i18n("Extera.AIFeaturesEditor", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .aiFeatures, settingName: .telegramAiSummaries, value: ExteraSettings.shared.value(.telegramAiSummaries), text: i18n("Extera.AIFeaturesSummaries", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .aiFeatures, text: i18n("Extera.AIFeaturesInfo", lang)))

    entries.append(.header(id: id.count, section: .messageMenu, text: i18n("Settings.ContextMenu", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .messageMenu, settingName: .showRepeatButton, value: ExteraSettings.shared.showRepeatButton, text: i18n("Extera.ShowRepeatButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messageMenu, settingName: .showSaveMessageButton, value: ExteraSettings.shared.value(.showSaveMessageButton), text: i18n("Extera.SaveMessage", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messageMenu, settingName: .showClearButton, value: ExteraSettings.shared.showClearButton, text: i18n("Extera.ShowClearButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messageMenu, settingName: .showHistoryButton, value: ExteraSettings.shared.showHistoryButton, text: i18n("Extera.ShowHistoryButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messageMenu, settingName: .showDetailsButton, value: ExteraSettings.shared.showDetailsButton, text: i18n("Extera.ShowDetailsButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messageMenu, settingName: .showShareAsImageButton, value: ExteraSettings.shared.value(.showShareAsImageButton), text: i18n("Extera.ShareAsImage", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messageMenu, settingName: .showSearchImageButton, value: ExteraSettings.shared.value(.showSearchImageButton), text: i18n("Extera.SearchImage", lang), enabled: true))

    entries.append(.toggle(id: id.count, section: .messageMenuStock, settingName: .contextShowReply, value: settings.contextShowReply, text: strings.Conversation_ContextMenuReply, enabled: true))
    entries.append(.toggle(id: id.count, section: .messageMenuStock, settingName: .contextShowPin, value: settings.contextShowPin, text: strings.Conversation_Pin, enabled: true))
    entries.append(.toggle(id: id.count, section: .messageMenuStock, settingName: .contextShowSaveMedia, value: settings.contextShowSaveMedia, text: strings.Preview_SaveToCameraRoll, enabled: true))
    entries.append(.toggle(id: id.count, section: .messageMenuStock, settingName: .contextShowMessageReplies, value: settings.contextShowMessageReplies, text: strings.Conversation_ContextViewThread, enabled: true))
    entries.append(.toggle(id: id.count, section: .messageMenuStock, settingName: .contextShowReport, value: settings.contextShowReport, text: strings.Conversation_ContextMenuReport, enabled: true))
    entries.append(.toggle(id: id.count, section: .messageMenuStock, settingName: .contextShowRestrict, value: settings.contextShowRestrict, text: strings.Conversation_ContextMenuBan, enabled: true))
    entries.append(.notice(id: id.count, section: .messageMenuStock, text: i18n("Settings.ContextMenu.Notice", lang)))

    let extera = ExteraSettings.shared
    let inlineResults = extera.inlineResults
    entries.append(.header(id: id.count, section: .inlineResults, text: i18n("Extera.InlineResults", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .inlineResults, settingName: .inlineResults, value: inlineResults, text: i18n("Extera.InlineShowResults", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .inlineResults, settingName: .inlineMathResult, value: extera.inlineMathResult, text: i18n("Extera.InlineCalculator", lang), enabled: inlineResults))
    entries.append(.toggle(id: id.count, section: .inlineResults, settingName: .inlineCurrencyRates, value: extera.inlineCurrencyRates, text: i18n("Extera.InlineCurrencies", lang), enabled: inlineResults))
    entries.append(.toggle(id: id.count, section: .inlineResults, settingName: .inlineUnitConversion, value: extera.inlineUnitConversion, text: i18n("Extera.InlineUnits", lang), enabled: inlineResults))
    entries.append(.toggle(id: id.count, section: .inlineResults, settingName: .inlineTimeZones, value: extera.inlineTimeZones, text: i18n("Extera.InlineTimeZones", lang), enabled: inlineResults))
    entries.append(.notice(id: id.count, section: .inlineResults, text: i18n("Extera.InlineResultsHint", lang)))

    entries.append(.toggle(id: id.count, section: .inlineResultsSettings, settingName: .inlineDigitGrouping, value: extera.inlineDigitGrouping, text: i18n("Extera.InlineDigitGrouping", lang), enabled: inlineResults))
    entries.append(.oneFromManySelector(id: id.count, section: .inlineResultsSettings, settingName: .inlineAngleUnit, text: i18n("Extera.InlineAngleUnit", lang), value: inlineAngleUnitTitle(extera.inlineAngleUnit, lang: lang), enabled: inlineResults && extera.inlineMathResult))
    entries.append(.oneFromManySelector(id: id.count, section: .inlineResultsSettings, settingName: .inlineTargetCurrency, text: i18n("Extera.InlineDefaultCurrency", lang), value: InlineCurrencyChoices.isSupported(extera.inlineTargetCurrency) ? extera.inlineTargetCurrency : i18n("Extera.Auto", lang), enabled: inlineResults && extera.inlineCurrencyRates))
    entries.append(.oneFromManySelector(id: id.count, section: .inlineResultsSettings, settingName: .inlineMeasureSystem, text: i18n("Extera.InlineMeasureSystem", lang), value: inlineMeasureSystemTitle(extera.inlineMeasureSystem, lang: lang), enabled: inlineResults && extera.inlineUnitConversion))
    entries.append(.notice(id: id.count, section: .inlineResultsSettings, text: i18n("Extera.InlineAutoCurrencyInfo", lang) + "\n\n" + inlineExamplesText(lang: lang)))

    entries.append(.header(id: id.count, section: .gestures, text: i18n("Extera.Gestures", lang).uppercased(), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .gestures, settingName: .doubleTapAction, text: i18n("Extera.DoubleTapIncoming", lang), value: doubleTapActionTitle(ExteraSettings.shared.doubleTapAction, lang: lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .gestures, settingName: .doubleTapActionOutgoing, text: i18n("Extera.DoubleTapOutgoing", lang), value: doubleTapActionTitle(ExteraSettings.shared.doubleTapActionOutgoing, lang: lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .gestures, settingName: .swipeAction, text: i18n("Extera.SwipeAction", lang), value: ayuSwipeActionsSummary(lang: lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .gestures, settingName: .disableUnarchiveSwipe, value: ExteraSettings.shared.disableUnarchiveSwipe, text: i18n("Extera.DisableUnarchiveSwipe", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .gestures, text: i18n("Extera.DisableUnarchiveSwipeInfo", lang)))

    entries.append(.header(id: id.count, section: .stickers, text: strings.StickerPacksSettings_Title.uppercased(), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .stickers, settingName: .stickerShape, text: i18n("Extera.StickerShape", lang), value: stickerShapeTitle(ExteraSettings.shared.stickerShape, lang: lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .stickers, settingName: .stickerTime, value: settings.stickerTimestamp, text: i18n("Extera.StickerTimeMode", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .stickers, settingName: .forceEmojiTab, value: settings.forceEmojiTab, text: i18n("Settings.ForceEmojiTab", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .stickers, settingName: .defaultEmojisFirst, value: settings.defaultEmojisFirst, text: i18n("Settings.DefaultEmojisFirst", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .stickers, text: i18n("Settings.DefaultEmojisFirst.Notice", lang)))

    // Other: profiles and stories.
    entries.append(.header(id: id.count, section: .profiles, text: i18n("Settings.Profiles.Header", lang), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .profiles, settingName: .defaultProfileTab, text: i18n("Extera.DefaultProfileTab", lang), value: defaultProfileTabTitle(ExteraSettings.shared.defaultProfileTab, strings: strings, lang: lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showIdAndDc, value: settings.showProfileId, text: i18n("Extera.ShowIdAndDc", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Extera.ShowIdAndDcInfo", lang)))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showRegDate, value: settings.showRegDate, text: i18n("Settings.ShowRegDate", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Extera.RegDateInfo", lang)))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showCreationDate, value: settings.showCreationDate, text: i18n("Settings.ShowCreationDate", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Settings.ShowCreationDate.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showExteraBadges, value: ExteraSettings.shared.value(.showExteraBadges), text: i18n("Extera.ShowBadges", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Extera.ShowBadgesInfo", lang)))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .confirmCalls, value: settings.confirmCalls, text: i18n("Settings.CallConfirmation", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Settings.CallConfirmation.Notice", lang)))

    entries.append(.header(id: id.count, section: .stories, text: strings.AutoDownloadSettings_Stories.uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .stories, settingName: .warnOnStoriesOpen, value: settings.warnOnStoriesOpen, text: i18n("Settings.Stories.WarnBeforeView", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .stories, settingName: .storyStealthMode, value: settings.storyStealthMode, text: strings.Story_StealthMode_Title, enabled: true))
    entries.append(.notice(id: id.count, section: .stories, text: strings.Story_StealthMode_ControlText))

    return filterSGItemListUIEntrires(entries: entries, by: state.searchQuery)
}

private func titleTextTitle(_ value: ExteraSettings.TitleText, lang: String) -> String {
    switch value {
    case .default:
        return i18n("Extera.Default", lang)
    case .username:
        return i18n("Extera.TitleTextUsername", lang)
    case .firstName:
        return i18n("Extera.TitleTextName", lang)
    case .appName:
        return "AyuGram"
    }
}

// One line of things to type per feature.
private func inlineExamplesText(lang: String) -> String {
    let russian = InlineExamples.isRussian(language: lang)
    let features: [(String, [InlineExampleGroup])] = [
        ("Extera.InlineCalculator", [InlineExamples.arithmetic, InlineExamples.percentages, InlineExamples.bases]),
        ("Extera.InlineCurrencies", [InlineExamples.currencyDefault, InlineExamples.currencyTarget]),
        ("Extera.InlineUnits", [InlineExamples.unitsDefault, InlineExamples.unitsTarget, InlineExamples.durations]),
        ("Extera.InlineTimeZones", [InlineExamples.timeZones, InlineExamples.currentTime])
    ]
    var lines: [String] = []
    for (title, groups) in features {
        let examples = groups.compactMap { $0.examples(russian: russian).first }
        lines.append("\(i18n(title, lang)): \(examples.joined(separator: "   "))")
    }
    return lines.joined(separator: "\n")
}

private func inlineAngleUnitTitle(_ value: ExteraSettings.InlineAngleUnit, lang: String) -> String {
    switch value {
    case .degrees:
        return i18n("Extera.InlineAngleDegrees", lang)
    case .radians:
        return i18n("Extera.InlineAngleRadians", lang)
    }
}

private func inlineMeasureSystemTitle(_ value: ExteraSettings.InlineMeasureSystem, lang: String) -> String {
    switch value {
    case .auto:
        return i18n("Extera.Auto", lang)
    case .metric:
        return i18n("Extera.InlineMeasureMetric", lang)
    case .imperial:
        return i18n("Extera.InlineMeasureImperial", lang)
    }
}

private func translationProviderTitle(_ value: SGSimpleSettings.TranslationBackend, lang: String) -> String {
    switch value {
    case .default:
        return "Telegram"
    case .gtranslate:
        return "Google"
    case .yandex:
        return i18n("Settings.Translation.Backend.yandex", lang)
    case .microsoft:
        return "Microsoft"
    case .system:
        return i18n("Settings.Translation.Backend.system", lang)
    }
}

private func adBlockNotice(lang: String) -> String {
    var text = i18n("Extera.AdBlockInfo", lang)
    guard ExteraSettings.shared.value(.enableAdBlock) else {
        return text
    }
    switch AyuAdBlockStore.shared.state {
    case .idle, .preparing:
        text += "\n\n" + i18n("Extera.AdBlock.Loading", lang)
    case let .ready(ruleCount):
        text += "\n\n" + i18n("Extera.AdBlock.Ready", lang, "\(ruleCount)")
    case .failed:
        text += "\n\n" + i18n("Extera.AdBlock.Failed", lang)
    }
    return text
}

private func translationTargetTitle(_ code: String, lang: String) -> String {
    if code.isEmpty {
        return i18n("Extera.TranslationTargetApp", lang)
    }
    let name = Locale(identifier: lang).localizedString(forLanguageCode: code) ?? code.uppercased()
    return name.prefix(1).uppercased() + name.dropFirst()
}

// "Follow App" first, then the languages the services translate to, by name.
private func translationTargetChoices(lang: String) -> [(code: String, title: String)] {
    let languages = supportedTranslationLanguages.map { (code: $0, title: translationTargetTitle($0, lang: lang)) }.sorted { lhs, rhs in
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
    return [(code: "", title: translationTargetTitle("", lang: lang))] + languages
}

// Apple's on-device translation needs iOS 18.
private func translationProviderChoices() -> [SGSimpleSettings.TranslationBackend] {
    var choices: [SGSimpleSettings.TranslationBackend] = [.default, .gtranslate, .yandex, .microsoft]
    if #available(iOS 18.0, *) {
        choices.append(.system)
    }
    return choices
}

private func videoMessagesCameraTitle(_ value: ExteraSettings.VideoMessagesCamera, lang: String) -> String {
    switch value {
    case .lastUsed:
        return i18n("Extera.VideoMessagesCameraLastUsed", lang)
    case .front:
        return i18n("Extera.VideoMessagesCameraFront", lang)
    case .back:
        return i18n("Extera.VideoMessagesCameraRear", lang)
    }
}

private func avatarCornersTitle(_ value: Int, lang: String) -> String {
    return value == 28 ? i18n("Extera.Default", lang) : "\(value)"
}

private func doubleTapActionTitle(_ value: ExteraSettings.DoubleTapAction, lang: String) -> String {
    switch value {
    case .disable:
        return i18n("Extera.DoubleTapDisable", lang)
    case .reactions:
        return i18n("Extera.DoubleTapReaction", lang)
    case .reply:
        return i18n("Extera.DoubleTapReply", lang)
    case .copy:
        return i18n("Extera.DoubleTapCopy", lang)
    case .forward:
        return i18n("Extera.DoubleTapForward", lang)
    case .edit:
        return i18n("Extera.DoubleTapEdit", lang)
    case .save:
        return i18n("Extera.DoubleTapSave", lang)
    case .repeat:
        return i18n("Extera.DoubleTapRepeat", lang)
    case .delete:
        return i18n("Extera.DoubleTapDelete", lang)
    case .translate:
        return i18n("Extera.DoubleTapTranslate", lang)
    }
}

private func stickerShapeTitle(_ value: ExteraSettings.StickerShape, lang: String) -> String {
    switch value {
    case .default:
        return i18n("Extera.Default", lang)
    case .rounded:
        return i18n("Extera.StickerShapeRounded", lang)
    case .roundedAsMessage:
        return i18n("Extera.StickerShapeRoundedMsg", lang)
    }
}

private func defaultProfileTabTitle(_ value: ExteraSettings.DefaultProfileTab, strings: PresentationStrings, lang: String) -> String {
    switch value {
    case .default:
        return i18n("Extera.Default", lang)
    case .media:
        return strings.PeerInfo_PaneMedia
    case .commonGroups:
        return strings.PeerInfo_PaneGroups
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
    var exportSettingsImpl: (() -> Void)?
    var importSettingsImpl: (() -> Void)?

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
        case .showExteraBadges:
            ExteraSettings.shared.set(.showExteraBadges, value)
        case .showSaveMessageButton:
            ExteraSettings.shared.set(.showSaveMessageButton, value)
        case .showSearchImageButton:
            ExteraSettings.shared.set(.showSearchImageButton, value)
        case .showProxyCountry:
            ExteraSettings.shared.set(.showProxyCountry, value)
        case .showShareAsImageButton:
            ExteraSettings.shared.set(.showShareAsImageButton, value)
        case .enableAdBlock:
            ExteraSettings.shared.set(.enableAdBlock, value)
            if value {
                AyuAdBlockStore.shared.prepare()
            }
        case .telegramAiSummaries:
            ExteraSettings.shared.set(.telegramAiSummaries, value)
        case .telegramAiEditor:
            ExteraSettings.shared.set(.telegramAiEditor, value)
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
        case .removeMessageTail:
            ExteraSettings.shared.set(.removeMessageTail, value)
        case .addCommaAfterMention:
            ExteraSettings.shared.set(.addCommaAfterMention, value)
        case .showForwardsCount:
            ExteraSettings.shared.set(.showForwardsCount, value)
        case .hideReactionsInPrivateChats:
            ExteraSettings.shared.set(.hideReactionsInPrivateChats, value)
        case .showResultsBeforeVoting:
            ExteraSettings.shared.set(.showResultsBeforeVoting, value)
        case .disableMarkdown:
            ExteraSettings.shared.set(.disableMarkdown, value)
        case .relativeLastSeen:
            ExteraSettings.shared.set(.relativeLastSeen, value)
        case .hideActionBarStatus:
            ExteraSettings.shared.set(.hideActionBarStatus, value)
        case .hideDialogsSearchBar:
            ExteraSettings.shared.set(.hideDialogsSearchBar, value)
            askForRestart?()
        case .hideKeyboardOnScroll:
            ExteraSettings.shared.set(.hideKeyboardOnScroll, value)
        case .disableUnarchiveSwipe:
            ExteraSettings.shared.set(.disableUnarchiveSwipe, value)
        case .showOnlineStatus:
            ExteraSettings.shared.set(.showOnlineStatus, value)
        case .archiveOnPull:
            ExteraSettings.shared.set(.archiveOnPull, value)
        case .pauseOnMinimizeVoice:
            ExteraSettings.shared.set(.pauseOnMinimizeVoice, value)
        case .pauseOnMinimizeRound:
            ExteraSettings.shared.set(.pauseOnMinimizeRound, value)
        case .pauseOnMinimizeVideo:
            ExteraSettings.shared.set(.pauseOnMinimizeVideo, value)
        case .senderMiniAvatars:
            ExteraSettings.shared.set(.senderMiniAvatars, value)
        case .replyColors:
            ExteraSettings.shared.set(.replyColors, value)
        case .replyEmoji:
            ExteraSettings.shared.set(.replyEmoji, value)
        case .replyBackground:
            ExteraSettings.shared.set(.replyBackground, value)
        case .preferOriginalQuality:
            ExteraSettings.shared.set(.preferOriginalQuality, value)
        case .showClearButton:
            ExteraSettings.shared.set(.showClearButton, value)
        case .showHistoryButton:
            ExteraSettings.shared.set(.showHistoryButton, value)
        case .showDetailsButton:
            ExteraSettings.shared.set(.showDetailsButton, value)
        case .singleCornerRadius:
            ExteraSettings.shared.set(.singleCornerRadius, value)
        case .tabCounterUnmutedOnly:
            ExteraSettings.shared.set(.tabCounterUnmutedOnly, value)
        case .showRepeatButton:
            ExteraSettings.shared.set(.showRepeatButton, value)
        case .inlineResults:
            ExteraSettings.shared.set(.inlineResults, value)
        case .inlineMathResult:
            ExteraSettings.shared.set(.inlineMathResult, value)
        case .inlineCurrencyRates:
            ExteraSettings.shared.set(.inlineCurrencyRates, value)
        case .inlineUnitConversion:
            ExteraSettings.shared.set(.inlineUnitConversion, value)
        case .inlineTimeZones:
            ExteraSettings.shared.set(.inlineTimeZones, value)
        case .inlineDigitGrouping:
            ExteraSettings.shared.set(.inlineDigitGrouping, value)
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
        case .contextShowReply:
            settings.contextShowReply = value
        case .contextShowPin:
            settings.contextShowPin = value
        case .contextShowSaveMedia:
            settings.contextShowSaveMedia = value
        case .contextShowMessageReplies:
            settings.contextShowMessageReplies = value
        case .contextShowReport:
            settings.contextShowReport = value
        case .contextShowRestrict:
            settings.contextShowRestrict = value
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
        if setting == .swipeAction {
            // A list in order, not one choice: it has its own screen.
            pushControllerImpl?(ayuSwipeActionsController(context: context, updated: {
                simplePromise.set(true)
            }))
            return
        }
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
        case .doubleTapSeekDuration:
            for value in ExteraSettings.doubleTapSeekDurationValues {
                options.append(SGOneFromManyOption(title: presentationData.strings.MessageTimer_Seconds(Int32(value)), isSelected: ExteraSettings.shared.doubleTapSeekDuration == value, action: {
                    ExteraSettings.shared.doubleTapSeekDuration = value
                    simplePromise.set(true)
                }))
            }
        case .defaultProfileTab:
            for value in ExteraSettings.DefaultProfileTab.allCases {
                options.append(SGOneFromManyOption(title: defaultProfileTabTitle(value, strings: presentationData.strings, lang: lang), isSelected: ExteraSettings.shared.defaultProfileTab == value, action: {
                    ExteraSettings.shared.defaultProfileTab = value
                    simplePromise.set(true)
                }))
            }
        case .stickerShape:
            for value in ExteraSettings.StickerShape.allCases {
                options.append(SGOneFromManyOption(title: stickerShapeTitle(value, lang: lang), isSelected: ExteraSettings.shared.stickerShape == value, action: {
                    ExteraSettings.shared.stickerShape = value
                    simplePromise.set(true)
                }))
            }
        case .swipeAction:
            break
        case .videoMessagesCamera:
            for value in ExteraSettings.VideoMessagesCamera.allCases {
                options.append(SGOneFromManyOption(title: videoMessagesCameraTitle(value, lang: lang), isSelected: ExteraSettings.shared.videoMessagesCamera == value, action: {
                    ExteraSettings.shared.videoMessagesCamera = value
                    simplePromise.set(true)
                }))
            }
        case .translationProvider:
            for value in translationProviderChoices() {
                options.append(SGOneFromManyOption(title: translationProviderTitle(value, lang: lang), isSelected: SGSimpleSettings.shared.translationBackendEnum == value, action: {
                    SGSimpleSettings.shared.translationBackend = value.rawValue
                    simplePromise.set(true)
                }))
            }
        case .translationTarget:
            for choice in translationTargetChoices(lang: lang) {
                options.append(SGOneFromManyOption(title: choice.title, isSelected: ExteraSettings.shared.targetLang == choice.code, action: {
                    ExteraSettings.shared.targetLang = choice.code
                    simplePromise.set(true)
                }))
            }
        case .inlineAngleUnit:
            for value in ExteraSettings.InlineAngleUnit.allCases {
                options.append(SGOneFromManyOption(title: inlineAngleUnitTitle(value, lang: lang), isSelected: ExteraSettings.shared.inlineAngleUnit == value, action: {
                    ExteraSettings.shared.inlineAngleUnit = value
                    simplePromise.set(true)
                }))
            }
        case .inlineMeasureSystem:
            for value in ExteraSettings.InlineMeasureSystem.allCases {
                options.append(SGOneFromManyOption(title: inlineMeasureSystemTitle(value, lang: lang), isSelected: ExteraSettings.shared.inlineMeasureSystem == value, action: {
                    ExteraSettings.shared.inlineMeasureSystem = value
                    simplePromise.set(true)
                }))
            }
        case .inlineTargetCurrency:
            let current = InlineCurrencyChoices.isSupported(ExteraSettings.shared.inlineTargetCurrency) ? ExteraSettings.shared.inlineTargetCurrency : ""
            let choices = [(code: "", title: i18n("Extera.Auto", lang))] + InlineCurrencyChoices.all(locale: Locale(identifier: lang))
            for choice in choices {
                options.append(SGOneFromManyOption(title: choice.title, isSelected: current == choice.code, action: {
                    ExteraSettings.shared.inlineTargetCurrency = choice.code
                    simplePromise.set(true)
                }))
            }
        case .titleText:
            for value in ExteraSettings.TitleText.allCases {
                options.append(SGOneFromManyOption(title: titleTextTitle(value, lang: lang), isSelected: ExteraSettings.shared.titleText == value, action: {
                    ExteraSettings.shared.titleText = value
                    simplePromise.set(true)
                }))
            }
        case .avatarCorners:
            for value in ExteraSettings.avatarCornersValues {
                options.append(SGOneFromManyOption(title: avatarCornersTitle(value, lang: lang), isSelected: ExteraSettings.shared.avatarCorners == value, action: {
                    ExteraSettings.shared.avatarCorners = value
                    simplePromise.set(true)
                }))
            }
        case .doubleTapAction:
            for value in ExteraSettings.DoubleTapAction.incomingCases {
                options.append(SGOneFromManyOption(title: doubleTapActionTitle(value, lang: lang), isSelected: ExteraSettings.shared.doubleTapAction == value, action: {
                    ExteraSettings.shared.doubleTapAction = value
                    simplePromise.set(true)
                }))
            }
        case .doubleTapActionOutgoing:
            for value in ExteraSettings.DoubleTapAction.allCases {
                options.append(SGOneFromManyOption(title: doubleTapActionTitle(value, lang: lang), isSelected: ExteraSettings.shared.doubleTapActionOutgoing == value, action: {
                    ExteraSettings.shared.doubleTapActionOutgoing = value
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
    }, action: { action in
        switch action.base as? SGSettingsAction {
        case .exportSettings:
            exportSettingsImpl?()
        case .importSettings:
            importSettingsImpl?()
        case .none:
            break
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
    exportSettingsImpl = { [weak controller] in
        guard let controller else {
            return
        }
        ayuExportSettingsBackup(context: context, from: controller)
    }
    importSettingsImpl = { [weak controller] in
        guard let controller else {
            return
        }
        ayuImportSettingsBackup(context: context, from: controller, applied: {
            simplePromise.set(true)
            askForRestart?()
        })
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
