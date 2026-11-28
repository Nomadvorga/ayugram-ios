import Foundation

/// Pixel arithmetic of the image service. The formulas, rounding and edge rules are Pillow's
/// (Convert.c, Paste.c, AlphaComposite.c, Blend.c, Chops.c, Resample.c, Geometry.c), so results
/// match it byte for byte where integer arithmetic allows.
enum AyuBridgeImageOps {
    struct Box {
        let left: Int
        let top: Int
        let width: Int
        let height: Int
    }

    enum Resampling: String {
        case nearest, box, bilinear, hamming, bicubic, lanczos

        var support: Double {
            switch self {
            case .nearest: return 0
            case .box: return 0.5
            case .bilinear, .hamming: return 1
            case .bicubic: return 2
            case .lanczos: return 3
            }
        }

        func weight(_ value: Double) -> Double {
            let x = abs(value)
            switch self {
            case .nearest: return 0
            case .box: return value > -0.5 && value <= 0.5 ? 1 : 0
            case .bilinear: return x < 1 ? 1 - x : 0
            case .hamming:
                if x == 0 { return 1 }
                if x >= 1 { return 0 }
                return sin(x * .pi) / (x * .pi) * (0.54 + 0.46 * cos(x * .pi))
            case .bicubic:
                let a = -0.5
                if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
                if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
                return 0
            case .lanczos:
                guard value >= -3, value < 3 else { return 0 }
                func sinc(_ v: Double) -> Double { v == 0 ? 1 : sin(v * .pi) / (v * .pi) }
                return sinc(value) * sinc(value / 3)
            }
        }
    }

    enum Transpose: String {
        case flipLeftRight = "flip_left_right", flipTopBottom = "flip_top_bottom", rotate90 = "rotate_90", rotate180 = "rotate_180"
        case rotate270 = "rotate_270", transpose, transverse
    }

    @inline(__always) static func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
        UInt8((Int(r) * 19595 + Int(g) * 38470 + Int(b) * 7471 + 0x8000) >> 16)
    }

    /// `a * b / 255`, rounded.
    @inline(__always) static func mulDiv255(_ a: Int, _ b: Int) -> Int {
        let t = a * b + 128
        return ((t >> 8) + t) >> 8
    }

    @inline(__always) static func clip(_ value: Int) -> UInt8 { value <= 0 ? 0 : (value >= 255 ? 255 : UInt8(value)) }

    // MARK: Modes and bands

    static func convert(_ image: AyuBridgePixelImage, to mode: AyuBridgePixelImage.Mode) -> AyuBridgePixelImage {
        if mode == image.mode { return image }
        let count = image.width * image.height
        let (sourceBands, targetBands) = (image.mode.bands, mode.bands)
        let (sourceGray, targetGray) = (image.mode.colorBands == 1, mode.colorBands == 1)
        let (sourceAlpha, targetAlpha) = (image.mode.hasAlpha, mode.hasAlpha)
        var out = [UInt8](repeating: 0, count: count * targetBands)
        image.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var s = 0, d = 0
                for _ in 0..<count {
                    if targetGray {
                        dst[d] = sourceGray ? src[s] : self.luma(src[s], src[s + 1], src[s + 2])
                    } else if sourceGray {
                        dst[d] = src[s]; dst[d + 1] = src[s]; dst[d + 2] = src[s]
                    } else {
                        dst[d] = src[s]; dst[d + 1] = src[s + 1]; dst[d + 2] = src[s + 2]
                    }
                    if targetAlpha { dst[d + targetBands - 1] = sourceAlpha ? src[s + sourceBands - 1] : 255 }
                    s += sourceBands; d += targetBands
                }
            }
        }
        return AyuBridgePixelImage(mode: mode, width: image.width, height: image.height, data: out)
    }

    static func band(_ image: AyuBridgePixelImage, _ band: Int) -> AyuBridgePixelImage {
        let count = image.width * image.height, bands = image.mode.bands
        var out = [UInt8](repeating: 0, count: count)
        image.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for index in 0..<count { dst[index] = src[index * bands + band] }
            }
        }
        return AyuBridgePixelImage(mode: .l, width: image.width, height: image.height, data: out)
    }

    static func merge(_ mode: AyuBridgePixelImage.Mode, _ parts: [AyuBridgePixelImage]) -> AyuBridgePixelImage {
        let (width, height, bands) = (parts[0].width, parts[0].height, mode.bands)
        var out = AyuBridgePixelImage(mode: mode, width: width, height: height, data: [UInt8](repeating: 0, count: width * height * bands))
        for (index, part) in parts.enumerated() { self.setBand(&out, index, from: part, constant: 0) }
        return out
    }

    static func setBand(_ image: inout AyuBridgePixelImage, _ band: Int, from source: AyuBridgePixelImage?, constant: UInt8) {
        let count = image.width * image.height, bands = image.mode.bands
        image.data.withUnsafeMutableBufferPointer { dst in
            if let source {
                source.data.withUnsafeBufferPointer { src in
                    for index in 0..<count { dst[index * bands + band] = src[index] }
                }
            } else {
                for index in 0..<count { dst[index * bands + band] = constant }
            }
        }
    }

    static func read(_ image: AyuBridgePixelImage, _ box: Box) -> [UInt8] {
        let bands = image.mode.bands
        var out = [UInt8]()
        out.reserveCapacity(box.width * box.height * bands)
        for y in box.top..<(box.top + box.height) {
            let start = (y * image.width + box.left) * bands
            out.append(contentsOf: image.data[start..<(start + box.width * bands)])
        }
        return out
    }

    static func write(_ image: inout AyuBridgePixelImage, _ box: Box, _ bytes: [UInt8]) {
        let bands = image.mode.bands, row = box.width * bands
        for y in 0..<box.height {
            let start = ((box.top + y) * image.width + box.left) * bands
            image.data.replaceSubrange(start..<(start + row), with: bytes[(y * row)..<((y + 1) * row)])
        }
    }

    static func point(_ image: AyuBridgePixelImage, _ table: [UInt8]) -> AyuBridgePixelImage {
        let bands = image.mode.bands
        var out = image
        out.data.withUnsafeMutableBufferPointer { dst in
            table.withUnsafeBufferPointer { lookup in
                var index = 0
                while index < dst.count {
                    for band in 0..<bands { dst[index + band] = lookup[band * 256 + Int(dst[index + band])] }
                    index += bands
                }
            }
        }
        return out
    }

    static func stats(_ image: AyuBridgePixelImage, kind: String, maximum: Int) throws -> AyuBridgeValue {
        let bands = image.mode.bands, count = image.width * image.height
        switch kind {
        case "histogram":
            var histogram = [Int64](repeating: 0, count: 256 * bands)
            image.data.withUnsafeBufferPointer { src in
                for index in 0..<count { for band in 0..<bands { histogram[band * 256 + Int(src[index * bands + band])] += 1 } }
            }
            return .array(histogram.map(AyuBridgeValue.integer))
        case "extrema":
            var low = [UInt8](repeating: 255, count: bands), high = [UInt8](repeating: 0, count: bands)
            image.data.withUnsafeBufferPointer { src in
                for index in 0..<count {
                    for band in 0..<bands {
                        let value = src[index * bands + band]
                        if value < low[band] { low[band] = value }
                        if value > high[band] { high[band] = value }
                    }
                }
            }
            return .array((0..<bands).map { .array([.integer(Int64(low[$0])), .integer(Int64(high[$0]))]) })
        case "bbox":
            // With an alpha band only alpha decides, as Pillow's `getbbox(alpha_only=True)`.
            let tested = image.mode.hasAlpha ? (bands - 1)..<bands : 0..<bands
            var (left, top, right, bottom) = (image.width, image.height, 0, 0)
            image.data.withUnsafeBufferPointer { src in
                for y in 0..<image.height {
                    for x in 0..<image.width {
                        let index = (y * image.width + x) * bands
                        var set = false
                        for band in tested where src[index + band] != 0 { set = true }
                        if set {
                            if x < left { left = x }
                            if x >= right { right = x + 1 }
                            if y < top { top = y }
                            bottom = y + 1
                        }
                    }
                }
            }
            return bottom == 0 ? .null : .array([left, top, right, bottom].map { .integer(Int64($0)) })
        case "colors":
            guard maximum >= 0 else { throw AyuBridgeFailure("invalid_arguments", "max must not be negative") }
            // 4,096 distinct colors are what one response can carry.
            let bound = 4_096
            var counts: [UInt32: Int64] = [:]
            var order: [UInt32] = []
            var exceeded = false
            image.data.withUnsafeBufferPointer { src in
                for index in 0..<count {
                    var key: UInt32 = 0
                    for band in 0..<bands { key = key << 8 | UInt32(src[index * bands + band]) }
                    if let seen = counts[key] { counts[key] = seen + 1; continue }
                    if counts.count >= min(maximum, bound) { exceeded = true; break }
                    counts[key] = 1
                    order.append(key)
                }
            }
            if exceeded {
                if maximum > bound { throw AyuBridgeFailure("resource_limit", "More than 4096 distinct colors") }
                return .null
            }
            return .array(order.map { key in
                .array([.integer(counts[key] ?? 0), .array((0..<bands).map { .integer(Int64((key >> UInt32(8 * (bands - 1 - $0))) & 255)) })])
            })
        default:
            throw AyuBridgeFailure.unsupported("image.stats " + String(kind.prefix(16)))
        }
    }

    // MARK: Geometry

    /// Pixels outside the source are zero, as in Pillow.
    static func crop(_ image: AyuBridgePixelImage, left: Int, top: Int, width: Int, height: Int) -> AyuBridgePixelImage {
        let bands = image.mode.bands
        var out = [UInt8](repeating: 0, count: width * height * bands)
        let x0 = max(0, left), x1 = min(image.width, left + width)
        let y0 = max(0, top), y1 = min(image.height, top + height)
        if x0 < x1, y0 < y1 {
            for y in y0..<y1 {
                let source = (y * image.width + x0) * bands
                let target = ((y - top) * width + (x0 - left)) * bands
                out.replaceSubrange(target..<(target + (x1 - x0) * bands), with: image.data[source..<(source + (x1 - x0) * bands)])
            }
        }
        return AyuBridgePixelImage(mode: image.mode, width: width, height: height, data: out)
    }

    static func transpose(_ image: AyuBridgePixelImage, _ method: Transpose) -> AyuBridgePixelImage {
        let (w, h, bands) = (image.width, image.height, image.mode.bands)
        let swaps = [.rotate90, .rotate270, .transpose, .transverse].contains(method)
        let (outWidth, outHeight) = swaps ? (h, w) : (w, h)
        var out = [UInt8](repeating: 0, count: image.data.count)
        image.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<outHeight {
                    for x in 0..<outWidth {
                        let (sx, sy): (Int, Int)
                        switch method {
                        case .flipLeftRight: (sx, sy) = (w - 1 - x, y)
                        case .flipTopBottom: (sx, sy) = (x, h - 1 - y)
                        case .rotate90: (sx, sy) = (w - 1 - y, x)
                        case .rotate180: (sx, sy) = (w - 1 - x, h - 1 - y)
                        case .rotate270: (sx, sy) = (y, h - 1 - x)
                        case .transpose: (sx, sy) = (y, x)
                        case .transverse: (sx, sy) = (w - 1 - y, h - 1 - x)
                        }
                        let source = (sy * w + sx) * bands, target = (y * outWidth + x) * bands
                        for band in 0..<bands { dst[target + band] = src[source + band] }
                    }
                }
            }
        }
        return AyuBridgePixelImage(mode: image.mode, width: outWidth, height: outHeight, data: out)
    }

    static func premultiplied(_ image: AyuBridgePixelImage) -> AyuBridgePixelImage {
        guard image.mode.hasAlpha else { return image }
        let bands = image.mode.bands
        var out = image
        out.data.withUnsafeMutableBufferPointer { dst in
            var index = 0
            while index < dst.count {
                let alpha = Int(dst[index + bands - 1])
                for band in 0..<(bands - 1) { dst[index + band] = UInt8(self.mulDiv255(Int(dst[index + band]), alpha)) }
                index += bands
            }
        }
        return out
    }

    static func unpremultiplied(_ image: AyuBridgePixelImage) -> AyuBridgePixelImage {
        guard image.mode.hasAlpha else { return image }
        let bands = image.mode.bands
        var out = image
        out.data.withUnsafeMutableBufferPointer { dst in
            var index = 0
            while index < dst.count {
                let alpha = Int(dst[index + bands - 1])
                if alpha != 255, alpha != 0 {
                    for band in 0..<(bands - 1) { dst[index + band] = self.clip(255 * Int(dst[index + band]) / alpha) }
                }
                index += bands
            }
        }
        return out
    }

    private struct Coefficients {
        let size: Int
        var bounds: [Int]
        let weights: [Int]
    }

    private static let precisionBits = 22

    private static func coefficients(inSize: Int, in0: Double, in1: Double, outSize: Int, filter: Resampling) -> Coefficients {
        let scale = (in1 - in0) / Double(outSize)
        let filterScale = max(scale, 1)
        let support = filter.support * filterScale
        let size = Int(support.rounded(.up)) * 2 + 1
        var bounds = [Int](repeating: 0, count: outSize * 2)
        var weights = [Int](repeating: 0, count: outSize * size)
        var line = [Double](repeating: 0, count: size)
        let inverse = 1 / filterScale
        for xx in 0..<outSize {
            let center = in0 + (Double(xx) + 0.5) * scale
            let xmin = max(0, Int(center - support + 0.5))
            let xmax = min(inSize, Int(center + support + 0.5)) - xmin
            var total = 0.0
            for x in 0..<max(0, xmax) {
                let weight = filter.weight((Double(x + xmin) - center + 0.5) * inverse)
                line[x] = weight
                total += weight
            }
            for x in 0..<max(0, xmax) {
                let weight = total != 0 ? line[x] / total : line[x]
                weights[xx * size + x] = Int(weight < 0 ? -0.5 + weight * Double(1 << self.precisionBits) : 0.5 + weight * Double(1 << self.precisionBits))
            }
            bounds[xx * 2] = xmin
            bounds[xx * 2 + 1] = max(0, xmax)
        }
        return Coefficients(size: size, bounds: bounds, weights: weights)
    }

    static func resize(_ image: AyuBridgePixelImage, width: Int, height: Int, filter: Resampling, box: [Double]) -> AyuBridgePixelImage {
        let bands = image.mode.bands
        if filter == .nearest {
            var out = [UInt8](repeating: 0, count: width * height * bands)
            let scaleX = (box[2] - box[0]) / Double(width), scaleY = (box[3] - box[1]) / Double(height)
            let columns = (0..<width).map { min(image.width - 1, max(0, Int(box[0] + (Double($0) + 0.5) * scaleX))) }
            image.data.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<height {
                        let sy = min(image.height - 1, max(0, Int(box[1] + (Double(y) + 0.5) * scaleY)))
                        for x in 0..<width {
                            let source = (sy * image.width + columns[x]) * bands, target = (y * width + x) * bands
                            for band in 0..<bands { dst[target + band] = src[source + band] }
                        }
                    }
                }
            }
            return AyuBridgePixelImage(mode: image.mode, width: width, height: height, data: out)
        }
        // Pillow resamples alpha modes premultiplied, so transparent pixels do not bleed their color.
        let source = self.premultiplied(image)
        let needHorizontal = width != image.width || box[0] != 0 || box[2] != Double(image.width)
        let needVertical = height != image.height || box[1] != 0 || box[3] != Double(image.height)
        var vertical = self.coefficients(inSize: image.height, in0: box[1], in1: box[3], outSize: height, filter: filter)
        let firstRow = vertical.bounds[0]
        let lastRow = vertical.bounds[height * 2 - 2] + vertical.bounds[height * 2 - 1]
        var current = source.data
        var (currentWidth, currentHeight) = (image.width, image.height)
        let shift = self.precisionBits
        if needHorizontal {
            let horizontal = self.coefficients(inSize: image.width, in0: box[0], in1: box[2], outSize: width, filter: filter)
            let rows = needVertical ? firstRow..<lastRow : 0..<image.height
            var out = [UInt8](repeating: 0, count: width * rows.count * bands)
            current.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    horizontal.weights.withUnsafeBufferPointer { weights in
                        for (row, y) in rows.enumerated() {
                            for xx in 0..<width {
                                let xmin = horizontal.bounds[xx * 2], xmax = horizontal.bounds[xx * 2 + 1]
                                let base = xx * horizontal.size
                                for band in 0..<bands {
                                    var sum = 1 << (shift - 1)
                                    var index = (y * currentWidth + xmin) * bands + band
                                    for x in 0..<xmax {
                                        sum += Int(src[index]) * weights[base + x]
                                        index += bands
                                    }
                                    dst[(row * width + xx) * bands + band] = self.clip(sum >> shift)
                                }
                            }
                        }
                    }
                }
            }
            current = out
            currentWidth = width
            currentHeight = rows.count
            if needVertical { for index in 0..<height { vertical.bounds[index * 2] -= firstRow } }
        }
        if needVertical {
            var out = [UInt8](repeating: 0, count: currentWidth * height * bands)
            current.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    vertical.weights.withUnsafeBufferPointer { weights in
                        for yy in 0..<height {
                            let ymin = vertical.bounds[yy * 2], ymax = vertical.bounds[yy * 2 + 1]
                            let base = yy * vertical.size
                            for x in 0..<(currentWidth * bands) {
                                var sum = 1 << (shift - 1)
                                var index = ymin * currentWidth * bands + x
                                for y in 0..<ymax {
                                    sum += Int(src[index]) * weights[base + y]
                                    index += currentWidth * bands
                                }
                                dst[yy * currentWidth * bands + x] = self.clip(sum >> shift)
                            }
                        }
                    }
                }
            }
            current = out
            currentHeight = height
        }
        return self.unpremultiplied(AyuBridgePixelImage(mode: image.mode, width: currentWidth, height: currentHeight, data: current))
    }

    /// Output pixel (x, y) samples the source at `matrix` applied to its center; pixels that map
    /// outside the source keep `fill`.
    static func affine(_ image: AyuBridgePixelImage, width: Int, height: Int, matrix: [Double], filter: Resampling, fill: [UInt8]) -> AyuBridgePixelImage {
        let bands = image.mode.bands
        let premultiply = filter != .nearest && image.mode.hasAlpha
        let source = premultiply ? self.premultiplied(image) : image
        var background = AyuBridgePixelImage(mode: image.mode, width: width, height: height, color: fill)
        if premultiply { background = self.premultiplied(background) }
        let (w, h) = (image.width, image.height)
        source.data.withUnsafeBufferPointer { src in
            background.data.withUnsafeMutableBufferPointer { dst in
                @inline(__always) func sample(_ x: Int, _ y: Int, _ band: Int) -> Double {
                    Double(src[(y * w + min(w - 1, max(0, x))) * bands + band])
                }
                for y in 0..<height {
                    for x in 0..<width {
                        var xin = matrix[0] * (Double(x) + 0.5) + matrix[1] * (Double(y) + 0.5) + matrix[2]
                        var yin = matrix[3] * (Double(x) + 0.5) + matrix[4] * (Double(y) + 0.5) + matrix[5]
                        guard xin >= 0, xin < Double(w), yin >= 0, yin < Double(h) else { continue }
                        let target = (y * width + x) * bands
                        if filter == .nearest {
                            let index = (Int(yin) * w + Int(xin)) * bands
                            for band in 0..<bands { dst[target + band] = src[index + band] }
                            continue
                        }
                        xin -= 0.5; yin -= 0.5
                        let x0 = Int(xin.rounded(.down)), y0 = Int(yin.rounded(.down))
                        let dx = xin - Double(x0), dy = yin - Double(y0)
                        for band in 0..<bands {
                            if filter == .bilinear {
                                let row0 = min(h - 1, max(0, y0))
                                let v1 = sample(x0, row0, band) + (sample(x0 + 1, row0, band) - sample(x0, row0, band)) * dx
                                var v2 = v1
                                if y0 + 1 >= 0, y0 + 1 < h {
                                    v2 = sample(x0, y0 + 1, band) + (sample(x0 + 1, y0 + 1, band) - sample(x0, y0 + 1, band)) * dx
                                }
                                dst[target + band] = UInt8(max(0, min(255, v1 + (v2 - v1) * dy)))
                            } else {
                                func cubic(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ t: Double) -> Double {
                                    b + t * ((-a + c) + t * ((2 * (a - b) + c - d) + t * (-a + b - c + d)))
                                }
                                func row(_ y: Int) -> Double {
                                    cubic(sample(x0 - 1, y, band), sample(x0, y, band), sample(x0 + 1, y, band), sample(x0 + 2, y, band), dx)
                                }
                                let first = row(min(h - 1, max(0, y0 - 1)))
                                let second = y0 >= 0 && y0 < h ? row(y0) : first
                                let third = y0 + 1 >= 0 && y0 + 1 < h ? row(y0 + 1) : second
                                let fourth = y0 + 2 >= 0 && y0 + 2 < h ? row(y0 + 2) : third
                                let value = cubic(first, second, third, fourth, dy)
                                dst[target + band] = value <= 0 ? 0 : (value >= 255 ? 255 : UInt8(value))
                            }
                        }
                    }
                }
            }
        }
        return premultiply ? self.unpremultiplied(background) : background
    }

    // MARK: Compositing

    /// `source` (or `color`) goes to (x, y); with a mask every band is `dst + (src - dst) * mask / 255`.
    static func paste(_ image: inout AyuBridgePixelImage, source: AyuBridgePixelImage?, color: [UInt8], x: Int, y: Int, mask: AyuBridgePixelImage?) {
        let bands = image.mode.bands
        guard let shape = source ?? mask else { return }
        let x0 = max(0, x), x1 = min(image.width, x + shape.width)
        let y0 = max(0, y), y1 = min(image.height, y + shape.height)
        guard x0 < x1, y0 < y1 else { return }
        let maskBands = mask?.mode.bands ?? 0
        let (width, shapeWidth) = (image.width, shape.width)
        image.data.withUnsafeMutableBufferPointer { dst in
            func run(_ src: UnsafeBufferPointer<UInt8>?, _ coverage: UnsafeBufferPointer<UInt8>?) {
                for row in y0..<y1 {
                    for column in x0..<x1 {
                        let target = (row * width + column) * bands
                        let offset = (row - y) * shapeWidth + (column - x)
                        let amount = coverage.map { Int($0[offset * maskBands + maskBands - 1]) } ?? 255
                        for band in 0..<bands {
                            let value = src.map { Int($0[offset * bands + band]) } ?? Int(color[band])
                            dst[target + band] = amount == 255 ? UInt8(value) : UInt8(self.div255(Int(dst[target + band]) * (255 - amount) + value * amount))
                        }
                    }
                }
            }
            func withMask(_ src: UnsafeBufferPointer<UInt8>?) {
                if let mask { mask.data.withUnsafeBufferPointer { run(src, $0) } } else { run(src, nil) }
            }
            if let source { source.data.withUnsafeBufferPointer { withMask($0) } } else { withMask(nil) }
        }
    }

    @inline(__always) static func div255(_ value: Int) -> Int {
        let t = value + 128
        return ((t >> 8) + t) >> 8
    }

    /// `source` over `image`, both RGBA and the same size.
    static func alphaComposite(_ image: AyuBridgePixelImage, _ source: AyuBridgePixelImage) -> AyuBridgePixelImage {
        var out = image
        let bits = 7
        func shifted(_ value: Int) -> Int { ((value >> 8) + value) >> 8 }
        out.data.withUnsafeMutableBufferPointer { dst in
            source.data.withUnsafeBufferPointer { src in
                var index = 0
                while index < dst.count {
                    let alpha = Int(src[index + 3])
                    if alpha != 0 {
                        let blend = Int(dst[index + 3]) * (255 - alpha)
                        let outAlpha = alpha * 255 + blend
                        let first = alpha * 255 * 255 * (1 << bits) / outAlpha
                        let second = 255 * (1 << bits) - first
                        for band in 0..<3 {
                            let value = Int(src[index + band]) * first + Int(dst[index + band]) * second
                            dst[index + band] = UInt8(truncatingIfNeeded: shifted(value + (0x80 << bits)) >> bits)
                        }
                        dst[index + 3] = UInt8(truncatingIfNeeded: shifted(outAlpha + 0x80))
                    }
                    index += 4
                }
            }
        }
        return out
    }

    static func blend(_ image: AyuBridgePixelImage, _ other: AyuBridgePixelImage, alpha: Double) -> AyuBridgePixelImage {
        if alpha == 0 { return image }
        if alpha == 1 { return other }
        var out = image
        let inside = alpha >= 0 && alpha <= 1
        // Pillow keeps the factor in single precision.
        let factor = Float(alpha)
        out.data.withUnsafeMutableBufferPointer { dst in
            other.data.withUnsafeBufferPointer { src in
                for index in 0..<dst.count {
                    let value = Float(dst[index]) + factor * (Float(src[index]) - Float(dst[index]))
                    dst[index] = inside ? UInt8(max(0, min(255, value))) : (value <= 0 ? 0 : (value >= 255 ? 255 : UInt8(value)))
                }
            }
        }
        return out
    }

    /// Per-byte arithmetic over the common area of two images of one mode.
    static func chop(_ image: AyuBridgePixelImage, _ other: AyuBridgePixelImage, kind: String, scale: Double, offset: Double) -> AyuBridgePixelImage {
        let bands = image.mode.bands
        let (width, height) = (min(image.width, other.width), min(image.height, other.height))
        var out = [UInt8](repeating: 0, count: width * height * bands)
        image.data.withUnsafeBufferPointer { first in
            other.data.withUnsafeBufferPointer { second in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<height {
                        for x in 0..<(width * bands) {
                            let a = Int(first[y * image.width * bands + x]), b = Int(second[y * other.width * bands + x])
                            let value: Int
                            switch kind {
                            case "difference": value = abs(a - b)
                            case "multiply": value = a * b / 255
                            case "add": value = Int((Double(a + b) / scale + offset).rounded(.towardZero))
                            default: value = Int((Double(a - b) / scale + offset).rounded(.towardZero))
                            }
                            dst[y * width * bands + x] = self.clip(value)
                        }
                    }
                }
            }
        }
        return AyuBridgePixelImage(mode: image.mode, width: width, height: height, data: out)
    }

    /// Shifts the image with wraparound.
    static func offset(_ image: AyuBridgePixelImage, dx: Int, dy: Int) -> AyuBridgePixelImage {
        let (w, h, bands) = (image.width, image.height, image.mode.bands)
        let shiftX = ((-dx % w) + w) % w, shiftY = ((-dy % h) + h) % h
        var out = [UInt8](repeating: 0, count: image.data.count)
        image.data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let sy = (y + shiftY) % h
                    for x in 0..<w {
                        let source = (sy * w + (x + shiftX) % w) * bands, target = (y * w + x) * bands
                        for band in 0..<bands { dst[target + band] = src[source + band] }
                    }
                }
            }
        }
        return AyuBridgePixelImage(mode: image.mode, width: w, height: h, data: out)
    }
}

/// Neighbourhood filters with Pillow's kernels, borders and rounding (BoxBlur.c, Filter.c,
/// RankFilter.c, UnsharpMask.c). Every band is filtered on its own, alpha included.
enum AyuBridgeImageFilters {
    static func apply(_ image: AyuBridgePixelImage, arguments args: AyuBridgeImageArguments) throws -> AyuBridgePixelImage {
        switch try args.string("kind") {
        case "gaussian_blur":
            try args.only(["image", "kind", "radius"])
            let radius = try self.radius(args)
            return self.boxBlur(image, x: self.boxRadius(radius.0, passes: 3), y: self.boxRadius(radius.1, passes: 3), passes: 3)
        case "box_blur":
            try args.only(["image", "kind", "radius"])
            let radius = try self.radius(args)
            return self.boxBlur(image, x: Float(radius.0), y: Float(radius.1), passes: 1)
        case "kernel":
            try args.only(["image", "kind", "size", "kernel", "scale", "offset"])
            let size = try args.int("size")
            guard size == 3 || size == 5 else { throw AyuBridgeFailure.unsupported("image.filter kernel size") }
            let kernel = try args.doubles("kernel", count: size * size)
            let scale = try args.double("scale")
            guard scale != 0 else { throw AyuBridgeFailure("invalid_arguments", "scale must not be zero") }
            return self.convolve(image, size: size, kernel: kernel.map { Float($0 / scale) }, offset: Float(try args.optionalDouble("offset") ?? 0))
        case "rank":
            try args.only(["image", "kind", "size", "rank"])
            let size = try args.int("size"), rank = try args.int("rank")
            guard size >= 1, size <= 15, size % 2 == 1, rank >= 0, rank < size * size else { throw AyuBridgeFailure("invalid_arguments", "bad filter size") }
            return self.rank(image, size: size, rank: rank)
        case "unsharp":
            try args.only(["image", "kind", "radius", "percent", "threshold"])
            let radius = try self.radius(args)
            let percent = try args.int("percent"), threshold = try args.int("threshold")
            guard abs(percent) <= 100_000, abs(threshold) <= 100_000 else { throw AyuBridgeFailure("invalid_arguments", "bad unsharp parameters") }
            let blurred = self.boxBlur(image, x: self.boxRadius(radius.0, passes: 3), y: self.boxRadius(radius.1, passes: 3), passes: 3)
            var out = image
            out.data.withUnsafeMutableBufferPointer { dst in
                blurred.data.withUnsafeBufferPointer { soft in
                    for index in 0..<dst.count {
                        let original = Int(dst[index]), difference = original - Int(soft[index])
                        if abs(difference) >= threshold { dst[index] = AyuBridgeImageOps.clip(original + difference * percent / 100) }
                    }
                }
            }
            return out
        default:
            throw AyuBridgeFailure.unsupported("image.filter kind")
        }
    }

    private static func radius(_ args: AyuBridgeImageArguments) throws -> (Double, Double) {
        let values: [Double]
        if args.values["radius"]?.array != nil { values = try args.doubles("radius", count: 2) } else { values = [try args.double("radius")] }
        guard values.allSatisfy({ $0 >= 0 && $0 <= 4_096 }) else { throw AyuBridgeFailure("invalid_arguments", "radius must be 0...4096") }
        return (values[0], values[values.count - 1])
    }

    /// The box radius whose `passes` repetitions approximate a Gaussian of the given sigma.
    private static func boxRadius(_ radius: Double, passes: Int) -> Float {
        let sigma2 = Float(radius * radius) / Float(passes)
        let length = (12 * sigma2 + 1).squareRoot()
        let whole = ((length - 1) / 2).rounded(.down)
        var fraction = (2 * whole + 1) * (whole * (whole + 1) - 3 * sigma2)
        fraction /= 6 * (sigma2 - (whole + 1) * (whole + 1))
        return whole + fraction
    }

    private static func boxBlur(_ image: AyuBridgePixelImage, x: Float, y: Float, passes: Int) -> AyuBridgePixelImage {
        var out = image
        let (width, height, bands) = (image.width, image.height, image.mode.bands)
        out.data.withUnsafeMutableBufferPointer { data in
            if x != 0 {
                var line = [UInt8](repeating: 0, count: width), result = [UInt8](repeating: 0, count: width)
                for row in 0..<height {
                    for band in 0..<bands {
                        let start = row * width * bands + band
                        for index in 0..<width { line[index] = data[start + index * bands] }
                        for _ in 0..<passes { self.blurLine(&line, &result, radius: x) }
                        for index in 0..<width { data[start + index * bands] = line[index] }
                    }
                }
            }
            if y != 0 {
                var line = [UInt8](repeating: 0, count: height), result = [UInt8](repeating: 0, count: height)
                for column in 0..<width {
                    for band in 0..<bands {
                        let start = column * bands + band
                        for index in 0..<height { line[index] = data[start + index * width * bands] }
                        for _ in 0..<passes { self.blurLine(&line, &result, radius: y) }
                        for index in 0..<height { data[start + index * width * bands] = line[index] }
                    }
                }
            }
        }
        return out
    }

    /// One box blur of a line with edge pixels extended; the result replaces `line`.
    private static func blurLine(_ line: inout [UInt8], _ result: inout [UInt8], radius floatRadius: Float) {
        let count = line.count, last = count - 1
        let radius = Int(floatRadius)
        let weight = Int(Float(1 << 24) / (floatRadius * 2 + 1))
        let far = ((1 << 24) - (radius * 2 + 1) * weight) / 2
        let edgeA = min(radius + 1, count), edgeB = max(count - radius - 1, 0)
        line.withUnsafeBufferPointer { input in
            result.withUnsafeMutableBufferPointer { output in
                var accumulator = Int(input[0]) * (radius + 1)
                for x in 0..<(edgeA - 1) { accumulator += Int(input[x]) }
                accumulator += Int(input[last]) * (radius - edgeA + 1)
                @inline(__always) func step(_ x: Int, subtract: Int, add: Int, left: Int, right: Int) {
                    accumulator += Int(input[add]) - Int(input[subtract])
                    let bulk = accumulator * weight + (Int(input[left]) + Int(input[right])) * far
                    output[x] = UInt8(truncatingIfNeeded: (bulk + (1 << 23)) >> 24)
                }
                if edgeA <= edgeB {
                    for x in 0..<edgeA { step(x, subtract: 0, add: x + radius, left: 0, right: x + radius + 1) }
                    for x in edgeA..<edgeB { step(x, subtract: x - radius - 1, add: x + radius, left: x - radius - 1, right: x + radius + 1) }
                    for x in edgeB...last { step(x, subtract: x - radius - 1, add: last, left: x - radius - 1, right: last) }
                } else {
                    for x in 0..<edgeB { step(x, subtract: 0, add: x + radius, left: 0, right: x + radius + 1) }
                    for x in edgeB..<edgeA { step(x, subtract: 0, add: last, left: 0, right: last) }
                    for x in edgeA..<count { step(x, subtract: x - radius - 1, add: last, left: x - radius - 1, right: last) }
                }
            }
        }
        swap(&line, &result)
    }

    /// A 3x3 or 5x5 kernel; the border the kernel cannot cover keeps the source pixels. Kernel
    /// rows run from the bottom row of the window to the top one, as in Pillow.
    private static func convolve(_ image: AyuBridgePixelImage, size: Int, kernel: [Float], offset: Float) -> AyuBridgePixelImage {
        let (width, height, bands) = (image.width, image.height, image.mode.bands)
        let reach = size / 2
        var out = image
        guard width > 2 * reach, height > 2 * reach else { return out }
        image.data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                kernel.withUnsafeBufferPointer { weights in
                    for y in reach..<(height - reach) {
                        for x in reach..<(width - reach) {
                            for band in 0..<bands {
                                var sum = offset + 0.5
                                for ky in 0..<size {
                                    let row = (y + reach - ky) * width
                                    for kx in 0..<size {
                                        sum += Float(src[(row + x - reach + kx) * bands + band]) * weights[ky * size + kx]
                                    }
                                }
                                dst[(y * width + x) * bands + band] = sum <= 0 ? 0 : (sum >= 255 ? 255 : UInt8(sum))
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// The `rank`-th smallest value of each size x size window, edges repeated.
    private static func rank(_ image: AyuBridgePixelImage, size: Int, rank: Int) -> AyuBridgePixelImage {
        let (width, height, bands) = (image.width, image.height, image.mode.bands)
        let reach = size / 2
        var out = image
        var window = [UInt8](repeating: 0, count: size * size)
        image.data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    for x in 0..<width {
                        for band in 0..<bands {
                            var index = 0
                            for wy in (y - reach)...(y + reach) {
                                let row = min(height - 1, max(0, wy)) * width
                                for wx in (x - reach)...(x + reach) {
                                    window[index] = src[(row + min(width - 1, max(0, wx))) * bands + band]
                                    index += 1
                                }
                            }
                            window.sort()
                            dst[(y * width + x) * bands + band] = window[rank]
                        }
                    }
                }
            }
        }
        return out
    }
}
