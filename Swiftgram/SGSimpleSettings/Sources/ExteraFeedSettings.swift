import Foundation

/// Local counterpart of exteraGram Android's feed/FeedConfig.kt. IDs are full encoded
/// Telegram peer IDs, scoped by the persistent account record (never the account slot).
public final class ExteraFeedSettings {
    /// Device-wide presentation options. Account selections and read cursors stay in `state`.
    public static let shared = PresentationSettings()

    public final class PresentationSettings {
        fileprivate init() {
            AyuSettingsStore.shared.register(defaults: [
                "extera.feed.widePosts": true,
                "extera.feed.showUnreadCounter": true
            ])
        }

        /// Expands the feed's post cards to the available list width.
        public var widePosts: Bool {
            get { return AyuSettingsStore.shared.bool("extera.feed.widePosts") }
            set { AyuSettingsStore.shared.setBool(newValue, "extera.feed.widePosts") }
        }

        /// Controls the unread counter; it does not filter unread posts or change read state.
        public var showUnreadCounter: Bool {
            get { return AyuSettingsStore.shared.bool("extera.feed.showUnreadCounter") }
            set { AyuSettingsStore.shared.setBool(newValue, "extera.feed.showUnreadCounter") }
        }
    }

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

        /// Replaces a selection explicitly, including clearing channels outside a search result.
        /// Selecting all is not truncated: the loader reports its separate 40-channel limit.
        public mutating func setChannelSelection(_ ids: Set<Int64>, categoryId: String?) {
            if let categoryId {
                guard let index = self.categories.firstIndex(where: { $0.id == categoryId }) else { return }
                self.categories[index].channelIds = ids
            } else {
                self.channelIds = ids
            }
        }

        /// The mark-all scope includes selected subscribed channels even if no posts have loaded.
        /// Archive exclusion is applied before any Telegram read operation is enqueued.
        public func markAllReadChannelIds(available: Set<Int64>, archived: Set<Int64>) -> Set<Int64> {
            let ids = self.effectiveChannelIds.intersection(available)
            return self.includeArchived ? ids : ids.subtracting(archived)
        }

        /// Applies only known message IDs, never an artificial Int32.max cursor that hides future posts.
        public mutating func markRead(maxIds: [Int64: Int32]) {
            for (channelId, messageId) in maxIds where messageId > 0 {
                let key = String(channelId)
                self.readMaxIds[key] = max(self.readMaxIds[key] ?? 0, messageId)
            }
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
            state.markRead(maxIds: [channelId: messageId])
        }
    }
}
