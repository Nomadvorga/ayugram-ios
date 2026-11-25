import AsyncDisplayKit
import ChatMessageItem
import ChatMessageItemView
import Display
import Foundation
import TelegramCore
import UIKit

/// Exports the currently displayed, single-message content tree. The caller supplies
/// current chat export permission; this helper also checks the message bound to the row.
enum ExteraMessageImageExport {
    struct Output {
        let image: UIImage
        let pngData: Data
    }

    enum CaptureError: Swift.Error {
        case notOnMainThread
        case exportNotAllowed
        case messageMismatch
        case groupedMessage
        case protectedContent
        case unsupportedContent
        case sourceUnavailable
        case sourceNotVisible
        case invalidGeometry
        case imageTooLarge
        case renderingFailed
        case encodingFailed
    }

    private static let maximumPixelCount: CGFloat = 16_000_000
    private static let maximumScale: CGFloat = 3.0

    /// Must be called on the main thread while the message (or its extracted context
    /// preview) is fully visible. It never loads an offscreen row, renders an ancestor,
    /// stitches screenshots, or returns a partial image when rendering fails.
    static func capture(
        node: ChatMessageItemView,
        message: EngineRawMessage,
        allowExport: Bool,
        backgroundColor: UIColor
    ) throws -> Output {
        guard Thread.isMainThread else {
            throw CaptureError.notOnMainThread
        }
        guard allowExport else {
            throw CaptureError.exportNotAllowed
        }
        guard node.isNodeLoaded, let item = node.item else {
            throw CaptureError.sourceUnavailable
        }
        guard case let .message(boundMessage, _, _, _, _) = item.content else {
            // Album source rects can span other messages, including protected ones.
            throw CaptureError.groupedMessage
        }
        guard boundMessage.id == message.id, boundMessage.stableId == message.stableId,
              item.message.id == message.id, item.message.stableId == message.stableId else {
            throw CaptureError.messageMismatch
        }
        guard message.groupingKey == nil, boundMessage.groupingKey == nil else {
            throw CaptureError.groupedMessage
        }
        guard item.additionalContent == nil else {
            // An admin-log row can contain a previous message inside the same tree.
            throw CaptureError.unsupportedContent
        }
        try self.checkExportable(message)
        try self.checkExportable(boundMessage)

        guard let rowWindow = node.view.window,
              let source = node.getMessageContextSourceNode(stableId: message.stableId),
              source.isNodeLoaded, source.contentNode.isNodeLoaded else {
            throw CaptureError.sourceUnavailable
        }
        let contentView = source.contentNode.view
        guard let window = contentView.window, window === rowWindow, contentView.superview != nil else {
            throw CaptureError.sourceUnavailable
        }
        // Context extraction reparents contentNode. Its bounds and contentRect keep
        // their coordinates, so use the live content tree, never the empty row wrapper.
        let crop = source.contentRect
        let bounds = contentView.bounds
        guard self.isValid(crop), self.isValid(bounds), bounds.contains(crop) else {
            throw CaptureError.invalidGeometry
        }
        try self.checkVisibility(of: contentView, crop: crop, in: window)

        let scale = min(self.maximumScale, window.screen.scale)
        guard scale.isFinite, scale > 0.0 else {
            throw CaptureError.invalidGeometry
        }
        // Round UP before checking the allocation: the renderer rounds fractional
        // point sizes to whole pixels. No Int conversion or multiplication can overflow.
        let pixelWidth = ceil(crop.width * scale)
        let pixelHeight = ceil(crop.height * scale)
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth >= 1.0, pixelHeight >= 1.0,
              pixelWidth <= self.maximumPixelCount,
              pixelHeight <= self.maximumPixelCount / pixelWidth else {
            throw CaptureError.imageTooLarge
        }
        // UIKit may create an intermediate surface for the source view while drawing
        // its effects, so bound that surface as well as the final cropped output.
        let sourcePixelWidth = ceil(bounds.width * scale)
        let sourcePixelHeight = ceil(bounds.height * scale)
        guard sourcePixelWidth.isFinite, sourcePixelHeight.isFinite,
              sourcePixelWidth >= 1.0, sourcePixelHeight >= 1.0,
              sourcePixelWidth <= self.maximumPixelCount,
              sourcePixelHeight <= self.maximumPixelCount / sourcePixelWidth else {
            throw CaptureError.imageTooLarge
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: crop.size, format: format)
        let outputRect = CGRect(origin: .zero, size: crop.size)
        let fillColor = backgroundColor.resolvedColor(with: contentView.traitCollection).withAlphaComponent(1.0)
        var didDraw = false
        let image = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.setFillColor(fillColor.cgColor)
            context.fill(outputRect)
            context.saveGState()
            context.clip(to: outputRect)
            context.translateBy(x: -crop.minX, y: -crop.minY)
            // drawHierarchy captures the message's UIKit effects. Rendering the window,
            // row's parent or scroll surface would include neighboring messages.
            didDraw = contentView.drawHierarchy(in: bounds, afterScreenUpdates: false)
            context.restoreGState()
        }
        guard didDraw else {
            throw CaptureError.renderingFailed
        }
        guard let cgImage = image.cgImage else {
            throw CaptureError.renderingFailed
        }
        guard cgImage.width > 0, cgImage.height > 0,
              cgImage.width <= Int(self.maximumPixelCount),
              cgImage.height <= Int(self.maximumPixelCount) / cgImage.width else {
            throw CaptureError.imageTooLarge
        }
        guard let pngData = image.pngData(), !pngData.isEmpty else {
            throw CaptureError.encodingFailed
        }
        return Output(image: image, pngData: pngData)
    }

    private static func checkExportable(_ message: EngineRawMessage) throws {
        guard message.id.peerId.namespace != Namespaces.Peer.SecretChat,
              message.id.namespace != Namespaces.Message.SecretIncoming,
              !message.isCopyProtected(), !message.containsSecretMedia,
              message.minAutoremoveOrClearTimeout != viewOnceTimeout,
              !message.media.contains(where: { $0 is TelegramMediaPaidContent }) else {
            throw CaptureError.protectedContent
        }
        guard !message.media.contains(where: { $0 is TelegramMediaExpiredContent }) else {
            throw CaptureError.unsupportedContent
        }
        for media in message.media {
            if let image = media as? TelegramMediaImage, image.imageId.namespace == Namespaces.Media.CloudSecretImage {
                throw CaptureError.protectedContent
            }
            if let file = media as? TelegramMediaFile, file.fileId.namespace == Namespaces.Media.CloudSecretFile {
                throw CaptureError.protectedContent
            }
        }
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        return !rect.isNull && !rect.isInfinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
            && rect.width > 0.0 && rect.height > 0.0
    }

    private static func checkVisibility(of contentView: UIView, crop: CGRect, in window: UIWindow) throws {
        var ancestor: UIView? = contentView
        while let current = ancestor {
            guard !current.isHidden, !current.layer.isHidden, current.alpha > 0.01, current.layer.opacity > 0.01 else {
                throw CaptureError.sourceNotVisible
            }
            if current.clipsToBounds || current.layer.masksToBounds || current === window {
                let convertedCrop = contentView.convert(crop, to: current)
                // The history wrapper rotates by pi. Allow only floating-point noise
                // from that conversion, far below one rendered pixel.
                guard self.isValid(convertedCrop), self.isValid(current.bounds),
                      current.bounds.insetBy(dx: -0.001, dy: -0.001).contains(convertedCrop) else {
                    throw CaptureError.sourceNotVisible
                }
            }
            if current === window {
                return
            }
            ancestor = current.superview
        }
        throw CaptureError.sourceNotVisible
    }
}
