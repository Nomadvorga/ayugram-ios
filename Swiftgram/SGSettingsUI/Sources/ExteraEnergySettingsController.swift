import AccountContext
import Display
import Foundation
import ItemListUI
import SGItemListUI
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UIKit

private enum ExteraEnergySection: Int32, SGItemListSection {
    case activation, effects, transitions
}

private enum ExteraEnergyToggle: Hashable {
    case followSystem, autoplayVideo, autoplayGif, smoothTransitions
    case group(ExteraEnergySettings.Group)
    case feature(ExteraEnergySettings.Feature)
}

private typealias ExteraEnergyRow = SGItemListUIEntry<ExteraEnergySection, ExteraEnergyToggle, Int, Int, Int, Int>
private typealias ExteraEnergyArguments = SGItemListArguments<ExteraEnergyToggle, Int, Int, Int, Int>

private enum ExteraEnergyEntry: ItemListNodeEntry {
    case row(ExteraEnergyRow)
    case threshold(value: Int32, active: Bool, followsSystem: Bool, title: String, status: String, never: String, always: String)

    var stableId: Int {
        switch self { case let .row(row): return row.stableId; case .threshold: return 1 }
    }
    var section: ItemListSectionId {
        switch self { case let .row(row): return row.section; case .threshold: return ExteraEnergySection.activation.rawValue }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.stableId < rhs.stableId }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! (ExteraEnergyArguments, (Int32) -> Void)
        switch self {
        case let .row(row): return row.item(presentationData: presentationData, arguments: arguments.0)
        case let .threshold(value, active, followsSystem, title, status, never, always):
            return ExteraEnergyThresholdItem(theme: presentationData.theme, value: value, active: active, enabled: !followsSystem, title: title, status: status, never: never, always: always, updated: arguments.1)
        }
    }
}

/// A focused child is expanded before the first transaction. The root owns navigation/search
/// registration; revealing a group never changes its saved choices.
public func exteraEnergySettingsController(context: AccountContext, focusOnFeature: ExteraEnergySettings.Feature? = nil) -> ViewController {
    typealias Settings = ExteraEnergySettings
    var expanded = Set<Settings.Group>()
    if let group = focusOnFeature?.group { expanded.insert(group) }
    let refresh = ValuePromise(true, ignoreRepeated: false)

    func nativeEnabled(_ feature: Settings.Feature, settings: EnergyUsageSettings) -> Bool {
        switch feature {
        case .stickerKeyboard, .stickerChat: return settings.loopStickers
        case .emojiKeyboard, .emojiReactions, .emojiChat: return settings.loopEmoji
        case .spoilers, .blur, .calls, .particles: return settings.fullTranslucency
        default: return true
        }
    }
    func updateNative(_ f: @escaping (inout EnergyUsageSettings) -> Void) {
        let _ = updateMediaDownloadSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
            var settings = settings
            f(&settings.energyUsageSettings)
            return settings
        }).start()
    }
    func enableNativeGroup(_ group: Settings.Group, _ enabled: Bool) {
        updateNative { settings in
            switch group {
            case .stickers: settings.loopStickers = enabled
            case .emoji: settings.loopEmoji = enabled
            case .chat: settings.fullTranslucency = enabled
            }
        }
    }
    func prepareEffectsCeiling(_ native: EnergyUsageSettings) {
        guard !native.fullTranslucency else { return }
        // The native effects switch previously disabled all four. Raising it for one
        // child must preserve the others' configured off state, across group boundaries.
        for feature in [Settings.Feature.spoilers, .blur, .calls, .particles] {
            Settings.shared.setEnabled(feature, false)
        }
    }
    let arguments = ExteraEnergyArguments(context: context, visualStyle: .extera, setBoolValue: { toggle, value in
        switch toggle {
        case .followSystem: Settings.shared.followSystem = value
        case .smoothTransitions:
            let _ = updatePresentationThemeSettingsInteractively(accountManager: context.sharedContext.accountManager, { $0.withUpdatedReduceMotion(!value) }).start()
        case .autoplayVideo:
            guard !ExteraEnergyRuntime.savingActive else { return }
            updateNative { $0.autoplayVideo = value }
        case .autoplayGif:
            guard !ExteraEnergyRuntime.savingActive else { return }
            updateNative { $0.autoplayGif = value }
        case let .group(group):
            guard !ExteraEnergyRuntime.savingActive else { return }
            if value && group == .chat {
                prepareEffectsCeiling(context.sharedContext.currentAutomaticMediaDownloadSettings.energyUsageSettings)
            }
            Settings.shared.setGroup(group, value)
            if value { enableNativeGroup(group, true) }
        case let .feature(feature):
            guard !ExteraEnergyRuntime.savingActive else { return }
            let native = context.sharedContext.currentAutomaticMediaDownloadSettings.energyUsageSettings
            if value, !nativeEnabled(feature, settings: native), let group = feature.group {
                // Enabling one child of a disabled native group must not also enable its siblings.
                if group == .chat {
                    prepareEffectsCeiling(native)
                } else {
                    Settings.shared.setGroup(group, false)
                }
                enableNativeGroup(group, true)
            } else if value, feature.group == nil, !native.fullTranslucency {
                prepareEffectsCeiling(native)
                updateNative { $0.fullTranslucency = true }
            }
            Settings.shared.setEnabled(feature, value)
        }
        refresh.set(true)
    }, setExpanded: { toggle, value in
        guard case let .group(group) = toggle else { return }
        if value { expanded.insert(group) } else { expanded.remove(group) }
        refresh.set(true)
    })
    let updateThreshold: (Int32) -> Void = { value in
        guard !Settings.shared.followSystem else { return }
        updateNative { $0.activationThreshold = max(4, min(96, value)) }
    }
    let signal = combineLatest(
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.automaticMediaDownloadSettings, ApplicationSpecificSharedDataKeys.presentationThemeSettings]),
        refresh.get(), exteraEnergyEnvironmentChanges()
    ) |> deliverOnMainQueue |> map { data, sharedData, _, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = data.strings.baseLanguageCode
        func text(_ suffix: String) -> String { return i18n("Extera.Energy.\(suffix)", lang) }
        let native = (sharedData.entries[ApplicationSpecificSharedDataKeys.automaticMediaDownloadSettings]?.get(MediaAutoDownloadSettings.self) ?? .defaultSettings).energyUsageSettings
        let theme = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationThemeSettings]?.get(PresentationThemeSettings.self) ?? .defaultSettings
        ExteraEnergyRuntime.updateNativeThreshold(native.activationThreshold)
        let saving = ExteraEnergyRuntime.savingActive
        let selected = Set(Settings.Feature.allCases.filter { Settings.shared.isEnabled($0) && nativeEnabled($0, settings: native) })
        var entries: [ExteraEnergyEntry] = []
        func append(_ row: ExteraEnergyRow) { entries.append(.row(row)) }
        entries.append(.threshold(value: native.activationThreshold, active: saving, followsSystem: Settings.shared.followSystem, title: data.strings.PowerSavingScreen_Title, status: text(saving ? "Active" : "Inactive"), never: text("Never"), always: text("Always")))
        append(.toggle(id: 2, section: .activation, settingName: .followSystem, value: Settings.shared.followSystem, text: text("FollowSystem"), enabled: true))
        append(.notice(id: 3, section: .activation, text: text(Settings.shared.followSystem ? "FollowSystemInfo" : "ThresholdInfo")))
        append(.header(id: 90, section: .effects, text: data.strings.PowerSavingScreen_OptionsHeader, badge: nil))
        for (index, group) in Settings.Group.allCases.enumerated() {
            let id = 100 + index * 100
            let state = Settings.GroupState(group: group, selectedFeatures: selected)
            append(.expandableToggle(id: id, section: .effects, settingName: .group(group), value: state.isOn, text: text("Group.\(group.rawValue)"), selectedCount: state.selected, totalCount: state.total, isExpanded: expanded.contains(group), enabled: !saving))
            if expanded.contains(group) {
                for (childIndex, feature) in group.features.enumerated() {
                    append(.checkbox(id: id + childIndex + 1, section: .effects, settingName: .feature(feature), value: selected.contains(feature), text: text("Feature.\(feature.rawValue)"), enabled: !saving))
                }
            }
        }
        append(.toggle(id: 400, section: .effects, settingName: .feature(.calls), value: selected.contains(.calls), text: text("Feature.calls"), enabled: !saving))
        append(.toggle(id: 401, section: .effects, settingName: .autoplayVideo, value: native.autoplayVideo, text: data.strings.PowerSavingScreen_OptionAutoplayVideoTitle, enabled: !saving))
        append(.toggle(id: 402, section: .effects, settingName: .autoplayGif, value: native.autoplayGif, text: data.strings.PowerSavingScreen_OptionAutoplayGifTitle, enabled: !saving))
        append(.toggle(id: 403, section: .effects, settingName: .feature(.particles), value: selected.contains(.particles), text: text("Feature.particles"), enabled: !saving))
        append(.notice(id: 404, section: .effects, text: text(saving ? "SavingInfo" : "AccessibilityInfo")))
        append(.toggle(id: 500, section: .transitions, settingName: .smoothTransitions, value: !theme.reduceMotion, text: text("SmoothTransitions"), enabled: true))
        append(.notice(id: 501, section: .transitions, text: text("SmoothTransitionsInfo")))
        return (ItemListControllerState(presentationData: ItemListPresentationData(data), title: .text(data.strings.PowerSavingScreen_Title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: data.strings.Common_Back), animateChanges: false), (ItemListNodeState(presentationData: ItemListPresentationData(data), entries: entries, style: .blocks, animateChanges: !data.reduceMotion && !UIAccessibility.isReduceMotionEnabled), (arguments, updateThreshold)))
    }
    return ItemListController(context: context, state: signal)
}
