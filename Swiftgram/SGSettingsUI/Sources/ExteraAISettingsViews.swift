import Foundation
import SGStrings
import TelegramPresentationData
import UIKit

enum ExteraAIStrings {
    static let keys: [String: String] = [
        "AI Chat": "Title",
        "Generate text from messages or before sending.": "HeroInfo",
        "General": "General", "Services": "Services", "Roles": "Roles", "Message History": "History", "None": "None", "Off": "Off",
        "Conversation history helps AI understand earlier requests and consider them when generating an answer.": "HistoryInfo",
        "Telegram AI": "TelegramAI", "Editor": "Editor", "Summaries": "Summaries",
        "Translation, style and proofreading of drafts": "EditorInfo",
        "Short summaries of long messages and posts": "SummariesInfo",
        "Selected functions use your AI service instead of Telegram servers. Select and configure a service first. A separate translation provider takes precedence for translation.": "ReplacementInfo",
        "Generation": "Generation", "Stream Responses": "Streaming",
        "Display answers smoothly as they arrive.": "StreamingInfo",
        "Show Only Response": "ShowResponseOnly", "Insert Response as Quote": "InsertAsQuote", "Temperature": "Temperature",
        "Temperature controls randomness: higher values are more creative, lower values more precise. Some models choose their own temperature.": "TemperatureInfo",
        "Try AI": "TryAI", "Improve Text": "Improve", "Summarize Text": "Summarize",
        "Nothing is sent from this page. In AI Chat and text processing, press Send to share the entered text with your selected service. API keys stay in this device’s Keychain.": "SendInfo",
        "Save Chat History": "SaveHistory", "Copied": "Copied",
        "Suggestions": "RoleSuggestions", "No System Role": "RoleNone",
        "Add Role": "RoleAdd", "AI Role": "RoleTitle", "Role Name": "RoleName",
        "Edit System Prompt": "RoleEditPrompt", "System Prompt": "RolePrompt",
        "Save Role": "RoleSave", "Use Role": "RoleUse", "Use Saved Role": "RoleUseSaved",
        "Copy Role": "RoleCopy", "Create Copy": "RoleCreateCopy", "Delete Role": "RoleDelete",
        "Delete this role?": "RoleDeleteConfirm",
        "Suggestions can be previewed, selected or copied into a new role. Save custom roles separately from selecting them. AI Chat uses the active role; the editor and summarizer keep their own instructions.": "RoleInfo",
        "The role name must contain between 1 and 64 characters.": "RoleNameLimit",
        "The prompt must contain no more than 1,024 characters.": "RolePromptLimit",
        "Custom": "ProviderCustom", "Test and Save Service": "ServiceTestSave",
        "User-Agent": "UserAgent", "Default": "UserAgentDefault",
        "OpenCode": "UserAgentOpenCode", "Claude Code": "UserAgentClaudeCode",
        "ZCode": "UserAgentZCode", "Codex": "UserAgentCodex",
        "Cursor": "UserAgentCursor", "Cline": "UserAgentCline", "Roo Code": "UserAgentRooCode",
        "Custom User-Agent": "UserAgentCustom", "Actual User-Agent": "UserAgentActual",
        "System default (URLSession)": "UserAgentSystemDefault",
        "Changes the HTTP client identifier for this service. Provider compatibility also depends on its API and authentication.": "UserAgentInfo"
    ]

    static let roleErrors: [String: (String, String)] = [
        "This AI role no longer exists.": ("RoleMissing", "Эта роль ИИ больше не существует."),
        "This AI role cannot be edited. Reopen the roles list.": ("RoleStale", "Эту роль ИИ нельзя изменить. Откройте список ролей заново."),
        "Enter a role name (up to 64 characters) and a system prompt (up to 1,024 characters).": ("RoleInvalid", "Введите название роли (до 64 символов) и системную инструкцию (до 1 024 символов)."),
        "An AI role with this name already exists.": ("RoleDuplicate", "Роль ИИ с таким названием уже существует."),
        "The AI role limit has been reached.": ("RoleCountLimit", "Достигнуто максимальное число ролей ИИ."),
        "Enter a User-Agent of 1–512 printable ASCII characters without leading or trailing spaces.": ("UserAgentInvalid", "Введите User-Agent длиной от 1 до 512 печатных символов ASCII без пробелов в начале и конце.")
    ]

    static func error(_ error: Error, language: String) -> String {
        let message = error.localizedDescription
        guard let (suffix, russian) = self.roleErrors[message] else { return message }
        let key = "Extera.AISettings." + suffix
        let value = i18n(key, language)
        if value != key && !value.isEmpty { return value }
        return language.hasPrefix("ru") ? russian : message
    }

    static func text(_ english: String, _ russian: String, language: String) -> String {
        if let suffix = self.keys[english] {
            let key = "Extera.AISettings." + suffix
            let value = i18n(key, language)
            if value != key && !value.isEmpty { return value }
        }
        return language.hasPrefix("ru") ? russian : english
    }
}

final class ExteraAISettingsButton: UIButton {
    var action: (() -> Void)?
    init() {
        super.init(frame: .zero)
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { self.action?() }
}

final class ExteraAISettingsSwitch: UISwitch {
    var update: ((Bool) -> Void)?
    init(value: Bool, update: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        self.isOn = value
        self.update = update
        self.addTarget(self, action: #selector(self.changed), for: .valueChanged)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { self.update?(self.isOn) }
}

/// Native slider with the same twenty 0.1 steps and 0...2 range as Android.
/// Dragging updates the value label; persistence happens at gesture completion.
final class ExteraAITemperatureSlider: UISlider {
    override func accessibilityIncrement() { self.adjust(by: 0.1) }
    override func accessibilityDecrement() { self.adjust(by: -0.1) }

    private func adjust(by delta: Float) {
        self.value = min(self.maximumValue, max(self.minimumValue, (self.value * 10).rounded() / 10 + delta))
        self.sendActions(for: .valueChanged)
    }
}

final class ExteraAITemperatureView: UIView {
    let slider = ExteraAITemperatureSlider()
    private let current = UILabel()
    var commit: ((Double) -> Void)?

    init(value: Double, title: String, theme: PresentationTheme) {
        super.init(frame: .zero)
        self.slider.minimumValue = 0
        self.slider.maximumValue = 2
        self.slider.value = Float(value)
        self.slider.minimumTrackTintColor = theme.list.itemAccentColor
        self.slider.accessibilityLabel = title
        self.slider.addTarget(self, action: #selector(self.changed), for: .valueChanged)
        self.slider.addTarget(self, action: #selector(self.finished), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let minimum = ExteraAISettingsViews.label("0.0", theme: theme, style: .footnote, secondary: true)
        let maximum = ExteraAISettingsViews.label("2.0", theme: theme, style: .footnote, secondary: true)
        self.current.font = .preferredFont(forTextStyle: .footnote)
        self.current.adjustsFontForContentSizeCategory = true
        self.current.textAlignment = .center
        self.current.textColor = theme.list.itemAccentColor
        maximum.textAlignment = .right
        let labels = UIStackView(arrangedSubviews: [minimum, self.current, maximum])
        labels.distribution = .fillEqually
        let content = UIStackView(arrangedSubviews: [labels, self.slider])
        content.axis = .vertical
        content.spacing = 8
        ExteraAISettingsViews.fill(self, child: content, insets: UIEdgeInsets(top: 16, left: 18, bottom: 16, right: 18))
        self.updateValue()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateValue() {
        let value = (Double(self.slider.value) * 10).rounded() / 10
        self.current.text = String(format: "%.1f", value)
        self.slider.accessibilityValue = self.current.text
    }

    func setValue(_ value: Double) {
        self.slider.value = Float(value)
        self.updateValue()
    }

    @objc private func changed() {
        self.slider.value = (self.slider.value * 10).rounded() / 10
        self.updateValue()
        // VoiceOver adjusts a slider without a touch-up gesture.
        if !self.slider.isTracking { self.finished() }
    }

    @objc private func finished() {
        let value = min(2, max(0, (Double(self.slider.value) * 10).rounded() / 10))
        self.slider.value = Float(value)
        self.updateValue()
        self.commit?(value)
    }
}

/// A quiet robot silhouette matching the reference hero without external assets.
final class ExteraAIRobotView: UIView {
    var color: UIColor = .gray { didSet { self.setNeedsDisplay() } }
    override init(frame: CGRect) { super.init(frame: frame); self.backgroundColor = .clear; self.isAccessibilityElement = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.translateBy(x: (rect.width - 80) / 2, y: (rect.height - 80) / 2)
        self.color.setFill()
        UIBezierPath(roundedRect: CGRect(x: 11, y: 23, width: 58, height: 42), cornerRadius: 13).fill()
        UIBezierPath(roundedRect: CGRect(x: 1, y: 35, width: 7, height: 18), cornerRadius: 3).fill()
        UIBezierPath(roundedRect: CGRect(x: 72, y: 35, width: 7, height: 18), cornerRadius: 3).fill()
        UIBezierPath(roundedRect: CGRect(x: 38, y: 12, width: 4, height: 15), cornerRadius: 2).fill()
        UIBezierPath(ovalIn: CGRect(x: 35, y: 6, width: 10, height: 10)).fill()
        context.setBlendMode(.clear)
        UIBezierPath(ovalIn: CGRect(x: 25, y: 36, width: 8, height: 8)).fill()
        UIBezierPath(ovalIn: CGRect(x: 47, y: 36, width: 8, height: 8)).fill()
        UIBezierPath(roundedRect: CGRect(x: 29, y: 51, width: 22, height: 4), cornerRadius: 2).fill()
        context.restoreGState()
    }
}

enum ExteraAISettingsViews {
    static func label(_ text: String, theme: PresentationTheme, style: UIFont.TextStyle = .body, secondary: Bool = false) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = secondary ? theme.list.itemSecondaryTextColor : theme.list.itemPrimaryTextColor
        return label
    }

    static func fill(_ parent: UIView, child: UIView, insets: UIEdgeInsets = .zero) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom)
        ])
    }

    static func padded(_ child: UIView, vertical: CGFloat = 12) -> UIView {
        let parent = UIView()
        self.fill(parent, child: child, insets: UIEdgeInsets(top: vertical, left: 16, bottom: vertical, right: 16))
        return parent
    }

    static func card(_ rows: [UIView], theme: PresentationTheme) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        for (index, row) in rows.enumerated() {
            if index != 0 {
                let line = UIView()
                line.backgroundColor = theme.list.itemBlocksSeparatorColor
                line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                stack.addArrangedSubview(self.padded(line, vertical: 0))
            }
            stack.addArrangedSubview(row)
        }
        stack.backgroundColor = theme.list.itemBlocksBackgroundColor
        stack.layer.cornerRadius = 22
        stack.clipsToBounds = true
        return stack
    }

    static func action(title: String, value: String, symbol: String, theme: PresentationTheme, action: @escaping () -> Void) -> UIView {
        let button = ExteraAISettingsButton()
        button.action = action
        button.accessibilityLabel = title
        button.accessibilityValue = value
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.tintColor = theme.list.itemSecondaryTextColor
        icon.contentMode = .scaleAspectFit
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let name = self.label(title, theme: theme)
        let detail = self.label(value, theme: theme)
        detail.textColor = theme.list.itemAccentColor
        detail.textAlignment = .right
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, name, detail])
        row.alignment = .center
        row.spacing = 12
        row.isUserInteractionEnabled = false
        self.fill(button, child: self.padded(row, vertical: 15))
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        return button
    }

    static func toggle(title: String, subtitle: String? = nil, value: Bool, theme: PresentationTheme, update: @escaping (Bool) -> Void) -> UIView {
        let column = UIStackView(arrangedSubviews: [self.label(title, theme: theme)])
        column.axis = .vertical
        column.spacing = 4
        if let subtitle { column.addArrangedSubview(self.label(subtitle, theme: theme, style: .footnote, secondary: true)) }
        let control = ExteraAISettingsSwitch(value: value, update: update)
        control.accessibilityLabel = title
        control.accessibilityHint = subtitle
        control.onTintColor = theme.list.itemAccentColor
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [column, control])
        row.spacing = 12
        row.alignment = .center
        return self.padded(row, vertical: 15)
    }
}
