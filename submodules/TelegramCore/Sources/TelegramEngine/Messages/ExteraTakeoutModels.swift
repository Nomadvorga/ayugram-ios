import Foundation

/// Cloud history export choices. This exporter reads the server directly and does not
/// fill, mark read, or otherwise modify the account's local message history.
public struct ExteraTakeoutOptions {
    public struct ChatTypes: OptionSet {
        public let rawValue: Int32
        public init(rawValue: Int32) { self.rawValue = rawValue }
        public static let personal = ChatTypes(rawValue: 1 << 0)
        public static let bots = ChatTypes(rawValue: 1 << 1)
        public static let privateGroups = ChatTypes(rawValue: 1 << 2)
        public static let publicGroups = ChatTypes(rawValue: 1 << 3)
        public static let privateChannels = ChatTypes(rawValue: 1 << 4)
        public static let publicChannels = ChatTypes(rawValue: 1 << 5)
        public static let all: ChatTypes = [.personal, .bots, .privateGroups, .publicGroups, .privateChannels, .publicChannels]
    }

    public enum Format: Int, CaseIterable { case json, html, jsonAndHTML }
    public enum Media: Int, CaseIterable { case none, photos, photosAndFiles }

    public var chatTypes: ChatTypes = [.personal, .privateGroups]
    public var format: Format = .json
    public var media: Media = .none
    public var includeLeftChannels = false
    /// Unix seconds; inclusive start, exclusive end. nil exports all dates.
    public var fromTimestamp: Int32?
    public var untilTimestamp: Int32?
    public var maximumFileSize: Int64 = 8 * 1024 * 1024
    /// Fails explicitly at the limit instead of producing a silently truncated export.
    public var maximumExportBytes: Int64 = 2 * 1024 * 1024 * 1024

    public init() {}

    func validate() throws {
        guard !self.chatTypes.isEmpty, self.chatTypes.subtracting(.all).isEmpty,
              self.maximumFileSize > 0, self.maximumFileSize <= 512 * 1024 * 1024,
              self.maximumExportBytes >= 1024 * 1024, self.maximumExportBytes <= 2 * 1024 * 1024 * 1024,
              self.fromTimestamp.map({ $0 >= 0 }) ?? true,
              self.untilTimestamp.map({ $0 > 0 }) ?? true else { throw ExteraTakeoutError.invalidOptions }
        if let start = self.fromTimestamp, let end = self.untilTimestamp, start >= end { throw ExteraTakeoutError.invalidOptions }
    }

    func includes(date: Int32) -> Bool {
        return date >= (self.fromTimestamp ?? 0) && (self.untilTimestamp.map { date < $0 } ?? true)
    }

    var sessionFlags: Int32 {
        var flags: Int32 = 0
        if !self.chatTypes.intersection([.personal, .bots]).isEmpty { flags |= 1 << 1 }
        if self.chatTypes.contains(.privateGroups) { flags |= 1 << 2 }
        if !self.chatTypes.intersection([.privateGroups, .publicGroups]).isEmpty { flags |= 1 << 3 }
        if !self.chatTypes.intersection([.privateChannels, .publicChannels]).isEmpty { flags |= 1 << 4 }
        if self.media != .none { flags |= 1 << 5 }
        return flags
    }
}

public enum ExteraTakeoutError: Error, LocalizedError {
    case invalidOptions
    case serverWait(seconds: Int)
    case floodWait(seconds: Int)
    case rpc(code: Int32, description: String)
    case invalidResponse
    case cursorDidNotAdvance
    case outputLimit
    case io
    case finishFailed

    public var errorDescription: String? {
        switch self {
        case .invalidOptions: return "Choose at least one chat type and a valid date and size range."
        case let .serverWait(seconds): return "Telegram requires a takeout authorization delay. Try again in \(seconds) seconds and check Telegram's service message."
        case let .floodWait(seconds): return "Telegram asked to wait \(seconds) seconds. This export was stopped; try again later."
        case let .rpc(code, description): return "Telegram export request failed (\(code): \(description))."
        case .invalidResponse: return "Telegram returned an unsupported or incomplete export response. No completed archive was produced."
        case .cursorDidNotAdvance: return "Telegram's export cursor stopped advancing. No completed archive was produced."
        case .outputLimit: return "The export reached its storage or file-count limit. Select fewer chat types, a shorter date range, or smaller media."
        case .io: return "The export could not write its files. Check available device storage."
        case .finishFailed: return "Telegram did not confirm the takeout session was finished. No completed archive was produced."
        }
    }

    static func server(code: Int32, text: String) -> ExteraTakeoutError {
        for (prefix, takeout) in [("TAKEOUT_INIT_DELAY_", true), ("FLOOD_WAIT_", false), ("FLOOD_PREMIUM_WAIT_", false)] {
            if text.hasPrefix(prefix), let seconds = Int(text.dropFirst(prefix.count)), seconds >= 0 {
                return takeout ? .serverWait(seconds: seconds) : .floodWait(seconds: seconds)
            }
        }
        // Retain only a server constant, never arbitrary error payloads containing account data.
        let safe = text.utf8.count <= 100 && text.utf8.allSatisfy { (65 ... 90).contains($0) || (48 ... 57).contains($0) || $0 == 95 }
        return .rpc(code: code, description: safe ? text : "REQUEST_FAILED")
    }
}

public struct ExteraTakeoutProgress {
    public enum Phase { case authorizing, listingChats, exportingHistory, downloadingMedia, finishing, packaging }
    public let phase: Phase
    public let chatTitle: String
    public let completedChats: Int
    public let totalChats: Int
    public let messages: Int64
    public let mediaFiles: Int
    public let skippedMedia: Int
    public let bytesWritten: Int64
}

/// The result owns its temporary directory. Retain until sharing finishes, then call
/// remove(); deinitialization is a second cleanup path if presentation is cancelled.
public final class ExteraTakeoutResult {
    public let archiveURL: URL
    public let messages: Int64
    public let skippedMedia: Int
    private let directory: URL

    init(archiveURL: URL, directory: URL, messages: Int64, skippedMedia: Int) {
        self.archiveURL = archiveURL
        self.directory = directory
        self.messages = messages
        self.skippedMedia = skippedMedia
    }

    public func remove() { try? FileManager.default.removeItem(at: self.directory) }
    deinit { self.remove() }
}

public enum ExteraTakeoutEvent {
    case progress(ExteraTakeoutProgress)
    case completed(ExteraTakeoutResult)
}

struct ExteraTakeoutChatRecord: Encodable {
    let id: String
    let title: String
    let type: String
    let split: Int
    let left: Bool
}

struct ExteraTakeoutMediaRecord: Encodable {
    let type: String
    let name: String?
    let size: Int64?
    var path: String?
    var skippedReason: String?
}

struct ExteraTakeoutMessageRecord: Encodable {
    let id: Int32
    let date: Int32
    let sender: String?
    let outgoing: Bool
    let text: String
    let serviceAction: String?
    let replyToMessageId: Int32?
    let groupedId: String?
    var media: ExteraTakeoutMediaRecord?
}
