import UIKit
import XCTest
@testable import AyuAtmosphericSnow

// These are source-only native tests. They need a future UIKit test target and have NOT been run.
final class AtmosphericEffectViewTests: XCTestCase {
    @MainActor
    func testStandaloneDefaultsToCombinedAndHiddenHost() async throws {
        let view = try AtmosphericEffectView(configuration: .init(snowEnabled: false))
        defer { view.invalidate() }
        XCTAssertEqual(view.renderPlane, .combined)
        XCTAssertEqual(view.hostState, AtmosphericHostState())
        XCTAssertEqual(view.motionPolicy, .system)
        XCTAssertFalse(view.isInvalidated)
        XCTAssertFalse(view.isAnimationScheduled)
    }

    @MainActor
    func testTouchTransparencyAndHostFrameOwnership() async throws {
        let view = try AtmosphericEffectView(configuration: .init(snowEnabled: false), motionPolicy: .reduced)
        let hostFrame = CGRect(x: 17, y: 23, width: 320, height: 640)
        view.frame = hostFrame // Host/test owns frame, never the effect's layout code.
        view.layoutIfNeeded()
        try view.prepareForRendering()
        XCTAssertEqual(view.frame, hostFrame)
        view.isUserInteractionEnabled = true
        XCTAssertFalse(view.point(inside: CGPoint(x: 20, y: 20), with: nil))
        XCTAssertNil(view.hitTest(CGPoint(x: 20, y: 20), with: nil))
        XCTAssertFalse(view.isEffectVisible)
        XCTAssertFalse(view.isAnimationScheduled)
    }

    @MainActor
    func testInvalidUpdateIsAtomicAndBackgroundSnowFails() async throws {
        let view = try AtmosphericEffectView(configuration: .init(snowEnabled: false))
        let invalid = AtmosphericSurface.glassPill(role: .button,
                                                   geometry: .init(rect: CGRect(x: 0, y: 0, width: 10, height: 44)))
        XCTAssertThrowsError(try view.update(surface: invalid)) {
            XCTAssertEqual($0 as? AtmosphericGeometryError, .unsupportedDimensions(.glassPill))
        }
        XCTAssertEqual(view.surface, .snow)
        XCTAssertThrowsError(try AtmosphericEffectView(configuration: .init(snowEnabled: false),
                                                       surface: .snow, renderPlane: .background)) {
            XCTAssertEqual($0 as? AtmosphericGeometryError, .unsupportedRenderPlane(.snow))
        }
    }

    func testGeometryRejectionsAreExplicit() throws {
        let rect = CGRect(x: 0, y: 0, width: 160, height: 60)
        let automaticAction = AtmosphericSurface.profileAction(.init(pill: .init(rect: rect)))
        XCTAssertThrowsError(try automaticAction.validate()) {
            XCTAssertEqual($0 as? AtmosphericGeometryError, .unsupportedShape(.profileAction))
        }
        let washedAction = AtmosphericSurface.profileAction(.init(pill: .init(
            rect: rect, shape: .roundedRectangle(cornerRadius: 16), drawsFrostWash: true
        )))
        XCTAssertThrowsError(try washedAction.validate()) {
            XCTAssertEqual($0 as? AtmosphericGeometryError, .unsupportedFrostWash(.profileAction))
        }
        let transparent = AtmosphericSurface.glassPill(role: .button, geometry: .init(
            rect: rect, visibility: .init(opacity: .nan)
        ))
        XCTAssertThrowsError(try transparent.validate()) {
            XCTAssertEqual($0 as? AtmosphericGeometryError, .invalidOpacity)
        }
        let expandedAvatar = AtmosphericSurface.profileAvatar(.init(rect: CGRect(x: 0, y: 0, width: 160, height: 100)))
        XCTAssertThrowsError(try expandedAvatar.validate()) {
            XCTAssertEqual($0 as? AtmosphericGeometryError, .unsupportedDimensions(.profileAvatar))
        }
    }

    func testTallInputAndProfileDimensionsUseSourceSpecificCaps() throws {
        let tall = AtmosphericPillGeometry(rect: CGRect(x: 0, y: 0, width: 320, height: 520))
        XCTAssertNoThrow(try AtmosphericSurface.glassPill(role: .messageInput, geometry: tall).validate())
        XCTAssertThrowsError(try AtmosphericSurface.glassPill(role: .button, geometry: tall).validate()) {
            XCTAssertEqual($0 as? AtmosphericGeometryError, .unsupportedDimensions(.glassPill))
        }
        var tooTall = tall
        tooTall.rect.size.height = 521
        XCTAssertThrowsError(try AtmosphericSurface.glassPill(role: .messageInput, geometry: tooTall).validate())
        let largeCard = AtmosphericPillGeometry(rect: CGRect(x: 0, y: 0, width: 320, height: 1800),
                                                shape: .roundedRectangle(cornerRadius: 16))
        XCTAssertNoThrow(try AtmosphericSurface.sectionCard(.init(pill: largeCard)).validate())
        var smallCard = largeCard
        smallCard.rect.size = CGSize(width: 119, height: 28)
        XCTAssertThrowsError(try AtmosphericSurface.sectionCard(.init(pill: smallCard)).validate()) {
            XCTAssertEqual($0 as? AtmosphericGeometryError, .unsupportedDimensions(.sectionCard))
        }
        let wideDrawable = AtmosphericPillGeometry(rect: CGRect(x: 0, y: 0, width: 651, height: 44))
        XCTAssertThrowsError(try AtmosphericSurface.glassPill(role: .blurredDrawable, geometry: wideDrawable).validate())
        XCTAssertNoThrow(try AtmosphericSurface.glassPill(role: .header, geometry: wideDrawable).validate())
    }

    @MainActor
    func testViewPreparationReusesBodyAcrossPresentationAndDisableChanges() async throws {
        var pill = AtmosphericPillGeometry(rect: CGRect(x: 8, y: 8, width: 240, height: 44), clampsTopEdge: false)
        let view = try AtmosphericEffectView(surface: .glassPill(role: .button, geometry: pill), motionPolicy: .reduced)
        defer { view.invalidate() }
        let original = try XCTUnwrap(view.cachedDecorationBodyIdentity)
        pill.rect = pill.rect.offsetBy(dx: 20, dy: 40)
        pill.visibility.opacity = 0.4
        pill.clipRect = CGRect(x: 0, y: 0, width: 320, height: 160)
        try view.update(surface: .glassPill(role: .button, geometry: pill))
        XCTAssertEqual(view.cachedDecorationBodyIdentity, original)
        var configuration = view.configuration
        configuration.snowSpeed = .fast
        try view.update(configuration: configuration)
        XCTAssertEqual(view.cachedDecorationBodyIdentity, original)
        configuration.glassPillsEnabled = false
        try view.update(configuration: configuration)
        XCTAssertEqual(view.cachedDecorationBodyIdentity, original)
        configuration.glassPillsEnabled = true
        try view.update(configuration: configuration)
        XCTAssertEqual(view.cachedDecorationBodyIdentity, original)
    }

    @MainActor
    func testInvalidationIsTerminalAndClearsPrivateCaches() async throws {
        let surface = AtmosphericSurface.glassPill(role: .button,
                                                   geometry: .init(rect: CGRect(x: 8, y: 8, width: 240, height: 44)))
        let view = try AtmosphericEffectView(surface: surface, motionPolicy: .reduced)
        XCTAssertNotNil(view.cachedDecorationBodyIdentity)
        let originalHost = view.hostState
        view.invalidate()
        view.invalidate() // Idempotent teardown.
        XCTAssertTrue(view.isInvalidated)
        XCTAssertEqual(view.renderingError, .invalidatedView)
        XCTAssertNil(view.cachedDecorationBodyIdentity)
        XCTAssertFalse(view.isEffectVisible)
        XCTAssertFalse(view.isAnimationScheduled)
        XCTAssertEqual(view.particleCount, 0)
        view.update(hostState: .init(pageKind: .chat, isVisible: true))
        view.update(motionPolicy: .full)
        view.reset(seed: 42)
        view.refreshVisibility()
        XCTAssertEqual(view.hostState, originalHost)
        XCTAssertEqual(view.motionPolicy, .reduced)
        XCTAssertThrowsError(try view.update(configuration: .init())) {
            XCTAssertEqual($0 as? AtmosphericRenderingError, .invalidatedView)
        }
        XCTAssertThrowsError(try view.update(surface: surface)) {
            XCTAssertEqual($0 as? AtmosphericRenderingError, .invalidatedView)
        }
        XCTAssertThrowsError(try view.prepareForRendering()) {
            XCTAssertEqual($0 as? AtmosphericRenderingError, .invalidatedView)
        }
        XCTAssertNil(view.cachedDecorationBodyIdentity)
    }

    @MainActor
    func testVisibleSnowStopsForHostConfigAndWindow() async throws {
        guard UIApplication.shared.applicationState == .active else { throw XCTSkip("Requires an active UIKit test host") }
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        }
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let effect = try AtmosphericEffectView(motionPolicy: .full)
        effect.frame = controller.view.bounds
        controller.view.addSubview(effect)
        effect.update(hostState: .init(pageKind: .chat, isVisible: true))
        XCTAssertEqual(effect.particleCount, 50)
        XCTAssertTrue(effect.isAnimationScheduled)
        effect.update(hostState: .init(pageKind: .chat, isVisible: false))
        XCTAssertFalse(effect.isAnimationScheduled)
        effect.update(hostState: .init(pageKind: .chat, isVisible: true))
        XCTAssertTrue(effect.isAnimationScheduled)
        effect.update(motionPolicy: .reduced)
        XCTAssertFalse(effect.isAnimationScheduled)
        effect.update(motionPolicy: .full)
        XCTAssertTrue(effect.isAnimationScheduled)
        var disabled = effect.configuration
        disabled.snowEnabled = false
        try effect.update(configuration: disabled)
        XCTAssertFalse(effect.isAnimationScheduled)
        disabled.snowEnabled = true
        try effect.update(configuration: disabled)
        controller.view.alpha = 0
        effect.refreshVisibility() // Required ancestor transition notification from the host.
        XCTAssertFalse(effect.isAnimationScheduled)
        controller.view.alpha = 1
        effect.refreshVisibility()
        XCTAssertTrue(effect.isAnimationScheduled)
        effect.removeFromSuperview()
        XCTAssertFalse(effect.isAnimationScheduled)
        controller.view.addSubview(effect)
        effect.update(hostState: .init(pageKind: .chat, isVisible: true))
        XCTAssertTrue(effect.isAnimationScheduled)
        effect.invalidate()
        effect.update(hostState: .init(pageKind: .chat, isVisible: true))
        effect.update(motionPolicy: .full)
        XCTAssertFalse(effect.isAnimationScheduled, "Stale callbacks cannot revive an invalidated mounted renderer")
        XCTAssertFalse(effect.isEffectVisible)
        effect.removeFromSuperview()
    }

    @MainActor
    func testActualTargetAndCumulativeAncestorClipsStopAnimation() async throws {
        guard UIApplication.shared.applicationState == .active else { throw XCTSkip("Requires an active UIKit test host") }
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        }
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        defer { window.isHidden = true }
        let outer = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        outer.clipsToBounds = true
        controller.view.addSubview(outer)
        let inner = UIView(frame: outer.bounds)
        inner.clipsToBounds = true
        outer.addSubview(inner)
        var pill = AtmosphericPillGeometry(rect: CGRect(x: 8, y: 8, width: 240, height: 44), clampsTopEdge: false)
        let effect = try AtmosphericEffectView(
            configuration: .init(navbarStyle: .auroraAndSparkles, navbarActiveGlow: false),
            surface: .glassPill(role: .button, geometry: pill), motionPolicy: .full
        )
        defer {
            effect.invalidate()
            effect.removeFromSuperview()
        }
        effect.frame = inner.bounds // A viewport overlay, not a view sized to the decorated target.
        inner.addSubview(effect)
        effect.update(hostState: .init(pageKind: .chat, isVisible: true))
        XCTAssertTrue(effect.isEffectVisible)
        XCTAssertTrue(effect.isAnimationScheduled)
        let body = try XCTUnwrap(effect.cachedDecorationBodyIdentity)
        pill.rect.origin.y = 400
        try effect.update(surface: .glassPill(role: .button, geometry: pill))
        XCTAssertEqual(effect.cachedDecorationBodyIdentity, body)
        XCTAssertFalse(effect.isEffectVisible, "The overlay remains onscreen, but its decorated target does not")
        XCTAssertFalse(effect.isAnimationScheduled)

        inner.frame.origin.y = 220
        effect.frame = CGRect(x: 0, y: -220, width: 320, height: 440)
        pill.rect = CGRect(x: 8, y: 140, width: 240, height: 88)
        try effect.update(surface: .glassPill(role: .button, geometry: pill))
        // In outer coordinates the target spans y=140...228; it intersects outer y=0...200
        // and inner y=220...420 independently, but no part survives both clips.
        XCTAssertFalse(effect.isEffectVisible)
        XCTAssertFalse(effect.isAnimationScheduled)
        inner.frame.origin.y = 0
        effect.frame.origin.y = 0
        effect.refreshVisibility()
        XCTAssertTrue(effect.isEffectVisible)
        XCTAssertTrue(effect.isAnimationScheduled)
    }

    @MainActor
    func testClockDoesNotRetainAView() async throws {
        weak var observed: AtmosphericEffectView?
        try autoreleasepool {
            let view = try AtmosphericEffectView(configuration: .init(snowEnabled: false))
            observed = view
        }
        XCTAssertNil(observed)
    }
}
