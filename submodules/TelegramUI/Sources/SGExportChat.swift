import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramPresentationData
import Display
import UIKit

public func sgExportChatJSON(context: AccountContext, peerId: PeerId, completion: @escaping (URL?) -> Void) -> Disposable {
    let disposable = context.engine.messages.exportChatJSON(peerId: peerId).startStandalone(next: { data in
        guard let data else {
            completion(nil)
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(peerId.id._internalGetInt64Value()).json")
        try? data.write(to: url)
        completion(url)
    })
    return disposable
}
