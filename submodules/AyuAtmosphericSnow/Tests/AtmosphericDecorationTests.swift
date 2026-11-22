import UIKit
import XCTest
@testable import AyuAtmosphericSnow

// Unrun native contracts, not visual-parity evidence. No test target is installed by this module work.
final class AtmosphericDecorationTests: XCTestCase {
    @MainActor
    func testPillOpacityTranslationClipAndUnrelatedSettingsReuseStaticBody() async throws {
        var configuration = AtmosphericSnowConfiguration(navbarActiveGlow: false)
        var pill = AtmosphericPillGeometry(rect: CGRect(x: 4, y: 12, width: 240, height: 44),
                                           drawsFrostWash: true, clampsTopEdge: false)
        let original = try prepare(.glassPill(role: .button, geometry: pill), configuration: configuration)
        pill.rect = pill.rect.offsetBy(dx: 15, dy: 50)
        pill.visibility.opacity = 0.4
        pill.clipRect = CGRect(x: 0, y: 40, width: 400, height: 140)
        let moved = try prepare(.glassPill(role: .button, geometry: pill), configuration: configuration, reusing: original)
        XCTAssertEqual(moved.staticBodyIdentity, original.staticBodyIdentity)
        XCTAssertEqual(moved.opacity, 0.4)
        XCTAssertTrue(moved.isVisible)
        XCTAssertNotEqual(moved.presentationBounds, original.presentationBounds)

        configuration.snowDensity = .heavy
        configuration.snowSpeed = .fast
        configuration.snowColor = .warm
        let unrelated = try prepare(.glassPill(role: .button, geometry: pill), configuration: configuration, reusing: moved)
        XCTAssertEqual(unrelated.staticBodyIdentity, original.staticBodyIdentity)
        pill.visibility.isVisible = false
        let hidden = try prepare(.glassPill(role: .button, geometry: pill), configuration: configuration, reusing: unrelated)
        XCTAssertEqual(hidden.staticBodyIdentity, original.staticBodyIdentity)
        XCTAssertFalse(hidden.isVisible)
        XCTAssertFalse(hidden.needsAnimation)
        XCTAssertTrue(hidden.presentationBounds.isNull)
    }

    @MainActor
    func testMaterialEdgesAndScaleReplaceOnlyTheLastBody() async throws {
        var configuration = AtmosphericSnowConfiguration(navbarActiveGlow: false)
        var pill = AtmosphericPillGeometry(rect: CGRect(x: 10, y: 15, width: 240, height: 44), clampsTopEdge: false)
        let original = try prepare(.glassPill(role: .button, geometry: pill), configuration: configuration)
        configuration.navbarGarlandPalette = .icyNeon
        let palette = try prepare(.glassPill(role: .button, geometry: pill), configuration: configuration, reusing: original)
        XCTAssertNotEqual(palette.staticBodyIdentity, original.staticBodyIdentity)
        configuration.navbarStyle = .frostAndIcicles
        let frost = try prepare(.glassPill(role: .button, geometry: pill), configuration: configuration, reusing: palette)
        XCTAssertNotEqual(frost.staticBodyIdentity, palette.staticBodyIdentity)
        pill.drawsBottomDecoration = false
        let clippedEdge = try prepare(.glassPill(role: .button, geometry: pill), configuration: configuration, reusing: frost)
        XCTAssertNotEqual(clippedEdge.staticBodyIdentity, frost.staticBodyIdentity)
        let scale = try prepare(.glassPill(role: .button, geometry: pill), configuration: configuration,
                                displayScale: 3, reusing: clippedEdge)
        XCTAssertNotEqual(scale.staticBodyIdentity, clippedEdge.staticBodyIdentity)
    }

    @MainActor
    func testNavbarSelectedTabMovesAndFadesWithoutRebuildingEitherBody() async throws {
        var configuration = AtmosphericSnowConfiguration()
        var geometry = AtmosphericNavigationBarGeometry(
            pill: .init(rect: CGRect(x: 8, y: 8, width: 300, height: 56)),
            selectedTab: .init(rect: CGRect(x: 20, y: 14, width: 80, height: 44))
        )
        let original = try prepare(.navigationBar(geometry), configuration: configuration)
        let selectedIdentity = try XCTUnwrap(original.selectedTabBodyIdentity)
        geometry.pill.rect = geometry.pill.rect.offsetBy(dx: 7, dy: 18)
        geometry.pill.visibility.opacity = 0.6
        geometry.pill.clipRect = CGRect(x: 0, y: 0, width: 360, height: 120)
        geometry.selectedTab = .init(rect: CGRect(x: 108, y: 32, width: 80, height: 44), visibility: .init(opacity: 0.45))
        let moved = try prepare(.navigationBar(geometry), configuration: configuration, reusing: original)
        XCTAssertEqual(moved.staticBodyIdentity, original.staticBodyIdentity)
        XCTAssertEqual(moved.selectedTabBodyIdentity, selectedIdentity)

        configuration.navbarActiveGlow = false
        let disabled = try prepare(.navigationBar(geometry), configuration: configuration, reusing: moved)
        XCTAssertEqual(disabled.staticBodyIdentity, original.staticBodyIdentity)
        XCTAssertNil(disabled.selectedTabBodyIdentity)
        XCTAssertFalse(disabled.needsAnimation)
        configuration.navbarActiveGlow = true
        let enabled = try prepare(.navigationBar(geometry), configuration: configuration, reusing: disabled)
        XCTAssertEqual(enabled.selectedTabBodyIdentity, selectedIdentity)
        geometry.selectedTab?.rect.size.width = 92
        let resized = try prepare(.navigationBar(geometry), configuration: configuration, reusing: enabled)
        XCTAssertEqual(resized.staticBodyIdentity, original.staticBodyIdentity)
        XCTAssertNotEqual(resized.selectedTabBodyIdentity, selectedIdentity)
    }

    @MainActor
    func testAvatarFadeAndNoStoriesResizeReuseReferenceBody() async throws {
        var geometry = AtmosphericAvatarGeometry(rect: CGRect(x: 3, y: 10, width: 96, height: 96))
        let original = try prepare(.profileAvatar(geometry))
        geometry.rect = CGRect(x: 20, y: 30, width: 114, height: 114)
        geometry.expansionProgress = 0.4
        geometry.visibility.opacity = 0.8
        geometry.insetProgress = 0.7
        geometry.foregroundAlpha = 0.6
        geometry.clipRect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let faded = try prepare(.profileAvatar(geometry), isDark: true, reusing: original)
        XCTAssertEqual(faded.staticBodyIdentity, original.staticBodyIdentity)
        XCTAssertEqual(faded.opacity, (0.55 - 0.4) / 0.35 * 0.8, accuracy: 0.000_001)
        geometry.expansionProgress = 0.55
        let expanded = try prepare(.profileAvatar(geometry), reusing: faded)
        XCTAssertEqual(expanded.staticBodyIdentity, original.staticBodyIdentity)
        XCTAssertFalse(expanded.isVisible)

        geometry = .init(rect: CGRect(x: 3, y: 10, width: 96, height: 96), hasStories: true)
        let stories = try prepare(.profileAvatar(geometry), reusing: expanded)
        XCTAssertNotEqual(stories.staticBodyIdentity, original.staticBodyIdentity)
        geometry.expansionProgress = 0.01 // 3.465-point inset still rounds to the same 3.5 at 2x.
        let sameInsetBucket = try prepare(.profileAvatar(geometry), reusing: stories)
        XCTAssertEqual(sameInsetBucket.staticBodyIdentity, stories.staticBodyIdentity)
    }

    @MainActor
    func testProfileActionReferenceBodySurvivesFadeAndTransformChanges() async throws {
        var geometry = AtmosphericProfileActionGeometry(
            pill: .init(rect: CGRect(x: 20, y: 20, width: 150, height: 56),
                        shape: .roundedRectangle(cornerRadius: 16), clampsTopEdge: false),
            scale: 0.95, expandedReferenceSize: CGSize(width: 160, height: 60)
        )
        let original = try prepare(.profileAction(geometry))
        geometry.pill.rect = CGRect(x: 30, y: 40, width: 144, height: 54)
        geometry.scale = 0.85
        geometry.expansionFraction = 0.9
        geometry.pill.visibility.opacity = 0.8
        geometry.pill.clipRect = CGRect(x: 0, y: 0, width: 320, height: 140)
        let moved = try prepare(.profileAction(geometry), reusing: original)
        XCTAssertEqual(moved.staticBodyIdentity, original.staticBodyIdentity)
        XCTAssertEqual(moved.opacity, (0.9 - 0.68) / 0.32 * 0.8, accuracy: 0.000_001)
        XCTAssertTrue(moved.isVisible)
    }

    @MainActor
    func testNavbarPlanesKeepWashAndSelectedFillBelowContent() async throws {
        var configuration = AtmosphericSnowConfiguration(navbarStyle: .frostAndIcicles)
        let geometry = AtmosphericNavigationBarGeometry(
            pill: .init(rect: CGRect(x: 8, y: 8, width: 300, height: 56)),
            selectedTab: .init(rect: CGRect(x: 20, y: 14, width: 80, height: 44))
        )
        let background = try prepare(.navigationBar(geometry), configuration: configuration, plane: .background)
        let foreground = try prepare(.navigationBar(geometry), configuration: configuration, plane: .foreground)
        let combined = try prepare(.navigationBar(geometry), configuration: configuration)
        XCTAssertEqual(background.staticBackgroundCommandCount, 1)
        XCTAssertEqual(background.staticForegroundCommandCount, 0)
        XCTAssertTrue(background.hasBackgroundDrawing)
        XCTAssertFalse(background.hasForegroundDrawing)
        XCTAssertTrue(background.needsAnimation, "Selected fill has its own source pulse")
        XCTAssertEqual(foreground.staticBackgroundCommandCount, 0)
        XCTAssertFalse(foreground.hasBackgroundDrawing)
        XCTAssertTrue(foreground.hasForegroundDrawing)
        XCTAssertTrue(foreground.needsAnimation)
        XCTAssertTrue(combined.hasBackgroundDrawing)
        XCTAssertTrue(combined.hasForegroundDrawing)
        configuration.navbarActiveGlow = false
        let staticBackground = try prepare(.navigationBar(geometry), configuration: configuration,
                                           plane: .background, reusing: background)
        let staticForeground = try prepare(.navigationBar(geometry), configuration: configuration,
                                           plane: .foreground, reusing: foreground)
        XCTAssertFalse(staticBackground.needsAnimation)
        XCTAssertFalse(staticForeground.needsAnimation)
    }

    @MainActor
    func testStyleThreeSparksSurviveGlowOffOnEveryFestiveSurface() async throws {
        let configuration = AtmosphericSnowConfiguration(navbarStyle: .auroraAndSparkles, navbarActiveGlow: false)
        let pill = AtmosphericPillGeometry(rect: CGRect(x: 10, y: 10, width: 240, height: 60),
                                           shape: .roundedRectangle(cornerRadius: 16))
        let surfaces: [AtmosphericSurface] = [
            .navigationBar(.init(pill: pill)),
            .glassPill(role: .button, geometry: pill),
            .profileAction(.init(pill: pill)),
            .sectionCard(.init(pill: pill)),
            .profileAvatar(.init(rect: CGRect(x: 10, y: 10, width: 96, height: 96)))
        ]
        for surface in surfaces {
            let decoration = try prepare(surface, configuration: configuration, plane: .foreground)
            XCTAssertTrue(decoration.needsAnimation, "Style 3 remains animated for \(surface.kind)")
            XCTAssertFalse(decoration.hasBackgroundDrawing)
        }
    }

    @MainActor
    func testWarmStyleRetainsColdAvatarRingAndStaticPaletteBulbs() async throws {
        var configuration = AtmosphericSnowConfiguration(navbarStyle: .warmGarland,
                                                          navbarGarlandPalette: .icyNeon, navbarActiveGlow: false)
        let avatar = try prepare(.profileAvatar(.init(rect: CGRect(x: 10, y: 10, width: 96, height: 96))),
                                  configuration: configuration, plane: .foreground)
        XCTAssertEqual(avatar.staticForegroundCommandCount, 17, "Two cold rings, one wire, fourteen static bulbs")
        XCTAssertFalse(avatar.needsAnimation)
        let surface = AtmosphericSurface.navigationBar(.init(pill: .init(rect: CGRect(x: 8, y: 8, width: 300, height: 56))))
        let garland = try prepare(surface, configuration: configuration, plane: .foreground)
        XCTAssertEqual(garland.staticForegroundCommandCount, 12, "Wire plus eleven bulbs; no warm-style pill frost rim")
        XCTAssertFalse(garland.needsAnimation)
        XCTAssertEqual(try render(garland, elapsed: 0), try render(garland, elapsed: 10))
        configuration.navbarGarlandPalette = .holidayMix
        let newPalette = try prepare(surface, configuration: configuration, plane: .foreground, reusing: garland)
        XCTAssertNotEqual(newPalette.staticBodyIdentity, garland.staticBodyIdentity, "Style 2 does not force warm gold")
    }

    @MainActor
    private func prepare(_ surface: AtmosphericSurface,
                         configuration: AtmosphericSnowConfiguration = .init(),
                         plane: AtmosphericRenderPlane = .combined, isDark: Bool = false,
                         displayScale: CGFloat = 2, reusing previous: AtmosphericDecoration? = nil) throws -> AtmosphericDecoration {
        try surface.validate()
        let decoration = try AtmosphericDecoration.prepare(surface: surface, configuration: configuration,
                                                            renderPlane: plane, isDark: isDark,
                                                            displayScale: displayScale, reusing: previous)
        return try XCTUnwrap(decoration)
    }

    @MainActor
    private func render(_ decoration: AtmosphericDecoration, elapsed: TimeInterval) throws -> Data {
        let context = try XCTUnwrap(atmosphericBitmapContext(width: 360, height: 160))
        context.translateBy(x: 0, y: 160)
        context.scaleBy(x: 1, y: -1)
        decoration.draw(in: context, elapsed: elapsed)
        let image = try XCTUnwrap(context.makeImage())
        let bytes = try XCTUnwrap(image.dataProvider?.data)
        return bytes as Data
    }
}
