// MARK: AyuGram
// The exteraGram tab: exteraGram's preferences that the iOS client has, under exteraGram's names and categories.
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
    case appearance
    case chatList
    case chats
    case gestures
    case media
}

private enum SGBoolSetting: String {
    case hidePhoneNumber
    case showIdAndDc
    case uploadSpeedBoost
    case formatTimeWithSeconds
    case hideStories
    case hideAllChats
    case hideNavigationBarLabels
    case showNavigationBar
    case showContactsTab
    case widePosts
    case bottomButton
    case hideSendAsPeer
    case quickTransitions
    case stickerTime
    case hideCameraTile
    case showCreationDate
    case doubleTapOutgoingEdit
}

private enum SGOneFromManySetting: String {
    case downloadSpeedBoost
}

private enum SGSliderSetting: String {
    case unused
}

private enum SGDisclosureLink: String {
    case categoryGeneral
    case categoryAppearance
    case categoryChats
}

public enum SGSettingsCategory {
    case general
    case appearance
    case chats

    fileprivate var sections: Set<SGControllerSection> {
        switch self {
        case .general:
            return [.general, .speedBoost]
        case .appearance:
            return [.appearance, .chatList]
        case .chats:
            return [.chats, .gestures, .media]
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
        }
    }
}

private struct SGSettingsControllerState: Equatable {
    var searchQuery: String?
}

private typealias SGControllerEntry = SGItemListUIEntry<SGControllerSection, SGBoolSetting, SGSliderSetting, SGOneFromManySetting, SGDisclosureLink, AnyHashable>

private func SGControllerEntries(presentationData: PresentationData, callListSettings: CallListSettings, state: SGSettingsControllerState, category: SGSettingsCategory?) -> [SGControllerEntry] {
    let allEntries = SGControllerAllEntries(presentationData: presentationData, callListSettings: callListSettings, state: state)
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
    return entries
}

private func SGControllerAllEntries(presentationData: PresentationData, callListSettings: CallListSettings, state: SGSettingsControllerState) -> [SGControllerEntry] {
    let lang = presentationData.strings.baseLanguageCode
    let strings = presentationData.strings
    let settings = SGSimpleSettings.shared
    var entries: [SGControllerEntry] = []
    let id = SGItemListCounter()

    entries.append(.searchInput(id: id.count, section: .search, title: NSAttributedString(string: "🔍"), text: state.searchQuery ?? "", placeholder: strings.Common_Search))

    entries.append(.toggle(id: id.count, section: .general, settingName: .hidePhoneNumber, value: settings.hidePhoneInSettings, text: i18n("Extera.HidePhoneNumber", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .general, settingName: .showIdAndDc, value: settings.showProfileId && settings.showDC, text: i18n("Extera.ShowIdAndDc", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .general, text: i18n("Extera.ShowIdAndDcInfo", lang)))
    entries.append(.toggle(id: id.count, section: .general, settingName: .formatTimeWithSeconds, value: settings.secondsInMessages, text: i18n("Extera.FormatTimeWithSeconds", lang), enabled: true))

    entries.append(.oneFromManySelector(id: id.count, section: .speedBoost, settingName: .downloadSpeedBoost, text: i18n("Extera.DownloadSpeedBoost", lang), value: downloadSpeedBoostTitle(settings.downloadSpeedBoost, lang: lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .speedBoost, settingName: .uploadSpeedBoost, value: settings.uploadSpeedBoost, text: i18n("Extera.UploadSpeedBoost", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .speedBoost, text: i18n("Extera.SpeedBoostInfo", lang)))

    entries.append(.header(id: id.count, section: .appearance, text: i18n("Extera.Appearance", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .hideStories, value: settings.hideStories, text: i18n("Extera.HideStories", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .showNavigationBar, value: !settings.hideTabBar, text: i18n("Extera.BottomNavigationBarMode", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .hideNavigationBarLabels, value: !settings.showTabNames, text: i18n("Extera.HideNavigationBarLabels", lang), enabled: !settings.hideTabBar))
    entries.append(.toggle(id: id.count, section: .appearance, settingName: .showContactsTab, value: callListSettings.showContactsTab, text: i18n("Extera.ShowContactsTab", lang), enabled: !settings.hideTabBar))

    entries.append(.header(id: id.count, section: .chatList, text: i18n("Extera.ListOfChats", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .chatList, settingName: .hideAllChats, value: settings.allChatsHidden, text: i18n("Extera.HideAllChats", lang, strings.ChatList_Tabs_AllChats), enabled: true))

    entries.append(.header(id: id.count, section: .chats, text: i18n("Ayu.CategoryChats", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .widePosts, value: settings.wideChannelPosts, text: i18n("Extera.WidePosts", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .bottomButton, value: !settings.hideChannelBottomButton, text: i18n("Extera.BottomButton", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .quickTransitions, value: !settings.disableScrollToNextChannel, text: i18n("Extera.QuickTransitions", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .stickerTime, value: settings.stickerTimestamp, text: i18n("Extera.StickerTimeMode", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .showCreationDate, value: settings.showCreationDate, text: i18n("Extera.CreationDate", lang), enabled: true))
    entries.append(.toggle(id: id.count, section: .chats, settingName: .hideSendAsPeer, value: settings.disableSendAsButton, text: i18n("Extera.HideSendAsPeer", lang), enabled: true))
    entries.append(.notice(id: id.count, section: .chats, text: i18n("Extera.HideSendAsPeerInfo", lang)))

    entries.append(.header(id: id.count, section: .gestures, text: i18n("Extera.Gestures", lang).uppercased(), badge: nil))
    entries.append(.toggle(id: id.count, section: .gestures, settingName: .doubleTapOutgoingEdit, value: settings.messageDoubleTapActionOutgoing == SGSimpleSettings.MessageDoubleTapAction.edit.rawValue, text: i18n("Extera.DoubleTapOutgoingEdit", lang), enabled: true))

    entries.append(.toggle(id: id.count, section: .media, settingName: .hideCameraTile, value: settings.disableGalleryCamera, text: i18n("Extera.HideCameraTile", lang), enabled: true))

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
        case .hidePhoneNumber:
            settings.hidePhoneInSettings = value
            askForRestart?()
        case .showIdAndDc:
            settings.showProfileId = value
            settings.showDC = value
        case .uploadSpeedBoost:
            settings.uploadSpeedBoost = value
        case .formatTimeWithSeconds:
            settings.secondsInMessages = value
        case .hideStories:
            settings.hideStories = value
        case .hideAllChats:
            settings.allChatsHidden = value
            askForRestart?()
        case .hideNavigationBarLabels:
            settings.showTabNames = !value
            askForRestart?()
        case .showNavigationBar:
            settings.hideTabBar = !value
            simplePromise.set(true)
            askForRestart?()
        case .showContactsTab:
            let _ = updateCallListSettingsInteractively(accountManager: context.sharedContext.accountManager, { $0.withUpdatedShowContactsTab(value) }).start()
        case .widePosts:
            settings.wideChannelPosts = value
        case .bottomButton:
            settings.hideChannelBottomButton = !value
        case .hideSendAsPeer:
            settings.disableSendAsButton = value
        case .quickTransitions:
            settings.disableScrollToNextChannel = !value
            settings.disableScrollToNextTopic = !value
        case .stickerTime:
            settings.stickerTimestamp = value
        case .hideCameraTile:
            settings.disableGalleryCamera = value
        case .showCreationDate:
            settings.showCreationDate = value
        case .doubleTapOutgoingEdit:
            settings.messageDoubleTapActionOutgoing = value ? SGSimpleSettings.MessageDoubleTapAction.edit.rawValue : SGSimpleSettings.MessageDoubleTapAction.default.rawValue
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
        }
    }, searchInput: { searchQuery in
        updateState { state in
            var updatedState = state
            updatedState.searchQuery = searchQuery
            return updatedState
        }
    })

    let sharedData = context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.callListSettings])
    let signal = combineLatest(simplePromise.get(), statePromise.get(), context.sharedContext.presentationData, sharedData)
    |> map { _, state, presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let callListSettings: CallListSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.callListSettings]?.get(CallListSettings.self) ?? CallListSettings.defaultSettings
        let entries = SGControllerEntries(presentationData: presentationData, callListSettings: callListSettings, state: state, category: category)
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
