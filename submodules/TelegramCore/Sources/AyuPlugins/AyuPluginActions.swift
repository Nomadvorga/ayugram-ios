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
