import Foundation

/// Local counterpart of exteraGram Android's feed/FeedConfig.kt. IDs are full encoded
/// Telegram peer IDs, scoped by the persistent account record (never the account slot).
public final class ExteraFeedSettings {
    public struct Category: Codable, Equatable {
        public var id: String
        public var title: String
        public var channelIds: Set<Int64>
        public var isHidden: Bool

        public init(id: String = UUID().uuidString, title: String, channelIds: Set<Int64> = [], isHidden: Bool = false) {
            self.id = id
            self.title = title
            self.channelIds = channelIds
            self.isHidden = isHidden
        }
    }

    public struct State: Codable, Equatable {
        public var channelIds: Set<Int64> = []
        public var includeArchived = false
        public var categories: [Category] = []
        public var selectedCategoryId: String?
        public var unreadOnly = false
        public var readMaxIds: [String: Int32] = [:]

        public init() {
        }

        public var selectedCategory: Category? {
            return self.categories.first(where: { $0.id == self.selectedCategoryId && !$0.isHidden })
        }

        public var effectiveChannelIds: Set<Int64> {
            return self.selectedCategory?.channelIds ?? self.channelIds
        }

        public func isUnread(channelId: Int64, messageId: Int32) -> Bool {
            return messageId > (self.readMaxIds[String(channelId)] ?? 0)
        }
    }

    private static let lock = NSRecursiveLock()
    private let key: String

    public init(accountId: Int64) {
        self.key = "extera.feed.account.\(accountId).v1"
    }

    public var state: State {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard let data = AyuSettingsStore.shared.string(self.key).data(using: .utf8),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    /// Reads and writes under one lock so independent feed screens cannot lose a cursor update.
    public func update(_ f: (inout State) -> Void) {
        // setString normally posts synchronously. A queue-bound observer may wait for
        // another queue that reads this state, so publish only after releasing our lock.
        AyuSettingsStore.shared.performBatchUpdates {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            var value = self.state
            let previous = value
            f(&value)
            if !value.categories.contains(where: { $0.id == value.selectedCategoryId && !$0.isHidden }) {
                value.selectedCategoryId = nil
            }
            guard value != previous, let data = try? JSONEncoder().encode(value),
                  let string = String(data: data, encoding: .utf8) else { return }
            AyuSettingsStore.shared.setString(string, self.key)
        }
    }

    public func markRead(channelId: Int64, messageId: Int32) {
        guard messageId > 0 else { return }
        self.update { state in
            let key = String(channelId)
            state.readMaxIds[key] = max(state.readMaxIds[key] ?? 0, messageId)
        }
    }
}
