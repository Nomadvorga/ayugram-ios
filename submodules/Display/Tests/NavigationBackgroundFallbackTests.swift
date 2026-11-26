import XCTest
import UIKit
@testable import Display

final class NavigationBackgroundFallbackTests: XCTestCase {
    func testEnergyDisabledPreservesTranslucentTint() {
        let tint = UIColor(white: 1.0, alpha: 0.1)
        let result = navigationBackgroundFallbackColor(color: tint, allowsBlur: false, reduceTransparency: false, forceThemeBlur: false, enableBlur: true)
        XCTAssertEqual(result.cgColor.alpha, 0.1, accuracy: 0.001)
    }

    func testReduceTransparencyUsesOpaqueFallback() {
        let tint = UIColor(white: 1.0, alpha: 0.1)
        let result = navigationBackgroundFallbackColor(color: tint, allowsBlur: true, reduceTransparency: true, forceThemeBlur: false, enableBlur: true)
        XCTAssertEqual(result.cgColor.alpha, 1.0, accuracy: 0.001)
    }

    func testForcedTintOnlyAppliesWhenBlurIsAllowed() {
        let color = UIColor.systemBlue
        let blurred = navigationBackgroundFallbackColor(color: color, allowsBlur: true, reduceTransparency: false, forceThemeBlur: true, enableBlur: true)
        let staticFallback = navigationBackgroundFallbackColor(color: color, allowsBlur: false, reduceTransparency: false, forceThemeBlur: true, enableBlur: true)
        XCTAssertEqual(blurred.cgColor.alpha, 0.85, accuracy: 0.001)
        XCTAssertEqual(staticFallback, color)
    }
}
