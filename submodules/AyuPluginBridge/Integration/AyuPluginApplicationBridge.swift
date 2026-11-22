import Foundation
import UIKit

/// Public identity/profile values only. No access hashes, phone numbers, paths,
/// account objects, authentication state or credentials cross this boundary.
public struct AyuPluginAccountSnapshot: Sendable {
    public let index: Int64
    public let identity: UUID
    public let userID: Int64
    public let user: [String: AyuBridgeValue]?
    public init(index: Int64, identity: UUID, userID: Int64, firstName: String? = nil, lastName: String? = nil, username: String? = nil) {
        self.index = index; self.identity = identity; self.userID = userID
        self.user = firstName.map { first in ["id": .integer(userID), "first_name": .string(String(first.prefix(256))),
            "last_name": .string(String((lastName ?? "").prefix(256))), "username": username.map { .string(String($0.prefix(256))) } ?? .null] }
    }
    var state: [String: AyuBridgeValue] { ["accountIndex": .integer(self.index), "accountIdentity": .string(self.identity.uuidString)] }
}

/// The app supplies the actual visible screen. A nil dialogID means this is not
/// a peer chat. Screen identities must change when the controller/account changes.
public struct AyuPluginScreenSnapshot: Sendable {
    public let identity: UUID
    public let accountIndex: Int64
    public let dialogID: Int64?
    public init(identity: UUID, accountIndex: Int64, dialogID: Int64? = nil) {
        self.identity = identity; self.accountIndex = accountIndex; self.dialogID = dialogID
    }
    var state: [String: AyuBridgeValue] { ["screenIdentity": .string(self.identity.uuidString), "accountIndex": .integer(self.accountIndex)] }
}

/// Compiled account/context/UI adapter. Native account snapshots are pushed by
/// TelegramUI; UI closures are used only on main and never run Python there.
/// The default service installs this provider, but absent bindings fail closed.
public final class AyuPluginApplicationBridge: AyuPluginHostProvider, @unchecked Sendable {
    public static let shared = AyuPluginApplicationBridge()
    public let capabilities = ["client.call", "ui.present"]
    private let lock = NSLock()
    private var accounts: [Int64: AyuPluginAccountSnapshot] = [:]
    private var selected: Int64?
    private var ownerGenerations: [String: UUID] = [:]
    private struct Reservation { let owner: String; let generation: UUID }
    private var reservations: [String: Reservation] = [:]
    private struct Observation { let event: Int64; let sink: AyuBridgeNativeCallback }
    private var observations: [String: [String: Observation]] = [:]
    @MainActor private var screenSource: (() -> AyuPluginScreenSnapshot?)?
    @MainActor private var presenterSource: (() -> UIViewController?)?
    @MainActor private var alertPresenter: ((UIAlertController) -> Void)?
    @MainActor private var dialogs: [String: UIAlertController] = [:]
    @MainActor private var bulletins: [String: UIView] = [:]

    public init() {}

    /// Called from the app's real active-account signals, on main. Indices are
    /// process-stable slots, not Android account storage or AccountRecordId bits.
    @MainActor public func updateAccounts(_ accounts: [AyuPluginAccountSnapshot], selected: Int64?) {
        guard accounts.count <= 64, Set(accounts.map(\.index)).count == accounts.count,
              accounts.allSatisfy({ $0.index >= 0 && $0.userID > 0 }) else { return }
        self.lock.lock()
        let previousIdentity = self.selected.flatMap { self.accounts[$0]?.identity }
        self.accounts = Dictionary(uniqueKeysWithValues: accounts.map { ($0.index, $0) })
        self.selected = selected.flatMap { self.accounts[$0] == nil ? nil : $0 }
        let changedAccount = previousIdentity != self.selected.flatMap { self.accounts[$0]?.identity }
        let selectedIndex = self.selected
        self.lock.unlock()
        if changedAccount {
            self.invalidatePresentations()
            if let selectedIndex { self.accountChanged(selectedIndex) }
        }
    }

    /// Explicit app-owned root only. No key-window discovery or private APIs.
    @MainActor public func bindScreen(screen: @escaping () -> AyuPluginScreenSnapshot?, presenter: @escaping () -> UIViewController?, presentAlert: ((UIAlertController) -> Void)? = nil) {
        self.invalidatePresentations()
        self.screenSource = screen; self.presenterSource = presenter; self.alertPresenter = presentAlert
    }

    /// Lock/background/account transitions remove only bridge-owned UI. No
    /// dismissal callbacks are fabricated for revoked presentations.
    @MainActor public func invalidatePresentations() {
        self.lock.lock(); let tokens = Array(self.reservations.keys); self.reservations.removeAll(); self.lock.unlock()
        for token in tokens { self.removePresentation(token) }
    }

    public func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
        // This provider needs the host-owned context, including result wrapping.
        throw AyuBridgeFailure.unsupported(operation)
    }

    public func prepareCall(pluginID: String, operation: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        guard !Thread.isMainThread, context.pluginID == pluginID else { throw AyuBridgeFailure("wrong_thread", "Application adapter is worker-only") }
        if operation == "ui.present" { return try self.preparePresentation(arguments, context: context) }
        guard operation == "client.call", Set(arguments.keys) == ["name", "args", "kwargs"],
              let name = arguments["name"]?.string, let args = arguments["args"]?.array,
              let kwargs = arguments["kwargs"]?.object, args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Invalid client helper arguments") }
        switch name {
        case "get_selected_account":
            guard kwargs.isEmpty else { throw Self.invalid() }
            return AyuBridgeProviderResult(.value(.integer(try self.account(nil).index)))
        case "get_user_config":
            guard Set(kwargs.keys).isSubset(of: ["account"]) else { throw Self.invalid() }
            return AyuBridgeProviderResult(.instance(className: Self.userConfig, state: try self.account(kwargs["account"]).state))
        case "get_last_fragment":
            guard kwargs.isEmpty else { throw Self.invalid() }
            guard let screen = self.currentScreen() else { return AyuBridgeProviderResult(.value(.null)) }
            _ = try self.account(.integer(screen.accountIndex))
            return AyuBridgeProviderResult(.instance(className: Self.fragment, state: screen.state))
        case "get_notification_center":
            guard kwargs.isEmpty else { throw Self.invalid() }
            return AyuBridgeProviderResult(.instance(className: Self.notificationCenter, state: Self.notificationCenterState))
        default: throw AyuBridgeFailure.unsupported("client_utils." + name)
        }
    }

    public func detach(pluginID: String) {
        self.lock.lock()
        self.ownerGenerations.removeValue(forKey: pluginID)
        self.observations.removeValue(forKey: pluginID)
        let tokens = self.reservations.filter { $0.value.owner == pluginID }.map(\.key)
        for token in tokens { self.reservations.removeValue(forKey: token) }
        self.lock.unlock()
        DispatchQueue.main.async { for token in tokens { self.removePresentation(token) } }
    }

    private func account(_ value: AyuBridgeValue?) throws -> AyuPluginAccountSnapshot {
        self.lock.lock(); defer { self.lock.unlock() }
        let index: Int64?
        if value == nil || value == .null { index = self.selected }
        else { guard let supplied = value?.integer, supplied >= 0 else { throw Self.invalid() }; index = supplied }
        guard let index, let account = self.accounts[index] else { throw AyuBridgeFailure("account_unavailable", "Requested account is not active") }
        return account
    }

    private func account(state: [String: AyuBridgeValue]) throws -> AyuPluginAccountSnapshot {
        let account = try self.account(state["accountIndex"])
        guard state["accountIdentity"]?.string == account.identity.uuidString else { throw AyuBridgeFailure("invalid_handle", "Account identity expired") }
        return account
    }

    private func currentScreen() -> AyuPluginScreenSnapshot? {
        precondition(!Thread.isMainThread)
        return DispatchQueue.main.sync { self.screenSource?() }
    }

    private func screen(state: [String: AyuBridgeValue]) throws -> AyuPluginScreenSnapshot {
        guard let screen = self.currentScreen(), state["screenIdentity"]?.string == screen.identity.uuidString,
              state["accountIndex"]?.integer == screen.accountIndex else { throw AyuBridgeFailure("screen_unavailable", "Screen context expired or is not visible") }
        _ = try self.account(.integer(screen.accountIndex))
        return screen
    }

    public func classRegistry() throws -> AyuBridgeClassRegistry {
        let accountAdapter = AyuBridgeClassAdapter(name: Self.userConfig,
            staticMethods: ["getInstance": { args, _ in
                guard args.count == 1 else { throw Self.invalid() }
                return .instance(className: Self.userConfig, state: try self.account(args[0]).state)
            }], staticFields: ["selectedAccount": { _ in .value(.integer(try self.account(nil).index)) }], methods: [
                "getClientUserId": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; return .value(.integer(try self.account(state: state).userID)) },
                "isClientActivated": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; _ = try self.account(state: state); return .value(.bool(true)) },
                "getCurrentUser": { state, args, _ in
                    guard args.isEmpty else { throw Self.invalid() }
                    guard let user = try self.account(state: state).user else { throw AyuBridgeFailure("data_unavailable", "Own profile snapshot is not ready") }
                    return .instance(className: Self.user, state: user)
                }
            ], validateState: { state in try Self.validateIdentityState(state, identity: "accountIdentity") })
        let userAdapter = AyuBridgeClassAdapter(name: Self.user, readableFields: ["id", "first_name", "last_name", "username"], validateState: { state in
            guard Set(state.keys) == ["id", "first_name", "last_name", "username"], let id = state["id"]?.integer, id > 0,
                  state["first_name"]?.string != nil, state["last_name"]?.string != nil,
                  state["username"] == .null || state["username"]?.string != nil,
                  state.values.allSatisfy({ ($0.string?.utf8.count ?? 0) <= 1024 }) else { throw Self.invalid() }
        })
        let fragmentAdapter = AyuBridgeClassAdapter(name: Self.fragment, methods: [
            "getCurrentAccount": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; return .value(.integer(try self.screen(state: state).accountIndex)) },
            "getDialogId": { state, args, _ in
                guard args.isEmpty else { throw Self.invalid() }
                guard let id = try self.screen(state: state).dialogID else { throw AyuBridgeFailure.unsupported("getDialogId on a non-chat screen") }
                return .value(.integer(id))
            },
            "getParentActivity": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; return .instance(className: Self.context, state: try self.screen(state: state).state) },
            "getContext": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; return .instance(className: Self.context, state: try self.screen(state: state).state) }
        ], validateState: { state in try Self.validateIdentityState(state, identity: "screenIdentity") })
        let contextAdapter = AyuBridgeClassAdapter(name: Self.context, validateState: { state in try Self.validateIdentityState(state, identity: "screenIdentity") })
        let dialogAdapter = AyuBridgeClassAdapter(name: Self.dialog, methods: [
            "dismiss": { state, args, context in
                guard args.isEmpty, let token = state["token"]?.string else { throw Self.invalid() }
                let owner = context.pluginID
                return .prepared(AyuBridgeProviderResult(.value(.null), commit: { _ in self.dismiss(token, owner: owner) }))
            },
            "isShowing": { state, args, context in
                guard args.isEmpty, let token = state["token"]?.string else { throw Self.invalid() }
                return .value(.bool(self.isShowing(token, owner: context.pluginID)))
            }
        ], validateState: { state in guard Set(state.keys) == ["token"], UUID(uuidString: state["token"]?.string ?? "") != nil else { throw Self.invalid() } })
        let notificationCenter = AyuBridgeClassAdapter(name: Self.notificationCenter,
            constants: ["activeAccountChanged": .integer(Self.activeAccountChanged)],
            staticMethods: ["getGlobalInstance": { args, _ in
                guard args.isEmpty else { throw Self.invalid() }
                return .instance(className: Self.notificationCenter, state: Self.notificationCenterState)
            }], methods: [
                "addObserver": { state, args, context in
                    let (callbackID, event, sink) = try Self.notificationObserver(state: state, args: args, context: context)
                    try self.checkObservationQuota(owner: context.pluginID)
                    return .prepared(AyuBridgeProviderResult(.value(.null), commit: { _ in
                        self.commitObservation(owner: context.pluginID, callbackID: callbackID, event: event, sink: sink)
                    }))
                },
                "removeObserver": { state, args, context in
                    let (callbackID, _, _) = try Self.notificationObserver(state: state, args: args, context: context)
                    return .prepared(AyuBridgeProviderResult(.value(.null), commit: { _ in
                        self.removeObservation(owner: context.pluginID, callbackID: callbackID)
                    }))
                }
            ], validateState: { state in guard state == Self.notificationCenterState else { throw Self.invalid() } })
        let notificationDelegate = AyuBridgeClassAdapter(name: Self.notificationDelegate,
            validateState: { state in guard state.isEmpty else { throw Self.invalid() } })
        return try .standard.adding([accountAdapter, userAdapter, fragmentAdapter, contextAdapter, dialogAdapter, notificationCenter, notificationDelegate])
    }

    private static let notificationCenter = "org.telegram.messenger.NotificationCenter"
    private static let notificationDelegate = "org.telegram.messenger.NotificationCenter$NotificationCenterDelegate"
    private static let activeAccountChanged: Int64 = 1
    private static let notificationCenterState: [String: AyuBridgeValue] = ["token": .string("global")]
    private static func notificationObserver(state: [String: AyuBridgeValue], args: [AyuBridgeValue],
                                              context: AyuBridgeAdapterContext) throws -> (String, Int64, AyuBridgeNativeCallback) {
        guard state == notificationCenterState, args.count == 2, let event = args[1].integer,
              event == activeAccountChanged else { throw invalid() }
        let snapshot = try context.snapshot(of: args[0])
        guard snapshot.className == notificationDelegate,
              let callback = snapshot.state["didReceivedNotification"],
              let callbackID = callback.object?["$callback"]?.string, !callbackID.isEmpty,
              callbackID.utf8.count <= 128 else { throw invalid() }
        return (callbackID, event, try context.callback(callback))
    }
    private func checkObservationQuota(owner: String) throws {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.observations[owner]?.count ?? 0 < 8 else { throw AyuBridgeFailure("resource_limit", "Notification observer quota exceeded") }
    }
    private func commitObservation(owner: String, callbackID: String, event: Int64, sink: AyuBridgeNativeCallback) {
        self.lock.lock()
        var values = self.observations[owner] ?? [:]
        guard values.count < 8 || values[callbackID] != nil else { self.lock.unlock(); return }
        values[callbackID] = Observation(event: event, sink: sink)
        self.observations[owner] = values
        self.lock.unlock()
    }
    private func removeObservation(owner: String, callbackID: String) {
        self.lock.lock(); self.observations[owner]?.removeValue(forKey: callbackID); self.lock.unlock()
    }
    private func accountChanged(_ index: Int64) {
        self.lock.lock(); let values = self.observations.values.flatMap { $0.values }; self.lock.unlock()
        for observation in values {
            observation.sink.send([.integer(observation.event), .integer(index), .array([])])
        }
    }

    private static let userConfig = "org.telegram.messenger.UserConfig"
    private static let user = "org.telegram.tgnet.TLRPC$User"
    private static let fragment = "org.telegram.ui.ActionBar.BaseFragment"
    private static let context = "android.content.Context"
    private static let dialog = "org.telegram.ui.ActionBar.AlertDialog"
    private static func invalid() -> AyuBridgeFailure { AyuBridgeFailure("invalid_arguments", "Unsupported application adapter arguments") }
    private static func validateIdentityState(_ state: [String: AyuBridgeValue], identity: String) throws {
        guard Set(state.keys) == ["accountIndex", identity], let index = state["accountIndex"]?.integer, index >= 0,
              UUID(uuidString: state[identity]?.string ?? "") != nil else { throw Self.invalid() }
    }

    private struct AlertAction: Sendable {
        let title: String
        let which: Int64
        let callback: AyuBridgeNativeCallback?
        let isCancel: Bool
    }
    private struct Presentation: Sendable {
        let token: String
        let owner: String
        let generation: UUID
        let screen: AyuPluginScreenSnapshot
        let kind: String
        let title: String?
        let text: String?
        let style: String
        let actions: [AlertAction]
    }

    private func preparePresentation(_ arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        guard Set(arguments.keys) == ["kind", "config"], let kind = arguments["kind"]?.string,
              let config = arguments["config"]?.object, let screen = self.currentScreen() else { throw AyuBridgeFailure("screen_unavailable", "No explicit visible presentation context") }
        _ = try self.account(.integer(screen.accountIndex))
        let ready = DispatchQueue.main.sync { self.presenterSource?()?.viewIfLoaded?.window != nil }
        guard ready else { throw AyuBridgeFailure("screen_unavailable", "Presentation root is not visible") }
        let title: String?, text: String?, style: String
        var actions: [AlertAction] = []
        if kind == "alert" {
            guard Set(config.keys).isSubset(of: ["context", "title", "message", "items", "positive_button", "negative_button", "neutral_button", "cancelable"]) else { throw AyuBridgeFailure.unsupported("alert configuration or custom view") }
            if let reference = config["context"], reference != .null {
                let snapshot = try context.snapshot(of: reference)
                guard [Self.context, Self.fragment].contains(snapshot.className), try self.screen(state: snapshot.state).identity == screen.identity else { throw Self.invalid() }
            }
            title = try Self.optionalText(config["title"], limit: 1024)
            text = try Self.optionalText(config["message"], limit: 8192)
            style = "simple"
            if let items = config["items"] {
                guard let values = items.object, Set(values.keys) == ["labels", "on_click"], let labels = values["labels"]?.array,
                      (1...32).contains(labels.count), let callback = values["on_click"] else { throw Self.invalid() }
                let sink = try context.callback(callback)
                for (index, label) in labels.enumerated() {
                    guard let title = try Self.optionalText(label, limit: 1024), !title.isEmpty else { throw Self.invalid() }
                    actions.append(AlertAction(title: title, which: Int64(index), callback: sink, isCancel: false))
                }
            }
            for (key, which) in [("positive_button", Int64(-1)), ("negative_button", -2), ("neutral_button", -3)] {
                if let button = config[key] {
                    guard let values = button.object, Set(values.keys) == ["text", "on_click"], let title = try Self.optionalText(values["text"], limit: 1024), !title.isEmpty else { throw Self.invalid() }
                    let callback = values["on_click"] ?? .null
                    actions.append(AlertAction(title: title, which: which, callback: callback == .null ? nil : try context.callback(callback), isCancel: key == "negative_button"))
                }
            }
            let cancelable: Bool
            if let value = config["cancelable"] { guard case let .bool(flag) = value else { throw Self.invalid() }; cancelable = flag }
            else { cancelable = true }
            if !actions.contains(where: \.isCancel), cancelable { actions.append(AlertAction(title: "Отмена", which: -2, callback: nil, isCancel: true)) }
            guard !actions.isEmpty, title != nil || text != nil || config["items"] != nil else { throw Self.invalid() }
        } else if kind == "bulletin" {
            guard Set(config.keys) == ["style", "text"], let supplied = config["style"]?.string, ["simple", "success", "error"].contains(supplied),
                  let value = try Self.optionalText(config["text"], limit: 4096), !value.isEmpty else { throw Self.invalid() }
            title = nil; text = value; style = supplied
        } else { throw AyuBridgeFailure.unsupported("presentation kind") }
        let token = UUID().uuidString
        self.lock.lock()
        guard self.reservations.count < 16, self.reservations.values.filter({ $0.owner == context.pluginID }).count < 4 else {
            self.lock.unlock(); throw AyuBridgeFailure("resource_limit", "Presentation quota exceeded")
        }
        let generation = self.ownerGenerations[context.pluginID] ?? UUID()
        self.ownerGenerations[context.pluginID] = generation
        self.reservations[token] = Reservation(owner: context.pluginID, generation: generation)
        self.lock.unlock()
        let presentation = Presentation(token: token, owner: context.pluginID, generation: generation, screen: screen, kind: kind, title: title, text: text, style: style, actions: actions)
        let result: AyuBridgeAdapterResult = kind == "alert" ? .instance(className: Self.dialog, state: ["token": .string(token)]) : .value(.null)
        return AyuBridgeProviderResult(result, rollback: { self.cancelReservation(token) }, commit: { reference in
            DispatchQueue.main.async { self.present(presentation, reference: reference) }
        })
    }

    private static func optionalText(_ value: AyuBridgeValue?, limit: Int) throws -> String? {
        if value == nil || value == .null { return nil }
        guard let text = value?.string, text.utf8.count <= limit else { throw Self.invalid() }
        return text
    }

    private func cancelReservation(_ token: String) { self.lock.lock(); self.reservations.removeValue(forKey: token); self.lock.unlock() }
    private func isCurrent(_ token: String, owner: String, generation: UUID? = nil) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let reservation = self.reservations[token], reservation.owner == owner,
              self.ownerGenerations[owner] == reservation.generation else { return false }
        return generation == nil || generation == reservation.generation
    }
    private func dismiss(_ token: String, owner: String) {
        // A button may have already closed this owned dialog before Python runs.
        // Immutable token ownership is checked by the host's dialog handle.
        guard self.isCurrent(token, owner: owner) else { return }
        self.cancelReservation(token)
        DispatchQueue.main.async { self.removePresentation(token) }
    }
    private func isShowing(_ token: String, owner: String) -> Bool {
        guard self.isCurrent(token, owner: owner) else { return false }
        return DispatchQueue.main.sync { self.dialogs[token]?.presentingViewController != nil }
    }

    @MainActor private func present(_ presentation: Presentation, reference: AyuBridgeValue) {
        guard self.isCurrent(presentation.token, owner: presentation.owner, generation: presentation.generation),
              let screen = self.screenSource?(), screen.identity == presentation.screen.identity, screen.accountIndex == presentation.screen.accountIndex,
              let presenter = self.presenterSource?(), presenter.viewIfLoaded?.window != nil else { self.cancelReservation(presentation.token); return }
        if presentation.kind == "alert" {
            guard presenter.presentedViewController == nil, self.dialogs.isEmpty else { self.cancelReservation(presentation.token); return }
            let alert = UIAlertController(title: presentation.title, message: presentation.text, preferredStyle: .alert)
            for action in presentation.actions {
                alert.addAction(UIAlertAction(title: action.title, style: action.isCancel ? .cancel : .default) { [weak self, weak alert] _ in
                    guard let self, self.isCurrent(presentation.token, owner: presentation.owner, generation: presentation.generation) else { return }
                    self.cancelReservation(presentation.token)
                    self.dialogs.removeValue(forKey: presentation.token)
                    // Deliver after native dismissal, so a callback can safely
                    // present another alert/bulletin without racing this modal.
                    alert?.dismiss(animated: true) { action.callback?.send([reference, .integer(action.which)]) }
                })
            }
            self.dialogs[presentation.token] = alert
            if let alertPresenter = self.alertPresenter { alertPresenter(alert) }
            else { presenter.present(alert, animated: true) }
        } else {
            let label = UILabel()
            label.text = presentation.text; label.numberOfLines = 0
            label.textColor = .white; label.font = .preferredFont(forTextStyle: .subheadline)
            label.textAlignment = .center; label.isAccessibilityElement = true
            let container = UIView()
            container.backgroundColor = presentation.style == "error" ? .systemRed : presentation.style == "success" ? .systemGreen : .darkGray
            container.layer.cornerRadius = 12
            container.addSubview(label); presenter.view.addSubview(container)
            container.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: presenter.view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                container.trailingAnchor.constraint(equalTo: presenter.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
                container.bottomAnchor.constraint(equalTo: presenter.view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12), label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12), label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
            ])
            self.bulletins[presentation.token] = container
            UIAccessibility.post(notification: .announcement, argument: presentation.text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.isCurrent(presentation.token, owner: presentation.owner, generation: presentation.generation) else { return }
                self.cancelReservation(presentation.token); self.removePresentation(presentation.token)
            }
        }
    }

    @MainActor private func removePresentation(_ token: String) {
        self.dialogs.removeValue(forKey: token)?.dismiss(animated: false)
        self.bulletins.removeValue(forKey: token)?.removeFromSuperview()
    }
}
