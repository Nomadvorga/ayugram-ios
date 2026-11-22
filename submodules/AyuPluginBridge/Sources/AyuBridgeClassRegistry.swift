import Foundation

/// Explicit native adapters, not Java reflection or a JVM. State and results are
/// JSON values; the host alone creates/revokes owned handles. Calls run on its worker.
public struct AyuBridgeClassAdapter: Sendable {
    public typealias Constructor = @Sendable ([AyuBridgeValue], AyuBridgeAdapterContext) throws -> [String: AyuBridgeValue]
    public typealias StaticMethod = @Sendable ([AyuBridgeValue], AyuBridgeAdapterContext) throws -> AyuBridgeAdapterResult
    public typealias InstanceMethod = @Sendable (inout [String: AyuBridgeValue], [AyuBridgeValue], AyuBridgeAdapterContext) throws -> AyuBridgeAdapterResult
    public let name: String
    public let constants: [String: AyuBridgeValue]
    public let constructor: Constructor?
    public let staticMethods: [String: StaticMethod]
    public let methods: [String: InstanceMethod]
    public let readableFields: Set<String>
    public let writableFields: Set<String>
    public let validateState: @Sendable ([String: AyuBridgeValue]) throws -> Void

    public init(name: String, constants: [String: AyuBridgeValue] = [:], constructor: Constructor? = nil,
                staticMethods: [String: StaticMethod] = [:], methods: [String: InstanceMethod] = [:],
                readableFields: Set<String> = [], writableFields: Set<String> = [],
                validateState: @escaping @Sendable ([String: AyuBridgeValue]) throws -> Void = { _ in }) {
        self.name = name; self.constants = constants; self.constructor = constructor
        self.staticMethods = staticMethods; self.methods = methods
        self.readableFields = readableFields; self.writableFields = writableFields
        self.validateState = validateState
    }
}

public enum AyuBridgeAdapterResult: Sendable {
    case value(AyuBridgeValue)
    case instance(className: String, state: [String: AyuBridgeValue])
}

/// Read-only snapshots of references in the current owner/generation. A context
/// cannot be used on another queue or after unload; adapters must not retain it.
public struct AyuBridgeAdapterContext: Sendable {
    public let pluginID: String
    private let resolve: @Sendable (AyuBridgeValue) throws -> AyuBridgeAdapterSnapshot
    init(pluginID: String, resolve: @escaping @Sendable (AyuBridgeValue) throws -> AyuBridgeAdapterSnapshot) {
        self.pluginID = pluginID; self.resolve = resolve
    }
    public func snapshot(of reference: AyuBridgeValue) throws -> AyuBridgeAdapterSnapshot { try self.resolve(reference) }
    public func state(of reference: AyuBridgeValue) throws -> [String: AyuBridgeValue] { try self.resolve(reference).state }
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
                  adapter.writableFields.isSubset(of: adapter.readableFields) else {
                throw AyuBridgeFailure("invalid_adapter", "Duplicate or invalid class adapter")
            }
            let names = Set(adapter.constants.keys).union(adapter.staticMethods.keys).union(adapter.methods.keys).union(adapter.readableFields)
            guard names.allSatisfy({ $0.utf8.count <= 128 && $0.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil }),
                  names.isDisjoint(with: ["getClass", "getName", "getDeclaredMethod", "getDeclaredMethods"]),
                  Set(adapter.constants.keys).isDisjoint(with: adapter.staticMethods.keys),
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
        // Curated immutable definitions; invalid application additions throw in init.
        do { return try AyuBridgeClassRegistry(AyuBridgeJavaValues.adapters) }
        catch { preconditionFailure("Invalid built-in Java value registry") }
    }()
}
