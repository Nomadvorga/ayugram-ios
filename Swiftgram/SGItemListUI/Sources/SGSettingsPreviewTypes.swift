import UIKit
import Display

/// Value-only inputs for a settings illustration. Raw ids match ExteraStickerSettings,
/// but this UI layer neither imports that model nor reads persisted preferences.
public struct SGStickerPreviewConfiguration: Equatable {
    public var size: Int32
    /// 0: default overlay, 1: side (with safe fallback), 2: hidden.
    public var timeMode: Int
    /// 0: original, 1: 6pt corners, 2: bubbleRadius.
    public var shape: Int
    public var bubbleRadius: CGFloat
    public var replyColors: Bool
    public var replyEmoji: Bool
    public var replyBackground: Bool
    public var title: String
    public var smallLabel: String
    public var largeLabel: String
    public var largeBadge: String
    public var timeText: String
    public var replyTitle: String
    public var replyText: String
    public var emoji: String
    public var stickerLabel: String

    public init(size: Int32, timeMode: Int = 0, shape: Int = 1, bubbleRadius: CGFloat = 20.0, replyColors: Bool = true, replyEmoji: Bool = true, replyBackground: Bool = true, title: String, smallLabel: String, largeLabel: String, largeBadge: String, timeText: String, replyTitle: String, replyText: String, emoji: String = "", stickerLabel: String = "") {
        self.size = size
        self.timeMode = timeMode
        self.shape = shape
        self.bubbleRadius = bubbleRadius
        self.replyColors = replyColors
        self.replyEmoji = replyEmoji
        self.replyBackground = replyBackground
        self.title = title
        self.smallLabel = smallLabel
        self.largeLabel = largeLabel
        self.largeBadge = largeBadge
        self.timeText = timeText
        self.replyTitle = replyTitle
        self.replyText = replyText
        self.emoji = emoji
        self.stickerLabel = stickerLabel
    }
}

/// No author/account/message is fabricated by the renderer: callers provide illustrative strings.
public struct SGMessagePreviewConfiguration: Equatable {
    public var author: String
    public var text: String
    public var timeText: String
    public var editedText: String
    public var removeTail: Bool
    public var showEdited: Bool
    public var editedIcon: Bool
    public var onlineDot: Bool
    public var showForwardCount: Bool
    public var forwardCount: Int
    public var monospacedTime: Bool
    public var boldTime: Bool
    public var timeScale: CGFloat

    public init(author: String, text: String, timeText: String, editedText: String, removeTail: Bool = false, showEdited: Bool = true, editedIcon: Bool = false, onlineDot: Bool = false, showForwardCount: Bool = false, forwardCount: Int = 0, monospacedTime: Bool = false, boldTime: Bool = false, timeScale: CGFloat = 1.0) {
        self.author = author
        self.text = text
        self.timeText = timeText
        self.editedText = editedText
        self.removeTail = removeTail
        self.showEdited = showEdited
        self.editedIcon = editedIcon
        self.onlineDot = onlineDot
        self.showForwardCount = showForwardCount
        self.forwardCount = forwardCount
        self.monospacedTime = monospacedTime
        self.boldTime = boldTime
        self.timeScale = timeScale
    }
}

public enum SGSettingsPreviewKind: Equatable {
    case sticker(SGStickerPreviewConfiguration)
    /// Exactly three tiles, with raw selection ids original=0, rounded=1, bubble=2.
    case stickerShapes(value: Int, options: [String])
    case message(SGMessagePreviewConfiguration)

    var searchableText: String {
        switch self {
        case let .sticker(configuration):
            return [configuration.title, configuration.smallLabel, configuration.largeLabel].joined(separator: " ")
        case let .stickerShapes(_, options): return options.joined(separator: " ")
        case .message: return ""
        }
    }
}

enum SGSettingsPreviewGeometry {
    static func stickerSize(_ value: Int32) -> Int32 { return max(4, min(20, value)) }

    static func stickerSide(width: CGFloat, size: Int32) -> CGFloat {
        return min(280.0, max(0.0, width - 32.0) * 0.82) * CGFloat(self.stickerSize(size)) / 20.0
    }

    static func stickerHeaderHeight(baseSize: CGFloat) -> CGFloat {
        let titleHeight = max(ceil(Font.medium(baseSize * 0.94).lineHeight) + 4.0, ceil(Font.semibold(baseSize * 0.76).lineHeight) + 6.0)
        let labelHeight = ceil(Font.regular(baseSize * 0.82).lineHeight) + 4.0
        return max(128.0, 18.0 + titleHeight + 12.0 + labelHeight + 44.0 + 12.0)
    }

    static func stickerQuoteHeight(baseSize: CGFloat) -> CGFloat {
        return max(38.0, 8.0 + ceil(Font.medium(baseSize * 0.82).lineHeight) + ceil(Font.regular(baseSize * 0.76).lineHeight))
    }

    static func stickerReplyHeight(baseSize: CGFloat) -> CGFloat {
        return 8.0 + self.stickerQuoteHeight(baseSize: baseSize) + 6.0 + ceil(Font.regular(baseSize * 0.88).lineHeight) + 8.0
    }

    static func stickerAreaHeight(_ configuration: SGStickerPreviewConfiguration, width: CGFloat, baseSize: CGFloat) -> CGFloat {
        let timeHeight = configuration.timeMode == 2 ? 0.0 : ceil(Font.regular(baseSize * 0.71).lineHeight) + 6.0
        return max(self.stickerSide(width: width, size: configuration.size), timeHeight)
    }

    static func timeFont(_ configuration: SGMessagePreviewConfiguration, baseSize: CGFloat) -> UIFont {
        let scale = configuration.timeScale.isFinite ? max(0.7, min(1.8, configuration.timeScale)) : 1.0
        let size = max(11.0, baseSize * 0.71) * scale
        if configuration.monospacedTime {
            if #available(iOS 13.0, *) { return UIFont.monospacedSystemFont(ofSize: size, weight: configuration.boldTime ? .semibold : .regular) }
            return Font.regular(size)
        }
        return configuration.boldTime ? Font.semibold(size) : Font.regular(size)
    }

    static func bodyHeight(_ configuration: SGMessagePreviewConfiguration, width: CGFloat, baseSize: CGFloat) -> CGFloat {
        let font = Font.regular(baseSize)
        let maxHeight = ceil(font.lineHeight * (baseSize > 22.0 ? 4.0 : 2.0))
        let textWidth = max(1.0, width - min(64.0, width * 0.22) - 40.0)
        let rect = (configuration.text as NSString).boundingRect(with: CGSize(width: textWidth, height: maxHeight), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], attributes: [.font: font], context: nil)
        return max(ceil(font.lineHeight), min(maxHeight, ceil(rect.height)))
    }

    static func height(kind: SGSettingsPreviewKind, width: CGFloat, baseSize: CGFloat) -> CGFloat {
        switch kind {
        case let .sticker(configuration):
            return self.stickerHeaderHeight(baseSize: baseSize) + self.stickerAreaHeight(configuration, width: width, baseSize: baseSize) + self.stickerReplyHeight(baseSize: baseSize) + 44.0
        case let .stickerShapes(_, options):
            let tileWidth = max(1.0, (width - 44.0 - 32.0) / 3.0)
            let font = Font.regular(baseSize * 0.82)
            let labelHeight = options.prefix(3).reduce(ceil(font.lineHeight)) { height, text in
                let rect = (text as NSString).boundingRect(with: CGSize(width: tileWidth, height: ceil(font.lineHeight * 2.0)), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], attributes: [.font: font], context: nil)
                return max(height, min(ceil(font.lineHeight * 2.0), ceil(rect.height)))
            }
            return 12.0 + min(88.0, tileWidth * 0.85) + 12.0 + labelHeight + 16.0
        case let .message(configuration):
            return 30.0 + ceil(Font.medium(baseSize * 0.82).lineHeight) + self.bodyHeight(configuration, width: width, baseSize: baseSize) + ceil(self.timeFont(configuration, baseSize: baseSize).lineHeight) + 24.0
        }
    }

    static func bubblePath(size: CGSize, radius: CGFloat, tail: Bool) -> CGPath {
        let path = UIBezierPath()
        let left = tail ? min(7.0, max(0.0, size.width) * 0.1) : 0.0
        let right = max(left, size.width)
        let bottom = max(0.0, size.height)
        let requestedRadius = radius.isFinite ? max(0.0, radius) : 0.0
        let r = min(requestedRadius, min((right - left) / 2.0, bottom / 2.0))
        path.move(to: CGPoint(x: left + r, y: 0.0))
        path.addLine(to: CGPoint(x: right - r, y: 0.0))
        path.addQuadCurve(to: CGPoint(x: right, y: r), controlPoint: CGPoint(x: right, y: 0.0))
        path.addLine(to: CGPoint(x: right, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: right - r, y: bottom), controlPoint: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + r, y: bottom))
        if tail {
            path.addCurve(to: CGPoint(x: 0.0, y: bottom), controlPoint1: CGPoint(x: left + r * 0.35, y: bottom), controlPoint2: CGPoint(x: left * 0.4, y: bottom))
            path.addCurve(to: CGPoint(x: left, y: bottom - r * 0.7), controlPoint1: CGPoint(x: left, y: bottom - r * 0.2), controlPoint2: CGPoint(x: left, y: bottom - r * 0.35))
        } else {
            path.addQuadCurve(to: CGPoint(x: left, y: bottom - r), controlPoint: CGPoint(x: left, y: bottom))
        }
        path.addLine(to: CGPoint(x: left, y: r))
        path.addQuadCurve(to: CGPoint(x: left + r, y: 0.0), controlPoint: CGPoint(x: left, y: 0.0))
        path.close()
        return path.cgPath
    }
}
