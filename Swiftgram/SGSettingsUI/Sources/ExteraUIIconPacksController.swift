import AccountContext
import Display
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramPresentationData
import UIKit

/// Built-in UI glyph picker (reference 30), separate from the home-screen icon picker.
public func exteraUIIconPacksController(context: AccountContext) -> ViewController {
    return ExteraUIIconPacksController(context: context)
}

private final class ExteraUIIconPackCell: UITableViewCell {
    private let preview = UIView()
    private let samples = (0 ..< 4).map { _ in UIImageView() }
    private let nameLabel = UILabel()
    private let authorLabel = UILabel()
    private let indicator = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let labels = UIStackView(arrangedSubviews: [self.nameLabel, self.authorLabel])
        labels.axis = .vertical
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        self.preview.translatesAutoresizingMaskIntoConstraints = false
        self.indicator.translatesAutoresizingMaskIntoConstraints = false
        for sample in self.samples {
            sample.contentMode = .scaleAspectFit
            sample.isAccessibilityElement = false
            self.preview.addSubview(sample)
        }
        self.indicator.contentMode = .scaleAspectFit
        self.nameLabel.font = UIFont.preferredFont(forTextStyle: .body)
        self.authorLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        for label in [self.nameLabel, self.authorLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        for view in [self.preview, labels, self.indicator] { self.contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            self.preview.leadingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.leadingAnchor),
            self.preview.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor),
            self.preview.widthAnchor.constraint(equalToConstant: 52),
            self.preview.heightAnchor.constraint(equalToConstant: 52),
            labels.leadingAnchor.constraint(equalTo: self.preview.trailingAnchor, constant: 16),
            labels.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 16),
            labels.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -16),
            self.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
            self.indicator.leadingAnchor.constraint(equalTo: labels.trailingAnchor, constant: 12),
            self.indicator.trailingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.trailingAnchor),
            self.indicator.centerYAnchor.constraint(equalTo: self.contentView.centerYAnchor),
            self.indicator.widthAnchor.constraint(equalToConstant: 24),
            self.indicator.heightAnchor.constraint(equalToConstant: 24)
        ])
        self.isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (index, sample) in self.samples.enumerated() {
            sample.frame = CGRect(x: CGFloat(index % 2) * 28, y: CGFloat(index / 2) * 28, width: 24, height: 24)
        }
    }

    func update(pack: ExteraUIIconPack, title: String, selected: Bool, theme: PresentationTheme) {
        let provider = ExteraUIIconProvider(pack: pack)
        let roles: [ExteraUIIconRole] = [.stickers, .link, .pin, .photo]
        let native = ["Chat/Context Menu/SaveSticker", "Chat/Context Menu/Link", "Chat/Context Menu/Pin", "Chat/Context Menu/Save"]
        let symbols = ["face.smiling", "link", "pin", "photo"]
        for (index, sample) in self.samples.enumerated() {
            sample.image = provider.image(for: roles[index], fallback: UIImage(bundleImageName: native[index]) ?? UIImage(systemName: symbols[index]))
            sample.tintColor = theme.list.itemSecondaryTextColor
        }
        self.nameLabel.text = title
        self.nameLabel.textColor = theme.list.itemPrimaryTextColor
        self.authorLabel.text = pack.author
        self.authorLabel.textColor = pack == .native ? theme.list.itemSecondaryTextColor : theme.list.itemAccentColor
        self.indicator.image = UIImage(systemName: selected ? "largecircle.fill.circle" : "circle")
        self.indicator.tintColor = selected ? theme.list.itemAccentColor : theme.list.itemSecondaryTextColor
        self.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.accessibilityLabel = title + ", " + pack.author
        self.accessibilityTraits = selected ? [.button, .selected] : [.button]
    }
}

private final class ExteraUIIconPacksController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var presentationDisposable: Disposable?
    private var observer: NSObjectProtocol?
    private var data: PresentationData { return self.context.sharedContext.currentPresentationData.with { $0 } }

    init(context: AccountContext) {
        self.context = context
        let data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)))
        self.title = self.text("Title", "Icon Packs", "Наборы иконок")
        self.observer = NotificationCenter.default.addObserver(forName: ExteraUIIconSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.table.reloadData()
        }
        self.presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.title = self.text("Title", "Icon Packs", "Наборы иконок")
            self.setNavigationBarPresentationData(NavigationBarPresentationData(theme: NavigationBarTheme(rootControllerTheme: data.theme), strings: NavigationBarStrings(presentationStrings: data.strings)), animated: false)
            self.updateTheme()
        })
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
        self.presentationDisposable?.dispose()
    }

    private func text(_ key: String, _ english: String, _ russian: String) -> String {
        let fullKey = "Extera.UIIcons." + key
        let language = self.data.strings.baseLanguageCode
        let value = i18n(fullKey, language)
        return value.isEmpty || value == fullKey ? (language.hasPrefix("ru") ? russian : english) : value
    }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode()
        self.displayNodeDidLoad()
        self.view.addSubview(self.table)
        self.table.register(ExteraUIIconPackCell.self, forCellReuseIdentifier: "pack")
        self.table.dataSource = self
        self.table.delegate = self
        self.table.rowHeight = UITableView.automaticDimension
        self.table.estimatedRowHeight = 88
        self.table.contentInsetAdjustmentBehavior = .never
        self.updateTheme()
    }

    private func updateTheme() {
        guard self.isNodeLoaded else { return }
        self.table.backgroundColor = self.data.theme.list.blocksBackgroundColor
        self.table.separatorColor = self.data.theme.list.itemBlocksSeparatorColor
        self.table.tintColor = self.data.theme.list.itemAccentColor
        self.table.reloadData()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let insets = layout.insets(options: [.input])
        self.table.frame = CGRect(origin: .zero, size: layout.size)
        self.table.contentInset = UIEdgeInsets(top: self.navigationLayout(layout: layout).navigationFrame.maxY, left: layout.safeInsets.left, bottom: insets.bottom, right: layout.safeInsets.right)
        self.table.scrollIndicatorInsets = self.table.contentInset
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return ExteraUIIconPack.allCases.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return self.text("BasePacks", "Base Packs", "Базовые наборы")
    }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return self.text("Info", "Used for supported icons throughout the app. Other icons keep their original appearance.", "Используется для поддерживаемых значков в приложении. Остальные значки сохраняют исходный вид.")
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "pack", for: indexPath) as! ExteraUIIconPackCell
        let pack = ExteraUIIconPack.allCases[indexPath.row]
        let title: String
        switch pack {
        case .native: title = self.text("Default", "Default", "По умолчанию")
        case .solar: title = "Solar Icon Set"
        case .remix: title = "Remix Icon"
        }
        cell.update(pack: pack, title: title, selected: ExteraUIIconSettings.shared.pack == pack, theme: self.data.theme)
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        ExteraUIIconSettings.shared.select(ExteraUIIconPack.allCases[indexPath.row])
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
