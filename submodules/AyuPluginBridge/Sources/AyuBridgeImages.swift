import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// Bounds of the image service, per plugin generation unless noted.
public struct AyuBridgeImageLimits: Sendable {
    public var imagesPerPlugin = 64
    public var bytesPerPlugin = 134_217_728
    /// One image: 4096 x 4096, or any shape with as many pixels.
    public var pixelsPerImage = 16_777_216
    public var sidePixels = 16_384
    public var fontsPerPlugin = 32
    /// An encoded file the host reads; a font file has the same bound.
    public var fileBytes = 67_108_864
    /// Raw pixel bytes of one `image.pixels.get`/`put`; as base64 they fit the 262,144-byte envelope.
    public var transferBytes = 131_072
    /// Images handed to a view that the main thread has not taken yet.
    public var pendingSnapshotsPerPlugin = 256
    public var drawCommands = 256
    public var textBytes = 16_384
    public var pathPoints = 4_096
    public init() {}
}

/// Eight-bit pixels with straight (non-premultiplied) alpha, bands interleaved, rows top to bottom.
struct AyuBridgePixelImage {
    enum Mode: String {
        case l = "L", la = "LA", rgb = "RGB", rgba = "RGBA"
        var bands: Int {
            switch self { case .l: return 1; case .la: return 2; case .rgb: return 3; case .rgba: return 4 }
        }
        var hasAlpha: Bool { self == .la || self == .rgba }
        var colorBands: Int { self.hasAlpha ? self.bands - 1 : self.bands }
    }
    var mode: Mode
    let width: Int
    let height: Int
    var data: [UInt8]

    init(mode: Mode, width: Int, height: Int, data: [UInt8]) {
        precondition(data.count == width * height * mode.bands)
        self.mode = mode; self.width = width; self.height = height; self.data = data
    }

    init(mode: Mode, width: Int, height: Int, color: [UInt8]) {
        let bands = mode.bands
        var data = [UInt8](repeating: color.first ?? 0, count: width * height * bands)
        if bands > 1, Set(color).count > 1 {
            data.withUnsafeMutableBufferPointer { out in
                var index = 0
                while index < out.count {
                    for band in 0..<bands { out[index + band] = color[band] }
                    index += bands
                }
            }
        }
        self.init(mode: mode, width: width, height: height, data: data)
    }
}

/// Plugin-owned images and fonts behind the `image.*` operations.
///
/// The host calls `perform` on its serial worker, never on main, so pixel work blocks only the
/// interpreter that asked for it. Handles are opaque strings scoped to one owner; everything an
/// owner holds is dropped by `removeAll(owner:)` when its generation ends.
public final class AyuBridgeImageService: @unchecked Sendable {
    public static let operations = [
        "image.create", "image.decode", "image.encode", "image.release", "image.copy", "image.convert", "image.band",
        "image.merge", "image.putalpha", "image.pixels.get", "image.pixels.put", "image.point", "image.stats",
        "image.crop", "image.resize", "image.transpose", "image.transform", "image.paste", "image.alpha_composite",
        "image.blend", "image.chop", "image.filter", "image.draw", "image.font.load", "image.font.measure",
    ]

    public let limits: AyuBridgeImageLimits
    private let lock = NSLock()
    private var images: [String: [String: AyuBridgePixelImage]] = [:]
    var fonts: [String: [String: AyuBridgeImageFont]] = [:]

    public init(limits: AyuBridgeImageLimits = AyuBridgeImageLimits()) { self.limits = limits }

    public struct Usage: Equatable, Sendable {
        public let images: Int
        public let bytes: Int
        public let fonts: Int
    }

    public func usage(owner: String) -> Usage {
        self.lock.lock(); defer { self.lock.unlock() }
        let owned = self.images[owner] ?? [:]
        return Usage(images: owned.count, bytes: owned.values.reduce(0) { $0 + $1.data.count }, fonts: self.fonts[owner]?.count ?? 0)
    }

    /// Frees every image, font and pending snapshot of the owner.
    public func removeAll(owner: String) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.images.removeValue(forKey: owner)
        self.fonts.removeValue(forKey: owner)
        AyuBridgeImageSnapshots.shared.discard(service: ObjectIdentifier(self), owner: owner)
    }

    /// The class and value state of an object the plugin owns in the host's registry.
    public typealias Resolver = (AyuBridgeValue) throws -> (className: String, state: [String: AyuBridgeValue])

    /// `resolve` lets `image.draw` commands name a Paint or a Path of the Java facade by reference.
    public func perform(owner: String, operation: String, arguments: [String: AyuBridgeValue], resolve: Resolver? = nil) throws -> AyuBridgeValue {
        self.lock.lock(); defer { self.lock.unlock() }
        let args = AyuBridgeImageArguments(arguments)
        switch operation {
        case "image.create":
            try args.only(["mode", "width", "height", "color"])
            let mode = try args.mode("mode")
            let (width, height) = try self.size(args.int("width"), args.int("height"))
            let color = try args.color("color", mode: mode) ?? [UInt8](repeating: 0, count: mode.bands)
            try self.reserve(owner: owner, bytes: width * height * mode.bands)
            return self.store(AyuBridgePixelImage(mode: mode, width: width, height: height, color: color), owner: owner)
        case "image.decode":
            try args.only(["path", "data", "bounds"])
            let data = try self.input(args)
            if try args.bool("bounds", default: false) {
                // The header only: nothing is decoded or stored, so the pixel quota does not apply.
                let header = try AyuBridgeImageCodec.header(data)
                return .object(["mode": .string(header.mode.rawValue), "width": .integer(Int64(header.width)), "height": .integer(Int64(header.height)),
                                "format": .string(header.format), "orientation": .integer(Int64(header.orientation)), "frames": .integer(Int64(header.frames))])
            }
            let decoded = try AyuBridgeImageCodec.decode(data, limits: self.limits) { bytes in
                try self.reserve(owner: owner, bytes: bytes)
            }
            var result = self.info(self.insert(decoded.image, owner: owner), decoded.image)
            result["format"] = .string(decoded.format)
            result["orientation"] = .integer(Int64(decoded.orientation))
            result["frames"] = .integer(Int64(decoded.frames))
            return .object(result)
        case "image.encode":
            try args.only(["image", "format", "path", "quality"])
            let image = try self.image(args, "image", owner: owner)
            let format = try args.string("format")
            let quality = try args.optionalInt("quality") ?? 75
            guard (0...100).contains(quality) else { throw AyuBridgeFailure("invalid_arguments", "quality must be 0...100") }
            let data = try AyuBridgeImageCodec.encode(image, format: format, quality: quality)
            let path = try args.path("path")
            do { try data.write(to: URL(fileURLWithPath: path), options: .atomic) } catch {
                throw AyuBridgeFailure("io_error", "Cannot write the image file")
            }
            return .object(["bytes": .integer(Int64(data.count))])
        case "image.release":
            try args.only(["images", "fonts"])
            for id in try args.strings("images") { self.images[owner]?.removeValue(forKey: id) }
            for id in try args.strings("fonts") { self.fonts[owner]?.removeValue(forKey: id) }
            return .null
        case "image.copy":
            try args.only(["image"])
            let image = try self.image(args, "image", owner: owner)
            try self.reserve(owner: owner, bytes: image.data.count)
            return self.store(image, owner: owner)
        case "image.convert":
            try args.only(["image", "mode"])
            let image = try self.image(args, "image", owner: owner)
            let mode = try args.mode("mode")
            try self.reserve(owner: owner, bytes: image.width * image.height * mode.bands)
            return self.store(AyuBridgeImageOps.convert(image, to: mode), owner: owner)
        case "image.band":
            try args.only(["image", "band"])
            let image = try self.image(args, "image", owner: owner)
            let band = try args.int("band")
            guard (0..<image.mode.bands).contains(band) else { throw AyuBridgeFailure("invalid_arguments", "band index out of range") }
            try self.reserve(owner: owner, bytes: image.width * image.height)
            return self.store(AyuBridgeImageOps.band(image, band), owner: owner)
        case "image.merge":
            try args.only(["mode", "bands"])
            let mode = try args.mode("mode")
            let bands = try args.strings("bands").map { try self.image($0, owner: owner) }
            guard bands.count == mode.bands, let first = bands.first,
                  bands.allSatisfy({ $0.mode == .l && $0.width == first.width && $0.height == first.height }) else {
                throw AyuBridgeFailure("invalid_arguments", "merge needs one L image of the same size per band")
            }
            try self.reserve(owner: owner, bytes: first.width * first.height * mode.bands)
            return self.store(AyuBridgeImageOps.merge(mode, bands), owner: owner)
        case "image.putalpha":
            try args.only(["image", "alpha"])
            let id = try args.string("image")
            let image = try self.image(id, owner: owner)
            guard let target = AyuBridgePixelImage.Mode(rawValue: image.mode.hasAlpha ? image.mode.rawValue : image.mode.rawValue + "A") else {
                throw AyuBridgeFailure("invalid_arguments", "putalpha is not defined for this mode")
            }
            var alpha: AyuBridgePixelImage?
            var constant: UInt8 = 0
            if let other = arguments["alpha"]?.string {
                let band = try self.image(other, owner: owner)
                guard band.mode == .l, band.width == image.width, band.height == image.height else {
                    throw AyuBridgeFailure("invalid_arguments", "alpha must be an L image of the same size")
                }
                alpha = band
            } else {
                constant = try AyuBridgeImageArguments.byte(arguments["alpha"] ?? .null)
            }
            if target != image.mode { try self.reserve(owner: owner, bytes: image.width * image.height, replacing: 0) }
            var result = target == image.mode ? image : AyuBridgeImageOps.convert(image, to: target)
            AyuBridgeImageOps.setBand(&result, target.bands - 1, from: alpha, constant: constant)
            self.images[owner]?[id] = result
            return .object(self.info(id, result))
        case "image.pixels.get":
            try args.only(["image", "box"])
            let image = try self.image(args, "image", owner: owner)
            let box = try self.pixelBox(args, image)
            return .object(["data": .string(Data(AyuBridgeImageOps.read(image, box)).base64EncodedString())])
        case "image.pixels.put":
            try args.only(["image", "box", "data"])
            let id = try args.string("image")
            var image = try self.image(id, owner: owner)
            let box = try self.pixelBox(args, image)
            guard let data = Data(base64Encoded: try args.string("data")), data.count == box.width * box.height * image.mode.bands else {
                throw AyuBridgeFailure("invalid_arguments", "pixel data does not match the box")
            }
            self.images[owner]?[id] = nil
            AyuBridgeImageOps.write(&image, box, [UInt8](data))
            self.images[owner]?[id] = image
            return .null
        case "image.point":
            try args.only(["image", "table"])
            let image = try self.image(args, "image", owner: owner)
            guard let table = arguments["table"]?.array, table.count == 256 * image.mode.bands else {
                throw AyuBridgeFailure("invalid_arguments", "table needs 256 entries per band")
            }
            let lookup = try table.map(AyuBridgeImageArguments.byte)
            try self.reserve(owner: owner, bytes: image.data.count)
            return self.store(AyuBridgeImageOps.point(image, lookup), owner: owner)
        case "image.stats":
            try args.only(["image", "kind", "max"])
            let image = try self.image(args, "image", owner: owner)
            return try AyuBridgeImageOps.stats(image, kind: try args.string("kind"), maximum: try args.optionalInt("max") ?? 256)
        case "image.crop":
            try args.only(["image", "box"])
            let image = try self.image(args, "image", owner: owner)
            let box = try args.ints("box", count: 4)
            let (width, height) = try self.size(box[2] - box[0], box[3] - box[1])
            try self.reserve(owner: owner, bytes: width * height * image.mode.bands)
            return self.store(AyuBridgeImageOps.crop(image, left: box[0], top: box[1], width: width, height: height), owner: owner)
        case "image.resize":
            try args.only(["image", "width", "height", "filter", "box"])
            let image = try self.image(args, "image", owner: owner)
            let (width, height) = try self.size(args.int("width"), args.int("height"))
            guard let filter = AyuBridgeImageOps.Resampling(rawValue: try args.string("filter")) else {
                throw AyuBridgeFailure.unsupported("image.resize filter")
            }
            var box = [0, 0, Double(image.width), Double(image.height)]
            if arguments["box"] != nil, arguments["box"] != .null {
                box = try args.doubles("box", count: 4)
                guard box[0] >= 0, box[1] >= 0, box[2] <= Double(image.width), box[3] <= Double(image.height), box[2] > box[0], box[3] > box[1] else {
                    throw AyuBridgeFailure("invalid_arguments", "box must lie inside the image and be non-empty")
                }
            }
            try self.reserve(owner: owner, bytes: width * height * image.mode.bands)
            return self.store(AyuBridgeImageOps.resize(image, width: width, height: height, filter: filter, box: box), owner: owner)
        case "image.transpose":
            try args.only(["image", "method"])
            let image = try self.image(args, "image", owner: owner)
            guard let method = AyuBridgeImageOps.Transpose(rawValue: try args.string("method")) else {
                throw AyuBridgeFailure.unsupported("image.transpose method")
            }
            try self.reserve(owner: owner, bytes: image.data.count)
            return self.store(AyuBridgeImageOps.transpose(image, method), owner: owner)
        case "image.transform":
            try args.only(["image", "width", "height", "matrix", "filter", "fill"])
            let image = try self.image(args, "image", owner: owner)
            let (width, height) = try self.size(args.int("width"), args.int("height"))
            let matrix = try args.doubles("matrix", count: 6)
            let name = try args.string("filter")
            guard ["nearest", "bilinear", "bicubic"].contains(name), let filter = AyuBridgeImageOps.Resampling(rawValue: name) else {
                throw AyuBridgeFailure.unsupported("image.transform filter")
            }
            let fill = try args.color("fill", mode: image.mode) ?? [UInt8](repeating: 0, count: image.mode.bands)
            try self.reserve(owner: owner, bytes: width * height * image.mode.bands)
            return self.store(AyuBridgeImageOps.affine(image, width: width, height: height, matrix: matrix, filter: filter, fill: fill), owner: owner)
        case "image.paste":
            try args.only(["image", "source", "color", "box", "mask"])
            let id = try args.string("image")
            var image = try self.image(id, owner: owner)
            let origin = try args.ints("box", count: 2)
            var mask: AyuBridgePixelImage?
            if let maskID = arguments["mask"]?.string {
                let found = try self.image(maskID, owner: owner)
                guard found.mode != .rgb else { throw AyuBridgeFailure("invalid_arguments", "bad transparency mask") }
                mask = found
            }
            var source: AyuBridgePixelImage?
            var color: [UInt8] = []
            if let sourceID = arguments["source"]?.string {
                let found = try self.image(sourceID, owner: owner)
                guard found.mode == image.mode else { throw AyuBridgeFailure("invalid_arguments", "source mode must match the image") }
                source = found
            } else {
                guard let ink = try args.color("color", mode: image.mode), mask != nil else {
                    throw AyuBridgeFailure("invalid_arguments", "paste needs a source image, or a color with a mask")
                }
                color = ink
            }
            if let source, let mask, mask.width != source.width || mask.height != source.height {
                throw AyuBridgeFailure("invalid_arguments", "mask size must match the source")
            }
            self.images[owner]?[id] = nil
            AyuBridgeImageOps.paste(&image, source: source, color: color, x: origin[0], y: origin[1], mask: mask)
            self.images[owner]?[id] = image
            return .null
        case "image.alpha_composite":
            try args.only(["image", "source"])
            let image = try self.image(args, "image", owner: owner)
            let source = try self.image(args, "source", owner: owner)
            guard image.mode == .rgba, source.mode == .rgba, image.width == source.width, image.height == source.height else {
                throw AyuBridgeFailure("invalid_arguments", "images do not match")
            }
            try self.reserve(owner: owner, bytes: image.data.count)
            return self.store(AyuBridgeImageOps.alphaComposite(image, source), owner: owner)
        case "image.blend":
            try args.only(["image", "source", "alpha"])
            let image = try self.image(args, "image", owner: owner)
            let source = try self.image(args, "source", owner: owner)
            let alpha = try args.double("alpha")
            guard image.mode == source.mode, image.width == source.width, image.height == source.height, abs(alpha) <= 1_000 else {
                throw AyuBridgeFailure("invalid_arguments", "images do not match")
            }
            try self.reserve(owner: owner, bytes: image.data.count)
            return self.store(AyuBridgeImageOps.blend(image, source, alpha: alpha), owner: owner)
        case "image.chop":
            try args.only(["image", "source", "kind", "scale", "offset", "dx", "dy"])
            let image = try self.image(args, "image", owner: owner)
            let kind = try args.string("kind")
            if kind == "offset" {
                try self.reserve(owner: owner, bytes: image.data.count)
                return self.store(AyuBridgeImageOps.offset(image, dx: try args.int("dx"), dy: try args.int("dy")), owner: owner)
            }
            let source = try self.image(args, "source", owner: owner)
            guard image.mode == source.mode, ["difference", "multiply", "subtract", "add"].contains(kind) else {
                throw kind.isEmpty || image.mode != source.mode ? AyuBridgeFailure("invalid_arguments", "images do not match") : AyuBridgeFailure.unsupported("image.chop " + kind)
            }
            let scale = try args.optionalDouble("scale") ?? 1
            guard scale != 0, abs(scale) <= 65_536 else { throw AyuBridgeFailure("invalid_arguments", "scale must not be zero") }
            let (width, height) = (min(image.width, source.width), min(image.height, source.height))
            try self.reserve(owner: owner, bytes: width * height * image.mode.bands)
            return self.store(AyuBridgeImageOps.chop(image, source, kind: kind, scale: scale, offset: try args.optionalDouble("offset") ?? 0), owner: owner)
        case "image.filter":
            let image = try self.image(args, "image", owner: owner)
            let filtered = try AyuBridgeImageFilters.apply(image, arguments: args)
            try self.reserve(owner: owner, bytes: filtered.data.count)
            return self.store(filtered, owner: owner)
        case "image.draw":
            try args.only(["image", "commands"])
            let id = try args.string("image")
            var image = try self.image(id, owner: owner)
            guard var commands = arguments["commands"]?.array, commands.count <= self.limits.drawCommands else {
                throw AyuBridgeFailure("resource_limit", "Too many draw commands")
            }
            commands = try commands.map { try Self.resolved($0, resolve) }
            let renderer = AyuBridgeImageRenderer(limits: self.limits, font: { try self.font($0, owner: owner) }, image: { try self.image($0, owner: owner) })
            // Validate the whole list before the first pixel changes.
            let prepared = try commands.map { try renderer.prepare($0, target: image) }
            self.images[owner]?[id] = nil
            for command in prepared { renderer.draw(command, into: &image) }
            self.images[owner]?[id] = image
            return .null
        case "image.font.load":
            try args.only(["path", "size", "index"])
            let size = try args.double("size")
            guard size >= 1, size <= 2_048 else { throw AyuBridgeFailure("invalid_arguments", "font size must be 1...2048") }
            guard (self.fonts[owner]?.count ?? 0) < self.limits.fontsPerPlugin else { throw AyuBridgeFailure("resource_limit", "Font quota exceeded") }
            let font: AyuBridgeImageFont
            if arguments["path"] == nil || arguments["path"] == .null {
                font = AyuBridgeImageFont.system(size: size)
            } else {
                font = try AyuBridgeImageFont.file(path: try args.path("path"), size: size, index: try args.optionalInt("index") ?? 0, limit: self.limits.fileBytes)
            }
            let id = UUID().uuidString
            self.fonts[owner, default: [:]][id] = font
            var result = font.description
            result["font"] = .string(id)
            return .object(result)
        case "image.font.measure":
            try args.only(["font", "text", "stroke_width"])
            let font = try self.font(try args.string("font"), owner: owner)
            let text = try args.string("text")
            guard text.utf8.count <= self.limits.textBytes else { throw AyuBridgeFailure("resource_limit", "Text is too long") }
            let stroke = try args.optionalDouble("stroke_width") ?? 0
            guard stroke >= 0, stroke <= 256 else { throw AyuBridgeFailure("invalid_arguments", "Invalid stroke width") }
            return font.measure(text, stroke: stroke)
        default:
            throw AyuBridgeFailure.unsupported(operation)
        }
    }

    // MARK: Snapshots for views

    /// An immutable copy of the image for the view `view`, made on the caller's (worker) thread
    /// and redeemed once on main through `AyuBridgeImageSnapshots`. `budget` is what the copy
    /// may take of the plugin's decoded-image quota.
    public func snapshot(owner: String, image id: String, view: String, budget: Int) throws -> (token: String, bytes: Int) {
        self.lock.lock(); defer { self.lock.unlock() }
        let image = try self.image(id, owner: owner)
        let bytes = image.width * image.height * (image.mode == .l ? 1 : 4)
        guard bytes <= budget else { throw AyuBridgeFailure("resource_limit", "Plugin image memory quota exceeded") }
        let token = try AyuBridgeImageSnapshots.shared.put(try AyuBridgeImageCodec.cgImage(image), service: ObjectIdentifier(self), owner: owner, view: view,
                                                           limit: self.limits.pendingSnapshotsPerPlugin)
        return (token, bytes)
    }

    /// Replaces references to host objects in a draw command by their state.
    private static func resolved(_ command: AyuBridgeValue, _ resolve: Resolver?) throws -> AyuBridgeValue {
        guard var fields = command.object else { return command }
        if let paint = fields["paint"], paint["$handle"] != .null {
            guard let resolve else { throw AyuBridgeFailure.unsupported("image.draw paint reference") }
            let object = try resolve(paint)
            guard object.className == "android.graphics.Paint" else { throw AyuBridgeFailure("invalid_arguments", "Expected a Paint") }
            fields["paint"] = .object(object.state)
        }
        if let path = fields["path"] {
            guard let resolve, fields["segments"] == nil else { throw AyuBridgeFailure.unsupported("image.draw path reference") }
            let object = try resolve(path)
            guard object.className == "android.graphics.Path", let commands = object.state["commands"]?.array else {
                throw AyuBridgeFailure("invalid_arguments", "Expected a Path")
            }
            fields["path"] = nil
            fields["segments"] = .array(commands.map { item in
                switch item["op"].string {
                case "move": return .array([.string("M"), item["x"], item["y"]])
                case "line": return .array([.string("L"), item["x"], item["y"]])
                default: return .array([.string("Z")])
                }
            })
        }
        return .object(fields)
    }

    // MARK: Store

    private func size(_ width: Int, _ height: Int) throws -> (Int, Int) {
        guard width > 0, height > 0 else { throw AyuBridgeFailure("invalid_arguments", "Image size must be positive") }
        guard width <= self.limits.sidePixels, height <= self.limits.sidePixels, width * height <= self.limits.pixelsPerImage else {
            throw AyuBridgeFailure("resource_limit", "Image is too large")
        }
        return (width, height)
    }

    /// Checks that one more image of `bytes` fits (`replacing: 0` grows an existing image instead).
    private func reserve(owner: String, bytes: Int, replacing: Int? = nil) throws {
        let owned = self.images[owner] ?? [:]
        if replacing == nil, owned.count >= self.limits.imagesPerPlugin { throw AyuBridgeFailure("resource_limit", "Image count quota exceeded") }
        let used = owned.values.reduce(0) { $0 + $1.data.count }
        guard bytes <= self.limits.bytesPerPlugin - used else { throw AyuBridgeFailure("resource_limit", "Image memory quota exceeded") }
    }

    private func insert(_ image: AyuBridgePixelImage, owner: String) -> String {
        let id = UUID().uuidString
        self.images[owner, default: [:]][id] = image
        return id
    }

    private func store(_ image: AyuBridgePixelImage, owner: String) -> AyuBridgeValue {
        .object(self.info(self.insert(image, owner: owner), image))
    }

    private func info(_ id: String, _ image: AyuBridgePixelImage) -> [String: AyuBridgeValue] {
        ["image": .string(id), "mode": .string(image.mode.rawValue), "width": .integer(Int64(image.width)), "height": .integer(Int64(image.height))]
    }

    private func image(_ id: String, owner: String) throws -> AyuBridgePixelImage {
        guard let image = self.images[owner]?[id] else { throw AyuBridgeFailure("invalid_handle", "Unknown image for this plugin") }
        return image
    }

    private func image(_ args: AyuBridgeImageArguments, _ key: String, owner: String) throws -> AyuBridgePixelImage {
        try self.image(try args.string(key), owner: owner)
    }

    private func font(_ id: String, owner: String) throws -> AyuBridgeImageFont {
        guard let font = self.fonts[owner]?[id] else { throw AyuBridgeFailure("invalid_handle", "Unknown font for this plugin") }
        return font
    }

    private func pixelBox(_ args: AyuBridgeImageArguments, _ image: AyuBridgePixelImage) throws -> AyuBridgeImageOps.Box {
        let box = try args.ints("box", count: 4)
        guard box[0] >= 0, box[1] >= 0, box[2] > box[0], box[3] > box[1], box[2] <= image.width, box[3] <= image.height else {
            throw AyuBridgeFailure("invalid_arguments", "box must lie inside the image and be non-empty")
        }
        let result = AyuBridgeImageOps.Box(left: box[0], top: box[1], width: box[2] - box[0], height: box[3] - box[1])
        guard result.width * result.height * image.mode.bands <= self.limits.transferBytes else {
            throw AyuBridgeFailure("resource_limit", "Pixel transfer is too large")
        }
        return result
    }

    private func input(_ args: AyuBridgeImageArguments) throws -> Data {
        if let text = args.values["data"]?.string {
            guard args.values["path"] == nil, let data = Data(base64Encoded: text) else { throw AyuBridgeFailure("invalid_arguments", "Invalid image data") }
            return data
        }
        return try AyuBridgeImageArguments.file(try args.path("path"), limit: self.limits.fileBytes)
    }
}

/// Typed readers for operation arguments.
struct AyuBridgeImageArguments {
    let values: [String: AyuBridgeValue]
    init(_ values: [String: AyuBridgeValue]) { self.values = values }

    func only(_ keys: Set<String>) throws {
        guard Set(self.values.keys).isSubset(of: keys) else { throw AyuBridgeFailure("invalid_arguments", "Unexpected argument") }
    }

    func string(_ key: String) throws -> String {
        guard let value = self.values[key]?.string else { throw AyuBridgeFailure("invalid_arguments", "Expected string " + key) }
        return value
    }

    func strings(_ key: String) throws -> [String] {
        guard let value = self.values[key] else { return [] }
        guard let items = value.array, items.count <= 256 else { throw AyuBridgeFailure("invalid_arguments", "Expected list " + key) }
        return try items.map {
            guard let text = $0.string else { throw AyuBridgeFailure("invalid_arguments", "Expected list of strings " + key) }
            return text
        }
    }

    static func integer(_ value: AyuBridgeValue?) -> Int? {
        if let value = value?.integer { return Int(exactly: value) }
        if let value = value?.double, value == value.rounded(), abs(value) < 1e15 { return Int(value) }
        return nil
    }

    func int(_ key: String) throws -> Int {
        guard let value = Self.integer(self.values[key]), abs(value) <= 1 << 40 else { throw AyuBridgeFailure("invalid_arguments", "Expected integer " + key) }
        return value
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = self.values[key], value != .null else { return nil }
        return try self.int(key)
    }

    func double(_ key: String) throws -> Double {
        guard let value = self.values[key]?.number, value.isFinite, abs(value) <= 1e12 else { throw AyuBridgeFailure("invalid_arguments", "Expected number " + key) }
        return value
    }

    func optionalDouble(_ key: String) throws -> Double? {
        guard let value = self.values[key], value != .null else { return nil }
        return try self.double(key)
    }

    func bool(_ key: String, default fallback: Bool) throws -> Bool {
        guard let value = self.values[key], value != .null else { return fallback }
        guard let flag = value.bool else { throw AyuBridgeFailure("invalid_arguments", "Expected boolean " + key) }
        return flag
    }

    func ints(_ key: String, count: Int) throws -> [Int] {
        guard let items = self.values[key]?.array, items.count == count else { throw AyuBridgeFailure("invalid_arguments", "Expected \(count) integers in " + key) }
        return try items.map {
            guard let value = Self.integer($0), abs(value) <= 1 << 40 else { throw AyuBridgeFailure("invalid_arguments", "Expected integers in " + key) }
            return value
        }
    }

    func doubles(_ key: String, count: Int? = nil, limit: Int = 16) throws -> [Double] {
        guard let items = self.values[key]?.array, count.map({ items.count == $0 }) ?? (items.count <= limit) else {
            throw AyuBridgeFailure("invalid_arguments", "Expected numbers in " + key)
        }
        return try items.map {
            guard let value = $0.number, value.isFinite, abs(value) <= 1e12 else { throw AyuBridgeFailure("invalid_arguments", "Expected numbers in " + key) }
            return value
        }
    }

    func mode(_ key: String) throws -> AyuBridgePixelImage.Mode {
        let name = try self.string(key)
        guard let mode = AyuBridgePixelImage.Mode(rawValue: name) else { throw AyuBridgeFailure.unsupported("image mode " + String(name.prefix(16))) }
        return mode
    }

    static func byte(_ value: AyuBridgeValue) throws -> UInt8 {
        guard let number = Self.integer(value), let byte = UInt8(exactly: number) else { throw AyuBridgeFailure("invalid_arguments", "Expected a value 0...255") }
        return byte
    }

    /// A color with one value per band of `mode`, or nil when the key is absent or null.
    func color(_ key: String, mode: AyuBridgePixelImage.Mode) throws -> [UInt8]? {
        guard let value = self.values[key], value != .null else { return nil }
        guard let items = value.array, items.count == mode.bands else { throw AyuBridgeFailure("invalid_arguments", "Color must have one value per band") }
        return try items.map(Self.byte)
    }

    func path(_ key: String) throws -> String {
        let path = try self.string(key)
        guard path.hasPrefix("/"), path.utf8.count <= 4_096, !path.utf8.contains(0) else { throw AyuBridgeFailure("invalid_arguments", "Expected an absolute path") }
        return path
    }

    /// The bytes of a regular file of at most `limit` bytes.
    static func file(_ path: String, limit: Int) throws -> Data {
        var status = stat()
        guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw AyuBridgeFailure("io_error", "Cannot read the file") }
        guard Int(status.st_size) <= limit else { throw AyuBridgeFailure("resource_limit", "File is too large") }
        guard let data = FileManager.default.contents(atPath: path), data.count <= limit else { throw AyuBridgeFailure("io_error", "Cannot read the file") }
        return data
    }
}

/// ImageIO in, ImageIO out. Pixels keep the values stored in the file: no color management.
enum AyuBridgeImageCodec {
    struct Decoded {
        let image: AyuBridgePixelImage
        let format: String
        let orientation: Int
        let frames: Int
    }

    private static let formats: [String: String] = [
        "public.jpeg": "JPEG", "public.png": "PNG", "com.compuserve.gif": "GIF", "org.webmproject.webp": "WEBP",
        "com.microsoft.bmp": "BMP", "public.tiff": "TIFF",
    ]
    private static let types: [String: String] = ["PNG": "public.png", "JPEG": "public.jpeg", "WEBP": "org.webmproject.webp"]

    struct Header {
        let source: CGImageSource
        let format: String
        let mode: AyuBridgePixelImage.Mode
        let width: Int
        let height: Int
        let orientation: Int
        let frames: Int
    }

    /// What the file says about its first frame; no pixel is decoded.
    static func header(_ data: Data) throws -> Header {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?,
              let format = self.formats[type], CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else {
            throw AyuBridgeFailure("image_format", "Cannot identify the image")
        }
        let model = properties[kCGImagePropertyColorModel] as? String
        let alpha = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        let gray = model == (kCGImagePropertyColorModelGray as String)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return Header(source: source, format: format, mode: gray ? (alpha ? .la : .l) : (alpha ? .rgba : .rgb), width: width, height: height,
                      orientation: (1...8).contains(orientation) ? orientation : 1, frames: CGImageSourceGetCount(source))
    }

    static func decode(_ data: Data, limits: AyuBridgeImageLimits, reserve: (Int) throws -> Void) throws -> Decoded {
        let header = try self.header(data)
        guard header.width <= limits.sidePixels, header.height <= limits.sidePixels, header.width * header.height <= limits.pixelsPerImage else {
            throw AyuBridgeFailure("resource_limit", "Image is too large")
        }
        // The header decides the mode, so the quota is checked before any pixel is decoded.
        try reserve(header.width * header.height * header.mode.bands)
        guard let image = CGImageSourceCreateImageAtIndex(header.source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == header.width, image.height == header.height else {
            throw AyuBridgeFailure("image_format", "Cannot decode the image")
        }
        return Decoded(image: try self.pixels(image, mode: header.mode), format: header.format, orientation: header.orientation, frames: header.frames)
    }

    /// Straight-alpha bytes of a decoded image in its own color space, so stored values survive.
    private static func pixels(_ image: CGImage, mode: AyuBridgePixelImage.Mode) throws -> AyuBridgePixelImage {
        let gray = mode.colorBands == 1
        let sourceModel = image.colorSpace?.model
        let space: CGColorSpace
        if gray, sourceModel == .monochrome, let own = image.colorSpace { space = own }
        else if !gray, sourceModel == .rgb, let own = image.colorSpace { space = own }
        else if !gray, sourceModel == .indexed, let base = image.colorSpace?.baseColorSpace, base.model == .rgb { space = base }
        else { space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB() }
        // vImage has no three-byte RGB target: decode RGB as RGBX and drop the fourth byte.
        let wide: AyuBridgePixelImage.Mode = mode == .rgb ? .rgba : mode
        let alphaInfo: CGImageAlphaInfo = mode.hasAlpha ? .last : (mode == .rgb ? .noneSkipLast : .none)
        var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: UInt32(8 * wide.bands), colorSpace: Unmanaged.passUnretained(space),
                                          bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue), version: 0, decode: nil, renderingIntent: .defaultIntent)
        var buffer = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError, let base = buffer.data else {
            throw AyuBridgeFailure("image_format", "Cannot decode the image")
        }
        defer { free(base) }
        let (width, height, bands) = (Int(buffer.width), Int(buffer.height), mode.bands)
        var data = [UInt8](repeating: 0, count: width * height * bands)
        let rows = base.assumingMemoryBound(to: UInt8.self)
        data.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = rows + y * buffer.rowBytes
                if wide == mode {
                    (out.baseAddress! + y * width * bands).update(from: row, count: width * bands)
                } else {
                    var target = y * width * 3
                    for x in 0..<width {
                        out[target] = row[x * 4]; out[target + 1] = row[x * 4 + 1]; out[target + 2] = row[x * 4 + 2]
                        target += 3
                    }
                }
            }
        }
        return AyuBridgePixelImage(mode: mode, width: width, height: height, data: data)
    }

    /// A CGImage over a private copy of the pixels.
    static func cgImage(_ image: AyuBridgePixelImage) throws -> CGImage {
        let gray = image.mode.colorBands == 1
        guard let space = CGColorSpace(name: gray ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(image.data) as CFData),
              let result = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8 * image.mode.bands,
                                   bytesPerRow: image.width * image.mode.bands, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: (image.mode.hasAlpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.none).rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw AyuBridgeFailure("resource_limit", "Cannot wrap the image")
        }
        return result
    }

    static func canEncode(_ format: String) -> Bool {
        guard let type = self.types[format], let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] else { return false }
        return supported.contains(type)
    }

    static func encode(_ image: AyuBridgePixelImage, format: String, quality: Int) throws -> Data {
        guard let type = self.types[format] else { throw AyuBridgeFailure.unsupported("image.encode format " + String(format.prefix(16))) }
        // ImageIO writes WebP on no current system; the answer is taken from the system, not assumed.
        guard self.canEncode(format) else { throw AyuBridgeFailure.unsupported("image.encode " + format + " (this system has no encoder)") }
        if format == "JPEG", image.mode.hasAlpha { throw AyuBridgeFailure("invalid_arguments", "JPEG cannot store alpha") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw AyuBridgeFailure("io_error", "Cannot create the encoder")
        }
        let options: [CFString: Any] = format == "PNG" ? [:] : [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100]
        CGImageDestinationAddImage(destination, try self.cgImage(image), options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AyuBridgeFailure("io_error", "Cannot encode the image") }
        return data as Data
    }
}

/// Images on their way to a view: put by a host worker, taken once by the main thread. A view
/// has at most one pending image, so commands that never reach main cannot pile copies up.
public final class AyuBridgeImageSnapshots: @unchecked Sendable {
    public static let shared = AyuBridgeImageSnapshots()
    private struct Entry {
        let service: ObjectIdentifier
        let owner: String
        let view: String
        let image: CGImage
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func put(_ image: CGImage, service: ObjectIdentifier, owner: String, view: String, limit: Int) throws -> String {
        self.lock.lock(); defer { self.lock.unlock() }
        self.entries = self.entries.filter { !($0.value.service == service && $0.value.owner == owner && $0.value.view == view) }
        guard self.entries.values.filter({ $0.service == service && $0.owner == owner }).count < limit else {
            throw AyuBridgeFailure("resource_limit", "Too many images are waiting for their views")
        }
        let token = UUID().uuidString
        self.entries[token] = Entry(service: service, owner: owner, view: view, image: image)
        return token
    }

    public func take(_ token: String) -> CGImage? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.entries.removeValue(forKey: token)?.image
    }

    public func pending(owner: String) -> Int {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.entries.values.filter { $0.owner == owner }.count
    }

    func discard(service: ObjectIdentifier, owner: String) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.entries = self.entries.filter { !($0.value.service == service && $0.value.owner == owner) }
    }
}
