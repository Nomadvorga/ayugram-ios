import UIKit

/// Android's `AlertDialog` progress styles: `ALERT_TYPE_SPINNER` (a round 56 pt box with a
/// spinner, nothing else) and `ALERT_TYPE_LOADING` (title, message, line progress, percent, buttons).
@MainActor final class AyuPluginProgressDialogController: UIViewController {
    struct Button {
        let title: String
        let action: @MainActor () -> Void
    }

    let isSpinner: Bool
    /// `android.app.ProgressDialog` in `STYLE_SPINNER`: a spinner beside the message, no progress line.
    let isIndeterminate: Bool
    /// Loading style only: whether a tap outside the box cancels the dialog.
    var cancelable: Bool
    /// Spinner: any touch (Android asks "Stop loading?"). Loading: a touch outside the box while cancelable.
    var onTouch: (@MainActor () -> Void)?
    private(set) var progress: Int
    let indicator = UIActivityIndicatorView(style: .medium)
    let bar = UIProgressView(progressViewStyle: .default)
    let percent = UILabel()
    let box = UIView()
    private let titleText: String?
    private var messageText: String?
    let messageLabel = UILabel()
    private let buttons: [Button]

    init(spinner: Bool, indeterminate: Bool = false, title: String?, message: String?, progress: Int, cancelable: Bool, buttons: [Button]) {
        self.isSpinner = spinner; self.isIndeterminate = indeterminate; self.titleText = title; self.messageText = message
        self.progress = progress; self.cancelable = cancelable; self.buttons = buttons
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { nil }

    func setMessage(_ text: String?) {
        self.messageText = text
        self.messageLabel.text = text
    }

    func setProgress(_ value: Int) {
        self.progress = value
        // Android: LineProgressView.setProgress(progress / 100f) and the text "%d%%".
        self.bar.setProgress(min(max(Float(value) / 100, 0), 1), animated: self.viewIfLoaded?.window != nil)
        self.percent.text = "\(value)%"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Android dims behind the loading dialog only; the spinner floats over the screen.
        self.view.backgroundColor = self.isSpinner ? .clear : UIColor(white: 0, alpha: 0.4)
        self.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapped(_:))))
        self.box.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.box)
        var constraints = [self.box.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
                           self.box.centerYAnchor.constraint(equalTo: self.view.centerYAnchor)]
        if self.isSpinner {
            self.box.backgroundColor = .secondarySystemBackground
            self.box.layer.cornerRadius = 28
            self.indicator.translatesAutoresizingMaskIntoConstraints = false
            self.indicator.startAnimating()
            self.box.addSubview(self.indicator)
            self.box.isAccessibilityElement = true
            self.box.accessibilityLabel = "Загрузка"
            constraints += [self.box.widthAnchor.constraint(equalToConstant: 56), self.box.heightAnchor.constraint(equalToConstant: 56),
                            self.indicator.centerXAnchor.constraint(equalTo: self.box.centerXAnchor),
                            self.indicator.centerYAnchor.constraint(equalTo: self.box.centerYAnchor)]
        } else {
            self.box.backgroundColor = .systemBackground
            self.box.layer.cornerRadius = 14
            let stack = UIStackView()
            stack.axis = .vertical; stack.spacing = 12; stack.alignment = .fill
            stack.translatesAutoresizingMaskIntoConstraints = false
            if let text = self.titleText {
                let label = UILabel()
                label.text = text; label.font = .boldSystemFont(ofSize: 20); label.numberOfLines = 0; label.textColor = .label
                stack.addArrangedSubview(label)
            }
            self.messageLabel.text = self.messageText
            self.messageLabel.font = .systemFont(ofSize: 16); self.messageLabel.numberOfLines = 0; self.messageLabel.textColor = .label
            if self.isIndeterminate {
                let row = UIStackView(arrangedSubviews: [self.indicator, self.messageLabel])
                row.axis = .horizontal; row.spacing = 16; row.alignment = .center
                self.indicator.setContentHuggingPriority(.required, for: .horizontal)
                self.indicator.startAnimating()
                stack.addArrangedSubview(row)
            } else {
                if self.messageText != nil { stack.addArrangedSubview(self.messageLabel) }
                self.percent.font = .boldSystemFont(ofSize: 14); self.percent.textColor = .secondaryLabel
                stack.addArrangedSubview(self.bar); stack.addArrangedSubview(self.percent)
            }
            if !self.buttons.isEmpty {
                let row = UIStackView()
                row.axis = .horizontal; row.spacing = 16; row.alignment = .center
                row.addArrangedSubview(UIView())
                for (index, button) in self.buttons.enumerated() {
                    let control = UIButton(type: .system)
                    control.setTitle(button.title, for: .normal)
                    control.titleLabel?.font = .boldSystemFont(ofSize: 16)
                    control.tag = index
                    control.addTarget(self, action: #selector(self.pressed(_:)), for: .touchUpInside)
                    row.addArrangedSubview(control)
                }
                stack.addArrangedSubview(row)
            }
            self.box.addSubview(stack)
            constraints += [self.box.widthAnchor.constraint(equalToConstant: 292),
                            stack.leadingAnchor.constraint(equalTo: self.box.leadingAnchor, constant: 24),
                            stack.trailingAnchor.constraint(equalTo: self.box.trailingAnchor, constant: -24),
                            stack.topAnchor.constraint(equalTo: self.box.topAnchor, constant: 20),
                            stack.bottomAnchor.constraint(equalTo: self.box.bottomAnchor, constant: -16)]
        }
        NSLayoutConstraint.activate(constraints)
        self.setProgress(self.progress)
    }

    @objc func pressed(_ sender: UIButton) {
        guard self.buttons.indices.contains(sender.tag) else { return }
        self.buttons[sender.tag].action()
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        self.touched(inside: self.box.frame.contains(recognizer.location(in: self.view)))
    }

    func touched(inside: Bool) {
        if self.isSpinner || (!inside && self.cancelable) { self.onTouch?() }
    }
}
