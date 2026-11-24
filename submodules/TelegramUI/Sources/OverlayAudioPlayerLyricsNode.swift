import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import UniversalMediaPlayer
import TelegramPresentationData
import SGStrings

final class OverlayAudioPlayerLyricsNode: ASDisplayNode {
    private final class LyricLine {
        let timestamp: Double?
        let text: String
        var textNode: TextNode?
        var size: CGSize = .zero

        init(timestamp: Double?, text: String) {
            self.timestamp = timestamp
            self.text = text
        }
    }

    private var presentationTheme: PresentationTheme
    private var presentationStrings: PresentationStrings
    private let scrollNode: ASScrollNode
    private let contentNode: ASDisplayNode
    private var lines: [LyricLine] = []
    private var currentLineIndex: Int?
    private var currentTrackKey: String?
    private var validSize: CGSize = .zero
    private let fetchDisposable = MetaDisposable()

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
    }

    deinit {
        self.fetchDisposable.dispose()
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

    func setTrack(title: String?, performer: String?) {
        let cleanedTitle = OverlayAudioPlayerLyricsNode.cleanedTrackTitle(title) ?? ""
        let cleanedPerformer = (performer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(cleanedTitle)|\(cleanedPerformer)"
        guard !cleanedTitle.isEmpty, key != self.currentTrackKey else {
            return
        }
        self.currentTrackKey = key
        self.fetchDisposable.set((OverlayAudioPlayerLyricsNode.lyricsSignal(title: cleanedTitle, performer: cleanedPerformer)
        |> deliverOnMainQueue).start(next: { [weak self] payload in
            guard let self else {
                return
            }
            self.applyLyrics(payload ?? (synced: nil, plain: nil))
        }))
    }

    func updateStatus(_ status: MediaPlayerStatus?) {
        guard let status else {
            return
        }
        let timestamp = status.timestamp
        var activeIndex: Int?
        for index in self.lines.indices {
            if let lineTimestamp = self.lines[index].timestamp, lineTimestamp <= timestamp + 0.25 {
                activeIndex = index
            }
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
        }
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        self.validSize = size
        transition.updateFrame(node: self.scrollNode, frame: CGRect(origin: CGPoint(), size: size))
        self.layoutLines()
    }

    private static func cleanedTrackTitle(_ title: String?) -> String? {
        let original = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var result = original
        while true {
            let updated = result.replacingOccurrences(of: "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression, range: nil)
            if updated == result {
                break
            }
            result = updated.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.isEmpty {
            result = original
        }
        return result
    }

    private struct LrclibEntry: Codable {
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private static func entrySignal(url: URL) -> Signal<(synced: String?, plain: String?)?, NoError> {
        return Signal { subscriber in
            var request = URLRequest(url: url)
            request.timeoutInterval = 12.0
            let task = URLSession.shared.dataTask(with: request) { data, _, _ in
                var payload: (synced: String?, plain: String?)?
                if let data, let entry = try? JSONDecoder().decode(LrclibEntry.self, from: data) {
                    payload = (entry.syncedLyrics, entry.plainLyrics)
                }
                subscriber.putNext(payload)
                subscriber.putCompletion()
            }
            task.resume()
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    private static func lyricsSignal(title: String, performer: String) -> Signal<(synced: String?, plain: String?)?, NoError> {
        var exactComponents = URLComponents(string: "https://lrclib.net/api/get")
        exactComponents?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: performer)
        ]
        var searchComponents = URLComponents(string: "https://lrclib.net/api/search")
        searchComponents?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: performer)
        ]
        guard let exactUrl = exactComponents?.url, let searchUrl = searchComponents?.url else {
            return .single(nil)
        }

        return entrySignal(url: exactUrl)
        |> mapToSignal { payload -> Signal<(synced: String?, plain: String?)?, NoError> in
            if let payload, payload.synced != nil || payload.plain != nil {
                return .single(payload)
            }
            return entrySignal(url: searchUrl)
        }
    }

    private func applyLyrics(_ payload: (synced: String?, plain: String?)) {
        var parsedLines: [LyricLine] = []
        if let synced = payload.synced, !synced.isEmpty {
            parsedLines = OverlayAudioPlayerLyricsNode.parseSyncedLyrics(synced)
        }
        if parsedLines.isEmpty, let plain = payload.plain, !plain.isEmpty {
            for rawLine in plain.split(separator: "\n", omittingEmptySubsequences: true) {
                let text = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    parsedLines.append(LyricLine(timestamp: nil, text: text))
                }
            }
        }

        self.currentLineIndex = nil
        for line in self.lines {
            line.textNode?.removeFromSupernode()
        }
        self.lines = parsedLines

        if self.validSize.width > 0.0 {
            self.layoutLines()
        }
    }

    private static func parseSyncedLyrics(_ source: String) -> [LyricLine] {
        var result: [LyricLine] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: true) {
            var times: [Double] = []
            var rest = Substring(String(rawLine))
            while rest.hasPrefix("["), let closeIndex = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<closeIndex]
                rest = rest[rest.index(after: closeIndex)...]
                let components = tag.split(separator: ":")
                if components.count == 2, let minutes = Double(components[0]), let seconds = Double(components[1]) {
                    times.append(minutes * 60.0 + seconds)
                } else {
                    break
                }
            }
            let text = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !times.isEmpty else {
                continue
            }
            for time in times {
                result.append(LyricLine(timestamp: time, text: text))
            }
        }
        result.sort(by: { ($0.timestamp ?? 0.0) < ($1.timestamp ?? 0.0) })
        return result
    }

    private func attributedString(for line: LyricLine, highlighted: Bool) -> NSAttributedString {
        return NSAttributedString(string: line.text, font: highlighted ? Font.semibold(15.0) : Font.regular(15.0), textColor: highlighted ? self.presentationTheme.list.itemPrimaryTextColor : self.presentationTheme.list.itemSecondaryTextColor)
    }

    private func layoutLines() {
        let size = self.validSize
        guard size.width > 0.0, size.height > 0.0 else {
            return
        }

        if self.lines.isEmpty {
            let noLyricsString = i18n("Player.Lyrics.NotFound", self.presentationStrings.baseLanguageCode)
            let attributedString = NSAttributedString(string: noLyricsString, font: Font.regular(15.0), textColor: self.presentationTheme.list.itemSecondaryTextColor, paragraphAlignment: .center)
            let textNode = TextNode()
            textNode.displaysAsynchronously = false
            textNode.maximumNumberOfLines = 0
            let makeLayout = TextNode.asyncLayout(textNode)
            let (textLayout, textApply) = makeLayout(TextNodeLayoutArguments(attributedString: attributedString, maximumNumberOfLines: 0, truncationType: .end, constrainedSize: CGSize(width: size.width - 48.0, height: .greatestFiniteMagnitude), alignment: .center))
            textNode.frame = CGRect(origin: CGPoint(x: 24.0, y: size.height / 2.0 - textLayout.size.height / 2.0), size: textLayout.size)
            let _ = textApply()
            self.contentNode.addSubnode(textNode)
            self.contentNode.frame = CGRect(origin: CGPoint(), size: size)
            self.scrollNode.view.contentSize = size
            return
        }

        let lineSpacing: CGFloat = 10.0
        var verticalOffset: CGFloat = size.height / 2.0
        for index in self.lines.indices {
            let line = self.lines[index]
            let textNode: TextNode
            if let existingNode = line.textNode {
                textNode = existingNode
            } else {
                textNode = TextNode()
                textNode.displaysAsynchronously = false
                textNode.maximumNumberOfLines = 3
                self.lines[index].textNode = textNode
                self.contentNode.addSubnode(textNode)
            }
            let makeLayout = TextNode.asyncLayout(textNode)
            let (textLayout, textApply) = makeLayout(TextNodeLayoutArguments(attributedString: self.attributedString(for: line, highlighted: index == self.currentLineIndex), maximumNumberOfLines: 3, truncationType: .end, constrainedSize: CGSize(width: size.width - 48.0, height: .greatestFiniteMagnitude)))
            textNode.frame = CGRect(origin: CGPoint(x: 24.0, y: verticalOffset), size: textLayout.size)
            let _ = textApply()
            self.lines[index].size = CGSize(width: size.width, height: max(18.0, textLayout.size.height))
            verticalOffset += self.lines[index].size.height + lineSpacing
        }
        let contentSize = CGSize(width: size.width, height: verticalOffset - lineSpacing + size.height / 2.0)
        self.contentNode.frame = CGRect(origin: CGPoint(), size: contentSize)
        self.scrollNode.view.contentSize = contentSize
        self.scrollToActiveLine()
    }

    private func applyAttributes(index: Int, highlighted: Bool) {
        guard index < self.lines.count, let textNode = self.lines[index].textNode else {
            return
        }
        let makeLayout = TextNode.asyncLayout(textNode)
        let (textLayout, textApply) = makeLayout(TextNodeLayoutArguments(attributedString: self.attributedString(for: self.lines[index], highlighted: highlighted), maximumNumberOfLines: 3, truncationType: .end, constrainedSize: CGSize(width: self.validSize.width - 48.0, height: .greatestFiniteMagnitude)))
        textNode.frame = CGRect(origin: textNode.frame.origin, size: textLayout.size)
        let _ = textApply()
        if highlighted {
            self.scrollToActiveLine()
        }
    }

    private func scrollToActiveLine() {
        guard let activeIndex = self.currentLineIndex, activeIndex < self.lines.count, let textNode = self.lines[activeIndex].textNode, self.validSize.height > 0.0 else {
            return
        }
        let lineMidY = textNode.frame.midY
        let contentHeight = max(self.contentNode.frame.height, self.validSize.height)
        var targetOffset = lineMidY - self.validSize.height / 2.0
        targetOffset = max(0.0, min(targetOffset, contentHeight - self.validSize.height))
        self.scrollNode.view.setContentOffset(CGPoint(x: 0.0, y: targetOffset), animated: true)
    }

    @objc private func tapGesture(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else {
            return
        }
        let location = recognizer.location(in: self.contentNode.view)
        var verticalOffset: CGFloat = self.validSize.height / 2.0
        let lineSpacing: CGFloat = 10.0
        for line in self.lines {
            let lineFrame = CGRect(x: 0.0, y: verticalOffset, width: line.size.width, height: line.size.height)
            if lineFrame.contains(location) {
                if let timestamp = line.timestamp {
                    self.requestSeek?(timestamp)
                }
                return
            }
            verticalOffset += line.size.height + lineSpacing
        }
    }
}
