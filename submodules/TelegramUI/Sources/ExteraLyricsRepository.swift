import Foundation
import SGSimpleSettings
import SwiftSignalKit

/// Provider endpoints and response shapes follow exteraGram's LyricsRepository/LyricsSources.
/// Automatic emits an early line result and can upgrade it to actual word timing.
enum ExteraLyricsRepository {
    struct Query {
        let title: String
        let performer: String
        let duration: Double
    }

    private final class CachedDocument: NSObject {
        let document: ExteraLyricsDocument
        init(_ document: ExteraLyricsDocument) { self.document = document }
    }

    private static let cache: NSCache<NSString, CachedDocument> = {
        let cache = NSCache<NSString, CachedDocument>()
        cache.countLimit = 24
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func cleanedTitle(_ title: String) -> String {
        let original = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = original.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? original : cleaned
    }

    static func fetch(query: Query, source: ExteraPlayerSettings.LyricsSource) -> Signal<ExteraLyricsDocument?, NoError> {
        guard source != .embeddedOnly, !query.title.isEmpty else { return .single(nil) }
        // JSON avoids collisions between metadata containing separators.
        let duration = query.duration.isFinite && query.duration > 0 ? query.duration : 0
        let keyParts = [query.title, query.performer, String(duration), String(source.rawValue)]
        let key = ((try? JSONEncoder().encode(keyParts)).flatMap { String(data: $0, encoding: .utf8) } ?? "") as NSString
        if let hit = self.cache.object(forKey: key) { return .single(hit.document) }
        let providers: [ExteraPlayerSettings.LyricsSource] = source == .automatic ? [.lrclib, .lrcmux, .betterLyrics] : [source]
        return self.request(providers: providers, index: 0, query: query, best: nil)
        |> map { document in
            // An automatic request can be cancelled after its early line result.
            // Do not turn that partial result into a permanent cache hit that
            // prevents a future request from attempting the word providers.
            if let document, source != .automatic || document.hasWords || document.instrumental {
                let cost = (try? JSONEncoder().encode(document).count) ?? 0
                self.cache.setObject(CachedDocument(document), forKey: key, cost: cost)
            }
            return document
        }
    }

    private static func request(providers: [ExteraPlayerSettings.LyricsSource], index: Int, query: Query, best: ExteraLyricsDocument?) -> Signal<ExteraLyricsDocument?, NoError> {
        guard index < providers.count, best?.hasWords != true, best?.instrumental != true else { return .single(best) }
        return self.provider(providers[index], query: query)
        |> mapToSignal { candidate -> Signal<ExteraLyricsDocument?, NoError> in
            let candidate = candidate.flatMap { self.fits($0, query: query) ? $0 : nil }
            let improved = candidate.flatMap { $0.rank > (best?.rank ?? 0) ? $0 : nil }
            let next = improved ?? best
            if index + 1 == providers.count || next?.hasWords == true || next?.instrumental == true { return .single(next) }
            let remaining = self.request(providers: providers, index: index + 1, query: query, best: next)
            if let improved { return .single(improved) |> then(remaining) }
            return remaining
        }
    }

    private static func fits(_ document: ExteraLyricsDocument, query: Query) -> Bool {
        guard query.duration.isFinite, query.duration > 0, document.isTimed else { return true }
        guard let first = document.lines.first(where: { !$0.text.isEmpty })?.start,
              let last = document.lines.last?.start else { return false }
        return first < query.duration && last <= query.duration + 5
    }

    private static func normalized(_ text: String) -> String {
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ object: [String: Any], title: String, artist: String, duration: String, query: Query) -> Bool {
        guard let candidateTitle = object[title] as? String,
              self.normalized(self.cleanedTitle(candidateTitle)) == self.normalized(self.cleanedTitle(query.title)) else { return false }
        if !query.performer.isEmpty {
            guard let candidateArtist = object[artist] as? String, self.normalized(candidateArtist) == self.normalized(query.performer) else { return false }
        }
        if query.duration.isFinite, query.duration > 0, let candidateDuration = object[duration] as? Double, candidateDuration > 0 {
            return candidateDuration.isFinite && abs(candidateDuration - query.duration) <= 5
        }
        return true
    }

    private static func url(_ base: String, _ items: [URLQueryItem], query: Query, durationName: String?) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = items
        if let durationName, query.duration.isFinite, query.duration > 0, query.duration < Double(Int32.max) {
            components?.queryItems?.append(URLQueryItem(name: durationName, value: String(Int(query.duration.rounded()))))
        }
        return components?.url
    }

    private static func json(_ url: URL?) -> Signal<Any?, NoError> {
        guard let url else { return .single(nil) }
        return Signal { subscriber in
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("AyuGram-iOS (https://github.com/Nomadvorga/ayugram-ios)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                var object: Any?
                if error == nil, let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode),
                   let data, data.count <= ExteraLyricsParser.maximumBytes {
                    object = try? JSONSerialization.jsonObject(with: data)
                }
                subscriber.putNext(object)
                subscriber.putCompletion()
            }
            task.resume()
            return ActionDisposable { task.cancel() }
        }
    }

    private static func provider(_ source: ExteraPlayerSettings.LyricsSource, query: Query) -> Signal<ExteraLyricsDocument?, NoError> {
        switch source {
        case .lrclib:
            let items = [URLQueryItem(name: "track_name", value: query.title), URLQueryItem(name: "artist_name", value: query.performer)]
            let exact = self.url("https://lrclib.net/api/get", items, query: query, durationName: "duration")
            let search = self.url("https://lrclib.net/api/search", items, query: query, durationName: nil)
            return self.json(exact) |> mapToSignal { object -> Signal<ExteraLyricsDocument?, NoError> in
                if let entry = object as? [String: Any], self.matches(entry, title: "trackName", artist: "artistName", duration: "duration", query: query),
                   let document = self.lrclib(entry) { return .single(document) }
                return self.json(search) |> map { object -> ExteraLyricsDocument? in
                    guard let entries = object as? [[String: Any]] else { return nil }
                    let candidates = entries.filter { self.matches($0, title: "trackName", artist: "artistName", duration: "duration", query: query) }
                    return candidates.sorted { abs(($0["duration"] as? Double ?? query.duration) - query.duration) < abs(($1["duration"] as? Double ?? query.duration) - query.duration) }.compactMap { self.lrclib($0) }.max(by: { $0.rank < $1.rank })
                }
            }
        case .lrcmux:
            let url = self.url("https://api.lrcmux.dev/get", [URLQueryItem(name: "title", value: query.title), URLQueryItem(name: "artist", value: query.performer), URLQueryItem(name: "level", value: "word"), URLQueryItem(name: "format", value: "json")], query: query, durationName: "duration")
            return self.json(url) |> map { object -> ExteraLyricsDocument? in
                guard let object = object as? [String: Any] else { return nil }
                if let track = object["track"] as? [String: Any], !self.matches(track, title: "title", artist: "artist", duration: "duration", query: query) { return nil }
                let meta = object["meta"] as? [String: Any]
                if meta?["instrumental"] as? Bool == true { return ExteraLyricsDocument(lines: [], provider: "LrcMux", instrumental: true) }
                guard let entries = object["lines"] as? [[String: Any]], entries.count <= ExteraLyricsParser.maximumLines else { return nil }
                if meta?["level"] as? String == "none" { return ExteraLyricsParser.parse(entries.compactMap { $0["text"] as? String }.joined(separator: "\n"), provider: "LrcMux") }
                let lines = entries.compactMap { line -> ExteraLyricsLine? in
                    guard let start = self.milliseconds(line["start"]) else { return nil }
                    var text = ""
                    var words: [ExteraLyricsWord] = []
                    if let parts = line["words"] as? [[String: Any]], parts.count <= ExteraLyricsParser.maximumWords {
                        for word in parts {
                            guard let part = word["text"] as? String, let time = self.milliseconds(word["start"]) else { continue }
                            let range = NSRange(location: (text as NSString).length, length: (part as NSString).length)
                            text += part
                            words.append(ExteraLyricsWord(range: range, start: time, end: self.milliseconds(word["end"])))
                        }
                    }
                    if words.isEmpty { text = line["text"] as? String ?? "" }
                    return ExteraLyricsLine(start: start, end: self.milliseconds(line["end"]), text: text, words: words)
                }
                return ExteraLyricsParser.normalized(lines: lines, provider: "LrcMux")
            }
        case .betterLyrics:
            guard !query.performer.isEmpty else { return .single(nil) }
            let url = self.url("https://lyrics-api.boidu.dev/getLyrics", [URLQueryItem(name: "s", value: query.title), URLQueryItem(name: "a", value: query.performer)], query: query, durationName: "d")
            return self.json(url) |> map { object -> ExteraLyricsDocument? in
                guard let object = object as? [String: Any], let ttml = object["ttml"] as? String else { return nil }
                return ExteraLyricsTTMLParser.parse(ttml, provider: "Better Lyrics")
            }
        case .automatic, .embeddedOnly: return .single(nil)
        }
    }

    private static func lrclib(_ entry: [String: Any]) -> ExteraLyricsDocument? {
        if entry["instrumental"] as? Bool == true { return ExteraLyricsDocument(lines: [], provider: "LRCLIB", instrumental: true) }
        if let synced = entry["syncedLyrics"] as? String, let document = ExteraLyricsParser.parse(synced, provider: "LRCLIB"), document.isTimed { return document }
        if let plain = entry["plainLyrics"] as? String { return ExteraLyricsParser.parse(plain, provider: "LRCLIB") }
        return nil
    }

    private static func milliseconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue / 1000
        return value.isFinite && value >= 0 ? value : nil
    }
}
