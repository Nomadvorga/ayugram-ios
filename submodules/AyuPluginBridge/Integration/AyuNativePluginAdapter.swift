import CryptoKit
import Foundation
import UIKit

/// Host-owned native compatibility routes. Each route is pinned to the exact
/// UTF-8 source that was statically audited. Nothing here imports, executes or
/// translates arbitrary Android classes: the app implements the known contract
/// with real iOS/Telegram behaviour.
public struct AyuNativeTextReplacement {
    public let range: NSRange
    public let length: Int
    public init(range: NSRange, length: Int) {
        self.range = range
        self.length = length
    }
}

public struct AyuNativeTextRewrite {
    public let text: String
    public let replacements: [AyuNativeTextReplacement]
    public init(text: String, replacements: [AyuNativeTextReplacement]) {
        self.text = text
        self.replacements = replacements
    }
}

/// A resolved Pull to Next Chat configuration. The chat list applies it to the
/// real dialogs, so the source target/strategy/filter settings keep working
/// instead of being decorative switches.
public struct AyuPullNextChatPolicy {
    public let sourceKind: String?
    public let currentPeerId: Int64?
    public let targetKinds: Set<String>
    public let strategy: Int
    public let includeMuted: Bool
    public let skipPinned: Bool
    public let otherFolders: Bool
    public let countMarkedUnread: Bool

    public init(sourceKind: String?, currentPeerId: Int64?, targetKinds: Set<String>, strategy: Int, includeMuted: Bool,
                skipPinned: Bool, otherFolders: Bool, countMarkedUnread: Bool) {
        self.sourceKind = sourceKind
        self.currentPeerId = currentPeerId
        self.targetKinds = targetKinds
        self.strategy = strategy
        self.includeMuted = includeMuted
        self.skipPinned = skipPinned
        self.otherFolders = otherFolders
        self.countMarkedUnread = countMarkedUnread
    }

    public func withCurrentPeerId(_ peerId: Int64?) -> AyuPullNextChatPolicy {
        return AyuPullNextChatPolicy(sourceKind: self.sourceKind, currentPeerId: peerId,
                                     targetKinds: self.targetKinds, strategy: self.strategy,
                                     includeMuted: self.includeMuted, skipPinned: self.skipPinned,
                                     otherFolders: self.otherFolders, countMarkedUnread: self.countMarkedUnread)
    }
}

@MainActor
class AyuNativePluginAdapter {
    let pluginID: String
    let defaults: UserDefaults
    let reportError: (String?) -> Void
    var actionTitle: String? { nil }

    init(pluginID: String, defaults: UserDefaults, reportError: @escaping (String?) -> Void) {
        self.pluginID = pluginID
        self.defaults = defaults
        self.reportError = reportError
    }

    var storageKey: String { "AyuPluginBridge.v1." + self.pluginID }

    func enable() throws {}
    func disable() {}
    func settings() throws -> [AyuPluginSetting] { [] }
    func set(_ row: AyuPluginSetting, value: AyuBridgeValue) throws {
        throw AyuPluginService.Failure.operation("INVALID_SETTING")
    }
    func activate(_ row: AyuPluginSetting, presenter: UIViewController?, completion: @escaping () -> Void) throws {
        completion()
    }
    func open(from presenter: UIViewController) {}

    // MARK: - Persistence

    func loadValues() throws -> [String: AyuBridgeValue] {
        guard let data = self.defaults.data(forKey: self.storageKey) else { return [:] }
        guard data.count <= 65_536 else { throw AyuPluginService.Failure.operation("SETTINGS_QUOTA") }
        do { return try JSONDecoder().decode([String: AyuBridgeValue].self, from: data) }
        catch { throw AyuPluginService.Failure.protocolError }
    }

    func saveValues(_ values: [String: AyuBridgeValue]) throws {
        let data = try JSONEncoder().encode(values)
        guard data.count <= 65_536 else { throw AyuPluginService.Failure.operation("SETTINGS_QUOTA") }
        self.defaults.set(data, forKey: self.storageKey)
    }

    func boolValue(_ key: String, default fallback: Bool) -> Bool {
        guard let value = try? self.loadValues()[key] else { return fallback }
        if case let .bool(flag) = value { return flag }
        return fallback
    }

    func integerValue(_ key: String, default fallback: Int) -> Int {
        guard let value = try? self.loadValues()[key], let number = value.integer else { return fallback }
        return Int(clamping: number)
    }

    func stringValue(_ key: String, default fallback: String) -> String {
        guard let value = try? self.loadValues()[key], let text = value.string else { return fallback }
        return text
    }

    func setValue(_ value: AyuBridgeValue, for key: String) throws {
        var values = try self.loadValues()
        values[key] = value
        try self.saveValues(values)
    }

    // MARK: - Rows

    func textRow(_ text: String, subtext: String = "", action: String? = nil, editor: String? = nil) -> AyuPluginSetting {
        var descriptor: [String: AyuBridgeValue] = ["type": .string("Text"), "text": .string(text), "subtext": .string(subtext)]
        if let action { descriptor["native_action"] = .string(action) }
        if let editor { descriptor["native_editor"] = .string(editor) }
        return AyuPluginSetting(descriptor: .object(descriptor), value: .null)
    }

    func staticRow(_ type: String, _ text: String, subtext: String = "") -> AyuPluginSetting {
        AyuPluginSetting(descriptor: .object(["type": .string(type), "text": .string(text), "subtext": .string(subtext)]), value: .null)
    }

    func switchRow(_ key: String, _ text: String, subtext: String, value: Bool) -> AyuPluginSetting {
        AyuPluginSetting(descriptor: .object(["type": .string("Switch"), "key": .string(key), "text": .string(text),
                                               "subtext": .string(subtext), "default": .bool(true)]), value: .bool(value))
    }

    func selectorRow(_ key: String, _ text: String, subtext: String, items: [String], value: Int) -> AyuPluginSetting {
        AyuPluginSetting(descriptor: .object(["type": .string("Selector"), "key": .string(key), "text": .string(text),
                                               "subtext": .string(subtext), "items": .array(items.map(AyuBridgeValue.string)),
                                               "default": .integer(0)]), value: .integer(Int64(value)))
    }

    func requireOwnedRow(_ row: AyuPluginSetting, key: String, kind: String) throws {
        guard row.key == key, row.type == kind, row.descriptor["native_generation"] == .null || row.descriptor["native_generation"].string != nil else {
            throw AyuPluginService.Failure.operation("STALE_SETTING")
        }
    }
}

struct AyuNativePluginDescriptor: Sendable {
    let id: String
    let adapterID: String
    let displayName: String
    let version: String
    let sha256: String
    let make: @MainActor @Sendable (UserDefaults, (String?) -> Void) -> AyuNativePluginAdapter

    func record(for source: Data) -> AyuInstalledPlugin? {
        guard source.count <= 1_048_576 else { return nil }
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        guard digest == self.sha256 else { return nil }
        return AyuInstalledPlugin(id: self.id, name: self.displayName, version: self.version,
                                  blockers: [], nativeAdapter: self.adapterID)
    }
}

enum AyuNativePluginCatalog {
    static let plugins: [AyuNativePluginDescriptor] = [
        AyuNativePluginDescriptor(id: "sand_box", adapterID: "sand_box.native.ios.v1", displayName: "SandBox", version: "1.0.0",
            sha256: "9bd2c5ffa93e6a866212a4e0fd263b6216dc10080bbd55c79f40625e8942f8e5",
            make: { defaults, report in AyuSandBoxAdapter(defaults: defaults, reportError: report) }),
        AyuNativePluginDescriptor(id: "ball", adapterID: "ball.native.ios.v1", displayName: "Ball", version: "1.1",
            sha256: "89f079f2a055ba851b6efec90a2c57d233b1f7204102363b2a637fa06579ea8f",
            make: { defaults, report in AyuBallAdapter(defaults: defaults, reportError: report) }),
        AyuNativePluginDescriptor(id: "screenshot_privacy", adapterID: "screenshot_privacy.native.ios.v1", displayName: "Screenshot Privacy", version: "1.4.2",
            sha256: "ce11a973f667623b84aadd1fc68d50fedf410e605759c251789383641cbef23e",
            make: { defaults, report in AyuScreenshotPrivacyAdapter(defaults: defaults, reportError: report) }),
        AyuNativePluginDescriptor(id: "pull_next_chat", adapterID: "pull_next_chat.native.ios.v1", displayName: "Pull to Next Chat", version: "1.0.0",
            sha256: "69975fd768369d2a46d28dbe87f8c580f772d0f974ce8434fca58f65babed709",
            make: { defaults, report in AyuPullNextChatAdapter(defaults: defaults, reportError: report) }),
    ]

    static func descriptor(for source: Data) -> AyuNativePluginDescriptor? {
        self.plugins.first { $0.record(for: source) != nil }
    }

    static func descriptor(id: String) -> AyuNativePluginDescriptor? {
        self.plugins.first { $0.id == id }
    }

    /// Static text peek only. It never compiles or executes plugin code and is
    /// used to fail closed when a known id arrives with an unaudited source.
    static func declaredID(in source: String) -> String? {
        guard source.utf8.count <= 1_048_576 else { return nil }
        let pattern = "(?m)^__id__[ \\t]*=[ \\t]*[\"']([A-Za-z][A-Za-z0-9_-]{1,31})[\"']"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = expression.firstMatch(in: source, range: range), match.numberOfRanges == 2,
              let valueRange = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[valueRange])
    }

    static func blocker(for id: String) -> String {
        return "Исходник «" + id + "» не совпадает с проверенной версией. Нативный iOS-адаптер не запускает изменённый код."
    }

    static func record(for source: Data) -> AyuInstalledPlugin? {
        guard let text = String(data: source, encoding: .utf8) else { return nil }
        if let descriptor = self.descriptor(for: source) {
            return descriptor.record(for: source)
        }
        guard let id = self.declaredID(in: text), let known = self.descriptor(id: id) else { return nil }
        return AyuInstalledPlugin(id: id, name: known.displayName, version: known.version,
                                  blockers: [self.blocker(for: id)])
    }
}

/// Small main-thread façade used by the real Telegram screens. It only forwards
/// to already-enabled, source-verified adapters; disabled plugins do nothing.
@MainActor
public final class AyuNativePluginRuntime {
    public static let shared = AyuNativePluginRuntime()
    public var presenter: (@MainActor () -> UIViewController?)?
    /// The plugin manager sets this while it is on screen so adapter feedback is
    /// visible above the modal instead of being dropped by the app presenter gate.
    public var feedbackPresenter: (@MainActor () -> UIViewController?)?
    public var nextUnread: (@MainActor (AyuPullNextChatPolicy) -> Void)?
    weak var groupMentions: AyuGroupMentionsAdapter?
    weak var sandBox: AyuSandBoxAdapter?
    weak var ball: AyuBallAdapter?
    weak var pullNextChat: AyuPullNextChatAdapter?
    weak var screenshotPrivacy: AyuScreenshotPrivacyAdapter?

    private init() {}

    public func expandGroupMentions(_ text: String, accountKey: String, peerID: Int64,
                                    isGroup: Bool, isChannel: Bool) -> String {
        guard let adapter = self.groupMentions else { return text }
        return adapter.expand(text, accountKey: accountKey, peerID: peerID, isGroup: isGroup, isChannel: isChannel)
    }

    /// Detailed form used before enqueueing messages: the caller can shift the
    /// UTF-16 ranges of existing text entities so links/formatting survive a
    /// rewritten mention command. This is the iOS equivalent of the Android hook
    /// modifying message text before entities are generated.
    public func expandGroupMentionsDetailed(_ text: String, accountKey: String, peerID: Int64,
                                            isGroup: Bool, isChannel: Bool) -> AyuNativeTextRewrite {
        guard let adapter = self.groupMentions else { return AyuNativeTextRewrite(text: text, replacements: []) }
        return adapter.expandDetailed(text, accountKey: accountKey, peerID: peerID, isGroup: isGroup, isChannel: isChannel)
    }

    /// Returns true when the command was consumed by SandBox and the caller must
    /// not send the message. Only the exact `.sand` prefix is recognised.
    public func handleSandCommand(_ text: String, from presenter: UIViewController?) -> Bool {
        guard let adapter = self.sandBox, adapter.isEnabled, adapter.commandEnabled else { return false }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard command.hasPrefix(".sand") else { return false }
        // Consume the command even when no presenter is available: sending the
        // literal ".sand" to the peer is never the intended behaviour.
        if let presenter = presenter ?? self.presenter?() {
            adapter.open(from: presenter)
        }
        return true
    }

    public func requestNextUnread(sourceKind: String, currentPeerId: Int64?) {
        guard let adapter = self.pullNextChat else { return }
        let kind = AyuPullNextChatAdapter.Kind(rawValue: sourceKind)
        guard let policy = adapter.policy(forSourceKind: kind) else { return }
        self.nextUnread?(policy.withCurrentPeerId(currentPeerId))
    }

    public func showMessage(_ text: String, style: String = "simple") {
        let host = self.feedbackPresenter?()?.viewIfLoaded
        AyuPluginApplicationBridge.shared.showBulletin(text, style: style, in: host)
    }

    public func privacyDidChange() {
        self.screenshotPrivacy?.refresh()
    }
}
