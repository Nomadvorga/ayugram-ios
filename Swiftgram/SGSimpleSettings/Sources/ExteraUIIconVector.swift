import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A closed static vector vocabulary. Never passed to a web view or an external SVG engine.
public final class ExteraUIIconVectorNode {
    public let name: String
    public let attributes: [String: String]
    public fileprivate(set) var children: [ExteraUIIconVectorNode] = []
    fileprivate init(_ name: String, _ attributes: [String: String]) { self.name = name; self.attributes = attributes }
}

public enum ExteraUIIconVector {
    public static func parse(_ data: Data) throws -> ExteraUIIconVectorNode {
        guard data.count <= ExteraUIIconArchive.maxFileBytes, let text = String(data: data, encoding: .utf8) else { throw ExteraUIIconError.unsupportedImage }
        let lower = text.lowercased()
        guard !lower.contains("<!doctype"), !lower.contains("<!entity") else { throw ExteraUIIconError.unsupportedImage }
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.failed, let root = delegate.root, root.name == "svg" else { throw ExteraUIIconError.unsupportedImage }
        return root
    }

    /// Android VectorDrawable input is exported as equivalent static SVG for .icons interoperability.
    public static func svgData(_ data: Data) throws -> Data {
        let root = try parse(data)
        func escape(_ text: String) -> String { return text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;") }
        func xml(_ node: ExteraUIIconVectorNode) -> String {
            let attributes = node.attributes.keys.sorted().map { " " + $0 + "=\"" + escape(node.attributes[$0]!) + "\"" }.joined()
            return "<" + node.name + attributes + ">" + node.children.map(xml).joined() + "</" + node.name + ">"
        }
        return Data(xml(root).utf8)
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var root: ExteraUIIconVectorNode?
        var stack: [ExteraUIIconVectorNode] = []
        var failed = false
        var count = 0
        var textBytes = 0
        var android = false
        private let elements: Set<String> = ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "defs", "clipPath", "linearGradient", "radialGradient", "stop", "title", "desc"]
        private let attributes: Set<String> = ["xmlns", "xmlns:xlink", "version", "id", "viewBox", "width", "height", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy", "d", "points", "fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "opacity", "color", "transform", "clip-path", "clip-rule", "clipPathUnits", "gradientUnits", "gradientTransform", "offset", "stop-color", "stop-opacity", "preserveAspectRatio"]
        private let styleKeys: Set<String> = ["fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "opacity", "color", "clip-path", "stop-color", "stop-opacity"]
        private func reject(_ parser: XMLParser) { self.failed = true; parser.abortParsing() }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            self.count += 1
            guard self.count <= 20_000, self.stack.count < 64 else { self.reject(parser); return }
            var name = elementName, attrs = attributeDict
            if self.stack.isEmpty { self.android = name == "vector" }
            if self.android {
                guard let converted = self.convertAndroid(name, attrs) else { self.reject(parser); return }
                name = converted.0; attrs = converted.1
            }
            if let style = attrs.removeValue(forKey: "style") {
                for statement in style.split(separator: ";") {
                    let parts = statement.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    guard parts.count == 2, self.styleKeys.contains(parts[0]) else { self.reject(parser); return }
                    attrs[parts[0]] = parts[1]
                }
            }
            guard self.elements.contains(name), self.stack.isEmpty ? name == "svg" && self.root == nil : name != "svg",
                  attrs.allSatisfy({ self.attributes.contains($0.key) && $0.value.utf8.count <= 256 * 1024 }) else { self.reject(parser); return }
            for (key, value) in attrs {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if key == "xmlns" || key == "xmlns:xlink" { continue }
                guard !normalized.contains("javascript:"), !normalized.contains("data:"), !normalized.contains("://"), !normalized.contains("\\") else { self.reject(parser); return }
                if normalized.contains("url(") {
                    guard ["fill", "stroke", "clip-path"].contains(key), value.range(of: #"^url\(#[A-Za-z_][A-Za-z0-9_.-]*\)$"#, options: .regularExpression) != nil else { self.reject(parser); return }
                }
            }
            if name == "svg" {
                guard attrs["preserveAspectRatio"] == nil || ["xMidYMid meet", "none"].contains(attrs["preserveAspectRatio"]!) else { self.reject(parser); return }
            }
            if name == "clipPath", let units = attrs["clipPathUnits"], units != "userSpaceOnUse" { self.reject(parser); return }
            let node = ExteraUIIconVectorNode(name, attrs)
            if let parent = self.stack.last { parent.children.append(node) } else { self.root = node }
            self.stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if !self.stack.isEmpty { self.stack.removeLast() } }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            self.textBytes += string.utf8.count
            if self.textBytes > 2 * 1024 * 1024 || (!string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !["title", "desc"].contains(self.stack.last?.name ?? "")) { self.reject(parser) }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { self.reject(parser) }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { self.reject(parser); return nil }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { self.reject(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { self.reject(parser) }

        private func convertAndroid(_ name: String, _ original: [String: String]) -> (String, [String: String])? {
            var attrs: [String: String] = [:]
            for (key, value) in original where !key.hasPrefix("xmlns") { attrs[key.replacingOccurrences(of: "android:", with: "")] = value }
            func paint(_ value: String) -> (String, String)? {
                if value.count == 9, value.hasPrefix("#"), let alpha = UInt8(value.dropFirst().prefix(2), radix: 16) {
                    return ("#" + value.dropFirst(3), String(Double(alpha) / 255))
                }
                if value.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) != nil { return (value, "1") }
                return nil
            }
            switch name {
            case "vector":
                guard Set(attrs.keys).isSubset(of: ["width", "height", "viewportWidth", "viewportHeight", "alpha", "name"]),
                      let width = attrs["viewportWidth"], let height = attrs["viewportHeight"] else { return nil }
                return ("svg", ["xmlns": "http://www.w3.org/2000/svg", "viewBox": "0 0 \(width) \(height)", "opacity": attrs["alpha"] ?? "1"])
            case "group":
                guard Set(attrs.keys).isSubset(of: ["name", "rotation", "pivotX", "pivotY", "scaleX", "scaleY", "translateX", "translateY"]) else { return nil }
                let px = attrs["pivotX"] ?? "0", py = attrs["pivotY"] ?? "0"
                guard let x = Double(px), let y = Double(py), x.isFinite, y.isFinite else { return nil }
                return ("g", ["transform": "translate(\(attrs["translateX"] ?? "0") \(attrs["translateY"] ?? "0")) translate(\(px) \(py)) rotate(\(attrs["rotation"] ?? "0")) scale(\(attrs["scaleX"] ?? "1") \(attrs["scaleY"] ?? "1")) translate(\(-x) \(-y))"])
            case "path":
                guard Set(attrs.keys).isSubset(of: ["name", "pathData", "fillColor", "fillAlpha", "fillType", "strokeColor", "strokeAlpha", "strokeWidth", "strokeLineCap", "strokeLineJoin", "strokeMiterLimit"]), let path = attrs["pathData"] else { return nil }
                var output = ["d": path, "fill": "none"]
                for (source, target) in [("fillColor", "fill"), ("strokeColor", "stroke")] {
                    if let value = attrs[source] {
                        guard let (color, alpha) = paint(value) else { return nil }
                        output[target] = color
                        let separate = Double(attrs[target + "Alpha"] ?? "1") ?? -1
                        guard separate >= 0, separate <= 1 else { return nil }
                        output[target + "-opacity"] = String((Double(alpha) ?? 1) * separate)
                    }
                }
                for (source, target) in [("strokeWidth", "stroke-width"), ("strokeLineCap", "stroke-linecap"), ("strokeLineJoin", "stroke-linejoin"), ("strokeMiterLimit", "stroke-miterlimit")] { output[target] = attrs[source] }
                output["fill-rule"] = attrs["fillType"] == "evenOdd" ? "evenodd" : "nonzero"
                return ("path", output)
            default: return nil
            }
        }
    }
}
