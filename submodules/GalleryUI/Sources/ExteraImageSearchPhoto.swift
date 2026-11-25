import CryptoKit
import Foundation
import ImageIO
import UIKit

struct ExteraImageSearchPhoto {
    let preview: UIImage
    let jpeg: Data
    let byteCount: Int
    let width: Int
    let height: Int
    let format: String
    let sha256: String
    let metadata: [(String, String)]

    /// Reads one complete cached image only. ImageIO downsamples before decoding;
    /// the exported JPEG is rendered afresh, excluding original EXIF/GPS metadata.
    static func load(path: String) throws -> ExteraImageSearchPhoto {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 32 * 1024 * 1024 else {
            throw ExteraImageSearchProtocol.SearchError.invalidImage
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 100000, height <= 100000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw ExteraImageSearchProtocol.SearchError.invalidImage }
        let image = UIImage(cgImage: thumbnail)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let jpeg = UIGraphicsImageRenderer(size: image.size, format: format).jpegData(withCompressionQuality: 0.9, actions: { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: image.size))
            image.draw(in: CGRect(origin: .zero, size: image.size))
        })
        guard !jpeg.isEmpty, jpeg.count <= ExteraImageSearchProtocol.maximumUploadBytes else {
            throw ExteraImageSearchProtocol.SearchError.invalidImage
        }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        var metadata: [(String, String)] = []
        for (label, value) in [
            ("Camera", tiff[kCGImagePropertyTIFFMake as String]),
            ("Model", tiff[kCGImagePropertyTIFFModel as String]),
            ("DateTimeOriginal", exif[kCGImagePropertyExifDateTimeOriginal as String]),
            ("LensModel", exif[kCGImagePropertyExifLensModel as String]),
            ("ExposureTime", exif[kCGImagePropertyExifExposureTime as String]),
            ("FNumber", exif[kCGImagePropertyExifFNumber as String]),
            ("ISOSpeedRatings", exif[kCGImagePropertyExifISOSpeedRatings as String]),
        ] {
            if let value { metadata.append((label, String(String(describing: value).prefix(256)))) }
        }
        if properties[kCGImagePropertyGPSDictionary as String] != nil {
            metadata.append(("GPS", "Present"))
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ExteraImageSearchPhoto(preview: UIImage(data: jpeg) ?? image, jpeg: jpeg, byteCount: data.count,
                                      width: width, height: height, format: CGImageSourceGetType(source).map { $0 as String } ?? "image",
                                      sha256: digest, metadata: metadata)
    }
}
