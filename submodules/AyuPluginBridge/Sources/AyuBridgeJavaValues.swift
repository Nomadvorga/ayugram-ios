import Foundation

/// Portable Java value/collection subsets. Unknown overloads fail explicitly.
/// No app selectors, Android services, networking, threads or native pointers.
enum AyuBridgeJavaValues {
    static var adapters: [AyuBridgeClassAdapter] {
        var result = [integer("java.lang.Integer", minimum: Int64(Int32.min), maximum: Int64(Int32.max), primitive: "int"),
                      integer("java.lang.Long", minimum: Int64.min, maximum: Int64.max, primitive: "long"),
                      self.boolean, self.arrayList, self.hashMap, self.atomicLong, self.atomicBoolean, self.system]
        result += ["int", "long", "boolean", "byte", "short", "char", "float", "double", "void"].map { AyuBridgeClassAdapter(name: $0) }
        return result.map { adapter in
            AyuBridgeClassAdapter(name: adapter.name, constants: adapter.constants, constructor: adapter.constructor,
                staticMethods: adapter.staticMethods, methods: adapter.methods, readableFields: adapter.readableFields,
                writableFields: adapter.writableFields, validateState: { state in
                    switch adapter.name {
                    case "java.util.ArrayList":
                        guard Set(state.keys) == ["values"], state["values"]?.array != nil else { throw AyuBridgeFailure("invalid_arguments", "Invalid list state") }
                    case "java.util.HashMap":
                        guard Set(state.keys) == ["entries"] else { throw AyuBridgeFailure("invalid_arguments", "Invalid map state") }
                        _ = try self.mapEntries(state)
                    case "java.lang.Integer", "java.lang.Long", "java.util.concurrent.atomic.AtomicLong":
                        guard Set(state.keys) == ["value"], let integer = state["value"]?.integer,
                              adapter.name != "java.lang.Integer" || (Int64(Int32.min)...Int64(Int32.max)).contains(integer) else { throw AyuBridgeFailure("invalid_arguments", "Invalid integer state") }
                    case "java.lang.Boolean", "java.util.concurrent.atomic.AtomicBoolean":
                        guard Set(state.keys) == ["value"], let value = state["value"], case .bool = value else { throw AyuBridgeFailure("invalid_arguments", "Invalid boolean state") }
                    default:
                        guard state.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Class does not have mutable state") }
                    }
                })
        }
    }

    static func arity(_ arguments: [AyuBridgeValue], _ count: Int) throws {
        guard arguments.count == count else { throw AyuBridgeFailure("invalid_arguments", "Unsupported Java overload") }
    }
    static func index(_ value: AyuBridgeValue, count: Int, insertion: Bool = false) throws -> Int {
        guard let index = value.integer, index >= 0, index < Int64(count) || (insertion && index == Int64(count)) else {
            throw AyuBridgeFailure("invalid_arguments", "Collection index out of range")
        }
        return Int(index)
    }
    static func number(_ value: AyuBridgeValue, minimum: Int64 = Int64.min, maximum: Int64 = Int64.max) throws -> Int64 {
        let result: Int64?
        if let integer = value.integer { result = integer }
        else if let text = value.string, !text.isEmpty, text.utf8.count <= 32,
                text.range(of: "^[+-]?[0-9]+$", options: .regularExpression) != nil { result = Int64(text) }
        else { result = nil }
        guard let result, result >= minimum, result <= maximum else { throw AyuBridgeFailure("invalid_arguments", "Expected bounded Java integer") }
        return result
    }

    static func integer(_ name: String, minimum: Int64, maximum: Int64, primitive: String) -> AyuBridgeClassAdapter {
        let parse: AyuBridgeClassAdapter.StaticMethod = { args, _ in
            try self.arity(args, 1)
            guard args[0].string != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected integer string") }
            return .value(.integer(try self.number(args[0], minimum: minimum, maximum: maximum)))
        }
        return AyuBridgeClassAdapter(name: name, constants: ["MIN_VALUE": .integer(minimum), "MAX_VALUE": .integer(maximum),
            "TYPE": .object(["$java_class": .string(primitive)])], constructor: { args, _ in
                try self.arity(args, 1); return ["value": .integer(try self.number(args[0], minimum: minimum, maximum: maximum))]
            }, staticMethods: [primitive == "int" ? "parseInt" : "parseLong": parse,
                "valueOf": { args, _ in
                    try self.arity(args, 1)
                    return .instance(className: name, state: ["value": .integer(try self.number(args[0], minimum: minimum, maximum: maximum))])
                }, "toString": { args, _ in
                    try self.arity(args, 1); return .value(.string(String(try self.number(args[0], minimum: minimum, maximum: maximum))))
                }], methods: ["longValue": { state, args, _ in try self.arity(args, 0); return .value(state["value"] ?? .null) },
                "intValue": { state, args, _ in
                    try self.arity(args, 0)
                    return .value(.integer(Int64(Int32(truncatingIfNeeded: try self.number(state["value"] ?? .null)))))
                }, "toString": { state, args, _ in
                    try self.arity(args, 0); return .value(.string(String(try self.number(state["value"] ?? .null))))
                }])
    }

    static func boolValue(_ value: AyuBridgeValue) throws -> Bool {
        if case let .bool(result) = value { return result }
        if let text = value.string { return text.lowercased() == "true" }
        throw AyuBridgeFailure("invalid_arguments", "Expected Java boolean or string")
    }
    static var boolean: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.lang.Boolean", constants: ["TYPE": .object(["$java_class": .string("boolean")])],
            constructor: { args, _ in try self.arity(args, 1); return ["value": .bool(try self.boolValue(args[0]))] },
            staticMethods: ["parseBoolean": { args, _ in try self.arity(args, 1); return .value(.bool(try self.boolValue(args[0]))) },
                "valueOf": { args, _ in try self.arity(args, 1); return .instance(className: "java.lang.Boolean", state: ["value": .bool(try self.boolValue(args[0]))]) }],
            methods: ["booleanValue": { state, args, _ in try self.arity(args, 0); return .value(state["value"] ?? .null) }])
    }

    static func list(_ value: AyuBridgeValue, _ context: AyuBridgeAdapterContext) throws -> [AyuBridgeValue] {
        if let values = value.array { return values }
        let snapshot = try context.snapshot(of: value)
        guard snapshot.className == "java.util.ArrayList" || AyuPluginNativeHost.primitiveArrayClassNames.contains(snapshot.className),
              let values = snapshot.state["values"]?.array else { throw AyuBridgeFailure("invalid_arguments", "Expected adapted list or array") }
        return values
    }
    static var arrayList: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.util.ArrayList", constructor: { args, context in
            if args.isEmpty { return ["values": .array([])] }
            try self.arity(args, 1)
            if let capacity = args[0].integer {
                guard (0...65_536).contains(capacity) else { throw AyuBridgeFailure("resource_limit", "Invalid list capacity") }
                return ["values": .array([])]
            }
            return ["values": .array(try self.list(args[0], context))]
        }, methods: [
            "size": { state, args, _ in try self.arity(args, 0); return .value(.integer(Int64(state["values"]?.array?.count ?? 0))) },
            "isEmpty": { state, args, _ in try self.arity(args, 0); return .value(.bool(state["values"]?.array?.isEmpty ?? true)) },
            "clear": { state, args, _ in try self.arity(args, 0); state["values"] = .array([]); return .value(.null) },
            "get": { state, args, _ in
                try self.arity(args, 1); let values = state["values"]?.array ?? []
                return .value(values[try self.index(args[0], count: values.count)])
            },
            "set": { state, args, _ in
                try self.arity(args, 2); var values = state["values"]?.array ?? []
                let index = try self.index(args[0], count: values.count); let old = values[index]
                values[index] = args[1]; state["values"] = .array(values); return .value(old)
            },
            "add": { state, args, _ in
                var values = state["values"]?.array ?? []
                if args.count == 1 { values.append(args[0]); state["values"] = .array(values); return .value(.bool(true)) }
                try self.arity(args, 2); values.insert(args[1], at: try self.index(args[0], count: values.count, insertion: true))
                state["values"] = .array(values); return .value(.null)
            },
            "addAll": { state, args, context in
                try self.arity(args, 1); let additions = try self.list(args[0], context)
                state["values"] = .array((state["values"]?.array ?? []) + additions); return .value(.bool(!additions.isEmpty))
            },
            "remove": { state, args, _ in
                try self.arity(args, 1); var values = state["values"]?.array ?? []
                if args[0].integer != nil {
                    let old = values.remove(at: try self.index(args[0], count: values.count)); state["values"] = .array(values); return .value(old)
                }
                guard let index = values.firstIndex(of: args[0]) else { return .value(.bool(false)) }
                values.remove(at: index); state["values"] = .array(values); return .value(.bool(true))
            },
            "contains": { state, args, _ in try self.arity(args, 1); return .value(.bool(state["values"]?.array?.contains(args[0]) ?? false)) },
            "indexOf": { state, args, _ in try self.arity(args, 1); return .value(.integer(Int64(state["values"]?.array?.firstIndex(of: args[0]) ?? -1))) },
            "toArray": { state, args, _ in try self.arity(args, 0); return .value(state["values"] ?? .array([])) }
        ])
    }

    // JSON objects require string keys, but Java maps do not. Preserve key types
    // using entry pairs; do not coerce account IDs or boolean keys into strings.
    static func mapEntries(_ state: [String: AyuBridgeValue]) throws -> [[AyuBridgeValue]] {
        guard let entries = state["entries"]?.array else { throw AyuBridgeFailure("invalid_arguments", "Invalid map state") }
        return try entries.map { value in
            guard let pair = value.array, pair.count == 2 else { throw AyuBridgeFailure("invalid_arguments", "Invalid map entry") }
            return pair
        }
    }
    static var hashMap: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.util.HashMap", constructor: { args, _ in
            try self.arity(args, 0); return ["entries": .array([])]
        }, methods: [
            "size": { state, args, _ in try self.arity(args, 0); return .value(.integer(Int64(state["entries"]?.array?.count ?? 0))) },
            "isEmpty": { state, args, _ in try self.arity(args, 0); return .value(.bool(state["entries"]?.array?.isEmpty ?? true)) },
            "clear": { state, args, _ in try self.arity(args, 0); state["entries"] = .array([]); return .value(.null) },
            "containsKey": { state, args, _ in
                try self.arity(args, 1); return .value(.bool(try self.mapEntries(state).contains { $0[0] == args[0] }))
            },
            "get": { state, args, _ in
                try self.arity(args, 1); return .value(try self.mapEntries(state).first { $0[0] == args[0] }?[1] ?? .null)
            },
            "put": { state, args, _ in
                try self.arity(args, 2); var entries = try self.mapEntries(state)
                let index = entries.firstIndex { $0[0] == args[0] }; let old = index.map { entries[$0][1] } ?? .null
                if let index { entries[index] = args } else { entries.append(args) }
                state["entries"] = .array(entries.map(AyuBridgeValue.array)); return .value(old)
            },
            "remove": { state, args, _ in
                try self.arity(args, 1); var entries = try self.mapEntries(state)
                guard let index = entries.firstIndex(where: { $0[0] == args[0] }) else { return .value(.null) }
                let old = entries.remove(at: index)[1]; state["entries"] = .array(entries.map(AyuBridgeValue.array)); return .value(old)
            }
        ])
    }

    static var atomicLong: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.util.concurrent.atomic.AtomicLong", constructor: { args, _ in
            guard args.count <= 1 else { throw AyuBridgeFailure("invalid_arguments", "Unsupported atomic constructor") }
            return ["value": .integer(try self.number(args.first ?? .integer(0)))]
        }, methods: [
            "get": { state, args, _ in try self.arity(args, 0); return .value(state["value"] ?? .integer(0)) },
            "set": { state, args, _ in try self.arity(args, 1); state["value"] = .integer(try self.number(args[0])); return .value(.null) },
            "getAndSet": { state, args, _ in try self.arity(args, 1); let old = state["value"] ?? .integer(0); state["value"] = .integer(try self.number(args[0])); return .value(old) },
            "incrementAndGet": { state, args, _ in try self.arity(args, 0); let result = try self.number(state["value"] ?? .integer(0)) &+ 1; state["value"] = .integer(result); return .value(.integer(result)) },
            "compareAndSet": { state, args, _ in
                try self.arity(args, 2); let expected = try self.number(args[0]); let next = try self.number(args[1])
                guard state["value"] == .integer(expected) else { return .value(.bool(false)) }
                state["value"] = .integer(next); return .value(.bool(true))
            }
        ])
    }
    static var atomicBoolean: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.util.concurrent.atomic.AtomicBoolean", constructor: { args, _ in
            guard args.count <= 1 else { throw AyuBridgeFailure("invalid_arguments", "Unsupported atomic constructor") }
            guard case let .bool(value) = args.first ?? .bool(false) else { throw AyuBridgeFailure("invalid_arguments", "Expected boolean") }
            return ["value": .bool(value)]
        }, methods: [
            "get": { state, args, _ in try self.arity(args, 0); return .value(state["value"] ?? .bool(false)) },
            "set": { state, args, _ in
                try self.arity(args, 1); guard case .bool = args[0] else { throw AyuBridgeFailure("invalid_arguments", "Expected boolean") }
                state["value"] = args[0]; return .value(.null)
            },
            "compareAndSet": { state, args, _ in
                try self.arity(args, 2); guard case .bool = args[0], case .bool = args[1] else { throw AyuBridgeFailure("invalid_arguments", "Expected boolean") }
                guard state["value"] == args[0] else { return .value(.bool(false)) }
                state["value"] = args[1]; return .value(.bool(true))
            }
        ])
    }

    static var system: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.lang.System", staticMethods: [
            "currentTimeMillis": { args, _ in
                try self.arity(args, 0); return .value(.integer(Int64(Date().timeIntervalSince1970 * 1000)))
            },
            "nanoTime": { args, _ in
                try self.arity(args, 0); return .value(.integer(Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)))
            }
        ])
    }
}
