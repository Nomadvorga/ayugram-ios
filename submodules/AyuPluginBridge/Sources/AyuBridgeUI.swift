import Foundation
import QuartzCore
import UIKit

/// Every UIKit object is confined to main. Worker submits JSON commands only.
/// One main-queue drain coalesces all queued mutations; reads flush earlier mutations.
final class AyuBridgeUI: @unchecked Sendable {
    struct Command: Sendable {
        let owner: String
        let generation: UUID
        let handle: String
        let method: String
        let arguments: [AyuBridgeValue]
    }
    typealias Callback = @Sendable (String, UUID, String, [AyuBridgeValue]) -> Void
    private let lock = NSLock()
    private var pending: [Command] = []
    private var scheduled = false
    private let limit: Int
    private let byteLimit: Int
    private var pendingBytes = 0
    private let callback: Callback
    // Main-only state; not exposed to worker or plugin code.
    private var views: [String: AyuBridgeView] = [:]
    private var containers: [String: UIView] = [:]
    private var mountedRoots: [String: Set<String>] = [:]
    private var generations: [String: UUID] = [:]
    private var customDialogs: [String: AyuBridgeDialogViewController] = [:]

    init(limit: Int, byteLimit: Int, callback: @escaping Callback) {
        self.limit = limit
        self.byteLimit = byteLimit
        self.callback = callback
    }

    @MainActor func install(owner: String, generation: UUID, container: UIView?) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.remove(owner: owner)
        self.generations[owner] = generation
        self.containers[owner] = container
    }

    @MainActor func setContainer(owner: String, container: UIView?) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.containers[owner] = container
        for handle in self.mountedRoots[owner] ?? [] {
            guard let view = self.views[handle], view.owner == owner else { continue }
            if let container {
                container.addSubview(view)
                view.frame = container.bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.setNeedsLayout()
            } else {
                // Preserve child hierarchy while the preview's surface is detached.
                view.removeFromSuperview()
            }
        }
    }

    @MainActor func remove(owner: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let handles = self.views.compactMap { $0.value.owner == owner ? $0.key : nil }
        for handle in handles {
            if let view = self.views.removeValue(forKey: handle) {
                view.layer.removeAllAnimations(); view.callback = nil; view.removeFromSuperview()
            }
        }
        self.containers.removeValue(forKey: owner)
        self.mountedRoots.removeValue(forKey: owner)
        self.generations.removeValue(forKey: owner)
        self.customDialogs.removeValue(forKey: owner)?.dismiss(animated: false)
        self.lock.lock()
        self.pending.removeAll { $0.owner == owner }
        self.pendingBytes = self.pending.reduce(0) { total, command in
            total + ((try? JSONEncoder().encode(command.arguments).count) ?? 0) + 256
        }
        self.lock.unlock()
    }

    @MainActor func create(owner: String, generation: UUID, handle: String, className: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.generations[owner] == generation else { return }
        let view = AyuBridgeView(owner: owner, className: className)
        view.callback = { [callback = self.callback] callbackID, arguments in
            // This closure enqueues work; it never enters Python or waits on its queue.
            callback(owner, generation, callbackID, [.object(["$handle": .string(handle), "$class": .string(className)])] + arguments)
        }
        self.views[handle] = view
    }

    func enqueue(_ commands: [Command]) throws {
        let bytes = try commands.reduce(0) { total, command in total + (try JSONEncoder().encode(command.arguments).count) + 256 }
        self.lock.lock()
        guard commands.count <= self.limit - self.pending.count, bytes <= self.byteLimit - self.pendingBytes else {
            self.lock.unlock()
            throw AyuBridgeFailure("resource_limit", "Too many pending UI commands")
        }
        self.pending.append(contentsOf: commands)
        self.pendingBytes += bytes
        let needsSchedule = !self.scheduled
        self.scheduled = true
        self.lock.unlock()
        if needsSchedule { DispatchQueue.main.async { [self] in self.flush() } }
    }

    @MainActor func flush() {
        dispatchPrecondition(condition: .onQueue(.main))
        self.lock.lock()
        let commands = self.pending
        self.pending.removeAll(keepingCapacity: true)
        self.pendingBytes = 0
        self.scheduled = false
        self.lock.unlock()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for command in commands {
            guard self.generations[command.owner] == command.generation,
                  let view = self.views[command.handle], view.owner == command.owner else { continue }
            self.apply(command, to: view)
        }
        CATransaction.commit()
    }

    @MainActor func read(owner: String, handle: String, method: String) throws -> AyuBridgeValue {
        dispatchPrecondition(condition: .onQueue(.main))
        self.flush()
        guard let view = self.views[handle], view.owner == owner else {
            throw AyuBridgeFailure("invalid_handle", "View is unavailable")
        }
        view.superview?.layoutIfNeeded()
        switch method {
        case "getWidth", "getMeasuredWidth": return .number(Double(view.bounds.width))
        case "getHeight", "getMeasuredHeight": return .number(Double(view.bounds.height))
        case "getX": return .number(Double(view.frame.minX))
        case "getY": return .number(Double(view.frame.minY))
        case "getAlpha": return .number(Double(view.alpha))
        case "getTranslationX": return .number(Double(view.translationX))
        case "getTranslationY": return .number(Double(view.translationY))
        case "getVisibility": return .number(Double(view.visibility))
        case "getText": return .string(view.label?.text ?? "")
        case "getChildCount": return .number(Double(view.bridgeChildren.count))
        default: throw AyuBridgeFailure.unsupported(method)
        }
    }

    struct DialogAction: Sendable {
        let title: String
        /// 0 = default, 1 = cancel, 2 = destructive.
        let style: Int
        let handler: @Sendable () -> Void
    }

    @MainActor func makeCustomDialog(owner: String, generation: UUID, handle: String, title: String?, message: String?, actions: [DialogAction], cancelable: Bool) throws -> AyuBridgeDialogViewController {
        dispatchPrecondition(condition: .onQueue(.main))
        self.flush()
        guard self.generations[owner] == generation, let view = self.views[handle], view.owner == owner else {
            throw AyuBridgeFailure("invalid_handle", "Dialog content view is unavailable")
        }
        guard view.superview == nil else { throw AyuBridgeFailure("invalid_state", "Dialog content must not have a parent") }
        return AyuBridgeDialogViewController(title: title, message: message, content: view, actions: actions, cancelable: cancelable)
    }

    @MainActor func trackCustomDialog(owner: String, controller: AyuBridgeDialogViewController) {
        self.customDialogs[owner] = controller
    }

    @MainActor func hasVisibleCustomDialog(owner: String) -> Bool {
        self.customDialogs[owner]?.presentingViewController != nil
    }

    @MainActor func showDialogBulletin(owner: String, text: String, style: String) {
        guard let controller = self.customDialogs[owner], controller.presentingViewController != nil else { return }
        controller.showBulletin(text: text, style: style)
    }

    @MainActor func readText(owner: String, handle: String) throws -> String {
        dispatchPrecondition(condition: .onQueue(.main))
        self.flush()
        guard let view = self.views[handle], view.owner == owner, let field = view.textField else {
            throw AyuBridgeFailure("invalid_handle", "Text field is unavailable")
        }
        return field.text ?? ""
    }

    @MainActor func mount(owner: String, handle: String) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        self.flush()
        guard let container = self.containers[owner], let view = self.views[handle], view.owner == owner else {
            throw AyuBridgeFailure("no_container", "App has not attached a mount container for this plugin")
        }
        guard view.superview == nil || view.superview === container else {
            throw AyuBridgeFailure("invalid_state", "Remove view from its parent before mounting")
        }
        container.addSubview(view)
        self.mountedRoots[owner, default: []].insert(handle)
        // Parent owns the root's frame. It follows this explicit mount container only.
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.setNeedsLayout()
    }

    @MainActor func release(owner: String, handle: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.flush()
        guard self.views[handle]?.owner == owner else { return }
        self.mountedRoots[owner]?.remove(handle)
        self.views.removeValue(forKey: handle)?.removeFromSuperview()
    }

    @MainActor private func apply(_ command: Command, to view: AyuBridgeView) {
        let args = command.arguments
        @MainActor func number(_ index: Int) -> CGFloat { return CGFloat(args[index].number ?? 0) }
        switch command.method {
        case "setAlpha": view.alpha = number(0)
        case "setTranslationX": view.translationX = number(0); view.updateTransform()
        case "setTranslationY": view.translationY = number(0); view.updateTransform()
        case "setScaleX": view.scaleX = number(0); view.updateTransform()
        case "setScaleY": view.scaleY = number(0); view.updateTransform()
        case "setVisibility":
            view.visibility = Int(number(0)); view.isHidden = view.visibility != 0
            view.superview?.setNeedsLayout()
        case "setBackgroundColor": view.backgroundColor = AyuBridgeUI.color(args[0].number ?? 0)
        case "setText":
            view.label?.text = args[0].string; view.textField?.text = args[0].string; view.superview?.setNeedsLayout()
        case "setTextColor":
            let color = AyuBridgeUI.textColor(args[0].number ?? 0)
            view.label?.textColor = color; view.textField?.textColor = color
        case "setTextSize":
            view.label?.font = .systemFont(ofSize: number(0)); view.textField?.font = .systemFont(ofSize: number(0)); view.superview?.setNeedsLayout()
        case "setHint": view.setHint(args[0].string ?? "")
        case "setHintTextColor": view.setHintColor(AyuBridgeUI.textColor(args[0].number ?? 0))
        case "setSingleLine": break
        case "setMinLines": break
        case "setOrientation": view.orientation = Int(number(0)); view.setNeedsLayout()
        case "setPadding": view.padding = UIEdgeInsets(top: number(1), left: number(0), bottom: number(3), right: number(2)); view.setNeedsLayout()
        case "setLayoutParams": view.parameters = args[0].object ?? [:]; view.superview?.setNeedsLayout()
        case "setFrame":
            // Explicit geometry is applied by the parent during its layout pass.
            view.parameters = ["x": args[0], "y": args[1], "width": args[2], "height": args[3]]
            view.superview?.setNeedsLayout()
        case "addView":
            if let child = self.views[args[0]["$handle"].string ?? ""], child.owner == view.owner {
                view.addSubview(child)
                view.setNeedsLayout()
            }
        case "removeView":
            if let child = self.views[args[0]["$handle"].string ?? ""], child.superview === view { child.removeFromSuperview(); view.setNeedsLayout() }
        case "removeAllViews": for child in view.bridgeChildren { child.removeFromSuperview() }; view.setNeedsLayout()
        case "bringToFront": view.superview?.bringSubviewToFront(view)
        case "setOnClickListener": view.clickCallback = args[0]["$callback"].string; view.updateRecognizers()
        case "setOnTouchListener": view.touchCallback = args[0]["$callback"].string; view.isUserInteractionEnabled = true
        case "setImageBase64":
            if let text = args[0].string, let data = Data(base64Encoded: text) { view.image?.image = UIImage(data: data) }
        case "unmount": self.mountedRoots[command.owner]?.remove(command.handle); view.removeFromSuperview()
        case "animate":
            let options = args[0].object ?? [:]
            let duration = options["duration_ms"]?.number ?? 250
            let alpha = options["alpha"]?.number
            let x = options["translation_x"]?.number
            let y = options["translation_y"]?.number
            UIView.animate(withDuration: duration / 1000.0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                if let alpha { view.alpha = CGFloat(alpha) }
                if let x { view.translationX = CGFloat(x) }
                if let y { view.translationY = CGFloat(y) }
                view.updateTransform()
            })
        default: preconditionFailure("UI command must be validated on the worker")
        }
    }

    @MainActor private static func color(_ raw: Double) -> UIColor {
        let color = UInt32(truncatingIfNeeded: Int64(raw))
        return UIColor(red: CGFloat((color >> 16) & 255) / 255, green: CGFloat((color >> 8) & 255) / 255, blue: CGFloat(color & 255) / 255, alpha: CGFloat((color >> 24) & 255) / 255)
    }

    /// Theme markers from the application adapter resolve to dynamic iOS
    /// colours; every other value is the plugin's ARGB colour.
    @MainActor private static func textColor(_ raw: Double) -> UIColor {
        let marker = Int64(raw)
        if marker == 0x0100_0001 { return .label }
        if marker == 0x0100_0002 { return .secondaryLabel }
        return self.color(raw)
    }
}

private final class AyuBridgeView: UIView {
    let owner: String
    let className: String
    let label: UILabel?
    let textField: UITextField?
    let image: UIImageView?
    var hintColor: UIColor = .secondaryLabel
    var orientation = 1
    var visibility = 0
    var parameters: [String: AyuBridgeValue] = ["width": .number(-2), "height": .number(-2)]
    var padding = UIEdgeInsets.zero
    var translationX: CGFloat = 0
    var translationY: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var clickCallback: String?
    var touchCallback: String?
    var callback: ((String, [AyuBridgeValue]) -> Void)?
    private var tap: UITapGestureRecognizer?
    var bridgeChildren: [AyuBridgeView] { return self.subviews.compactMap { $0 as? AyuBridgeView } }

    init(owner: String, className: String) {
        self.owner = owner; self.className = className
        self.label = className == "android.widget.TextView" ? UILabel() : nil
        self.textField = className == "android.widget.EditText" ? UITextField() : nil
        self.image = className == "android.widget.ImageView" ? UIImageView() : nil
        super.init(frame: .zero)
        if let label = self.label { label.numberOfLines = 0; self.addSubview(label) }
        if let textField = self.textField {
            textField.borderStyle = .none
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
            self.addSubview(textField)
        }
        if let image = self.image { image.contentMode = .scaleAspectFit; self.addSubview(image) }
    }
    required init?(coder: NSCoder) { return nil }

    @MainActor func setHint(_ text: String) {
        guard let field = self.textField else { return }
        field.attributedPlaceholder = NSAttributedString(string: text, attributes: [.foregroundColor: self.hintColor])
    }
    @MainActor func setHintColor(_ color: UIColor) {
        self.hintColor = color
        guard let field = self.textField, let text = field.attributedPlaceholder?.string else { return }
        field.attributedPlaceholder = NSAttributedString(string: text, attributes: [.foregroundColor: color])
    }

    @MainActor func updateTransform() {
        self.transform = CGAffineTransform(translationX: self.translationX, y: self.translationY).scaledBy(x: self.scaleX, y: self.scaleY)
    }

    @MainActor func updateRecognizers() {
        if self.clickCallback != nil && self.tap == nil {
            let tap = UITapGestureRecognizer(target: self, action: #selector(self.clicked))
            self.addGestureRecognizer(tap); self.tap = tap
        } else if self.clickCallback == nil, let tap = self.tap {
            self.removeGestureRecognizer(tap); self.tap = nil
        }
    }
    @objc private func clicked() { if let id = self.clickCallback { self.callback?(id, []) } }
    private func touch(_ touches: Set<UITouch>, action: Int) {
        guard let id = self.touchCallback, let touch = touches.first else { return }
        let point = touch.location(in: self)
        self.callback?(id, [.object(["action": .number(Double(action)), "x": .number(Double(point.x)), "y": .number(Double(point.y)), "timestamp": .number(touch.timestamp)])])
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesBegan(touches, with: event); self.touch(touches, action: 0) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesMoved(touches, with: event); self.touch(touches, action: 2) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesEnded(touches, with: event); self.touch(touches, action: 1) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesCancelled(touches, with: event); self.touch(touches, action: 3) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        if let label = self.label { return label.sizeThatFits(size) }
        if let textField = self.textField {
            let height = self.className == "android.widget.EditText" ? max(36, textField.sizeThatFits(size).height) : 0
            return CGSize(width: size.width.isFinite && size.width > 0 ? size.width : textField.sizeThatFits(size).width, height: height)
        }
        if let image = self.image { return image.image?.size ?? .zero }
        return .zero
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let content = self.bounds.inset(by: self.padding)
        self.label?.frame = content
        self.textField?.frame = content
        self.image?.frame = content
        var cursor: CGFloat = 0
        for child in self.bridgeChildren where child.visibility != 8 {
            let margins = (child.parameters["margins"]?.array ?? []).compactMap(\.number)
            let left = CGFloat(margins.indices.contains(0) ? margins[0] : 0)
            let top = CGFloat(margins.indices.contains(1) ? margins[1] : 0)
            let right = CGFloat(margins.indices.contains(2) ? margins[2] : 0)
            let bottom = CGFloat(margins.indices.contains(3) ? margins[3] : 0)
            let availableWidth = max(0, content.width - left - right)
            let availableHeight = max(0, content.height - top - bottom)
            let fit = child.sizeThatFits(CGSize(width: availableWidth, height: availableHeight))
            @MainActor func dimension(_ key: String, available: CGFloat, intrinsic: CGFloat) -> CGFloat {
                let raw = child.parameters[key]?.number ?? -2
                return raw == -1 ? available : raw == -2 ? intrinsic : CGFloat(raw)
            }
            let width = dimension("width", available: availableWidth, intrinsic: fit.width)
            let height = dimension("height", available: availableHeight, intrinsic: fit.height)
            var x = CGFloat(child.parameters["x"]?.number ?? 0)
            var y = CGFloat(child.parameters["y"]?.number ?? 0)
            if self.className == "android.widget.LinearLayout" {
                if self.orientation == 1 {
                    y += cursor + top; cursor += top + height + bottom
                } else {
                    x += cursor + left; cursor += left + width + right
                }
            } else {
                x += left; y += top
            }
            // Use bounds/center to avoid corrupting frame under an existing transform.
            child.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            child.center = CGPoint(x: content.minX + x + width / 2, y: content.minY + y + height / 2)
        }
    }
}

/// Plugin-authored dialog with an owned bridge view tree. The buttons deliver
/// their Python callbacks only after the native modal has been dismissed.
@MainActor final class AyuBridgeDialogViewController: UIViewController {
    private let dialogTitle: String?
    private let dialogMessage: String?
    private let content: AyuBridgeView
    private let actions: [AyuBridgeUI.DialogAction]
    private let cancelable: Bool
    private var bulletin: UIView?
    var onDismiss: (() -> Void)?
    private var didReportDismissal = false

    fileprivate init(title: String?, message: String?, content: AyuBridgeView, actions: [AyuBridgeUI.DialogAction], cancelable: Bool) {
        self.dialogTitle = title
        self.dialogMessage = message
        self.content = content
        self.actions = actions
        self.cancelable = cancelable
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }
    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(card)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        if let title = self.dialogTitle, !title.isEmpty {
            let label = UILabel()
            label.text = title
            label.font = .preferredFont(forTextStyle: .headline)
            label.textAlignment = .center
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }
        if let message = self.dialogMessage, !message.isEmpty {
            let label = UILabel()
            label.text = message
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
            label.textAlignment = .center
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }

        let contentHeight = max(88, CGFloat(max(1, self.content.bridgeChildren.count)) * 52 + self.content.padding.top + self.content.padding.bottom)
        self.content.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(self.content)
        self.content.heightAnchor.constraint(equalToConstant: contentHeight).isActive = true

        let buttonRow = UIStackView()
        buttonRow.axis = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 8
        for action in self.actions {
            let button = UIButton(type: .system)
            button.setTitle(action.title, for: .normal)
            if action.style == 1 { button.setTitleColor(.secondaryLabel, for: .normal) }
            if action.style == 2 { button.setTitleColor(.systemRed, for: .normal) }
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.addAction(UIAction { [weak self] _ in self?.perform(action) }, for: .touchUpInside)
            buttonRow.addArrangedSubview(button)
        }
        if !self.actions.isEmpty { stack.addArrangedSubview(buttonRow) }

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: self.view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: self.view.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        if self.cancelable {
            let tap = UITapGestureRecognizer(target: self, action: #selector(self.backgroundTapped))
            tap.cancelsTouchesInView = false
            self.view.addGestureRecognizer(tap)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.content.setNeedsLayout()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !self.didReportDismissal else { return }
        self.didReportDismissal = true
        self.onDismiss?()
    }

    private func perform(_ action: AyuBridgeUI.DialogAction) {
        self.dismiss(animated: true) { action.handler() }
    }

    @objc private func backgroundTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, self.cancelable else { return }
        let point = recognizer.location(in: self.view)
        guard !self.view.subviews.contains(where: { $0.frame.contains(point) && $0 !== self.bulletin }) else { return }
        self.dismiss(animated: true)
    }

    func showBulletin(text: String, style: String) {
        self.bulletin?.removeFromSuperview()
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textAlignment = .center
        label.backgroundColor = style == "error" ? .systemRed : style == "success" ? .systemGreen : .darkGray
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        self.bulletin = label
        UIAccessibility.post(notification: .announcement, argument: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak label] in label?.removeFromSuperview() }
    }
}
