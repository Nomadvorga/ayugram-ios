// Ported from exteraGram for Android (com.exteragram.messenger.api: ApiController, ProfileDTO, BadgeDTO and
// badges.source.ApiBadgeSource), GPL v3 or later, © exteraGram.

import Foundation

// A profile the exteraGram service knows: a supporter or a developer, a user or a chat, with its badge.
public struct AyuExteraProfile: Equatable {
    public enum Status: String {
        case regular = "DEFAULT"
        case developer = "DEVELOPER"
        case supporter = "SUPPORTER"
    }

    public let id: Int64
    public let isUser: Bool
    public let status: Status
    // Custom emoji shown next to the name.
    public let badgeDocumentId: Int64?
    // The owner's own text for the badge; "{name}" stands for the peer's name.
    public let badgeText: String?
    public let number: Int?
    public let canChangeBadge: Bool

    public init(id: Int64, isUser: Bool, status: Status, badgeDocumentId: Int64?, badgeText: String?, number: Int?, canChangeBadge: Bool) {
        self.id = id
        self.isUser = isUser
        self.status = status
        self.badgeDocumentId = badgeDocumentId
        self.badgeText = badgeText
        self.number = number
        self.canChangeBadge = canChangeBadge
    }

    // The supporter's number as exteraGram writes it; none for other profiles.
    public var formattedNumber: String? {
        guard let number = self.number, number >= 0, self.status != .regular else {
            return nil
        }
        return "#\(number)"
    }

    init?(json: [String: Any]) {
        guard let id = (json["id"] as? NSNumber)?.int64Value, let type = json["type"] as? String, type == "USER" || type == "CHAT" else {
            return nil
        }
        let badge = json["badge"] as? [String: Any]
        self.init(
            id: id,
            isUser: type == "USER",
            status: (json["status"] as? String).flatMap(Status.init(rawValue:)) ?? .regular,
            badgeDocumentId: (badge?["documentId"] as? NSNumber)?.int64Value,
            badgeText: (badge?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            number: (json["number"] as? NSNumber)?.intValue,
            canChangeBadge: (json["canChangeBadge"] as? Bool) ?? false
        )
    }

    var json: [String: Any] {
        var result: [String: Any] = ["id": self.id, "type": self.isUser ? "USER" : "CHAT", "status": self.status.rawValue]
        if let badgeDocumentId = self.badgeDocumentId {
            var badge: [String: Any] = ["documentId": badgeDocumentId]
            if let badgeText = self.badgeText {
                badge["text"] = badgeText
            }
            result["badge"] = badge
        }
        if let number = self.number {
            result["number"] = number
        }
        if self.canChangeBadge {
            result["canChangeBadge"] = true
        }
        return result
    }
}

// Every known profile, kept in the service's own JSON so a saved table reads like an answer.
public struct AyuExteraProfilesTable: Equatable {
    public private(set) var users: [Int64: AyuExteraProfile] = [:]
    public private(set) var chats: [Int64: AyuExteraProfile] = [:]

    public init() {
    }

    public var count: Int {
        return self.users.count + self.chats.count
    }

    public func profile(id: Int64, isUser: Bool) -> AyuExteraProfile? {
        return isUser ? self.users[id] : self.chats[id]
    }

    // An answer of `profiles` or `profiles/updates`: profiles to store, and to drop when marked deleted.
    // False when the data is not such an answer; the table is then left as it was.
    @discardableResult
    public mutating func apply(response: Data) -> Bool {
        guard let items = (try? JSONSerialization.jsonObject(with: response)) as? [Any] else {
            return false
        }
        for item in items {
            guard let json = item as? [String: Any], let profile = AyuExteraProfile(json: json) else {
                continue
            }
            let isDeleted = (json["deleted"] as? Bool) ?? false
            if profile.isUser {
                self.users[profile.id] = isDeleted ? nil : profile
            } else {
                self.chats[profile.id] = isDeleted ? nil : profile
            }
        }
        return true
    }

    public func data() -> Data {
        let profiles = (self.users.values.sorted { $0.id < $1.id } + self.chats.values.sorted { $0.id < $1.id }).map { $0.json }
        return (try? JSONSerialization.data(withJSONObject: profiles)) ?? Data("[]".utf8)
    }
}

// What is remembered between synchronizations, and what the next one asks for.
public struct AyuExteraProfilesSyncState: Equatable {
    public static let baseURL = "https://api.exteragram.app/api/v1/"
    public static let syncInterval: Double = 10.0 * 60.0
    public static let failureBackoff: Double = 5.0 * 60.0

    // The service's time of the last answer; the next request asks for changes since then.
    public var watermark: String?
    public var etag: String?
    public var lastSyncTime: Double
    public var lastFailureTime: Double

    public init(watermark: String? = nil, etag: String? = nil, lastSyncTime: Double = 0.0, lastFailureTime: Double = 0.0) {
        self.watermark = watermark
        self.etag = etag
        self.lastSyncTime = lastSyncTime
        self.lastFailureTime = lastFailureTime
    }

    private static func elapsed(since timestamp: Double, now: Double) -> Double {
        return timestamp <= 0.0 || timestamp > now ? .infinity : now - timestamp
    }

    public func isDue(now: Double) -> Bool {
        if AyuExteraProfilesSyncState.elapsed(since: self.lastFailureTime, now: now) < AyuExteraProfilesSyncState.failureBackoff {
            return false
        }
        return self.watermark == nil || AyuExteraProfilesSyncState.elapsed(since: self.lastSyncTime, now: now) >= AyuExteraProfilesSyncState.syncInterval
    }

    // Everything when nothing was synchronized yet, else the changes.
    public func request() -> URLRequest {
        var components = URLComponents(string: AyuExteraProfilesSyncState.baseURL + (self.watermark == nil ? "profiles" : "profiles/updates"))!
        if let watermark = self.watermark {
            components.queryItems = [URLQueryItem(name: "since", value: watermark)]
        }
        var request = URLRequest(url: components.url!)
        if let etag = self.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    public enum Outcome: Equatable {
        // Nothing changed.
        case unchanged
        // The body holds profiles to apply.
        case profiles
        case failed
    }

    // Records an answer. `stored` tells whether the profiles of a successful answer could be kept.
    public mutating func record(statusCode: Int, etag: String?, syncTimestamp: String?, now: Double, stored: Bool = true) -> Outcome {
        let isUnchanged = statusCode == 304
        guard isUnchanged || ((200 ..< 300).contains(statusCode) && stored) else {
            self.lastFailureTime = now
            return .failed
        }
        if let syncTimestamp, !syncTimestamp.isEmpty, ISO8601DateFormatter.ayuExteraSync.date(from: syncTimestamp) != nil || ISO8601DateFormatter.ayuExteraSyncFractional.date(from: AyuExteraProfilesSyncState.millisecondPrecision(syncTimestamp)) != nil {
            self.watermark = syncTimestamp
        } else {
            self.watermark = ISO8601DateFormatter.ayuExteraSync.string(from: Date(timeIntervalSince1970: now))
        }
        if !isUnchanged {
            self.etag = etag
        }
        self.lastSyncTime = now
        self.lastFailureTime = 0.0
        return isUnchanged ? .unchanged : .profiles
    }

    // The service writes nanoseconds; the formatter reads milliseconds.
    static func millisecondPrecision(_ timestamp: String) -> String {
        guard let dot = timestamp.firstIndex(of: "."), let end = timestamp[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else {
            return timestamp
        }
        let fraction = timestamp[timestamp.index(after: dot) ..< end]
        return String(timestamp[..<dot]) + "." + String((fraction + "000").prefix(3)) + String(timestamp[end...])
    }
}

extension ISO8601DateFormatter {
    static let ayuExteraSync: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let ayuExteraSyncFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
