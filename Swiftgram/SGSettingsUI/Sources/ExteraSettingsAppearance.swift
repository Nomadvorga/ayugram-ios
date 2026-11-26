import Foundation
import SGItemListUI
import SGSimpleSettings
import SwiftSignalKit
import UIKit

/// Read persisted style at state publication, then pass this value to renderer
/// arguments and every SGStyledItemListEntry in the same transaction.
public func exteraSettingsAppearance() -> SGExteraAppearance {
    let settings = ExteraStyleSettings.shared
    let controlStyle: SGExteraAppearance.ControlStyle
    switch settings.controlStyle {
    case .classic: controlStyle = .classic
    case .material: controlStyle = .material
    }
    let separatorStyle: SGExteraAppearance.SeparatorStyle
    switch settings.separatorStyle {
    case .line: separatorStyle = .line
    case .fullWidth: separatorStyle = .fullWidth
    case .none: separatorStyle = .none
    }
    return SGExteraAppearance(
        controlStyle: controlStyle,
        sectionRadius: CGFloat(settings.sectionRadius),
        separateHeaders: settings.separateHeaders,
        separatorStyle: separatorStyle
    )
}

/// Observe before the first state is published and release the token with the list subscription.
func exteraSettingsChanges() -> Signal<Bool, NoError> {
    return Signal { subscriber in
        let observers = [
            NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { _ in
                subscriber.putNext(true)
            },
            NotificationCenter.default.addObserver(forName: ExteraUIIconSettings.didChange, object: nil, queue: nil) { _ in
                subscriber.putNext(true)
            }
        ]
        subscriber.putNext(true)
        return ActionDisposable {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
    |> deliverOnMainQueue
}
