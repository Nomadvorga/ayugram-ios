import Foundation
import TelegramApiObjC

/// A function of this layer, found by its constructor id, for a request whose serialized bytes
/// the caller already has (the plugin bridge sends plugin-built functions unchanged).
public struct RawFunctionInfo {
    public let constructorId: Int32
    /// The schema name, as `FunctionDescription.name` gives it for a generated builder.
    public let name: String
    /// Name of the result type when the function returns one object (`Updates`), nil for a vector.
    public let resultTypeName: String?
    /// Describes the request by name only: its arguments are not decoded.
    public let description: FunctionDescription
}

private let rawFunctionIndexByConstructorId: [Int32: UInt32] = {
    var result: [Int32: UInt32] = [:]
    for index in 0 ..< TLApiFunctionCount {
        result[Int32(bitPattern: TLApiFunctionConstructorAt(index).pointee.constructorId)] = index
    }
    return result
}()

public extension Api {
    /// Nil when `constructorId` is not a function of the layer (a type constructor, or an id of
    /// another layer).
    static func rawFunction(constructorId: Int32) -> RawFunctionInfo? {
        guard let index = rawFunctionIndexByConstructorId[constructorId] else {
            return nil
        }
        let info = TLApiFunctionAt(index)
        let name = String(cString: info.pointee.constructor.name)
        var resultTypeName: String?
        if info.pointee.result.kind == .object, UInt32(info.pointee.result.typeIndex) < TLApiTypeCount {
            resultTypeName = String(cString: TLApiTypeAt(UInt32(info.pointee.result.typeIndex)).pointee.name)
        }
        return RawFunctionInfo(constructorId: constructorId, name: name, resultTypeName: resultTypeName, description: FunctionDescription(name: name, parameters: []))
    }
}

public extension TLObjectBacked {
    /// The constructor id of the value's current case, read from the schema table (nothing is serialized).
    var tlConstructorId: Int32 {
        return Int32(bitPattern: self.tlBackingObject.tl_constructorInfo.pointee.constructorId)
    }
}
