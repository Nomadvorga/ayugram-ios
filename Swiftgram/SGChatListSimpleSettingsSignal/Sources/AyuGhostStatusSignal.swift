import SGSimpleSettings
import Foundation
import SwiftSignalKit

// MARK: AyuGram
// Whether the chat list title marks that ghost mode is on ("Display Ghost Mode Status").
public func ayuGhostStatusSignal() -> Signal<Bool, NoError> {
    let current: () -> Bool = {
        return AyuGhostSettings.shared.displayGhostStatus && AyuGhostSettings.shared.isGhostModeActive
    }
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
