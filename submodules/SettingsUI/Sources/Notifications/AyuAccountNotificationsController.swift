import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import ItemListPeerItem
import AccountContext
import SGStrings

// MARK: AyuGram
// "Show notifications for": which of the signed-in accounts notify while another one is in use
// (exteraGram's AccountNotificationsActivity). The current account always notifies.

struct AyuNotifyingAccounts: Equatable {
    var currentUserId: Int64?
    var userIds: [Int64]

    func notifyingCount(_ settings: InAppNotificationSettings) -> Int {
        return self.userIds.filter { settings.ayuNotifies(accountUserId: $0, isCurrentAccount: $0 == self.currentUserId) }.count
    }
}

func ayuNotifyingAccounts(context: AccountContext) -> Signal<AyuNotifyingAccounts, NoError> {
    return context.sharedContext.activeAccountContexts
    |> map { primary, accounts, _ -> AyuNotifyingAccounts in
        return AyuNotifyingAccounts(
            currentUserId: primary?.account.peerId.id._internalGetInt64Value(),
            userIds: accounts.map { $0.1.account.peerId.id._internalGetInt64Value() }
        )
    }
    |> distinctUntilChanged
}

private final class AyuAccountNotificationsArguments {
    let updateNotifies: (Int64, Bool) -> Void

    init(updateNotifies: @escaping (Int64, Bool) -> Void) {
        self.updateNotifies = updateNotifies
    }
}

private enum AyuAccountNotificationsEntry: ItemListNodeEntry {
    case header(String)
    case account(index: Int32, context: AccountContext, peer: EnginePeer, dateTimeFormat: PresentationDateTimeFormat, nameDisplayOrder: PresentationPersonNameOrder, notifies: Bool, isCurrent: Bool)
    case info(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: Int64 {
        switch self {
        case .header:
            return 0
        case let .account(_, _, peer, _, _, _, _):
            return peer.id.toInt64()
        case .info:
            return 1
        }
    }

    private var sortIndex: Int32 {
        switch self {
        case .header:
            return -1
        case let .account(index, _, _, _, _, _, _):
            return index
        case .info:
            return Int32.max
        }
    }

    static func ==(lhs: AyuAccountNotificationsEntry, rhs: AyuAccountNotificationsEntry) -> Bool {
        switch lhs {
        case let .header(text):
            if case .header(text) = rhs {
                return true
            } else {
                return false
            }
        case let .account(lhsIndex, lhsContext, lhsPeer, lhsDateTimeFormat, lhsNameDisplayOrder, lhsNotifies, lhsIsCurrent):
            if case let .account(rhsIndex, rhsContext, rhsPeer, rhsDateTimeFormat, rhsNameDisplayOrder, rhsNotifies, rhsIsCurrent) = rhs {
                return lhsIndex == rhsIndex && lhsContext === rhsContext && lhsPeer == rhsPeer && lhsDateTimeFormat == rhsDateTimeFormat && lhsNameDisplayOrder == rhsNameDisplayOrder && lhsNotifies == rhsNotifies && lhsIsCurrent == rhsIsCurrent
            } else {
                return false
            }
        case let .info(text):
            if case .info(text) = rhs {
                return true
            } else {
                return false
            }
        }
    }

    static func <(lhs: AyuAccountNotificationsEntry, rhs: AyuAccountNotificationsEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! AyuAccountNotificationsArguments
        switch self {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .account(_, context, peer, dateTimeFormat, nameDisplayOrder, notifies, isCurrent):
            let text: ItemListPeerItemText
            if let addressName = peer.addressName, !addressName.isEmpty {
                text = .text("@\(addressName)", .secondary)
            } else {
                text = .none
            }
            let userId = peer.id.id._internalGetInt64Value()
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: dateTimeFormat, nameDisplayOrder: nameDisplayOrder, context: context, peer: peer, presence: nil, text: text, label: .none, editing: ItemListPeerItemEditing(editable: false, editing: false, revealed: false), switchValue: ItemListPeerItemSwitch(value: notifies, style: .standard, isEnabled: !isCurrent), enabled: true, selectable: false, sectionId: self.section, action: nil, setPeerIdWithRevealedOptions: { _, _ in }, removePeer: { _ in }, toggleUpdated: { value in
                arguments.updateNotifies(userId, value)
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

func ayuAccountNotificationsController(context: AccountContext) -> ViewController {
    let accountManager = context.sharedContext.accountManager
    let arguments = AyuAccountNotificationsArguments(updateNotifies: { userId, value in
        let _ = updateInAppNotificationSettingsInteractively(accountManager: accountManager, { settings in
            var settings = settings
            if value {
                settings.ayuMutedAccountUserIds.remove(userId)
            } else {
                settings.ayuMutedAccountUserIds.insert(userId)
            }
            return settings
        }).start()
    })

    let signal = combineLatest(
        context.sharedContext.presentationData,
        accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.inAppNotificationSettings]),
        context.sharedContext.activeAccountContexts,
        context.sharedContext.activeAccountsWithInfo
    )
    |> map { presentationData, sharedData, activeAccounts, accountsWithInfo -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.inAppNotificationSettings]?.get(InAppNotificationSettings.self) ?? InAppNotificationSettings.defaultSettings
        let lang = presentationData.strings.baseLanguageCode
        let currentAccountId = activeAccounts.primary?.account.id

        var entries: [AyuAccountNotificationsEntry] = [.header(i18n("Extera.NotificationAccounts.Header", lang).uppercased())]
        var index: Int32 = 0
        // Each row draws the avatar through its own account.
        for (_, accountContext, _) in activeAccounts.accounts {
            guard let info = accountsWithInfo.accounts.first(where: { $0.account.id == accountContext.account.id }) else {
                continue
            }
            let isCurrent = accountContext.account.id == currentAccountId
            let notifies = settings.ayuNotifies(accountUserId: accountContext.account.peerId.id._internalGetInt64Value(), isCurrentAccount: isCurrent)
            entries.append(.account(index: index, context: accountContext, peer: info.peer, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, notifies: notifies, isCurrent: isCurrent))
            index += 1
        }
        entries.append(.info(i18n("Extera.NotificationAccounts.Info", lang)))

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(i18n("Extera.NotificationAccounts", lang)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks)
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal)
}
