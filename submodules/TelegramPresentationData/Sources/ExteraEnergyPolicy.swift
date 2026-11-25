import Foundation
import SGSimpleSettings
import SwiftSignalKit
import TelegramUIPreferences
import UIKit

public extension EnergyUsageSettings {
    /// Keep the established native/device-capability gates and narrow them per surface.
    func exteraAllows(_ feature: ExteraEnergySettings.Feature) -> Bool {
        let nativeEnabled: Bool
        switch feature {
        case .stickerKeyboard, .stickerChat: nativeEnabled = self.loopStickers
        case .emojiKeyboard, .emojiReactions, .emojiChat: nativeEnabled = self.loopEmoji
        case .spoilers, .blur, .calls, .particles: nativeEnabled = self.fullTranslucency
        default: nativeEnabled = true
        }
        return ExteraEnergyRuntime.allows(feature, nativeEnabled: nativeEnabled)
    }
}

/// Observe system changes even for Never/Always: those slider endpoints must not unsubscribe
/// Low Power Mode, accessibility, foreground or preference updates.
public func exteraEnergyEnvironmentChanges() -> Signal<Bool, NoError> {
    return Signal { subscriber in
        let names = ExteraEnergyRuntime.notificationNames.filter { $0 != ExteraEnergyRuntime.policyDidChange }
        let observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in subscriber.putNext(true) }
        }
        subscriber.putNext(true)
        return ActionDisposable {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }
    } |> runOn(Queue.mainQueue())
}
