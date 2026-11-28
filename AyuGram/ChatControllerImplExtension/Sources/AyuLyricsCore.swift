// Ported from exteraGram for Android (com.exteragram.messenger.player: TrackQuery, lyrics.Lyrics,
// lyrics.LyricsRepository's LRCLIB requests and lyrics.LyricsSources' matching), GPL v3 or later, © exteraGram.

import Foundation

// What a track is looked up by.
struct AyuTrackQuery: Equatable {
    let artist: String?
    let title: String
    let album: String?
    // In seconds; 0 when unknown.
    let duration: Int

    private static let audioExtension = try! NSRegularExpression(pattern: "\\.(mp3|m4a|flac|ogg|oga|opus|wav|aac|alac|wma)$", options: [.caseInsensitive])
    private static let topicChannel = try! NSRegularExpression(pattern: "\\s+-\\s+Topic$", options: [.caseInsensitive])
    private static let decoration = try! NSRegularExpression(pattern: "\\s*[(\\[][^)\\]]*(official|lyric|video|audio|visualizer|remaster|hq|hd)[^)\\]]*[)\\]]", options: [.caseInsensitive])
    private static let brackets = try! NSRegularExpression(pattern: "\\s*[(\\[（【][^)\\]）】]*[)\\]）】]")

    private static func replacing(_ expression: NSRegularExpression, in string: String, firstOnly: Bool = false) -> String {
        let range = NSRange(string.startIndex..., in: string)
        if firstOnly, let match = expression.firstMatch(in: string, range: range), let matchRange = Range(match.range, in: string) {
            return string.replacingCharacters(in: matchRange, with: "")
        } else if firstOnly {
            return string
        }
        return expression.stringByReplacingMatches(in: string, range: range, withTemplate: "")
    }

    private static func clean(_ string: String?) -> String? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }
        return string
    }

    // The query for a music file's performer, title (or file name) and duration; nil without a title.
    init?(performer: String?, title: String?, album: String? = nil, duration: Double) {
        var artist = AyuTrackQuery.clean(performer)
        var title = AyuTrackQuery.clean(title)
        if let current = title {
            title = AyuTrackQuery.replacing(AyuTrackQuery.audioExtension, in: current, firstOnly: true).replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        }
        if artist == nil, let current = title, let dash = current.range(of: " - "), dash.lowerBound > current.startIndex {
            artist = AyuTrackQuery.clean(String(current[..<dash.lowerBound]))
            title = String(current[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let current = title {
            let stripped = AyuTrackQuery.replacing(AyuTrackQuery.decoration, in: current).trimmingCharacters(in: .whitespaces)
            title = stripped.isEmpty ? current : stripped
        }
        if let current = artist {
            let stripped = AyuTrackQuery.replacing(AyuTrackQuery.topicChannel, in: current, firstOnly: true).trimmingCharacters(in: .whitespaces)
            artist = stripped.isEmpty ? current : stripped
        }
        guard let title, !title.isEmpty else {
            return nil
        }
        self.artist = artist
        self.title = title
        self.album = AyuTrackQuery.clean(album)
        self.duration = duration.isFinite && duration > 0.0 ? Int(duration.rounded()) : 0
    }

    var key: String {
        return (self.artist ?? "").lowercased() + "\u{1}" + self.title.lowercased() + "\u{1}\(self.duration)"
    }

    // Letters and digits only, in lower case.
    static func normalize(_ string: String?) -> String {
        return String(String.UnicodeScalarView((string ?? "").lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }))
    }

    static func stripBrackets(_ string: String) -> String {
        return replacing(brackets, in: string)
    }

    static func titleMatches(_ query: String, _ candidate: String) -> Bool {
        var a = normalize(stripBrackets(query))
        if a.isEmpty {
            a = normalize(query)
        }
        var b = normalize(stripBrackets(candidate))
        if b.isEmpty {
            b = normalize(candidate)
        }
        if a.isEmpty || b.isEmpty {
            return false
        }
        if a == b {
            return true
        }
        return min(a.count, b.count) >= 4 && (a.hasPrefix(b) || b.hasPrefix(a))
    }

    static func artistMatches(_ query: String?, _ artists: [String]) -> Bool {
        let a = normalize(query)
        if a.isEmpty {
            return true
        }
        for artist in artists {
            let b = normalize(artist)
            if !b.isEmpty && (a.contains(b) || b.contains(a)) {
                return true
            }
        }
        return false
    }

    // Whether a search result may be this track at all.
    func isPlausible(title: String, artist: String, duration: Int) -> Bool {
        if self.duration > 0 && duration > 0 && abs(duration - self.duration) > AyuLyrics.maxDurationDifference {
            return false
        }
        if title.isEmpty {
            return true
        }
        return AyuTrackQuery.titleMatches(self.title, title) || (!artist.isEmpty && !(self.artist ?? "").isEmpty && AyuTrackQuery.artistMatches(self.artist, [artist]))
    }
}

struct AyuLyrics: Equatable {
    struct Line: Equatable {
        // In milliseconds from the start; -1 for a line without a time.
        let time: Int
        let text: String

        var isBlank: Bool {
            return self.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    static let maxDurationDifference = 5

    let lines: [Line]
    let isSynced: Bool
    let isInstrumental: Bool
    let provider: String

    static func instrumental(provider: String) -> AyuLyrics {
        return AyuLyrics(lines: [], isSynced: false, isInstrumental: true, provider: provider)
    }

    private static let time = try! NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]")
    private static let wordTime = try! NSRegularExpression(pattern: "<(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?>")
    private static let offset = try! NSRegularExpression(pattern: "^\\[offset:\\s*([+-]?\\d+)\\s*\\]", options: [.caseInsensitive])
    private static let meta = try! NSRegularExpression(pattern: "^\\[[a-zA-Z#]+:.*\\]$")

    private static func milliseconds(_ match: NSTextCheckingResult, in line: NSString) -> Int {
        var result = (Int(line.substring(with: match.range(at: 1))) ?? 0) * 60000 + (Int(line.substring(with: match.range(at: 2))) ?? 0) * 1000
        if match.range(at: 3).location != NSNotFound {
            let fraction = line.substring(with: match.range(at: 3))
            let value = Int(fraction) ?? 0
            result += fraction.count == 1 ? value * 100 : (fraction.count == 2 ? value * 10 : value)
        }
        return result
    }

    // Lyrics from LRC text ("[01:02.34]line", several times before one line, "[offset:±ms]", word times
    // "<01:02.50>" dropped), or from plain text when no line has a time.
    static func parse(_ text: String?, provider: String) -> AyuLyrics? {
        guard let text, !text.isEmpty else {
            return nil
        }
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var offsetValue = 0
        var timed: [Line] = []
        for row in rows {
            let line = row.trimmingCharacters(in: .whitespaces) as NSString
            let whole = NSRange(location: 0, length: line.length)
            if let match = offset.firstMatch(in: line as String, range: whole) {
                offsetValue = Int(line.substring(with: match.range(at: 1)).replacingOccurrences(of: "+", with: "")) ?? offsetValue
                continue
            }
            var times: [Int] = []
            var end = 0
            for match in time.matches(in: line as String, range: whole) {
                guard match.range.location == end else {
                    break
                }
                times.append(milliseconds(match, in: line))
                end = match.range.location + match.range.length
            }
            if times.isEmpty {
                continue
            }
            let rest = line.substring(from: end)
            let content = wordTime.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: (rest as NSString).length), withTemplate: "").trimmingCharacters(in: .whitespaces)
            for value in times {
                timed.append(Line(time: max(0, value - offsetValue), text: content))
            }
        }
        if !timed.isEmpty {
            return fromTimedLines(timed, provider: provider)
        }

        var plain: [Line] = []
        for row in rows {
            let line = row.trimmingCharacters(in: .whitespaces)
            if meta.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                continue
            }
            if line.isEmpty && (plain.isEmpty || plain[plain.count - 1].isBlank) {
                continue
            }
            plain.append(Line(time: -1, text: line))
        }
        while let last = plain.last, last.isBlank {
            plain.removeLast()
        }
        return plain.isEmpty ? nil : AyuLyrics(lines: plain, isSynced: false, isInstrumental: false, provider: provider)
    }

    // In time order, without blank lines at the start, at the end or after another blank line.
    static func fromTimedLines(_ timed: [Line], provider: String) -> AyuLyrics? {
        let sorted = timed.enumerated().sorted { $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset }.map { $0.element }
        var kept: [Line] = []
        for (index, line) in sorted.enumerated() {
            if line.isBlank && (kept.isEmpty || kept[kept.count - 1].isBlank || index == sorted.count - 1) {
                continue
            }
            kept.append(line)
        }
        while let last = kept.last, last.isBlank {
            kept.removeLast()
        }
        return kept.isEmpty ? nil : AyuLyrics(lines: kept, isSynced: true, isInstrumental: false, provider: provider)
    }

    // The line sung at a position in milliseconds; nil before the first one and for lyrics without times.
    func lineIndex(at position: Int) -> Int? {
        guard self.isSynced else {
            return nil
        }
        var low = 0
        var high = self.lines.count - 1
        var result: Int?
        while low <= high {
            let middle = (low + high) / 2
            if self.lines[middle].time <= position {
                result = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return result
    }
}

// The LRCLIB service (https://lrclib.net): a direct lookup by artist, title, album and duration, then a search.
enum AyuLrclib {
    static let name = "LRCLIB"

    private static func url(_ path: String, _ items: [(String, String?)]) -> URL? {
        var components = URLComponents(string: "https://lrclib.net/api/" + path)
        components?.queryItems = items.compactMap { name, value in
            return value.flatMap { $0.isEmpty ? nil : URLQueryItem(name: name, value: $0) }
        }
        // "+" in a query stands for a space on the server's side.
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        return components?.url
    }

    // Nil without an artist: the service needs one for a direct lookup.
    static func getRequest(_ query: AyuTrackQuery) -> URLRequest? {
        guard let artist = query.artist, !artist.isEmpty else {
            return nil
        }
        return url("get", [("artist_name", artist), ("track_name", query.title), ("album_name", query.album), ("duration", query.duration > 0 ? "\(query.duration)" : nil)]).map { URLRequest(url: $0, timeoutInterval: 15.0) }
    }

    static func searchRequest(_ query: AyuTrackQuery) -> URLRequest? {
        return url("search", [("track_name", query.title), ("artist_name", query.artist)]).map { URLRequest(url: $0, timeoutInterval: 15.0) }
    }

    private static func string(_ object: [String: Any], _ name: String) -> String? {
        guard let value = object[name] as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    // Lyrics of one record: timed when it has them, else plain.
    static func lyrics(record: [String: Any]) -> AyuLyrics? {
        if (record["instrumental"] as? Bool) == true {
            return .instrumental(provider: name)
        }
        let synced = AyuLyrics.parse(string(record, "syncedLyrics"), provider: name)
        if let synced, synced.isSynced {
            return synced
        }
        return AyuLyrics.parse(string(record, "plainLyrics"), provider: name) ?? synced
    }

    static func lyrics(getResponse data: Data) -> AyuLyrics? {
        guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return lyrics(record: record)
    }

    // The best of the search results that may be the track: timed lyrics first, then the closest duration.
    static func lyrics(searchResponse data: Data, query: AyuTrackQuery) -> AyuLyrics? {
        guard let records = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return nil
        }
        var best: AyuLyrics?
        var bestScore = Int.min
        for item in records {
            guard let record = item as? [String: Any] else {
                continue
            }
            let duration = (record["duration"] as? NSNumber).map { Int($0.doubleValue.rounded()) }
            guard query.isPlausible(title: (record["trackName"] as? String) ?? "", artist: (record["artistName"] as? String) ?? "", duration: duration ?? 0), let found = lyrics(record: record) else {
                continue
            }
            var score = found.isSynced ? 40 : 0
            if query.duration > 0, let duration {
                let difference = abs(duration - query.duration)
                score -= difference <= AyuLyrics.maxDurationDifference ? difference : 20 + min(difference, 60)
            }
            if score > bestScore {
                bestScore = score
                best = found
            }
        }
        return best
    }
}
