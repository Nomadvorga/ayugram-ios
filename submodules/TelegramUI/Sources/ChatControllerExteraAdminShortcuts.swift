import AccountContext
import ChatInterfaceState
import ChatPresentationInterfaceState
import ContextUI
import Display
import Foundation
import PeerInfoUI
import PresentationDataUtils
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

private typealias AdminPolicy = ExteraAdminShortcutPolicy

private struct ExteraAdminSnapshot {
    let group: EnginePeer
    let author: EnginePeer
    let participant: ChannelParticipant?
    let kind: AdminPolicy.GroupKind
    let actor: AdminPolicy.Actor
    let target: AdminPolicy.Target

    func actions(accountId: EnginePeer.Id) -> [AdminPolicy.Action] {
        return AdminPolicy.actions(enabled: ExteraAdminSettings.shared.quickAdminShortcuts, kind: self.kind, actor: self.actor, target: self.target, isSelf: self.author.id == accountId)
    }
}

private func exteraAdminRights(_ flags: TelegramChatAdminRightsFlags) -> AdminPolicy.Rights {
    var result: AdminPolicy.Rights = []
    if flags.contains(.canBanUsers) { result.insert(.banMembers) }
    if flags.contains(.canAddAdmins) { result.insert(.addAdmins) }
    if flags.contains(.canDeleteMessages) { result.insert(.deleteMessages) }
    return result
}

private func exteraAdminActor(_ participant: ChannelParticipant?) -> AdminPolicy.Actor {
    guard let participant else { return .unknown }
    switch participant {
    case .creator:
        return .owner
    case let .member(_, _, adminInfo, banInfo, _, _):
        if let banInfo, !banInfo.isMember || banInfo.rights.flags.contains(.banReadMessages) { return .unknown }
        if let adminInfo { return .administrator(exteraAdminRights(adminInfo.rights.rights)) }
        return .member
    }
}

private func exteraAdminTarget(_ participant: ChannelParticipant?) -> AdminPolicy.Target {
    guard let participant else { return .unknown }
    switch participant {
    case .creator:
        return .owner
    case let .member(_, _, adminInfo, banInfo, _, _):
        if let banInfo, !banInfo.isMember || banInfo.rights.flags.contains(.banReadMessages) { return .removed }
        return adminInfo == nil ? .member : .administrator
    }
}

/// Both participants come from channels.getParticipant, including the actor's actual current rights.
/// Basic groups use getFullChat and read its newly stored membership and peer in one engine snapshot.
private func exteraAdminSnapshot(context: AccountContext, groupId: EnginePeer.Id, authorId: EnginePeer.Id) -> Signal<ExteraAdminSnapshot?, NoError> {
    return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: groupId))
    |> mapToSignal { group -> Signal<ExteraAdminSnapshot?, NoError> in
        guard let group else { return .single(nil) }
        switch group {
        case let .channel(channel):
            guard case .group = channel.info, !channel.flags.contains(.isMonoforum), channel.participationStatus == .member else { return .single(nil) }
            return combineLatest(
                context.engine.peers.fetchChannelParticipant(peerId: groupId, participantId: context.account.peerId),
                context.engine.peers.fetchChannelParticipant(peerId: groupId, participantId: authorId),
                context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: authorId))
            )
            |> map { actor, target, author -> ExteraAdminSnapshot? in
                guard let author, case let .user(user) = author, !user.isDeleted else { return nil }
                return ExteraAdminSnapshot(group: group, author: author, participant: target, kind: .supergroup, actor: exteraAdminActor(actor), target: exteraAdminTarget(target))
            }
        case .legacyGroup:
            return context.engine.peers.fetchAndUpdateCachedPeerData(peerId: groupId)
            |> mapToSignal { updated -> Signal<ExteraAdminSnapshot?, NoError> in
                guard updated else { return .single(nil) }
                return context.engine.data.get(
                    TelegramEngine.EngineData.Item.Peer.Peer(id: groupId),
                    TelegramEngine.EngineData.Item.Peer.CachedData(id: groupId),
                    TelegramEngine.EngineData.Item.Peer.Peer(id: authorId)
                )
                |> map { group, cachedData, author -> ExteraAdminSnapshot? in
                    guard let group, case let .legacyGroup(legacyGroup) = group,
                        legacyGroup.membership == .Member, legacyGroup.migrationReference == nil,
                        let members = (cachedData as? CachedGroupData)?.participants?.participants,
                        let actorMember = members.first(where: { $0.peerId == context.account.peerId }),
                        let targetMember = members.first(where: { $0.peerId == authorId }),
                        let author, case let .user(user) = author, !user.isDeleted else { return nil }
                    let actor: AdminPolicy.Actor
                    switch (actorMember, legacyGroup.role) {
                    case (.creator, .creator): actor = .owner
                    case let (.admin, .admin(rights, _)): actor = .administrator(exteraAdminRights(rights.rights))
                    default: actor = .member
                    }
                    let target: AdminPolicy.Target
                    switch targetMember {
                    case .creator: target = .owner
                    case .admin: target = .administrator
                    case .member: target = .member
                    }
                    return ExteraAdminSnapshot(group: group, author: author, participant: nil, kind: .legacyGroup, actor: actor, target: target)
                }
            }
        default:
            return .single(nil)
        }
    }
    |> take(1)
    |> timeout(3.0, queue: .mainQueue(), alternate: .single(nil))
}

extension ChatControllerImpl {
    /// Append this signal's items to the existing author-avatar/username menu. It includes its own
    /// separator only when server-verified operations exist; disabled/private/unknown paths are empty.
    func exteraAdminShortcutItems(authorId: EnginePeer.Id) -> Signal<[ContextMenuItem], NoError> {
        guard ExteraAdminSettings.shared.quickAdminShortcuts, let groupId = self.chatLocation.peerId,
            authorId != self.context.account.peerId, authorId.namespace == Namespaces.Peer.CloudUser,
            !self.context.isFrozen, !self.presentationInterfaceState.isNotAccessible else { return .single([]) }
        if case .customChatContents = self.chatLocation { return .single([]) }
        // Avoid a network request for ordinary viewers. Positive cached rights are never trusted.
        guard let peer = self.presentationInterfaceState.renderedPeer?.peer else { return .single([]) }
        if let channel = peer as? TelegramChannel {
            guard channel.flags.contains(.isCreator) || channel.adminRights != nil else { return .single([]) }
        } else if let group = peer as? TelegramGroup {
            if case .member = group.role { return .single([]) }
        } else { return .single([]) }
        return exteraAdminSnapshot(context: self.context, groupId: groupId, authorId: authorId)
        |> deliverOnMainQueue
        |> map { [weak self] snapshot -> [ContextMenuItem] in
            guard let self, self.chatLocation.peerId == groupId, let snapshot else { return [] }
            let actions = snapshot.actions(accountId: self.context.account.peerId)
            guard !actions.isEmpty else { return [] }
            var items: [ContextMenuItem] = [.separator]
            for action in actions {
                let destructive = action == .ban || action == .removeMember || action == .deleteMessages
                let icon: String
                switch action {
                case .promote: icon = "Promote"
                case .restrict: icon = "Restrict"
                case .ban, .removeMember, .deleteMessages: icon = "Delete"
                }
                items.append(.action(ContextMenuActionItem(text: self.exteraAdminTitle(action), textColor: destructive ? .destructive : .primary, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/" + icon), color: destructive ? theme.contextMenu.destructiveColor : theme.contextMenu.primaryColor)
                }, action: { [weak self] controller, completion in
                    // Begin only after the existing menu has finished its native dismissal.
                    if let controller {
                        controller.dismiss { self?.exteraPerformAdminShortcut(action, groupId: groupId, authorId: authorId) }
                    } else {
                        completion(.dismissWithoutContent)
                        self?.exteraPerformAdminShortcut(action, groupId: groupId, authorId: authorId)
                    }
                })))
            }
            return items
        }
    }

    private func exteraAdminTitle(_ action: AdminPolicy.Action) -> String {
        let strings = self.presentationData.strings
        switch action {
        case .promote: return strings.GroupInfo_ActionPromote
        case .restrict: return strings.GroupInfo_ActionRestrict
        case .ban: return strings.Conversation_ContextMenuBanFull
        case .removeMember: return strings.GroupInfo_ActionRemove
        case .deleteMessages: return strings.Chat_AdminActionSheet_DeleteAllMessages
        }
    }

    private func exteraPerformAdminShortcut(_ action: AdminPolicy.Action, groupId: EnginePeer.Id, authorId: EnginePeer.Id, confirmed: Bool = false) {
        guard ExteraAdminSettings.shared.quickAdminShortcuts, self.chatLocation.peerId == groupId,
            !self.context.isFrozen, !self.presentationInterfaceState.isNotAccessible else { return }
        self.navigationActionDisposable.set((exteraAdminSnapshot(context: self.context, groupId: groupId, authorId: authorId)
        |> deliverOnMainQueue).startStrict(next: { [weak self] snapshot in
            guard let self, self.chatLocation.peerId == groupId, !self.context.isFrozen, !self.presentationInterfaceState.isNotAccessible else { return }
            guard let snapshot, snapshot.actions(accountId: self.context.account.peerId).contains(action) else {
                self.present(textAlertController(context: self.context, title: nil, text: i18n("Extera.Admin.Unavailable", self.presentationData.strings.baseLanguageCode), actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                return
            }
            switch action {
            case .promote:
                self.push(channelAdminController(context: self.context, updatedPresentationData: self.updatedPresentationData, peerId: groupId, adminId: authorId, initialParticipant: snapshot.participant, updated: { _ in }, upgradedToSupergroup: { [weak self] upgradedId, completion in
                    self?.exteraOpenUpgradedAdminGroup(upgradedId)
                    completion()
                }, transferedOwnership: { [weak self] peerId in
                    self?.exteraOpenUpgradedAdminGroup(peerId)
                }))
            case .restrict:
                self.push(channelBannedMemberController(context: self.context, updatedPresentationData: self.updatedPresentationData, peerId: groupId, memberId: authorId, initialParticipant: snapshot.participant, updated: { _ in }, upgradedToSupergroup: { [weak self] upgradedId, completion in
                    self?.exteraOpenUpgradedAdminGroup(upgradedId)
                    completion()
                }))
            case .ban, .removeMember, .deleteMessages:
                guard confirmed else {
                    self.exteraConfirmAdminShortcut(action, snapshot: snapshot)
                    return
                }
                // Reached only after an explicit destructive confirmation AND a second server
                // rights/membership fetch. No optimistic local history deletion or success toast.
                switch action {
                case .ban:
                    let _ = self.context.peerChannelMemberCategoriesContextsManager.updateMemberBannedRights(engine: self.context.engine, peerId: groupId, memberId: authorId, bannedRights: TelegramChatBannedRights(flags: [.banReadMessages], untilDate: Int32.max)).startStandalone()
                case .removeMember:
                    let _ = self.context.engine.peers.removePeerMember(peerId: groupId, memberId: authorId).startStandalone()
                case .deleteMessages:
                    let _ = self.context.engine.messages.clearAuthorHistory(peerId: groupId, memberId: authorId).startStandalone()
                default: break
                }
            }
        }))
    }

    private func exteraConfirmAdminShortcut(_ action: AdminPolicy.Action, snapshot: ExteraAdminSnapshot) {
        let key: String
        switch action {
        case .ban: key = "Extera.Admin.ConfirmBan"
        case .removeMember: key = "Extera.Admin.ConfirmRemove"
        case .deleteMessages: key = "Extera.Admin.ConfirmDeleteMessages"
        default: return
        }
        let groupId = snapshot.group.id
        let authorId = snapshot.author.id
        self.present(textAlertController(context: self.context, updatedPresentationData: self.updatedPresentationData, title: self.exteraAdminTitle(action), text: i18n(key, self.presentationData.strings.baseLanguageCode, snapshot.author.compactDisplayTitle, snapshot.group.compactDisplayTitle), actions: [
            TextAlertAction(type: .genericAction, title: self.presentationData.strings.Common_Cancel, action: {}),
            TextAlertAction(type: .destructiveAction, title: self.exteraAdminTitle(action), action: { [weak self] in
                self?.exteraPerformAdminShortcut(action, groupId: groupId, authorId: authorId, confirmed: true)
            })
        ]), in: .window(.root))
    }

    private func exteraOpenUpgradedAdminGroup(_ peerId: EnginePeer.Id) {
        let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        |> deliverOnMainQueue).startStandalone(next: { [weak self] peer in
            guard let self, let peer, let navigationController = self.navigationController as? NavigationController else { return }
            self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(peer), keepStack: .always))
        })
    }
}
