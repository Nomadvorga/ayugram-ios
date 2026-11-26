import AccountContext
import Display
import Foundation
import ItemListUI
import SGItemListUI
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramPresentationData

private enum ExteraStyleSection: Int32, SGItemListSection {
    case controls, sections, blur
}

private enum ExteraStyleToggle: Hashable {
    case separateHeaders, glassMessageMenu, forceBlur
}

private enum ExteraStyleSlider: Hashable {
    case sectionRadius
}

private enum ExteraStyleChoice: Hashable {
    case controlStyle, separatorStyle, glassBorder
}

private typealias ExteraStyleRow = SGItemListUIEntry<ExteraStyleSection, ExteraStyleToggle, ExteraStyleSlider, ExteraStyleChoice, Int, Int>
private typealias ExteraStyleArguments = SGItemListArguments<ExteraStyleToggle, ExteraStyleSlider, ExteraStyleChoice, Int, Int>

private func exteraStyleSeparatorTitle(_ value: ExteraStyleSettings.SeparatorStyle, language: String) -> String {
    switch value {
    case .line: return i18n("Extera.Style.Separator.Line", language)
    case .fullWidth: return i18n("Extera.Style.Separator.FullWidth", language)
    case .none: return i18n("Extera.Style.None", language)
    }
}

private func exteraStyleBorderTitle(_ value: ExteraStyleSettings.GlassBorder, language: String) -> String {
    switch value {
    case .none: return i18n("Extera.Style.None", language)
    case .line: return i18n("Extera.Style.GlassBorder.Line", language)
    case .highlights: return i18n("Extera.Style.GlassBorder.Highlights", language)
    }
}

/// All choices remain editable while effects are temporarily limited by energy
/// or accessibility. Consumers apply those limits without rewriting style intent.
public func exteraStyleSettingsController(context: AccountContext) -> ViewController {
    let settings = ExteraStyleSettings.shared
    var chooseImpl: ((ExteraStyleChoice) -> Void)?
    let storeChanges = Signal<Bool, NoError> { subscriber in
        // Subscribe before the initial publication so an external write cannot
        // disappear between the first persisted read and observer registration.
        let observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { _ in
            subscriber.putNext(true)
        }
        subscriber.putNext(true)
        return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
    }
    let signal = combineLatest(context.sharedContext.presentationData, storeChanges)
    |> deliverOnMainQueue
    |> map { data, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let language = data.strings.baseLanguageCode
        func text(_ suffix: String) -> String { return i18n("Extera.Style.\(suffix)", language) }
        let appearance = exteraSettingsAppearance()
        let arguments = ExteraStyleArguments(
            context: context,
            visualStyle: .extera,
            exteraAppearance: appearance,
            setBoolValue: { setting, value in
                switch setting {
                case .separateHeaders: settings.separateHeaders = value
                case .glassMessageMenu: settings.glassMessageMenu = value
                case .forceBlur: settings.forceBlur = value
                }
            },
            updateSliderValue: { setting, value in
                switch setting {
                case .sectionRadius: settings.sectionRadius = Int(value)
                }
            },
            setOneFromManyValue: { chooseImpl?($0) },
            setSegmentedValue: { setting, value in
                guard setting == .controlStyle, let style = ExteraStyleSettings.ControlStyle(rawValue: value) else { return }
                settings.controlStyle = style
            }
        )
        let entries: [ExteraStyleRow] = [
            .header(id: 0, section: .controls, text: text("ControlStyle"), badge: nil),
            .appearanceStyle(id: 1, section: .controls, settingName: .controlStyle, value: settings.controlStyle.rawValue, options: [text("Classic"), text("Material")], enabled: true),
            .header(id: 10, section: .sections, text: text("Sections"), badge: nil),
            .valueSlider(id: 11, section: .sections, settingName: .sectionRadius, configuration: SGItemListRangeConfiguration(
                value: Int32(settings.sectionRadius),
                minimum: Int32(ExteraStyleSettings.minimumSectionRadius),
                maximum: Int32(ExteraStyleSettings.maximumSectionRadius),
                step: 1,
                title: text("SectionRadius"),
                minimumLabel: text("Off"),
                maximumLabel: text("Maximum"),
                unitSuffix: text("PointUnit")
            ), enabled: true),
            .toggle(id: 12, section: .sections, settingName: .separateHeaders, value: settings.separateHeaders, text: text("SeparateHeaders"), enabled: true),
            .oneFromManySelector(id: 13, section: .sections, settingName: .separatorStyle, text: text("Separators"), value: exteraStyleSeparatorTitle(settings.separatorStyle, language: language), enabled: true),
            .header(id: 20, section: .blur, text: text("Blur"), badge: nil),
            .oneFromManySelector(id: 21, section: .blur, settingName: .glassBorder, text: text("GlassBorder"), value: exteraStyleBorderTitle(settings.glassBorder, language: language), enabled: true),
            .toggleSubtitle(id: 22, section: .blur, settingName: .glassMessageMenu, value: settings.glassMessageMenu, text: text("GlassMessageMenu"), subtitle: text("GlassMessageMenu.Info"), enabled: true),
            .toggleSubtitle(id: 23, section: .blur, settingName: .forceBlur, value: settings.forceBlur, text: text("ForceBlur"), subtitle: text("ForceBlur.Info"), enabled: true)
        ]
        // Use this concrete wrapper from the first state, including headers and
        // unchanged rows: appearance alone must invalidate their ItemList equality.
        let styledEntries = entries.map { SGStyledItemListEntry(entry: $0, appearance: appearance) }
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(data),
            title: .text(text("Title")),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: data.strings.Common_Back),
            animateChanges: false
        )
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(data), entries: styledEntries, style: .blocks, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    chooseImpl = { [weak controller] choice in
        guard let controller else { return }
        let data = context.sharedContext.currentPresentationData.with { $0 }
        let language = data.strings.baseLanguageCode
        let options: [SGOneFromManyOption]
        switch choice {
        case .controlStyle:
            return // The two style tiles write through setSegmentedValue.
        case .separatorStyle:
            options = ExteraStyleSettings.SeparatorStyle.allCases.map { value in
                SGOneFromManyOption(title: exteraStyleSeparatorTitle(value, language: language), isSelected: value == settings.separatorStyle, action: {
                    settings.separatorStyle = value
                })
            }
        case .glassBorder:
            options = ExteraStyleSettings.GlassBorder.allCases.map { value in
                SGOneFromManyOption(title: exteraStyleBorderTitle(value, language: language), isSelected: value == settings.glassBorder, action: {
                    settings.glassBorder = value
                })
            }
        }
        sgPresentOneFromManySelector(controller: controller, setting: choice, presentationData: data, options: options)
    }
    return controller
}
