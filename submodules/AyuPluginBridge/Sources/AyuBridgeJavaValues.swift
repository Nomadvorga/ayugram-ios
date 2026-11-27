import Foundation

/// Portable Java value/collection subsets. Unknown overloads fail explicitly.
/// No app selectors, Android services, networking, threads or native pointers.
enum AyuBridgeJavaValues {
    static var adapters: [AyuBridgeClassAdapter] {
        var result = [integer("java.lang.Byte", minimum: Int64(Int8.min), maximum: Int64(Int8.max), primitive: "byte", parseMethod: "parseByte"),
                      integer("java.lang.Short", minimum: Int64(Int16.min), maximum: Int64(Int16.max), primitive: "short", parseMethod: "parseShort"),
                      integer("java.lang.Integer", minimum: Int64(Int32.min), maximum: Int64(Int32.max), primitive: "int", parseMethod: "parseInt"),
                      integer("java.lang.Long", minimum: Int64.min, maximum: Int64.max, primitive: "long", parseMethod: "parseLong"),
                      self.boolean, self.float, self.object, self.weakReference, self.colorStateList, self.charSequence, self.spanned,
                      self.spannableString, self.spannableStringBuilder, self.styleSpan, self.underlineSpan, self.strikethroughSpan,
                      self.typefaceSpan, self.foregroundColorSpan, self.characterStyle, self.metricAffectingSpan,
                      self.updateAppearance, self.updateLayout, self.string, self.url, self.urlEncoder, self.scanner,
                      self.byteArrayOutputStream, self.collectionsSingletonList, self.collections,
                      self.arrayList, self.hashMap, self.atomicLong, self.atomicBoolean, self.system]
        result += ["int", "long", "boolean", "byte", "short", "char", "float", "double", "void"].map { AyuBridgeClassAdapter(name: $0) }
        return result.map { adapter in
            AyuBridgeClassAdapter(name: adapter.name, constants: adapter.constants, constructor: adapter.constructor,
                staticMethods: adapter.staticMethods, staticFields: adapter.staticFields, methods: adapter.methods,
                readableFields: adapter.readableFields, writableFields: adapter.writableFields,
                receiverMethods: adapter.receiverMethods, results: adapter.results, validateState: { state in
                    switch adapter.name {
                    case "java.lang.String":
                        guard Set(state.keys) == ["value"], let text = state["value"]?.string,
                              text.utf8.count <= Self.stringByteLimit else { throw AyuBridgeFailure("invalid_arguments", "Invalid Java String state") }
                    case "java.lang.Float":
                        guard Set(state.keys) == ["value"], let number = state["value"]?.number,
                              number.isFinite, Double(Float(number)).bitPattern == number.bitPattern else {
                            throw AyuBridgeFailure("invalid_arguments", "Invalid Java Float state")
                        }
                    case "java.lang.ref.WeakReference":
                        let hasNoTarget = state["target_handle"] == .null && state["target_class"] == .null
                        let hasValidTarget: Bool
                        if let handle = state["target_handle"]?.string, let className = state["target_class"]?.string {
                            hasValidTarget = UUID(uuidString: handle) != nil && className.utf8.count <= 256 &&
                                className.range(of: "^[A-Za-z][A-Za-z0-9_.$]*$", options: .regularExpression) != nil
                        } else {
                            hasValidTarget = false
                        }
                        guard Set(state.keys) == ["target_handle", "target_class"], hasNoTarget || hasValidTarget else {
                            throw AyuBridgeFailure("invalid_arguments", "Invalid weak reference state")
                        }
                    case "android.content.res.ColorStateList":
                        guard Set(state.keys) == ["color"], let color = state["color"]?.integer,
                              (Int64(Int32.min)...Int64(Int32.max)).contains(color) else {
                            throw AyuBridgeFailure("invalid_arguments", "Invalid ColorStateList state")
                        }
                    case "android.text.SpannableString", "android.text.SpannableStringBuilder":
                        guard Set(state.keys) == ["text", "spans"], let text = state["text"]?.string,
                              text.utf8.count <= Self.stringByteLimit else {
                            throw AyuBridgeFailure("invalid_arguments", "Invalid Spannable text state")
                        }
                        _ = try Self.spanRecords(state)
                    case "android.text.style.StyleSpan":
                        guard Set(state.keys) == ["style"], let style = state["style"]?.integer, (0...3).contains(style) else {
                            throw AyuBridgeFailure("invalid_arguments", "Invalid StyleSpan state")
                        }
                    case "android.text.style.TypefaceSpan":
                        guard Set(state.keys) == ["family"], let family = state["family"]?.string,
                              family.utf8.count <= 256 else { throw AyuBridgeFailure("invalid_arguments", "Invalid TypefaceSpan state") }
                    case "android.text.style.ForegroundColorSpan":
                        guard Set(state.keys) == ["color"], let color = state["color"]?.integer,
                              (Int64(Int32.min)...Int64(Int32.max)).contains(color) else {
                            throw AyuBridgeFailure("invalid_arguments", "Invalid ForegroundColorSpan state")
                        }
                    case "android.text.style.UnderlineSpan", "android.text.style.StrikethroughSpan":
                        guard state.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Invalid marker span state") }
                    case "java.net.URL":
                        guard Set(state.keys) == ["text", "protocol", "host", "authority", "port", "default_port", "path", "query", "ref", "file"],
                              let text = state["text"]?.string, text.utf8.count <= Self.urlByteLimit,
                              let scheme = state["protocol"]?.string, scheme == "http" || scheme == "https",
                              let host = state["host"]?.string, !host.isEmpty, host.utf8.count <= Self.urlByteLimit,
                              let authority = state["authority"]?.string, authority.utf8.count <= Self.urlByteLimit,
                              let port = state["port"]?.integer, (-1...65_535).contains(port),
                              let defaultPort = state["default_port"]?.integer, defaultPort == (scheme == "https" ? 443 : 80),
                              let path = state["path"]?.string, path.utf8.count <= Self.urlByteLimit,
                              Self.boundedOptionalString(state["query"], maximumBytes: Self.urlByteLimit),
                              Self.boundedOptionalString(state["ref"], maximumBytes: Self.urlByteLimit),
                              let file = state["file"]?.string, file.utf8.count <= Self.urlByteLimit else {
                            throw AyuBridgeFailure("invalid_arguments", "Invalid URL state")
                        }
                    case "java.util.Scanner":
                        guard Set(state.keys) == ["text", "cursor"], let text = state["text"]?.string,
                              text.utf8.count <= Self.stringByteLimit, let cursor = state["cursor"]?.integer,
                              cursor >= 0, cursor <= Int64((text as NSString).length) else {
                            throw AyuBridgeFailure("invalid_arguments", "Invalid Scanner state")
                        }
                    case "java.io.ByteArrayOutputStream":
                        guard Set(state.keys) == ["values"], let values = state["values"]?.array,
                              values.count <= Self.byteOutputLimit,
                              values.allSatisfy({ value in
                                  guard let integer = value.integer else { return false }
                                  return (0...255).contains(integer)
                              }) else {
                            throw AyuBridgeFailure("invalid_arguments", "Invalid byte output state")
                        }
                    case "java.util.Collections$SingletonList":
                        guard Set(state.keys) == ["value"] else { throw AyuBridgeFailure("invalid_arguments", "Invalid singleton list state") }
                    case "java.util.ArrayList":
                        guard Set(state.keys) == ["values"], state["values"]?.array != nil else { throw AyuBridgeFailure("invalid_arguments", "Invalid list state") }
                    case "java.util.HashMap":
                        guard Set(state.keys) == ["entries"] else { throw AyuBridgeFailure("invalid_arguments", "Invalid map state") }
                        _ = try self.mapEntries(state)
                    case "java.lang.Byte", "java.lang.Short", "java.lang.Integer", "java.lang.Long", "java.util.concurrent.atomic.AtomicLong":
                        guard Set(state.keys) == ["value"], let integer = state["value"]?.integer else {
                            throw AyuBridgeFailure("invalid_arguments", "Invalid integer state")
                        }
                        switch adapter.name {
                        case "java.lang.Byte":
                            guard (Int64(Int8.min)...Int64(Int8.max)).contains(integer) else { throw AyuBridgeFailure("invalid_arguments", "Invalid byte state") }
                        case "java.lang.Short":
                            guard (Int64(Int16.min)...Int64(Int16.max)).contains(integer) else { throw AyuBridgeFailure("invalid_arguments", "Invalid short state") }
                        case "java.lang.Integer":
                            guard (Int64(Int32.min)...Int64(Int32.max)).contains(integer) else { throw AyuBridgeFailure("invalid_arguments", "Invalid integer state") }
                        default: break
                        }
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
    private static func boundedOptionalString(_ value: AyuBridgeValue?, maximumBytes: Int) -> Bool {
        if value == .null { return true }
        guard let text = value?.string else { return false }
        return text.utf8.count <= maximumBytes
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

    static func integer(_ name: String, minimum: Int64, maximum: Int64, primitive: String, parseMethod: String) -> AyuBridgeClassAdapter {
        let parse: AyuBridgeClassAdapter.StaticMethod = { args, _ in
            try self.arity(args, 1)
            guard args[0].string != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected integer string") }
            return .value(.integer(try self.number(args[0], minimum: minimum, maximum: maximum)))
        }
        return AyuBridgeClassAdapter(name: name, constants: ["MIN_VALUE": .integer(minimum), "MAX_VALUE": .integer(maximum),
            "TYPE": .object(["$java_class": .string(primitive)])], constructor: { args, _ in
                try self.arity(args, 1); return ["value": .integer(try self.number(args[0], minimum: minimum, maximum: maximum))]
            }, staticMethods: [parseMethod: parse,
                "valueOf": { args, _ in
                    try self.arity(args, 1)
                    return .instance(className: name, state: ["value": .integer(try self.number(args[0], minimum: minimum, maximum: maximum))])
                }, "toString": { args, _ in
                    try self.arity(args, 1); return .value(.string(String(try self.number(args[0], minimum: minimum, maximum: maximum))))
                }], methods: ["longValue": { state, args, _ in try self.arity(args, 0); return .value(state["value"] ?? .null) },
                "intValue": { state, args, _ in
                    try self.arity(args, 0)
                    return .value(.integer(Int64(Int32(truncatingIfNeeded: try self.number(state["value"] ?? .null)))))
                }, "byteValue": { state, args, _ in
                    try self.arity(args, 0)
                    return .value(.integer(Int64(Int8(truncatingIfNeeded: try self.number(state["value"] ?? .null)))))
                }, "shortValue": { state, args, _ in
                    try self.arity(args, 0)
                    return .value(.integer(Int64(Int16(truncatingIfNeeded: try self.number(state["value"] ?? .null)))))
                }, "toString": { state, args, _ in
                    try self.arity(args, 0); return .value(.string(String(try self.number(state["value"] ?? .null))))
                }], results: ["valueOf": name])
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
            methods: ["booleanValue": { state, args, _ in try self.arity(args, 0); return .value(state["value"] ?? .null) }],
            results: ["valueOf": "java.lang.Boolean"])
    }

    private static func finiteFloat(_ value: AyuBridgeValue) throws -> Double {
        let raw: Double?
        if let number = value.number { raw = number }
        else if let integer = value.integer { raw = Double(integer) }
        else if let text = value.string, text.utf8.count <= 128 { raw = Double(text) }
        else { raw = nil }
        guard let raw, raw.isFinite else { throw AyuBridgeFailure.unsupported("Float non-finite or unsupported conversion") }
        let rounded = Float(raw)
        guard rounded.isFinite else { throw AyuBridgeFailure("invalid_arguments", "Float is out of range") }
        return Double(rounded)
    }

    static var float: AyuBridgeClassAdapter {
        let valueOf: AyuBridgeClassAdapter.StaticMethod = { args, _ in
            try Self.arity(args, 1)
            return .instance(className: "java.lang.Float", state: ["value": .number(try Self.finiteFloat(args[0]))])
        }
        return AyuBridgeClassAdapter(name: "java.lang.Float", constants: [
            "MIN_VALUE": .number(Double(Float.leastNonzeroMagnitude)),
            "MIN_NORMAL": .number(Double(Float.leastNormalMagnitude)),
            "MAX_VALUE": .number(Double(Float.greatestFiniteMagnitude)),
            "TYPE": .object(["$java_class": .string("float")]),
        ], constructor: { args, _ in
            try Self.arity(args, 1)
            return ["value": .number(try Self.finiteFloat(args[0]))]
        }, staticMethods: [
            "parseFloat": { args, _ in
                try Self.arity(args, 1)
                guard args[0].string != nil else { throw AyuBridgeFailure("invalid_arguments", "Float.parseFloat requires text") }
                return .value(.number(try Self.finiteFloat(args[0])))
            },
            "valueOf": valueOf,
        ], methods: [
            "floatValue": { state, args, _ in try Self.arity(args, 0); return .value(state["value"] ?? .null) },
        ], results: ["valueOf": "java.lang.Float"])
    }

    static var object: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.lang.Object", constructor: { args, _ in
            try Self.arity(args, 0)
            return [:]
        })
    }

    /// Marker interfaces used as array component types and bounded type checks.
    /// They intentionally do not expose arbitrary CharSequence/Spanned methods.
    static var charSequence: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.lang.CharSequence")
    }

    static var spanned: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.text.Spanned", constants: [
            "SPAN_INCLUSIVE_EXCLUSIVE": .integer(17),
            "SPAN_EXCLUSIVE_EXCLUSIVE": .integer(33),
            "SPAN_INCLUSIVE_INCLUSIVE": .integer(18),
            "SPAN_EXCLUSIVE_INCLUSIVE": .integer(34),
        ])
    }

    static var styleSpan: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.text.style.StyleSpan", constructor: { args, _ in
            try Self.arity(args, 1)
            guard let style = args[0].integer, (0...3).contains(style) else {
                throw AyuBridgeFailure("invalid_arguments", "StyleSpan requires a Typeface style from 0 through 3")
            }
            return ["style": .integer(style)]
        }, methods: ["getStyle": { state, args, _ in
            try Self.arity(args, 0)
            return .value(state["style"] ?? .null)
        }])
    }

    static var underlineSpan: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.text.style.UnderlineSpan", constructor: { args, _ in
            try Self.arity(args, 0)
            return [:]
        })
    }

    static var strikethroughSpan: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.text.style.StrikethroughSpan", constructor: { args, _ in
            try Self.arity(args, 0)
            return [:]
        })
    }

    static var typefaceSpan: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.text.style.TypefaceSpan", constructor: { args, _ in
            try Self.arity(args, 1)
            guard let family = args[0].string, family.utf8.count <= 256 else {
                throw AyuBridgeFailure("invalid_arguments", "TypefaceSpan requires a bounded family name")
            }
            return ["family": .string(family)]
        }, methods: ["getFamily": { state, args, _ in
            try Self.arity(args, 0)
            return .value(state["family"] ?? .null)
        }])
    }

    static var foregroundColorSpan: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.text.style.ForegroundColorSpan", constructor: { args, _ in
            try Self.arity(args, 1)
            guard let color = args[0].integer, (Int64(Int32.min)...Int64(Int32.max)).contains(color) else {
                throw AyuBridgeFailure("invalid_arguments", "ForegroundColorSpan requires a signed 32-bit color")
            }
            return ["color": .integer(color)]
        }, methods: ["getForegroundColor": { state, args, _ in
            try Self.arity(args, 0)
            return .value(state["color"] ?? .null)
        }])
    }

    static var characterStyle: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.text.style.CharacterStyle")
    }

    static var metricAffectingSpan: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.text.style.MetricAffectingSpan")
    }

    static var updateAppearance: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.text.style.UpdateAppearance")
    }

    static var updateLayout: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.text.style.UpdateLayout")
    }

    private static let spanStateKeys: Set<String> = ["span", "start", "end", "flags"]
    private static let supportedSpanClasses: Set<String> = [
        "android.text.style.StyleSpan", "android.text.style.UnderlineSpan", "android.text.style.StrikethroughSpan",
        "android.text.style.TypefaceSpan", "android.text.style.ForegroundColorSpan",
    ]
    private static let metricAffectingSpanClasses: Set<String> = ["android.text.style.StyleSpan", "android.text.style.TypefaceSpan"]

    private static func spanIsAssignable(_ actual: String, to requested: String) -> Bool {
        if actual == requested || requested == "java.lang.Object" { return true }
        if requested == "android.text.style.CharacterStyle" || requested == "android.text.style.UpdateAppearance" {
            return Self.supportedSpanClasses.contains(actual)
        }
        if requested == "android.text.style.MetricAffectingSpan" || requested == "android.text.style.UpdateLayout" {
            return Self.metricAffectingSpanClasses.contains(actual)
        }
        return false
    }

    private static func textArgument(_ value: AyuBridgeValue, _ context: AyuBridgeAdapterContext) throws -> (text: String, spans: [AyuBridgeValue]) {
        if let text = value.string {
            guard text.utf8.count <= Self.stringByteLimit else { throw AyuBridgeFailure("resource_limit", "Spannable text exceeds quota") }
            return (text, [])
        }
        let snapshot = try context.snapshot(of: value)
        guard ["java.lang.String", "android.text.SpannableString", "android.text.SpannableStringBuilder"].contains(snapshot.className),
              let text = snapshot.state["text"]?.string ?? snapshot.state["value"]?.string,
              text.utf8.count <= Self.stringByteLimit else {
            throw AyuBridgeFailure.unsupported("Spannable text constructor")
        }
        return (text, snapshot.state["spans"]?.array ?? [])
    }

    private static func spanRecords(_ state: [String: AyuBridgeValue]) throws -> [[String: AyuBridgeValue]] {
        guard let spans = state["spans"]?.array, spans.count <= 1_024,
              let text = state["text"]?.string, text.utf8.count <= Self.stringByteLimit else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid Spannable state")
        }
        let length = Int64((text as NSString).length)
        return try spans.map { value in
            guard let record = value.object, Set(record.keys) == Self.spanStateKeys,
                  record["span"]?.object?["$handle"]?.string != nil,
                  let start = record["start"]?.integer, let end = record["end"]?.integer,
                  let flags = record["flags"]?.integer, start >= 0, end >= start, end <= length,
                  (Int64(Int32.min)...Int64(Int32.max)).contains(flags) else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid Spannable span")
            }
            return record
        }
    }

    private static func spanIndex(_ value: AyuBridgeValue, _ records: [[String: AyuBridgeValue]]) -> Int? {
        records.firstIndex { $0["span"] == value }
    }

    private static func updatingSpansForReplacement(
        _ records: [[String: AyuBridgeValue]], start: Int, end: Int, replacementLength: Int
    ) -> [[String: AyuBridgeValue]] {
        let removedLength = end - start
        let delta = replacementLength - removedLength
        return records.compactMap { record in
            guard let oldStart = record["start"]?.integer, let oldEnd = record["end"]?.integer else { return nil }
            let spanStart = Int(oldStart), spanEnd = Int(oldEnd)
            if spanEnd <= start { return record }
            if spanStart >= end {
                var shifted = record
                shifted["start"] = .integer(Int64(spanStart + delta))
                shifted["end"] = .integer(Int64(spanEnd + delta))
                return shifted
            }
            if spanStart <= start && spanEnd >= end {
                var enclosing = record
                enclosing["end"] = .integer(Int64(spanEnd + delta))
                return enclosing
            }
            // Partial overlap is dropped instead of leaving stale or out-of-range metadata.
            return nil
        }
    }

    private static func offsetSpans(_ records: [[String: AyuBridgeValue]], by offset: Int) -> [[String: AyuBridgeValue]] {
        records.map { record in
            var shifted = record
            if let start = record["start"]?.integer { shifted["start"] = .integer(start + Int64(offset)) }
            if let end = record["end"]?.integer { shifted["end"] = .integer(end + Int64(offset)) }
            return shifted
        }
    }

    private static func boundedTextRange(_ args: [AyuBridgeValue], _ text: String) throws -> (Int, Int) {
        let source = text as NSString
        guard args.count == 2, let start = args[0].integer, let end = args[1].integer,
              start >= 0, end >= start, end <= Int64(source.length), start <= Int64(Int.max) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid Spannable range")
        }
        for boundaryValue in [Int(start), Int(end)] where boundaryValue > 0 && boundaryValue < source.length {
            let previous = source.character(at: boundaryValue - 1)
            let next = source.character(at: boundaryValue)
            guard !((0xD800...0xDBFF).contains(previous) && (0xDC00...0xDFFF).contains(next)) else {
                throw AyuBridgeFailure.unsupported("Spannable range splitting a surrogate pair")
            }
        }
        return (Int(start), Int(end))
    }

    private static func spannable(_ name: String, mutableText: Bool, requiresText: Bool) -> AyuBridgeClassAdapter {
        let constructor: AyuBridgeClassAdapter.Constructor = { args, context in
            if args.isEmpty && !requiresText { return ["text": .string(""), "spans": .array([])] }
            try Self.arity(args, 1)
            let value = try Self.textArgument(args[0], context)
            return ["text": .string(value.text), "spans": .array(value.spans)]
        }
        let textMethod: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            return .value(.string(state["text"]?.string ?? ""))
        }
        let lengthMethod: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            return .value(.integer(Int64(((state["text"]?.string ?? "") as NSString).length)))
        }
        let rangeText: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            let text = state["text"]?.string ?? ""
            let (start, end) = try Self.boundedTextRange(args, text)
            return .value(.string((text as NSString).substring(with: NSRange(location: start, length: end - start))))
        }
        var methods: [String: AyuBridgeClassAdapter.InstanceMethod] = [
            "length": lengthMethod,
            "toString": textMethod,
            "subSequence": rangeText,
            "getSpanStart": { state, args, _ in
                try Self.arity(args, 1)
                let records = try Self.spanRecords(state)
                return .value(.integer(records.first(where: { $0["span"] == args[0] })?["start"]?.integer ?? -1))
            },
            "getSpanEnd": { state, args, _ in
                try Self.arity(args, 1)
                let records = try Self.spanRecords(state)
                return .value(.integer(records.first(where: { $0["span"] == args[0] })?["end"]?.integer ?? -1))
            },
            "getSpanFlags": { state, args, _ in
                try Self.arity(args, 1)
                let records = try Self.spanRecords(state)
                return .value(.integer(records.first(where: { $0["span"] == args[0] })?["flags"]?.integer ?? 0))
            },
            "removeSpan": { state, args, _ in
                try Self.arity(args, 1)
                var records = try Self.spanRecords(state)
                records.removeAll { $0["span"] == args[0] }
                state["spans"] = .array(records.map(AyuBridgeValue.object))
                return .value(.null)
            },
            "setSpan": { state, args, context in
                guard args.count == 4, args[0].object?["$handle"]?.string != nil else {
                    throw AyuBridgeFailure("invalid_arguments", "Spannable.setSpan requires an owned span")
                }
                let spanSnapshot = try context.snapshot(of: args[0])
                guard Self.supportedSpanClasses.contains(spanSnapshot.className) else {
                    throw AyuBridgeFailure.unsupported("Spannable span class " + spanSnapshot.className)
                }
                var records = try Self.spanRecords(state)
                let (start, end) = try Self.boundedTextRange(Array(args[1...2]), state["text"]?.string ?? "")
                guard let flags = args[3].integer,
                      (Int64(Int32.min)...Int64(Int32.max)).contains(flags) else {
                    throw AyuBridgeFailure("invalid_arguments", "Invalid Spannable span range")
                }
                let record: [String: AyuBridgeValue] = ["span": args[0], "start": .integer(Int64(start)), "end": .integer(Int64(end)), "flags": .integer(flags)]
                if let index = Self.spanIndex(args[0], records) { records[index] = record } else {
                    guard records.count < 1_024 else { throw AyuBridgeFailure("resource_limit", "Too many Spannable spans") }
                    records.append(record)
                }
                state["spans"] = .array(records.map(AyuBridgeValue.object))
                return .value(.null)
            },
            "getSpans": { state, args, context in
                guard args.count == 3, let requested = args[2].object?["$java_class"]?.string else {
                    throw AyuBridgeFailure("invalid_arguments", "Spannable.getSpans requires a class reference")
                }
                let text = state["text"]?.string ?? ""
                let (start, end) = try Self.boundedTextRange(Array(args[0...1]), text)
                let records = try Self.spanRecords(state)
                var result: [AyuBridgeValue] = []
                for record in records {
                    guard let span = record["span"], let spanStart = record["start"]?.integer, let spanEnd = record["end"]?.integer else { continue }
                    guard spanEnd > Int64(start) && spanStart < Int64(end) else { continue }
                    let snapshot = try context.snapshot(of: span)
                    if Self.spanIsAssignable(snapshot.className, to: requested) { result.append(span) }
                }
                return .value(.array(result))
            },
        ]
        var receiverMethods: Set<String> = []
        if mutableText {
            methods["append"] = { state, args, context in
                try Self.arity(args, 1)
                let value = try Self.textArgument(args[0], context)
                var text = state["text"]?.string ?? ""
                guard text.utf8.count <= Self.stringByteLimit - value.text.utf8.count else { throw AyuBridgeFailure("resource_limit", "Spannable text exceeds quota") }
                let records = try Self.spanRecords(state)
                guard records.count <= 1_024 - value.spans.count else { throw AyuBridgeFailure("resource_limit", "Too many Spannable spans") }
                let additions = try Self.spanRecords(["text": .string(value.text), "spans": .array(value.spans)])
                let offset = (text as NSString).length
                text.append(value.text); state["text"] = .string(text)
                state["spans"] = .array((records + Self.offsetSpans(additions, by: offset)).map(AyuBridgeValue.object))
                return .instance(className: name, state: state)
            }
            methods["replace"] = { state, args, context in
                guard args.count == 3 else { throw AyuBridgeFailure.unsupported("SpannableStringBuilder.replace overload") }
                let text = state["text"]?.string ?? ""; let (start, end) = try Self.boundedTextRange(Array(args[0...1]), text)
                let value = try Self.textArgument(args[2], context)
                let replacement = (text as NSString).replacingCharacters(in: NSRange(location: start, length: end - start), with: value.text)
                guard replacement.utf8.count <= Self.stringByteLimit else { throw AyuBridgeFailure("resource_limit", "Spannable text exceeds quota") }
                let records = try Self.spanRecords(state)
                let retained = Self.updatingSpansForReplacement(records, start: start, end: end, replacementLength: (value.text as NSString).length)
                guard retained.count <= 1_024 - value.spans.count else { throw AyuBridgeFailure("resource_limit", "Too many Spannable spans") }
                let additions = try Self.spanRecords(["text": .string(value.text), "spans": .array(value.spans)])
                state["text"] = .string(replacement)
                state["spans"] = .array((retained + Self.offsetSpans(additions, by: start)).map(AyuBridgeValue.object))
                return .instance(className: name, state: state)
            }
            methods["delete"] = { state, args, _ in
                let text = state["text"]?.string ?? ""; let (start, end) = try Self.boundedTextRange(args, text)
                let records = try Self.spanRecords(state)
                state["text"] = .string((text as NSString).replacingCharacters(in: NSRange(location: start, length: end - start), with: ""))
                state["spans"] = .array(Self.updatingSpansForReplacement(records, start: start, end: end, replacementLength: 0).map(AyuBridgeValue.object))
                return .instance(className: name, state: state)
            }
            receiverMethods.formUnion(["append", "replace", "delete"])
        }
        return AyuBridgeClassAdapter(name: name, constructor: constructor, methods: methods, receiverMethods: receiverMethods,
                                     results: Dictionary(uniqueKeysWithValues: receiverMethods.map { ($0, name) }))
    }

    static var spannableString: AyuBridgeClassAdapter { self.spannable("android.text.SpannableString", mutableText: false, requiresText: true) }
    static var spannableStringBuilder: AyuBridgeClassAdapter { self.spannable("android.text.SpannableStringBuilder", mutableText: true, requiresText: false) }

    static var weakReference: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.lang.ref.WeakReference", constructor: { args, context in
            try Self.arity(args, 1)
            guard args[0] == .null || args[0].object?["$handle"]?.string != nil else {
                throw AyuBridgeFailure.unsupported("WeakReference target")
            }
            guard args[0] != .null else { return ["target_handle": .null, "target_class": .null] }
            let snapshot = try context.snapshot(of: args[0])
            guard let reference = args[0].object, let handle = reference["$handle"]?.string,
                  reference["$class"]?.string == snapshot.className else {
                throw AyuBridgeFailure("invalid_arguments", "WeakReference requires a typed owned target")
            }
            return ["target_handle": .string(handle), "target_class": .string(snapshot.className)]
        }, methods: [
            "get": { state, args, context in
                try Self.arity(args, 0)
                guard let handle = state["target_handle"]?.string, let className = state["target_class"]?.string else {
                    return .value(.null)
                }
                let reference = AyuBridgeValue.object(["$handle": .string(handle), "$class": .string(className)])
                do {
                    let snapshot = try context.snapshot(of: reference)
                    guard snapshot.className == className else { throw AyuBridgeFailure("invalid_arguments", "WeakReference target type changed") }
                    return .value(reference)
                } catch let failure as AyuBridgeFailure where failure.code == "INVALID_HANDLE" {
                    return .value(.null)
                }
            },
            "clear": { state, args, _ in
                try Self.arity(args, 0)
                state["target_handle"] = .null; state["target_class"] = .null
                return .value(.null)
            },
            "isEnqueued": { state, args, _ in try Self.arity(args, 0); return .value(.bool(false)) },
        ])
    }

    static var colorStateList: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.content.res.ColorStateList", staticMethods: [
            "valueOf": { args, _ in
                try Self.arity(args, 1)
                guard let color = args[0].integer, (Int64(Int32.min)...Int64(Int32.max)).contains(color) else {
                    throw AyuBridgeFailure("invalid_arguments", "ColorStateList.valueOf requires a signed 32-bit color")
                }
                return .instance(className: "android.content.res.ColorStateList", state: ["color": .integer(color)])
            },
        ], methods: [
            "getDefaultColor": { state, args, _ in
                try Self.arity(args, 0)
                return .value(state["color"] ?? .null)
            },
            "isStateful": { _, args, _ in
                try Self.arity(args, 0)
                return .value(.bool(false))
            },
            "getColorForState": { state, args, context in
                try Self.arity(args, 2)
                let states = try context.snapshot(of: args[0])
                guard states.className == "[I", states.state["component"] == .string("int"),
                      states.state["values"]?.array != nil,
                      let fallback = args[1].integer, (Int64(Int32.min)...Int64(Int32.max)).contains(fallback) else {
                    throw AyuBridgeFailure("invalid_arguments", "ColorStateList.getColorForState requires int[] and int")
                }
                return .value(state["color"] ?? .null)
            },
        ], results: ["valueOf": "android.content.res.ColorStateList"])
    }

    private static let stringByteLimit = 65_536

    private static func javaString(_ value: AyuBridgeValue) throws -> String {
        if let text = value.string {
            guard text.utf8.count <= Self.stringByteLimit else { throw AyuBridgeFailure("resource_limit", "Java String exceeds quota") }
            return text
        }
        if let integer = value.integer { return String(integer) }
        if let boolean = value.bool { return boolean ? "true" : "false" }
        if value == .null { return "null" }
        throw AyuBridgeFailure.unsupported("String conversion")
    }

    private static func stringState(_ value: String) throws -> [String: AyuBridgeValue] {
        guard value.utf8.count <= Self.stringByteLimit else { throw AyuBridgeFailure("resource_limit", "Java String exceeds quota") }
        return ["value": .string(value)]
    }

    private static func javaStringEquals(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    private static func javaStringContains(_ text: String, _ needle: String) -> Bool {
        let textUnits = Array(text.utf16)
        let needleUnits = Array(needle.utf16)
        guard needleUnits.count <= textUnits.count else { return false }
        if needleUnits.isEmpty { return true }

        // KMP keeps worst-case work linear even for repeated prefixes at the
        // maximum supported string quota.
        var prefixLengths = Array(repeating: 0, count: needleUnits.count)
        var prefix = 0
        for index in 1..<needleUnits.count {
            while prefix > 0, needleUnits[index] != needleUnits[prefix] {
                prefix = prefixLengths[prefix - 1]
            }
            if needleUnits[index] == needleUnits[prefix] { prefix += 1 }
            prefixLengths[index] = prefix
        }

        var matched = 0
        for unit in textUnits {
            while matched > 0, unit != needleUnits[matched] {
                matched = prefixLengths[matched - 1]
            }
            if unit == needleUnits[matched] { matched += 1 }
            if matched == needleUnits.count { return true }
        }
        return false
    }

    static var string: AyuBridgeClassAdapter {
        let validateText: @Sendable (String) throws -> String = { text in
            guard text.utf8.count <= Self.stringByteLimit else { throw AyuBridgeFailure("resource_limit", "Java String exceeds quota") }
            return text
        }
        let substring: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            guard args.count == 1 || args.count == 2,
                  let startValue = args[0].integer,
                  startValue >= 0, startValue <= Int64(Int.max) else {
                throw AyuBridgeFailure.unsupported("String.substring overload")
            }
            let text = try validateText(state["value"]?.string ?? "")
            let source = text as NSString
            let start = Int(startValue)
            let end: Int
            if args.count == 1 {
                end = source.length
            } else {
                guard let endValue = args[1].integer, endValue >= startValue, endValue <= Int64(Int.max) else {
                    throw AyuBridgeFailure("invalid_arguments", "String substring range is invalid")
                }
                end = Int(endValue)
            }
            guard end <= source.length else { throw AyuBridgeFailure("invalid_arguments", "String substring range is out of bounds") }
            // A wire String is Unicode; do not silently split a UTF-16 surrogate pair.
            func splitsSurrogatePair(_ index: Int) -> Bool {
                guard index > 0, index < source.length else { return false }
                let before = source.character(at: index - 1)
                let after = source.character(at: index)
                return (0xD800...0xDBFF).contains(before) && (0xDC00...0xDFFF).contains(after)
            }
            guard !splitsSurrogatePair(start), !splitsSurrogatePair(end) else {
                throw AyuBridgeFailure.unsupported("String substring splitting a surrogate pair")
            }
            let result = source.substring(with: NSRange(location: start, length: end - start))
            return .value(.string(try validateText(result)))
        }
        return AyuBridgeClassAdapter(name: "java.lang.String", constructor: { args, context in
            switch args.count {
            case 0: return ["value": .string("")]
            case 1:
                if let text = args[0].string { return try Self.stringState(text) }
                let snapshot = try context.snapshot(of: args[0])
                guard snapshot.className == "[C", let values = snapshot.state["values"]?.array,
                      values.allSatisfy({ $0.string?.utf16.count == 1 }) else {
                    throw AyuBridgeFailure.unsupported("String constructor overload")
                }
                return try Self.stringState(values.compactMap(\.string).joined())
            default: throw AyuBridgeFailure.unsupported("String constructor overload")
            }
        }, staticMethods: [
            "valueOf": { args, _ in
                try Self.arity(args, 1)
                return .value(.string(try Self.javaString(args[0])))
            },
        ], methods: [
            "length": { state, args, _ in
                try Self.arity(args, 0)
                let text = try validateText(state["value"]?.string ?? "")
                return .value(.integer(Int64(text.utf16.count)))
            },
            "isEmpty": { state, args, _ in
                try Self.arity(args, 0)
                return .value(.bool(try validateText(state["value"]?.string ?? "").isEmpty))
            },
            "toString": { state, args, _ in
                try Self.arity(args, 0)
                return .value(.string(try validateText(state["value"]?.string ?? "")))
            },
            "equals": { state, args, context in
                try Self.arity(args, 1)
                let lhs = try validateText(state["value"]?.string ?? "")
                if let rhs = args[0].string { return .value(.bool(Self.javaStringEquals(lhs, try validateText(rhs)))) }
                guard args[0].object?["$handle"]?.string != nil else { return .value(.bool(false)) }
                let snapshot = try context.snapshot(of: args[0])
                guard snapshot.className == "java.lang.String", let rhs = snapshot.state["value"]?.string else {
                    return .value(.bool(false))
                }
                return .value(.bool(Self.javaStringEquals(lhs, rhs)))
            },
            "contains": { state, args, _ in
                try Self.arity(args, 1)
                guard let needle = args[0].string else { throw AyuBridgeFailure("invalid_arguments", "String.contains requires text") }
                let text = try validateText(state["value"]?.string ?? "")
                return .value(.bool(Self.javaStringContains(text, try validateText(needle))))
            },
            "startsWith": { state, args, _ in
                try Self.arity(args, 1)
                guard let prefix = args[0].string else { throw AyuBridgeFailure("invalid_arguments", "String.startsWith requires text") }
                let textUnits = Array(try validateText(state["value"]?.string ?? "").utf16)
                let prefixUnits = Array(try validateText(prefix).utf16)
                return .value(.bool(textUnits.starts(with: prefixUnits)))
            },
            "endsWith": { state, args, _ in
                try Self.arity(args, 1)
                guard let suffix = args[0].string else { throw AyuBridgeFailure("invalid_arguments", "String.endsWith requires text") }
                let textUnits = Array(try validateText(state["value"]?.string ?? "").utf16)
                let suffixUnits = Array(try validateText(suffix).utf16)
                return .value(.bool(textUnits.suffix(suffixUnits.count).elementsEqual(suffixUnits)))
            },
            "compareTo": { state, args, _ in
                try Self.arity(args, 1)
                guard let other = args[0].string else { throw AyuBridgeFailure("invalid_arguments", "String.compareTo requires text") }
                let lhs = Array(try validateText(state["value"]?.string ?? "").utf16)
                let rhs = Array(try validateText(other).utf16)
                for (left, right) in zip(lhs, rhs) where left != right {
                    return .value(.integer(Int64(Int32(left) - Int32(right))))
                }
                return .value(.integer(Int64(lhs.count - rhs.count)))
            },
            "hashCode": { state, args, _ in
                try Self.arity(args, 0)
                let text = try validateText(state["value"]?.string ?? "")
                var hash: Int32 = 0
                for unit in text.utf16 { hash = hash &* 31 &+ Int32(unit) }
                return .value(.integer(Int64(hash)))
            },
            "trim": { state, args, _ in
                try Self.arity(args, 0)
                let source = (try validateText(state["value"]?.string ?? "")) as NSString
                var start = 0
                var end = source.length
                while start < end && source.character(at: start) <= 0x20 { start += 1 }
                while end > start && source.character(at: end - 1) <= 0x20 { end -= 1 }
                return .value(.string(source.substring(with: NSRange(location: start, length: end - start))))
            },
            "concat": { state, args, _ in
                try Self.arity(args, 1)
                guard let other = args[0].string else { throw AyuBridgeFailure("invalid_arguments", "String.concat requires text") }
                let text = try validateText(state["value"]?.string ?? "")
                let suffix = try validateText(other)
                guard text.utf8.count <= Self.stringByteLimit - suffix.utf8.count else {
                    throw AyuBridgeFailure("resource_limit", "Java String exceeds quota")
                }
                return .value(.string(text + suffix))
            },
            "substring": substring,
        ])
    }

    private static let urlByteLimit = 8_192

    private static func urlState(_ text: String) throws -> [String: AyuBridgeValue] {
        guard text.utf8.count <= Self.urlByteLimit,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: text),
              let rawScheme = components.scheme, let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let encodedHost = components.percentEncodedHost else {
            throw AyuBridgeFailure("invalid_arguments", "Expected a bounded absolute HTTP(S) URL without user-info")
        }
        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw AyuBridgeFailure.unsupported("URL protocol")
        }
        if let port = components.port, !(0...65_535).contains(port) {
            throw AyuBridgeFailure("invalid_arguments", "URL port is out of range")
        }
        let path = components.percentEncodedPath
        let query = components.percentEncodedQuery
        let fragment = components.percentEncodedFragment
        let file = path + (query.map { "?" + $0 } ?? "")
        let authority = encodedHost + (components.port.map { ":\($0)" } ?? "")
        return [
            "text": .string(text), "protocol": .string(scheme), "host": .string(host),
            "authority": .string(authority), "port": .integer(Int64(components.port ?? -1)),
            "default_port": .integer(scheme == "https" ? 443 : 80), "path": .string(path),
            "query": query.map(AyuBridgeValue.string) ?? .null,
            "ref": fragment.map(AyuBridgeValue.string) ?? .null, "file": .string(file),
        ]
    }

    static var url: AyuBridgeClassAdapter {
        let textMethod: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            return .value(state["text"] ?? .null)
        }
        let stringMethod: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            return .value(state["text"] ?? .null)
        }
        return AyuBridgeClassAdapter(name: "java.net.URL", constructor: { args, _ in
            try Self.arity(args, 1)
            guard let text = args[0].string else { throw AyuBridgeFailure.unsupported("URL constructor overload") }
            return try Self.urlState(text)
        }, methods: [
            "getProtocol": { state, args, _ in try Self.arity(args, 0); return .value(state["protocol"] ?? .null) },
            "getHost": { state, args, _ in try Self.arity(args, 0); return .value(state["host"] ?? .null) },
            "getAuthority": { state, args, _ in try Self.arity(args, 0); return .value(state["authority"] ?? .null) },
            "getPort": { state, args, _ in try Self.arity(args, 0); return .value(state["port"] ?? .integer(-1)) },
            "getDefaultPort": { state, args, _ in try Self.arity(args, 0); return .value(state["default_port"] ?? .integer(-1)) },
            "getPath": { state, args, _ in try Self.arity(args, 0); return .value(state["path"] ?? .string("")) },
            "getQuery": { state, args, _ in try Self.arity(args, 0); return .value(state["query"] ?? .null) },
            "getRef": { state, args, _ in try Self.arity(args, 0); return .value(state["ref"] ?? .null) },
            "getFile": { state, args, _ in try Self.arity(args, 0); return .value(state["file"] ?? .string("")) },
            "toExternalForm": textMethod,
            "toString": stringMethod,
        ])
    }

    static var urlEncoder: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.net.URLEncoder", staticMethods: [
            "encode": { args, _ in
                guard args.count == 1 || args.count == 2, let text = args[0].string,
                      text.utf8.count <= Self.stringByteLimit else {
                    throw AyuBridgeFailure.unsupported("URLEncoder.encode overload")
                }
                if args.count == 2 {
                    guard let charset = args[1].string, ["UTF-8", "UTF8"].contains(charset.uppercased()) else {
                        throw AyuBridgeFailure.unsupported("URLEncoder charset")
                    }
                }
                var encoded = [UInt8]()
                encoded.reserveCapacity(min(Self.stringByteLimit, text.utf8.count * 3))
                let hex = Array("0123456789ABCDEF".utf8)
                for byte in text.utf8 {
                    switch byte {
                    case 65...90, 97...122, 48...57, 45, 95, 46, 42:
                        encoded.append(byte)
                    case 32:
                        encoded.append(43)
                    default:
                        encoded.append(37)
                        encoded.append(hex[Int(byte >> 4)])
                        encoded.append(hex[Int(byte & 0x0F)])
                    }
                    guard encoded.count <= Self.stringByteLimit else {
                        throw AyuBridgeFailure("resource_limit", "Encoded URL exceeds quota")
                    }
                }
                return .value(.string(String(decoding: encoded, as: UTF8.self)))
            },
        ])
    }

    private static func scannerWhitespace(_ unit: unichar) -> Bool {
        unit == 0x20 || (0x09...0x0D).contains(unit)
    }

    private static func scannerToken(_ state: [String: AyuBridgeValue]) throws -> (text: String, end: Int)? {
        guard let text = state["text"]?.string, let rawCursor = state["cursor"]?.integer,
              rawCursor >= 0, rawCursor <= Int64(Int.max) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid Scanner state")
        }
        let source = text as NSString
        var index = Int(rawCursor)
        while index < source.length && Self.scannerWhitespace(source.character(at: index)) { index += 1 }
        guard index < source.length else { return nil }
        let start = index
        while index < source.length && !Self.scannerWhitespace(source.character(at: index)) { index += 1 }
        return (source.substring(with: NSRange(location: start, length: index - start)), index)
    }

    static var scanner: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.util.Scanner", constructor: { args, context in
            try Self.arity(args, 1)
            let text: String
            if let raw = args[0].string {
                text = raw
            } else {
                let snapshot = try context.snapshot(of: args[0])
                guard snapshot.className == "java.lang.String", let value = snapshot.state["value"]?.string else {
                    throw AyuBridgeFailure.unsupported("Scanner input constructor")
                }
                text = value
            }
            guard text.utf8.count <= Self.stringByteLimit else { throw AyuBridgeFailure("resource_limit", "Scanner input exceeds quota") }
            return ["text": .string(text), "cursor": .integer(0)]
        }, methods: [
            "hasNext": { state, args, _ in try Self.arity(args, 0); return .value(.bool(try Self.scannerToken(state) != nil)) },
            "next": { state, args, _ in
                try Self.arity(args, 0)
                guard let token = try Self.scannerToken(state) else { throw AyuBridgeFailure("invalid_state", "Scanner has no next token") }
                state["cursor"] = .integer(Int64(token.end))
                return .value(.string(token.text))
            },
            "hasNextLine": { state, args, _ in
                try Self.arity(args, 0)
                let length = ((state["text"]?.string ?? "") as NSString).length
                return .value(.bool(length > Int(state["cursor"]?.integer ?? 0)))
            },
            "nextLine": { state, args, _ in
                try Self.arity(args, 0)
                guard let text = state["text"]?.string, let rawCursor = state["cursor"]?.integer else {
                    throw AyuBridgeFailure("invalid_arguments", "Invalid Scanner state")
                }
                let source = text as NSString
                var index = Int(rawCursor)
                guard index < source.length else { throw AyuBridgeFailure("invalid_state", "Scanner has no next line") }
                let start = index
                while index < source.length {
                    let unit = source.character(at: index)
                    if unit == 0x0A || unit == 0x0D { break }
                    index += 1
                }
                let line = source.substring(with: NSRange(location: start, length: index - start))
                if index < source.length, source.character(at: index) == 0x0D { index += 1 }
                if index < source.length, source.character(at: index) == 0x0A { index += 1 }
                state["cursor"] = .integer(Int64(index))
                return .value(.string(line))
            },
            "hasNextInt": { state, args, _ in
                try Self.arity(args, 0)
                return .value(.bool(try Self.scannerToken(state).flatMap { Int32($0.text) } != nil))
            },
            "nextInt": { state, args, _ in
                try Self.arity(args, 0)
                guard let token = try Self.scannerToken(state), let value = Int32(token.text) else {
                    throw AyuBridgeFailure("invalid_state", "Scanner token is not a signed 32-bit integer")
                }
                state["cursor"] = .integer(Int64(token.end))
                return .value(.integer(Int64(value)))
            },
            "hasNextLong": { state, args, _ in
                try Self.arity(args, 0)
                return .value(.bool(try Self.scannerToken(state).flatMap { Int64($0.text) } != nil))
            },
            "nextLong": { state, args, _ in
                try Self.arity(args, 0)
                guard let token = try Self.scannerToken(state), let value = Int64(token.text) else {
                    throw AyuBridgeFailure("invalid_state", "Scanner token is not a signed 64-bit integer")
                }
                state["cursor"] = .integer(Int64(token.end))
                return .value(.integer(value))
            },
            "hasNextBoolean": { state, args, _ in
                try Self.arity(args, 0)
                guard let token = try Self.scannerToken(state)?.text.lowercased() else { return .value(.bool(false)) }
                return .value(.bool(token == "true" || token == "false"))
            },
            "nextBoolean": { state, args, _ in
                try Self.arity(args, 0)
                guard let token = try Self.scannerToken(state), ["true", "false"].contains(token.text.lowercased()) else {
                    throw AyuBridgeFailure("invalid_state", "Scanner token is not a boolean")
                }
                state["cursor"] = .integer(Int64(token.end))
                return .value(.bool(token.text.lowercased() == "true"))
            },
        ])
    }

    private static let byteOutputLimit = 65_536

    private static func outputByte(_ value: AyuBridgeValue) throws -> Int64 {
        guard let integer = value.integer, (Int64(Int32.min)...Int64(Int32.max)).contains(integer) else {
            throw AyuBridgeFailure("invalid_arguments", "Expected bounded byte output value")
        }
        return Int64(UInt8(truncatingIfNeeded: Int32(integer)))
    }

    private static func outputBytes(_ value: AyuBridgeValue, _ context: AyuBridgeAdapterContext) throws -> [Int64] {
        let snapshot = try context.snapshot(of: value)
        guard snapshot.className == "[B", snapshot.state["component"] == .string("byte"),
              let values = snapshot.state["values"]?.array else {
            throw AyuBridgeFailure.unsupported("ByteArrayOutputStream byte[] overload")
        }
        return try values.map(Self.outputByte)
    }

    static var byteArrayOutputStream: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.io.ByteArrayOutputStream", constructor: { args, _ in
            guard args.isEmpty || args.count == 1 else { throw AyuBridgeFailure.unsupported("ByteArrayOutputStream constructor overload") }
            if let capacity = args.first?.integer {
                guard (0...Int64(Self.byteOutputLimit)).contains(capacity) else { throw AyuBridgeFailure("resource_limit", "Byte output capacity exceeds quota") }
            } else if !args.isEmpty {
                throw AyuBridgeFailure("invalid_arguments", "Expected byte output capacity")
            }
            return ["values": .array([])]
        }, methods: [
            "size": { state, args, _ in
                try Self.arity(args, 0)
                return .value(.integer(Int64(state["values"]?.array?.count ?? 0)))
            },
            "write": { state, args, context in
                guard args.count == 1 || args.count == 3 else { throw AyuBridgeFailure("invalid_arguments", "Unsupported byte output write overload") }
                var values = state["values"]?.array ?? []
                let additions: [Int64]
                if args.count == 1 {
                    additions = [try Self.outputByte(args[0])]
                } else {
                    let bytes = try Self.outputBytes(args[0], context)
                    guard let offset = args[1].integer, let length = args[2].integer,
                          offset >= 0, length >= 0, offset <= Int64(bytes.count),
                          length <= Int64(bytes.count) - offset else {
                        throw AyuBridgeFailure("invalid_arguments", "Byte output range is out of bounds")
                    }
                    additions = Array(bytes[Int(offset)..<Int(offset + length)])
                }
                guard additions.count <= Self.byteOutputLimit - values.count else {
                    throw AyuBridgeFailure("resource_limit", "Byte output exceeds quota")
                }
                values.append(contentsOf: additions.map(AyuBridgeValue.integer))
                state["values"] = .array(values)
                return .value(.null)
            },
            "writeBytes": { state, args, context in
                try Self.arity(args, 1)
                let bytes = try Self.outputBytes(args[0], context)
                var values = state["values"]?.array ?? []
                guard bytes.count <= Self.byteOutputLimit - values.count else {
                    throw AyuBridgeFailure("resource_limit", "Byte output exceeds quota")
                }
                values.append(contentsOf: bytes.map(AyuBridgeValue.integer))
                state["values"] = .array(values)
                return .value(.null)
            },
            "toByteArray": { state, args, _ in
                try Self.arity(args, 0)
                let values = (state["values"]?.array ?? []).compactMap { value -> AyuBridgeValue? in
                    guard let integer = value.integer else { return nil }
                    return .integer(Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: integer))))
                }
                return .value(.array(values))
            },
            "reset": { state, args, _ in
                try Self.arity(args, 0)
                state["values"] = .array([])
                return .value(.null)
            },
            "flush": { state, args, _ in
                try Self.arity(args, 0)
                return .value(.null)
            },
            "close": { state, args, _ in
                try Self.arity(args, 0)
                return .value(.null)
            },
        ])
    }

    static var collectionsSingletonList: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.util.Collections$SingletonList", methods: [
            "size": { state, args, _ in try Self.arity(args, 0); return .value(.integer(1)) },
            "isEmpty": { state, args, _ in try Self.arity(args, 0); return .value(.bool(false)) },
            "get": { state, args, _ in
                try Self.arity(args, 1)
                guard args[0].integer == 0 else { throw AyuBridgeFailure("invalid_arguments", "Singleton list index out of range") }
                return .value(state["value"] ?? .null)
            },
            "contains": { state, args, _ in try Self.arity(args, 1); return .value(.bool(state["value"] == args[0])) },
            "toArray": { state, args, _ in try Self.arity(args, 0); return .value(.array([state["value"] ?? .null])) },
        ])
    }

    static var collections: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.util.Collections", staticMethods: [
            "singletonList": { args, _ in
                try Self.arity(args, 1)
                return .instance(className: "java.util.Collections$SingletonList", state: ["value": args[0]])
            },
        ], results: ["singletonList": "java.util.Collections$SingletonList"])
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
