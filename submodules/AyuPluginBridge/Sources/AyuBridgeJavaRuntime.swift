import Foundation

/// Java facade additions over the class-adapter registry: Intent, Bundle,
/// View, MotionEvent, Paint/Canvas, Drawable, Handler/Runnable. Every
/// unsupported overload raises `unsupported_api` — no fake success. Registered
/// by the integrator via `AyuBridgeClassRegistry.adding(AyuBridgeJavaRuntime.adapters)`.

enum AyuBridgeJavaRuntime {
    /// Utility adapters that have an explicit native value/rendering path.
    /// Canvas, Paint, ScrollView and widget adapter models remain excluded when
    /// the native-host view registry owns those classes.
    static var integratedAdapters: [AyuBridgeClassAdapter] {
        let enabled: Set<String> = ["android.os.Bundle", "android.content.Intent", "android.net.Uri", "android.graphics.Color", "android.graphics.drawable.ColorDrawable", "android.view.MotionEvent", "android.os.Handler"]
        return self.adapters.filter { enabled.contains($0.name) }
    }

    static var adapters: [AyuBridgeClassAdapter] {
        [bundle, intent, uri, view, layoutConstraints, motionEvent, paint, canvas, color, colorDrawable, runnable, handler, textView, editText, linearLayout, frameLayout, imageView, scrollView, checkBox, toast]
    }

    // MARK: android.widget (text/layout surface used by the corpus)

    /// Shared widget methods: setText/getText/setTextSize/setGravity/
    /// setVisibility/setEnabled over the widget's owned state; rendering
    /// happens in the native view channel.
    private static let widgetMethods: [String: AyuBridgeClassAdapter.InstanceMethod] = [
        "setText": { state, args, _ in
            guard args.count == 1, let text = args[0].string, text.utf8.count <= 10_000 else { throw Self.unsupported("setText") }
            state["text"] = .string(text)
            return .value(.null)
        },
        "getText": { state, args, _ in
            try Self.arity(args, 0)
            return .value(state["text"] ?? .string(""))
        },
        "setTextSize": { state, args, _ in
            try Self.arity(args, 1)
            guard let size = args[0].number, size > 0, size < 200 else { throw Self.unsupported("setTextSize") }
            state["text_size"] = .number(size)
            return .value(.null)
        },
        "setGravity": { state, args, _ in
            try Self.arity(args, 1)
            state["gravity"] = .integer(try Self.integer(args[0], "gravity"))
            return .value(.null)
        },
        "setVisibility": { state, args, _ in
            try Self.arity(args, 1)
            guard let value = args[0].integer, [0, 4, 8].contains(value) else { throw Self.unsupported("setVisibility") }
            state["visibility"] = .integer(value)
            return .value(.null)
        },
        "setEnabled": { state, args, _ in
            try Self.arity(args, 1)
            state["enabled"] = .bool(try Self.bool(args[0], "enabled"))
            return .value(.null)
        },
    ]

    private static func addChild(_ name: String, maximum: Int = 64) -> AyuBridgeClassAdapter.InstanceMethod {
        { state, args, _ in
            guard args.count == 1 || args.count == 2 else { throw Self.unsupported(name + ".addView") }
            var children = state["children"]?.array ?? []
            guard children.count < maximum else { throw AyuBridgeFailure("resource_limit", "Too many child views") }
            children.append(args[0])
            state["children"] = .array(children)
            return .value(.null)
        }
    }

    static var textView: AyuBridgeClassAdapter {
        let gravity: [String: AyuBridgeValue] = [
            "GRAVITY_CENTER": .integer(17), "GRAVITY_LEFT": .integer(3), "GRAVITY_RIGHT": .integer(5),
        ]
        return AyuBridgeClassAdapter(name: "android.widget.TextView", constants: gravity,
            constructor: { args, _ in try Self.arity(args, 0); return ["text": .string(""), "text_size": .number(14), "gravity": .integer(17), "visibility": .integer(0), "enabled": .bool(true)] },
            methods: Self.widgetMethods,
            validateState: { state in try Self.rejectState(["text", "text_size", "gravity", "visibility", "enabled"], state: state, className: "android.widget.TextView") })
    }

    static var editText: AyuBridgeClassAdapter {
        var handlers = Self.widgetMethods
        handlers["setHint"] = { state, args, _ in
            try Self.arity(args, 1)
            guard args[0].string != nil else { throw Self.unsupported("setHint") }
            state["hint"] = args[0]
            return .value(.null)
        }
        return AyuBridgeClassAdapter(name: "android.widget.EditText",
            constructor: { args, _ in try Self.arity(args, 0); return ["text": .string(""), "hint": .string(""), "text_size": .number(16), "visibility": .integer(0), "enabled": .bool(true)] },
            methods: handlers,
            validateState: { state in try Self.rejectState(["text", "hint", "text_size", "gravity", "visibility", "enabled"], state: state, className: "android.widget.EditText") })
    }

    static var linearLayout: AyuBridgeClassAdapter {
        let orientations: [String: AyuBridgeValue] = ["HORIZONTAL": .integer(0), "VERTICAL": .integer(1)]
        return AyuBridgeClassAdapter(name: "android.widget.LinearLayout", constants: orientations,
            constructor: { args, _ in try Self.arity(args, 0); return ["orientation": .integer(1), "children": .array([]), "visibility": .integer(0), "enabled": .bool(true)] },
            methods: [
                "setOrientation": { state, args, _ in
                    try Self.arity(args, 1)
                    guard let value = args[0].integer, [0, 1].contains(value) else { throw Self.unsupported("LinearLayout.setOrientation") }
                    state["orientation"] = .integer(value)
                    return .value(.null)
                },
                "addView": Self.addChild("LinearLayout"),
            ],
            validateState: { state in try Self.rejectState(["orientation", "children", "visibility", "enabled"], state: state, className: "android.widget.LinearLayout") })
    }

    static var frameLayout: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.widget.FrameLayout",
            constructor: { args, _ in try Self.arity(args, 0); return ["children": .array([]), "visibility": .integer(0), "enabled": .bool(true)] },
            methods: ["addView": Self.addChild("FrameLayout")],
            validateState: { state in try Self.rejectState(["children", "visibility", "enabled"], state: state, className: "android.widget.FrameLayout") })
    }

    static var imageView: AyuBridgeClassAdapter {
        let scales: [String: AyuBridgeValue] = ["FIT_CENTER": .integer(1), "CENTER_CROP": .integer(2)]
        return AyuBridgeClassAdapter(name: "android.widget.ImageView", constants: scales,
            constructor: { args, _ in try Self.arity(args, 0); return ["scale_type": .integer(1), "visibility": .integer(0), "enabled": .bool(true)] },
            methods: [
                "setImageResource": { state, args, _ in
                    try Self.arity(args, 1)
                    state["resource"] = .integer(try Self.integer(args[0], "resource"))
                    return .value(.null)
                },
                "setColorFilter": { state, args, _ in
                    try Self.arity(args, 1)
                    state["color_filter"] = .integer(try Self.integer(args[0], "color"))
                    return .value(.null)
                },
            ],
            validateState: { state in try Self.rejectState(["resource", "color_filter", "scale_type", "visibility", "enabled"], state: state, className: "android.widget.ImageView") })
    }

    static var scrollView: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.widget.ScrollView",
            constructor: { args, _ in try Self.arity(args, 0); return ["child": .null, "visibility": .integer(0), "enabled": .bool(true)] },
            methods: [
                "addView": { state, args, _ in
                    try Self.arity(args, 1)
                    state["child"] = args[0]
                    return .value(.null)
                },
            ],
            validateState: { state in try Self.rejectState(["child", "visibility", "enabled"], state: state, className: "android.widget.ScrollView") })
    }

    static var checkBox: AyuBridgeClassAdapter {
        var handlers = Self.widgetMethods
        handlers["setChecked"] = { state, args, _ in
            try Self.arity(args, 1)
            state["checked"] = .bool(try Self.bool(args[0], "checked"))
            return .value(.null)
        }
        handlers["isChecked"] = { state, args, _ in
            try Self.arity(args, 0)
            return .value(state["checked"] ?? .bool(false))
        }
        return AyuBridgeClassAdapter(name: "android.widget.CheckBox",
            constructor: { args, _ in try Self.arity(args, 0); return ["text": .string(""), "checked": .bool(false), "visibility": .integer(0), "enabled": .bool(true)] },
            methods: handlers,
            validateState: { state in try Self.rejectState(["text", "text_size", "gravity", "visibility", "enabled", "checked"], state: state, className: "android.widget.CheckBox") })
    }

    static var toast: AyuBridgeClassAdapter {
        let durations: [String: AyuBridgeValue] = ["LENGTH_SHORT": .integer(0), "LENGTH_LONG": .integer(1)]
        return AyuBridgeClassAdapter(name: "android.widget.Toast", constants: durations,
            constructor: { args, _ in try Self.arity(args, 0); return ["text": .string(""), "duration": .integer(0)] },
            methods: [
                "setText": { state, args, _ in
                    try Self.arity(args, 1)
                    guard let text = args[0].string, text.utf8.count <= 512 else { throw Self.unsupported("Toast.setText") }
                    state["text"] = .string(text)
                    return .value(.null)
                },
                "show": { state, args, _ in
                    // Display happens through the app's ui.present channel.
                    try Self.arity(args, 0)
                    return .value(.null)
                },
            ],
            validateState: { state in try Self.rejectState(["text", "duration"], state: state, className: "android.widget.Toast") })
    }

    // MARK: Shared helpers

    private static func string(_ value: AyuBridgeValue, _ what: String) throws -> String {
        guard let text = value.string else { throw AyuBridgeFailure("invalid_arguments", "Expected \(what)") }
        return text
    }
    private static func optionalString(_ value: AyuBridgeValue) -> String? { value.string }
    private static func integer(_ value: AyuBridgeValue, _ what: String) throws -> Int64 {
        guard let number = value.integer else { throw AyuBridgeFailure("invalid_arguments", "Expected \(what)") }
        return number
    }
    private static func colorInteger(_ value: AyuBridgeValue, _ what: String) throws -> Int64 {
        guard let color = value.integer,
              (color >= Int64(Int32.min) && color <= Int64(Int32.max)) ||
              (color >= 0 && color <= Int64(UInt32.max)) else {
            throw AyuBridgeFailure("invalid_arguments", "Expected \(what)")
        }
        return color
    }
    private static func optionalInteger(_ value: AyuBridgeValue) -> Int64? { value.integer }
    private static func bool(_ value: AyuBridgeValue, _ what: String) throws -> Bool {
        guard let flag = value.bool else { throw AyuBridgeFailure("invalid_arguments", "Expected \(what)") }
        return flag
    }
    private static func instance(_ className: String, _ state: [String: AyuBridgeValue]) -> AyuBridgeAdapterResult {
        .instance(className: className, state: state)
    }
    private static func unsupported(_ name: String) -> AyuBridgeFailure {
        AyuBridgeFailure.unsupported(name)
    }
    private static func rejectState(_ allowed: Set<String>, state: [String: AyuBridgeValue], className: String) throws {
        guard Set(state.keys).isSubset(of: allowed) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid \(className) state")
        }
    }

    // MARK: Bundle

    static var bundle: AyuBridgeClassAdapter {
        let put: (String, String) -> AyuBridgeClassAdapter.InstanceMethod = { keyType, _ in
            { state, args, _ in
                try Self.arity(args, 2)
                let key = try Self.string(args[0], "bundle key")
                guard keyType != "String" || args[1].string != nil,
                      keyType != "Int" || args[1].integer != nil,
                      keyType != "Boolean" || args[1].bool != nil,
                      keyType != "Long" || args[1].integer != nil,
                      keyType != "Double" || args[1].double != nil else {
                    throw Self.unsupported("Bundle.put\(keyType)")
                }
                state["entries"] = .object((state["entries"]?.object ?? [:]).merging([key: args[1]]) { _, new in new })
                return .value(.null)
            }
        }
        return AyuBridgeClassAdapter(name: "android.os.Bundle",
            constructor: { args, _ in try Self.arity(args, 0); return ["entries": .object([:])] },
            methods: [
                "putString": put("String", "putString"),
                "putInt": put("Int", "putInt"),
                "putLong": put("Long", "putLong"),
                "putBoolean": put("Boolean", "putBoolean"),
                "putDouble": put("Double", "putDouble"),
                "getString": { state, args, _ in
                    try Self.arity(args, 1)
                    let key = try Self.string(args[0], "bundle key")
                    let stored = state["entries"]?.object?[key]
                    guard let stored, stored.string != nil else { return .value(.null) }
                    return .value(stored)
                },
                "getInt": { state, args, _ in
                    guard args.count == 1 || args.count == 2 else { throw Self.unsupported("Bundle.getInt") }
                    let key = try Self.string(args[0], "bundle key")
                    let stored = state["entries"]?.object?[key]
                    if let stored, let number = stored.integer { return .value(.integer(number)) }
                    if args.count == 2, let fallback = args[1].integer { return .value(.integer(fallback)) }
                    return .value(.integer(0))
                },
                "getLong": { state, args, _ in
                    guard args.count == 1 || args.count == 2 else { throw Self.unsupported("Bundle.getLong") }
                    let key = try Self.string(args[0], "bundle key")
                    let stored = state["entries"]?.object?[key]
                    if let stored, let number = stored.integer { return .value(.integer(number)) }
                    if args.count == 2, let fallback = args[1].integer { return .value(.integer(fallback)) }
                    return .value(.integer(0))
                },
                "getBoolean": { state, args, _ in
                    guard args.count == 1 || args.count == 2 else { throw Self.unsupported("Bundle.getBoolean") }
                    let key = try Self.string(args[0], "bundle key")
                    let stored = state["entries"]?.object?[key]
                    if let stored, let flag = stored.bool { return .value(.bool(flag)) }
                    if args.count == 2, let fallback = args[1].bool { return .value(.bool(fallback)) }
                    return .value(.bool(false))
                },
                "keySet": { state, args, _ in
                    try Self.arity(args, 0)
                    let keys = (state["entries"]?.object ?? [:]).keys.sorted().map { AyuBridgeValue.string($0) }
                    return Self.instance("java.util.ArrayList", ["values": .array(keys)])
                },
                "isEmpty": { state, args, _ in
                    try Self.arity(args, 0)
                    return .value(.bool((state["entries"]?.object ?? [:]).isEmpty))
                },
            ], validateState: { state in try Self.rejectState(["entries"], state: state, className: "android.os.Bundle") })
    }

    private static func matches(_ value: AyuBridgeValue, _ keyType: String) -> Bool {
        switch keyType {
        case "String": return value.string != nil
        case "Int", "Long": return value.integer != nil
        case "Boolean": return value.bool != nil
        case "Double": return value.double != nil
        default: return false
        }
    }

    // MARK: Intent

    static var intent: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.content.Intent",
            constants: [
                "ACTION_SEND": .string("android.intent.action.SEND"),
                "ACTION_VIEW": .string("android.intent.action.VIEW"),
                "ACTION_MAIN": .string("android.intent.action.MAIN"),
                "CATEGORY_LAUNCHER": .string("android.intent.category.LAUNCHER"),
                "FLAG_ACTIVITY_NEW_TASK": .integer(0x1000_0000),
            ],
            constructor: { args, _ in
                if args.isEmpty { return ["action": .null, "entries": .object([:]), "categories": .array([]), "flags": .integer(0)] }
                try Self.arity(args, 1)
                return ["action": .string(try Self.string(args[0], "intent action")), "entries": .object([:]), "categories": .array([]), "flags": .integer(0)]
            },
            methods: [
                "setAction": { state, args, _ in
                    try Self.arity(args, 1)
                    var updated = state
                    updated["action"] = .string(try Self.string(args[0], "intent action"))
                    state = updated
                    return Self.instance("android.content.Intent", updated)
                },
                "getAction": { state, args, _ in try Self.arity(args, 0); return .value(state["action"] ?? .null) },
                "putExtra": { state, args, _ in
                    guard args.count == 2 else { throw Self.unsupported("Intent.putExtra") }
                    let key = try Self.string(args[0], "extra key")
                    var entries = state["entries"]?.object ?? [:]
                    entries[key] = args[1]
                    state["entries"] = .object(entries)
                    return .value(.null)
                },
                "getStringExtra": { state, args, _ in
                    try Self.arity(args, 1)
                    let key = try Self.string(args[0], "extra key")
                    let stored = state["entries"]?.object?[key]
                    guard let stored, stored.string != nil else { return .value(.null) }
                    return .value(stored)
                },
                "getIntExtra": { state, args, _ in
                    guard args.count == 2 else { throw Self.unsupported("Intent.getIntExtra") }
                    let key = try Self.string(args[0], "extra key")
                    let stored = state["entries"]?.object?[key]
                    if let stored, let number = stored.integer { return .value(.integer(number)) }
                    return .value(.integer(try Self.integer(args[1], "default value")))
                },
                "hasExtra": { state, args, _ in
                    try Self.arity(args, 1)
                    let key = try Self.string(args[0], "extra key")
                    return .value(.bool(state["entries"]?.object?[key] != nil))
                },
                "addCategory": { state, args, _ in
                    try Self.arity(args, 1)
                    var updated = state
                    let categories = updated["categories"]?.array ?? []
                    updated["categories"] = .array(categories + [.string(try Self.string(args[0], "category"))])
                    state = updated
                    return Self.instance("android.content.Intent", updated)
                },
                "addFlags": { state, args, _ in
                    try Self.arity(args, 1)
                    var updated = state
                    let flagBits = try Self.integer(args[0], "flags")
                    updated["flags"] = .integer((updated["flags"]?.integer ?? 0) | flagBits)
                    state = updated
                    return Self.instance("android.content.Intent", updated)
                },
                "getFlags": { state, args, _ in try Self.arity(args, 0); return .value(state["flags"] ?? .integer(0)) },
            ], readableFields: ["action"], writableFields: ["action"], receiverMethods: ["setAction", "addCategory", "addFlags"],
            validateState: { state in try Self.rejectState(["action", "entries", "categories", "flags"], state: state, className: "android.content.Intent") })
    }

    static var uri: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.net.Uri",
            staticMethods: ["parse": { args, _ in
                guard args.count == 1, let value = args[0].string, value.utf8.count <= 8_192,
                      URLComponents(string: value) != nil else {
                    throw AyuBridgeFailure("invalid_arguments", "Invalid or oversized URI")
                }
                return .instance(className: "android.net.Uri", state: ["value": .string(value)])
            }], methods: [
                "toString": { state, args, _ in
                    try Self.arity(args, 0)
                    return .value(.string(try Self.uriString(state)))
                },
                "getScheme": { state, args, _ in
                    try Self.arity(args, 0)
                    let scheme = try Self.uriComponents(state).scheme
                    return .value(scheme.map { .string($0) } ?? .null)
                },
                "getHost": { state, args, _ in
                    try Self.arity(args, 0)
                    let host = try Self.uriComponents(state).host
                    return .value(host.map { .string($0) } ?? .null)
                },
                "getPort": { state, args, _ in
                    try Self.arity(args, 0)
                    return .value(try Self.uriComponents(state).port.map { .integer(Int64($0)) } ?? .null)
                },
                "getPath": { state, args, _ in
                    try Self.arity(args, 0)
                    let components = try Self.uriComponents(state)
                    return .value(components.percentEncodedPath.isEmpty ? .null : .string(components.path))
                },
                "getEncodedPath": { state, args, _ in
                    try Self.arity(args, 0)
                    let components = try Self.uriComponents(state)
                    return .value(components.percentEncodedPath.isEmpty ? .null : .string(components.percentEncodedPath))
                },
                "getLastPathSegment": { state, args, _ in
                    try Self.arity(args, 0)
                    let components = try Self.uriComponents(state)
                    return .value(components.path.split(separator: "/").last.map { .string(String($0)) } ?? .null)
                },
                "getQueryParameter": { state, args, _ in
                    guard args.count == 1, let name = args[0].string, !name.isEmpty, name.utf8.count <= 256 else {
                        throw AyuBridgeFailure("invalid_arguments", "Invalid URI query parameter name")
                    }
                    let item = try Self.uriComponents(state).queryItems?.first(where: { $0.name == name })
                    return .value(item?.value.map { .string($0) } ?? .null)
                },
                "getFragment": { state, args, _ in
                    try Self.arity(args, 0)
                    let fragment = try Self.uriComponents(state).fragment
                    return .value(fragment.map { .string($0) } ?? .null)
                },
            ], validateState: { state in
                guard Set(state.keys) == ["value"] else { throw Self.invalid() }
                _ = try Self.uriString(state)
                _ = try Self.uriComponents(state)
            })
    }

    private static func uriString(_ state: [String: AyuBridgeValue]) throws -> String {
        guard let value = state["value"]?.string, value.utf8.count <= 8_192 else { throw Self.invalid() }
        return value
    }

    private static func uriComponents(_ state: [String: AyuBridgeValue]) throws -> URLComponents {
        guard let components = URLComponents(string: try Self.uriString(state)) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid URI")
        }
        return components
    }

    // MARK: View

    static var view: AyuBridgeClassAdapter {
        let visibility: [String: AyuBridgeValue] = ["VISIBLE": .integer(0), "INVISIBLE": .integer(4), "GONE": .integer(8)]
        return AyuBridgeClassAdapter(name: "android.view.View",
            constants: visibility,
            methods: [
                "setVisibility": { state, args, _ in
                    try Self.arity(args, 1)
                    guard let value = args[0].integer, [0, 4, 8].contains(value) else { throw Self.unsupported("View.setVisibility") }
                    var updated = state
                    updated["visibility"] = .integer(value)
                    state = updated
                    return Self.instance("android.view.View", updated)
                },
                "getVisibility": { state, args, _ in try Self.arity(args, 0); return .value(state["visibility"] ?? .integer(0)) },
                "setEnabled": { state, args, _ in
                    try Self.arity(args, 1)
                    var updated = state
                    updated["enabled"] = .bool(try Self.bool(args[0], "enabled"))
                    state = updated
                    return Self.instance("android.view.View", updated)
                },
                "setAlpha": { state, args, _ in
                    try Self.arity(args, 1)
                    guard let alpha = args[0].double, (0.0...1.0).contains(alpha) else { throw Self.unsupported("View.setAlpha") }
                    var updated = state
                    updated["alpha"] = .number(alpha)
                    state = updated
                    return Self.instance("android.view.View", updated)
                },
                "setTranslationX": { state, args, _ in
                    try Self.arity(args, 1)
                    var updated = state
                    updated["translation_x"] = .number(Double(try Self.integer(args[0], "translation")))
                    updated["translation_y"] = updated["translation_y"] ?? .number(0)
                    state = updated
                    return Self.instance("android.view.View", updated)
                },
                "setTranslationY": { state, args, _ in
                    try Self.arity(args, 1)
                    var updated = state
                    updated["translation_y"] = .number(Double(try Self.integer(args[0], "translation")))
                    updated["translation_x"] = updated["translation_x"] ?? .number(0)
                    state = updated
                    return Self.instance("android.view.View", updated)
                },
                "setScaleX": { state, args, _ in
                    try Self.arity(args, 1)
                    var updated = state
                    updated["scale_x"] = .number(Double(try Self.integer(args[0], "scale")))
                    updated["scale_y"] = updated["scale_y"] ?? .number(1)
                    state = updated
                    return Self.instance("android.view.View", updated)
                },
                "setScaleY": { state, args, _ in
                    try Self.arity(args, 1)
                    var updated = state
                    updated["scale_y"] = .number(Double(try Self.integer(args[0], "scale")))
                    updated["scale_x"] = updated["scale_x"] ?? .number(1)
                    state = updated
                    return Self.instance("android.view.View", updated)
                },
                "setPadding": { state, args, _ in
                    guard args.count == 4 else { throw Self.unsupported("View.setPadding") }
                    let paddings: [AyuBridgeValue] = try args.map { .number(Double(try Self.integer($0, "padding"))) }
                    var updated = state
                    updated["padding"] = .object(["left": paddings[0], "top": paddings[1], "right": paddings[2], "bottom": paddings[3]])
                    state = updated
                    return Self.instance("android.view.View", updated)
                },
                "setLayoutParams": { state, args, context in
                    try Self.arity(args, 1)
                    let snapshot = try context.snapshot(of: args[0])
                    guard snapshot.className == "android.view.ViewGroup.LayoutParams" else { throw Self.unsupported("View.setLayoutParams") }
                    var updated = state
                    updated["layout_params"] = args[0]
                    state = updated
                    return Self.instance("android.view.View", updated)
                },
            ], readableFields: ["visibility"], writableFields: ["visibility"], receiverMethods: ["setVisibility", "setEnabled", "setAlpha", "setTranslationX", "setTranslationY", "setScaleX", "setScaleY", "setPadding", "setLayoutParams"],
            validateState: { state in
                try Self.rejectState(["visibility", "enabled", "alpha", "translation_x", "translation_y", "scale_x", "scale_y", "padding", "layout_params"], state: state, className: "android.view.View")
            })
    }

    /// LayoutParams: width/height with MATCH_PARENT/WRAP_CONTENT semantics.
    static var layoutConstraints: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.view.ViewGroup.LayoutParams",
            constants: ["MATCH_PARENT": .integer(-1), "WRAP_CONTENT": .integer(-2)],
            constructor: { args, _ in
                if args.isEmpty { return ["width": .integer(-2), "height": .integer(-2)] }
                try Self.arity(args, 2)
                return ["width": .integer(try Self.integer(args[0], "width")), "height": .integer(try Self.integer(args[1], "height"))]
            },
            methods: [
                "setMargins": { state, args, _ in
                    guard args.count == 4 else { throw Self.unsupported("LayoutParams.setMargins") }
                    let margins: [AyuBridgeValue] = try args.map { .number(Double(try Self.integer($0, "margin"))) }
                    var updated = state
                    updated["margins"] = .object(["left": margins[0], "top": margins[1], "right": margins[2], "bottom": margins[3]])
                    state = updated
                    return Self.instance("android.view.ViewGroup.LayoutParams", updated)
                },
            ], readableFields: ["width", "height"], writableFields: ["width", "height"], receiverMethods: ["setMargins"],
            validateState: { state in
                try Self.rejectState(["width", "height", "margins"], state: state, className: "android.view.ViewGroup.LayoutParams")
                for key in ["width", "height"] {
                    if let value = state[key]?.integer, value < -2 { throw AyuBridgeFailure("invalid_arguments", "Invalid LayoutParams dimension") }
                }
            })
    }

    // MARK: MotionEvent

    static var motionEvent: AyuBridgeClassAdapter {
        let actions: [String: AyuBridgeValue] = [
            "ACTION_DOWN": .integer(0), "ACTION_UP": .integer(1), "ACTION_MOVE": .integer(2), "ACTION_CANCEL": .integer(3),
        ]
        return AyuBridgeClassAdapter(name: "android.view.MotionEvent", constants: actions,
            constructor: { args, _ in
                guard args.count == 3 || args.count == 4 else { throw Self.unsupported("MotionEvent.<init>") }
                guard let action = args[0].integer, [0, 1, 2, 3].contains(action) else { throw Self.unsupported("MotionEvent action") }
                var state: [String: AyuBridgeValue] = [
                    "action": .integer(action),
                    "x": .number(Double(try Self.integer(args[1], "x"))),
                    "y": .number(Double(try Self.integer(args[2], "y"))),
                ]
                if args.count == 4 { state["pointer_count"] = .integer(try Self.integer(args[3], "pointer count")) }
                return state
            },
            methods: [
                "getX": { state, args, _ in try Self.arity(args, 0); return .value(state["x"] ?? .number(0)) },
                "getY": { state, args, _ in try Self.arity(args, 0); return .value(state["y"] ?? .number(0)) },
                "getAction": { state, args, _ in try Self.arity(args, 0); return .value(state["action"] ?? .integer(0)) },
                "getPointerCount": { state, args, _ in try Self.arity(args, 0); return .value(state["pointer_count"] ?? .integer(1)) },
            ], validateState: { state in
                try Self.rejectState(["action", "x", "y", "pointer_count"], state: state, className: "android.view.MotionEvent")
            })
    }

    // MARK: Paint / Canvas (path-model drawing for snow/ball style plugins)

    static var paint: AyuBridgeClassAdapter {
        let caps: [String: AyuBridgeValue] = ["BUTT": .integer(0), "ROUND": .integer(1), "SQUARE": .integer(2)]
        let styles: [String: AyuBridgeValue] = ["FILL": .integer(0), "STROKE": .integer(1), "FILL_AND_STROKE": .integer(2)]
        return AyuBridgeClassAdapter(name: "android.graphics.Paint", constants: caps.merging(styles) { a, _ in a },
            constructor: { args, _ in try Self.arity(args, 0); return ["color": .integer(0xFF00_0000), "stroke_width": .number(0), "style": .integer(0), "cap": .integer(0), "anti_alias": .bool(true)] },
            methods: [
                "setColor": { state, args, _ in
                    try Self.arity(args, 1)
                    guard let color = args[0].integer, color >= 0, color <= 0xFFFF_FFFF else { throw Self.unsupported("Paint.setColor") }
                    var updated = state
                    updated["color"] = .integer(color)
                    state = updated
                    return Self.instance("android.graphics.Paint", updated)
                },
                "setStrokeWidth": { state, args, _ in
                    try Self.arity(args, 1)
                    guard let width = args[0].double, width >= 0 else { throw Self.unsupported("Paint.setStrokeWidth") }
                    var updated = state
                    updated["stroke_width"] = .number(width)
                    state = updated
                    return Self.instance("android.graphics.Paint", updated)
                },
                "setStyle": { state, args, _ in
                    try Self.arity(args, 1)
                    guard let style = args[0].integer, [0, 1, 2].contains(style) else { throw Self.unsupported("Paint.setStyle") }
                    var updated = state
                    updated["style"] = .integer(style)
                    state = updated
                    return Self.instance("android.graphics.Paint", updated)
                },
                "setStrokeCap": { state, args, _ in
                    try Self.arity(args, 1)
                    guard let cap = args[0].integer, [0, 1, 2].contains(cap) else { throw Self.unsupported("Paint.setStrokeCap") }
                    var updated = state
                    updated["cap"] = .integer(cap)
                    state = updated
                    return Self.instance("android.graphics.Paint", updated)
                },
                "setAntiAlias": { state, args, _ in
                    try Self.arity(args, 1)
                    var updated = state
                    updated["anti_alias"] = .bool(try Self.bool(args[0], "anti-alias flag"))
                    state = updated
                    return Self.instance("android.graphics.Paint", updated)
                },
                "setAlpha": { state, args, _ in
                    try Self.arity(args, 1)
                    guard let alpha = args[0].integer, (0...255).contains(alpha) else { throw Self.unsupported("Paint.setAlpha") }
                    var updated = state
                    var color = updated["color"]?.integer ?? 0xFF00_0000
                    color = (color & 0x00FF_FFFF) | (alpha << 24)
                    updated["color"] = .integer(color)
                    state = updated
                    return Self.instance("android.graphics.Paint", updated)
                },
            ], receiverMethods: ["setColor", "setStrokeWidth", "setStyle", "setStrokeCap", "setAntiAlias", "setAlpha"], validateState: { state in
                try Self.rejectState(["color", "stroke_width", "style", "cap", "anti_alias"], state: state, className: "android.graphics.Paint")
            })
    }

    static var canvas: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.graphics.Canvas",
            constructor: { args, _ in try Self.arity(args, 0); return ["path": .array([]), "width": .integer(0), "height": .integer(0)] },
            methods: [
                "drawCircle": { state, args, _ in
                    guard args.count == 4 else { throw Self.unsupported("Canvas.drawCircle") }
                    let x = try Self.doubleArgument(args[0]), y = try Self.doubleArgument(args[1]), radius = try Self.doubleArgument(args[2])
                    var path = state["path"]?.array ?? []
                    path.append(.object(["op": .string("circle"), "x": .number(x), "y": .number(y), "radius": .number(radius)]))
                    state["path"] = .array(path)
                    return .value(.null)
                },
                "drawRect": { state, args, _ in
                    guard args.count == 4 else { throw Self.unsupported("Canvas.drawRect") }
                    let left = try Self.doubleArgument(args[0]), top = try Self.doubleArgument(args[1]), right = try Self.doubleArgument(args[2]), bottom = try Self.doubleArgument(args[3])
                    var path = state["path"]?.array ?? []
                    path.append(.object(["op": .string("rect"), "left": .number(left), "top": .number(top), "right": .number(right), "bottom": .number(bottom)]))
                    state["path"] = .array(path)
                    return .value(.null)
                },
                "drawLine": { state, args, _ in
                    guard args.count == 4 else { throw Self.unsupported("Canvas.drawLine") }
                    let x0 = try Self.doubleArgument(args[0]), y0 = try Self.doubleArgument(args[1]), x1 = try Self.doubleArgument(args[2]), y1 = try Self.doubleArgument(args[3])
                    var path = state["path"]?.array ?? []
                    path.append(.object(["op": .string("line"), "x0": .number(x0), "y0": .number(y0), "x1": .number(x1), "y1": .number(y1)]))
                    state["path"] = .array(path)
                    return .value(.null)
                },
                "getWidth": { state, args, _ in try Self.arity(args, 0); return .value(state["width"] ?? .integer(0)) },
                "getHeight": { state, args, _ in try Self.arity(args, 0); return .value(state["height"] ?? .integer(0)) },
            ], validateState: { state in
                try Self.rejectState(["path", "width", "height"], state: state, className: "android.graphics.Canvas")
            })
    }

    private static func doubleArgument(_ value: AyuBridgeValue) throws -> Double {
        if let double = value.double { return double }
        if let integer = value.integer { return Double(integer) }
        throw AyuBridgeFailure("invalid_arguments", "Expected canvas coordinate")
    }

    // MARK: Color / Drawable

    private static func colorComponent(_ value: AyuBridgeValue, _ what: String) throws -> UInt32 {
        guard let component = value.integer, (0...255).contains(component) else {
            throw AyuBridgeFailure("invalid_arguments", "Expected \(what)")
        }
        return UInt32(component)
    }
    private static func packedColor(alpha: UInt32, red: UInt32, green: UInt32, blue: UInt32) -> AyuBridgeValue {
        let bits = (alpha << 24) | (red << 16) | (green << 8) | blue
        return .integer(Int64(Int32(bitPattern: bits)))
    }
    private static func parsedColor(_ text: String) throws -> AyuBridgeValue {
        if text.hasPrefix("#") {
            let digits = String(text.dropFirst())
            guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid color string")
            }
            return digits.count == 6
                ? Self.packedColor(alpha: 255, red: (value >> 16) & 255, green: (value >> 8) & 255, blue: value & 255)
                : .integer(Int64(Int32(bitPattern: value)))
        }
        let names: [String: UInt32] = [
            "black": 0xFF00_0000, "darkgray": 0xFF44_4444, "gray": 0xFF88_8888,
            "lightgray": 0xFFCC_CCCC, "white": 0xFFFF_FFFF, "red": 0xFFFF_0000,
            "green": 0xFF00_FF00, "blue": 0xFF00_00FF, "yellow": 0xFFFFFF00,
            "cyan": 0xFF00_FFFF, "aqua": 0xFF00_FFFF, "magenta": 0xFFFF_00FF,
            "fuchsia": 0xFFFF_00FF, "transparent": 0x0000_0000,
        ]
        guard let value = names[text.lowercased()] else { throw AyuBridgeFailure("invalid_arguments", "Invalid color string") }
        return .integer(Int64(Int32(bitPattern: value)))
    }
    private static func hsvColor(_ args: [AyuBridgeValue]) throws -> AyuBridgeValue {
        let alpha: UInt32
        let values: [AyuBridgeValue]
        if args.count == 1 {
            alpha = 255; values = args[0].array ?? []
        } else if args.count == 2 {
            alpha = try Self.colorComponent(args[0], "alpha"); values = args[1].array ?? []
        } else {
            throw AyuBridgeFailure("invalid_arguments", "Unsupported HSV overload")
        }
        guard values.count == 3,
              let hue = values[0].number, let saturation = values[1].number, let brightness = values[2].number,
              hue.isFinite, (0...360).contains(hue), (0...1).contains(saturation), (0...1).contains(brightness) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid HSV color")
        }
        if saturation == 0 {
            let component = UInt32((brightness * 255).rounded())
            return Self.packedColor(alpha: alpha, red: component, green: component, blue: component)
        }
        let scaled = (hue == 360 ? 0 : hue) / 60
        let sector = Int(scaled.rounded(.down))
        let fraction = scaled - Double(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        let rgb: (Double, Double, Double)
        switch sector {
        case 0: rgb = (brightness, t, p)
        case 1: rgb = (q, brightness, p)
        case 2: rgb = (p, brightness, t)
        case 3: rgb = (p, q, brightness)
        case 4: rgb = (t, p, brightness)
        default: rgb = (brightness, p, q)
        }
        return Self.packedColor(alpha: alpha, red: UInt32((rgb.0 * 255).rounded()), green: UInt32((rgb.1 * 255).rounded()), blue: UInt32((rgb.2 * 255).rounded()))
    }
    static var color: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.graphics.Color",
            constants: [
                "TRANSPARENT": .integer(0), "BLACK": Self.packedColor(alpha: 255, red: 0, green: 0, blue: 0),
                "DKGRAY": Self.packedColor(alpha: 255, red: 68, green: 68, blue: 68), "GRAY": Self.packedColor(alpha: 255, red: 136, green: 136, blue: 136),
                "LTGRAY": Self.packedColor(alpha: 255, red: 204, green: 204, blue: 204), "WHITE": Self.packedColor(alpha: 255, red: 255, green: 255, blue: 255),
                "RED": Self.packedColor(alpha: 255, red: 255, green: 0, blue: 0), "GREEN": Self.packedColor(alpha: 255, red: 0, green: 255, blue: 0),
                "BLUE": Self.packedColor(alpha: 255, red: 0, green: 0, blue: 255), "YELLOW": Self.packedColor(alpha: 255, red: 255, green: 255, blue: 0),
                "CYAN": Self.packedColor(alpha: 255, red: 0, green: 255, blue: 255), "MAGENTA": Self.packedColor(alpha: 255, red: 255, green: 0, blue: 255),
            ], staticMethods: [
                "argb": { args, _ in
                    try Self.arity(args, 4)
                    return .value(Self.packedColor(alpha: try Self.colorComponent(args[0], "alpha"), red: try Self.colorComponent(args[1], "red"), green: try Self.colorComponent(args[2], "green"), blue: try Self.colorComponent(args[3], "blue")))
                },
                "rgb": { args, _ in
                    try Self.arity(args, 3)
                    return .value(Self.packedColor(alpha: 255, red: try Self.colorComponent(args[0], "red"), green: try Self.colorComponent(args[1], "green"), blue: try Self.colorComponent(args[2], "blue")))
                },
                "parseColor": { args, _ in try Self.arity(args, 1); return .value(try Self.parsedColor(try Self.string(args[0], "color string"))) },
                "HSVToColor": { args, _ in .value(try Self.hsvColor(args)) },
            ])
    }

    static var colorDrawable: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.graphics.drawable.ColorDrawable",
            constructor: { args, _ in
                if args.isEmpty { return ["color": .integer(0)] }
                try Self.arity(args, 1)
                return ["color": .integer(try Self.colorInteger(args[0], "ARGB color"))]
            },
            methods: [
                "getColor": { state, args, _ in try Self.arity(args, 0); return .value(state["color"] ?? .integer(0)) },
                "setColor": { state, args, _ in
                    try Self.arity(args, 1)
                    let color = try Self.colorInteger(args[0], "ARGB color")
                    var updated = state
                    updated["color"] = .integer(color)
                    state = updated
                    return Self.instance("android.graphics.drawable.ColorDrawable", updated)
                },
            ], receiverMethods: ["setColor"], validateState: { state in try Self.rejectState(["color"], state: state, className: "android.graphics.drawable.ColorDrawable") })
    }

    // MARK: Runnable / Handler

    static var runnable: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.lang.Runnable",
            constructor: { args, context in
                try Self.arity(args, 1)
                let callback = try context.callback(args[0])
                return ["callback": .string(callback.id), "callback_ref": args[0]]
            },
            methods: [
                "run": { state, args, context in
                    try Self.arity(args, 0)
                    guard let reference = state["callback_ref"], let callback = try? context.callback(reference) else {
                        throw Self.unsupported("Runnable.run")
                    }
                    callback.send([])
                    return .value(.null)
                },
            ], validateState: { state in
                try Self.rejectState(["callback", "callback_ref"], state: state, className: "java.lang.Runnable")
            })
    }

    static var handler: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.os.Handler",
            constants: ["DELAYED_MS_QUANTUM": .integer(16)],
            constructor: { args, _ in try Self.arity(args, 0); return ["pending": .array([])] },
            methods: [
                "post": { state, args, context in
                    try Self.arity(args, 1)
                    let snapshot = try context.snapshot(of: args[0])
                    guard snapshot.className == "java.lang.Runnable" else { throw Self.unsupported("Handler.post") }
                    let callback = try context.callback(args[0])
                    return .prepared(try context.schedule(callback))
                },
                "postDelayed": { state, args, context in
                    try Self.arity(args, 2)
                    let snapshot = try context.snapshot(of: args[0])
                    guard snapshot.className == "java.lang.Runnable" else { throw Self.unsupported("Handler.postDelayed") }
                    let delay = try Self.integer(args[1], "delay"), callback = try context.callback(args[0])
                    guard delay >= 0, delay <= 60_000 else { throw AyuBridgeFailure("invalid_arguments", "Handler delay out of range") }
                    return .prepared(try context.schedule(callback, delayMilliseconds: delay))
                },
                "removeCallbacks": { state, args, _ in
                    try Self.arity(args, 1)
                    throw Self.unsupported("Handler.removeCallbacks")
                },
            ], validateState: { state in try Self.rejectState(["pending"], state: state, className: "android.os.Handler") })
    }

    private static func arity(_ arguments: [AyuBridgeValue], _ count: Int) throws {
        guard arguments.count == count else { throw AyuBridgeFailure("invalid_arguments", "Unsupported Java overload") }
    }
}
