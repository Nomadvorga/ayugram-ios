import SGSimpleSettings
import SGStrings
import CountrySelectionUI
import Foundation
import UIKit
import AccountContext
import TelegramPresentationData
import TelegramCore
import TelegramStringFormatting
import SwiftSignalKit // MARK: AyuGram

func sgPeerInfoProfileItems(nearestChatParticipant: (String?, Int32?), data: PeerInfoScreenData, context: AccountContext, presentationData: PresentationData, interaction: PeerInfoInteraction, isMyProfile: Bool) -> [PeerInfoScreenItem] {
    var items: [PeerInfoScreenItem] = []
    var itemId = 0
    var idText = ""
    var isMutualContact = false

    if case let .user(user) = data.peer {
        idText = String(user.id.id._internalGetInt64Value())
        isMutualContact = user.flags.contains(.mutualContact)
    } else if case let .channel(channel) = data.peer {
        idText = "-100" + String(channel.id.id._internalGetInt64Value())
    } else if case let .legacyGroup(group) = data.peer {
        idText = String(group.id.id._internalGetInt64Value())
    }

    if SGSimpleSettings.shared.showProfileId {
        items.append(PeerInfoScreenLabeledValueItem(id: itemId, context: context, label: "\(i18n("Chat.ID", presentationData.strings.baseLanguageCode)): \(idText)", text: "", textColor: .primary, action: { node, _ in
            interaction.openSgContextMenu(node, nil, .copy(text: idText, copyTitle: i18n("Chat.ID.Copy", presentationData.strings.baseLanguageCode), copiedTitle: i18n("Chat.ID.Copied", presentationData.strings.baseLanguageCode)))
        }, longTapAction: nil, contextAction: { node, gesture, _ in
            interaction.openSgContextMenu(node, gesture, .copy(text: idText, copyTitle: i18n("Chat.ID.Copy", presentationData.strings.baseLanguageCode), copiedTitle: i18n("Chat.ID.Copied", presentationData.strings.baseLanguageCode)))
        }, requestLayout: { _ in
            interaction.requestLayout(false)
        }))
        itemId += 1
    }

    if SGSimpleSettings.shared.showDC {
        var dcId: Int? = nil
        var phoneCountryText = ""
        var dcLabel = ""
        var dcText = ""

        if let cachedData = data.cachedData as? CachedUserData, let phoneCountry = cachedData.peerStatusSettings?.phoneCountry {
            var countryName = ""
            let countriesConfiguration = context.currentCountriesConfiguration.with { $0 }
            if let country = countriesConfiguration.countries.first(where: { $0.id == phoneCountry }) {
                countryName = country.localizedName ?? country.name
            } else if phoneCountry == "FT" {
                countryName = presentationData.strings.Chat_NonContactUser_AnonymousNumber
            } else if phoneCountry == "TS" {
                countryName = "Test"
            }
            phoneCountryText = emojiFlagForISOCountryCode(phoneCountry) + " " + countryName
        }
        if let peer = data.peer, let smallProfileImage = peer.smallProfileImage, let cloudResource = smallProfileImage.resource as? CloudPeerPhotoSizeMediaResource {
            dcId = cloudResource.datacenterId
        }

        if let dcId = dcId {
            dcLabel = "dc: \(dcId)"
            if !phoneCountryText.isEmpty {
                dcText = phoneCountryText
            }
        } else if !phoneCountryText.isEmpty {
            dcLabel = "dc: ?"
            dcText = phoneCountryText
        }

        if !dcText.isEmpty || !dcLabel.isEmpty {
            items.append(PeerInfoScreenLabeledValueItem(id: itemId, context: context, label: dcLabel, text: dcText, textColor: .primary, action: { node, _ in
                interaction.openSgContextMenu(node, nil, .openURL(url: "https://core.telegram.org/api/datacenter", title: i18n("Chat.DataCenter.LearnMore", presentationData.strings.baseLanguageCode)))
            }, longTapAction: nil, contextAction: { node, gesture, _ in
                interaction.openSgContextMenu(node, gesture, .openURL(url: "https://core.telegram.org/api/datacenter", title: i18n("Chat.DataCenter.LearnMore", presentationData.strings.baseLanguageCode)))
            }, requestLayout: { _ in
                interaction.requestLayout(false)
            }))
            itemId += 1
        }
    }

    if SGSimpleSettings.shared.showCreationDate, let channelCreationTimestamp = data.channelCreationTimestamp {
        let creationDateString = stringForDate(timestamp: channelCreationTimestamp, strings: presentationData.strings)
        items.append(PeerInfoScreenLabeledValueItem(id: itemId, context: context, label: i18n("Chat.Created.Label", presentationData.strings.baseLanguageCode), text: creationDateString, textColor: .primary, action: { node, _ in
            interaction.openSgContextMenu(node, nil, .copy(text: creationDateString, copyTitle: presentationData.strings.Chat_Context_Date_Copy, copiedTitle: i18n("Chat.Created.Copied", presentationData.strings.baseLanguageCode)))
        }, longTapAction: nil, contextAction: { node, gesture, _ in
            interaction.openSgContextMenu(node, gesture, .copy(text: creationDateString, copyTitle: presentationData.strings.Chat_Context_Date_Copy, copiedTitle: i18n("Chat.Created.Copied", presentationData.strings.baseLanguageCode)))
        }, requestLayout: { _ in
            interaction.requestLayout(false)
        }))
        itemId += 1
    }

    if let invitedAt = nearestChatParticipant.1 {
        let joinedDateString = stringForDate(timestamp: invitedAt, strings: presentationData.strings)
        items.append(PeerInfoScreenLabeledValueItem(id: itemId, context: context, label: i18n("Chat.JoinedDateTitle", presentationData.strings.baseLanguageCode, nearestChatParticipant.0 ?? "chat"), text: joinedDateString, textColor: .primary, action: { node, _ in
            interaction.openSgContextMenu(node, nil, .copy(text: joinedDateString, copyTitle: presentationData.strings.Chat_Context_Date_Copy, copiedTitle: i18n("Chat.JoinedDate.Copied", presentationData.strings.baseLanguageCode)))
        }, longTapAction: nil, contextAction: { node, gesture, _ in
            interaction.openSgContextMenu(node, gesture, .copy(text: joinedDateString, copyTitle: presentationData.strings.Chat_Context_Date_Copy, copiedTitle: i18n("Chat.JoinedDate.Copied", presentationData.strings.baseLanguageCode)))
        }, requestLayout: { _ in
            interaction.requestLayout(false)
        }))
        itemId += 1
    }

    if SGSimpleSettings.shared.showRegDate {
        var regDateString = ""
        if let cachedData = data.cachedData as? CachedUserData, let registrationDate = cachedData.peerStatusSettings?.registrationDate {
            let components = registrationDate.components(separatedBy: ".")
            if components.count == 2, let first = Int32(components[0]), let second = Int32(components[1]) {
                let month = first - 1
                let year = second - 1900
                regDateString = stringForMonth(strings: presentationData.strings, month: month, ofYear: year)
            }
        }
        if let regDate = data.regDate, regDateString.isEmpty {
            let regTimestamp = Int32((regDate.from + regDate.to) / 2)
            switch context.currentAppConfiguration.with({ $0 }).sgWebSettings.global.regdateFormat {
                case "year":
                    regDateString = stringForDateWithoutDayAndMonth(date: Date(timeIntervalSince1970: Double(regTimestamp)), strings: presentationData.strings)
                case "month":
                    regDateString = stringForDateWithoutDay(date: Date(timeIntervalSince1970: Double(regTimestamp)), strings: presentationData.strings)
                default:
                    regDateString = stringForDate(timestamp: regTimestamp, strings: presentationData.strings)
            }
        }
        if !regDateString.isEmpty {
            items.append(PeerInfoScreenLabeledValueItem(id: itemId, context: context, label: i18n("Chat.RegDate", presentationData.strings.baseLanguageCode), text: regDateString, textColor: .primary, action: { node, _ in
                interaction.openSgContextMenu(node, nil, .copy(text: regDateString, copyTitle: presentationData.strings.Chat_Context_Date_Copy, copiedTitle: i18n("Chat.RegDate.Copied", presentationData.strings.baseLanguageCode)))
            }, longTapAction: nil, contextAction: { node, gesture, _ in
                interaction.openSgContextMenu(node, gesture, .copy(text: regDateString, copyTitle: presentationData.strings.Chat_Context_Date_Copy, copiedTitle: i18n("Chat.RegDate.Copied", presentationData.strings.baseLanguageCode)))
            }, requestLayout: { _ in
                interaction.requestLayout(false)
            }))
            itemId += 1
        }
    }
    // MARK: AyuGram
    if !isMyProfile, let peer = data.peer, peer.id != context.account.peerId, peer.id.namespace == Namespaces.Peer.CloudUser || peer.id.namespace == Namespaces.Peer.CloudGroup || peer.id.namespace == Namespaces.Peer.CloudChannel {
        let lang = presentationData.strings.baseLanguageCode
        let peerIdValue = peer.id.toInt64()
        let exclusionRows: [(kind: AyuExclusions.Kind, label: String, never: String, always: String)] = [
            (.read, "Ayu.ReadExclusionMenuText", "Ayu.ExclusionDontRead", "Ayu.ExclusionAlwaysRead"),
            (.typing, "Ayu.TypingExclusionMenuText", "Ayu.ExclusionDontType", "Ayu.ExclusionAlwaysType"),
            (.saving, "Ayu.SavingExclusionMenuText", "Ayu.ExclusionDontSave", "Ayu.ExclusionAlwaysSave"),
        ]
        for row in exclusionRows {
            let titles: [AyuExclusions.Mode: String] = [
                .default: i18n("Ayu.ExclusionUseDefault", lang),
                .never: i18n(row.never, lang),
                .always: i18n(row.always, lang),
            ]
            let kind = row.kind
            let makeOptions: () -> SGContextMenuAction = {
                let current = AyuExclusions.shared.mode(kind, peerId: peerIdValue)
                return .options(AyuExclusions.Mode.allCases.map { value in
                    return SGContextMenuOption(title: titles[value] ?? "", isSelected: value == current, action: {
                        AyuExclusions.shared.setMode(value, kind: kind, peerId: peerIdValue)
                        interaction.requestLayout(true)
                    })
                })
            }
            let currentMode = AyuExclusions.shared.mode(kind, peerId: peerIdValue)
            items.append(PeerInfoScreenLabeledValueItem(id: itemId, context: context, label: i18n(row.label, lang), text: titles[currentMode] ?? "", textColor: .primary, action: { node, _ in
                interaction.openSgContextMenu(node, nil, makeOptions())
            }, longTapAction: nil, contextAction: { node, gesture, _ in
                interaction.openSgContextMenu(node, gesture, makeOptions())
            }, requestLayout: { _ in
                interaction.requestLayout(false)
            }))
            itemId += 1
        }
        if peer.id.namespace == Namespaces.Peer.CloudUser {
            let isShadowBanned = AyuShadowBan.shared.isBanned(peerId: peerIdValue)
            items.append(PeerInfoScreenLabeledValueItem(id: itemId, context: context, label: i18n("Ayu.FiltersShadowBan", lang), text: i18n(isShadowBanned ? "Ayu.FiltersQuickUnshadowBan" : "Ayu.FiltersQuickShadowBan", lang), textColor: .accent, action: { _, _ in
                AyuShadowBan.shared.setBanned(!isShadowBanned, peerId: peerIdValue)
                interaction.requestLayout(true)
            }, longTapAction: nil, contextAction: nil, requestLayout: { _ in
                interaction.requestLayout(false)
            }))
            itemId += 1
        }
        // "Clear Deleted": the context menu's single item is the confirmation.
        let clearTitle = i18n("Ayu.ClearDeletedMenuText", lang)
        let clearAction: SGContextMenuAction = .options([SGContextMenuOption(title: i18n("Ayu.ClearDeletedMessagesActionText", lang), isSelected: false, action: {
            let _ = (ayuClearDeletedMessages(account: context.account, peerId: peer.id)
            |> deliverOnMainQueue).start(next: { _ in
                interaction.requestLayout(true)
            })
        })])
        items.append(PeerInfoScreenLabeledValueItem(id: itemId, context: context, label: clearTitle, text: i18n("Ayu.ClearDeletedMessagesText", lang), textColor: .primary, action: { node, _ in
            interaction.openSgContextMenu(node, nil, clearAction)
        }, longTapAction: nil, contextAction: { node, gesture, _ in
            interaction.openSgContextMenu(node, gesture, clearAction)
        }, requestLayout: { _ in
            interaction.requestLayout(false)
        }))
        itemId += 1

        var isGroup = false
        if case .legacyGroup = data.peer {
            isGroup = true
        } else if case let .channel(channel) = data.peer, case .group = channel.info {
            isGroup = true
        }
        if isGroup {
            let deleteOwnAction: SGContextMenuAction = .options([SGContextMenuOption(title: i18n("Ayu.DeleteOwnMessages", lang), isSelected: false, action: {
                let _ = ayuDeleteOwnMessages(context: context, peerId: peer.id).start()
            })])
            items.append(PeerInfoScreenLabeledValueItem(id: itemId, context: context, label: i18n("Ayu.DeleteOwnMessages", lang), text: i18n("Ayu.DeleteOwnMessagesConfirmation", lang), textColor: .primary, action: { node, _ in
                interaction.openSgContextMenu(node, nil, deleteOwnAction)
            }, longTapAction: nil, contextAction: { node, gesture, _ in
                interaction.openSgContextMenu(node, gesture, deleteOwnAction)
            }, requestLayout: { _ in
                interaction.requestLayout(false)
            }))
            itemId += 1
        }
    }
    //
    if isMutualContact && !isMyProfile {
        items.append(PeerInfoScreenLabeledValueItem(id: itemId, label: i18n("MutualContact.Label", presentationData.strings.baseLanguageCode), text: "", action: nil, longTapAction: { _ in }, requestLayout: { _ in
            interaction.requestLayout(false)
        }))
    }

    return items
}

func sgPeerInfoSettingsProfileIdItems(data: PeerInfoScreenData, interaction: PeerInfoInteraction) -> [PeerInfoScreenItem] {
    guard SGSimpleSettings.shared.showProfileId else {
        return []
    }

    let idText = data.peer.map { String($0.id.id._internalGetInt64Value()) } ?? ""
    return [PeerInfoScreenActionItem(id: 100, text: "ID: \(idText)", color: .accent, action: {
        UIPasteboard.general.string = idText
        interaction.notifyTextCopied()
    })]
}

func sgPeerInfoSettingsItems(context: AccountContext, paymentsEnabled: Bool, presentationData: PresentationData, interaction: PeerInfoInteraction) -> [PeerInfoScreenItem] {
    // MARK: AyuGram
    // AyuGram's own preferences, then the exteraGram tab with the rest of the client features.
    var items: [PeerInfoScreenItem] = []
    items.append(PeerInfoScreenDisclosureItem(id: 2, label: .none, text: "AyuGram", icon: PresentationResourcesSettings.swiftgram, action: {
        interaction.openSettings(.ayugram)
    }))
    items.append(PeerInfoScreenDisclosureItem(id: 1, label: .none, text: "exteraGram", icon: PresentationResourcesSettings.swiftgramPro, action: {
        interaction.openSettings(.swiftgram)
    }))
    return items
}

// MARK: AyuGram
// "Delete own messages": finds the account's messages in the chat on the server, 100 at a time, and deletes them for everyone.
func ayuDeleteOwnMessages(context: AccountContext, peerId: EnginePeer.Id) -> Signal<Int, NoError> {
    let accountPeerId = context.account.peerId
    func step(deleted: Set<EngineMessage.Id>, iteration: Int) -> Signal<Int, NoError> {
        if iteration >= 200 {
            return .single(deleted.count)
        }
        return context.engine.messages.searchMessages(location: .peer(peerId: peerId, fromId: accountPeerId, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil), query: "", state: nil, limit: 100)
        |> take(1)
        |> mapToSignal { result, _ -> Signal<Int, NoError> in
            let ids = result.messages.map(\.id).filter { $0.peerId == peerId && !deleted.contains($0) }
            if ids.isEmpty {
                return .single(deleted.count)
            }
            return (context.engine.messages.deleteMessagesInteractively(messageIds: ids, type: .forEveryone)
            |> mapToSignal { _ -> Signal<Int, NoError> in
                return .complete()
            })
            |> then(step(deleted: deleted.union(ids), iteration: iteration + 1))
        }
    }
    return step(deleted: Set(), iteration: 0)
}