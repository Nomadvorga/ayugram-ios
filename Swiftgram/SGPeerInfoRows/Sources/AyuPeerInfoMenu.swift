import SGSimpleSettings
import SGStrings
import Foundation
import UIKit
import Display
import ContextUI
import AccountContext
import TelegramPresentationData
import TelegramCore
import SwiftSignalKit

// MARK: AyuGram
// "AyuGram" in the profile's "More" menu, as in AyuGram's chat menu: exclusions, shadow ban, clearing deleted messages.
func ayuPeerInfoMoreMenuItem(context: AccountContext, peer: EnginePeer, presentationData: PresentationData) -> ContextMenuItem? {
    if peer.id == context.account.peerId {
        return nil
    }
    switch peer.id.namespace {
    case Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel:
        break
    default:
        return nil
    }
    return .action(ContextMenuActionItem(text: "AyuGram", icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/AyuGram"), color: theme.contextMenu.primaryColor)
    }, action: { c, _ in
        c?.pushItems(items: .single(ContextController.Items(content: .list(ayuPeerInfoMenuItems(context: context, peer: peer, presentationData: presentationData)))))
    }))
}

private func ayuBackItem(_ presentationData: PresentationData) -> ContextMenuItem {
    return .action(ContextMenuActionItem(text: presentationData.strings.Common_Back, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.contextMenu.primaryColor)
    }, iconPosition: .left, action: { c, _ in
        c?.popItems()
    }))
}

private func ayuPeerInfoMenuItems(context: AccountContext, peer: EnginePeer, presentationData: PresentationData) -> [ContextMenuItem] {
    let lang = presentationData.strings.baseLanguageCode
    let peerIdValue = peer.id.toInt64()
    var items: [ContextMenuItem] = [ayuBackItem(presentationData), .separator]

    let exclusionRows: [(kind: AyuExclusions.Kind, label: String, never: String, always: String, icon: String)] = [
        (.read, "Ayu.ReadExclusionMenuText", "Ayu.ExclusionDontRead", "Ayu.ExclusionAlwaysRead", "Chat/Context Menu/Eye"),
        (.typing, "Ayu.TypingExclusionMenuText", "Ayu.ExclusionDontType", "Ayu.ExclusionAlwaysType", "Chat/Context Menu/Edit"),
        (.saving, "Ayu.SavingExclusionMenuText", "Ayu.ExclusionDontSave", "Ayu.ExclusionAlwaysSave", "Chat/Context Menu/Download"),
    ]
    for row in exclusionRows {
        let titles: [AyuExclusions.Mode: String] = [
            .default: i18n("Ayu.ExclusionUseDefault", lang),
            .never: i18n(row.never, lang),
            .always: i18n(row.always, lang),
        ]
        let kind = row.kind
        let current = AyuExclusions.shared.mode(kind, peerId: peerIdValue)
        items.append(.action(ContextMenuActionItem(text: i18n(row.label, lang), textLayout: .secondLineWithValue(titles[current] ?? ""), icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: row.icon), color: theme.contextMenu.primaryColor)
        }, action: { c, _ in
            var options: [ContextMenuItem] = [ayuBackItem(presentationData), .separator]
            for mode in AyuExclusions.Mode.allCases {
                options.append(.action(ContextMenuActionItem(text: titles[mode] ?? "", icon: { theme in
                    // Unchecked options keep an invisible check so every title starts after the icon column.
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: mode == current ? theme.contextMenu.primaryColor : .clear)
                }, action: { _, f in
                    AyuExclusions.shared.setMode(mode, kind: kind, peerId: peerIdValue)
                    f(.default)
                })))
            }
            c?.pushItems(items: .single(ContextController.Items(content: .list(options))))
        })))
    }

    if peer.id.namespace == Namespaces.Peer.CloudUser {
        let isShadowBanned = AyuShadowBan.shared.isBanned(peerId: peerIdValue)
        items.append(.action(ContextMenuActionItem(text: i18n(isShadowBanned ? "Ayu.FiltersQuickUnshadowBan" : "Ayu.FiltersQuickShadowBan", lang), icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: isShadowBanned ? "Chat/Context Menu/Unmute" : "Chat/Context Menu/Muted"), color: theme.contextMenu.primaryColor)
        }, action: { _, f in
            AyuShadowBan.shared.setBanned(!isShadowBanned, peerId: peerIdValue)
            f(.default)
        })))
    }

    items.append(.separator)

    items.append(ayuDestructiveItem(presentationData: presentationData, title: i18n("Ayu.ClearDeletedMenuText", lang), icon: "Chat/Context Menu/ClearMessages", confirmation: i18n("Ayu.ClearDeletedMessagesText", lang), confirmTitle: i18n("Ayu.ClearDeletedMessagesActionText", lang), action: {
        let _ = ayuClearDeletedMessages(account: context.account, peerId: peer.id).start()
    }))

    var isGroup = false
    if case .legacyGroup = peer {
        isGroup = true
    } else if case let .channel(channel) = peer, case .group = channel.info {
        isGroup = true
    }
    if isGroup {
        items.append(ayuDestructiveItem(presentationData: presentationData, title: i18n("Ayu.DeleteOwnMessages", lang), icon: "Chat/Context Menu/Delete", confirmation: i18n("Ayu.DeleteOwnMessagesConfirmation", lang), confirmTitle: i18n("Ayu.DeleteOwnMessages", lang), action: {
            let _ = ayuDeleteOwnMessages(context: context, peerId: peer.id).start()
        }))
    }

    items.append(.separator)
    items.append(.action(ContextMenuActionItem(text: "Тема чата: данные", icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Info"), color: theme.contextMenu.primaryColor)
    }, action: { c, _ in
        c?.pushItems(items: ayuChatThemeDiagnosticsItems(context: context, peer: peer, presentationData: presentationData))
    })))

    return items
}

// Temporary: what the server sends for this chat's theme, to compare with Telegram from the App Store.
private func ayuChatThemeDiagnosticsItems(context: AccountContext, peer: EnginePeer, presentationData: PresentationData) -> Signal<ContextController.Items, NoError> {
    let accountManager = context.sharedContext.accountManager
    let cachedThemes = context.engine.themes.getChatThemes(accountManager: accountManager, onlyCached: true)
    |> take(1)
    let fetchedThemes: Signal<[TelegramTheme]?, NoError> = context.engine.themes.getChatThemes(accountManager: accountManager, forceUpdate: true)
    |> take(1)
    |> map(Optional.init)
    |> timeout(15.0, queue: Queue.mainQueue(), alternate: .single(nil))
    let chatTheme = context.engine.data.get(TelegramEngine.EngineData.Item.Peer.ChatTheme(id: peer.id))

    return combineLatest(queue: Queue.mainQueue(), chatTheme, cachedThemes, fetchedThemes)
    |> map { chatTheme, cachedThemes, fetchedThemes -> ContextController.Items in
        let arguments = context.sharedContext.networkArguments
        let theme = presentationData.theme
        var lines: [String] = []
        lines.append("api_id: \(arguments.apiId), версия \(arguments.appVersion)")
        lines.append("Тема приложения: \(theme.referenceTheme), тёмная: \(theme.overallDarkAppearance ? "да" : "нет")")
        switch chatTheme {
        case let .some(.emoticon(emoticon)):
            lines.append("Тема чата: эмодзи \(emoticon)")
            let find: ([TelegramTheme]) -> TelegramTheme? = { $0.first(where: { $0.emoticon == emoticon }) }
            lines.append("")
            lines.append("Из кэша:")
            lines.append(contentsOf: ayuThemeSettingsLines(find(cachedThemes)?.settings))
            lines.append("")
            lines.append("С сервера сейчас:")
            if let fetchedThemes {
                lines.append(contentsOf: ayuThemeSettingsLines(find(fetchedThemes)?.settings))
            } else {
                lines.append("нет ответа")
            }
        case let .some(.gift(gift, themeSettings)):
            if case let .unique(uniqueGift) = gift {
                lines.append("Тема чата: подарок \(uniqueGift.slug)")
            } else {
                lines.append("Тема чата: подарок")
            }
            lines.append("")
            lines.append(contentsOf: ayuThemeSettingsLines(themeSettings))
        case .none:
            lines.append("Тема чата: нет")
        }
        let text = lines.joined(separator: "\n")

        let items: [ContextMenuItem] = [
            ayuBackItem(presentationData),
            .separator,
            .action(ContextMenuActionItem(text: text, textLayout: .multiline, textFont: .small, icon: { _ in
                return nil
            }, action: nil as ((ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void)?)),
            .action(ContextMenuActionItem(text: presentationData.strings.Conversation_ContextMenuCopy, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.contextMenu.primaryColor)
            }, action: { _, f in
                UIPasteboard.general.string = text
                f(.default)
            })),
        ]
        return ContextController.Items(content: .list(items))
    }
}

private func ayuThemeSettingsLines(_ settings: [TelegramThemeSettings]?) -> [String] {
    guard let settings, !settings.isEmpty else {
        return ["вариантов нет"]
    }
    let hex: (UInt32) -> String = { String(format: "#%06x", $0 & 0xffffff) }
    return settings.map { item in
        var wallpaper = "нет"
        if let value = item.wallpaper {
            switch value {
            case let .color(color):
                wallpaper = "цвет \(hex(color))"
            case let .gradient(gradient):
                wallpaper = "градиент " + gradient.colors.map(hex).joined(separator: " ")
            case let .file(file):
                wallpaper = "узор " + file.settings.colors.map(hex).joined(separator: " ") + " (\(file.settings.intensity ?? 0))"
            default:
                wallpaper = "другие"
            }
        }
        let messageColors = item.messageColors.isEmpty ? "нет" : item.messageColors.map(hex).joined(separator: " ")
        let outgoingAccent = item.outgoingAccentColor.flatMap(hex) ?? "нет"
        return "• \(item.baseTheme): акцент \(hex(item.accentColor)), исходящий акцент \(outgoingAccent), пузыри \(messageColors), анимация \(item.animateMessageColors ? "да" : "нет"), обои: \(wallpaper)"
    }
}

// A destructive action asks again on its own page before running.
private func ayuDestructiveItem(presentationData: PresentationData, title: String, icon: String, confirmation: String, confirmTitle: String, action: @escaping () -> Void) -> ContextMenuItem {
    return .action(ContextMenuActionItem(text: title, textColor: .destructive, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: icon), color: theme.contextMenu.destructiveColor)
    }, action: { c, _ in
        let confirmItems: [ContextMenuItem] = [
            ayuBackItem(presentationData),
            .separator,
            .action(ContextMenuActionItem(text: confirmation, textLayout: .multiline, textFont: .small, icon: { _ in
                return nil
            }, action: nil as ((ContextControllerProtocol?, @escaping (ContextMenuActionResult) -> Void) -> Void)?)),
            .action(ContextMenuActionItem(text: confirmTitle, textColor: .destructive, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: icon), color: theme.contextMenu.destructiveColor)
            }, action: { _, f in
                action()
                f(.default)
            })),
        ]
        c?.pushItems(items: .single(ContextController.Items(content: .list(confirmItems))))
    }))
}
