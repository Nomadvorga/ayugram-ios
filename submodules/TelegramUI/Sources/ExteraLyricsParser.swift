import Foundation

// Native adaptation of exteraGram's player/lyrics model and timestamp conventions.
// All ranges use UTF-16, matching NSAttributedString and TextNode.
struct ExteraLyricsWord: Codable, Equatable {
    let range: NSRange
    let start: Double
    let end: Double?
}

struct ExteraLyricsLine: Codable, Equatable {
    let start: Double?
    let end: Double?
    let text: String
    let words: [ExteraLyricsWord]
}

struct ExteraLyricsDocument: Codable, Equatable {
    let lines: [ExteraLyricsLine]
    let provider: String
    let instrumental: Bool

    var isTimed: Bool { return self.lines.first?.start != nil }
    var hasWords: Bool { return self.lines.contains(where: { !$0.words.isEmpty }) }
    var rank: Int { return self.hasWords ? 3 : (self.isTimed || self.instrumental ? 2 : 1) }

    /// Binary search keeps playback ticks independent of transcript length. Explicit ends
    /// (TTML/LrcMux and blank LRC cues) prevent the previous lyric lingering through a gap.
    func activeLine(at time: Double) -> Int? {
        guard time.isFinite, self.isTimed else { return nil }
        var lower = 0
        var upper = self.lines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if let start = self.lines[middle].start, start <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return nil }
        let index = lower - 1
        if let end = self.lines[index].end, time >= end { return nil }
        return index
    }
}

enum ExteraLyricsParser {
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumLines = 12000
    static let maximumWords = 100000

    static func parse(_ source: String, provider: String) -> ExteraLyricsDocument? {
        guard source.utf8.count <= self.maximumBytes else { return nil }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{feff}", with: "")
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("<") { return ExteraLyricsTTMLParser.parse(text, provider: provider) }
        if let timed = self.parseLRC(text, provider: provider) { return timed }
        // Malformed timestamped input must not expose raw markup as plain lyrics.
        let lines = text.components(separatedBy: .newlines).compactMap { raw -> ExteraLyricsLine? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("[") else { return nil }
            return ExteraLyricsLine(start: nil, end: nil, text: line, words: [])
        }
        guard !lines.isEmpty, lines.count <= self.maximumLines else { return nil }
        return ExteraLyricsDocument(lines: lines, provider: provider, instrumental: false)
    }

    /// LRC accepts mm:ss.xx / mm:ss:xxx and hh:mm:ss.xxx. TTML also uses
    /// offset units, clock frames, frameRateMultiplier, subFrameRate and tickRate.
    static func time(_ value: String, frameRate: Double = 30, subFrameRate: Double = 1, tickRate: Double = 1, lrc: Bool = false) -> Double? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let units: [(String, Double)] = [("ms", 0.001), ("h", 3600), ("m", 60), ("s", 1), ("f", 1 / frameRate), ("t", 1 / tickRate)]
        for (suffix, factor) in units where text.hasSuffix(suffix) {
            guard !lrc, let number = Double(text.dropLast(suffix.count)), number.isFinite, number >= 0 else { return nil }
            let result = number * factor
            return result.isFinite ? result : nil
        }
        // Apple's lyric TTML writes bare decimal seconds as well as clock values.
        if !lrc, !text.contains(":"), let seconds = Double(text), seconds.isFinite, seconds >= 0 { return seconds }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (lrc ? (2 ... 3).contains(parts.count) : (2 ... 4).contains(parts.count)) else { return nil }
        // Some enhanced LRC writers use a colon before the fractional seconds.
        if lrc, parts.count == 3, parts[1].count == 2, parts[2].count <= 3,
           !parts[2].contains("."), let minutes = Double(parts[0]), let seconds = Double(parts[1]),
           let fraction = Double("0." + String(parts[2])) {
            guard minutes >= 0, seconds >= 0, seconds < 60, minutes.isFinite else { return nil }
            return minutes * 60 + seconds + fraction
        }
        var total: Double = 0
        let clockParts = parts.count == 4 ? parts.prefix(3) : parts.prefix(parts.count)
        for (index, part) in clockParts.enumerated() {
            guard let number = Double(part), number.isFinite, number >= 0,
                  index == 0 || number < 60,
                  index == clockParts.count - 1 || number.rounded(.down) == number else { return nil }
            total = total * 60 + number
        }
        if parts.count == 4 {
            let frames = parts[3].split(separator: ".", omittingEmptySubsequences: false)
            guard !frames.isEmpty, frames.count <= 2, let frame = Double(frames[0]), frame >= 0, frame < frameRate else { return nil }
            var frameCount = frame
            if frames.count == 2 {
                guard let subframe = Double(frames[1]), subframe >= 0, subframe < subFrameRate else { return nil }
                frameCount += subframe / subFrameRate
            }
            total += frameCount / frameRate
        }
        return total.isFinite ? total : nil
    }

    static func normalized(lines: [ExteraLyricsLine], provider: String, instrumental: Bool = false) -> ExteraLyricsDocument? {
        guard lines.count <= self.maximumLines else { return nil }
        let timed = lines.filter { $0.start != nil }.enumerated().sorted {
            if $0.element.start == $1.element.start { return $0.offset < $1.offset }
            return ($0.element.start ?? 0) < ($1.element.start ?? 0)
        }.map(\.element)
        var result: [ExteraLyricsLine] = []
        var wordCount = 0
        for (index, line) in timed.enumerated() {
            guard let start = line.start, start.isFinite, start >= 0 else { continue }
            let nextStart = index + 1 < timed.count ? timed[index + 1].start : nil
            let explicitEnd = line.end.flatMap { $0.isFinite && $0 >= start ? $0 : nil }
            let end: Double?
            if let explicitEnd, let nextStart, nextStart > start { end = min(explicitEnd, nextStart) }
            else { end = explicitEnd ?? (nextStart.flatMap { $0 > start ? $0 : nil }) }
            let length = (line.text as NSString).length
            let validWords = line.words.filter { word in
                return word.start.isFinite && word.start >= start && word.range.location >= 0 && word.range.length > 0 && word.range.location <= length && word.range.length <= length - word.range.location
            }.sorted { $0.start < $1.start }
            wordCount += validWords.count
            guard wordCount <= self.maximumWords else { return nil }
            let words = validWords.enumerated().map { wordIndex, word -> ExteraLyricsWord in
                let following = wordIndex + 1 < validWords.count ? validWords[wordIndex + 1].start : end
                let ownEnd = word.end.flatMap { $0.isFinite && $0 >= word.start ? $0 : nil }
                let wordEnd: Double?
                if let ownEnd, let following { wordEnd = min(ownEnd, max(word.start, following)) }
                else { wordEnd = ownEnd ?? following }
                return ExteraLyricsWord(range: word.range, start: word.start, end: wordEnd)
            }
            result.append(ExteraLyricsLine(start: start, end: end, text: line.text, words: words))
        }
        guard result.contains(where: { !$0.text.isEmpty }) || instrumental else { return nil }
        return ExteraLyricsDocument(lines: result, provider: provider, instrumental: instrumental)
    }

    private static func parseLRC(_ source: String, provider: String) -> ExteraLyricsDocument? {
        let rows = source.components(separatedBy: .newlines)
        guard rows.count <= self.maximumLines * 2 else { return nil }
        var offset: Double = 0
        for row in rows {
            let text = row.trimmingCharacters(in: .whitespaces)
            if text.lowercased().hasPrefix("[offset:"), text.hasSuffix("]"), let ms = Double(text.dropFirst(8).dropLast()), ms.isFinite {
                offset = max(-3600, min(3600, ms / 1000))
            }
        }
        var lines: [ExteraLyricsLine] = []
        let wordPattern = try! NSRegularExpression(pattern: "<([0-9]+:[0-9:.]+)>")
        for row in rows {
            var rest = row.trimmingCharacters(in: .whitespaces)
            var starts: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: rest.startIndex) ..< close])
                guard let start = self.time(tag, lrc: true) else { break }
                starts.append(start)
                rest = String(rest[rest.index(after: close)...])
            }
            guard let originalStart = starts.first else { continue }
            let rawText = rest as NSString
            let matches = wordPattern.matches(in: rest, range: NSRange(location: 0, length: rawText.length))
            var text = ""
            var words: [ExteraLyricsWord] = []
            var position = 0
            var pendingStart: Double?
            for match in matches {
                let segment = rawText.substring(with: NSRange(location: position, length: match.range.location - position))
                let location = (text as NSString).length
                text += segment
                let time = self.time(rawText.substring(with: match.range(at: 1)), lrc: true)
                if let pendingStart, !segment.isEmpty {
                    words.append(ExteraLyricsWord(range: NSRange(location: location, length: (segment as NSString).length), start: pendingStart, end: time))
                }
                pendingStart = time
                position = NSMaxRange(match.range)
            }
            let tail = rawText.substring(from: position)
            let location = (text as NSString).length
            text += tail
            if let pendingStart, !tail.isEmpty {
                words.append(ExteraLyricsWord(range: NSRange(location: location, length: (tail as NSString).length), start: pendingStart, end: nil))
            }
            // Preserve spaces in timed text: trimming would invalidate Unicode word ranges.
            for start in starts {
                let shift = start - originalStart + offset
                let shifted = words.map { word in
                    ExteraLyricsWord(range: word.range, start: max(0, word.start + shift), end: word.end.map { max(0, $0 + shift) })
                }
                let explicitEnd = !matches.isEmpty && tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? pendingStart.map { max(0, $0 + shift) } : nil
                lines.append(ExteraLyricsLine(start: max(0, start + offset), end: explicitEnd, text: text, words: shifted))
                guard lines.count <= self.maximumLines else { return nil }
            }
        }
        return self.normalized(lines: lines, provider: provider)
    }
}
