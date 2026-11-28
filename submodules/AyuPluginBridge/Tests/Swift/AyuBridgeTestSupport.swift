import Foundation
import UIKit
import XCTest
@testable import AyuPluginBridge

/// Test-only value equality for adapter results. A prepared result carries
/// native commit/rollback closures, so it never compares equal: an assertion
/// against one fails instead of ignoring its effects.
extension AyuBridgeAdapterResult: @retroactive Equatable {
    public static func == (lhs: AyuBridgeAdapterResult, rhs: AyuBridgeAdapterResult) -> Bool {
        switch (lhs, rhs) {
        case let (.value(left), .value(right)):
            return left == right
        case let (.instance(leftClass, leftState), .instance(rightClass, rightState)):
            return leftClass == rightClass && leftState == rightState
        default:
            return false
        }
    }
}

/// Lock-protected cell for a value written from a `@Sendable` closure.
final class AyuTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { self.stored = value }
    var value: Value {
        get { self.lock.lock(); defer { self.lock.unlock() }; return self.stored }
        set { self.lock.lock(); defer { self.lock.unlock() }; self.stored = newValue }
    }
    func update(_ body: (inout Value) -> Void) {
        self.lock.lock(); defer { self.lock.unlock() }
        body(&self.stored)
    }
}

/// UIControl delivers target-action through UIApplication, which a hostless test
/// runner does not have. Skips the rest of the test there.
@MainActor func ayuTestRequireControlActions() throws {
    final class Probe: NSObject {
        var fired = false
        @objc func fire() { self.fired = true }
    }
    let probe = Probe()
    let control = UIControl()
    control.addTarget(probe, action: #selector(Probe.fire), for: .valueChanged)
    control.sendActions(for: .valueChanged)
    if !probe.fired { throw XCTSkip("UIControl target-action requires a host application") }
}

/// Without a host application UIKit finishes animations at once, delay included.
/// Skips the rest of the test there.
@MainActor func ayuTestRequireTimedAnimations() async throws {
    let view = UIView()
    let animator = UIViewPropertyAnimator(duration: 0.2, curve: .linear) { view.alpha = 0 }
    animator.startAnimation(afterDelay: 0.2)
    try await Task.sleep(nanoseconds: 50_000_000)
    guard animator.state == .active else { throw XCTSkip("Timed UIKit animations require a host application") }
    animator.stopAnimation(true)
}
