// Host check of the lyrics core. Run from the repository root:
// swiftc -warnings-as-errors -o /tmp/ayu-lyrics-tests AyuGram/ChatControllerImplExtension/Sources/AyuLyricsCore.swift AyuGram/ChatControllerImplExtension/Tests/lyrics.swift && /tmp/ayu-lyrics-tests [live]

import Foundation

@main
struct LyricsTests {
    static var passed = 0
    static var failed = 0
    static func check(_ label: String, _ expected: String, _ actual: String) {
        if expected == actual {
            passed += 1
        } else {
            failed += 1
            print("FAILED \(label): expected \(expected), got \(actual)")
        }
    }
    static func describe(_ query: AyuTrackQuery?) -> String {
        guard let query else {
            return "nil"
        }
        return "\(query.artist ?? "-")|\(query.title)|\(query.duration)"
    }
    static func describe(_ lyrics: AyuLyrics?) -> String {
        guard let lyrics else {
            return "nil"
        }
        if lyrics.isInstrumental {
            return "instrumental"
        }
        return (lyrics.isSynced ? "synced " : "plain ") + lyrics.lines.map { $0.time >= 0 ? "\($0.time):\($0.text)" : $0.text }.joined(separator: "/")
    }

    static func main() {
        check("performer and title", "Queen|Bohemian Rhapsody|355", describe(AyuTrackQuery(performer: " Queen ", title: "Bohemian Rhapsody (Official Video)", duration: 354.6)))
        check("file name", "Daft Punk|Get Lucky|0", describe(AyuTrackQuery(performer: nil, title: "Daft_Punk - Get_Lucky.mp3", duration: 0)))
        check("topic channel, remaster note", "Nirvana|Lithium|257", describe(AyuTrackQuery(performer: "Nirvana - Topic", title: "Lithium [2011 Remaster]", duration: 257)))
        check("a title of nothing but a note is kept", "-|(Official Audio)|10", describe(AyuTrackQuery(performer: nil, title: "(Official Audio)", duration: 10)))
        check("no title", "nil nil", "\(describe(AyuTrackQuery(performer: "X", title: nil, duration: 1))) \(describe(AyuTrackQuery(performer: "X", title: "  ", duration: 1)))")
        check("normalize", "группакровиviktortsoi4", AyuTrackQuery.normalize("Группа крови — Viktor Tsoi #4!"))
        check("title match", "true true true false false", "\(AyuTrackQuery.titleMatches("Hello (Live)", "hello")) \(AyuTrackQuery.titleMatches("Starlight", "Starlight - Radio Edit")) \(AyuTrackQuery.titleMatches("Song 2", "SONG 2")) \(AyuTrackQuery.titleMatches("Go", "Gone")) \(AyuTrackQuery.titleMatches("", "x"))")
        check("artist match", "true true true false", "\(AyuTrackQuery.artistMatches(nil, [])) \(AyuTrackQuery.artistMatches("Jay-Z & Kanye West", ["Kanye West"])) \(AyuTrackQuery.artistMatches("Muse", ["MUSE"])) \(AyuTrackQuery.artistMatches("Muse", ["Blur"]))")

        check("timed lines in order, offset applied", "synced 1500:first/12340:second/62000:third", describe(AyuLyrics.parse("[ti:Song]\n[offset:+500]\n[01:02.5]third\n[00:12.84] second \r\n[00:02.00]first\n", provider: "x")))
        check("several times before one line, word times dropped", "synced 1000:la <3/5000:word by word/9000:la <3", describe(AyuLyrics.parse("[00:01.00][00:09.00]la <3\n[00:05.000]word <00:05.50>by <00:06.00>word", provider: "x")))
        check("blank timed lines: none first, last or doubled", "synced 2000:a/3000:/5000:b", describe(AyuLyrics.parse("[00:01.00]\n[00:02.00]a\n[00:03.00]\n[00:04.00]\n[00:05.00]b\n[00:06.00]", provider: "x")))
        check("three digit fraction and colon", "synced 3070:y/61234:x", describe(AyuLyrics.parse("[01:01.234]x\n[00:03:07]y", provider: "x")))
        check("plain text", "plain one//two", describe(AyuLyrics.parse("[ar:Artist]\n\none\n\n\ntwo\n\n", provider: "x")))
        check("nothing", "nil nil nil", "\(describe(AyuLyrics.parse(nil, provider: "x"))) \(describe(AyuLyrics.parse("", provider: "x"))) \(describe(AyuLyrics.parse("[ti:only tags]", provider: "x")))")
        let synced = AyuLyrics.parse("[00:10.00]a\n[00:20.00]b\n[00:30.00]c", provider: "x")!
        check("current line", "nil 0 0 1 2 2", [9999, 10000, 19999, 20000, 30000, 999999].map { synced.lineIndex(at: $0).map { "\($0)" } ?? "nil" }.joined(separator: " "))

        let query = AyuTrackQuery(performer: "Daft Punk", title: "Get Lucky + More", album: "RAM", duration: 369)!
        check("direct lookup", "https://lrclib.net/api/get?artist_name=Daft%20Punk&track_name=Get%20Lucky%20%2B%20More&album_name=RAM&duration=369", AyuLrclib.getRequest(query)?.url?.absoluteString ?? "nil")
        check("search, and no direct lookup without an artist", "https://lrclib.net/api/search?track_name=Song nil", "\(AyuLrclib.searchRequest(AyuTrackQuery(performer: nil, title: "Song", duration: 0)!)?.url?.absoluteString ?? "nil") \(AyuLrclib.getRequest(AyuTrackQuery(performer: nil, title: "Song", duration: 0)!)?.url?.absoluteString ?? "nil")")
        check("record", "synced 1000:a | plain b | instrumental | nil", [#"{"syncedLyrics":"[00:01.00]a","plainLyrics":"a"}"#, #"{"syncedLyrics":null,"plainLyrics":"b"}"#, #"{"instrumental":true}"#, #"{"code":404,"name":"TrackNotFound"}"#].map { describe(AyuLrclib.lyrics(getResponse: Data($0.utf8))) }.joined(separator: " | "))
        let search = #"""
        [{"trackName":"Get Lucky","artistName":"Daft Punk","duration":248,"plainLyrics":"radio edit"},
         {"trackName":"Get Lucky","artistName":"Daft Punk","duration":371.4,"plainLyrics":"album plain"},
         {"trackName":"Get Lucky","artistName":"Daft Punk","duration":367,"syncedLyrics":"[00:01.00]album synced"},
         {"trackName":"Another Song","artistName":"Somebody","duration":369,"syncedLyrics":"[00:01.00]wrong"}]
        """#
        check("search picks timed lyrics of the right length", "synced 1000:album synced", describe(AyuLrclib.lyrics(searchResponse: Data(search.utf8), query: AyuTrackQuery(performer: "Daft Punk", title: "Get Lucky", duration: 369)!)))
        check("search without a duration takes timed lyrics", "synced 1000:album synced", describe(AyuLrclib.lyrics(searchResponse: Data(search.utf8), query: AyuTrackQuery(performer: "Daft Punk", title: "Get Lucky", duration: 0)!)))
        check("search with nothing plausible", "nil nil", "\(describe(AyuLrclib.lyrics(searchResponse: Data(search.utf8), query: AyuTrackQuery(performer: "Blur", title: "Song 2", duration: 120)!))) \(describe(AyuLrclib.lyrics(searchResponse: Data("{}".utf8), query: query)))")

        if CommandLine.arguments.contains("live"), let request = AyuLrclib.getRequest(AyuTrackQuery(performer: "Queen", title: "Bohemian Rhapsody", duration: 355)!) {
            let semaphore = DispatchSemaphore(value: 0)
            URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
                let lyrics = data.flatMap { AyuLrclib.lyrics(getResponse: $0) }
                print("live: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0), \(lyrics.map { "\($0.isSynced ? "synced" : "plain"), \($0.lines.count) lines, first: \($0.lines.first?.text ?? "")" } ?? "no lyrics (\(error?.localizedDescription ?? "none found"))")")
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 20.0)
        }

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
