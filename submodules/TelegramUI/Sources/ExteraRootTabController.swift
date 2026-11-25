import AccountContext
import Display
import Foundation
import SGSimpleSettings
import SGStrings
import TabBarUI
import TelegramPresentationData
import UIKit

struct ExteraNavigationMenuAction {
    let id: String
    let title: String
    let symbol: String
    var enabled: Bool = true
}

func exteraNavigationText(_ key: String, _ english: String, _ russian: String, language: String) -> String {
    let fullKey = "Extera.Navigation." + key
    let localized = i18n(fullKey, language)
    return localized.isEmpty || localized == fullKey ? (language.hasPrefix("ru") ? russian : english) : localized
}

private final class ExteraMenuButton: UIButton {
    var action: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { self.action?() }
}

/// Keeps the menu on the tab host: pushed chats retain their ordinary interactive Back gesture.
final class ExteraRootTabController: TabBarControllerImpl {
    var menuActions: () -> [ExteraNavigationMenuAction] = { [] }
    var performMenuAction: (String) -> Void = { _ in }
    private var configuration = ExteraNavigationSettings.shared.configuration
    private var menuItem: UIBarButtonItem!
    private var edgeGesture: UIScreenEdgePanGestureRecognizer?
    private var drawer: UIView?
    private var dismissDrawerImpl: (() -> Void)?
    private var lastLayout: ContainerViewLayout?
    private var menuTheme: PresentationTheme
    private var menuStrings: PresentationStrings
    private let fallbackMenuButton = ExteraMenuButton(frame: .zero)
    private weak var menuItemController: ViewController?
    private var iconPackObserver: NSObjectProtocol?

    override init(theme: PresentationTheme, strings: PresentationStrings) {
        self.menuTheme = theme
        self.menuStrings = strings
        super.init(theme: theme, strings: strings)
        self.menuItem = UIBarButtonItem(image: ExteraUIIconProvider.current.image(for: .menu, fallback: UIImage(systemName: "line.3.horizontal")), style: .plain, target: self, action: #selector(self.menuPressed))
        self.menuItem.accessibilityLabel = exteraNavigationText("Menu", "Navigation Menu", "Меню навигации", language: strings.baseLanguageCode)
        self.fallbackMenuButton.setImage(ExteraUIIconProvider.current.image(for: .menu, fallback: UIImage(systemName: "line.3.horizontal")), for: .normal)
        self.fallbackMenuButton.layer.cornerRadius = 22
        self.fallbackMenuButton.action = { [weak self] in self?.openNavigationMenu(sourceView: self?.fallbackMenuButton) }
        self.iconPackObserver = NotificationCenter.default.addObserver(forName: ExteraUIIconSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let image = ExteraUIIconProvider.current.image(for: .menu, fallback: UIImage(systemName: "line.3.horizontal"))
            self.menuItem.image = image
            self.fallbackMenuButton.setImage(image, for: .normal)
            self.dismissDrawerImpl?()
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let observer = self.iconPackObserver { NotificationCenter.default.removeObserver(observer) }
    }

    func updateNavigationConfiguration(_ configuration: ExteraNavigationSettings.Configuration, theme: PresentationTheme, strings: PresentationStrings) {
        self.configuration = configuration
        self.menuTheme = theme
        self.menuStrings = strings
        self.menuItem.accessibilityLabel = exteraNavigationText("Menu", "Navigation Menu", "Меню навигации", language: strings.baseLanguageCode)
        self.edgeGesture?.isEnabled = configuration.sidebar
        self.dismissDrawerImpl?()
        self.updateLayout()
    }

    override func loadDisplayNode() {
        super.loadDisplayNode()
        let gesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(self.edgePanned(_:)))
        gesture.edges = .left
        gesture.isEnabled = self.configuration.sidebar
        self.view.addGestureRecognizer(gesture)
        self.edgeGesture = gesture
        self.view.addSubview(self.fallbackMenuButton)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        if self.lastLayout?.size != layout.size { self.dismissDrawerImpl?() }
        self.lastLayout = layout
        // Some root pages draw a custom header instead of a UIKit navigation item. When the bar
        // is hidden, keep an accessible exit on those pages as well as the chat list's header menu.
        self.fallbackMenuButton.isHidden = self.configuration.barMode != .hide || self.currentController is ChatListController
        self.fallbackMenuButton.accessibilityLabel = self.menuItem.accessibilityLabel
        self.fallbackMenuButton.backgroundColor = self.menuTheme.list.itemBlocksBackgroundColor
        self.fallbackMenuButton.tintColor = self.menuTheme.list.itemAccentColor
        self.fallbackMenuButton.frame = CGRect(x: layout.size.width - layout.safeInsets.right - 56, y: layout.size.height - layout.safeInsets.bottom - 56, width: 44, height: 44)
        self.view.bringSubviewToFront(self.fallbackMenuButton)
        if let drawer = self.drawer { self.view.bringSubviewToFront(drawer) }
        if let controller = self.currentController {
            if let previous = self.menuItemController, previous !== controller {
                previous.navigationItem.rightBarButtonItems = previous.navigationItem.rightBarButtonItems?.filter { $0 !== self.menuItem }
            }
            self.menuItemController = controller
            var items = controller.navigationItem.rightBarButtonItems ?? []
            if !items.contains(where: { $0 === self.menuItem }) {
                items.append(self.menuItem)
                controller.navigationItem.rightBarButtonItems = items
            }
        }
    }

    @objc private func edgePanned(_ gesture: UIScreenEdgePanGestureRecognizer) {
        if gesture.state == .began { self.showDrawer() }
    }
    @objc private func menuPressed() { self.openNavigationMenu() }

    func openNavigationMenu(sourceView: UIView? = nil) {
        if self.configuration.sidebar { self.showDrawer(); return }
        let alert = UIAlertController(title: self.menuItem.accessibilityLabel, message: nil, preferredStyle: .actionSheet)
        for item in self.menuActions() where !ExteraNavigationSettings.Configuration.isDivider(item.id) {
            let action = UIAlertAction(title: item.title, style: .default, handler: { [weak self] _ in self?.performMenuAction(item.id) })
            action.isEnabled = item.enabled
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: self.menuStrings.Common_Cancel, style: .cancel))
        if let sourceView {
            alert.popoverPresentationController?.sourceView = sourceView
            alert.popoverPresentationController?.sourceRect = sourceView.bounds
        } else { alert.popoverPresentationController?.barButtonItem = self.menuItem }
        self.present(alert, animated: true)
    }

    private func showDrawer() {
        guard self.drawer == nil, let layout = self.lastLayout else { return }
        let overlay = UIView(frame: CGRect(origin: .zero, size: layout.size))
        overlay.accessibilityViewIsModal = true
        let backdrop = ExteraMenuButton(frame: overlay.bounds)
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        backdrop.accessibilityLabel = self.menuStrings.Common_Close
        overlay.addSubview(backdrop)
        let width = min(340.0, max(240.0, layout.size.width - 56.0))
        let panel = UIView(frame: CGRect(x: 0, y: 0, width: width, height: layout.size.height))
        panel.backgroundColor = self.menuTheme.list.blocksBackgroundColor
        overlay.addSubview(panel)
        let scroll = UIScrollView(frame: panel.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        panel.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: max(layout.statusBarHeight ?? 0, layout.safeInsets.top) + 12),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12 + layout.safeInsets.left),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -max(16, layout.safeInsets.bottom)),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24 - layout.safeInsets.left)
        ])
        for item in self.menuActions() {
            if ExteraNavigationSettings.Configuration.isDivider(item.id) {
                let divider = UIView()
                divider.backgroundColor = self.menuTheme.list.itemBlocksSeparatorColor
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(divider)
            } else {
                let button = ExteraMenuButton(frame: .zero)
                button.setTitle("  " + item.title, for: .normal)
                button.setTitleColor(self.menuTheme.list.itemPrimaryTextColor, for: .normal)
                button.setTitleColor(self.menuTheme.list.itemSecondaryTextColor, for: .disabled)
                button.setImage(ExteraUIIconProvider.current.navigationImage(id: item.id, fallback: UIImage(systemName: item.symbol)), for: .normal)
                button.tintColor = self.menuTheme.list.itemAccentColor
                button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
                button.titleLabel?.adjustsFontForContentSizeCategory = true
                button.titleLabel?.numberOfLines = 0
                button.contentHorizontalAlignment = .left
                button.contentEdgeInsets = UIEdgeInsets(top: 14, left: 10, bottom: 14, right: 10)
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
                button.isEnabled = item.enabled
                button.action = { [weak self] in
                    self?.dismissDrawerImpl?()
                    self?.performMenuAction(item.id)
                }
                stack.addArrangedSubview(button)
            }
        }
        self.view.addSubview(overlay)
        self.drawer = overlay
        let animate = !UIAccessibility.isReduceMotionEnabled
        let immersive = self.configuration.immersiveSidebar
        let duration: TimeInterval = animate ? (immersive ? 0.35 : 0.22) : 0
        panel.transform = CGAffineTransform(translationX: -width, y: 0)
        backdrop.alpha = 0
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: immersive ? 0.88 : 1, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: {
            panel.transform = .identity
            backdrop.alpha = 1
        }, completion: nil)
        self.dismissDrawerImpl = { [weak self, weak overlay] in
            guard let self, let overlay else { return }
            self.dismissDrawerImpl = nil
            UIView.animate(withDuration: animate ? 0.2 : 0, animations: {
                panel.transform = CGAffineTransform(translationX: -width, y: 0)
                backdrop.alpha = 0
            }, completion: { [weak self, weak overlay] _ in
                overlay?.removeFromSuperview()
                self?.drawer = nil
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            })
        }
        backdrop.action = { [weak self] in self?.dismissDrawerImpl?() }
        let close = UISwipeGestureRecognizer(target: self, action: #selector(self.closeDrawer))
        close.direction = .left
        panel.addGestureRecognizer(close)
        UIAccessibility.post(notification: .screenChanged, argument: stack.arrangedSubviews.first)
    }
    @objc private func closeDrawer() { self.dismissDrawerImpl?() }
}
