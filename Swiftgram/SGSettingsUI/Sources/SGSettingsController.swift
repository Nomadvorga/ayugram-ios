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
import Speech

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
    case application
    case other
    case chats
    case gestures
    case stickers
    case profiles
    case stories
    case media
    case replies
    case reactions
    case messageMenu
    case camera
    case speechRecognition
    case backup
    case inlineCalculator
    case browser
    case chatLinks
    case stickerAppearance
    case messages
    case swipeActions
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
    case hideActionBarStatus
    case hideFloatingButton
    case hideDialogsSearchBar
    case senderMiniAvatars
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
    case hideReactionsInChannels
    case hideReactionsInGroups
    case hideReactionsInPrivateChats
    case removeMessageTail
    case replyColors
    case replyEmoji
    case replyBackground
    case showForwardsCount
    case showOnlineStatus
    case showPollResultsBeforeVoting
    case hideKeyboardOnScroll
    case quickAdminShortcuts
    case swipeToReplyIncoming
    case swipeToReplyOutgoing
    case preferOriginalQuality
    case pauseOnMinimizeVideo
    case pauseOnMinimizeVoice
    case pauseOnMinimizeRound
    case rememberLastUsedCamera
    case zoomSlider
    case staticZoom
    case unmuteWithVolumeButtons
    case appleSpeechOnDeviceOnly
    case showCopyPhotoButton
    case showSaveMessageButton
    case showRepeatMessageButton
    case showClearButton
    case showHistoryButton
    case showReportButton
    case showDetailsButton
    case showMessageImageExportButton
    case groupMessageMenu
    case inlineResults
    case inlineMathResult
    case inlineDigitGrouping
    case adBlockingEnabled
    case unlimitedRecentStickers
    case inlineUnits
    case inlineCurrencies
    case inlineTimeZones
    case inlineImperial
    case preferEmbeddedLyrics
    case lyricsAutoScroll
    case lyricsTapToSeek
    case repliesGroup
    case reactionsGroup
    case transitionsGroup
    case pauseGroup
    case menuGroup
    case aiFeaturesGroup
    case aiEditor
    case aiSummaries
    case aiInstantViewSummaries
    case wideFeedPosts
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
    case channelBottomButton
    case chatListTitle
    case downloadSpeedBoost
    case allChatsTitle
    case tabTitleStyle
    case tabCounterMode
    case translationProvider
    case translationTargetLanguage
    case doNotTranslateLanguages
    case showIdAndDc
    case customSavePath
    case defaultProfileTab
    case doubleTapIncoming
    case doubleTapOutgoing
    case doubleTapSeekDuration
    case videoMessagesCamera
    case appleSpeechLocale
    case transcriptionBackend
    case inlineAngleUnit
    case stickerSize
    case stickerTimeMode
    case stickerShape
    case inlineTargetCurrency
    case lyricsSource
    case lyricsDisplayMode
    case lyricsOffset
}

private enum SGSliderSetting: String {
    case stickerRawSize
    case avatarCorners
    case accountColorsSaturation
    case outgoingPhotoQuality
}

private enum SGDisclosureLink: String {
    case styleSettings
    case readReceipts
    case energySettings
    case uiIconPacks
    case speechRecognition
    case appIcon
    case navigationSettings
    case categoryGeneral
    case categoryAppearance
    case categoryChats
    case categoryMedia
    case categoryOther
    case upstreamSource
    case settingsBackup
    case browserExceptions
    case aiServices
    case channelFeed
    case dataPills
    case browserFilters
    case cloudExport
    case chatSettings
    case inlineResults
    case swipeActions
}

public enum SGSettingsCategory {
    case general
    case appearance
    case chats
    case media
    case other

    // Detail pages opened from Chats, also indexed by the main search.
    case inlineResults
    case swipeActions

    fileprivate var sections: Set<SGControllerSection> {
        switch self {
        case .general:
            return [.translation, .general, .speedBoost, .storage, .profileGeneral, .archive]
        case .appearance:
            return [.avatarCorners, .appearance, .tabs, .folders, .chatList, .accountColors, .application]
        case .chats:
            return [.stickerAppearance, .replies, .chatLinks, .stickers, .gestures, .chats, .messages, .messageMenu, .sending]
        case .media:
            return [.media, .camera, .speechRecognition]
        case .other:
            return [.other, .profiles, .stories, .backup, .browser]
        case .inlineResults:
            return [.inlineCalculator]
        case .swipeActions:
            return [.swipeActions]
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
        case .media:
            return "Extera.CategoryMedia"
        case .other:
            return "Ayu.CategoryOther"
        case .inlineResults:
            return "Extera.InlineResults"
        case .swipeActions:
            return "Extera.SwipeActions"
        }
    }
}

private func chatListTitleOption(_ value: ExteraSettings.ChatListTitle, lang: String) -> String {
    switch value {
    case .ayuGram: return "AyuGram"
    case .fullName: return i18n("Extera.ActionBarTitleFullName", lang)
    case .firstName: return i18n("Extera.ActionBarTitleName", lang)
    case .chats: return i18n("Extera.ActionBarTitleChats", lang)
    case .username: return i18n("Extera.ActionBarTitleUsername", lang)
    }
}

private func tabTitleStyleTitle(_ value: ExteraSettings.TabTitleStyle, lang: String) -> String {
    switch value {
    case .textWithIcons: return i18n("Extera.TabTitleStyle.TextWithIcons", lang)
    case .textOnly: return i18n("Extera.TabTitleStyle.TextOnly", lang)
    case .iconsOnly: return i18n("Extera.TabTitleStyle.IconsOnly", lang)
    }
}

private func tabCounterModeTitle(_ value: ExteraSettings.TabCounterMode, lang: String) -> String {
    switch value {
    case .allChats: return i18n("Extera.TabCounter.AllChats", lang)
    case .unmuted: return i18n("Extera.TabCounter.Unmuted", lang)
    case .off: return i18n("Extera.TabCounter.Off", lang)
    }
}

private struct SGSettingsControllerState: Equatable {
    var searchQuery: String?
    var expandedGroups: Set<SGBoolSetting> = []
}

private func doubleTapActionTitle(_ action: ExteraChatSettings.DoubleTapAction, lang: String) -> String {
    switch action {
    case .inherit: return i18n("Extera.DoubleTapAction.Inherit", lang)
    case .disabled: return i18n("Extera.DoubleTapAction.Disabled", lang)
    case .reaction: return i18n("Extera.DoubleTapAction.Reaction", lang)
    case .reply: return i18n("Extera.DoubleTapAction.Reply", lang)
    case .copy: return i18n("Extera.DoubleTapAction.Copy", lang)
    case .forward: return i18n("Extera.DoubleTapAction.Forward", lang)
    case .edit: return i18n("Extera.DoubleTapAction.Edit", lang)
    case .save: return i18n("Extera.DoubleTapAction.Save", lang)
    case .repeatMessage: return i18n("Ayu.RepeatMessage", lang)
    case .delete: return i18n("Extera.DoubleTapAction.Delete", lang)
    case .translate: return i18n("Extera.DoubleTapAction.Translate", lang)
    case .read: return i18n("Extera.DoubleTapAction.Read", lang)
    }
}

private func channelBottomButtonTitle(_ value: ExteraChatSettings.ChannelBottomButton, lang: String) -> String {
    switch value {
    case .hidden: return i18n("Extera.Chat.ChannelBottomButton.Hidden", lang)
    case .mute: return i18n("Extera.Chat.ChannelBottomButton.Mute", lang)
    case .discuss: return i18n("Extera.Chat.ChannelBottomButton.Discuss", lang)
    }
}

private func doubleTapActionSymbol(_ action: ExteraChatSettings.DoubleTapAction) -> String {
    switch action {
    case .inherit, .reaction: return "heart"
    case .disabled: return "nosign"
    case .reply: return "arrowshape.turn.up.left"
    case .copy: return "doc.on.doc"
    case .forward: return "arrowshape.turn.up.right"
    case .edit: return "pencil"
    case .save: return "bookmark"
    case .repeatMessage: return "repeat"
    case .delete: return "trash"
    case .translate: return "globe"
    case .read: return "checkmark"
    }
}

private func defaultProfileTabTitle(_ tab: ExteraGeneralSettings.DefaultProfileTab, lang: String) -> String {
    switch tab {
    case .default: return i18n("Extera.ProfileTab.Default", lang)
    case .media: return i18n("Extera.ProfileTab.Media", lang)
    case .groupsInCommon: return i18n("Extera.ProfileTab.GroupsInCommon", lang)
    }
}

private func speechLocaleTitle(_ identifier: String, lang: String) -> String {
    guard !identifier.isEmpty else { return i18n("Extera.SpeechLocale.Automatic", lang) }
    let locale = Locale(identifier: lang.replacingOccurrences(of: "-raw", with: ""))
    return locale.localizedString(forIdentifier: identifier) ?? identifier
}

private func cameraChoiceKey(_ value: Int) -> String {
    switch value {
    case 1: return "Extera.CameraRear"
    case 2: return "Extera.CameraAsk"
    default: return "Extera.CameraFront"
    }
}

private typealias SGControllerEntry = SGItemListUIEntry<SGControllerSection, SGBoolSetting, SGSliderSetting, SGOneFromManySetting, SGDisclosureLink, AnyHashable>

private func appendSettingsGroup(_ entries: inout [SGControllerEntry], id: SGItemListCounter, section: SGControllerSection, setting: SGBoolSetting, text: String, children: [(SGBoolSetting, Bool, String)], state: SGSettingsControllerState) {
    let selectedCount = children.filter { $0.1 }.count
    let expanded = state.expandedGroups.contains(setting) || !(state.searchQuery ?? "").isEmpty
    entries.append(.expandableToggle(id: id.count, section: section, settingName: setting, value: selectedCount > 0, text: text, selectedCount: selectedCount, totalCount: children.count, isExpanded: expanded, enabled: true))
    for (child, value, title) in children {
        // Reserve IDs even when closed: expanding a group must not change the
        // identity of every following item or replace a focused accessibility row.
        let childId = id.count
        if expanded {
            entries.append(.checkbox(id: childId, section: section, settingName: child, value: value, text: title, enabled: true))
        }
    }
}

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
    entries.append(.header(id: id.count, section: .categories, text: i18n("Extera.Categories", lang), badge: nil))
    entries.append(.disclosure(id: id.count, section: .categories, link: .categoryGeneral, text: i18n("Ayu.CategoryGeneral", lang)))
    entries.append(.disclosure(id: id.count, section: .categories, link: .categoryAppearance, text: i18n("Ayu.CategoryAppearance", lang)))
    entries.append(.disclosure(id: id.count, section: .categories, link: .categoryChats, text: i18n("Ayu.CategoryChats", lang)))
    entries.append(.disclosure(id: id.count, section: .categories, link: .categoryMedia, text: i18n("Extera.CategoryMedia", lang)))
    entries.append(.disclosure(id: id.count, section: .categories, link: .categoryOther, text: i18n("Ayu.CategoryOther", lang)))
    entries.append(.disclosure(id: id.count, section: .categories, link: .aiServices, text: i18n("Extera.AI", lang)))
    entries.append(.disclosure(id: id.count, section: .categories, link: .channelFeed, text: i18n("Extera.ChannelFeed", lang)))
    entries.append(.disclosure(id: id.count, section: .categories, link: .dataPills, text: i18n("Extera.DataPills", lang)))
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
    entries.append(.header(id: id.count, section: .translation, text: i18n("Extera.TranslateMessages", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .translation, settingName: .showTranslateButton, value: translationSettings.showTranslate, text: i18n("Extera.ShowTranslateButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .translation, settingName: .showTranslateChatButton, value: translationSettings.translateChats, text: i18n("Extera.ShowTranslateChatButton", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .translation, settingName: .translationProvider, text: i18n("Extera.TranslationProvider", lang), value: translationProviderTitle(settings.translationBackendEnum, lang: lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .translation, settingName: .translationTargetLanguage, text: i18n("Extera.TranslationTarget", lang), value: translationTargetTitle(strings: strings, lang: lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .translation, settingName: .doNotTranslateLanguages, text: i18n("Extera.DoNotTranslate", lang), value: doNotTranslateTitle(settings: translationSettings, strings: strings, lang: lang), enabled: true))
    entries.append(.notice(id: id.count, section: .translation, text: i18n("Extera.TranslateMessagesInfo1", lang)))

    // General.
    entries.append(.header(id: id.count, section: .general, text: i18n("Extera.General", lang), badge: nil))
    entries.append(.toggleSubtitle(id: id.count, section: .general, settingName: .disableNumberRounding, value: ExteraSettings.shared.disableNumberRounding, text: i18n("Extera.DisableNumberRounding", lang), subtitle: "1.23K → 1,234", enabled: true))
    entries.append(.toggleSubtitle(id: id.count, section: .general, settingName: .formatTimeWithSeconds, value: settings.secondsInMessages, text: i18n("Extera.FormatTimeWithSeconds", lang), subtitle: "12:34 → 12:34:56", enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .inAppVibration, value: ExteraSettings.shared.inAppVibration, text: i18n("Extera.InAppVibration", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .disableNotificationDelay, value: ExteraSettings.shared.disableNotificationDelay, text: i18n("Extera.DisableNotificationDelay", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .filterZalgo, value: ExteraSettings.shared.filterZalgo, text: i18n("Extera.FilterZalgo", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .general, text: i18n("Extera.FilterZalgoInfo", lang, ExteraSettings.shared.filteredText("Z̷͍͌ā̸̜l̸̞̂g̷͍̝o̶̩̓"))))

    // Download speed boost.
    entries.append(.header(id: id.count, section: .speedBoost, text: i18n("Extera.DownloadSpeedBoost", lang), badge: nil))
    let downloadModes = SGSimpleSettings.DownloadSpeedBoostValues.allCases
    entries.append(.segmentedSelector(id: id.count, section: .speedBoost, settingName: .downloadSpeedBoost, value: downloadModes.firstIndex(where: { $0.rawValue == settings.downloadSpeedBoost }) ?? 0, options: downloadModes.map { downloadSpeedBoostTitle($0.rawValue, lang: lang) }, enabled: true))
    entries.append(.toggle(id: id.count, section: .speedBoost, settingName: .uploadSpeedBoost, value: settings.uploadSpeedBoost, text: i18n("Extera.UploadSpeedBoost", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .speedBoost, text: i18n("Extera.SpeedBoostInfo", lang)))

    // Storage: on iOS saved media lands in a named album instead of a directory.
    entries.append(.header(id: id.count, section: .storage, text: i18n("Extera.StorageSettings", lang), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .storage, settingName: .customSavePath, text: i18n("Extera.CustomSavePath", lang), value: ExteraSettings.shared.saveFolderName, enabled: true))
    entries.append(.notice(id: id.count, section: .storage, text: i18n("Extera.CustomSavePathInfo", lang, ExteraSettings.shared.saveFolderName)))

    // Profile.
    entries.append(.header(id: id.count, section: .profileGeneral, text: i18n("Extera.Profile", lang), badge: nil))
    entries.append(.toggleSubtitle(id: id.count, section: .profileGeneral, settingName: .relativeLastSeen, value: ExteraSettings.shared.relativeLastSeen, text: i18n("Extera.RelativeLastSeen", lang), subtitle: i18n("Extera.RelativeLastSeenInfo", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .profileGeneral, settingName: .hidePhoneNumber, value: settings.hidePhoneInSettings, text: i18n("Extera.HidePhoneNumber", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .profileGeneral, settingName: .defaultProfileTab, text: i18n("Extera.DefaultProfileTab", lang), value: defaultProfileTabTitle(ExteraGeneralSettings.shared.defaultProfileTab, lang: lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .profileGeneral, settingName: .showIdAndDc, text: i18n("Extera.ShowIdAndDc", lang), value: showIdAndDcTitle(ExteraSettings.shared.showIdAndDc, lang: lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profileGeneral, text: i18n("Extera.ShowIdAndDcInfo", lang)))

    // Archived chats.
    entries.append(.header(id: id.count, section: .archive, text: i18n("Extera.ArchivedChats", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .archive, settingName: .hideArchiveFolder, value: ExteraSettings.shared.hideArchiveFolder, text: i18n("Extera.HideArchiveFolder", lang), enabled: true))
    if !ExteraSettings.shared.hideArchiveFolder {
        entries.append(.toggle(id: id.count, section: .archive, settingName: .archiveOnPull, value: ExteraSettings.shared.archiveOnPull, text: i18n("Extera.ArchiveOnPull", lang), enabled: true))
    }
    entries.append(.toggle(id: id.count, section: .archive, settingName: .disableUnarchiveSwipe, value: ExteraSettings.shared.disableUnarchiveSwipe, text: i18n("Extera.DisableUnarchiveSwipe", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .archive, text: i18n("Extera.DisableUnarchiveSwipeInfo", lang)))

    // Appearance: exteraGram's avatar shape comes before the Chat List section.
    entries.append(.appearancePreview(id: id.count, section: .avatarCorners, kind: .avatar(value: Int32(ExteraSettings.shared.avatarCorners), title: i18n("Extera.AvatarCorners", lang), square: i18n("Extera.AvatarSquare", lang), circle: i18n("Extera.AvatarCircle", lang)), settingName: .avatarCorners))
    entries.append(.toggle(id: id.count, section: .avatarCorners, settingName: .singleCornerRadius, value: ExteraSettings.shared.singleCornerRadius, text: i18n("Extera.SingleCornerRadius", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .avatarCorners, text: i18n("Extera.SingleCornerRadiusInfo", lang)))

    // Appearance: Chat List settings follow the avatar preview, as in AyuGram.
    entries.append(.header(id: id.count, section: .chatList, text: i18n("Extera.ListOfChats", lang), badge: nil))
    entries.append(.appearancePreview(id: id.count, section: .chatList, kind: .chatList(title: previewTitle, centered: ExteraSettings.shared.centerTitle, snow: ExteraSettings.shared.forceSnow), settingName: nil))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .forceSnow, value: ExteraSettings.shared.forceSnow, text: i18n("Extera.ForceSnow", lang, "Force Snow"), enabled: true))
    entries.append(.notice(id: id.count, section: .chatList, text: i18n("Extera.ForceSnowInfo", lang)))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .hideActionBarStatus, value: ExteraSettings.shared.hideActionBarStatus, text: i18n("Extera.HideActionBarStatus", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .centerTitle, value: ExteraSettings.shared.centerTitle, text: i18n("Extera.CenterTitle", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .hideStories, value: settings.hideStories, text: i18n("Extera.HideStories", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .hideFloatingButton, value: ExteraSettings.shared.hideFloatingButton, text: i18n("Extera.HideFloatingButton", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .chatList, text: i18n("Extera.HideFloatingButtonInfo", lang)))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .hideDialogsSearchBar, value: ExteraSettings.shared.hideDialogsSearchBar, text: i18n("Extera.HideDialogsSearchBar", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .senderMiniAvatars, value: ExteraSettings.shared.senderMiniAvatars, text: i18n("Extera.SenderMiniAvatars", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .compactChatList, value: settings.compactChatList, text: i18n("Settings.CompactChatList", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .chatList, settingName: .chatListTitle, text: i18n("Extera.ActionBarTitle", lang), value: chatListTitleOption(ExteraSettings.shared.chatListTitle, lang: lang), enabled: true))

    entries.append(.header(id: id.count, section: .tabs, text: i18n("Extera.BottomNavigationBarMode", lang), badge: nil))
    entries.append(.disclosure(id: id.count, section: .tabs, link: .navigationSettings, text: i18n("Extera.NavigationSettings", lang)))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .showNavigationBar, value: !settings.hideTabBar, text: i18n("Extera.BottomNavigationBarMode", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .hideNavigationBarLabels, value: !settings.showTabNames, text: i18n("Extera.HideNavigationBarLabels", lang), enabled: !settings.hideTabBar))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .showContactsTab, value: callListSettings.showContactsTab, text: i18n("Extera.ShowContactsTab", lang), enabled: !settings.hideTabBar))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .showCallsTab, value: callListSettings.showTab, text: strings.CallSettings_TabIcon, enabled: !settings.hideTabBar))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .tabBarSearch, value: settings.tabBarSearchEnabled, text: i18n("Settings.Tabs.SearchButton", lang), enabled: !settings.hideTabBar))
    entries.append(.toggle(id: id.count, section: .tabs, settingName: .wideTabBar, value: settings.wideTabBar, text: i18n("Settings.Tabs.WideTabBar", lang), enabled: !settings.hideTabBar))
    entries.append(.notice(id: id.count, section: .tabs, text: i18n("Settings.Tabs.WideTabBar.Notice", lang)))

    entries.append(.header(id: id.count, section: .folders, text: strings.Settings_ChatFolders, badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .folders, settingName: .tabTitleStyle, text: i18n("Extera.TabTitleStyle", lang), value: tabTitleStyleTitle(ExteraSettings.shared.tabTitleStyle, lang: lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .folders, settingName: .tabCounterMode, text: i18n("Extera.TabCounter", lang), value: tabCounterModeTitle(ExteraSettings.shared.tabCounterMode, lang: lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .folders, settingName: .hideAllChats, value: settings.allChatsHidden, text: i18n("Extera.HideAllChats", lang, strings.ChatList_Tabs_AllChats), enabled: true))
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

    // Application: bundled alternate icons with an explicit preview/confirmation.
    entries.append(.header(id: id.count, section: .application, text: i18n("Extera.Application", lang), badge: nil))
    entries.append(.disclosure(id: id.count, section: .application, link: .styleSettings, text: i18n("Extera.Style.Title", lang)))
    entries.append(.disclosure(id: id.count, section: .application, link: .appIcon, text: strings.Appearance_AppIcon))
    entries.append(.disclosure(id: id.count, section: .application, link: .energySettings, text: strings.PowerSavingScreen_Title))
    entries.append(.disclosureSubtitle(id: id.count, section: .application, link: .uiIconPacks, text: i18n("Extera.UIIcons.Title", lang), subtitle: i18n("Extera.UIIcons.Info", lang), iconName: "square.grid.2x2"))

    entries.append(.header(id: id.count, section: .stickerAppearance, text: i18n("Extera.StickersAndEmoji", lang), badge: nil))
    entries.append(.settingsPreview(id: id.count, section: .stickerAppearance, kind: .sticker(SGStickerPreviewConfiguration(size: Int32(ExteraStickerSettings.shared.size), timeMode: ExteraStickerSettings.shared.timeMode.rawValue, shape: ExteraStickerSettings.shared.shape.rawValue, replyColors: ExteraMessageSettings.shared.replyColors, replyEmoji: ExteraMessageSettings.shared.replyEmoji, replyBackground: ExteraMessageSettings.shared.replyBackground, title: i18n("Extera.StickerSize", lang), smallLabel: i18n("Extera.Preview.Small", lang), largeLabel: i18n("Extera.Preview.Large", lang), largeBadge: i18n("Extera.Preview.LargeBadge", lang), timeText: "12:34", replyTitle: i18n("Extera.Preview.Author", lang), replyText: i18n("Extera.Preview.Reply", lang), emoji: "✦", stickerLabel: i18n("Extera.Preview.Sticker", lang))), sliderSetting: .stickerRawSize, selectionSetting: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .stickerAppearance, settingName: .stickerTimeMode, text: i18n("Settings.Stickers.Timestamp", lang), value: i18n("Extera.StickerTimeMode.\(ExteraStickerSettings.shared.timeMode.rawValue)", lang), enabled: true))
    appendSettingsGroup(&entries, id: id, section: .stickerAppearance, setting: .repliesGroup, text: i18n("Extera.Replies", lang), children: [
        (.replyColors, ExteraMessageSettings.shared.replyColors, i18n("Extera.ReplyColors", lang)),
        (.replyEmoji, ExteraMessageSettings.shared.replyEmoji, i18n("Extera.ReplyEmoji", lang)),
        (.replyBackground, ExteraMessageSettings.shared.replyBackground, i18n("Extera.ReplyBackground", lang))
    ], state: state)
    entries.append(.settingsPreview(id: id.count, section: .stickerAppearance, kind: .stickerShapes(value: ExteraStickerSettings.shared.shape.rawValue, options: ExteraStickerSettings.Shape.allCases.map { i18n("Extera.StickerShape.\($0.rawValue)", lang) }), sliderSetting: nil, selectionSetting: .stickerShape))

    entries.append(.disclosureSubtitle(id: id.count, section: .chatLinks, link: .aiServices, text: i18n("Extera.AIChat", lang), subtitle: i18n("Extera.AIChatInfo", lang), iconName: "sparkles"))
    entries.append(.disclosureSubtitle(id: id.count, section: .chatLinks, link: .inlineResults, text: i18n("Extera.InlineResults", lang), subtitle: i18n("Extera.InlineResultsInfo", lang), iconName: "function"))
    entries.append(.disclosureSubtitle(id: id.count, section: .chatLinks, link: .chatSettings, text: i18n("Extera.ChatSettings", lang), subtitle: i18n("Extera.ChatSettingsInfo", lang), iconName: "bubble.left.and.bubble.right"))

    entries.append(.header(id: id.count, section: .stickers, text: i18n("Extera.StickersAndEmoji", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .stickers, settingName: .unlimitedRecentStickers, value: ExteraStickerSettings.shared.unlimitedRecentStickers, text: i18n("Extera.UnlimitedRecentStickers", lang), enabled: true))
    appendSettingsGroup(&entries, id: id, section: .stickers, setting: .reactionsGroup, text: i18n("Settings.HideReactions", lang), children: [
        (.hideReactionsInChannels, ExteraMessageSettings.shared.hideReactionsInChannels, i18n("Extera.Channels", lang)),
        (.hideReactionsInGroups, ExteraMessageSettings.shared.hideReactionsInGroups, i18n("Extera.Groups", lang)),
        (.hideReactionsInPrivateChats, ExteraMessageSettings.shared.hideReactionsInPrivateChats, i18n("Extera.PrivateChats", lang))
    ], state: state)
    entries.append(.notice(id: id.count, section: .stickers, text: i18n("Extera.HideReactionsInfo", lang)))

    entries.append(.header(id: id.count, section: .gestures, text: i18n("Extera.Gestures", lang), badge: nil))
    entries.append(.appearancePreview(id: id.count, section: .gestures, kind: .doubleTap(incomingSymbol: doubleTapActionSymbol(ExteraChatSettings.shared.effectiveDoubleTapAction(incoming: true)), outgoingSymbol: doubleTapActionSymbol(ExteraChatSettings.shared.effectiveDoubleTapAction(incoming: false))), settingName: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .gestures, settingName: .doubleTapIncoming, text: i18n("Extera.DoubleTapIncoming", lang), value: doubleTapActionTitle(ExteraChatSettings.shared.effectiveDoubleTapAction(incoming: true), lang: lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .gestures, settingName: .doubleTapOutgoing, text: i18n("Extera.DoubleTapOutgoing", lang), value: doubleTapActionTitle(ExteraChatSettings.shared.effectiveDoubleTapAction(incoming: false), lang: lang), enabled: true))
    entries.append(.disclosure(id: id.count, section: .gestures, link: .swipeActions, text: i18n("Extera.SwipeActions", lang)))
    entries.append(.notice(id: id.count, section: .gestures, text: i18n("Extera.DoubleTapInfo", lang)))
    entries.append(.disclosure(id: id.count, section: .gestures, link: .readReceipts, text: i18n("Ayu.ReadStatus.Title", lang)))

    entries.append(.header(id: id.count, section: .chats, text: i18n("Ayu.CategoryChats", lang), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .chats, settingName: .channelBottomButton, text: i18n("Extera.Chat.ChannelBottomButton", lang), value: channelBottomButtonTitle(ExteraChatSettings.shared.effectiveChannelBottomButton, lang: lang), enabled: true))
    appendSettingsGroup(&entries, id: id, section: .chats, setting: .widePosts, text: i18n("Extera.WidePosts", lang), children: [
        (.wideFeedPosts, ExteraFeedSettings.shared.widePosts, i18n("Extera.ChannelFeed", lang)),
        (.wideChannelPosts, settings.wideChannelPosts, i18n("Extera.Channels", lang))
    ], state: state)
    let aiConfiguration = ExteraAISettings.shared.configuration
    appendSettingsGroup(&entries, id: id, section: .chats, setting: .aiFeaturesGroup, text: i18n("Extera.AIFeatures", lang), children: [
        (.aiEditor, aiConfiguration.showEditor, i18n("Extera.AIFeatures.Editor", lang)),
        (.aiSummaries, aiConfiguration.showSummaries, i18n("Extera.AIFeatures.Summaries", lang)),
        (.aiInstantViewSummaries, aiConfiguration.showInstantViewSummaries, i18n("Extera.SummarizeInstantView", lang))
    ], state: state)
    appendSettingsGroup(&entries, id: id, section: .chats, setting: .transitionsGroup, text: i18n("Extera.QuickTransitions", lang), children: [
        (.quickTransitions, !settings.disableScrollToNextChannel, i18n("Extera.Channels", lang)),
        (.quickTransitionsTopics, !settings.disableScrollToNextTopic, i18n("Extera.Topics", lang))
    ], state: state)
    entries.append(.toggle(id: id.count, section: .chats, settingName: .disableGreetingSticker, value: ExteraSettings.shared.disableGreetingSticker, text: i18n("Extera.DisableGreetingSticker", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .hideKeyboardOnScroll, value: ExteraChatSettings.shared.hideKeyboardOnScroll, text: i18n("Extera.HideKeyboardOnScroll", lang), enabled: true))
    entries.append(.toggleSubtitle(id: id.count, section: .chats, settingName: .quickAdminShortcuts, value: ExteraAdminSettings.shared.quickAdminShortcuts, text: i18n("Extera.Admin.QuickShortcuts", lang), subtitle: i18n("Extera.Admin.QuickShortcutsInfo", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .commaAfterMention, value: ExteraChatSettings.shared.addCommaAfterMention, text: i18n("Settings.CommaAfterMention", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .hideSendAsPeer, value: settings.disableSendAsButton, text: i18n("Extera.HideSendAsPeer", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .chats, text: i18n("Extera.HideSendAsPeerInfo", lang)))

    entries.append(.header(id: id.count, section: .messages, text: i18n("Extera.Messages", lang), badge: nil))
    entries.append(.settingsPreview(id: id.count, section: .messages, kind: .message(SGMessagePreviewConfiguration(author: i18n("Extera.Preview.Author", lang), text: i18n("Extera.Preview.Message", lang), timeText: "12:34", editedText: strings.Conversation_MessageEditedLabel, removeTail: ExteraMessageSettings.shared.removeMessageTail, editedIcon: ExteraSettings.shared.replaceEditedWithIcon, onlineDot: ExteraMessageSettings.shared.showOnlineStatus, showForwardCount: ExteraMessageSettings.shared.showForwardsCount, forwardCount: 67)), sliderSetting: nil, selectionSetting: nil))
    entries.append(.toggle(id: id.count, section: .messages, settingName: .removeMessageTail, value: ExteraMessageSettings.shared.removeMessageTail, text: i18n("Extera.RemoveMessageTail", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messages, settingName: .replaceEditedWithIcon, value: ExteraSettings.shared.replaceEditedWithIcon, text: i18n("Extera.ReplaceEditedWithIcon", lang, strings.Conversation_MessageEditedLabel), enabled: true))
    entries.append(.toggle(id: id.count, section: .messages, settingName: .showForwardsCount, value: ExteraMessageSettings.shared.showForwardsCount, text: i18n("Extera.ShowForwardsCount", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messages, settingName: .showOnlineStatus, value: ExteraMessageSettings.shared.showOnlineStatus, text: i18n("Extera.ShowOnlineStatus", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messages, settingName: .hideShareButton, value: ExteraSettings.shared.hideShareButton, text: i18n("Extera.HideSideShareButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messages, settingName: .showPollResultsBeforeVoting, value: ExteraMessageSettings.shared.showPollResultsBeforeVoting, text: i18n("Extera.ShowPollResultsBeforeVoting", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messages, settingName: .hideSponsoredMessages, value: settings.hideSponsoredMessages, text: i18n("Settings.HideSponsoredMessages", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messages, settingName: .recordingButton, value: !settings.hideRecordingButton, text: i18n("Settings.RecordingButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .messages, settingName: .snapDeletionEffect, value: !settings.disableSnapDeletionEffect, text: i18n("Settings.SnapDeletionEffect", lang), enabled: true))
    entries.append(.header(id: id.count, section: .inlineCalculator, text: i18n("Extera.InlineCalculator", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .inlineCalculator, settingName: .inlineResults, value: ExteraMathSettings.shared.inlineResults, text: i18n("Extera.InlineResults", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .inlineCalculator, settingName: .inlineMathResult, value: ExteraMathSettings.shared.inlineMathResult, text: i18n("Extera.InlineMathResult", lang), enabled: ExteraMathSettings.shared.inlineResults))
    let calculatorEnabled = ExteraMathSettings.shared.inlineResults && ExteraMathSettings.shared.inlineMathResult
    entries.append(.toggle(id: id.count, section: .inlineCalculator, settingName: .inlineDigitGrouping, value: ExteraMathSettings.shared.inlineDigitGrouping, text: i18n("Extera.InlineDigitGrouping", lang), enabled: calculatorEnabled))
    entries.append(.oneFromManySelector(id: id.count, section: .inlineCalculator, settingName: .inlineAngleUnit, text: i18n("Extera.InlineAngleUnit", lang), value: i18n(ExteraMathSettings.shared.inlineAngleUnit == .degrees ? "Extera.AngleUnit.Degrees" : "Extera.AngleUnit.Radians", lang), enabled: calculatorEnabled))
    entries.append(.notice(id: id.count, section: .inlineCalculator, text: i18n("Extera.InlineCalculatorInfo", lang)))
    entries.append(.toggle(id: id.count, section: .inlineCalculator, settingName: .inlineUnits, value: ExteraMathSettings.shared.inlineUnits, text: i18n("Extera.InlineUnits", lang), enabled: ExteraMathSettings.shared.inlineResults))
    entries.append(.toggle(id: id.count, section: .inlineCalculator, settingName: .inlineCurrencies, value: ExteraMathSettings.shared.inlineCurrencies, text: i18n("Extera.InlineCurrencies", lang), enabled: ExteraMathSettings.shared.inlineResults))
    entries.append(.toggle(id: id.count, section: .inlineCalculator, settingName: .inlineTimeZones, value: ExteraMathSettings.shared.inlineTimeZones, text: i18n("Extera.InlineTimeZones", lang), enabled: ExteraMathSettings.shared.inlineResults))
    entries.append(.toggle(id: id.count, section: .inlineCalculator, settingName: .inlineImperial, value: ExteraMathSettings.shared.inlineImperial, text: i18n("Extera.InlineImperial", lang), enabled: ExteraMathSettings.shared.inlineResults && ExteraMathSettings.shared.inlineUnits))
    entries.append(.oneFromManySelector(id: id.count, section: .inlineCalculator, settingName: .inlineTargetCurrency, text: i18n("Extera.InlineTargetCurrency", lang), value: ExteraMathSettings.shared.inlineTargetCurrency, enabled: ExteraMathSettings.shared.inlineResults && ExteraMathSettings.shared.inlineCurrencies))

    entries.append(.header(id: id.count, section: .swipeActions, text: i18n("Extera.SwipeActions", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .swipeActions, settingName: .swipeToReplyIncoming, value: ExteraChatSettings.shared.swipeToReplyIncoming, text: i18n("Extera.SwipeToReplyIncoming", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .swipeActions, settingName: .swipeToReplyOutgoing, value: ExteraChatSettings.shared.swipeToReplyOutgoing, text: i18n("Extera.SwipeToReplyOutgoing", lang), enabled: true))

    entries.append(.header(id: id.count, section: .stickers, text: i18n("Extera.StickersAndEmoji", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .stickers, settingName: .forceEmojiTab, value: settings.forceEmojiTab, text: i18n("Settings.ForceEmojiTab", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .stickers, settingName: .defaultEmojisFirst, value: settings.defaultEmojisFirst, text: i18n("Settings.DefaultEmojisFirst", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .stickers, text: i18n("Settings.DefaultEmojisFirst.Notice", lang)))

    entries.append(.header(id: id.count, section: .media, text: i18n("Extera.CategoryMedia", lang), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .media, settingName: .doubleTapSeekDuration, text: i18n("Extera.DoubleTapSeekDuration", lang), value: i18n("Extera.SeekSeconds", lang, ExteraMediaSettings.shared.doubleTapSeekDuration), enabled: true))
    entries.append(.toggle(id: id.count, section: .media, settingName: .preferOriginalQuality, value: ExteraMediaSettings.shared.preferOriginalQuality, text: i18n("Extera.PreferOriginalQuality", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .media, settingName: .unmuteWithVolumeButtons, value: ExteraMediaSettings.shared.unmuteWithVolumeButtons, text: i18n("Extera.UnmuteWithVolumeButtons", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .media, text: i18n("Extera.UnmuteWithVolumeButtonsInfo", lang)))
    appendSettingsGroup(&entries, id: id, section: .media, setting: .pauseGroup, text: i18n("Extera.PauseOnMinimize", lang), children: [
        (.pauseOnMinimizeVideo, ExteraMediaSettings.shared.pauseOnMinimizeVideo, i18n("Extera.PauseOnMinimizeVideo", lang)),
        (.pauseOnMinimizeVoice, ExteraMediaSettings.shared.pauseOnMinimizeVoice, i18n("Extera.PauseOnMinimizeVoice", lang)),
        (.pauseOnMinimizeRound, ExteraMediaSettings.shared.pauseOnMinimizeRound, i18n("Extera.PauseOnMinimizeRound", lang))
    ], state: state)
    entries.append(.toggle(id: id.count, section: .media, settingName: .lyricsInPlayer, value: settings.lyricsInPlayer, text: i18n("Settings.LyricsInPlayer", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .media, settingName: .lyricsSource, text: i18n("Extera.LyricsSource", lang), value: i18n("Extera.LyricsSource.\(ExteraPlayerSettings.shared.lyricsSource.rawValue)", lang), enabled: settings.lyricsInPlayer))
    entries.append(.oneFromManySelector(id: id.count, section: .media, settingName: .lyricsDisplayMode, text: i18n("Extera.LyricsDisplayMode", lang), value: i18n("Extera.LyricsMode.\(ExteraPlayerSettings.shared.lyricsDisplayMode.rawValue)", lang), enabled: settings.lyricsInPlayer))
    entries.append(.toggle(id: id.count, section: .media, settingName: .preferEmbeddedLyrics, value: ExteraPlayerSettings.shared.preferEmbeddedLyrics, text: i18n("Extera.PreferEmbeddedLyrics", lang), enabled: settings.lyricsInPlayer))
    entries.append(.toggle(id: id.count, section: .media, settingName: .lyricsAutoScroll, value: ExteraPlayerSettings.shared.lyricsAutoScroll, text: i18n("Extera.LyricsAutoScroll", lang), enabled: settings.lyricsInPlayer))
    entries.append(.toggle(id: id.count, section: .media, settingName: .lyricsTapToSeek, value: ExteraPlayerSettings.shared.lyricsTapToSeek, text: i18n("Extera.LyricsTapToSeek", lang), enabled: settings.lyricsInPlayer))
    entries.append(.oneFromManySelector(id: id.count, section: .media, settingName: .lyricsOffset, text: i18n("Extera.LyricsOffset", lang), value: "\(ExteraPlayerSettings.shared.lyricsOffsetMilliseconds) ms", enabled: settings.lyricsInPlayer))
    entries.append(.toggle(id: id.count, section: .media, settingName: .swipeForVideoPIP, value: settings.videoPIPSwipeDirection != SGSimpleSettings.VideoPIPSwipeDirection.none.rawValue, text: i18n("Settings.swipeForVideoPIP", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .media, text: i18n("Settings.swipeForVideoPIP.Notice", lang)))

    entries.append(.header(id: id.count, section: .camera, text: i18n("Extera.Camera", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .camera, settingName: .hideCameraTile, value: settings.disableGalleryCamera, text: i18n("Extera.HideCameraTile", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .camera, settingName: .cameraTilePreview, value: !settings.disableGalleryCameraPreview, text: i18n("Settings.GalleryCameraPreview", lang), enabled: !settings.disableGalleryCamera))
    entries.append(.toggle(id: id.count, section: .camera, settingName: .rememberLastUsedCamera, value: ExteraMediaSettings.shared.rememberLastUsedCamera, text: i18n("Extera.RememberLastUsedCamera", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .camera, settingName: .zoomSlider, value: ExteraMediaSettings.shared.zoomSlider, text: i18n("Extera.ZoomSlider", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .camera, settingName: .staticZoom, value: ExteraMediaSettings.shared.staticZoom, text: i18n("Extera.StaticZoom", lang), enabled: true))
    entries.append(.oneFromManySelector(id: id.count, section: .camera, settingName: .videoMessagesCamera, text: i18n("Extera.VideoMessagesCamera", lang), value: i18n(cameraChoiceKey(ExteraMediaSettings.shared.videoMessagesCamera), lang), enabled: !ExteraMediaSettings.shared.rememberLastUsedCamera))

    entries.append(.header(id: id.count, section: .speechRecognition, text: i18n("Extera.SpeechRecognition", lang), badge: nil))
    entries.append(.oneFromManySelector(id: id.count, section: .speechRecognition, settingName: .transcriptionBackend, text: i18n("Extera.TranscriptionBackend", lang), value: ExteraVoskSettings.shared.isSelected ? "Vosk" : i18n(settings.transcriptionBackendEnum == .apple ? "Extera.TranscriptionBackend.Apple" : "Extera.TranscriptionBackend.Default", lang), enabled: true))
    entries.append(.disclosure(id: id.count, section: .speechRecognition, link: .speechRecognition, text: i18n("Extera.SpeechLanguagesAndModels", lang)))
    entries.append(.toggle(id: id.count, section: .speechRecognition, settingName: .appleSpeechOnDeviceOnly, value: ExteraTranslationSettings.shared.appleSpeechOnDeviceOnly, text: i18n("Extera.SpeechOnDeviceOnly", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .speechRecognition, text: i18n("Extera.SpeechRecognitionInfo", lang)))

    entries.append(.header(id: id.count, section: .messageMenu, text: i18n("Extera.MessageMenu", lang), badge: nil))
    appendSettingsGroup(&entries, id: id, section: .messageMenu, setting: .menuGroup, text: i18n("Extera.MessageMenu", lang), children: [
        (.showCopyPhotoButton, ExteraMenuSettings.shared.showCopyPhotoButton, i18n("Extera.MenuCopyPhoto", lang)),
        (.showSaveMessageButton, ExteraMenuSettings.shared.showSaveMessageButton, i18n("Extera.MenuSaveMessage", lang)),
        (.showRepeatMessageButton, ExteraMenuSettings.shared.showRepeatMessageButton, i18n("Extera.MenuRepeatMessage", lang)),
        (.showClearButton, ExteraMenuSettings.shared.showClearButton, i18n("Extera.MenuClear", lang)),
        (.showHistoryButton, ExteraMenuSettings.shared.showHistoryButton, i18n("Extera.MenuHistory", lang)),
        (.showReportButton, ExteraMenuSettings.shared.showReportButton, i18n("Extera.MenuReport", lang)),
        (.showDetailsButton, ExteraMenuSettings.shared.showDetailsButton, i18n("Extera.MenuDetails", lang))
    ], state: state)
    entries.append(.toggle(id: id.count, section: .messageMenu, settingName: .groupMessageMenu, value: ExteraMenuSettings.shared.groupMessageMenu, text: i18n("Extera.GroupMessageMenu", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .messageMenu, text: i18n("Extera.GroupMessageMenuInfo", lang)))
    entries.append(.toggle(id: id.count, section: .messageMenu, settingName: .showMessageImageExportButton, value: ExteraMenuSettings.shared.showMessageImageExportButton, text: i18n("Extera.MenuExportMessageImage", lang), enabled: true))

    entries.append(.header(id: id.count, section: .sending, text: strings.NetworkUsageSettings_MediaImageDataSection, badge: nil))
    entries.append(.toggle(id: id.count, section: .sending, settingName: .sendLargePhotos, value: settings.sendLargePhotos, text: i18n("Settings.Photo.SendLarge", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .sending, text: i18n("Settings.Photo.SendLarge.Notice", lang)))
    entries.append(.header(id: id.count, section: .sending, text: i18n("Extera.OutgoingPhotoQuality", lang), badge: nil))
    entries.append(.percentageSlider(id: id.count, section: .sending, settingName: .outgoingPhotoQuality, value: settings.outgoingPhotoQuality))
    entries.append(.toggle(id: id.count, section: .sending, settingName: .sendWithReturnKey, value: settings.sendWithReturnKey, text: i18n("Settings.SendWithReturnKey", lang), enabled: true))

    entries.append(.header(id: id.count, section: .backup, text: i18n("Extera.SettingsBackup", lang), badge: nil))
    entries.append(.disclosure(id: id.count, section: .backup, link: .settingsBackup, text: i18n("Extera.SettingsBackup", lang)))

    entries.append(.header(id: id.count, section: .browser, text: i18n("Extera.Browser", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .browser, settingName: .adBlockingEnabled, value: ExteraBrowserSettings.shared.adBlockingEnabled, text: i18n("Extera.AdBlockingEnabled", lang), enabled: true))
    entries.append(.disclosure(id: id.count, section: .browser, link: .browserExceptions, text: i18n("Extera.BrowserExceptions", lang)))
    entries.append(.disclosure(id: id.count, section: .browser, link: .browserFilters, text: i18n("Extera.BrowserFilters", lang)))
    entries.append(.notice(id: id.count, section: .browser, text: i18n("Extera.BrowserExceptionsInfo", lang)))

    entries.append(.header(id: id.count, section: .other, text: "AyuGram", badge: nil))
    entries.append(.disclosure(id: id.count, section: .other, link: .categoryMedia, text: i18n("Extera.CategoryMedia", lang)))
    entries.append(.disclosure(id: id.count, section: .other, link: .channelFeed, text: i18n("Extera.ChannelFeed", lang)))
    entries.append(.disclosure(id: id.count, section: .other, link: .dataPills, text: i18n("Extera.DataPills", lang)))
    entries.append(.disclosure(id: id.count, section: .other, link: .cloudExport, text: i18n("Extera.Takeout.Title", lang)))
    entries.append(.notice(id: id.count, section: .other, text: i18n("Extera.ModifiedVersionNotice", lang)))
    entries.append(.disclosure(id: id.count, section: .other, link: .upstreamSource, text: i18n("Extera.UpstreamSource", lang)))
    entries.append(.toggle(id: id.count, section: .other, settingName: .hideAccountInNotifications, value: settings.hideAccountInNotifications, text: i18n("Settings.HideAccountInNotifications", lang), enabled: true))
    entries.append(.header(id: id.count, section: .profiles, text: i18n("Settings.Profiles.Header", lang), badge: nil))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showRegDate, value: settings.showRegDate, text: i18n("Settings.ShowRegDate", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Extera.RegDateInfo", lang)))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .showCreationDate, value: settings.showCreationDate, text: i18n("Settings.ShowCreationDate", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Settings.ShowCreationDate.Notice", lang)))
    entries.append(.toggle(id: id.count, section: .profiles, settingName: .confirmCalls, value: settings.confirmCalls, text: i18n("Settings.CallConfirmation", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .profiles, text: i18n("Settings.CallConfirmation.Notice", lang)))

    entries.append(.header(id: id.count, section: .stories, text: strings.AutoDownloadSettings_Stories, badge: nil))
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

public func sgSettingsController(context: AccountContext, category: SGSettingsCategory? = nil, showOverview: Bool = true) -> ViewController {
    if category == .other && showOverview {
        return exteraOtherSettingsController(context: context, backupAction: exteraOtherBackupAction(context: context), additionalSettings: {
            return sgSettingsController(context: context, category: .other, showOverview: false)
        })
    }
    if category == nil && showOverview {
        return exteraSettingsOverviewController(context: context, ayu: false)
    }
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?
    var presentOneFromManyImpl: ((SGOneFromManySetting, [SGOneFromManyOption]) -> Void)?
    var askForRestart: (() -> Void)?
    let updateDownloadMode: (SGSimpleSettings.DownloadSpeedBoostValues) -> Void = { value in
        guard SGSimpleSettings.shared.downloadSpeedBoost != value.rawValue else { return }
        SGSimpleSettings.shared.downloadSpeedBoost = value.rawValue
        let _ = updateNetworkSettingsInteractively(postbox: context.account.postbox, network: context.account.network, { settings in
            var settings = settings
            settings.useExperimentalDownload = value != .none
            return settings
        }).start(completed: {
            Queue.mainQueue().async { askForRestart?() }
        })
    }
    var editBrowserExceptionsImpl: (() -> Void)?

    let initialState = SGSettingsControllerState()
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((SGSettingsControllerState) -> SGSettingsControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let simplePromise = ValuePromise(true, ignoreRepeated: false)

    let arguments = SGItemListArguments<SGBoolSetting, SGSliderSetting, SGOneFromManySetting, SGDisclosureLink, AnyHashable>(
        context: context,
        visualStyle: .extera,
        setBoolValue: { setting, value in
        let settings = SGSimpleSettings.shared
        switch setting {
        case .aiFeaturesGroup, .aiEditor, .aiSummaries, .aiInstantViewSummaries:
            do {
                try ExteraAISettings.shared.update { configuration in
                    if setting == .aiFeaturesGroup || setting == .aiEditor { configuration.showEditor = value }
                    if setting == .aiFeaturesGroup || setting == .aiSummaries { configuration.showSummaries = value }
                    if setting == .aiFeaturesGroup || setting == .aiInstantViewSummaries { configuration.showInstantViewSummaries = value }
                }
            } catch {
                let data = context.sharedContext.currentPresentationData.with { $0 }
                presentControllerImpl?(UndoOverlayController(presentationData: data, content: .info(title: nil, text: error.localizedDescription, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in true }), nil)
            }
        case .repliesGroup:
            ExteraSettings.performBatchUpdates {
                ExteraMessageSettings.shared.replyColors = value
                ExteraMessageSettings.shared.replyEmoji = value
                ExteraMessageSettings.shared.replyBackground = value
            }
        case .reactionsGroup:
            ExteraSettings.performBatchUpdates {
                ExteraMessageSettings.shared.hideReactionsInChannels = value
                ExteraMessageSettings.shared.hideReactionsInGroups = value
                ExteraMessageSettings.shared.hideReactionsInPrivateChats = value
            }
        case .transitionsGroup:
            settings.disableScrollToNextChannel = !value
            settings.disableScrollToNextTopic = !value
        case .pauseGroup:
            ExteraSettings.performBatchUpdates {
                ExteraMediaSettings.shared.pauseOnMinimizeVideo = value
                ExteraMediaSettings.shared.pauseOnMinimizeVoice = value
                ExteraMediaSettings.shared.pauseOnMinimizeRound = value
            }
        case .menuGroup:
            ExteraSettings.performBatchUpdates {
                ExteraMenuSettings.shared.showCopyPhotoButton = value
                ExteraMenuSettings.shared.showSaveMessageButton = value
                ExteraMenuSettings.shared.showRepeatMessageButton = value
                ExteraMenuSettings.shared.showClearButton = value
                ExteraMenuSettings.shared.showHistoryButton = value
                ExteraMenuSettings.shared.showReportButton = value
                ExteraMenuSettings.shared.showDetailsButton = value
            }
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
            // The example under the toggle is rebuilt from the new value.
            simplePromise.set(true)
        case .hideActionBarStatus:
            ExteraSettings.shared.set(.hideActionBarStatus, value)
        case .hideFloatingButton:
            ExteraSettings.shared.set(.hideFloatingButton, value)
        case .hideDialogsSearchBar:
            ExteraSettings.shared.set(.hideDialogsSearchBar, value)
        case .senderMiniAvatars:
            ExteraSettings.shared.set(.senderMiniAvatars, value)
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
            ExteraSettings.performBatchUpdates {
                settings.wideChannelPosts = value
                ExteraFeedSettings.shared.widePosts = value
            }
        case .wideFeedPosts:
            ExteraFeedSettings.shared.widePosts = value
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
            SGSimpleSettings.shared.videoPIPSwipeDirection = value ? SGSimpleSettings.VideoPIPSwipeDirection.up.rawValue : SGSimpleSettings.VideoPIPSwipeDirection.none.rawValue
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
            ExteraChatSettings.shared.addCommaAfterMention = value
        case .hideKeyboardOnScroll:
            ExteraChatSettings.shared.hideKeyboardOnScroll = value
        case .quickAdminShortcuts:
            ExteraAdminSettings.shared.quickAdminShortcuts = value
        case .swipeToReplyIncoming:
            ExteraChatSettings.shared.swipeToReplyIncoming = value
        case .swipeToReplyOutgoing:
            ExteraChatSettings.shared.swipeToReplyOutgoing = value
        case .hideReactionsInChannels:
            ExteraMessageSettings.shared.hideReactionsInChannels = value
        case .hideReactionsInGroups:
            ExteraMessageSettings.shared.hideReactionsInGroups = value
        case .hideReactionsInPrivateChats:
            ExteraMessageSettings.shared.hideReactionsInPrivateChats = value
        case .removeMessageTail:
            ExteraMessageSettings.shared.removeMessageTail = value
        case .replyColors:
            ExteraMessageSettings.shared.replyColors = value
        case .replyEmoji:
            ExteraMessageSettings.shared.replyEmoji = value
        case .replyBackground:
            ExteraMessageSettings.shared.replyBackground = value
        case .showForwardsCount:
            ExteraMessageSettings.shared.showForwardsCount = value
        case .showOnlineStatus:
            ExteraMessageSettings.shared.showOnlineStatus = value
        case .showPollResultsBeforeVoting:
            ExteraMessageSettings.shared.showPollResultsBeforeVoting = value
        case .preferOriginalQuality:
            ExteraMediaSettings.shared.preferOriginalQuality = value
        case .pauseOnMinimizeVideo:
            ExteraMediaSettings.shared.pauseOnMinimizeVideo = value
        case .pauseOnMinimizeVoice:
            ExteraMediaSettings.shared.pauseOnMinimizeVoice = value
        case .pauseOnMinimizeRound:
            ExteraMediaSettings.shared.pauseOnMinimizeRound = value
        case .rememberLastUsedCamera:
            ExteraMediaSettings.shared.rememberLastUsedCamera = value
        case .zoomSlider:
            ExteraMediaSettings.shared.zoomSlider = value
        case .staticZoom:
            ExteraMediaSettings.shared.staticZoom = value
        case .unmuteWithVolumeButtons:
            ExteraMediaSettings.shared.unmuteWithVolumeButtons = value
        case .appleSpeechOnDeviceOnly:
            ExteraTranslationSettings.shared.appleSpeechOnDeviceOnly = value
        case .showCopyPhotoButton:
            ExteraMenuSettings.shared.showCopyPhotoButton = value
        case .showSaveMessageButton:
            ExteraMenuSettings.shared.showSaveMessageButton = value
        case .showRepeatMessageButton:
            ExteraMenuSettings.shared.showRepeatMessageButton = value
        case .showClearButton:
            ExteraMenuSettings.shared.showClearButton = value
        case .showHistoryButton:
            ExteraMenuSettings.shared.showHistoryButton = value
        case .showReportButton:
            ExteraMenuSettings.shared.showReportButton = value
        case .showDetailsButton:
            ExteraMenuSettings.shared.showDetailsButton = value
        case .showMessageImageExportButton:
            ExteraMenuSettings.shared.showMessageImageExportButton = value
        case .groupMessageMenu:
            ExteraMenuSettings.shared.groupMessageMenu = value
        case .inlineResults:
            ExteraMathSettings.shared.inlineResults = value
        case .inlineMathResult:
            ExteraMathSettings.shared.inlineMathResult = value
        case .inlineDigitGrouping:
            ExteraMathSettings.shared.inlineDigitGrouping = value
        case .adBlockingEnabled:
            ExteraBrowserSettings.shared.adBlockingEnabled = value
        case .unlimitedRecentStickers:
            ExteraStickerSettings.shared.unlimitedRecentStickers = value
        case .inlineUnits:
            ExteraMathSettings.shared.inlineUnits = value
        case .inlineCurrencies:
            ExteraMathSettings.shared.inlineCurrencies = value
        case .inlineTimeZones:
            ExteraMathSettings.shared.inlineTimeZones = value
        case .inlineImperial:
            ExteraMathSettings.shared.inlineImperial = value
        case .preferEmbeddedLyrics:
            ExteraPlayerSettings.shared.preferEmbeddedLyrics = value
        case .lyricsAutoScroll:
            ExteraPlayerSettings.shared.lyricsAutoScroll = value
        case .lyricsTapToSeek:
            ExteraPlayerSettings.shared.lyricsTapToSeek = value
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
        simplePromise.set(true)
    }, updateSliderValue: { setting, value in
        switch setting {
        case .stickerRawSize:
            let size = max(4, min(20, Int(value)))
            if ExteraStickerSettings.shared.size != size {
                ExteraStickerSettings.shared.size = size
                simplePromise.set(true)
            }
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
        case .outgoingPhotoQuality:
            SGSimpleSettings.shared.outgoingPhotoQuality = value
            simplePromise.set(true)
        }
    }, setOneFromManyValue: { setting in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        var options: [SGOneFromManyOption] = []
        switch setting {
        case .channelBottomButton:
            for value in ExteraChatSettings.ChannelBottomButton.allCases {
                options.append(SGOneFromManyOption(title: channelBottomButtonTitle(value, lang: lang), isSelected: ExteraChatSettings.shared.effectiveChannelBottomButton == value, action: {
                    ExteraChatSettings.shared.channelBottomButton = value
                    SGSimpleSettings.shared.hideChannelBottomButton = false
                    simplePromise.set(true)
                }))
            }
        case .inlineTargetCurrency:
            let codes = ["auto", "USD", "EUR", "RUB", "GBP", "CNY", "JPY", "INR", "TRY", "UAH", "KZT", "BYN", "CHF", "CAD", "AUD", "BRL", "KRW", "AED", "BTC", "ETH", "SOL", "USDT", "GRAM"]
            for code in codes {
                options.append(SGOneFromManyOption(title: code == "auto" ? i18n("Extera.CurrencyAutomatic", lang) : code, isSelected: ExteraMathSettings.shared.inlineTargetCurrency == code, action: {
                    ExteraMathSettings.shared.inlineTargetCurrency = code
                    simplePromise.set(true)
                }))
            }
        case .lyricsSource:
            for source in ExteraPlayerSettings.LyricsSource.allCases {
                options.append(SGOneFromManyOption(title: i18n("Extera.LyricsSource.\(source.rawValue)", lang), isSelected: ExteraPlayerSettings.shared.lyricsSource == source, action: {
                    ExteraPlayerSettings.shared.lyricsSource = source
                    simplePromise.set(true)
                }))
            }
        case .lyricsDisplayMode:
            for mode in ExteraPlayerSettings.LyricsDisplayMode.allCases {
                options.append(SGOneFromManyOption(title: i18n("Extera.LyricsMode.\(mode.rawValue)", lang), isSelected: ExteraPlayerSettings.shared.lyricsDisplayMode == mode, action: {
                    ExteraPlayerSettings.shared.lyricsDisplayMode = mode
                    simplePromise.set(true)
                }))
            }
        case .lyricsOffset:
            let prompt = promptController(context: context, text: i18n("Extera.LyricsOffsetPrompt", lang), value: "\(ExteraPlayerSettings.shared.lyricsOffsetMilliseconds)", placeholder: "0", apply: { text in
                if let text, let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    ExteraPlayerSettings.shared.lyricsOffsetMilliseconds = value
                    simplePromise.set(true)
                }
            })
            presentControllerImpl?(prompt, nil)
            return
        case .stickerSize:
            for value in 4 ... 20 {
                let percentage = Int((Double(value) / 12.0 * 100.0).rounded())
                options.append(SGOneFromManyOption(title: "\(percentage)%" + (value == 12 ? " · " + i18n("Extera.StickerSizeDefault", lang) : ""), isSelected: ExteraStickerSettings.shared.size == value, action: {
                    ExteraStickerSettings.shared.size = value
                    simplePromise.set(true)
                }))
            }
        case .stickerTimeMode:
            for mode in ExteraStickerSettings.TimeMode.allCases {
                options.append(SGOneFromManyOption(title: i18n("Extera.StickerTimeMode.\(mode.rawValue)", lang), isSelected: ExteraStickerSettings.shared.timeMode == mode, action: {
                    ExteraStickerSettings.shared.timeMode = mode
                    simplePromise.set(true)
                }))
            }
        case .stickerShape:
            for shape in ExteraStickerSettings.Shape.allCases {
                options.append(SGOneFromManyOption(title: i18n("Extera.StickerShape.\(shape.rawValue)", lang), isSelected: ExteraStickerSettings.shared.shape == shape, action: {
                    ExteraStickerSettings.shared.shape = shape
                    simplePromise.set(true)
                }))
            }
        case .inlineAngleUnit:
            for value in [ExteraMathSettings.AngleUnit.degrees, .radians] {
                options.append(SGOneFromManyOption(title: i18n(value == .degrees ? "Extera.AngleUnit.Degrees" : "Extera.AngleUnit.Radians", lang), isSelected: ExteraMathSettings.shared.inlineAngleUnit == value, action: {
                    ExteraMathSettings.shared.inlineAngleUnit = value
                    simplePromise.set(true)
                }))
            }
        case .defaultProfileTab:
            for value in ExteraGeneralSettings.DefaultProfileTab.allCases {
                options.append(SGOneFromManyOption(title: defaultProfileTabTitle(value, lang: lang), isSelected: ExteraGeneralSettings.shared.defaultProfileTab == value, action: {
                    ExteraGeneralSettings.shared.defaultProfileTab = value
                    simplePromise.set(true)
                }))
            }
        case .doubleTapIncoming, .doubleTapOutgoing:
            let incoming = setting == .doubleTapIncoming
            let current = incoming ? ExteraChatSettings.shared.doubleTapIncoming : ExteraChatSettings.shared.doubleTapOutgoing
            for value in ExteraChatSettings.DoubleTapAction.allCases {
                if incoming && (value == .edit || value == .inherit) {
                    continue
                }
                if !incoming && value == .read {
                    continue
                }
                options.append(SGOneFromManyOption(title: doubleTapActionTitle(value, lang: lang), isSelected: current == value, action: {
                    if incoming {
                        ExteraChatSettings.shared.doubleTapIncoming = value
                    } else {
                        ExteraChatSettings.shared.doubleTapOutgoing = value
                    }
                    simplePromise.set(true)
                }))
            }
        case .doubleTapSeekDuration:
            for value in ExteraMediaSettings.doubleTapSeekDurations {
                options.append(SGOneFromManyOption(title: i18n("Extera.SeekSeconds", lang, value), isSelected: ExteraMediaSettings.shared.doubleTapSeekDuration == value, action: {
                    ExteraMediaSettings.shared.doubleTapSeekDuration = value
                    simplePromise.set(true)
                }))
            }
        case .videoMessagesCamera:
            for value in [0, 1, 2] {
                options.append(SGOneFromManyOption(title: i18n(cameraChoiceKey(value), lang), isSelected: ExteraMediaSettings.shared.videoMessagesCamera == value, action: {
                    ExteraMediaSettings.shared.videoMessagesCamera = value
                    simplePromise.set(true)
                }))
            }
        case .appleSpeechLocale:
            let current = ExteraTranslationSettings.shared.appleSpeechLocaleIdentifier
            var identifiers = SFSpeechRecognizer.supportedLocales().map { $0.identifier }
            if !current.isEmpty && !identifiers.contains(current) {
                identifiers.append(current)
            }
            identifiers.sort { speechLocaleTitle($0, lang: lang).localizedCaseInsensitiveCompare(speechLocaleTitle($1, lang: lang)) == .orderedAscending }
            for identifier in [""] + identifiers {
                options.append(SGOneFromManyOption(title: speechLocaleTitle(identifier, lang: lang), isSelected: current == identifier, action: {
                    ExteraSpeechSettings.shared.languageSelection = identifier.isEmpty ? .automatic : .locale(identifier)
                    simplePromise.set(true)
                }))
            }
        case .transcriptionBackend:
            for value in SGSimpleSettings.TranscriptionBackend.allCases {
                options.append(SGOneFromManyOption(title: i18n(value == .apple ? "Extera.TranscriptionBackend.Apple" : "Extera.TranscriptionBackend.Default", lang), isSelected: !ExteraVoskSettings.shared.isSelected && SGSimpleSettings.shared.transcriptionBackendEnum == value, action: {
                    ExteraVoskSettings.shared.isSelected = false
                    SGSimpleSettings.shared.transcriptionBackend = value.rawValue
                    simplePromise.set(true)
                }))
            }
            options.append(SGOneFromManyOption(title: "Vosk", isSelected: ExteraVoskSettings.shared.isSelected, action: {
                ExteraVoskSettings.shared.isSelected = true
                simplePromise.set(true)
                pushControllerImpl?(sgVoskRecognitionController(context: context))
            }))
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
                    updateDownloadMode(value)
                    simplePromise.set(true)
                }))
            }
        case .tabTitleStyle:
            for value in ExteraSettings.TabTitleStyle.allCases {
                options.append(SGOneFromManyOption(title: tabTitleStyleTitle(value, lang: lang), isSelected: ExteraSettings.shared.tabTitleStyle == value, action: {
                    ExteraSettings.shared.tabTitleStyle = value
                    simplePromise.set(true)
                }))
            }
        case .tabCounterMode:
            for value in ExteraSettings.TabCounterMode.allCases {
                options.append(SGOneFromManyOption(title: tabCounterModeTitle(value, lang: lang), isSelected: ExteraSettings.shared.tabCounterMode == value, action: {
                    ExteraSettings.shared.tabCounterMode = value
                    simplePromise.set(true)
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
        case .styleSettings:
            pushControllerImpl?(exteraStyleSettingsController(context: context))
        case .speechRecognition:
            if ExteraVoskSettings.shared.isSelected {
                pushControllerImpl?(sgVoskRecognitionController(context: context))
            } else {
                pushControllerImpl?(sgSpeechRecognitionController(context: context))
            }
        case .appIcon:
            pushControllerImpl?(exteraAppIconController(context: context))
        case .uiIconPacks:
            pushControllerImpl?(exteraUIIconPacksController(context: context))
        case .energySettings:
            pushControllerImpl?(exteraEnergySettingsController(context: context))
        case .readReceipts:
            pushControllerImpl?(ayuReadHistoryController(context: context))
        case .navigationSettings:
            pushControllerImpl?(exteraNavigationSettingsController(context: context))
        case .chatSettings:
            pushControllerImpl?(exteraChatAppearanceSettingsController(context: context))
        case .inlineResults:
            pushControllerImpl?(exteraInlineSettingsController(context: context))
        case .swipeActions:
            pushControllerImpl?(sgSettingsController(context: context, category: .swipeActions))
        case .categoryGeneral:
            pushControllerImpl?(sgSettingsController(context: context, category: .general))
        case .categoryAppearance:
            pushControllerImpl?(sgSettingsController(context: context, category: .appearance))
        case .categoryChats:
            pushControllerImpl?(sgSettingsController(context: context, category: .chats))
        case .categoryMedia:
            pushControllerImpl?(sgSettingsController(context: context, category: .media))
        case .categoryOther:
            pushControllerImpl?(sgSettingsController(context: context, category: .other))
        case .settingsBackup:
            pushControllerImpl?(exteraBackupController(context: context))
        case .browserExceptions:
            editBrowserExceptionsImpl?()
        case .browserFilters:
            pushControllerImpl?(exteraBrowserFiltersController(context: context))
        case .cloudExport:
            pushControllerImpl?(exteraTakeoutController(context: context))
        case .aiServices:
            pushControllerImpl?(exteraAISettingsController(context: context))
        case .channelFeed:
            pushControllerImpl?(exteraFeedController(context: context))
        case .dataPills:
            pushControllerImpl?(exteraPillSettingsController(context: context))
        case .upstreamSource:
            context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: "https://github.com/exteraSquad/exteraGram", forceExternal: true, presentationData: context.sharedContext.currentPresentationData.with { $0 }, navigationController: nil, dismissInput: {})
        }
    }, searchInput: { searchQuery in
        updateState { state in
            var updatedState = state
            updatedState.searchQuery = searchQuery
            return updatedState
        }
    }, setExpanded: { setting, expanded in
        updateState { state in
            var updatedState = state
            if expanded {
                updatedState.expandedGroups.insert(setting)
            } else {
                updatedState.expandedGroups.remove(setting)
            }
            return updatedState
        }
    }, setSegmentedValue: { setting, index in
        switch setting {
        case .downloadSpeedBoost:
            let modes = SGSimpleSettings.DownloadSpeedBoostValues.allCases
            guard modes.indices.contains(index) else { return }
            updateDownloadMode(modes[index])
        case .stickerShape:
            guard let shape = ExteraStickerSettings.Shape(rawValue: index) else { return }
            ExteraStickerSettings.shared.shape = shape
        default:
            return
        }
        simplePromise.set(true)
    })

    let sharedData = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings, ApplicationSpecificSharedDataKeys.experimentalUISettings, ApplicationSpecificSharedDataKeys.translationSettings])
    let signal = combineLatest(
        simplePromise.get(),
        statePromise.get(),
        context.sharedContext.presentationData,
        sharedData,
        context.engine.accountData.observeAvailableColorOptions(scope: .replies),
        context.engine.accountData.observeAvailableColorOptions(scope: .profile),
        context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId)),
        exteraSettingsChanges()
    )
    |> deliverOnMainQueue
    |> map { _, state, presentationData, sharedData, availableReplyColors, availableProfileColors, accountPeer, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
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
        let username: String?
        if let accountPeer, case let .user(user) = accountPeer {
            username = user.addressName
        } else {
            username = nil
        }
        let previewTitle = ExteraSettings.shared.chatListTitleText(firstName: firstName, lastName: lastName, chatsTitle: presentationData.strings.DialogList_Title, username: username)
        let appearance = exteraSettingsAppearance()
        let entries = SGControllerEntries(presentationData: presentationData, callListSettings: callListSettings, experimentalUISettings: experimentalUISettings, translationSettings: translationSettings, nameColors: nameColors, state: state, previewTitle: previewTitle, category: category).map {
            SGStyledItemListEntry(entry: $0, appearance: appearance)
        }
        let title = category.flatMap { i18n($0.titleKey, presentationData.strings.baseLanguageCode) } ?? "exteraGram"
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { _ in
        simplePromise.set(true)
    }
    editBrowserExceptionsImpl = { [weak controller] in
        guard let controller else { return }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        let alert = UIAlertController(title: i18n("Extera.BrowserExceptions", lang), message: i18n("Extera.BrowserExceptionsEditorInfo", lang), preferredStyle: .alert)
        alert.addTextField { field in
            field.text = ExteraBrowserSettings.shared.exceptionHosts.joined(separator: ", ")
            field.placeholder = "example.com, example.org"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Done, style: .default, handler: { [weak alert, weak controller] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            let inputs = text.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let hosts = inputs.compactMap(ExteraBrowserSettings.normalizedHost)
            guard hosts.count == inputs.count else {
                let error = UIAlertController(title: i18n("Extera.BrowserExceptions", lang), message: i18n("Extera.BrowserExceptionsInvalid", lang), preferredStyle: .alert)
                error.addAction(UIAlertAction(title: presentationData.strings.Common_OK, style: .default))
                controller?.present(error, animated: true)
                return
            }
            ExteraBrowserSettings.shared.exceptionHosts = hosts
            simplePromise.set(true)
        }))
        controller.present(alert, animated: true)
    }
    presentOneFromManyImpl = { [weak controller] setting, options in
        guard let controller else {
            return
        }
        if setting == .doubleTapIncoming || setting == .doubleTapOutgoing {
            let incoming = setting == .doubleTapIncoming
            let picker = exteraDoubleTapActionPicker(context: context, incoming: incoming, selected: ExteraChatSettings.shared.effectiveDoubleTapAction(incoming: incoming), selectedAction: { value in
                if incoming {
                    ExteraChatSettings.shared.doubleTapIncoming = value
                } else {
                    ExteraChatSettings.shared.doubleTapOutgoing = value
                }
                simplePromise.set(true)
            })
            controller.present(picker, animated: true)
        } else {
            sgPresentOneFromManySelector(controller: controller, setting: setting, presentationData: context.sharedContext.currentPresentationData.with { $0 }, options: options)
        }
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
