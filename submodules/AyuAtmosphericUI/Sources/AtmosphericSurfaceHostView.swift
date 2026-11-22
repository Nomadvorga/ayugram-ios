import UIKit
import AyuAtmosphericHost

/// Explicitly forwarded by a containing controller when its selected screen changes.
@MainActor public protocol AtmosphericSurfaceVisibility: AnyObject {
    func updateAtmosphericSurfaceVisibility(_ visible: Bool)
}

/// A non-drawing lifecycle sentinel in a known surface container, not a view-tree discovery mechanism.
/// The surface owner supplies container-local geometry. Neither this view nor the renderer owns its own frame.
public final class AtmosphericSurfaceHostView: UIView {
    private weak var container: UIView?
    private let role: AtmosphericHostRole
    private var attachment: AtmosphericSurfaceAttachment?
    private var geometry = AtmosphericHostGeometry(rect: .zero, visible: false)
    private var ownerVisible = true
    private var applicationActive: Bool
    private var sceneActive: Bool?

    public init(container: UIView, role: AtmosphericHostRole) {
        self.container = container
        self.role = role
        self.applicationActive = UIApplication.shared.applicationState == .active
        super.init(frame: .zero)

        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = false
        self.accessibilityElementsHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(self.applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.applicationWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.applicationWillResignActive), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.sceneActivationChanged(_:)), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.sceneActivationChanged(_:)), name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.sceneActivationChanged(_:)), name: UIScene.didEnterBackgroundNotification, object: nil)
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        self.attachment?.detach()
    }

    /// This sentinel cannot introduce a hit target, including in a sparse ASDisplayNode container.
    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return nil
    }

    override public func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        return false
    }

    public func update(geometry: AtmosphericHostGeometry) {
        self.geometry = geometry
        self.refresh()
    }

    /// Transient screen/search/transition visibility; reappearing surfaces keep their latest geometry.
    public func setOwnerVisible(_ visible: Bool) {
        self.ownerVisible = visible
        self.refresh()
    }

    /// Called by normal owner layout, alpha, theme and navigation events, never by a display-link poll.
    public func refresh() {
        guard let container = self.container, self.superview === container, self.window != nil else {
            self.detachAttachment()
            return
        }
        if self.attachment == nil {
            self.attachment = AtmosphericSurfaceAttachment(container: container, role: self.role)
        }
        var geometry = self.geometry
        geometry.visible = geometry.visible && self.ownerVisible && self.applicationActive
        if #available(iOS 13.0, *), let scene = self.window?.windowScene {
            geometry.visible = geometry.visible && self.sceneActive != false && scene.activationState == .foregroundActive
        }
        self.attachment?.update(geometry: geometry)
    }

    private func detachAttachment() {
        // detach() is permanent: a later window reattachment creates a new registration.
        self.attachment?.detach()
        self.attachment = nil
    }

    override public func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview !== self.container {
            self.detachAttachment()
        }
        super.willMove(toSuperview: newSuperview)
    }

    override public func didMoveToSuperview() {
        super.didMoveToSuperview()
        self.refresh()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        self.applicationActive = UIApplication.shared.applicationState == .active
        if let scene = self.window?.windowScene {
            self.sceneActive = scene.activationState == .foregroundActive
        } else {
            self.sceneActive = nil
        }
        self.refresh()
    }

    @objc private func applicationDidBecomeActive() {
        self.applicationActive = true
        self.refresh()
    }

    @objc private func applicationWillResignActive() {
        self.applicationActive = false
        self.refresh()
    }

    @objc private func sceneActivationChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, let windowScene = self.window?.windowScene, scene === windowScene else {
            return
        }
        self.sceneActive = notification.name == UIScene.didActivateNotification
        // A scene can reactivate while UIApplication is already active, without another application notification.
        self.applicationActive = UIApplication.shared.applicationState == .active
        self.refresh()
    }
}
