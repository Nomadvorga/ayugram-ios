import UIKit
import XCTest
import AyuAtmosphericHost
import AyuAtmosphericSnow
@testable import AyuPluginBridge

final class AyuAtmosphericRenderingTests: XCTestCase {
    @MainActor func testSectionCardUsesActualCornersAndViewportEdges() throws {
        let state = AyuAtmosphericRenderingState()
        let renderer = AyuAtmosphericRendering(state: state, role: .sectionCard)
        defer { renderer.stop() }
        renderer.view.frame = CGRect(x: 0, y: 0, width: 324, height: 324)
        let rect = CGRect(x: 12, y: 12, width: 300, height: 300)
        let geometry = AtmosphericHostGeometry(rect: rect, cornerRadius: 26, visible: false,
            drawTopEdge: false, drawBottomEdge: true, isDarkTheme: true)
        renderer.update(role: .sectionCard, geometry: geometry, dark: true)
        let effect = try XCTUnwrap(renderer.view.subviews.first as? AtmosphericEffectView)
        guard case let .sectionCard(card) = effect.surface else { return XCTFail("Expected grouped section card") }
        XCTAssertEqual(card.pill.rect, rect)
        XCTAssertEqual(card.pill.shape, .roundedRectangle(cornerRadius: 26))
        XCTAssertFalse(card.pill.drawsTopDecoration)
        XCTAssertTrue(card.pill.drawsBottomDecoration)
        XCTAssertFalse(card.pill.drawsFrostWash)
        XCTAssertFalse(effect.isAnimationScheduled)
    }

    @MainActor func testDiagnosticsRemainUntilEveryFailedRendererRecovers() {
        let state = AyuAtmosphericRenderingState()
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var messages: [String?] = []
        state.reportError = { messages.append($0) }
        state.setError("First surface failed", identifier: first)
        state.setError("Second surface failed", identifier: second)
        XCTAssertEqual(state.renderingError, "First surface failed")
        state.setError(nil, identifier: first)
        XCTAssertEqual(state.renderingError, "Second surface failed")
        state.setError(nil, identifier: second)
        XCTAssertNil(state.renderingError)
        XCTAssertEqual(messages.count, 3)
        XCTAssertNil(messages.last!)
    }

    @MainActor func testNavbarTwoPassesPassThroughTouchesAndInvalidateTogether() throws {
        let state = AyuAtmosphericRenderingState()
        try state.apply(values: ["snow_defaults_v": .integer(1)])
        let renderer = AyuAtmosphericRendering(state: state, role: .navbar)
        renderer.view.frame = CGRect(x: 0, y: 0, width: 240, height: 60)
        renderer.backgroundView?.frame = renderer.view.frame
        renderer.update(role: .navbar, geometry: AtmosphericHostGeometry(rect: renderer.view.bounds, cornerRadius: 30,
                                                                         selectedTabRect: CGRect(x: 5, y: 5, width: 50, height: 50), visible: false), dark: true)
        let foreground = try XCTUnwrap(renderer.view.subviews.first as? AtmosphericEffectView)
        let background = try XCTUnwrap(renderer.backgroundView?.subviews.first as? AtmosphericEffectView)
        XCTAssertEqual(foreground.renderPlane, .foreground)
        XCTAssertEqual(background.renderPlane, .background)
        XCTAssertEqual(foreground.surface, background.surface)
        XCTAssertNil(renderer.view.hitTest(CGPoint(x: 20, y: 20), with: nil))
        XCTAssertFalse(foreground.isAnimationScheduled)
        renderer.stop()
        XCTAssertTrue(foreground.isInvalidated)
        XCTAssertTrue(background.isInvalidated)
        renderer.update(role: .navbar, geometry: AtmosphericHostGeometry(rect: renderer.view.bounds), dark: false)
        XCTAssertTrue(renderer.view.subviews.isEmpty)
    }

    @MainActor func testMessageInputIsTheOnlyTallGlassException() throws {
        let state = AyuAtmosphericRenderingState()
        var errors: [String] = []
        state.reportError = { if let message = $0 { errors.append(message) } }
        let renderer = AyuAtmosphericRendering(state: state, role: .glassPill)
        renderer.view.frame = CGRect(x: 0, y: 0, width: 240, height: 120)
        var geometry = AtmosphericHostGeometry(rect: renderer.view.bounds, cornerRadius: 20, visible: false)
        renderer.update(role: .glassPill, geometry: geometry, dark: false)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(renderer.view.subviews.isEmpty)
        geometry.allowsTallGlass = true
        renderer.update(role: .glassPill, geometry: geometry, dark: false)
        let effect = try XCTUnwrap(renderer.view.subviews.first as? AtmosphericEffectView)
        if case let .glassPill(role, _) = effect.surface { XCTAssertEqual(role, .messageInput) }
        else { XCTFail("Expected typed message-input glass surface") }
        renderer.stop()
    }

    @MainActor func testGenericBlurredDrawableRetainsNarrowerWidthLimit() throws {
        let state = AyuAtmosphericRenderingState()
        let renderer = AyuAtmosphericRendering(state: state, role: .glassPill)
        renderer.view.frame = CGRect(x: 0, y: 0, width: 700, height: 44)
        var geometry = AtmosphericHostGeometry(rect: renderer.view.bounds, cornerRadius: 22, visible: false)
        geometry.glassDrawsFrostWash = true
        renderer.update(role: .glassPill, geometry: geometry, dark: false)
        XCTAssertTrue(renderer.view.subviews.isEmpty)
        XCTAssertNotNil(state.renderingError)
        geometry.rect.size.width = 600
        renderer.update(role: .glassPill, geometry: geometry, dark: false)
        let effect = try XCTUnwrap(renderer.view.subviews.first as? AtmosphericEffectView)
        if case let .glassPill(role, pill) = effect.surface {
            XCTAssertEqual(role, .blurredDrawable)
            XCTAssertTrue(pill.drawsFrostWash)
        } else { XCTFail("Expected typed blurred-drawable glass surface") }
        XCTAssertNil(state.renderingError)
        renderer.stop()
    }
}
