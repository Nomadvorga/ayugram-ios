import UIKit

/// Native, touch-transparent atmospheric_snow surface. The host owns this view's frame,
/// geometry, page identity, visibility, placement relative to content, and persistence.
/// This view installs no app hooks and is not connected to AyuGram by creating it alone.
@MainActor
public final class AtmosphericEffectView: UIView {
    public private(set) var configuration: AtmosphericSnowConfiguration
    public private(set) var surface: AtmosphericSurface
    public let renderPlane: AtmosphericRenderPlane
    public private(set) var hostState: AtmosphericHostState = .init()
    public private(set) var motionPolicy: AtmosphericMotionPolicy
    /// Terminal lifecycle state; stale host messages cannot restart an invalidated view.
    public private(set) var isInvalidated = false
    /// Resource failure or terminal invalidation; invalid requests throw without replacing old state.
    public private(set) var renderingError: AtmosphericRenderingError?

    /// A stable default, not a promise of Python's random stream. Inject a seed for reproducibility.
    public nonisolated static let defaultSeed: UInt64 = 0x415955534E4F5731

    /// True only when this view is enrolled in the currently running shared native display link.
    /// This is a scheduling diagnostic, not an FPS measurement or visual-parity assertion.
    public var isAnimationScheduled: Bool {
        return isRegisteredWithClock && AtmosphericAnimationClock.shared.isRunning
    }

    /// Actual bounded snow population; zero for non-snow surfaces.
    public var particleCount: Int { return surface.kind == .snow ? particleSystem.particles.count : 0 }

    /// Host/config/window/scene/actual-target visibility, separate from application-active link gating.
    public var isEffectVisible: Bool { return isEligibleForPresentation }

    private var particleSystem: AtmosphericParticleSystem
    private var seed: UInt64
    private var atlas: AtmosphericSnowAtlas?
    private var decoration: AtmosphericDecoration?
    // One last festive body/tab variant, retained across disable/re-enable; never a geometry history.
    private var decorationCache: AtmosphericDecoration?
    private var preparedKey: ResourceKey?
    private var sampleTime: TimeInterval = 0
    private var isRegisteredWithClock = false
    private var isInitialized = false
    // Unlike a memory address, this identity cannot be reused before an async deinit cleanup runs.
    fileprivate let animationIdentifier = UUID()
    private var lifetime: AtmosphericAnimationLifetime?

    // Internal source-only test diagnostic; the public adapter does not depend on cache identities.
    var cachedDecorationBodyIdentity: ObjectIdentifier? { return decorationCache?.staticBodyIdentity }

    /// Starts with zero frame and hidden host state. Set bounds/frame from the host, then
    /// call `update(hostState:)`. Combined is a standalone preview default; production navbar
    /// hosts use separate background/foreground views. Snow has no background-only plane.
    public init(
        configuration: AtmosphericSnowConfiguration = .init(),
        surface: AtmosphericSurface = .snow,
        renderPlane: AtmosphericRenderPlane = .combined,
        seed: UInt64 = AtmosphericEffectView.defaultSeed,
        motionPolicy: AtmosphericMotionPolicy = .system
    ) throws {
        try Self.validate(surface: surface, renderPlane: renderPlane)
        self.configuration = configuration
        self.surface = surface
        self.renderPlane = renderPlane
        self.motionPolicy = motionPolicy
        self.seed = seed
        self.particleSystem = AtmosphericParticleSystem(seed: seed)
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        contentMode = .redraw
        lifetime = AtmosphericAnimationLifetime(identifier: animationIdentifier)
        isInitialized = true
        AtmosphericAnimationClock.shared.observe(self)
        try prepareForRendering()
    }

    @available(*, unavailable, message: "Create AtmosphericEffectView with typed configuration and surface geometry.")
    public required init?(coder: NSCoder) { fatalError("Typed initializer required") }

    /// Atomically changes typed settings and prepares resources. No dictionary is read on a frame.
    public func update(configuration next: AtmosphericSnowConfiguration) throws {
        guard !isInvalidated else { throw AtmosphericRenderingError.invalidatedView }
        let resources = try makeResources(configuration: next, surface: surface)
        configuration = next
        commit(resources)
        prepareParticles()
        setNeedsDisplay()
        refreshVisibility()
    }

    /// Validates and prepares a new surface before changing state. Unsupported geometry throws.
    /// Update rectangles when host layout/scroll/action geometry changes; this view never guesses it.
    public func update(surface next: AtmosphericSurface) throws {
        guard !isInvalidated else { throw AtmosphericRenderingError.invalidatedView }
        try Self.validate(surface: next, renderPlane: renderPlane)
        let resources = try makeResources(configuration: configuration, surface: next)
        let changedKind = next.kind != surface.kind
        surface = next
        if changedKind { particleSystem.reset(seed: seed) }
        commit(resources)
        prepareParticles()
        setNeedsDisplay()
        refreshVisibility()
    }

    /// Required for page changes, reuse, disappearance, and explicit host visibility changes.
    public func update(hostState: AtmosphericHostState) {
        guard !isInvalidated else { return }
        self.hostState = hostState
        setNeedsDisplay()
        refreshVisibility()
    }

    /// Reduced motion freezes at the current sample; full motion resumes without physics catch-up.
    public func update(motionPolicy: AtmosphericMotionPolicy) {
        guard !isInvalidated else { return }
        self.motionPolicy = motionPolicy
        setNeedsDisplay()
        refreshVisibility()
    }

    /// Re-seeds native particles and sets the frozen sample to zero. Active animation re-synchronizes
    /// with the shared phase on the next tick. Does not reset settings or other surfaces.
    public func reset(seed: UInt64) {
        guard !isInvalidated else { return }
        self.seed = seed
        particleSystem.reset(seed: seed)
        sampleTime = 0
        prepareParticles()
        setNeedsDisplay()
    }

    /// Permanently revokes this renderer: removes clock/event registration, releases its caches,
    /// and ignores stale host/motion/seed messages. Typed configuration/surface/prepare calls throw.
    /// The parent must still revoke its own generation-bound host callbacks and remove the view.
    /// Preferences are never changed. Create a new view for a new plugin generation.
    public func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        endAnimationRegistration()
        AtmosphericAnimationClock.shared.forget(identifier: animationIdentifier)
        atlas = nil
        decoration = nil
        decorationCache = nil
        preparedKey = nil
        particleSystem.reset(seed: seed, keepingCapacity: false)
        sampleTime = 0
        renderingError = .invalidatedView
        setNeedsDisplay()
    }

    /// Explicit preparation/retry after assigning bounds or changing traits. UIKit callbacks also
    /// prepare as needed; failures there are exposed via `renderingError` and stop animation.
    /// Calling this repeatedly with unchanged config/shape/traits reuses cached native resources.
    public func prepareForRendering() throws {
        guard !isInvalidated else { throw AtmosphericRenderingError.invalidatedView }
        do {
            let resources = try makeResources(configuration: configuration, surface: surface)
            commit(resources)
            prepareParticles()
        } catch {
            renderingError = (error as? AtmosphericRenderingError) ?? .graphicsAllocationFailed
            atlas = nil
            decoration = nil
            decorationCache = nil
            preparedKey = nil
            endAnimationRegistration()
            setNeedsDisplay()
            throw error
        }
        setNeedsDisplay()
        refreshVisibility()
    }

    /// Call after an ancestor's hidden/alpha/clipping/transform changes, including re-showing it.
    /// Running frames detect ancestor invisibility and stop; no polling link is kept to detect re-show.
    public func refreshVisibility() {
        guard isInitialized, !isInvalidated else { return }
        // Re-showing a static garland must also redraw, even though it requires no display link.
        setNeedsDisplay()
        if isEligibleForAnimationIgnoringApplication {
            if !isRegisteredWithClock {
                isRegisteredWithClock = true
                AtmosphericAnimationClock.shared.add(self)
            }
        } else {
            endAnimationRegistration()
        }
    }

    public override var isHidden: Bool {
        didSet {
            if isInitialized { setNeedsDisplay(); refreshVisibility() }
        }
    }

    public override var alpha: CGFloat {
        didSet {
            if isInitialized { setNeedsDisplay(); refreshVisibility() }
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        prepareFromUIKitCallback()
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if isInitialized { refreshVisibility() }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        prepareFromUIKitCallback()
        // Deliberately no assignment to self.frame, bounds, center, or transform.
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        prepareFromUIKitCallback()
    }

    /// Remains touch-transparent even if host code mistakenly re-enables user interaction.
    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { return false }
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { return nil }

    public override func draw(_ rect: CGRect) {
        guard isEligibleForPresentation, let context = UIGraphicsGetCurrentContext() else { return }
        if surface.kind == .snow {
            guard let atlas else { return }
            context.saveGState()
            context.clip(to: bounds)
            // One flip for the entire particle pass, rather than a bitmap/context per particle.
            context.translateBy(x: bounds.minX, y: bounds.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .low
            let scale = displayScale
            for flake in particleSystem.particles {
                guard let presentation = particleSystem.presentation(of: flake, elapsed: sampleTime,
                                                                     configuration: configuration) else { continue }
                let diameter = presentation.snappedDiameter(displayScale: scale)
                let half = diameter * 0.5
                let destination = CGRect(x: presentation.center.x - half,
                                         y: bounds.height - presentation.center.y - half,
                                         width: diameter, height: diameter)
                context.setAlpha(CGFloat(presentation.bucketAlpha) / 255)
                context.draw(atlas.image(for: presentation.sprite), in: destination)
            }
            context.restoreGState()
        } else {
            decoration?.draw(in: context, elapsed: sampleTime)
        }
    }

    // Called only by the main-run-loop clock. No resource construction, persistence, or Task here.
    func animationFrame(deltaTime: TimeInterval, elapsed: TimeInterval) -> Bool {
        guard isEligibleForAnimationIgnoringApplication,
              UIApplication.shared.applicationState == .active else {
            isRegisteredWithClock = false
            return false
        }
        sampleTime = elapsed
        if surface.kind == .snow {
            particleSystem.advance(deltaTime: deltaTime, elapsed: elapsed, configuration: configuration)
        }
        setNeedsDisplay()
        return true
    }

    private static func validate(surface: AtmosphericSurface, renderPlane: AtmosphericRenderPlane) throws {
        try surface.validate()
        if renderPlane == .background {
            switch surface {
            case .navigationBar: break
            case let .glassPill(_, geometry) where geometry.drawsFrostWash: break
            default: throw AtmosphericGeometryError.unsupportedRenderPlane(surface.kind)
            }
        }
    }

    private var displayScale: CGFloat {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return scale.isFinite && scale > 0 ? scale : 1
    }

    private var isDark: Bool { return traitCollection.userInterfaceStyle != .light }

    private func isEnabled(configuration: AtmosphericSnowConfiguration, surface: AtmosphericSurface) -> Bool {
        switch surface {
        case .snow: return configuration.snowEnabled
        case .navigationBar: return configuration.navbarFestiveEnabled
        case .glassPill: return configuration.glassPillsEnabled
        case .profileAvatar, .profileAction, .sectionCard: return configuration.profileFestiveEnabled
        }
    }

    private var isEligibleForPresentation: Bool {
        guard isInitialized, !isInvalidated, renderingError == nil, hostState.isVisible, window != nil,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              isEnabled(configuration: configuration, surface: surface) else { return false }
        if let scene = window?.windowScene, scene.activationState != .foregroundActive { return false }
        let presentationRect: CGRect
        if surface.kind == .snow {
            guard configuration.snowArea.includes(hostState.pageKind), atlas != nil,
                  bounds.width > 10, bounds.height > 10 else { return false }
            presentationRect = bounds
        } else {
            guard let decoration, decoration.isVisible else { return false }
            presentationRect = decoration.presentationBounds.intersection(bounds)
            guard !presentationRect.isNull, presentationRect.width > 0, presentationRect.height > 0 else { return false }
        }
        return hasVisibleAncestors(presentationRect: presentationRect)
    }

    private var isEligibleForAnimationIgnoringApplication: Bool {
        guard isEligibleForPresentation, !usesReducedMotion else { return false }
        return surface.kind == .snow || decoration?.needsAnimation == true
    }

    private var usesReducedMotion: Bool {
        switch motionPolicy {
        case .system: return UIAccessibility.isReduceMotionEnabled
        case .reduced: return true
        case .full: return false
        }
    }

    private func hasVisibleAncestors(presentationRect: CGRect) -> Bool {
        var ancestor: UIView? = self
        var visibleRect = presentationRect
        var opacity: CGFloat = 1
        var depth = 0
        while let view = ancestor {
            depth += 1
            // Pathological hierarchies fail closed instead of creating an unbounded walk.
            guard depth <= 128, !view.isHidden, view.alpha.isFinite else { return false }
            opacity *= view.alpha
            guard opacity > 0.05 else { return false }
            guard !visibleRect.isNull, visibleRect.minX.isFinite, visibleRect.minY.isFinite,
                  visibleRect.maxX.isFinite, visibleRect.maxY.isFinite,
                  visibleRect.width > 0.15, visibleRect.height > 0.15 else { return false }
            if view.clipsToBounds || view is UIWindow {
                guard view.bounds.minX.isFinite, view.bounds.minY.isFinite,
                      view.bounds.maxX.isFinite, view.bounds.maxY.isFinite else { return false }
                visibleRect = visibleRect.intersection(view.bounds)
                guard !visibleRect.isNull, visibleRect.width > 0.15, visibleRect.height > 0.15 else { return false }
            }
            // Carry the surviving clip forward. Testing the original rectangle against every
            // ancestor independently could report visibility when their clips have no overlap.
            let parent = view.superview
            if let parent { visibleRect = view.convert(visibleRect, to: parent) }
            ancestor = parent
        }
        return true
    }

    private func prepareParticles() {
        guard surface.kind == .snow, configuration.snowEnabled else { return }
        particleSystem.prepare(size: bounds.size, displayScale: displayScale, configuration: configuration)
    }

    private func prepareFromUIKitCallback() {
        guard isInitialized, !isInvalidated else { return }
        do { try prepareForRendering() } catch { /* Exposed via renderingError; no pretending success. */ }
    }

    private func endAnimationRegistration() {
        guard isRegisteredWithClock else { return }
        isRegisteredWithClock = false
        AtmosphericAnimationClock.shared.remove(identifier: animationIdentifier)
    }

    private struct ResourceKey: Equatable {
        let configuration: AtmosphericSnowConfiguration
        let surface: AtmosphericSurface
        let renderPlane: AtmosphericRenderPlane
        let isDark: Bool
        let displayScale: CGFloat
    }

    private struct Resources {
        let key: ResourceKey
        let atlas: AtmosphericSnowAtlas?
        let decoration: AtmosphericDecoration?
    }

    private func makeResources(configuration: AtmosphericSnowConfiguration, surface: AtmosphericSurface) throws -> Resources {
        let key = ResourceKey(configuration: configuration, surface: surface, renderPlane: renderPlane,
                              isDark: isDark, displayScale: displayScale)
        if key == preparedKey { return Resources(key: key, atlas: atlas, decoration: decoration) }
        if !isEnabled(configuration: configuration, surface: surface) {
            return Resources(key: key, atlas: nil, decoration: nil)
        }
        if surface.kind == .snow {
            let atlas = try AtmosphericSpriteStore.shared.snowAtlas(rgb: configuration.snowColor.rgb(isDark: isDark))
            return Resources(key: key, atlas: atlas, decoration: nil)
        }
        let decoration = try AtmosphericDecoration.prepare(surface: surface, configuration: configuration,
                                                            renderPlane: renderPlane, isDark: isDark,
                                                            displayScale: displayScale, reusing: decorationCache)
        return Resources(key: key, atlas: nil, decoration: decoration)
    }

    private func commit(_ resources: Resources) {
        preparedKey = resources.key
        atlas = resources.atlas
        decoration = resources.decoration
        if let decoration = resources.decoration { decorationCache = decoration }
        renderingError = nil
    }
}

// One shared link instead of one link per decorated control. All UI state stays @MainActor.
// Link -> proxy -> WEAK clock, and clock -> WEAK views: neither path retains a view in a cycle.
@MainActor
private final class AtmosphericAnimationClock: NSObject {
    static let shared = AtmosphericAnimationClock()
    // Dormant weak views receive accessibility/scene activation events without a polling link.
    private var observedViews: [UUID: AtmosphericWeakEffectView] = [:]
    private var clients: [UUID: AtmosphericWeakEffectView] = [:]
    private var removed: [UUID] = []
    private var link: CADisplayLink?
    private var target: AtmosphericDisplayLinkTarget?
    private var lastTimestamp: TimeInterval?
    private var elapsed: TimeInterval = 0
    private var applicationIsActive: Bool

    var isRunning: Bool {
        return link != nil && applicationIsActive && UIApplication.shared.applicationState == .active
    }

    private override init() {
        applicationIsActive = UIApplication.shared.applicationState == .active
        super.init()
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(applicationBecameActive(_:)),
                                  name: UIApplication.didBecomeActiveNotification, object: nil)
        notifications.addObserver(self, selector: #selector(applicationResignedActive(_:)),
                                  name: UIApplication.willResignActiveNotification, object: nil)
        notifications.addObserver(self, selector: #selector(applicationResignedActive(_:)),
                                  name: UIApplication.didEnterBackgroundNotification, object: nil)
        notifications.addObserver(self, selector: #selector(accessibilityPreferenceChanged(_:)),
                                  name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        notifications.addObserver(self, selector: #selector(sceneVisibilityChanged(_:)),
                                  name: UIScene.didActivateNotification, object: nil)
        notifications.addObserver(self, selector: #selector(sceneVisibilityChanged(_:)),
                                  name: UIScene.willDeactivateNotification, object: nil)
        notifications.addObserver(self, selector: #selector(sceneVisibilityChanged(_:)),
                                  name: UIScene.didEnterBackgroundNotification, object: nil)
    }

    func observe(_ view: AtmosphericEffectView) {
        observedViews[view.animationIdentifier] = AtmosphericWeakEffectView(view)
    }

    func add(_ view: AtmosphericEffectView) {
        let identifier = view.animationIdentifier
        let client = observedViews[identifier] ?? AtmosphericWeakEffectView(view)
        observedViews[identifier] = client
        clients[identifier] = client
        startIfNeeded()
    }

    func remove(identifier: UUID) {
        clients.removeValue(forKey: identifier)
        if clients.isEmpty { stop() }
    }

    func forget(identifier: UUID) {
        observedViews.removeValue(forKey: identifier)
        remove(identifier: identifier)
        if observedViews.isEmpty { AtmosphericSpriteStore.shared.removeAll() }
    }

    private func startIfNeeded() {
        guard applicationIsActive, UIApplication.shared.applicationState == .active,
              !clients.isEmpty, link == nil else { return }
        let target = AtmosphericDisplayLinkTarget(clock: self)
        let link = CADisplayLink(target: target, selector: #selector(AtmosphericDisplayLinkTarget.tick(_:)))
        // Requested scheduling cadence, NOT measured FPS. Source Android invalidation rates differ.
        link.preferredFramesPerSecond = 30
        lastTimestamp = nil
        self.target = target
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    private func stop() {
        link?.invalidate()
        link = nil
        target = nil
        lastTimestamp = nil
    }

    func tick(_ link: CADisplayLink) {
        guard applicationIsActive, UIApplication.shared.applicationState == .active else { stop(); return }
        let delta = lastTimestamp.map { link.timestamp - $0 } ?? 0
        lastTimestamp = link.timestamp
        let dt = AtmosphericParticleSystem.clampedDeltaTime(delta)
        elapsed += dt
        removed.removeAll(keepingCapacity: true)
        // No compactMap/filter/array creation on the frame path; mutate after iteration.
        for (identifier, client) in clients {
            guard let view = client.view else { removed.append(identifier); continue }
            if !view.animationFrame(deltaTime: dt, elapsed: elapsed) { removed.append(identifier) }
        }
        for identifier in removed { clients.removeValue(forKey: identifier) }
        removed.removeAll(keepingCapacity: true)
        if clients.isEmpty { stop() }
    }

    @objc private func applicationBecameActive(_ notification: Notification) {
        applicationIsActive = true
        refreshClients()
        startIfNeeded()
    }

    @objc private func applicationResignedActive(_ notification: Notification) {
        applicationIsActive = false
        stop()
    }

    @objc private func accessibilityPreferenceChanged(_ notification: Notification) { refreshClients() }
    @objc private func sceneVisibilityChanged(_ notification: Notification) {
        refreshClients()
        startIfNeeded()
    }

    private func refreshClients() {
        removed.removeAll(keepingCapacity: true)
        // Event-time snapshot permits registration changes during refresh; not used on frames.
        let snapshot = Array(observedViews.values)
        for client in snapshot { client.view?.refreshVisibility() }
        for (identifier, client) in observedViews where client.view == nil { removed.append(identifier) }
        for identifier in removed {
            observedViews.removeValue(forKey: identifier)
            clients.removeValue(forKey: identifier)
        }
        removed.removeAll(keepingCapacity: true)
        if clients.isEmpty { stop() }
    }
}

@MainActor
private final class AtmosphericWeakEffectView {
    weak var view: AtmosphericEffectView?
    init(_ view: AtmosphericEffectView) { self.view = view }
}

@MainActor
private final class AtmosphericDisplayLinkTarget: NSObject {
    weak var clock: AtmosphericAnimationClock?
    init(clock: AtmosphericAnimationClock) { self.clock = clock }
    @objc func tick(_ link: CADisplayLink) { clock?.tick(link) }
}

// A non-UI lifetime token avoids calling actor-isolated UIKit methods from nonisolated deinit.
// It captures only a Sendable identity, not the dying view. Dead weak slots also vanish on tick.
private final class AtmosphericAnimationLifetime {
    let identifier: UUID
    init(identifier: UUID) { self.identifier = identifier }
    deinit {
        let identifier = self.identifier
        Task { @MainActor in AtmosphericAnimationClock.shared.forget(identifier: identifier) }
    }
}
