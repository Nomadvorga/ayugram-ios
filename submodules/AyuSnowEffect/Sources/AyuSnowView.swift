import UIKit
import SGSimpleSettings

/// AyuGram's downward drifting snow, rendered by Core Animation without a display link.
/// The owner explicitly enables it only while its controller is visible.
public final class AyuSnowView: UIView {
    public enum Style {
        case chat
        case header
    }

    public var isActive = false {
        didSet { self.updateEmission() }
    }

    public var color: UIColor = .white {
        didSet {
            if !oldValue.isEqual(self.color) {
                self.removeEmitter()
                self.updateEmission()
            }
        }
    }

    private let style: Style
    private var emitter: CAEmitterLayer?
    private var observers: [NSObjectProtocol] = []
    private var lowPowerMode = false

    // One shared texture, never regenerated during layout or animation.
    private static let dot: CGImage? = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3.0
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 3.0, height: 3.0), format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 0.0, y: 0.0, width: 3.0, height: 3.0))
        }.cgImage
    }()

    public init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
        self.clipsToBounds = true
        let center = NotificationCenter.default
        var notifications = [ayuSettingsDidChangeNotification, UIApplication.didBecomeActiveNotification,
                             UIApplication.willResignActiveNotification, Notification.Name.NSProcessInfoPowerStateDidChange,
                             UIAccessibility.reduceMotionStatusDidChangeNotification,
                             ProcessInfo.thermalStateDidChangeNotification]
        if #available(iOS 13.0, *) {
            notifications.append(contentsOf: [UIScene.didActivateNotification, UIScene.didEnterBackgroundNotification])
        }
        for name in notifications {
            self.observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                if notification.name == UIApplication.willResignActiveNotification {
                    self.removeEmitter()
                } else {
                    self.updateEmission()
                }
            })
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        self.updateEmission()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        self.updateEmission()
    }

    private func removeEmitter() {
        self.emitter?.removeFromSuperlayer()
        self.emitter = nil
    }

    private func updateEmission() {
        guard self.isActive, self.window != nil, !self.bounds.isEmpty,
              ExteraSettings.shared.forceSnow, !UIAccessibility.isReduceMotionEnabled,
              UIApplication.shared.applicationState == .active else {
            self.removeEmitter()
            return
        }
        if #available(iOS 13.0, *), let scene = self.window?.windowScene, scene.activationState != .foregroundActive {
            self.removeEmitter()
            return
        }
        let thermalState = ProcessInfo.processInfo.thermalState
        guard thermalState != .critical else {
            self.removeEmitter()
            return
        }
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled || thermalState == .serious
        if self.emitter != nil && self.lowPowerMode != lowPowerMode {
            self.removeEmitter()
        }
        self.lowPowerMode = lowPowerMode
        let emitter: CAEmitterLayer
        if let current = self.emitter {
            emitter = current
        } else {
            emitter = CAEmitterLayer()
            emitter.emitterShape = .rectangle
            emitter.emitterMode = .surface
            emitter.renderMode = .unordered
            let cell = CAEmitterCell()
            cell.contents = Self.dot
            cell.contentsScale = 3.0
            cell.color = self.color.cgColor
            // Android SnowflakesEffect uses small dots drifting down at 70...109 degrees.
            // Android caps a full chat at 300 particles. At a maximum lifetime of 5 s,
            // 60 births/s preserves that bound independently of the display refresh rate.
            cell.birthRate = self.style == .header ? 18.0 : 60.0
            cell.lifetime = self.style == .header ? 2.05 : 4.0
            cell.lifetimeRange = self.style == .header ? 0.05 : 1.0
            cell.velocity = 44.0
            cell.velocityRange = 4.0
            cell.emissionLongitude = .pi / 2.0
            cell.emissionRange = .pi * 39.0 / 180.0
            cell.scale = 0.5
            cell.scaleRange = 0.0
            cell.alphaSpeed = self.style == .header ? -0.48 : -0.2
            emitter.emitterCells = [cell]
            self.layer.addSublayer(emitter)
            self.emitter = emitter
        }
        // Geometry updates do not rebuild cells or restart the particle simulation.
        let screenBounds = self.window?.screen.bounds ?? self.bounds
        let screenArea = max(1.0, screenBounds.width * screenBounds.height)
        let areaScale = min(1.0, max(0.12, self.bounds.width * self.bounds.height / screenArea))
        let birthRate = Float(self.style == .header ? 1.0 : areaScale) * (lowPowerMode ? 0.35 : 1.0)
        guard emitter.frame != self.bounds || emitter.birthRate != birthRate else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = self.bounds
        emitter.emitterPosition = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        emitter.emitterSize = self.bounds.size
        emitter.birthRate = birthRate
        CATransaction.commit()
    }
}
