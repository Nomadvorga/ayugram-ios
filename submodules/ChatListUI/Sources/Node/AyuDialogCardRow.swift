import Foundation
import UIKit
import CoreImage
import AyuDialogCards

/// Host implementation of Premium Dialog Cards 2.1.1. The audited source paints
/// each dialog cell with a rounded, darkened, 90 px blurred avatar bitmap, a
/// vertical white stroke gradient and optional muted/online overlays. This file
/// reproduces that contract with Core Animation layers; it never runs plugin
/// code and does no bitmap work on the main thread.

enum AyuDialogCardSpecial {
    case saved
    case service
}

struct AyuDialogCardInfo {
    let style: AyuDialogCardsStyle
    let peerId: Int64
    let special: AyuDialogCardSpecial?
    let isMuted: Bool
    let isOnline: Bool
    let frame: CGRect
    var avatarImage: UIImage?
}

/// Shared LRU of finished 90 px, already tinted card bitmaps. The blur runs on a
/// utility queue, so scrolling never waits for Core Image. Keys include the
/// source CGImage identity: a reloaded avatar produces a different object and
/// therefore a fresh bitmap instead of a stale one.
final class AyuDialogCardImageCache {
    static let shared = AyuDialogCardImageCache()

    private final class Entry {
        weak var source: CGImage?
        let image: CGImage
        init(source: CGImage, image: CGImage) {
            self.source = source
            self.image = image
        }
    }

    private static let dimension = Int(AyuDialogCardsMetrics.blurSourceSize)
    private static let context = CIContext(options: [CIContextOption.cacheIntermediates: false])
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.telegram.ayu.dialogCards.blur", qos: .utility)
    private var storage: [String: Entry] = [:]
    private var order: [String] = []

    private init() {}

    func cached(_ key: String, source: CGImage) -> CGImage? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let entry = self.storage[key], entry.source === source else {
            if self.storage.removeValue(forKey: key) != nil {
                self.order.removeAll(where: { $0 == key })
            }
            return nil
        }
        if let index = self.order.firstIndex(of: key) {
            self.order.remove(at: index)
            self.order.append(key)
        }
        return entry.image
    }

    func render(key: String, source: CGImage, placeholder: UIColor, blur: CGFloat, darken: CGFloat,
                completion: @escaping (CGImage?) -> Void) {
        if let cached = self.cached(key, source: source) {
            completion(cached)
            return
        }
        let dimension = Self.dimension
        let colorSpace = Self.colorSpace
        self.queue.async { [weak self] in
            let image = AyuDialogCardImageCache.makeImage(source: source, placeholder: placeholder,
                                                         blur: blur, darken: darken,
                                                         dimension: dimension, colorSpace: colorSpace)
            if let image {
                self?.store(image, for: key, source: source)
            }
            completion(image)
        }
    }

    private func store(_ image: CGImage, for key: String, source: CGImage) {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.storage[key] == nil {
            self.order.append(key)
        }
        self.storage[key] = Entry(source: source, image: image)
        while self.order.count > 64 {
            let old = self.order.removeFirst()
            if old != key {
                self.storage.removeValue(forKey: old)
            }
        }
    }

    private static func makeImage(source: CGImage, placeholder: UIColor, blur: CGFloat, darken: CGFloat,
                                  dimension: Int, colorSpace: CGColorSpace) -> CGImage? {
        guard let bitmap = CGContext(data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let rect = CGRect(x: 0.0, y: 0.0, width: CGFloat(dimension), height: CGFloat(dimension))
        bitmap.setFillColor(placeholder.cgColor)
        bitmap.fill(rect)
        bitmap.interpolationQuality = .medium
        // The source calls Bitmap.createScaledBitmap(..., BLUR_SIZE, BLUR_SIZE),
        // an exact filtered stretch into 90 x 90. The resulting BitmapShader is
        // then scaled with max(card_w / bw, card_h / bh), i.e. aspect-fill, which
        // `resizeAspectFill` reproduces on the card layer.
        bitmap.draw(source, in: rect)
        guard let scaled = bitmap.makeImage() else {
            return nil
        }

        let input = CIImage(cgImage: scaled)
        let radius = max(1.0, min(25.0, blur))
        // Android's stack blur clamps at the bitmap edge. Clamping the input
        // extent prevents a transparent fringe along the card border.
        let blurred = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
        guard let blurredImage = context.createCGImage(blurred, from: input.extent, format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }

        guard let tinted = CGContext(data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        tinted.draw(blurredImage, in: rect)
        let alpha = max(0.0, min(1.0, darken / 100.0))
        if alpha > 0.0 {
            tinted.setFillColor(UIColor(white: 0.0, alpha: alpha).cgColor)
            tinted.fill(rect)
        }
        return tinted.makeImage()
    }
}

/// Card background: blurred avatar (or the special gradient), the source stroke
/// gradient and the rounding. It sits above the row separator and below the
/// real text/avatar nodes.
final class AyuDialogCardBackgroundView: UIView {
    private let avatarLayer = CALayer()
    private let placeholderLayer = CALayer()
    private let specialLayer = CAGradientLayer()
    private let strokeLayer = CAGradientLayer()
    private let strokeMaskLayer = CAShapeLayer()

    private var configuredSpecial: AyuDialogCardSpecial?
    private var configuredStroke: (width: CGFloat, alpha: CGFloat, radius: CGFloat)?
    private var currentAvatarImage: CGImage?

    init() {
        super.init(frame: .zero)
        self.isUserInteractionEnabled = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.layer.isOpaque = false

        self.avatarLayer.contentsGravity = .resizeAspectFill
        self.avatarLayer.masksToBounds = true
        self.avatarLayer.minificationFilter = .linear
        self.avatarLayer.magnificationFilter = .linear

        self.placeholderLayer.masksToBounds = true

        self.specialLayer.isHidden = true
        self.specialLayer.masksToBounds = true
        self.specialLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        self.specialLayer.endPoint = CGPoint(x: 1.0, y: 1.0)

        self.strokeLayer.isHidden = true
        self.strokeMaskLayer.fillColor = UIColor.clear.cgColor
        self.strokeMaskLayer.strokeColor = UIColor.white.cgColor
        self.strokeLayer.mask = self.strokeMaskLayer

        self.layer.addSublayer(self.placeholderLayer)
        self.layer.addSublayer(self.avatarLayer)
        self.layer.addSublayer(self.specialLayer)
        self.layer.addSublayer(self.strokeLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(radius: CGFloat, special: AyuDialogCardSpecial?) {
        let frame = self.bounds
        let radius = max(0.0, min(radius, min(frame.width, frame.height) * 0.5))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.placeholderLayer.frame = frame
        self.placeholderLayer.cornerRadius = radius
        self.avatarLayer.frame = frame
        self.avatarLayer.cornerRadius = radius
        self.specialLayer.frame = frame
        self.specialLayer.cornerRadius = radius
        self.strokeLayer.frame = frame
        self.strokeMaskLayer.frame = frame
        CATransaction.commit()

        if self.configuredSpecial != special {
            self.configuredSpecial = special
            switch special {
            case .saved?:
                self.specialLayer.colors = [AyuDialogCardsMetrics.savedGradient.top.cgColor,
                                            AyuDialogCardsMetrics.savedGradient.bottom.cgColor]
            case .service?:
                self.specialLayer.colors = [AyuDialogCardsMetrics.serviceGradient.top.cgColor,
                                            AyuDialogCardsMetrics.serviceGradient.bottom.cgColor]
            case nil:
                self.specialLayer.colors = nil
            }
        }
        self.specialLayer.isHidden = special == nil
        self.avatarLayer.isHidden = special != nil
        self.placeholderLayer.isHidden = special != nil
        self.updateSpecialPoints()
    }

    private func updateSpecialPoints() {
        let frame = self.bounds
        guard frame.width > 0.0, frame.height > 0.0 else {
            return
        }
        // The source gradient line is `span = max(card_w, card_h)` long and runs
        // diagonally from the top-left of a centred span square.
        let span = max(frame.width, frame.height)
        let y0 = (frame.height - span) * 0.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.specialLayer.startPoint = CGPoint(x: 0.0, y: y0 / frame.height)
        self.specialLayer.endPoint = CGPoint(x: 1.0, y: (y0 + span) / frame.height)
        CATransaction.commit()
    }

    func setPlaceholder(_ color: UIColor?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.placeholderLayer.backgroundColor = color?.cgColor
        CATransaction.commit()
    }

    func setAvatar(_ image: CGImage?, animated: Bool) {
        let changed = self.currentAvatarImage !== image
        self.currentAvatarImage = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.avatarLayer.contents = image
        CATransaction.commit()
        if animated && changed && image != nil {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = AyuDialogCardsMetrics.fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.avatarLayer.add(fade, forKey: "ayu.dialogCards.fade")
        }
    }

    func setStroke(width: CGFloat, alpha: CGFloat, radius: CGFloat) {
        guard width > 0.0, alpha > 0.0 else {
            self.configuredStroke = nil
            self.strokeLayer.isHidden = true
            return
        }
        let radius = max(0.0, min(radius, min(self.bounds.width, self.bounds.height) * 0.5))
        let previous = self.configuredStroke
        if previous?.width != width || previous?.alpha != alpha || previous?.radius != radius {
            self.configuredStroke = (width, alpha, radius)
            let path = UIBezierPath(roundedRect: self.bounds.insetBy(dx: width * 0.5, dy: width * 0.5),
                                    cornerRadius: max(0.0, radius - width * 0.5))
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.strokeMaskLayer.lineWidth = width
            self.strokeMaskLayer.path = path.cgPath
            self.strokeLayer.colors = [UIColor.white.withAlphaComponent(alpha).cgColor,
                                       UIColor.white.withAlphaComponent(0.0).cgColor]
            CATransaction.commit()
        }
        self.strokeLayer.isHidden = false
    }

    func hideStroke() {
        self.configuredStroke = nil
        self.strokeLayer.isHidden = true
    }
}

/// Muted/online overlay drawn above the row's real content, like the source's
/// `on_cell_after_draw` pass.
final class AyuDialogCardOverlayView: UIView {
    private let fillLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private var configured: (radius: CGFloat, fill: UIColor?, border: UIColor?, borderWidth: CGFloat, size: CGSize)?

    init() {
        super.init(frame: .zero)
        self.isUserInteractionEnabled = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.layer.isOpaque = false
        self.fillLayer.fillColor = UIColor.clear.cgColor
        self.borderLayer.fillColor = UIColor.clear.cgColor
        self.layer.addSublayer(self.fillLayer)
        self.layer.addSublayer(self.borderLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(radius: CGFloat, fill: UIColor?, border: UIColor?, borderWidth: CGFloat) {
        let frame = self.bounds
        let radius = max(0.0, min(radius, min(frame.width, frame.height) * 0.5))
        if let configured = self.configured, configured.radius == radius, configured.fill == fill,
           configured.border == border, configured.borderWidth == borderWidth, configured.size == frame.size {
            return
        }
        self.configured = (radius, fill, border, borderWidth, frame.size)
        let path = UIBezierPath(roundedRect: frame, cornerRadius: radius).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.fillLayer.frame = frame
        self.borderLayer.frame = frame
        self.fillLayer.path = path
        self.fillLayer.fillColor = fill?.cgColor ?? UIColor.clear.cgColor
        self.fillLayer.isHidden = fill == nil
        if let border, borderWidth > 0.0 {
            let borderPath = UIBezierPath(roundedRect: frame.insetBy(dx: borderWidth * 0.5, dy: borderWidth * 0.5),
                                          cornerRadius: max(0.0, radius - borderWidth * 0.5)).cgPath
            self.borderLayer.path = borderPath
            self.borderLayer.lineWidth = borderWidth
            self.borderLayer.strokeColor = border.cgColor
            self.borderLayer.isHidden = false
        } else {
            self.borderLayer.isHidden = true
        }
        CATransaction.commit()
    }
}

/// Per-row card state. It owns exactly one background and one overlay view and
/// keeps the last image key so scroll relayouts do not re-render or re-upload
/// an unchanged bitmap.
final class AyuDialogCardRow {
    private weak var hostView: UIView?
    private let backgroundView = AyuDialogCardBackgroundView()
    private let overlayView = AyuDialogCardOverlayView()
    private var current: AyuDialogCardInfo?
    private var imageKey: String?
    private var pendingKey: String?
    private var hasAvatarImage = false

    init(hostView: UIView, separatorView: UIView) {
        self.hostView = hostView
        if separatorView.superview === hostView {
            hostView.insertSubview(self.backgroundView, aboveSubview: separatorView)
        } else {
            hostView.insertSubview(self.backgroundView, at: 0)
        }
        hostView.addSubview(self.overlayView)
        self.backgroundView.isHidden = true
        self.overlayView.isHidden = true
    }

    func updateAvatarImage(_ image: UIImage?) {
        guard var info = self.current, info.avatarImage?.cgImage !== image?.cgImage else {
            return
        }
        info.avatarImage = image
        self.update(info)
    }

    func update(_ info: AyuDialogCardInfo?) {
        guard let info else {
            guard self.current != nil || !self.backgroundView.isHidden || !self.overlayView.isHidden else {
                return
            }
            self.current = nil
            self.imageKey = nil
            self.pendingKey = nil
            self.hasAvatarImage = false
            self.backgroundView.isHidden = true
            self.overlayView.isHidden = true
            return
        }
        self.current = info
        self.hostView?.bringSubviewToFront(self.overlayView)
        self.backgroundView.isHidden = false
        self.backgroundView.frame = info.frame
        self.overlayView.frame = info.frame

        let style = info.style
        let radius = min(max(0.0, style.rounding), min(info.frame.width, info.frame.height) * 0.5)
        self.backgroundView.apply(radius: radius, special: info.special)

        let muted = info.isMuted && style.muteDim
        let online = !muted && info.isOnline && style.onlineBorder
        if muted || online {
            self.backgroundView.hideStroke()
        } else {
            self.backgroundView.setStroke(width: style.strokeWidth, alpha: style.strokeAlpha / 100.0, radius: radius)
        }

        if muted {
            let fill = AyuDialogCardsMetrics.mutedFill.withAlphaComponent(AyuDialogCardsMetrics.mutedFillAlpha(opacity: style.muteOpacity))
            let border: UIColor?
            if style.muteStroke && style.strokeWidth > 0.0 {
                border = AyuDialogCardsMetrics.mutedBorder.withAlphaComponent(AyuDialogCardsMetrics.mutedBorderAlpha(opacity: style.muteOpacity))
            } else {
                border = nil
            }
            self.overlayView.apply(radius: radius, fill: fill, border: border,
                                   borderWidth: max(0.1, style.strokeWidth * AyuDialogCardsMetrics.strokeOnlineRatio))
            self.overlayView.isHidden = false
        } else if online {
            let border: UIColor? = style.strokeWidth > 0.0 ? AyuDialogCardsMetrics.onlineBorder : nil
            self.overlayView.apply(radius: radius, fill: AyuDialogCardsMetrics.onlineFill,
                                   border: border,
                                   borderWidth: max(0.1, style.strokeWidth * AyuDialogCardsMetrics.strokeOnlineRatio))
            self.overlayView.isHidden = false
        } else {
            self.overlayView.isHidden = true
        }

        guard info.special == nil else {
            self.imageKey = nil
            self.pendingKey = nil
            self.hasAvatarImage = false
            return
        }

        let placeholder = AyuDialogCardsMetrics.placeholderColor(peerId: info.peerId, darken: style.darken)
        self.backgroundView.setPlaceholder(placeholder)
        guard let source = info.avatarImage?.cgImage else {
            self.backgroundView.setAvatar(nil, animated: false)
            self.imageKey = nil
            self.pendingKey = nil
            self.hasAvatarImage = false
            return
        }

        let key = "\(UInt(bitPattern: ObjectIdentifier(source)))|\(style.blur)|\(style.darken)"
        if let cached = AyuDialogCardImageCache.shared.cached(key, source: source) {
            if self.imageKey != key {
                self.imageKey = key
                self.pendingKey = nil
                self.backgroundView.setAvatar(cached, animated: !self.hasAvatarImage)
                self.hasAvatarImage = true
            }
            return
        }

        self.backgroundView.setAvatar(nil, animated: false)
        self.hasAvatarImage = false
        guard self.pendingKey != key else {
            return
        }
        self.pendingKey = key
        AyuDialogCardImageCache.shared.render(key: key, source: source, placeholder: placeholder,
                                              blur: style.blur, darken: style.darken) { [weak self] image in
            DispatchQueue.main.async {
                guard let self, let image else {
                    return
                }
                guard let current = self.current, current.style.blur == style.blur,
                      current.style.darken == style.darken,
                      current.avatarImage?.cgImage === source else {
                    if self.pendingKey == key {
                        self.pendingKey = nil
                    }
                    return
                }
                guard self.pendingKey == key || self.imageKey == key else {
                    return
                }
                self.pendingKey = nil
                self.imageKey = key
                self.backgroundView.setAvatar(image, animated: !self.hasAvatarImage)
                self.hasAvatarImage = true
            }
        }
    }
}

extension ChatListItemNode {
    /// Re-runs the current layout apply pass. Used when the plugin settings
    /// change while the list is on screen; it does not request a new item layout.
    func refreshAyuDialogCards() {
        guard let layoutParams = self.layoutParams else {
            return
        }
        let (_, apply) = self.asyncLayout()(layoutParams.0, layoutParams.6, layoutParams.1, layoutParams.2,
                                           layoutParams.3, layoutParams.4, layoutParams.5)
        let _ = apply(false, false)
    }
}
