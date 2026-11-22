import UIKit
import AyuAtmosphericHost
import AyuAtmosphericSnow

/// One typed configuration snapshot, changed only by native settings events.
@MainActor final class AyuAtmosphericRenderingState {
    private(set) var configuration = AtmosphericSnowConfiguration()
    private(set) var revision: UInt64 = 0
    var reportError: ((String?) -> Void)?
    private var errors: [UUID: String] = [:]
    private var publishedError: String?
    var renderingError: String? { self.publishedError }

    func setError(_ message: String?, identifier: UUID) {
        self.errors[identifier] = message
        let next = self.errors.keys.sorted { $0.uuidString < $1.uuidString }.first.flatMap { self.errors[$0] }
        if next != self.publishedError { self.publishedError = next; self.reportError?(next) }
    }

    func apply(values: [String: AyuBridgeValue]) throws {
        self.configuration = try AtmosphericSnowConfiguration(settings: Self.convert(values))
        self.revision &+= 1
    }

    static func convert(_ values: [String: AyuBridgeValue]) throws -> [String: AtmosphericSettingValue] {
        var settings: [String: AtmosphericSettingValue] = [:]
        for (key, value) in values {
            switch value {
            case let .bool(value): settings[key] = .boolean(value)
            case let .integer(value):
                guard let value = Int(exactly: value) else { throw AyuPluginService.Failure.protocolError }
                settings[key] = .integer(value)
            case let .number(value): settings[key] = .number(value)
            case let .string(value): settings[key] = .string(value)
            case .null: settings[key] = .null
            case .array, .object: throw AyuPluginService.Failure.protocolError
            }
        }
        return settings
    }

    func clear() {
        self.reportError = nil
        self.errors.removeAll()
        self.publishedError = nil
        self.configuration = AtmosphericSnowConfiguration()
        self.revision &+= 1
    }
}

/// The facade owns these containers' frames; each container owns its effect child's frame.
@MainActor private final class AyuAtmosphericPassView: UIView {
    var effect: AtmosphericEffectView?
    init() {
        super.init(frame: .zero)
        self.isOpaque = false
        self.isUserInteractionEnabled = false
        self.accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { return nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        self.effect?.frame = self.bounds
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    func install(_ effect: AtmosphericEffectView) {
        self.effect = effect
        self.addSubview(effect)
        effect.frame = self.bounds
    }
    func revoke() {
        self.effect?.invalidate()
        self.effect?.removeFromSuperview()
        self.effect = nil
    }
}

@MainActor final class AyuAtmosphericRendering: AtmosphericHostRendering {
    private let state: AyuAtmosphericRenderingState
    private let role: AtmosphericHostRole
    private let foreground = AyuAtmosphericPassView()
    private let background: AyuAtmosphericPassView?
    private var appliedRevision: UInt64?
    private var stopped = false
    private let diagnosticIdentifier = UUID()
    var view: UIView { self.foreground }
    var backgroundView: UIView? { self.background }

    init(state: AyuAtmosphericRenderingState, role: AtmosphericHostRole) {
        self.state = state
        self.role = role
        self.background = role == .navbar ? AyuAtmosphericPassView() : nil
    }

    isolated deinit {
        self.foreground.revoke()
        self.background?.revoke()
        self.state.setError(nil, identifier: self.diagnosticIdentifier)
    }

    func update(role: AtmosphericHostRole, geometry: AtmosphericHostGeometry, dark: Bool) {
        guard !self.stopped, role == self.role else { return }
        let appearance: UIUserInterfaceStyle = dark ? .dark : .light
        self.foreground.overrideUserInterfaceStyle = appearance
        self.background?.overrideUserInterfaceStyle = appearance
        do {
            let surface = Self.surface(role: role, geometry: geometry)
            try surface.validate()
            let page: AtmosphericPageKind
            switch geometry.page {
            case .chat: page = .chat
            case .chatList: page = .chatList
            case .other: page = .other
            }
            let hostState = AtmosphericHostState(pageKind: page, isVisible: geometry.visible)
            try self.updatePass(self.foreground, surface: surface,
                                plane: self.background == nil ? .combined : .foreground, hostState: hostState)
            if let background = self.background {
                try self.updatePass(background, surface: surface, plane: .background, hostState: hostState)
            }
            self.appliedRevision = self.state.revision
            self.state.setError(nil, identifier: self.diagnosticIdentifier)
        } catch {
            // Reject invalid/recycled geometry explicitly, never substitute an unrelated effect.
            // A subsequent valid host event can create fresh views; stale invalidated ones cannot revive.
            self.foreground.revoke()
            self.background?.revoke()
            self.appliedRevision = nil
            let message = "Atmospheric Snow · \(role): \(error.localizedDescription)"
            self.state.setError(message, identifier: self.diagnosticIdentifier)
        }
    }

    private func updatePass(_ container: AyuAtmosphericPassView, surface: AtmosphericSurface,
                            plane: AtmosphericRenderPlane, hostState: AtmosphericHostState) throws {
        if container.effect == nil {
            let effect = try AtmosphericEffectView(configuration: self.state.configuration, surface: surface,
                                                   renderPlane: plane, motionPolicy: .system)
            container.install(effect)
        }
        guard let effect = container.effect else { throw AyuPluginService.Failure.runtime }
        effect.frame = container.bounds
        if self.appliedRevision != self.state.revision, effect.configuration != self.state.configuration {
            try effect.update(configuration: self.state.configuration)
        }
        if effect.surface != surface { try effect.update(surface: surface) }
        effect.update(hostState: hostState)
        // Parent-assigned bounds/Telegram theme may have changed before UIKit's deferred layout.
        try effect.prepareForRendering()
    }

    func stop() {
        guard !self.stopped else { return }
        self.stopped = true
        self.foreground.revoke()
        self.background?.revoke()
        self.state.setError(nil, identifier: self.diagnosticIdentifier)
    }

    private static func surface(role: AtmosphericHostRole, geometry: AtmosphericHostGeometry) -> AtmosphericSurface {
        let visibility = AtmosphericSurfaceVisibility(isVisible: geometry.visible, opacity: geometry.alpha)
        var automaticRadius = min(geometry.rect.width, geometry.rect.height) * 0.5
        if role != .navbar && geometry.rect.height > 58 { automaticRadius = min(automaticRadius, 24) }
        // Preserve the source's compact/circular pill decoration when the actual host radius
        // matches its automatic shape. Nonmatching UIKit shapes retain their explicit radius.
        let usesAutomaticShape = geometry.cornerRadius == 0 || abs(geometry.cornerRadius - automaticRadius) < 0.01
        let shape: AtmosphericPillShape = usesAutomaticShape && (role == .glassPill || role == .navbar)
            ? .automatic : .roundedRectangle(cornerRadius: geometry.cornerRadius)
        var pill = AtmosphericPillGeometry(rect: geometry.rect,
                                          shape: shape,
                                          visibility: visibility,
                                          drawsTopDecoration: geometry.drawTopEdge,
                                          drawsBottomDecoration: geometry.drawBottomEdge,
                                          clampsTopEdge: false)
        switch role {
        case .snowfall: return .snow
        case .navbar:
            return .navigationBar(.init(pill: pill, selectedTab: geometry.selectedTabRect.map {
                AtmosphericSelectedTabGeometry(rect: $0)
            }))
        case .glassPill:
            pill.drawsFrostWash = geometry.glassDrawsFrostWash
            let glassRole: AtmosphericGlassPillRole = geometry.allowsTallGlass ? .messageInput
                : (geometry.glassDrawsFrostWash ? .blurredDrawable : .button)
            return .glassPill(role: glassRole, geometry: pill)
        case .profileAvatar:
            return .profileAvatar(.init(rect: geometry.rect, visibility: visibility,
                                        expansionProgress: geometry.avatarExpansion, hasStories: geometry.avatarHasStories,
                                        insetProgress: geometry.avatarInsetsProgress, foregroundAlpha: geometry.avatarForegroundAlpha,
                                        clipRect: nil))
        case .profileAction:
            return .profileAction(.init(pill: pill, expansionFraction: geometry.profileExpansionFraction,
                                        scale: geometry.profileActionScale, expandedReferenceSize: geometry.expandedActionReferenceSize))
        case .sectionCard: return .sectionCard(.init(pill: pill))
        }
    }
}
