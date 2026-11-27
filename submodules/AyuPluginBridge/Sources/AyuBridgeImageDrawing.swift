import CoreGraphics
import CoreText
import Foundation

/// A font of the image service: a file loaded through CoreText (never registered with the
/// system) or the system font. Text is laid out on one line and drawn as glyph outlines.
struct AyuBridgeImageFont {
    let font: CTFont
    let size: Double

    static func system(size: Double, kind: CTFontUIFontType = .system) -> AyuBridgeImageFont {
        let font = CTFontCreateUIFontForLanguage(kind, CGFloat(size), nil) ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(size), nil)
        return AyuBridgeImageFont(font: font, size: size)
    }

    static func file(path: String, size: Double, index: Int, limit: Int) throws -> AyuBridgeImageFont {
        let data = try AyuBridgeImageArguments.file(path, limit: limit)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], !descriptors.isEmpty else {
            throw AyuBridgeFailure("image_format", "Cannot read the font file")
        }
        guard descriptors.indices.contains(index) else { throw AyuBridgeFailure("invalid_arguments", "Font index out of range") }
        return AyuBridgeImageFont(font: CTFontCreateWithFontDescriptor(descriptors[index], CGFloat(size), nil), size: size)
    }

    var description: [String: AyuBridgeValue] {
        ["size": .number(self.size), "ascent": .number(Double(CTFontGetAscent(self.font))), "descent": .number(Double(CTFontGetDescent(self.font))),
         "family": .string(CTFontCopyFamilyName(self.font) as String),
         "style": .string((CTFontCopyAttribute(self.font, kCTFontStyleNameAttribute) as? String) ?? "Regular")]
    }

    private func line(_ text: String) -> CTLine {
        let attributes = [kCTFontAttributeName: self.font] as CFDictionary
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes)!)
    }

    /// Glyph outlines with the pen at (0, 0) on the baseline, y growing downwards, and the advance.
    /// Glyphs without an outline (color bitmaps) contribute their advance only.
    func outline(_ text: String) -> (path: CGPath, advance: Double) {
        let line = self.line(text)
        let path = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            // CoreText substitutes another font for characters this one lacks.
            let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? self.font
            for index in 0..<count {
                guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                path.addPath(glyph, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[index].x, ty: -positions[index].y))
            }
        }
        return (path, Double(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    func measure(_ text: String, stroke: Double) -> AyuBridgeValue {
        let (path, advance) = self.outline(text)
        var ink: [Double] = [0, 0, 0, 0]
        if !path.isEmpty {
            let box = path.boundingBoxOfPath.insetBy(dx: -CGFloat(stroke), dy: -CGFloat(stroke))
            ink = [Double(box.minX), Double(box.minY), Double(box.maxX), Double(box.maxY)]
        }
        return .object(["advance": .number(advance), "ink": .array(ink.map(AyuBridgeValue.number)),
                        "ascent": .number(Double(CTFontGetAscent(self.font))), "descent": .number(Double(CTFontGetDescent(self.font)))])
    }
}

/// Draws `image.draw` commands. A shape is rasterized by CoreGraphics into an eight-bit coverage
/// mask and the ink is then mixed into the straight-alpha pixels with that mask, so no pixel
/// passes through premultiplied storage. `replace` moves every band towards the ink (Pillow's
/// ImageDraw); `over` is source-over with the ink's alpha (Android's Canvas).
struct AyuBridgeImageRenderer {
    let limits: AyuBridgeImageLimits
    let font: (String) throws -> AyuBridgeImageFont
    let image: (String) throws -> AyuBridgePixelImage

    struct Ink {
        let bands: [UInt8]
        let alpha: Int
    }

    struct Bitmap {
        let image: CGImage
        let destination: CGRect
        let alpha: CGFloat
        let filter: Bool
    }

    struct Command {
        var path: CGPath = CGMutablePath()
        var fill: Ink?
        var stroke: Ink?
        /// The stroke pass also fills, and comes first: outlined text, and Android's FILL_AND_STROKE.
        var strokeFills = false
        /// The path holds an outer and an inner outline; the fill is the band between them.
        var evenOdd = false
        var lineWidth: CGFloat = 1
        var cap: CGLineCap = .butt
        var join: CGLineJoin = .miter
        var antialias = false
        var over = false
        var matrix: CGAffineTransform = .identity
        var clips: [(matrix: CGAffineTransform, rect: CGRect)] = []
        var bitmap: Bitmap?
    }

    private static let keys: Set<String> = [
        "op", "box", "radius", "radii", "start", "sweep", "center", "points", "segments", "text", "font", "size", "origin",
        "stroke_width", "stroke_ink", "source", "src", "dst", "alpha", "filter", "fill", "stroke", "width", "cap", "join",
        "antialias", "blend", "matrix", "clips", "paint", "ring",
    ]

    func prepare(_ value: AyuBridgeValue, target: AyuBridgePixelImage) throws -> Command {
        guard let fields = value.object else { throw AyuBridgeFailure("invalid_arguments", "Invalid draw command") }
        let args = AyuBridgeImageArguments(fields)
        try args.only(Self.keys)
        var command = Command()
        let blend = fields["blend"]?.string ?? "replace"
        guard blend == "replace" || blend == "over" else { throw AyuBridgeFailure.unsupported("image.draw blend") }
        command.over = blend == "over"
        command.antialias = try args.bool("antialias", default: false)
        command.fill = try self.ink(fields["fill"], target: target, over: command.over)
        command.stroke = try self.ink(fields["stroke"], target: target, over: command.over)
        if let width = try args.optionalDouble("width") { command.lineWidth = CGFloat(width) }
        command.cap = try Self.cap(fields["cap"]?.string ?? "butt")
        command.join = try Self.join(fields["join"]?.string ?? "miter")
        if fields["matrix"] != nil { command.matrix = try Self.transform(try args.doubles("matrix", count: 6)) }
        if let clips = fields["clips"]?.array {
            guard clips.count <= 32 else { throw AyuBridgeFailure("resource_limit", "Too many clips") }
            command.clips = try clips.map { clip in
                let clipArgs = AyuBridgeImageArguments(clip.object ?? [:])
                try clipArgs.only(["matrix", "rect"])
                return (try Self.transform(try clipArgs.doubles("matrix", count: 6)), try Self.rect(try clipArgs.doubles("rect", count: 4)))
            }
        }
        var textSize = 12.0
        var filter = try args.bool("filter", default: false)
        var alpha = try args.optionalInt("alpha") ?? 255
        var paintInk: Ink?
        var paintFont: CTFontUIFontType = .system
        if let paint = fields["paint"]?.object {
            // The state of an android.graphics.Paint, resolved by the host from the plugin's handle.
            guard let color = paint["color"]?.integer, let style = paint["style"]?.string, let width = paint["stroke_width"]?.number,
                  let cap = paint["cap"]?.string, let join = paint["join"]?.string, let size = paint["text_size"]?.number else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid paint")
            }
            let bits = UInt32(truncatingIfNeeded: color)
            let argb = [UInt8(bits >> 16 & 255), UInt8(bits >> 8 & 255), UInt8(bits & 255), UInt8(bits >> 24)]
            let ink = Self.ink(argb: argb, target: target)
            paintInk = ink
            // Of a typeface the system font can follow weight and fixed pitch; other families keep the system design.
            if let typeface = paint["typeface"]?.object {
                if typeface["family"]?.string == "monospace" { paintFont = .userFixedPitch }
                else if (typeface["weight"]?.integer ?? 400) >= 600 { paintFont = .emphasizedSystem }
            }
            command.fill = style == "FILL" ? ink : nil
            command.stroke = style == "FILL" ? nil : ink
            command.strokeFills = style == "FILL_AND_STROKE"
            // Android draws a zero-width stroke as a hairline.
            command.lineWidth = max(1, CGFloat(width))
            command.cap = try Self.cap(cap.lowercased())
            command.join = try Self.join(join.lowercased())
            command.antialias = paint["anti_alias"]?.bool ?? false
            command.over = true
            textSize = size
            filter = paint["filter_bitmap"]?.bool ?? false
            alpha = Int(bits >> 24)
        }
        guard command.lineWidth >= 0, command.lineWidth <= 10_000 else { throw AyuBridgeFailure("invalid_arguments", "Invalid stroke width") }
        let path = CGMutablePath()
        let operation = try args.string("op")
        // An outline `ring` wide just inside the shape: the shape minus itself inset by that much.
        var ring: CGFloat = 0
        if let width = try args.optionalDouble("ring") {
            guard width > 0, width <= 10_000, ["rect", "round_rect", "ellipse"].contains(operation) else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid ring")
            }
            ring = CGFloat(width)
        }
        switch operation {
        case "rect", "round_rect", "ellipse":
            let outer = try Self.rect(try args.doubles("box", count: 4))
            var radii = [try args.optionalDouble("radius") ?? 0, try args.optionalDouble("radius") ?? 0]
            if fields["radii"] != nil { radii = try args.doubles("radii", count: 2) }
            let inner = outer.insetBy(dx: ring, dy: ring)
            let hollow = ring > 0 && !inner.isNull && inner.width > 0 && inner.height > 0
            for (rect, inset) in hollow ? [(outer, 0), (inner, ring)] : [(outer, 0)] {
                let rx = min(max(0, CGFloat(radii[0]) - inset), rect.width / 2), ry = min(max(0, CGFloat(radii[1]) - inset), rect.height / 2)
                if operation == "ellipse" { path.addEllipse(in: rect) }
                else if operation == "round_rect", rx > 0, ry > 0 { path.addRoundedRect(in: rect, cornerWidth: rx, cornerHeight: ry) }
                else { path.addRect(rect) }
            }
            command.evenOdd = hollow
        case "arc":
            let rect = try Self.rect(try args.doubles("box", count: 4))
            let start = try args.double("start"), sweep = try args.double("sweep")
            let shape = CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: rect.width / 2, y: rect.height / 2)
            if abs(sweep) >= 360 {
                path.addEllipse(in: rect)
            } else {
                let from = CGFloat(start * .pi / 180), to = CGFloat((start + sweep) * .pi / 180)
                if try args.bool("center", default: false) { path.move(to: .zero, transform: shape) }
                else { path.move(to: CGPoint(x: cos(from), y: sin(from)), transform: shape) }
                path.addArc(center: .zero, radius: 1, startAngle: from, endAngle: to, clockwise: sweep < 0, transform: shape)
                if try args.bool("center", default: false) { path.closeSubpath() }
            }
        case "line":
            let points = try args.doubles("points", limit: self.limits.pathPoints * 2)
            guard points.count >= 4, points.count % 2 == 0 else { throw AyuBridgeFailure("invalid_arguments", "A line needs two or more points") }
            path.move(to: CGPoint(x: points[0], y: points[1]))
            for index in stride(from: 2, to: points.count, by: 2) { path.addLine(to: CGPoint(x: points[index], y: points[index + 1])) }
            // A line is stroked whatever the paint's style; a point with a butt cap is a square.
            command.fill = nil
            command.strokeFills = false
            if command.stroke == nil { command.stroke = paintInk }
            if points.count == 4, points[0] == points[2], points[1] == points[3], command.cap == .butt { command.cap = .square }
        case "path":
            guard let segments = fields["segments"]?.array, segments.count <= self.limits.pathPoints else {
                throw AyuBridgeFailure("resource_limit", "Path is too long")
            }
            for segment in segments {
                guard let parts = segment.array, let verb = parts.first?.string else { throw AyuBridgeFailure("invalid_arguments", "Invalid path segment") }
                let numbers = try parts.dropFirst().map { part -> CGFloat in
                    guard let number = part.number, number.isFinite, abs(number) <= 1e7 else { throw AyuBridgeFailure("invalid_arguments", "Invalid path coordinate") }
                    return CGFloat(number)
                }
                switch (verb, numbers.count) {
                case ("M", 2): path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
                case ("L", 2) where !path.isEmpty: path.addLine(to: CGPoint(x: numbers[0], y: numbers[1]))
                case ("Q", 4) where !path.isEmpty: path.addQuadCurve(to: CGPoint(x: numbers[2], y: numbers[3]), control: CGPoint(x: numbers[0], y: numbers[1]))
                case ("C", 6) where !path.isEmpty:
                    path.addCurve(to: CGPoint(x: numbers[4], y: numbers[5]), control1: CGPoint(x: numbers[0], y: numbers[1]), control2: CGPoint(x: numbers[2], y: numbers[3]))
                case ("Z", 0) where !path.isEmpty: path.closeSubpath()
                default: throw AyuBridgeFailure("invalid_arguments", "Invalid path segment")
                }
            }
        case "fill":
            // The whole image whatever the matrix; clips still apply.
            command.matrix = .identity
            path.addRect(CGRect(x: 0, y: 0, width: target.width, height: target.height))
            if let paintInk { command.fill = paintInk }
            command.stroke = nil
            command.strokeFills = false
        case "text":
            let text = try args.string("text")
            guard text.utf8.count <= self.limits.textBytes else { throw AyuBridgeFailure("resource_limit", "Text is too long") }
            let font: AyuBridgeImageFont
            if let id = fields["font"]?.string { font = try self.font(id) } else {
                let size = try args.optionalDouble("size") ?? textSize
                guard size >= 1, size <= 2_048 else { throw AyuBridgeFailure("invalid_arguments", "font size must be 1...2048") }
                font = .system(size: size, kind: paintFont)
            }
            if let paintInk {
                // Outlined glyphs (Paint.Style.STROKE) are not drawn as filled ones.
                guard command.stroke == nil else { throw AyuBridgeFailure.unsupported("image.draw text with a stroking paint") }
                command.fill = paintInk
            }
            let origin = try args.doubles("origin", count: 2)
            path.addPath(font.outline(text).path, transform: CGAffineTransform(translationX: CGFloat(origin[0]), y: CGFloat(origin[1])))
            // Glyph edges are always smoothed, as FreeType and Skia do.
            command.antialias = true
            command.stroke = nil
            if let strokeWidth = try args.optionalDouble("stroke_width"), strokeWidth > 0 {
                guard strokeWidth <= 256 else { throw AyuBridgeFailure("invalid_arguments", "Invalid stroke width") }
                command.stroke = try self.ink(fields["stroke_ink"], target: target, over: command.over) ?? command.fill
                command.lineWidth = CGFloat(strokeWidth * 2)
                command.join = .round
                command.strokeFills = true
            }
        case "image":
            var source = try self.image(try args.string("source"))
            if fields["src"] != nil, fields["src"] != .null {
                let box = try args.ints("src", count: 4)
                guard box[0] >= 0, box[1] >= 0, box[2] > box[0], box[3] > box[1], box[2] <= source.width, box[3] <= source.height else {
                    throw AyuBridgeFailure("invalid_arguments", "src must lie inside the source and be non-empty")
                }
                source = AyuBridgeImageOps.crop(source, left: box[0], top: box[1], width: box[2] - box[0], height: box[3] - box[1])
            }
            guard (0...255).contains(alpha) else { throw AyuBridgeFailure("invalid_arguments", "alpha must be 0...255") }
            // Gray sources are widened first: CoreGraphics would color-match gray to RGB.
            let wide = AyuBridgeImageOps.convert(source, to: source.mode.hasAlpha ? .rgba : .rgb)
            command.bitmap = Bitmap(image: try AyuBridgeImageCodec.cgImage(wide), destination: try Self.rect(try args.doubles("dst", count: 4)),
                                    alpha: CGFloat(alpha) / 255, filter: filter)
            command.fill = nil
            command.stroke = nil
        default:
            throw AyuBridgeFailure.unsupported("image.draw op")
        }
        command.path = path
        return command
    }

    private static func cap(_ name: String) throws -> CGLineCap {
        switch name { case "butt": return .butt; case "round": return .round; case "square": return .square
        default: throw AyuBridgeFailure.unsupported("image.draw cap") }
    }

    private static func join(_ name: String) throws -> CGLineJoin {
        switch name { case "miter": return .miter; case "round": return .round; case "bevel": return .bevel
        default: throw AyuBridgeFailure.unsupported("image.draw join") }
    }

    private static func transform(_ values: [Double]) throws -> CGAffineTransform {
        let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
        guard abs(matrix.a * matrix.d - matrix.b * matrix.c) > 1e-12 else { throw AyuBridgeFailure("invalid_arguments", "Matrix is not invertible") }
        return matrix
    }

    /// `[left, top, right, bottom]` in continuous coordinates.
    private static func rect(_ box: [Double]) throws -> CGRect {
        guard box[2] >= box[0], box[3] >= box[1], box.allSatisfy({ abs($0) <= 1e7 }) else { throw AyuBridgeFailure("invalid_arguments", "Invalid box") }
        return CGRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1])
    }

    private func ink(_ value: AyuBridgeValue?, target: AyuBridgePixelImage, over: Bool) throws -> Ink? {
        guard let value, value != .null else { return nil }
        guard let items = value.array else { throw AyuBridgeFailure("invalid_arguments", "Ink must be a list") }
        let bytes = try items.map(AyuBridgeImageArguments.byte)
        let bands = target.mode.bands
        if over, !target.mode.hasAlpha, bytes.count == bands + 1 { return Ink(bands: Array(bytes.prefix(bands)), alpha: Int(bytes[bands])) }
        guard bytes.count == bands else { throw AyuBridgeFailure("invalid_arguments", "Ink must have one value per band") }
        return Ink(bands: bytes, alpha: over && target.mode.hasAlpha ? Int(bytes[bands - 1]) : 255)
    }

    private static func ink(argb: [UInt8], target: AyuBridgePixelImage) -> Ink {
        var bands = target.mode.colorBands == 1 ? [AyuBridgeImageOps.luma(argb[0], argb[1], argb[2])] : Array(argb.prefix(3))
        if target.mode.hasAlpha { bands.append(argb[3]) }
        return Ink(bands: bands, alpha: Int(argb[3]))
    }

    // MARK: Rasterization

    func draw(_ command: Command, into image: inout AyuBridgePixelImage) {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var reach = CGRect.null
        if let bitmap = command.bitmap {
            reach = bitmap.destination.applying(command.matrix)
        } else if !command.path.isEmpty {
            let scale = max(hypot(command.matrix.a, command.matrix.b), hypot(command.matrix.c, command.matrix.d))
            // A miter may reach four half-widths beyond the outline.
            let margin = command.stroke == nil ? 1 : command.lineWidth * 2 * scale + 1
            reach = command.path.boundingBoxOfPath.applying(command.matrix).insetBy(dx: -margin, dy: -margin)
        }
        let dirty = reach.intersection(bounds).integral
        guard !dirty.isNull, dirty.width >= 1, dirty.height >= 1 else { return }
        let area = (x: Int(dirty.minX), y: Int(dirty.minY), width: Int(dirty.width), height: Int(dirty.height))
        if let bitmap = command.bitmap {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: area.width, height: area.height, bitsPerComponent: 8, bytesPerRow: area.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let memory = context.data else { return }
            context.clear(CGRect(x: 0, y: 0, width: area.width, height: area.height))
            self.enter(context, command, area)
            context.setAlpha(bitmap.alpha)
            context.interpolationQuality = bitmap.filter ? .medium : .none
            context.setShouldAntialias(bitmap.filter)
            // Images are drawn with their first row at the bottom of the rectangle; turn it back.
            context.translateBy(x: bitmap.destination.minX, y: bitmap.destination.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(bitmap.image, in: CGRect(x: 0, y: 0, width: bitmap.destination.width, height: bitmap.destination.height))
            Self.compositePremultiplied(memory.assumingMemoryBound(to: UInt8.self), rowBytes: context.bytesPerRow, area: area, into: &image)
            return
        }
        let passes = command.strokeFills ? [(command.stroke, true), (command.fill, false)] : [(command.fill, false), (command.stroke, true)]
        for (ink, stroke) in passes {
            guard let ink,
                  let context = CGContext(data: nil, width: area.width, height: area.height, bitsPerComponent: 8, bytesPerRow: area.width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue), let memory = context.data else { continue }
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: area.width, height: area.height))
            self.enter(context, command, area)
            // Coverage is always computed; without anti-aliasing a pixel is inked when at least half
            // of it is covered, which is what sampling pixel centers gives Pillow and Skia.
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.addPath(command.path)
            if stroke {
                context.setStrokeColor(gray: 1, alpha: 1)
                context.setLineWidth(command.lineWidth)
                context.setLineCap(command.cap)
                context.setLineJoin(command.join)
                context.setMiterLimit(4)
                if command.strokeFills {
                    context.setFillColor(gray: 1, alpha: 1)
                    context.drawPath(using: .fillStroke)
                } else {
                    context.strokePath()
                }
            } else {
                context.setFillColor(gray: 1, alpha: 1)
                context.fillPath(using: command.evenOdd ? .evenOdd : .winding)
            }
            Self.composite(memory.assumingMemoryBound(to: UInt8.self), rowBytes: context.bytesPerRow, area: area, ink: ink, over: command.over,
                           threshold: !command.antialias, into: &image)
        }
    }

    /// Image coordinates (y downwards) for the dirty area, then the command's clips and matrix.
    private func enter(_ context: CGContext, _ command: Command, _ area: (x: Int, y: Int, width: Int, height: Int)) {
        context.translateBy(x: 0, y: CGFloat(area.height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -CGFloat(area.x), y: -CGFloat(area.y))
        for clip in command.clips {
            context.concatenate(clip.matrix)
            context.clip(to: clip.rect)
            context.concatenate(clip.matrix.inverted())
        }
        context.concatenate(command.matrix)
    }

    private static func composite(_ mask: UnsafePointer<UInt8>, rowBytes: Int, area: (x: Int, y: Int, width: Int, height: Int), ink: Ink, over: Bool,
                                  threshold: Bool, into image: inout AyuBridgePixelImage) {
        let bands = image.mode.bands, width = image.width
        let hasAlpha = image.mode.hasAlpha
        image.data.withUnsafeMutableBufferPointer { dst in
            for row in 0..<area.height {
                for column in 0..<area.width {
                    var coverage = Int(mask[row * rowBytes + column])
                    if threshold { coverage = coverage >= 128 ? 255 : 0 }
                    if coverage == 0 { continue }
                    let target = ((area.y + row) * width + area.x + column) * bands
                    if !over || !hasAlpha {
                        if over { coverage = AyuBridgeImageOps.mulDiv255(coverage, ink.alpha) }
                        for band in 0..<bands {
                            dst[target + band] = UInt8(AyuBridgeImageOps.div255(Int(dst[target + band]) * (255 - coverage) + Int(ink.bands[band]) * coverage))
                        }
                        continue
                    }
                    let sourceAlpha = AyuBridgeImageOps.mulDiv255(coverage, ink.alpha)
                    if sourceAlpha == 0 { continue }
                    let kept = Int(dst[target + bands - 1]) * (255 - sourceAlpha)
                    let total = sourceAlpha * 255 + kept
                    for band in 0..<(bands - 1) {
                        dst[target + band] = AyuBridgeImageOps.clip((Int(ink.bands[band]) * sourceAlpha * 255 + Int(dst[target + band]) * kept + total / 2) / total)
                    }
                    dst[target + bands - 1] = UInt8(AyuBridgeImageOps.div255(total))
                }
            }
        }
    }

    /// Source-over of premultiplied RGBA pixels onto the straight-alpha image.
    private static func compositePremultiplied(_ pixels: UnsafePointer<UInt8>, rowBytes: Int, area: (x: Int, y: Int, width: Int, height: Int),
                                               into image: inout AyuBridgePixelImage) {
        let bands = image.mode.bands, width = image.width
        let hasAlpha = image.mode.hasAlpha, gray = image.mode.colorBands == 1
        image.data.withUnsafeMutableBufferPointer { dst in
            for row in 0..<area.height {
                for column in 0..<area.width {
                    let source = row * rowBytes + column * 4
                    let sourceAlpha = Int(pixels[source + 3])
                    if sourceAlpha == 0 { continue }
                    var color = [Int(pixels[source]), Int(pixels[source + 1]), Int(pixels[source + 2])]
                    if gray { color = [(color[0] * 19595 + color[1] * 38470 + color[2] * 7471 + 0x8000) >> 16] }
                    let target = ((area.y + row) * width + area.x + column) * bands
                    if !hasAlpha {
                        for band in 0..<bands {
                            dst[target + band] = AyuBridgeImageOps.clip(AyuBridgeImageOps.div255(color[band] * 255 + Int(dst[target + band]) * (255 - sourceAlpha)))
                        }
                        continue
                    }
                    let kept = Int(dst[target + bands - 1]) * (255 - sourceAlpha)
                    let total = sourceAlpha * 255 + kept
                    for band in 0..<(bands - 1) {
                        dst[target + band] = AyuBridgeImageOps.clip((color[band] * 65_025 + Int(dst[target + band]) * kept + total / 2) / total)
                    }
                    dst[target + bands - 1] = UInt8(AyuBridgeImageOps.div255(total))
                }
            }
        }
    }
}
