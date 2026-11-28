import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import AppBundle
import SGSimpleSettings
import SGStrings
import SGItemListUI

// MARK: AyuGram
// exteraGram "Swipe Actions": which actions a swipe to the left on a message offers and in what order
// (SwipeActionsPreferencesActivity). The first runs on a plain swipe.

private final class AyuSwipeActionsArguments {
    let toggleAction: (ExteraSettings.DoubleTapAction) -> Void
    let setSwitch: (ExteraSettings.Keys, Bool) -> Void

    init(toggleAction: @escaping (ExteraSettings.DoubleTapAction) -> Void, setSwitch: @escaping (ExteraSettings.Keys, Bool) -> Void) {
        self.toggleAction = toggleAction
        self.setSwitch = setSwitch
    }
}

private enum AyuSwipeActionsSection: Int32 {
    case enabled
    case disabled
    case behavior
}

private enum AyuSwipeActionsEntry: ItemListNodeEntry {
    case header(index: Int32, section: AyuSwipeActionsSection, text: String)
    case action(index: Int32, action: ExteraSettings.DoubleTapAction, title: String, isEnabled: Bool)
    case info(index: Int32, section: AyuSwipeActionsSection, text: String)
    case toggle(index: Int32, key: ExteraSettings.Keys, title: String, value: Bool)

    var section: ItemListSectionId {
        switch self {
        case let .header(_, section, _), let .info(_, section, _):
            return section.rawValue
        case let .action(_, _, _, isEnabled):
            return (isEnabled ? AyuSwipeActionsSection.enabled : AyuSwipeActionsSection.disabled).rawValue
        case .toggle:
            return AyuSwipeActionsSection.behavior.rawValue
        }
    }

    // An action keeps its id wherever it stands, so a reorder moves its row.
    var stableId: Int32 {
        switch self {
        case let .header(_, section, _):
            return 100 + section.rawValue
        case let .info(_, section, _):
            return 200 + section.rawValue
        case let .action(_, action, _, _):
            return 300 + Int32(action.rawValue)
        case let .toggle(_, key, _, _):
            return key == .swipeActionsLoop ? 400 : 401
        }
    }

    private var index: Int32 {
        switch self {
        case let .header(index, _, _), let .action(index, _, _, _), let .info(index, _, _), let .toggle(index, _, _, _):
            return index
        }
    }

    static func <(lhs: AyuSwipeActionsEntry, rhs: AyuSwipeActionsEntry) -> Bool {
        return lhs.index < rhs.index
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AyuSwipeActionsArguments
        switch self {
        case let .header(_, _, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .action(_, action, title, isEnabled):
            let icon = action.menuIconName.flatMap { generateTintedImage(image: UIImage(bundleImageName: $0), color: isEnabled ? presentationData.theme.list.itemAccentColor : presentationData.theme.list.itemSecondaryTextColor) }
            return AyuReorderableIconItem(presentationData: presentationData, systemStyle: .glass, icon: icon, title: title, reorderable: isEnabled, sectionId: self.section, action: {
                arguments.toggleAction(action)
            })
        case let .info(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .toggle(_, key, title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setSwitch(key, value)
            })
        }
    }
}

private func ayuSwipeActionTitle(_ action: ExteraSettings.DoubleTapAction, lang: String) -> String {
    switch action {
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

// What the settings row shows: the action of a plain swipe and how many more can be picked.
func ayuSwipeActionsSummary(lang: String) -> String {
    let actions = ExteraSettings.shared.swipeActions
    guard let first = actions.first else {
        return i18n("Extera.DoubleTapDisable", lang)
    }
    let title = ayuSwipeActionTitle(first, lang: lang)
    return actions.count > 1 ? "\(title) +\(actions.count - 1)" : title
}

private func ayuSwipeActionsEntries(lang: String) -> [AyuSwipeActionsEntry] {
    let settings = ExteraSettings.shared
    let enabled = settings.swipeActions
    let disabled = ExteraSettings.DoubleTapAction.swipeListCases.filter { !enabled.contains($0) }

    var entries: [AyuSwipeActionsEntry] = []
    var index: Int32 = 0
    func append(_ make: (Int32) -> AyuSwipeActionsEntry) {
        entries.append(make(index))
        index += 1
    }

    if !enabled.isEmpty {
        append { .header(index: $0, section: .enabled, text: i18n("Extera.SwipeActions.Enabled", lang).uppercased()) }
        for action in enabled {
            append { .action(index: $0, action: action, title: ayuSwipeActionTitle(action, lang: lang), isEnabled: true) }
        }
        append { .info(index: $0, section: .enabled, text: i18n("Extera.SwipeActions.OrderInfo", lang)) }
    }

    if !disabled.isEmpty {
        append { .header(index: $0, section: .disabled, text: i18n("Extera.SwipeActions.Disabled", lang).uppercased()) }
        for action in disabled {
            append { .action(index: $0, action: action, title: ayuSwipeActionTitle(action, lang: lang), isEnabled: false) }
        }
        if enabled.isEmpty {
            append { .info(index: $0, section: .disabled, text: i18n("Extera.SwipeActions.EmptyInfo", lang)) }
        }
    }

    append { .header(index: $0, section: .behavior, text: i18n("Extera.SwipeActions.Behavior", lang).uppercased()) }
    append { .toggle(index: $0, key: .swipeActionsLoop, title: i18n("Extera.SwipeActions.Loop", lang), value: settings.swipeActionsLoop) }
    append { .toggle(index: $0, key: .swipeActionsReversed, title: i18n("Extera.SwipeActions.Reversed", lang), value: settings.swipeActionsReversed) }
    append { .info(index: $0, section: .behavior, text: i18n("Extera.SwipeActions.BehaviorInfo", lang)) }

    return entries
}

// `updated` runs after every change, for the screen that shows the summary.
func ayuSwipeActionsController(context: AccountContext, updated: @escaping () -> Void) -> ViewController {
    let changes = ValuePromise<Int>(0, ignoreRepeated: true)
    var changeCount = 0
    let changed: () -> Void = {
        changeCount += 1
        changes.set(changeCount)
        updated()
    }

    let arguments = AyuSwipeActionsArguments(toggleAction: { action in
        ExteraSettings.shared.swipeActions = ExteraSettings.DoubleTapAction.swipeList(ExteraSettings.shared.swipeActions, toggling: action)
        changed()
    }, setSwitch: { key, value in
        ExteraSettings.shared.set(key, value)
        changed()
    })

    let signal = combineLatest(context.sharedContext.presentationData, changes.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(i18n("Extera.SwipeActions", lang)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: ayuSwipeActionsEntries(lang: lang), style: .blocks)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.setReorderEntry({ (fromIndex: Int, toIndex: Int, entries: [AyuSwipeActionsEntry]) -> Signal<Bool, NoError> in
        guard fromIndex < entries.count, case let .action(_, action, _, true) = entries[fromIndex] else {
            return .single(false)
        }
        var reference: ExteraSettings.DoubleTapAction?
        var downwards = fromIndex < toIndex
        if toIndex < entries.count {
            if case let .action(_, target, _, true) = entries[toIndex] {
                reference = target
            } else {
                // Dropped on a header, a footer or among the disabled ones: the nearest end of the list.
                downwards = !(entries[toIndex] < entries[fromIndex])
            }
        } else {
            downwards = true
        }
        let current = ExteraSettings.shared.swipeActions
        let reordered = ExteraSettings.DoubleTapAction.swipeList(current, moving: action, to: reference, downwards: downwards)
        if reordered == current {
            return .single(false)
        }
        ExteraSettings.shared.swipeActions = reordered
        changed()
        return .single(true)
    })
    return controller
}
