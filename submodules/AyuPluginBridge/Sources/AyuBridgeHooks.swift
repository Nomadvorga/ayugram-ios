import Foundation

/// Typed hook registry replacing Android's method hooks. A plugin subscribes to
/// declared hook points; the app publishes payloads. Ordering is deterministic,
/// a hook may modify or cancel a payload, one plugin's failure is isolated, and
/// every registration is authorized by code-evaluated capability predicates —
/// never by pinned digests. Screenshot-privacy-class capabilities do not exist
/// here: defeating OS privacy is not an adapter target and cannot be requested.

public struct AyuBridgeHookPoint: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public extension AyuBridgeHookPoint {
    static let messageSendPre = AyuBridgeHookPoint(rawValue: "message.send.pre")
    static let messageSendPost = AyuBridgeHookPoint(rawValue: "message.send.post")
    static let messageEditPre = AyuBridgeHookPoint(rawValue: "message.edit.pre")
    static let messageEditPost = AyuBridgeHookPoint(rawValue: "message.edit.post")
    static let messageDeletePre = AyuBridgeHookPoint(rawValue: "message.delete.pre")
    static let messageReceived = AyuBridgeHookPoint(rawValue: "message.received")
    static let chatDidOpen = AyuBridgeHookPoint(rawValue: "chat.did_open")
    static let chatDidClose = AyuBridgeHookPoint(rawValue: "chat.did_close")
    static let dialogListDidChange = AyuBridgeHookPoint(rawValue: "dialogs.changed")
    static let themeDidChange = AyuBridgeHookPoint(rawValue: "theme.changed")
    static let appWillResignActive = AyuBridgeHookPoint(rawValue: "app.will_resign_active")
    static let appDidBecomeActive = AyuBridgeHookPoint(rawValue: "app.did_become_active")

    /// Whether the hook observes a mutation before it commits and may replace
    /// or cancel it. Post/receive/observe hooks cannot mutate.
    static let mutating: Set<AyuBridgeHookPoint> = [.messageSendPre, .messageEditPre, .messageDeletePre]
    var isMutable: Bool { Self.mutating.contains(self) }
}

/// The aggregate result of a publication: the possibly replaced payload, an
/// explicit cancellation with its reason, and per-plugin failure records.
public struct AyuBridgeHookOutcome: Sendable {
    public let payload: [String: AyuBridgeValue]
    public let cancelled: String?
    public let failures: [String: String]
    public init(payload: [String: AyuBridgeValue], cancelled: String?, failures: [String: String]) {
        self.payload = payload
        self.cancelled = cancelled
        self.failures = failures
    }
}

/// Capabilities a plugin requests at install. Denial names the missing
/// capability; the predicate evaluates the request's declared scope, so a
/// narrower request can pass where a broader one fails.
public struct AyuBridgeCapability: Hashable, Codable, Sendable {
    public let name: String
    public let scope: [String: AyuBridgeValue]
    public init(_ name: String, scope: [String: AyuBridgeValue] = [:]) {
        self.name = name; self.scope = scope
    }
}

public enum AyuBridgeCapabilityName: String, CaseIterable, Sendable {
    case messagesRead = "messages.read"
    case messagesSend = "messages.send"
    case messagesMutate = "messages.mutate"
    case network = "network"
    case uiOverlay = "ui.overlay"
    case uiSettings = "ui.settings"
    case mediaDecode = "media.decode"
    case storage = "storage"
}

public enum AyuBridgeCapabilityError: Error, Equatable, Sendable {
    case missing(name: String, reason: String)
    case unknown(name: String)
    case forbidden(name: String, reason: String)
}

public struct AyuBridgeCapabilitySet: Sendable {
    public let granted: [AyuBridgeCapability]
    public init(_ granted: [AyuBridgeCapability]) { self.granted = granted }

    public func has(_ name: AyuBridgeCapabilityName) -> Bool {
        self.granted.contains { $0.name == name.rawValue }
    }
    public func scope(of name: AyuBridgeCapabilityName) -> [String: AyuBridgeValue] {
        self.granted.first { $0.name == name.rawValue }?.scope ?? [:]
    }
    /// Code-based predicate: the grant must exist and its scope must cover the
    /// requested use. Chat scoping: an absent "chats" list means all chats; a
    /// present list is an allow-list of Int64 chat ids.
    public func check(_ name: AyuBridgeCapabilityName, chatID: Int64? = nil) throws {
        guard let grant = self.granted.first(where: { $0.name == name.rawValue }) else {
            if AyuBridgeCapabilityName(rawValue: name.rawValue) == nil { throw AyuBridgeCapabilityError.unknown(name: name.rawValue) }
            throw AyuBridgeCapabilityError.missing(name: name.rawValue, reason: "not requested by the plugin")
        }
        if let chatID {
            let chats = grant.scope["chats"]?.array?.compactMap(\.integer)
            if let chats, !chats.contains(chatID) {
                throw AyuBridgeCapabilityError.missing(name: name.rawValue, reason: "chat \(chatID) is outside the granted scope")
            }
        }
    }
    /// Screenshot-privacy and other OS-defeating requests are refused by name,
    /// before any predicate runs.
    public static func validateRequest(_ names: [String]) throws {
        for name in names where name.lowercased().contains("screenshot") || name.lowercased().contains("capture") {
            throw AyuBridgeCapabilityError.forbidden(name: name, reason: "OS privacy defeating capabilities are not adapter targets")
        }
    }
}

struct AyuBridgeHookSubscription: Sendable {
    let id: Int64
    let point: AyuBridgeHookPoint
    let pluginID: String
    let priority: Int
    let sink: @Sendable ([String: AyuBridgeValue]) throws -> AyuBridgeHookDecision
}

public struct AyuBridgeHookDecision: Sendable {
    public enum Action: Sendable { case proceed, cancel(String), replace([String: AyuBridgeValue]) }
    public let action: Action
    public static let proceed = AyuBridgeHookDecision(action: .proceed)
    public static func cancel(_ reason: String) -> AyuBridgeHookDecision { AyuBridgeHookDecision(action: .cancel(reason)) }
    public static func replace(_ payload: [String: AyuBridgeValue]) -> AyuBridgeHookDecision { AyuBridgeHookDecision(action: .replace(payload)) }
}

public enum AyuBridgeHookError: Error, Equatable, Sendable {
    case missingCapability(name: String, reason: String)
    case unknownPoint(String)
    case duplicateSubscription(Int64)
    case payloadTooLarge(Int)
}

/// The app owns publication; plugins own subscriptions. Thread-safe: publish
/// runs each sink serially on the calling (host worker) queue and isolates
/// thrown errors per plugin. Revoking a plugin's subscriptions cannot throw.
public final class AyuBridgeHookRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptions: [AyuBridgeHookSubscription] = []
    private var nextID: Int64 = 1
    private let maxPayloadBytes: Int

    public init(maxPayloadBytes: Int = 262_144) { self.maxPayloadBytes = maxPayloadBytes }

    public func subscribe(pluginID: String, point: AyuBridgeHookPoint, priority: Int = 0,
                          capabilities: AyuBridgeCapabilitySet,
                          sink: @escaping @Sendable ([String: AyuBridgeValue]) throws -> AyuBridgeHookDecision) throws -> Int64 {
        let required: AyuBridgeCapabilityName
        switch point {
        case .messageSendPre, .messageSendPost: required = .messagesSend
        case .messageEditPre, .messageEditPost, .messageDeletePre: required = .messagesMutate
        default: required = .messagesRead
        }
        do { try capabilities.check(required) }
        catch let error as AyuBridgeCapabilityError {
            switch error {
            case let .missing(name, reason): throw AyuBridgeHookError.missingCapability(name: name, reason: reason)
            case let .forbidden(name, reason): throw AyuBridgeHookError.missingCapability(name: name, reason: reason)
            default: throw AyuBridgeHookError.missingCapability(name: required.rawValue, reason: "unknown capability")
            }
        }
        self.lock.lock(); defer { self.lock.unlock() }
        let id = self.nextID
        self.nextID += 1
        self.subscriptions.append(AyuBridgeHookSubscription(id: id, point: point, pluginID: pluginID, priority: priority, sink: sink))
        self.subscriptions.sort { ($0.priority, $0.id) < ($1.priority, $1.id) }
        return id
    }

    public func revoke(pluginID: String) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.subscriptions.removeAll { $0.pluginID == pluginID }
    }

    public func revoke(subscription id: Int64) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.subscriptions.removeAll { $0.id == id }
    }

    public func subscriptionCount(pluginID: String? = nil) -> Int {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let pluginID else { return self.subscriptions.count }
        return self.subscriptions.filter { $0.pluginID == pluginID }.count
    }

    /// Publishes a payload to the point's subscribers in priority order. For a
    /// mutating point the returned payload is the possibly replaced one and
    /// `cancelled` reports an explicit cancellation with its reason. Oversized
    /// payloads throw before any sink runs; a sink's thrown error becomes that
    /// plugin's failure record and never stops the chain.
    public func publish(_ point: AyuBridgeHookPoint, payload: [String: AyuBridgeValue]) throws -> (payload: [String: AyuBridgeValue], cancelled: String?, failures: [String: String]) {
        let encoded = try JSONEncoder().encode(AyuBridgeValue.object(payload))
        guard encoded.count <= self.maxPayloadBytes else { throw AyuBridgeHookError.payloadTooLarge(encoded.count) }
        self.lock.lock()
        let matching = self.subscriptions.filter { $0.point == point }
        self.lock.unlock()
        var current = payload
        var cancelled: String?
        var failures: [String: String] = [:]
        for subscription in matching {
            do {
                let decision = try subscription.sink(current)
                switch decision.action {
                case .proceed: break
                case let .cancel(reason):
                    if point.isMutable { cancelled = reason; return (current, cancelled, failures) }
                    failures[subscription.pluginID] = "observe hooks cannot cancel"
                case let .replace(replacement):
                    if point.isMutable { current = replacement } else { failures[subscription.pluginID] = "observe hooks cannot mutate" }
                }
            } catch {
                let message = (error as? AyuBridgeFailure)?.message ?? String(describing: error)
                failures[subscription.pluginID] = message
            }
        }
        return (current, cancelled, failures)
    }
}
