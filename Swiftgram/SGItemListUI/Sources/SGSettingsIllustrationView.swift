import UIKit
import Display
import TelegramPresentationData

/// Original vector artwork for a settings example; it is not an account's sticker or message.
private final class SGStickerArtworkView: UIView {
    private let artwork = CALayer()
    private let body = CAShapeLayer()
    private let head = CAShapeLayer()
    private let eyes = CAShapeLayer()
    private let pupils = CAShapeLayer()
    private let details = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
        self.clipsToBounds = true
        self.layer.addSublayer(self.artwork)
        for layer in [self.body, self.head, self.eyes, self.pupils, self.details] { self.artwork.addSublayer(layer) }
        self.body.path = UIBezierPath(ovalIn: CGRect(x: 14.0, y: 49.0, width: 72.0, height: 62.0)).cgPath
        let head = UIBezierPath()
        head.move(to: CGPoint(x: 16.0, y: 9.0))
        head.addLine(to: CGPoint(x: 36.0, y: 25.0))
        head.addQuadCurve(to: CGPoint(x: 64.0, y: 25.0), controlPoint: CGPoint(x: 50.0, y: 20.0))
        head.addLine(to: CGPoint(x: 84.0, y: 9.0))
        head.addLine(to: CGPoint(x: 89.0, y: 57.0))
        head.addCurve(to: CGPoint(x: 11.0, y: 57.0), controlPoint1: CGPoint(x: 92.0, y: 94.0), controlPoint2: CGPoint(x: 8.0, y: 94.0))
        head.close()
        self.head.path = head.cgPath
        let eyes = UIBezierPath(ovalIn: CGRect(x: 27.0, y: 45.0, width: 16.0, height: 15.0))
        eyes.append(UIBezierPath(ovalIn: CGRect(x: 57.0, y: 45.0, width: 16.0, height: 15.0)))
        self.eyes.path = eyes.cgPath
        let pupils = UIBezierPath(ovalIn: CGRect(x: 33.0, y: 46.0, width: 5.0, height: 13.0))
        pupils.append(UIBezierPath(ovalIn: CGRect(x: 63.0, y: 46.0, width: 5.0, height: 13.0)))
        self.pupils.path = pupils.cgPath
        let details = UIBezierPath()
        details.move(to: CGPoint(x: 46.0, y: 65.0))
        details.addLine(to: CGPoint(x: 50.0, y: 68.0))
        details.addLine(to: CGPoint(x: 54.0, y: 65.0))
        for side in [-1.0, 1.0] as [CGFloat] {
            for offset in [-3.0, 3.0] as [CGFloat] {
                details.move(to: CGPoint(x: 50.0 + side * 15.0, y: 69.0))
                details.addLine(to: CGPoint(x: 50.0 + side * 40.0, y: 69.0 + offset))
            }
        }
        self.details.path = details.cgPath
        self.details.fillColor = UIColor.clear.cgColor
        self.details.lineWidth = 1.1
        self.details.lineCap = .round
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(theme: PresentationTheme) {
        let background = theme.list.itemBlocksBackgroundColor.mixedWith(theme.list.itemAccentColor, alpha: 0.14)
        self.backgroundColor = background
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fur = background.mixedWith(theme.list.itemPrimaryTextColor, alpha: 0.2)
        self.body.fillColor = fur.cgColor
        self.head.fillColor = fur.cgColor
        self.eyes.fillColor = theme.list.itemAccentColor.cgColor
        self.pupils.fillColor = theme.list.itemBlocksBackgroundColor.cgColor
        self.details.strokeColor = theme.list.itemSecondaryTextColor.cgColor
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.artwork.bounds = CGRect(x: 0.0, y: 0.0, width: 100.0, height: 100.0)
        self.artwork.position = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        self.artwork.setAffineTransform(CGAffineTransform(scaleX: self.bounds.width / 100.0, y: self.bounds.height / 100.0))
        CATransaction.commit()
    }
}

/// A non-interactive illustration shared by the sticker and message settings previews.
final class SGSettingsIllustrationView: UIView {
    private let pattern = CAShapeLayer()
    private let bubble = CAShapeLayer()
    private let quote = UIView()
    private let quoteStripe = UIView()
    private let sticker = SGStickerArtworkView(frame: .zero)
    private let thumbnail = SGStickerArtworkView(frame: .zero)
    private let avatar = UIImageView(image: sgItemListSymbolImage(named: "person.crop.circle.fill"))
    private let online = CALayer()
    private let author = UILabel()
    private let quoteText = UILabel()
    private let body = UILabel()
    private let time = UILabel()
    private let edited = UILabel()
    private let forwardCount = UILabel()
    private let editedIcon = UIImageView(image: sgItemListSymbolImage(named: "pencil"))
    private let forwardIcon = UIImageView(image: sgItemListSymbolImage(named: "arrowshape.turn.up.right.fill"))
    private var kind: SGSettingsPreviewKind?
    private var theme: PresentationTheme?
    private var baseSize: CGFloat = 17.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isUserInteractionEnabled = false
        self.accessibilityElementsHidden = true
        self.clipsToBounds = true
        self.layer.addSublayer(self.pattern)
        self.pattern.fillColor = UIColor.clear.cgColor
        self.pattern.lineWidth = 0.6
        self.layer.addSublayer(self.bubble)
        for view in [self.sticker, self.quote, self.avatar, self.author, self.quoteText, self.body, self.time, self.edited, self.forwardCount, self.editedIcon, self.forwardIcon] as [UIView] { self.addSubview(view) }
        self.quote.addSubview(self.quoteStripe)
        self.quote.addSubview(self.thumbnail)
        self.quote.layer.cornerRadius = 7.0
        self.quoteStripe.layer.cornerRadius = 1.5
        self.thumbnail.layer.cornerRadius = 4.0
        self.author.numberOfLines = 1
        self.author.lineBreakMode = .byTruncatingTail
        self.quoteText.numberOfLines = 1
        self.quoteText.lineBreakMode = .byTruncatingTail
        self.body.lineBreakMode = .byTruncatingTail
        for label in [self.time, self.edited, self.forwardCount] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        for image in [self.avatar, self.editedIcon, self.forwardIcon] { image.contentMode = .scaleAspectFit }
        self.avatar.layer.addSublayer(self.online)
        self.online.borderWidth = 2.0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(kind: SGSettingsPreviewKind, theme: PresentationTheme, baseSize: CGFloat) {
        self.kind = kind
        self.theme = theme
        self.baseSize = baseSize
        self.backgroundColor = theme.list.blocksBackgroundColor.mixedWith(theme.list.itemAccentColor, alpha: theme.overallDarkAppearance ? 0.035 : 0.055)
        self.sticker.update(theme: theme)
        self.thumbnail.update(theme: theme)
        self.author.font = Font.medium(baseSize * 0.82)
        self.body.font = Font.regular(baseSize)
        self.time.font = Font.regular(baseSize * 0.71)
        self.body.textColor = theme.chat.message.incoming.primaryTextColor
        self.author.textColor = theme.list.itemAccentColor
        self.avatar.tintColor = theme.list.itemAccentColor.withAlphaComponent(0.6)
        self.avatar.backgroundColor = theme.list.itemAccentColor.withAlphaComponent(0.12)
        self.avatar.layer.cornerRadius = 20.0
        self.online.backgroundColor = theme.list.itemAccentColor.cgColor
        self.online.borderColor = self.backgroundColor?.cgColor
        self.online.isHidden = true
        self.sticker.isHidden = true
        self.quote.isHidden = true
        self.quoteText.isHidden = true
        self.avatar.isHidden = true
        self.edited.isHidden = true
        self.editedIcon.isHidden = true
        self.forwardCount.isHidden = true
        self.forwardIcon.isHidden = true
        self.time.backgroundColor = .clear
        self.time.textColor = theme.chat.message.incoming.secondaryTextColor
        self.time.layer.cornerRadius = 0.0
        self.time.clipsToBounds = true
        self.time.isHidden = false
        self.time.textAlignment = .right
        self.body.numberOfLines = baseSize > 22.0 ? 4 : 2
        switch kind {
        case let .sticker(configuration):
            self.sticker.isHidden = false
            self.quote.isHidden = false
            self.quoteText.isHidden = false
            self.author.text = configuration.replyTitle
            self.quoteText.text = (configuration.replyEmoji && !configuration.emoji.isEmpty ? configuration.emoji + " " : "") + configuration.stickerLabel
            self.quoteText.font = Font.regular(baseSize * 0.76)
            self.quoteText.textColor = theme.chat.message.incoming.secondaryTextColor
            self.body.text = configuration.replyText
            self.body.font = Font.regular(baseSize * 0.88)
            self.author.textColor = configuration.replyColors ? theme.list.itemAccentColor : theme.chat.message.incoming.primaryTextColor
            self.quote.backgroundColor = configuration.replyBackground ? self.author.textColor.withAlphaComponent(0.1) : .clear
            self.quoteStripe.backgroundColor = self.author.textColor
            self.time.text = configuration.timeText
            self.time.isHidden = configuration.timeMode == 2
            self.time.textAlignment = .center
            self.time.textColor = theme.chat.message.mediaDateAndStatusTextColor
            self.time.backgroundColor = theme.chat.message.mediaDateAndStatusFillColor
            self.time.layer.cornerRadius = 10.0
            self.body.numberOfLines = 1
        case let .message(configuration):
            self.avatar.isHidden = false
            self.online.isHidden = !configuration.onlineDot
            self.author.text = configuration.author
            self.body.text = configuration.text
            self.time.text = configuration.timeText
            self.time.font = SGSettingsPreviewGeometry.timeFont(configuration, baseSize: baseSize)
            self.edited.text = configuration.editedText
            self.edited.font = self.time.font
            self.edited.textColor = self.time.textColor
            self.edited.isHidden = !configuration.showEdited || configuration.editedIcon
            self.editedIcon.isHidden = !configuration.showEdited || !configuration.editedIcon
            self.editedIcon.tintColor = self.time.textColor
            self.forwardCount.text = String(max(0, configuration.forwardCount))
            self.forwardCount.font = self.time.font
            self.forwardCount.textColor = self.time.textColor
            self.forwardCount.isHidden = !configuration.showForwardCount
            self.forwardIcon.isHidden = !configuration.showForwardCount
            self.forwardIcon.tintColor = self.time.textColor
        case .stickerShapes: break
        }
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let kind = self.kind, let theme = self.theme else { return }
        let width = max(0.0, self.bounds.width)
        let height = max(0.0, self.bounds.height)
        let decoration = UIBezierPath()
        for row in 0 ..< 5 {
            for column in 0 ..< 6 {
                let x = CGFloat(column) * 72.0 + (row % 2 == 0 ? 14.0 : 42.0)
                let y = CGFloat(row) * 72.0 + 18.0
                decoration.append(UIBezierPath(ovalIn: CGRect(x: x, y: y, width: 18.0, height: 18.0)))
                decoration.move(to: CGPoint(x: x + 30.0, y: y + 16.0))
                decoration.addLine(to: CGPoint(x: x + 38.0, y: y + 8.0))
                decoration.addLine(to: CGPoint(x: x + 46.0, y: y + 16.0))
                decoration.addLine(to: CGPoint(x: x + 38.0, y: y + 24.0))
                decoration.close()
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.pattern.path = decoration.cgPath
        self.pattern.strokeColor = theme.list.itemAccentColor.withAlphaComponent(0.16).cgColor
        self.bubble.fillColor = (theme.chat.message.incoming.bubble.withoutWallpaper.fill.first ?? theme.list.itemBlocksBackgroundColor).cgColor
        switch kind {
        case let .sticker(configuration):
            let desiredSide = SGSettingsPreviewGeometry.stickerSide(width: width, size: configuration.size)
            let replyHeight = SGSettingsPreviewGeometry.stickerReplyHeight(baseSize: self.baseSize)
            let availableArea = max(0.0, height - replyHeight - 44.0)
            let side = min(desiredSide, availableArea)
            let areaHeight = min(availableArea, SGSettingsPreviewGeometry.stickerAreaHeight(configuration, width: width, baseSize: self.baseSize))
            self.sticker.frame = CGRect(x: max(0.0, width - 16.0 - side), y: 18.0, width: side, height: side)
            let requestedRadius = configuration.shape == 0 ? 0.0 : (configuration.shape == 1 ? 6.0 : configuration.bubbleRadius)
            self.sticker.layer.cornerRadius = requestedRadius.isFinite ? max(0.0, min(side / 2.0, requestedRadius)) : 0.0
            let replyFrame = CGRect(x: min(12.0, width * 0.03), y: 18.0 + areaHeight + 12.0, width: max(0.0, min(280.0, width - 24.0)), height: replyHeight)
            self.bubble.frame = replyFrame
            self.bubble.path = SGSettingsPreviewGeometry.bubblePath(size: replyFrame.size, radius: 16.0, tail: true)
            self.quote.frame = CGRect(x: replyFrame.minX + 12.0, y: replyFrame.minY + 8.0, width: max(0.0, replyFrame.width - 24.0), height: SGSettingsPreviewGeometry.stickerQuoteHeight(baseSize: self.baseSize))
            self.quoteStripe.frame = CGRect(x: 0.0, y: 0.0, width: 3.0, height: self.quote.bounds.height)
            self.thumbnail.frame = CGRect(x: 8.0, y: floor((self.quote.bounds.height - 30.0) / 2.0), width: 30.0, height: 30.0)
            self.author.frame = CGRect(x: self.quote.frame.minX + 46.0, y: self.quote.frame.minY + 4.0, width: max(0.0, self.quote.frame.width - 52.0), height: ceil(self.author.font.lineHeight))
            self.quoteText.frame = CGRect(x: self.author.frame.minX, y: self.author.frame.maxY, width: self.author.frame.width, height: ceil(self.quoteText.font.lineHeight))
            self.body.frame = CGRect(x: replyFrame.minX + 14.0, y: self.quote.frame.maxY + 6.0, width: max(0.0, replyFrame.width - 28.0), height: ceil(self.body.font.lineHeight))
            let stampWidth = min(max(0.0, width - 32.0), ceil(self.time.intrinsicContentSize.width) + 16.0)
            let stampHeight = ceil(self.time.font.lineHeight) + 6.0
            var stamp = CGRect(x: max(0.0, self.sticker.frame.maxX - stampWidth - 6.0), y: max(18.0, self.sticker.frame.maxY - stampHeight - 5.0), width: stampWidth, height: stampHeight)
            if configuration.timeMode == 1 && self.sticker.frame.minX - stampWidth - 8.0 >= 12.0 {
                stamp.origin.x = self.sticker.frame.minX - stampWidth - 8.0
            }
            self.time.frame = stamp
        case let .message(configuration):
            let bubbleFrame = CGRect(x: min(64.0, width * 0.22), y: 14.0, width: max(0.0, width - min(64.0, width * 0.22) - 12.0), height: max(0.0, height - 30.0))
            self.bubble.frame = bubbleFrame
            self.bubble.path = SGSettingsPreviewGeometry.bubblePath(size: bubbleFrame.size, radius: 16.0, tail: !configuration.removeTail)
            self.avatar.frame = CGRect(x: 12.0, y: max(0.0, bubbleFrame.maxY - 42.0), width: min(40.0, width * 0.14), height: min(40.0, width * 0.14))
            self.avatar.layer.cornerRadius = self.avatar.bounds.width / 2.0
            self.online.frame = CGRect(x: max(0.0, self.avatar.bounds.width - 12.0), y: max(0.0, self.avatar.bounds.height - 12.0), width: 12.0, height: 12.0)
            self.online.cornerRadius = 6.0
            let textWidth = max(0.0, bubbleFrame.width - 28.0)
            self.author.frame = CGRect(x: bubbleFrame.minX + 14.0, y: bubbleFrame.minY + 9.0, width: textWidth, height: ceil(self.author.font.lineHeight))
            self.body.frame = CGRect(x: bubbleFrame.minX + 14.0, y: self.author.frame.maxY + 4.0, width: textWidth, height: SGSettingsPreviewGeometry.bodyHeight(configuration, width: width, baseSize: self.baseSize))
            let footerY = self.body.frame.maxY + 2.0
            let footerHeight = ceil(self.time.font.lineHeight)
            var cursor = bubbleFrame.maxX - 14.0
            func place(_ view: UIView, desiredWidth: CGFloat) {
                let available = max(0.0, cursor - bubbleFrame.minX - 14.0)
                let size = min(available, desiredWidth)
                view.frame = CGRect(x: cursor - size, y: footerY, width: size, height: footerHeight)
                cursor = max(bubbleFrame.minX + 14.0, cursor - size - 5.0)
            }
            place(self.time, desiredWidth: ceil(self.time.intrinsicContentSize.width))
            if configuration.showEdited {
                if configuration.editedIcon { place(self.editedIcon, desiredWidth: 12.0) }
                else { place(self.edited, desiredWidth: ceil(self.edited.intrinsicContentSize.width)) }
            }
            if configuration.showForwardCount {
                place(self.forwardCount, desiredWidth: ceil(self.forwardCount.intrinsicContentSize.width))
                place(self.forwardIcon, desiredWidth: 12.0)
            }
        case .stickerShapes: break
        }
        CATransaction.commit()
    }
}
