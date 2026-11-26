import Foundation
import ImageIO
import SGSimpleSettings
import UIKit

/// Static Core Graphics rendering only. Scripts, URLs, entities, CSS and foreign objects cannot reach this layer.
public enum ExteraUIIconRendering {
    private static let cache = NSCache<NSString, UIImage>()

    public static func validate(_ preview: ExteraUIIconPackImport) throws {
        for path in Set(preview.pack.icons.values) {
            guard let bytes = preview.files[path] else { throw ExteraUIIconError.corruptFile }
            _ = try image(data: bytes, path: path)
        }
    }
    public static func image(pack: ExteraCustomUIIconPack, path: String) -> UIImage? {
        let key = (pack.revision + ":" + path) as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let bytes = try? ExteraUIIconPackStore.shared.data(for: pack, path: path), let image = try? self.image(data: bytes, path: path) else { return nil }
        cache.totalCostLimit = 16 * 1024 * 1024
        cache.setObject(image, forKey: key, cost: 72 * 72 * 4)
        return image
    }
    public static func image(data: Data, path: String) throws -> UIImage {
        guard data.count <= ExteraUIIconArchive.maxFileBytes else { throw ExteraUIIconError.limitExceeded }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "svg" || ext == "xml" {
            let root = try ExteraUIIconVector.parse(data)
            let renderer = try VectorRenderer(root)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3; format.opaque = false
            var failure: Error?
            let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).image { context in
                do { try renderer.draw(context.cgContext) } catch { failure = error }
            }
            if let failure { throw failure }
            return image.withRenderingMode(.alwaysTemplate)
        }
        guard ["png", "jpg", "jpeg", "webp"].contains(ext),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? NSNumber, let h = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              w.int64Value > 0, h.int64Value > 0, w.int64Value <= 100_000_000 / h.int64Value,
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 72] as CFDictionary) else { throw ExteraUIIconError.unsupportedImage }
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(x: 0, y: 0, width: 24, height: 24))
        }.withRenderingMode(.alwaysTemplate)
    }

    private final class VectorRenderer {
        let root: ExteraUIIconVectorNode
        var definitions: [String: ExteraUIIconVectorNode] = [:]
        let viewBox: CGRect
        var operations = 0

        init(_ root: ExteraUIIconVectorNode) throws {
            self.root = root
            if let value = root.attributes["viewBox"] {
                let values = try numbers(value)
                guard values.count == 4, values[2] > 0, values[3] > 0 else { throw ExteraUIIconError.unsupportedImage }
                self.viewBox = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
            } else {
                self.viewBox = CGRect(x: 0, y: 0, width: try scalar(root.attributes["width"] ?? "24"), height: try scalar(root.attributes["height"] ?? "24"))
            }
            guard self.viewBox.width >= 0.001, self.viewBox.height >= 0.001 else { throw ExteraUIIconError.unsupportedImage }
            func collect(_ node: ExteraUIIconVectorNode) throws {
                if let id = node.attributes["id"] {
                    guard definitions[id] == nil else { throw ExteraUIIconError.unsupportedImage }
                    definitions[id] = node
                }
                for child in node.children { try collect(child) }
            }
            try collect(root)
        }
        func draw(_ context: CGContext) throws {
            let sx = 24 / viewBox.width, sy = 24 / viewBox.height
            let none = root.attributes["preserveAspectRatio"] == "none"
            let scale = min(sx, sy)
            context.translateBy(x: none ? 0 : (24 - viewBox.width * scale) / 2, y: none ? 0 : (24 - viewBox.height * scale) / 2)
            context.scaleBy(x: none ? sx : scale, y: none ? sy : scale)
            context.translateBy(x: -viewBox.minX, y: -viewBox.minY)
            try self.node(root, context, inherited: ["fill": "black", "stroke": "none", "color": "white"])
        }
        func node(_ node: ExteraUIIconVectorNode, _ context: CGContext, inherited: [String: String]) throws {
            self.operations += 1 + (node.attributes["d"]?.utf8.count ?? 0) / 2 + (node.attributes["points"]?.utf8.count ?? 0) / 2
            guard operations <= 200_000 else { throw ExteraUIIconError.limitExceeded }
            if ["defs", "clipPath", "linearGradient", "radialGradient", "stop", "title", "desc"].contains(node.name) { return }
            var style = inherited
            for (key, value) in node.attributes { style[key] = value }
            context.saveGState(); defer { context.restoreGState() }
            if let value = node.attributes["transform"] { context.concatenate(try transform(value)) }
            let ctm = context.ctm
            guard [ctm.a, ctm.b, ctm.c, ctm.d, ctm.tx, ctm.ty].allSatisfy({ $0.isFinite && abs($0) <= 100_000_000 }) else { throw ExteraUIIconError.limitExceeded }
            // Group opacity applies once to the composited group rather than independently to its children.
            let opacity = try alpha(node.attributes["opacity"] ?? "1")
            context.setAlpha(opacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { context.endTransparencyLayer() }
            if let clip = node.attributes["clip-path"] {
                guard let id = reference(clip), let definition = definitions[id], definition.name == "clipPath" else { throw ExteraUIIconError.unsupportedImage }
                let path = try clipPath(definition)
                context.addPath(path)
                context.clip(using: definition.attributes["clip-rule"] == "evenodd" ? .evenOdd : .winding)
            }
            if node.name == "g" || node.name == "svg" {
                var childStyle = style
                for key in ["opacity", "transform", "clip-path", "id"] { childStyle.removeValue(forKey: key) }
                for child in node.children { try self.node(child, context, inherited: childStyle) }
                return
            }
            let path = try shape(node)
            let fill = style["fill"] ?? "black", stroke = style["stroke"] ?? "none"
            let rule: CGPathFillRule = style["fill-rule"] == "evenodd" ? .evenOdd : .winding
            if fill != "none" {
                context.saveGState(); context.setAlpha(try alpha(style["fill-opacity"] ?? "1"))
                if let id = reference(fill) {
                    context.addPath(path); context.clip(using: rule)
                    try gradient(id, context, bounds: path.boundingBoxOfPath)
                } else { context.setFillColor(try color(fill, current: style["color"] ?? "white")); context.addPath(path); context.drawPath(using: rule == .evenOdd ? .eoFill : .fill) }
                context.restoreGState()
            }
            if stroke != "none" {
                context.saveGState(); defer { context.restoreGState() }
                let width = try scalar(style["stroke-width"] ?? "1")
                guard width >= 0 else { throw ExteraUIIconError.unsupportedImage }
                context.setLineWidth(width)
                switch style["stroke-linecap"] ?? "butt" {
                case "butt": context.setLineCap(.butt)
                case "round": context.setLineCap(.round)
                case "square": context.setLineCap(.square)
                default: throw ExteraUIIconError.unsupportedImage
                }
                switch style["stroke-linejoin"] ?? "miter" {
                case "miter": context.setLineJoin(.miter)
                case "round": context.setLineJoin(.round)
                case "bevel": context.setLineJoin(.bevel)
                default: throw ExteraUIIconError.unsupportedImage
                }
                context.setMiterLimit(max(1, try scalar(style["stroke-miterlimit"] ?? "4")))
                context.setAlpha(try alpha(style["stroke-opacity"] ?? "1"))
                context.addPath(path)
                if let id = reference(stroke) { context.replacePathWithStrokedPath(); context.clip(); try gradient(id, context, bounds: path.boundingBoxOfPath) }
                else { context.setStrokeColor(try color(stroke, current: style["color"] ?? "white")); context.strokePath() }
            }
        }
        func clipPath(_ node: ExteraUIIconVectorNode) throws -> CGPath {
            let result = CGMutablePath()
            for child in node.children {
                let path: CGPath
                if child.name == "g" { path = try clipPath(child) } else { path = try shape(child) }
                result.addPath(path, transform: try transform(child.attributes["transform"] ?? ""))
            }
            var t = try transform(node.attributes["transform"] ?? "")
            return result.copy(using: &t) ?? result
        }
        func gradient(_ id: String, _ context: CGContext, bounds: CGRect) throws {
            guard let node = definitions[id], ["linearGradient", "radialGradient"].contains(node.name), node.children.count >= 2 else { throw ExteraUIIconError.unsupportedImage }
            var colors: [CGColor] = [], locations: [CGFloat] = []
            for stop in node.children {
                guard stop.name == "stop" else { throw ExteraUIIconError.unsupportedImage }
                let offset = try fraction(stop.attributes["offset"] ?? "0")
                guard offset >= (locations.last ?? 0), offset <= 1 else { throw ExteraUIIconError.unsupportedImage }
                let c = try color(stop.attributes["stop-color"] ?? "black", current: "white")
                guard let painted = c.copy(alpha: try alpha(stop.attributes["stop-opacity"] ?? "1")) else { throw ExteraUIIconError.unsupportedImage }
                locations.append(offset); colors.append(painted)
            }
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: locations) else { throw ExteraUIIconError.unsupportedImage }
            context.saveGState(); defer { context.restoreGState() }
            let units = node.attributes["gradientUnits"] ?? "objectBoundingBox"
            if units == "objectBoundingBox" {
                guard bounds.width > 0, bounds.height > 0 else { return }
                context.translateBy(x: bounds.minX, y: bounds.minY); context.scaleBy(x: bounds.width, y: bounds.height)
            } else if units != "userSpaceOnUse" { throw ExteraUIIconError.unsupportedImage }
            context.concatenate(try transform(node.attributes["gradientTransform"] ?? ""))
            func coordinate(_ key: String, _ defaultValue: String) throws -> CGFloat {
                let value = node.attributes[key] ?? defaultValue
                if value.hasSuffix("%"), units == "userSpaceOnUse" { return try fraction(value) * (["y1", "y2", "cy", "fy"].contains(key) ? self.viewBox.height : self.viewBox.width) }
                return try fraction(value)
            }
            if node.name == "linearGradient" {
                context.drawLinearGradient(gradient, start: CGPoint(x: try coordinate("x1", "0"), y: try coordinate("y1", "0")), end: CGPoint(x: try coordinate("x2", "1"), y: try coordinate("y2", "0")), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else {
                let cx = try coordinate("cx", "0.5"), cy = try coordinate("cy", "0.5"), r = try coordinate("r", "0.5")
                guard r > 0 else { throw ExteraUIIconError.unsupportedImage }
                context.drawRadialGradient(gradient, startCenter: CGPoint(x: try coordinate("fx", String(Double(cx))), y: try coordinate("fy", String(Double(cy)))), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: r, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
    }

    private static func shape(_ node: ExteraUIIconVectorNode) throws -> CGPath {
        let a = node.attributes
        func n(_ key: String, _ fallback: String = "0") throws -> CGFloat { return try scalar(a[key] ?? fallback) }
        let path = CGMutablePath()
        switch node.name {
        case "path": return try ExteraUIIconPath.parse(a["d"] ?? "")
        case "rect":
            let w = try n("width"), h = try n("height"), rx = try n("rx", a["ry"] ?? "0"), ry = try n("ry", a["rx"] ?? "0")
            guard w >= 0, h >= 0, rx >= 0, ry >= 0 else { throw ExteraUIIconError.unsupportedImage }
            path.addRoundedRect(in: CGRect(x: try n("x"), y: try n("y"), width: w, height: h), cornerWidth: min(rx, w / 2), cornerHeight: min(ry, h / 2))
        case "circle", "ellipse":
            let rx = try n(node.name == "circle" ? "r" : "rx"), ry = try n(node.name == "circle" ? "r" : "ry")
            guard rx >= 0, ry >= 0 else { throw ExteraUIIconError.unsupportedImage }
            path.addEllipse(in: CGRect(x: try n("cx") - rx, y: try n("cy") - ry, width: rx * 2, height: ry * 2))
        case "line": path.move(to: CGPoint(x: try n("x1"), y: try n("y1"))); path.addLine(to: CGPoint(x: try n("x2"), y: try n("y2")))
        case "polygon", "polyline":
            let values = try numbers(a["points"] ?? "")
            guard values.count >= 4, values.count % 2 == 0 else { throw ExteraUIIconError.unsupportedImage }
            path.move(to: CGPoint(x: values[0], y: values[1]))
            for i in stride(from: 2, to: values.count, by: 2) { path.addLine(to: CGPoint(x: values[i], y: values[i + 1])) }
            if node.name == "polygon" { path.closeSubpath() }
        default: throw ExteraUIIconError.unsupportedImage
        }
        return path
    }
    private static func scalar(_ value: String) throws -> CGFloat {
        let text = value.hasSuffix("px") ? String(value.dropLast(2)) : value
        guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite, abs(number) <= 1_000_000 else { throw ExteraUIIconError.unsupportedImage }
        return CGFloat(number)
    }
    private static func numbers(_ value: String) throws -> [CGFloat] {
        return try ExteraUIIconPath.tokens(value, commands: false).map { try scalar($0) }
    }
    private static func fraction(_ value: String) throws -> CGFloat { return value.hasSuffix("%") ? try scalar(String(value.dropLast())) / 100 : try scalar(value) }
    private static func alpha(_ value: String) throws -> CGFloat { let result = try scalar(value); guard (0 ... 1).contains(result) else { throw ExteraUIIconError.unsupportedImage }; return result }
    private static func reference(_ value: String) -> String? { return value.hasPrefix("url(#") && value.hasSuffix(")") ? String(value.dropFirst(5).dropLast()) : nil }
    private static func color(_ value: String, current: String) throws -> CGColor {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text == "currentcolor" { guard current.lowercased() != "currentcolor" else { throw ExteraUIIconError.unsupportedImage }; return try color(current, current: "white") }
        let named: [String: UInt32] = ["white": 0xffffff, "black": 0, "red": 0xff0000, "green": 0x008000, "blue": 0x0000ff, "gray": 0x808080, "grey": 0x808080, "yellow": 0xffff00]
        if text == "transparent" { return UIColor.clear.cgColor }
        if let value = named[text] { return UIColor(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1).cgColor }
        if text.hasPrefix("#") {
            var hex = String(text.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard [6, 8].contains(hex.count), let number = UInt32(hex, radix: 16) else { throw ExteraUIIconError.unsupportedImage }
            let rgb = hex.count == 8 ? number >> 8 : number
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: hex.count == 8 ? CGFloat(number & 255) / 255 : 1).cgColor
        }
        if text.hasPrefix("rgb("), text.hasSuffix(")") {
            let values = try numbers(String(text.dropFirst(4).dropLast()))
            guard values.count == 3, values.allSatisfy({ (0 ... 255).contains($0) }) else { throw ExteraUIIconError.unsupportedImage }
            return UIColor(red: values[0] / 255, green: values[1] / 255, blue: values[2] / 255, alpha: 1).cgColor
        }
        throw ExteraUIIconError.unsupportedImage
    }
    private static func transform(_ value: String) throws -> CGAffineTransform {
        let regex = try NSRegularExpression(pattern: #"([A-Za-z]+)\s*\(([^()]*)\)"#)
        let text = value as NSString
        var end = 0, result = CGAffineTransform.identity
        for match in regex.matches(in: value, range: NSRange(location: 0, length: text.length)) {
            guard text.substring(with: NSRange(location: end, length: match.range.location - end)).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))).isEmpty else { throw ExteraUIIconError.unsupportedImage }
            let name = text.substring(with: match.range(at: 1)), n = try numbers(text.substring(with: match.range(at: 2)))
            let next: CGAffineTransform
            switch name {
            case "matrix" where n.count == 6: next = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            case "translate" where n.count == 1 || n.count == 2: next = CGAffineTransform(translationX: n[0], y: n.count == 2 ? n[1] : 0)
            case "scale" where n.count == 1 || n.count == 2: next = CGAffineTransform(scaleX: n[0], y: n.count == 2 ? n[1] : n[0])
            case "rotate" where n.count == 1 || n.count == 3:
                let rotation = CGAffineTransform(rotationAngle: n[0] * .pi / 180)
                next = n.count == 3 ? CGAffineTransform(translationX: -n[1], y: -n[2]).concatenating(rotation).concatenating(CGAffineTransform(translationX: n[1], y: n[2])) : rotation
            case "skewX" where n.count == 1: next = CGAffineTransform(a: 1, b: 0, c: tan(n[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewY" where n.count == 1: next = CGAffineTransform(a: 1, b: tan(n[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: throw ExteraUIIconError.unsupportedImage
            }
            result = next.concatenating(result)
            guard [result.a, result.b, result.c, result.d, result.tx, result.ty].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else { throw ExteraUIIconError.limitExceeded }
            end = match.range.location + match.range.length
        }
        guard text.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExteraUIIconError.unsupportedImage }
        return result
    }
}

private enum ExteraUIIconPath {
    static func tokens(_ string: String, commands: Bool) throws -> [String] {
        let regex = try NSRegularExpression(pattern: commands ? #"[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?"# : #"[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?"#)
        let text = string as NSString
        var end = 0, result: [String] = []
        for match in regex.matches(in: string, range: NSRange(location: 0, length: text.length)) {
            guard result.count < 100_000, text.substring(with: NSRange(location: end, length: match.range.location - end)).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))).isEmpty else { throw ExteraUIIconError.unsupportedImage }
            result.append(text.substring(with: match.range)); end = match.range.location + match.range.length
        }
        guard text.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ExteraUIIconError.unsupportedImage }
        return result
    }
    static func parse(_ string: String) throws -> CGPath {
        let tokens = try self.tokens(string, commands: true)
        let path = CGMutablePath()
        var index = 0, command = "", previous = "", current = CGPoint.zero, start = CGPoint.zero, control = CGPoint.zero
        func number() throws -> CGFloat {
            guard index < tokens.count, let value = Double(tokens[index]), value.isFinite, abs(value) <= 1_000_000 else { throw ExteraUIIconError.unsupportedImage }
            index += 1; return CGFloat(value)
        }
        while index < tokens.count {
            if tokens[index].first?.isLetter == true { command = tokens[index]; index += 1 }
            guard !command.isEmpty else { throw ExteraUIIconError.unsupportedImage }
            let upper = command.uppercased(), relative = command != upper
            if path.isEmpty && upper != "M" { throw ExteraUIIconError.unsupportedImage }
            let origin = current
            func point() throws -> CGPoint { return CGPoint(x: try number() + (relative ? origin.x : 0), y: try number() + (relative ? origin.y : 0)) }
            switch upper {
            case "M": current = try point(); path.move(to: current); start = current; command = relative ? "l" : "L"
            case "L": current = try point(); path.addLine(to: current)
            case "H": current.x = try number() + (relative ? origin.x : 0); path.addLine(to: current)
            case "V": current.y = try number() + (relative ? origin.y : 0); path.addLine(to: current)
            case "C": let a = try point(), b = try point(), end = try point(); path.addCurve(to: end, control1: a, control2: b); control = b; current = end
            case "S":
                let a = ["C", "S"].contains(previous) ? CGPoint(x: origin.x * 2 - control.x, y: origin.y * 2 - control.y) : origin
                let b = try point(), end = try point(); path.addCurve(to: end, control1: a, control2: b); control = b; current = end
            case "Q": let a = try point(), end = try point(); path.addQuadCurve(to: end, control: a); control = a; current = end
            case "T":
                let a = ["Q", "T"].contains(previous) ? CGPoint(x: origin.x * 2 - control.x, y: origin.y * 2 - control.y) : origin
                let end = try point(); path.addQuadCurve(to: end, control: a); control = a; current = end
            case "A":
                let rx = try number(), ry = try number(), angle = try number(), large = try number(), sweep = try number(), end = try point()
                guard [CGFloat(0), 1].contains(large), [CGFloat(0), 1].contains(sweep), rx >= 0, ry >= 0 else { throw ExteraUIIconError.unsupportedImage }
                try arc(path, from: origin, to: end, rx: rx, ry: ry, angle: angle, large: large == 1, sweep: sweep == 1); current = end
            case "Z": path.closeSubpath(); current = start; command = ""
            default: throw ExteraUIIconError.unsupportedImage
            }
            previous = upper
        }
        return path
    }
    private static func arc(_ path: CGMutablePath, from p: CGPoint, to q: CGPoint, rx inputX: CGFloat, ry inputY: CGFloat, angle: CGFloat, large: Bool, sweep: Bool) throws {
        if p == q { return }
        if inputX == 0 || inputY == 0 { path.addLine(to: q); return }
        guard inputX >= 0.000001, inputY >= 0.000001 else { throw ExteraUIIconError.limitExceeded }
        let phi = angle * .pi / 180, c = cos(phi), s = sin(phi)
        let dx = (p.x - q.x) / 2, dy = (p.y - q.y) / 2
        let x = c * dx + s * dy, y = -s * dx + c * dy
        var rx = inputX, ry = inputY
        let ratio = x * x / (rx * rx) + y * y / (ry * ry)
        if ratio > 1 { rx *= sqrt(ratio); ry *= sqrt(ratio) }
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y * y - ry * ry * x * x)
        let denominator = rx * rx * y * y + ry * ry * x * x
        let k = (large == sweep ? CGFloat(-1) : 1) * sqrt(numerator / max(denominator, .leastNonzeroMagnitude))
        let cx = k * rx * y / ry, cy = -k * ry * x / rx
        let center = CGPoint(x: c * cx - s * cy + (p.x + q.x) / 2, y: s * cx + c * cy + (p.y + q.y) / 2)
        let a = atan2((y - cy) / ry, (x - cx) / rx)
        var delta = atan2((-y - cy) / ry, (-x - cx) / rx) - a
        if sweep && delta < 0 { delta += 2 * .pi }; if !sweep && delta > 0 { delta -= 2 * .pi }
        guard [rx, ry, center.x, center.y, a, delta].allSatisfy({ $0.isFinite && abs($0) <= 10_000_000 }) else { throw ExteraUIIconError.limitExceeded }
        let pieces = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        func position(_ t: CGFloat) -> CGPoint { return CGPoint(x: center.x + c * rx * cos(t) - s * ry * sin(t), y: center.y + s * rx * cos(t) + c * ry * sin(t)) }
        func derivative(_ t: CGFloat) -> CGPoint { return CGPoint(x: -c * rx * sin(t) - s * ry * cos(t), y: -s * rx * sin(t) + c * ry * cos(t)) }
        for i in 0 ..< pieces {
            let t = a + delta * CGFloat(i) / CGFloat(pieces), u = a + delta * CGFloat(i + 1) / CGFloat(pieces)
            let factor = 4 / CGFloat(3) * tan((u - t) / 4)
            let first = position(t), last = position(u), d1 = derivative(t), d2 = derivative(u)
            path.addCurve(to: last, control1: CGPoint(x: first.x + factor * d1.x, y: first.y + factor * d1.y), control2: CGPoint(x: last.x - factor * d2.x, y: last.y - factor * d2.y))
        }
    }
}
