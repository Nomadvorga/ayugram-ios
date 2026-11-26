import Foundation
import QuartzCore
import UIKit

/// Every UIKit object is confined to main. Worker submits JSON commands only.
/// One main-queue drain coalesces all queued mutations; reads flush earlier mutations.
final class AyuBridgeUI: @unchecked Sendable {
    private struct ViewMetadata {
        let owner: String
        let generation: UUID
        let className: String
    }

    struct Command: Sendable {
        let owner: String
        let generation: UUID
        let handle: String
        let method: String
        let arguments: [AyuBridgeValue]
        let backgroundDrawableHandle: String?
        let layoutClassName: String?
        let layoutHandle: String?
        let animationCompletionCallbackID: String?

        init(owner: String, generation: UUID, handle: String, method: String,
             arguments: [AyuBridgeValue], backgroundDrawableHandle: String?,
             layoutClassName: String?, layoutHandle: String?,
             animationCompletionCallbackID: String? = nil) {
            self.owner = owner
            self.generation = generation
            self.handle = handle
            self.method = method
            self.arguments = arguments
            self.backgroundDrawableHandle = backgroundDrawableHandle
            self.layoutClassName = layoutClassName
            self.layoutHandle = layoutHandle
            self.animationCompletionCallbackID = animationCompletionCallbackID
        }
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
    // Protected by `lock`; enqueue validates type-specific operations off-main.
    private var viewMetadata: [String: ViewMetadata] = [:]
    private var containers: [String: UIView] = [:]
    private var mountedRoots: [String: Set<String>] = [:]
    private var generations: [String: UUID] = [:]
    private var customDialogs: [String: AyuBridgeDialogViewController] = [:]
    private var propertyAnimators: [String: UIViewPropertyAnimator] = [:]

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
        self.lock.lock()
        self.viewMetadata = self.viewMetadata.filter { $0.value.owner != owner }
        self.lock.unlock()
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
                self.stopAnimator(for: handle, view: view, preservingCurrent: false)
                view.layer.removeAllAnimations(); view.callback = nil; view.textWatcherCallback = nil
                view.clearTextWatchers(); view.removeFromSuperview()
            }
        }
        self.containers.removeValue(forKey: owner)
        self.mountedRoots.removeValue(forKey: owner)
        self.generations.removeValue(forKey: owner)
        self.customDialogs.removeValue(forKey: owner)?.dismiss(animated: false)
        self.lock.lock()
        self.viewMetadata = self.viewMetadata.filter { $0.value.owner != owner }
        self.pending.removeAll { $0.owner == owner }
        self.pendingBytes = self.pending.reduce(0) { total, command in
            total + ((try? JSONEncoder().encode(command.arguments).count) ?? 0) + 256
        }
        self.lock.unlock()
    }

    @MainActor func create(owner: String, generation: UUID, handle: String, className: String,
                           isIndeterminateProgressBar: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard self.generations[owner] == generation else { return }
        let view = AyuBridgeView(owner: owner, className: className,
                                 isIndeterminateProgressBar: isIndeterminateProgressBar)
        view.callback = { [callback = self.callback] callbackID, arguments in
            // This closure enqueues work; it never enters Python or waits on its queue.
            callback(owner, generation, callbackID, [.object(["$handle": .string(handle), "$class": .string(className)])] + arguments)
        }
        view.textWatcherCallback = { [callback = self.callback] callbackID, arguments in
            // TextWatcher methods do not receive the EditText as an argument.
            callback(owner, generation, callbackID, arguments)
        }
        self.views[handle] = view
        self.lock.lock()
        self.viewMetadata[handle] = ViewMetadata(owner: owner, generation: generation, className: className)
        self.lock.unlock()
    }

    func enqueue(_ commands: [Command]) throws {
        let bytes = try commands.reduce(0) { total, command in total + (try JSONEncoder().encode(command.arguments).count) + 256 }
        self.lock.lock()
        do {
            for command in commands { try self.validateTextCommand(command) }
        } catch {
            self.lock.unlock()
            throw error
        }
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
        view.layoutBridgeHierarchy()
        switch method {
        case "getWidth", "getMeasuredWidth": return .number(Double(view.bounds.width))
        case "getHeight", "getMeasuredHeight": return .number(Double(view.bounds.height))
        case "getX": return .number(Double(view.frame.minX))
        case "getY": return .number(Double(view.frame.minY))
        case "getId": return .integer(Int64(view.bridgeID))
        case "getMinimumWidth": return .integer(Int64(view.bridgeMinimumWidth))
        case "getMinimumHeight": return .integer(Int64(view.bridgeMinimumHeight))
        case "getElevation": return .number(Double(view.bridgeElevation))
         case "getAlpha": return .number(Double(view.alpha))
         case "getRotation": return .number(Double(view.bridgeRotation))
         case "getRotationX": return .number(Double(view.bridgeRotationX))
         case "getRotationY": return .number(Double(view.bridgeRotationY))
         case "getPivotX": return .number(Double(view.effectivePivot.x))
         case "getPivotY": return .number(Double(view.effectivePivot.y))
         case "getCameraDistance": return .number(Double(view.cameraDistance))
         case "getScaleX": return .number(Double(view.scaleX))
        case "getScaleY": return .number(Double(view.scaleY))
        case "getTranslationX": return .number(Double(view.translationX))
        case "getTranslationY": return .number(Double(view.translationY))
        case "getVisibility": return .number(Double(view.visibility))
        case "getOrientation": return .integer(Int64(view.orientation))
        case "getGravity": return .integer(view.gravity.rawValue)
        case "getClipChildren": return .bool(view.bridgeClipChildren)
        case "getClipToOutline": return .bool(view.bridgeClipToOutline)
        case "getScrollX":
            let offset = view.className == "android.widget.HorizontalScrollView" ? (view.scrollingView?.contentOffset.x ?? 0) : 0
            return .integer(Int64(max(0, offset.isFinite ? offset.rounded(.towardZero) : 0)))
        case "getScrollY":
            let offset = view.className == "android.widget.ScrollView" ? (view.scrollingView?.contentOffset.y ?? 0) : 0
            return .integer(Int64(max(0, offset.isFinite ? offset.rounded(.towardZero) : 0)))
        case "isFillViewport": return .bool(view.scrollFillViewport)
        case "isEnabled": return .bool(view.bridgeEnabled)
        case "isClickable": return .bool(view.bridgeClickable)
        case "isFocusable": return .bool(view.bridgeFocusable)
        case "isSelected": return .bool(view.bridgeSelected)
        case "isChecked": return .bool(view.bridgeChecked)
        case "isShown": return .bool(Self.isShown(view))
        case "hasFocus": return .bool(view.textField?.isFirstResponder ?? false)
        case "getSelectionStart": return .integer(Int64(self.selectionOffset(view.textField, isEnd: false)))
        case "getSelectionEnd": return .integer(Int64(self.selectionOffset(view.textField, isEnd: true)))
        case "isAttachedToWindow": return .bool(view.window != nil)
        case "getText": return .string(view.label?.text ?? "")
        case "getContentDescription": return view.contentDescription.map(AyuBridgeValue.string) ?? .null
        case "getPaddingLeft": return .number(Double(view.padding.left))
        case "getPaddingTop": return .number(Double(view.padding.top))
        case "getPaddingRight": return .number(Double(view.padding.right))
        case "getPaddingBottom": return .number(Double(view.padding.bottom))
        case "getChildCount": return .number(Double(view.bridgeChildren.count))
        default: throw AyuBridgeFailure.unsupported(method)
        }
    }

    @MainActor private func selectionOffset(_ field: UITextField?, isEnd: Bool) -> Int {
        guard let field, let selectedRange = field.selectedTextRange else { return -1 }
        let position = isEnd ? selectedRange.end : selectedRange.start
        return field.offset(from: field.beginningOfDocument, to: position)
    }

    @MainActor func setSelection(owner: String, handle: String, offset: Int) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        self.flush()
        guard let view = self.views[handle], view.owner == owner, let field = view.textField else {
            throw AyuBridgeFailure.unsupported("EditText.setSelection")
        }
        guard offset >= 0, offset <= (field.text ?? "").utf16.count,
              let position = field.position(from: field.beginningOfDocument, offset: offset),
              let range = field.textRange(from: position, to: position) else {
            throw AyuBridgeFailure("invalid_arguments", "EditText selection is out of range")
        }
        field.selectedTextRange = range
    }

    /// The command router accepts these operations for both text classes, but a
    /// UITextField cannot represent multiline or minimum-line TextView behavior.
    /// Validate before queueing so unsupported cases fail synchronously.
    private func validateTextCommand(_ command: Command) throws {
        guard command.method == "setSingleLine" || command.method == "setMinLines" || command.method == "setMaxLines" else { return }
        guard let metadata = self.viewMetadata[command.handle], metadata.owner == command.owner,
              metadata.generation == command.generation else {
            throw AyuBridgeFailure("invalid_handle", "View is unavailable")
        }
        let supportsMultiline = metadata.className == "android.widget.TextView"
        guard supportsMultiline || metadata.className == "android.widget.EditText" else {
            throw AyuBridgeFailure.unsupported(command.method)
        }
        guard let value = command.arguments.first else {
            throw AyuBridgeFailure("invalid_arguments", "Missing text layout value")
        }
        var options = AyuBridgeTextLayoutOptions()
        if command.method == "setSingleLine" {
            try options.setSingleLine(value, supportsMultiline: supportsMultiline)
        } else if command.method == "setMinLines" {
            try options.setMinimumLines(value, supportsMultiline: supportsMultiline)
        } else {
            try options.setMaximumLines(value, supportsMultiline: supportsMultiline)
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

    @MainActor func requestFocus(owner: String, handle: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        self.flush()
        guard let view = self.views[handle], view.owner == owner, view.bridgeEnabled,
              !view.isHidden, let field = view.textField, field.isEnabled, field.window != nil else { return false }
        return field.becomeFirstResponder()
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
        if let view = self.views[handle] {
            self.stopAnimator(for: handle, view: view, preservingCurrent: false)
        }
        self.mountedRoots[owner]?.remove(handle)
        if let view = self.views.removeValue(forKey: handle) {
            view.callback = nil; view.textWatcherCallback = nil; view.clearTextWatchers(); view.removeFromSuperview()
        }
        self.lock.lock()
        if self.viewMetadata[handle]?.owner == owner { self.viewMetadata.removeValue(forKey: handle) }
        self.lock.unlock()
    }

    /// Stop a native animator without allowing a stale completion to reach the
    /// callback queue. When preservingCurrent is true, the presentation layer
    /// is copied back to the model before its animations are removed. This is
    /// deliberately a one-time snapshot, not a display-link/frame callback.
    @MainActor private func stopAnimator(for handle: String, view: AyuBridgeView, preservingCurrent: Bool) {
        let presentation = preservingCurrent ? view.layer.presentation() : nil
        let animator = self.propertyAnimators.removeValue(forKey: handle)

        if let animator {
            if preservingCurrent {
                if animator.state == .active {
                    animator.stopAnimation(false)
                    animator.finishAnimation(at: .current)
                }
            } else if animator.state == .active {
                animator.stopAnimation(true)
            }
        }

        if preservingCurrent {
            // The presentation layer can be absent before a delayed animator
            // has produced its first frame. In that case read the model only
            // after finishing at the current animator position, not before it
            // has been stopped (when it may already contain the target value).
            let currentAlpha = presentation.map { CGFloat($0.opacity) } ?? view.alpha
            let currentTransform = presentation?.transform ?? view.layer.transform
            view.alpha = currentAlpha
            view.adoptPresentationTransform(currentTransform)
        }
        view.layer.removeAllAnimations()
    }

    @MainActor private func apply(_ command: Command, to view: AyuBridgeView) {
        let args = command.arguments
        @MainActor func number(_ index: Int) -> CGFloat { return CGFloat(args[index].number ?? 0) }
        switch command.method {
        case "setAlpha": view.alpha = number(0)
        case "setTranslationX": view.translationX = number(0); view.updateTransform()
        case "setTranslationY": view.translationY = number(0); view.updateTransform()
        case "setRotation":
            if let rotation = args.first?.number { view.bridgeRotation = CGFloat(rotation); view.updateTransform() }
        case "setRotationX":
            if let rotation = args.first?.number { view.bridgeRotationX = CGFloat(rotation); view.updateTransform() }
        case "setRotationY":
            if let rotation = args.first?.number { view.bridgeRotationY = CGFloat(rotation); view.updateTransform() }
         case "setPivotX":
             if let pivot = args.first?.number, pivot.isFinite, abs(pivot) <= 100_000 {
                 view.pivotX = CGFloat(pivot); view.updatePivot()
             }
         case "setPivotY":
             if let pivot = args.first?.number, pivot.isFinite, abs(pivot) <= 100_000 {
                 view.pivotY = CGFloat(pivot); view.updatePivot()
             }
         case "setCameraDistance":
             if let distance = args.first?.number, distance.isFinite, distance > 0, distance <= 1_000_000 {
                 view.cameraDistance = CGFloat(distance); view.updateTransform()
             }
        case "setScaleX": view.scaleX = number(0); view.updateTransform()
        case "setScaleY": view.scaleY = number(0); view.updateTransform()
        case "setVisibility":
            view.visibility = Int(number(0)); view.isHidden = view.visibility != 0
            if view.indeterminateProgressBar != nil {
                if view.visibility == 0 { view.indeterminateProgressBar?.startAnimating() }
                else { view.indeterminateProgressBar?.stopAnimating() }
            }
            view.invalidateBridgeLayout()
        case "setId":
            if let identifier = args.first?.integer, let bounded = Int32(exactly: identifier) { view.bridgeID = bounded }
        case "setEnabled":
            let enabled = args.first?.bool ?? false
            view.setBridgeEnabled(enabled)
        case "setFocusable":
            if let focusable = args.first?.bool { view.bridgeFocusable = focusable }
        case "setSelected":
            if let selected = args.first?.bool { view.bridgeSelected = selected }
        case "setClickable":
            if let clickable = args.first?.bool { view.setBridgeClickable(clickable) }
        case "setMinimumWidth":
            if let width = args.first?.integer { view.bridgeMinimumWidth = CGFloat(width); view.invalidateBridgeLayout() }
        case "setMinimumHeight":
            if let height = args.first?.integer { view.bridgeMinimumHeight = CGFloat(height); view.invalidateBridgeLayout() }
        case "setElevation":
            if let elevation = args.first?.number {
                view.bridgeElevation = CGFloat(elevation)
                view.layer.zPosition = CGFloat(elevation)
            }
        case "setClipChildren":
            if let clips = args.first?.bool {
                view.bridgeClipChildren = clips
                view.childContainer.clipsToBounds = clips
            }
        case "requestLayout": view.invalidateBridgeLayout()
        case "invalidate": view.setNeedsDisplay()
        case "clearFocus": _ = view.textField?.resignFirstResponder()
        case "setBackgroundColor":
            view.bridgeBackgroundColor = AyuBridgeUI.color(args[0].number ?? 0)
            view.backgroundShape = 0
            view.backgroundCornerRadius = 0
            view.backgroundStrokeWidth = 0
            view.backgroundStrokeColor = nil
            view.bridgeHasOutline = true
            view.updateBackgroundStyle()
        case "setBackgroundStyle":
            let style = args[0].object ?? [:]
            view.bridgeBackgroundColor = AyuBridgeUI.color(style["color"]?.number ?? 0)
            view.backgroundShape = Int(style["shape"]?.number ?? 0)
            view.backgroundCornerRadius = CGFloat(style["corner_radius"]?.number ?? 0)
            view.backgroundStrokeWidth = CGFloat(style["stroke_width"]?.number ?? 0)
            view.bridgeHasOutline = true
            if let strokeColor = style["stroke_color"]?.number {
                view.backgroundStrokeColor = AyuBridgeUI.color(strokeColor).cgColor
            } else {
                view.backgroundStrokeColor = nil
            }
            view.updateBackgroundStyle()
        case "clearBackground":
            view.bridgeBackgroundColor = .clear
            view.backgroundShape = 0
            view.backgroundCornerRadius = 0
            view.backgroundStrokeWidth = 0
            view.backgroundStrokeColor = nil
            view.bridgeHasOutline = false
            view.updateBackgroundStyle()
        case "setClipToOutline":
            if let enabled = args.first?.bool {
                view.bridgeClipToOutline = enabled
                view.updateClipOutline()
            }
        case "setFillViewport":
            guard Self.isScrollViewClass(view.className), let enabled = args.first?.bool else { break }
            view.scrollFillViewport = enabled
            view.invalidateBridgeLayout()
        case "setVerticalScrollBarEnabled":
            guard view.className == "android.widget.ScrollView", let enabled = args.first?.bool else { break }
            view.scrollingView?.showsVerticalScrollIndicator = enabled
        case "setHorizontalScrollBarEnabled":
            guard view.className == "android.widget.HorizontalScrollView", let enabled = args.first?.bool else { break }
            view.scrollingView?.showsHorizontalScrollIndicator = enabled
        case "setClipToPadding":
            guard Self.isScrollViewClass(view.className) else { break }
            view.scrollingView?.clipsToBounds = true
        case "setOverScrollNever":
            guard Self.isScrollViewClass(view.className) else { break }
            view.scrollingView?.bounces = false
        case "setMax":
            guard let maximum = args.first?.integer, let progress = view.progressBar else { break }
            view.progressMaximum = maximum
            view.progressValue = min(view.progressValue, maximum)
            progress.setProgress(Self.progressFraction(view.progressValue, maximum: maximum), animated: false)
        case "setProgress":
            guard let value = args.first?.integer, let progress = view.progressBar else { break }
            view.progressValue = min(max(0, value), view.progressMaximum)
            progress.setProgress(Self.progressFraction(view.progressValue, maximum: view.progressMaximum), animated: false)
        case "setProgressTintColor":
            guard let progress = view.progressBar else { break }
            if let color = args.first?.integer { progress.progressTintColor = Self.color(Double(color)) }
            else { progress.progressTintColor = nil }
        case "setButtonTintColor":
            guard let button = view.checkBoxButton else { break }
            button.tintColor = args.first?.integer.map { Self.color(Double($0)) } ?? .systemBlue
        case "setChecked":
            if let checked = args.first?.bool { view.setBridgeChecked(checked, notify: true) }
        case "setOnCheckedChangeListener":
            view.checkedChangeCallbackID = args.first?["$callback"].string
        case "performHapticFeedback":
            if let feedback = args.first?.integer { view.performBridgeHapticFeedback(feedback) }
        case "scrollTo", "smoothScrollTo":
            guard Self.isScrollViewClass(view.className), let scroll = view.scrollingView,
                  let x = args.first?.integer, let y = args.last?.integer else { break }
            if view.className == "android.widget.ScrollView" {
                let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
                let target = min(CGFloat(max(0, y)), maximum)
                scroll.setContentOffset(CGPoint(x: 0, y: target), animated: command.method == "smoothScrollTo")
            } else {
                let maximum = max(0, scroll.contentSize.width - scroll.bounds.width)
                let target = min(CGFloat(max(0, x)), maximum)
                scroll.setContentOffset(CGPoint(x: target, y: 0), animated: command.method == "smoothScrollTo")
            }
        case "scrollBy":
            guard Self.isScrollViewClass(view.className), let scroll = view.scrollingView,
                  let deltaX = args.first?.integer, let deltaY = args.last?.integer else { break }
            if view.className == "android.widget.ScrollView" {
                let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
                let requested = scroll.contentOffset.y + CGFloat(deltaY)
                scroll.setContentOffset(CGPoint(x: 0, y: min(max(0, requested), maximum)), animated: false)
            } else {
                let maximum = max(0, scroll.contentSize.width - scroll.bounds.width)
                let requested = scroll.contentOffset.x + CGFloat(deltaX)
                scroll.setContentOffset(CGPoint(x: min(max(0, requested), maximum), y: 0), animated: false)
            }
        case "setOutlineProvider":
            if let isBackground = args.first?.bool {
                view.bridgeOutlineProviderIsBackground = isBackground
                view.updateClipOutline()
            }
        case "setText":
            view.setTextValue(args[0].string ?? "", notifyTextWatchers: true); view.invalidateBridgeLayout()
        case "setContentDescription":
            view.setContentDescription(args.first?.string)
        case "setTextColor":
            let color = AyuBridgeUI.textColor(args[0].number ?? 0)
            view.label?.textColor = color; view.textField?.textColor = color
            view.checkBoxButton?.setTitleColor(color, for: .normal)
        case "setTextSize", "setTextSizeSP":
            let size = command.method == "setTextSizeSP"
                ? UIFontMetrics.default.scaledValue(for: number(0), compatibleWith: view.traitCollection) : number(0)
            view.label?.font = AyuBridgeUI.textFont(size: size, style: view.textTypefaceStyle)
            view.textField?.font = AyuBridgeUI.textFont(size: size, style: view.textTypefaceStyle)
            view.checkBoxButton?.titleLabel?.font = AyuBridgeUI.textFont(size: size, style: view.textTypefaceStyle)
            view.invalidateBridgeLayout()
        case "setTextSizePixels":
            let windowScale = view.window?.screen.scale ?? UIScreen.main.scale
            let scale = windowScale.isFinite && windowScale > 0 ? windowScale : 1
            let size = number(0) / scale
            view.label?.font = AyuBridgeUI.textFont(size: size, style: view.textTypefaceStyle)
            view.textField?.font = AyuBridgeUI.textFont(size: size, style: view.textTypefaceStyle)
            view.checkBoxButton?.titleLabel?.font = AyuBridgeUI.textFont(size: size, style: view.textTypefaceStyle)
            view.invalidateBridgeLayout()
        case "setTypefaceStyle":
            let style = args[0].integer ?? 0
            view.textTypefaceStyle = style
            let size = view.label?.font.pointSize ?? view.textField?.font.pointSize ?? 14
            view.label?.font = AyuBridgeUI.textFont(size: size, style: style)
            view.textField?.font = AyuBridgeUI.textFont(size: size, style: style)
            view.checkBoxButton?.titleLabel?.font = AyuBridgeUI.textFont(size: size, style: style)
            view.invalidateBridgeLayout()
        case "setInputType":
            guard let field = view.textField, let flags = args[0].integer else { break }
            field.isSecureTextEntry = flags & 0x80 != 0
            field.autocorrectionType = flags & 0x8_0000 != 0 ? .no : .default
            field.spellCheckingType = flags & 0x8_0000 != 0 ? .no : .default
        case "setScaleType":
            switch args[0].string {
            case "CENTER": view.image?.contentMode = .center
            case "FIT_XY": view.image?.contentMode = .scaleToFill
            case "FIT_CENTER", "CENTER_INSIDE": view.image?.contentMode = .scaleAspectFit
            case "CENTER_CROP": view.image?.contentMode = .scaleAspectFill
            case "MATRIX": view.image?.contentMode = .topLeft
            default: break
            }
            view.image?.clipsToBounds = true
        case "setEllipsize":
            let mode = args[0].string
            switch mode {
            case "END": view.label?.lineBreakMode = .byTruncatingTail
            case "START": view.label?.lineBreakMode = .byTruncatingHead
            case "MIDDLE": view.label?.lineBreakMode = .byTruncatingMiddle
            default: view.label?.lineBreakMode = .byWordWrapping
            }
            view.invalidateBridgeLayout()
        case "setTextAlignment":
            guard let value = args.first?.integer, let label = view.label else { break }
            let isRTL = label.effectiveUserInterfaceLayoutDirection == .rightToLeft
            switch value {
            case 0: label.bridgeTextAlignment = .natural
            case 1: label.bridgeTextAlignment = view.gravity.textAlignment(for: label.effectiveUserInterfaceLayoutDirection)
            case 2, 5: label.bridgeTextAlignment = isRTL ? .right : .left
            case 3, 6: label.bridgeTextAlignment = isRTL ? .left : .right
            case 4: label.bridgeTextAlignment = .center
            default: break
            }
            view.invalidateBridgeLayout()
        case "setHint": view.setHint(args[0].string ?? "")
        case "setHintTextColor": view.setHintColor(AyuBridgeUI.textColor(args[0].number ?? 0))
        case "setSingleLine":
            if let value = args.first {
                try? view.textLayoutOptions.setSingleLine(value, supportsMultiline: view.label != nil)
                view.label?.numberOfLines = view.textLayoutOptions.numberOfLines
                view.invalidateBridgeLayout()
            }
        case "setMinLines":
            if let value = args.first {
                try? view.textLayoutOptions.setMinimumLines(value, supportsMultiline: view.label != nil)
                view.invalidateBridgeLayout()
            }
        case "setMaxLines":
            if let value = args.first {
                try? view.textLayoutOptions.setMaximumLines(value, supportsMultiline: view.label != nil)
                view.label?.numberOfLines = view.textLayoutOptions.numberOfLines
                view.invalidateBridgeLayout()
            }
        case "setGravity":
            if let value = args.first, let gravity = try? AyuBridgeViewGravity(value) {
                view.gravity = gravity
                view.label?.bridgeGravity = gravity
                if let textField = view.textField {
                    textField.textAlignment = gravity.textAlignment(for: textField.effectiveUserInterfaceLayoutDirection)
                }
                view.invalidateBridgeLayout()
            }
        case "setOrientation": view.orientation = Int(number(0)); view.invalidateBridgeLayout()
        case "setPadding": view.padding = UIEdgeInsets(top: number(1), left: number(0), bottom: number(3), right: number(2)); view.invalidateBridgeLayout()
        case "setLayoutParams": view.parameters = args[0].object ?? [:]; view.invalidateBridgeLayout()
        case "setFrame":
            // Explicit geometry is applied by the parent during its layout pass.
            view.parameters = ["x": args[0], "y": args[1], "width": args[2], "height": args[3]]
            view.invalidateBridgeLayout()
        case "addView":
            if let child = self.views[args[0]["$handle"].string ?? ""], child.owner == view.owner {
                if args.count == 2, let parameters = args[1].object { child.parameters = parameters }
                if args.count == 3, let parameters = args[1].object { child.parameters = parameters }
                if args.count == 3, let index = args[2].integer {
                    view.childContainer.insertSubview(child, at: Int(index))
                } else {
                    view.childContainer.addSubview(child)
                }
                view.invalidateBridgeLayout()
            }
        case "removeView":
            if let child = self.views[args[0]["$handle"].string ?? ""], child.superview === view.childContainer { child.removeFromSuperview(); view.invalidateBridgeLayout() }
        case "removeAllViews": for child in view.bridgeChildren { child.removeFromSuperview() }; view.invalidateBridgeLayout()
        case "bringToFront": view.superview?.bringSubviewToFront(view)
        case "setOnClickListener":
            view.clickCallback = args[0]["$callback"].string
            if view.clickCallback != nil { view.setBridgeClickable(true) }
            view.updateRecognizers()
        case "setOnTouchListener": view.touchCallback = args[0]["$callback"].string; view.isUserInteractionEnabled = true
        case "addTextChangedListener":
            if let registration = args.first?.object,
               let handle = registration["listener_handle"]?.string,
               let callbacks = registration["callbacks"]?.object {
                view.addTextWatcher(handle: handle, callbacks: callbacks.compactMapValues(\.string))
            }
        case "removeTextChangedListener":
            if let handle = args.first?["listener_handle"].string { view.removeTextWatcher(handle: handle) }
        case "setImageBase64":
            if let text = args[0].string, let data = Data(base64Encoded: text) { view.setBridgeImage(UIImage(data: data)) }
        case "clearImage": view.setBridgeImage(nil)
        case "setColorFilter": view.setBridgeColorFilter(args.first?.integer)
        case "unmount": self.mountedRoots[command.owner]?.remove(command.handle); view.removeFromSuperview()
        case "animate":
            let options = args[0].object ?? [:]
            let duration = max(0, options["duration_ms"]?.number ?? 250)
            let delay = max(0, options["start_delay_ms"]?.number ?? 0)
            let alpha = options["alpha"]?.number
            let x = options["translation_x"]?.number
            let y = options["translation_y"]?.number
            let hasTransformTarget = x != nil || y != nil
                || options["scale_x"]?.number != nil || options["scale_y"]?.number != nil
                || options["rotation"]?.number != nil || options["rotation_x"]?.number != nil
                || options["rotation_y"]?.number != nil

            // Keep animation work native. A plugin may configure a Java
            // interpolator, but no callback is made for intermediate frames.
            self.stopAnimator(for: command.handle, view: view, preservingCurrent: true)
            let interpolator = options["interpolator"]?.object?["class"]?.string
            let interpolatorState = options["interpolator"]?.object?["state"]?.object ?? [:]
            @MainActor func applyFinalValues() {
                if let alpha { view.alpha = CGFloat(alpha) }
                if let x { view.translationX = CGFloat(x) }
                if let y { view.translationY = CGFloat(y) }
                if let scaleX = options["scale_x"]?.number { view.scaleX = CGFloat(scaleX) }
                if let scaleY = options["scale_y"]?.number { view.scaleY = CGFloat(scaleY) }
                if let rotation = options["rotation"]?.number { view.bridgeRotation = CGFloat(rotation) }
                if let rotationX = options["rotation_x"]?.number { view.bridgeRotationX = CGFloat(rotationX) }
                if let rotationY = options["rotation_y"]?.number { view.bridgeRotationY = CGFloat(rotationY) }
                if hasTransformTarget {
                    view.updateTransform()
                } else {
                    view.updateTransformPreservingOverride()
                }
            }
            if UIAccessibility.isReduceMotionEnabled || duration <= 0 {
                applyFinalValues()
                if let callbackID = command.animationCompletionCallbackID {
                    self.callback(command.owner, command.generation, callbackID, [])
                }
                return
            }
            let animator: UIViewPropertyAnimator
            switch interpolator {
            case "android.view.animation.OvershootInterpolator":
                let tension = interpolatorState["parameter"]?.number ?? 2
                let timing = UICubicTimingParameters(
                    controlPoint1: CGPoint(x: 1.0 / 3.0, y: (tension + 3) / 3.0),
                    controlPoint2: CGPoint(x: 2.0 / 3.0, y: 1)
                )
                animator = UIViewPropertyAnimator(duration: duration / 1000.0, timingParameters: timing)
            case "android.view.animation.LinearInterpolator":
                animator = UIViewPropertyAnimator(duration: duration / 1000.0, curve: .linear)
            case "android.view.animation.DecelerateInterpolator":
                // This cubic is exactly 1 - (1 - t)^2 (Android's default
                // factor 1). Other factors are not cubic curves and must be
                // rejected by the worker-side host rather than silently
                // claiming Android timing parity here.
                let timing = UICubicTimingParameters(
                    controlPoint1: CGPoint(x: 1.0 / 3.0, y: 2.0 / 3.0),
                    controlPoint2: CGPoint(x: 2.0 / 3.0, y: 1)
                )
                animator = UIViewPropertyAnimator(duration: duration / 1000.0, timingParameters: timing)
            default:
                animator = UIViewPropertyAnimator(duration: duration / 1000.0, curve: .easeInOut)
            }
            animator.addAnimations {
                applyFinalValues()
            }
            animator.addCompletion { [weak self, weak animator] position in
                guard let self, let animator,
                      self.generations[command.owner] == command.generation,
                      self.propertyAnimators[command.handle] === animator else { return }
                self.propertyAnimators.removeValue(forKey: command.handle)
                guard position == .end, let callbackID = command.animationCompletionCallbackID else { return }
                self.callback(command.owner, command.generation, callbackID, [])
            }
            self.propertyAnimators[command.handle] = animator
            if delay > 0 {
                animator.startAnimation(afterDelay: delay / 1000.0)
            } else {
                animator.startAnimation()
            }
        default: preconditionFailure("UI command must be validated on the worker")
        }
    }

    @MainActor func cancelAnimations(owner: String, handle: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        // Apply any queued animate command before canceling. This preserves
        // worker submission order without making main wait for Python.
        self.flush()
        guard let view = self.views[handle], view.owner == owner else { return }
        self.stopAnimator(for: handle, view: view, preservingCurrent: true)
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

    @MainActor private static func isShown(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden { return false }
            current = candidate.superview
        }
        return true
    }

    @MainActor fileprivate static func isScrollViewClass(_ className: String) -> Bool {
        className == "android.widget.ScrollView" || className == "android.widget.HorizontalScrollView"
    }

    @MainActor private static func progressFraction(_ value: Int64, maximum: Int64) -> Float {
        guard maximum > 0 else { return 0 }
        return Float(min(max(0, value), maximum)) / Float(maximum)
    }

    @MainActor private static func textFont(size: CGFloat, style: Int64) -> UIFont {
        guard style != 0 else { return .systemFont(ofSize: size) }
        if style == 1 { return .boldSystemFont(ofSize: size) }
        if style == 2 { return .italicSystemFont(ofSize: size) }
        let bold = UIFont.boldSystemFont(ofSize: size)
        let symbolicTraits = bold.fontDescriptor.symbolicTraits.union(.traitItalic)
        let traits = bold.fontDescriptor.withSymbolicTraits(symbolicTraits) ?? bold.fontDescriptor
        return UIFont(descriptor: traits, size: size)
    }
}

/// The subset of Android text layout options that can be modeled by UILabel and
/// bounded intrinsic sizing. UITextField remains single-line and rejects the
/// multiline-only minimum-line operation.
struct AyuBridgeTextLayoutOptions: Equatable {
    private(set) var isSingleLine = false
    private(set) var minimumLines = 0
    private(set) var maximumLines: Int?

    var numberOfLines: Int { self.isSingleLine ? 1 : (self.maximumLines ?? 0) }

    mutating func setSingleLine(_ value: AyuBridgeValue, supportsMultiline: Bool) throws {
        let singleLine: Bool
        if let boolean = value.bool {
            singleLine = boolean
        } else if let number = value.number, number.isFinite, number == 0 || number == 1 {
            singleLine = number == 1
        } else {
            throw AyuBridgeFailure("invalid_arguments", "Expected a boolean line mode")
        }
        guard supportsMultiline || singleLine else {
            throw AyuBridgeFailure.unsupported("EditText.setSingleLine(false)")
        }
        self.isSingleLine = singleLine
    }

    mutating func setMinimumLines(_ value: AyuBridgeValue, supportsMultiline: Bool) throws {
        guard supportsMultiline else { throw AyuBridgeFailure.unsupported("EditText.setMinLines") }
        guard let number = value.number, number.isFinite, (0...64).contains(number), number.rounded() == number else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid minimum line count")
        }
        self.minimumLines = Int(number)
    }

    mutating func setMaximumLines(_ value: AyuBridgeValue, supportsMultiline: Bool) throws {
        guard supportsMultiline else { throw AyuBridgeFailure.unsupported("EditText.setMaxLines") }
        guard let number = value.integer, (1...64).contains(number) else {
            throw AyuBridgeFailure("invalid_arguments", "Invalid maximum line count")
        }
        self.maximumLines = Int(number)
    }

    func minimumHeight(lineHeight: Double) -> Double {
        guard lineHeight.isFinite, lineHeight > 0 else { return 0 }
        let effectiveLines = self.isSingleLine ? min(self.minimumLines, 1) : self.minimumLines
        return Double(effectiveLines) * lineHeight
    }
}

/// Explicit Android Gravity bit subset used by TextView and LinearLayout.
/// Fill, clip, display-clipping, and unknown bits are rejected rather than
/// treated as a successful no-op.
struct AyuBridgeViewGravity: Equatable {
    enum Horizontal: Equatable {
        case unspecified
        case left
        case center
        case right
        case start
        case end
    }

    enum Vertical: Equatable {
        case unspecified
        case top
        case center
        case bottom
    }

    let rawValue: Int64
    let horizontal: Horizontal
    let vertical: Vertical

    static let defaultValue = AyuBridgeViewGravity(rawValue: 0, horizontal: .unspecified, vertical: .unspecified)

    private init(rawValue: Int64, horizontal: Horizontal, vertical: Vertical) {
        self.rawValue = rawValue
        self.horizontal = horizontal
        self.vertical = vertical
    }

    init(_ value: AyuBridgeValue) throws {
        guard let number = value.number, number.isFinite, number.rounded() == number,
              number >= 0, number <= Double(0x0080_0077) else {
            throw AyuBridgeFailure("invalid_arguments", "Gravity must be a nonnegative integer")
        }
        let rawValue = Int64(number)
        let horizontalBits = rawValue & 0x7
        let verticalBits = rawValue & 0x70
        let relative = rawValue & 0x0080_0000 != 0
        let supportedMask: Int64 = 0x0080_0077
        guard rawValue & ~supportedMask == 0 else {
            throw AyuBridgeFailure("invalid_arguments", "Gravity contains unsupported flags")
        }

        let horizontal: Horizontal
        if relative {
            switch horizontalBits {
            case 3: horizontal = .start
            case 5: horizontal = .end
            default: throw AyuBridgeFailure("invalid_arguments", "Invalid relative horizontal gravity")
            }
        } else {
            switch horizontalBits {
            case 0: horizontal = .unspecified
            case 1: horizontal = .center
            case 3: horizontal = .left
            case 5: horizontal = .right
            default: throw AyuBridgeFailure("invalid_arguments", "Invalid horizontal gravity")
            }
        }

        let vertical: Vertical
        switch verticalBits {
        case 0: vertical = .unspecified
        case 16: vertical = .center
        case 48: vertical = .top
        case 80: vertical = .bottom
        default: throw AyuBridgeFailure("invalid_arguments", "Invalid vertical gravity")
        }

        self.init(rawValue: rawValue, horizontal: horizontal, vertical: vertical)
    }

    func horizontalOffset(available: CGFloat, extent: CGFloat, direction: UIUserInterfaceLayoutDirection) -> CGFloat {
        switch self.horizontal {
        case .unspecified, .left: return 0
        case .center: return (available - extent) / 2
        case .right: return available - extent
        case .start: return direction == .rightToLeft ? available - extent : 0
        case .end: return direction == .rightToLeft ? 0 : available - extent
        }
    }

    func verticalOffset(available: CGFloat, extent: CGFloat) -> CGFloat {
        switch self.vertical {
        case .unspecified, .top: return 0
        case .center: return (available - extent) / 2
        case .bottom: return available - extent
        }
    }

    func textAlignment(for direction: UIUserInterfaceLayoutDirection) -> NSTextAlignment {
        switch self.horizontal {
        case .unspecified, .left: return .left
        case .center: return .center
        case .right: return .right
        case .start: return direction == .rightToLeft ? .right : .left
        case .end: return direction == .rightToLeft ? .left : .right
        }
    }
}

struct AyuBridgeLinearLayoutWeights {
    static func distribute(remaining: CGFloat, weights: [Double]) -> [CGFloat] {
        guard remaining.isFinite, remaining > 0 else { return Array(repeating: 0, count: weights.count) }
        let validWeights = weights.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = validWeights.reduce(0, +)
        guard total.isFinite, total > 0 else { return Array(repeating: 0, count: weights.count) }
        return validWeights.map { CGFloat(Double(remaining) * $0 / total) }
    }
}

private final class AyuBridgeTextLabel: UILabel {
    var bridgeGravity = AyuBridgeViewGravity.defaultValue {
        didSet { self.setNeedsDisplay() }
    }
    var bridgeTextAlignment: NSTextAlignment? {
        didSet { self.setNeedsDisplay() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.textAlignment = self.bridgeTextAlignment ?? self.bridgeGravity.textAlignment(for: self.effectiveUserInterfaceLayoutDirection)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let textRect = super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines)
        let y = bounds.minY + self.bridgeGravity.verticalOffset(available: bounds.height, extent: textRect.height)
        return CGRect(x: textRect.minX, y: y, width: textRect.width, height: textRect.height)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: self.textRect(forBounds: rect, limitedToNumberOfLines: self.numberOfLines))
    }
}

private final class AyuBridgeView: UIView, UITextFieldDelegate {
    private struct TextWatcherRegistration {
        let handle: String
        let callbacks: [String: String]
    }

    let owner: String
    let className: String
    let label: AyuBridgeTextLabel?
    let checkBoxButton: UIButton?
    let textField: UITextField?
    let image: UIImageView?
    let scrollingView: UIScrollView?
    let progressBar: UIProgressView?
    let indeterminateProgressBar: UIActivityIndicatorView?
    var progressMaximum: Int64 = 100
    var progressValue: Int64 = 0
    var bridgeChecked = false
    var checkedChangeCallbackID: String?
    var hintColor: UIColor = .secondaryLabel
    var orientation = 1
    var visibility = 0
    var parameters: [String: AyuBridgeValue] = ["width": .number(-2), "height": .number(-2)]
    var padding = UIEdgeInsets.zero
    var textLayoutOptions = AyuBridgeTextLayoutOptions()
    var gravity = AyuBridgeViewGravity.defaultValue
    var bridgeEnabled = true
    var bridgeFocusable = false
    var bridgeSelected = false
    var textTypefaceStyle: Int64 = 0
    var translationX: CGFloat = 0
    var translationY: CGFloat = 0
    var bridgeRotation: CGFloat = 0
    var bridgeRotationX: CGFloat = 0
    var bridgeRotationY: CGFloat = 0
    var pivotX: CGFloat?
    var pivotY: CGFloat?
    var cameraDistance: CGFloat = 10_000
    private var presentationTransformOverride: CATransform3D?
    private var presentationTransformPivotOffset: CGPoint?
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var bridgeID: Int32 = -1
    var bridgeMinimumWidth: CGFloat = 0
    var bridgeMinimumHeight: CGFloat = 0
    var bridgeElevation: CGFloat = 0
    var bridgeClipChildren = false
    var bridgeClipToOutline = false
    var bridgeOutlineProviderIsBackground = true
    var scrollFillViewport = false
    var bridgeHasOutline = false
    private(set) var bridgeClickable = false
    var bridgeBackgroundColor: UIColor = .clear
    private var bridgeOriginalImage: UIImage?
    private var bridgeColorFilter: Int64?
    var backgroundShape = 0
    var backgroundCornerRadius: CGFloat = 0
    var backgroundStrokeWidth: CGFloat = 0
    var backgroundStrokeColor: CGColor?
    private var ovalBackgroundLayer: CAShapeLayer?
    private var clipOutlineMask: CAShapeLayer?
    var clickCallback: String?
    var touchCallback: String?
    private(set) var contentDescription: String?
    var callback: ((String, [AyuBridgeValue]) -> Void)?
    var textWatcherCallback: ((String, [AyuBridgeValue]) -> Void)?
    private var textWatchers: [TextWatcherRegistration] = []
    private var lastTextValue = ""
    private var tap: UITapGestureRecognizer?
    private var impactFeedback: UIImpactFeedbackGenerator?
    private var selectionFeedback: UISelectionFeedbackGenerator?
    var childContainer: UIView { self.scrollingView.map { $0 as UIView } ?? self }
    var bridgeChildren: [AyuBridgeView] { self.childContainer.subviews.compactMap { $0 as? AyuBridgeView } }

    init(owner: String, className: String, isIndeterminateProgressBar: Bool = false) {
        self.owner = owner; self.className = className
        self.label = ["android.widget.TextView", "android.widget.CheckBox"].contains(className) ? AyuBridgeTextLabel() : nil
        self.checkBoxButton = className == "android.widget.CheckBox" ? UIButton(type: .system) : nil
        self.textField = className == "android.widget.EditText" ? UITextField() : nil
        self.image = ["android.widget.ImageView", "android.widget.ImageButton"].contains(className) ? UIImageView() : nil
        self.scrollingView = AyuBridgeUI.isScrollViewClass(className) ? UIScrollView() : nil
        self.progressBar = className == "android.widget.ProgressBar" && !isIndeterminateProgressBar ? UIProgressView(progressViewStyle: .bar) : nil
        self.indeterminateProgressBar = className == "android.widget.ProgressBar" && isIndeterminateProgressBar ? UIActivityIndicatorView(style: .medium) : nil
        super.init(frame: .zero)
        if let label = self.label {
            label.numberOfLines = 0
            if self.checkBoxButton == nil { self.addSubview(label) }
        }
        if let checkBoxButton = self.checkBoxButton {
            checkBoxButton.contentHorizontalAlignment = .leading
            checkBoxButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
            checkBoxButton.setTitleColor(.label, for: .normal)
            checkBoxButton.setImage(UIImage(systemName: "square"), for: .normal)
            checkBoxButton.setImage(UIImage(systemName: "checkmark.square.fill"), for: .selected)
            checkBoxButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
            checkBoxButton.addTarget(self, action: #selector(self.checkBoxTapped), for: .touchUpInside)
            self.addSubview(checkBoxButton)
        }
        if let textField = self.textField {
            textField.borderStyle = .none
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
            textField.delegate = self
            textField.addTarget(self, action: #selector(self.textFieldChanged(_:)), for: .editingChanged)
            self.addSubview(textField)
        }
        if let image = self.image { image.contentMode = .scaleAspectFit; self.addSubview(image) }
        if let scrollingView = self.scrollingView {
            scrollingView.clipsToBounds = true
            scrollingView.showsHorizontalScrollIndicator = false
            scrollingView.contentInsetAdjustmentBehavior = .never
            scrollingView.bounces = false
            self.addSubview(scrollingView)
        }
        if let progressBar = self.progressBar { self.addSubview(progressBar) }
        if let activityIndicator = self.indeterminateProgressBar {
            activityIndicator.hidesWhenStopped = false
            activityIndicator.startAnimating()
            self.addSubview(activityIndicator)
        }
    }
    required init?(coder: NSCoder) { return nil }

    @MainActor func setTextValue(_ text: String, notifyTextWatchers: Bool) {
        let previous = self.lastTextValue
        self.lastTextValue = text
        self.label?.text = text
        self.textField?.text = text
        self.checkBoxButton?.setTitle(text, for: .normal)
        self.checkBoxButton?.accessibilityLabel = text
        if notifyTextWatchers { self.notifyTextWatchers(from: previous, to: text) }
    }

    @MainActor func setBridgeImage(_ image: UIImage?) {
        self.bridgeOriginalImage = image
        self.updateBridgeImage()
    }

    @MainActor func setBridgeColorFilter(_ color: Int64?) {
        self.bridgeColorFilter = color
        self.updateBridgeImage()
    }

    @MainActor private func updateBridgeImage() {
        guard let imageView = self.image else { return }
        guard let color = self.bridgeColorFilter else {
            imageView.image = self.bridgeOriginalImage
            imageView.tintColor = nil
            return
        }
        let bits = UInt32(truncatingIfNeeded: color)
        imageView.tintColor = UIColor(red: CGFloat((bits >> 16) & 255) / 255,
                                      green: CGFloat((bits >> 8) & 255) / 255,
                                      blue: CGFloat(bits & 255) / 255,
                                      alpha: CGFloat((bits >> 24) & 255) / 255)
        imageView.image = self.bridgeOriginalImage?.withRenderingMode(.alwaysTemplate)
    }

    @MainActor func addTextWatcher(handle: String, callbacks: [String: String]) {
        self.textWatchers.append(TextWatcherRegistration(handle: handle, callbacks: callbacks))
    }

    @MainActor func removeTextWatcher(handle: String) {
        guard let index = self.textWatchers.firstIndex(where: { $0.handle == handle }) else { return }
        self.textWatchers.remove(at: index)
    }

    @MainActor func clearTextWatchers() { self.textWatchers.removeAll(keepingCapacity: false) }

    @MainActor func setContentDescription(_ description: String?) {
        self.contentDescription = description
        if let label = self.label {
            label.accessibilityLabel = description
        } else if let textField = self.textField {
            textField.accessibilityLabel = description
        } else if let image = self.image {
            image.accessibilityLabel = description
        } else {
            self.accessibilityLabel = description
            self.isAccessibilityElement = description != nil
        }
        self.checkBoxButton?.accessibilityLabel = description ?? self.label?.text
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let swiftRange = Range(range, in: textField.text ?? "") else { return false }
        let candidate = (textField.text ?? "").replacingCharacters(in: swiftRange, with: string)
        return candidate.utf8.count <= 65_536
    }

    @objc private func textFieldChanged(_ sender: UITextField) {
        let newText = sender.text ?? ""
        let previous = self.lastTextValue
        self.lastTextValue = newText
        self.notifyTextWatchers(from: previous, to: newText)
    }

    @MainActor private func notifyTextWatchers(from oldText: String, to newText: String) {
        guard oldText != newText, oldText.utf8.count <= 65_536, newText.utf8.count <= 65_536 else { return }
        // Compare Unicode scalars, then report Java's UTF-16 offsets. Comparing
        // raw UTF-16 units could put the edit boundary between a surrogate pair
        // when one supplementary character is replaced by another.
        let oldScalars = Array(oldText.unicodeScalars)
        let newScalars = Array(newText.unicodeScalars)
        var prefix = 0
        while prefix < oldScalars.count && prefix < newScalars.count && oldScalars[prefix] == newScalars[prefix] { prefix += 1 }
        var suffix = 0
        let suffixLimit = min(oldScalars.count - prefix, newScalars.count - prefix)
        while suffix < suffixLimit && oldScalars[oldScalars.count - suffix - 1] == newScalars[newScalars.count - suffix - 1] { suffix += 1 }
        let prefixUnits = oldScalars[..<prefix].reduce(into: 0) { count, scalar in
            count += scalar.value > 0xFFFF ? 2 : 1
        }
        let oldSuffixUnits = oldScalars.suffix(suffix).reduce(into: 0) { count, scalar in
            count += scalar.value > 0xFFFF ? 2 : 1
        }
        let newSuffixUnits = newScalars.suffix(suffix).reduce(into: 0) { count, scalar in
            count += scalar.value > 0xFFFF ? 2 : 1
        }
        let oldUnitCount = oldText.utf16.count
        let newUnitCount = newText.utf16.count
        let removed = oldUnitCount - prefixUnits - oldSuffixUnits
        let inserted = newUnitCount - prefixUnits - newSuffixUnits
        let beforeArguments: [AyuBridgeValue] = [.string(oldText), .integer(Int64(prefixUnits)), .integer(Int64(removed)), .integer(Int64(inserted))]
        let changedArguments: [AyuBridgeValue] = [.string(newText), .integer(Int64(prefixUnits)), .integer(Int64(removed)), .integer(Int64(inserted))]
        let watchers = self.textWatchers
        // Android dispatches each phase to every registered watcher before it
        // advances to the next phase.
        for (method, arguments) in [("beforeTextChanged", beforeArguments), ("onTextChanged", changedArguments), ("afterTextChanged", [.string(newText)])] {
            for watcher in watchers {
                if let callback = watcher.callbacks[method] { self.textWatcherCallback?(callback, arguments) }
            }
        }
    }

    @MainActor func setHint(_ text: String) {
        guard let field = self.textField else { return }
        field.attributedPlaceholder = NSAttributedString(string: text, attributes: [.foregroundColor: self.hintColor])
    }
    @MainActor func setHintColor(_ color: UIColor) {
        self.hintColor = color
        guard let field = self.textField, let text = field.attributedPlaceholder?.string else { return }
        field.attributedPlaceholder = NSAttributedString(string: text, attributes: [.foregroundColor: color])
    }

    /// The Android default pivot is the current center of the view. An
    /// explicitly supplied pivot is a local-coordinate value and is allowed
    /// outside the bounds; changing it must not move the UIView's layout-owned
    /// frame or anchor point.
    @MainActor var effectivePivot: CGPoint {
        let defaultX = self.bounds.width.isFinite ? self.bounds.width / 2 : 0
        let defaultY = self.bounds.height.isFinite ? self.bounds.height / 2 : 0
        return CGPoint(x: self.pivotX ?? defaultX, y: self.pivotY ?? defaultY)
    }

    private static func finite(_ transform: CATransform3D) -> Bool {
        [transform.m11, transform.m12, transform.m13, transform.m14,
         transform.m21, transform.m22, transform.m23, transform.m24,
         transform.m31, transform.m32, transform.m33, transform.m34,
         transform.m41, transform.m42, transform.m43, transform.m44].allSatisfy(\.isFinite)
    }

    private static func unit(_ value: CGFloat) -> CGFloat {
        min(1, max(-1, value))
    }

    @MainActor private func nativeTransform() -> CATransform3D {
        let pivot = self.effectivePivot
        let center = CGPoint(x: self.bounds.width / 2, y: self.bounds.height / 2)
        let pivotOffsetX = pivot.x - center.x
        let pivotOffsetY = pivot.y - center.y

        let distance = self.cameraDistance.isFinite && self.cameraDistance > 0
            ? self.cameraDistance : 10_000
        let scaleX = self.scaleX.isFinite ? self.scaleX : 1
        let scaleY = self.scaleY.isFinite ? self.scaleY : 1
        let rotation = self.bridgeRotation.isFinite ? self.bridgeRotation : 0
        let rotationX = self.bridgeRotationX.isFinite ? self.bridgeRotationX : 0
        let rotationY = self.bridgeRotationY.isFinite ? self.bridgeRotationY : 0

        // CATransform3DTranslate/Scale/Rotate prepend their operation. Build
        // T(-p) * Ry * Rx * Rz * S * T(p) * perspective, then append the
        // screen-space translation so rotation/scale do not rotate it.
        var transform = CATransform3DIdentity
        transform.m34 = -1 / distance
        transform = CATransform3DTranslate(transform, pivotOffsetX, pivotOffsetY, 0)
        transform = CATransform3DScale(transform, scaleX, scaleY, 1)
        transform = CATransform3DRotate(transform, rotation * .pi / 180, 0, 0, 1)
        transform = CATransform3DRotate(transform, rotationX * .pi / 180, 1, 0, 0)
        transform = CATransform3DRotate(transform, rotationY * .pi / 180, 0, 1, 0)
        transform = CATransform3DTranslate(transform, -pivotOffsetX, -pivotOffsetY, 0)
        transform = CATransform3DConcat(
            transform,
            CATransform3DMakeTranslation(self.translationX, self.translationY, 0)
        )
        return transform
    }

    @MainActor func updateTransform() {
        self.presentationTransformOverride = nil
        self.presentationTransformPivotOffset = nil
        self.layer.transform = self.nativeTransform()
    }

    /// Reapply the current transform without discarding a one-time
    /// presentation snapshot. This is used by alpha-only animator replacement
    /// and layout passes so that a canceled 3D transform is not reconstructed
    /// from an approximate matrix decomposition.
    @MainActor func updateTransformPreservingOverride() {
        if let transform = self.presentationTransformOverride,
           let oldPivotOffset = self.presentationTransformPivotOffset {
            let pivot = self.effectivePivot
            let center = CGPoint(x: self.bounds.width / 2, y: self.bounds.height / 2)
            let newPivotOffset = CGPoint(x: pivot.x - center.x, y: pivot.y - center.y)
            if oldPivotOffset != newPivotOffset {
                // Rebase the captured transform from the old center-relative
                // pivot to the new one. Translation commutes with the
                // screen-space translation, so this retains the exact sampled
                // matrix while following an explicit pivot across resize.
                let delta = CGPoint(x: oldPivotOffset.x - newPivotOffset.x,
                                    y: oldPivotOffset.y - newPivotOffset.y)
                let inverseDelta = CGPoint(x: -delta.x, y: -delta.y)
                let rebased = CATransform3DConcat(
                    CATransform3DConcat(
                        CATransform3DMakeTranslation(delta.x, delta.y, 0),
                        transform
                    ),
                    CATransform3DMakeTranslation(inverseDelta.x, inverseDelta.y, 0)
                )
                self.presentationTransformOverride = rebased
                self.presentationTransformPivotOffset = newPivotOffset
            }
        }
        self.layer.transform = self.presentationTransformOverride ?? self.nativeTransform()
    }

    /// Reconcile model properties with a one-time presentation-layer snapshot
    /// before an animator is canceled or replaced. The matrix is retained on
    /// the layer exactly, while the scalar fields are decomposed for future
    /// getters/setters. Interpolated matrices can contain a small amount of
    /// shear, so the decomposition is intentionally best-effort; preserving
    /// the raw matrix is what guarantees no visual jump at cancellation.
    @MainActor func adoptPresentationTransform(_ transform: CATransform3D) {
        guard Self.finite(transform) else { return }

        let pivot = self.effectivePivot
        let center = CGPoint(x: self.bounds.width / 2, y: self.bounds.height / 2)
        let pivotOffsetX = pivot.x - center.x
        let pivotOffsetY = pivot.y - center.y

        let scaleXMagnitude = sqrt(transform.m11 * transform.m11 + transform.m21 * transform.m21 + transform.m31 * transform.m31)
        let scaleYMagnitude = sqrt(transform.m12 * transform.m12 + transform.m22 * transform.m22 + transform.m32 * transform.m32)
        let scaleZMagnitude = sqrt(transform.m13 * transform.m13 + transform.m23 * transform.m23 + transform.m33 * transform.m33)
        let epsilon = CGFloat.ulpOfOne.squareRoot()

        if scaleXMagnitude.isFinite, scaleYMagnitude.isFinite, scaleZMagnitude.isFinite,
           scaleXMagnitude >= 0, scaleYMagnitude >= 0, scaleZMagnitude > epsilon {
            self.scaleX = scaleXMagnitude == 0 ? 0 : (self.scaleX < 0 ? -scaleXMagnitude : scaleXMagnitude)
            self.scaleY = scaleYMagnitude == 0 ? 0 : (self.scaleY < 0 ? -scaleYMagnitude : scaleYMagnitude)

            let normalizedM12 = transform.m21 / max(scaleXMagnitude, epsilon)
            let normalizedM22 = transform.m22 / max(scaleYMagnitude, epsilon)
            let normalizedM13 = transform.m13 / scaleZMagnitude
            let normalizedM33 = transform.m33 / scaleZMagnitude

            // The upper-left block follows Ry * Rx * Rz * S. These equations
            // recover that Euler order without touching the anchorPoint.
            self.bridgeRotationX = asin(Self.unit(transform.m23 / scaleZMagnitude)) * 180 / .pi
            self.bridgeRotationY = atan2(-normalizedM13, normalizedM33) * 180 / .pi
            self.bridgeRotation = atan2(-normalizedM12, normalizedM22) * 180 / .pi

            // Recover translation after removing the affine displacement
            // contributed by the center-relative pivot. This is best-effort
            // for projective presentation matrices; the raw matrix remains the
            // authoritative visual state until the next explicit transform.
            self.translationX = transform.m41 - pivotOffsetX
                + transform.m11 * pivotOffsetX + transform.m21 * pivotOffsetY
            self.translationY = transform.m42 - pivotOffsetY
                + transform.m12 * pivotOffsetX + transform.m22 * pivotOffsetY

        }

        // Use the presentation matrix itself for the hand-off frame. The next
        // explicit transform mutation rebuilds it from the reconciled fields;
        // an alpha-only update or a layout pass keeps this exact matrix.
        self.presentationTransformOverride = transform
        let center = CGPoint(x: self.bounds.width / 2, y: self.bounds.height / 2)
        let pivot = self.effectivePivot
        self.presentationTransformPivotOffset = CGPoint(x: pivot.x - center.x, y: pivot.y - center.y)
        self.layer.transform = transform
    }

    @MainActor func updatePivot() {
        // Do not change anchorPoint or frame: the parent remains the sole
        // owner of layout geometry. Rebuilding from bounds keeps the default
        // center pivot correct after a resize and preserves outside pivots.
        self.setNeedsLayout()
        self.updateTransform()
    }

    @MainActor func updateBackgroundStyle() {
        if self.backgroundShape == 1 {
            self.backgroundColor = nil
            self.layer.cornerRadius = 0
            self.layer.borderWidth = 0
            self.layer.borderColor = nil
            let shape: CAShapeLayer
            if let existing = self.ovalBackgroundLayer {
                shape = existing
            } else {
                shape = CAShapeLayer()
                self.layer.insertSublayer(shape, at: 0)
                self.ovalBackgroundLayer = shape
            }
            shape.frame = self.bounds
            let maximumInset = max(0, min(shape.bounds.width, shape.bounds.height) / 2)
            let strokeInset = min(max(0, self.backgroundStrokeWidth / 2), maximumInset)
            shape.path = UIBezierPath(ovalIn: shape.bounds.insetBy(dx: strokeInset, dy: strokeInset)).cgPath
            shape.fillColor = self.bridgeBackgroundColor.cgColor
            shape.strokeColor = self.backgroundStrokeWidth > 0 ? self.backgroundStrokeColor : nil
            shape.lineWidth = self.backgroundStrokeWidth
        } else {
            self.ovalBackgroundLayer?.removeFromSuperlayer()
            self.ovalBackgroundLayer = nil
            self.backgroundColor = self.bridgeBackgroundColor
            self.layer.cornerRadius = max(0, self.backgroundCornerRadius)
            self.layer.borderWidth = self.backgroundStrokeWidth
            self.layer.borderColor = self.backgroundStrokeWidth > 0 ? self.backgroundStrokeColor : nil
        }
        self.updateClipOutline()
    }

    @MainActor func updateClipOutline() {
        guard self.bridgeClipToOutline, self.bridgeOutlineProviderIsBackground, self.bridgeHasOutline else {
            if let mask = self.clipOutlineMask, self.layer.mask === mask {
                self.layer.mask = nil
            }
            self.clipOutlineMask = nil
            return
        }
        let mask: CAShapeLayer
        if let existing = self.clipOutlineMask {
            mask = existing
        } else {
            mask = CAShapeLayer()
            self.clipOutlineMask = mask
            self.layer.mask = mask
        }
        let bounds = CGRect(origin: .zero, size: self.bounds.size)
        mask.frame = bounds
        if self.backgroundShape == 1 {
            mask.path = UIBezierPath(ovalIn: bounds).cgPath
        } else {
            let radius = min(max(0, self.backgroundCornerRadius), min(bounds.width, bounds.height) / 2)
            mask.path = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
        }
    }

    @MainActor func updateRecognizers() {
        if self.clickCallback != nil && self.tap == nil {
            let tap = UITapGestureRecognizer(target: self, action: #selector(self.clicked))
            tap.cancelsTouchesInView = false
            tap.isEnabled = self.bridgeEnabled && self.bridgeClickable
            self.addGestureRecognizer(tap); self.tap = tap
        } else if self.clickCallback == nil, let tap = self.tap {
            self.removeGestureRecognizer(tap); self.tap = nil
        } else {
            self.tap?.isEnabled = self.bridgeEnabled && self.bridgeClickable
        }
    }
    @MainActor func setBridgeClickable(_ clickable: Bool) {
        self.bridgeClickable = clickable
        self.tap?.isEnabled = self.bridgeEnabled && clickable
    }
    @MainActor func setBridgeEnabled(_ enabled: Bool) {
        self.bridgeEnabled = enabled
        self.textField?.isEnabled = enabled
        self.checkBoxButton?.isEnabled = enabled
        self.tap?.isEnabled = enabled && self.bridgeClickable
    }
    @MainActor func setBridgeChecked(_ checked: Bool, notify: Bool) {
        guard self.bridgeChecked != checked else { return }
        self.bridgeChecked = checked
        self.checkBoxButton?.isSelected = checked
        self.checkBoxButton?.accessibilityValue = checked ? "Checked" : "Not checked"
        if notify, let callbackID = self.checkedChangeCallbackID {
            self.callback?(callbackID, [.bool(checked)])
        }
    }
    @MainActor func performBridgeHapticFeedback(_ feedback: Int64) {
        switch feedback {
        case 0:
            let generator = self.impactFeedback ?? UIImpactFeedbackGenerator(style: .medium)
            self.impactFeedback = generator
            generator.impactOccurred()
            generator.prepare()
        case 4:
            let generator = self.selectionFeedback ?? UISelectionFeedbackGenerator()
            self.selectionFeedback = generator
            generator.selectionChanged()
            generator.prepare()
        default:
            break
        }
    }
    @objc private func checkBoxTapped() {
        guard self.bridgeEnabled else { return }
        self.setBridgeChecked(!self.bridgeChecked, notify: true)
    }
    @objc private func clicked() { if self.bridgeEnabled && self.bridgeClickable, let id = self.clickCallback { self.callback?(id, []) } }
    private func touch(_ touches: Set<UITouch>, action: Int) {
        guard self.bridgeEnabled, let id = self.touchCallback, let touch = touches.first else { return }
        let point = touch.location(in: self)
        self.callback?(id, [.object(["action": .number(Double(action)), "x": .number(Double(point.x)), "y": .number(Double(point.y)), "timestamp": .number(touch.timestamp)])])
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesBegan(touches, with: event); self.touch(touches, action: 0) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesMoved(touches, with: event); self.touch(touches, action: 2) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesEnded(touches, with: event); self.touch(touches, action: 1) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { super.touchesCancelled(touches, with: event); self.touch(touches, action: 3) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        if let label = self.label {
            let fit = label.sizeThatFits(size)
            let minimumHeight = CGFloat(self.textLayoutOptions.minimumHeight(lineHeight: Double(label.font.lineHeight)))
            return CGSize(width: max(fit.width, self.bridgeMinimumWidth), height: max(max(fit.height, minimumHeight), self.bridgeMinimumHeight))
        }
        if let textField = self.textField {
            let height = max(self.className == "android.widget.EditText" ? max(36, textField.sizeThatFits(size).height) : 0, self.bridgeMinimumHeight)
            let width = size.width.isFinite && size.width > 0 ? size.width : textField.sizeThatFits(size).width
            return CGSize(width: max(width, self.bridgeMinimumWidth), height: height)
        }
        if let image = self.image {
            let size = image.image?.size ?? .zero
            return CGSize(width: max(size.width, self.bridgeMinimumWidth), height: max(size.height, self.bridgeMinimumHeight))
        }
        if let progressBar = self.progressBar {
            let fit = progressBar.sizeThatFits(size)
            return CGSize(width: max(fit.width, self.bridgeMinimumWidth), height: max(fit.height, self.bridgeMinimumHeight))
        }
        if let activityIndicator = self.indeterminateProgressBar {
            let fit = activityIndicator.sizeThatFits(size)
            return CGSize(width: max(fit.width, self.bridgeMinimumWidth), height: max(fit.height, self.bridgeMinimumHeight))
        }
        if let checkBoxButton = self.checkBoxButton {
            let fit = checkBoxButton.sizeThatFits(size)
            return CGSize(width: max(fit.width, self.bridgeMinimumWidth), height: max(fit.height, self.bridgeMinimumHeight))
        }

        let children = self.bridgeChildren.filter { $0.visibility != 8 }
        guard !children.isEmpty else { return CGSize(width: self.bridgeMinimumWidth, height: self.bridgeMinimumHeight) }
        let fittingWidth = size.width.isFinite && size.width > 0 ? size.width : 0
        let fittingHeight = size.height.isFinite && size.height > 0 ? size.height : 0
        let plans = children.map { child -> (view: AyuBridgeView, left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat, width: CGFloat, height: CGFloat) in
            let margins = child.bridgeMargins
            let fit = child.sizeThatFits(CGSize(width: max(0, fittingWidth - margins.left - margins.right), height: max(0, fittingHeight - margins.top - margins.bottom)))
            let width = child.bridgeDimension("width", available: max(0, fittingWidth - margins.left - margins.right), intrinsic: fit.width)
            let height = child.bridgeDimension("height", available: max(0, fittingHeight - margins.top - margins.bottom), intrinsic: fit.height)
            return (child, margins.left, margins.top, margins.right, margins.bottom, width, height)
        }

        if self.className == "android.widget.LinearLayout" {
            let vertical = self.orientation == 1
            let main = plans.reduce(CGFloat.zero) { total, plan in
                total + (vertical ? plan.top + plan.height + plan.bottom : plan.left + plan.width + plan.right)
            }
            let cross = plans.reduce(CGFloat.zero) { total, plan in
                max(total, vertical ? plan.left + plan.width + plan.right : plan.top + plan.height + plan.bottom)
            }
            return vertical ? CGSize(width: max(cross, self.bridgeMinimumWidth), height: max(main, self.bridgeMinimumHeight)) : CGSize(width: max(main, self.bridgeMinimumWidth), height: max(cross, self.bridgeMinimumHeight))
        }

        if self.className == "android.widget.ScrollView" || self.className == "android.widget.HorizontalScrollView" {
            let plan = plans[0]
            return CGSize(width: max(plan.left + plan.width + plan.right, self.bridgeMinimumWidth), height: max(plan.top + plan.height + plan.bottom, self.bridgeMinimumHeight))
        }

        let result = plans.reduce(CGSize.zero) { result, plan in
            CGSize(width: max(result.width, plan.left + plan.width + plan.right), height: max(result.height, plan.top + plan.height + plan.bottom))
        }
        return CGSize(width: max(result.width, self.bridgeMinimumWidth), height: max(result.height, self.bridgeMinimumHeight))
    }

    private var bridgeMargins: (left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
        if let margins = self.parameters["margins"]?.array {
            let values = margins.compactMap(\.number)
            return (CGFloat(values.indices.contains(0) ? values[0] : 0), CGFloat(values.indices.contains(1) ? values[1] : 0),
                    CGFloat(values.indices.contains(2) ? values[2] : 0), CGFloat(values.indices.contains(3) ? values[3] : 0))
        }
        if let margins = self.parameters["margins"]?.object {
            return (CGFloat(margins["left"]?.number ?? 0), CGFloat(margins["top"]?.number ?? 0),
                    CGFloat(margins["right"]?.number ?? 0), CGFloat(margins["bottom"]?.number ?? 0))
        }
        return (0, 0, 0, 0)
    }

    private func bridgeDimension(_ key: String, available: CGFloat, intrinsic: CGFloat) -> CGFloat {
        let raw = self.parameters[key]?.number ?? -2
        if raw == -1 { return available }
        if raw == -2 { return max(0, intrinsic) }
        return raw.isFinite && raw >= 0 ? CGFloat(raw) : 0
    }

    @MainActor func invalidateBridgeLayout() {
        self.setNeedsLayout()
        var current: UIView? = self.superview
        while let view = current {
            if let bridge = view as? AyuBridgeView { bridge.setNeedsLayout() }
            current = view.superview
        }
    }

    @MainActor func layoutBridgeHierarchy() {
        var owner: AyuBridgeView = self
        var current: UIView? = self.superview
        while let view = current {
            if let bridge = view as? AyuBridgeView { owner = bridge }
            current = view.superview
        }
        owner.layoutIfNeeded()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        self.updateBackgroundStyle()
        let content = self.bounds.inset(by: self.padding)
        self.label?.frame = content
        self.checkBoxButton?.frame = content
        self.textField?.frame = content
        self.image?.frame = content
        self.scrollingView?.frame = content
        self.progressBar?.frame = content
        self.indeterminateProgressBar?.frame = content
        let children = self.bridgeChildren.filter { $0.visibility != 8 }
        var plans: [(view: AyuBridgeView, left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat, width: CGFloat, height: CGFloat)] = []
        for child in children {
            let margins = child.bridgeMargins
            let left = margins.left
            let top = margins.top
            let right = margins.right
            let bottom = margins.bottom
            let availableWidth = max(0, content.width - left - right)
            let availableHeight = max(0, content.height - top - bottom)
            let fit = child.sizeThatFits(CGSize(width: availableWidth, height: availableHeight))
            @MainActor func dimension(_ key: String, available: CGFloat, intrinsic: CGFloat) -> CGFloat {
                let raw = child.parameters[key]?.number ?? -2
                return raw == -1 ? available : raw == -2 ? intrinsic : CGFloat(raw)
            }
            let width = dimension("width", available: availableWidth, intrinsic: fit.width)
            let height = dimension("height", available: availableHeight, intrinsic: fit.height)
            plans.append((child, left, top, right, bottom, width, height))
        }

        if self.className == "android.widget.ScrollView" {
            var cursor: CGFloat = 0
            for plan in plans {
                let availableWidth = max(0, content.width - plan.left - plan.right)
                let width = plan.view.parameters["width"]?.number == -1 ? availableWidth : plan.width
                let availableHeight = max(0, content.height - plan.top - plan.bottom)
                let height = self.scrollFillViewport ? max(plan.height, availableHeight) : plan.height
                let x = plan.left
                let y = cursor + plan.top
                plan.view.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
                plan.view.center = CGPoint(x: x + width / 2, y: y + height / 2)
                cursor += plan.top + height + plan.bottom
            }
            self.scrollingView?.contentSize = CGSize(width: content.width, height: max(content.height, cursor))
            if let scroll = self.scrollingView {
                let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
                let offset = min(max(0, scroll.contentOffset.y), maximum)
                if scroll.contentOffset.y != offset { scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false) }
            }
        } else if self.className == "android.widget.HorizontalScrollView" {
            var cursor: CGFloat = 0
            for plan in plans {
                let availableWidth = max(0, content.width - plan.left - plan.right)
                let width = self.scrollFillViewport ? max(plan.width, availableWidth) : plan.width
                let availableHeight = max(0, content.height - plan.top - plan.bottom)
                let height = plan.view.parameters["height"]?.number == -1 ? availableHeight : plan.height
                let x = cursor + plan.left
                let y = plan.top
                plan.view.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
                plan.view.center = CGPoint(x: x + width / 2, y: y + height / 2)
                cursor += plan.left + width + plan.right
            }
            self.scrollingView?.contentSize = CGSize(width: max(content.width, cursor), height: content.height)
            if let scroll = self.scrollingView {
                let maximum = max(0, scroll.contentSize.width - scroll.bounds.width)
                let offset = min(max(0, scroll.contentOffset.x), maximum)
                if scroll.contentOffset.x != offset { scroll.setContentOffset(CGPoint(x: offset, y: 0), animated: false) }
            }
        } else if self.className == "android.widget.LinearLayout" {
            let isVertical = self.orientation == 1
            let availableMainExtent = isVertical ? content.height : content.width
            let initialMainExtent = plans.reduce(CGFloat.zero) { total, plan in
                total + (isVertical ? plan.top + plan.height + plan.bottom : plan.left + plan.width + plan.right)
            }
            let remaining = max(0, availableMainExtent - initialMainExtent)
            let extra = AyuBridgeLinearLayoutWeights.distribute(remaining: remaining,
                weights: plans.map { $0.view.parameters["weight"]?.number ?? 0 })
            for index in plans.indices {
                if isVertical { plans[index].height += extra[index] }
                else { plans[index].width += extra[index] }
            }
            let totalMainExtent = plans.reduce(CGFloat.zero) { total, plan in
                total + (isVertical ? plan.top + plan.height + plan.bottom : plan.left + plan.width + plan.right)
            }
            let mainOffset = isVertical
                ? self.gravity.verticalOffset(available: content.height, extent: totalMainExtent)
                : self.gravity.horizontalOffset(available: content.width, extent: totalMainExtent, direction: self.effectiveUserInterfaceLayoutDirection)
            var cursor = mainOffset
            for plan in plans {
                let x: CGFloat
                let y: CGFloat
                if isVertical {
                    let availableWidth = max(0, content.width - plan.left - plan.right)
                    x = plan.left + self.gravity.horizontalOffset(available: availableWidth, extent: plan.width, direction: self.effectiveUserInterfaceLayoutDirection)
                    y = cursor + plan.top
                    cursor += plan.top + plan.height + plan.bottom
                } else {
                    let availableHeight = max(0, content.height - plan.top - plan.bottom)
                    x = cursor + plan.left
                    y = plan.top + self.gravity.verticalOffset(available: availableHeight, extent: plan.height)
                    cursor += plan.left + plan.width + plan.right
                }
                plan.view.bounds = CGRect(origin: .zero, size: CGSize(width: plan.width, height: plan.height))
                plan.view.center = CGPoint(x: content.minX + x + plan.width / 2, y: content.minY + y + plan.height / 2)
            }
        } else {
            for plan in plans {
                let originX = self.scrollingView == nil ? content.minX : 0
                let originY = self.scrollingView == nil ? content.minY : 0
                let x = CGFloat(plan.view.parameters["x"]?.number ?? 0) + plan.left
                let y = CGFloat(plan.view.parameters["y"]?.number ?? 0) + plan.top
                plan.view.bounds = CGRect(origin: .zero, size: CGSize(width: plan.width, height: plan.height))
                plan.view.center = CGPoint(x: originX + x + plan.width / 2, y: originY + y + plan.height / 2)
                if self.scrollingView != nil {
                    self.scrollingView?.contentSize = CGSize(
                        width: max(content.width, plan.width + plan.left + plan.right),
                        height: max(content.height, plan.height + plan.top + plan.bottom)
                    )
                }
            }
            if plans.isEmpty { self.scrollingView?.contentSize = .zero }
        }
        // The default pivot is derived from bounds. Rebuild after the parent
        // has assigned the new layout size; explicit pivots remain untouched.
        self.updateTransformPreservingOverride()
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
