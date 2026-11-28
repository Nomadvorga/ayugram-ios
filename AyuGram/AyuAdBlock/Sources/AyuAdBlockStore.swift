import Foundation
import WebKit

// MARK: AyuGram
// The rule lists of the web ad blocker: downloaded filter lists, converted, compiled by WebKit and kept by it
// between launches. Rebuilt every four days. Main thread only, except where noted.
public final class AyuAdBlockStore {
    public static let shared = AyuAdBlockStore()
    public static let didChangeNotification = Notification.Name("AyuAdBlockStoreDidChange")

    // exteraGram's subscriptions, without the lists made of what only uBlock's own engine understands.
    public static let filterListURLs = [
        "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssetsCDN@main/thirdparties/easylist.txt",
        "https://cdn.jsdelivr.net/gh/uBlockOrigin/uAssetsCDN@main/thirdparties/easyprivacy.txt",
        "https://cdn.jsdelivr.net/gh/dimisa-RUAdList/RUAdListCDN@main/lists/ruadlist.ubo.min.txt",
        "https://filters.adtidy.org/extension/ublock/filters/11.txt",
        "https://ublockorigin.github.io/uAssetsCDN/filters/filters.min.txt",
        "https://ublockorigin.github.io/uAssetsCDN/filters/unbreak.min.txt",
        "https://ublockorigin.github.io/uAssetsCDN/filters/quick-fixes.min.txt"
    ]

    public enum State: Equatable {
        case idle
        case preparing
        case ready(ruleCount: Int)
        case failed
    }

    private static let identifiersKey = "ayu.adblock.identifiers"
    private static let ruleCountKey = "ayu.adblock.ruleCount"
    private static let builtAtKey = "ayu.adblock.builtAt"
    private static let formatKey = "ayu.adblock.format"
    // Raised whenever the converter changes what it makes of the same filters.
    private static let format = 1
    private static let lifetime: Double = 4.0 * 24.0 * 60.0 * 60.0
    private static let retryInterval: Double = 10.0 * 60.0
    private static let rulesPerList = 20000
    private static let smallestList = 500
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private let defaults = UserDefaults.standard
    private let workQueue = DispatchQueue(label: "app.ayugram.adblock", qos: .utility)
    private let session = URLSession(configuration: .ephemeral)
    private var lists: [WKContentRuleList]?
    private var isLookingUp = false
    private var isBuilding = false
    private var lastFailure: Double = 0.0
    private var waiting: [([WKContentRuleList]) -> Void] = []

    public private(set) var state: State = .idle {
        didSet {
            if self.state != oldValue {
                NotificationCenter.default.post(name: AyuAdBlockStore.didChangeNotification, object: nil)
            }
        }
    }

    private init() {
        if self.hasBuild {
            self.state = .ready(ruleCount: self.defaults.integer(forKey: AyuAdBlockStore.ruleCountKey))
        }
    }

    private var identifiers: [String] {
        return self.defaults.stringArray(forKey: AyuAdBlockStore.identifiersKey) ?? []
    }

    private var hasBuild: Bool {
        return !self.identifiers.isEmpty && self.defaults.integer(forKey: AyuAdBlockStore.formatKey) == AyuAdBlockStore.format
    }

    private var isExpired: Bool {
        let builtAt = self.defaults.double(forKey: AyuAdBlockStore.builtAtKey)
        let now = Date().timeIntervalSince1970
        return builtAt <= 0.0 || builtAt > now || now - builtAt >= AyuAdBlockStore.lifetime
    }

    // The compiled rule lists: at once when they are in memory, else when they are read or built. Not called
    // at all when they could not be made.
    public func ruleLists(_ completion: @escaping ([WKContentRuleList]) -> Void) {
        if let lists = self.lists {
            completion(lists)
            self.prepare()
            return
        }
        self.waiting.append(completion)
        self.prepare()
    }

    // Makes sure the rule lists exist and are fresh.
    public func prepare() {
        if self.lists == nil && self.hasBuild {
            self.lookUp()
        } else if !self.hasBuild || self.isExpired {
            self.build()
        }
    }

    private func lookUp() {
        guard !self.isLookingUp else {
            return
        }
        self.isLookingUp = true
        let identifiers = self.identifiers
        var found: [WKContentRuleList] = []
        var index = 0
        func next() {
            guard index < identifiers.count else {
                self.isLookingUp = false
                if found.count == identifiers.count {
                    self.deliver(found)
                    if self.isExpired {
                        self.build()
                    }
                } else {
                    // WebKit's store was emptied: everything is made again.
                    self.defaults.removeObject(forKey: AyuAdBlockStore.identifiersKey)
                    self.build()
                }
                return
            }
            WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifiers[index]) { list, _ in
                if let list {
                    found.append(list)
                }
                index += 1
                next()
            }
        }
        next()
    }

    private func deliver(_ lists: [WKContentRuleList]) {
        self.lists = lists
        let waiting = self.waiting
        self.waiting = []
        for completion in waiting {
            completion(lists)
        }
    }

    private func build() {
        let now = Date().timeIntervalSince1970
        guard !self.isBuilding, now - self.lastFailure >= AyuAdBlockStore.retryInterval || now < self.lastFailure else {
            return
        }
        self.isBuilding = true
        if self.lists == nil {
            self.state = .preparing
        }

        self.download { texts in
            guard !texts.isEmpty else {
                self.finishBuild(lists: [], identifiers: [], ruleCount: 0)
                return
            }
            self.workQueue.async {
                let ruleLists = AyuAdBlockConverter.ruleLists(AyuAdBlockConverter.convert(lists: texts), limit: AyuAdBlockStore.rulesPerList)
                DispatchQueue.main.async {
                    self.compile(ruleLists)
                }
            }
        }
    }

    // The text of every filter list that could be downloaded.
    private func download(_ completion: @escaping ([String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var texts: [Int: String] = [:]
        for (index, address) in AyuAdBlockStore.filterListURLs.enumerated() {
            guard let url = URL(string: address) else {
                continue
            }
            var request = URLRequest(url: url, timeoutInterval: 60.0)
            request.setValue(AyuAdBlockStore.userAgent, forHTTPHeaderField: "User-Agent")
            group.enter()
            self.session.dataTask(with: request, completionHandler: { data, response, _ in
                if let response = response as? HTTPURLResponse, response.statusCode == 200, let data, let text = String(data: data, encoding: .utf8) {
                    lock.lock()
                    texts[index] = text
                    lock.unlock()
                }
                group.leave()
            }).resume()
        }
        group.notify(queue: .main) {
            completion(texts.keys.sorted().compactMap { texts[$0] })
        }
    }

    // Compiles one list after another. A list WebKit refuses is tried in halves, so one filter it cannot take
    // costs a few hundred rules, not everything.
    private func compile(_ ruleLists: [[AyuAdBlockRule]]) {
        let generation = Int(Date().timeIntervalSince1970)
        var pending = ruleLists
        var compiled: [WKContentRuleList] = []
        var identifiers: [String] = []
        var ruleCount = 0

        func next() {
            guard !pending.isEmpty else {
                self.finishBuild(lists: compiled, identifiers: identifiers, ruleCount: ruleCount)
                return
            }
            let rules = pending.removeFirst()
            let identifier = "ayu-adblock-\(generation)-\(identifiers.count)"
            self.workQueue.async {
                let json = AyuAdBlockConverter.json(rules)
                DispatchQueue.main.async {
                    WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
                        if let list {
                            compiled.append(list)
                            identifiers.append(identifier)
                            ruleCount += rules.count
                        } else if rules.count > AyuAdBlockStore.smallestList {
                            let (first, second) = AyuAdBlockStore.halves(rules)
                            pending.insert(contentsOf: [first, second], at: 0)
                        }
                        next()
                    }
                }
            }
        }
        next()
    }

    // Both halves keep the exceptions at the end, where the whole list had them.
    static func halves(_ rules: [AyuAdBlockRule]) -> ([AyuAdBlockRule], [AyuAdBlockRule]) {
        let body = rules.filter { $0.action != .ignorePreviousRules }
        let exceptions = rules.filter { $0.action == .ignorePreviousRules }
        if body.count < 2 {
            let middle = rules.count / 2
            return (Array(rules[..<middle]), Array(rules[middle...]))
        }
        let middle = body.count / 2
        return (Array(body[..<middle]) + exceptions, Array(body[middle...]) + exceptions)
    }

    private func finishBuild(lists: [WKContentRuleList], identifiers: [String], ruleCount: Int) {
        self.isBuilding = false
        guard !lists.isEmpty else {
            self.lastFailure = Date().timeIntervalSince1970
            if self.lists == nil {
                self.state = .failed
            }
            return
        }
        let previous = self.identifiers.filter { !identifiers.contains($0) }
        self.defaults.set(identifiers, forKey: AyuAdBlockStore.identifiersKey)
        self.defaults.set(ruleCount, forKey: AyuAdBlockStore.ruleCountKey)
        self.defaults.set(Date().timeIntervalSince1970, forKey: AyuAdBlockStore.builtAtKey)
        self.defaults.set(AyuAdBlockStore.format, forKey: AyuAdBlockStore.formatKey)
        self.deliver(lists)
        self.state = .ready(ruleCount: ruleCount)
        // Web views opened before keep the lists they were given; the store only forgets the old files.
        for identifier in previous {
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }
        }
    }

    // Removes everything that was built, for when the blocker is switched off.
    public func removeAll() {
        guard !self.isBuilding, !self.isLookingUp else {
            return
        }
        let identifiers = self.identifiers
        self.defaults.removeObject(forKey: AyuAdBlockStore.identifiersKey)
        self.defaults.removeObject(forKey: AyuAdBlockStore.ruleCountKey)
        self.defaults.removeObject(forKey: AyuAdBlockStore.builtAtKey)
        self.lists = nil
        self.state = .idle
        for identifier in identifiers {
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }
        }
    }
}
