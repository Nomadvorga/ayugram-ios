import Foundation
import SGMath
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import ChatPresentationInterfaceState
import ChatInputContextPanelNode
import ChatControllerInteraction
import SGStrings

/// A native result row hosted by the composer's existing input-context surface.
/// Tapping the result appends it at the caret; the copy button only copies its value.
final class ExteraMathChatInputContextPanelNode: ChatInputContextPanelNode {
    private let containerNode = ASDisplayNode()
    private let separatorNode = ASDisplayNode()
    private let resultButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private var suggestion: ExteraMathEngine.Suggestion?
    private var sourceText = ""
    private var options = ExteraMathEngine.Options()
    private var currencyRequest: ExteraMathCurrencyRequest?
    private var currencyFailed = false

    deinit {
        self.currencyRequest?.cancel()
    }

    override func didExitHierarchy() {
        super.didExitHierarchy()
        self.currencyRequest?.cancel()
        self.currencyRequest = nil
    }

    override init(context: AccountContext, theme: PresentationTheme, strings: PresentationStrings, fontSize: PresentationFontSize, chatPresentationContext: ChatPresentationContext) {
        super.init(context: context, theme: theme, strings: strings, fontSize: fontSize, chatPresentationContext: chatPresentationContext)
        self.isOpaque = false
        self.addSubnode(self.containerNode)
        self.containerNode.addSubnode(self.separatorNode)
        self.containerNode.view.addSubview(self.resultButton)
        self.containerNode.view.addSubview(self.copyButton)
        self.resultButton.contentHorizontalAlignment = .left
        self.resultButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        self.resultButton.addTarget(self, action: #selector(self.insertResult), for: .touchUpInside)
        self.copyButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        self.copyButton.addTarget(self, action: #selector(self.copyResult), for: .touchUpInside)
    }

    func update(suggestion: ExteraMathEngine.Suggestion, sourceText: String, options: ExteraMathEngine.Options) {
        if self.sourceText != sourceText || self.suggestion?.insertAt != suggestion.insertAt {
            self.currencyRequest?.cancel()
            self.currencyRequest = nil
            self.currencyFailed = false
        }
        self.sourceText = sourceText
        self.options = options
        if self.options.currencyRates == nil { self.options.currencyRates = ExteraMathCurrencyRequest.cached() }
        self.suggestion = ExteraMathEngine.suggestion(in: sourceText, caret: suggestion.insertAt, options: self.options) ?? suggestion
        if suggestion.isPendingCurrency || self.suggestion?.currencyRateDate != nil {
            if self.currencyRequest == nil, !self.currencyFailed, ExteraMathCurrencyRequest.shouldRefresh() {
                self.currencyRequest = ExteraMathCurrencyRequest { [weak self] snapshot in
                    guard let self else { return }
                    self.currencyRequest = nil
                    self.currencyFailed = snapshot == nil
                    if let snapshot { self.options.currencyRates = snapshot }
                    self.suggestion = ExteraMathEngine.suggestion(in: self.sourceText, caret: suggestion.insertAt, options: self.options)
                    if self.suggestion?.isPendingCurrency == true { self.currencyFailed = true }
                    self.updateResult()
                }
            } else if self.currencyRequest == nil, self.suggestion?.isPendingCurrency == true {
                self.currencyFailed = true
            }
        }
        self.updateResult()
    }

    private func localized(_ key: String, fallback: String) -> String {
        let text = i18n(key, self.strings.baseLanguageCode)
        return text == key || text.isEmpty ? fallback : text
    }

    private func updateResult() {
        guard let suggestion = self.suggestion else {
            self.resultButton.isEnabled = false
            self.copyButton.isEnabled = false
            return
        }
        let pending = suggestion.isPendingCurrency
        self.resultButton.isEnabled = !pending
        self.copyButton.isEnabled = !pending
        let value = pending ? self.localized(self.currencyFailed ? "Extera.Math.RatesUnavailable" : "Extera.Math.LoadingRates", fallback: self.currencyFailed ? "Exchange rates unavailable" : "Loading exchange rates…") : suggestion.value
        var title = "= " + value
        if let date = suggestion.currencyRateDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: self.strings.baseLanguageCode)
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            title += " · " + formatter.string(from: date)
        }
        self.resultButton.setTitle(title, for: .normal)
        self.resultButton.accessibilityLabel = suggestion.expression + " " + title
        self.updateAccessibilityLabels()
    }

    private func updateAccessibilityLabels() {
        self.resultButton.accessibilityHint = i18n("Extera.Math.InsertResult", self.strings.baseLanguageCode)
        self.copyButton.accessibilityLabel = i18n("Extera.Math.CopyResult", self.strings.baseLanguageCode) + ": " + (self.suggestion?.isPendingCurrency == true ? "" : self.suggestion?.value ?? "")
    }

    @objc private func insertResult() {
        guard let suggestion = self.suggestion, !suggestion.isPendingCurrency, let interaction = self.interfaceInteraction else { return }
        let sourceText = self.sourceText
        var options = self.options
        if suggestion.currencyRateDate != nil { options.now = Date() }
        interaction.updateTextInputStateAndMode { state, mode in
            let selection = state.selectionRange
            // Revalidate both text and selection: a dismissed row can finish a touch
            // after the user has already moved the caret or edited another block.
            guard selection.isEmpty, selection.lowerBound == suggestion.insertAt,
                  state.inputText.string == sourceText,
                  ExteraMathEngine.suggestion(in: sourceText, caret: selection.lowerBound, options: options) == suggestion else {
                return (state, mode)
            }
            return (state.replacingFlatRange(NSRange(location: suggestion.insertAt, length: 0), with: suggestion.insertText), mode)
        }
    }

    @objc private func copyResult() {
        guard let suggestion = self.suggestion, !suggestion.isPendingCurrency else { return }
        if suggestion.currencyRateDate != nil {
            var options = self.options
            options.now = Date()
            guard ExteraMathEngine.suggestion(in: self.sourceText, caret: suggestion.insertAt, options: options) == suggestion else { return }
        }
        UIPasteboard.general.string = suggestion.value
        UIAccessibility.post(notification: .announcement, argument: self.strings.Conversation_TextCopied)
    }

    override func updateLayout(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, bottomInset: CGFloat, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState) {
        self.theme = interfaceState.theme
        self.strings = interfaceState.strings
        self.updateResult()
        self.containerNode.backgroundColor = interfaceState.theme.list.plainBackgroundColor
        self.separatorNode.backgroundColor = interfaceState.theme.list.itemPlainSeparatorColor
        self.resultButton.setTitleColor(interfaceState.theme.list.itemPrimaryTextColor, for: .normal)
        self.resultButton.titleLabel?.font = Font.medium(min(22.0, max(17.0, interfaceState.fontSize.baseDisplaySize)))
        self.copyButton.tintColor = interfaceState.theme.list.itemAccentColor
        let height: CGFloat = 52.0
        // The composer passes the overlap with its input field as bottomInset.
        // Keep the entire row above that field (including its rounded mask).
        let frame = CGRect(x: leftInset, y: max(0.0, size.height - bottomInset - height), width: max(0.0, size.width - leftInset - rightInset), height: height)
        transition.updateFrame(node: self.containerNode, frame: frame)
        self.resultButton.frame = CGRect(x: 12.0, y: 0.0, width: max(0.0, frame.width - 68.0), height: height)
        self.copyButton.frame = CGRect(x: max(0.0, frame.width - 52.0), y: 0.0, width: 52.0, height: height)
        self.separatorNode.frame = CGRect(x: 0.0, y: 0.0, width: frame.width, height: UIScreenPixel)
    }

    override var topItemFrame: CGRect? { return self.containerNode.frame }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.containerNode.frame.contains(point) else { return nil }
        return self.containerNode.view.hitTest(CGPoint(x: point.x - self.containerNode.frame.minX, y: point.y - self.containerNode.frame.minY), with: event)
    }
}
