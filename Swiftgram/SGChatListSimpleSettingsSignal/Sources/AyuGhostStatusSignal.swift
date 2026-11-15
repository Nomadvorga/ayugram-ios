import SGSimpleSettings
import Foundation
import SwiftSignalKit

// MARK: AyuGram
// The current value of an Ayu setting, emitted again whenever the settings change.
public func ayuSettingSignal(_ current: @escaping () -> Bool) -> Signal<Bool, NoError> {
    let changes = Signal<Bool, NoError> { subscriber in
        subscriber.putNext(current())
        let observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { _ in
            subscriber.putNext(current())
        }
        return ActionDisposable {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    return changes |> distinctUntilChanged
}

// Whether the chat list title marks that ghost mode is on ("Display Ghost Mode Status").
public func ayuGhostStatusSignal() -> Signal<Bool, NoError> {
    return ayuSettingSignal {
        return AyuGhostSettings.shared.displayGhostStatus && AyuGhostSettings.shared.isGhostModeActive
    }
}
