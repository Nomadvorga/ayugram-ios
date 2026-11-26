import CoreFoundation
import Foundation

/// A deliberately closed, portable set of exteraGram preferences. Never enumerate a defaults domain here:
/// the same domain also contains account data, caches, AyuGram settings and plugin preferences.
public enum ExteraSettingsBackup {
    public static let format = "exteragram-ios-settings"
    public static let version = 1
    public static let maximumFileSize = 256 * 1024

    public enum BackupError: Error {
        case fileTooLarge
        case malformed
        case unsupportedVersion
        case unknownSetting
        case invalidValue
    }

    /// Only the three shared Telegram preferences exposed by the exteraGram screen.
    /// The UI applies these through Telegram's account-manager transactions.
    public struct SharedPreferences {
        public let showContactsTab: Bool
        public let showCallsTab: Bool
        public let foldersAtBottom: Bool

        public init(showContactsTab: Bool, showCallsTab: Bool, foldersAtBottom: Bool) {
            self.showContactsTab = showContactsTab
            self.showCallsTab = showCallsTab
            self.foldersAtBottom = foldersAtBottom
        }
    }

    /// Can only be constructed after the complete document has passed validation.
    public struct ValidatedBackup {
        fileprivate let values: [String: Value]
        public let sharedPreferences: SharedPreferences?
        /// The icon-pack envelope is kept as canonical JSON data. The settings
        /// module validates its JSON shape here; the UI layer performs the
        /// platform image validation before committing it to the icon store.
        public let iconPackBackupData: Data?

        public var settingCount: Int {
            return self.values.count + (self.sharedPreferences == nil ? 0 : 3)
        }

        /// A partial import must not change the transport setting unless its source preference is present.
        public var includesDownloadSpeedBoost: Bool {
            return self.values["simple.downloadSpeedBoost"] != nil
        }
    }

    fileprivate enum Value {
        case boolean(Bool)
        case integer(Int)
        case string(String)
        case strings([String])

        var json: Any {
            switch self {
            case let .boolean(value): return value
            case let .integer(value): return value
            case let .string(value): return value
            case let .strings(value): return value
            }
        }
    }

    private enum Rule {
        case boolean
        case integer(ClosedRange<Int>)
        case integerSet(Set<Int>)
        case string(Set<String>)
        case text(maximumLength: Int, allowedCharacters: CharacterSet?)
        case exactHosts
        case navigationConfiguration
        case pillConfiguration

        func validate(_ object: Any) throws -> Value {
            switch self {
            case .pillConfiguration:
                guard let value = object as? String else { throw BackupError.invalidValue }
                let layout = try ExteraPillPortableSettings.decode(value, rejectDuplicateKeys: ExteraSettingsBackup.rejectDuplicateKeys)
                return .string(ExteraPillPortableSettings.configurationJSON(layout))
            case .navigationConfiguration:
                guard let value = object as? String, let data = value.data(using: .utf8) else { throw BackupError.invalidValue }
                try ExteraSettingsBackup.rejectDuplicateKeys(data)
                guard ExteraNavigationSettings.isValidConfigurationJSON(value) else { throw BackupError.invalidValue }
                return .string(value)
            case .boolean:
                // NSNumber bridges 0/1 to Bool. A conditional Bool cast alone is not strict JSON validation.
                guard let number = object as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw BackupError.invalidValue
                }
                return .boolean(number.boolValue)
            case let .integer(range):
                guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                    let value = Int(number.stringValue), range.contains(value) else {
                    throw BackupError.invalidValue
                }
                return .integer(value)
            case let .string(allowed):
                guard let value = object as? String, allowed.contains(value) else {
                    throw BackupError.invalidValue
                }
                return .string(value)
            case let .integerSet(allowed):
                guard case let .integer(value) = try Rule.integer(Int(Int32.min) ... Int(Int32.max)).validate(object), allowed.contains(value) else {
                    throw BackupError.invalidValue
                }
                return .integer(value)
            case let .text(maximumLength, allowedCharacters):
                guard let value = object as? String, value.count <= maximumLength,
                    value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                    value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && (allowedCharacters?.contains($0) ?? true) }) else {
                    throw BackupError.invalidValue
                }
                return .string(value)
            case .exactHosts:
                // The document byte limit bounds this array; do not impose a smaller count limit
                // than the browser itself, or a valid list could make all settings unexportable.
                guard let hosts = object as? [String],
                    Set(hosts).count == hosts.count,
                    hosts.allSatisfy({ ExteraBrowserSettings.normalizedHost($0) == $0 }) else {
                    throw BackupError.invalidValue
                }
                return .strings(hosts.sorted())
            }
        }
    }

    private struct Setting {
        let name: String
        let rule: Rule
        let defaultValue: Value
        let read: () -> Value
        let write: ((Value) -> Void)?
        let aiFlag: WritableKeyPath<ExteraAIConfiguration, Bool>?
        let aiWrite: ((inout ExteraAIConfiguration, Value) -> Void)?

        init(name: String, rule: Rule, defaultValue: Value, read: @escaping () -> Value, write: ((Value) -> Void)? = nil, aiFlag: WritableKeyPath<ExteraAIConfiguration, Bool>? = nil, aiWrite: ((inout ExteraAIConfiguration, Value) -> Void)? = nil) {
            self.name = name
            self.rule = rule
            self.defaultValue = defaultValue
            self.read = read
            self.write = write
            self.aiFlag = aiFlag
            self.aiWrite = aiWrite
        }
    }

    private static func aiBoolean(_ name: String, _ keyPath: WritableKeyPath<ExteraAIConfiguration, Bool>, defaultValue: Bool = true) -> Setting {
        return Setting(name: name, rule: .boolean, defaultValue: .boolean(defaultValue), read: {
            .boolean(ExteraAISettings.shared.configuration[keyPath: keyPath])
        }, aiFlag: keyPath)
    }

    private static func navigationConfiguration() -> Setting {
        let data: Data
        do { data = try JSONEncoder().encode(ExteraNavigationSettings.Configuration()) }
        catch { preconditionFailure("Navigation defaults must encode: \(error)") }
        return Setting(name: "extera.navigation.configuration", rule: .navigationConfiguration, defaultValue: .string(String(decoding: data, as: UTF8.self)), read: {
            .string(ExteraNavigationSettings.shared.configurationJSON)
        }, write: {
            if case let .string(value) = $0 { precondition(ExteraNavigationSettings.shared.restoreConfigurationJSON(value)) }
        })
    }

    private static func pillConfiguration() -> Setting {
        return Setting(name: ExteraPillPortableSettings.key, rule: .pillConfiguration,
            defaultValue: .string(ExteraPillPortableSettings.configurationJSON(ExteraPillStackLayout())), read: {
                .string(ExteraPillPortableSettings.configurationJSON(ExteraPillStackSettings.shared.layout))
            }, write: {
                // ValidatedBackup and the encoded default are the only sources. Decode before
                // entering the setter; no malformed document can cause a partial layout write.
                guard case let .string(value) = $0 else {
                    preconditionFailure("Pill backup value must have passed complete validation")
                }
                let layout: ExteraPillStackLayout
                do {
                    layout = try ExteraPillPortableSettings.decode(value, rejectDuplicateKeys: ExteraSettingsBackup.rejectDuplicateKeys)
                } catch {
                    preconditionFailure("Pill backup value must have passed complete validation: \(error)")
                }
                ExteraPillPortableSettings.applyValidated(layout, settings: ExteraPillStackSettings.shared, custom: ExteraPillSettings.shared.pills)
            })
    }

    private static func aiTemperature(_ name: String) -> Setting {
        return Setting(name: name, rule: .integer(0 ... 20), defaultValue: .integer(10), read: {
            let value = ExteraAISettings.shared.configuration.temperature
            return .integer(value.isFinite ? Int((max(0.0, min(2.0, value)) * 10.0).rounded()) : 10)
        }, aiWrite: { configuration, value in
            if case let .integer(tenths) = value { configuration.temperature = Double(tenths) / 10.0 }
        })
    }

    private static func aiEditorPolicy(_ name: String) -> Setting {
        return Setting(name: name, rule: .string(["automatic", "enabled", "disabled"]), defaultValue: .string("automatic"), read: {
            let policy = ExteraAISettings.shared.configuration.useForTextProcessing
            return .string(policy.map { $0 ? "enabled" : "disabled" } ?? "automatic")
        }, aiWrite: { configuration, value in
            if case let .string(policy) = value {
                configuration.useForTextProcessing = policy == "automatic" ? nil : policy == "enabled"
            }
        })
    }

    private static func aiSummaryPolicy(_ name: String) -> Setting {
        return Setting(name: name, rule: .string(["automatic", "enabled", "disabled"]), defaultValue: .string("automatic"), read: {
            let policy = ExteraAISettings.shared.configuration.replaceTelegramSummaries
            return .string(policy.map { $0 ? "enabled" : "disabled" } ?? "automatic")
        }, aiWrite: { configuration, value in
            if case let .string(policy) = value {
                configuration.replaceTelegramSummaries = policy == "automatic" ? nil : policy == "enabled"
            }
        })
    }

    private static func boolean(_ name: String, defaultValue: Bool = false, read: @escaping () -> Bool, write: @escaping (Bool) -> Void) -> Setting {
        return Setting(name: name, rule: .boolean, defaultValue: .boolean(defaultValue), read: { .boolean(read()) }, write: {
            if case let .boolean(value) = $0 { write(value) }
        })
    }

    private static func integer(_ name: String, allowed: Set<Int>, defaultValue: Int, read: @escaping () -> Int, write: @escaping (Int) -> Void) -> Setting {
        return Setting(name: name, rule: .integerSet(allowed), defaultValue: .integer(defaultValue), read: { .integer(read()) }, write: {
            if case let .integer(value) = $0 { write(value) }
        })
    }

    private static func text(_ name: String, maximumLength: Int, allowedCharacters: CharacterSet? = nil, read: @escaping () -> String, write: @escaping (String) -> Void) -> Setting {
        return Setting(name: name, rule: .text(maximumLength: maximumLength, allowedCharacters: allowedCharacters), defaultValue: .string(""), read: { .string(read()) }, write: {
            if case let .string(value) = $0 { write(value) }
        })
    }

    private static func exteraBoolean(_ key: ExteraSettings.Keys, defaultValue: Bool = false) -> Setting {
        return Setting(name: "extera.\(key.rawValue)", rule: .boolean, defaultValue: .boolean(defaultValue), read: {
            return .boolean(ExteraSettings.shared.value(key))
        }, write: { value in
            if case let .boolean(value) = value {
                ExteraSettings.shared.set(key, value)
            }
        })
    }

    private static func simpleBoolean(_ key: SGSimpleSettings.Keys, _ keyPath: ReferenceWritableKeyPath<SGSimpleSettings, Bool>) -> Setting {
        let defaultValue = (SGSimpleSettings.defaultValues[key.rawValue] ?? SGSimpleSettings.groupDefaultValues[key.rawValue]) as? Bool ?? false
        return Setting(name: "simple.\(key.rawValue)", rule: .boolean, defaultValue: .boolean(defaultValue), read: {
            return .boolean(SGSimpleSettings.shared[keyPath: keyPath])
        }, write: { value in
            if case let .boolean(value) = value {
                if SGSimpleSettings.shared[keyPath: keyPath] != value {
                    SGSimpleSettings.shared[keyPath: keyPath] = value
                }
            }
        })
    }

    private static func simpleInteger(_ key: SGSimpleSettings.Keys, _ keyPath: ReferenceWritableKeyPath<SGSimpleSettings, Int32>, range: ClosedRange<Int>, defaultValue: Int) -> Setting {
        return Setting(name: "simple.\(key.rawValue)", rule: .integer(range), defaultValue: .integer(defaultValue), read: {
            return .integer(Int(SGSimpleSettings.shared[keyPath: keyPath]))
        }, write: { value in
            if case let .integer(value) = value {
                if SGSimpleSettings.shared[keyPath: keyPath] != Int32(value) {
                    SGSimpleSettings.shared[keyPath: keyPath] = Int32(value)
                }
            }
        })
    }

    private static func simpleString(_ key: SGSimpleSettings.Keys, _ keyPath: ReferenceWritableKeyPath<SGSimpleSettings, String>, allowed: [String], defaultValue: String) -> Setting {
        return Setting(name: "simple.\(key.rawValue)", rule: .string(Set(allowed)), defaultValue: .string(defaultValue), read: {
            return .string(SGSimpleSettings.shared[keyPath: keyPath])
        }, write: { value in
            if case let .string(value) = value {
                if SGSimpleSettings.shared[keyPath: keyPath] != value {
                    SGSimpleSettings.shared[keyPath: keyPath] = value
                }
            }
        })
    }

    // Explicit allowlist: adding a preference anywhere else must never silently expand backup/reset scope.
    private static let settings: [Setting] = [
        aiBoolean("extera.ai.showEditor", \.showEditor),
        aiBoolean("extera.ai.showSummaries", \.showSummaries),
        aiBoolean("extera.ai.showInstantViewSummaries", \.showInstantViewSummaries),
        aiBoolean("extera.ai.showResponseOnly", \.showResponseOnly, defaultValue: false),
        aiBoolean("extera.ai.insertAsQuote", \.insertAsQuote),
        aiTemperature("extera.ai.temperatureTenths"),
        navigationConfiguration(),
        pillConfiguration(),
        aiSummaryPolicy("extera.ai.replaceTelegramSummaries"),
        aiEditorPolicy("extera.ai.replaceTelegramEditor"),
        boolean("extera.browser.automaticFilterUpdates", defaultValue: true, read: { ExteraBrowserFilters.shared.automaticUpdates }, write: { ExteraBrowserFilters.shared.automaticUpdates = $0 }),
        boolean("extera.stickers.unlimitedRecent", read: { ExteraStickerSettings.shared.unlimitedRecentStickers }, write: { ExteraStickerSettings.shared.unlimitedRecentStickers = $0 }),
        integer("extera.stickers.size", allowed: Set(4 ... 20), defaultValue: 12, read: { ExteraStickerSettings.shared.size }, write: { ExteraStickerSettings.shared.size = $0 }),
        exteraBoolean(.disableNumberRounding),
        exteraBoolean(.inAppVibration, defaultValue: true),
        exteraBoolean(.replaceEditedWithIcon),
        exteraBoolean(.hideShareButton),
        exteraBoolean(.disableGreetingSticker),
        exteraBoolean(.filterZalgo),
        exteraBoolean(.forceSnow),
        exteraBoolean(.centerTitle),
        exteraBoolean(.singleCornerRadius),
        exteraBoolean(.hideActionBarStatus),
        exteraBoolean(.hideFloatingButton),
        exteraBoolean(.hideDialogsSearchBar),
        exteraBoolean(.senderMiniAvatars),
        exteraBoolean(.disableNotificationDelay),
        exteraBoolean(.relativeLastSeen),
        exteraBoolean(.hideArchiveFolder),
        exteraBoolean(.archiveOnPull, defaultValue: true),
        exteraBoolean(.disableUnarchiveSwipe, defaultValue: true),
        integer("extera.tabTitleStyle", allowed: [0, 1, 2], defaultValue: 0, read: { ExteraSettings.shared.tabTitleStyle.rawValue }, write: {
            if let value = ExteraSettings.TabTitleStyle(rawValue: $0) { ExteraSettings.shared.tabTitleStyle = value }
        }),
        integer("extera.tabCounterMode", allowed: [0, 1, 2], defaultValue: 0, read: { ExteraSettings.shared.tabCounterMode.rawValue }, write: {
            if let value = ExteraSettings.TabCounterMode(rawValue: $0) { ExteraSettings.shared.tabCounterMode = value }
        }),
        integer("extera.showIdAndDc", allowed: [0, 1, 2], defaultValue: 0, read: { ExteraSettings.shared.showIdAndDc.rawValue }, write: {
            if let value = ExteraSettings.ShowIdAndDc(rawValue: $0) { ExteraSettings.shared.showIdAndDc = value }
        }),
        integer("extera.general.defaultProfileTab", allowed: [0, 1, 2], defaultValue: 0, read: { ExteraGeneralSettings.shared.defaultProfileTab.rawValue }, write: {
            if let value = ExteraGeneralSettings.DefaultProfileTab(rawValue: $0) { ExteraGeneralSettings.shared.defaultProfileTab = value }
        }),
        text("extera.customSavePath", maximumLength: 255, allowedCharacters: CharacterSet(charactersIn: "/:").inverted, read: { ExteraSettings.shared.customSavePath }, write: { ExteraSettings.shared.customSavePath = $0 }),
        text("extera.translationTargetLanguage", maximumLength: 64, allowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"), read: { ExteraSettings.shared.translationTargetLanguage }, write: { ExteraSettings.shared.translationTargetLanguage = $0 }),
        Setting(name: "extera.avatarCorners", rule: .integer(0 ... 28), defaultValue: .integer(28), read: {
            return .integer(ExteraSettings.shared.avatarCorners)
        }, write: { value in
            if case let .integer(value) = value { ExteraSettings.shared.avatarCorners = value }
        }),
        Setting(name: "extera.chatListTitle", rule: .integer(0 ... 4), defaultValue: .integer(0), read: {
            return .integer(ExteraSettings.shared.chatListTitle.rawValue)
        }, write: { value in
            if case let .integer(value) = value, let title = ExteraSettings.ChatListTitle(rawValue: value) {
                ExteraSettings.shared.chatListTitle = title
            }
        }),
        simpleBoolean(.hidePhoneInSettings, \.hidePhoneInSettings),
        simpleBoolean(.secondsInMessages, \.secondsInMessages),
        simpleBoolean(.uploadSpeedBoost, \.uploadSpeedBoost),
        simpleBoolean(.sendLargePhotos, \.sendLargePhotos),
        simpleBoolean(.sendWithReturnKey, \.sendWithReturnKey),
        simpleBoolean(.hideAccountInNotifications, \.hideAccountInNotifications),
        simpleBoolean(.hideStories, \.hideStories),
        simpleBoolean(.allChatsHidden, \.allChatsHidden),
        simpleBoolean(.compactChatList, \.compactChatList),
        simpleBoolean(.hideTabBar, \.hideTabBar),
        simpleBoolean(.showTabNames, \.showTabNames),
        simpleBoolean(.tabBarSearchEnabled, \.tabBarSearchEnabled),
        simpleBoolean(.wideTabBar, \.wideTabBar),
        simpleBoolean(.compactFolderNames, \.compactFolderNames),
        simpleBoolean(.rememberLastFolder, \.rememberLastFolder),
        simpleBoolean(.lyricsInPlayer, \.lyricsInPlayer),
        simpleBoolean(.hideSponsoredMessages, \.hideSponsoredMessages),
        simpleBoolean(.filterZalgoText, \.filterZalgoText),
        simpleBoolean(.commaAfterMention, \.commaAfterMention),
        simpleBoolean(.hideChannelBottomButton, \.hideChannelBottomButton),
        simpleBoolean(.wideChannelPosts, \.wideChannelPosts),
        simpleBoolean(.hideRecordingButton, \.hideRecordingButton),
        simpleBoolean(.disableSnapDeletionEffect, \.disableSnapDeletionEffect),
        simpleBoolean(.disableSendAsButton, \.disableSendAsButton),
        simpleBoolean(.disableGalleryCamera, \.disableGalleryCamera),
        simpleBoolean(.disableGalleryCameraPreview, \.disableGalleryCameraPreview),
        simpleBoolean(.disableScrollToNextChannel, \.disableScrollToNextChannel),
        simpleBoolean(.disableScrollToNextTopic, \.disableScrollToNextTopic),
        simpleBoolean(.hideReactions, \.hideReactions),
        simpleBoolean(.forceEmojiTab, \.forceEmojiTab),
        simpleBoolean(.defaultEmojisFirst, \.defaultEmojisFirst),
        simpleBoolean(.stickerTimestamp, \.stickerTimestamp),
        // Apply the old boolean first, then let an explicitly backed-up enum own visibility.
        integer("extera.stickers.timeMode", allowed: [0, 1, 2], defaultValue: 0, read: { ExteraStickerSettings.shared.timeMode.rawValue }, write: {
            if let mode = ExteraStickerSettings.TimeMode(rawValue: $0) { ExteraStickerSettings.shared.timeMode = mode }
        }),
        integer("extera.stickers.shape", allowed: [0, 1, 2], defaultValue: 1, read: { ExteraStickerSettings.shared.shape.rawValue }, write: {
            if let shape = ExteraStickerSettings.Shape(rawValue: $0) { ExteraStickerSettings.shared.shape = shape }
        }),
        simpleBoolean(.showProfileId, \.showProfileId),
        simpleBoolean(.showDC, \.showDC),
        simpleBoolean(.showRegDate, \.showRegDate),
        simpleBoolean(.showCreationDate, \.showCreationDate),
        simpleBoolean(.confirmCalls, \.confirmCalls),
        simpleBoolean(.warnOnStoriesOpen, \.warnOnStoriesOpen),
        simpleBoolean(.storyStealthMode, \.storyStealthMode),
        simpleBoolean(.videoControlsInFooter, \.videoControlsInFooter),
        simpleBoolean(.combinedMediaViewer, \.combinedMediaViewer),
        simpleInteger(.accountColorsSaturation, \.accountColorsSaturation, range: 0 ... 100, defaultValue: 100),
        simpleInteger(.outgoingPhotoQuality, \.outgoingPhotoQuality, range: 0 ... 100, defaultValue: 70),
        simpleInteger(.stickerSize, \.stickerSize, range: 0 ... 100, defaultValue: 100),
        simpleString(.downloadSpeedBoost, \.downloadSpeedBoost, allowed: ["none", "medium", "maximum"], defaultValue: "none"),
        simpleString(.allChatsTitleLengthOverride, \.allChatsTitleLengthOverride, allowed: ["none", "short", "long"], defaultValue: "none"),
        simpleString(.chatListLines, \.chatListLines, allowed: ["1", "2", "3"], defaultValue: "3"),
        simpleString(.videoPIPSwipeDirection, \.videoPIPSwipeDirection, allowed: ["up", "down", "none"], defaultValue: "up"),
        simpleString(.messageDoubleTapActionOutgoing, \.messageDoubleTapActionOutgoing, allowed: ["default", "none", "edit"], defaultValue: "default"),
        simpleString(.translationBackend, \.translationBackend, allowed: ["default", "gtranslate", "microsoft", "yandex", "system"], defaultValue: "default"),
        simpleString(.transcriptionBackend, \.transcriptionBackend, allowed: ["default", "apple"], defaultValue: "default"),
        text("extera.appleSpeechLocaleIdentifier", maximumLength: 64, allowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"), read: { ExteraTranslationSettings.shared.appleSpeechLocaleIdentifier }, write: { ExteraTranslationSettings.shared.appleSpeechLocaleIdentifier = $0 }),
        boolean("extera.appleSpeechOnDeviceOnly", read: { ExteraTranslationSettings.shared.appleSpeechOnDeviceOnly }, write: { ExteraTranslationSettings.shared.appleSpeechOnDeviceOnly = $0 }),
        boolean("extera.speech.isEnabled", defaultValue: true, read: { ExteraSpeechSettings.shared.isEnabled }, write: { ExteraSpeechSettings.shared.isEnabled = $0 }),
        boolean("extera.speech.useManagedOfflineModel", read: { ExteraSpeechSettings.shared.useManagedOfflineModel }, write: { ExteraSpeechSettings.shared.useManagedOfflineModel = $0 }),
        boolean("extera.vosk.isSelected", read: { ExteraVoskSettings.shared.isSelected }, write: { ExteraVoskSettings.shared.isSelected = $0 }),
        Setting(name: "extera.vosk.language", rule: .string(Set(["none", "auto", "en", "es", "zh", "hi", "fa", "fr", "ru", "pt", "de", "ja", "ko", "it", "uk", "gu", "pl", "nl", "tr", "vi", "cs", "uz", "eo", "kk", "tg", "ca"])), defaultValue: .string("none"), read: { .string(ExteraVoskSettings.shared.language) }, write: {
            if case let .string(language) = $0 { ExteraVoskSettings.shared.language = language }
        }),
        boolean(ExteraAdminSettings.quickAdminShortcutsKey, defaultValue: true, read: { ExteraAdminSettings.shared.quickAdminShortcuts }, write: { ExteraAdminSettings.shared.quickAdminShortcuts = $0 }),
        boolean(ExteraEnergySettings.followSystemKey, read: { ExteraEnergySettings.shared.followSystem }, write: { ExteraEnergySettings.shared.followSystem = $0 }),
        Setting(name: ExteraUIIconSettings.storageKey, rule: .string(Set(ExteraUIIconPack.allCases.map(\.rawValue))), defaultValue: .string(ExteraUIIconPack.native.rawValue), read: { .string(ExteraUIIconSettings.shared.pack.rawValue) }, write: {
            if case let .string(value) = $0 { ExteraUIIconSettings.shared.select(ExteraUIIconPack.normalized(value)) }
        }),
        boolean("extera.chat.hideKeyboardOnScroll", read: { ExteraChatSettings.shared.hideKeyboardOnScroll }, write: { ExteraChatSettings.shared.hideKeyboardOnScroll = $0 }),
        boolean("extera.feed.widePosts", defaultValue: true, read: { ExteraFeedSettings.shared.widePosts }, write: { ExteraFeedSettings.shared.widePosts = $0 }),
        boolean("extera.feed.showUnreadCounter", defaultValue: true, read: { ExteraFeedSettings.shared.showUnreadCounter }, write: { ExteraFeedSettings.shared.showUnreadCounter = $0 }),
        integer("extera.chat.channelBottomButton", allowed: [0, 1, 2], defaultValue: 1, read: { ExteraChatSettings.shared.channelBottomButton.rawValue }, write: {
            if let value = ExteraChatSettings.ChannelBottomButton(rawValue: $0) { ExteraChatSettings.shared.channelBottomButton = value }
        }),
        boolean("extera.chat.addCommaAfterMention", read: { ExteraChatSettings.shared.addCommaAfterMention }, write: { ExteraChatSettings.shared.addCommaAfterMention = $0 }),
        boolean("extera.chat.swipeToReplyIncoming", defaultValue: true, read: { ExteraChatSettings.shared.swipeToReplyIncoming }, write: { ExteraChatSettings.shared.swipeToReplyIncoming = $0 }),
        boolean("extera.chat.swipeToReplyOutgoing", defaultValue: true, read: { ExteraChatSettings.shared.swipeToReplyOutgoing }, write: { ExteraChatSettings.shared.swipeToReplyOutgoing = $0 }),
        integer("extera.chat.doubleTapIncoming", allowed: [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10], defaultValue: 1, read: { ExteraChatSettings.shared.doubleTapIncoming.rawValue }, write: {
            if let value = ExteraChatSettings.DoubleTapAction(rawValue: $0) { ExteraChatSettings.shared.doubleTapIncoming = value }
        }),
        integer("extera.chat.doubleTapOutgoing", allowed: [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10], defaultValue: -1, read: { ExteraChatSettings.shared.doubleTapOutgoing.rawValue }, write: {
            if let value = ExteraChatSettings.DoubleTapAction(rawValue: $0) { ExteraChatSettings.shared.doubleTapOutgoing = value }
        }),
        boolean("extera.hideReactionsInPrivateChats", read: { ExteraMessageSettings.shared.hideReactionsInPrivateChats }, write: { ExteraMessageSettings.shared.hideReactionsInPrivateChats = $0 }),
        // These two controls intentionally alias AyuGram's existing reaction preferences.
        boolean("extera.hideReactionsInChannels", read: { ExteraMessageSettings.shared.hideReactionsInChannels }, write: { ExteraMessageSettings.shared.hideReactionsInChannels = $0 }),
        boolean("extera.hideReactionsInGroups", read: { ExteraMessageSettings.shared.hideReactionsInGroups }, write: { ExteraMessageSettings.shared.hideReactionsInGroups = $0 }),
        boolean("extera.removeMessageTail", read: { ExteraMessageSettings.shared.removeMessageTail }, write: { ExteraMessageSettings.shared.removeMessageTail = $0 }),
        boolean("extera.replyColors", defaultValue: true, read: { ExteraMessageSettings.shared.replyColors }, write: { ExteraMessageSettings.shared.replyColors = $0 }),
        boolean("extera.replyEmoji", defaultValue: true, read: { ExteraMessageSettings.shared.replyEmoji }, write: { ExteraMessageSettings.shared.replyEmoji = $0 }),
        boolean("extera.replyBackground", defaultValue: true, read: { ExteraMessageSettings.shared.replyBackground }, write: { ExteraMessageSettings.shared.replyBackground = $0 }),
        boolean("extera.showForwardsCount", read: { ExteraMessageSettings.shared.showForwardsCount }, write: { ExteraMessageSettings.shared.showForwardsCount = $0 }),
        boolean("extera.showPollResultsBeforeVoting", read: { ExteraMessageSettings.shared.showPollResultsBeforeVoting }, write: { ExteraMessageSettings.shared.showPollResultsBeforeVoting = $0 }),
        boolean("extera.menu.showCopyPhotoButton", defaultValue: true, read: { ExteraMenuSettings.shared.showCopyPhotoButton }, write: { ExteraMenuSettings.shared.showCopyPhotoButton = $0 }),
        boolean("extera.menu.showSaveMessageButton", read: { ExteraMenuSettings.shared.showSaveMessageButton }, write: { ExteraMenuSettings.shared.showSaveMessageButton = $0 }),
        boolean("extera.menu.showRepeatMessageButton", read: { ExteraMenuSettings.shared.showRepeatMessageButton }, write: { ExteraMenuSettings.shared.showRepeatMessageButton = $0 }),
        boolean("extera.menu.showClearButton", defaultValue: true, read: { ExteraMenuSettings.shared.showClearButton }, write: { ExteraMenuSettings.shared.showClearButton = $0 }),
        boolean("extera.menu.showHistoryButton", read: { ExteraMenuSettings.shared.showHistoryButton }, write: { ExteraMenuSettings.shared.showHistoryButton = $0 }),
        boolean("extera.menu.showReportButton", defaultValue: true, read: { ExteraMenuSettings.shared.showReportButton }, write: { ExteraMenuSettings.shared.showReportButton = $0 }),
        boolean("extera.menu.showDetailsButton", read: { ExteraMenuSettings.shared.showDetailsButton }, write: { ExteraMenuSettings.shared.showDetailsButton = $0 }),
        boolean("extera.menu.showMessageImageExportButton", read: { ExteraMenuSettings.shared.showMessageImageExportButton }, write: { ExteraMenuSettings.shared.showMessageImageExportButton = $0 }),
        boolean("extera.menu.groupMessageMenu", defaultValue: true, read: { ExteraMenuSettings.shared.groupMessageMenu }, write: { ExteraMenuSettings.shared.groupMessageMenu = $0 }),
        integer("extera.media.doubleTapSeekDuration", allowed: [5, 10, 15, 30], defaultValue: 10, read: { ExteraMediaSettings.shared.doubleTapSeekDuration }, write: { ExteraMediaSettings.shared.doubleTapSeekDuration = $0 }),
        integer("extera.media.videoMessagesCamera", allowed: [0, 1, 2], defaultValue: 0, read: { ExteraMediaSettings.shared.videoMessagesCamera }, write: { ExteraMediaSettings.shared.videoMessagesCamera = $0 }),
        boolean("extera.media.preferOriginalQuality", read: { ExteraMediaSettings.shared.preferOriginalQuality }, write: { ExteraMediaSettings.shared.preferOriginalQuality = $0 }),
        boolean("extera.media.pauseOnMinimizeVideo", defaultValue: true, read: { ExteraMediaSettings.shared.pauseOnMinimizeVideo }, write: { ExteraMediaSettings.shared.pauseOnMinimizeVideo = $0 }),
        boolean("extera.media.pauseOnMinimizeVoice", read: { ExteraMediaSettings.shared.pauseOnMinimizeVoice }, write: { ExteraMediaSettings.shared.pauseOnMinimizeVoice = $0 }),
        boolean("extera.media.pauseOnMinimizeRound", read: { ExteraMediaSettings.shared.pauseOnMinimizeRound }, write: { ExteraMediaSettings.shared.pauseOnMinimizeRound = $0 }),
        boolean("extera.chatMedia.pauseOtherAudio", defaultValue: true, read: { ExteraChatMediaSettings.shared.pauseOtherAudio }, write: { ExteraChatMediaSettings.shared.pauseOtherAudio = $0 }),
        boolean("extera.media.rememberLastUsedCamera", defaultValue: true, read: { ExteraMediaSettings.shared.rememberLastUsedCamera }, write: { ExteraMediaSettings.shared.rememberLastUsedCamera = $0 }),
        boolean("extera.media.zoomSlider", defaultValue: true, read: { ExteraMediaSettings.shared.zoomSlider }, write: { ExteraMediaSettings.shared.zoomSlider = $0 }),
        boolean("extera.media.staticZoom", read: { ExteraMediaSettings.shared.staticZoom }, write: { ExteraMediaSettings.shared.staticZoom = $0 }),
        boolean("extera.media.unmuteWithVolumeButtons", read: { ExteraMediaSettings.shared.unmuteWithVolumeButtons }, write: { ExteraMediaSettings.shared.unmuteWithVolumeButtons = $0 }),
        Setting(name: ExteraChatAppearanceSettings.swipeActionKey, rule: .string(Set(ExteraChatAppearanceSettings.SwipeAction.allCases.map(\.rawValue))), defaultValue: .string("archive"), read: { .string(ExteraChatAppearanceSettings.shared.swipeAction.rawValue) }, write: {
            if case let .string(value) = $0, let action = ExteraChatAppearanceSettings.SwipeAction(rawValue: value) { ExteraChatAppearanceSettings.shared.swipeAction = action }
        }),
        Setting(name: ExteraChatAppearanceSettings.microphoneKey, rule: .string(Set(ExteraChatAppearanceSettings.Microphone.allCases.map(\.rawValue))), defaultValue: .string("automatic"), read: { .string(ExteraChatAppearanceSettings.shared.microphone.rawValue) }, write: {
            if case let .string(value) = $0, let microphone = ExteraChatAppearanceSettings.Microphone(rawValue: value) { ExteraChatAppearanceSettings.shared.microphone = microphone }
        }),
        Setting(name: ExteraChatAppearanceSettings.distanceUnitKey, rule: .string(Set(ExteraChatAppearanceSettings.DistanceUnit.allCases.map(\.rawValue))), defaultValue: .string("automatic"), read: { .string(ExteraChatAppearanceSettings.shared.distanceUnit.rawValue) }, write: {
            if case let .string(value) = $0, let unit = ExteraChatAppearanceSettings.DistanceUnit(rawValue: value) { ExteraChatAppearanceSettings.shared.distanceUnit = unit }
        }),
        boolean("extera.inlineResults", defaultValue: true, read: { ExteraMathSettings.shared.inlineResults }, write: { ExteraMathSettings.shared.inlineResults = $0 }),
        boolean("extera.inlineMathResult", defaultValue: true, read: { ExteraMathSettings.shared.inlineMathResult }, write: { ExteraMathSettings.shared.inlineMathResult = $0 }),
        boolean("extera.inlineDigitGrouping", defaultValue: true, read: { ExteraMathSettings.shared.inlineDigitGrouping }, write: { ExteraMathSettings.shared.inlineDigitGrouping = $0 }),
        boolean("extera.inlineUnits", defaultValue: true, read: { ExteraMathSettings.shared.inlineUnits }, write: { ExteraMathSettings.shared.inlineUnits = $0 }),
        boolean("extera.inlineCurrencies", defaultValue: true, read: { ExteraMathSettings.shared.inlineCurrencies }, write: { ExteraMathSettings.shared.inlineCurrencies = $0 }),
        boolean("extera.inlineTimeZones", defaultValue: true, read: { ExteraMathSettings.shared.inlineTimeZones }, write: { ExteraMathSettings.shared.inlineTimeZones = $0 }),
        boolean("extera.inlineImperial", read: { ExteraMathSettings.shared.inlineImperial }, write: { ExteraMathSettings.shared.inlineImperial = $0 }),
        boolean("extera.showOnlineStatus", read: { ExteraMessageSettings.shared.showOnlineStatus }, write: { ExteraMessageSettings.shared.showOnlineStatus = $0 }),
        // Apply after the legacy boolean: new backups preserve auto, while old
        // partial backups still select the explicit metric/imperial preference.
        Setting(name: "extera.inlineMeasureSystem", rule: .string(["auto", "metric", "imperial"]), defaultValue: .string("auto"), read: { .string(ExteraMathSettings.shared.inlineMeasureSystem.rawValue) }, write: {
            if case let .string(value) = $0, let system = ExteraMathSettings.MeasureSystem(rawValue: value) { ExteraMathSettings.shared.inlineMeasureSystem = system }
        }),
        Setting(name: "extera.inlineTargetCurrency", rule: .string(Set(NSLocale.commonISOCurrencyCodes + ["auto", "BTC", "ETH", "SOL", "USDT", "GRAM"])), defaultValue: .string("auto"), read: { .string(ExteraMathSettings.shared.inlineTargetCurrency) }, write: {
            if case let .string(value) = $0 { ExteraMathSettings.shared.inlineTargetCurrency = value }
        }),
        integer("extera.player.lyricsSource", allowed: Set(ExteraPlayerSettings.LyricsSource.allCases.map { $0.rawValue }), defaultValue: 0, read: { ExteraPlayerSettings.shared.lyricsSource.rawValue }, write: {
            if let source = ExteraPlayerSettings.LyricsSource(rawValue: $0) { ExteraPlayerSettings.shared.lyricsSource = source }
        }),
        integer("extera.player.lyricsDisplayMode", allowed: Set(ExteraPlayerSettings.LyricsDisplayMode.allCases.map { $0.rawValue }), defaultValue: 0, read: { ExteraPlayerSettings.shared.lyricsDisplayMode.rawValue }, write: {
            if let mode = ExteraPlayerSettings.LyricsDisplayMode(rawValue: $0) { ExteraPlayerSettings.shared.lyricsDisplayMode = mode }
        }),
        boolean("extera.player.preferEmbeddedLyrics", defaultValue: true, read: { ExteraPlayerSettings.shared.preferEmbeddedLyrics }, write: { ExteraPlayerSettings.shared.preferEmbeddedLyrics = $0 }),
        boolean("extera.player.lyricsAutoScroll", defaultValue: true, read: { ExteraPlayerSettings.shared.lyricsAutoScroll }, write: { ExteraPlayerSettings.shared.lyricsAutoScroll = $0 }),
        boolean("extera.player.lyricsTapToSeek", defaultValue: true, read: { ExteraPlayerSettings.shared.lyricsTapToSeek }, write: { ExteraPlayerSettings.shared.lyricsTapToSeek = $0 }),
        Setting(name: "extera.player.lyricsOffsetMilliseconds", rule: .integer(-10000 ... 10000), defaultValue: .integer(0), read: { .integer(ExteraPlayerSettings.shared.lyricsOffsetMilliseconds) }, write: {
            if case let .integer(value) = $0 { ExteraPlayerSettings.shared.lyricsOffsetMilliseconds = value }
        }),
        Setting(name: "extera.inlineAngleUnit", rule: .string(["degrees", "radians"]), defaultValue: .string("degrees"), read: { .string(ExteraMathSettings.shared.inlineAngleUnit.rawValue) }, write: {
            if case let .string(value) = $0, let unit = ExteraMathSettings.AngleUnit(rawValue: value) { ExteraMathSettings.shared.inlineAngleUnit = unit }
        }),
        integer(ExteraStyleSettings.controlStyleKey, allowed: [0, 1], defaultValue: 1, read: { ExteraStyleSettings.shared.controlStyle.rawValue }, write: {
            if let style = ExteraStyleSettings.ControlStyle(rawValue: $0) { ExteraStyleSettings.shared.controlStyle = style }
        }),
        Setting(name: ExteraStyleSettings.sectionRadiusKey, rule: .integer(0 ... 64), defaultValue: .integer(22), read: { .integer(ExteraStyleSettings.shared.sectionRadius) }, write: {
            if case let .integer(value) = $0 { ExteraStyleSettings.shared.sectionRadius = value }
        }),
        boolean(ExteraStyleSettings.separateHeadersKey, defaultValue: true, read: { ExteraStyleSettings.shared.separateHeaders }, write: { ExteraStyleSettings.shared.separateHeaders = $0 }),
        Setting(name: ExteraStyleSettings.separatorStyleKey, rule: .string(["line", "fullWidth", "none"]), defaultValue: .string("line"), read: { .string(ExteraStyleSettings.shared.separatorStyle.rawValue) }, write: {
            if case let .string(value) = $0, let style = ExteraStyleSettings.SeparatorStyle(rawValue: value) { ExteraStyleSettings.shared.separatorStyle = style }
        }),
        Setting(name: ExteraStyleSettings.glassBorderKey, rule: .string(["none", "line", "highlights"]), defaultValue: .string("none"), read: { .string(ExteraStyleSettings.shared.glassBorder.rawValue) }, write: {
            if case let .string(value) = $0, let border = ExteraStyleSettings.GlassBorder(rawValue: value) { ExteraStyleSettings.shared.glassBorder = border }
        }),
        boolean(ExteraStyleSettings.glassMessageMenuKey, read: { ExteraStyleSettings.shared.glassMessageMenu }, write: { ExteraStyleSettings.shared.glassMessageMenu = $0 }),
        boolean(ExteraStyleSettings.forceBlurKey, read: { ExteraStyleSettings.shared.forceBlur }, write: { ExteraStyleSettings.shared.forceBlur = $0 }),
        boolean("extera.browser.adBlockingEnabled", defaultValue: true, read: { ExteraBrowserSettings.shared.adBlockingEnabled }, write: { ExteraBrowserSettings.shared.adBlockingEnabled = $0 }),
        Setting(name: "extera.browser.exceptionHosts", rule: .exactHosts, defaultValue: .strings([]), read: { .strings(ExteraBrowserSettings.shared.exceptionHosts) }, write: {
            if case let .strings(hosts) = $0 { ExteraBrowserSettings.shared.exceptionHosts = hosts }
        }),
    ] + ExteraEnergySettings.Feature.allCases.map { feature in
        boolean(ExteraEnergySettings.key(for: feature), defaultValue: true, read: { ExteraEnergySettings.shared.isEnabled(feature) }, write: { ExteraEnergySettings.shared.setEnabled(feature, $0) })
    }

    private static let settingsByName: [String: Setting] = Dictionary(uniqueKeysWithValues: ExteraSettingsBackup.settings.map { ($0.name, $0) })

    /// Call on the main queue, as with the settings screen's property-wrapper setters.
    public static func exportData(sharedPreferences: SharedPreferences? = nil, iconPackBackup: Data? = nil) throws -> Data {
        precondition(Thread.isMainThread)
        var values: [String: Any] = [:]
        for setting in self.settings {
            let value = setting.read().json
            _ = try setting.rule.validate(value)
            values[setting.name] = value
        }
        var document: [String: Any] = ["format": self.format, "version": self.version, "settings": values]
        if let sharedPreferences {
            document["shared"] = [
                "showContactsTab": sharedPreferences.showContactsTab,
                "showCallsTab": sharedPreferences.showCallsTab,
                "foldersAtBottom": sharedPreferences.foldersAtBottom,
            ]
        }
        if let iconPackBackup {
            guard let iconObject = try JSONSerialization.jsonObject(with: iconPackBackup) as? [String: Any] else {
                throw BackupError.invalidValue
            }
            document["uiIconPacks"] = iconObject
        }
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= self.maximumFileSize else { throw BackupError.fileTooLarge }
        return data
    }

    /// Does not initialize the settings singletons or write anything. Unknown keys (including plugin keys)
    /// are rejected, even if another part of the application happens to recognize them.
    public static func validate(data: Data) throws -> ValidatedBackup {
        guard data.count <= self.maximumFileSize else { throw BackupError.fileTooLarge }
        try self.rejectDuplicateKeys(data)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BackupError.malformed
        }
        guard let document = object as? [String: Any],
            Set(document.keys).isSubset(of: ["format", "version", "settings", "shared", "uiIconPacks"]),
            document["format"] as? String == self.format,
            let rawVersion = document["version"],
            let values = document["settings"] as? [String: Any], !values.isEmpty else {
            throw BackupError.malformed
        }
        guard case let .integer(version) = try Rule.integer(1 ... Int(Int32.max)).validate(rawVersion), version == self.version else {
            throw BackupError.unsupportedVersion
        }
        var validated: [String: Value] = [:]
        for (name, value) in values {
            guard let setting = self.settingsByName[name] else { throw BackupError.unknownSetting }
            validated[name] = try setting.rule.validate(value)
        }
        let sharedPreferences: SharedPreferences?
        if let rawShared = document["shared"] {
            guard let shared = rawShared as? [String: Any], Set(shared.keys) == ["showContactsTab", "showCallsTab", "foldersAtBottom"],
                let rawContacts = shared["showContactsTab"], let rawCalls = shared["showCallsTab"], let rawFolders = shared["foldersAtBottom"],
                case let .boolean(contacts) = try Rule.boolean.validate(rawContacts),
                case let .boolean(calls) = try Rule.boolean.validate(rawCalls),
                case let .boolean(folders) = try Rule.boolean.validate(rawFolders) else {
                throw BackupError.invalidValue
            }
            sharedPreferences = SharedPreferences(showContactsTab: contacts, showCallsTab: calls, foldersAtBottom: folders)
        } else {
            sharedPreferences = nil
        }
        let iconPackBackupData: Data?
        if let rawIconBackup = document["uiIconPacks"] {
            guard let iconObject = rawIconBackup as? [String: Any] else { throw BackupError.invalidValue }
            iconPackBackupData = try JSONSerialization.data(withJSONObject: iconObject, options: [.sortedKeys])
        } else {
            iconPackBackupData = nil
        }
        return ValidatedBackup(values: validated, sharedPreferences: sharedPreferences, iconPackBackupData: iconPackBackupData)
    }

    /// Apply only a previously validated document. Missing allowlisted settings retain their current values.
    /// All writes go through the original setters so cached values and extension mirrors stay coherent.
    /// AI flags are encoded together before any other write, so a persistence error leaves the import unapplied.
    public static func apply(_ backup: ValidatedBackup) throws {
        precondition(Thread.isMainThread)
        var failure: Error?
        AyuSettingsStore.shared.performBatchUpdates {
            do {
                try self.write(backup.values)
                SGSimpleSettings.shared.synchronizeShared()
            } catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// The caller must obtain confirmation first. Writes defaults only to this same closed allowlist.
    /// SharedPreferences must additionally be reset by the UI using Telegram's own defaults.
    public static func reset() throws {
        precondition(Thread.isMainThread)
        var failure: Error?
        AyuSettingsStore.shared.performBatchUpdates {
            do {
                try self.write(Dictionary(uniqueKeysWithValues: self.settings.map { ($0.name, $0.defaultValue) }))
                SGSimpleSettings.shared.synchronizeShared()
            } catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// Keep the only throwing persistence operation first and apply its flags in one read/modify/write.
    /// Missing flags retain their current values; services, roles, credentials and history are untouched.
    private static func write(_ values: [String: Value]) throws {
        let aiSettings = self.settings.filter { ($0.aiFlag != nil || $0.aiWrite != nil) && values[$0.name] != nil }
        if !aiSettings.isEmpty {
            try ExteraAISettings.shared.update { configuration in
                for setting in aiSettings {
                    guard let value = values[setting.name] else { continue }
                    if let keyPath = setting.aiFlag, case let .boolean(flag) = value { configuration[keyPath: keyPath] = flag }
                    setting.aiWrite?(&configuration, value)
                }
            }
        }
        for setting in self.settings {
            if let value = values[setting.name] { setting.write?(value) }
        }
    }

    /// Validate UTF-8, grammar and duplicate keys before JSONSerialization, whose dictionary output
    /// has already lost duplicate keys. This also keeps acceptance independent of parser extensions
    /// such as trailing commas and caps nesting before Foundation allocates the object graph.
    private static func rejectDuplicateKeys(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else { throw BackupError.malformed }
        var validator = JSONStructureValidator(bytes: Array(data))
        try validator.validate()
    }

    private struct JSONStructureValidator {
        let bytes: [UInt8]
        var index = 0

        mutating func validate() throws {
            // A UTF-8 BOM is permitted at the start only, matching Foundation's JSON reader.
            if self.bytes.starts(with: [0xef, 0xbb, 0xbf]) { self.index = 3 }
            try self.value(depth: 0)
            self.whitespace()
            guard self.index == self.bytes.count else { throw BackupError.malformed }
        }

        mutating func whitespace() {
            while self.index < self.bytes.count, [9, 10, 13, 32].contains(self.bytes[self.index]) {
                self.index += 1
            }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            self.whitespace()
            guard self.index < self.bytes.count, self.bytes[self.index] == byte else { return false }
            self.index += 1
            return true
        }

        mutating func value(depth: Int) throws {
            self.whitespace()
            guard self.index < self.bytes.count else { throw BackupError.malformed }
            switch self.bytes[self.index] {
            case 123: // object
                guard depth < 16 else { throw BackupError.malformed }
                self.index += 1
                if self.consume(125) { return }
                var keys: Set<String> = []
                repeat {
                    let key = try self.string()
                    guard keys.insert(key).inserted, self.consume(58) else { throw BackupError.malformed }
                    try self.value(depth: depth + 1)
                    if self.consume(125) { return }
                    guard self.consume(44) else { throw BackupError.malformed }
                } while true
            case 91: // array
                guard depth < 16 else { throw BackupError.malformed }
                self.index += 1
                if self.consume(93) { return }
                repeat {
                    try self.value(depth: depth + 1)
                    if self.consume(93) { return }
                    guard self.consume(44) else { throw BackupError.malformed }
                } while true
            case 34:
                _ = try self.string()
            case 116: try self.literal(Array("true".utf8))
            case 102: try self.literal(Array("false".utf8))
            case 110: try self.literal(Array("null".utf8))
            case 45, 48 ... 57: try self.number()
            default: throw BackupError.malformed
            }
        }

        mutating func string() throws -> String {
            self.whitespace()
            let start = self.index
            guard self.consume(34) else { throw BackupError.malformed }
            while self.index < self.bytes.count {
                let byte = self.bytes[self.index]
                self.index += 1
                if byte == 34 {
                    do {
                        guard let string = try JSONSerialization.jsonObject(with: Data(self.bytes[start ..< self.index]), options: [.fragmentsAllowed]) as? String else {
                            throw BackupError.malformed
                        }
                        return string
                    } catch { throw BackupError.malformed }
                }
                guard byte >= 32 else { throw BackupError.malformed }
                if byte == 92 {
                    // Skip the escaped character; Foundation checks legal escapes and surrogate pairs.
                    guard self.index < self.bytes.count else { throw BackupError.malformed }
                    self.index += 1
                }
            }
            throw BackupError.malformed
        }

        mutating func literal(_ literal: [UInt8]) throws {
            guard self.bytes[self.index...].starts(with: literal) else { throw BackupError.malformed }
            self.index += literal.count
        }

        mutating func digits() -> Int {
            let start = self.index
            while self.index < self.bytes.count, (48 ... 57).contains(self.bytes[self.index]) { self.index += 1 }
            return self.index - start
        }

        mutating func number() throws {
            if self.bytes[self.index] == 45 { self.index += 1 }
            guard self.index < self.bytes.count else { throw BackupError.malformed }
            if self.bytes[self.index] == 48 {
                self.index += 1
            } else {
                guard self.digits() > 0 else { throw BackupError.malformed }
            }
            if self.index < self.bytes.count, self.bytes[self.index] == 46 {
                self.index += 1
                guard self.digits() > 0 else { throw BackupError.malformed }
            }
            if self.index < self.bytes.count, self.bytes[self.index] == 69 || self.bytes[self.index] == 101 {
                self.index += 1
                if self.index < self.bytes.count, self.bytes[self.index] == 43 || self.bytes[self.index] == 45 { self.index += 1 }
                guard self.digits() > 0 else { throw BackupError.malformed }
            }
        }
    }
}
