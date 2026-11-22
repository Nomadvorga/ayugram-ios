import Foundation
import UIKit
import AsyncDisplayKit
import ContextUI
import TelegramPresentationData
import Display
import AyuAtmosphericHost
import AyuAtmosphericUI

final class PeerInfoHeaderActionButtonNode: HighlightableButtonNode {
    let key: PeerInfoHeaderButtonKey
    private let action: (PeerInfoHeaderActionButtonNode, ContextGesture?) -> Void
    let referenceNode: ContextReferenceContentNode
    let containerNode: ContextControllerSourceNode
    private let backgroundNode: ASDisplayNode
    private let textNode: ImmediateTextNode
    
    private var theme: PresentationTheme?
    private var atmosphericHost: AtmosphericSurfaceHostView?
    private var atmosphericVisible = false
    private var atmosphericExpandedSize: CGSize?

    func updateAtmosphericVisibility(_ visible: Bool) {
        self.atmosphericVisible = visible
        self.refreshAtmosphericSurface()
    }

    func removeAtmosphericSurface() {
        MainActor.assumeIsolated {
            self.atmosphericVisible = false
            self.atmosphericHost?.removeFromSuperview()
            self.atmosphericHost = nil
        }
    }

    private func refreshAtmosphericSurface() {
        MainActor.assumeIsolated { self.refreshAtmosphericSurfaceOnMainActor() }
    }

    @MainActor private func refreshAtmosphericSurfaceOnMainActor() {
        guard let theme = self.theme else {
            return
        }
        let container = self.view
        let rect = self.backgroundNode.view.convert(self.backgroundNode.bounds, to: container)
        let backgroundAlpha = self.backgroundNode.alpha * self.referenceNode.alpha * self.containerNode.alpha
        let eligible = rect.width >= 24.0 && rect.height >= 32.0 && rect.height <= 120.0
        let visible = self.atmosphericVisible && !self.backgroundNode.isHidden && backgroundAlpha > 0.05
            && (self.backgroundNode.backgroundColor?.cgColor.alpha ?? 0.0) > 0.05
            && !self.textNode.isHidden && self.textNode.alpha > 0.05
            && AtmosphericSurfaceLayout.hierarchyAllowsDecoration(in: container)
            && AtmosphericSurfaceLayout.actionHasVisibleArea(rect, in: container)
        if self.atmosphericHost == nil && eligible && visible {
            let host = AtmosphericSurfaceHostView(container: container, role: .profileAction)
            self.atmosphericHost = host
            container.addSubview(host)
        }
        var geometry = AtmosphericHostGeometry(
            rect: rect,
            cornerRadius: self.backgroundNode.cornerRadius,
            visible: eligible && visible,
            alpha: backgroundAlpha,
            profileExpansionFraction: 1.0,
            isDarkTheme: theme.overallDarkAppearance
        )
        // convert(_:to:) already includes the container transform in rect.
        geometry.profileActionScale = 1.0
        geometry.expandedActionReferenceSize = self.atmosphericExpandedSize
        self.atmosphericHost?.update(geometry: geometry)
    }

    override var alpha: CGFloat {
        didSet {
            self.refreshAtmosphericSurface()
        }
    }

    override var isHidden: Bool {
        didSet {
            self.refreshAtmosphericSurface()
        }
    }
    
    init(key: PeerInfoHeaderButtonKey, action: @escaping (PeerInfoHeaderActionButtonNode, ContextGesture?) -> Void) {
        self.key = key
        self.action = action
        
        self.referenceNode = ContextReferenceContentNode()
        self.containerNode = ContextControllerSourceNode()
        self.containerNode.animateScale = false
        
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.cornerRadius = 11.0
                
        self.textNode = ImmediateTextNode()
        self.textNode.displaysAsynchronously = false
        self.textNode.isUserInteractionEnabled = false
        
        super.init()
        
        self.accessibilityTraits = .button
        
        self.containerNode.addSubnode(self.referenceNode)
        self.referenceNode.addSubnode(self.backgroundNode)
        self.addSubnode(self.containerNode)
        self.addSubnode(self.textNode)
        
        self.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self {
                if highlighted {
                    strongSelf.layer.removeAnimation(forKey: "opacity")
                    strongSelf.alpha = 0.4
                } else {
                    strongSelf.alpha = 1.0
                    strongSelf.layer.animateAlpha(from: 0.4, to: 1.0, duration: 0.2)
                }
            }
        }
        
        self.containerNode.activated = { [weak self] gesture, _ in
            if let strongSelf = self {
                strongSelf.action(strongSelf, gesture)
            }
        }
        
        self.addTarget(self, action: #selector(self.buttonPressed), forControlEvents: .touchUpInside)
    }
    
    @objc private func buttonPressed() {
        self.action(self, nil)
    }
    
    func update(size: CGSize, text: String, presentationData: PresentationData, transition: ContainedViewLayoutTransition) {
        let themeUpdated = self.theme != presentationData.theme
        if themeUpdated {
            self.theme = presentationData.theme
            
            self.containerNode.isGestureEnabled = false
                                                            
            self.backgroundNode.backgroundColor = presentationData.theme.list.itemAccentColor
            transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(), size: size))
        }
        
        self.textNode.attributedText = NSAttributedString(string: text, font: Font.semibold(16.0), textColor: presentationData.theme.list.itemCheckColors.foregroundColor)
        self.accessibilityLabel = text
        let titleSize = self.textNode.updateLayout(CGSize(width: 120.0, height: .greatestFiniteMagnitude))
        
        transition.updateFrame(node: self.containerNode, frame: CGRect(origin: CGPoint(), size: size))
        transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(), size: size))
        transition.updateFrameAdditiveToCenter(node: self.textNode, frame: CGRect(origin: CGPoint(x: floorToScreenPixels((size.width - titleSize.width) / 2.0), y: floorToScreenPixels((size.height - titleSize.height) / 2.0)), size: titleSize))
        
        self.referenceNode.frame = self.containerNode.bounds
        if let reference = self.atmosphericExpandedSize {
            if abs(reference.width - size.width) > 6.0 || abs(reference.height - size.height) > 6.0 {
                self.atmosphericExpandedSize = size
            }
        } else {
            self.atmosphericExpandedSize = size
        }
        self.refreshAtmosphericSurface()
    }
}
