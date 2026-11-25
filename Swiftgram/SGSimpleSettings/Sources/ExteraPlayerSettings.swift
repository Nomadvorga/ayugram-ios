import Foundation

/// Native lyrics preferences. Provider identifiers are persisted and must stay stable.
public final class ExteraPlayerSettings: @unchecked Sendable {
    public enum LyricsSource: Int, CaseIterable {
        case automatic = 0
        case lrclib = 1
        case lrcmux = 2
        case betterLyrics = 3
        case embeddedOnly = 4
    }

    public enum LyricsDisplayMode: Int, CaseIterable {
        case lines = 0
        case words = 1
        case plain = 2
        case subtitles = 3
    }

    public static let shared = ExteraPlayerSettings()
    private let store = AyuSettingsStore.shared

    private init() {
        self.store.register(defaults: [
            "extera.player.lyricsSource": LyricsSource.automatic.rawValue,
            "extera.player.lyricsDisplayMode": LyricsDisplayMode.lines.rawValue,
            "extera.player.preferEmbeddedLyrics": true,
            "extera.player.lyricsAutoScroll": true,
            "extera.player.lyricsTapToSeek": true,
            "extera.player.lyricsOffsetMilliseconds": 0
        ])
    }

    /// Automatic tries LRCLIB, LrcMux and Better Lyrics, keeping the best timing available.
    /// Embedded-only never sends track metadata to an online provider.
    public var lyricsSource: LyricsSource {
        get { return LyricsSource(rawValue: self.store.int("extera.player.lyricsSource")) ?? .automatic }
        set { self.store.setInt(newValue.rawValue, "extera.player.lyricsSource") }
    }

    /// Words highlights actual provider word timings; untimed songs remain readable in every mode.
    public var lyricsDisplayMode: LyricsDisplayMode {
        get { return LyricsDisplayMode(rawValue: self.store.int("extera.player.lyricsDisplayMode")) ?? .lines }
        set { self.store.setInt(newValue.rawValue, "extera.player.lyricsDisplayMode") }
    }

    public var preferEmbeddedLyrics: Bool {
        get { return self.store.bool("extera.player.preferEmbeddedLyrics") }
        set { self.store.setBool(newValue, "extera.player.preferEmbeddedLyrics") }
    }

    public var lyricsAutoScroll: Bool {
        get { return self.store.bool("extera.player.lyricsAutoScroll") }
        set { self.store.setBool(newValue, "extera.player.lyricsAutoScroll") }
    }

    public var lyricsTapToSeek: Bool {
        get { return self.store.bool("extera.player.lyricsTapToSeek") }
        set { self.store.setBool(newValue, "extera.player.lyricsTapToSeek") }
    }

    /// Positive values display lyrics later. Tapping a line seeks to its adjusted start.
    public var lyricsOffsetMilliseconds: Int {
        get { return min(10000, max(-10000, self.store.int("extera.player.lyricsOffsetMilliseconds"))) }
        set { self.store.setInt(min(10000, max(-10000, newValue)), "extera.player.lyricsOffsetMilliseconds") }
    }
}
