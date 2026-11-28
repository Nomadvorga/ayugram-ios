import AccountContext
import AppBundle
import Display
import Foundation
import SGStrings
import SwiftSignalKit
import TelegramPresentationData
import UIKit

func exteraSettingsOverviewController(context: AccountContext, ayu: Bool) -> ViewController {
    return ExteraSettingsOverviewController(context: context, ayu: ayu)
}

private final class ExteraOverviewRow: UIControl {
    let symbol = UIImageView()
    let titleLabel = UILabel()
    let valueLabel = UILabel()
    let separator = UIView()
    var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isAccessibilityElement = true
        self.accessibilityTraits = .button
        self.symbol.contentMode = .scaleAspectFit
        self.titleLabel.numberOfLines = 0
        self.valueLabel.numberOfLines = 0
        self.valueLabel.textAlignment = .right
        for view in [self.symbol, self.titleLabel, self.valueLabel, self.separator] { self.addSubview(view) }
        self.addTarget(self, action: #selector(self.activate), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { self.action?() }
    override var isHighlighted: Bool { didSet { self.alpha = self.isHighlighted ? 0.6 : 1.0 } }

    func height(width: CGFloat) -> CGFloat {
        let available = max(1.0, width - 92.0)
        let valueWidth = self.valueLabel.text == nil ? 0.0 : available * 0.55
        return max(54.0, max(self.titleLabel.sizeThatFits(CGSize(width: max(1.0, available - valueWidth), height: .greatestFiniteMagnitude)).height,
            self.valueLabel.sizeThatFits(CGSize(width: max(1.0, valueWidth), height: .greatestFiniteMagnitude)).height) + 24.0)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let available = max(0.0, self.bounds.width - 92.0)
        let valueWidth = self.valueLabel.text == nil ? 0.0 : available * 0.55
        self.symbol.frame = CGRect(x: 22.0, y: (self.bounds.height - 25.0) * 0.5, width: 25.0, height: 25.0)
        self.titleLabel.frame = CGRect(x: 72.0, y: 10.0, width: max(0.0, available - valueWidth), height: max(0.0, self.bounds.height - 20.0))
        self.valueLabel.frame = CGRect(x: self.bounds.width - 20.0 - valueWidth, y: 10.0, width: valueWidth, height: max(0.0, self.bounds.height - 20.0))
        self.separator.frame = CGRect(x: 72.0, y: self.bounds.height - 1.0 / UIScreen.main.scale, width: max(0.0, self.bounds.width - 72.0), height: 1.0 / UIScreen.main.scale)
    }
}

private final class ExteraSettingsOverviewController: ViewController {
    private let context: AccountContext
    private let ayu: Bool
    private var data: PresentationData
    private var disposable: Disposable?
    private var contentSizeObserver: NSObjectProtocol?
    private var validLayout: ContainerViewLayout?
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let nameLabel = UILabel()
    private let versionLabel = UILabel()
    private let categoriesLabel = UILabel()
    private let linksLabel = UILabel()
    private let categoriesPanel = UIView()
    private let linksPanel = UIView()
    private let backButton = UIButton(type: .custom)
    private let searchButton = UIButton(type: .custom)
    private let attributionButton = UIButton(type: .system)
    private var categoryRows: [ExteraOverviewRow] = []
    private var linkRows: [ExteraOverviewRow] = []

    init(context: AccountContext, ayu: Bool) {
        self.context = context
        self.ayu = ayu
        self.data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: nil)
        self.title = ayu ? "AyuGram" : "exteraGram"
        self.disposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.data = data
            if self.isNodeLoaded { self.updatePresentation() }
        })
        self.contentSizeObserver = NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main, using: { [weak self] _ in self?.updatePresentation() })
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        self.disposable?.dispose()
        if let observer = self.contentSizeObserver { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode()
        self.displayNodeDidLoad()
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.scrollView.alwaysBounceVertical = true
        self.displayNode.view.addSubview(self.scrollView)
        self.imageView.contentMode = .scaleAspectFit
        self.imageView.clipsToBounds = true
        self.imageView.image = UIImage(bundleImageName: self.ayu ? "AyuOverviewIcon" : "ExteraOverviewIcon")
        self.nameLabel.text = self.ayu ? "AyuGram" : "exteraGram"
        self.nameLabel.accessibilityTraits = .header
        for label in [self.nameLabel, self.versionLabel] { label.textAlignment = .center; label.numberOfLines = 0 }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        self.versionLabel.text = build.isEmpty ? version : "\(version) (\(build))"
        for view in [self.imageView, self.nameLabel, self.versionLabel, self.categoriesLabel, self.categoriesPanel, self.linksLabel, self.linksPanel] { self.scrollView.addSubview(view) }
        self.attributionButton.titleLabel?.numberOfLines = 0
        self.attributionButton.titleLabel?.textAlignment = .center
        self.attributionButton.addTarget(self, action: #selector(self.openAttribution), for: .touchUpInside)
        self.scrollView.addSubview(self.attributionButton)
        for panel in [self.categoriesPanel, self.linksPanel] { panel.layer.cornerRadius = 24.0; panel.clipsToBounds = true }
        for label in [self.categoriesLabel, self.linksLabel] { label.numberOfLines = 0; label.accessibilityTraits = .header }
        self.backButton.setImage(UIImage(systemName: "arrow.left"), for: .normal)
        self.backButton.addTarget(self, action: #selector(self.goBack), for: .touchUpInside)
        self.searchButton.setImage(UIImage(systemName: "magnifyingglass"), for: .normal)
        self.searchButton.addTarget(self, action: #selector(self.openSearch), for: .touchUpInside)
        self.searchButton.isHidden = self.ayu
        for button in [self.backButton, self.searchButton] { button.layer.cornerRadius = 24.0; self.displayNode.view.addSubview(button) }
        self.updatePresentation()
    }

    private func row(_ title: String, symbol: String, value: String? = nil, action: @escaping () -> Void) -> ExteraOverviewRow {
        let row = ExteraOverviewRow()
        row.titleLabel.text = title
        row.valueLabel.text = value
        row.symbol.image = UIImage(systemName: symbol)
        row.accessibilityLabel = title
        row.accessibilityValue = value
        row.action = action
        return row
    }

    private func updatePresentation() {
        guard self.isNodeLoaded else { return }
        let theme = self.data.theme
        let lang = self.data.strings.baseLanguageCode
        self.displayNode.backgroundColor = theme.list.blocksBackgroundColor
        self.nameLabel.textColor = theme.list.itemPrimaryTextColor
        self.versionLabel.textColor = theme.list.itemSecondaryTextColor
        self.nameLabel.font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: 23.0, weight: .semibold))
        self.versionLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16.0))
        self.categoriesLabel.text = i18n("Extera.Categories", lang)
        self.linksLabel.text = i18n("Extera.Overview.Links", lang)
        self.attributionButton.setTitle(i18n("Extera.Overview.Attribution", lang), for: .normal)
        self.attributionButton.setTitleColor(theme.list.itemAccentColor, for: .normal)
        self.attributionButton.titleLabel?.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13.0))
        for label in [self.categoriesLabel, self.linksLabel] {
            label.textColor = theme.list.itemAccentColor
            label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15.0, weight: .semibold))
        }
        for row in self.categoryRows + self.linkRows { row.removeFromSuperview() }
        if self.ayu {
            let categories: [(String, String, AyuSettingsCategory)] = [("Ayu.Overview.Ghost", "figure.walk", .ghost), ("Ayu.Overview.Spy", "eye", .spy), ("Ayu.Overview.Filters", "line.3.horizontal.decrease.circle", .filters), ("Ayu.Overview.Customization", "paintpalette", .customization)]
            self.categoryRows = categories.map { key, symbol, category in
                self.row(i18n(key, lang), symbol: symbol, action: { [weak self] in
                    guard let self else { return }
                    self.pushOverviewController(ayuSettingsController(context: self.context, category: category))
                })
            }
        } else {
            let categories: [(String, String, SGSettingsCategory)] = [("Ayu.CategoryGeneral", "square.grid.2x2", .general), ("Ayu.CategoryAppearance", "paintpalette", .appearance), ("Ayu.CategoryChats", "bubble.left", .chats), ("Ayu.CategoryOther", "star", .other)]
            self.categoryRows = categories.map { key, symbol, category in
                self.row(i18n(key, lang), symbol: symbol, action: { [weak self] in
                    guard let self else { return }
                    self.pushOverviewController(sgSettingsController(context: self.context, category: category))
                })
            }
        }
        let links: [(String, String, String, String)] = [
            ("Channel", "megaphone", self.ayu ? "@ayugram" : "@exteraGram", self.ayu ? "https://t.me/ayugram" : "https://t.me/exteraGram"),
            ("Chats", "person.2", self.ayu ? "@ayugramchat" : "@exteraForum", self.ayu ? "https://t.me/ayugramchat" : "https://t.me/exteraForum"),
            ("Translation", "character.bubble", "Crowdin", self.ayu ? "https://translate.ayugram.one" : "https://crowdin.com/project/exteralocales"),
            (self.ayu ? "Documentation" : "Website", "globe", self.ayu ? "ayugram.one" : "exteraGram.app", self.ayu ? "https://docs.ayugram.one" : "https://exteragram.app")
        ]
        self.linkRows = links.map { key, symbol, value, url in
            self.row(i18n("Extera.Overview.\(key)", lang), symbol: symbol, value: value, action: { [weak self] in
                guard let self else { return }
                self.context.sharedContext.openExternalUrl(context: self.context, urlContext: .generic, url: url, forceExternal: false, presentationData: self.data, navigationController: self.navigationController as? NavigationController, dismissInput: {})
            })
        }
        for (panel, rows) in [(self.categoriesPanel, self.categoryRows), (self.linksPanel, self.linkRows)] {
            panel.backgroundColor = theme.list.itemBlocksBackgroundColor
            for (index, row) in rows.enumerated() {
                row.titleLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17.0))
                row.valueLabel.font = row.titleLabel.font
                row.titleLabel.textColor = theme.list.itemPrimaryTextColor
                row.valueLabel.textColor = theme.list.itemAccentColor
                row.symbol.tintColor = theme.list.itemSecondaryTextColor
                row.separator.backgroundColor = theme.list.itemBlocksSeparatorColor
                row.separator.isHidden = index == rows.count - 1
                panel.addSubview(row)
            }
        }
        for button in [self.backButton, self.searchButton] { button.backgroundColor = theme.list.itemBlocksBackgroundColor; button.tintColor = theme.list.itemPrimaryTextColor }
        self.backButton.accessibilityLabel = self.data.strings.Common_Back
        self.searchButton.accessibilityLabel = self.data.strings.Common_Search
        self.updateLayout()
    }

    private func pushOverviewController(_ controller: ViewController) { (self.navigationController as? NavigationController)?.pushViewController(controller) }
    @objc private func goBack() { let _ = self.navigationController?.popViewController(animated: true) }
    @objc private func openSearch() { self.pushOverviewController(sgSettingsController(context: self.context, showOverview: false)) }
    @objc private func openAttribution() {
        self.context.sharedContext.openExternalUrl(context: self.context, urlContext: .generic, url: "https://github.com/exteraSquad/exteraGram", forceExternal: false, presentationData: self.data, navigationController: self.navigationController as? NavigationController, dismissInput: {})
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.validLayout = layout
        self.updateLayout()
    }
    private func updateLayout() {
        guard let layout = self.validLayout, self.isNodeLoaded else { return }
        let top = layout.insets(options: [.statusBar]).top
        let bottom = layout.insets(options: []).bottom
        let sides = layout.sideInsets(forBandFrom: top, to: layout.size.height - bottom)
        let width = max(0.0, min(600.0, layout.size.width - sides.left - sides.right))
        let x = sides.left + (layout.size.width - sides.left - sides.right - width) * 0.5
        let cardWidth = max(0.0, width - 26.0)
        self.scrollView.frame = CGRect(origin: .zero, size: layout.size)
        self.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: top + 60.0, left: 0.0, bottom: bottom, right: 0.0)
        self.backButton.frame = CGRect(x: sides.left + 13.0, y: top + 8.0, width: 48.0, height: 48.0)
        self.searchButton.frame = CGRect(x: layout.size.width - sides.right - 61.0, y: top + 8.0, width: 48.0, height: 48.0)
        self.imageView.frame = CGRect(x: x + (width - 78.0) * 0.5, y: top + 46.0, width: 78.0, height: 78.0)
        self.imageView.layer.cornerRadius = 22.0
        var y = self.imageView.frame.maxY + 20.0
        for label in [self.nameLabel, self.versionLabel] {
            let height = label.sizeThatFits(CGSize(width: cardWidth, height: .greatestFiniteMagnitude)).height
            label.frame = CGRect(x: x + 13.0, y: y, width: cardWidth, height: height)
            y += height + 7.0
        }
        y += 38.0
        for (label, panel, rows) in [(self.categoriesLabel, self.categoriesPanel, self.categoryRows), (self.linksLabel, self.linksPanel, self.linkRows)] {
            let labelHeight = label.sizeThatFits(CGSize(width: max(0.0, cardWidth - 26.0), height: .greatestFiniteMagnitude)).height
            label.frame = CGRect(x: x + 26.0, y: y, width: max(0.0, cardWidth - 26.0), height: labelHeight)
            y += labelHeight + 13.0
            var rowY: CGFloat = 0.0
            for row in rows { let height = row.height(width: cardWidth); row.frame = CGRect(x: 0.0, y: rowY, width: cardWidth, height: height); rowY += height }
            panel.frame = CGRect(x: x + 13.0, y: y, width: cardWidth, height: rowY)
            y += rowY + 30.0
        }
        let attributionHeight = max(44.0, self.attributionButton.sizeThatFits(CGSize(width: cardWidth, height: .greatestFiniteMagnitude)).height)
        self.attributionButton.frame = CGRect(x: x + 13.0, y: y, width: cardWidth, height: attributionHeight)
        self.scrollView.contentSize = CGSize(width: layout.size.width, height: y + attributionHeight + 20.0 + bottom)
    }
}
