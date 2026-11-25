# Production lyrics parser checks

These checks compile the actual Foundation-only production parser. No Telegram
application bundle, network access, UIKit or copied parser implementation is needed.
From the repository root on a Swift host:

```sh
swiftc submodules/TelegramUI/Sources/ExteraLyricsParser.swift \
  submodules/TelegramUI/Sources/ExteraLyricsTTMLParser.swift \
  Tests/ExteraLyrics/main.swift -o /tmp/extera-lyrics-tests
/tmp/extera-lyrics-tests
```

The fixtures cover enhanced/repeated/offset LRC, blank cues, explicit gaps,
Unicode UTF-16 word ranges, stable duplicate sorting, malformed/oversized input,
Apple song-absolute TTML (a response shape verified against Better Lyrics),
standard relative TTML, frame/tick clocks, XML entities/depth and Codable round trips.

This Windows checkout has no Swift compiler. Tree-sitter parsing is feasible here;
the executable checks above have **not** been run here. AVFoundation embedded tags,
Ogg/FLAC metadata, cancellation and player settings need separate iOS integration
checks. Record playback/seek/manual-scroll and display-mode transitions per the
root AGENTS.md before claiming visual acceptance.
