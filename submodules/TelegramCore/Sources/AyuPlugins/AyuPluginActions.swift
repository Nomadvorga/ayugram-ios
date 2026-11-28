import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

/// State changes a plugin may ask for (`telegram.action.*`). Each one goes through the call the
/// app itself makes for the same user action, so the app's own rules (ghost mode, what a
/// deletion removes for whom, the min/access-hash rules of cached peers) apply unchanged.

private func ayuPluginUnknownDialog<T>() -> Signal<T, AyuPluginCoreError> {
    return .fail(.invalidArguments("dialog_id is not known to the account"))
}

/// Deletes stored cloud messages of a dialog the way the chat screen does. `forEveryone` is
/// Android's `forAll`; a channel has one copy of each message, so there it is always true.
/// Completes once the deletion is recorded locally and queued for the server.
public func ayuPluginDeleteMessages(account: Account, dialogId: Int64, ids: [Int32], forEveryone: Bool) -> Signal<Never, AyuPluginCoreError> {
    return account.postbox.transaction { transaction -> PeerId? in
        return ayuPluginCachedPeer(transaction: transaction, dialogId: dialogId)?.id
    }
    |> castError(AyuPluginCoreError.self)
    |> mapToSignal { peerId -> Signal<Never, AyuPluginCoreError> in
        guard let peerId else {
            return ayuPluginUnknownDialog()
        }
        let messageIds = ids.map { MessageId(peerId: peerId, namespace: Namespaces.Message.Cloud, id: $0) }
        let type: InteractiveMessagesDeletionType = forEveryone || peerId.namespace == Namespaces.Peer.CloudChannel ? .forEveryone : .forLocalPeer
        return TelegramEngine(account: account).messages.deleteMessagesInteractively(messageIds: messageIds, type: type)
        |> castError(AyuPluginCoreError.self)
        |> ignoreValues
    }
}

/// Marks the incoming messages of a dialog up to the stored message `maxId` as read, as
/// scrolling to that message does.
public func ayuPluginReadDialog(account: Account, dialogId: Int64, maxId: Int32) -> Signal<Never, AyuPluginCoreError> {
    let stateManager: AccountStateManager = account.stateManager
    return account.postbox.transaction { transaction -> AyuPluginCoreError? in
        guard let peer = ayuPluginCachedPeer(transaction: transaction, dialogId: dialogId) else {
            return .invalidArguments("dialog_id is not known to the account")
        }
        guard let message = transaction.getMessage(MessageId(peerId: peer.id, namespace: Namespaces.Message.Cloud, id: maxId)) else {
            return .invalidArguments("max_id is not a stored message of the dialog")
        }
        _internal_applyMaxReadIndexInteractively(transaction: transaction, stateManager: stateManager, index: message.index)
        return nil
    }
    |> castError(AyuPluginCoreError.self)
    |> mapToSignal { error -> Signal<Never, AyuPluginCoreError> in
        if let error {
            return .fail(error)
        }
        return .complete()
    }
}

/// Marks every dialog with unread messages as read, each the way the chat list's "Mark as Read"
/// does (the topics of a forum included): the main list (`folderId` 0), the archive (1) or,
/// with a negative `folderId`, both. A dialog with no unread message that is only marked unread
/// by hand keeps its mark: Android reads the dialogs whose `unread_count` is above zero.
public func ayuPluginReadAllDialogs(account: Account, folderId: Int32) -> Signal<Never, AyuPluginCoreError> {
    let network: Network = account.network
    let viewTracker: AccountViewTracker = account.viewTracker
    let groups: [PeerGroupId]
    if folderId < 0 {
        groups = [.root, Namespaces.PeerGroup.archive]
    } else if folderId == 0 {
        groups = [.root]
    } else if folderId == Namespaces.PeerGroup.archive.rawValue {
        groups = [Namespaces.PeerGroup.archive]
    } else {
        groups = []
    }
    return account.postbox.transaction { transaction -> Void in
        for groupId in groups {
            for peerId in transaction.getUnreadChatListPeerIds(groupId: groupId, filterPredicate: nil, additionalFilter: nil, stopOnFirstMatch: false) {
                if let state = transaction.getCombinedPeerReadState(peerId), state.count == 0, state.markedUnread {
                    continue
                }
                _internal_togglePeerUnreadMarkInteractively(transaction: transaction, network: network, viewTracker: viewTracker, peerId: peerId, setToValue: false)
            }
        }
    }
    |> castError(AyuPluginCoreError.self)
    |> ignoreValues
}

/// Moves dialogs into the main list (`folderId` 0) or the archive (1) the way the chat list's
/// "Archive" and "Unarchive" do, which also unpins them. As on Android, a dialog that is not in
/// the chat list is skipped, and Saved Messages, the service notifications chat and a promoted
/// chat never go to the archive. The value is Android's result: 0 when no dialog was accepted,
/// 2 when the archive held no chat before, otherwise 1.
public func ayuPluginAddDialogsToFolder(account: Account, dialogIds: [Int64], folderId: Int32) -> Signal<Int32, AyuPluginCoreError> {
    let groupId: PeerGroupId
    if folderId == 0 {
        groupId = .root
    } else if folderId == Namespaces.PeerGroup.archive.rawValue {
        groupId = Namespaces.PeerGroup.archive
    } else {
        return .fail(.invalidArguments("folder_id must be 0 or 1"))
    }
    let accountPeerId = account.peerId
    return account.postbox.transaction { transaction -> Int32 in
        let toArchive = groupId != .root
        let createsArchive = toArchive && transaction.getTopChatListEntries(groupId: groupId, count: 1).isEmpty
        let promoted = Set(transaction.getAdditionalChatListItems().map { $0.peerId })
        var added = false
        for dialogId in dialogIds {
            guard let peerId = ayuPluginCachedPeer(transaction: transaction, dialogId: dialogId)?.id else {
                continue
            }
            if toArchive && (peerId == accountPeerId || dialogId == 777000 || promoted.contains(peerId)) {
                continue
            }
            guard transaction.getPeerChatListIndex(peerId) != nil else {
                continue
            }
            added = true
            _internal_updatePeerGroupIdInteractively(transaction: transaction, peerId: peerId, groupId: groupId)
        }
        return !added ? 0 : (createsArchive ? 2 : 1)
    }
    |> castError(AyuPluginCoreError.self)
}

/// Hands a boxed `Updates` to the account's state manager, as a caller of `Network.request`
/// does with a response. It passes the update hooks like a container the server pushed.
public func ayuPluginProcessUpdates(account: Account, updates: Data) throws {
    guard let parsed = Api.parse(Buffer(data: updates)) as? Api.Updates else {
        throw AyuPluginCoreError.invalidArguments("updates is not an Updates object of layer \(ayuPluginApiLayer)")
    }
    account.stateManager.addUpdates(parsed)
}

/// Merges boxed `User` and `Chat` objects into the peer cache exactly as the users and chats
/// of a response are merged (a `min` object never replaces a full one, an access hash is kept).
public func ayuPluginStorePeers(account: Account, users: [Data], chats: [Data]) -> Signal<Never, AyuPluginCoreError> {
    var parsedUsers: [Api.User] = []
    for data in users {
        guard let user = Api.parse(Buffer(data: data)) as? Api.User else {
            return .fail(.invalidArguments("users must hold User objects of layer \(ayuPluginApiLayer)"))
        }
        parsedUsers.append(user)
    }
    var parsedChats: [Api.Chat] = []
    for data in chats {
        guard let chat = Api.parse(Buffer(data: data)) as? Api.Chat else {
            return .fail(.invalidArguments("chats must hold Chat objects of layer \(ayuPluginApiLayer)"))
        }
        parsedChats.append(chat)
    }
    let accountPeerId = account.peerId
    return account.postbox.transaction { transaction -> Void in
        updatePeers(transaction: transaction, accountPeerId: accountPeerId, peers: AccumulatedPeers(transaction: transaction, chats: parsedChats, users: parsedUsers))
    }
    |> castError(AyuPluginCoreError.self)
    |> ignoreValues
}

/// Starts the request that refreshes the cached full info of a user (`isUser`), or of a group
/// or channel, and completes once it is started; the result arrives in the cache.
public func ayuPluginLoadFullPeer(account: Account, isUser: Bool, id: Int64) -> Signal<Never, AyuPluginCoreError> {
    let accountPeerId = account.peerId
    let network = account.network
    let postbox = account.postbox
    return postbox.transaction { transaction -> PeerId? in
        return ayuPluginCachedPeer(transaction: transaction, dialogId: isUser ? id : -id)?.id
    }
    |> castError(AyuPluginCoreError.self)
    |> mapToSignal { peerId -> Signal<Never, AyuPluginCoreError> in
        guard let peerId else {
            return .fail(.invalidArguments("id is not known to the account"))
        }
        let _ = _internal_fetchAndUpdateCachedPeerData(accountPeerId: accountPeerId, peerId: peerId, network: network, postbox: postbox).start()
        return .complete()
    }
}
