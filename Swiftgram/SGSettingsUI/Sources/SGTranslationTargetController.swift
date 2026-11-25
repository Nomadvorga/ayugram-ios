// MARK: AyuGram
// exteraGram's "General" tab has a global target language for translations. iOS keeps the target per chat, so this
// screen picks the language used whenever a chat has no target of its own.
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
import TranslateUI
import SGSimpleSettings
import SGStrings

private final class SGTranslationTargetControllerArguments {
    let selectLanguage: (String) -> Void

    init(selectLanguage: @escaping (String) -> Void) {
        self.selectLanguage = selectLanguage
    }
}

private enum SGTranslationTargetSection: Int32 {
    case languages
}

private enum SGTranslationTargetEntry: ItemListNodeEntry {
    case language(index: Int32, code: String, title: String, subtitle: String, checked: Bool)

    var section: ItemListSectionId {
        return SGTranslationTargetSection.languages.rawValue
    }

    var stableId: Int32 {
        switch self {
        case let .language(index, _, _, _, _):
            return index
        }
    }

    static func ==(lhs: SGTranslationTargetEntry, rhs: SGTranslationTargetEntry) -> Bool {
        switch lhs {
        case let .language(lhsIndex, lhsCode, lhsTitle, lhsSubtitle, lhsChecked):
            if case let .language(rhsIndex, rhsCode, rhsTitle, rhsSubtitle, rhsChecked) = rhs,
               lhsIndex == rhsIndex, lhsCode == rhsCode, lhsTitle == rhsTitle, lhsSubtitle == rhsSubtitle, lhsChecked == rhsChecked {
                return true
            }
            return false
        }
    }

    static func <(lhs: SGTranslationTargetEntry, rhs: SGTranslationTargetEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SGTranslationTargetControllerArguments
        switch self {
        case let .language(_, code, title, subtitle, checked):
            return LocalizationListItem(presentationData: presentationData, systemStyle: .glass, id: code, title: title, subtitle: subtitle, checked: checked, activity: false, loading: false, editing: LocalizationListItemEditing(editable: false, editing: false, revealed: false, reorderable: false), sectionId: self.section, alwaysPlain: false, action: {
                arguments.selectLanguage(code)
            }, setItemWithRevealedOptions: nil, removeItem: nil)
        }
    }
}

private func sgTranslationTargetEntries(strings: PresentationStrings, selectedCode: String) -> [SGTranslationTargetEntry] {
    let interfaceCode = strings.baseLanguageCode
    var interfaceLanguageName = interfaceCode
    var rawInterfaceCode = interfaceCode
    let rawSuffix = "-raw"
    if rawInterfaceCode.hasSuffix(rawSuffix) {
        rawInterfaceCode = String(rawInterfaceCode.dropLast(rawSuffix.count))
    }
    for code in supportedTranslationLanguages + ["zh-hans", "zh-hant"] {
        if normalizeTranslationLanguage(code) == normalizeTranslationLanguage(rawInterfaceCode), let name = Locale(identifier: interfaceCode).localizedString(forLanguageCode: code) {
            interfaceLanguageName = name.capitalized
            break
        }
    }

    let lang = interfaceCode
    var entries: [SGTranslationTargetEntry] = []
    entries.append(.language(index: 0, code: "", title: i18n("Extera.TranslationTargetDefault", lang), subtitle: interfaceLanguageName, checked: selectedCode.isEmpty))

    let enLocale = Locale(identifier: "en")
    var added = Set<String>()
    var orderedCodes: [String] = []
    for code in popularTranslationLanguages + supportedTranslationLanguages + ["zh-hans", "zh-hant"] {
        let normalized = normalizeTranslationLanguage(code)
        if added.contains(normalized) {
            continue
        }
        added.insert(normalized)
        orderedCodes.append(code)
    }

    var index: Int32 = 1
    for code in orderedCodes {
        guard let title = enLocale.localizedString(forLanguageCode: code) else {
            continue
        }
        let languageLocale = Locale(identifier: code)
        var subtitle = languageLocale.localizedString(forLanguageCode: code) ?? title
        if code == "zh-hans" || code == "zh-hant" {
            subtitle += " \(code)"
        }
        entries.append(.language(index: index, code: code, title: title.capitalized, subtitle: subtitle.capitalized, checked: normalizeTranslationLanguage(selectedCode) == normalizeTranslationLanguage(code)))
        index += 1
    }
    return entries
}

public func sgTranslationTargetController(context: AccountContext) -> ViewController {
    var selectLanguageImpl: ((String) -> Void)?

    let arguments = SGTranslationTargetControllerArguments(selectLanguage: { code in
        ExteraSettings.shared.translationTargetLanguage = code
        selectLanguageImpl?(code)
    })

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = presentationData.strings
        let entries = sgTranslationTargetEntries(strings: strings, selectedCode: ExteraSettings.shared.translationTargetLanguage)
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(i18n("Extera.TranslationTarget", strings.baseLanguageCode)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controller.alwaysSynchronous = true
    selectLanguageImpl = { [weak controller] _ in
        (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    return controller
}
