import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Bounded TTML reader for the timed paragraphs/spans returned by Better Lyrics.
/// Uses Foundation's XML parser; no HTML rendering or external entity resolution.
enum ExteraLyricsTTMLParser {
    private enum Content {
        case text(String)
        case element(Element)
    }

    private final class Element {
        let name: String
        let attributes: [String: String]
        var children: [Content] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var root: Element?
        var stack: [Element] = []
        var count = 0
        var rejected = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            self.count += 1
            guard self.stack.count < 64, self.count <= ExteraLyricsParser.maximumWords else {
                self.rejected = true
                parser.abortParsing()
                return
            }
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict { attributes[String(key.split(separator: ":").last ?? Substring(key))] = value }
            let element = Element(name: String(elementName.split(separator: ":").last ?? Substring(elementName)), attributes: attributes)
            if let parent = self.stack.last { parent.children.append(.element(element)) }
            else { self.root = element }
            self.stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let element = self.stack.last else { return }
            // Coalesce parser chunks, including chunks split around an XML entity.
            if let last = element.children.last, case let .text(previous) = last {
                element.children[element.children.count - 1] = .text(previous + string)
            } else { element.children.append(.text(string)) }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if !self.stack.isEmpty { self.stack.removeLast() }
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { return nil }
    }

    private struct Clock {
        let frameRate: Double
        let subFrameRate: Double
        let tickRate: Double
        let absolute: Bool

        func time(_ value: String?) -> Double? {
            guard let value else { return nil }
            return ExteraLyricsParser.time(value, frameRate: self.frameRate, subFrameRate: self.subFrameRate, tickRate: self.tickRate)
        }
    }

    private struct Timing {
        let start: Double
        let end: Double?
        let hasStart: Bool
    }

    private static func timing(_ element: Element, parent: Timing, clock: Clock) -> Timing {
        let begin = clock.time(element.attributes["begin"])
        // iTunes/Apple lyric TTML (used by Better Lyrics) uses song-absolute
        // begin/end values on div, p and span. Standard TTML uses parent offsets.
        let origin = clock.absolute ? 0 : parent.start
        let start = begin.map { origin + $0 } ?? parent.start
        var end = clock.time(element.attributes["end"]).map { origin + $0 }
        if let duration = clock.time(element.attributes["dur"]) { end = min(end ?? .greatestFiniteMagnitude, start + duration) }
        if let parentEnd = parent.end { end = min(end ?? parentEnd, parentEnd) }
        return Timing(start: start, end: end, hasStart: parent.hasStart || begin != nil)
    }

    static func parse(_ xml: String, provider: String) -> ExteraLyricsDocument? {
        guard xml.utf8.count <= ExteraLyricsParser.maximumBytes,
              xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              let data = xml.data(using: .utf8) else { return nil }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.rejected, let root = reader.root, root.name == "tt" else { return nil }
        func positive(_ value: String?, fallback: Double) -> Double {
            guard let value, let number = Double(value), number.isFinite, number > 0 else { return fallback }
            return min(number, 1000000)
        }
        var rate = positive(root.attributes["frameRate"], fallback: 30)
        if let multiplier = root.attributes["frameRateMultiplier"]?.split(separator: " "), multiplier.count == 2,
           let numerator = Double(multiplier[0]), let denominator = Double(multiplier[1]),
           numerator.isFinite, denominator.isFinite, numerator > 0, denominator > 0 {
            rate *= numerator / denominator
        }
        guard rate.isFinite, rate > 0, rate <= 1000000 else { return nil }
        let subRate = positive(root.attributes["subFrameRate"], fallback: 1)
        let tickRate = positive(root.attributes["tickRate"], fallback: root.attributes["frameRate"] == nil ? 1 : rate * subRate)
        let clock = Clock(frameRate: rate, subFrameRate: subRate, tickRate: tickRate, absolute: root.attributes["timing"] != nil)
        var lines: [ExteraLyricsLine] = []
        func paragraph(_ element: Element, timing: Timing) {
            var text = ""
            var words: [ExteraLyricsWord] = []
            func append(_ value: String, preserve: Bool) {
                let value = preserve ? value : value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                if !preserve, text.hasSuffix(" "), value.hasPrefix(" ") { text += value.dropFirst() }
                else { text += value }
            }
            func walk(_ node: Element, parent: Timing, preserve: Bool) {
                let timing = self.timing(node, parent: parent, clock: clock)
                let preserve = node.attributes["space"].map { $0 == "preserve" } ?? preserve
                let role = node.attributes["role"] ?? ""
                // Auxiliary translation/romanization should not be sung as the primary line.
                if role == "x-translation" || role == "x-roman" { return }
                let start = (text as NSString).length
                let previousWordCount = words.count
                for child in node.children {
                    switch child {
                    case let .text(value): append(value, preserve: preserve)
                    case let .element(child):
                        if child.name == "br" { append("\n", preserve: true) }
                        else { walk(child, parent: timing, preserve: preserve) }
                    }
                }
                let length = (text as NSString).length - start
                if node.name == "span", node.attributes["begin"] != nil, words.count == previousWordCount, length > 0 {
                    words.append(ExteraLyricsWord(range: NSRange(location: start, length: length), start: timing.start, end: timing.end))
                }
            }
            // The paragraph timing has already been resolved; walk its children from that origin.
            let proxy = Element(name: "p", attributes: ["space": element.attributes["space"] ?? "default"])
            proxy.children = element.children
            walk(proxy, parent: timing, preserve: false)
            let leading = text.prefix(while: { $0.isWhitespace })
            let shift = (String(leading) as NSString).length
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let trimmedLength = (trimmed as NSString).length
            let adjusted = words.compactMap { word -> ExteraLyricsWord? in
                let location = max(0, word.range.location - shift)
                let end = min(trimmedLength, NSMaxRange(word.range) - shift)
                guard end > location else { return nil }
                return ExteraLyricsWord(range: NSRange(location: location, length: end - location), start: word.start, end: word.end)
            }
            guard let start = timing.hasStart ? timing.start : adjusted.first?.start else { return }
            if let end = timing.end, end < start { return }
            lines.append(ExteraLyricsLine(start: start, end: timing.end, text: trimmed, words: adjusted))
        }
        func collect(_ element: Element, parent: Timing, inBody: Bool) {
            let timing = self.timing(element, parent: parent, clock: clock)
            let inBody = inBody || element.name == "body"
            if inBody, element.name == "p" {
                if lines.count < ExteraLyricsParser.maximumLines { paragraph(element, timing: timing) }
                return
            }
            for child in element.children {
                if case let .element(child) = child { collect(child, parent: timing, inBody: inBody) }
            }
        }
        collect(root, parent: Timing(start: 0, end: nil, hasStart: false), inBody: false)
        return ExteraLyricsParser.normalized(lines: lines, provider: provider)
    }
}
