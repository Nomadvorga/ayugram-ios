import Foundation
import UIKit

/// Immutable snapshot of the audited Premium Dialog Cards 2.1.1 settings.
/// The bridge adapter owns the source and writes this value; the chat list only
/// reads it on row updates, so no UserDefaults/JSON work happens while scrolling.
public struct AyuDialogCardsStyle: Equatable, Sendable {
    public var isEnabled: Bool
    public var rounding: CGFloat
    public var blur: CGFloat
    public var darken: CGFloat
    public var strokeWidth: CGFloat
    public var strokeAlpha: CGFloat
    public var onlineBorder: Bool
    public var showsOnlineBadge: Bool
    public var muteDim: Bool
    public var muteOpacity: CGFloat
    public var muteStroke: Bool

    public init(isEnabled: Bool = true, rounding: CGFloat = 15.0, blur: CGFloat = 7.0,
                darken: CGFloat = 55.0, strokeWidth: CGFloat = 0.5, strokeAlpha: CGFloat = 24.0,
                onlineBorder: Bool = false, showsOnlineBadge: Bool = true,
                muteDim: Bool = false, muteOpacity: CGFloat = 30.0, muteStroke: Bool = false) {
        self.isEnabled = isEnabled
        self.rounding = rounding
        self.blur = blur
        self.darken = darken
        self.strokeWidth = strokeWidth
        self.strokeAlpha = strokeAlpha
        self.onlineBorder = onlineBorder
        self.showsOnlineBadge = showsOnlineBadge
        self.muteDim = muteDim
        self.muteOpacity = muteOpacity
        self.muteStroke = muteStroke
    }

    public static let `default` = AyuDialogCardsStyle()
}

/// Source geometry, in points (Android dp). Values are fixed by the audited
/// plugin and are not exposed as settings there.
public enum AyuDialogCardsMetrics {
    public static let marginX: CGFloat = 6.0
    public static let marginY: CGFloat = 5.0
    public static let strokeOnlineRatio: CGFloat = 1.6
    public static let avatarScale: CGFloat = 0.75
    public static let fadeDuration: CFTimeInterval = 0.16
    public static let blurSourceSize: CGFloat = 90.0

    public static let onlineFill = UIColor(red: 0xB1.0 / 255.0, green: 0xE5.0 / 255.0, blue: 0x48.0 / 255.0, alpha: 0x26.0 / 255.0)
    public static let onlineBorder = UIColor(red: 0xB1.0 / 255.0, green: 0xE5.0 / 255.0, blue: 0x48.0 / 255.0, alpha: 1.0)
    public static let mutedFill = UIColor(red: 0x22.0 / 255.0, green: 0x24.0 / 255.0, blue: 0x2B.0 / 255.0, alpha: 1.0)
    public static let mutedBorder = UIColor(red: 0x43.0 / 255.0, green: 0x47.0 / 255.0, blue: 0x53.0 / 255.0, alpha: 1.0)

    /// `SPECIAL_COLORS` from the source: Saved Messages and the Telegram service chat.
    public static let savedGradient = (top: UIColor(red: 0x28.0 / 255.0, green: 0x18.0 / 255.0, blue: 0x4F.0 / 255.0, alpha: 1.0),
                                       bottom: UIColor(red: 0x12.0 / 255.0, green: 0x2D.0 / 255.0, blue: 0x5B.0 / 255.0, alpha: 1.0))
    public static let serviceGradient = (top: UIColor(red: 0x0D.0 / 255.0, green: 0x3E.0 / 255.0, blue: 0x44.0 / 255.0, alpha: 1.0),
                                         bottom: UIColor(red: 0x1A.0 / 255.0, green: 0x25.0 / 255.0, blue: 0x3B.0 / 255.0, alpha: 1.0))
    public static let servicePeerId: Int64 = 1271266957
    public static let placeholderColors: [UInt32] = [
        0xFFE17076, 0xFFFAA774, 0xFFA695E7, 0xFF7BC862, 0xFF6EC9CB, 0xFF65AADD, 0xFFEE7AEC,
    ]

    /// `get_placeholder_color`: the avatar palette colour scaled by the darken
    /// percentage, used until a blurred avatar is available.
    public static func placeholderColor(peerId: Int64, darken: CGFloat) -> UIColor {
        let index = Int(abs(peerId) % Int64(placeholderColors.count))
        let base = placeholderColors[index]
        let keep = 0.18 * (1.0 - max(0.0, min(1.0, darken / 100.0)))
        return UIColor(red: CGFloat((base >> 16) & 0xFF) / 255.0 * keep,
                       green: CGFloat((base >> 8) & 0xFF) / 255.0 * keep,
                       blue: CGFloat(base & 0xFF) / 255.0 * keep,
                       alpha: 1.0)
    }

    public static func mutedFillAlpha(opacity: CGFloat) -> CGFloat {
        max(0.0, min(1.0, (100.0 - opacity) * 2.3 / 255.0))
    }

    public static func mutedBorderAlpha(opacity: CGFloat) -> CGFloat {
        max(0.0, min(1.0, (100.0 - opacity) * 1.91 / 255.0))
    }
}

/// Main-thread snapshot used by the chat list. The adapter updates it only when
/// the plugin is enabled or a setting changes; reading it is a plain property
/// load and never starts Python or decodes JSON. The type is deliberately not
/// actor-isolated so the nonisolated chat-list layout code can read it without
/// an async hop; every writer is on the main thread.
public final class AyuDialogCardsState {
    public static let shared = AyuDialogCardsState()
    public static let didChange = Notification.Name("AyuDialogCardsStateDidChange")

    public private(set) var style: AyuDialogCardsStyle?

    private init() {}

    public func setStyle(_ style: AyuDialogCardsStyle?) {
        guard self.style != style else {
            return
        }
        self.style = style
        NotificationCenter.default.post(name: AyuDialogCardsState.didChange, object: self)
    }
}
