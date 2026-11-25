import AccountContext
import AVFoundation
import Display
import Foundation
import ItemListUI
import SettingsUI
import SGItemListUI
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramCore
import TelegramAudio
import TelegramPresentationData
import TelegramUIPreferences
import UIKit

private enum ExteraChatAppearanceSection: Int32, SGItemListSection {
    case appearance
    case chatList
    case icon
    case swipe
    case behavior
    case media
    case other
}

private enum ExteraChatAppearanceToggle: Hashable {
    case tapForNextMedia
    case raiseToListen
    case pauseRecording
    case sendWithCmdEnter
}

private enum ExteraChatAppearanceLink: Hashable {
    case appearance
    case icon
    case autoNight
    case browser
    case animations
    case stickers
    case microphonePermission
    case share
}

private enum ExteraChatAppearanceChoice: Hashable {
    case distance
    case microphone
}

private typealias ExteraChatAppearanceSetting = SGItemListUIEntry<ExteraChatAppearanceSection, ExteraChatAppearanceToggle, Int, ExteraChatAppearanceChoice, ExteraChatAppearanceLink, Int>
private typealias ExteraChatAppearanceSettingsArguments = SGItemListArguments<ExteraChatAppearanceToggle, Int, ExteraChatAppearanceChoice, ExteraChatAppearanceLink, Int>

private struct ExteraChatAppearanceArguments {
    let settings: ExteraChatAppearanceSettingsArguments
    let setLines: (SGSimpleSettings.ChatListLines) -> Void
    let setSwipe: (ExteraChatAppearanceSettings.SwipeAction) -> Void
}

private enum ExteraChatAppearanceEntry: ItemListNodeEntry {
    case setting(ExteraChatAppearanceSetting)
    case lines(id: Int, value: SGSimpleSettings.ChatListLines, two: String, three: String)
    case swipe(id: Int, value: ExteraChatAppearanceSettings.SwipeAction, titles: [String])

    var stableId: Int {
        switch self {
        case let .setting(entry): return entry.stableId
        case let .lines(id, _, _, _): return id
        case let .swipe(id, _, _): return id
        }
    }

    var section: ItemListSectionId {
        switch self {
        case let .setting(entry): return entry.section
        case .lines: return ExteraChatAppearanceSection.chatList.rawValue
        case .swipe: return ExteraChatAppearanceSection.swipe.rawValue
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.stableId < rhs.stableId }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ExteraChatAppearanceArguments
        switch self {
        case let .setting(entry):
            return entry.item(presentationData: presentationData, arguments: arguments.settings)
        case let .lines(_, value, two, three):
            return ExteraChatLinesItem(theme: presentationData.theme, value: value, two: two, three: three, updated: arguments.setLines)
        case let .swipe(_, value, titles):
            return ExteraChatSwipePreviewItem(theme: presentationData.theme, sectionId: self.section, value: value, titles: titles, updated: arguments.setSwipe)
        }
    }
}

/// Chat appearance and media settings backed by the same preferences as Telegram's native screens.
/// Push with Display.NavigationController; the caller owns the category entry point.
public func exteraChatAppearanceSettingsController(context: AccountContext) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?
    var chooseDistanceImpl: (() -> Void)?
    var chooseMicrophoneImpl: (() -> Void)?
    var updateMicrophoneSheetImpl: (() -> Void)?
    let refresh = ValuePromise(true, ignoreRepeated: false)
    let settingsArguments = ExteraChatAppearanceSettingsArguments(context: context, visualStyle: .extera, setBoolValue: { setting, value in
        switch setting {
        case .tapForNextMedia:
            let _ = updateMediaDisplaySettingsInteractively(accountManager: context.sharedContext.accountManager, {
                $0.withUpdatedShowNextMediaOnTap(value)
            }).start()
        case .raiseToListen:
            let _ = updateMediaInputSettingsInteractively(accountManager: context.sharedContext.accountManager, {
                $0.withUpdatedEnableRaiseToSpeak(value)
            }).start()
        case .pauseRecording:
            let _ = updateMediaInputSettingsInteractively(accountManager: context.sharedContext.accountManager, {
                $0.withUpdatedPauseMusicOnRecording(value)
            }).start()
        case .sendWithCmdEnter:
            let _ = updateChatSettingsInteractively(accountManager: context.sharedContext.accountManager, {
                $0.withUpdatedSendWithCmdEnter(value)
            }).start()
        }
    }, setOneFromManyValue: { choice in
        switch choice {
        case .distance: chooseDistanceImpl?()
        case .microphone: chooseMicrophoneImpl?()
        }
    }, openDisclosureLink: { link in
        switch link {
        case .appearance:
            pushImpl?(themeSettingsController(context: context, focusOnItemTag: .fontSize))
        case .icon:
            pushImpl?(exteraAppIconController(context: context))
        case .autoNight:
            pushImpl?(themeAutoNightSettingsController(context: context))
        case .browser:
            pushImpl?(webBrowserSettingsController(context: context))
        case .animations:
            pushImpl?(exteraEnergySettingsController(context: context))
        case .stickers:
            pushImpl?(context.sharedContext.makeInstalledStickerPacksController(context: context, mode: .general, forceTheme: nil))
        case .microphonePermission:
            context.sharedContext.applicationBindings.openSettings()
        case .share:
            if #available(iOS 13.0, *) {
                pushImpl?(intentsSettingsController(context: context))
            }
        }
    })
    let arguments = ExteraChatAppearanceArguments(settings: settingsArguments, setLines: { value in
        SGSimpleSettings.shared.chatListLines = value.rawValue
        refresh.set(true)
    }, setSwipe: { value in
        ExteraChatAppearanceSettings.shared.swipeAction = value
        refresh.set(true)
    })
    let sharedData = context.sharedContext.accountManager.sharedData(keys: Set([
        ApplicationSpecificSharedDataKeys.mediaDisplaySettings,
        ApplicationSpecificSharedDataKeys.mediaInputSettings,
        ApplicationSpecificSharedDataKeys.chatSettings,
        ApplicationSpecificSharedDataKeys.presentationThemeSettings
    ]))
    let microphoneEvents = Signal<Bool, NoError> { subscriber in
        let names = [AVAudioSession.routeChangeNotification, UIApplication.didBecomeActiveNotification, ayuSettingsDidChangeNotification]
        let observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in subscriber.putNext(true) }
        }
        subscriber.putNext(true)
        return ActionDisposable {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    }
    let signal = combineLatest(context.sharedContext.presentationData, sharedData, refresh.get(), microphoneEvents)
    |> deliverOnMainQueue
    |> map { presentationData, sharedData, _, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        updateMicrophoneSheetImpl?()
        let strings = presentationData.strings
        let lang = strings.baseLanguageCode
        let media = sharedData.entries[ApplicationSpecificSharedDataKeys.mediaDisplaySettings]?.get(MediaDisplaySettings.self) ?? .defaultSettings
        let input = sharedData.entries[ApplicationSpecificSharedDataKeys.mediaInputSettings]?.get(MediaInputSettings.self) ?? .defaultSettings
        let chat = sharedData.entries[ApplicationSpecificSharedDataKeys.chatSettings]?.get(ChatSettings.self) ?? .defaultSettings
        let theme = sharedData.entries[ApplicationSpecificSharedDataKeys.presentationThemeSettings]?.get(PresentationThemeSettings.self) ?? .defaultSettings
        let nightMode: String
        switch theme.currentModeAutomaticThemeSwitchSetting.trigger {
        case .explicitNone: nightMode = strings.AutoNightTheme_Disabled
        case .system: nightMode = strings.AutoNightTheme_System
        case .timeBased: nightMode = strings.AutoNightTheme_Scheduled
        case .brightness: nightMode = strings.AutoNightTheme_Automatic
        }
        let id = SGItemListCounter()
        var entries: [ExteraChatAppearanceEntry] = []
        func append(_ entry: ExteraChatAppearanceSetting) { entries.append(.setting(entry)) }
        append(.disclosureSubtitle(id: id.count, section: .appearance, link: .appearance, text: strings.Appearance_TextSizeSetting, subtitle: strings.Appearance_Title, iconName: "textformat.size"))
        append(.header(id: id.count, section: .chatList, text: i18n("Extera.ListOfChats", lang), badge: nil))
        let lines = SGSimpleSettings.ChatListLines(rawValue: SGSimpleSettings.shared.chatListLines) ?? .defaultValue
        entries.append(.lines(id: id.count, value: lines, two: i18n("Settings.ChatList.Lines.2", lang), three: i18n("Settings.ChatList.Lines.3", lang)))
        // Preserve the existing one-line mode until the user explicitly chooses two or three.
        append(.disclosureSubtitle(id: id.count, section: .icon, link: .icon, text: strings.Appearance_AppIcon, subtitle: "", iconName: "app"))
        append(.header(id: id.count, section: .swipe, text: i18n("Extera.ChatAppearance.SwipeTitle", lang), badge: nil))
        entries.append(.swipe(id: id.count, value: ExteraChatAppearanceSettings.shared.swipeAction, titles: [
            i18n("Extera.ChatAppearance.SwipeFolder", lang), strings.DialogList_Pin, strings.DialogList_Read,
            strings.ChatList_ArchiveAction, strings.ChatList_Mute, strings.Common_Delete
        ]))
        append(.notice(id: id.count, section: .swipe, text: i18n("Extera.ChatAppearance.SwipeInfo", lang)))
        append(.disclosureSubtitle(id: id.count, section: .behavior, link: .autoNight, text: strings.Appearance_AutoNightTheme, subtitle: nightMode, iconName: "moon"))
        append(.disclosureSubtitle(id: id.count, section: .behavior, link: .browser, text: strings.WebBrowser_Title, subtitle: "", iconName: "globe"))
        append(.disclosureSubtitle(id: id.count, section: .behavior, link: .animations, text: strings.AppearanceSettings_Animations, subtitle: "", iconName: "play.circle"))
        append(.disclosureSubtitle(id: id.count, section: .behavior, link: .stickers, text: strings.ChatSettings_StickersAndReactions, subtitle: "", iconName: "face.smiling"))
        append(.header(id: id.count, section: .media, text: i18n("Extera.ChatAppearance.MediaAndSound", lang), badge: nil))
        append(.toggle(id: id.count, section: .media, settingName: .tapForNextMedia, value: media.showNextMediaOnTap, text: strings.Appearance_ShowNextMediaOnTap, enabled: true))
        append(.toggleSubtitle(id: id.count, section: .media, settingName: .raiseToListen, value: input.enableRaiseToSpeak, text: strings.Settings_RaiseToListen, subtitle: strings.Settings_RaiseToListenInfo, enabled: true))
        append(.toggle(id: id.count, section: .media, settingName: .pauseRecording, value: input.pauseMusicOnRecording, text: strings.Settings_PauseMusicOnRecording, enabled: true))
        let microphone = ExteraChatAppearanceSettings.shared.microphone
        let microphoneAvailable = ExteraChatAppearanceSettings.microphoneOptions(inputs: currentRecordingMicrophonePorts() ?? []).contains(microphone)
        let microphoneValue = i18n("Extera.ChatAppearance.Microphone.\(microphone.rawValue)", lang) + (microphoneAvailable ? "" : " · " + i18n("Extera.ChatAppearance.MicrophoneUnavailable", lang))
        append(.oneFromManySelector(id: id.count, section: .media, settingName: .microphone, text: i18n("Extera.ChatAppearance.Microphone", lang), value: microphoneValue, enabled: true))
        append(.notice(id: id.count, section: .media, text: i18n("Extera.ChatAppearance.MicrophoneRoutingInfo", lang)))
        if ManagedAudioSessionImpl.respectsSystemRecordingInput {
            append(.notice(id: id.count, section: .media, text: i18n("Extera.ChatAppearance.MicrophoneSystemOverride", lang)))
        }
        append(.disclosureSubtitle(id: id.count, section: .media, link: .microphonePermission, text: i18n("Extera.ChatAppearance.MicrophonePermission", lang), subtitle: i18n("Extera.ChatAppearance.MicrophoneInfo", lang), iconName: "mic"))
        append(.header(id: id.count, section: .other, text: strings.ChatSettings_Other, badge: nil))
        if #available(iOS 13.0, *) {
            append(.disclosureSubtitle(id: id.count, section: .other, link: .share, text: strings.ChatSettings_IntentsSettings, subtitle: i18n("Extera.ChatAppearance.ShareInfo", lang), iconName: "square.and.arrow.up"))
        }
        // This native setting controls a hardware keyboard's Command-Enter behavior.
        if #available(iOS 13.4, *) {
            append(.toggle(id: id.count, section: .other, settingName: .sendWithCmdEnter, value: chat.sendWithCmdEnter, text: strings.Appearance_SendWithCmdEnter, enabled: true))
        }
        append(.oneFromManySelector(id: id.count, section: .other, settingName: .distance, text: i18n("Extera.ChatAppearance.DistanceUnits", lang), value: i18n("Extera.ChatAppearance.Distance.\(ExteraChatAppearanceSettings.shared.distanceUnit.rawValue)", lang), enabled: true))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(i18n("Extera.ChatSettings", lang)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks)
        return (controllerState, (listState, arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { _ in refresh.set(true) }
    chooseDistanceImpl = { [weak controller] in
        guard let controller else { return }
        let data = context.sharedContext.currentPresentationData.with { $0 }
        let current = ExteraChatAppearanceSettings.shared.distanceUnit
        let options = ExteraChatAppearanceSettings.DistanceUnit.allCases.map { unit in
            SGOneFromManyOption(title: i18n("Extera.ChatAppearance.Distance.\(unit.rawValue)", data.strings.baseLanguageCode), isSelected: unit == current, action: {
                ExteraChatAppearanceSettings.shared.distanceUnit = unit
                refresh.set(true)
            })
        }
        sgPresentOneFromManySelector(controller: controller, setting: ExteraChatAppearanceChoice.distance, presentationData: data, options: options)
    }
    chooseMicrophoneImpl = { [weak controller] in
        guard let controller else { return }
        let sheet = ActionSheetController(presentationData: context.sharedContext.currentPresentationData.with { $0 })
        updateMicrophoneSheetImpl = { [weak sheet] in
            guard let sheet else { return }
            let data = context.sharedContext.currentPresentationData.with { $0 }
            let lang = data.strings.baseLanguageCode
            let inputs = currentRecordingMicrophonePorts()
            let available = ExteraChatAppearanceSettings.microphoneOptions(inputs: inputs ?? [])
            let selected = ExteraChatAppearanceSettings.shared.microphone
            var header = i18n("Extera.ChatAppearance.Microphone", lang)
            var items: [ActionSheetItem] = []
            for choice in ExteraChatAppearanceSettings.Microphone.allCases {
                let candidate = ExteraChatAppearanceSettings.preferredRecordingInput(microphone: choice, inputs: inputs ?? [], currentInputUIDs: AVAudioSession.sharedInstance().currentRoute.inputs.map { $0.uid })
                let title = i18n("Extera.ChatAppearance.Microphone.\(choice.rawValue)", lang)
                if let candidate { header += "\n\(title): \(candidate.name)" }
                let enabled = available.contains(choice)
                items.append(ActionSheetButtonItem(title: title, color: enabled ? .accent : .disabled, font: choice == selected ? .bold : .default, enabled: enabled, action: { [weak sheet] in
                    // A port can disappear between rendering the sheet and receiving the tap.
                    guard ExteraChatAppearanceSettings.microphoneOptions(inputs: currentRecordingMicrophonePorts() ?? []).contains(choice) else { refresh.set(true); return }
                    ExteraChatAppearanceSettings.shared.microphone = choice
                    sheet?.dismissAnimated()
                    refresh.set(true)
                }))
            }
            // Device names belong in the multiline header, not in the sheet's single-line buttons.
            items.insert(ActionSheetTextItem(title: header, parseMarkdown: false), at: 0)
            if inputs == nil || inputs?.isEmpty == true {
                items.append(ActionSheetTextItem(title: i18n("Extera.ChatAppearance.MicrophoneAvailabilityInfo", lang), parseMarkdown: false))
            }
            if ManagedAudioSessionImpl.respectsSystemRecordingInput {
                items.append(ActionSheetTextItem(title: i18n("Extera.ChatAppearance.MicrophoneSystemOverride", lang), parseMarkdown: false))
            }
            sheet.setItemGroups([
                ActionSheetItemGroup(items: items),
                ActionSheetItemGroup(items: [ActionSheetButtonItem(title: data.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak sheet] in sheet?.dismissAnimated() })])
            ])
        }
        sheet.dismissed = { _ in updateMicrophoneSheetImpl = nil }
        updateMicrophoneSheetImpl?()
        controller.present(sheet, in: .window(.root))
    }
    pushImpl = { [weak controller] next in
        (controller?.navigationController as? NavigationController)?.pushViewController(next)
    }
    return controller
}

/// A page-local preview keeps the shared SGItemListUI API independent of this screen.
private final class ExteraChatLinesItem: ListViewItem, ItemListItem {
    let sectionId = ExteraChatAppearanceSection.chatList.rawValue
    let theme: PresentationTheme
    let value: SGSimpleSettings.ChatListLines
    let two: String
    let three: String
    let updated: (SGSimpleSettings.ChatListLines) -> Void

    init(theme: PresentationTheme, value: SGSimpleSettings.ChatListLines, two: String, three: String, updated: @escaping (SGSimpleSettings.ChatListLines) -> Void) {
        self.theme = theme
        self.value = value
        self.two = two
        self.three = three
        self.updated = updated
    }

    private func layout(params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors) -> ListViewItemNodeLayout {
        let itemNeighbors = itemListNeighbors(item: self, topFacet: neighbors.previous?.base(ItemListNeighborFacet.self), bottomFacet: neighbors.next?.base(ItemListNeighborFacet.self))
        let cardWidth = params.width - max(13.0, params.leftInset) - max(13.0, params.rightInset)
        let labelWidth = max(1.0, (cardWidth - 40.0) * 0.5)
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let labelHeight = [self.two, self.three].map {
            ($0 as NSString).boundingRect(with: CGSize(width: labelWidth, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin, attributes: [.font: font], context: nil).height
        }.max() ?? font.lineHeight
        return ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: 132.0 + ceil(labelHeight)), insets: itemListNeighborsGroupedInsets(itemNeighbors, params))
    }

    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, neighbors: ListViewItemNeighbors, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        let layout = self.layout(params: params, neighbors: neighbors)
        Queue.mainQueue().async {
            let node = ExteraChatLinesNode()
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            completion(node, { (nil, { _ in node.apply(item: self, params: params, size: layout.contentSize) }) })
        }
    }

    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, neighbors: ListViewItemNeighbors, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        let layout = self.layout(params: params, neighbors: neighbors)
        Queue.mainQueue().async {
            guard let node = node() as? ExteraChatLinesNode else { return }
            completion(layout, { _ in node.apply(item: self, params: params, size: layout.contentSize) })
        }
    }
}

private final class ExteraChatLinesNode: ListViewItemNode {
    private let card = UIView()
    private let two = ExteraChatLinesOption(lines: .two)
    private let three = ExteraChatLinesOption(lines: .three)

    init() {
        super.init(layerBacked: false)
        self.view.addSubview(self.card)
        self.card.addSubview(self.two)
        self.card.addSubview(self.three)
        self.card.layer.cornerRadius = 22.0
    }

    func apply(item: ExteraChatLinesItem, params: ListViewItemLayoutParams, size: CGSize) {
        let left = max(13.0, params.leftInset)
        let right = max(13.0, params.rightInset)
        let width = max(0.0, size.width - left - right)
        self.card.frame = CGRect(x: left, y: 0.0, width: width, height: size.height)
        self.card.backgroundColor = SGItemListVisualStyle.extera.cardColor(theme: item.theme)
        let optionWidth = max(0.0, (width - 32.0) * 0.5)
        self.two.frame = CGRect(x: 12.0, y: 10.0, width: optionWidth, height: size.height - 20.0)
        self.three.frame = CGRect(x: 20.0 + optionWidth, y: 10.0, width: optionWidth, height: size.height - 20.0)
        self.two.update(theme: item.theme, title: item.two, selected: item.value == .two, action: { item.updated(.two) })
        self.three.update(theme: item.theme, title: item.three, selected: item.value == .three, action: { item.updated(.three) })
    }
}

private final class ExteraChatLinesOption: UIControl {
    private let lines: SGSimpleSettings.ChatListLines
    private let label = UILabel()
    private var theme: PresentationTheme?
    private var selectedOption = false
    private var action: (() -> Void)?

    init(lines: SGSimpleSettings.ChatListLines) {
        self.lines = lines
        super.init(frame: .zero)
        self.isOpaque = false
        self.label.numberOfLines = 0
        self.label.textAlignment = .center
        self.label.adjustsFontForContentSizeCategory = true
        self.label.isAccessibilityElement = false
        self.addSubview(self.label)
        self.isAccessibilityElement = true
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { preconditionFailure() }

    func update(theme: PresentationTheme, title: String, selected: Bool, action: @escaping () -> Void) {
        self.theme = theme
        self.selectedOption = selected
        self.action = action
        self.label.text = title
        self.label.font = .preferredFont(forTextStyle: .subheadline)
        self.label.textColor = theme.list.itemPrimaryTextColor
        self.accessibilityLabel = title
        self.accessibilityTraits = selected ? [.button, .selected] : [.button]
        self.setNeedsLayout()
        self.setNeedsDisplay()
    }

    @objc private func pressed() { self.action?() }

    override func accessibilityActivate() -> Bool {
        self.action?()
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.label.frame = CGRect(x: 2.0, y: 108.0, width: max(0.0, self.bounds.width - 4.0), height: max(0.0, self.bounds.height - 108.0))
    }

    override func draw(_ rect: CGRect) {
        guard let theme = self.theme else { return }
        let width = self.bounds.width
        let outline = UIBezierPath(roundedRect: CGRect(x: 1.0, y: 1.0, width: max(0.0, width - 2.0), height: 96.0), cornerRadius: 10.0)
        theme.list.itemSecondaryTextColor.withAlphaComponent(0.06).setFill()
        outline.fill()
        (self.selectedOption ? theme.list.itemAccentColor : theme.list.itemSecondaryTextColor.withAlphaComponent(0.2)).setStroke()
        outline.lineWidth = self.selectedOption ? 2.0 : 1.0
        outline.stroke()
        for row in 0 ..< 2 {
            let y = 16.0 + CGFloat(row) * 40.0
            theme.list.itemSecondaryTextColor.withAlphaComponent(0.25).setFill()
            UIBezierPath(ovalIn: CGRect(x: 10.0, y: y, width: 22.0, height: 22.0)).fill()
            for line in 0 ..< (self.lines == .two ? 2 : 3) {
                let bar = CGRect(x: 39.0, y: y + 2.0 + CGFloat(line) * 7.0, width: max(0.0, width - 76.0) * (line == 0 ? 0.65 : 1.0), height: 4.0)
                UIBezierPath(roundedRect: bar, cornerRadius: 2.0).fill()
            }
        }
        let radio = CGRect(x: max(0.0, width - 27.0), y: 40.0, width: 18.0, height: 18.0)
        (self.selectedOption ? theme.list.itemAccentColor : theme.list.itemSecondaryTextColor).setStroke()
        let ring = UIBezierPath(ovalIn: radio)
        ring.lineWidth = 2.0
        ring.stroke()
        if self.selectedOption {
            theme.list.itemAccentColor.setFill()
            UIBezierPath(ovalIn: radio.insetBy(dx: 4.0, dy: 4.0)).fill()
        }
    }
}
