import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import Display
import UIKit

public func sgExportChatJSON(context: AccountContext, peerId: PeerId, completion: @escaping (URL?) -> Void) -> Disposable {
    let disposable = context.account.postbox.transaction { transaction -> Data? in
        var entries: [[String: Any]] = []
        transaction.scanMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, tag: nil, { message -> Bool in
            entries.append([
                "id": message.id.id,
                "date": message.timestamp,
                "sender": message.effectiveAuthor?.displayTitle ?? "",
                "out": message.isOutgoing,
                "text": message.text
            ])
            return true
        })
        guard !entries.isEmpty else {
            return nil
        }
        let peer = transaction.getPeer(peerId)
        let result: [String: Any] = [
            "chat": peer?.displayTitle ?? "",
            "peerId": peerId.id.rawValue,
            "exportedAt": Int32(Date().timeIntervalSince1970),
            "messages": entries
        ]
        return try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }.startStandalone(next: { data in
        guard let data else {
            completion(nil)
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(peerId.id.rawValue).json")
        try? data.write(to: url)
        completion(url)
    })
    return disposable
}
