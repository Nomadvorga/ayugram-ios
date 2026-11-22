import UIKit

/// Explicit application surfaces; no Android reflection or view-class-name discovery.
public enum AtmosphericHostRole: Equatable, Sendable {
    case snowfall, navbar, glassPill, profileAvatar, profileAction, sectionCard
}

public enum AtmosphericHostPage: Equatable, Sendable {
    case chat, chatList, other
}

/// Coordinates are local to the attachment's container. Its parent owns the overlay frame.
public struct AtmosphericHostGeometry {
    public var rect: CGRect
    public var cornerRadius: CGFloat
    public var selectedTabRect: CGRect?
    public var page: AtmosphericHostPage
    public var visible: Bool
    public var alpha: CGFloat
    public var allowsTallGlass: Bool
    public var drawTopEdge: Bool
    public var drawBottomEdge: Bool
    public var avatarExpansion: CGFloat
    public var avatarHasStories: Bool
    public var avatarInsetsProgress: CGFloat
    public var avatarForegroundAlpha: CGFloat
    public var profileExpansionFraction: CGFloat
    public var backgroundInsertionIndex: Int
    /// Telegram presentation theme may differ from UIKit's system appearance.
    public var isDarkTheme: Bool?
    public var glassDrawsFrostWash = false
    public var profileActionScale: CGFloat = 1
    public var expandedActionReferenceSize: CGSize?

    public init(rect: CGRect, cornerRadius: CGFloat = 0, selectedTabRect: CGRect? = nil, page: AtmosphericHostPage = .other, visible: Bool = true, alpha: CGFloat = 1, allowsTallGlass: Bool = false, drawTopEdge: Bool = true, drawBottomEdge: Bool = true, avatarExpansion: CGFloat = 0, avatarHasStories: Bool = false, avatarInsetsProgress: CGFloat = 1, avatarForegroundAlpha: CGFloat = 0, profileExpansionFraction: CGFloat = 1, backgroundInsertionIndex: Int = 0, isDarkTheme: Bool? = nil) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.selectedTabRect = selectedTabRect
        self.page = page
        self.visible = visible
        self.alpha = alpha
        self.allowsTallGlass = allowsTallGlass
        self.drawTopEdge = drawTopEdge
        self.drawBottomEdge = drawBottomEdge
        self.avatarExpansion = avatarExpansion
        self.avatarHasStories = avatarHasStories
        self.avatarInsetsProgress = avatarInsetsProgress
        self.avatarForegroundAlpha = avatarForegroundAlpha
        self.profileExpansionFraction = profileExpansionFraction
        self.backgroundInsertionIndex = backgroundInsertionIndex
        self.isDarkTheme = isDarkTheme
    }
}

/// Implemented by a trusted native adapter. Never calls the interpreter during drawing.
@MainActor public protocol AtmosphericHostRendering: AnyObject {
    var view: UIView { get }
    /// Optional pre-content navbar wash/selection fill. The primary view is post-content.
    var backgroundView: UIView? { get }
    func update(role: AtmosphericHostRole, geometry: AtmosphericHostGeometry, dark: Bool)
    func stop()
}

public extension AtmosphericHostRendering {
    var backgroundView: UIView? { nil }
}

/// Process-local registry. Disabled at startup; a user-driven plugin enable supplies the factory.
@MainActor public final class AtmosphericHost {
    public static let shared = AtmosphericHost()
    public typealias Factory = @MainActor (AtmosphericHostRole) -> any AtmosphericHostRendering
    private final class Registration {
        weak var attachment: AtmosphericSurfaceAttachment?
        init(_ attachment: AtmosphericSurfaceAttachment) { self.attachment = attachment }
    }
    private var registrations: [Registration] = []
    private var factory: Factory?
    public private(set) var generation: UUID?
    public private(set) var presentationThemeIsDark: Bool?
    public var isEnabled: Bool { self.factory != nil }

    private init() {}

    /// Explicit application theme context, also for glass components without a theme argument.
    /// This is not a luminance/class/window guess and does not allocate effects while disabled.
    public func updateTheme(isDark: Bool) {
        guard self.presentationThemeIsDark != isDark else { return }
        self.presentationThemeIsDark = isDark
        self.refresh()
    }

    /// Replacing a generation revokes every old renderer before installing the new one.
    public func enable(factory: @escaping Factory) {
        self.disable()
        self.generation = UUID()
        self.factory = factory
        self.refresh()
    }

    /// A synchronous main-actor cleanup barrier: all overlays and their animation clocks stop.
    public func disable() {
        self.factory = nil
        self.generation = nil
        for registration in self.registrations { registration.attachment?.removeRendering() }
        self.registrations.removeAll { $0.attachment == nil }
    }

    /// Called only for settings/theme/layout events, never on an interpreter frame callback.
    public func refresh() {
        self.registrations.removeAll { $0.attachment == nil }
        for registration in self.registrations { registration.attachment?.refresh() }
    }

    fileprivate func register(_ attachment: AtmosphericSurfaceAttachment) {
        self.registrations.removeAll { $0.attachment == nil }
        self.registrations.append(Registration(attachment))
    }

    fileprivate func unregister(_ attachment: AtmosphericSurfaceAttachment) {
        self.registrations.removeAll { $0.attachment == nil || $0.attachment === attachment }
    }

    fileprivate func makeRendering(role: AtmosphericHostRole) -> (any AtmosphericHostRendering)? { self.factory?(role) }
}

/// A typed host-owned attachment. No renderer exists while the plugin is disabled.
@MainActor public final class AtmosphericSurfaceAttachment {
    private weak var container: UIView?
    private let role: AtmosphericHostRole
    private var geometry = AtmosphericHostGeometry(rect: .zero, visible: false)
    private var rendering: (any AtmosphericHostRendering)?
    private var mountedGeneration: UUID?
    private var detached = false

    public init(container: UIView, role: AtmosphericHostRole) {
        self.container = container
        self.role = role
        AtmosphericHost.shared.register(self)
    }

    isolated deinit {
        self.rendering?.stop()
        self.rendering?.view.removeFromSuperview()
        self.rendering?.backgroundView?.removeFromSuperview()
    }

    public func update(geometry: AtmosphericHostGeometry) {
        self.geometry = geometry
        self.refresh()
    }

    public func detach() {
        self.detached = true
        self.removeRendering()
        AtmosphericHost.shared.unregister(self)
        self.container = nil
    }

    fileprivate func removeRendering() {
        self.rendering?.stop()
        self.rendering?.view.removeFromSuperview()
        self.rendering?.backgroundView?.removeFromSuperview()
        self.rendering = nil
        self.mountedGeneration = nil
    }

    fileprivate func refresh() {
        guard !self.detached, let container = self.container, AtmosphericHost.shared.isEnabled else {
            self.removeRendering()
            return
        }
        let rect = self.geometry.rect
        let valid = !rect.isNull && !rect.isInfinite && rect.width.isFinite && rect.height.isFinite
            && rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width > 0 && rect.height > 0
            && self.geometry.cornerRadius.isFinite && self.geometry.cornerRadius >= 0
            && self.geometry.alpha.isFinite && self.geometry.avatarExpansion.isFinite
            && self.geometry.avatarInsetsProgress.isFinite && self.geometry.avatarForegroundAlpha.isFinite
            && self.geometry.profileExpansionFraction.isFinite
            && self.geometry.profileActionScale.isFinite
        guard valid else { self.removeRendering(); return }
        var visible = self.geometry.visible && container.window != nil
        var ancestor: UIView? = container
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 { visible = false; break }
            ancestor = view.superview
        }
        if let window = container.window,
           !container.convert(rect, to: window).intersects(window.bounds) { visible = false }
        // Off-screen surfaces are not instantiated. Existing ones receive visible=false to stop.
        if self.mountedGeneration != AtmosphericHost.shared.generation { self.removeRendering() }
        if self.rendering == nil && visible {
            self.rendering = AtmosphericHost.shared.makeRendering(role: self.role)
            self.mountedGeneration = AtmosphericHost.shared.generation
        }
        guard let rendering = self.rendering else { return }
        if rendering.view.superview !== container { container.addSubview(rendering.view) }
        // Source decorations extend beyond the target pill (notably bottom icicles).
        // Keep a bounded drawing canvas around non-snow targets rather than clipping them
        // at the pill edge. Existing container/ancestor clipping remains authoritative.
        let margin: CGFloat = self.role == .snowfall ? 0 : 12
        let canvas = rect.insetBy(dx: -margin, dy: -margin)
        // We are the parent, not the effect view itself: this is the sole frame owner.
        rendering.view.frame = canvas
        if let background = rendering.backgroundView {
            let maximumIndex = background.superview === container ? max(0, container.subviews.count - 1) : container.subviews.count
            container.insertSubview(background, at: min(max(0, self.geometry.backgroundInsertionIndex), maximumIndex))
            background.frame = canvas
            background.isHidden = !visible
        }
        var local = self.geometry
        local.rect = CGRect(x: margin, y: margin, width: rect.width, height: rect.height)
        local.visible = visible
        if let selected = local.selectedTabRect { local.selectedTabRect = selected.offsetBy(dx: -canvas.minX, dy: -canvas.minY) }
        rendering.view.isHidden = !visible
        rendering.update(role: self.role, geometry: local,
                         dark: local.isDarkTheme ?? AtmosphericHost.shared.presentationThemeIsDark
                             ?? (container.traitCollection.userInterfaceStyle == .dark))
        container.bringSubviewToFront(rendering.view)
    }
}
