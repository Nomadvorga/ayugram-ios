import Foundation
import UIKit

/// Read the system at the point of use. The threshold is a transient copy of the existing native
/// account-manager preference, published by TelegramPresentationData's energy resolver.
public enum ExteraEnergyRuntime {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var threshold: Int32 = 15
        var reduceMotion = false
    }
    private static let state = State()

    public static func updateNativeThreshold(_ threshold: Int32) {
        self.state.lock.lock()
        let changed = self.state.threshold != threshold
        self.state.threshold = threshold
        self.state.lock.unlock()
        if changed { NotificationCenter.default.post(name: self.policyDidChange, object: nil) }
    }

    public static func updateNativeReduceMotion(_ reduceMotion: Bool) {
        self.state.lock.lock()
        let changed = self.state.reduceMotion != reduceMotion
        self.state.reduceMotion = reduceMotion
        self.state.lock.unlock()
        if changed { NotificationCenter.default.post(name: self.policyDidChange, object: nil) }
    }

    public static let policyDidChange = Notification.Name("ExteraEnergyPolicyDidChange")
    public static var notificationNames: [Notification.Name] {
        return [UIDevice.batteryLevelDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange,
                UIAccessibility.reduceMotionStatusDidChangeNotification, UIAccessibility.reduceTransparencyStatusDidChangeNotification,
                UIApplication.didBecomeActiveNotification, ayuSettingsDidChangeNotification, self.policyDidChange]
    }

    public static var savingActive: Bool {
        self.state.lock.lock()
        let threshold = self.state.threshold
        self.state.lock.unlock()
        return ExteraEnergySettings.savingActive(
            threshold: threshold, followSystem: ExteraEnergySettings.shared.followSystem,
            batteryLevel: UIDevice.current.batteryLevel, systemLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    public static func allows(_ feature: ExteraEnergySettings.Feature, nativeEnabled: Bool = true) -> Bool {
        self.state.lock.lock()
        let reduceMotion = self.state.reduceMotion
        self.state.lock.unlock()
        return ExteraEnergySettings.allows(
            feature, selected: ExteraEnergySettings.shared.isEnabled(feature), nativeEnabled: nativeEnabled,
            savingActive: self.savingActive, reduceMotion: reduceMotion || UIAccessibility.isReduceMotionEnabled,
            reduceTransparency: UIAccessibility.isReduceTransparencyEnabled
        )
    }
}

/// Own with the view/node. Refresh callbacks run on main, outside preference/resolver updates.
public final class ExteraEnergyObservation {
    private var observers: [NSObjectProtocol] = []

    public init(changed: @escaping () -> Void) {
        self.observers = ExteraEnergyRuntime.notificationNames.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async(execute: changed)
            }
        }
    }

    deinit {
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }
}
