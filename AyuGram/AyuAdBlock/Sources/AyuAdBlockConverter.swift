// The web ad blocker of exteraGram for Android (com.exteragram.messenger.adblock) runs uBlock's filter lists in
// a native engine. WebKit has its own engine for content rule lists, so on iOS the same filter lists are turned
// into such rules. What a rule list cannot express (scriptlets, redirects, procedural filters) is left out.

import Foundation

public struct AyuAdBlockRule: Equatable {
    public enum Action: Equatable {
        case block
        case ignorePreviousRules
        case hide(selector: String)
    }

    public var urlFilter: String
    public var isCaseSensitive: Bool = false
    public var ifDomain: [String] = []
    public var unlessDomain: [String] = []
    public var resourceTypes: [String] = []
    public var loadTypes: [String] = []
    public var action: Action

    public var json: [String: Any] {
        var trigger: [String: Any] = ["url-filter": self.urlFilter]
        if self.isCaseSensitive {
            trigger["url-filter-is-case-sensitive"] = true
        }
        if !self.ifDomain.isEmpty {
            trigger["if-domain"] = self.ifDomain
        } else if !self.unlessDomain.isEmpty {
            trigger["unless-domain"] = self.unlessDomain
        }
        if !self.resourceTypes.isEmpty {
            trigger["resource-type"] = self.resourceTypes
        }
        if !self.loadTypes.isEmpty {
            trigger["load-type"] = self.loadTypes
        }
        let action: [String: Any]
        switch self.action {
        case .block:
            action = ["type": "block"]
        case .ignorePreviousRules:
            action = ["type": "ignore-previous-rules"]
        case let .hide(selector):
            action = ["type": "css-display-none", "selector": selector]
        }
        return ["trigger": trigger, "action": action]
    }
}

public enum AyuAdBlockConverter {
    // Rules of filter lists, in the order a rule list wants them: what hides, what blocks, then the exceptions,
    // which undo everything before them for the requests they match.
    public struct Rules: Equatable {
        public var hiding: [AyuAdBlockRule] = []
        public var blocking: [AyuAdBlockRule] = []
        public var exceptions: [AyuAdBlockRule] = []
        // Filters a rule list has no way to express, and comments are not counted.
        public var skipped: Int = 0

        public init() {
        }

        public var count: Int {
            return self.hiding.count + self.blocking.count + self.exceptions.count
        }
    }

    // Subresources: everything a page loads but frames and other pages.
    static let subresourceTypes = ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping", "fetch", "websocket", "other"]

    private static let typeOptions: [String: [String]] = [
        "script": ["script"],
        "image": ["image"],
        "stylesheet": ["style-sheet"],
        "css": ["style-sheet"],
        "font": ["font"],
        "media": ["media"],
        "xmlhttprequest": ["raw", "fetch"],
        "xhr": ["raw", "fetch"],
        "websocket": ["websocket"],
        "ping": ["ping"],
        "beacon": ["ping"],
        "other": ["other"],
        "object": ["other"],
        "subdocument": ["document"],
        "frame": ["document"]
    ]

    private static let ignoredOptions: Set<String> = ["important", "all", "~object", "~popup", "~document", "~doc", "~ping", "~other"]

    public static func convert(lists: [String]) -> Rules {
        var result = Rules()
        // Selectors that hide everywhere, and the sites that made an exception for one.
        var genericSelectors: [String] = []
        var seenSelectors = Set<String>()
        var selectorExceptions: [String: Set<String>] = [:]
        var seenRules = Set<String>()

        for list in lists {
            list.enumerateLines { line, _ in
                let line = line.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") || line.hasPrefix("# ") || line == "#" {
                    return
                }
                if let cosmetic = AyuAdBlockConverter.cosmetic(line) {
                    switch cosmetic {
                    case .unsupported:
                        result.skipped += 1
                    case let .exception(domains, selector):
                        selectorExceptions[selector, default: Set()].formUnion(domains)
                    case let .generic(selector):
                        if seenSelectors.insert(selector).inserted {
                            genericSelectors.append(selector)
                        }
                    case let .rule(rule):
                        if seenRules.insert(AyuAdBlockConverter.identity(rule)).inserted {
                            result.hiding.append(rule)
                        }
                    }
                    return
                }
                guard let rule = AyuAdBlockConverter.network(line) else {
                    result.skipped += 1
                    return
                }
                guard seenRules.insert(AyuAdBlockConverter.identity(rule)).inserted else {
                    return
                }
                if rule.action == .ignorePreviousRules {
                    result.exceptions.append(rule)
                } else {
                    result.blocking.append(rule)
                }
            }
        }

        // Selectors nobody excepted share rules; an excepted one gets its own with the sites left out.
        var plain: [String] = []
        var generic: [AyuAdBlockRule] = []
        for selector in genericSelectors {
            if let domains = selectorExceptions[selector], !domains.isEmpty {
                generic.append(AyuAdBlockRule(urlFilter: ".*", unlessDomain: domains.sorted().map { "*" + $0 }, action: .hide(selector: selector)))
            } else {
                plain.append(selector)
            }
        }
        var index = 0
        while index < plain.count {
            let group = plain[index ..< min(index + AyuAdBlockConverter.selectorsPerRule, plain.count)]
            generic.append(AyuAdBlockRule(urlFilter: ".*", action: .hide(selector: group.joined(separator: ", "))))
            index += AyuAdBlockConverter.selectorsPerRule
        }
        result.hiding = generic + result.hiding
        return result
    }

    static let selectorsPerRule = 100

    private static func identity(_ rule: AyuAdBlockRule) -> String {
        return "\(rule.urlFilter)\u{1}\(rule.isCaseSensitive)\u{1}\(rule.ifDomain)\u{1}\(rule.unlessDomain)\u{1}\(rule.resourceTypes)\u{1}\(rule.loadTypes)\u{1}\(rule.action)"
    }

    // MARK: Element hiding

    enum Cosmetic: Equatable {
        case unsupported
        case generic(selector: String)
        case exception(domains: [String], selector: String)
        case rule(AyuAdBlockRule)
    }

    private static let domainListCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,~*-_")

    // A line with an element hiding marker ("##", "#@#", "#?#", ...) after nothing or a list of domains; nil
    // for any other line.
    static func cosmetic(_ line: String) -> Cosmetic? {
        guard let hash = line.firstIndex(of: "#") else {
            return nil
        }
        let domainsPart = line[line.startIndex ..< hash]
        guard domainsPart.unicodeScalars.allSatisfy({ domainListCharacters.contains($0) }) else {
            return nil
        }
        let rest = line[hash...]
        let marker: String
        if rest.hasPrefix("##") {
            marker = "##"
        } else if rest.hasPrefix("#@#") {
            marker = "#@#"
        } else if rest.hasPrefix("#?#") || rest.hasPrefix("#$#") || rest.hasPrefix("#%#") || rest.hasPrefix("#@?#") || rest.hasPrefix("#@$#") || rest.hasPrefix("#@%#") || rest.hasPrefix("#$?#") || rest.hasPrefix("#@$?#") {
            return .unsupported
        } else {
            return nil
        }
        let selector = rest.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        guard isSupportedSelector(selector) else {
            return .unsupported
        }

        var included: [String] = []
        var excluded: [String] = []
        for entry in domainsPart.split(separator: ",") {
            let isExcluded = entry.hasPrefix("~")
            let domain = (isExcluded ? entry.dropFirst() : entry).lowercased()
            // "example.*" stands for every top level domain: no such thing in a rule list.
            guard isDomain(domain) else {
                return .unsupported
            }
            if isExcluded {
                excluded.append(domain)
            } else {
                included.append(domain)
            }
        }

        if marker == "#@#" {
            // Without domains it switches a selector off everywhere: the lists that do that are not ours.
            return included.isEmpty || !excluded.isEmpty ? .unsupported : .exception(domains: included, selector: selector)
        }
        if included.isEmpty && excluded.isEmpty {
            return .generic(selector: selector)
        }
        // A rule is limited to sites or keeps off sites, never both.
        if !included.isEmpty && !excluded.isEmpty {
            return .unsupported
        }
        var rule = AyuAdBlockRule(urlFilter: ".*", action: .hide(selector: selector))
        rule.ifDomain = included.map { "*" + $0 }
        rule.unlessDomain = excluded.map { "*" + $0 }
        return .rule(rule)
    }

    private static let unsupportedSelectorParts = [
        "+js(", ":has-text(", ":contains(", ":xpath(", ":style(", ":remove(", ":remove-attr(", ":remove-class(", ":matches-css", ":matches-path(", ":matches-attr(", ":matches-media(", ":matches-prop(",
        ":upward(", ":nth-ancestor(", ":min-text-length(", ":watch-attr(", ":others(", ":-abp-", ":if(", ":if-not(", ":spath(", ":shadow(", ":has(", ":is(", ":where(", "{", "}", "@", "\\", "//"
    ]

    // What WebKit's rule compiler is sure to take; one selector it refuses fails its whole list.
    static func isSupportedSelector(_ selector: String) -> Bool {
        if selector.isEmpty || selector.hasPrefix("^") || selector.hasPrefix("+") || selector.utf16.count > 500 {
            return false
        }
        guard selector.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) else {
            return false
        }
        for part in unsupportedSelectorParts {
            if selector.contains(part) {
                return false
            }
        }
        // Brackets and quotes must pair up.
        var depth = 0
        var square = 0
        var quote: Character?
        for character in selector {
            if let open = quote {
                if character == open {
                    quote = nil
                }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
            case "(":
                depth += 1
            case ")":
                depth -= 1
            case "[":
                square += 1
            case "]":
                square -= 1
            default:
                break
            }
            if depth < 0 || square < 0 {
                return false
            }
        }
        return depth == 0 && square == 0 && quote == nil
    }

    static func isDomain(_ domain: String) -> Bool {
        if domain.isEmpty || domain.hasPrefix(".") || domain.hasSuffix(".") || domain.hasPrefix("-") {
            return false
        }
        return domain.unicodeScalars.allSatisfy { scalar in
            return (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) || scalar == "." || scalar == "-" || scalar == "_"
        }
    }

    // MARK: Requests

    // A blocking filter or an exception ("@@") as a rule; nil when a rule list cannot express it.
    static func network(_ line: String) -> AyuAdBlockRule? {
        var text = Substring(line)
        let isException = text.hasPrefix("@@")
        if isException {
            text = text.dropFirst(2)
        }

        var options: [Substring] = []
        if let dollar = text.lastIndex(of: "$"), text.index(after: dollar) < text.endIndex {
            let candidate = text[text.index(after: dollar)...]
            // A "$" inside the address is followed by more of the address, not by a list of options.
            if !candidate.contains("/") || candidate.contains("domain=") || candidate.contains("from=") {
                options = candidate.split(separator: ",")
                text = text[..<dollar]
            }
        }

        var rule = AyuAdBlockRule(urlFilter: "", action: isException ? .ignorePreviousRules : .block)
        var types: [String] = []
        var excludedTypes: [String] = []
        var isThirdParty: Bool?
        var isWholePage = false
        for option in options {
            let name = option.lowercased()
            if ignoredOptions.contains(name) {
                continue
            }
            switch name {
            case "third-party", "3p", "~first-party", "~1p":
                isThirdParty = true
            case "~third-party", "~3p", "first-party", "1p":
                isThirdParty = false
            case "match-case":
                rule.isCaseSensitive = true
            case "document", "doc":
                isWholePage = true
            case "popup", "generichide", "ghide", "elemhide", "ehide", "specifichide", "shide", "genericblock":
                return nil
            default:
                if name.hasPrefix("domain=") || name.hasPrefix("from=") {
                    for entry in option[option.index(after: option.firstIndex(of: "=")!)...].split(separator: "|") {
                        let isExcluded = entry.hasPrefix("~")
                        let domain = (isExcluded ? entry.dropFirst() : entry).lowercased()
                        guard isDomain(domain) else {
                            return nil
                        }
                        if isExcluded {
                            rule.unlessDomain.append("*" + domain)
                        } else {
                            rule.ifDomain.append("*" + domain)
                        }
                    }
                } else if let mapped = typeOptions[name] {
                    types.append(contentsOf: mapped)
                } else if name.hasPrefix("~"), let mapped = typeOptions[String(name.dropFirst())] {
                    excludedTypes.append(contentsOf: mapped)
                } else {
                    // Redirects, removed parameters, headers and the rest: another engine's work.
                    return nil
                }
            }
        }
        if !rule.ifDomain.isEmpty && !rule.unlessDomain.isEmpty {
            return nil
        }

        let pattern = String(text)
        if isWholePage {
            // "@@||site^$document" switches blocking off on a site; as a block it would stop the visit itself.
            guard isException, types.isEmpty, pattern.hasPrefix("||"), rule.ifDomain.isEmpty, rule.unlessDomain.isEmpty else {
                return nil
            }
            var host = pattern.dropFirst(2)
            if host.hasSuffix("^") {
                host = host.dropLast()
            }
            guard isDomain(host.lowercased()) else {
                return nil
            }
            rule.urlFilter = ".*"
            rule.ifDomain = ["*" + host.lowercased()]
            return rule
        }

        guard let urlFilter = urlFilter(pattern, isCaseSensitive: rule.isCaseSensitive, isLimited: !rule.ifDomain.isEmpty) else {
            return nil
        }
        rule.urlFilter = urlFilter

        if let isThirdParty {
            rule.loadTypes = [isThirdParty ? "third-party" : "first-party"]
        }
        if !types.isEmpty {
            // A frame is a document, and so is the page: only another site's frame can be told from it.
            if types.contains("document") && isThirdParty != true {
                if types.allSatisfy({ $0 == "document" }) {
                    if isThirdParty == false {
                        return nil
                    }
                    rule.loadTypes = ["third-party"]
                } else {
                    types.removeAll { $0 == "document" }
                }
            }
            rule.resourceTypes = unique(types)
        } else if !excludedTypes.isEmpty {
            rule.resourceTypes = subresourceTypes.filter { !excludedTypes.contains($0) }
        } else if isThirdParty == true {
            // Another site's frames included; the page itself is never third party.
            rule.resourceTypes = []
        } else {
            rule.resourceTypes = subresourceTypes
        }
        return rule
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static let escapedCharacters: Set<Character> = [".", "+", "?", "$", "{", "}", "(", ")", "[", "]", "|", "\\", "/"]
    private static let separator = "[^a-zA-Z0-9_.%-]"

    // The filter's address pattern as the regular expression of a rule: "||" a host or its subdomain, "|" an
    // end of the address, "^" a separator, "*" anything.
    static func urlFilter(_ pattern: String, isCaseSensitive: Bool, isLimited: Bool) -> String? {
        var pattern = Substring(pattern)
        guard pattern.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 }) else {
            return nil
        }
        // A regular expression of the list's own: WebKit's are a small subset.
        if pattern.count > 1 && pattern.hasPrefix("/") && pattern.hasSuffix("/") {
            return nil
        }

        var result = ""
        if pattern.hasPrefix("||") {
            result = "^[^:]+:(//)?([^/]+\\.)?"
            pattern = pattern.dropFirst(2)
        } else if pattern.hasPrefix("|") {
            result = "^"
            pattern = pattern.dropFirst()
        }
        var isAnchoredAtEnd = false
        if pattern.hasSuffix("|") {
            isAnchoredAtEnd = true
            pattern = pattern.dropLast()
        }
        while pattern.hasPrefix("*") {
            pattern = pattern.dropFirst()
        }
        while pattern.hasSuffix("*") {
            pattern = pattern.dropLast()
        }
        let endsWithSeparator = !isAnchoredAtEnd && pattern.hasSuffix("^")
        if endsWithSeparator {
            pattern = pattern.dropLast()
        }

        var literalLength = 0
        var previousWasWildcard = false
        for character in pattern {
            if character == "*" {
                if !previousWasWildcard {
                    result += ".*"
                }
                previousWasWildcard = true
                continue
            }
            previousWasWildcard = false
            if character == "^" {
                result += separator
            } else {
                if escapedCharacters.contains(character) {
                    result += "\\"
                }
                result += isCaseSensitive ? String(character) : character.lowercased()
                literalLength += 1
            }
        }
        // A pattern of a character or two matches half the web; with a site to apply on it may be anything.
        if literalLength < 3 {
            guard isLimited else {
                return nil
            }
            if result.isEmpty {
                return ".*"
            }
        }
        if endsWithSeparator {
            // The separator, or the end of the address.
            result += "(" + separator + ".*)?$"
        } else if isAnchoredAtEnd {
            result += "$"
        }
        return result
    }

    // MARK: Rule lists

    // The rules as the JSON of rule lists of at most `limit` rules each. Exceptions only undo rules of their own
    // list, so every list ends with all of them.
    public static func ruleLists(_ rules: Rules, limit: Int = 30000) -> [[AyuAdBlockRule]] {
        let exceptions = rules.exceptions
        let body = rules.hiding + rules.blocking
        let size = max(1, limit - exceptions.count)
        var lists: [[AyuAdBlockRule]] = []
        var index = 0
        while index < body.count {
            lists.append(Array(body[index ..< min(index + size, body.count)]) + exceptions)
            index += size
        }
        return lists
    }

    public static func json(_ rules: [AyuAdBlockRule]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rules.map { $0.json }), let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}
