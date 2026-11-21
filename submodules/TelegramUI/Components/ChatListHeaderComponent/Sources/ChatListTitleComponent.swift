import Foundation
import SGSimpleSettings
import UIKit
import Display
import ComponentFlow
import ComponentDisplayAdapters
import TelegramPresentationData
import AccountContext
import ChatListTitleView
import NavigationBarComponent

/// The chat list's title (`ChatListTitleView`: network status, lock, emoji status) as a row-filling
/// `NavigationBarComponent` title. While the stories are collapsed into the title (`sideContentFraction` 1), it
/// slides left to keep clear of the right buttons.
final class ChatListTitleComponent: Component {
    typealias EnvironmentType = NavigationBarTitleEnvironment

    let context: AccountContext
    let theme: PresentationTheme
    let strings: PresentationStrings
    let title: NetworkStatusTitle
    let usesAccountTitle: Bool
    let sideContentFraction: CGFloat
    private let centerTitle: Bool
    let openStatusSetup: (UIView) -> Void
    let toggleIsLocked: () -> Void

    init(context: AccountContext, theme: PresentationTheme, strings: PresentationStrings, title: NetworkStatusTitle, usesAccountTitle: Bool, sideContentFraction: CGFloat, openStatusSetup: @escaping (UIView) -> Void, toggleIsLocked: @escaping () -> Void) {
        self.context = context
        self.theme = theme
        self.strings = strings
        self.title = title
        self.usesAccountTitle = usesAccountTitle
        self.sideContentFraction = sideContentFraction
        self.centerTitle = ExteraSettings.shared.centerTitle
        self.openStatusSetup = openStatusSetup
        self.toggleIsLocked = toggleIsLocked
    }

    static func ==(lhs: ChatListTitleComponent, rhs: ChatListTitleComponent) -> Bool {
        if lhs.centerTitle != rhs.centerTitle {
            return false
        }
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.theme !== rhs.theme {
            return false
        }
        if lhs.strings !== rhs.strings {
            return false
        }
        if lhs.usesAccountTitle != rhs.usesAccountTitle {
            return false
        }
        if lhs.title != rhs.title {
            return false
        }
        if lhs.sideContentFraction != rhs.sideContentFraction {
            return false
        }
        return true
    }

    final class View: UIView {
        private(set) var titleView: ChatListTitleView?
        private var component: ChatListTitleComponent?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let titleView = self.titleView else {
                return nil
            }
            return titleView.hitTest(self.convert(point, to: titleView), with: event)
        }

        func update(component: ChatListTitleComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<NavigationBarTitleEnvironment>, transition: ComponentTransition) -> CGSize {
            self.component = component
            let rightButtonsExtent = environment[NavigationBarTitleEnvironment.self].value.rightButtonsExtent

            var titleTransition = transition
            let titleView: ChatListTitleView
            if let current = self.titleView {
                titleView = current
            } else {
                titleTransition = .immediate
                titleView = ChatListTitleView(context: component.context, theme: component.theme, strings: component.strings, animationCache: component.context.animationCache, animationRenderer: component.context.animationRenderer)
                titleView.manualLayout = true
                self.titleView = titleView
                self.addSubview(titleView)
            }

            titleView.theme = component.theme
            titleView.strings = component.strings
            titleView.setTitle(component.title, animated: false)
            var titleLayoutSize: CGSize
            var titleLayoutOriginX: CGFloat
            if component.centerTitle {
                let titleEnvironment = environment[NavigationBarTitleEnvironment.self].value
                let buttonMargin = max(titleEnvironment.leftButtonsExtent, titleEnvironment.rightButtonsExtent) + 4.0
                // ChatListTitleView draws the lock and credibility icon beside its text. Reserve their
                // overhang on both sides so neither can enter a button even for a long account name.
                let decorationMargin: CGFloat = max(component.title.isPasscodeSet ? 18.0 : 0.0, component.title.peerStatus != nil && !component.title.activity ? 24.0 : 0.0)
                let width = max(0.0, availableSize.width - 2.0 * (buttonMargin + decorationMargin))
                titleLayoutSize = CGSize(width: width, height: availableSize.height)
                titleLayoutOriginX = floor((availableSize.width - width) * 0.5)
                titleView.isHidden = width <= 0.0
            } else {
                titleLayoutSize = availableSize
                titleLayoutOriginX = 0.0
                titleView.isHidden = false
            }
            let titleContentRect = titleView.updateLayoutInternal(size: titleLayoutSize, transition: transition.containedViewLayoutTransition)
            var centerContentOffsetX = component.centerTitle ? 0.0 : -max(0.0, titleContentRect.maxX - 2.0 - (availableSize.width - rightButtonsExtent))
            if !component.centerTitle && component.usesAccountTitle && !component.title.activity {
                let titleEnvironment = environment[NavigationBarTitleEnvironment.self].value
                let leftLimit = titleEnvironment.leftButtonsExtent + 4.0
                let rightLimit = availableSize.width - titleEnvironment.rightButtonsExtent - 4.0
                let currentOffset = centerContentOffsetX * component.sideContentFraction
                if titleContentRect.minX + currentOffset < leftLimit || titleContentRect.maxX + currentOffset > rightLimit {
                    // New account-name titles may be much longer than "Chats". Only an intersecting
                    // root title falls back to the available button band; short/non-root titles keep
                    // the existing off-mode placement exactly.
                    let decorationMargin: CGFloat = max(component.title.isPasscodeSet ? 18.0 : 0.0, component.title.peerStatus != nil ? 24.0 : 0.0)
                    let width = max(0.0, rightLimit - leftLimit - 2.0 * decorationMargin)
                    titleLayoutSize = CGSize(width: width, height: availableSize.height)
                    titleLayoutOriginX = leftLimit + decorationMargin
                    centerContentOffsetX = 0.0
                    titleView.isHidden = width <= 0.0
                    let _ = titleView.updateLayoutInternal(size: titleLayoutSize, transition: transition.containedViewLayoutTransition)
                }
            }

            titleView.openStatusSetup = { [weak self] sourceView in
                guard let self else {
                    return
                }
                self.component?.openStatusSetup(sourceView)
            }
            titleView.toggleIsLocked = { [weak self] in
                guard let self else {
                    return
                }
                self.component?.toggleIsLocked()
            }

            let titleOffset: CGFloat
            if component.title.activity {
                titleOffset = 0.0
            } else {
                titleOffset = centerContentOffsetX * component.sideContentFraction
            }
            titleTransition.setFrame(view: titleView, frame: CGRect(origin: CGPoint(x: titleLayoutOriginX + titleOffset, y: 0.0), size: titleLayoutSize))

            return availableSize
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<NavigationBarTitleEnvironment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
