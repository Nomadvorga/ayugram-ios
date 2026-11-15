import SGSettingsUI
import SGStrings
import UndoUI
//
import AccountContext
import ContactListUI
import ContextUI
import Display
import Foundation
import OverlayStatusController
import Postbox
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit
import ChatControllerInteraction
import ChatPresentationInterfaceState

func sgHandleInternalUrlRoute(context: AccountContext, parsedUrl: URL, navigationController: NavigationController?) -> Bool {
    guard let path = parsedUrl.pathComponents.last else {
        return false
    }
    switch path {
    case "debug":
        if let debugController = context.sharedContext.makeDebugSettingsController(context: context) {
            navigationController?.pushViewController(debugController)
            return true
        }
    case "settings":
        navigationController?.pushViewController(sgSettingsController(context: context))
        return true
    case "ios_settings":
        context.sharedContext.applicationBindings.openSettings()
        return true
    case "contacts":
        if let lastViewController = navigationController?.viewControllers.last as? ViewController {
            lastViewController.present(ContactsController(context: context), in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
        }
        return true
    case "restart":
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let lang = presentationData.strings.baseLanguageCode
        context.sharedContext.presentGlobalController(
            UndoOverlayController(
                presentationData: presentationData,
                content: .info(title: nil, text: "Common.RestartRequired".i18n(lang), timeout: nil, customUndoText: "Common.RestartNow".i18n(lang)),
                elevatedLayout: false,
                action: { action in if action == .undo { exit(0) }; return true }
            ),
            nil
        )
    default:
        break
    }
    return false
}

func sgCanRevealContent(messages: [EngineRawMessage], context: AccountContext, copyProtectionEnabled: Bool) -> Bool {
    guard !copyProtectionEnabled else {
        return false
    }
    for message in messages {
        if message.canRevealContent(contentSettings: context.currentContentSettings.with { $0 }) {
            return true
        }
    }
    return false
}

func sgInsertContextMenu(actions: inout [ContextMenuItem], sgActions: inout [ContextMenuItem], index: Int?, chatPresentationInterfaceState: ChatPresentationInterfaceState) {
    guard !sgActions.isEmpty else {
        return
    }
    if !actions.isEmpty {
        if let index {
            actions.insert(.separator, at: index)
        } else {
            actions.append(.separator)
        }
    }
    var popSGItems: (() -> Void)? = nil
    sgActions.insert(.action(ContextMenuActionItem(text: chatPresentationInterfaceState.strings.Common_Back, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.actionSheet.primaryTextColor)
    }, iconPosition: .left, action: { _, _ in
        popSGItems?()
    })), at: 0)
    sgActions.insert(.separator, at: 1)
    let sgItems = sgActions
    let swiftgramSubMenu: ContextMenuItem = .action(ContextMenuActionItem(text: "AyuGram", icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "SwiftgramContextMenu"), color: theme.actionSheet.primaryTextColor)
    }, action: { c, _ in
        popSGItems = { [weak c] in
            c?.popItems()
        }
        c?.pushItems(items: .single(ContextController.Items(content: .list(sgItems))))
    }))
    if let index {
        actions.insert(swiftgramSubMenu, at: index + 1)
    } else {
        actions.append(swiftgramSubMenu)
    }
}
