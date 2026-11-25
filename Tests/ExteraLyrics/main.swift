import Foundation

// Compile with the production Foundation-only parser files; see README.md.
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(condition(), message)
}

func near(_ value: Double?, _ expected: Double) -> Bool {
    return value.map { abs($0 - expected) < 0.00001 } ?? false
}

check(near(ExteraLyricsParser.time("01:02.345", lrc: true), 62.345), "LRC fractional seconds")
check(near(ExteraLyricsParser.time("01:02:345", lrc: true), 62.345), "LRC colon fraction")
check(near(ExteraLyricsParser.time("01:02:03.500", lrc: true), 3723.5), "LRC hour clock")
check(near(ExteraLyricsParser.time("250ms"), 0.25), "TTML millisecond offset")
check(near(ExteraLyricsParser.time("1.5m"), 90), "TTML minute offset")
check(near(ExteraLyricsParser.time("33.522"), 33.522), "Apple bare decimal seconds")
check(near(ExteraLyricsParser.time("00:00:01:15", frameRate: 30), 1.5), "TTML frame clock")
check(near(ExteraLyricsParser.time("50t", tickRate: 100), 0.5), "TTML ticks")
check(ExteraLyricsParser.time("00:99", lrc: true) == nil, "Invalid seconds rejected")
check(ExteraLyricsParser.time("-01:20", lrc: true) == nil, "Negative timestamps rejected")
check(ExteraLyricsParser.time("NaNs") == nil, "Nonfinite time rejected")
check(ExteraLyricsParser.time("00:00:01:") == nil, "Malformed frame clock rejected")

let repeated = ExteraLyricsParser.parse("[00:02.00][00:12.00]<00:02.00>Hi <00:02.50>🌍<00:03.00>\n[offset:500]", provider: "test")!
check(repeated.lines.count == 2, "Repeated line timestamps retained")
check(near(repeated.lines[0].start, 2.5) && near(repeated.lines[1].start, 12.5), "Offset applies to all cues")
check(repeated.lines[0].text == "Hi 🌍", "Word markers removed")
check(repeated.lines[0].words[1].range == NSRange(location: 3, length: 2), "Emoji uses UTF-16 range")
check(near(repeated.lines[1].words[1].start, 13), "Repeated word timestamps shifted with line")
check(near(repeated.lines[1].end, 13.5), "Trailing word timestamp terminates final lyric")
check(repeated.activeLine(at: 3.6) == nil, "Explicit end clears lyric in instrumental gap")
check(repeated.activeLine(at: 1) == nil, "No highlight before first cue")

let gaps = ExteraLyricsParser.parse("[00:01]One\n[00:03]\n[00:06]Two", provider: "test")!
check(gaps.lines.count == 3, "Blank timed cues retained")
check(gaps.lines[gaps.activeLine(at: 4)!].text.isEmpty, "Blank cue ends previous lyric")
check(gaps.activeLine(at: 6) == 2, "Next lyric starts at exact boundary")

let sorted = ExteraLyricsParser.parse("[00:05]Last\n[00:01]First\n[00:01]Same", provider: "test")!
check(sorted.lines.map(\.text) == ["First", "Same", "Last"], "Stable sorting for duplicate timestamps")
check(sorted.activeLine(at: 1) == 1, "Duplicate timestamp search is deterministic")
let plain = ExteraLyricsParser.parse("First\r\n\r\nSecond", provider: "test")!
check(!plain.isTimed && plain.lines.count == 2, "CRLF plain lyrics")
check(ExteraLyricsParser.parse("[ar:Metadata]\n[00:99]Broken", provider: "test") == nil, "Malformed markup not displayed as plain text")
check(ExteraLyricsParser.parse(String(repeating: "a", count: ExteraLyricsParser.maximumBytes + 1), provider: "test") == nil, "Document byte limit")

let apple = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word"><body dur="4:26.773"><div begin="33.522" end="49.846"><p begin="33.522" end="35.789"><span begin="33.522" end="33.855">Look</span> <span begin="33.855" end="35.789">🌍 &amp; stars</span></p></div></body></tt>
"""
let appleDocument = ExteraLyricsParser.parse(apple, provider: "test")!
check(near(appleDocument.lines[0].start, 33.522), "Apple nested timestamps are song absolute")
check(near(appleDocument.lines[0].words[0].start, 33.522), "Apple word timestamp not added twice")
check(appleDocument.lines[0].text == "Look 🌍 & stars", "XML entity and emoji decoded")
check(appleDocument.lines[0].words[1].range == NSRange(location: 5, length: 10), "TTML word Unicode ranges")
check(appleDocument.activeLine(at: 36) == nil, "TTML paragraph end clears highlight")

let relative = """
<tt xmlns="http://www.w3.org/ns/ttml"><body begin="10s"><div begin="2s"><p begin="1s" dur="3s"><span begin="0s" dur="1s">Hello</span> <span begin="1s">world</span></p></div></body></tt>
"""
let relativeDocument = ExteraLyricsParser.parse(relative, provider: "test")!
check(near(relativeDocument.lines[0].start, 13), "Standard TTML uses parent relative time")
check(near(relativeDocument.lines[0].words[1].start, 14), "Nested relative word time")
check(near(relativeDocument.lines[0].end, 16), "TTML duration creates line end")

let preserve = """
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><p begin="1s" end="4s">  A <span ttm:role="x-translation">translated</span><br/>B  </p></body></tt>
"""
check(ExteraLyricsParser.parse(preserve, provider: "test")?.lines[0].text == "A \nB", "Line breaks preserved and auxiliary translation excluded")
check(ExteraLyricsParser.parse("<tt><body><p begin=\"1s\">broken", provider: "test") == nil, "Malformed XML rejected")
check(ExteraLyricsParser.parse("<!DOCTYPE tt [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><tt><body><p begin=\"1s\">&x;</p></body></tt>", provider: "test") == nil, "XML entities rejected")
let deep = "<tt><body>" + String(repeating: "<span>", count: 65) + "x" + String(repeating: "</span>", count: 65) + "</body></tt>"
check(ExteraLyricsParser.parse(deep, provider: "test") == nil, "XML depth limit")

let roundTrip = try JSONDecoder().decode(ExteraLyricsDocument.self, from: JSONEncoder().encode(appleDocument))
check(roundTrip == appleDocument, "Document Codable retains timings and Unicode ranges")
print("Passed \(checks) production lyrics parser checks")
