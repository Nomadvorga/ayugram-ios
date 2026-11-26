import AccountContext
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

private typealias HeaderPolicy = ExteraAdminHeaderPolicy

private struct ExteraAdminHeaderSnapshot {
    let peer: EnginePeer
    let kind: HeaderPolicy.Kind
    let role: HeaderPolicy.Role

    var entries: [HeaderPolicy.Entry] {
        return HeaderPolicy.entries(enabled: ExteraAdminSettings.shared.quickAdminShortcuts, kind: self.kind, role: self.role, isMember: true, isMonoforum: false)
    }
}

private func exteraAdminHeaderKind(_ channel: TelegramChannel) -> HeaderPolicy.Kind {
    if channel.flags.contains(.isGigagroup) { return .gigagroup }
    switch channel.info {
    case .broadcast: return .broadcast
    case .group: return .supergroup
    }
}

private func exteraAdminHeaderRole(_ participant: ChannelParticipant?, accountId: EnginePeer.Id) -> HeaderPolicy.Role {
    guard let participant, participant.peerId == accountId else { return .unknown }
    switch participant {
    case .creator: return .owner
    case let .member(_, _, adminInfo, banInfo, _, _):
        if let banInfo, !banInfo.isMember || banInfo.rights.flags.contains(.banReadMessages) { return .unknown }
        return adminInfo == nil ? .member : .administrator
    }
}

/// Refresh peer metadata for the native destination screens and fetch the actor's server role.
/// Neither a cached creator flag nor cached admin rights is sufficient to expose/open a section.
private func exteraAdminHeaderSnapshot(context: AccountContext, peerId: EnginePeer.Id) -> Signal<ExteraAdminHeaderSnapshot?, NoError> {
    guard peerId.namespace == Namespaces.Peer.CloudChannel else { return .single(nil) }
    return combineLatest(
        context.engine.peers.fetchAndUpdateCachedPeerData(peerId: peerId),
        context.engine.peers.fetchChannelParticipant(peerId: peerId, participantId: context.account.peerId)
    )
    |> mapToSignal { updated, participant -> Signal<ExteraAdminHeaderSnapshot?, NoError> in
        guard updated else { return .single(nil) }
        let role = exteraAdminHeaderRole(participant, accountId: context.account.peerId)
        guard role == .owner || role == .administrator else { return .single(nil) }
        return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        |> map { peer -> ExteraAdminHeaderSnapshot? in
            guard let peer, case let .channel(channel) = peer, channel.participationStatus == .member,
                !channel.flags.contains(.isMonoforum) else { return nil }
            return ExteraAdminHeaderSnapshot(peer: peer, kind: exteraAdminHeaderKind(channel), role: role)
        }
    }
    |> take(1)
    |> timeout(3.0, queue: .mainQueue(), alternate: .single(nil))
}

extension ChatControllerImpl {
    private func exteraCanRequestAdminHeader(peerId: EnginePeer.Id) -> Bool {
        guard ExteraAdminSettings.shared.quickAdminShortcuts, self.chatLocation.peerId == peerId,
            !self.context.isFrozen, !self.presentationInterfaceState.isNotAccessible,
            self.presentationInterfaceState.interfaceState.selectionState == nil,
            let channel = self.presentationInterfaceState.renderedPeer?.chatMainPeer as? TelegramChannel,
            channel.id == peerId, channel.participationStatus == .member, !channel.flags.contains(.isMonoforum) else { return false }
        return !HeaderPolicy.entries(enabled: true, kind: exteraAdminHeaderKind(channel), role: channel.flags.contains(.isCreator) ? .owner : (channel.adminRights == nil ? .member : .administrator), isMember: true, isMonoforum: false).isEmpty
    }

    /// Existing Info and forum-sidebar More menus consume this, preserving their own items/source.
    /// A single initial emission prevents the moderation section from appearing mid-animation.
    func exteraAdminHeaderMenuItems(addingTo base: Signal<[ContextMenuItem], NoError>, peerId: EnginePeer.Id) -> Signal<[ContextMenuItem], NoError> {
        guard self.exteraCanRequestAdminHeader(peerId: peerId) else { return base }
        return combineLatest(base, exteraAdminHeaderSnapshot(context: self.context, peerId: peerId))
        |> deliverOnMainQueue
        |> map { [weak self] items, snapshot -> [ContextMenuItem] in
            guard let self, self.exteraCanRequestAdminHeader(peerId: peerId), let snapshot else { return items }
            let adminItems = self.exteraAdminHeaderItems(snapshot)
            return adminItems.isEmpty ? items : items + (items.isEmpty ? [] : [.separator]) + adminItems
        }
    }

    /// The existing forum More factory lives in frozen ChatListUI. Keep it available as the native
    /// More submenu without changing its API, source or actions. Non-admin/disabled paths fall through.
    @discardableResult
    func exteraOpenAdminHeaderMoreMenu(peerId: EnginePeer.Id, sourceView: UIView, gesture: ContextGesture?, originalMenu: @escaping () -> Void) -> Bool {
        guard self.exteraCanRequestAdminHeader(peerId: peerId) else { return false }
        self.navigationActionDisposable.set((exteraAdminHeaderSnapshot(context: self.context, peerId: peerId)
        |> deliverOnMainQueue).startStrict(next: { [weak self] snapshot in
            guard let self, self.chatLocation.peerId == peerId else { return }
            guard self.exteraCanRequestAdminHeader(peerId: peerId), let snapshot, !snapshot.entries.isEmpty else {
                originalMenu()
                return
            }
            var items = self.exteraAdminHeaderItems(snapshot)
            items.append(.separator)
            items.append(.action(ContextMenuActionItem(text: self.presentationData.strings.Common_More, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/More"), color: theme.contextMenu.primaryColor)
            }, action: { controller, completion in
                if let controller { controller.dismiss(completion: originalMenu) }
                else { completion(.dismissWithoutContent); originalMenu() }
            })))
            let controller = makeContextController(presentationData: self.presentationData, source: .reference(ChatControllerContextReferenceContentSource(controller: self, sourceView: sourceView, insets: .zero)), items: .single(ContextController.Items(content: .list(items))), gesture: gesture)
            self.presentInGlobalOverlay(controller)
        }))
        return true
    }

    private func exteraAdminHeaderItems(_ snapshot: ExteraAdminHeaderSnapshot) -> [ContextMenuItem] {
        return snapshot.entries.map { entry in
            let title: String
            let icon: String
            switch entry.destination {
            case .groupPermissions:
                title = self.presentationData.strings.GroupInfo_Permissions
                icon = "Restrict"
            case .removedUsers:
                title = self.presentationData.strings.GroupInfo_Permissions_Removed
                icon = "Restrict"
            case .administrators:
                title = self.presentationData.strings.GroupInfo_Administrators
                icon = "Promote"
            case .members:
                title = snapshot.kind == .broadcast ? self.presentationData.strings.Channel_Info_Subscribers : self.presentationData.strings.Group_Info_Members
                icon = "Groups"
            case .recentActions:
                title = self.presentationData.strings.Group_Info_AdminLog
                icon = "Schedule"
            }
            return .action(ContextMenuActionItem(text: title, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/" + icon), color: theme.contextMenu.primaryColor)
            }, action: { [weak self] controller, completion in
                let open: () -> Void = { [weak self] in self?.exteraOpenAdminHeaderDestination(entry, peerId: snapshot.peer.id) }
                if let controller { controller.dismiss { open() } }
                else { completion(.dismissWithoutContent); open() }
            }))
        }
    }

    private func exteraOpenAdminHeaderDestination(_ entry: HeaderPolicy.Entry, peerId: EnginePeer.Id) {
        guard self.exteraCanRequestAdminHeader(peerId: peerId) else { return }
        self.navigationActionDisposable.set((exteraAdminHeaderSnapshot(context: self.context, peerId: peerId)
        |> deliverOnMainQueue).startStrict(next: { [weak self] snapshot in
            guard let self, self.exteraCanRequestAdminHeader(peerId: peerId) else { return }
            guard let snapshot, snapshot.entries.contains(entry) else {
                self.present(textAlertController(context: self.context, title: nil, text: i18n("Extera.Admin.Unavailable", self.presentationData.strings.baseLanguageCode), actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                return
            }
            let controller: ViewController
            switch entry.destination {
            case .groupPermissions:
                controller = channelPermissionsController(context: self.context, updatedPresentationData: self.updatedPresentationData, peerId: peerId)
            case .removedUsers:
                controller = channelBlacklistController(context: self.context, updatedPresentationData: self.updatedPresentationData, peerId: peerId)
            case .administrators:
                controller = channelAdminsController(context: self.context, updatedPresentationData: self.updatedPresentationData, peerId: peerId)
            case .members:
                controller = channelMembersController(context: self.context, updatedPresentationData: self.updatedPresentationData, peerId: peerId)
            case .recentActions:
                controller = self.context.sharedContext.makeChatRecentActionsController(context: self.context, peer: snapshot.peer, adminPeerId: nil, starsState: nil)
            }
            self.push(controller)
        }))
    }
}
