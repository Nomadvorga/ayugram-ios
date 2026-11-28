import CoreMotion
import Foundation
import UIKit

/// Native contract for Ball 1.1. The audited source draws a self-contained
/// physics toy over the chat. iOS uses a real UIKit overlay, Core Animation
/// timing, CoreMotion gravity for the tilt mode and native gestures instead of
/// Choreographer/SensorEventListener.
@MainActor
final class AyuBallAdapter: AyuNativePluginAdapter {
    private(set) var isEnabled = false
    override var actionTitle: String? { self.isEnabled ? "Играть в Ball" : nil }

    init(defaults: UserDefaults, reportError: @escaping (String?) -> Void) {
        super.init(pluginID: "ball", defaults: defaults, reportError: reportError)
    }

    override func enable() throws {
        self.isEnabled = true
        self.reportError(nil)
        AyuNativePluginRuntime.shared.ball = self
    }

    override func disable() {
        self.isEnabled = false
        if AyuNativePluginRuntime.shared.ball === self { AyuNativePluginRuntime.shared.ball = nil }
    }

    // Audited source constants: r = dp(28), g = dp(1300), FLOOR_E = 0.80.
    var gravity: CGFloat { 1300 }
    var diameter: CGFloat { 56 }
    var restitution: CGFloat { 0.80 }

    /// Source setting `counter`: show the combo multiplier on impacts.
    var showsCounter: Bool { self.boolValue("counter", default: true) }

    override func settings() throws -> [AyuPluginSetting] {
        var rows: [AyuPluginSetting] = [
            self.staticRow("Header", "Игра"),
            self.switchRow("counter", "Счётчик комбо",
                           subtext: "Показывать множитель X при ударах",
                           value: self.boolValue("counter", default: true)),
            self.switchRow("gyro", "Управление наклоном",
                           subtext: "Мяч скатывается в сторону наклона телефона",
                           value: self.boolValue("gyro", default: true)),
            self.staticRow("Divider", "iOS: наклон читается через CoreMotion с тем же сглаживанием и мёртвой зоной, что в исходнике. Если сенсор недоступен, остаются перетаскивание и бросок пальцем."),
        ]
        rows.append(self.textRow("Открыть игру", subtext: "Мини-игра с мячом поверх приложения", action: "ball.open"))
        return rows
    }

    override func set(_ row: AyuPluginSetting, value: AyuBridgeValue) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        guard let key = row.key else { throw AyuPluginService.Failure.operation("INVALID_SETTING") }
        guard key == "counter" || key == "gyro", case .bool = value else {
            throw AyuPluginService.Failure.operation(key == "counter" || key == "gyro" ? "INVALID_SETTING_TYPE" : "INVALID_SETTING")
        }
        try self.setValue(value, for: key)
    }

    override func activate(_ row: AyuPluginSetting, presenter: UIViewController?, completion: @escaping () -> Void) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        if row.descriptor["native_action"].string == "ball.open" {
            guard let presenter else { throw AyuPluginService.Failure.inactive }
            self.open(from: presenter)
        }
        completion()
    }

    override func open(from presenter: UIViewController) {
        guard self.isEnabled else { return }
        let controller = AyuBallViewController(gravity: self.gravity, diameter: self.diameter, restitution: self.restitution,
                                               showsCounter: self.showsCounter,
                                               usesTilt: self.boolValue("gyro", default: true))
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true)
    }
}

@MainActor
final class AyuBallViewController: UIViewController {
    private let gravity: CGFloat
    private let diameter: CGFloat
    private let restitution: CGFloat
    private let showsCounter: Bool
    private let usesTilt: Bool
    private let ball = AyuBallView()
    private let comboLabel = UILabel()
    private let hintLabel = UILabel()
    private let motion = CMMotionManager()
    private var filteredTiltX: CGFloat = 0
    private var filteredTiltY: CGFloat = 1
    private var tiltX: CGFloat = 0
    private var tiltY: CGFloat = 1
    private var link: CADisplayLink?
    private var velocity = CGVector(dx: 120, dy: -300)
    private var position = CGPoint.zero
    private var lastStamp = CACurrentMediaTime()
    private var combo = 0
    private var lastHit = CACurrentMediaTime()
    private let lightFeedback = UIImpactFeedbackGenerator(style: .light)
    private let mediumFeedback = UIImpactFeedbackGenerator(style: .medium)

    init(gravity: CGFloat, diameter: CGFloat, restitution: CGFloat, showsCounter: Bool, usesTilt: Bool) {
        self.gravity = gravity
        self.diameter = diameter
        self.restitution = restitution
        self.showsCounter = showsCounter
        self.usesTilt = usesTilt
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = UIColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1)
        let gradient = CAGradientLayer()
        gradient.colors = [UIColor(red: 0.12, green: 0.15, blue: 0.25, alpha: 1).cgColor,
                           UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1).cgColor]
        gradient.frame = self.view.bounds
        gradient.startPoint = CGPoint(x: 0.2, y: 0)
        gradient.endPoint = CGPoint(x: 0.8, y: 1)
        self.view.layer.addSublayer(gradient)
        self.gradientLayer = gradient

        self.ball.frame = CGRect(x: 0, y: 0, width: self.diameter, height: self.diameter)
        self.ball.layer.cornerRadius = self.diameter / 2
        self.view.addSubview(self.ball)

        let top = UIStackView()
        top.axis = .horizontal
        top.spacing = 8
        top.alignment = .center
        top.translatesAutoresizingMaskIntoConstraints = false
        let close = UIButton(type: .system)
        close.setTitle("×", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        close.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
        top.addArrangedSubview(close)
        self.comboLabel.font = .systemFont(ofSize: 34, weight: .bold)
        self.comboLabel.textColor = .white
        self.comboLabel.textAlignment = .center
        self.comboLabel.layer.shadowColor = UIColor.black.cgColor
        self.comboLabel.layer.shadowOpacity = 0.75
        self.comboLabel.layer.shadowRadius = 6
        self.comboLabel.layer.shadowOffset = .zero
        self.comboLabel.isHidden = true
        self.view.addSubview(self.comboLabel)
        self.view.addSubview(top)

        self.hintLabel.text = self.usesTilt
            ? "Наклоняйте телефон, тяните мяч или нажмите на поле"
            : "Тяните мяч или нажмите на поле — мяч полетит от пальца"
        self.hintLabel.font = .preferredFont(forTextStyle: .footnote)
        self.hintLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        self.hintLabel.textAlignment = .center
        self.hintLabel.numberOfLines = 0
        self.hintLabel.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.hintLabel)

        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            top.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 14),
            self.hintLabel.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 20),
            self.hintLabel.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -20),
            self.hintLabel.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        self.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tap(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.pan(_:)))
        self.view.addGestureRecognizer(pan)
    }

    private var gradientLayer: CAGradientLayer?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.gradientLayer?.frame = self.view.bounds
        if self.position == .zero {
            self.position = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)
        }
        self.clampPosition()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.ball.frame = CGRect(x: self.position.x - self.diameter / 2, y: self.position.y - self.diameter / 2,
                                 width: self.diameter, height: self.diameter)
        self.ball.layer.cornerRadius = self.diameter / 2
        self.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.stop()
    }

    private func start() {
        guard self.link == nil else { return }
        self.lastStamp = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(self.tick))
        // The source runs from Choreographer at the display refresh rate. The
        // game is not visual-critical, so cap it at 60 fps on ProMotion devices
        // instead of waking the main thread 120 times a second.
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 60.0, preferred: 60.0)
        }
        link.add(to: .main, forMode: .common)
        self.link = link
        self.lightFeedback.prepare()
        self.mediumFeedback.prepare()
        self.startTilt()
    }

    private func stop() {
        self.link?.invalidate()
        self.link = nil
        self.motion.stopDeviceMotionUpdates()
    }

    /// Source `set_gyro(on)`: reset to plain downward gravity, then let the
    /// sensor steer the ball. CoreMotion gravity points down in g while Android's
    /// gravity sensor reports the opposite in m/s², so the source targets map to
    /// +x and -y here.
    private func startTilt() {
        guard self.usesTilt, self.motion.isDeviceMotionAvailable, !self.motion.isDeviceMotionActive else { return }
        self.tiltX = 0
        self.tiltY = 1
        self.filteredTiltX = 0
        self.filteredTiltY = 1
        self.motion.deviceMotionUpdateInterval = 1.0 / 60.0
        self.motion.startDeviceMotionUpdates(to: .main, withHandler: { [weak self] data, _ in
            guard let self, let gravity = data?.gravity else { return }
            self.applyTilt(x: CGFloat(gravity.x), y: CGFloat(gravity.y))
        })
    }

    /// Source `_on_tilt(ax, ay)`: the same ×0.2 filter, ±0.05 dead zone and
    /// ±1.5 clamp, applied to the converted CoreMotion gravity vector.
    private func applyTilt(x: CGFloat, y: CGFloat) {
        self.filteredTiltX += (x - self.filteredTiltX) * 0.2
        self.filteredTiltY += (-y - self.filteredTiltY) * 0.2
        let dead = abs(self.filteredTiltX) - 0.05
        if dead > 0 {
            self.tiltX = (self.filteredTiltX < 0 ? -1 : 1) * min(dead, 1.5)
        } else {
            self.tiltX = 0
        }
        self.tiltY = max(-1.5, min(self.filteredTiltY, 1.5))
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let delta = min(0.05, max(0.001, now - self.lastStamp))
        self.lastStamp = now
        self.velocity.dx += self.gravity * self.tiltX * CGFloat(delta)
        self.velocity.dy += self.gravity * self.tiltY * CGFloat(delta)
        self.position.x += self.velocity.dx * CGFloat(delta)
        self.position.y += self.velocity.dy * CGFloat(delta)
        self.resolveCollisions()
        self.ball.center = self.position
        self.ball.rotation += CGFloat(delta) * self.velocity.dx / max(30, self.diameter)
        self.updateComboPosition(now: now)
    }

    private func resolveCollisions() {
        let radius = self.diameter / 2
        let bounds = self.view.bounds.inset(by: self.view.safeAreaInsets)
        var bounced = false
        if self.position.x - radius < bounds.minX { self.position.x = bounds.minX + radius; self.velocity.dx = abs(self.velocity.dx) * self.restitution; bounced = true }
        if self.position.x + radius > bounds.maxX { self.position.x = bounds.maxX - radius; self.velocity.dx = -abs(self.velocity.dx) * self.restitution; bounced = true }
        if self.position.y - radius < bounds.minY { self.position.y = bounds.minY + radius; self.velocity.dy = abs(self.velocity.dy) * self.restitution; bounced = true }
        if self.position.y + radius > bounds.maxY {
            self.position.y = bounds.maxY - radius
            self.velocity.dy = -abs(self.velocity.dy) * self.restitution
            self.velocity.dx *= 0.985
            bounced = true
            if abs(self.velocity.dy) < 60 {
                self.velocity.dy = 0
                self.velocity.dx *= 0.96
            }
        }
        if bounced {
            self.registerHit()
        }
    }

    private func registerHit() {
        let now = CACurrentMediaTime()
        if now - self.lastHit > 1.6 {
            self.combo = 0
        }
        self.combo += 1
        self.lastHit = now
        if self.showsCounter {
            self.comboLabel.text = "X\(self.combo)"
            self.comboLabel.sizeToFit()
            self.comboLabel.isHidden = false
            self.comboLabel.alpha = 1.0
            self.comboLabel.transform = CGAffineTransform(scaleX: 1.7, y: 1.7)
            self.updateComboPosition(now: now)
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.comboLabel.transform = .identity
            }
        }
        if abs(self.velocity.dy) + abs(self.velocity.dx) > 500 {
            self.lightFeedback.impactOccurred()
            self.lightFeedback.prepare()
        }
    }

    /// Mirrors the source `X%d` label: it follows the ball and fades out after
    /// COMBO_TIMEOUT (1.6 s) plus the same 0.5 s fade window.
    private func updateComboPosition(now: CFTimeInterval) {
        guard self.showsCounter, !self.comboLabel.isHidden else { return }
        let radius = self.diameter / 2
        let x = min(max(self.position.x, 60), self.view.bounds.width - 60)
        let y = min(max(self.position.y - radius - 36, 60), self.view.bounds.height - 100)
        self.comboLabel.center = CGPoint(x: x, y: y)
        let idle = now - self.lastHit
        if idle > 1.6 {
            let alpha = 1.0 - (idle - 1.6) / 0.5
            if alpha <= 0 {
                self.comboLabel.isHidden = true
                self.combo = 0
            } else {
                self.comboLabel.alpha = CGFloat(alpha)
            }
        }
    }

    private func clampPosition() {
        let radius = self.diameter / 2
        let bounds = self.view.bounds.inset(by: self.view.safeAreaInsets)
        guard bounds.width > radius * 2, bounds.height > radius * 2 else { return }
        self.position.x = min(max(self.position.x, bounds.minX + radius), bounds.maxX - radius)
        self.position.y = min(max(self.position.y, bounds.minY + radius), bounds.maxY - radius)
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self.view)
        self.kick(from: point)
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            let translation = gesture.translation(in: self.view)
            self.position = CGPoint(x: self.position.x + translation.x, y: self.position.y + translation.y)
            gesture.setTranslation(.zero, in: self.view)
            self.clampPosition()
            self.ball.center = self.position
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: self.view)
            self.velocity = CGVector(dx: max(-1800, min(1800, velocity.x)) * 0.6,
                                     dy: max(-1800, min(1800, velocity.y)) * 0.6)
            if abs(self.velocity.dx) + abs(self.velocity.dy) < 120 { self.kick(from: self.ball.center) }
        default:
            break
        }
    }

    private func kick(from point: CGPoint) {
        var dx = self.position.x - point.x
        var dy = self.position.y - point.y
        let length = max(1, hypot(dx, dy))
        dx /= length; dy /= length
        let power: CGFloat = 900
        self.velocity = CGVector(dx: dx * power, dy: dy * power - 120)
        if abs(dx) < 0.05 { self.velocity.dx = Bool.random() ? 260 : -260 }
        self.mediumFeedback.impactOccurred()
        self.mediumFeedback.prepare()
    }

    @objc private func closePressed() { self.dismiss(animated: true) }

}

@MainActor
final class AyuBallView: UIView {
    var rotation: CGFloat = 0 {
        didSet { self.setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.isOpaque = false
        self.backgroundColor = .clear
    }
    required init?(coder: NSCoder) { return nil }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let bounds = self.bounds.insetBy(dx: 2, dy: 2)
        context.saveGState()
        context.translateBy(x: self.bounds.midX, y: self.bounds.midY)
        context.rotate(by: self.rotation)
        context.addEllipse(in: CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: bounds.width, height: bounds.height))
        context.clip()
        let colors = [UIColor(red: 1, green: 0.62, blue: 0.2, alpha: 1).cgColor,
                      UIColor(red: 0.9, green: 0.2, blue: 0.24, alpha: 1).cgColor]
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: -bounds.width / 2, y: -bounds.height / 2),
                                       end: CGPoint(x: bounds.width / 2, y: bounds.height / 2), options: [])
        }
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(2)
        context.addEllipse(in: CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: bounds.width, height: bounds.height))
        context.strokePath()
        let line = UIBezierPath()
        line.move(to: CGPoint(x: -bounds.width / 2 + 6, y: 0))
        line.addQuadCurve(to: CGPoint(x: bounds.width / 2 - 6, y: 0), controlPoint: CGPoint(x: 0, y: -bounds.height / 3))
        context.addPath(line.cgPath)
        context.strokePath()
        context.restoreGState()
    }
}
