import Foundation
import AyuSettingsBackup

var passed = 0
var failed = 0
func check(_ label: String, _ expected: String, _ actual: String) {
    if expected == actual { passed += 1 } else { failed += 1; print("FAIL \(label): expected \(expected), actual \(actual)") }
}
func removeTestDefaults() {
    UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
    UserDefaults.standard.removePersistentDomain(forName: APP_GROUP_IDENTIFIER)
    UserDefaults(suiteName: APP_GROUP_IDENTIFIER)?.removePersistentDomain(forName: APP_GROUP_IDENTIFIER)
}
removeTestDefaults()
let settings = ExteraSettings.shared
let legacy = SGSimpleSettings.shared
let schema = settings.backupSchema()
let fresh = schema.export()
let extera = fresh.configs["exteraconfig"] ?? [:]
check("fresh export differs from itself", "0", "\(schema.differenceCount(fresh))")
check("fresh titleText is the app name", "0", "\(extera["titleText"]?.intValue ?? -1)")
check("fresh seek duration is index of 10 s", "1", "\(extera["doubleTapSeekDuration"]?.intValue ?? -1)")
check("fresh camera left to the iOS group", "nil 0", "\(extera["videoMessagesCamera"]?.intValue.map { "\($0)" } ?? "nil") \(fresh.configs["ayugramios"]?["videoMessagesCamera"]?.intValue ?? -1)")
check("fresh automatic currency left out", "nil", extera["inlineTargetCurrency"]?.stringValue ?? "nil")
check("fresh swipe is reply", "2", extera["swipeActions"]?.stringValue ?? "nil")
check("fresh file round trip", "true", "\(ExteraBackupDocument(fileData: fresh.fileData()) == fresh)")

let android = ExteraBackupDocument(fileData: Data("""
{"exteraconfig": {"relativeLastSeen": true, "filterZalgo": true, "showRepeatMessageButton": false, "titleText": 0, "doubleTapSeekDuration": 3,
 "videoMessagesCamera": 1, "avatarCorners": 13.0, "swipeActions": "4,3,44,4,1", "swipeActionsLoop": true, "doNotUseProxy": 5, "doubleTapAction": 5, "doubleTapActionOutOwner": 5,
 "stickerShape": 2, "inlineTargetCurrency": "EUR", "tabletMode": 1, "centerTitle": true}}
""".utf8))!
check("android backup recognized", "true", "\(schema.recognizes(android))")
// titleText 0 and the repeat button off are the defaults here.
check("android difference", "11", "\(schema.differenceCount(android))")
check("android applied", "13", "\(schema.apply(android))")
check("android swipe list, unknown and repeated ids dropped", "forward copy reactions | 4,3,1 | true false", "\(settings.swipeActions.map { "\($0)" }.joined(separator: " ")) | \(schema.export().configs["exteraconfig"]?["swipeActions"]?.stringValue ?? "nil") | \(settings.swipeActionsLoop) \(settings.swipeActionsReversed)")
check("android state", "true true false appName 30 back 12 forward 5 reactions edit roundedAsMessage EUR",
      "\(settings.relativeLastSeen) \(settings.filterZalgo) \(settings.showRepeatButton) \(settings.titleText) \(settings.doubleTapSeekDuration) \(settings.videoMessagesCamera) \(settings.avatarCorners) \(settings.swipeAction) \(settings.doNotUseProxy.rawValue) \(settings.doubleTapAction) \(settings.doubleTapActionOutgoing) \(settings.stickerShape) \(settings.inlineTargetCurrency)")
check("nothing differs after apply", "0", "\(schema.differenceCount(android))")

// Preferences kept in SGSimpleSettings.
func ints(_ config: [String: ExteraBackupValue], _ keys: [String]) -> String {
    return keys.map { key in config[key]?.intValue.map { "\($0)" } ?? "nil" }.joined(separator: " ")
}
func bools(_ config: [String: ExteraBackupValue], _ keys: [String]) -> String {
    return keys.map { key in config[key]?.boolValue.map { "\($0)" } ?? "nil" }.joined(separator: " ")
}
let legacyInts = ["downloadSpeedBoost", "showIdAndDc", "bottomButton", "stickerTimeMode", "bottomNavigationBarMode"]
let iosConfig = fresh.configs["ayugramios"] ?? [:]
check("fresh legacy numbers are stock", "0 0 1 0 0", ints(extera, legacyInts))
check("fresh legacy switches are stock", "false false true true true false", bools(extera, ["formatTimeWithSeconds", "hideNavigationBarLabels", "quickTransitionForChannels", "quickTransitionForTopics", "showReportButton", "hideCameraTile"]))
check("fresh iOS numbers", "100 0", ints(iosConfig, ["accountColorsSaturation", "allChatsTitleLengthOverride"]))
check("fresh iOS switches", "false true true false", bools(iosConfig, ["compactChatList", "contextShowPin", "tabBarSearchEnabled", "hideReactions"]))

// Values iOS has fewer states for keep the nearest one, and do not count as a change when that is the current one.
let androidLegacy = ExteraBackupDocument(fileData: Data("""
{"exteraconfig": {"formatTimeWithSeconds": true, "downloadSpeedBoost": 2, "showIdAndDc": 2, "bottomButton": 2, "stickerTimeMode": 1,
 "bottomNavigationBarMode": 2, "hideNavigationBarLabels": true, "quickTransitionForTopics": false, "showReportButton": false,
 "hidePhoneNumber": true, "stickerSize": 14.0}}
""".utf8))!
check("android legacy difference", "7", "\(schema.differenceCount(androidLegacy))")
check("android legacy applied", "10", "\(schema.apply(androidLegacy))")
check("android legacy state", "true maximum true true false true false false true false true",
      "\(legacy.secondsInMessages) \(legacy.downloadSpeedBoost) \(legacy.showProfileId) \(legacy.showDC) \(legacy.hideChannelBottomButton) \(legacy.stickerTimestamp) \(legacy.hideTabBar) \(legacy.showTabNames) \(legacy.disableScrollToNextTopic) \(legacy.contextShowReport) \(legacy.hidePhoneInSettings)")
check("android legacy export", "2 2 1 0 0", ints(schema.export().configs["exteraconfig"] ?? [:], legacyInts))
check("nothing differs after legacy apply", "0", "\(schema.differenceCount(androidLegacy))")

let androidOff = ExteraBackupDocument(fileData: Data("""
{"exteraconfig": {"downloadSpeedBoost": 3, "showIdAndDc": 0, "bottomButton": 0, "stickerTimeMode": 2, "bottomNavigationBarMode": 1}}
""".utf8))!
check("android off difference, out of range refused", "4 4", "\(schema.differenceCount(androidOff)) \(schema.apply(androidOff))")
check("android off state", "maximum false false true false true",
      "\(legacy.downloadSpeedBoost) \(legacy.showProfileId) \(legacy.showDC) \(legacy.hideChannelBottomButton) \(legacy.stickerTimestamp) \(legacy.hideTabBar)")
check("android off export", "2 0 0 2 1", ints(schema.export().configs["exteraconfig"] ?? [:], legacyInts))

let iosLegacy = ExteraBackupDocument(fileData: Data("""
{"ayugramios": {"accountColorsSaturation": 40, "allChatsTitleLengthOverride": 2, "compactChatList": true, "contextShowPin": false,
 "hideAccountInNotifications": true, "wideTabBar": 1}}
""".utf8))!
check("iOS legacy difference, wrong type refused", "5 5", "\(schema.differenceCount(iosLegacy)) \(schema.apply(iosLegacy))")
check("iOS legacy state", "40 long true false true false",
      "\(legacy.accountColorsSaturation) \(legacy.allChatsTitleLengthOverride) \(legacy.compactChatList) \(legacy.contextShowPin) \(legacy.hideAccountInNotifications) \(legacy.wideTabBar)")
let saturationOutOfRange = ExteraBackupDocument(fileData: Data("{\"ayugramios\": {\"accountColorsSaturation\": 101}}".utf8))!
check("saturation out of range refused", "false", "\(schema.recognizes(saturationOutOfRange))")

// The AyuGram stores.
let ghost = AyuGhostSettings.shared
let customization = AyuCustomizationSettings.shared
check("fresh ayu switches", "true false true false true true", bools(iosConfig, ["ayu.ghost.hideReadMessages", "ayu.ghost.useScheduledMessages", "ayu.saveDeletedMessages", "ayu.confirm.sticker", "ayu.disableAds", "ayu.showDeletedMarker"]))
check("fresh ayu numbers", "0 0 0", ints(iosConfig, ["ayu.ghost.sendWithoutSound", "ayu.deletedMark", "ayu.deletedMarkColor"]))
check("fresh reactions under Android's names", "false false", bools(extera, ["hideReactionsInChannels", "hideReactionsInGroups"]))
check("ghost mode, last seen, camera and lists are not exported", "true",
      "\(iosConfig.keys.allSatisfy { !$0.hasSuffix("ghostMode") && !$0.contains("lastSeen") && !$0.contains("camera.") && !$0.contains("exclusion") && !$0.contains("shadow") })")
check("ayu entry count in the iOS group", "34", "\(iosConfig.keys.filter { $0.hasPrefix("ayu.") }.count)")

ghost.setGhostModeActive(true)
let ayu = ExteraBackupDocument(fileData: Data("""
{"exteraconfig": {"hideReactionsInChannels": true},
 "ayugramios": {"ayu.ghost.ghostMode": false, "ayu.ghost.hideTyping": false, "ayu.ghost.sendWithoutSound": 2, "ayu.ghost.lastSeen": 5,
  "ayu.saveForBots": true, "ayu.confirm.voice": true, "ayu.deletedMark": 4, "ayu.deletedMarkColor": 5, "ayu.hideFromBlocked": true,
  "ayu.camera.roundVideoBack": true}}
""".utf8))!
check("ayu difference, unknown and out of range refused", "7 7", "\(schema.differenceCount(ayu)) \(schema.apply(ayu))")
check("ayu state", "true false true false always true true eyeCrossed red true",
      "\(customization.hideChannelReactions) \(customization.hideGroupReactions) \(ghost.isGhostModeActive) \(ghost.value(.hideTyping)) \(ghost.sendWithoutSound) \(AyuSaveSettings.shared.saveForBots) \(AyuSendConfirmations.shared.isEnabled(.voice)) \(customization.deletedMark) \(customization.deletedMarkColor) \(customization.hideFromBlocked)")
check("nothing differs after ayu apply", "0", "\(schema.differenceCount(ayu))")

// Back to the first state through its own export.
check("restore difference", "32", "\(schema.differenceCount(fresh))")
schema.apply(fresh)
check("restored", "true", "\(schema.export() == fresh)")
check("restored camera and currency", "lastUsed []", "\(settings.videoMessagesCamera) [\(settings.inlineTargetCurrency)]")
check("restored legacy", "false none false true false 100", "\(legacy.secondsInMessages) \(legacy.downloadSpeedBoost) \(legacy.hideTabBar) \(legacy.stickerTimestamp) \(legacy.hideAccountInNotifications) \(legacy.accountColorsSaturation)")
check("restored ayu, ghost mode untouched", "false true never trashBin true", "\(customization.hideChannelReactions) \(ghost.value(.hideTyping)) \(ghost.sendWithoutSound) \(customization.deletedMark) \(ghost.isGhostModeActive)")

// The swipe list: one action until a list is saved, an empty list is "off".
check("restored swipe list", "reply | reply", "\(settings.swipeActions.map { "\($0)" }.joined(separator: " ")) | \(settings.swipeAction)")
settings.swipeAction = .disable
check("swipe off", "0 disable []", "\(settings.swipeActions.count) \(settings.swipeAction) [\(schema.export().configs["exteraconfig"]?["swipeActions"]?.stringValue ?? "nil")]")
check("malformed swipe list refused", "false false", "\(schema.recognizes(ExteraBackupDocument(fileData: Data("{\"exteraconfig\": {\"swipeActions\": \"2,,3\"}}".utf8))!)) \(schema.recognizes(ExteraBackupDocument(fileData: Data("{\"exteraconfig\": {\"swipeActions\": \"2, 3\"}}".utf8))!))")
settings.swipeActions = [.reply]
typealias Swipe = ExteraSettings.DoubleTapAction
func names(_ actions: [Swipe]) -> String {
    return actions.map { "\($0)" }.joined(separator: " ")
}
check("an action switched on takes its place in exteraGram's order", "reactions delete copy translate | delete translate | copy delete translate | reply delete forward copy",
      "\(names(Swipe.swipeList([.delete, .copy, .translate], toggling: .reactions))) | \(names(Swipe.swipeList([.delete, .copy, .translate], toggling: .copy))) | \(names(Swipe.swipeList([.delete, .translate], toggling: .copy))) | \(names(Swipe.swipeList([.reply, .delete, .copy], toggling: .forward)))")
check("disable is not a swipe action", "reply", names(Swipe.swipeList([.reply], toggling: .disable)))
check("moving an action", "copy reply delete | delete reply copy | reply delete copy | copy reply delete | reply copy delete",
      "\(names(Swipe.swipeList([.reply, .copy, .delete], moving: .copy, to: .reply, downwards: false))) | \(names(Swipe.swipeList([.reply, .copy, .delete], moving: .delete, to: .reply, downwards: false))) | \(names(Swipe.swipeList([.reply, .copy, .delete], moving: .copy, to: .delete, downwards: true))) | \(names(Swipe.swipeList([.reply, .copy, .delete], moving: .copy, to: nil, downwards: false))) | \(names(Swipe.swipeList([.reply, .copy, .delete], moving: .forward, to: .reply, downwards: true)))")

// The account manager's switches come from the caller.
check("no account switches without values", "nil", "\(iosConfig["showContactsTab"]?.boolValue.map { "\($0)" } ?? "nil")")
var storedAccountSwitches: [String] = []
let accountSchema = settings.backupSchema(accountSwitches: [.showContactsTab: true, .foldersAtBottom: false], setAccountSwitch: { accountSwitch, value in
    storedAccountSwitches.append("\(accountSwitch.rawValue)=\(value)")
})
let accountFresh = accountSchema.export()
check("account switches exported to the iOS group", "true nil false nil",
      ["showContactsTab", "showCallsTab", "foldersAtBottom"].map { accountFresh.configs["ayugramios"]?[$0]?.boolValue.map { "\($0)" } ?? "nil" }.joined(separator: " ") + " \(accountFresh.configs["exteraconfig"]?["showContactsTab"]?.boolValue.map { "\($0)" } ?? "nil")")
let accountBackup = ExteraBackupDocument(fileData: Data("""
{"ayugramios": {"showContactsTab": false, "showCallsTab": false, "foldersAtBottom": false}}
""".utf8))!
check("account switch difference, the one without a value skipped", "1 2", "\(accountSchema.differenceCount(accountBackup)) \(accountSchema.apply(accountBackup))")
check("account switches stored through the caller", "showContactsTab=false foldersAtBottom=false", storedAccountSwitches.joined(separator: " "))
check("nothing differs after account apply", "0", "\(accountSchema.differenceCount(accountBackup))")
check("wrong type refused", "false", "\(accountSchema.recognizes(ExteraBackupDocument(fileData: Data("{\"ayugramios\": {\"showContactsTab\": 1}}".utf8))!))")

// The translation service: exteraGram's index, Apple's translation only in the iOS group.
func providerDocument(_ json: String) -> ExteraBackupDocument {
    return ExteraBackupDocument(fileData: Data(json.utf8))!
}
func exportedProvider() -> String {
    let exported = schema.export()
    return "\(exported.configs["exteraconfig"]?["translationProvider"]?.intValue.map { "\($0)" } ?? "nil") \(exported.configs["ayugramios"]?["translationBackend"]?.stringValue ?? "nil")"
}
check("fresh provider is Telegram", "0 default", exportedProvider())
check("yandex from exteraGram", "1 1 yandex", "\(schema.differenceCount(providerDocument("{\"exteraconfig\": {\"translationProvider\": 2}}"))) \(schema.apply(providerDocument("{\"exteraconfig\": {\"translationProvider\": 2}}"))) \(legacy.translationBackendEnum)")
check("yandex exported in both groups", "2 yandex", exportedProvider())
check("microsoft, unknown indexes refused", "true false microsoft", { () -> String in
    let recognized = "\(schema.recognizes(providerDocument("{\"exteraconfig\": {\"translationProvider\": 3}}"))) \(schema.recognizes(providerDocument("{\"exteraconfig\": {\"translationProvider\": 4}}")))"
    schema.apply(providerDocument("{\"exteraconfig\": {\"translationProvider\": 3}}"))
    return recognized + " \(legacy.translationBackendEnum)"
}())
check("system wins over the index in an iOS file", "system", { () -> String in
    schema.apply(providerDocument("{\"exteraconfig\": {\"translationProvider\": 1}, \"ayugramios\": {\"translationBackend\": \"system\"}}"))
    return "\(legacy.translationBackendEnum)"
}())
check("system left out of exteraGram's group", "nil system", exportedProvider())
check("unknown backend name refused", "false", "\(schema.recognizes(providerDocument("{\"ayugramios\": {\"translationBackend\": \"deepl\"}}")))")
func targetDocument(_ value: String) -> ExteraBackupDocument {
    return providerDocument("{\"exteraconfig\": {\"targetLang\": \"\(value)\"}}")
}
check("fresh target follows the app", "app", fresh.configs["exteraconfig"]?["targetLang"]?.stringValue ?? "nil")
check("target language keeps the language of a regional code", "1 pt pt 0", { () -> String in
    let applied = schema.apply(targetDocument("pt-BR"))
    return "\(applied) \(settings.targetLang) \(schema.export().configs["exteraconfig"]?["targetLang"]?.stringValue ?? "nil") \(schema.differenceCount(targetDocument("pt-BR")))"
}())
check("target language in use", "pt ru", "\(settings.translationTargetLanguage(appLanguage: "ru")) \({ () -> String in schema.apply(targetDocument("app")); return settings.translationTargetLanguage(appLanguage: "ru") }())")
check("norwegian as the services name it, malformed codes refused", "no false false false", { () -> String in
    schema.apply(targetDocument("nb"))
    return "\(settings.targetLang) \(schema.recognizes(targetDocument("p"))) \(schema.recognizes(targetDocument("русский"))) \(schema.recognizes(targetDocument("en us")))"
}())
schema.apply(fresh)
check("provider restored", "0 default", exportedProvider())

removeTestDefaults()
print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
