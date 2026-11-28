import Foundation
import UIKit

/// JSON-only boundary. Handles and callbacks are data, never Swift object addresses.
public indirect enum AyuBridgeValue: Codable, Equatable, Hashable, Sendable {
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
    public var bool: Bool? { if case let .bool(value) = self { return value }; return nil }
    public var number: Double? {
        switch self { case let .number(value): return value; case let .integer(value): return Double(value); default: return nil }
    }
    /// Strictly a floating-point payload, not an integer coercion.
    public var double: Double? { if case let .number(value) = self { return value }; return nil }
    /// A float without a fraction is accepted where an integer is expected, as Python's `4.0`
    /// always was by this host; an integer never passes through a double.
    public var integer: Int64? {
        switch self { case let .integer(value): return value; case let .number(value): return Int64(exactly: value); default: return nil }
    }
    public var array: [AyuBridgeValue]? { if case let .array(value) = self { return value }; return nil }
    public var object: [String: AyuBridgeValue]? { if case let .object(value) = self { return value }; return nil }
    public subscript(_ key: String) -> AyuBridgeValue { self.object?[key] ?? .null }

    /// Bridge helper: wraps any Codable bridge DTO into a JSON value.
    /// Encoding failures become `.null` — payloads were validated upstream.
    public static func encodable<T: Encodable>(_ value: T) -> AyuBridgeValue {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(AyuBridgeValue.self, from: data) else { return .null }
        return decoded
    }
}

/// Wire text. A number's spelling carries its type: `2` is an integer and `2.0` a float, as
/// Python reads and writes them. Foundation's coders read `2.0` as an integer and write the
/// double 2 as `2`, so text exchanged with Python and stored plugin values use this codec.
public enum AyuBridgeJSON {
    public static func decode(_ data: Data) throws -> AyuBridgeValue {
        try self.value(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Compact, `/` unescaped; throws for a nonfinite number.
    public static func encode(_ value: AyuBridgeValue) throws -> Data {
        var bytes: [UInt8] = []
        try self.write(value, into: &bytes)
        return Data(bytes)
    }

    private static func value(_ object: Any) throws -> AyuBridgeValue {
        switch object {
        case is NSNull: return .null
        case let text as String: return .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            // The parser gives a token with a fraction or exponent a floating type.
            switch String(cString: number.objCType) {
            case "c", "s", "i", "l", "q", "C", "S", "I", "L": return .integer(number.int64Value)
            case "Q":
                if let exact = Int64(exactly: number.uint64Value) { return .integer(exact) }
                return .number(number.doubleValue)
            default:
                guard number.doubleValue.isFinite else { throw AyuBridgeFailure("invalid_request", "Nonfinite JSON number") }
                return .number(number.doubleValue)
            }
        case let items as [Any]: return .array(try items.map(self.value))
        case let fields as [String: Any]: return .object(try fields.mapValues(self.value))
        default: throw AyuBridgeFailure("invalid_request", "Unsupported JSON value")
        }
    }

    private static func write(_ value: AyuBridgeValue, into bytes: inout [UInt8]) throws {
        switch value {
        case .null: bytes.append(contentsOf: "null".utf8)
        case let .bool(item): bytes.append(contentsOf: (item ? "true" : "false").utf8)
        case let .integer(item): bytes.append(contentsOf: String(item).utf8)
        case let .number(item):
            guard item.isFinite else { throw AyuBridgeFailure("invalid_arguments", "Nonfinite number") }
            // Swift's shortest round-trip spelling always has a fraction or an exponent.
            bytes.append(contentsOf: item.description.utf8)
        case let .string(item): self.write(item, into: &bytes)
        case let .array(items):
            bytes.append(0x5B)
            for (index, item) in items.enumerated() {
                if index > 0 { bytes.append(0x2C) }
                try self.write(item, into: &bytes)
            }
            bytes.append(0x5D)
        case let .object(fields):
            bytes.append(0x7B)
            var first = true
            for (key, item) in fields {
                if !first { bytes.append(0x2C) }
                first = false
                self.write(key, into: &bytes)
                bytes.append(0x3A)
                try self.write(item, into: &bytes)
            }
            bytes.append(0x7D)
        }
    }

    private static let hex = Array("0123456789abcdef".utf8)

    private static func write(_ text: String, into bytes: inout [UInt8]) {
        bytes.append(0x22)
        for byte in text.utf8 {
            switch byte {
            case 0x22: bytes.append(contentsOf: [0x5C, 0x22])
            case 0x5C: bytes.append(contentsOf: [0x5C, 0x5C])
            case 0x08: bytes.append(contentsOf: [0x5C, 0x62])
            case 0x09: bytes.append(contentsOf: [0x5C, 0x74])
            case 0x0A: bytes.append(contentsOf: [0x5C, 0x6E])
            case 0x0C: bytes.append(contentsOf: [0x5C, 0x66])
            case 0x0D: bytes.append(contentsOf: [0x5C, 0x72])
            case 0x00...0x1F: bytes.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, self.hex[Int(byte >> 4)], self.hex[Int(byte & 15)]])
            default: bytes.append(byte)
            }
        }
        bytes.append(0x22)
    }
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

/// The app owns the visible presenter. Plugin dialogs with custom views reserve
/// an immutable token so Python can dismiss only its own presentation.
public protocol AyuPluginDialogHost: AnyObject {
    func reserveDialogToken(_ token: String, pluginID: String) throws
    @MainActor func presentBridgeDialog(_ controller: UIViewController, token: String, pluginID: String) throws
    func dismissBridgeDialog(token: String, pluginID: String)
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
    /// `telegram.*` operations carry TL values: a request holds one 1 MiB value as base64 with its
    /// envelope (the C entry point's bound), a result fills the entry point's 1 MiB response.
    public var telegramRequestBytes = 1_572_864
    public var telegramResponseBytes = 1_048_576
    /// Arguments of a callback sent with an overflow substitute (a request response): a 4 MiB TL
    /// value as base64. With its envelope it stays inside the 6,000,000 characters the SDK reads.
    public var guaranteedCallbackBytes = 5_900_000
    public var objectsPerPlugin = 256
    public var adapterStateBytesPerPlugin = 1_048_576
    public var commandsPerTransaction = 256
    public var arrayElementsPerPlugin = 65_536
    public var arrayBytesPerPlugin = 1_048_576
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

extension AyuBridgeRequest {
    init(_ fields: [String: AyuBridgeValue]) throws {
        guard let version = fields["version"]?.integer, let id = fields["id"], let pluginID = fields["plugin_id"]?.string,
              let operation = fields["operation"]?.string, let arguments = fields["arguments"]?.object else {
            throw AyuBridgeFailure("invalid_request", "Malformed request or arguments")
        }
        self.version = Int(clamping: version); self.id = id; self.pluginID = pluginID; self.operation = operation; self.arguments = arguments
    }
}

struct AyuBridgeResponse: Encodable {
    let version = 1
    let id: AyuBridgeValue
    let result: AyuBridgeValue?
    let error: AyuBridgeFailure?

    var value: AyuBridgeValue {
        var fields: [String: AyuBridgeValue] = ["version": .integer(Int64(self.version)), "id": self.id]
        if let result = self.result { fields["result"] = result }
        if let error = self.error { fields["error"] = .object(["code": .string(error.code), "message": .string(error.message)]) }
        return .object(fields)
    }
}
