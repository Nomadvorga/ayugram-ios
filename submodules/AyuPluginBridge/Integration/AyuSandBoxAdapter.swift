import Foundation
import UIKit

// MARK: - Element model

enum AyuSandElement: UInt8, CaseIterable {
    case empty, wall, stone, sand, dirt, gunpowder, snow, seed, ash, water
    case oil, acid, alkali, mercury, lava, steam, smoke, gas, wood, coal
    case tnt, ice, plant, fungus, wire, battery, lamp, glass, salt, fire
    case bolt, spark

    enum Kind { case empty, solid, powder, liquid, gas, fire, energy }

    var name: String {
        switch self {
        case .empty: return "Ластик"; case .wall: return "Стена"; case .stone: return "Камень"
        case .sand: return "Песок"; case .dirt: return "Земля"; case .gunpowder: return "Порох"
        case .snow: return "Снег"; case .seed: return "Семя"; case .ash: return "Пепел"
        case .water: return "Вода"; case .oil: return "Масло"; case .acid: return "Кислота"
        case .alkali: return "Щёлочь"; case .mercury: return "Ртуть"; case .lava: return "Лава"
        case .steam: return "Пар"; case .smoke: return "Дым"; case .gas: return "Газ"
        case .wood: return "Дерево"; case .coal: return "Уголь"; case .tnt: return "Динамит"
        case .ice: return "Лёд"; case .plant: return "Растение"; case .fungus: return "Грибок"
        case .wire: return "Провод"; case .battery: return "Батарея"; case .lamp: return "Лампа"
        case .glass: return "Стекло"; case .salt: return "Соль"; case .fire: return "Огонь"
        case .bolt: return "Молния"; case .spark: return "Искра"
        }
    }

    /// Exact emoji declared by the audited source. The Android build renders
    /// SVG icons, so iOS shows the source emoji over the element colour as the
    /// closest native palette tile.
    var emoji: String {
        switch self {
        case .empty: return "🚫"; case .wall: return "🧱"; case .stone: return "🪨"
        case .sand: return "⏳"; case .dirt: return "🟤"; case .gunpowder: return "💥"
        case .snow: return "❄️"; case .seed: return "🌰"; case .ash: return "🌫"
        case .water: return "💧"; case .oil: return "🛢"; case .acid: return "🧪"
        case .alkali: return "🥛"; case .mercury: return "⚪"; case .lava: return "🌋"
        case .steam: return "☁️"; case .smoke: return "💨"; case .gas: return "🫧"
        case .wood: return "🪵"; case .coal: return "⚫"; case .tnt: return "🧨"
        case .ice: return "🧊"; case .plant: return "🌿"; case .fungus: return "🍄"
        case .wire: return "🔌"; case .battery: return "🔋"; case .lamp: return "💡"
        case .glass: return "🔮"; case .salt: return "🧂"; case .fire: return "🔥"
        case .bolt: return "⚡"; case .spark: return "✨"
        }
    }

    var color: UIColor {
        switch self {
        case .empty: return UIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        case .wall: return UIColor(red: 0.42, green: 0.42, blue: 0.46, alpha: 1)
        case .stone: return UIColor(red: 0.48, green: 0.48, blue: 0.49, alpha: 1)
        case .sand: return UIColor(red: 0.86, green: 0.75, blue: 0.49, alpha: 1)
        case .dirt: return UIColor(red: 0.48, green: 0.34, blue: 0.22, alpha: 1)
        case .gunpowder: return UIColor(red: 0.25, green: 0.25, blue: 0.26, alpha: 1)
        case .snow: return UIColor(red: 0.92, green: 0.95, blue: 1, alpha: 1)
        case .seed: return UIColor(red: 0.54, green: 0.39, blue: 0.22, alpha: 1)
        case .ash: return UIColor(red: 0.43, green: 0.42, blue: 0.4, alpha: 1)
        case .water: return UIColor(red: 0.2, green: 0.48, blue: 0.95, alpha: 1)
        case .oil: return UIColor(red: 0.5, green: 0.4, blue: 0.14, alpha: 1)
        case .acid: return UIColor(red: 0.6, green: 0.9, blue: 0.3, alpha: 1)
        case .alkali: return UIColor(red: 0.88, green: 0.9, blue: 0.95, alpha: 1)
        case .mercury: return UIColor(red: 0.72, green: 0.74, blue: 0.78, alpha: 1)
        case .lava: return UIColor(red: 1, green: 0.48, blue: 0.1, alpha: 1)
        case .steam: return UIColor(red: 0.78, green: 0.78, blue: 0.85, alpha: 1)
        case .smoke: return UIColor(red: 0.32, green: 0.32, blue: 0.35, alpha: 1)
        case .gas: return UIColor(red: 0.62, green: 0.82, blue: 0.62, alpha: 1)
        case .wood: return UIColor(red: 0.43, green: 0.3, blue: 0.18, alpha: 1)
        case .coal: return UIColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)
        case .tnt: return UIColor(red: 0.78, green: 0.22, blue: 0.18, alpha: 1)
        case .ice: return UIColor(red: 0.64, green: 0.85, blue: 0.98, alpha: 1)
        case .plant: return UIColor(red: 0.35, green: 0.74, blue: 0.39, alpha: 1)
        case .fungus: return UIColor(red: 0.75, green: 0.45, blue: 0.75, alpha: 1)
        case .wire: return UIColor(red: 0.85, green: 0.68, blue: 0.25, alpha: 1)
        case .battery: return UIColor(red: 0.25, green: 0.62, blue: 0.35, alpha: 1)
        case .lamp: return UIColor(red: 1, green: 0.9, blue: 0.42, alpha: 1)
        case .glass: return UIColor(red: 0.62, green: 0.82, blue: 0.91, alpha: 1)
        case .salt: return UIColor(red: 0.92, green: 0.94, blue: 0.97, alpha: 1)
        case .fire: return UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)
        case .bolt: return UIColor(red: 1, green: 0.92, blue: 0.4, alpha: 1)
        case .spark: return UIColor(red: 1, green: 0.82, blue: 0.3, alpha: 1)
        }
    }

    var kind: Kind {
        switch self {
        case .empty: return .empty
        case .wall, .stone, .wood, .coal, .glass, .battery, .wire, .lamp, .tnt: return .solid
        case .sand, .dirt, .gunpowder, .snow, .seed, .ash, .salt: return .powder
        case .water, .oil, .acid, .alkali, .mercury, .lava: return .liquid
        case .steam, .smoke, .gas: return .gas
        case .fire: return .fire
        case .bolt, .spark: return .energy
        case .ice, .plant, .fungus: return .solid
        }
    }

    var density: Int {
        switch self {
        case .sand: return 4; case .dirt: return 5; case .salt: return 4; case .ash: return 3
        case .gunpowder: return 4; case .seed: return 3
        case .water: return 3; case .oil: return 2; case .acid: return 2; case .alkali: return 2
        case .mercury: return 8; case .lava: return 7
        default: return 1
        }
    }

    var isFlammable: Bool {
        switch self {
        case .wood, .coal, .oil, .gas, .plant, .fungus, .seed, .tnt, .gunpowder: return true
        default: return false
        }
    }

    var isLiquidLike: Bool { self.kind == .liquid }
    var isGasLike: Bool { self.kind == .gas }
}

// MARK: - Adapter

@MainActor
final class AyuSandBoxAdapter: AyuNativePluginAdapter {
    private(set) var isEnabled = false
    var commandEnabled: Bool { self.isEnabled && self.boolValue("enabled", default: true) }
    override var actionTitle: String? { self.isEnabled ? "Открыть песочницу" : nil }

    init(defaults: UserDefaults, reportError: @escaping (String?) -> Void) {
        super.init(pluginID: "sand_box", defaults: defaults, reportError: reportError)
    }

    override func enable() throws {
        self.isEnabled = true
        self.reportError(nil)
        AyuNativePluginRuntime.shared.sandBox = self
    }

    override func disable() {
        self.isEnabled = false
        if AyuNativePluginRuntime.shared.sandBox === self { AyuNativePluginRuntime.shared.sandBox = nil }
    }

    // Audited source constants: GRID_WIDTHS[1] = 150, SPEED_STEPS[0] = ×1.
    var gridWidth: Int { 150 }
    var speed: Int { 1 }

    override func settings() throws -> [AyuPluginSetting] {
        return [
            self.staticRow("Header", "SandBox"),
            self.textRow("Открыть песочницу", subtext: "Полноэкранная игра с палитрой элементов", action: "sand_box.open"),
            self.staticRow("Divider", "Команда .sand в поле ввода открывает игру вместо отправки сообщения."),
            self.staticRow("Divider", "Рисуйте песок, воду, огонь и другие элементы. Симуляция остаётся внутри приложения и не запускает Android/JS-код."),
        ]
    }

    override func set(_ row: AyuPluginSetting, value: AyuBridgeValue) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        throw AyuPluginService.Failure.operation("INVALID_SETTING")
    }

    override func activate(_ row: AyuPluginSetting, presenter: UIViewController?, completion: @escaping () -> Void) throws {
        guard self.isEnabled else { throw AyuPluginService.Failure.inactive }
        if row.descriptor["native_action"].string == "sand_box.open" {
            guard let presenter else { throw AyuPluginService.Failure.inactive }
            self.open(from: presenter)
        }
        completion()
    }

    override func open(from presenter: UIViewController) {
        guard self.isEnabled else { return }
        let controller = AyuSandBoxViewController(adapter: self)
        controller.modalPresentationStyle = .fullScreen
        presenter.present(controller, animated: true)
    }

    func savedScene() -> String { self.stringValue("scene_v1", default: "") }
    func saveScene(_ value: String) { try? self.setValue(.string(value), for: "scene_v1") }
}

// MARK: - Game controller

@MainActor
final class AyuSandBoxViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    private let adapter: AyuSandBoxAdapter
    private let canvas: AyuSandCanvas
    private let palette: UICollectionView
    private let pauseButton = UIButton(type: .system)
    private let speedButton = UIButton(type: .system)
    private let brushSlider = UISlider()
    private let brushLabel = UILabel()
    private var paused = false
    private var speed: Int

    init(adapter: AyuSandBoxAdapter) {
        self.adapter = adapter
        self.speed = adapter.speed
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 68, height: 48)
        layout.minimumLineSpacing = 6
        layout.minimumInteritemSpacing = 6
        layout.sectionInset = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        self.palette = UICollectionView(frame: .zero, collectionViewLayout: layout)
        self.canvas = AyuSandCanvas(width: adapter.gridWidth)
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        self.canvas.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(self.canvas)

        let top = UIStackView()
        top.axis = .horizontal
        top.alignment = .center
        top.spacing = 6
        top.translatesAutoresizingMaskIntoConstraints = false
        top.addArrangedSubview(self.button("×", action: #selector(self.closePressed)))
        top.addArrangedSubview(self.button("Очистить", action: #selector(self.clearPressed)))
        top.addArrangedSubview(self.button("Демо", action: #selector(self.demoPressed)))
        self.pauseButton.setTitle("Пауза", for: .normal)
        self.pauseButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        self.pauseButton.addTarget(self, action: #selector(self.pausePressed), for: .touchUpInside)
        top.addArrangedSubview(self.pauseButton)
        self.speedButton.setTitle("×\(self.speed)", for: .normal)
        self.speedButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        self.speedButton.addTarget(self, action: #selector(self.speedPressed), for: .touchUpInside)
        top.addArrangedSubview(self.speedButton)
        top.addArrangedSubview(self.button("Сохранить", action: #selector(self.savePressed)))
        top.addArrangedSubview(self.button("Загрузить", action: #selector(self.loadPressed)))
        self.view.addSubview(top)

        self.brushLabel.text = "Кисть 3"
        self.brushLabel.textColor = .secondaryLabel
        self.brushLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        self.brushLabel.translatesAutoresizingMaskIntoConstraints = false
        self.brushSlider.minimumValue = 1
        self.brushSlider.maximumValue = 16
        self.brushSlider.value = 3
        self.brushSlider.translatesAutoresizingMaskIntoConstraints = false
        self.brushSlider.addTarget(self, action: #selector(self.brushChanged), for: .valueChanged)
        self.view.addSubview(self.brushLabel)
        self.view.addSubview(self.brushSlider)

        self.palette.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.11, alpha: 1)
        self.palette.dataSource = self
        self.palette.delegate = self
        self.palette.register(AyuSandPaletteCell.self, forCellWithReuseIdentifier: "element")
        self.palette.translatesAutoresizingMaskIntoConstraints = false
        self.palette.showsHorizontalScrollIndicator = false
        self.view.addSubview(self.palette)

        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 4),
            top.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 8),
            top.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -8),
            self.canvas.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 6),
            self.canvas.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.canvas.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.brushLabel.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 12),
            self.brushLabel.centerYAnchor.constraint(equalTo: self.brushSlider.centerYAnchor),
            self.brushLabel.widthAnchor.constraint(equalToConstant: 64),
            self.brushSlider.leadingAnchor.constraint(equalTo: self.brushLabel.trailingAnchor, constant: 8),
            self.brushSlider.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -12),
            self.brushSlider.topAnchor.constraint(equalTo: self.canvas.bottomAnchor, constant: 4),
            self.palette.topAnchor.constraint(equalTo: self.brushSlider.bottomAnchor, constant: 4),
            self.palette.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.palette.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.palette.heightAnchor.constraint(equalToConstant: 112),
            self.palette.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor),
        ])
        self.canvas.onFPS = { [weak self] value in
            self?.brushLabel.text = "Кисть \(Int(self?.brushSlider.value ?? 3)) · \(value)"
        }
        self.canvas.start()
        if let saved = self.restoreScene() { self.canvas.load(saved) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.canvas.stop()
    }

    private func button(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func closePressed() { self.dismiss(animated: true) }
    @objc private func clearPressed() {
        self.canvas.clear()
        AyuNativePluginRuntime.shared.showMessage("Поле очищено", style: "simple")
    }

    @objc private func demoPressed() {
        self.canvas.demo()
        AyuNativePluginRuntime.shared.showMessage("Демо-сцена построена", style: "simple")
    }

    @objc private func pausePressed() {
        self.paused.toggle()
        self.canvas.isPaused = self.paused
        self.pauseButton.setTitle(self.paused ? "Играть" : "Пауза", for: .normal)
    }

    @objc private func speedPressed() {
        self.speed = self.speed == 1 ? 2 : (self.speed == 2 ? 4 : 1)
        self.canvas.stepsPerFrame = self.speed
        self.speedButton.setTitle("×\(self.speed)", for: .normal)
    }

    @objc private func brushChanged() {
        self.canvas.brush = max(1, Int(self.brushSlider.value.rounded()))
        self.brushLabel.text = "Кисть \(self.canvas.brush)"
    }

    @objc private func savePressed() {
        let scene = self.canvas.encoded()
        self.adapter.saveScene(scene)
        AyuNativePluginRuntime.shared.showMessage("Сцена сохранена", style: "success")
    }

    @objc private func loadPressed() {
        guard !self.adapter.savedScene().isEmpty else {
            AyuNativePluginRuntime.shared.showMessage("Сохранений пока нет", style: "error")
            return
        }
        if let saved = self.restoreScene() {
            self.canvas.load(saved)
            AyuNativePluginRuntime.shared.showMessage("Сцена загружена", style: "success")
        }
    }

    private func restoreScene() -> String? {
        let value = self.adapter.savedScene()
        return value.isEmpty ? nil : value
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        AyuSandElement.allCases.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "element", for: indexPath) as! AyuSandPaletteCell
        let element = AyuSandElement.allCases[indexPath.item]
        cell.configure(element: element, selected: self.canvas.selected == element)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        self.canvas.selected = AyuSandElement.allCases[indexPath.item]
        collectionView.reloadData()
    }
}

@MainActor
final class AyuSandPaletteCell: UICollectionViewCell {
    private let swatch = UIView()
    private let glyph = UILabel()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.contentView.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
        self.contentView.layer.cornerRadius = 9
        self.contentView.layer.borderWidth = 1
        self.contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        self.swatch.translatesAutoresizingMaskIntoConstraints = false
        self.swatch.layer.cornerRadius = 6
        self.label.translatesAutoresizingMaskIntoConstraints = false
        self.label.font = .systemFont(ofSize: 9, weight: .medium)
        self.label.textColor = .secondaryLabel
        self.label.textAlignment = .center
        self.label.adjustsFontSizeToFitWidth = true
        self.label.minimumScaleFactor = 0.7
        self.glyph.translatesAutoresizingMaskIntoConstraints = false
        self.glyph.font = .systemFont(ofSize: 15)
        self.glyph.textAlignment = .center
        self.contentView.addSubview(self.swatch)
        self.swatch.addSubview(self.glyph)
        self.contentView.addSubview(self.label)
        NSLayoutConstraint.activate([
            self.swatch.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 5),
            self.swatch.centerXAnchor.constraint(equalTo: self.contentView.centerXAnchor),
            self.swatch.widthAnchor.constraint(equalToConstant: 22),
            self.swatch.heightAnchor.constraint(equalToConstant: 22),
            self.glyph.centerXAnchor.constraint(equalTo: self.swatch.centerXAnchor),
            self.glyph.centerYAnchor.constraint(equalTo: self.swatch.centerYAnchor),
            self.label.topAnchor.constraint(equalTo: self.swatch.bottomAnchor, constant: 2),
            self.label.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 2),
            self.label.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { return nil }

    func configure(element: AyuSandElement, selected: Bool) {
        self.swatch.backgroundColor = element.color.withAlphaComponent(0.32)
        self.swatch.layer.cornerRadius = 6
        self.glyph.text = element.emoji
        self.label.text = element.name
        self.contentView.layer.borderColor = (selected ? UIColor.systemYellow : UIColor.white.withAlphaComponent(0.08)).cgColor
        self.contentView.layer.borderWidth = selected ? 2 : 1
    }
}

// MARK: - Canvas / simulation

@MainActor
final class AyuSandCanvas: UIView {
    private(set) var width: Int
    private(set) var height: Int
    private var cells: [UInt8]
    private var life: [UInt8]
    private var variant: [UInt8]
    private var moved: [Bool]
    private var powered: [Bool]
    var brush = 3
    var selected: AyuSandElement = .water
    var stepsPerFrame = 1
    var isPaused = false
    var onFPS: ((Int) -> Void)?

    private var link: CADisplayLink?
    private var frames = 0
    private var frameStamp = CACurrentMediaTime()
    private var lastPoint: CGPoint?

    init(width: Int) {
        self.width = max(60, min(240, width))
        self.height = Int((Double(self.width) * 1.66).rounded())
        let count = self.width * self.height
        self.cells = [UInt8](repeating: 0, count: count)
        self.life = [UInt8](repeating: 0, count: count)
        self.variant = [UInt8](repeating: 0, count: count)
        self.moved = [Bool](repeating: false, count: count)
        self.powered = [Bool](repeating: false, count: count)
        super.init(frame: .zero)
        self.backgroundColor = AyuSandElement.empty.color
        self.isMultipleTouchEnabled = false
        self.clipsToBounds = true
        for index in 0..<count { self.variant[index] = UInt8.random(in: 0...3) }
    }
    required init?(coder: NSCoder) { return nil }

    isolated deinit { self.link?.invalidate() }

    func start() {
        guard self.link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(self.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        self.link?.invalidate()
        self.link = nil
    }

    @objc private func tick() {
        if !self.isPaused {
            for _ in 0..<max(1, self.stepsPerFrame) { self.step() }
        }
        self.setNeedsDisplay()
        self.frames += 1
        let now = CACurrentMediaTime()
        if now - self.frameStamp >= 1 {
            self.onFPS?(self.frames)
            self.frames = 0
            self.frameStamp = now
        }
    }

    // MARK: Painting

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        self.lastPoint = touch.location(in: self)
        self.paint(at: self.lastPoint!)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        if let last = self.lastPoint {
            let steps = max(1, Int(hypot(point.x - last.x, point.y - last.y) / 3))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                self.paint(at: CGPoint(x: last.x + (point.x - last.x) * t, y: last.y + (point.y - last.y) * t))
            }
        } else {
            self.paint(at: point)
        }
        self.lastPoint = point
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { self.lastPoint = nil }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { self.lastPoint = nil }

    private func paint(at point: CGPoint) {
        guard self.bounds.width > 0, self.bounds.height > 0 else { return }
        let cellWidth = self.bounds.width / CGFloat(self.width)
        let cellHeight = self.bounds.height / CGFloat(self.height)
        let centerX = Int(point.x / max(1, cellWidth))
        let centerY = Int(point.y / max(1, cellHeight))
        let radius = max(0, self.brush - 1)
        for dy in -radius...radius {
            for dx in -radius...radius {
                guard dx * dx + dy * dy <= radius * radius + 1 else { continue }
                let x = centerX + dx, y = centerY + dy
                guard x >= 0, x < self.width, y >= 0, y < self.height else { continue }
                let index = y * self.width + x
                if self.selected == .empty {
                    self.cells[index] = 0; self.life[index] = 0
                } else {
                    self.cells[index] = self.selected.rawValue
                    self.life[index] = self.selected == .fire ? 100 : (self.selected == .spark ? 24 : 0)
                }
            }
        }
    }

    // MARK: Simulation

    private func index(_ x: Int, _ y: Int) -> Int { y * self.width + x }
    private func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < self.width && y >= 0 && y < self.height }
    private func element(_ index: Int) -> AyuSandElement { AyuSandElement(rawValue: self.cells[index]) ?? .empty }

    private func canSwap(_ source: AyuSandElement, _ target: AyuSandElement) -> Bool {
        if target.kind == .empty { return true }
        if source.kind == .powder && (target.isLiquidLike || target.isGasLike) { return source.density > target.density }
        if source.isLiquidLike && target.isGasLike { return source.density > target.density }
        return false
    }

    private func swap(_ a: Int, _ b: Int) {
        self.cells.swapAt(a, b); self.life.swapAt(a, b); self.variant.swapAt(a, b)
    }

    private func set(_ index: Int, _ element: AyuSandElement, life: UInt8 = 0) {
        self.cells[index] = element.rawValue; self.life[index] = life
    }

    func step() {
        self.moved = [Bool](repeating: false, count: self.cells.count)
        self.powered = [Bool](repeating: false, count: self.cells.count)
        self.updatePower()
        for y in stride(from: self.height - 1, through: 0, by: -1) {
            let leftToRight = Bool.random()
            for offset in 0..<self.width {
                let x = leftToRight ? offset : self.width - 1 - offset
                let i = self.index(x, y)
                guard !self.moved[i] else { continue }
                let current = self.element(i)
                switch current.kind {
                case .powder: self.stepPowder(x: x, y: y, i: i, element: current)
                case .liquid: self.stepLiquid(x: x, y: y, i: i, element: current)
                case .gas: self.reactAndMoveGas(x: x, y: y, i: i, element: current)
                case .fire, .energy: self.reactFire(x: x, y: y, i: i, element: current)
                case .solid: self.reactSolid(x: x, y: y, i: i, element: current)
                case .empty: break
                }
            }
        }
    }

    private func stepPowder(x: Int, y: Int, i: Int, element: AyuSandElement) {
        if element == .seed {
            self.reactSeed(x: x, y: y, i: i)
            if self.element(i) != .seed { return }
        }
        if element == .snow && self.nearFire(x: x, y: y) {
            self.set(i, .water); return
        }
        if element == .salt, self.nearElement(x: x, y: y, .water) {
            if let water = self.neighborIndex(x: x, y: y, matching: .water) {
                self.set(water, .water)
                self.set(i, .empty)
            }
            return
        }
        guard y + 1 < self.height else { return }
        let below = self.index(x, y + 1)
        if self.canSwap(element, self.element(below)) { self.swap(i, below); self.moved[below] = true; return }
        let direction = Bool.random() ? 1 : -1
        for dx in [direction, -direction] {
            let nx = x + dx
            guard self.inside(nx, y + 1) else { continue }
            let target = self.index(nx, y + 1)
            if self.canSwap(element, self.element(target)) { self.swap(i, target); self.moved[target] = true; return }
        }
    }

    private func stepLiquid(x: Int, y: Int, i: Int, element: AyuSandElement) {
        if element == .lava {
            if self.nearElement(x: x, y: y, .water) {
                self.set(i, .stone)
                if let water = self.neighborIndex(x: x, y: y, matching: .water) { self.set(water, .steam, life: 120) }
                return
            }
            _ = self.igniteNeighbors(x: x, y: y)
        }
        if element == .acid {
            if let solid = self.neighborIndex(x: x, y: y, where: { $0.kind == .solid && $0 != .glass && $0 != .battery }) {
                self.set(solid, .empty)
                if Int.random(in: 0..<3) == 0 { self.set(i, .empty) }
                return
            }
        }
        if y + 1 < self.height {
            let below = self.index(x, y + 1)
            if self.canSwap(element, self.element(below)) { self.swap(i, below); self.moved[below] = true; return }
            let direction = Bool.random() ? 1 : -1
            for dx in [direction, -direction] {
                let nx = x + dx
                if self.inside(nx, y + 1), self.canSwap(element, self.element(self.index(nx, y + 1))) {
                    let target = self.index(nx, y + 1); self.swap(i, target); self.moved[target] = true; return
                }
            }
        }
        let direction = Bool.random() ? 1 : -1
        for distance in 1...4 {
            let nx = x + direction * distance
            guard self.inside(nx, y) else { break }
            let target = self.index(nx, y)
            if self.canSwap(element, self.element(target)) { self.swap(i, target); self.moved[target] = true; return }
            if self.element(target).kind != .empty { break }
        }
    }

    private func reactAndMoveGas(x: Int, y: Int, i: Int, element: AyuSandElement) {
        if element.isFlammable && self.nearFire(x: x, y: y) { self.set(i, .fire, life: 60); return }
        if y > 0 {
            let above = self.index(x, y - 1)
            if self.canSwap(element, self.element(above)) { self.swap(i, above); self.moved[above] = true; return }
            let direction = Bool.random() ? 1 : -1
            for dx in [direction, -direction] {
                let nx = x + dx
                if self.inside(nx, y - 1), self.canSwap(element, self.element(self.index(nx, y - 1))) {
                    let target = self.index(nx, y - 1); self.swap(i, target); self.moved[target] = true; return
                }
            }
        }
        if Int.random(in: 0..<6) == 0 {
            let nx = x + (Bool.random() ? 1 : -1)
            if self.inside(nx, y), self.element(self.index(nx, y)).kind == .empty {
                let target = self.index(nx, y); self.swap(i, target); self.moved[target] = true
            }
        }
    }

    private func reactFire(x: Int, y: Int, i: Int, element: AyuSandElement) {
        let decrement: UInt8 = element == .bolt ? 8 : (element == .spark ? 4 : 3)
        self.life[i] = self.life[i] > decrement ? self.life[i] - decrement : 0
        if self.life[i] == 0 {
            self.set(i, element == .fire ? (Int.random(in: 0..<3) == 0 ? .ash : .smoke) : .empty, life: element == .fire ? 80 : 0)
            return
        }
        if element == .fire || element == .bolt {
            if let water = self.neighborIndex(x: x, y: y, matching: .water) {
                self.set(water, .steam, life: 140)
                self.set(i, .smoke, life: 60)
                return
            }
            if element == .bolt || (element == .fire && Int.random(in: 0..<5) == 0) {
                self.igniteNeighbors(x: x, y: y)
            }
            if element == .bolt {
                self.explode(x: x, y: y, radius: 2)
                self.set(i, .empty)
            }
        }
    }

    private func reactSolid(x: Int, y: Int, i: Int, element: AyuSandElement) {
        if element == .tnt && self.nearFire(x: x, y: y) {
            self.explode(x: x, y: y, radius: 5); return
        }
        if element == .ice && self.nearFire(x: x, y: y) {
            if Int.random(in: 0..<4) == 0 { self.set(i, .water) }
        }
        if element == .plant {
            if self.nearElement(x: x, y: y, .water) && Int.random(in: 0..<40) == 0 {
                let nx = x + Int.random(in: -1...1), ny = y - 1
                if self.inside(nx, ny), self.element(self.index(nx, ny)).kind == .empty { self.set(self.index(nx, ny), .plant) }
            }
            if self.nearFire(x: x, y: y) { self.set(i, .fire, life: 50) }
        }
        if element == .fungus && self.nearFire(x: x, y: y) { self.set(i, .fire, life: 40) }
        if element == .wood && self.nearFire(x: x, y: y) && Int.random(in: 0..<3) == 0 { self.set(i, .fire, life: 70) }
        if element == .coal && self.nearFire(x: x, y: y) && Int.random(in: 0..<4) == 0 { self.set(i, .fire, life: 100) }
        if element == .lamp && self.powered[i] { self.life[i] = 30 }
        if element == .lamp && self.life[i] > 0 { self.life[i] -= 1 }
    }

    private func reactSeed(x: Int, y: Int, i: Int) {
        guard y + 1 < self.height else { return }
        let below = self.element(self.index(x, y + 1))
        if below == .dirt && self.nearElement(x: x, y: y, .water) && Int.random(in: 0..<24) == 0 {
            self.set(i, .plant)
        }
    }

    private func updatePower() {
        var wires: [Int] = []
        for i in self.cells.indices where self.element(i) == .wire { wires.append(i) }
        var changed = true
        var rounds = 0
        while changed && rounds < 12 {
            changed = false
            for i in wires where !self.powered[i] {
                let x = i % self.width, y = i / self.width
                if self.hasNeighbor(x: x, y: y, matching: .battery) || self.hasNeighbor(x: x, y: y, where: { self.powered[$0] }) {
                    self.powered[i] = true; changed = true
                }
            }
            rounds += 1
        }
        for i in self.cells.indices where self.element(i) == .lamp {
            let x = i % self.width, y = i / self.width
            if self.hasNeighbor(x: x, y: y, where: { self.element($0) == .wire && self.powered[$0] }) { self.powered[i] = true }
        }
    }

    private func neighborIndex(x: Int, y: Int, where predicate: (AyuSandElement) -> Bool) -> Int? {
        for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
            let nx = x + dx, ny = y + dy
            guard self.inside(nx, ny) else { continue }
            let index = self.index(nx, ny)
            if predicate(self.element(index)) { return index }
        }
        return nil
    }

    private func neighborIndex(x: Int, y: Int, matching element: AyuSandElement) -> Int? {
        self.neighborIndex(x: x, y: y, where: { $0 == element })
    }

    private func nearElement(x: Int, y: Int, _ element: AyuSandElement) -> Bool {
        self.neighborIndex(x: x, y: y, matching: element) != nil
    }

    private func nearFire(x: Int, y: Int) -> Bool {
        self.hasNeighbor(x: x, y: y, where: { $0 == .fire || $0 == .lava || $0 == .spark })
    }

    private func hasNeighbor(x: Int, y: Int, matching element: AyuSandElement) -> Bool {
        self.hasNeighbor(x: x, y: y, where: { $0 == element })
    }

    private func hasNeighbor(x: Int, y: Int, where predicate: (Int) -> Bool) -> Bool {
        for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
            let nx = x + dx, ny = y + dy
            guard self.inside(nx, ny) else { continue }
            if predicate(self.index(nx, ny)) { return true }
        }
        return false
    }

    @discardableResult
    private func igniteNeighbors(_ x: Int, _ y: Int) -> Bool {
        var ignited = false
        for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0), (1, 1), (-1, 1), (1, -1), (-1, -1)] {
            let nx = x + dx, ny = y + dy
            guard self.inside(nx, ny) else { continue }
            let index = self.index(nx, ny)
            let target = self.element(index)
            if target.isFlammable || target == .gunpowder {
                if target == .gunpowder { self.explode(x: nx, y: ny, radius: 3) }
                else { self.set(index, .fire, life: 80) }
                ignited = true
            }
        }
        return ignited
    }

    private func explode(x: Int, y: Int, radius: Int) {
        for dy in -radius...radius {
            for dx in -radius...radius {
                guard dx * dx + dy * dy <= radius * radius else { continue }
                let nx = x + dx, ny = y + dy
                guard self.inside(nx, ny) else { continue }
                let index = self.index(nx, ny)
                let target = self.element(index)
                if target == .wall || target == .glass { continue }
                if Int.random(in: 0..<3) == 0 { self.set(index, .fire, life: 50) }
                else if Int.random(in: 0..<2) == 0 { self.set(index, .smoke, life: 90) }
                else { self.set(index, .empty) }
            }
        }
    }

    // MARK: Rendering

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), self.width > 0, self.height > 0 else { return }
        let cellWidth = self.bounds.width / CGFloat(self.width)
        let cellHeight = self.bounds.height / CGFloat(self.height)
        var paths: [UInt8: CGMutablePath] = [:]
        for y in 0..<self.height {
            for x in 0..<self.width {
                let index = self.index(x, y)
                let element = self.element(index)
                if element == .empty { continue }
                let key = element.rawValue
                let path = paths[key] ?? CGMutablePath()
                path.addRect(CGRect(x: CGFloat(x) * cellWidth, y: CGFloat(y) * cellHeight,
                                    width: cellWidth + 0.6, height: cellHeight + 0.6))
                paths[key] = path
            }
        }
        for (raw, path) in paths {
            let element = AyuSandElement(rawValue: raw) ?? .empty
            context.setFillColor(element.color.cgColor)
            context.addPath(path)
            context.fillPath()
        }
        for i in self.cells.indices where self.element(i) == .lamp && self.powered[i] {
            let x = CGFloat(i % self.width) * cellWidth, y = CGFloat(i / self.width) * cellHeight
            context.setFillColor(UIColor(red: 1, green: 0.95, blue: 0.55, alpha: 0.35).cgColor)
            context.fill(CGRect(x: x - cellWidth, y: y - cellHeight, width: cellWidth * 3, height: cellHeight * 3))
        }
    }

    // MARK: Scene

    func clear() {
        self.cells = [UInt8](repeating: 0, count: self.cells.count)
        self.life = [UInt8](repeating: 0, count: self.life.count)
    }

    func demo() {
        self.clear()
        let floor = self.height - 2
        for x in 0..<self.width { self.set(self.index(x, floor), .wall); self.set(self.index(x, floor - 1), .wall) }
        for _ in 0..<800 {
            let x = Int.random(in: 10..<max(11, self.width - 10))
            let y = Int.random(in: max(0, floor - 24)..<floor)
            if self.element(self.index(x, y)) == .empty { self.set(self.index(x, y), .sand) }
        }
        for _ in 0..<450 {
            let x = Int.random(in: 8..<max(9, self.width / 2))
            let y = Int.random(in: max(0, floor - 8)..<floor)
            if self.element(self.index(x, y)) == .empty { self.set(self.index(x, y), .water) }
        }
        let treeX = max(4, self.width - 28)
        for y in (floor - 18)..<floor { self.set(self.index(treeX, y), .wood) }
        for y in (floor - 22)..<(floor - 18) {
            self.set(self.index(treeX - 1, y), .plant)
            self.set(self.index(treeX + 1, y), .plant)
        }
        self.set(self.index(8, floor - 1), .battery)
        self.set(self.index(9, floor - 1), .wire)
        self.set(self.index(10, floor - 1), .wire)
        self.set(self.index(11, floor - 1), .lamp)
    }

    func encoded() -> String {
        var parts: [String] = []
        var current = self.cells[0]
        var count = 1
        for index in 1..<self.cells.count {
            if self.cells[index] == current && count < 4096 { count += 1 }
            else { parts.append("\(current):\(count)"); current = self.cells[index]; count = 1 }
        }
        parts.append("\(current):\(count)")
        return "\(self.width)x\(self.height);" + parts.joined(separator: ",")
    }

    func load(_ encoded: String) {
        guard encoded.utf8.count <= 600_000 else { return }
        let sections = encoded.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard sections.count == 2 else { return }
        let size = sections[0].split(separator: "x").compactMap { Int($0) }
        guard size.count == 2, size[0] == self.width, size[1] == self.height else {
            AyuNativePluginRuntime.shared.showMessage("Сцена сохранена для другого размера поля", style: "error")
            return
        }
        var decoded: [UInt8] = []
        decoded.reserveCapacity(self.cells.count)
        for pair in sections[1].split(separator: ",") {
            let values = pair.split(separator: ":")
            guard values.count == 2, let raw = UInt8(values[0]), let count = Int(values[1]), count > 0, count <= 8192 else { return }
            decoded.append(contentsOf: repeatElement(raw, count: count))
            if decoded.count > self.cells.count { return }
        }
        guard decoded.count == self.cells.count else { return }
        self.cells = decoded
        self.life = [UInt8](repeating: 0, count: self.cells.count)
    }
}
