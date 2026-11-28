// MARK: AyuGram
import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import AccountContext
import AppBundle
import ChatInputTextNode
import SGSimpleSettings
import SGStrings
import AyuInlineResults

// exteraGram's inline results: the answer to "2+2=" shown in gray after the caret of the message field.
// Space inserts it, Backspace right after the insertion takes it back.
final class AyuInlineMathGhost {
    private static let ghostAlpha: CGFloat = 0.4
    private static let announceDelay: TimeInterval = 0.6

    private let engine: InlineResultsEngine
    private let session: InlineMathSession
    private let label = UILabel()
    private let language: () -> String

    private weak var textView: ChatInputTextView?
    private var storageObserver: NSObjectProtocol?
    private var isApplying = false
    private var refreshScheduled = false
    private var announcedValue: String?
    private var announceWork: DispatchWorkItem?
    private var phoneDisposable: Disposable?

    init(context: AccountContext, language: @escaping () -> String) {
        self.language = language
        let accountId = context.account.id.int64
        var ratesUpdated: (() -> Void)?
        // Currency of the account's phone number country; the device region stands in until the number is read.
        let phoneCurrency = Atomic<String?>(value: nil)
        self.engine = InlineResultsEngine(environment: InlineResultsEngine.Environment(
            starsUsdSellRate1000: { [weak context] in
                return (context?.currentAppConfiguration.with { $0 }.data?["stars_usd_sell_rate_x1000"] as? Double) ?? 2000.0
            },
            targetCurrency: {
                return ExteraSettings.shared.inlineTargetCurrency
            },
            currentAccount: {
                return accountId
            },
            accountCurrency: { _ in
                if let currency = phoneCurrency.with({ $0 }) {
                    return currency
                }
                guard let region = (Locale.current as NSLocale).countryCode else {
                    return nil
                }
                return InlineResultsEngine.localCurrency(countries: [region], localeCountry: nil)
            }
        ), onRatesUpdated: {
            ratesUpdated?()
        })
        self.session = InlineMathSession(engine: self.engine)

        self.label.isUserInteractionEnabled = false
        self.label.isAccessibilityElement = false
        self.label.isHidden = true
        self.label.backgroundColor = nil

        ratesUpdated = { [weak self] in
            self?.refresh()
        }

        self.phoneDisposable = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self, case let .user(user) = peer, let phone = user.phone, let currency = AyuInlineMathGhost.currency(forPhone: phone) else {
                return
            }
            let _ = phoneCurrency.swap(currency)
            self.engine.invalidateAccountCurrency()
            self.refresh()
        })
    }

    // The device region wins among the countries that share the number's calling code (+1, +7).
    private static func currency(forPhone phone: String) -> String? {
        guard let path = getAppBundle().path(forResource: "PhoneCountries", ofType: "txt"), let table = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let countries = InlineResultsEngine.countries(forPhone: phone, phoneCountries: table)
        return InlineResultsEngine.localCurrency(countries: countries, localeCountry: (Locale.current as NSLocale).countryCode)
    }

    deinit {
        if let storageObserver = self.storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
        }
        self.announceWork?.cancel()
        self.phoneDisposable?.dispose()
    }

    // nil for an input backend that is not a text view: no inline results there.
    func attach(to textView: ChatInputTextView?) {
        if self.textView === textView {
            return
        }
        if let storageObserver = self.storageObserver {
            NotificationCenter.default.removeObserver(storageObserver)
            self.storageObserver = nil
        }
        self.label.removeFromSuperview()
        self.label.isHidden = true
        self.session.reset()
        self.textView = textView
        guard let textView else {
            return
        }
        textView.addSubview(self.label)
        // Every change of the text, typed or set by the app (a sent message, a restored draft).
        self.storageObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: textView.textStorage, queue: nil, using: { [weak self] notification in
            guard let self, let storage = notification.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else {
                return
            }
            if !self.isApplying {
                self.session.textDidChange()
            }
            self.scheduleRefresh()
        })
        self.refresh()
    }

    func selectionDidChange() {
        guard let textView = self.textView else {
            return
        }
        if !self.isApplying {
            self.session.selectionDidChange(textView.selectedRange)
        }
        self.scheduleRefresh()
    }

    func focusDidChange() {
        self.scheduleRefresh()
    }

    // True when the key was taken: the caller must refuse the keyboard's own edit.
    func handle(range: NSRange, replacement: String) -> Bool {
        guard !self.isApplying, let textView = self.textView else {
            return false
        }
        let selection = textView.selectedRange
        guard let edit = self.session.edit(forReplacing: range, with: replacement, selection: selection) else {
            return false
        }
        let length = textView.textStorage.length
        // The edit is made after the text view has finished refusing this key.
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self else {
                return
            }
            guard let textView, self.textView === textView, textView.selectedRange == selection, textView.textStorage.length == length else {
                self.refresh()
                return
            }
            self.session.perform(edit) { edit in
                self.isApplying = true
                if edit.replacement.isEmpty {
                    textView.selectedRange = edit.range
                    textView.deleteBackward()
                } else {
                    textView.insertText(edit.replacement)
                }
                self.isApplying = false
            }
            self.refresh()
        }
        return true
    }

    private func configuration() -> InlineResultsConfiguration? {
        let settings = ExteraSettings.shared
        guard settings.inlineResultsEnabled else {
            return nil
        }
        let imperial: Bool
        switch settings.inlineMeasureSystem {
        case .auto:
            imperial = InlineResultsEngine.isImperial(regionCode: (Locale.current as NSLocale).countryCode)
        case .metric:
            imperial = false
        case .imperial:
            imperial = true
        }
        let language = self.language()
        return InlineResultsConfiguration(
            calculator: settings.inlineMathResult,
            currencies: settings.inlineCurrencyRates,
            units: settings.inlineUnitConversion,
            timeZones: settings.inlineTimeZones,
            degrees: settings.inlineAngleUnit == .degrees,
            grouping: settings.inlineDigitGrouping,
            imperial: imperial,
            decimalSeparator: InlineResultsEngine.decimalSeparator(language: language),
            language: language
        )
    }

    private func scheduleRefresh() {
        if self.refreshScheduled {
            return
        }
        self.refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard let textView = self.textView else {
            return
        }
        guard let configuration = self.configuration() else {
            if self.session.suggestion != nil || !self.label.isHidden {
                self.session.reset()
                self.hide()
            }
            return
        }
        self.engine.prepare(configuration)

        let selection = textView.selectedRange
        let storage = textView.textStorage
        // Cheap test before the text is copied out of the text view: a result needs "=" before the caret.
        guard selection.length == 0, selection.location >= 2, selection.location <= storage.length, (storage.string as NSString).character(at: selection.location - 1) == 0x3D else {
            self.session.dismissSuggestion()
            self.hide()
            return
        }
        let suggestion = self.session.refresh(text: storage.string, selection: selection, isActive: textView.isFirstResponder, hasMarkedText: textView.markedTextRange != nil, configuration: configuration)
        guard let suggestion, self.show(suggestion, in: textView) else {
            self.session.dismissSuggestion()
            self.hide()
            return
        }
        self.announce(suggestion.value)
    }

    private func hide() {
        self.label.isHidden = true
        self.announceWork?.cancel()
        self.announceWork = nil
        self.announcedValue = nil
    }

    // False when the ghost cannot be drawn after the caret: right-to-left text or no room left on the line.
    private func show(_ suggestion: InlineMathSuggestion, in textView: ChatInputTextView) -> Bool {
        let storage = textView.textStorage
        let equalsIndex = suggestion.insertAt - 1
        guard equalsIndex >= 0, equalsIndex < storage.length else {
            return false
        }
        if let position = textView.position(from: textView.beginningOfDocument, offset: suggestion.insertAt), textView.baseWritingDirection(for: position, in: .backward) == .rightToLeft {
            return false
        }
        let attributes = storage.attributes(at: equalsIndex, effectiveRange: nil)
        guard let font = (attributes[.font] as? UIFont) ?? textView.font else {
            return false
        }
        let color = (attributes[.foregroundColor] as? UIColor) ?? textView.textColor ?? UIColor.gray

        let layoutManager = textView.layoutManager
        let container = textView.textContainer
        layoutManager.ensureLayout(for: container)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: equalsIndex)
        guard glyphIndex < layoutManager.numberOfGlyphs else {
            return false
        }
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
        let baseline = lineRect.minY + layoutManager.location(forGlyphAt: glyphIndex).y

        self.label.font = font
        self.label.textColor = color.withAlphaComponent(AyuInlineMathGhost.ghostAlpha)
        self.label.text = suggestion.insertText
        let size = self.label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))

        let inset = textView.textContainerInset
        let left = glyphRect.maxX
        let available = lineRect.maxX - container.lineFragmentPadding - left
        if size.width > available {
            return false
        }
        self.label.frame = CGRect(x: inset.left + left, y: inset.top + baseline - font.ascender, width: ceil(size.width), height: ceil(font.lineHeight))
        self.label.isHidden = false
        textView.bringSubviewToFront(self.label)
        return true
    }

    private func announce(_ value: String) {
        guard UIAccessibility.isVoiceOverRunning, value != self.announcedValue else {
            return
        }
        self.announceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session.suggestion?.value == value else {
                return
            }
            self.announcedValue = value
            UIAccessibility.post(notification: .announcement, argument: "Extera.InlineResultAnnouncement".i18n(self.language(), args: value))
        }
        self.announceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AyuInlineMathGhost.announceDelay, execute: work)
    }
}
