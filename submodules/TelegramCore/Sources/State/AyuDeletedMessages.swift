import Foundation
import Postbox
import SwiftSignalKit
import SGSimpleSettings

// MARK: AyuGram
// Messages deleted on the server (by their author, an admin, or this account on another device)
// stay in the chat with AyuDeletedMessageAttribute. Deletions made on this device never get here:
// they remove the message locally before the server echoes the update.
// Returns true when the message is kept and must not be deleted.
func ayuKeepDeletedMessage(transaction: Transaction, id: MessageId) -> Bool {
    if id.namespace != Namespaces.Message.Cloud {
        return false
    }
    let exclusion = ayuSavingExclusion(peerId: id.peerId)
    if exclusion == .never || (exclusion == .default && !AyuSaveSettings.shared.saveDeletedMessages) {
        return false
    }
    guard let message = transaction.getMessage(id) else {
        return false
    }
    if message.ayuDeletedDate != nil {
        return true
    }
    if message.media.contains(where: { $0 is TelegramMediaAction }) {
        return false
    }
    if exclusion == .default && !AyuSaveSettings.shared.saveForBots && ayuIsBotDialog(message) {
        return false
    }
    let deletionDate = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
    transaction.updateMessage(id, update: { currentMessage in
        let storeForwardInfo = currentMessage.forwardInfo.flatMap(StoreMessageForwardInfo.init)
        var attributes = currentMessage.attributes
        attributes.append(AyuDeletedMessageAttribute(date: deletionDate))
        return .update(StoreMessage(id: currentMessage.id, customStableId: nil, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: attributes, media: currentMessage.media))
    })
    return true
}

// "Clear Deleted": removes the kept deleted messages of a chat from this device.
public func ayuClearDeletedMessages(account: Account, peerId: PeerId) -> Signal<Int, NoError> {
    let mediaBox = account.postbox.mediaBox
    return account.postbox.transaction { transaction -> Int in
        var ids: [MessageId] = []
        transaction.withAllMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, { message in
            if message.ayuDeletedDate != nil {
                ids.append(message.id)
            }
            return true
        })
        if !ids.isEmpty {
            _internal_deleteMessages(transaction: transaction, mediaBox: mediaBox, ids: ids)
        }
        return ids.count
    }
}

func ayuSavingExclusion(peerId: PeerId) -> AyuExclusions.Mode {
    return AyuExclusions.shared.mode(.saving, peerId: peerId.toInt64())
}

func ayuIsBotDialog(_ message: Message) -> Bool {
    if let user = message.peers[message.id.peerId] as? TelegramUser, user.botInfo != nil {
        return true
    }
    return false
}

// Keeps what can be kept and returns the global ids that still have to be deleted.
func ayuGlobalIdsToDelete(transaction: Transaction, ids: [Int32]) -> [Int32] {
    return ids.filter { globalId in
        guard let messageId = transaction.messageIdsForGlobalIds([globalId]).first else {
            return true
        }
        return !ayuKeepDeletedMessage(transaction: transaction, id: messageId)
    }
}
