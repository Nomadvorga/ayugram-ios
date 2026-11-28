import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import UniversalMediaPlayer
import SGStrings

// MARK: AyuGram
// The lyrics of a track from the music player, looked up online like exteraGram's player does. Lines with
// times follow the playback: the one being sung is brighter and kept in view.

private let ayuLyricsSession = URLSession(configuration: .ephemeral)
private var ayuLyricsCache: [String: AyuLyrics] = [:]

// The lyrics on the main queue: a direct lookup, then a search. Nil when the service has none.
private func ayuRequestLyrics(_ query: AyuTrackQuery, completion: @escaping (AyuLyrics?) -> Void) {
    if let cached = ayuLyricsCache[query.key] {
        completion(cached)
        return
    }
    func finish(_ lyrics: AyuLyrics?) {
        DispatchQueue.main.async {
            if let lyrics {
                if ayuLyricsCache.count >= 50 {
                    ayuLyricsCache.removeAll()
                }
                ayuLyricsCache[query.key] = lyrics
            }
            completion(lyrics)
        }
    }
    func search() {
        guard let request = AyuLrclib.searchRequest(query) else {
            finish(nil)
            return
        }
        ayuLyricsSession.dataTask(with: request, completionHandler: { data, _, _ in
            finish(data.flatMap { AyuLrclib.lyrics(searchResponse: $0, query: query) })
        }).resume()
    }
    guard let request = AyuLrclib.getRequest(query) else {
        search()
        return
    }
    ayuLyricsSession.dataTask(with: request, completionHandler: { data, response, _ in
        if let response = response as? HTTPURLResponse, response.statusCode == 200, let data, let lyrics = AyuLrclib.lyrics(getResponse: data) {
            finish(lyrics)
        } else {
            search()
        }
    }).resume()
}

// What to look a music file's lyrics up by: its tags, else its name.
func ayuTrackQuery(file: TelegramMediaFile) -> AyuTrackQuery? {
    for attribute in file.attributes {
        if case let .Audio(_, duration, title, performer, _) = attribute {
            return AyuTrackQuery(performer: performer, title: (title ?? "").isEmpty ? file.fileName : title, duration: Double(duration))
        }
    }
    return AyuTrackQuery(performer: nil, title: file.fileName, duration: file.duration ?? 0.0)
}

final class AyuLyricsController: ViewController {
    private let context: AccountContext
    private var presentationData: PresentationData
    private let query: AyuTrackQuery
    private let messageId: EngineMessage.Id

    private let textView = UITextView()
    private let statusLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var lyrics: AyuLyrics?
    // The range of every line in the text view's text.
    private var lineRanges: [NSRange] = []
    private var currentLine: Int?
    private var playbackStatus: MediaPlayerStatus?
    private var playbackDisposable: Disposable?
    private var timer: Foundation.Timer?
    private var validLayout: (layout: ContainerViewLayout, navigationHeight: CGFloat)?

    init(context: AccountContext, query: AyuTrackQuery, messageId: EngineMessage.Id) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.query = query
        self.messageId = messageId

        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationTheme: self.presentationData.theme, presentationStrings: self.presentationData.strings))

        self.navigationPresentation = .modal
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.title = query.title
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(customView: UIView())
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Done, style: .done, target: self, action: #selector(self.donePressed))
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.playbackDisposable?.dispose()
        self.timer?.invalidate()
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.presentationData.theme.list.plainBackgroundColor

        self.textView.backgroundColor = .clear
        self.textView.isEditable = false
        self.textView.alwaysBounceVertical = true
        self.textView.textContainerInset = UIEdgeInsets(top: 20.0, left: 16.0, bottom: 32.0, right: 16.0)
        self.textView.indicatorStyle = self.presentationData.theme.overallDarkAppearance ? .white : .black
        self.displayNode.view.addSubview(self.textView)

        self.statusLabel.numberOfLines = 0
        self.statusLabel.textAlignment = .center
        self.statusLabel.font = Font.regular(16.0)
        self.statusLabel.textColor = self.presentationData.theme.list.itemSecondaryTextColor
        self.statusLabel.isHidden = true
        self.displayNode.view.addSubview(self.statusLabel)

        self.activityIndicator.color = self.presentationData.theme.list.itemSecondaryTextColor
        self.activityIndicator.startAnimating()
        self.displayNode.view.addSubview(self.activityIndicator)

        ayuRequestLyrics(self.query, completion: { [weak self] lyrics in
            self?.setLyrics(lyrics)
        })
    }

    private func setLyrics(_ lyrics: AyuLyrics?) {
        self.activityIndicator.stopAnimating()
        let lang = self.presentationData.strings.baseLanguageCode
        guard let lyrics, lyrics.isInstrumental || !lyrics.lines.isEmpty else {
            self.statusLabel.text = i18n("Extera.Lyrics.NotFound", lang)
            self.statusLabel.isHidden = false
            self.layoutContent()
            return
        }
        if lyrics.isInstrumental {
            self.statusLabel.text = i18n("Extera.Lyrics.Instrumental", lang)
            self.statusLabel.isHidden = false
            self.layoutContent()
            return
        }
        self.lyrics = lyrics
        self.updateText()

        guard lyrics.isSynced else {
            return
        }
        let messageId = self.messageId
        self.playbackDisposable = (self.context.sharedContext.mediaManager.musicMediaPlayerState
        |> deliverOnMainQueue).startStrict(next: { [weak self] state in
            guard let self else {
                return
            }
            if let (_, stateOrLoading, _) = state, case let .state(playbackState) = stateOrLoading, let itemId = playbackState.item.id as? PeerMessagesMediaPlaylistItemId, itemId.messageId == messageId {
                self.playbackStatus = playbackState.status
            } else {
                self.playbackStatus = nil
            }
            self.updateCurrentLine()
        })
        let timer = Foundation.Timer(timeInterval: 0.25, repeats: true, block: { [weak self] _ in
            self?.updateCurrentLine()
        })
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateText() {
        guard let lyrics = self.lyrics else {
            return
        }
        let theme = self.presentationData.theme
        let text = NSMutableAttributedString()
        var ranges: [NSRange] = []
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 8.0
        paragraph.lineSpacing = 2.0
        for (index, line) in lyrics.lines.enumerated() {
            let isCurrent = !lyrics.isSynced || index == self.currentLine
            let string = NSAttributedString(string: line.text.isEmpty ? " " : line.text, attributes: [
                .font: lyrics.isSynced ? Font.semibold(20.0) : Font.regular(17.0),
                .foregroundColor: isCurrent ? theme.list.itemPrimaryTextColor : theme.list.itemSecondaryTextColor.withAlphaComponent(0.6),
                .paragraphStyle: paragraph
            ])
            ranges.append(NSRange(location: text.length, length: string.length))
            text.append(string)
            text.append(NSAttributedString(string: "\n", attributes: [.font: Font.regular(17.0), .paragraphStyle: paragraph]))
        }
        text.append(NSAttributedString(string: "\n" + i18n("Extera.Lyrics.Source", self.presentationData.strings.baseLanguageCode, lyrics.provider), attributes: [
            .font: Font.regular(13.0),
            .foregroundColor: theme.list.itemSecondaryTextColor
        ]))
        self.lineRanges = ranges
        let offset = self.textView.contentOffset
        self.textView.attributedText = text
        self.textView.setContentOffset(offset, animated: false)
    }

    private func updateCurrentLine() {
        guard let lyrics = self.lyrics, lyrics.isSynced else {
            return
        }
        var line: Int?
        if let status = self.playbackStatus {
            var position = status.timestamp
            if case .playing = status.status {
                position += (CACurrentMediaTime() - status.generationTimestamp) * status.baseRate
            }
            line = lyrics.lineIndex(at: Int(position * 1000.0))
        }
        guard line != self.currentLine else {
            return
        }
        self.currentLine = line
        self.updateText()

        // The current line is brought to the upper third, unless the text is being dragged.
        if let line, line < self.lineRanges.count, !self.textView.isDragging, !self.textView.isDecelerating {
            self.textView.layoutManager.ensureLayout(for: self.textView.textContainer)
            let glyphRange = self.textView.layoutManager.glyphRange(forCharacterRange: self.lineRanges[line], actualCharacterRange: nil)
            let rect = self.textView.layoutManager.boundingRect(forGlyphRange: glyphRange, in: self.textView.textContainer)
            let visibleHeight = self.textView.bounds.height - self.textView.adjustedContentInset.top - self.textView.adjustedContentInset.bottom
            let maxOffset = max(-self.textView.adjustedContentInset.top, self.textView.contentSize.height + self.textView.adjustedContentInset.bottom - self.textView.bounds.height)
            let target = rect.minY + self.textView.textContainerInset.top - visibleHeight / 3.0 - self.textView.adjustedContentInset.top
            self.textView.setContentOffset(CGPoint(x: 0.0, y: min(maxOffset, max(-self.textView.adjustedContentInset.top, target))), animated: true)
        }
    }

    private func layoutContent() {
        guard let (layout, navigationHeight) = self.validLayout else {
            return
        }
        let frame = CGRect(x: layout.safeInsets.left, y: navigationHeight, width: layout.size.width - layout.safeInsets.left - layout.safeInsets.right, height: max(0.0, layout.size.height - navigationHeight))
        self.textView.frame = frame
        self.textView.contentInset = UIEdgeInsets(top: 0.0, left: 0.0, bottom: layout.intrinsicInsets.bottom, right: 0.0)
        self.textView.scrollIndicatorInsets = self.textView.contentInset
        self.activityIndicator.center = CGPoint(x: frame.midX, y: frame.minY + min(160.0, frame.height / 2.0))
        let statusSize = self.statusLabel.sizeThatFits(CGSize(width: frame.width - 48.0, height: frame.height))
        self.statusLabel.frame = CGRect(x: frame.minX + floor((frame.width - statusSize.width) / 2.0), y: frame.minY + min(140.0, floor((frame.height - statusSize.height) / 2.0)), width: statusSize.width, height: statusSize.height)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)

        self.validLayout = (layout, self.navigationLayout(layout: layout).navigationFrame.maxY)
        self.layoutContent()
    }

    @objc private func donePressed() {
        self.dismiss()
    }
}
