import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi
import MtProtoKit
import SGSimpleSettings

// MARK: AyuGram
// The account's blocked users for "Hide from Blocked Users", loaded once per session on first use.
public final class AyuBlockedPeers {
    public static let shared = AyuBlockedPeers()

    private let lock = NSLock()
    private var peerIds: [PeerId: Set<Int64>] = [:]
    private var loadingAccounts = Set<PeerId>()
    private let disposables = DisposableSet()

    private init() {
    }

    // The blocked users known so far; the first call starts loading them.
    public func blockedPeerIds(account: Account) -> Set<Int64> {
        self.lock.lock()
        if let value = self.peerIds[account.peerId] {
            self.lock.unlock()
            return value
        }
        let shouldLoad = !self.loadingAccounts.contains(account.peerId)
        self.loadingAccounts.insert(account.peerId)
        self.lock.unlock()
        if shouldLoad {
            self.load(account: account, offset: 0, collected: Set())
        }
        return Set()
    }

    func update(accountPeerId: PeerId, peerId: PeerId, isBlocked: Bool) {
        self.lock.lock()
        guard var value = self.peerIds[accountPeerId] else {
            self.lock.unlock()
            return
        }
        if isBlocked {
            value.insert(peerId.toInt64())
        } else {
            value.remove(peerId.toInt64())
        }
        self.peerIds[accountPeerId] = value
        self.lock.unlock()
        ayuPostMessageFiltersDidChange()
    }

    private func load(account: Account, offset: Int32, collected: Set<Int64>) {
        let limit: Int32 = 100
        self.disposables.add((account.network.request(Api.functions.contacts.getBlocked(flags: 0, offset: offset, limit: limit))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.contacts.Blocked?, NoError> in
            return .single(nil)
        }
        |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self else {
                return
            }
            var collected = collected
            var hasMore = false
            if let result {
                let blocked: [Api.PeerBlocked]
                switch result {
                case let .blocked(data):
                    blocked = data.blocked
                case let .blockedSlice(data):
                    blocked = data.blocked
                    hasMore = !data.blocked.isEmpty && Int(offset) + data.blocked.count < Int(data.count) && offset < 5000
                }
                for blockedPeer in blocked {
                    switch blockedPeer {
                    case let .peerBlocked(blockedData):
                        collected.insert(blockedData.peerId.peerId.toInt64())
                    }
                }
            }
            if hasMore {
                self.load(account: account, offset: offset + limit, collected: collected)
            } else {
                self.lock.lock()
                self.peerIds[account.peerId] = collected
                self.loadingAccounts.remove(account.peerId)
                self.lock.unlock()
                ayuPostMessageFiltersDidChange()
            }
        }))
    }
}

private func ayuPostMessageFiltersDidChange() {
    Queue.mainQueue().async {
        NotificationCenter.default.post(name: ayuMessageFiltersDidChangeNotification, object: nil)
    }
}
