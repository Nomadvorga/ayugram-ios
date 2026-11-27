import Foundation

/// Explicit native adapters, not Java reflection or a JVM. State and results are
/// JSON values; the host alone creates/revokes owned handles. Calls run on its worker.
public struct AyuBridgeClassAdapter: Sendable {
    public typealias Constructor = @Sendable ([AyuBridgeValue], AyuBridgeAdapterContext) throws -> [String: AyuBridgeValue]
    public typealias StaticMethod = @Sendable ([AyuBridgeValue], AyuBridgeAdapterContext) throws -> AyuBridgeAdapterResult
    public typealias StaticField = @Sendable (AyuBridgeAdapterContext) throws -> AyuBridgeAdapterResult
    public typealias InstanceMethod = @Sendable (inout [String: AyuBridgeValue], [AyuBridgeValue], AyuBridgeAdapterContext) throws -> AyuBridgeAdapterResult
    public let name: String
    public let constants: [String: AyuBridgeValue]
    public let constructor: Constructor?
    public let staticMethods: [String: StaticMethod]
    public let staticFields: [String: StaticField]
    public let methods: [String: InstanceMethod]
    public let readableFields: Set<String>
    public let writableFields: Set<String>
    /// Instance methods whose returned same-class state is the receiver's
    /// updated state rather than a request to allocate a new object. Other
    /// `.instance` results remain distinct owned objects.
    public let receiverMethods: Set<String>
    /// Members (static or instance methods and static fields) whose result is always an
    /// instance of the named adapter class, or null. The host rejects any other result, and
    /// publishes the map so static preflight can follow `Class.member(...).member` chains.
    public let results: [String: String]
    /// Members that exist only while the app supplies what they answer from (a presentation
    /// snapshot): the names this closure returns are neither advertised nor resolved.
    public let hiddenMembers: @Sendable () -> Set<String>
    public let validateState: @Sendable ([String: AyuBridgeValue]) throws -> Void

    public init(name: String, constants: [String: AyuBridgeValue] = [:], constructor: Constructor? = nil,
                staticMethods: [String: StaticMethod] = [:], staticFields: [String: StaticField] = [:], methods: [String: InstanceMethod] = [:],
                 readableFields: Set<String> = [], writableFields: Set<String> = [], receiverMethods: Set<String> = [],
                 results: [String: String] = [:],
                 hiddenMembers: @escaping @Sendable () -> Set<String> = { [] },
                 validateState: @escaping @Sendable ([String: AyuBridgeValue]) throws -> Void = { _ in }) {
        self.name = name; self.constants = constants; self.constructor = constructor
        self.staticMethods = staticMethods; self.methods = methods
        self.staticFields = staticFields
        self.readableFields = readableFields; self.writableFields = writableFields; self.receiverMethods = receiverMethods
        self.results = results
        self.hiddenMembers = hiddenMembers
        self.validateState = validateState
    }
}

public enum AyuBridgeAdapterResult: Sendable {
    case value(AyuBridgeValue)
    case instance(className: String, state: [String: AyuBridgeValue])
    /// Native adapter effects (e.g. dialog dismissal) also commit only after
    /// the host validates the enclosing mutation/state and returned value.
    indirect case prepared(AyuBridgeProviderResult)
}

/// Read-only snapshots of references in the current owner/generation. A context
/// cannot be used on another queue or after unload; adapters must not retain it.
public struct AyuBridgeAdapterContext: Sendable {
    public let pluginID: String
    private let resolve: @Sendable (AyuBridgeValue) throws -> AyuBridgeAdapterSnapshot
    private let resolveCallback: @Sendable (AyuBridgeValue) throws -> AyuBridgeNativeCallback
    private let schedule: (@Sendable (AyuBridgeNativeCallback, Int64) throws -> AyuBridgeProviderResult)?
    private let readAnimationPreference: @Sendable () -> Bool
    init(pluginID: String, resolveCallback: @escaping @Sendable (AyuBridgeValue) throws -> AyuBridgeNativeCallback,
         resolve: @escaping @Sendable (AyuBridgeValue) throws -> AyuBridgeAdapterSnapshot,
         schedule: (@Sendable (AyuBridgeNativeCallback, Int64) throws -> AyuBridgeProviderResult)? = nil,
         readAnimationPreference: @escaping @Sendable () -> Bool = { true }) {
        self.pluginID = pluginID; self.resolve = resolve; self.resolveCallback = resolveCallback
        self.schedule = schedule; self.readAnimationPreference = readAnimationPreference
    }
    public func snapshot(of reference: AyuBridgeValue) throws -> AyuBridgeAdapterSnapshot { try self.resolve(reference) }
    public func state(of reference: AyuBridgeValue) throws -> [String: AyuBridgeValue] { try self.resolve(reference).state }
    /// Resolve on the host worker, then retain only this revocable native sender,
    /// never the context itself. It cannot mint Python callback identities.
    public func callback(_ reference: AyuBridgeValue) throws -> AyuBridgeNativeCallback { try self.resolveCallback(reference) }
    /// Enqueue a bounded, generation-revocable callback on the host. Adapters
    /// that do not receive a host scheduler fail explicitly.
    public func schedule(_ callback: AyuBridgeNativeCallback, delayMilliseconds: Int64 = 0) throws -> AyuBridgeProviderResult {
        guard let schedule = self.schedule else { throw AyuBridgeFailure.unsupported("adapter scheduling") }
        return try schedule(callback, delayMilliseconds)
    }
    /// The current native host's user animation preference. It is an iOS-side
    /// Reduce Motion signal, not an emulation of Android's animator scale.
    public func animationsEnabled() -> Bool { self.readAnimationPreference() }
}

public struct AyuBridgeNativeCallback: Sendable {
    private let sink: @Sendable ([AyuBridgeValue]) -> Void
    private let guaranteedSink: (@Sendable ([AyuBridgeValue], [AyuBridgeValue]) -> Void)?
    private let releaseSink: @Sendable () -> Void
    public let id: String
    init(id: String, sink: @escaping @Sendable ([AyuBridgeValue]) -> Void,
         guaranteed: (@Sendable ([AyuBridgeValue], [AyuBridgeValue]) -> Void)? = nil, release: @escaping @Sendable () -> Void = {}) {
        self.id = id
        self.sink = sink
        self.guaranteedSink = guaranteed
        self.releaseSink = release
    }
    /// For a listener or a subscribed event stream: delivered in the order sent. May be dropped,
    /// with the plugin flagged, when too many callbacks of the plugin are pending ("Delivery
    /// queue" in `Python/protocol.md`); a burst of more than 128 goes as one batched event.
    public func send(_ arguments: [AyuBridgeValue]) { self.sink(arguments) }
    /// For a callback that must arrive and whose sender bounds how many are outstanding (a
    /// request in flight, the one result of an activity or picker): it is never refused for the number of pending callbacks, and the small
    /// `substitute` is delivered in its place when `arguments` are too large to send or to queue.
    public func send(_ arguments: [AyuBridgeValue], orOnOverflow substitute: [AyuBridgeValue]) {
        if let guaranteedSink = self.guaranteedSink { guaranteedSink(arguments, substitute) } else { self.sink(arguments) }
    }
    /// Forget a one-shot callback after its last `send` (or without one), so its
    /// id leaves the per-plugin callback registry. Proxy and timer callbacks stay.
    public func release() { self.releaseSink() }
}

public struct AyuBridgeAdapterSnapshot: Sendable {
    public let className: String
    public let state: [String: AyuBridgeValue]
}

public struct AyuBridgeClassRegistry: Sendable {
    public let adapters: [String: AyuBridgeClassAdapter]
    public init(_ adapters: [AyuBridgeClassAdapter]) throws {
        var result: [String: AyuBridgeClassAdapter] = [:]
        for adapter in adapters {
            guard adapter.name.range(of: "^[A-Za-z][A-Za-z0-9_.$]*$", options: .regularExpression) != nil,
                  adapter.name.utf8.count <= 256, result[adapter.name] == nil,
                  !AyuPluginNativeHost.reservedClassNames.contains(adapter.name),
                   adapter.writableFields.isSubset(of: adapter.readableFields),
                   adapter.receiverMethods.isSubset(of: Set(adapter.methods.keys)) else {
                throw AyuBridgeFailure("invalid_adapter", "Duplicate or invalid class adapter")
            }
            let names = Set(adapter.constants.keys).union(adapter.staticMethods.keys).union(adapter.staticFields.keys).union(adapter.methods.keys).union(adapter.readableFields)
            guard names.allSatisfy({ $0.utf8.count <= 128 && $0.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil }),
                  names.isDisjoint(with: ["getClass", "getName", "getDeclaredMethod", "getDeclaredMethods"]),
                   Set(adapter.constants.keys).isDisjoint(with: adapter.staticMethods.keys),
                   Set(adapter.staticFields.keys).isDisjoint(with: Set(adapter.constants.keys).union(adapter.staticMethods.keys)),
                  adapter.readableFields.isDisjoint(with: adapter.methods.keys) else {
                throw AyuBridgeFailure("invalid_adapter", "Ambiguous or invalid adapter member")
            }
            result[adapter.name] = adapter
        }
        let known = Set(result.keys).union(AyuPluginNativeHost.reservedClassNames)
        for adapter in result.values {
            for value in adapter.constants.values { try Self.validateConstant(value, known: known) }
            guard try JSONEncoder().encode(adapter.constants).count <= 131_072 else {
                throw AyuBridgeFailure("invalid_adapter", "Adapter constants exceed quota")
            }
            let callable = Set(adapter.staticMethods.keys).union(adapter.staticFields.keys).union(adapter.methods.keys)
            guard adapter.results.allSatisfy({ member, className in
                callable.contains(member) && result[className] != nil
                    && (!adapter.receiverMethods.contains(member) || className == adapter.name)
            }) else {
                throw AyuBridgeFailure("invalid_adapter", "Adapter result declaration names an unknown member or class")
            }
        }
        self.adapters = result
    }

    public func adding(_ adapters: [AyuBridgeClassAdapter]) throws -> AyuBridgeClassRegistry {
        try AyuBridgeClassRegistry(Array(self.adapters.values) + adapters)
    }
    private static func validateConstant(_ value: AyuBridgeValue, known: Set<String>, depth: Int = 0) throws {
        guard depth < 24 else { throw AyuBridgeFailure("invalid_adapter", "Constant nesting exceeds quota") }
        switch value {
        case let .number(number):
            guard number.isFinite else { throw AyuBridgeFailure("invalid_adapter", "Non-finite adapter constant") }
        case let .array(values):
            for value in values { try self.validateConstant(value, known: known, depth: depth + 1) }
        case let .object(values):
            if values.keys.contains(where: { $0.hasPrefix("$") }) {
                guard values.count == 1, let name = values["$java_class"]?.string, known.contains(name) else {
                    throw AyuBridgeFailure("invalid_adapter", "Constants cannot contain handles or callbacks")
                }
            }
            for value in values.values { try self.validateConstant(value, known: known, depth: depth + 1) }
        default: break
        }
    }
    public static let standard: AyuBridgeClassRegistry = {
        // Curated immutable definitions and the non-visual utility adapters
        // that can coexist with the native-host view registry.
        do {
            return try AyuBridgeClassRegistry(AyuBridgeJavaValues.adapters).adding(AyuBridgeJavaRuntime.integratedAdapters + AyuBridgeJavaRuntime.memberAdapters)
        }
        catch { preconditionFailure("Invalid built-in Java value registry") }
    }()
}
