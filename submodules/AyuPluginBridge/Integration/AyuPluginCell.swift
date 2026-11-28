import UIKit

/// The list of exteraGram's `PluginsActivity`: pinned plugins first, each group by name. A search
/// query keeps the plugins whose name contains it, ignoring case.
enum AyuPluginListOrder {
    static func arrange(_ plugins: [AyuInstalledPlugin], pinned: Set<String>, query: String? = nil) -> [AyuInstalledPlugin] {
        let needle = (query ?? "").lowercased()
        let visible = needle.isEmpty ? plugins : plugins.filter { $0.name.lowercased().contains(needle) }
        return visible.sorted { left, right in
            let leftPinned = pinned.contains(left.id), rightPinned = pinned.contains(right.id)
            if leftPinned != rightPinned { return leftPinned }
            return left.name != right.name ? left.name < right.name : left.id < right.id
        }
    }
}

/// Pinned plugin ids (Android `pinnedPlugins`). A pin is a list preference only: it never
/// enables, loads or authorizes a plugin. As on Android, deleting a plugin keeps its pin, so a
/// plugin installed again returns to the top.
@MainActor final class AyuPluginPins {
    static let key = "AyuPluginBridge.pinnedPlugins"
    private let defaults: UserDefaults
    private(set) var ids: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.ids = Set((defaults.stringArray(forKey: Self.key) ?? []).prefix(AyuPluginCapacity.maximumInstalledPlugins))
    }

    func contains(_ id: String) -> Bool { self.ids.contains(id) }

    /// Returns the new state. A full table refuses a further pin.
    @discardableResult func toggle(_ id: String) -> Bool {
        if self.ids.remove(id) == nil {
            guard self.ids.count < AyuPluginCapacity.maximumInstalledPlugins else { return false }
            self.ids.insert(id)
        }
        self.save()
        return self.ids.contains(id)
    }

    private func save() {
        if self.ids.isEmpty { self.defaults.removeObject(forKey: Self.key) }
        else { self.defaults.set(self.ids.sorted(), forKey: Self.key) }
    }
}

/// A plugin's `__icon__ = "Pack/N"`: document N of the sticker set with the short name `Pack`.
/// The pattern is Android's (`Plugin.setIcon`), with the index bounded to nine digits.
struct AyuPluginIconReference: Hashable {
    let pack: String
    let index: Int

    init?(_ icon: String?) {
        guard let icon, let slash = icon.utf8.lastIndex(of: UInt8(ascii: "/")) else { return nil }
        let pack = icon.utf8[..<slash], digits = icon.utf8[icon.utf8.index(after: slash)...]
        func letter(_ byte: UInt8) -> Bool { (97...122).contains(byte | 0x20) }
        func digit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
        guard let first = pack.first, letter(first), pack.allSatisfy({ letter($0) || digit($0) || $0 == UInt8(ascii: "_") }),
              (1...9).contains(digits.count), digits.allSatisfy(digit),
              let index = Int(String(decoding: digits, as: UTF8.self)) else { return nil }
        self.pack = String(decoding: pack, as: UTF8.self)
        self.index = index
    }
}

/// One plugin as a card, after exteraGram's `PluginCell`: the icon, name, version and author,
/// description (or the error in red), requirement chips, then share / open in / pin / settings on the left,
/// delete on the right and the switch at the top. The cell only reports what was pressed; consent
/// and every operation stay with the screen that owns it.
///
/// The icon is a slot only: the bridge has no Telegram media, so the screen hands the picture in.
/// Added for iOS: the line saying a plugin is unsupported or busy, and a
/// selection mark for the batch mode. Unlike Android, an error does not hide the switch, because
/// here an enabled plugin can carry a non-fatal error and must stay switchable.
final class AyuPluginCell: UITableViewCell {
    enum Action { case toggle, share, openIn, pin, settings, delete, copyError }
    /// `pending` keeps the slot empty, as Android does until the sticker arrives or when it never does.
    enum Icon { case none, pending, image(UIImage, player: IconPlayer? = nil) }
    /// Makes a view that plays the icon in a loop, as Android's `BackupImageView` does, and calls
    /// `started` once it draws; nil for a picture that does not move. Each card gets its own view.
    typealias IconPlayer = @MainActor (_ started: @escaping @MainActor () -> Void) -> UIView?
    static let reuseIdentifier = "AyuPluginCell"
    static let iconIdentifier = "AyuPluginCell.icon"
    /// The switch lies over the top right corner; text beside it keeps clear of it.
    private static let switchSize = CGSize(width: 51, height: 31)
    private static let switchClearance: CGFloat = 63
    /// Android `pluginsCompactView`.
    static let compactKey = "AyuPluginBridge.pluginsCompactView"
    private static let inset: CGFloat = 16

    var onAction: ((Action) -> Void)?

    private let card = UIView()
    private let iconView = UIImageView()
    private let lead = UIStackView()
    private let titles = UIStackView()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let statusLabel = UILabel()
    private let chips = AyuPluginChipsView()
    private let separator = UIView()
    private let toggleControl = UIControl()
    private let toggle = UISwitch()
    private let selectionMark = UIImageView()
    private let shareButton = AyuPluginCellButton(symbol: "square.and.arrow.up", label: "Поделиться")
    private let openInButton = AyuPluginCellButton(symbol: "arrow.up.forward.square", label: "Открыть в…")
    private let pinButton = AyuPluginCellButton(symbol: "pin", label: "Закрепить")
    private let settingsButton = AyuPluginCellButton(symbol: "gearshape", label: "Настройки плагина")
    private let deleteButton = AyuPluginCellButton(symbol: "trash", label: "Удалить плагин", destructive: true)
    private var chipsHeight: NSLayoutConstraint?
    private var separatorHeight: NSLayoutConstraint?
    private var iconSide: [NSLayoutConstraint] = []
    private var pluginID: String?

    static func subtitle(for plugin: AyuInstalledPlugin, compact: Bool = false) -> String {
        let author = (plugin.author ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (compact ? "v" : "Версия ") + plugin.version + (author.isEmpty ? "" : " • " + author)
    }

    /// The iOS-only line under the description: why the switch is missing or disabled.
    static func statusNote(for plugin: AyuInstalledPlugin) -> String? {
        if plugin.isBusy { return plugin.status }
        if !plugin.blockers.isEmpty && !plugin.isEnabled { return plugin.status + " · ограничений: \(plugin.blockers.count)" }
        return nil
    }

    static func showsSwitch(for plugin: AyuInstalledPlugin) -> Bool { plugin.isEnabled || plugin.blockers.isEmpty }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        self.backgroundConfiguration = .clear()
        self.selectionStyle = .none
        // Cards are separated by their own spacing, not by the table's hairline.
        self.separatorInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: .greatestFiniteMagnitude)

        self.card.backgroundColor = .secondarySystemGroupedBackground
        self.card.layer.cornerRadius = 16
        self.card.layer.cornerCurve = .continuous

        self.nameLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 18, weight: .bold))
        self.nameLabel.numberOfLines = 3
        self.subtitleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14))
        self.subtitleLabel.textColor = .secondaryLabel
        self.subtitleLabel.numberOfLines = 2
        self.descriptionLabel.numberOfLines = 0
        self.descriptionLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.errorPressed)))
        self.statusLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13))
        self.statusLabel.numberOfLines = 0
        for label in [self.nameLabel, self.subtitleLabel, self.descriptionLabel, self.statusLabel] { label.adjustsFontForContentSizeCategory = true }
        self.separator.backgroundColor = .separator

        self.toggle.isUserInteractionEnabled = false
        self.selectionMark.contentMode = .center
        self.selectionMark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        for view in [self.toggle, self.selectionMark] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.toggleControl.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: self.toggleControl.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: self.toggleControl.centerYAnchor)
            ])
        }
        // The switch shows state only: it changes after the operation succeeded, as on Android.
        self.toggleControl.addTarget(self, action: #selector(self.togglePressed), for: .touchUpInside)
        self.toggleControl.isAccessibilityElement = true

        self.iconView.contentMode = .scaleAspectFit
        self.iconView.clipsToBounds = true
        self.iconView.layer.cornerRadius = 8
        self.iconView.layer.cornerCurve = .continuous
        self.iconView.accessibilityIdentifier = Self.iconIdentifier
        self.iconView.isHidden = true

        for label in [self.nameLabel, self.subtitleLabel] { self.titles.addArrangedSubview(label) }
        self.titles.axis = .vertical; self.titles.spacing = 2
        self.titles.isLayoutMarginsRelativeArrangement = true
        self.titles.directionalLayoutMargins = .zero
        for view in [self.iconView, self.titles] as [UIView] { self.lead.addArrangedSubview(view) }
        self.lead.axis = .vertical; self.lead.alignment = .leading; self.lead.spacing = 12

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = UIStackView(arrangedSubviews: [self.shareButton, self.openInButton, self.pinButton, self.settingsButton, spacer, self.deleteButton])
        buttons.spacing = 8
        self.shareButton.addTarget(self, action: #selector(self.sharePressed), for: .touchUpInside)
        self.openInButton.addTarget(self, action: #selector(self.openInPressed), for: .touchUpInside)
        self.pinButton.addTarget(self, action: #selector(self.pinPressed), for: .touchUpInside)
        self.settingsButton.addTarget(self, action: #selector(self.settingsPressed), for: .touchUpInside)
        self.deleteButton.addTarget(self, action: #selector(self.deletePressed), for: .touchUpInside)

        let content = UIStackView(arrangedSubviews: [self.lead, self.descriptionLabel, self.statusLabel, self.chips, self.separator, buttons])
        content.axis = .vertical; content.spacing = 12
        content.setCustomSpacing(8, after: self.separator)

        self.card.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        self.toggleControl.translatesAutoresizingMaskIntoConstraints = false
        self.contentView.addSubview(self.card)
        self.card.addSubview(content)
        self.card.addSubview(self.toggleControl)
        // Below required: a hidden arranged subview is collapsed by the stack, and the table
        // imposes its own height while a cell is being measured.
        let chipsHeight = self.chips.heightAnchor.constraint(equalToConstant: 0)
        let separatorHeight = self.separator.heightAnchor.constraint(equalToConstant: 0.5)
        let cardBottom = self.card.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -4)
        self.iconSide = [self.iconView.widthAnchor.constraint(equalToConstant: 56), self.iconView.heightAnchor.constraint(equalToConstant: 56)]
        let softened = [chipsHeight, separatorHeight, cardBottom] + self.iconSide
        softened.forEach { $0.priority = UILayoutPriority(999) }
        self.chipsHeight = chipsHeight; self.separatorHeight = separatorHeight
        NSLayoutConstraint.activate(softened + [
            self.toggleControl.topAnchor.constraint(equalTo: content.topAnchor),
            self.toggleControl.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            self.toggleControl.widthAnchor.constraint(equalToConstant: Self.switchSize.width),
            self.toggleControl.heightAnchor.constraint(equalToConstant: Self.switchSize.height),
            self.card.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 4),
            self.card.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor),
            self.card.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: self.card.topAnchor, constant: Self.inset),
            content.leadingAnchor.constraint(equalTo: self.card.leadingAnchor, constant: Self.inset),
            content.trailingAnchor.constraint(equalTo: self.card.trailingAnchor, constant: -Self.inset),
            content.bottomAnchor.constraint(equalTo: self.card.bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    /// `selected` is nil outside the batch mode; `locked` disables every control while a batch runs.
    /// `compact` is Android's compact view: one-line name and "vX • author" beside a 49 pt icon,
    /// instead of under a 56 pt one.
    func configure(_ plugin: AyuInstalledPlugin, pinned: Bool, selected: Bool? = nil, locked: Bool = false, compact: Bool = false, icon: Icon = .none) {
        let animated = self.pluginID == plugin.id && self.window != nil
        let showsIcon: Bool
        switch icon {
        case .none: showsIcon = false; self.iconView.image = nil; self.stopPlayer()
        case .pending: showsIcon = true; self.iconView.image = nil; self.stopPlayer()
        case let .image(image, player):
            showsIcon = true
            self.play(image, with: player)
            if self.player?.started == true {
                self.iconView.image = nil
            } else if animated && self.iconView.image == nil && !self.iconView.isHidden {
                UIView.transition(with: self.iconView, duration: 0.2, options: .transitionCrossDissolve) { self.iconView.image = image }
            } else { self.iconView.image = image }
        }
        self.iconView.isHidden = !showsIcon
        self.iconSide.forEach { $0.constant = compact ? 49 : 56 }
        let beside = showsIcon && compact
        self.lead.axis = beside ? .horizontal : .vertical
        self.lead.alignment = beside ? .center : .leading
        self.lead.spacing = beside ? 16 : 12
        self.pluginID = plugin.id
        let idle = !plugin.isBusy && !locked
        self.nameLabel.text = plugin.name
        self.nameLabel.numberOfLines = compact ? 1 : 3
        self.subtitleLabel.text = Self.subtitle(for: plugin, compact: compact)
        self.subtitleLabel.numberOfLines = compact ? 1 : 2

        if let error = plugin.error, !error.isEmpty {
            self.descriptionLabel.text = String(error.prefix(512))
            self.descriptionLabel.textColor = .systemRed
            self.descriptionLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedSystemFont(ofSize: 12, weight: .regular))
            self.descriptionLabel.isUserInteractionEnabled = true
            self.descriptionLabel.accessibilityHint = "Нажмите, чтобы скопировать текст ошибки"
            self.descriptionLabel.isHidden = false
        } else {
            let description = (plugin.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.descriptionLabel.text = description
            self.descriptionLabel.textColor = .label
            self.descriptionLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 15))
            self.descriptionLabel.isUserInteractionEnabled = false
            self.descriptionLabel.accessibilityHint = nil
            self.descriptionLabel.isHidden = description.isEmpty
        }

        let note = Self.statusNote(for: plugin)
        self.statusLabel.text = note
        self.statusLabel.textColor = plugin.isBusy ? .secondaryLabel : .systemOrange
        self.statusLabel.isHidden = note == nil

        self.chips.set(plugin.requirements ?? [])
        self.chips.isHidden = self.chips.isEmpty

        let showsSwitch = selected == nil && Self.showsSwitch(for: plugin)
        self.toggle.isHidden = !showsSwitch
        self.toggle.setOn(plugin.isEnabled, animated: animated && showsSwitch)
        self.toggle.isEnabled = idle
        self.selectionMark.isHidden = selected == nil
        self.selectionMark.image = UIImage(systemName: selected == true ? "checkmark.circle.fill" : "circle")
        self.selectionMark.tintColor = selected == true ? .systemBlue : .tertiaryLabel
        self.toggleControl.isHidden = !showsSwitch && selected == nil
        // Under a 56 pt icon the text has the whole width: the switch is beside the icon.
        self.titles.directionalLayoutMargins.trailing = !self.toggleControl.isHidden && (compact || !showsIcon) ? Self.switchClearance : 0
        self.toggleControl.isUserInteractionEnabled = showsSwitch && idle
        self.toggleControl.accessibilityLabel = plugin.name
        self.toggleControl.accessibilityValue = selected.map { $0 ? "выбран" : "не выбран" } ?? (plugin.isEnabled ? "включён" : "выключен")
        self.toggleControl.accessibilityTraits = showsSwitch ? (idle ? .button : [.button, .notEnabled]) : .staticText

        self.pinButton.set(symbol: pinned ? "pin.slash" : "pin", label: pinned ? "Открепить" : "Закрепить")
        // Android shows this only for a plugin that registered settings. Here the only way to
        // know is to ask the plugin for its rows, which revokes the callbacks of a settings page
        // that is open, so every enabled plugin gets the button and an empty page says so.
        self.settingsButton.isHidden = !plugin.isEnabled
        let actionable = idle && selected == nil
        for button in [self.shareButton, self.openInButton, self.pinButton, self.settingsButton, self.deleteButton] { button.isEnabled = actionable }
        self.card.alpha = plugin.isBusy ? 0.6 : 1
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.onAction = nil
        self.pluginID = nil
        self.stopPlayer()
    }

    /// The player lies in the icon view, which clips it to the rounded slot; `still` names the picture it plays.
    private var player: (view: UIView, still: UIImage, started: Bool)?

    private func play(_ still: UIImage, with make: IconPlayer?) {
        if make != nil, let player = self.player, player.still === still { return }
        self.stopPlayer()
        let started: @MainActor () -> Void = { [weak self] in
            guard let self, self.player?.still === still else { return }
            self.player?.started = true
            // The still picture would show through a moving one.
            self.iconView.image = nil
        }
        guard let view = make?(started) else { return }
        view.frame = self.iconView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        self.iconView.addSubview(view)
        self.player = (view, still, false)
    }

    private func stopPlayer() {
        self.player?.view.removeFromSuperview()
        self.player = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let scale = self.window?.screen.scale, scale > 0 { self.separatorHeight?.constant = 1 / scale }
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        let color: UIColor = highlighted ? .tertiarySystemGroupedBackground : .secondarySystemGroupedBackground
        if animated { UIView.animate(withDuration: 0.2) { self.card.backgroundColor = color } }
        else { self.card.backgroundColor = color }
    }

    /// The chips wrap, so their height depends on the width the table is about to give the row.
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority, verticalFittingPriority: UILayoutPriority) -> CGSize {
        self.chipsHeight?.constant = self.chips.isHidden ? 0 : self.chips.height(forWidth: max(0, targetSize.width - 2 * Self.inset))
        return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
    }

    @objc private func togglePressed() { self.onAction?(.toggle) }
    @objc private func sharePressed() { self.onAction?(.share) }
    @objc private func openInPressed() { self.onAction?(.openIn) }
    @objc private func pinPressed() { self.onAction?(.pin) }
    @objc private func settingsPressed() { self.onAction?(.settings) }
    @objc private func deletePressed() { self.onAction?(.delete) }
    @objc private func errorPressed() { self.onAction?(.copyError) }
}

/// A 40 pt round icon button that shrinks while pressed and springs back, as `PluginCell.createButton`.
private final class AyuPluginCellButton: UIButton {
    private let destructive: Bool

    init(symbol: String, label: String, destructive: Bool = false) {
        self.destructive = destructive
        super.init(frame: .zero)
        self.tintColor = destructive ? .systemRed : .secondaryLabel
        self.layer.cornerRadius = 20
        self.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 18, weight: .regular), forImageIn: .normal)
        self.set(symbol: symbol, label: label)
        let size = [self.widthAnchor.constraint(equalToConstant: 40), self.heightAnchor.constraint(equalToConstant: 40)]
        size.forEach { $0.priority = UILayoutPriority(999) }
        NSLayoutConstraint.activate(size)
    }

    required init?(coder: NSCoder) { return nil }

    func set(symbol: String, label: String) {
        self.setImage(UIImage(systemName: symbol), for: .normal)
        self.accessibilityLabel = label
    }

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != self.isHighlighted else { return }
            let pressed = self.isHighlighted
            let tint: UIColor = self.destructive ? .systemRed : .secondaryLabel
            UIView.animate(withDuration: pressed ? 0.08 : 0.35, delay: 0, usingSpringWithDamping: pressed ? 1 : 0.5, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = pressed ? CGAffineTransform(scaleX: 0.85, y: 0.85) : .identity
                self.backgroundColor = pressed ? tint.withAlphaComponent(0.12) : .clear
            }
        }
    }
}

/// A wrapping row of requirement chips (`PluginRequirementsView`). Chips are labels only: Android
/// opens the package page on a tap, which this screen does not do.
final class AyuPluginChipsView: UIView {
    private static let spacing: CGFloat = 4
    private static let maximumChips = 16
    private var texts: [String] = []
    private var labels: [UILabel] = []

    var isEmpty: Bool { self.labels.isEmpty }

    func set(_ texts: [String]) {
        let texts = texts.prefix(Self.maximumChips).map { String($0.prefix(48)) }.filter { !$0.isEmpty }
        guard texts != self.texts else { return }
        self.texts = texts
        self.labels.forEach { $0.removeFromSuperview() }
        self.labels = texts.map { text in
            let label = AyuPluginChipLabel()
            label.text = text
            self.addSubview(label)
            return label
        }
        self.setNeedsLayout()
    }

    func height(forWidth width: CGFloat) -> CGFloat { self.arrange(width: width, apply: false) }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.arrange(width: self.bounds.width, apply: true)
    }

    @discardableResult private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for label in self.labels {
            var size = label.intrinsicContentSize
            size.width = min(size.width, width)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + Self.spacing; rowHeight = 0 }
            if apply { label.frame = CGRect(origin: CGPoint(x: x, y: y), size: size) }
            x += size.width + Self.spacing
            rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight
    }
}

private final class AyuPluginChipLabel: UILabel {
    private static let padding = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12))
        self.adjustsFontForContentSizeCategory = true
        self.textColor = .systemBlue
        self.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        self.layer.cornerRadius = 6
        self.layer.masksToBounds = true
        self.lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) { return nil }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: Self.padding)) }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: ceil(size.width) + Self.padding.left + Self.padding.right, height: ceil(size.height) + Self.padding.top + Self.padding.bottom)
    }
}

/// A short notice over the bottom of the list, after Android's bulletins: a line, an optional
/// second line and an optional button. Whoever shows it places it and takes it away.
final class AyuPluginBulletinView: UIView {
    private let onAction: (() -> Void)?

    /// Long enough to read the second line and reach the button when there is one.
    var duration: TimeInterval { self.onAction == nil ? 1.5 : 4 }

    init(text: String, detail: String? = nil, actionTitle: String? = nil, onAction: (() -> Void)? = nil) {
        self.onAction = actionTitle == nil ? nil : onAction
        super.init(frame: .zero)
        self.backgroundColor = UIColor.label.withAlphaComponent(0.9)
        self.layer.cornerRadius = 12
        self.isUserInteractionEnabled = self.onAction != nil

        let title = UILabel()
        title.text = text; title.textColor = .systemBackground; title.numberOfLines = 2
        title.font = .preferredFont(forTextStyle: .subheadline)
        let texts = UIStackView(arrangedSubviews: [title])
        texts.axis = .vertical; texts.spacing = 2
        if let detail, !detail.isEmpty {
            let label = UILabel()
            label.text = detail; label.textColor = UIColor.systemBackground.withAlphaComponent(0.7); label.numberOfLines = 3
            label.font = .preferredFont(forTextStyle: .caption1)
            texts.addArrangedSubview(label)
        }
        let content = UIStackView(arrangedSubviews: [texts])
        content.alignment = .center; content.spacing = 12
        if let actionTitle, self.onAction != nil {
            let button = UIButton(type: .system)
            button.setTitle(actionTitle, for: .normal)
            button.titleLabel?.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.addTarget(self, action: #selector(self.actionPressed), for: .touchUpInside)
            content.addArrangedSubview(button)
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: self.topAnchor, constant: 10), content.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -10),
            content.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 16), content.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    @objc private func actionPressed() { self.onAction?() }
}

/// The placeholder row of an empty list or an empty search (`EmptyPluginsView`). Android offers the
/// plugin catalog here; iOS has no catalog, so the button imports a file instead.
final class AyuPluginEmptyCell: UITableViewCell {
    static let reuseIdentifier = "AyuPluginEmptyCell"
    static let pictureIdentifier = "AyuPluginEmptyCell.picture"
    /// Android's `EmptyPluginsView` picture is 100 dp; the glyph stands in the same box.
    private static let pictureSide: CGFloat = 100
    var onButton: (() -> Void)?

    private let pictureView = UIImageView()
    private let emojiLabel = UILabel()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let button = UIButton(configuration: .filled())

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        self.backgroundConfiguration = .clear()
        self.selectionStyle = .none
        self.separatorInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: .greatestFiniteMagnitude)

        self.emojiLabel.font = .systemFont(ofSize: 72)
        self.emojiLabel.isAccessibilityElement = false
        self.emojiLabel.textAlignment = .center
        self.pictureView.contentMode = .scaleAspectFit
        self.pictureView.accessibilityIdentifier = Self.pictureIdentifier
        self.pictureView.isHidden = true
        self.titleLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 20, weight: .bold))
        self.messageLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14))
        self.messageLabel.textColor = .secondaryLabel
        for label in [self.titleLabel, self.messageLabel] {
            label.numberOfLines = 0; label.textAlignment = .center; label.adjustsFontForContentSizeCategory = true
        }
        self.button.configuration?.cornerStyle = .capsule
        self.button.configuration?.buttonSize = .large
        self.button.addTarget(self, action: #selector(self.buttonPressed), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [self.pictureView, self.emojiLabel, self.titleLabel, self.messageLabel, self.button])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 8
        for view in [self.pictureView, self.emojiLabel] as [UIView] { stack.setCustomSpacing(20, after: view) }
        stack.setCustomSpacing(20, after: self.messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.contentView.addSubview(stack)
        let bottom = stack.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -32)
        let buttonWidth = self.button.widthAnchor.constraint(equalToConstant: 256)
        // The glyph and the picture take the same box, so the row keeps its height when one replaces the other.
        let art = [self.pictureView.widthAnchor, self.pictureView.heightAnchor, self.emojiLabel.heightAnchor].map { $0.constraint(equalToConstant: Self.pictureSide) }
        for constraint in [bottom, buttonWidth] + art { constraint.priority = UILayoutPriority(999) }
        NSLayoutConstraint.activate(art + [
            bottom, buttonWidth,
            stack.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 48),
            stack.centerXAnchor.constraint(equalTo: self.contentView.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: self.contentView.leadingAnchor, constant: 20),
            self.messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 272)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    /// `picture` is the sticker that stands for `emoji`; until the screen has it the glyph shows.
    /// `player` plays that sticker in a loop over the picture, as on the cards.
    func configure(emoji: String, picture: UIImage? = nil, player: AyuPluginCell.IconPlayer? = nil, title: String?, message: String, buttonTitle: String?) {
        self.emojiLabel.text = emoji
        self.setPicture(picture, player: player)
        self.titleLabel.text = title
        self.titleLabel.isHidden = title == nil
        self.messageLabel.text = message
        self.button.configuration?.title = buttonTitle
        self.button.isHidden = buttonTitle == nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.onButton = nil
        self.stopPlayer()
    }

    /// Puts a picture that arrived late in place of the glyph, if this cell still shows `emoji`.
    func show(_ picture: UIImage, player: AyuPluginCell.IconPlayer? = nil, for emoji: String) {
        guard self.emojiLabel.text == emoji else { return }
        self.setPicture(picture, player: player)
    }

    private var player: (view: UIView, still: UIImage, started: Bool)?

    private func setPicture(_ picture: UIImage?, player make: AyuPluginCell.IconPlayer?) {
        self.pictureView.isHidden = picture == nil
        self.emojiLabel.isHidden = picture != nil
        if make == nil || self.player?.still !== picture {
            self.stopPlayer()
            if let picture, let view = make?({ [weak self] in
                guard let self, self.player?.still === picture else { return }
                self.player?.started = true
                // The still picture would show through a moving one.
                self.pictureView.image = nil
            }) {
                view.frame = self.pictureView.bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.isUserInteractionEnabled = false
                self.pictureView.addSubview(view)
                self.player = (view, picture, false)
            }
        }
        self.pictureView.image = self.player?.started == true ? nil : picture
    }

    private func stopPlayer() {
        self.player?.view.removeFromSuperview()
        self.player = nil
    }

    @objc private func buttonPressed() { self.onButton?() }
}
