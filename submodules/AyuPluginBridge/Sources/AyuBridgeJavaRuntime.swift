import Foundation

/// Java facade additions over the class-adapter registry: Intent, Bundle,
/// View, ViewConfiguration, SystemClock, MotionEvent, bounded Paint values, Canvas/Drawable, Handler/Runnable. Every
/// unsupported overload raises `unsupported_api` — no fake success. Registered
/// by the integrator via `AyuBridgeClassRegistry.adding(AyuBridgeJavaRuntime.adapters)`.

enum AyuBridgeJavaRuntime {
    /// Utility adapters that have an explicit native value/rendering path.
    /// Canvas, ScrollView and widget adapter models remain excluded when the
    /// native-host view registry owns those classes. Paint is a value-only model.
    static var integratedAdapters: [AyuBridgeClassAdapter] {
        let enabled: Set<String> = ["android.os.Bundle", "android.os.SystemClock", "android.content.Intent", "android.net.Uri", "android.graphics.Color", "android.graphics.Matrix", "android.graphics.Paint", "android.graphics.Paint$Cap", "android.graphics.Paint$Join", "android.graphics.Paint$Style", "android.graphics.Path", "android.graphics.Rect", "android.graphics.RectF", "android.graphics.Typeface", "android.text.TextUtils$TruncateAt", "android.widget.ImageView$ScaleType", "java.util.Locale", "java.nio.ByteBuffer", "android.graphics.drawable.ColorDrawable", "android.graphics.drawable.GradientDrawable", "android.graphics.PorterDuff$Mode", "android.graphics.PorterDuffColorFilter", "android.view.MotionEvent", "android.view.View$MeasureSpec", "android.view.ViewConfiguration", "android.os.Handler", "android.view.animation.LinearInterpolator", "android.view.animation.DecelerateInterpolator", "android.view.animation.OvershootInterpolator", "android.view.animation.AccelerateDecelerateInterpolator", "android.view.animation.AccelerateInterpolator", "android.view.animation.AnticipateInterpolator", "android.view.animation.AnticipateOvershootInterpolator", "android.view.animation.BounceInterpolator", "android.animation.ValueAnimator"]
        return self.adapters.filter { enabled.contains($0.name) }
    }

    static var adapters: [AyuBridgeClassAdapter] {
        [bundle, intent, uri, view, layoutConstraints, motionEvent, paint, paintCap, paintJoin, paintStyle, path, matrix, canvas, color, rect, rectF, typeface, truncateAt, imageScaleType, locale, byteBuffer, colorDrawable, gradientDrawable, porterDuffMode, porterDuffColorFilter, runnable, handler, measureSpec, viewConfiguration, systemClock, textView, editText, linearLayout, frameLayout, imageView, scrollView, checkBox, toast, linearInterpolator, decelerateInterpolator, overshootInterpolator, accelerateDecelerateInterpolator, accelerateInterpolator, anticipateInterpolator, anticipateOvershootInterpolator, bounceInterpolator, valueAnimator]
    }

    private static let maximumByteBufferBytes = 4096
    private static let rectangleFields = ["left", "top", "right", "bottom"]

    private static func rectangleComponent(_ value: AyuBridgeValue, floating: Bool) throws -> AyuBridgeValue {
        if floating {
            let raw = value.number ?? value.integer.map(Double.init)
            guard let raw, raw.isFinite, abs(raw) <= 10_000_000 else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid rectangle coordinate")
            }
            let number = Float(raw)
            guard number.isFinite else { throw AyuBridgeFailure("invalid_arguments", "Invalid rectangle coordinate") }
            return .number(Double(number))
        }
        guard let integer = value.integer, (Int64(Int32.min)...Int64(Int32.max)).contains(integer) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid rectangle coordinate")
        }
        return .integer(integer)
    }

    private static func rectangleCoordinate(_ state: [String: AyuBridgeValue], _ field: String, floating: Bool) throws -> Double {
        guard let value = state[field] else { throw AyuBridgeFailure("invalid_arguments", "Invalid rectangle state") }
        if floating {
            guard let coordinate = value.number, coordinate.isFinite, abs(coordinate) <= 10_000_000 else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid rectangle state")
            }
            return Double(Float(coordinate))
        }
        guard let coordinate = value.integer, (Int64(Int32.min)...Int64(Int32.max)).contains(coordinate) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid rectangle state")
        }
        return Double(coordinate)
    }

    private static func rectangleArgument(_ value: AyuBridgeValue, className: String,
                                          floating: Bool, context: AyuBridgeAdapterContext) throws -> [String: AyuBridgeValue] {
        let snapshot = try context.snapshot(of: value)
        guard snapshot.className == className else { throw AyuBridgeFailure.unsupported(className + " geometry overload") }
        try Self.validateRectangle(snapshot.state, floating: floating)
        return snapshot.state
    }

    private static func validateRectangle(_ state: [String: AyuBridgeValue], floating: Bool) throws {
        guard Set(state.keys) == Set(Self.rectangleFields) else { throw AyuBridgeFailure("invalid_arguments", "Invalid rectangle state") }
        for field in Self.rectangleFields { _ = try Self.rectangleCoordinate(state, field, floating: floating) }
    }

    private static func rectangleSet(_ state: inout [String: AyuBridgeValue], values: [Double], floating: Bool) throws {
        guard values.count == 4 else { throw AyuBridgeFailure("invalid_arguments", "Invalid rectangle coordinate count") }
        for (field, value) in zip(Self.rectangleFields, values) {
            state[field] = try Self.rectangleComponent(floating ? .number(value) : .integer(Int64(value)), floating: floating)
        }
    }

    private static func rectangleValues(_ state: [String: AyuBridgeValue], floating: Bool) throws -> [Double] {
        try Self.rectangleFields.map { try Self.rectangleCoordinate(state, $0, floating: floating) }
    }

    private static func rectangleArithmetic(_ value: Double, floating: Bool) -> Double {
        floating ? Double(Float(value)) : Double(Int32(truncatingIfNeeded: Int64(value)))
    }

    private static func rectangleAdapter(_ name: String, floating: Bool) -> AyuBridgeClassAdapter {
        let fields = Self.rectangleFields
        let zero = floating ? AyuBridgeValue.number(0) : .integer(0)
        let constructor: AyuBridgeClassAdapter.Constructor = { args, _ in
            guard args.isEmpty || args.count == 4 else { throw AyuBridgeFailure.unsupported(name + " constructor overload") }
            var state = Dictionary(uniqueKeysWithValues: fields.map { ($0, zero) })
            if !args.isEmpty {
                for (field, value) in zip(fields, args) { state[field] = try Self.rectangleComponent(value, floating: floating) }
            }
            return state
        }
        let setValues: AyuBridgeClassAdapter.InstanceMethod = { state, args, context in
            if args.count == 1 {
                let copied = try Self.rectangleArgument(args[0], className: name, floating: floating, context: context)
                for field in fields { state[field] = copied[field] }
            } else if args.count == 4 {
                for (field, value) in zip(fields, args) { state[field] = try Self.rectangleComponent(value, floating: floating) }
            } else {
                throw AyuBridgeFailure.unsupported(name + ".set overload")
            }
            return .instance(className: name, state: state)
        }
        let setEmpty: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            for field in fields { state[field] = zero }
            return .instance(className: name, state: state)
        }
        let width: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            let left = try Self.rectangleCoordinate(state, "left", floating: floating)
            let right = try Self.rectangleCoordinate(state, "right", floating: floating)
            if floating { return .value(.number(Self.rectangleArithmetic(right - left, floating: true))) }
            let result = Int32(right) &- Int32(left)
            return .value(.integer(Int64(result)))
        }
        let height: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            let top = try Self.rectangleCoordinate(state, "top", floating: floating)
            let bottom = try Self.rectangleCoordinate(state, "bottom", floating: floating)
            if floating { return .value(.number(Self.rectangleArithmetic(bottom - top, floating: true))) }
            let result = Int32(bottom) &- Int32(top)
            return .value(.integer(Int64(result)))
        }
        let centerX: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            let left = try Self.rectangleCoordinate(state, "left", floating: floating)
            let right = try Self.rectangleCoordinate(state, "right", floating: floating)
            if floating { return .value(.number(Self.rectangleArithmetic((left + right) * 0.5, floating: true))) }
            let sum = Int32(left) &+ Int32(right)
            return .value(.integer(Int64(sum >> 1)))
        }
        let centerY: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            let top = try Self.rectangleCoordinate(state, "top", floating: floating)
            let bottom = try Self.rectangleCoordinate(state, "bottom", floating: floating)
            if floating { return .value(.number(Self.rectangleArithmetic((top + bottom) * 0.5, floating: true))) }
            let sum = Int32(top) &+ Int32(bottom)
            return .value(.integer(Int64(sum >> 1)))
        }
        let exactCenterX: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            let left = try Self.rectangleCoordinate(state, "left", floating: floating)
            let right = try Self.rectangleCoordinate(state, "right", floating: floating)
            return .value(.number(Double(Float((left + right) * 0.5))))
        }
        let exactCenterY: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            let top = try Self.rectangleCoordinate(state, "top", floating: floating)
            let bottom = try Self.rectangleCoordinate(state, "bottom", floating: floating)
            return .value(.number(Double(Float((top + bottom) * 0.5))))
        }
        let isEmpty: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            let left = try Self.rectangleCoordinate(state, "left", floating: floating)
            let top = try Self.rectangleCoordinate(state, "top", floating: floating)
            let right = try Self.rectangleCoordinate(state, "right", floating: floating)
            let bottom = try Self.rectangleCoordinate(state, "bottom", floating: floating)
            return .value(.bool(left >= right || top >= bottom))
        }
        let offset: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            guard args.count == 2 else { throw AyuBridgeFailure.unsupported(name + ".offset overload") }
            let dx = try Self.rectangleCoordinateValue(args[0], floating: floating)
            let dy = try Self.rectangleCoordinateValue(args[1], floating: floating)
            var values = try Self.rectangleValues(state, floating: floating)
            values[0] = Self.rectangleArithmetic(values[0] + dx, floating: floating)
            values[2] = Self.rectangleArithmetic(values[2] + dx, floating: floating)
            values[1] = Self.rectangleArithmetic(values[1] + dy, floating: floating)
            values[3] = Self.rectangleArithmetic(values[3] + dy, floating: floating)
            try Self.rectangleSet(&state, values: values, floating: floating)
            return .instance(className: name, state: state)
        }
        let offsetTo: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            guard args.count == 2 else { throw AyuBridgeFailure.unsupported(name + ".offsetTo overload") }
            let left = try Self.rectangleCoordinateValue(args[0], floating: floating)
            let top = try Self.rectangleCoordinateValue(args[1], floating: floating)
            let current = try Self.rectangleValues(state, floating: floating)
            let width = Self.rectangleArithmetic(current[2] - current[0], floating: floating)
            let height = Self.rectangleArithmetic(current[3] - current[1], floating: floating)
            try Self.rectangleSet(&state, values: [left, top, Self.rectangleArithmetic(left + width, floating: floating), Self.rectangleArithmetic(top + height, floating: floating)], floating: floating)
            return .instance(className: name, state: state)
        }
        let inset: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            guard args.count == 2 else { throw AyuBridgeFailure.unsupported(name + ".inset overload") }
            let dx = try Self.rectangleCoordinateValue(args[0], floating: floating)
            let dy = try Self.rectangleCoordinateValue(args[1], floating: floating)
            var values = try Self.rectangleValues(state, floating: floating)
            values[0] = Self.rectangleArithmetic(values[0] + dx, floating: floating)
            values[2] = Self.rectangleArithmetic(values[2] - dx, floating: floating)
            values[1] = Self.rectangleArithmetic(values[1] + dy, floating: floating)
            values[3] = Self.rectangleArithmetic(values[3] - dy, floating: floating)
            try Self.rectangleSet(&state, values: values, floating: floating)
            return .instance(className: name, state: state)
        }
        let contains: AyuBridgeClassAdapter.InstanceMethod = { state, args, context in
            let bounds = try Self.rectangleValues(state, floating: floating)
            if args.count == 1 {
                let otherState = try Self.rectangleArgument(args[0], className: name, floating: floating, context: context)
                let other = try Self.rectangleValues(otherState, floating: floating)
                return .value(.bool(other[0] >= bounds[0] && other[1] >= bounds[1] && other[2] <= bounds[2] && other[3] <= bounds[3]
                    && bounds[0] < bounds[2] && bounds[1] < bounds[3]))
            }
            if args.count == 2 {
                let x = try Self.rectangleCoordinateValue(args[0], floating: floating)
                let y = try Self.rectangleCoordinateValue(args[1], floating: floating)
                return .value(.bool(bounds[0] <= x && x < bounds[2] && bounds[1] <= y && y < bounds[3]))
            }
            if args.count == 4 {
                let other = try args.map { try Self.rectangleCoordinateValue($0, floating: floating) }
                return .value(.bool(other[0] >= bounds[0] && other[1] >= bounds[1] && other[2] <= bounds[2] && other[3] <= bounds[3]
                    && bounds[0] < bounds[2] && bounds[1] < bounds[3]))
            }
            throw AyuBridgeFailure.unsupported(name + ".contains overload")
        }
        let intersect: AyuBridgeClassAdapter.InstanceMethod = { state, args, context in
            let other: [Double]
            if args.count == 1 {
                let otherState = try Self.rectangleArgument(args[0], className: name, floating: floating, context: context)
                other = try Self.rectangleValues(otherState, floating: floating)
            } else if args.count == 4 {
                other = try args.map { try Self.rectangleCoordinateValue($0, floating: floating) }
            } else {
                throw AyuBridgeFailure.unsupported(name + ".intersect overload")
            }
            let current = try Self.rectangleValues(state, floating: floating)
            let left = max(current[0], other[0]); let top = max(current[1], other[1])
            let right = min(current[2], other[2]); let bottom = min(current[3], other[3])
            guard left < right, top < bottom else { return .value(.bool(false)) }
            try Self.rectangleSet(&state, values: [left, top, right, bottom], floating: floating)
            return .value(.bool(true))
        }
        let union: AyuBridgeClassAdapter.InstanceMethod = { state, args, context in
            let other: [Double]
            if args.count == 1 {
                let otherState = try Self.rectangleArgument(args[0], className: name, floating: floating, context: context)
                other = try Self.rectangleValues(otherState, floating: floating)
            } else if args.count == 2 {
                let x = try Self.rectangleCoordinateValue(args[0], floating: floating)
                let y = try Self.rectangleCoordinateValue(args[1], floating: floating)
                let current = try Self.rectangleValues(state, floating: floating)
                if current[0] < current[2] && current[1] < current[3] {
                    try Self.rectangleSet(&state, values: [min(current[0], x), min(current[1], y), max(current[2], x), max(current[3], y)], floating: floating)
                    return .instance(className: name, state: state)
                }
                try Self.rectangleSet(&state, values: [x, y, x, y], floating: floating)
                return .instance(className: name, state: state)
            } else if args.count == 4 {
                other = try args.map { try Self.rectangleCoordinateValue($0, floating: floating) }
            } else {
                throw AyuBridgeFailure.unsupported(name + ".union overload")
            }
            let current = try Self.rectangleValues(state, floating: floating)
            if other[0] >= other[2] || other[1] >= other[3] { return .instance(className: name, state: state) }
            if current[0] >= current[2] || current[1] >= current[3] {
                try Self.rectangleSet(&state, values: other, floating: floating)
            } else {
                try Self.rectangleSet(&state, values: [min(current[0], other[0]), min(current[1], other[1]), max(current[2], other[2]), max(current[3], other[3])], floating: floating)
            }
            return .instance(className: name, state: state)
        }
        let sort: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            var values = try Self.rectangleValues(state, floating: floating)
            if values[0] > values[2] { values.swapAt(0, 2) }
            if values[1] > values[3] { values.swapAt(1, 3) }
            try Self.rectangleSet(&state, values: values, floating: floating)
            return .instance(className: name, state: state)
        }
        let methods: [String: AyuBridgeClassAdapter.InstanceMethod] = [
            "set": setValues, "setEmpty": setEmpty, "width": width, "height": height,
            "centerX": centerX, "centerY": centerY, "exactCenterX": exactCenterX, "exactCenterY": exactCenterY,
            "isEmpty": isEmpty, "offset": offset, "offsetTo": offsetTo, "inset": inset,
            "contains": contains, "intersect": intersect, "union": union, "sort": sort,
        ]
        return AyuBridgeClassAdapter(name: name, constructor: constructor, methods: methods,
            readableFields: Set(fields), writableFields: Set(fields),
            receiverMethods: ["set", "setEmpty", "offset", "offsetTo", "inset", "intersect", "union", "sort"],
            validateState: { state in try Self.validateRectangle(state, floating: floating) })
    }

    private static func rectangleCoordinateValue(_ value: AyuBridgeValue, floating: Bool) throws -> Double {
        try Self.rectangleCoordinate(["value": try Self.rectangleComponent(value, floating: floating)], "value", floating: floating)
    }

    static var rect: AyuBridgeClassAdapter { Self.rectangleAdapter("android.graphics.Rect", floating: false) }
    static var rectF: AyuBridgeClassAdapter { Self.rectangleAdapter("android.graphics.RectF", floating: true) }

    private static func byteBufferParts(_ state: [String: AyuBridgeValue]) throws -> (bytes: [AyuBridgeValue], position: Int, limit: Int, mark: Int?) {
        guard Set(state.keys) == ["bytes", "position", "limit", "mark"],
              let bytes = state["bytes"]?.array, bytes.count <= Self.maximumByteBufferBytes,
              let positionValue = state["position"]?.integer, let limitValue = state["limit"]?.integer,
              positionValue >= 0, limitValue >= 0, limitValue <= Int64(bytes.count), positionValue <= limitValue,
              bytes.allSatisfy({ value in value.integer.map { (-128...127).contains($0) } ?? false }) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid ByteBuffer state")
        }
        let markValue = state["mark"] ?? .null
        let mark: Int?
        if markValue == .null {
            mark = nil
        } else if let value = markValue.integer, value >= 0, value <= positionValue {
            mark = Int(value)
        } else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid ByteBuffer mark")
        }
        return (bytes, Int(positionValue), Int(limitValue), mark)
    }

    private static func byteBufferArgument(_ value: AyuBridgeValue) throws -> Int64 {
        guard let byte = value.integer, (-128...127).contains(byte) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid signed byte")
        }
        return byte
    }

    private static func byteBufferReceiver(_ state: [String: AyuBridgeValue]) -> AyuBridgeAdapterResult {
        .instance(className: "java.nio.ByteBuffer", state: state)
    }

    static var byteBuffer: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "java.nio.ByteBuffer", staticMethods: [
            "wrap": { args, context in
                guard args.count == 1, args[0].object?["$handle"]?.string != nil else {
                    throw AyuBridgeFailure.unsupported("ByteBuffer.wrap overload")
                }
                let snapshot = try context.snapshot(of: args[0])
                guard snapshot.className == "[B", snapshot.state["component"] == .string("byte"),
                      let bytes = snapshot.state["values"]?.array, bytes.count <= Self.maximumByteBufferBytes,
                      bytes.allSatisfy({ value in value.integer.map { (-128...127).contains($0) } ?? false }) else {
                    throw AyuBridgeFailure("invalid_arguments", "ByteBuffer.wrap requires a bounded byte array")
                }
                return .instance(className: "java.nio.ByteBuffer", state: [
                    "bytes": .array(bytes), "position": .integer(0),
                    "limit": .integer(Int64(bytes.count)), "mark": .null,
                ])
            },
        ], methods: [
            "capacity": { state, args, _ in
                try Self.arity(args, 0); let buffer = try Self.byteBufferParts(state)
                return .value(.integer(Int64(buffer.bytes.count)))
            },
            "position": { state, args, _ in
                let buffer = try Self.byteBufferParts(state)
                switch args.count {
                case 0: return .value(.integer(Int64(buffer.position)))
                case 1:
                    guard let position = args[0].integer, position >= 0, position <= Int64(buffer.limit) else {
                        throw AyuBridgeFailure("invalid_arguments", "ByteBuffer position is out of bounds")
                    }
                    state["position"] = .integer(position)
                    if let mark = buffer.mark, mark > position { state["mark"] = .null }
                    return Self.byteBufferReceiver(state)
                default: throw AyuBridgeFailure.unsupported("ByteBuffer.position overload")
                }
            },
            "limit": { state, args, _ in
                let buffer = try Self.byteBufferParts(state)
                switch args.count {
                case 0: return .value(.integer(Int64(buffer.limit)))
                case 1:
                    guard let limit = args[0].integer, limit >= 0, limit <= Int64(buffer.bytes.count) else {
                        throw AyuBridgeFailure("invalid_arguments", "ByteBuffer limit is out of bounds")
                    }
                    state["limit"] = .integer(limit)
                    if Int64(buffer.position) > limit { state["position"] = .integer(limit) }
                    if let mark = buffer.mark, mark > limit { state["mark"] = .null }
                    return Self.byteBufferReceiver(state)
                default: throw AyuBridgeFailure.unsupported("ByteBuffer.limit overload")
                }
            },
            "remaining": { state, args, _ in
                try Self.arity(args, 0); let buffer = try Self.byteBufferParts(state)
                return .value(.integer(Int64(buffer.limit - buffer.position)))
            },
            "hasRemaining": { state, args, _ in
                try Self.arity(args, 0); let buffer = try Self.byteBufferParts(state)
                return .value(.bool(buffer.position < buffer.limit))
            },
            "get": { state, args, _ in
                let buffer = try Self.byteBufferParts(state)
                switch args.count {
                case 0:
                    guard buffer.position < buffer.limit else { throw AyuBridgeFailure("invalid_state", "ByteBuffer underflow") }
                    state["position"] = .integer(Int64(buffer.position + 1))
                    return .value(buffer.bytes[buffer.position])
                case 1:
                    guard let index = args[0].integer, index >= 0, index < Int64(buffer.limit) else {
                        throw AyuBridgeFailure("invalid_arguments", "ByteBuffer index is out of bounds")
                    }
                    return .value(buffer.bytes[Int(index)])
                default: throw AyuBridgeFailure.unsupported("ByteBuffer.get overload")
                }
            },
            "put": { state, args, _ in
                let buffer = try Self.byteBufferParts(state)
                switch args.count {
                case 1:
                    guard buffer.position < buffer.limit else { throw AyuBridgeFailure("invalid_state", "ByteBuffer overflow") }
                    let byte = try Self.byteBufferArgument(args[0])
                    state["bytes"] = .array(buffer.bytes.enumerated().map { index, value in
                        index == buffer.position ? .integer(byte) : value
                    })
                    state["position"] = .integer(Int64(buffer.position + 1))
                case 2:
                    guard let index = args[0].integer, index >= 0, index < Int64(buffer.limit) else {
                        throw AyuBridgeFailure("invalid_arguments", "ByteBuffer index is out of bounds")
                    }
                    let byte = try Self.byteBufferArgument(args[1])
                    state["bytes"] = .array(buffer.bytes.enumerated().map { $0.offset == Int(index) ? .integer(byte) : $0.element })
                default: throw AyuBridgeFailure.unsupported("ByteBuffer.put overload")
                }
                return Self.byteBufferReceiver(state)
            },
            "flip": { state, args, _ in
                try Self.arity(args, 0); let buffer = try Self.byteBufferParts(state)
                state["limit"] = .integer(Int64(buffer.position)); state["position"] = .integer(0); state["mark"] = .null
                return Self.byteBufferReceiver(state)
            },
            "rewind": { state, args, _ in
                try Self.arity(args, 0); _ = try Self.byteBufferParts(state)
                state["position"] = .integer(0); state["mark"] = .null
                return Self.byteBufferReceiver(state)
            },
            "clear": { state, args, _ in
                try Self.arity(args, 0); let buffer = try Self.byteBufferParts(state)
                state["position"] = .integer(0); state["limit"] = .integer(Int64(buffer.bytes.count)); state["mark"] = .null
                return Self.byteBufferReceiver(state)
            },
            "mark": { state, args, _ in
                try Self.arity(args, 0); let buffer = try Self.byteBufferParts(state)
                state["mark"] = .integer(Int64(buffer.position)); return Self.byteBufferReceiver(state)
            },
            "reset": { state, args, _ in
                try Self.arity(args, 0); let buffer = try Self.byteBufferParts(state)
                guard let mark = buffer.mark else { throw AyuBridgeFailure("invalid_state", "ByteBuffer mark is unset") }
                state["position"] = .integer(Int64(mark)); return Self.byteBufferReceiver(state)
            },
        ], receiverMethods: ["position", "limit", "put", "flip", "rewind", "clear", "mark", "reset"],
           results: ["wrap": "java.nio.ByteBuffer"],
           validateState: { state in _ = try Self.byteBufferParts(state) })
    }

    static var truncateAt: AyuBridgeClassAdapter {
        let modes = ["END", "START", "MIDDLE"]
        return AyuBridgeClassAdapter(name: "android.text.TextUtils$TruncateAt",
            staticFields: Dictionary(uniqueKeysWithValues: modes.map { mode in
                (mode, { _ in AyuBridgeAdapterResult.instance(className: "android.text.TextUtils$TruncateAt", state: ["mode": .string(mode)]) } as AyuBridgeClassAdapter.StaticField)
            }),
            results: Dictionary(uniqueKeysWithValues: modes.map { ($0, "android.text.TextUtils$TruncateAt") }),
            validateState: { state in
                guard state.count == 1, let mode = state["mode"]?.string, modes.contains(mode) else {
                    throw Self.unsupported("TextUtils.TruncateAt")
                }
            })
    }

    static var locale: AyuBridgeClassAdapter {
        @Sendable func snapshot(_ locale: Locale, identifier: String? = nil) -> [String: AyuBridgeValue] {
            let nativeLocale = locale as NSLocale
            return [
                "identifier": .string(identifier ?? locale.identifier),
                "language": .string(nativeLocale.object(forKey: .languageCode) as? String ?? ""),
                "country": .string(nativeLocale.object(forKey: .countryCode) as? String ?? ""),
                "variant": .string(nativeLocale.object(forKey: .variantCode) as? String ?? ""),
            ]
        }
        let presets: [String: String] = [
            "CANADA": "en_CA", "CANADA_FRENCH": "fr_CA", "CHINA": "zh_CN", "CHINESE": "zh",
            "ENGLISH": "en", "FRANCE": "fr_FR", "FRENCH": "fr", "GERMANY": "de_DE", "GERMAN": "de",
            "ITALY": "it_IT", "ITALIAN": "it", "JAPAN": "ja_JP", "JAPANESE": "ja",
            "KOREA": "ko_KR", "KOREAN": "ko", "ROOT": "und", "SIMPLIFIED_CHINESE": "zh_CN",
            "TAIWAN": "zh_TW", "TRADITIONAL_CHINESE": "zh_TW", "UK": "en_GB", "US": "en_US",
        ]
        let staticFields = Dictionary(uniqueKeysWithValues: presets.map { key, identifier in
            (key, { _ in
                .instance(className: "java.util.Locale", state: snapshot(Locale(identifier: identifier)))
            } as AyuBridgeClassAdapter.StaticField)
        })
        return AyuBridgeClassAdapter(name: "java.util.Locale",
            constructor: { args, _ in
                let identifier: String
                switch args.count {
                case 0: return snapshot(Locale.current)
                case 1:
                    guard let value = args[0].string, value.utf8.count <= 128 else { throw AyuBridgeFailure("invalid_arguments", "Invalid Locale identifier") }
                    identifier = value
                case 2, 3:
                    guard args.allSatisfy({ $0.string != nil }), args.allSatisfy({ ($0.string?.utf8.count ?? 129) <= 64 }) else {
                        throw AyuBridgeFailure("invalid_arguments", "Invalid Locale component")
                    }
                    let language = args[0].string ?? ""
                    let country = args[1].string ?? ""
                    let variant = args.count == 3 ? (args[2].string ?? "") : ""
                    if !variant.isEmpty {
                        identifier = language + "_" + country + "_" + variant
                    } else if !country.isEmpty {
                        identifier = language + "_" + country
                    } else {
                        identifier = language
                    }
                default: throw AyuBridgeFailure.unsupported("Locale constructor overload")
                }
                return snapshot(Locale(identifier: identifier), identifier: identifier)
            },
            staticMethods: ["getDefault": { args, _ in
                guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Wrong Locale.getDefault arity") }
                return .instance(className: "java.util.Locale", state: snapshot(Locale.current))
            }],
            staticFields: staticFields,
            methods: [
                "getLanguage": { state, args, _ in try Self.arity(args, 0); return .value(state["language"] ?? .string("")) },
                "getCountry": { state, args, _ in try Self.arity(args, 0); return .value(state["country"] ?? .string("")) },
                "getVariant": { state, args, _ in try Self.arity(args, 0); return .value(state["variant"] ?? .string("")) },
                "getLanguageTag": { state, args, _ in
                    try Self.arity(args, 0)
                    let identifier = state["identifier"]?.string ?? ""
                    guard !identifier.isEmpty else { return .value(.string("und")) }
                    let nativeLocale = Locale(identifier: identifier) as NSLocale
                    let language = nativeLocale.object(forKey: .languageCode) as? String ?? "und"
                    let script = nativeLocale.object(forKey: .scriptCode) as? String
                    let region = nativeLocale.object(forKey: .countryCode) as? String
                    let variant = nativeLocale.object(forKey: .variantCode) as? String
                    return .value(.string(([language] + [script, region, variant].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: "-")))
                },
                "toString": { state, args, _ in try Self.arity(args, 0); return .value(state["identifier"] ?? .string("")) },
            ],
            results: Dictionary(uniqueKeysWithValues: (Array(presets.keys) + ["getDefault"]).map { ($0, "java.util.Locale") }),
            validateState: { state in
                let allowed: Set<String> = ["identifier", "language", "country", "variant"]
                guard Set(state.keys) == allowed,
                      state.values.allSatisfy({ $0.string.map { $0.utf8.count <= 128 } ?? false }) else {
                    throw AyuBridgeFailure("invalid_arguments", "Invalid Locale state")
                }
            })
    }

    static var imageScaleType: AyuBridgeClassAdapter {
        let modes = ["CENTER", "FIT_XY", "FIT_CENTER", "CENTER_INSIDE", "CENTER_CROP", "MATRIX"]
        return AyuBridgeClassAdapter(name: "android.widget.ImageView$ScaleType",
            staticFields: Dictionary(uniqueKeysWithValues: modes.map { mode in
                (mode, { _ in
                    .instance(className: "android.widget.ImageView$ScaleType", state: ["mode": .string(mode)])
                } as AyuBridgeClassAdapter.StaticField)
            }),
            results: Dictionary(uniqueKeysWithValues: modes.map { ($0, "android.widget.ImageView$ScaleType") }),
            validateState: { state in
                guard Set(state.keys) == ["mode"], let mode = state["mode"]?.string, modes.contains(mode) else {
                    throw Self.unsupported("ImageView.ScaleType")
                }
            })
    }

    // MARK: Bounded animation values

    /// These adapters are value-only. They never create a display link or call
    /// Python for each frame; ViewPropertyAnimator consumes the descriptor and
    /// UIKit performs the actual animation on the main thread.
    private static func interpolationInput(_ value: AyuBridgeValue) throws -> Double {
        guard let input = value.number, input.isFinite, (0...1).contains(input) else {
            throw AyuBridgeFailure("invalid_arguments", "Interpolator input must be finite and within 0...1")
        }
        return input
    }

    private static func validateInterpolatorState(_ state: [String: AyuBridgeValue], name: String) throws -> Double {
        guard Set(state.keys) == ["parameter"], let parameter = state["parameter"]?.number,
              parameter.isFinite, (0...10).contains(parameter) else {
            throw AyuBridgeFailure("invalid_state", "Invalid " + name + " state")
        }
        return parameter
    }

    private static func interpolatorAdapter(_ name: String, defaultParameter: Double?, formula: @escaping @Sendable (Double, Double) -> Double) -> AyuBridgeClassAdapter {
        let constructor: AyuBridgeClassAdapter.Constructor = { args, _ in
            guard args.count <= 1 else { throw Self.unsupported(name + " constructor overload") }
            let parameter: Double
            if let defaultParameter {
                if let supplied = args.first?.number {
                    guard supplied.isFinite, (0...10).contains(supplied) else {
                        throw AyuBridgeFailure("invalid_arguments", "Interpolator parameter is out of range")
                    }
                    parameter = supplied
                } else if args.isEmpty {
                    parameter = defaultParameter
                } else {
                    throw AyuBridgeFailure("invalid_arguments", "Interpolator parameter must be numeric")
                }
            } else {
                guard args.isEmpty else { throw Self.unsupported(name + " constructor overload") }
                parameter = 0
            }
            return ["parameter": .number(parameter)]
        }
        return AyuBridgeClassAdapter(name: name, constructor: constructor,
            methods: [
                "getInterpolation": { state, args, _ in
                    try Self.arity(args, 1)
                    let input = try Self.interpolationInput(args[0])
                    let parameter = try Self.validateInterpolatorState(state, name: name)
                    let output = formula(input, parameter)
                    guard output.isFinite else { throw AyuBridgeFailure("invalid_state", "Interpolator result is not finite") }
                    return .value(.number(output))
                },
            ],
            validateState: { state in _ = try Self.validateInterpolatorState(state, name: name) })
    }

    static var linearInterpolator: AyuBridgeClassAdapter {
        self.interpolatorAdapter("android.view.animation.LinearInterpolator", defaultParameter: nil) { input, _ in input }
    }

    static var decelerateInterpolator: AyuBridgeClassAdapter {
        // Android's default constructor uses factor 1.0.
        self.interpolatorAdapter("android.view.animation.DecelerateInterpolator", defaultParameter: 1) { input, factor in
            1 - pow(1 - input, 2 * factor)
        }
    }

    static var overshootInterpolator: AyuBridgeClassAdapter {
        // Android's default constructor uses tension 2.0.
        self.interpolatorAdapter("android.view.animation.OvershootInterpolator", defaultParameter: 2) { input, tension in
            let shifted = input - 1
            return shifted * shifted * ((tension + 1) * shifted + tension) + 1
        }
    }

    static var accelerateDecelerateInterpolator: AyuBridgeClassAdapter {
        self.interpolatorAdapter("android.view.animation.AccelerateDecelerateInterpolator", defaultParameter: nil) { input, _ in
            cos((input + 1) * Double.pi) / 2 + 0.5
        }
    }

    static var accelerateInterpolator: AyuBridgeClassAdapter {
        self.interpolatorAdapter("android.view.animation.AccelerateInterpolator", defaultParameter: 1) { input, factor in
            factor == 1 ? input * input : pow(input, 2 * factor)
        }
    }

    static var anticipateInterpolator: AyuBridgeClassAdapter {
        self.interpolatorAdapter("android.view.animation.AnticipateInterpolator", defaultParameter: 2) { input, tension in
            input * input * ((tension + 1) * input - tension)
        }
    }

    static var anticipateOvershootInterpolator: AyuBridgeClassAdapter {
        // Android multiplies the one-argument tension by 1.5; the stored
        // parameter is the constructor argument, as for the other curves.
        self.interpolatorAdapter("android.view.animation.AnticipateOvershootInterpolator", defaultParameter: 2) { input, tension in
            let scaled = tension * 1.5
            if input < 0.5 {
                let t = input * 2
                return 0.5 * (t * t * ((scaled + 1) * t - scaled))
            }
            let t = input * 2 - 2
            return 0.5 * (t * t * ((scaled + 1) * t + scaled) + 2)
        }
    }

    static var bounceInterpolator: AyuBridgeClassAdapter {
        self.interpolatorAdapter("android.view.animation.BounceInterpolator", defaultParameter: nil) { input, _ in
            let t = input * 1.1226
            func bounce(_ value: Double) -> Double { value * value * 8 }
            if t < 0.3535 { return bounce(t) }
            if t < 0.7408 { return bounce(t - 0.54719) + 0.7 }
            if t < 0.9644 { return bounce(t - 0.8526) + 0.9 }
            return bounce(t - 1.0435) + 0.95
        }
    }

    /// The static capability is useful for plugins that only gate native
    /// ChangeBounds/UIKit animations on Android's global animator setting.
    /// Per-frame ValueAnimator listeners remain intentionally unsupported.
    static var valueAnimator: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.animation.ValueAnimator", staticMethods: [
            "areAnimatorsEnabled": { args, context in
                try Self.arity(args, 0)
                return .value(.bool(context.animationsEnabled()))
            },
        ])
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
            ], results: ["keySet": "java.util.ArrayList"], validateState: { state in try Self.rejectState(["entries"], state: state, className: "android.os.Bundle") })
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
            results: ["setAction": "android.content.Intent", "addCategory": "android.content.Intent", "addFlags": "android.content.Intent"],
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
            ], results: ["parse": "android.net.Uri"], validateState: { state in
                guard Set(state.keys) == ["value"] else { throw AyuBridgeFailure("invalid_arguments", "Invalid URI state") }
                _ = try Self.uriString(state)
                _ = try Self.uriComponents(state)
            })
    }

    private static func uriString(_ state: [String: AyuBridgeValue]) throws -> String {
        guard let value = state["value"]?.string, value.utf8.count <= 8_192 else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid URI value")
        }
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

    // MARK: Paint value model (rendering is deliberately not implied)

    private static let paintName = "android.graphics.Paint"
    private static let paintStyleName = "android.graphics.Paint$Style"
    private static let paintCapName = "android.graphics.Paint$Cap"
    private static let paintJoinName = "android.graphics.Paint$Join"
    private static let paintFlags: Int64 = 0x07
    private static let paintStyles = ["FILL", "STROKE", "FILL_AND_STROKE"]
    private static let paintCaps = ["BUTT", "ROUND", "SQUARE"]
    private static let paintJoins = ["MITER", "ROUND", "BEVEL"]

    private static func paintDefaultState(flags: Int64 = 0) -> [String: AyuBridgeValue] {
        ["flags": .integer(flags),
         "color": .integer(Int64(Int32(bitPattern: 0xFF00_0000))),
         "stroke_width": .number(0), "text_size": .number(12),
         "style": .string("FILL"), "cap": .string("BUTT"), "join": .string("MITER"),
         "anti_alias": .bool(flags & 1 != 0), "filter_bitmap": .bool(flags & 2 != 0),
         "dither": .bool(flags & 4 != 0)]
    }

    private static func paintEnum(_ name: String, values: [String]) -> AyuBridgeClassAdapter {
        let fields = Dictionary(uniqueKeysWithValues: values.map { value in
            (value, { _ in AyuBridgeAdapterResult.instance(className: name, state: ["value": .string(value)]) } as AyuBridgeClassAdapter.StaticField)
        })
        return AyuBridgeClassAdapter(name: name, staticFields: fields, results: Dictionary(uniqueKeysWithValues: values.map { ($0, name) }), validateState: { state in
            guard Set(state.keys) == ["value"], let value = state["value"]?.string, values.contains(value) else {
                throw Self.unsupported(name)
            }
        })
    }

    private static func paintEnumValue(_ reference: AyuBridgeValue, name: String, allowed: [String], context: AyuBridgeAdapterContext) throws -> String {
        let snapshot = try context.snapshot(of: reference)
        guard snapshot.className == name, Set(snapshot.state.keys) == ["value"],
              let value = snapshot.state["value"]?.string, allowed.contains(value) else {
            throw AyuBridgeFailure.unsupported(name + " value")
        }
        return value
    }

    private static func paintState(_ state: [String: AyuBridgeValue]) throws -> [String: AyuBridgeValue] {
        if let typeface = state["typeface"]?.object { _ = try AyuBridgeTypefaceValue(state: typeface) }
        guard Set(state.keys).subtracting(state["typeface"]?.object == nil ? [] : ["typeface"]) == ["flags", "color", "stroke_width", "text_size", "style", "cap", "join", "anti_alias", "filter_bitmap", "dither"],
              let flags = state["flags"]?.integer, flags >= 0, flags & ~Self.paintFlags == 0,
              let color = state["color"]?.integer, (Int64(Int32.min)...Int64(Int32.max)).contains(color),
              let strokeWidth = state["stroke_width"]?.number, strokeWidth.isFinite, (0...10_000).contains(strokeWidth),
              let textSize = state["text_size"]?.number, textSize.isFinite, (0...10_000).contains(textSize),
              let style = state["style"]?.string, Self.paintStyles.contains(style),
              let cap = state["cap"]?.string, Self.paintCaps.contains(cap),
              let join = state["join"]?.string, Self.paintJoins.contains(join),
              let antiAlias = state["anti_alias"]?.bool, let filterBitmap = state["filter_bitmap"]?.bool,
              let dither = state["dither"]?.bool,
              antiAlias == (flags & 1 != 0), filterBitmap == (flags & 2 != 0), dither == (flags & 4 != 0) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid Paint value state")
        }
        return state
    }

    private static func paintToggle(_ flag: Int64, field: String) -> AyuBridgeClassAdapter.InstanceMethod {
        { state, args, _ in
            try Self.arity(args, 1)
            let enabled = try Self.bool(args[0], field)
            var flags = state["flags"]?.integer ?? 1
            flags = enabled ? flags | flag : flags & ~flag
            state["flags"] = .integer(flags)
            state[field] = .bool(enabled)
            return .value(.null)
        }
    }

    static var paint: AyuBridgeClassAdapter {
        let defaults = Self.paintDefaultState()
        let copy: AyuBridgeClassAdapter.InstanceMethod = { state, args, context in
            try Self.arity(args, 1)
            let snapshot = try context.snapshot(of: args[0])
            guard snapshot.className == Self.paintName else { throw AyuBridgeFailure.unsupported("Paint.set overload") }
            state = try Self.paintState(snapshot.state)
            return .value(.null)
        }
        let styleGet: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            return .instance(className: Self.paintStyleName, state: ["value": state["style"] ?? .string("FILL")])
        }
        let capGet: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            return .instance(className: Self.paintCapName, state: ["value": state["cap"] ?? .string("BUTT")])
        }
        let joinGet: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            return .instance(className: Self.paintJoinName, state: ["value": state["join"] ?? .string("MITER")])
        }
        return AyuBridgeClassAdapter(name: Self.paintName,
            constants: ["ANTI_ALIAS_FLAG": .integer(1), "FILTER_BITMAP_FLAG": .integer(2), "DITHER_FLAG": .integer(4)],
            constructor: { args, context in
                if args.isEmpty { return defaults }
                guard args.count == 1 else { throw AyuBridgeFailure.unsupported("Paint constructor overload") }
                if let flags = args[0].integer {
                    guard flags >= 0, flags & ~Self.paintFlags == 0 else { throw AyuBridgeFailure.unsupported("Paint flags") }
                    return Self.paintDefaultState(flags: flags)
                }
                let snapshot = try context.snapshot(of: args[0])
                guard snapshot.className == Self.paintName else { throw AyuBridgeFailure.unsupported("Paint constructor overload") }
                return try Self.paintState(snapshot.state)
            }, methods: [
                "set": copy,
            "reset": { state, args, _ in try Self.arity(args, 0); state = Self.paintDefaultState(); return .value(.null) },
                "setColor": { state, args, _ in
                    try Self.arity(args, 1)
                    guard let color = args[0].integer, (Int64(Int32.min)...Int64(Int32.max)).contains(color) else { throw Self.unsupported("Paint.setColor") }
                    state["color"] = .integer(color); return .value(.null)
                },
                "setARGB": { state, args, _ in
                    try Self.arity(args, 4)
                    let components = try args.map { value -> UInt32 in
                        guard let component = value.integer, (0...255).contains(component) else {
                            throw AyuBridgeFailure("invalid_arguments", "Paint.setARGB components must be in 0...255")
                        }
                        return UInt32(component)
                    }
                    let bits = (components[0] << 24) | (components[1] << 16) | (components[2] << 8) | components[3]
                    state["color"] = .integer(Int64(Int32(bitPattern: bits)))
                    return .value(.null)
                },
                "getColor": { state, args, _ in try Self.arity(args, 0); return .value(state["color"] ?? defaults["color"]!) },
                "setAlpha": { state, args, _ in
                    try Self.arity(args, 1)
                    guard let alpha = args[0].integer, (0...255).contains(alpha) else { throw Self.unsupported("Paint.setAlpha") }
                    let color = Int32(truncatingIfNeeded: state["color"]?.integer ?? defaults["color"]!.integer!)
                    let bits = (UInt32(bitPattern: color) & 0x00FF_FFFF) | (UInt32(alpha) << 24)
                    state["color"] = .integer(Int64(Int32(bitPattern: bits))); return .value(.null)
                },
                "getAlpha": { state, args, _ in
                    try Self.arity(args, 0)
                    let color = UInt32(bitPattern: Int32(truncatingIfNeeded: state["color"]?.integer ?? 0))
                    return .value(.integer(Int64((color >> 24) & 0xFF)))
                },
                "setStrokeWidth": { state, args, _ in
                    try Self.arity(args, 1)
                    let width = args[0].number ?? args[0].integer.map(Double.init)
                    guard let width, width.isFinite, (0...10_000).contains(width) else { throw Self.unsupported("Paint.setStrokeWidth") }
                    state["stroke_width"] = .number(Double(Float(width))); return .value(.null)
                },
                "getStrokeWidth": { state, args, _ in try Self.arity(args, 0); return .value(state["stroke_width"] ?? .number(0)) },
                "setTextSize": { state, args, _ in
                    try Self.arity(args, 1)
                    let size = args[0].number ?? args[0].integer.map(Double.init)
                    guard let size, size.isFinite, (0...10_000).contains(size) else { throw Self.unsupported("Paint.setTextSize") }
                    state["text_size"] = .number(Double(Float(size))); return .value(.null)
                },
                "getTextSize": { state, args, _ in try Self.arity(args, 0); return .value(state["text_size"] ?? .number(12)) },
                "setStyle": { state, args, context in
                    try Self.arity(args, 1); state["style"] = .string(try Self.paintEnumValue(args[0], name: Self.paintStyleName, allowed: Self.paintStyles, context: context)); return .value(.null)
                },
                "getStyle": styleGet,
                "setStrokeCap": { state, args, context in
                    try Self.arity(args, 1); state["cap"] = .string(try Self.paintEnumValue(args[0], name: Self.paintCapName, allowed: Self.paintCaps, context: context)); return .value(.null)
                },
                "getStrokeCap": capGet,
                "setStrokeJoin": { state, args, context in
                    try Self.arity(args, 1); state["join"] = .string(try Self.paintEnumValue(args[0], name: Self.paintJoinName, allowed: Self.paintJoins, context: context)); return .value(.null)
                },
                "getStrokeJoin": joinGet,
                "setAntiAlias": Self.paintToggle(1, field: "anti_alias"),
                "isAntiAlias": { state, args, _ in try Self.arity(args, 0); return .value(state["anti_alias"] ?? .bool(false)) },
                "setFilterBitmap": Self.paintToggle(2, field: "filter_bitmap"),
                "isFilterBitmap": { state, args, _ in try Self.arity(args, 0); return .value(state["filter_bitmap"] ?? .bool(false)) },
                "setDither": Self.paintToggle(4, field: "dither"),
                "isDither": { state, args, _ in try Self.arity(args, 0); return .value(state["dither"] ?? .bool(false)) },
                "getFlags": { state, args, _ in try Self.arity(args, 0); return .value(state["flags"] ?? .integer(1)) },
                "setTypeface": { state, args, context in
                    try Self.arity(args, 1)
                    // Android returns its argument; the result here is an equal Typeface, not the same object.
                    let typeface = try AyuBridgeTypefaceValue.argument(args[0], context: context)
                    state["typeface"] = typeface.map { .object($0.state) }
                    return typeface.map { .instance(className: AyuBridgeTypefaceValue.className, state: $0.state) } ?? .value(.null)
                },
                "getTypeface": { state, args, _ in
                    try Self.arity(args, 0)
                    guard let typeface = state["typeface"]?.object else { return .value(.null) }
                    return .instance(className: AyuBridgeTypefaceValue.className, state: typeface)
                },
                "hasGlyph": { state, args, _ in
                    try Self.arity(args, 1)
                    guard let text = args[0].string else { throw AyuBridgeFailure("invalid_arguments", "Paint.hasGlyph expects a string") }
                    let typeface = try state["typeface"]?.object.map { try AyuBridgeTypefaceValue(state: $0) } ?? .default
                    return .value(.bool(AyuBridgeGlyphCoverage.hasGlyph(text, typeface: typeface)))
                },
            ], results: ["setTypeface": "android.graphics.Typeface", "getTypeface": "android.graphics.Typeface",
                         "getStyle": Self.paintStyleName, "getStrokeCap": Self.paintCapName, "getStrokeJoin": Self.paintJoinName],
               validateState: { _ = try Self.paintState($0) })
    }

    static var paintStyle: AyuBridgeClassAdapter { Self.paintEnum(Self.paintStyleName, values: Self.paintStyles) }
    static var paintCap: AyuBridgeClassAdapter { Self.paintEnum(Self.paintCapName, values: Self.paintCaps) }
    static var paintJoin: AyuBridgeClassAdapter { Self.paintEnum(Self.paintJoinName, values: Self.paintJoins) }

    // MARK: Porter-Duff SRC_IN tint value subset

    private static let porterDuffModeName = "android.graphics.PorterDuff$Mode"
    private static let porterDuffModeValues = ["SRC_IN"]
    private static let porterDuffColorFilterName = "android.graphics.PorterDuffColorFilter"

    static var porterDuffMode: AyuBridgeClassAdapter {
        Self.paintEnum(Self.porterDuffModeName, values: Self.porterDuffModeValues)
    }

    static var porterDuffColorFilter: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: Self.porterDuffColorFilterName,
            constructor: { args, context in
                try Self.arity(args, 2)
                let color = try Self.colorInteger(args[0], "ARGB color")
                let mode = try context.snapshot(of: args[1])
                guard mode.className == Self.porterDuffModeName,
                      Set(mode.state.keys) == ["value"],
                      mode.state["value"]?.string == "SRC_IN" else {
                    throw AyuBridgeFailure.unsupported("PorterDuffColorFilter mode")
                }
                return ["color": .integer(color), "mode": .string("SRC_IN")]
            }, methods: [
                "getColor": { state, args, _ in
                    try Self.arity(args, 0)
                    return .value(state["color"] ?? .null)
                },
                "getMode": { state, args, _ in
                    try Self.arity(args, 0)
                    guard state["mode"]?.string == "SRC_IN" else {
                        throw AyuBridgeFailure("invalid_state", "Invalid PorterDuffColorFilter mode")
                    }
                    return .instance(className: Self.porterDuffModeName, state: ["value": .string("SRC_IN")])
                },
            ], results: ["getMode": Self.porterDuffModeName], validateState: { state in
                try Self.rejectState(["color", "mode"], state: state, className: Self.porterDuffColorFilterName)
                _ = try Self.colorInteger(state["color"] ?? .null, "ARGB color")
                guard state["mode"]?.string == "SRC_IN" else {
                    throw AyuBridgeFailure("invalid_arguments", "Unsupported PorterDuffColorFilter mode")
                }
            })
    }

    // MARK: Bounded Path command values (no Canvas renderer)

    private static let pathName = "android.graphics.Path"
    private static let maximumPathCommands = 1_024

    private static func pathDefaultState() -> [String: AyuBridgeValue] {
        ["commands": .array([]), "current": .array([.number(0), .number(0)]),
         "start": .array([.number(0), .number(0)]), "has_current": .bool(false)]
    }

    private static func pathCoordinate(_ value: AyuBridgeValue) throws -> Double {
        let raw = value.number ?? value.integer.map(Double.init)
        guard let raw, raw.isFinite, abs(raw) <= 10_000_000 else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid Path coordinate")
        }
        let coordinate = Float(raw)
        guard coordinate.isFinite else { throw AyuBridgeFailure("invalid_arguments", "Invalid Path coordinate") }
        return Double(coordinate)
    }

    private static func pathPair(_ values: [AyuBridgeValue]?) throws -> (Double, Double) {
        guard let values, values.count == 2 else { throw AyuBridgeFailure("invalid_arguments", "Invalid Path point") }
        return (try Self.pathCoordinate(values[0]), try Self.pathCoordinate(values[1]))
    }

    private static func validatePath(_ state: [String: AyuBridgeValue]) throws {
        guard Set(state.keys) == ["commands", "current", "start", "has_current"],
              let commands = state["commands"]?.array, commands.count <= Self.maximumPathCommands,
              let hasCurrent = state["has_current"]?.bool else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid Path state")
        }
        _ = try Self.pathPair(state["current"]?.array)
        _ = try Self.pathPair(state["start"]?.array)
        for command in commands {
            guard let object = command.object, let operation = object["op"]?.string else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid Path command")
            }
            switch operation {
            case "move", "line":
                guard Set(object.keys) == ["op", "x", "y"] else { throw AyuBridgeFailure("invalid_arguments", "Invalid Path command") }
                _ = try Self.pathCoordinate(object["x"] ?? .null)
                _ = try Self.pathCoordinate(object["y"] ?? .null)
            case "close":
                guard Set(object.keys) == ["op"] else { throw AyuBridgeFailure("invalid_arguments", "Invalid Path command") }
            default: throw AyuBridgeFailure("invalid_arguments", "Invalid Path command")
            }
        }
        if !hasCurrent && !commands.isEmpty {
            throw AyuBridgeFailure("invalid_arguments", "Inconsistent Path state")
        }
    }

    private static func appendPathCommand(_ state: inout [String: AyuBridgeValue], _ command: [String: AyuBridgeValue]) throws {
        var commands = state["commands"]?.array ?? []
        guard commands.count < Self.maximumPathCommands else { throw AyuBridgeFailure("resource_limit", "Path command limit exceeded") }
        commands.append(.object(command))
        state["commands"] = .array(commands)
    }

    static var path: AyuBridgeClassAdapter {
        let constructor: AyuBridgeClassAdapter.Constructor = { args, context in
            if args.isEmpty { return Self.pathDefaultState() }
            try Self.arity(args, 1)
            let snapshot = try context.snapshot(of: args[0])
            guard snapshot.className == Self.pathName else { throw AyuBridgeFailure.unsupported("Path constructor overload") }
            try Self.validatePath(snapshot.state)
            return snapshot.state
        }
        let set: AyuBridgeClassAdapter.InstanceMethod = { state, args, context in
            try Self.arity(args, 1)
            let snapshot = try context.snapshot(of: args[0])
            guard snapshot.className == Self.pathName else { throw AyuBridgeFailure.unsupported("Path.set overload") }
            try Self.validatePath(snapshot.state)
            state = snapshot.state
            return .instance(className: Self.pathName, state: state)
        }
        let moveTo: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            guard args.count == 2 else { throw AyuBridgeFailure.unsupported("Path.moveTo overload") }
            let x = try Self.pathCoordinate(args[0]); let y = try Self.pathCoordinate(args[1])
            try Self.appendPathCommand(&state, ["op": .string("move"), "x": .number(x), "y": .number(y)])
            state["current"] = .array([.number(x), .number(y)])
            state["start"] = .array([.number(x), .number(y)])
            state["has_current"] = .bool(true)
            return .instance(className: Self.pathName, state: state)
        }
        let lineTo: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            guard args.count == 2 else { throw AyuBridgeFailure.unsupported("Path.lineTo overload") }
            let x = try Self.pathCoordinate(args[0]); let y = try Self.pathCoordinate(args[1])
            if state["has_current"]?.bool != true {
                guard (state["commands"]?.array?.count ?? 0) <= Self.maximumPathCommands - 2 else {
                    throw AyuBridgeFailure("resource_limit", "Path command limit exceeded")
                }
                try Self.appendPathCommand(&state, ["op": .string("move"), "x": .number(0), "y": .number(0)])
                state["current"] = .array([.number(0), .number(0)])
                state["start"] = .array([.number(0), .number(0)])
                state["has_current"] = .bool(true)
            } else if state["commands"]?.array?.last?.object?["op"]?.string == "close" {
                // Skia begins a new contour from the previous contour's start
                // when a segment follows close().
                guard (state["commands"]?.array?.count ?? 0) <= Self.maximumPathCommands - 2 else {
                    throw AyuBridgeFailure("resource_limit", "Path command limit exceeded")
                }
                try Self.appendPathCommand(&state, ["op": .string("move"), "x": state["start"]?.array?[0] ?? .number(0), "y": state["start"]?.array?[1] ?? .number(0)])
            }
            try Self.appendPathCommand(&state, ["op": .string("line"), "x": .number(x), "y": .number(y)])
            state["current"] = .array([.number(x), .number(y)])
            return .instance(className: Self.pathName, state: state)
        }
        let close: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            guard state["has_current"]?.bool == true else { return .instance(className: Self.pathName, state: state) }
            let start = try Self.pathPair(state["start"]?.array)
            if state["commands"]?.array?.last?.object?["op"]?.string != "close" {
                try Self.appendPathCommand(&state, ["op": .string("close")])
            }
            state["current"] = .array([.number(start.0), .number(start.1)])
            return .instance(className: Self.pathName, state: state)
        }
        let clear: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            state = Self.pathDefaultState()
            return .instance(className: Self.pathName, state: state)
        }
        return AyuBridgeClassAdapter(name: Self.pathName, constructor: constructor, methods: [
            "set": set, "moveTo": moveTo, "lineTo": lineTo, "close": close,
            "reset": clear, "rewind": clear,
            "isEmpty": { state, args, _ in
                try Self.arity(args, 0)
                let commands = state["commands"]?.array ?? []
                return .value(.bool(commands.isEmpty))
            },
        ], receiverMethods: ["set", "moveTo", "lineTo", "close", "reset", "rewind"],
           validateState: { try Self.validatePath($0) })
    }

    // MARK: Bounded affine Matrix subset

    private static let matrixName = "android.graphics.Matrix"
    private static let matrixIdentity = [1.0, 0, 0, 0, 1, 0, 0, 0, 1]

    private static func matrixValues(_ state: [String: AyuBridgeValue]) throws -> [Double] {
        guard Set(state.keys) == ["values"], let values = state["values"]?.array, values.count == 9 else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid Matrix state")
        }
        return try values.map { value in
            let raw = value.number ?? value.integer.map(Double.init)
            guard let raw, raw.isFinite, abs(raw) <= 10_000_000, Float(raw).isFinite else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid Matrix state")
            }
            return Double(Float(raw))
        }
    }

    private static func matrixCoordinates(_ args: [AyuBridgeValue], method: String) throws -> (Double, Double) {
        guard args.count == 2 else { throw AyuBridgeFailure.unsupported("Matrix." + method + " overload") }
        func coordinate(_ value: AyuBridgeValue) throws -> Double {
            let raw = value.number ?? value.integer.map(Double.init)
            guard let raw, raw.isFinite, abs(raw) <= 10_000 else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid Matrix coordinate")
            }
            let result = Float(raw)
            guard result.isFinite else { throw AyuBridgeFailure("invalid_arguments", "Invalid Matrix coordinate") }
            return Double(result)
        }
        return (try coordinate(args[0]), try coordinate(args[1]))
    }

    private static func matrixState(_ values: [Double]) throws -> [String: AyuBridgeValue] {
        guard values.count == 9 else { throw AyuBridgeFailure("invalid_arguments", "Invalid Matrix value count") }
        let converted = try values.map { value -> AyuBridgeValue in
            guard value.isFinite, abs(value) <= 10_000_000, Float(value).isFinite else {
                throw AyuBridgeFailure("resource_limit", "Matrix values exceed bounds")
            }
            return .number(Double(Float(value)))
        }
        return ["values": .array(converted)]
    }

    static var matrix: AyuBridgeClassAdapter {
        let constructor: AyuBridgeClassAdapter.Constructor = { args, context in
            if args.isEmpty { return try Self.matrixState(Self.matrixIdentity) }
            try Self.arity(args, 1)
            let snapshot = try context.snapshot(of: args[0])
            guard snapshot.className == Self.matrixName else { throw AyuBridgeFailure.unsupported("Matrix constructor overload") }
            _ = try Self.matrixValues(snapshot.state)
            return snapshot.state
        }
        let set: AyuBridgeClassAdapter.InstanceMethod = { state, args, context in
            try Self.arity(args, 1)
            let snapshot = try context.snapshot(of: args[0])
            guard snapshot.className == Self.matrixName else { throw AyuBridgeFailure.unsupported("Matrix.set overload") }
            _ = try Self.matrixValues(snapshot.state)
            state = snapshot.state
            return .instance(className: Self.matrixName, state: state)
        }
        let reset: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            state = try Self.matrixState(Self.matrixIdentity)
            return .instance(className: Self.matrixName, state: state)
        }
        let setTranslate: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            let (dx, dy) = try Self.matrixCoordinates(args, method: "setTranslate")
            state = try Self.matrixState([1, 0, dx, 0, 1, dy, 0, 0, 1])
            return .instance(className: Self.matrixName, state: state)
        }
        let setScale: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            let (sx, sy) = try Self.matrixCoordinates(args, method: "setScale")
            state = try Self.matrixState([sx, 0, 0, 0, sy, 0, 0, 0, 1])
            return .instance(className: Self.matrixName, state: state)
        }
        let postTranslate: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            let (dx, dy) = try Self.matrixCoordinates(args, method: "postTranslate")
            var m = try Self.matrixValues(state)
            m[2] = Double(Float(m[2] + dx * m[8])); m[5] = Double(Float(m[5] + dy * m[8]))
            state = try Self.matrixState(m)
            return .instance(className: Self.matrixName, state: state)
        }
        let postScale: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            let (sx, sy) = try Self.matrixCoordinates(args, method: "postScale")
            var m = try Self.matrixValues(state)
            for index in 0...2 { m[index] = Double(Float(m[index] * sx)) }
            for index in 3...5 { m[index] = Double(Float(m[index] * sy)) }
            state = try Self.matrixState(m)
            return .instance(className: Self.matrixName, state: state)
        }
        let preTranslate: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            let (dx, dy) = try Self.matrixCoordinates(args, method: "preTranslate")
            var m = try Self.matrixValues(state)
            m[2] = Double(Float(m[2] + m[0] * dx + m[1] * dy))
            m[5] = Double(Float(m[5] + m[3] * dx + m[4] * dy))
            state = try Self.matrixState(m)
            return .instance(className: Self.matrixName, state: state)
        }
        let preScale: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            let (sx, sy) = try Self.matrixCoordinates(args, method: "preScale")
            var m = try Self.matrixValues(state)
            for index in [0, 3, 6] { m[index] = Double(Float(m[index] * sx)) }
            for index in [1, 4, 7] { m[index] = Double(Float(m[index] * sy)) }
            state = try Self.matrixState(m)
            return .instance(className: Self.matrixName, state: state)
        }
        let isIdentity: AyuBridgeClassAdapter.InstanceMethod = { state, args, _ in
            try Self.arity(args, 0)
            return .value(.bool(try Self.matrixValues(state) == Self.matrixIdentity))
        }
        return AyuBridgeClassAdapter(name: Self.matrixName, constructor: constructor, methods: [
            "set": set, "reset": reset, "setTranslate": setTranslate, "setScale": setScale,
            "postTranslate": postTranslate, "postScale": postScale, "preTranslate": preTranslate,
            "preScale": preScale, "isIdentity": isIdentity,
        ], receiverMethods: ["set", "reset", "setTranslate", "setScale", "postTranslate", "postScale", "preTranslate", "preScale"],
           validateState: { _ = try Self.matrixValues($0) })
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
            "fuchsia": 0xFFFF_00FF, "darkgrey": 0xFF44_4444, "grey": 0xFF88_8888,
            "lightgrey": 0xFFCC_CCCC, "lime": 0xFF00_FF00, "maroon": 0xFF80_0000,
            "navy": 0xFF00_0080, "olive": 0xFF80_8000, "purple": 0xFF80_0080,
            "silver": 0xFFC0_C0C0, "teal": 0xFF00_8080,
            "transparent": 0x0000_0000,
        ]
        guard let value = names[text.lowercased()] else { throw AyuBridgeFailure("invalid_arguments", "Invalid color string") }
        return .integer(Int64(Int32(bitPattern: value)))
    }
    private static func colorByte(_ value: AyuBridgeValue, shift: UInt32) throws -> AyuBridgeValue {
        let color = UInt32(truncatingIfNeeded: try Self.colorInteger(value, "ARGB color"))
        return .integer(Int64((color >> shift) & 255))
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
                "alpha": { args, _ in try Self.arity(args, 1); return .value(try Self.colorByte(args[0], shift: 24)) },
                "red": { args, _ in try Self.arity(args, 1); return .value(try Self.colorByte(args[0], shift: 16)) },
                "green": { args, _ in try Self.arity(args, 1); return .value(try Self.colorByte(args[0], shift: 8)) },
                "blue": { args, _ in try Self.arity(args, 1); return .value(try Self.colorByte(args[0], shift: 0)) },
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

    static var viewConfiguration: AyuBridgeClassAdapter {
        let state = ["scaled_touch_slop": AyuBridgeValue.integer(8)]
        return AyuBridgeClassAdapter(name: "android.view.ViewConfiguration",
            staticMethods: [
                "get": { args, context in
                    try Self.arity(args, 1)
                    let snapshot = try context.snapshot(of: args[0])
                    guard snapshot.className == "android.content.Context" else {
                        throw Self.unsupported("ViewConfiguration.get Context")
                    }
                    return .instance(className: "android.view.ViewConfiguration", state: state)
                },
                "getLongPressTimeout": { args, _ in
                    try Self.arity(args, 0)
                    return .value(.integer(500))
                },
            ],
            methods: [
                "getScaledTouchSlop": { current, args, _ in
                    try Self.arity(args, 0)
                    guard current == state else { throw AyuBridgeFailure("invalid_state", "Invalid ViewConfiguration state") }
                    return .value(.integer(8))
                },
            ],
            results: ["get": "android.view.ViewConfiguration"],
            validateState: { current in
                guard current == state else { throw AyuBridgeFailure("invalid_state", "Invalid ViewConfiguration state") }
            })
    }

    static var systemClock: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.os.SystemClock", staticMethods: [
            "uptimeMillis": { args, _ in
                try Self.arity(args, 0)
                let uptimeMilliseconds = ProcessInfo.processInfo.systemUptime * 1_000
                guard uptimeMilliseconds.isFinite, uptimeMilliseconds >= 0,
                      uptimeMilliseconds < Double(Int64.max) else {
                    throw AyuBridgeFailure("invalid_state", "Monotonic clock value is out of range")
                }
                return .value(.integer(Int64(uptimeMilliseconds)))
            },
        ])
    }

    private static let measureSpecModeMask: UInt32 = 0xC000_0000
    private static let measureSpecSizeMask: UInt32 = 0x3FFF_FFFF
    private static let measureSpecExactly = Int32(1 << 30)
    private static let measureSpecAtMost = Int32(bitPattern: 0x8000_0000)
    private static let measureSpecMask = Int32(bitPattern: 0xC000_0000)

    private static func measureSpecInt(_ value: AyuBridgeValue) throws -> Int32 {
        guard let raw = value.integer, let converted = Int32(exactly: raw) else {
            throw AyuBridgeFailure("invalid_arguments", "MeasureSpec requires a signed 32-bit integer")
        }
        return converted
    }

    static var measureSpec: AyuBridgeClassAdapter {
        AyuBridgeClassAdapter(name: "android.view.View$MeasureSpec",
            constants: [
                "MODE_SHIFT": .integer(30),
                "MODE_MASK": .integer(Int64(Self.measureSpecMask)),
                "UNSPECIFIED": .integer(0),
                "EXACTLY": .integer(Int64(Self.measureSpecExactly)),
                "AT_MOST": .integer(Int64(Self.measureSpecAtMost)),
            ],
            staticMethods: [
                "makeMeasureSpec": { args, _ in
                    try Self.arity(args, 2)
                    guard let size = args[0].integer,
                          (0...Int64(Self.measureSpecSizeMask)).contains(size) else {
                        throw AyuBridgeFailure("invalid_arguments", "MeasureSpec size is out of range")
                    }
                    let mode = try Self.measureSpecInt(args[1])
                    guard [Int32(0), Self.measureSpecExactly, Self.measureSpecAtMost].contains(mode) else {
                        throw AyuBridgeFailure("invalid_arguments", "Unsupported MeasureSpec mode")
                    }
                    let raw = (UInt32(size) & Self.measureSpecSizeMask) |
                        (UInt32(bitPattern: mode) & Self.measureSpecModeMask)
                    return .value(.integer(Int64(Int32(bitPattern: raw))))
                },
                "getMode": { args, _ in
                    try Self.arity(args, 1)
                    let raw = try Self.measureSpecInt(args[0])
                    let mode = UInt32(bitPattern: raw) & Self.measureSpecModeMask
                    return .value(.integer(Int64(Int32(bitPattern: mode))))
                },
                "getSize": { args, _ in
                    try Self.arity(args, 1)
                    let raw = try Self.measureSpecInt(args[0])
                    let size = UInt32(bitPattern: raw) & Self.measureSpecSizeMask
                    return .value(.integer(Int64(size)))
                },
            ])
    }

    private static func arity(_ arguments: [AyuBridgeValue], _ count: Int) throws {
        guard arguments.count == count else { throw AyuBridgeFailure("invalid_arguments", "Unsupported Java overload") }
    }
}
