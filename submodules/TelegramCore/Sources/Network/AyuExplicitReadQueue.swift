import Foundation

public enum AyuReadHistoryEnqueueResult: Equatable {
    case queued
    case coalesced
    case queueFull
    case invalidInput
    case loggedOut
}

/// An account-scoped, persisted error for an explicit read. Only allowlisted
/// server constants and local error codes are stored, never arbitrary RPC text.
public struct AyuReadHistoryFailure: Codable, Equatable {
    public let id: String
    /// Packed Postbox PeerId; convert with PeerId(peerIdValue) in the UI.
    public let peerIdValue: Int64
    public let maxId: Int32
    public let code: String
}

public struct AyuReadHistoryRequest: Equatable {
    public let peerIdValue: Int64
    public let maxId: Int32

    public init(peerIdValue: Int64, maxId: Int32) {
        self.peerIdValue = peerIdValue
        self.maxId = maxId
    }
}

public struct AyuReadHistoryPending: Equatable {
    public let id: String
    public let peerIdValue: Int64
    public let maxId: Int32
    public let attempts: Int
    public let retryAt: Double
}

public struct AyuReadHistoryReceipt: Codable, Equatable {
    public enum Status: String, Codable {
        case confirmed
        // Cancelling cannot retract a request already received by the server.
        case cancelled
    }

    public let id: String
    public let peerIdValue: Int64
    public let maxId: Int32
    public let status: Status
    public let timestamp: Double
}

public struct AyuReadHistorySnapshot: Equatable {
    public let ownerIdValue: Int64
    public let closed: Bool
    public let pending: [AyuReadHistoryPending]
    public let failures: [AyuReadHistoryFailure]
    public let receipts: [AyuReadHistoryReceipt]

    init(_ queue: AyuExplicitReadQueue) {
        self.ownerIdValue = queue.ownerId
        self.closed = queue.closed
        self.pending = queue.intents.map { .init(id: $0.id, peerIdValue: $0.peerId, maxId: $0.maxId, attempts: $0.attempts, retryAt: $0.retryAt) }
        self.failures = queue.failures
        self.receipts = queue.receipts
    }
}

public enum AyuReadHistoryControlResult: Equatable {
    case applied
    case stale
    case waitingForRetry
    case queueFull
    case invalidInput
    case loggedOut
}

public enum AyuReadHistoryControl: Equatable {
    case cancel(id: String, maxId: Int32)
    case retryPending(id: String, maxId: Int32)
    case retryFailure(id: String)
    case dismissFailure(id: String)
}

enum AyuExplicitReadAttemptResult: Equatable {
    case success
    case retry(after: Double?)
    case rejected(String)
}

/// Foundation-only queue policy. The owning account's Postbox is the sole store.
/// The bound applies across peers; an accepted intent is never evicted for space.
struct AyuExplicitReadQueue: Codable, Equatable {
    static let capacity = 1024
    static let failureCapacity = 32
    static let receiptCapacity = 64

    struct Intent: Codable, Equatable {
        let id: String
        let peerId: Int64
        var maxId: Int32
        var attempts: Int
        var retryAt: Double
    }

    let ownerId: Int64
    private(set) var revision: Int64 = 0
    private(set) var closed = false
    private(set) var intents: [Intent] = []
    private(set) var failures: [AyuReadHistoryFailure] = []
    private(set) var receipts: [AyuReadHistoryReceipt] = []

    init(ownerId: Int64) {
        self.ownerId = ownerId
    }

    private enum CodingKeys: String, CodingKey {
        case ownerId, revision, closed, intents, failures, receipts
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.ownerId = try values.decode(Int64.self, forKey: .ownerId)
        self.revision = try values.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        self.closed = try values.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        self.intents = try values.decode([Intent].self, forKey: .intents)
        self.failures = try values.decode([AyuReadHistoryFailure].self, forKey: .failures)
        // The first queue version had no receipt history.
        self.receipts = try values.decodeIfPresent([AyuReadHistoryReceipt].self, forKey: .receipts) ?? []
    }

    mutating func enqueue(peerId: Int64, maxId: Int32) -> AyuReadHistoryEnqueueResult {
        guard !self.closed else {
            return .loggedOut
        }
        guard maxId > 0, maxId < Int32.max - 1 else {
            self.recordFailure(peerId: peerId, maxId: maxId, code: "LOCAL_INVALID_MESSAGE")
            return .invalidInput
        }
        if let index = self.intents.firstIndex(where: { $0.peerId == peerId }) {
            // New actions cannot bypass a persisted flood/backoff deadline.
            self.intents[index].maxId = max(self.intents[index].maxId, maxId)
            return .coalesced
        }
        // Unresolved server rejections keep the slot of the accepted intent.
        // They must remain reachable until explicitly retried/dismissed.
        guard self.intents.count + self.failures.filter({ !$0.code.hasPrefix("LOCAL_") }).count < Self.capacity else {
            self.recordFailure(peerId: peerId, maxId: maxId, code: "LOCAL_QUEUE_FULL")
            return .queueFull
        }
        self.intents.append(Intent(id: UUID().uuidString, peerId: peerId, maxId: maxId, attempts: 0, retryAt: 0))
        return .queued
    }

    mutating func finish(_ sent: Intent, result: AyuExplicitReadAttemptResult, now: Double) {
        guard !self.closed, let index = self.intents.firstIndex(where: { $0.id == sent.id && $0.peerId == sent.peerId }) else {
            return
        }
        switch result {
        case .success:
            self.recordReceipt(peerId: sent.peerId, maxId: sent.maxId, status: .confirmed, now: now)
            if self.intents[index].maxId <= sent.maxId {
                self.intents.remove(at: index)
            } else {
                self.intents[index].attempts = 0
                self.intents[index].retryAt = 0
            }
        case let .rejected(code):
            // A reply to an older maxId cannot discard a newer explicit action.
            if self.intents[index].maxId > sent.maxId {
                self.intents[index].attempts = 0
                self.intents[index].retryAt = 0
            } else {
                self.intents.remove(at: index)
                self.recordFailure(peerId: sent.peerId, maxId: sent.maxId, code: code)
            }
        case let .retry(after):
            let attempts = min(16, self.intents[index].attempts + 1)
            self.intents[index].attempts = attempts
            self.intents[index].retryAt = now + max(Self.backoff(attempts: attempts), after ?? 0)
        }
    }

    mutating func recordFailure(peerId: Int64, maxId: Int32, code: String) {
        self.failures.append(.init(id: UUID().uuidString, peerIdValue: peerId, maxId: maxId, code: code))
        let localIds = Set(self.failures.filter { $0.code.hasPrefix("LOCAL_") }.suffix(Self.failureCapacity).map(\.id))
        self.failures.removeAll(where: { $0.code.hasPrefix("LOCAL_") && !localIds.contains($0.id) })
    }

    mutating func acknowledgeFailures(ids: Set<String>) {
        self.failures.removeAll(where: { ids.contains($0.id) })
    }

    mutating func cancel(id: String, maxId: Int32, now: Double) -> AyuReadHistoryControlResult {
        guard !self.closed else { return .loggedOut }
        guard let index = self.intents.firstIndex(where: { $0.id == id && $0.maxId == maxId }) else { return .stale }
        let intent = self.intents.remove(at: index)
        self.recordReceipt(peerId: intent.peerId, maxId: intent.maxId, status: .cancelled, now: now)
        return .applied
    }

    mutating func retryPending(id: String, maxId: Int32, now: Double) -> AyuReadHistoryControlResult {
        guard !self.closed else { return .loggedOut }
        guard let index = self.intents.firstIndex(where: { $0.id == id && $0.maxId == maxId }) else { return .stale }
        guard self.intents[index].retryAt <= now else { return .waitingForRetry }
        let intent = self.intents.remove(at: index)
        // A fresh identity invalidates late completions of the interrupted attempt.
        let _ = self.enqueue(peerId: intent.peerId, maxId: intent.maxId)
        return .applied
    }

    mutating func retryFailure(id: String) -> AyuReadHistoryControlResult {
        guard !self.closed else { return .loggedOut }
        guard let failure = self.failures.first(where: { $0.id == id }) else { return .stale }
        guard failure.maxId > 0, failure.maxId < Int32.max - 1,
              failure.code == "LOCAL_QUEUE_FULL" || !failure.code.hasPrefix("LOCAL_") else { return .invalidInput }
        let previous = self
        self.acknowledgeFailures(ids: [id])
        switch self.enqueue(peerId: failure.peerIdValue, maxId: failure.maxId) {
        case .queued, .coalesced:
            return .applied
        case .queueFull:
            self = previous
            return .queueFull
        case .invalidInput:
            self = previous
            return .invalidInput
        case .loggedOut:
            self = previous
            return .loggedOut
        }
    }

    private mutating func recordReceipt(peerId: Int64, maxId: Int32, status: AyuReadHistoryReceipt.Status, now: Double) {
        self.receipts.append(.init(id: UUID().uuidString, peerIdValue: peerId, maxId: maxId, status: status, timestamp: now))
        self.receipts = Array(self.receipts.suffix(Self.receiptCapacity))
    }

    mutating func advanceRevision() {
        self.revision += 1
    }

    mutating func close() {
        self.closed = true
        self.intents.removeAll()
        self.failures.removeAll()
        self.receipts.removeAll()
    }

    static func backoff(attempts: Int) -> Double {
        return min(300, pow(2, Double(max(0, min(16, attempts) - 1))))
    }

    /// No generic 4xx/auth verdict: auth/logout is owned by Network/Account.
    /// Unknown errors, timeouts, 5xx and offline failures always retry.
    static func classifyError(code: Int32, text: String) -> AyuExplicitReadAttemptResult {
        if code == 400 || code == 403 {
            switch text {
            case "PEER_ID_INVALID", "CHAT_ID_INVALID", "CHANNEL_INVALID", "CHANNEL_PRIVATE", "MSG_ID_INVALID", "INPUT_USER_DEACTIVATED":
                return .rejected(text)
            default: break
            }
        }
        for prefix in ["FLOOD_WAIT_", "FLOOD_PREMIUM_WAIT_"] where text.hasPrefix(prefix) {
            if let seconds = Int32(text.dropFirst(prefix.count)), seconds > 0 {
                return .retry(after: Double(seconds))
            }
        }
        return .retry(after: nil)
    }
}
