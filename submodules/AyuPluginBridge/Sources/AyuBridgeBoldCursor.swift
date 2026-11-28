import QuartzCore
import UIKit

/// The text field of Telegram's `EditTextBoldCursor`: its own caret (a bar of `cursorWidth` by
/// `cursorSize`, centred on the caret position) and, after `setLineColors`, the line under the text.
@MainActor final class AyuBridgeBoldCursorField: UITextField {
    static let className = "org.telegram.ui.Components.EditTextBoldCursor"
    /// Android's defaults: 2 dp wide, `dp(24)` tall, `0xff54a1db`.
    static let defaultCursorColor = UIColor(red: 0x54 / 255, green: 0xa1 / 255, blue: 0xdb / 255, alpha: 1)
    static let lineAnimationDuration: CFTimeInterval = 0.15

    var cursorWidth: CGFloat = 2 { didSet { self.caretChanged() } }
    var cursorSize: CGFloat = 24 { didSet { self.caretChanged() } }
    var cursorColor: UIColor = AyuBridgeBoldCursorField.defaultCursorColor { didSet { self.updateTint() } }
    /// `setCursorVisible(false)` hides the caret without forgetting its colour.
    var cursorVisible = true { didSet { self.updateTint() } }

    /// The line of `setLineColors`: one point of `color`, covered while focused by two of `active`.
    let line = CALayer()
    let activeLine = CALayer()
    private(set) var lineVisible = false
    private(set) var lineActive = false
    private var lineWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.updateTint()
        for layer in [self.line, self.activeLine] {
            layer.isHidden = true
            layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        }
    }

    required init?(coder: NSCoder) { nil }

    private func updateTint() {
        self.tintColor = self.cursorVisible ? self.cursorColor : .clear
    }

    private func caretChanged() {
        // UIKit asks for the caret rectangle again when the selection is set.
        guard self.isFirstResponder, let range = self.selectedTextRange else { return }
        self.selectedTextRange = nil
        self.selectedTextRange = range
    }

    override func caretRect(for position: UITextPosition) -> CGRect {
        let rect = super.caretRect(for: position)
        // `rect.top = rect.centerY() - cursorSize / 2`, in Android's integer arithmetic.
        let top = (rect.midY).rounded(.down) - (self.cursorSize / 2).rounded(.down)
        return CGRect(x: rect.minX, y: top, width: self.cursorWidth, height: self.cursorSize)
    }

    /// `setLineColors(color, active, error)`. Android draws no line while `color` is 0; the error
    /// colour belongs to `setErrorText`, which is not provided.
    func setLineColors(_ color: UIColor?, active: UIColor) {
        self.lineVisible = color != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.line.backgroundColor = color?.cgColor
        self.activeLine.backgroundColor = active.cgColor
        self.line.isHidden = !self.lineVisible
        self.activeLine.isHidden = !self.lineVisible
        CATransaction.commit()
        self.lineActive = self.isFirstResponder
        self.superview?.setNeedsLayout()
    }

    /// Places the line in `owner`, the view whose padding surrounds this field: across its whole
    /// width, ending two points above its bottom edge (`lineY = getMeasuredHeight() - dp(2)`).
    func layoutLine(in owner: UIView) {
        guard self.lineVisible else { return }
        if self.line.superlayer !== owner.layer {
            owner.layer.addSublayer(self.line)
            owner.layer.addSublayer(self.activeLine)
        }
        let size = owner.bounds.size
        self.lineWidth = size.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let position = CGPoint(x: size.width / 2, y: size.height - 2)
        self.line.position = position
        self.line.bounds = CGRect(x: 0, y: 0, width: size.width, height: 1)
        self.activeLine.position = position
        self.activeLine.bounds = CGRect(x: 0, y: 0, width: size.width, height: self.lineActive ? 2 : 0)
        CATransaction.commit()
    }

    /// Focus gained: the active line grows from the centre to the full width, two points thick.
    /// Focus lost: it thins out to nothing. Both take Android's 150 ms with its ease-in-out curve.
    func setLineActive(_ active: Bool, animated: Bool) {
        guard active != self.lineActive else { return }
        self.lineActive = active
        guard self.lineVisible else { return }
        if active {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.activeLine.bounds = CGRect(x: 0, y: 0, width: 0, height: 2)
            CATransaction.commit()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Self.lineAnimationDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        self.activeLine.bounds = CGRect(x: 0, y: 0, width: self.lineWidth, height: active ? 2 : 0)
        CATransaction.commit()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { self.setLineActive(true, animated: self.window != nil) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { self.setLineActive(false, animated: self.window != nil) }
        return resigned
    }
}
