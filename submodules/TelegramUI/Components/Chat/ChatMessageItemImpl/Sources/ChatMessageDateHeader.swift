import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import AccountContext
import AvatarNode
import TelegramCore
import TelegramUniversalVideoContent
import UniversalMediaPlayer
import GalleryUI
import HierarchyTrackingLayer
import WallpaperBackgroundNode
import ChatControllerInteraction
import AvatarVideoNode
import ChatMessageItem
import ChatMessageItemCommon
import AvatarNode
import ComponentFlow
import EmojiStatusComponent
import AppBundle
import GlassBackgroundComponent
// MARK: AyuGram
import SGSimpleSettings
import PeerOnlineMarkerNode

// The sender's online dot is drawn by `onlineMarkerLayer`; the node-based variant stays off so an avatar never shows two.
private let ayuDrawsSenderOnlineDot = false

private let timezoneOffset: Int32 = {
    let nowTimestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
    var now: time_t = time_t(nowTimestamp)
    var timeinfoNow: tm = tm()
    localtime_r(&now, &timeinfoNow)
    return Int32(timeinfoNow.tm_gmtoff)
}()

private let granularity: Int32 = 60 * 60 * 24

public final class ChatMessageDateHeader: ListViewItemHeader {
    public struct Id: Hashable {
        public let roundedTimestamp: Int64?
        public let separableThreadId: Int64?
        
        public init(roundedTimestamp: Int64?, separableThreadId: Int64?) {
            self.roundedTimestamp = roundedTimestamp
            self.separableThreadId = separableThreadId
        }
    }
    
    public final class HeaderData {
        public enum Contents {
            case peer(EnginePeer)
            case thread(id: Int64, info: EngineMessage.AssociatedThreadInfo)
        }
        
        public let contents: Contents
        
        public init(contents: Contents) {
            self.contents = contents
        }
    }
    
    private let timestamp: Int32
    private let roundedTimestamp: Int32
    private let scheduled: Bool
    public let displayHeader: HeaderData?
    
    public let id: ListViewItemNode.HeaderId
    public let stackingId: ListViewItemNode.HeaderId?
    public let idValue: Id
    public let presentationData: ChatPresentationData
    public let controllerInteraction: ChatControllerInteraction?
    public let context: AccountContext
    public let action: ((Int32, Bool) -> Void)?
    
    public init(timestamp: Int32, separableThreadId: Int64?, scheduled: Bool, displayHeader: HeaderData?, presentationData: ChatPresentationData, controllerInteraction: ChatControllerInteraction?, context: AccountContext, action: ((Int32, Bool) -> Void)? = nil) {
        self.timestamp = timestamp
        self.scheduled = scheduled
        self.displayHeader = displayHeader
        self.presentationData = presentationData
        self.controllerInteraction = controllerInteraction
        self.context = context
        self.action = action
        self.roundedTimestamp = dateHeaderTimestampId(timestamp: timestamp)
        if let _ = self.displayHeader {
            self.idValue = ChatMessageDateHeader.Id(roundedTimestamp: 0, separableThreadId: separableThreadId)
            self.id = ListViewItemNode.HeaderId(space: 3, id: self.idValue)
            self.stackingId = ListViewItemNode.HeaderId(space: 2, id: ChatMessageDateHeader.Id(roundedTimestamp: Int64(self.roundedTimestamp), separableThreadId: nil))
        } else {
            self.idValue = ChatMessageDateHeader.Id(roundedTimestamp: Int64(self.roundedTimestamp), separableThreadId: nil)
            self.id = ListViewItemNode.HeaderId(space: 2, id: self.idValue)
            self.stackingId = nil
        }
        
        let isRotated = controllerInteraction?.chatIsRotated ?? true
        
        self.stickDirection = isRotated ? .bottom : .top
    }
    
    public let stickDirection: ListViewItemHeaderStickDirection
    public let stickOverInsets: Bool = true
    
    public let height: CGFloat = 34.0

    public func combinesWith(other: ListViewItemHeader) -> Bool {
        if let other = other as? ChatMessageDateHeader, other.id == self.id {
            return true
        } else {
            return false
        }
    }
    
    public func node(synchronousLoad: Bool) -> ListViewItemHeaderNode {
        return ChatMessageDateHeaderNodeImpl(localTimestamp: self.roundedTimestamp, scheduled: self.scheduled, displayHeader: self.displayHeader, presentationData: self.presentationData, controllerInteraction: self.controllerInteraction, context: self.context, action: self.action)
    }
    
    public func updateNode(_ node: ListViewItemHeaderNode, previous: ListViewItemHeader?, next: ListViewItemHeader?) {
        guard let node = node as? ChatMessageDateHeaderNodeImpl, let next = next as? ChatMessageDateHeader else {
            return
        }
        node.updatePresentationData(next.presentationData, context: next.context)
    }
}

private func monthAtIndex(_ index: Int, strings: PresentationStrings) -> String {
    switch index {
        case 0:
            return strings.Month_GenJanuary
        case 1:
            return strings.Month_GenFebruary
        case 2:
            return strings.Month_GenMarch
        case 3:
            return strings.Month_GenApril
        case 4:
            return strings.Month_GenMay
        case 5:
            return strings.Month_GenJune
        case 6:
            return strings.Month_GenJuly
        case 7:
            return strings.Month_GenAugust
        case 8:
            return strings.Month_GenSeptember
        case 9:
            return strings.Month_GenOctober
        case 10:
            return strings.Month_GenNovember
        case 11:
            return strings.Month_GenDecember
        default:
            return ""
    }
}

private func dateHeaderTimestampId(timestamp: Int32) -> Int32 {
    if timestamp == scheduleWhenOnlineTimestamp || timestamp >= Int32.max - 1000 {
        return timestamp
    } else if timestamp == Int32.max {
        return timestamp / (granularity) * (granularity)
    } else {
        return ((timestamp + timezoneOffset) / (granularity)) * (granularity)
    }
}

private final class ChatMessageDateSectionSeparatorNode: ASDisplayNode {
    private let controllerInteraction: ChatControllerInteraction?
    private let presentationData: ChatPresentationData
    
    public let backgroundNode: NavigationBackgroundNode
    private var backgroundContent: WallpaperBubbleBackgroundNode?
    
    private let patternLayer: SimpleShapeLayer
    
    init(
        controllerInteraction: ChatControllerInteraction?,
        presentationData: ChatPresentationData
    ) {
        self.controllerInteraction = controllerInteraction
        self.presentationData = presentationData
        
        if controllerInteraction?.presentationContext.backgroundNode?.hasExtraBubbleBackground() == true, let backgroundContent = controllerInteraction?.presentationContext.backgroundNode?.makeBubbleBackground(for: .free) {
            backgroundContent.clipsToBounds = true
            self.backgroundContent = backgroundContent
        }
                
        self.backgroundNode = NavigationBackgroundNode(color: .clear)
        self.backgroundNode.isUserInteractionEnabled = false
        
        self.patternLayer = SimpleShapeLayer()
        
        super.init()
        
        self.backgroundColor = nil
        self.isOpaque = false
        
        if let backgroundContent = self.backgroundContent {
            self.addSubnode(backgroundContent)
            backgroundContent.layer.mask = self.patternLayer
        } else {
            self.addSubnode(self.backgroundNode)
            self.backgroundNode.layer.mask = self.patternLayer
        }
        
        let fullTranslucency: Bool = self.controllerInteraction?.enableFullTranslucency ?? true
        
        self.backgroundNode.updateColor(color: selectDateFillStaticColor(theme: self.presentationData.theme.theme, wallpaper: self.presentationData.theme.wallpaper), enableBlur: fullTranslucency && dateFillNeedsBlur(theme: self.presentationData.theme.theme, wallpaper: self.presentationData.theme.wallpaper), transition: .immediate)
        
        self.patternLayer.lineWidth = 1.66
        self.patternLayer.strokeColor = UIColor.white.cgColor
        
        let linePath = CGMutablePath()
        linePath.move(to: CGPoint(x: 0.0, y: self.patternLayer.lineWidth * 0.5))
        linePath.addLine(to: CGPoint(x: 10000.0, y: self.patternLayer.lineWidth * 0.5))
        self.patternLayer.path = linePath
        self.patternLayer.lineDashPattern = [6.0 as NSNumber, 2.0 as NSNumber] as [NSNumber]
    }
    
    func update(size: CGSize, transition: ContainedViewLayoutTransition) {
        let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: size.width, height: 10.0))
        transition.updateFrame(node: self.backgroundNode, frame: backgroundFrame)
        self.backgroundNode.update(size: backgroundFrame.size, transition: transition)
        
        transition.updateFrame(layer: self.patternLayer, frame: CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: 1.66)))
        
        if let backgroundContent = self.backgroundContent {
            backgroundContent.allowsGroupOpacity = true
            self.backgroundNode.isHidden = true
            
            transition.updateFrame(node: backgroundContent, frame: self.backgroundNode.frame)
            backgroundContent.cornerRadius = backgroundFrame.size.height / 2.0
            
            /*if let (rect, containerSize) = self.absolutePosition {
                var backgroundFrame = backgroundContent.frame
                backgroundFrame.origin.x += rect.minX
                backgroundFrame.origin.y += containerSize.height - rect.minY
                backgroundContent.update(rect: backgroundFrame, within: containerSize, transition: transition)
            }*/
        }
    }
}

private final class ChatMessageDateContentNode: ASDisplayNode {
    private var presentationData: ChatPresentationData
    private let controllerInteraction: ChatControllerInteraction?
    
    public let labelNode: TextNode
    public let backgroundNode: NavigationBackgroundNode
    public let stickBackgroundNode: ASImageNode
    
    private var backgroundContent: WallpaperBubbleBackgroundNode?
    private var text: String
    
    private var stickDistanceFactor: CGFloat = 0.0
    private var lastBackgroundFrame: CGRect?
    // Bubble mode off: the date is gray text on the page; parked at the top while the chat scrolls it stands on a glass
    // island in the primary text colour, made the first time it parks (spec 5.7, 6.10).
    private var hasBubblelessState = false
    private var isFlashing = true
    private var glassView: GlassBackgroundView?
    private var parkedLabelNode: TextNode?
    
    init(presentationData: ChatPresentationData, controllerInteraction: ChatControllerInteraction?, localTimestamp: Int32, scheduled: Bool) {
        self.presentationData = presentationData
        self.controllerInteraction = controllerInteraction
        
        self.labelNode = TextNode()
        self.labelNode.isUserInteractionEnabled = false
        self.labelNode.displaysAsynchronously = !presentationData.isPreview
        
        if controllerInteraction?.presentationContext.backgroundNode?.hasExtraBubbleBackground() == true, let backgroundContent = controllerInteraction?.presentationContext.backgroundNode?.makeBubbleBackground(for: .free) {
            backgroundContent.clipsToBounds = true
            self.backgroundContent = backgroundContent
        }
                
        self.backgroundNode = NavigationBackgroundNode(color: .clear)
        self.backgroundNode.isUserInteractionEnabled = false
        
        self.stickBackgroundNode = ASImageNode()
        self.stickBackgroundNode.isLayerBacked = true
        self.stickBackgroundNode.displayWithoutProcessing = true
        self.stickBackgroundNode.displaysAsynchronously = false
        
        let nowTimestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
        
        var t: time_t = time_t(localTimestamp)
        var timeinfo: tm = tm()
        gmtime_r(&t, &timeinfo)
        
        var now: time_t = time_t(nowTimestamp)
        var timeinfoNow: tm = tm()
        localtime_r(&now, &timeinfoNow)
        
        var text: String
        if timeinfo.tm_year == timeinfoNow.tm_year {
            if timeinfo.tm_yday == timeinfoNow.tm_yday {
                text = presentationData.strings.Weekday_Today
            } else {
                text = presentationData.strings.Date_ChatDateHeader(monthAtIndex(Int(timeinfo.tm_mon), strings: presentationData.strings), "\(timeinfo.tm_mday)").string
            }
        } else {
            text = presentationData.strings.Date_ChatDateHeaderYear(monthAtIndex(Int(timeinfo.tm_mon), strings: presentationData.strings), "\(timeinfo.tm_mday)", "\(1900 + timeinfo.tm_year)").string
        }
        
        if scheduled {
            if localTimestamp == scheduleWhenOnlineTimestamp {
                text = presentationData.strings.ScheduledMessages_ScheduledOnline
            } else if timeinfo.tm_year == timeinfoNow.tm_year && timeinfo.tm_yday == timeinfoNow.tm_yday {
                text = presentationData.strings.ScheduledMessages_ScheduledToday
            } else {
                text = presentationData.strings.ScheduledMessages_ScheduledDate(text).string
            }
        }
        self.text = text
        
        super.init()
        
        let graphics = PresentationResourcesChat.principalGraphics(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper, bubbleCorners: presentationData.chatBubbleCorners)

        let fullTranslucency: Bool = true
        
        self.backgroundNode.updateColor(color: selectDateFillStaticColor(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper), enableBlur: fullTranslucency && dateFillNeedsBlur(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper), transition: .immediate)
        self.stickBackgroundNode.image = graphics.dateFloatingBackground
        self.stickBackgroundNode.alpha = 0.0
        
        if let backgroundContent = self.backgroundContent {
            self.addSubnode(backgroundContent)
        } else {
            self.addSubnode(self.backgroundNode)
        }
        self.addSubnode(self.labelNode)
                
        let titleFont = Font.medium(min(18.0, floor(presentationData.fontSize.baseDisplaySize * 13.0 / 17.0)))
        
        let attributedString = NSAttributedString(string: text, font: titleFont, textColor: bubbleVariableColor(variableColor: presentationData.theme.theme.chat.serviceMessage.dateTextColor, wallpaper: presentationData.theme.wallpaper))
        let labelLayout = TextNode.asyncLayout(self.labelNode)
                
        let (size, apply) = labelLayout(TextNodeLayoutArguments(attributedString: attributedString, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: 320.0, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
        let _ = apply()
        self.labelNode.frame = CGRect(origin: CGPoint(), size: size.size)
        
        self.updateBubblelessIsland(transition: .immediate)
    }
    
    func updatePresentationData(_ presentationData: ChatPresentationData, context: AccountContext) {
        let previousPresentationData = self.presentationData
        self.presentationData = presentationData
        
        let graphics = PresentationResourcesChat.principalGraphics(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper, bubbleCorners: presentationData.chatBubbleCorners)
        
        let fullTranslucency: Bool = true

        self.backgroundNode.updateColor(color: selectDateFillStaticColor(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper), enableBlur: fullTranslucency && dateFillNeedsBlur(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper), transition: .immediate)
        self.stickBackgroundNode.image = graphics.dateFloatingBackground
        
        let titleFont = Font.medium(min(18.0, floor(presentationData.fontSize.baseDisplaySize * 13.0 / 17.0)))
        
        let attributedString = NSAttributedString(string: self.text, font: titleFont, textColor: bubbleVariableColor(variableColor: presentationData.theme.theme.chat.serviceMessage.dateTextColor, wallpaper: presentationData.theme.wallpaper))
        let labelLayout = TextNode.asyncLayout(self.labelNode)
        
        let (size, apply) = labelLayout(TextNodeLayoutArguments(attributedString: attributedString, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: 320.0, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
        let _ = apply()
        
        if presentationData.fontSize != previousPresentationData.fontSize {
            self.labelNode.bounds = CGRect(origin: CGPoint(), size: size.size)
        }
        
        if let parkedLabelNode = self.parkedLabelNode {
            self.layoutParkedLabel(parkedLabelNode)
        }
        self.updateBubblelessIsland(transition: .immediate)
    }
    
    /// The parked date's label: the date in the primary text colour, where the gray one is.
    private func layoutParkedLabel(_ parkedLabelNode: TextNode) {
        let titleFont = Font.medium(min(18.0, floor(self.presentationData.fontSize.baseDisplaySize * 13.0 / 17.0)))
        let (layout, apply) = TextNode.asyncLayout(parkedLabelNode)(TextNodeLayoutArguments(attributedString: NSAttributedString(string: self.text, font: titleFont, textColor: self.presentationData.theme.theme.list.itemPrimaryTextColor), backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: 320.0, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
        let _ = apply()
        parkedLabelNode.bounds = CGRect(origin: CGPoint(), size: layout.size)
        parkedLabelNode.position = self.labelNode.position
    }
    
    /// Without bubbles the pill never shows: in the history the date is the gray label, parked it stands on the glass
    /// island in the primary text colour, and once scrolling stops the island dematerialises (glass under a fading parent
    /// breaks) while its label fades. With bubbles this only restores what it changed.
    private func updateBubblelessIsland(transition: ComponentTransition) {
        guard !self.presentationData.chatBubbleCorners.bubbleMode else {
            if self.hasBubblelessState {
                self.hasBubblelessState = false
                self.backgroundNode.alpha = 1.0
                self.backgroundContent?.alpha = 1.0
                self.labelNode.alpha = 1.0
                self.glassView?.removeFromSuperview()
                self.glassView = nil
                self.parkedLabelNode?.removeFromSupernode()
                self.parkedLabelNode = nil
            }
            return
        }
        self.hasBubblelessState = true
        self.backgroundNode.alpha = 0.0
        self.backgroundContent?.alpha = 0.0
        
        let state = chatMessageBubblelessDateState(stickDistanceFactor: self.stickDistanceFactor, isFlashing: self.isFlashing)
        var materialisesLater = false
        if state.showsIsland, self.glassView == nil {
            let glassView = GlassBackgroundView()
            glassView.isUserInteractionEnabled = false
            self.glassView = glassView
            self.view.insertSubview(glassView, belowSubview: self.labelNode.view)
            let parkedLabelNode = TextNode()
            parkedLabelNode.isUserInteractionEnabled = false
            parkedLabelNode.displaysAsynchronously = false
            parkedLabelNode.alpha = 0.0
            self.parkedLabelNode = parkedLabelNode
            self.addSubnode(parkedLabelNode)
            self.layoutParkedLabel(parkedLabelNode)
            if let lastBackgroundFrame = self.lastBackgroundFrame {
                glassView.frame = lastBackgroundFrame.insetBy(dx: -6.0, dy: -3.0)
            }
            // Glass animates from the state it was last committed in: it materialises a frame later.
            materialisesLater = true
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1.0 / 60.0) { [weak self] in
                self?.updateBubblelessIsland(transition: transition)
            }
        }
        if let glassView = self.glassView {
            glassView.update(size: glassView.bounds.size, cornerRadius: glassView.bounds.height * 0.5, isDark: self.presentationData.theme.theme.overallDarkAppearance, tintColor: .init(kind: .panel), isVisible: state.showsIsland && !materialisesLater, transition: materialisesLater ? .immediate : transition)
        }
        transition.setAlpha(view: self.labelNode.view, alpha: state.showsHistoryLabel ? 1.0 : 0.0)
        if let parkedLabelNode = self.parkedLabelNode {
            transition.setAlpha(view: parkedLabelNode.view, alpha: state.showsParkedLabel ? 1.0 : 0.0)
        }
    }
    
    /// Without bubbles: whether the chat is scrolling (or the date is in the history), from the header's flashing.
    func updateBubblelessFlashing(_ isFlashing: Bool, animated: Bool) {
        if self.isFlashing == isFlashing {
            return
        }
        self.isFlashing = isFlashing
        self.updateBubblelessIsland(transition: animated ? .easeInOut(duration: isFlashing ? 0.3 : 0.4) : .immediate)
    }
    
    /// Without bubbles the parked date that has gone takes no taps.
    var bubblelessTakesTaps: Bool? {
        guard !self.presentationData.chatBubbleCorners.bubbleMode else {
            return nil
        }
        return chatMessageBubblelessDateState(stickDistanceFactor: self.stickDistanceFactor, isFlashing: self.isFlashing).takesTaps
    }
    
    func updateBackgroundColor(color: UIColor, enableBlur: Bool) {
        self.backgroundNode.updateColor(color: color, enableBlur: enableBlur, transition: .immediate)
    }
    
    func update(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition) {
        let chatDateSize: CGFloat = 22.0
        let chatDateInset: CGFloat = 6.0
        
        let labelSize = self.labelNode.bounds.size
        let backgroundSize = CGSize(width: labelSize.width + chatDateInset * 2.0, height: chatDateSize)
        
        let backgroundFrame = CGRect(origin: CGPoint(x: leftInset + floorToScreenPixels((size.width - leftInset - rightInset - backgroundSize.width) / 2.0), y: (size.height - chatDateSize) / 2.0), size: backgroundSize)
        
        transition.updateFrame(node: self.stickBackgroundNode, frame: CGRect(origin: CGPoint(), size: backgroundFrame.size))
        transition.updateFrame(node: self.backgroundNode, frame: backgroundFrame)
        self.backgroundNode.update(size: backgroundFrame.size, cornerRadius: backgroundFrame.size.height / 2.0, transition: transition)
        let labelFrame = CGRect(origin: CGPoint(x: backgroundFrame.origin.x + chatDateInset, y: backgroundFrame.origin.y + floorToScreenPixels((backgroundSize.height - labelSize.height) / 2.0)), size: labelSize)
        
        transition.updatePosition(node: self.labelNode, position: labelFrame.center)
        self.labelNode.bounds = CGRect(origin: CGPoint(), size: labelFrame.size)
        self.lastBackgroundFrame = backgroundFrame
        if let parkedLabelNode = self.parkedLabelNode {
            transition.updatePosition(node: parkedLabelNode, position: labelFrame.center)
        }
        if let glassView = self.glassView {
            let glassFrame = backgroundFrame.insetBy(dx: -6.0, dy: -3.0)
            transition.updateFrame(view: glassView, frame: glassFrame)
            glassView.update(size: glassFrame.size, cornerRadius: glassFrame.height * 0.5, isDark: self.presentationData.theme.theme.overallDarkAppearance, tintColor: .init(kind: .panel), isVisible: chatMessageBubblelessDateState(stickDistanceFactor: self.stickDistanceFactor, isFlashing: self.isFlashing).showsIsland, transition: ComponentTransition(transition))
        }
                
        if let backgroundContent = self.backgroundContent {
            backgroundContent.allowsGroupOpacity = true
            self.backgroundNode.isHidden = true
            
            transition.updateFrame(node: backgroundContent, frame: self.backgroundNode.frame)
            backgroundContent.cornerRadius = backgroundFrame.size.height / 2.0
            
            /*if let (rect, containerSize) = self.absolutePosition {
                var backgroundFrame = backgroundContent.frame
                backgroundFrame.origin.x += rect.minX
                backgroundFrame.origin.y += containerSize.height - rect.minY
                backgroundContent.update(rect: backgroundFrame, within: containerSize, transition: transition)
            }*/
        }
    }
    
    func updateStickDistanceFactor(_ factor: CGFloat, transition: ContainedViewLayoutTransition) {
        self.stickBackgroundNode.alpha = factor
        let wasParked = chatMessageBubblelessDateIsParked(stickDistanceFactor: self.stickDistanceFactor)
        self.stickDistanceFactor = factor
        if self.hasBubblelessState, wasParked != chatMessageBubblelessDateIsParked(stickDistanceFactor: factor) {
            self.updateBubblelessIsland(transition: transition.isAnimated ? .easeInOut(duration: 0.25) : .immediate)
        }
    }
}

private final class ChatMessagePeerContentNode: ASDisplayNode {
    private static let arrowImage = generateTintedImage(image: UIImage(bundleImageName: "Chat/Message/HeaderArrow"), color: .white)!.withRenderingMode(.alwaysTemplate)
    
    private let context: AccountContext
    private var presentationData: ChatPresentationData
    private let controllerInteraction: ChatControllerInteraction?
    private let displayHeader: ChatMessageDateHeader.HeaderData
    
    private var avatarNode: AvatarNode?
    private var icon: ComponentView<Empty>?
    private var arrowIcon: UIImageView?
    
    public let labelNode: TextNode
    public let backgroundNode: NavigationBackgroundNode
    public let stickBackgroundNode: ASImageNode
    
    private var backgroundContent: WallpaperBubbleBackgroundNode?
    private var text: String
    private var labelMaxWidth: CGFloat = 320.0
    
    init(context: AccountContext, presentationData: ChatPresentationData, controllerInteraction: ChatControllerInteraction?, displayHeader: ChatMessageDateHeader.HeaderData) {
        self.context = context
        self.presentationData = presentationData
        self.controllerInteraction = controllerInteraction
        self.displayHeader = displayHeader
        
        self.labelNode = TextNode()
        self.labelNode.isUserInteractionEnabled = false
        self.labelNode.displaysAsynchronously = !presentationData.isPreview
        
        if controllerInteraction?.presentationContext.backgroundNode?.hasExtraBubbleBackground() == true, let backgroundContent = controllerInteraction?.presentationContext.backgroundNode?.makeBubbleBackground(for: .free) {
            backgroundContent.clipsToBounds = true
            self.backgroundContent = backgroundContent
        }
                
        self.backgroundNode = NavigationBackgroundNode(color: .clear)
        self.backgroundNode.isUserInteractionEnabled = false
        
        self.stickBackgroundNode = ASImageNode()
        self.stickBackgroundNode.isLayerBacked = true
        self.stickBackgroundNode.displayWithoutProcessing = true
        self.stickBackgroundNode.displaysAsynchronously = false
        
        let text: String
        switch displayHeader.contents {
        case let .peer(peer):
            text = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        case let .thread(_, info):
            text = info.title
        }
        self.text = text
        
        super.init()
        
        let graphics = PresentationResourcesChat.principalGraphics(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper, bubbleCorners: presentationData.chatBubbleCorners)

        let fullTranslucency: Bool = true
        
        self.backgroundNode.updateColor(color: selectDateFillStaticColor(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper), enableBlur: fullTranslucency && dateFillNeedsBlur(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper), transition: .immediate)
        self.stickBackgroundNode.image = graphics.dateFloatingBackground
        self.stickBackgroundNode.alpha = 0.0
        
        if let backgroundContent = self.backgroundContent {
            self.addSubnode(backgroundContent)
        } else {
            self.addSubnode(self.backgroundNode)
        }
        
        switch displayHeader.contents {
        case let .peer(peer):
            let avatarNode = AvatarNode(font: avatarPlaceholderFont(size: 8.0))
            self.avatarNode = avatarNode
            self.addSubnode(avatarNode)
            
            if peer.smallProfileImage != nil {
                avatarNode.setPeerV2(context: context, theme: presentationData.theme.theme, peer: peer, displayDimensions: CGSize(width: 16.0, height: 16.0))
            } else {
                avatarNode.setPeer(context: context, theme: presentationData.theme.theme, peer: peer, displayDimensions: CGSize(width: 16.0, height: 16.0))
            }
        case let .thread(id, info):
            let avatarIconContent: EmojiStatusComponent.Content
            if id != 1 {
                if let fileId = info.icon, fileId != 0 {
                    // A template emoji takes the header's text colour, as the General icon does.
                    avatarIconContent = .animation(content: .customEmoji(fileId: fileId), size: CGSize(width: 16.0, height: 16.0), placeholderColor: presentationData.theme.theme.list.mediaPlaceholderColor, themeColor: bubbleVariableColor(variableColor: presentationData.theme.theme.chat.serviceMessage.dateTextColor, wallpaper: presentationData.theme.wallpaper), loopMode: .count(0))
                } else {
                    avatarIconContent = .topic(title: String(info.title.prefix(1)), color: info.iconColor, size: CGSize(width: 16.0, height: 16.0))
                }
            } else {
                avatarIconContent = .image(image: PresentationResourcesChatList.generalTopicTemplateIcon(presentationData.theme.theme), tintColor: bubbleVariableColor(variableColor: presentationData.theme.theme.chat.serviceMessage.dateTextColor, wallpaper: presentationData.theme.wallpaper))
            }
            
            let avatarIconComponent = EmojiStatusComponent(
                context: context,
                animationCache: context.animationCache,
                animationRenderer: context.animationRenderer,
                content: avatarIconContent,
                isVisibleForAnimations: false,
                action: nil
            )
            let icon = ComponentView<Empty>()
            self.icon = icon
            let _ = icon.update(
                transition: .immediate,
                component: AnyComponent(avatarIconComponent),
                environment: {},
                containerSize: CGSize(width: 16.0, height: 16.0)
            )
            if let iconView = icon.view {
                self.view.addSubview(iconView)
            }
        }
        self.addSubnode(self.labelNode)
        
        let labelSize = self.layoutLabel()
        self.labelNode.frame = CGRect(origin: CGPoint(), size: labelSize)
        
        let arrowIcon = UIImageView(image: ChatMessagePeerContentNode.arrowImage)
        self.arrowIcon = arrowIcon
        self.view.addSubview(arrowIcon)
    }
    
    func updatePresentationData(_ presentationData: ChatPresentationData, context: AccountContext) {
        let previousPresentationData = self.presentationData
        self.presentationData = presentationData
        
        let graphics = PresentationResourcesChat.principalGraphics(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper, bubbleCorners: presentationData.chatBubbleCorners)
        
        let fullTranslucency: Bool = true

        self.backgroundNode.updateColor(color: selectDateFillStaticColor(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper), enableBlur: fullTranslucency && dateFillNeedsBlur(theme: presentationData.theme.theme, wallpaper: presentationData.theme.wallpaper), transition: .immediate)
        self.stickBackgroundNode.image = graphics.dateFloatingBackground
        
        let labelSize = self.layoutLabel()
        
        if presentationData.fontSize != previousPresentationData.fontSize {
            self.labelNode.bounds = CGRect(origin: CGPoint(), size: labelSize)
        }
    }
    
    private func layoutLabel() -> CGSize {
        let titleFont = Font.medium(min(18.0, floor(self.presentationData.fontSize.baseDisplaySize * 13.0 / 17.0)))
        
        let attributedString = NSAttributedString(string: self.text, font: titleFont, textColor: bubbleVariableColor(variableColor: self.presentationData.theme.theme.chat.serviceMessage.dateTextColor, wallpaper: self.presentationData.theme.wallpaper))
        let labelLayout = TextNode.asyncLayout(self.labelNode)
        
        let (size, apply) = labelLayout(TextNodeLayoutArguments(attributedString: attributedString, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: self.labelMaxWidth, height: CGFloat.greatestFiniteMagnitude), alignment: .natural, cutout: nil, insets: UIEdgeInsets()))
        let _ = apply()
        return size.size
    }
    
    func updateBackgroundColor(color: UIColor, enableBlur: Bool) {
        self.backgroundNode.updateColor(color: color, enableBlur: enableBlur, transition: .immediate)
    }
    
    func update(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition) {
        let chatDateSize: CGFloat = 22.0
        let chatDateInset: CGFloat = 6.0
        let arrowInset: CGFloat = 5.0
        let arrowSpacing: CGFloat = arrowInset + 6.0
        
        let avatarDiameter: CGFloat = 16.0
        let avatarInset: CGFloat
        switch self.displayHeader.contents {
        case .peer:
            avatarInset = 2.0
        case .thread:
            avatarInset = 4.0
        }
        let avatarSpacing: CGFloat = 4.0
        
        let labelMaxWidth = chatMessageHeaderTitleMaxWidth(width: size.width, leftInset: leftInset, rightInset: rightInset, chromeWidth: avatarInset + avatarDiameter + avatarSpacing + chatDateInset + arrowSpacing, margin: 8.0)
        if self.labelMaxWidth != labelMaxWidth {
            self.labelMaxWidth = labelMaxWidth
            self.labelNode.bounds = CGRect(origin: CGPoint(), size: self.layoutLabel())
        }
        
        let labelSize = self.labelNode.bounds.size
        let backgroundSize = CGSize(width: avatarInset + avatarDiameter + avatarSpacing + labelSize.width + chatDateInset + arrowSpacing, height: chatDateSize)
        
        let backgroundFrame = CGRect(origin: CGPoint(x: leftInset + floorToScreenPixels((size.width - leftInset - rightInset - backgroundSize.width) / 2.0), y: (size.height - chatDateSize) / 2.0), size: backgroundSize)
        
        let iconFrame = CGRect(origin: CGPoint(x: backgroundFrame.minX + avatarInset, y: backgroundFrame.origin.y + floorToScreenPixels((backgroundSize.height - avatarDiameter) / 2.0)), size: CGSize(width: avatarDiameter, height: avatarDiameter))
        
        if let avatarNode = self.avatarNode {
            transition.updateFrame(node: avatarNode, frame: iconFrame)
            avatarNode.updateSize(size: iconFrame.size)
        }
        if let iconView = self.icon?.view {
            transition.updateFrame(view: iconView, frame: iconFrame)
        }
        
        transition.updateFrame(node: self.stickBackgroundNode, frame: CGRect(origin: CGPoint(), size: backgroundFrame.size))
        transition.updateFrame(node: self.backgroundNode, frame: backgroundFrame)
        self.backgroundNode.update(size: backgroundFrame.size, cornerRadius: backgroundFrame.size.height / 2.0, transition: transition)
        let labelFrame = CGRect(origin: CGPoint(x: backgroundFrame.origin.x + avatarInset + avatarDiameter + avatarSpacing, y: backgroundFrame.origin.y + floorToScreenPixels((backgroundSize.height - labelSize.height) / 2.0)), size: labelSize)
        
        transition.updatePosition(node: self.labelNode, position: labelFrame.center)
        self.labelNode.bounds = CGRect(origin: CGPoint(), size: labelFrame.size)
        
        if let arrowIcon = self.arrowIcon, let image = arrowIcon.image {
            arrowIcon.tintColor = bubbleVariableColor(variableColor: presentationData.theme.theme.chat.serviceMessage.dateTextColor, wallpaper: presentationData.theme.wallpaper).withMultipliedAlpha(0.7)
            let arrowSize = image.size
            let arrowFrame = CGRect(origin: CGPoint(x: backgroundFrame.maxX - arrowInset - arrowSize.width, y: backgroundFrame.minY + floorToScreenPixels((backgroundFrame.height - arrowSize.height) * 0.5)), size: arrowSize)
            transition.updateFrame(view: arrowIcon, frame: arrowFrame)
        }
                
        if let backgroundContent = self.backgroundContent {
            backgroundContent.allowsGroupOpacity = true
            self.backgroundNode.isHidden = true
            
            transition.updateFrame(node: backgroundContent, frame: self.backgroundNode.frame)
            backgroundContent.cornerRadius = backgroundFrame.size.height / 2.0
            
            /*if let (rect, containerSize) = self.absolutePosition {
                var backgroundFrame = backgroundContent.frame
                backgroundFrame.origin.x += rect.minX
                backgroundFrame.origin.y += containerSize.height - rect.minY
                backgroundContent.update(rect: backgroundFrame, within: containerSize, transition: transition)
            }*/
        }
    }
    
    func updateStickDistanceFactor(_ factor: CGFloat, transition: ContainedViewLayoutTransition) {
        self.stickBackgroundNode.alpha = factor
    }
}

public final class ChatMessageDateHeaderNodeImpl: ListViewItemHeaderNode, ChatMessageDateHeaderNode {
    private var dateContentNode: ChatMessageDateContentNode?
    private var peerContentNode: ChatMessagePeerContentNode?
    
    private var sectionSeparator: ChatMessageDateSectionSeparatorNode?
    
    private let context: AccountContext
    private let localTimestamp: Int32
    private let scheduled: Bool
    private let displayHeader: ChatMessageDateHeader.HeaderData?
    private var presentationData: ChatPresentationData
    private let controllerInteraction: ChatControllerInteraction?
    
    private var flashingOnScrolling = false
    private var stickDistanceFactor: CGFloat = 0.0
    private var action: ((Int32, Bool) -> Void)? = nil
    
    private var params: (size: CGSize, leftInset: CGFloat, rightInset: CGFloat)?
    private var absolutePosition: (CGRect, CGSize)?
    
    public init(localTimestamp: Int32, scheduled: Bool, displayHeader: ChatMessageDateHeader.HeaderData?, presentationData: ChatPresentationData, controllerInteraction: ChatControllerInteraction?, context: AccountContext, action: ((Int32, Bool) -> Void)? = nil) {
        self.context = context
        self.presentationData = presentationData
        self.controllerInteraction = controllerInteraction
        
        self.localTimestamp = localTimestamp
        self.scheduled = scheduled
        self.displayHeader = displayHeader
        self.action = action
        
        let isRotated = controllerInteraction?.chatIsRotated ?? true
        
        super.init(layerBacked: false, isRotated: isRotated, seeThrough: false)
        
        if isRotated {
            self.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)
        }
        
        if let displayHeader {
            if self.peerContentNode == nil {
                let sectionSeparator = ChatMessageDateSectionSeparatorNode(controllerInteraction: controllerInteraction, presentationData: presentationData)
                self.sectionSeparator = sectionSeparator
                self.addSubnode(sectionSeparator)
                
                let peerContentNode = ChatMessagePeerContentNode(context: self.context, presentationData: self.presentationData, controllerInteraction: self.controllerInteraction, displayHeader: displayHeader)
                self.peerContentNode = peerContentNode
                self.addSubnode(peerContentNode)
            }
        } else {
            if self.dateContentNode == nil {
                let dateContentNode = ChatMessageDateContentNode(presentationData: self.presentationData, controllerInteraction: self.controllerInteraction, localTimestamp: self.localTimestamp, scheduled: self.scheduled)
                self.dateContentNode = dateContentNode
                self.addSubnode(dateContentNode)
            }
        }
    }

    override public func didLoad() {
        super.didLoad()
        
        self.view.addGestureRecognizer(ListViewTapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))
    }
    
    public func updateItem(hasDate: Bool, hasPeer: Bool) {
    }
    
    public func updatePresentationData(_ presentationData: ChatPresentationData, context: AccountContext) {
        if let dateContentNode = self.dateContentNode {
            dateContentNode.updatePresentationData(presentationData, context: context)
        }
        if let peerContentNode = self.peerContentNode {
            peerContentNode.updatePresentationData(presentationData, context: context)
        }
        // A switch of bubble mode changes who hides the date (its alpha, or its glass): it takes the current flashing.
        self.updateFlashing(animated: false)

        self.setNeedsLayout()
    }
    
    public func updateBackgroundColor(color: UIColor, enableBlur: Bool) {
        if let dateContentNode = self.dateContentNode {
            dateContentNode.updateBackgroundColor(color: color, enableBlur: enableBlur)
        }
        if let peerContentNode = self.peerContentNode {
            peerContentNode.updateBackgroundColor(color: color, enableBlur: enableBlur)
        }
    }
    
    override public func updateAbsoluteRect(_ rect: CGRect, within containerSize: CGSize) {
        /*self.absolutePosition = (rect, containerSize)
        if let backgroundContent = self.backgroundContent {
            var backgroundFrame = backgroundContent.frame
            backgroundFrame.origin.x += rect.minX
            backgroundFrame.origin.y += containerSize.height - rect.minY
            backgroundContent.update(rect: backgroundFrame, within: containerSize, transition: .immediate)
        }*/
    }
    
    override public func updateLayout(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition) {
        self.params = (size, leftInset, rightInset)
        
        var contentOffsetY: CGFloat = 0.0
        var isFirst = true
        if let dateContentNode = self.dateContentNode {
            if isFirst {
                isFirst = false
                contentOffsetY += 7.0
            } else {
                contentOffsetY += 7.0
            }
            let contentFrame = CGRect(origin: CGPoint(x: 0.0, y: contentOffsetY), size: CGSize(width: size.width, height: 20.0))
            transition.updateFrame(node: dateContentNode, frame: contentFrame)
            dateContentNode.update(size: contentFrame.size, leftInset: leftInset, rightInset: rightInset, transition: transition)
            contentOffsetY += 20.0
        }
        if let peerContentNode = self.peerContentNode {
            if isFirst {
                isFirst = false
                contentOffsetY += 7.0
            } else {
                contentOffsetY += 7.0
            }
            let contentFrame = CGRect(origin: CGPoint(x: 0.0, y: contentOffsetY), size: CGSize(width: size.width, height: 20.0))
            transition.updateFrame(node: peerContentNode, frame: contentFrame)
            peerContentNode.update(size: contentFrame.size, leftInset: leftInset, rightInset: rightInset, transition: transition)
            contentOffsetY += 20.0
            
            if let sectionSeparator = self.sectionSeparator {
                let sectionSeparatorFrame = CGRect(origin: CGPoint(x: 0.0, y: contentFrame.minY + floorToScreenPixels((contentFrame.height - 1.66) * 0.5)), size: CGSize(width: size.width, height: 1.66))
                sectionSeparator.update(size: sectionSeparatorFrame.size, transition: transition)
                transition.updatePosition(node: sectionSeparator, position: sectionSeparatorFrame.center)
                transition.updateBounds(node: sectionSeparator, bounds: CGRect(origin: CGPoint(), size: sectionSeparatorFrame.size))
            }
        }
        contentOffsetY += 7.0
    }
    
    override public func updateStickDistanceFactor(_ factor: CGFloat, distance: CGFloat, transition: ContainedViewLayoutTransition) {
        if !self.stickDistanceFactor.isEqual(to: factor) {
            if let dateContentNode = self.dateContentNode {
                dateContentNode.updateStickDistanceFactor(factor, transition: transition)
            }
            if let peerContentNode = self.peerContentNode {
                peerContentNode.updateStickDistanceFactor(factor, transition: transition)
            }
            
            let wasZero = self.stickDistanceFactor < 0.5
            let isZero = factor < 0.5
            self.stickDistanceFactor = factor
            
            if wasZero != isZero {
                var animated = true
                if case .immediate = transition {
                    animated = false
                }
                self.updateFlashing(animated: animated)
            }
        }
        
        if let sectionSeparator = self.sectionSeparator {
            transition.updateTransform(node: sectionSeparator, transform: CGAffineTransformMakeTranslation(0.0, -distance))
        }
    }
    
    override public func updateFlashingOnScrolling(_ isFlashingOnScrolling: Bool, animated: Bool) {
        self.flashingOnScrolling = isFlashingOnScrolling
        self.updateFlashing(animated: animated)
    }
    
    private func updateFlashing(animated: Bool) {
        let flashing = self.flashingOnScrolling || self.stickDistanceFactor < 0.5
        
        let alpha: CGFloat = flashing ? 1.0 : 0.0
        
        if let dateContentNode = self.dateContentNode {
            if dateContentNode.bubblelessTakesTaps != nil {
                // Without bubbles the date shows or hides its parts itself: its island is glass.
                if dateContentNode.alpha != 1.0 {
                    dateContentNode.layer.removeAnimation(forKey: "opacity")
                    dateContentNode.alpha = 1.0
                }
                dateContentNode.updateBubblelessFlashing(flashing, animated: animated)
            } else {
                let previousAlpha = dateContentNode.alpha
                
                if !previousAlpha.isEqual(to: alpha) {
                    dateContentNode.alpha = alpha
                    if animated {
                        let duration: Double = flashing ? 0.3 : 0.4
                        dateContentNode.layer.animateAlpha(from: previousAlpha, to: alpha, duration: duration)
                    }
                }
            }
        }
        
        if let peerContentNode = self.peerContentNode {
            let previousAlpha = peerContentNode.alpha
            
            if !previousAlpha.isEqual(to: alpha) {
                peerContentNode.alpha = alpha
                if animated {
                    let duration: Double = flashing ? 0.3 : 0.4
                    peerContentNode.layer.animateAlpha(from: previousAlpha, to: alpha, duration: duration)
                }
            }
        }
    }
    
    override public func animateRemoved(duration: Double) {
        self.alpha = 0.0
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: duration, removeOnCompletion: false)
        if self.dateContentNode != nil {
            self.layer.animateScale(from: 1.0, to: 0.2, duration: duration, removeOnCompletion: false)
        }
    }

    override public func animateAdded(duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: self.alpha, duration: 0.2)
        if self.dateContentNode != nil {
            self.layer.animateScale(from: 0.2, to: 1.0, duration: 0.2)
        }
    }
    
    override public func getEffectiveAlpha() -> CGFloat {
        if let dateContentNode = self.dateContentNode {
            if let takesTaps = dateContentNode.bubblelessTakesTaps {
                return takesTaps ? 1.0 : 0.0
            }
            return dateContentNode.alpha
        }
        if let peerContentNode = self.peerContentNode {
            return peerContentNode.alpha
        }
        return 0.0
    }

    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !self.bounds.contains(point) {
            return nil
        }
        if let dateContentNode = self.dateContentNode {
            if dateContentNode.frame.contains(point) {
                if dateContentNode.alpha.isZero || dateContentNode.bubblelessTakesTaps == false {
                    return nil
                }
                
                if dateContentNode.backgroundNode.frame.contains(point.offsetBy(dx: -dateContentNode.frame.minX, dy: -dateContentNode.frame.minY)) {
                    return self.view
                }
            }
        }
        if let peerContentNode = self.peerContentNode {
            if peerContentNode.frame.contains(point) {
                if peerContentNode.alpha.isZero {
                    return nil
                }
                
                if peerContentNode.backgroundNode.frame.contains(point.offsetBy(dx: -peerContentNode.frame.minX, dy: -peerContentNode.frame.minY)) {
                    return self.view
                }
            }
        }
        return nil
    }
    
    override public func touchesCancelled(_ touches: Set<UITouch>?, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
    }
    
    @objc private func tapGesture(_ recognizer: ListViewTapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.action?(self.localTimestamp, self.stickDistanceFactor < 0.5)
        }
    }
}

private func avatarHeaderSize() -> CGFloat {
    return chatMessageAvatarHeaderSize
}

public final class ChatMessageAvatarHeader: ListViewItemHeader {
    public struct Id: Hashable {
        public var peerId: EnginePeer.Id
        public var timestampId: Int32
    }

    public let id: ListViewItemNode.HeaderId
    public let stackingId: ListViewItemNode.HeaderId? = nil
    public let peerId: EnginePeer.Id
    public let peer: EnginePeer?
    public let messageReference: MessageReference?
    public let adMessageId: EngineMessage.Id?
    public let effectiveTimestamp: Int32
    public let presentationData: ChatPresentationData
    public let context: AccountContext
    public let controllerInteraction: ChatControllerInteraction?
    public let storyStats: EnginePeerStoryStats?

    public init(timestamp: Int32, peerId: EnginePeer.Id, peer: EnginePeer?, messageReference: MessageReference?, message: EngineMessage, presentationData: ChatPresentationData, context: AccountContext, controllerInteraction: ChatControllerInteraction?, storyStats: EnginePeerStoryStats?) {
        let message = message._asMessage()
        self.peerId = peerId
        self.peer = peer
        self.messageReference = messageReference
        if message.adAttribute != nil {
            self.adMessageId = message.id
        } else {
            self.adMessageId = nil
        }

        var effectiveTimestamp = message.timestamp
        if let forwardInfo = message.forwardInfo, forwardInfo.flags.contains(.isImported) {
            effectiveTimestamp = forwardInfo.date
        }
        self.effectiveTimestamp = effectiveTimestamp

        self.presentationData = presentationData
        self.context = context
        self.controllerInteraction = controllerInteraction
        self.id = ListViewItemNode.HeaderId(space: 1, id: Id(peerId: peerId, timestampId: dateHeaderTimestampId(timestamp: timestamp)))
        self.storyStats = storyStats
        
        let isRotated = controllerInteraction?.chatIsRotated ?? true
        
        if presentationData.chatBubbleCorners.bubbleMode {
            self.stickDirection = isRotated ? .top : .bottom
        } else {
            // Without bubbles the avatar heads its run beside the author's name and sticks to the top of the
            // chat while the rest of the run scrolls by.
            self.stickDirection = isRotated ? .bottom : .top
        }
    }
    
    public let stickDirection: ListViewItemHeaderStickDirection
    public let stickOverInsets: Bool = false

    public let height: CGFloat = avatarHeaderSize()

    public func combinesWith(other: ListViewItemHeader) -> Bool {
        if let other = other as? ChatMessageAvatarHeader, other.id == self.id {
            if abs(self.effectiveTimestamp - other.effectiveTimestamp) >= chatMessageBubblelessRunInterval {
                return false
            }
            return true
        } else {
            return false
        }
    }

    public func node(synchronousLoad: Bool) -> ListViewItemHeaderNode {
        return ChatMessageAvatarHeaderNodeImpl(peerId: self.peerId, peer: self.peer, messageReference: self.messageReference, adMessageId: self.adMessageId, presentationData: self.presentationData, context: self.context, controllerInteraction: self.controllerInteraction, storyStats: self.storyStats, synchronousLoad: synchronousLoad)
    }

    public func updateNode(_ node: ListViewItemHeaderNode, previous: ListViewItemHeader?, next: ListViewItemHeader?) {
        guard let node = node as? ChatMessageAvatarHeaderNodeImpl else {
            return
        }
        node.updatePresentationData(self.presentationData, context: self.context)
        if let peer = self.peer {
            node.updatePeer(peer: peer)
        }
        node.updateStoryStats(storyStats: self.storyStats, theme: self.presentationData.theme.theme, force: false)
    }
}

private let avatarFont = avatarPlaceholderFont(size: 16.0)

private let maxVideoLoopCount = 3

public final class ChatMessageAvatarHeaderNodeImpl: ListViewItemHeaderNode, ChatMessageAvatarHeaderNode {
    private let context: AccountContext
    private var presentationData: ChatPresentationData
    private let controllerInteraction: ChatControllerInteraction?
    private var storyStats: EnginePeerStoryStats?
    
    private let peerId: EnginePeer.Id
    private let messageReference: MessageReference?
    private var peer: EnginePeer?
    private let adMessageId: EngineMessage.Id?

    private let containerNode: ContextControllerSourceNode
    public let avatarNode: AvatarNode
    private var avatarVideoNode: AvatarVideoNode?
        
    private var cachedDataDisposable = MetaDisposable()
    private var hierarchyTrackingLayer: HierarchyTrackingLayer?
    
    private var backgroundContent: WallpaperBubbleBackgroundNode?
    
    private var isAvatarHidden: Bool = false
    private let onlineMarkerLayer = CAShapeLayer()
    private let onlinePresenceDisposable = MetaDisposable()
    private var onlinePresenceTimer: SwiftSignalKit.Timer?
    private var onlineSettingsObserver: NSObjectProtocol?
    private var onlinePresenceActive = false
    private var onlinePresenceVisible = false
    private var usesCustomLetters = false
    
    // MARK: AyuGram
    private var ayuOnlineNode: PeerOnlineMarkerNode?
    private let ayuPresenceDisposable = MetaDisposable()
    private var ayuIsObservingPresence: Bool = false
    private var ayuDidReceivePresence: Bool = false
    private var ayuPresence: EnginePeer.Presence?
    private var ayuOnlineTimer: SwiftSignalKit.Timer?
    private var ayuIsOnline: Bool = false
    
    private var trackingIsInHierarchy: Bool = false {
        didSet {
            if self.trackingIsInHierarchy != oldValue {
                Queue.mainQueue().justDispatch {
                    if self.trackingIsInHierarchy {
                        self.avatarVideoNode?.resetPlayback()
                    }
                    self.updateVideoVisibility()
                }
            }
        }
    }
    
    public init(peerId: EnginePeer.Id, peer: EnginePeer?, messageReference: MessageReference?, adMessageId: EngineMessage.Id?, presentationData: ChatPresentationData, context: AccountContext, controllerInteraction: ChatControllerInteraction?, storyStats: EnginePeerStoryStats?, synchronousLoad: Bool) {
        self.peerId = peerId
        self.peer = peer
        self.messageReference = messageReference
        self.adMessageId = adMessageId
        self.presentationData = presentationData
        self.context = context
        self.controllerInteraction = controllerInteraction
        self.storyStats = storyStats

        self.containerNode = ContextControllerSourceNode()

        self.avatarNode = AvatarNode(font: avatarFont)
        self.avatarNode.contentNode.displaysAsynchronously = !presentationData.isPreview

        let isRotated = controllerInteraction?.chatIsRotated ?? true
        
        super.init(layerBacked: false, isRotated: isRotated, seeThrough: false)

        if isRotated {
            self.transform = CATransform3DMakeRotation(CGFloat.pi, 0.0, 0.0, 1.0)
        }

        self.addSubnode(self.containerNode)
        self.containerNode.addSubnode(self.avatarNode)
        self.onlineMarkerLayer.isHidden = true
        self.onlineMarkerLayer.lineWidth = 2.0
        self.avatarNode.layer.addSublayer(self.onlineMarkerLayer)
        self.onlineSettingsObserver = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.updateOnlinePresenceSubscription()
        })

        if let peer = peer {
            self.setPeer(context: context, theme: presentationData.theme.theme, synchronousLoad: synchronousLoad, peer: peer, authorOfMessage: messageReference, emptyColor: .black)
        }
        
        if let storyStats {
            self.updateStoryStats(storyStats: storyStats, theme: presentationData.theme.theme, force: true)
        }

        self.containerNode.activated = { [weak self] gesture, _ in
            guard let strongSelf = self, let peer = strongSelf.peer?._asPeer() else {
                return
            }
            var messageId: EngineMessage.Id?
            if let messageReference = messageReference, case let .message(_, _, id, _, _, _, _) = messageReference.content {
                messageId = id
            }
            strongSelf.controllerInteraction?.openPeerContextMenu(peer, messageId, strongSelf.containerNode, strongSelf.containerNode.bounds, gesture)
        }

        self.updateSelectionState(animated: false)
        
        // MARK: AyuGram
        self.ayuUpdateOnlineObservation()
    }
    
    deinit {
        self.cachedDataDisposable.dispose()
        self.onlinePresenceDisposable.dispose()
        self.onlinePresenceTimer?.invalidate()
        if let observer = self.onlineSettingsObserver { NotificationCenter.default.removeObserver(observer) }
        // MARK: AyuGram
        self.ayuPresenceDisposable.dispose()
        self.ayuOnlineTimer?.invalidate()
    }

    override public func didEnterHierarchy() {
        super.didEnterHierarchy()
        self.onlinePresenceVisible = true
        self.updateOnlinePresenceSubscription()
    }

    override public func didExitHierarchy() {
        super.didExitHierarchy()
        self.onlinePresenceVisible = false
        self.updateOnlinePresenceSubscription()
    }

    private func updateOnlinePresenceSubscription() {
        let eligible: Bool
        if let peer = self.peer, case let .user(user) = peer {
            eligible = user.botInfo == nil && !user.isDeleted && user.id != self.context.account.peerId
        } else {
            eligible = false
        }
        let active = self.onlinePresenceVisible && !self.usesCustomLetters && eligible && ExteraMessageSettings.shared.showOnlineStatus
        guard active != self.onlinePresenceActive else { return }
        self.onlinePresenceActive = active
        self.onlinePresenceDisposable.set(nil)
        self.onlinePresenceTimer?.invalidate()
        self.onlinePresenceTimer = nil
        self.onlineMarkerLayer.isHidden = true
        guard active else { return }
        self.onlinePresenceDisposable.set((self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Presence(id: self.peerId))
        |> deliverOnMainQueue).startStrict(next: { [weak self] presence in
            guard let self, self.onlinePresenceActive else { return }
            self.onlinePresenceTimer?.invalidate()
            self.onlinePresenceTimer = nil
            let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
            // A hidden/recently/unknown presence never implies online.
            guard let presence, case let .present(until) = presence.status, until >= now else {
                self.onlineMarkerLayer.isHidden = true
                return
            }
            self.onlineMarkerLayer.isHidden = false
            let timer = SwiftSignalKit.Timer(timeout: max(1.0, Double(Int64(until) - Int64(now) + 1)), repeat: false, completion: { [weak self] in
                self?.onlineMarkerLayer.isHidden = true
                self?.onlinePresenceTimer = nil
            }, queue: Queue.mainQueue())
            self.onlinePresenceTimer = timer
            timer.start()
        }))
    }
    
    // MARK: AyuGram
    // exteraGram "Show Online Indicator": the chat list's online dot on the avatar of a sender who is online.
    private func ayuUpdateOnlineObservation() {
        var isEligible = false
        if ayuDrawsSenderOnlineDot, ExteraSettings.shared.showOnlineStatus, !self.presentationData.isPreview, self.adMessageId == nil, case let .user(user) = self.peer, user.botInfo == nil, !user.flags.contains(.isSupport), !isServicePeer(user), user.id != self.context.account.peerId {
            isEligible = true
        }
        if isEligible == self.ayuIsObservingPresence {
            return
        }
        self.ayuIsObservingPresence = isEligible
        
        if isEligible {
            self.ayuDidReceivePresence = false
            self.ayuPresenceDisposable.set((self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Presence(id: self.peerId))
            |> deliverOnMainQueue).startStrict(next: { [weak self] presence in
                guard let self else {
                    return
                }
                // As on Android, the dot is simply there with the avatar and animates only on later changes.
                let animated = self.ayuDidReceivePresence
                self.ayuDidReceivePresence = true
                self.ayuPresence = presence
                self.ayuUpdateIsOnline(animated: animated)
            }))
        } else {
            self.ayuPresenceDisposable.set(nil)
            self.ayuPresence = nil
            self.ayuUpdateIsOnline(animated: true)
        }
    }
    
    private func ayuUpdateIsOnline(animated: Bool) {
        self.ayuOnlineTimer?.invalidate()
        self.ayuOnlineTimer = nil
        
        var isOnline = false
        if let presence = self.ayuPresence, case let .present(until) = presence.status {
            // The same clock and comparison as the chat list's dot.
            let timestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
            if until >= timestamp {
                isOnline = true
                // No update arrives when "online until" runs out.
                let timer = SwiftSignalKit.Timer(timeout: Double(until) - Double(timestamp) + 1.0, repeat: false, completion: { [weak self] in
                    self?.ayuUpdateIsOnline(animated: true)
                }, queue: Queue.mainQueue())
                self.ayuOnlineTimer = timer
                timer.start()
            }
        }
        if isOnline == self.ayuIsOnline {
            return
        }
        self.ayuIsOnline = isOnline
        
        let onlineNode: PeerOnlineMarkerNode
        if let current = self.ayuOnlineNode {
            onlineNode = current
        } else {
            onlineNode = PeerOnlineMarkerNode()
            onlineNode.setImage(PresentationResourcesChatList.recentStatusOnlineIcon(self.presentationData.theme.theme, state: .regular), color: nil, transition: .immediate)
            self.ayuOnlineNode = onlineNode
            self.avatarNode.addSubnode(onlineNode)
        }
        let (onlineSize, onlineApply) = onlineNode.asyncLayout()(isOnline, false)
        // Android's proportions: the dot with its ring is 16/54 of the avatar, centred 6dp from the right and 8dp from the bottom of a 42dp avatar.
        let avatarSize = avatarHeaderSize()
        let onlineScale = (avatarSize * 16.0 / 54.0) / onlineSize.width
        onlineNode.bounds = CGRect(origin: CGPoint(), size: onlineSize)
        onlineNode.position = CGPoint(x: avatarSize * (1.0 - 6.0 / 42.0), y: avatarSize * (1.0 - 8.0 / 42.0))
        onlineNode.transform = CATransform3DMakeScale(onlineScale, onlineScale, 1.0)
        onlineApply(animated)
    }

    public func setCustomLetters(context: AccountContext, theme: PresentationTheme, synchronousLoad: Bool, letters: [String], emptyColor: UIColor) {
        self.containerNode.isGestureEnabled = false
        self.usesCustomLetters = true
        self.updateOnlinePresenceSubscription()

        self.avatarNode.setCustomLetters(letters, icon: !letters.isEmpty ? nil : .phone, roundingScope: .chatMessage)
    }
    
    public func updatePeer(peer enginePeer: EnginePeer) {
        let peer = enginePeer._asPeer()
        if let previousPeer = self.peer?._asPeer(), previousPeer.nameColor != peer.nameColor || previousPeer.smallProfileImage != peer.smallProfileImage || previousPeer.displayLetters != peer.displayLetters {
            self.peer = enginePeer
            if peer.smallProfileImage != nil {
                self.avatarNode.setPeerV2(context: self.context, theme: self.presentationData.theme.theme, peer: enginePeer, authorOfMessage: self.messageReference, overrideImage: nil, emptyColor: .black, synchronousLoad: false, displayDimensions: CGSize(width: avatarHeaderSize(), height: avatarHeaderSize()), roundingScope: .chatMessage)
            } else {
                self.avatarNode.setPeer(context: self.context, theme: self.presentationData.theme.theme, peer: enginePeer, authorOfMessage: self.messageReference, overrideImage: nil, emptyColor: .black, synchronousLoad: false, displayDimensions: CGSize(width: avatarHeaderSize(), height: avatarHeaderSize()), roundingScope: .chatMessage)
            }
        }
    }

    public func setPeer(context: AccountContext, theme: PresentationTheme, synchronousLoad: Bool, peer enginePeer: EnginePeer, authorOfMessage: MessageReference?, emptyColor: UIColor) {
        let peer = enginePeer._asPeer()
        if let messageReference = self.messageReference, let id = messageReference.id {
            self.containerNode.isGestureEnabled = !id.peerId.isVerificationCodes
        } else {
            self.containerNode.isGestureEnabled = true
        }

        var overrideImage: AvatarNodeImageOverride?
        if peer.isDeleted {
            overrideImage = .deletedIcon
        }
        if peer.smallProfileImage != nil {
            self.avatarNode.setPeerV2(context: context, theme: theme, peer: enginePeer, authorOfMessage: authorOfMessage, overrideImage: overrideImage, emptyColor: emptyColor, synchronousLoad: synchronousLoad, displayDimensions: CGSize(width: avatarHeaderSize(), height: avatarHeaderSize()), roundingScope: .chatMessage)
        } else {
            self.avatarNode.setPeer(context: context, theme: theme, peer: enginePeer, authorOfMessage: authorOfMessage, overrideImage: overrideImage, emptyColor: emptyColor, synchronousLoad: synchronousLoad, displayDimensions: CGSize(width: avatarHeaderSize(), height: avatarHeaderSize()), roundingScope: .chatMessage)
        }
        
        if peer.isPremium && context.sharedContext.energyUsageSettings.autoplayVideo {
            self.cachedDataDisposable.set((context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.CachedData(id: peer.id))
            |> deliverOnMainQueue).startStrict(next: { [weak self] cachedData in
                guard let strongSelf = self else {
                    return
                }

                let cachedPeerData = cachedData as? CachedUserData
                var personalPhoto: TelegramMediaImage?
                var profilePhoto: TelegramMediaImage?
                var isKnown = false
                
                if let cachedPeerData = cachedPeerData {
                    if case let .known(maybePersonalPhoto) = cachedPeerData.personalPhoto {
                        personalPhoto = maybePersonalPhoto
                        isKnown = true
                    }
                    if case let .known(maybePhoto) = cachedPeerData.photo {
                        profilePhoto = maybePhoto
                        isKnown = true
                    }
                    if profilePhoto == nil, case let .known(maybePhoto) = cachedPeerData.fallbackPhoto {
                        profilePhoto = maybePhoto
                        isKnown = true
                    }
                }
                
                if isKnown {
                    let photo = personalPhoto ?? profilePhoto
                    if let photo = photo, !photo.videoRepresentations.isEmpty || photo.emojiMarkup != nil {
                        let videoNode: AvatarVideoNode
                        if let current = strongSelf.avatarVideoNode {
                            videoNode = current
                        } else {
                            videoNode = AvatarVideoNode(context: context)
                            strongSelf.avatarNode.contentNode.addSubnode(videoNode)
                            strongSelf.avatarVideoNode = videoNode
                        }
                        videoNode.update(peer: enginePeer, photo: photo, size: CGSize(width: avatarHeaderSize(), height: avatarHeaderSize()))
                        
                        if strongSelf.hierarchyTrackingLayer == nil {
                            let hierarchyTrackingLayer = HierarchyTrackingLayer()
                            hierarchyTrackingLayer.didEnterHierarchy = { [weak self] in
                                guard let strongSelf = self else {
                                    return
                                }
                                strongSelf.trackingIsInHierarchy = true
                            }
                            
                            hierarchyTrackingLayer.didExitHierarchy = { [weak self] in
                                guard let strongSelf = self else {
                                    return
                                }
                                strongSelf.trackingIsInHierarchy = false
                            }
                            strongSelf.hierarchyTrackingLayer = hierarchyTrackingLayer
                            strongSelf.layer.addSublayer(hierarchyTrackingLayer)
                        }
                    } else {
                        if let avatarVideoNode = strongSelf.avatarVideoNode {
                            avatarVideoNode.removeFromSupernode()
                            strongSelf.avatarVideoNode = nil
                        }
                        strongSelf.hierarchyTrackingLayer?.removeFromSuperlayer()
                        strongSelf.hierarchyTrackingLayer = nil
                    }
                    strongSelf.updateVideoVisibility()
                } else {
                    if let photo = peer.largeProfileImage, photo.hasVideo {
                        let _ = context.engine.peers.fetchAndUpdateCachedPeerData(peerId: peer.id).startStandalone()
                    }
                }
            }))
        } else {            
            self.cachedDataDisposable.set(nil)
            
            self.avatarVideoNode?.removeFromSupernode()
            self.avatarVideoNode = nil
            
            self.hierarchyTrackingLayer?.removeFromSuperlayer()
            self.hierarchyTrackingLayer = nil
        }
    }
    
    public func updateStoryStats(storyStats: EnginePeerStoryStats?, theme: PresentationTheme, force: Bool) {
        /*if storyStats != nil {
            var backgroundContent: WallpaperBubbleBackgroundNode?
            if let current = self.backgroundContent {
                backgroundContent = current
            } else {
                if let backgroundContentValue = self.controllerInteraction.presentationContext.backgroundNode?.makeBubbleBackground(for: .free) {
                    backgroundContentValue.clipsToBounds = true
                    self.backgroundContent = backgroundContentValue
                    backgroundContent = backgroundContentValue
                    self.containerNode.insertSubnode(backgroundContentValue, belowSubnode: self.avatarNode)
                    
                    let maskLayer = SimpleShapeLayer()
                    maskLayer.fillColor = nil
                    maskLayer.strokeColor = UIColor.white.cgColor
                    maskLayer.lineWidth = 2.0
                    maskLayer.path = UIBezierPath(ovalIn: CGRect(origin: CGPoint(), size: CGSize(width: 38.0, height: 38.0)).insetBy(dx: 1.0, dy: 1.0)).cgPath
                    backgroundContentValue.layer.mask = maskLayer
                }
            }
            
            if let backgroundContent {
                backgroundContent.frame = CGRect(origin: CGPoint(), size: CGSize(width: 38.0, height: 38.0))
                backgroundContent.cornerRadius = backgroundContent.bounds.width * 0.5
            }
        } else {
            if let backgroundContent = self.backgroundContent {
                self.backgroundContent = nil
                backgroundContent.removeFromSupernode()
            }
        }
        
        if self.storyStats != storyStats || self.presentationData.theme.theme !== theme || force {
            var colors = AvatarNode.Colors(theme: theme)
            colors.seenColors = [UIColor(white: 1.0, alpha: 0.2), UIColor(white: 1.0, alpha: 0.2)]
            self.avatarNode.setStoryStats(storyStats: storyStats.flatMap { storyStats in
                return AvatarNode.StoryStats(
                    totalCount: storyStats.totalCount != 0 ? 1 : 0,
                    unseenCount: storyStats.unseenCount != 0 ? 1 : 0,
                    hasUnseenCloseFriendsItems: storyStats.hasUnseenCloseFriends
                )
            }, presentationParams: AvatarNode.StoryPresentationParams(
                colors: colors,
                lineWidth: 2.0,
                inactiveLineWidth: 2.0
            ), transition: .immediate)
        }*/
    }

    override public func didLoad() {
        super.didLoad()

        self.avatarNode.view.addGestureRecognizer(ListViewTapGestureRecognizer(target: self, action: #selector(self.tapGesture(_:))))
    }

    public func updatePresentationData(_ presentationData: ChatPresentationData, context: AccountContext) {
        if self.presentationData !== presentationData {
            self.presentationData = presentationData
            self.setNeedsLayout()
        }
        // MARK: AyuGram
        self.ayuOnlineNode?.setImage(PresentationResourcesChatList.recentStatusOnlineIcon(presentationData.theme.theme, state: .regular), color: nil, transition: .immediate)
        self.ayuUpdateOnlineObservation()
    }

    override public func updateLayout(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition) {
        // Without bubbles the message rows trim the run so that its top edge is already where the avatar
        // belongs, level with the author's name and first line.
        let avatarOriginY: CGFloat = self.presentationData.chatBubbleCorners.bubbleMode ? -3.0 : 0.0
        transition.updateFrame(node: self.containerNode, frame: CGRect(origin: CGPoint(x: leftInset + chatMessageAvatarHeaderInset, y: avatarOriginY), size: CGSize(width: avatarHeaderSize(), height: avatarHeaderSize())))
        let avatarFrame = CGRect(origin: CGPoint(), size: CGSize(width: avatarHeaderSize(), height: avatarHeaderSize()))
        self.avatarNode.position = avatarFrame.center
        self.avatarNode.bounds = CGRect(origin: CGPoint(), size: avatarFrame.size)
        self.avatarNode.updateSize(size: avatarFrame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.onlineMarkerLayer.frame = CGRect(x: avatarFrame.width - 12.0, y: avatarFrame.height - 12.0, width: 12.0, height: 12.0)
        self.onlineMarkerLayer.path = UIBezierPath(ovalIn: CGRect(x: 1.0, y: 1.0, width: 10.0, height: 10.0)).cgPath
        self.onlineMarkerLayer.fillColor = self.presentationData.theme.theme.chatList.onlineDotColor.cgColor
        self.onlineMarkerLayer.strokeColor = self.presentationData.theme.theme.chatList.backgroundColor.cgColor
        CATransaction.commit()
    }

    override public func animateRemoved(duration: Double) {
        self.alpha = 0.0
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: duration, removeOnCompletion: false)
        if !self.isAvatarHidden {
            self.avatarNode.layer.animateScale(from: 1.0, to: 0.2, duration: duration, removeOnCompletion: false)
        }
    }

    override public func animateAdded(duration: Double) {
        self.layer.animateAlpha(from: 0.0, to: self.alpha, duration: 0.2)
        self.avatarNode.layer.animateScale(from: 0.2, to: 1.0, duration: 0.2)
    }

    override public func updateStickDistanceFactor(_ factor: CGFloat, distance: CGFloat, transition: ContainedViewLayoutTransition) {
    }

    override public func updateFlashingOnScrolling(_ isFlashingOnScrolling: Bool, animated: Bool) {
    }
    
    private var currentSelectionOffset: CGFloat = 0.0

    public func updateSelectionState(animated: Bool) {
        let currentSelectionOffset = self.currentSelectionOffset
        let offset: CGFloat = self.controllerInteraction?.selectionState != nil ? 42.0 : 0.0
        self.currentSelectionOffset = offset

        let previousSubnodeTransform = CATransform3DMakeTranslation(currentSelectionOffset, 0.0, 0.0)
        self.subnodeTransform = CATransform3DMakeTranslation(offset, 0.0, 0.0)
        if animated {
            self.layer.animate(from: NSValue(caTransform3D: previousSubnodeTransform), to: NSValue(caTransform3D: self.subnodeTransform), keyPath: "sublayerTransform", timingFunction: CAMediaTimingFunctionName.easeOut.rawValue, duration: 0.2)
        }
    }
    
    public func updateAvatarIsHidden(isHidden: Bool, transition: ContainedViewLayoutTransition) {
        self.isAvatarHidden = isHidden
        var avatarTransform: CATransform3D = CATransform3DIdentity
        if isHidden {
            let scale: CGFloat = isHidden ? 0.001 : 1.0
            avatarTransform = CATransform3DTranslate(avatarTransform, -avatarHeaderSize() * 0.5, avatarHeaderSize() * 0.5, 0.0)
            avatarTransform = CATransform3DScale(avatarTransform, scale, scale, 1.0)
        }
        transition.updateTransform(node: self.avatarNode, transform: avatarTransform)
        transition.updateAlpha(node: self.avatarNode, alpha: isHidden ? 0.0 : 1.0)
    }

    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !self.bounds.contains(point) {
            return nil
        }
        let result = self.containerNode.view.hitTest(self.view.convert(point, to: self.containerNode.view), with: event)
        return result
    }

    override public func touchesCancelled(_ touches: Set<UITouch>?, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
    }

    @objc private func tapGesture(_ recognizer: ListViewTapGestureRecognizer) {
        if case .ended = recognizer.state {
            if self.peerId.namespace == Namespaces.Peer.Empty, case let .message(_, _, id, _, _, _, _) = self.messageReference?.content {
                self.controllerInteraction?.displayMessageTooltip(id, self.presentationData.strings.Conversation_ForwardAuthorHiddenTooltip, false, self, self.avatarNode.frame)
            } else if let peer = self.peer?._asPeer() {
                if peer.id.isVerificationCodes {
                    self.controllerInteraction?.playShakeAnimation()
                } else if let adMessageId = self.adMessageId {
                    self.controllerInteraction?.activateAdAction(adMessageId, nil, false, false)
                } else {
                    if let channel = peer as? TelegramChannel, case .broadcast = channel.info {
                        self.controllerInteraction?.openPeer(EnginePeer(peer), .chat(textInputState: nil, subject: nil, peekData: nil), self.messageReference, .default)
                    } else {
                        self.controllerInteraction?.openPeer(EnginePeer(peer), .info(nil), self.messageReference, .groupParticipant(storyStats: nil, avatarHeaderNode: self))
                    }
                }
            }
        }
    }
    
    private func updateVideoVisibility() {
        let isVisible = self.trackingIsInHierarchy
        self.avatarVideoNode?.updateVisibility(isVisible)
      
        if let videoNode = self.avatarVideoNode {
            videoNode.updateLayout(size: self.avatarNode.bounds.size, cornerRadius: self.avatarNode.ayuVideoCornerRadius(size: self.avatarNode.bounds.size), transition: .immediate)
            videoNode.frame = self.avatarNode.bounds
        }
    }
}
