import UIKit

// Cached native drawing operations. Stroked outlines, gradients, paths, and sprites
// are created ONLY while preparing geometry, never inside a display-link callback.
@MainActor
private enum AtmosphericStaticCommand {
    case fill(CGPath, CGColor)
    case gradient(CGPath, CGGradient, CGPoint, CGPoint)
    case image(CGImage, CGRect, CGFloat)

    var bounds: CGRect {
        switch self {
        case let .fill(path, _), let .gradient(path, _, _, _): return path.boundingBoxOfPath
        case let .image(_, rect, _): return rect
        }
    }

    func draw(in context: CGContext, opacity: CGFloat) {
        context.saveGState()
        switch self {
        case let .fill(path, color):
            context.setAlpha(opacity)
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
        case let .gradient(path, gradient, start, end):
            context.setAlpha(opacity)
            context.addPath(path)
            context.clip()
            context.drawLinearGradient(gradient, start: start, end: end,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case let .image(image, rect, alpha):
            context.setAlpha(alpha * opacity)
            atmosphericDrawImage(image, in: rect, context: context)
        }
        context.restoreGState()
    }
}

@MainActor
private struct AtmosphericStaticBatch {
    let commands: [AtmosphericStaticCommand]
    let image: CGImage?
    let imageRect: CGRect

    init(commands: [AtmosphericStaticCommand], displayScale: CGFloat) {
        self.commands = commands
        var union = CGRect.null
        for command in commands { union = union.union(command.bounds) }
        let rect = union.isNull ? CGRect.zero : union.integral
        imageRect = rect
        let scale = displayScale > 0 && displayScale.isFinite ? displayScale : 1
        let width = ceil(rect.width * scale)
        let height = ceil(rect.height * scale)
        // Bounded to 4 MiB per static batch. Tall/very wide shapes keep cached vector commands.
        // That fallback creates no new CGPath/CGGradient/CGColor/CGImage during drawing.
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= 2048, height <= 2048, width * height <= 1_048_576,
              let context = atmosphericBitmapContext(width: Int(width), height: Int(height)) else {
            image = nil
            return
        }
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        for command in commands { command.draw(in: context, opacity: 1) }
        image = context.makeImage()
    }

    func draw(in context: CGContext, opacity: CGFloat) {
        if let image {
            context.setAlpha(opacity)
            atmosphericDrawImage(image, in: imageRect, context: context)
        } else {
            for command in commands { command.draw(in: context, opacity: opacity) }
        }
    }
}

@MainActor
private struct AtmosphericSparkle {
    let image: CGImage
    let rect: CGRect
    let baseAlpha: CGFloat
    let center: CGFloat
    let amplitude: CGFloat
    let frequency: CGFloat
    let phase: CGFloat

    init(point: CGPoint, size: CGFloat, rgb: AtmosphericRGB, baseAlpha: CGFloat,
         center: CGFloat = 0.675, amplitude: CGFloat = 0.325,
         frequency: CGFloat = 2.5, phase: CGFloat) throws {
        image = try AtmosphericSpriteStore.shared.sparkle(rgb: rgb)
        let half = size * 1.19
        rect = CGRect(x: point.x - half, y: point.y - half, width: half * 2, height: half * 2)
        self.baseAlpha = baseAlpha
        self.center = center
        self.amplitude = amplitude
        self.frequency = frequency
        self.phase = phase
    }

    func draw(in context: CGContext, elapsed: TimeInterval, opacity: CGFloat) {
        let pulse = center + amplitude * sin(CGFloat(elapsed) * frequency + phase)
        let alpha = Int(baseAlpha * pulse * opacity)
        guard alpha > 4 else { return }
        // Source _tinted_paint's 16-level alpha quantization.
        let quantized = min(255, (alpha >> 4) * 16 + 15)
        context.setAlpha(CGFloat(quantized) / 255)
        atmosphericDrawImage(image, in: rect, context: context)
    }
}

@MainActor
private final class AtmosphericSelectedTab {
    let fill: CGPath?
    let rim: CGPath?
    let fillColor: CGColor
    let rimColor: CGColor
    let fillAlpha: CGFloat
    let sparkles: [AtmosphericSparkle]
    let bounds: CGRect

    // Geometry is origin-independent. Moving/fading a selected tab never creates a new path.
    init(size: CGSize, isDark: Bool, renderPlane: AtmosphericRenderPlane) throws {
        let rect = CGRect(origin: .zero, size: size)
        let fillPath = renderPlane != .foreground ? roundedPath(rect, radius: min(size.width, size.height) * 0.5) : nil
        let rimRect = rect.insetBy(dx: 0.6, dy: 0.6)
        let rimPath = renderPlane != .background && rimRect.width > 0 && rimRect.height > 0
            ? stroked(roundedPath(rimRect, radius: min(rimRect.width, rimRect.height) * 0.5), width: 1.05) : nil
        fill = fillPath
        rim = rimPath
        fillColor = atmosphericColor(255, 130, 210, 255)
        rimColor = atmosphericColor(255, 175, 226, 255)
        fillAlpha = isDark ? 34 : 42
        let preparedSparkles: [AtmosphericSparkle]
        if renderPlane != .background {
            preparedSparkles = [
                try .init(point: CGPoint(x: rect.maxX - 7, y: rect.minY + 7), size: 3,
                          rgb: .init(235, 248, 255), baseAlpha: 210,
                          center: 0.725, amplitude: 0.275, frequency: 3.1, phase: 0),
                try .init(point: CGPoint(x: rect.minX + 8, y: rect.maxY - 7), size: 2.2,
                          rgb: .init(255, 232, 170), baseAlpha: 170,
                          center: 0.725, amplitude: 0.275, frequency: 2.7, phase: 1.9)
            ]
        } else {
            preparedSparkles = []
        }
        sparkles = preparedSparkles
        var drawingBounds = CGRect.null
        if let fillPath { drawingBounds = drawingBounds.union(fillPath.boundingBoxOfPath) }
        if let rimPath { drawingBounds = drawingBounds.union(rimPath.boundingBoxOfPath) }
        for sparkle in preparedSparkles { drawingBounds = drawingBounds.union(sparkle.rect) }
        bounds = drawingBounds
    }

    func drawBackground(in context: CGContext, elapsed: TimeInterval, opacity: CGFloat) {
        guard let fill else { return }
        let pulse = 0.72 + 0.28 * sin(elapsed * 2.3)
        let alpha = Int(Double(fillAlpha) * pulse)
        context.setAlpha(CGFloat(alpha) / 255 * opacity)
        context.setFillColor(fillColor)
        context.addPath(fill)
        context.fillPath()
    }

    func drawForeground(in context: CGContext, elapsed: TimeInterval, opacity: CGFloat) {
        let pulse = 0.65 + 0.35 * sin(elapsed * 2.3)
        if let rim {
            context.setAlpha(CGFloat(Int(115 * pulse)) / 255 * opacity)
            context.setFillColor(rimColor)
            context.addPath(rim)
            context.fillPath()
        }
        for sparkle in sparkles {
            sparkle.draw(in: context, elapsed: elapsed, opacity: opacity)
        }
    }
}

// Immutable cached body. Presentation alpha/origin/clip/fade are deliberately absent.
@MainActor
private final class AtmosphericDecorationBody {
    let background: AtmosphericStaticBatch
    let foreground: AtmosphericStaticBatch
    let sparkles: [AtmosphericSparkle]
    let bounds: CGRect

    init(background: [AtmosphericStaticCommand], foreground: [AtmosphericStaticCommand],
         sparkles: [AtmosphericSparkle], displayScale: CGFloat) {
        let backgroundBatch = AtmosphericStaticBatch(commands: background, displayScale: displayScale)
        let foregroundBatch = AtmosphericStaticBatch(commands: foreground, displayScale: displayScale)
        self.background = backgroundBatch
        self.foreground = foregroundBatch
        self.sparkles = sparkles
        var drawingBounds = CGRect.null
        if !background.isEmpty { drawingBounds = drawingBounds.union(backgroundBatch.imageRect) }
        if !foreground.isEmpty { drawingBounds = drawingBounds.union(foregroundBatch.imageRect) }
        for sparkle in sparkles { drawingBounds = drawingBounds.union(sparkle.rect) }
        bounds = drawingBounds
    }
}

private struct AtmosphericPillBodyKey: Equatable {
    let size: CGSize
    let radius: CGFloat
    let isCircle: Bool
    let isNavbar: Bool
    let thin: Bool
    let rimWidth: CGFloat
    let style: AtmosphericFestiveStyle
    let palette: AtmosphericGarlandPalette
    let isDark: Bool
    let displayScale: CGFloat
    let drawsFrostWash: Bool
    let drawsTopDecoration: Bool
    let drawsBottomDecoration: Bool
    let clampsTopEdge: Bool
    let sparkleBaseAlpha: CGFloat?
    let renderPlane: AtmosphericRenderPlane
}

private struct AtmosphericAvatarBodyKey: Equatable {
    let referenceInset: CGFloat
    let style: AtmosphericFestiveStyle
    let palette: AtmosphericGarlandPalette
    let displayScale: CGFloat
    let renderPlane: AtmosphericRenderPlane
}

private enum AtmosphericDecorationBodyKey: Equatable {
    case pill(AtmosphericPillBodyKey)
    case avatar(AtmosphericAvatarBodyKey)
}

private struct AtmosphericSelectedTabKey: Equatable {
    let size: CGSize
    let isDark: Bool
    let renderPlane: AtmosphericRenderPlane
}

@MainActor
private struct AtmosphericCachedSelectedTab {
    let key: AtmosphericSelectedTabKey
    let body: AtmosphericSelectedTab
}

/// A lightweight presentation of one cached body and at most one selected-tab body.
/// Reusing the last preparation is bounded; no historical geometry dictionary is retained.
@MainActor
struct AtmosphericDecoration {
    private let bodyKey: AtmosphericDecorationBodyKey
    private let body: AtmosphericDecorationBody
    private let cachedSelectedTab: AtmosphericCachedSelectedTab?
    private let selectedTab: AtmosphericSelectedTab?
    private let selectedTabOrigin: CGPoint
    private let selectedTabOpacity: CGFloat
    private let transform: CGAffineTransform
    private let clipRect: CGRect?
    let opacity: CGFloat
    let isVisible: Bool
    let renderPlane: AtmosphericRenderPlane

    var needsAnimation: Bool {
        guard isVisible else { return false }
        switch renderPlane {
        case .background: return selectedTab != nil
        case .foreground, .combined: return selectedTab != nil || !body.sparkles.isEmpty
        }
    }

    // Internal identities/drawing diagnostics for source-only cache/plane tests, not adapter API.
    var staticBodyIdentity: ObjectIdentifier { return ObjectIdentifier(body) }
    var selectedTabBodyIdentity: ObjectIdentifier? { return selectedTab.map { ObjectIdentifier($0) } }
    var staticBackgroundCommandCount: Int { return body.background.commands.count }
    var staticForegroundCommandCount: Int { return body.foreground.commands.count }
    var hasBackgroundDrawing: Bool { return !body.background.commands.isEmpty || selectedTab?.fill != nil }
    var hasForegroundDrawing: Bool {
        return !body.foreground.commands.isEmpty || !body.sparkles.isEmpty
            || selectedTab?.rim != nil || selectedTab?.sparkles.isEmpty == false
    }

    // Constant-size CGRect math, using bounds prepared with the immutable bodies.
    // This lets a full-screen overlay stop when its actual decorated target scrolls offscreen.
    var presentationBounds: CGRect {
        guard isVisible else { return .null }
        var rect = body.bounds
        if let selectedTab {
            rect = rect.union(selectedTab.bounds.offsetBy(dx: selectedTabOrigin.x, dy: selectedTabOrigin.y))
        }
        guard !rect.isNull else { return .null }
        rect = rect.applying(transform)
        if let clipRect { rect = rect.intersection(clipRect) }
        guard !rect.isNull, rect.minX.isFinite, rect.minY.isFinite,
              rect.maxX.isFinite, rect.maxY.isFinite, rect.width > 0, rect.height > 0 else { return .null }
        return rect
    }

    private init(bodyKey: AtmosphericDecorationBodyKey, body: AtmosphericDecorationBody,
                 cachedSelectedTab: AtmosphericCachedSelectedTab?, selectedTab: AtmosphericSelectedTab?,
                 selectedTabOrigin: CGPoint = .zero, selectedTabOpacity: CGFloat = 1,
                 transform: CGAffineTransform, clipRect: CGRect?, opacity: CGFloat,
                 isVisible: Bool, renderPlane: AtmosphericRenderPlane) {
        self.bodyKey = bodyKey
        self.body = body
        self.cachedSelectedTab = cachedSelectedTab
        self.selectedTab = selectedTab
        self.selectedTabOrigin = selectedTabOrigin
        self.selectedTabOpacity = selectedTabOpacity
        self.transform = transform
        self.clipRect = clipRect
        self.opacity = opacity
        self.isVisible = isVisible && opacity > 0.02
        self.renderPlane = renderPlane
    }

    static func prepare(surface: AtmosphericSurface, configuration: AtmosphericSnowConfiguration,
                        renderPlane: AtmosphericRenderPlane, isDark: Bool, displayScale: CGFloat,
                        reusing previous: Self? = nil) throws -> Self? {
        switch surface {
        case .snow: return nil
        case let .navigationBar(geometry):
            return try preparePill(geometry.pill, configuration: configuration, renderPlane: renderPlane,
                                   isDark: isDark, displayScale: displayScale, isNavbar: true, thin: false,
                                   rimWidth: 1.15, selectedTab: geometry.selectedTab, previous: previous)
        case let .glassPill(_, geometry):
            return try preparePill(geometry, configuration: configuration, renderPlane: renderPlane,
                                   isDark: isDark, displayScale: displayScale, isNavbar: false, thin: false,
                                   rimWidth: 1.05, selectedTab: nil, previous: previous)
        case let .sectionCard(geometry):
            return try preparePill(geometry.pill, configuration: configuration, renderPlane: renderPlane,
                                   isDark: isDark, displayScale: displayScale, isNavbar: false, thin: true,
                                   rimWidth: 1.20, selectedTab: nil, previous: previous)
        case let .profileAction(geometry):
            var pill = geometry.pill
            let fade = max(0, min(1, (geometry.expansionFraction - 0.68) / 0.32))
            pill.visibility.opacity *= fade
            pill.visibility.isVisible = pill.visibility.isVisible && fade > 0.05 && geometry.scale > 0.25
                && pill.visibility.opacity > 0.04
            if let clip = pill.clipRect {
                let intersection = pill.rect.intersection(clip)
                pill.visibility.isVisible = pill.visibility.isVisible && intersection.width >= 12
                    && intersection.height >= 14 && clip.maxY - pill.rect.minY >= pill.rect.height * 0.65
                    && pill.rect.maxY > 4
            }
            var reference: CGSize? = nil
            if let expanded = geometry.expandedReferenceSize {
                let widthRatio = pill.rect.width / expanded.width
                let heightRatio = pill.rect.height / expanded.height
                if min(widthRatio, heightRatio) <= 0.68 { pill.visibility.isVisible = false }
                if geometry.scale < 0.999 || widthRatio < 0.98 || heightRatio < 0.98 { reference = expanded }
            }
            return try preparePill(pill, configuration: configuration, renderPlane: renderPlane,
                                   isDark: isDark, displayScale: displayScale, isNavbar: false, thin: true,
                                   rimWidth: 1.15, selectedTab: nil, referenceSize: reference,
                                   actionScale: reference == nil ? 1 : geometry.scale, previous: previous)
        case let .profileAvatar(geometry):
            return try prepareAvatar(geometry, configuration: configuration, renderPlane: renderPlane,
                                     displayScale: displayScale, previous: previous)
        }
    }

    func draw(in context: CGContext, elapsed: TimeInterval) {
        guard isVisible else { return }
        context.saveGState()
        if let clipRect { context.clip(to: clipRect) }
        context.concatenate(transform)
        if renderPlane != .foreground {
            body.background.draw(in: context, opacity: opacity)
            drawSelectedTab(in: context, elapsed: elapsed, isForeground: false)
        }
        if renderPlane != .background {
            body.foreground.draw(in: context, opacity: opacity)
            for sparkle in body.sparkles { sparkle.draw(in: context, elapsed: elapsed, opacity: opacity) }
            drawSelectedTab(in: context, elapsed: elapsed, isForeground: true)
        }
        context.restoreGState()
    }

    private func drawSelectedTab(in context: CGContext, elapsed: TimeInterval, isForeground: Bool) {
        guard let selectedTab else { return }
        context.saveGState()
        context.translateBy(x: selectedTabOrigin.x, y: selectedTabOrigin.y)
        if isForeground {
            selectedTab.drawForeground(in: context, elapsed: elapsed, opacity: opacity * selectedTabOpacity)
        } else {
            selectedTab.drawBackground(in: context, elapsed: elapsed, opacity: opacity * selectedTabOpacity)
        }
        context.restoreGState()
    }

    private static func preparePill(
        _ pill: AtmosphericPillGeometry, configuration: AtmosphericSnowConfiguration,
        renderPlane: AtmosphericRenderPlane, isDark: Bool, displayScale: CGFloat,
        isNavbar: Bool, thin: Bool, rimWidth: CGFloat, selectedTab tab: AtmosphericSelectedTabGeometry?,
        referenceSize: CGSize? = nil, actionScale: CGFloat = 1, previous: Self?
    ) throws -> Self {
        let sourceSize = referenceSize ?? pill.rect.size
        let scale = displayScale > 0 && displayScale.isFinite ? displayScale : 1
        var size = sourceSize
        if thin && size.height <= 120 {
            size.width = max(24, (size.width * scale * 0.125).rounded(.toNearestOrEven) * 8) / scale
            size.height = max(22, (size.height * scale * 0.25).rounded(.toNearestOrEven) * 4) / scale
        }
        let targetSize = CGSize(width: pill.rect.width * actionScale, height: pill.rect.height * actionScale)
        let transform = CGAffineTransform(a: targetSize.width / size.width, b: 0, c: 0,
                                          d: targetSize.height / size.height,
                                          tx: pill.rect.midX - targetSize.width * 0.5,
                                          ty: pill.rect.midY - targetSize.height * 0.5)
        // Source uses 140-dp reference geometry for tall cached strips. Rims use actual height.
        let geometryHeight: CGFloat = !isNavbar && size.height > 120 ? 140 : size.height
        let shape = PillSpec.shapeParameters(width: size.width, height: geometryHeight,
                                            shape: pill.shape, isNavbar: isNavbar)
        let hasForeground = renderPlane != .background
        let style = hasForeground ? configuration.navbarStyle : .snowcapAndGarland
        let drawsWash = renderPlane != .foreground && (isNavbar || pill.drawsFrostWash)
        let drawsTop = hasForeground && pill.drawsTopDecoration && style != .auroraAndSparkles
        let drawsBottom = hasForeground && pill.drawsBottomDecoration && style == .frostAndIcicles
        let hasGradientRim = hasForeground && style != .warmGarland && !(thin && size.height > 120)
        let sparkleAlpha: CGFloat?
        if hasForeground && style == .auroraAndSparkles {
            sparkleAlpha = 215
        } else if hasForeground && !isNavbar && !thin && configuration.navbarActiveGlow {
            sparkleAlpha = 155
        } else {
            sparkleAlpha = nil
        }
        let key = AtmosphericPillBodyKey(
            size: size, radius: shape.radius, isCircle: shape.isCircle,
            isNavbar: isNavbar, thin: thin, rimWidth: rimWidth, style: style,
            palette: drawsTop && (style == .snowcapAndGarland || style == .warmGarland)
                ? configuration.navbarGarlandPalette : .holidayMix,
            isDark: drawsWash || hasGradientRim ? isDark : false, displayScale: scale,
            drawsFrostWash: drawsWash, drawsTopDecoration: drawsTop, drawsBottomDecoration: drawsBottom,
            clampsTopEdge: drawsTop && style != .warmGarland && !isNavbar
                && (pill.clampsTopEdge ?? (pill.rect.minY <= 1.8)),
            sparkleBaseAlpha: sparkleAlpha, renderPlane: renderPlane
        )
        let bodyKey = AtmosphericDecorationBodyKey.pill(key)
        let body: AtmosphericDecorationBody
        if let previous, previous.bodyKey == bodyKey {
            body = previous.body
        } else {
            body = try makePillBody(key)
        }

        var cachedSelected = previous?.cachedSelectedTab
        var selected: AtmosphericSelectedTab? = nil
        var selectedOrigin = CGPoint.zero
        var selectedOpacity: CGFloat = 1
        if isNavbar, configuration.navbarActiveGlow, let tab,
           tab.visibility.isVisible, tab.visibility.opacity > 0.02 {
            let selectedKey = AtmosphericSelectedTabKey(size: tab.rect.size, isDark: isDark, renderPlane: renderPlane)
            if let cached = cachedSelected, cached.key == selectedKey {
                selected = cached.body
            } else {
                let selectedBody = try AtmosphericSelectedTab(size: tab.rect.size, isDark: isDark, renderPlane: renderPlane)
                cachedSelected = .init(key: selectedKey, body: selectedBody)
                selected = selectedBody
            }
            selectedOrigin = CGPoint(x: tab.rect.minX - pill.rect.minX, y: tab.rect.minY - pill.rect.minY)
            selectedOpacity = tab.visibility.opacity
        }
        return .init(bodyKey: bodyKey, body: body, cachedSelectedTab: cachedSelected, selectedTab: selected,
                     selectedTabOrigin: selectedOrigin, selectedTabOpacity: selectedOpacity,
                     transform: transform, clipRect: pill.clipRect,
                     opacity: pill.visibility.opacity, isVisible: pill.visibility.isVisible, renderPlane: renderPlane)
    }

    private static func makePillBody(_ key: AtmosphericPillBodyKey) throws -> AtmosphericDecorationBody {
        let size = key.size
        let geometryHeight: CGFloat = !key.isNavbar && size.height > 120 ? 140 : size.height
        let spec = PillSpec(width: size.width, height: geometryHeight, radius: key.radius,
                            isCircle: key.isCircle, isNavbar: key.isNavbar, thin: key.thin)
        let outline = roundedPath(CGRect(origin: .zero, size: size), radius: key.radius)
        let style = key.style
        var background: [AtmosphericStaticCommand] = []
        var foreground: [AtmosphericStaticCommand] = []
        var sparkles: [AtmosphericSparkle] = []

        if key.drawsFrostWash {
            let alpha = key.isNavbar ? (key.isDark ? 30 : 38) : (key.isDark ? 22 : 30)
            background.append(try gradientFill(outline, colors: [atmosphericColor(alpha, 165, 218, 255),
                                                                atmosphericColor(0, 180, 225, 255)],
                                               stops: [0, 1], startY: 0, endY: geometryHeight * 0.65))
        }
        if key.renderPlane != .background && style != .warmGarland {
            let rim = stroked(outline, width: key.rimWidth)
            if key.thin && size.height > 120 {
                foreground.append(.fill(rim, atmosphericColor(95, 220, 242, 255)))
            } else {
                let top = key.isDark ? atmosphericColor(145, 210, 236, 255) : atmosphericColor(170, 130, 195, 245)
                let bottom = key.isDark ? atmosphericColor(45, 130, 185, 235) : atmosphericColor(60, 100, 165, 225)
                foreground.append(try gradientFill(rim, colors: [top, bottom], stops: [0, 1],
                                                   startY: 0, endY: geometryHeight))
            }
        }
        if key.drawsBottomDecoration {
            let paths = spec.iciclePaths(actualHeight: size.height)
            foreground.append(try gradientFill(paths.fill,
                                               colors: [atmosphericColor(195, 235, 248, 255),
                                                        atmosphericColor(115, 175, 220, 255)],
                                               stops: [0, 1], startY: size.height - 1,
                                               endY: size.height + spec.maximumIcicleLength + 0.5))
            foreground.append(.fill(stroked(paths.highlight, width: 0.70), atmosphericColor(145, 255, 255, 255)))
        }
        if key.drawsTopDecoration {
            if style == .snowcapAndGarland || style == .frostAndIcicles {
                let paths = spec.snowPaths(clampTop: key.clampsTopEdge)
                foreground.append(try gradientFill(paths.fill,
                                                   colors: [atmosphericColor(242, 255, 255, 255),
                                                            atmosphericColor(215, 232, 245, 255),
                                                            atmosphericColor(145, 185, 218, 250)],
                                                   stops: [0, 0.58, 1], startY: -1.8, endY: 5.8 * spec.thickness))
                foreground.append(.fill(stroked(paths.crest, width: 0.85), atmosphericColor(190, 255, 255, 255)))
            }
            if style == .snowcapAndGarland || style == .warmGarland {
                let wire = spec.garlandGeometry()
                foreground.append(.fill(stroked(wire.path, width: 0.95), atmosphericColor(120, 62, 92, 118)))
                try appendBulbs(to: &foreground, points: wire.bulbs, auraRadius: spec.auraRadius,
                                palette: key.palette)
            }
        }
        if let baseAlpha = key.sparkleBaseAlpha {
            for (index, position) in spec.sparklePositions.enumerated() {
                sparkles.append(try .init(point: position.point, size: position.size,
                                         rgb: .init(220, 244, 255),
                                         baseAlpha: baseAlpha,
                                         phase: CGFloat(index) * 2.1))
            }
        }
        return .init(background: background, foreground: foreground, sparkles: sparkles, displayScale: key.displayScale)
    }

    private static func prepareAvatar(_ geometry: AtmosphericAvatarGeometry,
                                      configuration: AtmosphericSnowConfiguration,
                                      renderPlane: AtmosphericRenderPlane, displayScale: CGFloat,
                                      previous: Self?) throws -> Self {
        let scale = displayScale > 0 && displayScale.isFinite ? displayScale : 1
        let side = min(geometry.rect.width, geometry.rect.height)
        let referenceScale = side / 96
        let storyInset = geometry.hasStories ? floor(3.5 * scale) / scale : 0
        let inset = storyInset * (1 - geometry.expansionProgress) * geometry.insetProgress * (1 - geometry.foregroundAlpha)
        let referenceInset = inset > 0.5 && referenceScale > 0.05
            ? (inset / referenceScale * scale).rounded(.toNearestOrEven) / scale : 0
        let style = configuration.navbarStyle
        let key = AtmosphericAvatarBodyKey(
            referenceInset: referenceInset, style: style,
            palette: style == .snowcapAndGarland || style == .warmGarland
                ? configuration.navbarGarlandPalette : .holidayMix,
            displayScale: scale, renderPlane: renderPlane
        )
        let bodyKey = AtmosphericDecorationBodyKey.avatar(key)
        let body: AtmosphericDecorationBody
        if let previous, previous.bodyKey == bodyKey {
            body = previous.body
        } else {
            body = try makeAvatarBody(key)
        }
        let fade = max(0, min(1, (0.55 - geometry.expansionProgress) / 0.35))
        let opacity = fade * geometry.visibility.opacity
        return .init(bodyKey: bodyKey, body: body, cachedSelectedTab: previous?.cachedSelectedTab, selectedTab: nil,
                     transform: CGAffineTransform(a: referenceScale, b: 0, c: 0, d: referenceScale,
                                                  tx: geometry.rect.midX - side * 0.5,
                                                  ty: geometry.rect.midY - side * 0.5),
                     clipRect: geometry.clipRect, opacity: opacity,
                     isVisible: geometry.visibility.isVisible && geometry.expansionProgress < 0.55
                        && side * 0.5 - inset >= 18 && opacity > 0.04, renderPlane: renderPlane)
    }

    private static func makeAvatarBody(_ key: AtmosphericAvatarBodyKey) throws -> AtmosphericDecorationBody {
        guard key.renderPlane != .background else {
            return .init(background: [], foreground: [], sparkles: [], displayScale: key.displayScale)
        }
        let outerRadius = 48 - key.referenceInset
        let rimRadius = max(12, outerRadius - 1.35)
        let circle = CGPath(ellipseIn: CGRect(x: 48 - rimRadius, y: 48 - rimRadius,
                                            width: rimRadius * 2, height: rimRadius * 2), transform: nil)
        var foreground: [AtmosphericStaticCommand] = [
            .fill(stroked(circle, width: 3.4), atmosphericColor(85, 170, 224, 255)),
            try gradientFill(stroked(circle, width: 1.65),
                             colors: [atmosphericColor(235, 224, 244, 255), atmosphericColor(120, 145, 206, 250)],
                             stops: [0, 1], startY: 48 - rimRadius, endY: 48 + rimRadius)
        ]
        let style = key.style
        if style != .warmGarland {
            let arc = CGMutablePath()
            arc.addArc(center: CGPoint(x: 48, y: 48), radius: rimRadius - 1.2,
                       startAngle: -162 * .pi / 180, endAngle: -18 * .pi / 180, clockwise: false)
            foreground.append(.fill(stroked(arc, width: 0.9), atmosphericColor(175, 245, 252, 255)))
        }
        if style == .snowcapAndGarland || style == .frostAndIcicles {
            let fill = CGMutablePath()
            let crest = CGMutablePath()
            var inner: [CGPoint] = []
            let snowRadius = outerRadius - 0.5
            for index in 0...28 {
                let u = CGFloat(index) / 28
                let angle = (-142 + 104 * u) * .pi / 180
                let taper = pow(max(0, sin(.pi * u)), 0.55)
                let thickness = (2.1 + 0.85 * sin(u * .pi * 5 + 0.3)) * taper
                let outside = CGPoint(x: 48 + cos(angle) * snowRadius, y: 48 + sin(angle) * snowRadius)
                let innerRadius = max(8, snowRadius - thickness)
                inner.append(CGPoint(x: 48 + cos(angle) * innerRadius, y: 48 + sin(angle) * innerRadius))
                if index == 0 { fill.move(to: outside); crest.move(to: outside) }
                else { fill.addLine(to: outside); crest.addLine(to: outside) }
            }
            for point in inner.reversed() { fill.addLine(to: point) }
            fill.closeSubpath()
            foreground.append(try gradientFill(fill,
                                               colors: [atmosphericColor(245, 255, 255, 255),
                                                        atmosphericColor(175, 214, 238, 255)],
                                               stops: [0, 1], startY: 48 - outerRadius, endY: 48 - outerRadius * 0.45))
            foreground.append(.fill(stroked(crest, width: 0.75), atmosphericColor(195, 255, 255, 255)))
        }
        if style == .snowcapAndGarland || style == .warmGarland {
            let count = outerRadius >= 44 ? 14 : 10
            let wire = CGMutablePath()
            let radius = rimRadius - 2.3
            for index in 0..<(count * 5) {
                let u = CGFloat(index) / CGFloat(count * 5)
                let angle = 2 * .pi * u - .pi * 0.5
                let sag = abs(sin(u * .pi * CGFloat(count))) * 1.25
                let point = CGPoint(x: 48 + cos(angle) * (radius - sag), y: 48 + sin(angle) * (radius - sag))
                if index == 0 { wire.move(to: point) } else { wire.addLine(to: point) }
            }
            wire.closeSubpath()
            foreground.append(.fill(stroked(wire, width: 0.85), atmosphericColor(120, 62, 92, 118)))
            let points = (0..<count).map { index -> CGPoint in
                let angle = 2 * .pi * (CGFloat(index) + 0.5) / CGFloat(count) - .pi * 0.5
                return CGPoint(x: 48 + cos(angle) * (radius - 1.8), y: 48 + sin(angle) * (radius - 1.8))
            }
            try appendBulbs(to: &foreground, points: points, auraRadius: 4.2,
                            palette: key.palette)
        }
        var sparkles: [AtmosphericSparkle] = []
        if style == .auroraAndSparkles {
            for (index, degrees) in [CGFloat(-138), -42, 48, 138].enumerated() {
                let angle = degrees * .pi / 180
                let radius = rimRadius - 1.6
                sparkles.append(try .init(point: CGPoint(x: 48 + cos(angle) * radius, y: 48 + sin(angle) * radius),
                                         size: index < 2 ? 2.3 : 2.1, rgb: .init(225, 246, 255),
                                         baseAlpha: 225, phase: CGFloat(index) * 2.1))
            }
        }
        return .init(background: [], foreground: foreground, sparkles: sparkles, displayScale: key.displayScale)
    }
}

@MainActor
private func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

@MainActor
private func stroked(_ path: CGPath, width: CGFloat) -> CGPath {
    return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

@MainActor
private func gradientFill(_ path: CGPath, colors: [CGColor], stops: [CGFloat],
                          startY: CGFloat, endY: CGFloat) throws -> AtmosphericStaticCommand {
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                    locations: stops) else {
        throw AtmosphericRenderingError.graphicsAllocationFailed
    }
    return .gradient(path, gradient, CGPoint(x: 0, y: startY), CGPoint(x: 0, y: endY))
}

@MainActor
private func appendBulbs(to commands: inout [AtmosphericStaticCommand], points: [CGPoint],
                         auraRadius: CGFloat, palette: AtmosphericGarlandPalette) throws {
    let colors = palette.colors
    for (index, point) in points.enumerated() {
        let image = try AtmosphericSpriteStore.shared.bulb(rgb: colors[index % colors.count])
        commands.append(.image(image, CGRect(x: point.x - auraRadius, y: point.y - auraRadius,
                                             width: auraRadius * 2, height: auraRadius * 2), 225 / 255))
    }
}

// Compact parameter table follows source _build_pill_geometry (1382–1656).
private struct PillSpec {
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat
    let isNavbar: Bool
    let isCircle: Bool
    let thin: Bool
    let steps: Int
    let edgeInset: CGFloat
    let puff: CGFloat
    let thickness: CGFloat
    let bulbCount: Int
    let garlandInset: CGFloat
    let sag: CGFloat
    let wireY: CGFloat
    let bulbY: CGFloat
    let auraRadius: CGFloat
    let iciclePositions: [CGFloat]
    let icicleLengths: [CGFloat]
    let icicleInset: CGFloat
    let icicleHalfWidth: CGFloat

    var maximumIcicleLength: CGFloat { return icicleLengths.max() ?? 0 }

    static func shapeParameters(width: CGFloat, height: CGFloat, shape: AtmosphericPillShape,
                                isNavbar: Bool) -> (radius: CGFloat, isCircle: Bool) {
        switch shape {
        case .automatic:
            let radius = !isNavbar && height > 58 ? min(width * 0.5, height * 0.5, 24) : min(width, height) * 0.5
            return (radius, !isNavbar && width <= height * 1.28 && width < 110)
        case let .roundedRectangle(cornerRadius):
            return (max(0, min(width * 0.5, height * 0.5, cornerRadius)), false)
        }
    }

    init(width: CGFloat, height: CGFloat, radius: CGFloat, isCircle: Bool, isNavbar: Bool, thin: Bool) {
        self.width = width
        self.height = height
        self.radius = radius
        self.isCircle = isCircle
        self.isNavbar = isNavbar
        self.thin = thin
        let compact = !isNavbar && !isCircle && width < 145
        let basePuff: CGFloat
        let baseThickness: CGFloat
        let baseSag: CGFloat
        let baseAura: CGFloat
        let lengths: [CGFloat]
        if isNavbar {
            steps = 44; edgeInset = 0.22; basePuff = 1; baseThickness = 1
            bulbCount = 11; garlandInset = 0.36; baseSag = 2.3; wireY = 0.6
            baseAura = 7.2
            iciclePositions = [0.04, 0.12, 0.21, 0.31, 0.40, 0.50, 0.60, 0.69, 0.78, 0.87, 0.96]
            lengths = [4.2, 6.8, 3.6, 7.6, 4.8, 8.2, 4.4, 7.2, 3.9, 6.4, 4.5]
            icicleInset = 0.65; icicleHalfWidth = 1.35
        } else if isCircle {
            steps = 24; edgeInset = 0.22; basePuff = 0.50; baseThickness = 0.58
            bulbCount = 3; garlandInset = 0.30; baseSag = 1; wireY = 0.8
            baseAura = 4.6
            iciclePositions = [0.28, 0.50, 0.72]; lengths = [2.2, 3, 2.2]
            icicleInset = 0.62; icicleHalfWidth = 0.95
        } else if compact {
            steps = 28; edgeInset = 0.24; basePuff = 0.65; baseThickness = 0.68
            bulbCount = max(3, min(5, Int(floor(width / 26))))
            garlandInset = 0.34; baseSag = 1.45; wireY = 0.75; baseAura = 5.2
            iciclePositions = [0.14, 0.38, 0.62, 0.86]; lengths = [2.6, 3.9, 3.2, 2.7]
            icicleInset = 0.60; icicleHalfWidth = 1.05
        } else {
            steps = 40; edgeInset = 0.24; basePuff = 0.74; baseThickness = 0.74
            bulbCount = max(5, min(10, Int(floor(width / 36)) + 1))
            garlandInset = 0.34; baseSag = 1.75; wireY = 0.75; baseAura = 5.4
            let count = max(5, min(11, Int(floor(width / 24))))
            iciclePositions = (0..<count).map { (CGFloat($0) + 0.5) / CGFloat(count) }
            let base: [CGFloat] = [2.8, 4.4, 3.1, 4.9, 3.4, 4.1]
            lengths = (0..<count).map { base[$0 % base.count] }
            icicleInset = 0.65; icicleHalfWidth = 1.10
        }
        let isThin = thin && !isNavbar
        puff = basePuff * (isThin ? 0.62 : 1)
        thickness = baseThickness * (isThin ? 0.56 : 1)
        sag = baseSag * (isThin ? 0.72 : 1)
        bulbY = isThin ? 1.05 : (isNavbar ? 1.4 : (isCircle ? 1.25 : (compact ? 1.3 : 1.35)))
        auraRadius = isThin ? min(baseAura, 4.35) : baseAura
        icicleLengths = isThin ? lengths.map { $0 * 0.76 } : lengths
    }

    private func topY(_ x: CGFloat) -> CGFloat {
        if x < radius {
            let dx = radius - x
            return radius - sqrt(max(0, radius * radius - dx * dx))
        }
        if x > width - radius {
            let dx = x - (width - radius)
            return radius - sqrt(max(0, radius * radius - dx * dx))
        }
        return 0
    }

    func snowPaths(clampTop: Bool) -> (fill: CGPath, crest: CGPath) {
        let fill = CGMutablePath()
        let crest = CGMutablePath()
        var x0 = radius * edgeInset
        var x1 = width - radius * edgeInset
        if x1 <= x0 + 4 { x0 = radius * 0.15; x1 = width - radius * 0.15 }
        var bottom: [CGPoint] = []
        bottom.reserveCapacity(steps + 1)
        for index in 0...steps {
            let u = CGFloat(index) / CGFloat(steps)
            let x = x0 + (x1 - x0) * u
            let baseY = topY(x)
            let taper = pow(max(0, sin(.pi * u)), 0.55)
            let bump = (0.75 + 0.55 * sin(u * .pi * 5 + 0.4) + 0.30 * cos(u * .pi * 9)) * taper * puff
            let thickness = (3.1 + 1.35 * sin(u * .pi * 6 - 0.3) + 0.65 * cos(u * .pi * 11)) * taper * self.thickness
            let top = CGPoint(x: x, y: clampTop ? max(0, baseY - bump * 0.55) : baseY - bump * 0.55)
            bottom.append(CGPoint(x: x, y: baseY + thickness))
            if index == 0 { fill.move(to: top); crest.move(to: top) }
            else { fill.addLine(to: top); crest.addLine(to: top) }
        }
        for point in bottom.reversed() { fill.addLine(to: point) }
        fill.closeSubpath()
        return (fill, crest)
    }

    func garlandGeometry() -> (path: CGPath, bulbs: [CGPoint]) {
        let path = CGMutablePath()
        let x0 = radius * garlandInset
        let x1 = width - radius * garlandInset
        guard x1 > x0 + 4 else { return (path, []) }
        let steps = width > 120 ? 54 : 28
        for index in 0...steps {
            let u = CGFloat(index) / CGFloat(steps)
            let x = x0 + (x1 - x0) * u
            let sag = abs(sin(u * .pi * CGFloat(max(1, bulbCount - 1)) * 0.5)) * self.sag
            let point = CGPoint(x: x, y: topY(x) + wireY + sag)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        let bulbs = (0..<bulbCount).map { index -> CGPoint in
            let u = bulbCount == 1 ? 0.5 : CGFloat(index) / CGFloat(max(1, bulbCount - 1))
            let x = x0 + (x1 - x0) * u
            let sag = abs(sin(u * .pi * CGFloat(max(1, bulbCount - 1)) * 0.5)) * self.sag
            return CGPoint(x: x, y: topY(x) + bulbY + sag)
        }
        return (path, bulbs)
    }

    func iciclePaths(actualHeight: CGFloat) -> (fill: CGPath, highlight: CGPath) {
        let fill = CGMutablePath()
        let highlight = CGMutablePath()
        let x0 = radius * icicleInset
        let x1 = width - radius * icicleInset
        guard x1 > x0 + 4 else { return (fill, highlight) }
        let offset = actualHeight - height
        for (position, length) in zip(iciclePositions, icicleLengths) {
            let x = x0 + (x1 - x0) * position
            let top = height - 0.8
            let tip = height + length
            let halfWidth = icicleHalfWidth + length * 0.09
            fill.move(to: CGPoint(x: x - halfWidth, y: top + offset))
            fill.addQuadCurve(to: CGPoint(x: x, y: tip + offset),
                              control: CGPoint(x: x - halfWidth * 0.35, y: (top + tip) * 0.55 + offset))
            fill.addQuadCurve(to: CGPoint(x: x + halfWidth, y: top + offset),
                              control: CGPoint(x: x + halfWidth * 0.35, y: (top + tip) * 0.55 + offset))
            fill.closeSubpath()
            highlight.move(to: CGPoint(x: x - halfWidth * 0.35, y: top + 0.7 + offset))
            highlight.addLine(to: CGPoint(x: x - halfWidth * 0.08, y: tip - 1 + offset))
        }
        return (fill, highlight)
    }

    var sparklePositions: [(point: CGPoint, size: CGFloat)] {
        if isCircle {
            return [(CGPoint(x: width * 0.80, y: height * 0.22), 2.3),
                    (CGPoint(x: width * 0.20, y: height * 0.78), 1.9)]
        }
        if thin {
            let inset = max(radius, 12) * 0.65
            return [(CGPoint(x: inset, y: 6.5), 2), (CGPoint(x: width - inset, y: 6.5), 2)]
        }
        return [(CGPoint(x: radius * 0.62, y: 7.5), isNavbar ? 2.8 : 2.2),
                (CGPoint(x: width - radius * 0.62, y: 8), isNavbar ? 2.8 : 2.2),
                (CGPoint(x: width * 0.5, y: height - (isNavbar ? 5.5 : 4.2)), isNavbar ? 2.9 : 2.1)]
    }
}
