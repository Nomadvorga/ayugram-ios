import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import UniversalMediaPlayer
import TelegramPresentationData
import SGStrings
import SGSimpleSettings

final class OverlayAudioPlayerLyricsNode: ASDisplayNode {
    private final class LyricLine {
        let timestamp: Double?
        let text: String
        let words: [ExteraLyricsWord]
        var textNode: TextNode?
        var size: CGSize = .zero

        init(_ line: ExteraLyricsLine) {
            self.timestamp = line.start
            self.text = line.text
            self.words = line.words
        }
    }

    private struct Configuration: Equatable {
        let source: ExteraPlayerSettings.LyricsSource
        let mode: ExteraPlayerSettings.LyricsDisplayMode
        let preferEmbedded: Bool
        let autoScroll: Bool
        let tapToSeek: Bool
        let offset: Int

        static func current() -> Configuration {
            let settings = ExteraPlayerSettings.shared
            return Configuration(source: settings.lyricsSource, mode: settings.lyricsDisplayMode, preferEmbedded: settings.preferEmbeddedLyrics, autoScroll: settings.lyricsAutoScroll, tapToSeek: settings.lyricsTapToSeek, offset: settings.lyricsOffsetMilliseconds)
        }
    }

    private struct Track {
        let id: String?
        let query: ExteraLyricsRepository.Query
        let cachedFilePath: String?
        let embeddedLyrics: String?
    }

    private var presentationTheme: PresentationTheme
    private var presentationStrings: PresentationStrings
    private let scrollNode: ASScrollNode
    private let contentNode: ASDisplayNode
    private var emptyTextNode: TextNode?
    private var lines: [LyricLine] = []
    private var currentLineIndex: Int?
    private var currentTrackKey: String?
    private var validSize: CGSize = .zero
    private let fetchDisposable = MetaDisposable()
    private let embeddedDisposable = MetaDisposable()
    private var playbackStatus: MediaPlayerStatus?
    private var playbackTimer: SwiftSignalKit.Timer?
    private var displayed = false
    private var configuration = Configuration.current()
    private var track: Track?
    private var document: ExteraLyricsDocument?
    private var requestGeneration = 0
    private var settingsObserver: NSObjectProtocol?
    private var currentWordIndex: Int?
    private var playbackTime: Double = 0
    private var loading = false

    var requestSeek: ((Double) -> Void)?

    init(presentationData: PresentationData) {
        self.presentationTheme = presentationData.theme
        self.presentationStrings = presentationData.strings

        self.scrollNode = ASScrollNode()
        self.contentNode = ASDisplayNode()

        super.init()

        self.scrollNode.view.showsVerticalScrollIndicator = false
        self.scrollNode.view.showsHorizontalScrollIndicator = false
        self.scrollNode.view.alwaysBounceVertical = true
        self.scrollNode.view.delaysContentTouches = false
        self.addSubnode(self.scrollNode)
        self.scrollNode.addSubnode(self.contentNode)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:)))
        self.scrollNode.view.addGestureRecognizer(tapGesture)
        self.settingsObserver = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshConfiguration()
        }
    }

    deinit {
        self.fetchDisposable.dispose()
        self.embeddedDisposable.dispose()
        self.playbackTimer?.invalidate()
        if let settingsObserver = self.settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    func updateTheme(_ presentationData: PresentationData) {
        self.presentationTheme = presentationData.theme
        self.presentationStrings = presentationData.strings
        for index in self.lines.indices {
            self.applyAttributes(index: index, highlighted: index == self.currentLineIndex)
        }
        if self.lines.isEmpty && self.validSize.width > 0.0 {
            self.layoutLines()
        }
    }

    /// Pass a stable media/resource identity and the complete cached local audio path when
    /// available. The optional arguments preserve existing callers and never fetch media.
    func setTrack(title: String?, performer: String?, duration: Double = 0.0, trackId: String? = nil, cachedFilePath: String? = nil, embeddedLyrics: String? = nil) {
        let cleanedTitle = ExteraLyricsRepository.cleanedTitle(title ?? "")
        let cleanedPerformer = (performer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = duration.isFinite && duration > 0.0 && duration < Double(Int32.max) ? duration : 0
        let durationKey = Int(duration.rounded())
        let keyParts = [title ?? "", cleanedPerformer, String(durationKey), trackId ?? "", cachedFilePath ?? "", embeddedLyrics ?? ""]
        let key = (try? JSONEncoder().encode(keyParts)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        guard key != self.currentTrackKey else {
            return
        }
        self.currentTrackKey = key
        self.playbackStatus = nil
        self.track = cleanedTitle.isEmpty && cachedFilePath == nil && embeddedLyrics == nil ? nil : Track(id: trackId, query: ExteraLyricsRepository.Query(title: cleanedTitle, performer: cleanedPerformer, duration: duration), cachedFilePath: cachedFilePath, embeddedLyrics: embeddedLyrics)
        self.reloadLyrics()
    }

    /// A resource can finish caching after playback begins. Preserve the live playback
    /// clock while retrying embedded tags, and reject completion for an old resource.
    func updateCachedFilePath(_ path: String, trackId: String) {
        guard let track = self.track, track.id == trackId, track.cachedFilePath != path else { return }
        self.track = Track(id: track.id, query: track.query, cachedFilePath: path, embeddedLyrics: track.embeddedLyrics)
        let generation = self.requestGeneration
        self.embeddedDisposable.set((ExteraLyricsEmbedded.read(cachedFilePath: path) |> deliverOnMainQueue).start(next: { [weak self] document in
            guard let self, self.requestGeneration == generation, self.track?.id == trackId else { return }
            if let document, self.configuration.preferEmbedded || self.configuration.source == .embeddedOnly {
                // Keep visible online lyrics until local metadata is actually usable.
                self.fetchDisposable.set(nil)
                self.loading = false
                self.applyLyrics(document)
            } else if let document, self.document == nil {
                self.loading = false
                self.applyLyrics(document)
            } else if self.configuration.source == .embeddedOnly {
                self.loading = false
                self.layoutLines()
            }
        }))
    }

    private func refreshConfiguration() {
        let updated = Configuration.current()
        guard updated != self.configuration else { return }
        let refetch = updated.source != self.configuration.source || updated.preferEmbedded != self.configuration.preferEmbedded
        let modeChanged = updated.mode != self.configuration.mode
        self.configuration = updated
        if refetch { self.reloadLyrics() }
        else {
            self.currentWordIndex = nil
            if modeChanged { self.scrollNode.view.setContentOffset(.zero, animated: false) }
            self.layoutLines()
            self.updatePlaybackTimer()
            self.updatePlaybackPosition()
        }
    }

    private func reloadLyrics() {
        self.requestGeneration += 1
        let generation = self.requestGeneration
        let key = self.currentTrackKey
        self.fetchDisposable.set(nil)
        self.embeddedDisposable.set(nil)
        self.loading = self.track != nil
        self.applyLyrics(nil, force: true)
        self.scrollNode.view.setContentOffset(.zero, animated: false)
        guard let track = self.track else { return }
        let embedded: Signal<ExteraLyricsDocument?, NoError>
        if let text = track.embeddedLyrics, let document = ExteraLyricsParser.parse(text, provider: "Embedded") {
            embedded = .single(document)
        } else if let path = track.cachedFilePath { embedded = ExteraLyricsEmbedded.read(cachedFilePath: path) }
        else { embedded = .single(nil) }
        let configuration = self.configuration
        let signal = embedded |> mapToSignal { embedded -> Signal<ExteraLyricsDocument?, NoError> in
            if configuration.source == .embeddedOnly || (configuration.preferEmbedded && embedded != nil) { return .single(embedded) }
            return ExteraLyricsRepository.fetch(query: track.query, source: configuration.source) |> map { $0 ?? embedded }
        }
        self.fetchDisposable.set((signal |> deliverOnMainQueue).start(next: { [weak self] document in
            guard let self, self.requestGeneration == generation, self.currentTrackKey == key else { return }
            self.loading = false
            if let document { self.applyLyrics(document) }
            else if self.document == nil { self.applyLyrics(nil) }
        }))
    }

    func updateStatus(_ status: MediaPlayerStatus?) {
        self.playbackStatus = status
        self.updatePlaybackTimer()
        self.updatePlaybackPosition()
    }

    func setDisplayed(_ value: Bool) {
        guard self.displayed != value else { return }
        self.displayed = value
        if value { self.refreshConfiguration() }
        self.updatePlaybackTimer()
        if value { self.updatePlaybackPosition() }
    }

    private func updatePlaybackTimer() {
        let playing: Bool
        if let status = self.playbackStatus, case .playing = status.status {
            playing = true
        } else {
            playing = false
        }
        if self.displayed && playing && self.configuration.mode != .plain && self.document?.isTimed == true {
            if self.playbackTimer == nil {
                let timer = SwiftSignalKit.Timer(timeout: 0.1, repeat: true, completion: { [weak self] in
                    self?.updatePlaybackPosition()
                }, queue: .mainQueue())
                self.playbackTimer = timer
                timer.start()
            }
        } else {
            self.playbackTimer?.invalidate()
            self.playbackTimer = nil
        }
    }

    private func updatePlaybackPosition() {
        guard self.displayed, let status = self.playbackStatus else {
            return
        }
        var timestamp = status.timestamp
        if case .playing = status.status, status.generationTimestamp.isFinite, status.generationTimestamp > 0.0, status.baseRate.isFinite {
            timestamp += max(0.0, CACurrentMediaTime() - status.generationTimestamp) * status.baseRate
        }
        if status.duration > 0.0 { timestamp = min(timestamp, status.duration) }
        timestamp -= Double(self.configuration.offset) / 1000
        guard timestamp.isFinite else { return }
        self.playbackTime = timestamp
        let activeIndex = self.configuration.mode == .plain ? nil : self.document?.activeLine(at: timestamp)
        let previousWordIndex = self.currentWordIndex
        self.currentWordIndex = activeIndex.flatMap { index in
            self.lines[index].words.lastIndex(where: { $0.start <= timestamp && timestamp < ($0.end ?? .greatestFiniteMagnitude) })
        }
        if activeIndex != self.currentLineIndex {
            let previousIndex = self.currentLineIndex
            self.currentLineIndex = activeIndex
            if let previousIndex {
                self.applyAttributes(index: previousIndex, highlighted: false)
            }
            if let activeIndex {
                self.applyAttributes(index: activeIndex, highlighted: true)
            }
            if self.configuration.mode == .subtitles { self.layoutLines() }
        } else if self.configuration.mode == .words, previousWordIndex != self.currentWordIndex, let activeIndex {
            self.applyAttributes(index: activeIndex, highlighted: true, scroll: false)
        }
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.validSize = size
        transition.updateFrame(node: self.scrollNode, frame: CGRect(origin: CGPoint(), size: size))
        self.layoutLines()
    }

    private func applyLyrics(_ document: ExteraLyricsDocument?, force: Bool = false) {
        if !force, self.document == document {
            if self.lines.isEmpty { self.layoutLines() }
            return
        }
        self.document = document
        self.currentLineIndex = nil
        self.currentWordIndex = nil
        for line in self.lines {
            line.textNode?.removeFromSupernode()
        }
        self.lines = (document?.lines ?? []).map(LyricLine.init)
        self.updatePlaybackTimer()

        if self.validSize.width > 0.0 {
            self.layoutLines()
        }
        self.updatePlaybackPosition()
    }

    private func attributedString(for line: LyricLine, highlighted: Bool) -> NSAttributedString {
        let subtitle = self.configuration.mode == .subtitles && self.document?.isTimed == true
        // Keep font metrics fixed between ticks, so highlighting cannot change wrapping.
        let result = NSMutableAttributedString(attributedString: NSAttributedString(string: line.text, font: subtitle ? Font.semibold(20.0) : Font.regular(15.0), textColor: highlighted ? self.presentationTheme.list.itemPrimaryTextColor : self.presentationTheme.list.itemSecondaryTextColor, paragraphAlignment: subtitle ? .center : .natural))
        if highlighted, self.configuration.mode == .words, !line.words.isEmpty {
            result.addAttribute(.foregroundColor, value: self.presentationTheme.list.itemSecondaryTextColor, range: NSRange(location: 0, length: result.length))
            for word in line.words where word.start <= self.playbackTime {
                result.addAttribute(.foregroundColor, value: self.presentationTheme.list.itemPrimaryTextColor, range: word.range)
            }
        }
        return result
    }

    private func layoutLines() {
        let size = self.validSize
        guard size.width > 0.0, size.height > 0.0 else {
            return
        }

        if self.lines.isEmpty {
            let key = self.loading ? "Player.Lyrics.Loading" : (self.document?.instrumental == true ? "Player.Lyrics.Instrumental" : "Player.Lyrics.NotFound")
            let noLyricsString = i18n(key, self.presentationStrings.baseLanguageCode)
            let attributedString = NSAttributedString(string: noLyricsString, font: Font.regular(15.0), textColor: self.presentationTheme.list.itemSecondaryTextColor, paragraphAlignment: .center)
            let textNode: TextNode
            if let existingNode = self.emptyTextNode {
                textNode = existingNode
            } else {
                textNode = TextNode()
                self.emptyTextNode = textNode
                self.contentNode.addSubnode(textNode)
            }
            textNode.displaysAsynchronously = false
            let makeLayout = TextNode.asyncLayout(textNode)
            let (textLayout, textApply) = makeLayout(TextNodeLayoutArguments(attributedString: attributedString, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: max(1.0, size.width - 48.0), height: .greatestFiniteMagnitude), alignment: .center))
            textNode.frame = CGRect(origin: CGPoint(x: 24.0, y: size.height / 2.0 - textLayout.size.height / 2.0), size: textLayout.size)
            let _ = textApply()
            self.contentNode.frame = CGRect(origin: CGPoint(), size: size)
            self.scrollNode.view.contentSize = size
            return
        }

        self.emptyTextNode?.removeFromSupernode()
        self.emptyTextNode = nil

        let lineSpacing: CGFloat = 10.0
        let subtitles = self.configuration.mode == .subtitles && self.document?.isTimed == true
        let firstVisibleIndex = max(0, (self.currentLineIndex ?? 0) - 1)
        let lastVisibleIndex = min(self.lines.count - 1, (self.currentLineIndex ?? 0) + 1)
        var verticalOffset: CGFloat = subtitles ? 24.0 : size.height / 2.0
        for index in self.lines.indices {
            let line = self.lines[index]
            let textNode: TextNode
            if let existingNode = line.textNode {
                textNode = existingNode
            } else {
                textNode = TextNode()
                textNode.displaysAsynchronously = false
                self.lines[index].textNode = textNode
                self.contentNode.addSubnode(textNode)
            }
            textNode.isHidden = subtitles && !(firstVisibleIndex ... lastVisibleIndex).contains(index)
            if textNode.isHidden { continue }
            let makeLayout = TextNode.asyncLayout(textNode)
            let (textLayout, textApply) = makeLayout(TextNodeLayoutArguments(attributedString: self.attributedString(for: line, highlighted: index == self.currentLineIndex), maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: max(1.0, size.width - 48.0), height: .greatestFiniteMagnitude), alignment: subtitles ? .center : .natural))
            textNode.frame = CGRect(origin: CGPoint(x: 24.0, y: verticalOffset), size: textLayout.size)
            let _ = textApply()
            self.lines[index].size = CGSize(width: size.width, height: max(18.0, textLayout.size.height))
            verticalOffset += self.lines[index].size.height + lineSpacing
        }
        let contentSize = CGSize(width: size.width, height: max(size.height, verticalOffset - lineSpacing + (subtitles ? 24.0 : size.height / 2.0)))
        self.contentNode.frame = CGRect(origin: CGPoint(), size: contentSize)
        self.scrollNode.view.contentSize = contentSize
        self.scrollToActiveLine()
    }

    private func applyAttributes(index: Int, highlighted: Bool, scroll: Bool = true) {
        guard index < self.lines.count, let textNode = self.lines[index].textNode, !textNode.isHidden else {
            return
        }
        let makeLayout = TextNode.asyncLayout(textNode)
        let subtitles = self.configuration.mode == .subtitles && self.document?.isTimed == true
        let (textLayout, textApply) = makeLayout(TextNodeLayoutArguments(attributedString: self.attributedString(for: self.lines[index], highlighted: highlighted), maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: max(1.0, self.validSize.width - 48.0), height: .greatestFiniteMagnitude), alignment: subtitles ? .center : .natural))
        textNode.frame = CGRect(origin: textNode.frame.origin, size: textLayout.size)
        let _ = textApply()
        if highlighted && scroll {
            self.scrollToActiveLine()
        }
    }

    private func scrollToActiveLine() {
        guard self.displayed, self.configuration.autoScroll, self.configuration.mode != .plain, self.configuration.mode != .subtitles, !self.scrollNode.view.isTracking, !self.scrollNode.view.isDragging, !self.scrollNode.view.isDecelerating, let activeIndex = self.currentLineIndex, activeIndex < self.lines.count, let textNode = self.lines[activeIndex].textNode, self.validSize.height > 0.0 else {
            return
        }
        let lineMidY = textNode.frame.midY
        let contentHeight = max(self.contentNode.frame.height, self.validSize.height)
        var targetOffset = lineMidY - self.validSize.height / 2.0
        targetOffset = max(0.0, min(targetOffset, contentHeight - self.validSize.height))
        self.scrollNode.view.setContentOffset(CGPoint(x: 0.0, y: targetOffset), animated: true)
    }

    @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, self.configuration.tapToSeek else {
            return
        }
        let location = recognizer.location(in: self.contentNode.view)
        for line in self.lines {
            guard let textNode = line.textNode, !textNode.isHidden else { continue }
            let lineFrame = CGRect(x: 0.0, y: textNode.frame.minY, width: self.validSize.width, height: line.size.height)
            if lineFrame.contains(location) {
                if let timestamp = line.timestamp {
                    self.requestSeek?(max(0, timestamp + Double(self.configuration.offset) / 1000))
                }
                return
            }
        }
    }
}
