import AccountContext
import AppBundle
import Display
import Foundation
import SGStrings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

/// A preview and confirmation screen for the icons actually exposed by the iOS application bindings.
public func exteraAppIconController(context: AccountContext) -> ViewController {
    return ExteraAppIconController(context: context)
}

private struct ExteraAppIconEntry {
    let icon: PresentationAppIcon
    let image: UIImage
}

private struct ExteraAppIconMetadata: Decodable {
    let name: String
    let family: String
    let title: String
    let titleKey: String?
    let description: String?
    let author: String?
    let heroColor: String
    let seasonal: Bool
}

private final class ExteraAppIconCell: UIControl {
    let imageView = UIImageView()
    let titleLabel = UILabel()
    private let checkView = UIView()
    private let check = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isAccessibilityElement = true
        self.layer.cornerRadius = 18.0
        self.imageView.contentMode = .scaleAspectFit
        self.imageView.clipsToBounds = true
        self.titleLabel.textAlignment = .center
        self.titleLabel.numberOfLines = 2
        self.titleLabel.font = UIFont.systemFont(ofSize: 14.0)
        self.checkView.isUserInteractionEnabled = false
        self.checkView.layer.cornerRadius = 11.0
        self.check.fillColor = nil
        self.check.strokeColor = UIColor.white.cgColor
        self.check.lineWidth = 2.5
        self.check.lineCap = .round
        self.check.lineJoin = .round
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 5.0, y: 11.0))
        path.addLine(to: CGPoint(x: 9.0, y: 15.0))
        path.addLine(to: CGPoint(x: 17.0, y: 7.0))
        self.check.path = path.cgPath
        self.checkView.layer.addSublayer(self.check)
        self.addSubview(self.imageView)
        self.addSubview(self.titleLabel)
        self.addSubview(self.checkView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(62.0, max(0.0, self.bounds.width - 34.0))
        let imageFrame = CGRect(x: floor((self.bounds.width - side) * 0.5), y: 14.0, width: side, height: side)
        self.imageView.frame = imageFrame
        self.imageView.layer.cornerRadius = side * 0.25
        self.titleLabel.frame = CGRect(x: 2.0, y: imageFrame.maxY + 10.0, width: max(0.0, self.bounds.width - 4.0), height: 32.0)
        self.checkView.frame = CGRect(x: imageFrame.maxX - 19.0, y: imageFrame.maxY - 19.0, width: 22.0, height: 22.0)
        self.check.frame = self.checkView.bounds
    }

    func update(title: String, selected: Bool, current: Bool, data: PresentationData, currentText: String) {
        self.titleLabel.text = title
        self.titleLabel.textColor = data.theme.list.itemPrimaryTextColor
        self.backgroundColor = selected ? data.theme.list.itemAccentColor.withAlphaComponent(0.10) : .clear
        self.checkView.backgroundColor = data.theme.list.itemAccentColor
        self.checkView.isHidden = !selected
        self.accessibilityLabel = title
        self.accessibilityValue = current ? currentText : nil
        self.accessibilityTraits = selected ? [.button, .selected] : [.button]
    }

    override var isHighlighted: Bool {
        didSet { self.alpha = self.isHighlighted ? 0.65 : 1.0 }
    }
}

private final class ExteraAppIconController: ViewController, UIScrollViewDelegate {
    private let context: AccountContext
    private var data: PresentationData
    private var entries: [ExteraAppIconEntry] = []
    private var visibleEntries: [ExteraAppIconEntry] = []
    private var metadata: [String: ExteraAppIconMetadata] = [:]
    private var selectedFamily = "ayu"
    private var familySelections: [String: String] = [:]
    // Selection is a draft. Only the application binding's completion can confirm a change.
    private var selectedName: String?
    private var currentName: String?
    private var applying = false
    private var presentationDisposable: Disposable?
    private var catalogDisposable: Disposable?
    private var foregroundDisposable: Disposable?
    private let entitlementDisposable = MetaDisposable()
    private var validLayout: ContainerViewLayout?
    private var heroHeight: CGFloat = 0.0
    private var toolbarBottom: CGFloat = 0.0
    private let scrollView = UIScrollView()
    private let heroView = UIView()
    private let heroGradient = CAGradientLayer()
    private let heroImage = UIImageView()
    private let heroTitle = UILabel()
    private let heroDescription = UILabel()
    private let panelView = UIView()
    private let emptyLabel = UILabel()
    private var cells: [ExteraAppIconCell] = []
    private let headerView = UIView()
    private let backButton = UIButton(type: .custom)
    private let compactImage = UIImageView()
    private let footerView = UIView()
    private let footerGradient = CAGradientLayer()
    private let selectButton = UIButton(type: .custom)
    private let familyControl = UISegmentedControl(items: ["AyuGram", "exteraGram"])
    private let activity = UIActivityIndicatorView(style: .medium)

    init(context: AccountContext) {
        self.context = context
        self.data = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: nil)
        self.title = self.data.strings.Appearance_AppIcon
        self.presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            self.data = data
            if self.isNodeLoaded { self.updatePresentation() }
        })
        self.foregroundDisposable = (context.sharedContext.applicationBindings.applicationIsActive
        |> distinctUntilChanged
        |> deliverOnMainQueue).start(next: { [weak self] active in
            guard let self, active, !self.applying, self.isNodeLoaded else { return }
            self.refreshCurrentIcon()
        })
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        self.presentationDisposable?.dispose()
        self.catalogDisposable?.dispose()
        self.foregroundDisposable?.dispose()
        self.entitlementDisposable.dispose()
    }

    private func text(_ key: String) -> String {
        return i18n("Extera.AppIcon.\(key)", self.data.strings.baseLanguageCode)
    }

    override func loadDisplayNode() {
        self.displayNode = ViewControllerTracingNode()
        self.displayNodeDidLoad()
        self.scrollView.delegate = self
        self.scrollView.contentInsetAdjustmentBehavior = .never
        self.scrollView.showsVerticalScrollIndicator = false
        self.scrollView.alwaysBounceVertical = true
        self.displayNode.view.addSubview(self.scrollView)
        self.heroView.layer.addSublayer(self.heroGradient)
        self.heroGradient.type = .radial
        self.heroGradient.startPoint = CGPoint(x: 0.5, y: 0.4)
        self.heroGradient.endPoint = CGPoint(x: 1.0, y: 1.0)
        self.heroView.isUserInteractionEnabled = false
        self.scrollView.addSubview(self.heroView)
        self.heroImage.contentMode = .scaleAspectFit
        self.heroImage.clipsToBounds = true
        self.heroView.addSubview(self.heroImage)
        self.heroTitle.font = UIFont.systemFont(ofSize: 24.0, weight: .bold)
        self.heroTitle.textAlignment = .center
        self.heroTitle.numberOfLines = 2
        self.heroTitle.accessibilityTraits = .header
        self.heroView.addSubview(self.heroTitle)
        self.heroDescription.font = UIFont.systemFont(ofSize: 16.0)
        self.heroDescription.textAlignment = .center
        self.heroDescription.numberOfLines = 2
        self.heroView.addSubview(self.heroDescription)
        self.panelView.layer.cornerRadius = 24.0
        self.panelView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        self.scrollView.addSubview(self.panelView)
        self.emptyLabel.numberOfLines = 0
        self.emptyLabel.textAlignment = .center
        self.emptyLabel.font = UIFont.systemFont(ofSize: 16.0)
        self.panelView.addSubview(self.emptyLabel)
        self.headerView.isUserInteractionEnabled = false
        self.displayNode.view.addSubview(self.headerView)
        self.compactImage.contentMode = .scaleAspectFit
        self.compactImage.clipsToBounds = true
        self.compactImage.layer.cornerRadius = 12.0
        self.compactImage.isAccessibilityElement = false
        self.displayNode.view.addSubview(self.compactImage)
        self.backButton.layer.cornerRadius = 24.0
        self.backButton.addTarget(self, action: #selector(self.goBack), for: .touchUpInside)
        self.displayNode.view.addSubview(self.backButton)
        self.footerView.layer.addSublayer(self.footerGradient)
        self.displayNode.view.addSubview(self.footerView)
        self.familyControl.addTarget(self, action: #selector(self.changeFamily), for: .valueChanged)
        self.familyControl.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 16.0, weight: .semibold)], for: .normal)
        self.footerView.addSubview(self.familyControl)
        self.selectButton.titleLabel?.font = UIFont.systemFont(ofSize: 17.0, weight: .semibold)
        self.selectButton.titleLabel?.adjustsFontSizeToFitWidth = true
        self.selectButton.titleLabel?.minimumScaleFactor = 0.7
        self.selectButton.setTitleColor(.white, for: .normal)
        self.selectButton.addTarget(self, action: #selector(self.confirmSelection), for: .touchUpInside)
        self.footerView.addSubview(self.selectButton)
        self.activity.hidesWhenStopped = true
        self.activity.color = .white
        self.activity.isUserInteractionEnabled = false
        self.selectButton.addSubview(self.activity)
        self.updatePresentation()
        self.loadCatalog()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if self.isNodeLoaded && !self.applying { self.refreshCurrentIcon() }
    }

    private func loadCatalog() {
        // As in ThemeSettingsController: bindings own availability, not names from the Android catalog.
        let appIcons: Signal<[PresentationAppIcon], NoError> = .single(self.context.sharedContext.applicationBindings.getAvailableAlternateIcons())
        self.catalogDisposable = (appIcons |> deliverOnMainQueue).start(next: { [weak self] icons in
            guard let self else { return }
            let bundle = getAppBundle()
            if let url = bundle.url(forResource: "ExteraAppIconCatalog", withExtension: "json"),
                let data = try? Data(contentsOf: url),
                let catalog = try? JSONDecoder().decode([ExteraAppIconMetadata].self, from: data) {
                self.metadata = Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            }
            let phoneIconInfo = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
            let tabletIconInfo = bundle.object(forInfoDictionaryKey: "CFBundleIcons~ipad") as? [String: Any]
            let iconInfo = UIDevice.current.userInterfaceIdiom == .pad ? (tabletIconInfo ?? phoneIconInfo) : phoneIconInfo
            let alternateIcons = iconInfo?["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
            var names = Set<String>()
            self.entries = icons.compactMap { icon in
                guard names.insert(icon.name).inserted,
                    icon.isDefault || alternateIcons[icon.name] != nil,
                    let image = UIImage(named: icon.imageName, in: bundle, compatibleWith: nil) else {
                    return nil
                }
                return ExteraAppIconEntry(icon: icon, image: image)
            }
            self.refreshCurrentIcon()
            self.selectedName = self.currentName ?? self.entries.first?.icon.name
            self.selectedFamily = self.selectedName.flatMap { self.metadata[$0]?.family } ?? "ayu"
            self.rebuildCells()
            self.updateSelection()
            self.updateContentLayout()
        })
    }

    private func refreshCurrentIcon() {
        let name = self.context.sharedContext.applicationBindings.getAlternateIconName()
        let previousName = self.currentName
        self.currentName = name ?? self.entries.first(where: { $0.icon.isDefault })?.icon.name
        // Follow external changes only while the user has not made a separate draft selection.
        if self.selectedName == nil || self.selectedName == previousName {
            self.selectedName = self.currentName
            if let name = self.selectedName, let family = self.metadata[name]?.family, family != self.selectedFamily {
                self.selectedFamily = family
                self.rebuildCells()
                self.updateContentLayout()
            }
        }
        self.updateSelection()
    }

    private func title(for icon: PresentationAppIcon) -> String {
        if icon.isDefault { return self.text("Default") }
        if let item = self.metadata[icon.name] {
            if let key = item.titleKey {
                return i18n(key, self.data.strings.baseLanguageCode)
            }
            return item.title
        }
        // Keep the established iOS names; do not relabel unrelated assets as Android artwork.
        switch icon.name {
        case "New1": return self.data.strings.Appearance_AppIconNew1
        case "New2": return self.data.strings.Appearance_AppIconNew2
        case "BlueClassicIcon": return self.data.strings.Appearance_AppIconClassic
        case "BlackClassicIcon": return self.data.strings.Appearance_AppIconClassicX
        case "BlueFilledIcon": return self.data.strings.Appearance_AppIconFilled
        case "BlackFilledIcon": return self.data.strings.Appearance_AppIconFilledX
        case "Premium": return self.data.strings.Appearance_AppIconPremium
        case "PremiumBlack": return self.data.strings.Appearance_AppIconBlack
        case "PremiumTurbo": return self.data.strings.Appearance_AppIconTurbo
        default: return icon.name
        }
    }

    private func updatePresentation() {
        let dark = self.data.theme.overallDarkAppearance
        let panel = dark ? UIColor(white: 0.095, alpha: 1.0) : self.data.theme.list.itemBlocksBackgroundColor
        let background = dark ? UIColor(red: 0.055, green: 0.035, blue: 0.085, alpha: 1.0) : self.data.theme.list.blocksBackgroundColor
        self.displayNode.backgroundColor = background
        self.panelView.backgroundColor = panel
        self.heroGradient.colors = [UIColor(red: 0.25, green: 0.12, blue: 0.35, alpha: dark ? 1.0 : 0.18).cgColor, background.cgColor]
        self.headerView.backgroundColor = background
        self.footerGradient.colors = [panel.withAlphaComponent(0.0).cgColor, panel.cgColor, panel.cgColor]
        self.footerGradient.locations = [0.0, 0.35, 1.0]
        self.heroTitle.textColor = self.data.theme.list.itemPrimaryTextColor
        self.heroDescription.textColor = self.data.theme.list.itemSecondaryTextColor
        self.emptyLabel.textColor = self.data.theme.list.itemSecondaryTextColor
        self.emptyLabel.text = self.text("Empty")
        self.backButton.backgroundColor = panel.withAlphaComponent(0.92)
        self.backButton.accessibilityLabel = self.data.strings.Common_Back
        self.backButton.setImage(self.backImage(color: self.data.theme.list.itemPrimaryTextColor), for: .normal)
        self.selectButton.backgroundColor = self.data.theme.list.itemAccentColor
        self.familyControl.backgroundColor = dark ? UIColor(white: 0.15, alpha: 1.0) : UIColor(white: 0.88, alpha: 1.0)
        self.familyControl.selectedSegmentTintColor = dark ? UIColor(white: 0.22, alpha: 1.0) : .white
        self.familyControl.setTitleTextAttributes([.foregroundColor: self.data.theme.list.itemSecondaryTextColor], for: .normal)
        self.familyControl.setTitleTextAttributes([.foregroundColor: self.data.theme.list.itemPrimaryTextColor], for: .selected)
        self.title = self.data.strings.Appearance_AppIcon
        self.setStatusBarStyle(dark ? .White : .Black, animated: false)
        self.updateSelection()
    }

    private func updateSelection() {
        guard self.isNodeLoaded else { return }
        let selected = self.entries.first(where: { $0.icon.name == self.selectedName })
        self.heroImage.image = selected?.image
        self.compactImage.image = selected?.image
        self.heroTitle.text = selected.map { self.title(for: $0.icon) }
        let item = selected.flatMap { self.metadata[$0.icon.name] }
        self.heroDescription.text = selected?.icon.isDefault == true ? nil : (item?.description ?? item?.author.map { "@\($0)" })
        if let hex = item?.heroColor.dropFirst(), let value = UInt32(hex, radix: 16) {
            let color = UIColor(red: CGFloat((value >> 16) & 255) / 255.0, green: CGFloat((value >> 8) & 255) / 255.0, blue: CGFloat(value & 255) / 255.0, alpha: self.data.theme.overallDarkAppearance ? 1.0 : 0.2)
            self.heroGradient.colors = [color.cgColor, self.displayNode.backgroundColor?.cgColor ?? UIColor.black.cgColor]
        }
        self.familyControl.isHidden = !self.hasBothFamilies
        self.familyControl.selectedSegmentIndex = self.selectedFamily == "extera" ? 1 : 0
        self.familyControl.isEnabled = !self.applying
        self.emptyLabel.isHidden = !self.entries.isEmpty
        for (index, cell) in self.cells.enumerated() {
            let entry = self.visibleEntries[index]
            cell.update(title: self.title(for: entry.icon), selected: entry.icon.name == self.selectedName, current: entry.icon.name == self.currentName, data: self.data, currentText: self.text("Current"))
            cell.isEnabled = !self.applying
        }
        self.selectButton.setTitle(self.applying ? nil : self.text(self.selectedName == self.currentName ? "KeepCurrent" : "Select"), for: .normal)
        self.selectButton.accessibilityLabel = self.text(self.selectedName == self.currentName ? "KeepCurrent" : "Select")
        self.selectButton.isEnabled = selected != nil && !self.applying
        self.selectButton.alpha = selected == nil ? 0.5 : 1.0
        if self.applying { self.activity.startAnimating() } else { self.activity.stopAnimating() }
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        self.validLayout = layout
        self.updateContentLayout()
    }

    private func updateContentLayout() {
        guard let layout = self.validLayout, self.isNodeLoaded else { return }
        let size = layout.size
        let top = layout.insets(options: [.statusBar]).top
        let bottom = layout.insets(options: []).bottom
        let side = layout.sideInsets(forBandFrom: top, to: size.height - bottom)
        let width = max(0.0, size.width - side.left - side.right)
        let contentWidth = min(width, 600.0)
        let contentX = side.left + (width - contentWidth) * 0.5
        self.toolbarBottom = top + 64.0
        self.heroHeight = self.toolbarBottom + 224.0
        self.scrollView.frame = CGRect(origin: .zero, size: size)
        self.heroView.frame = CGRect(x: 0.0, y: 0.0, width: size.width, height: self.heroHeight + 24.0)
        self.heroGradient.frame = self.heroView.bounds
        let imageSide = min(126.0, contentWidth * 0.31)
        self.heroImage.frame = CGRect(x: contentX + (contentWidth - imageSide) * 0.5, y: top + 40.0, width: imageSide, height: imageSide)
        self.heroImage.layer.cornerRadius = imageSide * 0.25
        self.heroTitle.frame = CGRect(x: contentX + 16.0, y: self.heroImage.frame.maxY + 18.0, width: max(0.0, contentWidth - 32.0), height: 48.0)
        let cellWidth = max(0.0, (contentWidth - 20.0) / 4.0)
        let rowHeight: CGFloat = min(62.0, max(0.0, cellWidth - 34.0)) + 62.0
        let rows = (self.visibleEntries.count + 3) / 4
        let footerExtra: CGFloat = self.hasBothFamilies ? 56.0 : 0.0
        let panelHeight = max(size.height - self.heroHeight, 20.0 + CGFloat(rows) * rowHeight + 110.0 + footerExtra)
        self.panelView.frame = CGRect(x: 0.0, y: self.heroHeight, width: size.width, height: max(180.0, panelHeight))
        for (index, cell) in self.cells.enumerated() {
            cell.frame = CGRect(x: contentX + 10.0 + CGFloat(index % 4) * cellWidth, y: 12.0 + CGFloat(index / 4) * rowHeight, width: cellWidth, height: rowHeight - 6.0)
        }
        self.emptyLabel.frame = CGRect(x: contentX + 24.0, y: 28.0, width: max(0.0, contentWidth - 48.0), height: 80.0)
        self.scrollView.contentSize = CGSize(width: size.width, height: self.panelView.frame.maxY)
        self.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: self.toolbarBottom, left: 0.0, bottom: bottom + 80.0, right: 0.0)
        self.headerView.frame = CGRect(x: 0.0, y: 0.0, width: size.width, height: self.toolbarBottom)
        self.backButton.frame = CGRect(x: side.left + 12.0, y: top + 8.0, width: 48.0, height: 48.0)
        self.compactImage.frame = CGRect(x: contentX + (contentWidth - 40.0) * 0.5, y: top + 12.0, width: 40.0, height: 40.0)
        let footerHeight = bottom + 88.0 + footerExtra
        self.footerView.frame = CGRect(x: 0.0, y: size.height - footerHeight, width: size.width, height: footerHeight)
        self.footerGradient.frame = self.footerView.bounds
        let buttonSide = layout.bottomEdgeSideInsets()
        let buttonWidth = min(600.0, max(0.0, size.width - buttonSide.left - buttonSide.right - 32.0))
        self.selectButton.frame = CGRect(x: buttonSide.left + (size.width - buttonSide.left - buttonSide.right - buttonWidth) * 0.5, y: 20.0 + footerExtra, width: buttonWidth, height: 50.0)
        let segmentWidth = min(220.0, max(0.0, contentWidth - 32.0))
        self.familyControl.frame = CGRect(x: contentX + (contentWidth - segmentWidth) * 0.5, y: 20.0, width: segmentWidth, height: 36.0)
        self.heroDescription.frame = CGRect(x: contentX + 16.0, y: self.heroTitle.frame.maxY, width: max(0.0, contentWidth - 32.0), height: 42.0)
        self.selectButton.layer.cornerRadius = 25.0
        self.activity.center = CGPoint(x: buttonWidth * 0.5, y: 25.0)
        self.updateScrollAppearance()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.updateScrollAppearance()
    }

    private func updateScrollAppearance() {
        let offset = max(0.0, self.scrollView.contentOffset.y)
        let distance = max(1.0, self.heroHeight - self.toolbarBottom)
        let progress = min(1.0, max(0.0, (offset - distance + 60.0) / 60.0))
        self.headerView.alpha = progress
        self.compactImage.alpha = progress
        self.heroImage.alpha = 1.0 - progress
        self.heroTitle.alpha = 1.0 - progress
        self.heroDescription.alpha = 1.0 - progress
    }

    @objc private func selectIcon(_ sender: ExteraAppIconCell) {
        guard !self.applying, self.visibleEntries.indices.contains(sender.tag) else { return }
        self.selectedName = self.visibleEntries[sender.tag].icon.name
        self.familySelections[self.selectedFamily] = self.selectedName
        self.updateSelection()
    }

    private var hasBothFamilies: Bool {
        return self.entries.contains(where: { self.metadata[$0.icon.name]?.family == "ayu" })
            && self.entries.contains(where: { self.metadata[$0.icon.name]?.family == "extera" })
    }

    private func rebuildCells() {
        let month = Calendar.current.component(.month, from: Date())
        let winter = month == 12 || month == 1 || month == 2
        self.visibleEntries = self.entries.filter { entry in
            guard let item = self.metadata[entry.icon.name] else { return !self.hasBothFamilies }
            return (!self.hasBothFamilies || item.family == self.selectedFamily)
                && (!item.seasonal || winter || entry.icon.name == self.currentName)
        }
        for cell in self.cells { cell.removeFromSuperview() }
        self.cells = self.visibleEntries.enumerated().map { index, entry in
            let cell = ExteraAppIconCell(frame: .zero)
            cell.tag = index
            cell.imageView.image = UIImage(named: entry.icon.name, in: getAppBundle(), compatibleWith: nil) ?? entry.image
            cell.addTarget(self, action: #selector(self.selectIcon(_:)), for: .touchUpInside)
            self.panelView.addSubview(cell)
            return cell
        }
    }

    @objc private func changeFamily() {
        guard !self.applying else { return }
        self.familySelections[self.selectedFamily] = self.selectedName
        self.selectedFamily = self.familyControl.selectedSegmentIndex == 1 ? "extera" : "ayu"
        self.rebuildCells()
        self.selectedName = self.familySelections[self.selectedFamily]
            ?? self.visibleEntries.first(where: { $0.icon.name == self.currentName })?.icon.name
            ?? self.visibleEntries.first?.icon.name
        self.updateSelection()
        self.updateContentLayout()
        self.scrollView.setContentOffset(.zero, animated: false)
    }

    @objc private func confirmSelection() {
        guard !self.applying, let entry = self.entries.first(where: { $0.icon.name == self.selectedName }) else { return }
        if entry.icon.name == self.currentName {
            self.goBack()
            return
        }
        self.applying = true
        self.updateSelection()
        // Preserve the existing premium check without importing or bypassing the app's presentation API.
        self.entitlementDisposable.set((self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId))
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self else { return }
            guard self.navigationController?.topViewController === self else {
                self.applying = false
                self.updateSelection()
                return
            }
            if entry.icon.isPremium && !(peer?.isPremium ?? false) {
                self.applying = false
                self.updateSelection()
                let controller = self.context.sharedContext.makePremiumIntroController(context: self.context, source: .appIcons, forceDark: false, dismissed: nil)
                self.pushIconController(controller)
                return
            }
            // The binding owns UIApplication and its callback chain, including extensions' behavior.
            self.context.sharedContext.applicationBindings.requestSetAlternateIconName(entry.icon.isDefault ? nil : entry.icon.name, { [weak self] success in
                Queue.mainQueue().async {
                    guard let self else { return }
                    self.applying = false
                    self.refreshCurrentIcon()
                    guard self.navigationController?.topViewController === self else { return }
                    if success {
                        self.selectedName = self.currentName
                        self.updateSelection()
                        self.goBack()
                    } else {
                        // The binding deliberately exposes Bool, so use a native, localized generic error.
                        let alert = UIAlertController(title: self.data.strings.Appearance_AppIcon, message: self.text("Error"), preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: self.data.strings.Common_OK, style: .default))
                        self.present(alert, animated: true)
                    }
                }
            })
        }))
    }

    private func pushIconController(_ controller: ViewController) {
        (self.navigationController as? NavigationController)?.pushViewController(controller)
    }

    @objc private func goBack() {
        guard let navigationController = self.navigationController as? NavigationController,
            navigationController.topViewController === self else { return }
        let _ = navigationController.popViewController(animated: true)
    }

    private func backImage(color: UIColor) -> UIImage {
        return UIGraphicsImageRenderer(size: CGSize(width: 24.0, height: 24.0)).image { _ in
            color.setStroke()
            let path = UIBezierPath()
            path.lineWidth = 2.0
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: CGPoint(x: 12.0, y: 5.0))
            path.addLine(to: CGPoint(x: 5.0, y: 12.0))
            path.addLine(to: CGPoint(x: 12.0, y: 19.0))
            path.move(to: CGPoint(x: 5.0, y: 12.0))
            path.addLine(to: CGPoint(x: 21.0, y: 12.0))
            path.stroke()
        }
    }
}
