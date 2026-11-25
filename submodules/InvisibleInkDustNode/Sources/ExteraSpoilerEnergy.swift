import Foundation
import SGSimpleSettings
import UIKit

/// Pause the existing dust in place. Removing it would expose unrevealed text/media.
final class ExteraSpoilerEnergy {
    private weak var layer: CAEmitterLayer?
    private var observation: ExteraEnergyObservation?
    private var pausedByEnergy = false

    init() {
        self.observation = ExteraEnergyObservation { [weak self] in self?.update() }
    }

    func attach(_ layer: CAEmitterLayer) {
        self.layer = layer
        self.pausedByEnergy = false
        self.update()
    }

    private func update() {
        guard let layer else { return }
        if !ExteraEnergyRuntime.allows(.spoilers) && !self.pausedByEnergy {
            let time = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0.0
            layer.timeOffset = time
            self.pausedByEnergy = true
        } else if ExteraEnergyRuntime.allows(.spoilers) && self.pausedByEnergy {
            let time = layer.timeOffset
            layer.speed = 1.0
            layer.timeOffset = 0.0
            layer.beginTime = 0.0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - time
            self.pausedByEnergy = false
        }
    }
}
