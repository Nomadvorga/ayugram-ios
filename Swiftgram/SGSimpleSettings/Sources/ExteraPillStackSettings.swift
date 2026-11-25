import Foundation

/// Inventory from reference frame 31. Stable names are independent of display language.
public enum ExteraBuiltinPill: String, Codable, CaseIterable {
    case weather, gram, btc, usd, storage, proxy, entryTime
    public var id: String { "builtin." + self.rawValue }
    public var symbol: String {
        switch self {
        case .weather: return "cloud.fill"
        case .gram: return "diamond.fill"
        case .btc: return "bitcoinsign.circle.fill"
        case .usd: return "dollarsign.circle.fill"
        case .storage: return "internaldrive.fill"
        case .proxy: return "checkmark.shield.fill"
        case .entryTime: return "shoeprints.fill"
        }
    }
    public func title(_ language: String) -> String {
        switch self {
        case .weather: return exteraPillText(language, "Weather", "Погода")
        case .gram: return "GRAM"
        case .btc: return "BTC"
        case .usd: return "USD"
        case .storage: return exteraPillText(language, "Storage Usage", "Использование памяти")
        case .proxy: return exteraPillText(language, "Proxy", "Прокси")
        case .entryTime: return exteraPillText(language, "Entry Time", "Время захода")
        }
    }
    public static func from(id: String) -> Self? { allCases.first { $0.id == id } }
}

/// Separate from customHTTPPills.v1: imports/backup of HTTP endpoints keep their exact v1 schema.
public struct ExteraPillStackLayout: Codable, Equatable {
    public var visible: [String] = []
    public var hidden: [String] = ExteraBuiltinPill.allCases.map { $0.id }
    public var infiniteScrolling = true
    public var selected: String?

    public init() {}
    private enum CodingKeys: String, CodingKey { case visible, hidden, infiniteScrolling, selected }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.visible = try values.decodeIfPresent([String].self, forKey: .visible) ?? []
        self.hidden = try values.decodeIfPresent([String].self, forKey: .hidden) ?? ExteraBuiltinPill.allCases.map { $0.id }
        self.infiniteScrolling = try values.decodeIfPresent(Bool.self, forKey: .infiniteScrolling) ?? true
        self.selected = try values.decodeIfPresent(String.self, forKey: .selected)
    }
    public static func customId(_ id: UUID) -> String { "custom." + id.uuidString.lowercased() }
    public func normalized(custom: [ExteraPillSpec]) -> Self {
        let inventory = ExteraBuiltinPill.allCases.map { $0.id } + custom.map { Self.customId($0.id) }
        let known = Set(inventory)
        var seen = Set<String>()
        var result = self
        result.visible = self.visible.filter { known.contains($0) && seen.insert($0).inserted }
        result.hidden = (self.hidden + inventory).filter { known.contains($0) && seen.insert($0).inserted }
        if let selected = result.selected, !result.visible.contains(selected) { result.selected = nil }
        return result
    }
    public mutating func setVisible(_ id: String, _ show: Bool) {
        guard (self.visible + self.hidden).contains(id) else { return }
        if show {
            guard !self.visible.contains(id) else { return }
            self.hidden.removeAll { $0 == id }; self.visible.append(id)
        } else {
            guard !self.hidden.contains(id) else { return }
            self.visible.removeAll { $0 == id }; self.hidden.append(id)
            if self.selected == id { self.selected = nil }
        }
    }
    /// Identity-based insertion supports cross-section moves, including an empty destination.
    public mutating func move(_ id: String, visible: Bool, before: String?) {
        guard (self.visible + self.hidden).contains(id), before != id else { return }
        let destination = visible ? self.visible : self.hidden
        guard before == nil || destination.contains(before!) else { return }
        self.visible.removeAll { $0 == id }; self.hidden.removeAll { $0 == id }
        var target = visible ? self.visible : self.hidden
        target.insert(id, at: before.flatMap { target.firstIndex(of: $0) } ?? target.count)
        if visible { self.visible = target } else { self.hidden = target }
        if !visible && self.selected == id { self.selected = nil }
    }
    public func renderedIds(custom: [ExteraPillSpec]) -> [String] {
        let enabled = Set(custom.filter { $0.enabled }.map { Self.customId($0.id) })
        return self.normalized(custom: custom).visible.filter { ExteraBuiltinPill.from(id: $0) != nil || enabled.contains($0) }
    }
    public func next(from current: String?, direction: Int, ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        let next = index + (direction < 0 ? -1 : 1)
        if ids.indices.contains(next) { return ids[next] }
        return self.infiniteScrolling ? (direction < 0 ? ids.last : ids.first) : current
    }
}

public final class ExteraPillStackSettings: @unchecked Sendable {
    public static let shared = ExteraPillStackSettings()
    public static let didChange = Notification.Name("ExteraPillStackDidChange")
    public static let key = "extera.pillStack.layout.v1"
    private let defaults: UserDefaults
    private let lock = NSRecursiveLock()
    public convenience init() { self.init(userDefaults: AyuSettingsStore.shared.userDefaults) }
    public init(userDefaults: UserDefaults) { self.defaults = userDefaults }
    public var layout: ExteraPillStackLayout {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let data = self.defaults.data(forKey: Self.key), let layout = try? JSONDecoder().decode(ExteraPillStackLayout.self, from: data) else { return ExteraPillStackLayout() }
        return layout
    }
    public func update(custom: [ExteraPillSpec], _ f: (inout ExteraPillStackLayout) -> Void) {
        self.lock.lock()
        var layout = self.layout.normalized(custom: custom)
        f(&layout)
        layout = layout.normalized(custom: custom)
        if let data = try? JSONEncoder().encode(layout) { self.defaults.set(data, forKey: Self.key) }
        self.lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    /// Grants are per account. Layout migration/import never grants access to remote providers.
    public func allowed(_ provider: String, account: Int64) -> Bool { self.defaults.bool(forKey: "extera.pillStack.\(account).allow.\(provider)") }
    public func allow(_ provider: String, account: Int64, value: Bool) {
        self.defaults.set(value, forKey: "extera.pillStack.\(account).allow.\(provider)")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    public func allowsWeather(source: String, account: Int64) -> Bool {
        self.allowed("weather", account: account) && self.defaults.string(forKey: "extera.pillStack.\(account).weatherSource") == source
    }
    public func allowWeather(source: String, account: Int64, value: Bool) {
        let key = "extera.pillStack.\(account).weatherSource"
        if value { self.defaults.set(source, forKey: key) } else { self.defaults.removeObject(forKey: key) }
        self.allow("weather", account: account, value: value)
    }
    public func allowsCustom(_ spec: ExteraPillSpec, account: Int64) -> Bool {
        self.defaults.string(forKey: "extera.pillStack.\(account).customURL.\(spec.id.uuidString)") == spec.url
    }
    public func allowCustom(_ spec: ExteraPillSpec, account: Int64, value: Bool) {
        let key = "extera.pillStack.\(account).customURL.\(spec.id.uuidString)"
        if value { self.defaults.set(spec.url, forKey: key) } else { self.defaults.removeObject(forKey: key) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    public func currency(account: Int64) -> String {
        if let value = self.defaults.string(forKey: "extera.pillStack.\(account).currency") { return value }
        if #available(iOS 16.0, macOS 13.0, *) { return Locale.current.currency?.identifier ?? "USD" }
        return Locale.current.currencyCode ?? "USD"
    }
    public func setCurrency(_ currency: String, account: Int64) {
        guard currency.count == 3, currency.unicodeScalars.allSatisfy({ (65 ... 90).contains(Int($0.value)) }) else { return }
        self.defaults.set(currency, forKey: "extera.pillStack.\(account).currency")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// Production completion gate: cancelling or switching the selected provider invalidates old work,
/// even when a transport delivers a completion after cancellation or A → B → A.
public struct ExteraPillProviderGeneration {
    public struct Ticket: Equatable { fileprivate let generation: UInt64; public let id: String }
    private var generation: UInt64 = 0
    private var current: Ticket?
    public init() {}
    public mutating func begin(_ id: String) -> Ticket {
        self.cancel()
        let ticket = Ticket(generation: self.generation, id: id)
        self.current = ticket
        return ticket
    }
    public mutating func cancel() { self.generation &+= 1; self.current = nil }
    public func accepts(_ ticket: Ticket) -> Bool { self.current == ticket }
}

/// Leases from explicit HTTP dashboards observe all enabled configurations. A search stack
/// observes only the exact approved configuration selected in that host. Shared hosts cannot
/// broaden each other's scope after one closes, and imported replacement URLs are never approved
/// by an old search lease. Used directly by the foreground HTTP scheduler.
public struct ExteraPillRequestLeases {
    private struct Lease { let approved: [ExteraPillSpec]? }
    private var values: [UUID: Lease] = [:]
    public init() {}
    public var isEmpty: Bool { self.values.isEmpty }
    public mutating func acquire(approved: [ExteraPillSpec]?) -> UUID {
        let id = UUID(); self.values[id] = Lease(approved: approved); return id
    }
    public mutating func release(_ id: UUID) { self.values.removeValue(forKey: id) }
    public func permits(_ spec: ExteraPillSpec) -> Bool {
        self.values.values.contains { $0.approved == nil || $0.approved!.contains(spec) }
    }
}

public enum ExteraPillExchangeRate {
    /// Coinbase publishes units per USD. A base/target cross rate is target units / base units.
    public static func value(data: Data, base: String, target: String, locale: Locale = .current) throws -> String {
        guard data.count <= 512 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any], payload["currency"] as? String == "USD",
              let rates = payload["rates"] as? [String: String],
              let baseValue = Double(rates[base] ?? ""), baseValue.isFinite, baseValue > 0,
              let targetValue = Double(rates[target] ?? ""), targetValue.isFinite, targetValue > 0 else { throw ExteraPillError.missingValue }
        let price = targetValue / baseValue
        guard price.isFinite, price > 0 else { throw ExteraPillError.invalidNumber }
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = price < 1 ? 6 : 2
        guard let text = formatter.string(from: NSNumber(value: price)) else { throw ExteraPillError.invalidNumber }
        return text + " " + target
    }
}
