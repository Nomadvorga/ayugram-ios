import Foundation

/// JSON-only boundary. Handles and callbacks are data, never Swift object addresses.
public indirect enum AyuBridgeValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([AyuBridgeValue])
    case object([String: AyuBridgeValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Int64.self) { self = .integer(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([AyuBridgeValue].self) { self = .array(item) }
        else { self = .object(try value.decode([String: AyuBridgeValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public var string: String? { if case let .string(value) = self { return value }; return nil }
    public var number: Double? {
        switch self { case let .number(value): return value; case let .integer(value): return Double(value); default: return nil }
    }
    public var integer: Int64? {
        if case let .integer(value) = self { return value }; return nil
    }
    public var array: [AyuBridgeValue]? { if case let .array(value) = self { return value }; return nil }
    public var object: [String: AyuBridgeValue]? { if case let .object(value) = self { return value }; return nil }
    public subscript(_ key: String) -> AyuBridgeValue { self.object?[key] ?? .null }
}

public struct AyuBridgeFailure: Error, Codable, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code.uppercased(); self.message = message }
    public static func unsupported(_ name: String) -> AyuBridgeFailure {
        return AyuBridgeFailure("unsupported_api", "Unsupported API: \(name)")
    }
}

/// Implemented by the app. Called on the host's serial worker, never on main.
/// Implementations must marshal UI work to main without having main wait for this worker.
/// Operations must be declared by capabilities, preserve the supplied owner, and throw on failure.
public protocol AyuPluginHostProvider: AnyObject, Sendable {
    var capabilities: [String] { get }
    func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue
    /// Object-producing calls return typed state, not wire handles. The host
    /// validates/stores the result before committing asynchronous native effects.
    func prepareCall(pluginID: String, operation: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult
    func detach(pluginID: String)
}

public struct AyuBridgeProviderResult: Sendable {
    public let result: AyuBridgeAdapterResult
    public let rollback: @Sendable () -> Void
    public let commit: @Sendable (AyuBridgeValue) -> Void
    public init(_ result: AyuBridgeAdapterResult, rollback: @escaping @Sendable () -> Void = {}, commit: @escaping @Sendable (AyuBridgeValue) -> Void = { _ in }) {
        self.result = result; self.rollback = rollback; self.commit = commit
    }
}

public extension AyuPluginHostProvider {
    func prepareCall(pluginID: String, operation: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        AyuBridgeProviderResult(.value(try self.call(pluginID: pluginID, operation: operation, arguments: arguments)))
    }
}

public final class AyuUnsupportedPluginHostProvider: AyuPluginHostProvider, Sendable {
    public init() {}
    public var capabilities: [String] { return [] }
    public func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
        throw AyuBridgeFailure.unsupported(operation)
    }
    public func detach(pluginID: String) {}
}

public struct AyuPluginBridgeLimits: Sendable {
    public var requestBytes = 262_144
    public var responseBytes = 262_144
    public var objectsPerPlugin = 256
    public var adapterStateBytesPerPlugin = 1_048_576
    public var commandsPerTransaction = 256
    public var pendingUICommands = 1024
    public var pendingUIBytes = 1_048_576
    public var decodedImageBytesPerPlugin = 8_388_608
    public var callbacksPerPlugin = 128
    public var settingsBytesPerPlugin = 65_536
    public var plugins = 32
    public init() {}
}

struct AyuBridgeRequest: Decodable {
    let version: Int
    let id: AyuBridgeValue
    let pluginID: String
    let operation: String
    let arguments: [String: AyuBridgeValue]
    enum CodingKeys: String, CodingKey {
        case version, id, operation, arguments
        case pluginID = "plugin_id"
    }
}

struct AyuBridgeResponse: Encodable {
    let version = 1
    let id: AyuBridgeValue
    let result: AyuBridgeValue?
    let error: AyuBridgeFailure?
}
