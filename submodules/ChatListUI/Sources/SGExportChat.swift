import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import Display

// Retained by the progress overlay's cancel action. The operation does not
// retain this owner, so dismissing/deallocating the overlay cancels its work.
final class CachedChatExportTask {
    let disposable = MetaDisposable()
    weak var progress: ViewController?
    private(set) var isCancelled = false

    func cancel() {
        self.isCancelled = true
        self.disposable.dispose()
        self.progress?.dismiss()
    }

    deinit {
        self.disposable.dispose()
    }
}

private final class CachedChatExportFile: Disposable {
    private let queue = Queue(name: "CachedChatExportFile")
    private let disposable = MetaDisposable()
    private let lock = NSLock()
    private var cancelled = false
    private var ownedURL: URL?
    private var completion: ((URL?) -> Void)?

    init(completion: @escaping (URL?) -> Void) {
        self.completion = completion
    }

    func start(context: AccountContext, peerId: EnginePeer.Id) {
        self.disposable.set((context.engine.messages.exportChatJSON(peerId: peerId)
        |> deliverOn(self.queue)).start(next: { [self] data in
            self.lock.lock()
            let cancelled = self.cancelled
            self.lock.unlock()
            guard !cancelled else { return }

            var result: URL?
            if let data {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(peerId.id._internalGetInt64Value())-\(UUID().uuidString).json")
                self.lock.lock()
                let mayWrite = !self.cancelled
                if mayWrite { self.ownedURL = url }
                self.lock.unlock()
                guard mayWrite else { return }
                do {
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    result = url
                } catch {
                    try? FileManager.default.removeItem(at: url)
                }
                // Disposal can race the synchronous write. Even when disposal
                // removed the path before write() finished, remove its new output.
                self.lock.lock()
                let cancelledAfterWrite = self.cancelled
                self.lock.unlock()
                if cancelledAfterWrite {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
            }
            let url = result
            Queue.mainQueue().async { [self] in
                self.lock.lock()
                let completion = self.cancelled ? nil : self.completion
                self.completion = nil
                if completion != nil {
                    // Ownership passes to the completion callback, which either
                    // shares the file or removes it when its presenter is gone.
                    self.ownedURL = nil
                }
                self.lock.unlock()
                completion?(url)
                self.disposable.set(nil)
            }
        }))
    }

    func dispose() {
        self.lock.lock()
        self.cancelled = true
        self.completion = nil
        let url = self.ownedURL
        self.ownedURL = nil
        self.lock.unlock()
        self.disposable.dispose()
        if let url {
            self.queue.async { try? FileManager.default.removeItem(at: url) }
        }
    }
}

/// Exports cached cloud-message text. Completion runs on the main queue and
/// takes ownership of a successful temporary URL; disposal cleans up until then.
public func sgExportChatJSON(context: AccountContext, peerId: EnginePeer.Id, completion: @escaping (URL?) -> Void) -> Disposable {
    let export = CachedChatExportFile(completion: completion)
    export.start(context: context, peerId: peerId)
    return export
}
