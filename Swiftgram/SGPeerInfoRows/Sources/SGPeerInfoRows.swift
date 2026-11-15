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

    // MARK: AyuGram
    // As in AyuGram: the ID is the value and "ID · DC N" its label.
    if SGSimpleSettings.shared.showProfileId && !idText.isEmpty {
        var label = "ID"
        if SGSimpleSettings.shared.showDC, let peer = data.peer, let smallProfileImage = peer.smallProfileImage, let cloudResource = smallProfileImage.resource as? CloudPeerPhotoSizeMediaResource {
            label += " · DC \(cloudResource.datacenterId)"
        }
        items.append(PeerInfoScreenLabeledValueItem(id: itemId, context: context, label: label, text: idText, textColor: .primary, action: { node, _ in
            interaction.openSgContextMenu(node, nil, .copy(text: idText, copyTitle: i18n("Chat.ID.Copy", presentationData.strings.baseLanguageCode), copiedTitle: i18n("Chat.ID.Copied", presentationData.strings.baseLanguageCode)))
        }, longTapAction: nil, contextAction: { node, gesture, _ in
            interaction.openSgContextMenu(node, gesture, .copy(text: idText, copyTitle: i18n("Chat.ID.Copy", presentationData.strings.baseLanguageCode), copiedTitle: i18n("Chat.ID.Copied", presentationData.strings.baseLanguageCode)))
        }, requestLayout: { _ in
            interaction.requestLayout(false)
        }))
        itemId += 1
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

    // MARK: AyuGram
    // Registration date: Telegram's own month when it gives one, otherwise an estimate from the user ID.
    if SGSimpleSettings.shared.showRegDate, case let .user(user) = data.peer, user.botInfo == nil, user.id != context.account.peerId {
        var regDateString = ""
        if let cachedData = data.cachedData as? CachedUserData, let registrationDate = cachedData.peerStatusSettings?.registrationDate {
            let components = registrationDate.components(separatedBy: ".")
            if components.count == 2, let first = Int32(components[0]), let second = Int32(components[1]) {
                regDateString = stringForMonth(strings: presentationData.strings, month: first - 1, ofYear: second - 1900)
            }
        }
        if regDateString.isEmpty {
            let estimate = Date(timeIntervalSince1970: TimeInterval(ayuEstimatedRegistrationTimestamp(userId: user.id.id._internalGetInt64Value())))
            let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: estimate)
            if let year = components.year, let month = components.month {
                regDateString = "≈ " + stringForMonth(strings: presentationData.strings, month: Int32(month - 1), ofYear: Int32(year - 1900))
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

// MARK: AyuGram
// Known (user ID, registration time) points; the registration date of other IDs is interpolated between them.
private let ayuRegistrationDatePoints: [(id: Int64, timestamp: Int64)] = [
    (1_000_000, 1380326400),
    (7_679_610, 1388448000),
    (15_835_244, 1392940000),
    (38_015_510, 1393632000),
    (54_845_238, 1411257000),
    (63_263_518, 1414454000),
    (101_260_938, 1425600000),
    (116_812_045, 1437696000),
    (130_029_930, 1441324000),
    (143_445_125, 1448928000),
    (152_079_341, 1453420000),
    (171_295_414, 1457481000),
    (181_783_990, 1460246000),
    (222_021_233, 1465344000),
    (278_941_742, 1473465600),
    (297_621_225, 1481846400),
    (337_808_429, 1487707200),
    (369_669_043, 1490918400),
    (400_169_472, 1501459200),
    (805_158_066, 1563208000),
    (1_974_255_900, 1634000000),
    (2_147_483_647, 1640995200),
    (5_000_000_000, 1643673600),
    (5_500_000_000, 1661990400),
    (6_000_000_000, 1677628800),
    (6_500_000_000, 1696118400),
    (7_000_000_000, 1709251200),
    (7_500_000_000, 1725148800),
    (8_000_000_000, 1740787200),
]

func ayuEstimatedRegistrationTimestamp(userId: Int64) -> Int64 {
    let points = ayuRegistrationDatePoints
    let now = Int64(Date().timeIntervalSince1970)
    guard let first = points.first, let last = points.last else {
        return now
    }
    if userId <= first.id {
        return first.timestamp
    }
    if userId >= last.id {
        let previous = points[points.count - 2]
        let slope = Double(last.timestamp - previous.timestamp) / Double(last.id - previous.id)
        return min(now, last.timestamp + Int64(Double(userId - last.id) * slope))
    }
    for index in 1 ..< points.count where userId <= points[index].id {
        let lower = points[index - 1]
        let upper = points[index]
        let fraction = Double(userId - lower.id) / Double(upper.id - lower.id)
        return lower.timestamp + Int64(fraction * Double(upper.timestamp - lower.timestamp))
    }
    return now
}