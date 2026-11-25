import Foundation

/// A snapshot of the active capture device's zoom bounds, read on its session queue.
/// The slider uses a logarithmic scale so large digital-zoom ranges remain controllable.
public struct CameraZoomState: Equatable {
    public let minimum: CGFloat
    public let maximum: CGFloat
    public let neutral: CGFloat
    public let value: CGFloat

    public init?(minimum: CGFloat, maximum: CGFloat, neutral: CGFloat, value: CGFloat) {
        guard minimum.isFinite, maximum.isFinite, neutral.isFinite,
              minimum > 0.0, maximum >= minimum else { return nil }
        self.minimum = minimum
        self.maximum = maximum
        self.neutral = min(maximum, max(minimum, neutral))
        self.value = value.isFinite ? min(maximum, max(minimum, value)) : self.neutral
    }

    public var fraction: CGFloat {
        guard self.maximum > self.minimum else { return 0.0 }
        return min(1.0, max(0.0, (log(self.value) - log(self.minimum)) / (log(self.maximum) - log(self.minimum))))
    }

    public func target(for update: CameraZoomUpdate) -> CGFloat? {
        let target: CGFloat
        switch update {
        case .read:
            return nil
        case let .fraction(fraction):
            guard fraction.isFinite else { return self.value }
            if fraction <= 0.0 { return self.minimum }
            if fraction >= 1.0 { return self.maximum }
            // Subtract logs instead of dividing bounds: a finite range can have an infinite ratio.
            target = exp(log(self.minimum) * (1.0 - fraction) + log(self.maximum) * fraction)
        case let .delta(delta):
            guard delta.isFinite, delta > 0.0 else { return self.value }
            target = self.value * delta
        case .reset:
            target = self.neutral
        }
        return min(self.maximum, max(self.minimum, target))
    }
}

public enum CameraZoomUpdate {
    case read
    case fraction(CGFloat)
    case delta(CGFloat)
    case reset
}
