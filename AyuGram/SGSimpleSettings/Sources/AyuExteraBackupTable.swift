import Foundation
import AyuSettingsBackup

// MARK: AyuGram
// Which preferences go into a ".extera" settings backup. The "exteraconfig" group uses exteraGram for
// Android's names and value ranges, so a backup made on either platform applies on the other wherever
// the option exists on both. Preferences Android has no place for go into the iOS group, which it skips.
// The switches of the exteraGram settings screen that the account manager keeps, not a settings class.
// Whoever has an account context passes their current values and the way to store one.
public enum ExteraBackupAccountSwitch: String, CaseIterable {
    case showContactsTab
    case showCallsTab
    case foldersAtBottom
}

public extension ExteraSettings {
    // Switches whose name and meaning are the same on Android.
    private static let sharedSwitches: [Keys] = [
        .disableNumberRounding, .inAppVibration, .replaceEditedWithIcon, .hideShareButton, .disableGreetingSticker,
        .filterZalgo, .removeMessageTail, .addCommaAfterMention, .showForwardsCount, .hideReactionsInPrivateChats,
        .showResultsBeforeVoting, .disableMarkdown, .relativeLastSeen, .hideActionBarStatus, .hideDialogsSearchBar,
        .hideKeyboardOnScroll, .disableUnarchiveSwipe, .showOnlineStatus, .archiveOnPull, .pauseOnMinimizeVoice,
        .pauseOnMinimizeRound, .pauseOnMinimizeVideo, .senderMiniAvatars, .replyColors, .replyEmoji, .replyBackground,
        .preferOriginalQuality, .showClearButton, .showHistoryButton, .showDetailsButton, .singleCornerRadius,
        .inlineResults, .inlineMathResult, .inlineCurrencyRates, .inlineUnitConversion, .inlineTimeZones,
        .inlineDigitGrouping, .swipeActionsLoop, .swipeActionsReversed, .showSaveMessageButton, .enableAdBlock, .telegramAiSummaries, .telegramAiEditor
    ]

    func backupSchema(accountSwitches: [ExteraBackupAccountSwitch: Bool] = [:], setAccountSwitch: @escaping (ExteraBackupAccountSwitch, Bool) -> Void = { _, _ in }) -> ExteraBackupSchema {
        let ios = ExteraBackupDocument.iosConfig
        var entries: [ExteraBackupEntry] = []

        for key in ExteraSettings.sharedSwitches {
            entries.append(.bool(key.rawValue, get: { self.value(key) }, set: { self.set(key, $0) }))
        }
        entries.append(.bool("showRepeatMessageButton", get: { self.showRepeatButton }, set: { self.set(.showRepeatButton, $0) }))

        entries.append(.int("stickerShape", range: 0 ... 2, get: { self.stickerShape.rawValue }, set: { value in
            if let shape = StickerShape(rawValue: value) {
                self.stickerShape = shape
            }
        }))
        // Android: 0 app name, 1 username, 2 first name, 3 "Chats".
        entries.append(.int("titleText", range: 0 ... 3, get: {
            switch self.titleText {
            case .appName:
                return 0
            case .username:
                return 1
            case .firstName:
                return 2
            case .default:
                return 3
            }
        }, set: { value in
            switch value {
            case 0:
                self.titleText = .appName
            case 1:
                self.titleText = .username
            case 2:
                self.titleText = .firstName
            default:
                self.titleText = .default
            }
        }))
        // Android stores the position in 5 / 10 / 15 / 30 seconds.
        entries.append(.int("doubleTapSeekDuration", range: 0 ... ExteraSettings.doubleTapSeekDurationValues.count - 1, get: {
            return ExteraSettings.doubleTapSeekDurationValues.firstIndex(of: self.doubleTapSeekDuration)
        }, set: { value in
            self.doubleTapSeekDuration = ExteraSettings.doubleTapSeekDurationValues[value]
        }))
        entries.append(.int("doNotUseProxy", range: 0 ... 7, get: { self.doNotUseProxy.rawValue }, set: { value in
            self.doNotUseProxy = ProxyDisableConditions(rawValue: value)
        }))
        entries.append(.int("doubleTapAction", range: 0 ... 9, get: { self.doubleTapAction.rawValue }, accepts: { value in
            return DoubleTapAction(rawValue: value).map { DoubleTapAction.incomingCases.contains($0) } ?? false
        }, set: { value in
            if let action = DoubleTapAction(rawValue: value) {
                self.doubleTapAction = action
            }
        }))
        entries.append(.int("doubleTapActionOutOwner", range: 0 ... 9, get: { self.doubleTapActionOutgoing.rawValue }, set: { value in
            if let action = DoubleTapAction(rawValue: value) {
                self.doubleTapActionOutgoing = action
            }
        }))
        // Android: 0 front, 1 rear, 2 ask every time (not on iOS). "Last used" exists only on iOS, see below.
        entries.append(.int("videoMessagesCamera", range: 0 ... 1, get: {
            switch self.videoMessagesCamera {
            case .front:
                return 0
            case .back:
                return 1
            case .lastUsed:
                return nil
            }
        }, set: { value in
            self.videoMessagesCamera = value == 0 ? .front : .back
        }))
        // Android keeps any radius from 0 to 28; iOS offers steps of 4.
        entries.append(.float("avatarCorners", range: 0.0 ... 28.0, get: { Double(self.avatarCorners) }, stored: { value in
            return min(28.0, max(0.0, (value / 4.0).rounded() * 4.0))
        }, set: { value in
            self.avatarCorners = Int(value)
        }))
        // Android's list of swipe actions (its own rule for the text: ids of one or two digits); ids that are
        // not swipe actions are dropped. An empty list switches the swipe off.
        entries.append(.string("swipeActions", get: { DoubleTapAction.androidSwipeList(self.swipeActions) }, accepts: { value in
            if value.isEmpty {
                return true
            }
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            return parts.allSatisfy({ (1 ... 2).contains($0.count) && $0.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) })
        }, stored: { value in
            return DoubleTapAction.androidSwipeList(DoubleTapAction.swipeList(fromAndroid: value))
        }, set: { value in
            self.swipeActions = DoubleTapAction.swipeList(fromAndroid: value)
        }))
        // Android: "app" follows the app language, else a language code that may carry a region ("pt-br").
        entries.append(.string("targetLang", get: { self.targetLang.isEmpty ? "app" : self.targetLang }, accepts: { value in
            let parts = value.lowercased().replacingOccurrences(of: "_", with: "-").components(separatedBy: "-")
            return value.count <= 16 && (2 ... 3).contains(parts[0].count) && parts.allSatisfy { part in
                return !part.isEmpty && part.unicodeScalars.allSatisfy { ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) }
            }
        }, stored: { value in
            return ExteraSettings.targetLanguage(fromAndroid: value) ?? "app"
        }, set: { value in
            self.targetLang = ExteraSettings.targetLanguage(fromAndroid: value) ?? ""
        }))
        // Android leaves "automatic" (empty) out of a backup.
        entries.append(.string("inlineTargetCurrency", get: { self.inlineTargetCurrency.isEmpty ? nil : self.inlineTargetCurrency }, accepts: { value in
            return (3 ... 5).contains(value.count) && value.unicodeScalars.allSatisfy { $0.value >= 65 && $0.value <= 90 }
        }, set: { value in
            self.inlineTargetCurrency = value
        }))

        entries.append(contentsOf: ExteraSettings.sharedLegacyEntries())

        // iOS only. These come last, so the camera choice of an iOS backup wins over the Android value above.
        entries.append(.bool("showShareAsImageButton", group: ios, get: { self.value(.showShareAsImageButton) }, set: { self.set(.showShareAsImageButton, $0) }))
        entries.append(.bool("showProxyCountry", group: ios, get: { self.value(.showProxyCountry) }, set: { self.set(.showProxyCountry, $0) }))
        entries.append(.bool("showSearchImageButton", group: ios, get: { self.value(.showSearchImageButton) }, set: { self.set(.showSearchImageButton, $0) }))
        entries.append(.bool("showExteraBadges", group: ios, get: { self.value(.showExteraBadges) }, set: { self.set(.showExteraBadges, $0) }))
        entries.append(.bool("tabCounterUnmutedOnly", group: ios, get: { self.tabCounterUnmutedOnly }, set: { self.set(.tabCounterUnmutedOnly, $0) }))
        entries.append(.int("defaultProfileTab", group: ios, range: 0 ... 2, get: { self.defaultProfileTab.rawValue }, set: { value in
            if let tab = DefaultProfileTab(rawValue: value) {
                self.defaultProfileTab = tab
            }
        }))
        entries.append(.int("inlineAngleUnit", group: ios, range: 0 ... 1, get: { self.inlineAngleUnit.rawValue }, set: { value in
            if let unit = InlineAngleUnit(rawValue: value) {
                self.inlineAngleUnit = unit
            }
        }))
        entries.append(.int("inlineMeasureSystem", group: ios, range: 0 ... 2, get: { self.inlineMeasureSystem.rawValue }, set: { value in
            if let system = InlineMeasureSystem(rawValue: value) {
                self.inlineMeasureSystem = system
            }
        }))
        entries.append(.bool("inlineTargetCurrencyAutomatic", group: ios, get: { self.inlineTargetCurrency.isEmpty }, set: { value in
            if value {
                self.inlineTargetCurrency = ""
            }
        }))
        entries.append(.int("videoMessagesCamera", group: ios, range: 0 ... 2, get: { self.videoMessagesCamera.rawValue }, set: { value in
            if let camera = VideoMessagesCamera(rawValue: value) {
                self.videoMessagesCamera = camera
            }
        }))
        entries.append(contentsOf: ExteraSettings.iosLegacyEntries())
        entries.append(contentsOf: ExteraSettings.ayuEntries())

        // Android has none of the three; a switch without a value stays out of the backup.
        var accountValues = accountSwitches
        for accountSwitch in ExteraBackupAccountSwitch.allCases where accountValues[accountSwitch] != nil {
            entries.append(.bool(accountSwitch.rawValue, group: ios, get: { accountValues[accountSwitch] ?? false }, set: { value in
                accountValues[accountSwitch] = value
                setAccountSwitch(accountSwitch, value)
            }))
        }
        return ExteraBackupSchema(entries: entries)
    }

    // The AyuGram preferences, under the names they are stored with. Left out on purpose: the ghost mode
    // switch itself (it is the current state, flipped many times a day, not a preference; its options are
    // here), remembered state (last seen, last round video camera) and the per-account lists (exclusions,
    // shadow ban).
    private static func ayuEntries() -> [ExteraBackupEntry] {
        let ios = ExteraBackupDocument.iosConfig
        let ghost = AyuGhostSettings.shared
        let save = AyuSaveSettings.shared
        let confirmations = AyuSendConfirmations.shared
        let customization = AyuCustomizationSettings.shared

        // The same two switches as on Android.
        var entries: [ExteraBackupEntry] = [
            .bool("hideReactionsInChannels", get: { customization.hideChannelReactions }, set: { customization.hideChannelReactions = $0 }),
            .bool("hideReactionsInGroups", get: { customization.hideGroupReactions }, set: { customization.hideGroupReactions = $0 })
        ]

        let ghostSwitches: [AyuGhostSettings.Keys] = [
            .hideReadMessages, .hideReadStories, .hideOnline, .hideTyping, .automaticOffline, .onlinePulseOnSend,
            .markReadAfterAction, .useScheduledMessages, .suggestGhostModeBeforeViewingStory, .displayGhostStatus
        ]
        for key in ghostSwitches {
            entries.append(.bool("ayu.ghost.\(key.rawValue)", group: ios, get: { ghost.value(key) }, set: { ghost.set(key, $0) }))
        }
        entries.append(.int("ayu.ghost.sendWithoutSound", group: ios, range: 0 ... 2, get: { ghost.sendWithoutSound.rawValue }, set: { value in
            if let mode = AyuGhostSettings.SendWithoutSound(rawValue: value) {
                ghost.sendWithoutSound = mode
            }
        }))

        entries.append(contentsOf: [
            .bool("ayu.saveDeletedMessages", group: ios, get: { save.saveDeletedMessages }, set: { save.saveDeletedMessages = $0 }),
            .bool("ayu.saveMessagesHistory", group: ios, get: { save.saveMessagesHistory }, set: { save.saveMessagesHistory = $0 }),
            .bool("ayu.saveForBots", group: ios, get: { save.saveForBots }, set: { save.saveForBots = $0 }),
            .bool("ayu.saveReadDate", group: ios, get: { save.saveReadDate }, set: { save.saveReadDate = $0 }),
            .bool("ayu.saveLocalOnline", group: ios, get: { save.saveLocalOnline }, set: { save.saveLocalOnline = $0 })
        ])
        for kind in AyuSendConfirmations.Kind.allCases {
            entries.append(.bool("ayu.confirm.\(kind.rawValue)", group: ios, get: { confirmations.isEnabled(kind) }, set: { confirmations.setEnabled(kind, $0) }))
        }

        entries.append(contentsOf: [
            .bool("ayu.showDeletedMarker", group: ios, get: { customization.showDeletedMarker }, set: { customization.showDeletedMarker = $0 }),
            .bool("ayu.semiTransparentDeletedMessages", group: ios, get: { customization.semiTransparentDeletedMessages }, set: { customization.semiTransparentDeletedMessages = $0 }),
            .bool("ayu.disableAds", group: ios, get: { customization.disableAds }, set: { customization.disableAds = $0 }),
            .bool("ayu.disableOpenLinkWarning", group: ios, get: { customization.disableOpenLinkWarning }, set: { customization.disableOpenLinkWarning = $0 }),
            .bool("ayu.hideNotificationBadge", group: ios, get: { customization.hideNotificationBadge }, set: { customization.hideNotificationBadge = $0 }),
            .bool("ayu.hideFolderCounters", group: ios, get: { customization.hideFolderCounters }, set: { customization.hideFolderCounters = $0 }),
            .bool("ayu.copyUsernameAsLink", group: ios, get: { customization.copyUsernameAsLink }, set: { customization.copyUsernameAsLink = $0 }),
            .bool("ayu.disableSimilarChannels", group: ios, get: { customization.disableSimilarChannels }, set: { customization.disableSimilarChannels = $0 }),
            .bool("ayu.disableCustomBackgrounds", group: ios, get: { customization.disableCustomBackgrounds }, set: { customization.disableCustomBackgrounds = $0 }),
            .bool("ayu.simpleQuotesAndReplies", group: ios, get: { customization.simpleQuotesAndReplies }, set: { customization.simpleQuotesAndReplies = $0 }),
            .bool("ayu.hidePremiumStatuses", group: ios, get: { customization.hidePremiumStatuses }, set: { customization.hidePremiumStatuses = $0 }),
            .bool("ayu.hideFromBlocked", group: ios, get: { customization.hideFromBlocked }, set: { customization.hideFromBlocked = $0 })
        ])
        entries.append(.int("ayu.deletedMark", group: ios, range: 0 ... AyuCustomizationSettings.DeletedMark.allCases.count - 1, get: { customization.deletedMark.rawValue }, set: { value in
            if let mark = AyuCustomizationSettings.DeletedMark(rawValue: value) {
                customization.deletedMark = mark
            }
        }))
        entries.append(.int("ayu.deletedMarkColor", group: ios, range: 0 ... AyuCustomizationSettings.DeletedMarkColor.allCases.count - 1, get: { customization.deletedMarkColor.rawValue }, set: { value in
            if let color = AyuCustomizationSettings.DeletedMarkColor(rawValue: value) {
                customization.deletedMarkColor = color
            }
        }))
        return entries
    }

    // Preferences kept in SGSimpleSettings that exteraGram for Android has too, under its names and values.
    private static func sharedLegacyEntries() -> [ExteraBackupEntry] {
        let settings = SGSimpleSettings.shared
        var entries: [ExteraBackupEntry] = [
            .bool("formatTimeWithSeconds", get: { settings.secondsInMessages }, set: { settings.secondsInMessages = $0 }),
            .bool("uploadSpeedBoost", get: { settings.uploadSpeedBoost }, set: { settings.uploadSpeedBoost = $0 }),
            .bool("hidePhoneNumber", get: { settings.hidePhoneInSettings }, set: { settings.hidePhoneInSettings = $0 }),
            .bool("hideStories", get: { settings.hideStories }, set: { settings.hideStories = $0 }),
            .bool("hideAllChats", get: { settings.allChatsHidden }, set: { settings.allChatsHidden = $0 }),
            .bool("hideNavigationBarLabels", get: { !settings.showTabNames }, set: { settings.showTabNames = !$0 }),
            .bool("widePostsInChannels", get: { settings.wideChannelPosts }, set: { settings.wideChannelPosts = $0 }),
            .bool("quickTransitionForChannels", get: { !settings.disableScrollToNextChannel }, set: { settings.disableScrollToNextChannel = !$0 }),
            .bool("quickTransitionForTopics", get: { !settings.disableScrollToNextTopic }, set: { settings.disableScrollToNextTopic = !$0 }),
            .bool("hideSendAsPeer", get: { settings.disableSendAsButton }, set: { settings.disableSendAsButton = $0 }),
            .bool("hideCameraTile", get: { settings.disableGalleryCamera }, set: { settings.disableGalleryCamera = $0 }),
            .bool("showReportButton", get: { settings.contextShowReport }, set: { settings.contextShowReport = $0 })
        ]
        // Android: 0 off, 1 fast, 2 extreme.
        let speedBoosts = SGSimpleSettings.DownloadSpeedBoostValues.allCases
        entries.append(.int("downloadSpeedBoost", range: 0 ... speedBoosts.count - 1, get: {
            return speedBoosts.firstIndex { $0.rawValue == settings.downloadSpeedBoost }
        }, set: { value in
            settings.downloadSpeedBoost = speedBoosts[value].rawValue
        }))
        // Android: 0 Telegram, 1 Google, 2 Yandex, 3 Microsoft. Apple's translation exists only on iOS, see the iOS group.
        entries.append(.int("translationProvider", range: 0 ... 3, get: {
            switch settings.translationBackendEnum {
            case .default:
                return 0
            case .gtranslate:
                return 1
            case .yandex:
                return 2
            case .microsoft:
                return 3
            case .system:
                return nil
            }
        }, set: { value in
            let backends: [SGSimpleSettings.TranslationBackend] = [.default, .gtranslate, .yandex, .microsoft]
            settings.translationBackend = backends[value].rawValue
        }))
        // Android: 0 off, 1 the Telegram API id, 2 the Bot API id; the same three as ExteraSettings.showIdAndDc.
        // The two older switches follow it.
        entries.append(.int("showIdAndDc", range: 0 ... 2, get: { ExteraSettings.shared.showIdAndDc.rawValue }, set: { value in
            if let mode = ExteraSettings.ShowIdAndDc(rawValue: value) {
                ExteraSettings.shared.showIdAndDc = mode
            }
            settings.showProfileId = value != 0
            settings.showDC = value != 0
        }))
        // Android: 0 no button under a channel, 1 mute, 2 discuss. The button iOS shows is the mute one.
        entries.append(.int("bottomButton", range: 0 ... 2, get: { settings.hideChannelBottomButton ? 0 : 1 }, stored: { min($0, 1) }, set: { value in
            settings.hideChannelBottomButton = value == 0
        }))
        // Android: 0 time inside the sticker, 1 beside it, 2 hidden.
        entries.append(.int("stickerTimeMode", range: 0 ... 2, get: { settings.stickerTimestamp ? 0 : 2 }, stored: { $0 == 2 ? 2 : 0 }, set: { value in
            settings.stickerTimestamp = value != 2
        }))
        // Android: 0 shown, 1 hidden, 2 floating.
        entries.append(.int("bottomNavigationBarMode", range: 0 ... 2, get: { settings.hideTabBar ? 1 : 0 }, stored: { $0 == 1 ? 1 : 0 }, set: { value in
            settings.hideTabBar = value == 1
        }))
        return entries
    }

    // Preferences kept in SGSimpleSettings that only iOS has.
    private static func iosLegacyEntries() -> [ExteraBackupEntry] {
        let ios = ExteraBackupDocument.iosConfig
        let settings = SGSimpleSettings.shared
        var entries: [ExteraBackupEntry] = [
            .bool("sendLargePhotos", group: ios, get: { settings.sendLargePhotos }, set: { settings.sendLargePhotos = $0 }),
            .bool("sendWithReturnKey", group: ios, get: { settings.sendWithReturnKey }, set: { settings.sendWithReturnKey = $0 }),
            .bool("hideAccountInNotifications", group: ios, get: { settings.hideAccountInNotifications }, set: { value in
                settings.hideAccountInNotifications = value
                settings.synchronizeShared()
            }),
            .bool("wideTabBar", group: ios, get: { settings.wideTabBar }, set: { settings.wideTabBar = $0 }),
            .bool("tabBarSearchEnabled", group: ios, get: { settings.tabBarSearchEnabled }, set: { settings.tabBarSearchEnabled = $0 }),
            .bool("compactFolderNames", group: ios, get: { settings.compactFolderNames }, set: { settings.compactFolderNames = $0 }),
            .bool("rememberLastFolder", group: ios, get: { settings.rememberLastFolder }, set: { settings.rememberLastFolder = $0 }),
            .bool("compactChatList", group: ios, get: { settings.compactChatList }, set: { settings.compactChatList = $0 }),
            .bool("disableGalleryCameraPreview", group: ios, get: { settings.disableGalleryCameraPreview }, set: { settings.disableGalleryCameraPreview = $0 }),
            .bool("hideRecordingButton", group: ios, get: { settings.hideRecordingButton }, set: { settings.hideRecordingButton = $0 }),
            .bool("disableSnapDeletionEffect", group: ios, get: { settings.disableSnapDeletionEffect }, set: { settings.disableSnapDeletionEffect = $0 }),
            .bool("hideReactions", group: ios, get: { settings.hideReactions }, set: { settings.hideReactions = $0 }),
            .bool("forceEmojiTab", group: ios, get: { settings.forceEmojiTab }, set: { settings.forceEmojiTab = $0 }),
            .bool("defaultEmojisFirst", group: ios, get: { settings.defaultEmojisFirst }, set: { settings.defaultEmojisFirst = $0 }),
            .bool("showRegDate", group: ios, get: { settings.showRegDate }, set: { settings.showRegDate = $0 }),
            .bool("showCreationDate", group: ios, get: { settings.showCreationDate }, set: { settings.showCreationDate = $0 }),
            .bool("confirmCalls", group: ios, get: { settings.confirmCalls }, set: { settings.confirmCalls = $0 }),
            .bool("warnOnStoriesOpen", group: ios, get: { settings.warnOnStoriesOpen }, set: { settings.warnOnStoriesOpen = $0 }),
            .bool("storyStealthMode", group: ios, get: { settings.storyStealthMode }, set: { settings.storyStealthMode = $0 }),
            .bool("contextShowReply", group: ios, get: { settings.contextShowReply }, set: { settings.contextShowReply = $0 }),
            .bool("contextShowPin", group: ios, get: { settings.contextShowPin }, set: { settings.contextShowPin = $0 }),
            .bool("contextShowSaveMedia", group: ios, get: { settings.contextShowSaveMedia }, set: { settings.contextShowSaveMedia = $0 }),
            .bool("contextShowMessageReplies", group: ios, get: { settings.contextShowMessageReplies }, set: { settings.contextShowMessageReplies = $0 }),
            .bool("contextShowRestrict", group: ios, get: { settings.contextShowRestrict }, set: { settings.contextShowRestrict = $0 })
        ]
        entries.append(.int("accountColorsSaturation", group: ios, range: 0 ... 100, get: { Int(settings.accountColorsSaturation) }, set: { value in
            settings.accountColorsSaturation = Int32(value)
        }))
        let titleLengths = SGSimpleSettings.AllChatsTitleLengthOverride.allCases
        entries.append(.int("allChatsTitleLengthOverride", group: ios, range: 0 ... titleLengths.count - 1, get: {
            return titleLengths.firstIndex { $0.rawValue == settings.allChatsTitleLengthOverride }
        }, set: { value in
            settings.allChatsTitleLengthOverride = titleLengths[value].rawValue
        }))
        // After `translationProvider`, so the iOS-only choice wins when a file has both.
        entries.append(.string("translationBackend", group: ios, get: { settings.translationBackendEnum.rawValue }, accepts: { value in
            return SGSimpleSettings.TranslationBackend(rawValue: value) != nil
        }, set: { value in
            settings.translationBackend = value
        }))
        return entries
    }
}

extension ExteraSettings {
    // The language of exteraGram's target language, nil for "follow the app".
    static func targetLanguage(fromAndroid value: String) -> String? {
        let code = value.lowercased().replacingOccurrences(of: "_", with: "-").components(separatedBy: "-")[0]
        if code == "app" || code.isEmpty {
            return nil
        }
        return code == "nb" ? "no" : code
    }
}
