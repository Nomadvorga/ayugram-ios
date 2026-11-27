import AVFoundation
import AyuPluginBridge
import CoreGraphics
import Foundation
import ImageIO
import TelegramCore
import UniformTypeIdentifiers

/// Turns a plugin's local file into what TelegramCore's send queue takes: the host reads the
/// file, detects its type and prepares sizes, thumbnail, dimensions and duration itself.
/// Blocking; never called on main.
enum AyuPluginLocalMedia {
    /// Longest side of a sent photo, as the app's own picker scales it; `sendingHighQuality`
    /// doubles it.
    static let photoSide = 1280
    static let highQualityPhotoSide = 2560
    static let thumbnailSide = 320

    static func prepare(_ media: AyuPluginTelegramSendPlan.Media, highQuality: Bool) throws -> AyuPluginOutgoingMedia {
        switch media {
        case .none:
            return .none
        case let .document(data):
            return .document(data)
        case let .photo(data):
            return .photo(data)
        case let .file(path, kind, description):
            switch kind {
            case .photo:
                // The sizes come from the file; a `photo` description adds nothing to them.
                return .localImage(try self.image(path: path, side: highQuality ? self.highQualityPhotoSide : self.photoSide, quality: highQuality ? 0.92 : 0.87))
            case .document:
                return .localFile(AyuPluginLocalFile(path: path, mimeType: self.mimeType(path: path, fallback: "application/octet-stream"), attributes: [.FileName(fileName: self.fileName(path))], thumbnail: nil, descriptionDocument: description))
            case .video:
                return .localFile(try self.video(path: path, description: description))
            case .audio:
                return .localFile(try self.audio(path: path, description: description))
            }
        }
    }

    static func fileName(_ path: String) -> String {
        return (path as NSString).lastPathComponent
    }

    static func mimeType(path: String, fallback: String) -> String {
        let pathExtension = (path as NSString).pathExtension
        guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension), let mimeType = type.preferredMIMEType else {
            return fallback
        }
        return mimeType
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    /// The image at `path`, oriented upright, scaled down to `side` on its longest side and
    /// encoded as JPEG.
    static func image(path: String, side: Int, quality: Double) throws -> AyuPluginLocalImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0, let data = self.jpeg(image, quality: quality) else {
            throw AyuPluginTelegramBackendError.invalidArguments("path is not an image the app can read")
        }
        return AyuPluginLocalImage(jpegData: data, dimensions: PixelDimensions(width: Int32(clamping: image.width), height: Int32(clamping: image.height)))
    }

    private static func video(path: String, description: Data?) throws -> AyuPluginLocalFile {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = CMTimeGetSeconds(asset.duration)
        guard let track = asset.tracks(withMediaType: .video).first, duration.isFinite, duration >= 0 else {
            throw AyuPluginTelegramBackendError.invalidArguments("path is not a video the app can read")
        }
        let size = track.naturalSize.applying(track.preferredTransform)
        let width = Int32(clamping: Int(abs(size.width).rounded()))
        let height = Int32(clamping: Int(abs(size.height).rounded()))
        guard width > 0, height > 0 else {
            throw AyuPluginTelegramBackendError.invalidArguments("path is not a video the app can read")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: self.thumbnailSide, height: self.thumbnailSide)
        var thumbnail: AyuPluginLocalImage?
        if let frame = try? generator.copyCGImage(at: .zero, actualTime: nil), let data = self.jpeg(frame, quality: 0.6) {
            thumbnail = AyuPluginLocalImage(jpegData: data, dimensions: PixelDimensions(width: Int32(clamping: frame.width), height: Int32(clamping: frame.height)))
        }
        let attributes: [TelegramMediaFileAttribute] = [
            .FileName(fileName: self.fileName(path)),
            .Video(duration: duration, size: PixelDimensions(width: width, height: height), flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil),
        ]
        return AyuPluginLocalFile(path: path, mimeType: self.mimeType(path: path, fallback: "video/mp4"), attributes: attributes, thumbnail: thumbnail, descriptionDocument: description)
    }

    private static func audio(path: String, description: Data?) throws -> AyuPluginLocalFile {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration = CMTimeGetSeconds(asset.duration)
        guard !asset.tracks(withMediaType: .audio).isEmpty, duration.isFinite, duration >= 0 else {
            throw AyuPluginTelegramBackendError.invalidArguments("path is not an audio file the app can read")
        }
        func text(_ identifier: AVMetadataIdentifier) -> String? {
            let value = AVMetadataItem.metadataItems(from: asset.commonMetadata, filteredByIdentifier: identifier).first?.stringValue
            return value.flatMap { $0.isEmpty ? nil : String($0.prefix(256)) }
        }
        let attributes: [TelegramMediaFileAttribute] = [
            .FileName(fileName: self.fileName(path)),
            .Audio(isVoice: false, duration: Int(duration.rounded()), title: text(.commonIdentifierTitle), performer: text(.commonIdentifierArtist), waveform: nil),
        ]
        return AyuPluginLocalFile(path: path, mimeType: self.mimeType(path: path, fallback: "audio/mpeg"), attributes: attributes, thumbnail: nil, descriptionDocument: description)
    }
}
