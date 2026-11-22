import UIKit
import XCTest
@testable import AyuAtmosphericHost

final class AtmosphericHostTests: XCTestCase {
    @MainActor func testDisabledHostDoesNotAllocateRenderer() {
        AtmosphericHost.shared.disable()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let attachment = AtmosphericSurfaceAttachment(container: container, role: .snowfall)
        attachment.update(geometry: AtmosphericHostGeometry(rect: container.bounds))
        XCTAssertTrue(container.subviews.isEmpty)
        XCTAssertFalse(AtmosphericHost.shared.isEnabled)
        attachment.detach()
    }

    @MainActor func testGenerationCleanupAndParentOwnedCoordinates() {
        AtmosphericHost.shared.disable()
        defer { AtmosphericHost.shared.disable() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        window.isHidden = false
        defer { window.isHidden = true }
        let renderer = MockAtmosphericRendering()
        let attachment = AtmosphericSurfaceAttachment(container: container, role: .navbar)
        let rect = CGRect(x: 20, y: 30, width: 150, height: 60)
        let selected = CGRect(x: 25, y: 35, width: 30, height: 40)
        attachment.update(geometry: AtmosphericHostGeometry(rect: rect, cornerRadius: 20, selectedTabRect: selected))
        AtmosphericHost.shared.enable { _ in renderer }
        let generation = AtmosphericHost.shared.generation
        XCTAssertNotNil(generation)
        XCTAssertEqual(renderer.view.frame, rect.insetBy(dx: -12, dy: -12))
        XCTAssertEqual(renderer.lastGeometry?.rect, CGRect(x: 12, y: 12, width: rect.width, height: rect.height))
        XCTAssertEqual(renderer.lastGeometry?.selectedTabRect, selected.offsetBy(dx: -8, dy: -18))
        AtmosphericHost.shared.disable()
        XCTAssertTrue(renderer.didStop)
        XCTAssertNil(renderer.view.superview)
        XCTAssertNil(AtmosphericHost.shared.generation)
        attachment.detach()
    }

    @MainActor func testHiddenAncestorSuppressesInstantiation() {
        AtmosphericHost.shared.disable()
        defer { AtmosphericHost.shared.disable() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        window.isHidden = false
        defer { window.isHidden = true }
        container.isHidden = true
        var allocations = 0
        AtmosphericHost.shared.enable { _ in allocations += 1; return MockAtmosphericRendering() }
        let attachment = AtmosphericSurfaceAttachment(container: container, role: .glassPill)
        attachment.update(geometry: AtmosphericHostGeometry(rect: container.bounds, cornerRadius: 20))
        XCTAssertEqual(allocations, 0)
        attachment.detach()
    }

    @MainActor func testBothNavbarPlanesAndThemeOverrideShareLifecycle() {
        AtmosphericHost.shared.disable()
        defer { AtmosphericHost.shared.disable() }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        window.isHidden = false
        defer { window.isHidden = true }
        let content = UIView()
        container.addSubview(content)
        let renderer = MockAtmosphericRendering()
        let attachment = AtmosphericSurfaceAttachment(container: container, role: .navbar)
        var geometry = AtmosphericHostGeometry(rect: CGRect(x: 20, y: 20, width: 200, height: 60))
        attachment.update(geometry: geometry)
        AtmosphericHost.shared.updateTheme(isDark: true)
        AtmosphericHost.shared.enable { _ in renderer }
        XCTAssertEqual(renderer.lastDark, true)
        XCTAssertEqual(renderer.backgroundView?.frame, renderer.view.frame)
        XCTAssertTrue(container.subviews.first === renderer.backgroundView)
        XCTAssertTrue(container.subviews.last === renderer.view)
        geometry.isDarkTheme = false
        attachment.update(geometry: geometry)
        XCTAssertEqual(renderer.lastDark, false)
        geometry.visible = false
        attachment.update(geometry: geometry)
        XCTAssertTrue(renderer.view.isHidden)
        XCTAssertEqual(renderer.backgroundView?.isHidden, true)
        attachment.detach()
        XCTAssertTrue(renderer.didStop)
        XCTAssertNil(renderer.view.superview)
        XCTAssertNil(renderer.backgroundView?.superview)
        XCTAssertTrue(content.superview === container)
    }
}

@MainActor private final class MockAtmosphericRendering: AtmosphericHostRendering {
    let view = UIView()
    let backgroundView: UIView? = UIView()
    var lastGeometry: AtmosphericHostGeometry?
    var lastDark: Bool?
    var didStop = false
    func update(role: AtmosphericHostRole, geometry: AtmosphericHostGeometry, dark: Bool) {
        self.lastGeometry = geometry
        self.lastDark = dark
    }
    func stop() { self.didStop = true }
}
