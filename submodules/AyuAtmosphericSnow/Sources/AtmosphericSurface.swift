import CoreGraphics
import Foundation

/// The host supplies page identity; this backend does not inspect app controllers.
public enum AtmosphericPageKind: Equatable, Sendable {
    case chat
    case chatList
    case profile
    case other
    /// Equivalent to the source finding no active fragment (excluded by restricted areas).
    case unavailable
    /// Explicit source exception fallback, not a guessed page (included by restricted areas).
    case lookupFailed
}

/// Host-controlled visibility complements window and ancestor checks.
/// Defaults to hidden so recycled/offscreen surfaces never start animating accidentally.
public struct AtmosphericHostState: Equatable, Sendable {
    public var pageKind: AtmosphericPageKind
    public var isVisible: Bool

    public init(pageKind: AtmosphericPageKind = .unavailable, isVisible: Bool = false) {
        self.pageKind = pageKind
        self.isVisible = isVisible
    }
}

/// Additional source drawable/action visibility, not UIKit ancestor alpha.
/// Do not repeat an opacity already applied to the overlay by UIKit.
public struct AtmosphericSurfaceVisibility: Equatable, Sendable {
    public var isVisible: Bool
    public var opacity: CGFloat

    public init(isVisible: Bool = true, opacity: CGFloat = 1) {
        self.isVisible = isVisible
        self.opacity = opacity
    }

    public static let visible = AtmosphericSurfaceVisibility()
    public static let hidden = AtmosphericSurfaceVisibility(isVisible: false, opacity: 0)
}

/// The supported source pill shapes. Arbitrary paths, meshes, and collision masks are
/// deliberately not accepted; the host must not replace such shapes with a guessed rectangle.
public enum AtmosphericPillShape: Equatable, Sendable {
    /// Source automatic pill: half-minimum radius, capped at 24 points for non-navbar heights > 58.
    case automatic
    /// Source explicit corner radius; positive radii are limited to half the shape's dimensions.
    case roundedRectangle(cornerRadius: CGFloat)
}

/// Geometry of one rounded source pill, in the effect view's local coordinates (UIKit points).
/// The host owns frame/layout and can explicitly suppress top/bottom strips on clipped cards.
public struct AtmosphericPillGeometry: Equatable, Sendable {
    public var rect: CGRect
    public var shape: AtmosphericPillShape
    public var visibility: AtmosphericSurfaceVisibility
    public var clipRect: CGRect?
    /// Used by glass pills. Navbar wash is unconditional; profile actions/cards require false.
    public var drawsFrostWash: Bool
    public var drawsTopDecoration: Bool
    public var drawsBottomDecoration: Bool
    /// Nil uses the source heuristic `rect.minY <= 1.8`.
    public var clampsTopEdge: Bool?

    public init(
        rect: CGRect,
        shape: AtmosphericPillShape = .automatic,
        visibility: AtmosphericSurfaceVisibility = .visible,
        clipRect: CGRect? = nil,
        drawsFrostWash: Bool = false,
        drawsTopDecoration: Bool = true,
        drawsBottomDecoration: Bool = true,
        clampsTopEdge: Bool? = nil
    ) {
        self.rect = rect
        self.shape = shape
        self.visibility = visibility
        self.clipRect = clipRect
        self.drawsFrostWash = drawsFrostWash
        self.drawsTopDecoration = drawsTopDecoration
        self.drawsBottomDecoration = drawsBottomDecoration
        self.clampsTopEdge = clampsTopEdge
    }
}

/// The host identifies the selected tab and supplies its final translated rectangle.
public struct AtmosphericSelectedTabGeometry: Equatable, Sendable {
    public var rect: CGRect
    public var visibility: AtmosphericSurfaceVisibility

    public init(rect: CGRect, visibility: AtmosphericSurfaceVisibility = .visible) {
        self.rect = rect
        self.visibility = visibility
    }
}

/// Actual navbar pill geometry, not the containing view's guessed safe-area rectangle.
/// Android's 7.67-dp inset is a host layout choice, not something this view applies to its frame.
public struct AtmosphericNavigationBarGeometry: Equatable, Sendable {
    public var pill: AtmosphericPillGeometry
    public var selectedTab: AtmosphericSelectedTabGeometry?

    public init(pill: AtmosphericPillGeometry, selectedTab: AtmosphericSelectedTabGeometry? = nil) {
        self.pill = pill
        self.selectedTab = selectedTab
    }
}

/// Source view-hook roles. Only message input accepts tall (up to 520-point) pills.
public enum AtmosphericGlassPillRole: Equatable, Sendable {
    case button
    case folder
    case header
    case search
    case profileTabs
    case messageInput
    /// Android's direct blurred-drawable path has the narrower 650-point width limit.
    case blurredDrawable
}

/// Avatar state that reproduces the source's expansion fade and story inset.
/// The renderer uses its 96-point reference ring and scales it to this rectangle.
public struct AtmosphericAvatarGeometry: Equatable, Sendable {
    public var rect: CGRect
    public var visibility: AtmosphericSurfaceVisibility
    public var expansionProgress: CGFloat
    public var hasStories: Bool
    public var insetProgress: CGFloat
    public var foregroundAlpha: CGFloat
    public var clipRect: CGRect?

    public init(
        rect: CGRect,
        visibility: AtmosphericSurfaceVisibility = .visible,
        expansionProgress: CGFloat = 0,
        hasStories: Bool = false,
        insetProgress: CGFloat = 1,
        foregroundAlpha: CGFloat = 0,
        clipRect: CGRect? = nil
    ) {
        self.rect = rect
        self.visibility = visibility
        self.expansionProgress = expansionProgress
        self.hasStories = hasStories
        self.insetProgress = insetProgress
        self.foregroundAlpha = foregroundAlpha
        self.clipRect = clipRect
    }
}

/// One profile action, not an inferred row of three buttons.
/// Supply source-equivalent expansion fraction and an optional stable expanded reference size.
/// Action/text/glass alpha and deleted/hidden state belong in `pill.visibility`.
public struct AtmosphericProfileActionGeometry: Equatable, Sendable {
    public var pill: AtmosphericPillGeometry
    public var expansionFraction: CGFloat
    public var scale: CGFloat
    public var expandedReferenceSize: CGSize?

    public init(
        pill: AtmosphericPillGeometry,
        expansionFraction: CGFloat = 1,
        scale: CGFloat = 1,
        expandedReferenceSize: CGSize? = nil
    ) {
        self.pill = pill
        self.expansionFraction = expansionFraction
        self.scale = scale
        self.expandedReferenceSize = expandedReferenceSize
    }
}

/// A host-grouped profile section card. This backend never scans list children or guesses groups.
public struct AtmosphericSectionCardGeometry: Equatable, Sendable {
    public var pill: AtmosphericPillGeometry

    public init(pill: AtmosphericPillGeometry) { self.pill = pill }
}

/// All supported native rendering surfaces. Each effect view represents exactly one surface.
public enum AtmosphericSurface: Equatable, Sendable {
    /// Falling snow over the full view bounds; filtered using the supplied host page kind.
    case snow
    case navigationBar(AtmosphericNavigationBarGeometry)
    case glassPill(role: AtmosphericGlassPillRole, geometry: AtmosphericPillGeometry)
    case profileAvatar(AtmosphericAvatarGeometry)
    case profileAction(AtmosphericProfileActionGeometry)
    case sectionCard(AtmosphericSectionCardGeometry)

    public var kind: AtmosphericSurfaceKind {
        switch self {
        case .snow: return .snow
        case .navigationBar: return .navigationBar
        case .glassPill: return .glassPill
        case .profileAvatar: return .profileAvatar
        case .profileAction: return .profileAction
        case .sectionCard: return .sectionCard
        }
    }

    /// Fails explicitly for unsupported dimensions and invalid geometry before updating a view.
    public func validate() throws {
        switch self {
        case .snow: break
        case let .navigationBar(geometry):
            try validatePill(geometry.pill)
            guard geometry.pill.rect.width > 20, geometry.pill.rect.height > 20 else {
                throw AtmosphericGeometryError.unsupportedDimensions(kind)
            }
            if let tab = geometry.selectedTab {
                try validateRect(tab.rect)
                try validateVisibility(tab.visibility)
            }
        case let .glassPill(role, geometry):
            try validatePill(geometry)
            let maximumHeight: CGFloat = role == .messageInput ? 520 : 88
            let maximumWidth: CGFloat = role == .blurredDrawable ? 650 : 1200
            try validateDimensions(geometry.rect, minimumHeight: 22, maximumHeight: maximumHeight,
                                   maximumWidth: maximumWidth, kind: kind)
        case let .profileAvatar(geometry):
            try validateRect(geometry.rect)
            try validateVisibility(geometry.visibility)
            try validateClip(geometry.clipRect)
            try validateUnitInterval(geometry.expansionProgress, field: "expansionProgress")
            try validateUnitInterval(geometry.insetProgress, field: "insetProgress")
            try validateUnitInterval(geometry.foregroundAlpha, field: "foregroundAlpha")
            guard geometry.rect.width >= 38, geometry.rect.height >= 38,
                  abs(geometry.rect.width - geometry.rect.height) <= 12 else {
                throw AtmosphericGeometryError.unsupportedDimensions(kind)
            }
        case let .profileAction(geometry):
            try validatePill(geometry.pill)
            try validateProfilePill(geometry.pill, kind: kind)
            try validateDimensions(geometry.pill.rect, minimumHeight: 32, maximumHeight: 120,
                                   maximumWidth: 1200, kind: kind)
            try validateUnitInterval(geometry.expansionFraction, field: "expansionFraction")
            guard geometry.scale.isFinite, geometry.scale >= 0, geometry.scale <= 1 else {
                throw AtmosphericGeometryError.invalidProgress("scale")
            }
            if let size = geometry.expandedReferenceSize {
                guard size.width.isFinite, size.height.isFinite,
                      size.width >= 24, size.width <= 1200, size.height >= 32, size.height <= 120 else {
                    throw AtmosphericGeometryError.unsupportedDimensions(kind)
                }
            }
        case let .sectionCard(geometry):
            try validatePill(geometry.pill)
            try validateProfilePill(geometry.pill, kind: kind)
            try validateDimensions(geometry.pill.rect, minimumHeight: 28, maximumHeight: 1800,
                                   maximumWidth: 1200, kind: kind)
            guard geometry.pill.rect.width >= 120 else { throw AtmosphericGeometryError.unsupportedDimensions(kind) }
        }
    }
}

/// Surface identity for diagnostics and geometry errors.
public enum AtmosphericSurfaceKind: String, Codable, Sendable {
    case snow, navigationBar, glassPill, profileAvatar, profileAction, sectionCard
}

/// Wash and selected-tab fill belong below host content; rims and strips belong above it.
/// Use two effect views with identical geometry for before/after-draw ordering.
public enum AtmosphericRenderPlane: Equatable, Sendable {
    case background
    case foreground
    /// Explicit single-plane preview. Not a substitute for correct production content ordering.
    case combined
}

/// Reduced motion freezes particles, shimmer, and pulses at the current sample, without a link.
/// It preserves static festive decoration. `.system` follows UIKit's accessibility preference.
public enum AtmosphericMotionPolicy: Equatable, Sendable {
    case system
    case reduced
    case full
}

/// Invalid or unsupported geometry is not silently replaced with a generic rectangle.
public enum AtmosphericGeometryError: Error, Equatable, Sendable, LocalizedError {
    case invalidRectangle
    case invalidOpacity
    case invalidCornerRadius
    case invalidProgress(String)
    case unsupportedDimensions(AtmosphericSurfaceKind)
    case unsupportedRenderPlane(AtmosphericSurfaceKind)
    case unsupportedShape(AtmosphericSurfaceKind)
    case unsupportedFrostWash(AtmosphericSurfaceKind)

    public var errorDescription: String? {
        switch self {
        case .invalidRectangle: return "Atmospheric geometry requires finite, positive rectangles."
        case .invalidOpacity: return "Atmospheric surface opacity must be in 0...1."
        case .invalidCornerRadius: return "Atmospheric corner radius must be finite and nonnegative."
        case let .invalidProgress(field): return "Atmospheric \(field) must be in 0...1."
        case let .unsupportedDimensions(kind): return "Unsupported atmospheric \(kind.rawValue) dimensions."
        case let .unsupportedRenderPlane(kind): return "Unsupported atmospheric \(kind.rawValue) render plane."
        case let .unsupportedShape(kind): return "Atmospheric \(kind.rawValue) requires an explicit rounded-rectangle radius."
        case let .unsupportedFrostWash(kind): return "Atmospheric \(kind.rawValue) does not support an interior frost wash."
        }
    }
}

private func validateRect(_ rect: CGRect) throws {
    guard rect.origin.x.isFinite, rect.origin.y.isFinite,
          rect.width.isFinite, rect.height.isFinite,
          rect.maxX.isFinite, rect.maxY.isFinite,
          rect.width > 0, rect.height > 0 else { throw AtmosphericGeometryError.invalidRectangle }
}

private func validateClip(_ rect: CGRect?) throws {
    if let rect { try validateRect(rect) }
}

private func validateVisibility(_ visibility: AtmosphericSurfaceVisibility) throws {
    guard visibility.opacity.isFinite, (0...1).contains(visibility.opacity) else {
        throw AtmosphericGeometryError.invalidOpacity
    }
}

private func validateUnitInterval(_ value: CGFloat, field: String) throws {
    guard value.isFinite, (0...1).contains(value) else { throw AtmosphericGeometryError.invalidProgress(field) }
}

private func validatePill(_ geometry: AtmosphericPillGeometry) throws {
    try validateRect(geometry.rect)
    try validateClip(geometry.clipRect)
    try validateVisibility(geometry.visibility)
    if case let .roundedRectangle(radius) = geometry.shape, !radius.isFinite || radius < 0 {
        throw AtmosphericGeometryError.invalidCornerRadius
    }
}

private func validateProfilePill(_ geometry: AtmosphericPillGeometry, kind: AtmosphericSurfaceKind) throws {
    guard case .roundedRectangle = geometry.shape else { throw AtmosphericGeometryError.unsupportedShape(kind) }
    guard !geometry.drawsFrostWash else { throw AtmosphericGeometryError.unsupportedFrostWash(kind) }
}

private func validateDimensions(
    _ rect: CGRect, minimumHeight: CGFloat, maximumHeight: CGFloat,
    maximumWidth: CGFloat, kind: AtmosphericSurfaceKind
) throws {
    guard rect.width >= 24, rect.width <= maximumWidth,
          rect.height >= minimumHeight, rect.height <= maximumHeight else {
        throw AtmosphericGeometryError.unsupportedDimensions(kind)
    }
}
