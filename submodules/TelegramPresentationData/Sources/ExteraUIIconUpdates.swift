import Foundation
import SGSimpleSettings
import SwiftSignalKit

public final class ExteraUIIconObservation {
    private var observer: NSObjectProtocol?
    public init(_ updated: @escaping () -> Void) {
        self.observer = NotificationCenter.default.addObserver(forName: ExteraUIIconSettings.didChange, object: nil, queue: .main) { _ in updated() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

public func exteraUIIconPackUpdates() -> Signal<ExteraUIIconProvider, NoError> {
    return Signal { subscriber in
        let observation = ExteraUIIconObservation { subscriber.putNext(.current) }
        subscriber.putNext(.current)
        return ActionDisposable { _ = observation }
    }
}
