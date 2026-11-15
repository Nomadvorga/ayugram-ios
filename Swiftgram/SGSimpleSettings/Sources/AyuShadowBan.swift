import Foundation

// MARK: AyuGram
// Posted on the main queue when the shadow ban list or the blocked users change, so open chats re-filter their history.
public let ayuMessageFiltersDidChangeNotification = Notification.Name("AyuMessageFiltersDidChange")

// "Shadow Ban": messages of these users are hidden locally in groups and channels' comments.
public final class AyuShadowBan {
    public static let shared = AyuShadowBan()

    private static let key = "ayu.filters.shadowBan"

    private let store = AyuSettingsStore.shared
    private let lock = NSLock()
    private var cachedPeerIds: Set<Int64>?

    private init() {
    }

    public var peerIds: Set<Int64> {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let cachedPeerIds = self.cachedPeerIds {
            return cachedPeerIds
        }
        let peerIds = Set(self.store.intDictionary(AyuShadowBan.key).keys.compactMap(Int64.init))
        self.cachedPeerIds = peerIds
        return peerIds
    }

    public func isBanned(peerId: Int64) -> Bool {
        return self.peerIds.contains(peerId)
    }

    public func setBanned(_ banned: Bool, peerId: Int64) {
        var values = self.store.intDictionary(AyuShadowBan.key)
        if banned {
            values[String(peerId)] = 1
        } else {
            values.removeValue(forKey: String(peerId))
        }
        self.lock.lock()
        self.cachedPeerIds = Set(values.keys.compactMap(Int64.init))
        self.lock.unlock()
        self.store.setIntDictionary(values, AyuShadowBan.key)
        NotificationCenter.default.post(name: ayuMessageFiltersDidChangeNotification, object: nil)
    }
}
