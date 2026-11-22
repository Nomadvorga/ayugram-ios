import UIKit

/// A native graphics-resource failure, separate from unsupported settings or geometry.
public enum AtmosphericRenderingError: Error, Equatable, Sendable, LocalizedError {
    case graphicsAllocationFailed
    case invalidatedView

    public var errorDescription: String? {
        switch self {
        case .graphicsAllocationFailed: return "Unable to allocate atmospheric graphics resources."
        case .invalidatedView: return "This atmospheric view has been permanently invalidated."
        }
    }
}

struct AtmosphericRGB: Hashable, Sendable {
    let red: Int
    let green: Int
    let blue: Int

    init(_ red: Int, _ green: Int, _ blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

extension AtmosphericSnowColor {
    func rgb(isDark: Bool) -> AtmosphericRGB {
        switch self {
        case .automatic: return isDark ? .init(240, 247, 255) : .init(118, 165, 214)
        case .white: return .init(255, 255, 255)
        case .icyBlue: return .init(188, 226, 255)
        case .warm: return .init(255, 241, 204)
        }
    }
}

extension AtmosphericGarlandPalette {
    var colors: [AtmosphericRGB] {
        switch self {
        case .holidayMix: return [.init(255, 208, 88), .init(255, 86, 98), .init(82, 232, 152), .init(110, 204, 255)]
        case .warmGold: return [.init(255, 214, 102), .init(255, 236, 168), .init(255, 184, 78)]
        case .icyNeon: return [.init(128, 214, 255), .init(235, 248, 255), .init(98, 238, 224)]
        }
    }
}

@MainActor
func atmosphericColor(_ alpha: Int, _ red: Int, _ green: Int, _ blue: Int) -> CGColor {
    return CGColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                   blue: CGFloat(blue) / 255, alpha: CGFloat(alpha) / 255)
}

@MainActor
func atmosphericColor(_ alpha: Int, _ rgb: AtmosphericRGB) -> CGColor {
    return atmosphericColor(alpha, rgb.red, rgb.green, rgb.blue)
}

@MainActor
func atmosphericBitmapContext(width: Int, height: Int) -> CGContext? {
    return CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    )
}

/// Draws a cached bitmap upright in a UIKit (top-left) context. No new bitmap is created.
@MainActor
func atmosphericDrawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
    context.saveGState()
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
}

@MainActor
final class AtmosphericSnowAtlas {
    let grain: CGImage
    let bokeh: CGImage
    private let crystals: [CGImage]

    init(rgb: AtmosphericRGB) throws {
        bokeh = try makeRadialSprite(size: 96, rgb: rgb,
                                    alphas: [255, 230, 155, 78, 28, 7, 0],
                                    stops: [0, 0.14, 0.30, 0.50, 0.70, 0.87, 1])
        grain = try makeRadialSprite(size: 64, rgb: rgb,
                                    alphas: [255, 245, 180, 72, 16, 0],
                                    stops: [0, 0.24, 0.44, 0.66, 0.84, 1])
        var images: [CGImage] = []
        images.reserveCapacity(18)
        for variant in 0..<3 {
            let base = try makeCrystalSprite(variant: variant, rgb: rgb)
            for rotation in 0..<6 {
                if rotation == 0 {
                    images.append(base)
                } else {
                    guard let context = atmosphericBitmapContext(width: 128, height: 128) else {
                        throw AtmosphericRenderingError.graphicsAllocationFailed
                    }
                    context.translateBy(x: 64, y: 64)
                    // Clockwise in the final upright image, in six source 10-degree steps.
                    context.rotate(by: -CGFloat(rotation) * .pi / 18)
                    context.draw(base, in: CGRect(x: -64, y: -64, width: 128, height: 128))
                    guard let image = context.makeImage() else {
                        throw AtmosphericRenderingError.graphicsAllocationFailed
                    }
                    images.append(image)
                }
            }
        }
        crystals = images
    }

    func image(for sprite: AtmosphericSnowSprite) -> CGImage {
        switch sprite {
        case .grain: return grain
        case .bokeh: return bokeh
        case let .crystal(variant, rotation): return crystals[variant * 6 + rotation]
        }
    }
}

// Shared across views: at most five source snow colors, ten bulb colors, four sparkle colors.
// Sprite construction is confined to prepare/configuration changes, never display-link ticks.
@MainActor
final class AtmosphericSpriteStore {
    static let shared = AtmosphericSpriteStore()
    private var snowAtlases: [AtmosphericRGB: AtmosphericSnowAtlas] = [:]
    private var snowOrder: [AtmosphericRGB] = []
    private var bulbs: [AtmosphericRGB: CGImage] = [:]
    private var sparkles: [AtmosphericRGB: CGImage] = [:]

    func removeAll() {
        snowAtlases.removeAll()
        snowOrder.removeAll()
        bulbs.removeAll()
        sparkles.removeAll()
    }

    func snowAtlas(rgb: AtmosphericRGB) throws -> AtmosphericSnowAtlas {
        if let atlas = snowAtlases[rgb] { return atlas }
        let atlas = try AtmosphericSnowAtlas(rgb: rgb)
        if snowOrder.count == 5 {
            snowAtlases.removeValue(forKey: snowOrder.removeFirst())
        }
        snowOrder.append(rgb)
        snowAtlases[rgb] = atlas
        return atlas
    }

    func bulb(rgb: AtmosphericRGB) throws -> CGImage {
        if let image = bulbs[rgb] { return image }
        guard let context = atmosphericBitmapContext(width: 64, height: 64) else {
            throw AtmosphericRenderingError.graphicsAllocationFailed
        }
        let aura = try makeRadialSprite(size: 96, rgb: rgb,
                                       alphas: [255, 230, 155, 78, 28, 7, 0],
                                       stops: [0, 0.14, 0.30, 0.50, 0.70, 0.87, 1])
        context.setAlpha(185 / 255)
        context.draw(aura, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setAlpha(1)
        let radius: CGFloat = 32 * 0.275
        context.setFillColor(atmosphericColor(235, rgb))
        context.fillEllipse(in: CGRect(x: 32 - radius, y: 32 - radius, width: radius * 2, height: radius * 2))
        context.setFillColor(atmosphericColor(220, 255, 255, 255))
        let highlight = radius * 0.45
        context.fillEllipse(in: CGRect(x: 32 - highlight, y: 32 - highlight, width: highlight * 2, height: highlight * 2))
        guard let image = context.makeImage() else { throw AtmosphericRenderingError.graphicsAllocationFailed }
        bulbs[rgb] = image
        return image
    }

    func sparkle(rgb: AtmosphericRGB) throws -> CGImage {
        if let image = sparkles[rgb] { return image }
        guard let context = atmosphericBitmapContext(width: 32, height: 32) else {
            throw AtmosphericRenderingError.graphicsAllocationFailed
        }
        let arm: CGFloat = 32 * 0.42
        let diagonal = arm * 0.55
        context.setLineCap(.round)
        context.setLineWidth(max(1, arm * 0.22))
        context.setStrokeColor(atmosphericColor(255, rgb))
        context.move(to: CGPoint(x: 16 - arm, y: 16))
        context.addLine(to: CGPoint(x: 16 + arm, y: 16))
        context.move(to: CGPoint(x: 16, y: 16 - arm))
        context.addLine(to: CGPoint(x: 16, y: 16 + arm))
        context.strokePath()
        context.setStrokeColor(atmosphericColor(166, rgb))
        context.move(to: CGPoint(x: 16 - diagonal, y: 16 - diagonal))
        context.addLine(to: CGPoint(x: 16 + diagonal, y: 16 + diagonal))
        context.move(to: CGPoint(x: 16 - diagonal, y: 16 + diagonal))
        context.addLine(to: CGPoint(x: 16 + diagonal, y: 16 - diagonal))
        context.strokePath()
        guard let image = context.makeImage() else { throw AtmosphericRenderingError.graphicsAllocationFailed }
        sparkles[rgb] = image
        return image
    }
}

@MainActor
private func makeRadialSprite(size: Int, rgb: AtmosphericRGB, alphas: [Int], stops: [CGFloat]) throws -> CGImage {
    guard let context = atmosphericBitmapContext(width: size, height: size) else {
        throw AtmosphericRenderingError.graphicsAllocationFailed
    }
    let colors = alphas.map { atmosphericColor($0, rgb) }
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                    locations: stops) else {
        throw AtmosphericRenderingError.graphicsAllocationFailed
    }
    let half = CGFloat(size) * 0.5
    let center = CGPoint(x: half, y: half)
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: half, options: [])
    guard let image = context.makeImage() else { throw AtmosphericRenderingError.graphicsAllocationFailed }
    return image
}

@MainActor
private func makeCrystalSprite(variant: Int, rgb: AtmosphericRGB) throws -> CGImage {
    guard let context = atmosphericBitmapContext(width: 128, height: 128) else {
        throw AtmosphericRenderingError.graphicsAllocationFailed
    }
    let glow = try makeRadialSprite(size: 128, rgb: rgb, alphas: [58, 26, 7, 0], stops: [0, 0.35, 0.72, 1])
    context.draw(glow, in: CGRect(x: 0, y: 0, width: 128, height: 128))
    let path = CGMutablePath()
    let length: CGFloat = 128 * 0.40
    let branches: [(CGFloat, CGFloat, CGFloat)]
    switch variant {
    case 0: branches = [(0.38, 0.24, 0.92), (0.64, 0.21, 0.90), (0.84, 0.11, 0.85)]
    case 1: branches = [(0.30, 0.16, 1.00), (0.50, 0.27, 0.92), (0.70, 0.19, 0.88), (0.87, 0.10, 0.82)]
    default: branches = [(0.44, 0.23, 1.02), (0.76, 0.18, 0.86)]
    }
    for arm in 0..<6 {
        let angle = CGFloat(arm) * .pi / 3
        let cosine = cos(angle)
        let sine = sin(angle)
        path.move(to: CGPoint(x: 64, y: 64))
        path.addLine(to: CGPoint(x: 64 + cosine * length, y: 64 + sine * length))
        for (position, ratio, branchAngle) in branches {
            let base = CGPoint(x: 64 + cosine * length * position, y: 64 + sine * length * position)
            for sign in [CGFloat(-1), CGFloat(1)] {
                let direction = angle + sign * branchAngle
                path.move(to: base)
                path.addLine(to: CGPoint(x: base.x + cos(direction) * length * ratio,
                                        y: base.y + sin(direction) * length * ratio))
            }
        }
        let ring = length * (variant == 2 ? 0.34 : 0.26)
        let nextAngle = CGFloat(arm + 1) * .pi / 3
        path.move(to: CGPoint(x: 64 + cosine * ring, y: 64 + sine * ring))
        path.addLine(to: CGPoint(x: 64 + cos(nextAngle) * ring, y: 64 + sin(nextAngle) * ring))
    }
    context.setLineCap(.round)
    context.setStrokeColor(atmosphericColor(65, rgb))
    context.setLineWidth(128 * 0.062)
    context.addPath(path)
    context.strokePath()
    context.setStrokeColor(atmosphericColor(245, rgb))
    context.setLineWidth(128 * 0.025)
    context.addPath(path)
    context.strokePath()
    context.setFillColor(atmosphericColor(255, rgb))
    let centerRadius: CGFloat = 128 * 0.026
    context.fillEllipse(in: CGRect(x: 64 - centerRadius, y: 64 - centerRadius,
                                  width: centerRadius * 2, height: centerRadius * 2))
    guard let image = context.makeImage() else { throw AtmosphericRenderingError.graphicsAllocationFailed }
    return image
}
