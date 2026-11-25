// Native adaptation of exteraGram's adblock subscription lifecycle.
// Reference: exteraSquad/exteraGram, GPL-3.0-or-later; see docs/third-party/exteragram-notice.md.
import Foundation

public struct ExteraBrowserSubscription: Codable, Equatable {
    public var id: String
    public var name: String
    public var url: String
    public var enabled: Bool
    /// Every edit replaces this token; late network/parse results cannot overwrite an edit.
    public var revision: String

    public init(id: String = UUID().uuidString, name: String, url: String, enabled: Bool = true, revision: String = UUID().uuidString) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
        self.revision = revision
    }

    public static func requestURL(_ input: String) -> URL? {
        guard input.utf8.count <= 2048, let value = URLComponents(string: input),
              value.scheme?.lowercased() == "https", let host = value.host, !host.isEmpty,
              value.user == nil, value.password == nil, value.fragment == nil,
              value.port == nil || value.port == 443 else { return nil }
        return value.url
    }
}

public enum ExteraBrowserFilterError: Error, LocalizedError {
    case invalid(String)
    case network
    case status(Int)
    case tooLarge
    case cancelled
    case storage

    public var errorDescription: String? {
        switch self {
        case let .invalid(text): return text
        case .network: return "The filter list could not be downloaded. Check the URL and connection. Existing cached rules are kept."
        case let .status(code): return "The filter server returned HTTP \(code). Existing cached rules are kept."
        case .tooLarge: return "The filter list exceeds the 6 MB download or 150,000-line limit. Existing cached rules are kept."
        case .cancelled: return "Filter update cancelled. Existing cached rules are kept."
        case .storage: return "The filter cache could not be saved. Existing cached rules are kept."
        }
    }
}

/// Configuration only. Downloads and converted rules live in Caches, outside settings backups.
public final class ExteraBrowserFilters: @unchecked Sendable {
    public static let shared = ExteraBrowserFilters()
    public static let didChangeNotification = Notification.Name("ExteraBrowserFiltersDidChange")
    public static let maximumSubscriptions = 4
    public static let maximumRulesPerList = 10000
    public static let maximumCustomRules = 1000
    private let store = AyuSettingsStore.shared
    private let lock = NSRecursiveLock()
    private let subscriptionsKey = "extera.browser.subscriptions.v1"
    private let customRulesKey = "extera.browser.customFilters.v1"
    private let automaticKey = "extera.browser.automaticFilterUpdates"

    private init() { self.store.register(defaults: [self.automaticKey: true]) }

    public var subscriptions: [ExteraBrowserSubscription] {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let data = self.store.string(self.subscriptionsKey).data(using: .utf8), let result = try? JSONDecoder().decode([ExteraBrowserSubscription].self, from: data) else { return [] }
        var identifiers = Set<String>()
        var urls = Set<String>()
        return Array(result.filter { item in
            UUID(uuidString: item.id) != nil && UUID(uuidString: item.revision) != nil && item.name.count <= 100 && ExteraBrowserSubscription.requestURL(item.url) != nil && identifiers.insert(item.id).inserted && urls.insert(item.url).inserted
        }.prefix(Self.maximumSubscriptions))
    }

    public var customRules: String { return self.store.string(self.customRulesKey) }

    public var automaticUpdates: Bool {
        get { return self.store.bool(self.automaticKey) }
        set {
            self.store.setBool(newValue, self.automaticKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Replace preferences for import/restore. Cache identities are retained only for unchanged URLs.
    public func setSubscriptions(_ values: [ExteraBrowserSubscription]) throws {
        guard values.count <= Self.maximumSubscriptions,
              Set(values.map { $0.id }).count == values.count,
              Set(values.map { $0.url }).count == values.count,
              values.allSatisfy({ UUID(uuidString: $0.id) != nil && UUID(uuidString: $0.revision) != nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 100 && ExteraBrowserSubscription.requestURL($0.url) != nil }) else {
            throw ExteraBrowserFilterError.invalid("Add up to four unique HTTPS filter subscriptions with valid names and identifiers.")
        }
        var failure: Error?
        self.store.performBatchUpdates {
            self.lock.lock()
            defer { self.lock.unlock() }
            do {
                let old = self.subscriptions
                let updated = values.map { item -> ExteraBrowserSubscription in
                    var item = item
                    if let previous = old.first(where: { $0.id == item.id }), previous != item { item.revision = UUID().uuidString }
                    return item
                }
                self.store.setString(String(decoding: try JSONEncoder().encode(updated), as: UTF8.self), self.subscriptionsKey)
            } catch { failure = error }
        }
        if let failure { throw failure }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Hold the preferences lock across the final short cache publish. A background import or
    /// editor cannot replace a subscription between its revision check and file publication.
    func publishIfCurrent(_ subscription: ExteraBrowserSubscription, _ body: () throws -> Void) throws -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.subscriptions.contains(subscription), subscription.enabled else { return false }
        try body()
        return true
    }

    public func setCustomRules(_ text: String) throws {
        guard text.utf8.count <= 128 * 1024 else { throw ExteraBrowserFilterError.invalid("Custom filters must be no larger than 128 KB.") }
        let result = try ExteraBrowserABPConverter.convert(text, limit: Self.maximumCustomRules)
        guard result.omittedRules == 0 else { throw ExteraBrowserFilterError.invalid("Custom filters exceed the 1,000 converted-rule limit.") }
        self.store.setString(text, self.customRulesKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

/// WebKit's JSON format is intentionally narrower than ABP. No arbitrary regular expressions,
/// JavaScript, cosmetic selectors or unknown options are passed through to the WebKit compiler.
public struct ExteraBrowserContentRule: Codable, Equatable {
    public struct Trigger: Codable, Equatable {
        public var urlFilter: String
        public var caseSensitive: Bool = false
        public var resourceTypes: [String]
        public var loadTypes: [String]?
        public var ifDomains: [String]?
        public var unlessDomains: [String]?

        private enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case caseSensitive = "url-filter-is-case-sensitive"
            case resourceTypes = "resource-type"
            case loadTypes = "load-type"
            case ifDomains = "if-domain"
            case unlessDomains = "unless-domain"
        }
    }
    public struct Action: Codable, Equatable { public var type: String }
    public var trigger: Trigger
    public var action: Action
}

public struct ExteraBrowserConversion: Codable {
    public var rules: [ExteraBrowserContentRule]
    public var title: String?
    public var expires: TimeInterval
    public var unsupportedRules: Int
    public var omittedRules: Int
    public var cosmeticRules: Int
}

public enum ExteraBrowserABPConverter {
    public static let version = 1
    private static let resourceTypes = ["script", "image", "style-sheet", "font", "media", "raw", "svg-document"]
    private static let optionTypes = ["script": "script", "image": "image", "stylesheet": "style-sheet", "font": "font", "media": "media", "xmlhttprequest": "raw", "other": "raw"]

    /// Preserve all supported allow rules before using the remaining budget for block rules.
    /// Network rules only; documents/subdocuments are deliberately excluded.
    public static func convert(_ text: String, limit: Int = ExteraBrowserFilters.maximumRulesPerList) throws -> ExteraBrowserConversion {
        guard text.utf8.count <= 6 * 1024 * 1024 else { throw ExteraBrowserFilterError.tooLarge }
        var blocks: [ExteraBrowserContentRule] = []
        var allows: [ExteraBrowserContentRule] = []
        var unsupported = 0
        var cosmetic = 0
        var supported = 0
        var title: String?
        var expires: TimeInterval = 5 * 24 * 3600
        var lineCount = 0
        var conditionalDepth = 0
        var seen = Set<String>()
        let lines = text.split(maxSplits: 150000, whereSeparator: { $0.isNewline })
        guard lines.count <= 150000 else { throw ExteraBrowserFilterError.tooLarge }
        // badfilter disables the matching ordinary rule wherever it occurs in this list.
        // Dropping only the badfilter line would incorrectly reactivate that rule.
        var disabled = Set<String>()
        var disabledDepth = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("!#if") { disabledDepth += 1; continue }
            if line.hasPrefix("!#endif") { disabledDepth = max(0, disabledDepth - 1); continue }
            if disabledDepth > 0 || line.hasPrefix("!") { continue }
            guard line.utf8.count <= 1024, let dollar = line.lastIndex(of: "$") else { continue }
            let options = line[line.index(after: dollar)...].split(separator: ",").map(String.init)
            if options.contains("badfilter") {
                let remaining = options.filter { $0 != "badfilter" }
                disabled.insert(String(line[..<dollar]) + (remaining.isEmpty ? "" : "$" + remaining.joined(separator: ",")))
            }
        }
        for raw in lines {
            lineCount += 1
            guard lineCount <= 150000 else { throw ExteraBrowserFilterError.tooLarge }
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("!#if") { conditionalDepth += 1; unsupported += 1; continue }
            if line.hasPrefix("!#endif") { conditionalDepth = max(0, conditionalDepth - 1); continue }
            if conditionalDepth > 0 { if !line.hasPrefix("!") { unsupported += 1 }; continue }
            if line.hasPrefix("!#") { unsupported += 1; continue }
            if line.hasPrefix("!") {
                let lower = line.lowercased()
                if lower.hasPrefix("! title:") { title = String(line.dropFirst(8).trimmingCharacters(in: .whitespaces).prefix(100)) }
                if lower.hasPrefix("! expires:") {
                    let value = lower.dropFirst(10).trimmingCharacters(in: .whitespaces)
                    if let first = value.split(separator: " ").first, let number = Double(first), number.isFinite {
                        expires = min(14 * 24 * 3600, max(6 * 3600, number * (value.contains("hour") ? 3600 : 24 * 3600)))
                    }
                }
                continue
            }
            if line.hasPrefix("[") { continue }
            if ["##", "#@#", "#?#", "#$#", "#%#"].contains(where: { line.contains($0) }) { cosmetic += 1; continue }
            if disabled.contains(line) { continue }
            guard line.utf8.count <= 1024, seen.insert(line).inserted else { unsupported += 1; continue }
            guard let rules = self.convertLine(line) else { unsupported += 1; continue }
            supported += rules.count
            if rules.first?.action.type == "ignore-previous-rules" {
                guard allows.count + rules.count <= limit else { throw ExteraBrowserFilterError.invalid("This list has too many allow rules for WebKit. Choose a smaller list.") }
                allows.append(contentsOf: rules)
            } else if blocks.count < limit {
                blocks.append(contentsOf: rules.prefix(limit - blocks.count))
            }
        }
        blocks = Array(blocks.prefix(max(0, limit - allows.count)))
        return ExteraBrowserConversion(rules: blocks + allows, title: title, expires: expires, unsupportedRules: unsupported, omittedRules: supported - blocks.count - allows.count, cosmeticRules: cosmetic)
    }

    private static func convertLine(_ line: String) -> [ExteraBrowserContentRule]? {
        let exception = line.hasPrefix("@@")
        let value = exception ? String(line.dropFirst(2)) : line
        let parts = value.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        let pattern = String(first)
        guard !(pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 1), !pattern.contains("|*") else { return nil }
        var positive = Set<String>()
        var negative = Set<String>()
        var loadType: String?
        var caseSensitive = false
        var domains: [String] = []
        var excludedDomains: [String] = []
        if parts.count == 2 {
            for raw in parts[1].split(separator: ",", omittingEmptySubsequences: false) {
                let option = String(raw).lowercased()
                let negated = option.hasPrefix("~")
                let name = negated ? String(option.dropFirst()) : option
                if let type = self.optionTypes[name] {
                    if negated { negative.insert(type) } else { positive.insert(type) }
                } else if name == "third-party" || name == "3p" {
                    guard loadType == nil else { return nil }
                    loadType = negated ? "first-party" : "third-party"
                } else if option == "match-case" {
                    caseSensitive = true
                } else if option.hasPrefix("domain=") {
                    guard domains.isEmpty && excludedDomains.isEmpty else { return nil }
                    let entries = option.dropFirst(7).split(separator: "|", omittingEmptySubsequences: false)
                    guard !entries.isEmpty, entries.count <= 32 else { return nil }
                    for entry in entries {
                        let excluded = entry.hasPrefix("~")
                        let host = excluded ? String(entry.dropFirst()) : String(entry)
                        guard ExteraBrowserSettings.normalizedHost(host) == host else { return nil }
                        if excluded { excludedDomains.append("*" + host) } else { domains.append("*" + host) }
                    }
                    // WebKit permits one top-URL/domain condition, never both inclusion and exclusion.
                    guard domains.isEmpty || excludedDomains.isEmpty else { return nil }
                } else {
                    // Includes document/subdocument, important, badfilter, redirect, removeparam,
                    // CSP, headers, generichide and all scriptlet/engine-specific options.
                    return nil
                }
            }
        }
        let types = (positive.isEmpty ? Set(self.resourceTypes) : positive).subtracting(negative).sorted()
        guard !types.isEmpty, let expressions = self.expressions(pattern) else { return nil }
        return expressions.map { expression in
            let trigger = ExteraBrowserContentRule.Trigger(urlFilter: expression, caseSensitive: caseSensitive, resourceTypes: types, loadTypes: loadType.map { [$0] }, ifDomains: domains.isEmpty ? nil : domains, unlessDomains: excludedDomains.isEmpty ? nil : excludedDomains)
            return ExteraBrowserContentRule(trigger: trigger, action: .init(type: exception ? "ignore-previous-rules" : "block"))
        }
    }

    private static func expressions(_ source: String) -> [String]? {
        guard source.utf8.allSatisfy({ $0 >= 33 && $0 < 127 }), source.filter({ $0 == "*" }).count <= 3 else { return nil }
        var text = source
        var prefix = ""
        if text.hasPrefix("||") {
            text.removeFirst(2)
            let host = String(text.prefix(while: { $0 != "^" && $0 != "/" && $0 != ":" && $0 != "*" && $0 != "|" }))
            guard ExteraBrowserSettings.normalizedHost(host) == host.lowercased(), host.contains(".") else { return nil }
            prefix = "^https?://([a-z0-9-]+\\.)*"
            text.removeFirst(host.count)
            prefix += self.literal(host.lowercased())
            if text.isEmpty || text == "^" { return [prefix + "\\.?(:[0-9]+)?/"] }
            guard text.hasPrefix("/") || text.hasPrefix(":") else { return nil }
        } else if text.hasPrefix("|") {
            prefix = "^"
            text.removeFirst()
            guard text.hasPrefix("https://") || text.hasPrefix("http://") else { return nil }
        }
        var suffix = ""
        if text.hasSuffix("|") { text.removeLast(); suffix = "$" }
        guard !text.isEmpty, !text.contains("|"), text.filter({ $0.isLetter || $0.isNumber }).count >= 3 else { return nil }
        let terminalSeparator = text.hasSuffix("^")
        if terminalSeparator { text.removeLast() }
        var expression = prefix
        for character in text {
            if character == "*" { expression += ".*" }
            else if character == "^" { expression += "[^a-zA-Z0-9_.%-]" }
            else { expression += self.literal(String(character)) }
        }
        if terminalSeparator {
            guard suffix.isEmpty else { return nil }
            return [expression + "[^a-zA-Z0-9_.%-]", expression + "$"]
        }
        return [expression + suffix]
    }

    private static func literal(_ text: String) -> String {
        var result = ""
        for character in text {
            if ".+?()[]{}^$|\\*".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
