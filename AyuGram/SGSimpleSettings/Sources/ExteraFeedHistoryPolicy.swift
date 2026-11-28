/// Pure history decisions shared by the engine adapter and host tests.
public enum ExteraFeedHistoryPolicy {
    public static let maximumConcurrentRequests = 4
    public static let maximumPostsPerChannel = 100
    public static let maximumVisiblePosts = 1000

    /// A non-exhausted channel may still contain posts newer than another channel's
    /// oldest page. Only the intersection of the confirmed windows can be published.
    public static func frontier<Channel: Hashable, Position: Comparable>(oldest: [Channel: Position], exhausted: Set<Channel>) -> Position? {
        return oldest.compactMap { exhausted.contains($0.key) ? nil : $0.value }.max()
    }

    public struct RequestQueue {
        private var pending: [Int64] = []
        public var isEmpty: Bool { return self.pending.isEmpty }

        public init() {}

        public mutating func replace(with ids: Set<Int64>) {
            self.pending = ids.sorted()
        }

        /// A cancelled active page must be retried with its old cursor on resume.
        public mutating func resume(cancelled ids: Set<Int64>) {
            self.pending = Set(self.pending).union(ids).sorted()
        }

        public mutating func next(active: Set<Int64>) -> Int64? {
            guard active.count < ExteraFeedHistoryPolicy.maximumConcurrentRequests else { return nil }
            while !self.pending.isEmpty {
                let id = self.pending.removeFirst()
                if !active.contains(id) { return id }
            }
            return nil
        }
    }
}
