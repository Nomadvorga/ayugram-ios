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
    public let isGroup: Bool
    public let isChannel: Bool
    public init(identity: UUID, accountIndex: Int64, dialogID: Int64? = nil, isGroup: Bool = false, isChannel: Bool = false) {
        self.identity = identity; self.accountIndex = accountIndex; self.dialogID = dialogID
        self.isGroup = isGroup; self.isChannel = isChannel
    }
    var state: [String: AyuBridgeValue] { ["screenIdentity": .string(self.identity.uuidString), "accountIndex": .integer(self.accountIndex)] }
}

/// Compiled account/context/UI adapter. Native account snapshots are pushed by
/// TelegramUI; UI closures are used only on main and never run Python there.
/// The default service installs this provider, but absent bindings fail closed.
public struct AyuPluginSendHook: Sendable {
    public let pluginID: String
    public let callbackID: String
    public let priority: Int
}

public protocol AyuPluginSendHookSource: AnyObject, Sendable {
    func sendHooks() -> [AyuPluginSendHook]
}

public final class AyuPluginApplicationBridge: AyuPluginHostProvider, AyuPluginSendHookSource, AyuPluginDialogHost, @unchecked Sendable {
    public static let shared = AyuPluginApplicationBridge()
    public let capabilities = ["client.call", "ui.present", "hooks.register", "hooks.unregister"]
    private let lock = NSLock()
    private var accounts: [Int64: AyuPluginAccountSnapshot] = [:]
    private var selected: Int64?
    private var ownerGenerations: [String: UUID] = [:]
    private struct SendHook { let owner: String; let callbackID: String; let priority: Int; let order: UInt64 }
    private var sendHooksByToken: [String: SendHook] = [:]
    private var pendingSendHooks: [String: Reservation] = [:]
    private var sendHookOrder: UInt64 = 0
    private struct Reservation { let owner: String; let generation: UUID }
    private var reservations: [String: Reservation] = [:]
    private var clipboardReservations: [String: Reservation] = [:]
    private struct URLReservation {
        let owner: String
        let generation: UUID
        let account: AyuPluginAccountSnapshot
        let screen: AyuPluginScreenSnapshot
        let url: URL
    }
    private var urlReservations: [String: URLReservation] = [:]
    private let clipboardWriter: @MainActor @Sendable (String) -> Void
    // Descriptor ids are stable host-owned state; every show gets a fresh token.
    private var feedbackTokens: [String: String] = [:]
    private struct Observation { let event: Int64; let sink: AyuBridgeNativeCallback }
    private var observations: [String: [String: Observation]] = [:]
    @MainActor private var screenSource: (() -> AyuPluginScreenSnapshot?)?
    @MainActor private var localeIdentifierSource: (() -> String)?
    @MainActor private var presenterSource: (() -> UIViewController?)?
    @MainActor private var urlOpenerSource: ((AyuPluginScreenSnapshot, URL) -> Void)?
    // Read by worker-side preparation; written by bindScreen under `lock`.
    private var urlRouteBound = false
    @MainActor private var alertPresenter: ((UIAlertController) -> Void)?
    @MainActor private var dialogs: [String: UIViewController] = [:]
    @MainActor private var bulletins: [String: UIView] = [:]
    @MainActor private var bulletinScreens: [String: AyuPluginScreenSnapshot] = [:]
    @MainActor private var appBulletin: UIView?
    @MainActor private var appBulletinGeneration: Int = 0

    public init() { self.clipboardWriter = { UIPasteboard.general.string = $0 } }

    // Synthetic tests exercise commit/revoke without touching the device pasteboard.
    init(clipboardWriter: @escaping @MainActor @Sendable (String) -> Void) {
        self.clipboardWriter = clipboardWriter
    }

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
    @MainActor public func bindScreen(screen: @escaping () -> AyuPluginScreenSnapshot?, presenter: @escaping () -> UIViewController?, presentAlert: ((UIAlertController) -> Void)? = nil,
                                      openURL: ((AyuPluginScreenSnapshot, URL) -> Void)? = nil,
                                      localeIdentifier: (() -> String)? = nil) {
        self.invalidatePresentations()
        self.screenSource = screen; self.presenterSource = presenter; self.alertPresenter = presentAlert; self.urlOpenerSource = openURL
        self.localeIdentifierSource = localeIdentifier
        self.lock.lock(); self.urlRouteBound = openURL != nil; self.lock.unlock()
    }

    /// Lock/background/account transitions remove only bridge-owned UI. No
    /// dismissal callbacks are fabricated for revoked presentations.
    @MainActor public func invalidatePresentations() {
        self.lock.lock(); let tokens = Array(self.reservations.keys); self.reservations.removeAll(); self.feedbackTokens.removeAll(); self.clipboardReservations.removeAll(); self.urlReservations.removeAll(); self.lock.unlock()
        for token in tokens { self.removePresentation(token) }
    }

    /// App-owned feedback for native adapters. It uses the same explicit
    /// presenter as plugin bulletins but has no plugin reservation or callback.
    @MainActor public func showBulletin(_ text: String, style: String = "simple", in hostView: UIView? = nil) {
        let view = hostView ?? self.presenterSource?()?.viewIfLoaded
        guard text.utf8.count <= 4096, !text.isEmpty, let view, view.window != nil else { return }
        self.appBulletin?.removeFromSuperview()
        self.appBulletinGeneration += 1
        let generation = self.appBulletinGeneration
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textAlignment = .center
        label.isAccessibilityElement = true
        let container = UIView()
        container.backgroundColor = style == "error" ? .systemRed : style == "success" ? .systemGreen : .darkGray
        container.layer.cornerRadius = 12
        container.addSubview(label)
        view.addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        self.appBulletin = container
        UIAccessibility.post(notification: .announcement, argument: text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak container] in
            guard let self, let container, self.appBulletinGeneration == generation, self.appBulletin === container else { return }
            container.removeFromSuperview()
            self.appBulletin = nil
        }
    }

    public func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
        // This provider needs the host-owned context, including result wrapping.
        throw AyuBridgeFailure.unsupported(operation)
    }

    public func prepareCall(pluginID: String, operation: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        guard !Thread.isMainThread, context.pluginID == pluginID else { throw AyuBridgeFailure("wrong_thread", "Application adapter is worker-only") }
        if operation == "ui.present" { return try self.preparePresentation(arguments, context: context) }
        if operation == "hooks.register" { return try self.prepareSendHook(arguments, context: context) }
        if operation == "hooks.unregister" {
            guard Set(arguments.keys) == ["token"], let token = arguments["token"]?.string, UUID(uuidString: token) != nil else { throw Self.invalid() }
            self.lock.lock()
            let owner = self.sendHooksByToken[token]?.owner ?? self.pendingSendHooks[token]?.owner
            self.lock.unlock()
            guard owner == nil || owner == pluginID else { throw AyuBridgeFailure("invalid_handle", "Send hook token belongs to another plugin") }
            return AyuBridgeProviderResult(.value(.null), commit: { _ in self.removeSendHook(token: token, owner: pluginID) })
        }
        guard operation == "client.call", Set(arguments.keys) == ["name", "args", "kwargs"],
              let name = arguments["name"]?.string, let args = arguments["args"]?.array,
              let kwargs = arguments["kwargs"]?.object else { throw AyuBridgeFailure("invalid_arguments", "Invalid client helper arguments") }
        if name == "copy_to_clipboard" {
            guard kwargs.isEmpty, args.count == 1, let text = args[0].string, text.utf8.count <= 65_536 else { throw Self.invalid() }
            return try self.prepareClipboard(text, owner: pluginID)
        }
        guard args.isEmpty else { throw Self.invalid() }
        switch name {
        case "get_selected_account":
            guard kwargs.isEmpty else { throw Self.invalid() }
            return AyuBridgeProviderResult(.value(.integer(try self.account(nil).index)))
        case "get_user_config":
            guard Set(kwargs.keys).isSubset(of: ["account"]) else { throw Self.invalid() }
            return AyuBridgeProviderResult(.instance(className: Self.userConfig, state: try self.account(kwargs["account"]).state))
        case "get_messages_controller":
            guard Set(kwargs.keys).isSubset(of: ["account"]) else { throw Self.invalid() }
            return AyuBridgeProviderResult(.instance(className: Self.messagesController, state: try self.account(kwargs["account"]).state))
        case "get_account_instance":
            guard Set(kwargs.keys).isSubset(of: ["account"]) else { throw Self.invalid() }
            return AyuBridgeProviderResult(.instance(className: Self.accountInstance, state: try self.account(kwargs["account"]).state))
        case "get_last_fragment":
            guard kwargs.isEmpty else { throw Self.invalid() }
            guard let screen = self.currentScreen() else { return AyuBridgeProviderResult(.value(.null)) }
            _ = try self.account(.integer(screen.accountIndex))
            return AyuBridgeProviderResult(.instance(className: Self.fragment, state: screen.state))
        case "get_notification_center":
            guard Set(kwargs.keys).isSubset(of: ["account"]) else { throw Self.invalid() }
            guard kwargs["account"] == nil || kwargs["account"] == .null else { throw AyuBridgeFailure.unsupported("account-scoped NotificationCenter") }
            return AyuBridgeProviderResult(.instance(className: Self.notificationCenter, state: Self.notificationCenterState))
        default: throw AyuBridgeFailure.unsupported("client_utils." + name)
        }
    }

    public func detach(pluginID: String) {
        self.lock.lock()
        self.ownerGenerations.removeValue(forKey: pluginID)
        self.clipboardReservations = self.clipboardReservations.filter { $0.value.owner != pluginID }
        self.urlReservations = self.urlReservations.filter { $0.value.owner != pluginID }
        self.observations.removeValue(forKey: pluginID)
        let hookTokens = self.sendHooksByToken.filter { $0.value.owner == pluginID }.map(\.key)
        for token in hookTokens { self.sendHooksByToken.removeValue(forKey: token) }
        let pendingTokens = self.pendingSendHooks.filter { $0.value.owner == pluginID }.map(\.key)
        for token in pendingTokens { self.pendingSendHooks.removeValue(forKey: token) }
        let tokens = self.reservations.filter { $0.value.owner == pluginID }.map(\.key)
        for token in tokens { self.reservations.removeValue(forKey: token) }
        let revoked = Set(tokens)
        self.feedbackTokens = self.feedbackTokens.filter { !revoked.contains($0.value) }
        self.lock.unlock()
        DispatchQueue.main.async { for token in tokens { self.removePresentation(token) } }
    }

    private func prepareClipboard(_ text: String, owner: String) throws -> AyuBridgeProviderResult {
        guard let screen = self.currentScreen() else { throw AyuBridgeFailure("screen_unavailable", "Clipboard requires a visible screen") }
        let account = try self.account(.integer(screen.accountIndex))
        let token = UUID().uuidString
        self.lock.lock()
        guard self.clipboardReservations.count < 16,
              self.clipboardReservations.values.filter({ $0.owner == owner }).count < 4 else {
            self.lock.unlock(); throw AyuBridgeFailure("resource_limit", "Clipboard quota exceeded")
        }
        let generation = self.ownerGenerations[owner] ?? UUID()
        self.ownerGenerations[owner] = generation
        self.clipboardReservations[token] = Reservation(owner: owner, generation: generation)
        self.lock.unlock()
        return AyuBridgeProviderResult(.value(.null), rollback: {
            self.lock.lock(); self.clipboardReservations.removeValue(forKey: token); self.lock.unlock()
        }, commit: { _ in
            DispatchQueue.main.async {
                // Consume once even if the caller accidentally commits twice.
                self.lock.lock()
                let reservation = self.clipboardReservations.removeValue(forKey: token)
                let valid = reservation?.owner == owner && reservation?.generation == generation
                    && self.ownerGenerations[owner] == generation
                    && self.accounts[account.index]?.identity == account.identity
                self.lock.unlock()
                guard valid, let current = self.screenSource?(), current.identity == screen.identity,
                      current.accountIndex == screen.accountIndex else { return }
                self.clipboardWriter(text)
                self.showBulletin("Copied to clipboard")
            }
        })
    }

    private func prepareBrowserOpenURL(_ contextValue: AyuBridgeValue, urlValue: AyuBridgeValue, owner: String,
                                       context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        let contextSnapshot = try context.snapshot(of: contextValue)
        guard [Self.fragment, Self.context].contains(contextSnapshot.className) else { throw Self.invalid() }
        guard self.isURLRouteBound() else { throw AyuBridgeFailure("screen_unavailable", "Telegram URL route is not bound") }
        // Resolve the owned immutable handle on the worker. Visibility is checked
        // by the queued effect so preparation never waits for the main thread.
        guard let identityString = contextSnapshot.state["screenIdentity"]?.string,
              let identity = UUID(uuidString: identityString),
              let accountIndex = contextSnapshot.state["accountIndex"]?.integer else { throw Self.invalid() }
        let screen = AyuPluginScreenSnapshot(identity: identity, accountIndex: accountIndex)
        let account = try self.account(.integer(screen.accountIndex))
        let url = try Self.browserURL(urlValue, context: context)
        let token = UUID().uuidString
        self.lock.lock()
        let generation = self.ownerGenerations[owner] ?? UUID()
        self.ownerGenerations[owner] = generation
        guard self.urlReservations.count < 16,
              self.urlReservations.values.filter({ $0.owner == owner }).count < 4 else {
            self.lock.unlock(); throw AyuBridgeFailure("resource_limit", "Browser URL dispatch quota exceeded")
        }
        self.urlReservations[token] = URLReservation(owner: owner, generation: generation, account: account, screen: screen, url: url)
        self.lock.unlock()
        return AyuBridgeProviderResult(.value(.null), rollback: {
            self.lock.lock(); self.urlReservations.removeValue(forKey: token); self.lock.unlock()
        }, commit: { _ in
            DispatchQueue.main.async {
                self.lock.lock()
                let reservation = self.urlReservations.removeValue(forKey: token)
                let valid: Bool
                if let reservation {
                    valid = reservation.owner == owner && reservation.generation == generation
                        && self.ownerGenerations[owner] == generation
                        && self.accounts[reservation.account.index]?.identity == reservation.account.identity
                } else {
                    valid = false
                }
                self.lock.unlock()
                guard valid, let reservation,
                      let current = self.screenSource?(), current.identity == reservation.screen.identity,
                      current.accountIndex == reservation.screen.accountIndex else { return }
                self.urlOpenerSource?(reservation.screen, reservation.url)
            }
        })
    }

    private func isURLRouteBound() -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.urlRouteBound
    }

    private static func browserURL(_ value: AyuBridgeValue, context: AyuBridgeAdapterContext) throws -> URL {
        let string: String
        if let supplied = value.string {
            string = supplied
        } else {
            guard value.object?["$handle"]?.string != nil else { throw Self.invalid() }
            let uri = try context.snapshot(of: value)
            guard uri.className == "android.net.Uri", let supplied = uri.state["value"]?.string else { throw Self.invalid() }
            string = supplied
        }
        guard string.utf8.count <= 8_192,
              string == string.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url, url.baseURL == nil else { throw Self.invalid() }
        guard scheme == "http" || scheme == "https" else { throw AyuBridgeFailure.unsupported("Browser.openUrl URL scheme") }
        if let port = components.port, !(1...65_535).contains(port) { throw Self.invalid() }
        return url
    }

    private func prepareSendHook(_ arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        guard let kind = arguments["kind"]?.string else { throw Self.invalid() }
        guard kind == "send_message" else { throw AyuBridgeFailure.unsupported("hook kind") }
        guard Set(arguments.keys) == ["kind", "priority", "callback"],
              let priority = arguments["priority"]?.integer, priority >= Int64(Int32.min), priority <= Int64(Int32.max),
              let callback = arguments["callback"] else { throw Self.invalid() }
        _ = try context.callback(callback)
        guard let callbackID = callback.object?["$callback"]?.string, !callbackID.isEmpty else { throw Self.invalid() }
        let owner = context.pluginID
        let token = UUID().uuidString
        self.lock.lock()
        let ownedCount = self.sendHooksByToken.values.filter { $0.owner == owner }.count
            + self.pendingSendHooks.values.filter { $0.owner == owner }.count
        guard ownedCount < 16, self.sendHooksByToken.count + self.pendingSendHooks.count < 256 else {
            self.lock.unlock(); throw AyuBridgeFailure("resource_limit", "Send hook quota exceeded")
        }
        let generation = self.ownerGenerations[owner] ?? UUID()
        self.ownerGenerations[owner] = generation
        self.pendingSendHooks[token] = Reservation(owner: owner, generation: generation)
        self.lock.unlock()
        return AyuBridgeProviderResult(.value(.string(token)), rollback: {
            self.lock.lock(); self.pendingSendHooks.removeValue(forKey: token); self.lock.unlock()
        }, commit: { _ in
            self.lock.lock()
            guard let reservation = self.pendingSendHooks.removeValue(forKey: token),
                  self.ownerGenerations[owner] == reservation.generation else { self.lock.unlock(); return }
            self.sendHookOrder &+= 1
            self.sendHooksByToken[token] = SendHook(owner: owner, callbackID: callbackID, priority: Int(priority), order: self.sendHookOrder)
            self.lock.unlock()
        })
    }

    private func removeSendHook(token: String, owner: String) {
        self.lock.lock()
        if self.sendHooksByToken[token]?.owner == owner { self.sendHooksByToken.removeValue(forKey: token) }
        if self.pendingSendHooks[token]?.owner == owner { self.pendingSendHooks.removeValue(forKey: token) }
        self.lock.unlock()
    }

    /// Snapshot used by the app's send path. Higher priority first, then
    /// registration order, matching the Android hook dispatcher.
    public func sendHooks() -> [AyuPluginSendHook] {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.sendHooksByToken.values.sorted { left, right in
            left.priority == right.priority ? left.order < right.order : left.priority > right.priority
        }.map { AyuPluginSendHook(pluginID: $0.owner, callbackID: $0.callbackID, priority: $0.priority) }
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

    private func profile(_ account: AyuPluginAccountSnapshot) throws -> AyuBridgeAdapterResult {
        guard let user = account.user else { throw AyuBridgeFailure("data_unavailable", "Own profile snapshot is not ready") }
        return .instance(className: Self.user, state: user)
    }

    private func visibleChat(account: AyuPluginAccountSnapshot, id: Int64) -> AyuBridgeAdapterResult {
        guard let screen = self.currentScreen(), screen.accountIndex == account.index,
              let dialogID = screen.dialogID, dialogID < 0, dialogID != Int64.min,
              dialogID == -id else { return .value(.null) }
        return .instance(className: Self.chat, state: [
            "id": .integer(-dialogID), "broadcast": .bool(screen.isChannel), "megagroup": .bool(screen.isGroup)
        ])
    }

    public func classRegistry() throws -> AyuBridgeClassRegistry {
        let localeControllerAdapter = AyuBridgeClassAdapter(name: Self.localeController,
            staticMethods: ["getInstance": { args, _ in
                guard args.isEmpty else { throw Self.invalid() }
                return .instance(className: Self.localeController, state: self.localeControllerState())
            }], methods: [
                "isRTL": { state, args, _ in
                    guard args.isEmpty else { throw Self.invalid() }
                    try Self.validateLocaleControllerState(state)
                    let language = state["language"]?.string ?? ""
                    return .value(.bool(NSLocale.characterDirection(forLanguage: language) == .rightToLeft))
                },
                "getCurrentLocale": { state, args, _ in
                    guard args.isEmpty else { throw Self.invalid() }
                    try Self.validateLocaleControllerState(state)
                    let identifier = state["identifier"]?.string ?? ""
                    let locale = Locale(identifier: identifier) as NSLocale
                    return .instance(className: "java.util.Locale", state: [
                        "identifier": .string(identifier),
                        "language": .string(locale.object(forKey: .languageCode) as? String ?? ""),
                        "country": .string(locale.object(forKey: .countryCode) as? String ?? ""),
                        "variant": .string(locale.object(forKey: .variantCode) as? String ?? ""),
                    ])
                },
                "getCurrentLocaleInfo": { state, args, _ in
                    guard args.isEmpty else { throw Self.invalid() }
                    try Self.validateLocaleControllerState(state)
                    return .instance(className: Self.localeInfo, state: [
                        "pluralLangCode": .string(Self.pluralLanguageCode(forLanguage: state["language"]?.string ?? "")),
                    ])
                },
            ], validateState: Self.validateLocaleControllerState)
        let localeInfoAdapter = AyuBridgeClassAdapter(name: Self.localeInfo,
            readableFields: ["pluralLangCode"], validateState: { state in
                guard Set(state.keys) == ["pluralLangCode"],
                      let code = state["pluralLangCode"]?.string,
                      (1...32).contains(code.utf8.count),
                      code.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else {
                    throw Self.invalid()
                }
            })
        let accountAdapter = AyuBridgeClassAdapter(name: Self.userConfig,
            staticMethods: ["getInstance": { args, _ in
                guard args.count == 1 else { throw Self.invalid() }
                return .instance(className: Self.userConfig, state: try self.account(args[0]).state)
            }], staticFields: ["selectedAccount": { _ in .value(.integer(try self.account(nil).index)) }], methods: [
                "getClientUserId": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; return .value(.integer(try self.account(state: state).userID)) },
                "isClientActivated": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; _ = try self.account(state: state); return .value(.bool(true)) },
                "getCurrentUser": { state, args, _ in
                    guard args.isEmpty else { throw Self.invalid() }
                    return try self.profile(self.account(state: state))
                }
            ], validateState: { state in try Self.validateIdentityState(state, identity: "accountIdentity") })
        let accountInstanceAdapter = AyuBridgeClassAdapter(name: Self.accountInstance,
            staticMethods: ["getInstance": { args, _ in
                guard args.count == 1 else { throw Self.invalid() }
                return .instance(className: Self.accountInstance, state: try self.account(args[0]).state)
            }], methods: [
                "getCurrentAccount": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; return .value(.integer(try self.account(state: state).index)) },
                "getUserConfig": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; return .instance(className: Self.userConfig, state: try self.account(state: state).state) },
                "getMessagesController": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; return .instance(className: Self.messagesController, state: try self.account(state: state).state) }
            ], validateState: { state in try Self.validateIdentityState(state, identity: "accountIdentity") })
        let userAdapter = AyuBridgeClassAdapter(name: Self.user, readableFields: ["id", "first_name", "last_name", "username"], validateState: { state in
            guard Set(state.keys) == ["id", "first_name", "last_name", "username"], let id = state["id"]?.integer, id > 0,
                  state["first_name"]?.string != nil, state["last_name"]?.string != nil,
                  state["username"] == .null || state["username"]?.string != nil,
                  state.values.allSatisfy({ ($0.string?.utf8.count ?? 0) <= 1024 }) else { throw Self.invalid() }
        })
        let fragmentAdapter = AyuBridgeClassAdapter(name: Self.fragment, methods: [
            "getCurrentAccount": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; return .value(.integer(try self.screen(state: state).accountIndex)) },
            "getAccountInstance": { state, args, _ in
                guard args.isEmpty else { throw Self.invalid() }
                return .instance(className: Self.accountInstance, state: try self.account(.integer(self.screen(state: state).accountIndex)).state)
            },
            "getUserConfig": { state, args, _ in
                guard args.isEmpty else { throw Self.invalid() }
                return .instance(className: Self.userConfig, state: try self.account(.integer(self.screen(state: state).accountIndex)).state)
            },
            "getMessagesController": { state, args, _ in
                guard args.isEmpty else { throw Self.invalid() }
                return .instance(className: Self.messagesController, state: try self.account(.integer(self.screen(state: state).accountIndex)).state)
            },
            "getDialogId": { state, args, _ in
                guard args.isEmpty else { throw Self.invalid() }
                guard let id = try self.screen(state: state).dialogID, id != 0, id != Int64.min else { throw AyuBridgeFailure.unsupported("getDialogId on a non-chat screen") }
                return .value(.integer(id))
            },
            "getParentActivity": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; return .instance(className: Self.context, state: try self.screen(state: state).state) },
            "getContext": { state, args, _ in guard args.isEmpty else { throw Self.invalid() }; return .instance(className: Self.context, state: try self.screen(state: state).state) }
        ], validateState: { state in try Self.validateIdentityState(state, identity: "screenIdentity") })
        let contextAdapter = AyuBridgeClassAdapter(name: Self.context, methods: [
            "getResources": { state, args, _ in
                guard args.isEmpty else { throw Self.invalid() }
                let screen = try self.screen(state: state)
                return .instance(className: Self.resourceManager, state: screen.state)
            }
        ], validateState: { state in try Self.validateIdentityState(state, identity: "screenIdentity") })
        let resourcesAdapter = AyuBridgeClassAdapter(name: Self.resourceManager, methods: [
            "getConfiguration": { state, args, _ in
                guard args.isEmpty else { throw Self.invalid() }
                let screen = try self.screen(state: state)
                return .instance(className: Self.configuration, state: try self.configurationState(screen))
            },
            "getDisplayMetrics": { state, args, _ in
                guard args.isEmpty else { throw Self.invalid() }
                let screen = try self.screen(state: state)
                return .instance(className: Self.displayMetrics, state: try self.displayMetricsState(screen))
            }
        ], validateState: { state in try Self.validateIdentityState(state, identity: "screenIdentity") })
        let configurationAdapter = AyuBridgeClassAdapter(name: Self.configuration,
            constants: ["ORIENTATION_UNDEFINED": .integer(0), "ORIENTATION_PORTRAIT": .integer(1), "ORIENTATION_LANDSCAPE": .integer(2)],
            readableFields: ["orientation"], validateState: { state in
                try Self.validateIdentityState(state.filter { $0.key != "orientation" }, identity: "screenIdentity")
                guard Set(state.keys) == ["accountIndex", "screenIdentity", "orientation"],
                      let orientation = state["orientation"]?.integer, (0...2).contains(orientation) else { throw Self.invalid() }
                _ = try self.screen(state: ["accountIndex": state["accountIndex"] ?? .null,
                                            "screenIdentity": state["screenIdentity"] ?? .null])
            })
        let displayMetricsAdapter = AyuBridgeClassAdapter(name: Self.displayMetrics,
            readableFields: ["density", "densityDpi", "widthPixels", "heightPixels"], validateState: { state in
                let fields: Set<String> = ["density", "densityDpi", "widthPixels", "heightPixels"]
                try Self.validateIdentityState(state.filter { !fields.contains($0.key) }, identity: "screenIdentity")
                guard Set(state.keys) == fields.union(["accountIndex", "screenIdentity"]),
                      let density = state["density"]?.number, density.isFinite, density > 0, density <= 16,
                      let dpi = state["densityDpi"]?.integer, dpi > 0, dpi <= 2560,
                      let width = state["widthPixels"]?.integer, width > 0, width <= 100_000,
                      let height = state["heightPixels"]?.integer, height > 0, height <= 100_000 else { throw Self.invalid() }
            })
        let messagesControllerAdapter = AyuBridgeClassAdapter(name: Self.messagesController,
            staticMethods: ["getInstance": { args, _ in
                guard args.count == 1 else { throw Self.invalid() }
                return .instance(className: Self.messagesController, state: try self.account(args[0]).state)
            }], methods: [
            "getUser": { state, args, _ in
                guard args.count == 1, let userID = args[0].integer, userID > 0 else { throw Self.invalid() }
                let account = try self.account(state: state)
                guard userID == account.userID else { return .value(.null) }
                return try self.profile(account)
            },
            "getChat": { state, args, _ in
                guard args.count == 1, let chatID = args[0].integer, chatID > 0 else { throw Self.invalid() }
                return try self.visibleChat(account: self.account(state: state), id: chatID)
            }
        ], validateState: { state in try Self.validateIdentityState(state, identity: "accountIdentity") })
        let chatAdapter = AyuBridgeClassAdapter(name: Self.chat, readableFields: ["id", "broadcast", "megagroup"], validateState: { state in
            guard Set(state.keys) == ["id", "broadcast", "megagroup"], let id = state["id"]?.integer, id > 0,
                  state["broadcast"]?.bool != nil, state["megagroup"]?.bool != nil else { throw Self.invalid() }
        })
        let themeAdapter = AyuBridgeClassAdapter(name: Self.theme,
            constants: Self.themeKeys,
            staticMethods: ["getColor": { args, _ in
                guard args.count == 1, let key = args[0].integer, key >= 1, key <= Int64(Self.themeKeyNames.count) else { throw Self.invalid() }
                return .value(.integer(try self.themeColor(key)))
            }, "isDarkThemeEnabled": { args, _ in
                guard args.isEmpty else { throw Self.invalid() }
                return .value(.bool(try self.withPresentationTraits { $0.userInterfaceStyle == .dark }))
            }])
        let typedValueAdapter = AyuBridgeClassAdapter(name: Self.typedValue,
            constants: ["COMPLEX_UNIT_DIP": .integer(1), "COMPLEX_UNIT_PX": .integer(0), "COMPLEX_UNIT_SP": .integer(2)],
            staticMethods: ["applyDimension": { args, context in
                guard args.count == 3, let unit = args[0].integer,
                      let value = args[1].number, value.isFinite, abs(value) <= 100_000 else { throw Self.invalid() }
                guard (0...2).contains(unit) else { throw AyuBridgeFailure.unsupported("TypedValue.applyDimension unit") }
                let metrics = try context.snapshot(of: args[2])
                guard metrics.className == Self.displayMetrics, let density = metrics.state["density"]?.number else { throw Self.invalid() }
                _ = try self.screen(state: ["accountIndex": metrics.state["accountIndex"] ?? .null, "screenIdentity": metrics.state["screenIdentity"] ?? .null])
                return .value(.number(unit == 0 ? value : value * density))
            }])
        let stringAdapter = AyuBridgeClassAdapter(name: Self.javaString, methods: [
                "toString": { state, args, _ in guard args.isEmpty, let value = state["value"]?.string else { throw Self.invalid() }; return .value(.string(value)) },
                "length": { state, args, _ in guard args.isEmpty, let value = state["value"]?.string else { throw Self.invalid() }; return .value(.integer(Int64(value.utf16.count))) }
            ], readableFields: ["value"], validateState: { state in
                guard Set(state.keys) == ["value"], let value = state["value"]?.string, value.utf8.count <= 65_536 else { throw Self.invalid() }
            })
        let bulletinFactoryAdapter = AyuBridgeClassAdapter(name: Self.bulletinFactory,
            staticMethods: [
                "of": { args, context in
                    guard args.count == 1 else { throw Self.invalid() }
                    let snapshot = try context.snapshot(of: args[0])
                    guard [Self.fragment, Self.context].contains(snapshot.className) else { throw Self.invalid() }
                    return .instance(className: Self.bulletinFactory, state: try self.screen(state: snapshot.state).state)
                },
                "global": { args, _ in
                    guard args.isEmpty else { throw Self.invalid() }
                    guard let screen = self.currentScreen() else { throw AyuBridgeFailure("screen_unavailable", "No visible bulletin context") }
                    _ = try self.account(.integer(screen.accountIndex))
                    return .instance(className: Self.bulletinFactory, state: screen.state)
                }
            ], methods: [
                "createErrorBulletin": { state, args, _ in
                    return try self.feedbackDescriptor(className: Self.bulletin, screenState: state, args: args, style: "error", duration: 3000)
                },
                "createSuccessBulletin": { state, args, _ in
                    return try self.feedbackDescriptor(className: Self.bulletin, screenState: state, args: args, style: "success", duration: 3000)
                }
            ], validateState: { state in try Self.validateIdentityState(state, identity: "screenIdentity") })
        let bulletinAdapter = AyuBridgeClassAdapter(name: Self.bulletin, methods: [
            "setDuration": { state, args, context in
                guard args.count == 1, let duration = args[0].integer, (1...10_000).contains(duration) else { throw Self.invalid() }
                if let descriptor = state["token"]?.string, let token = self.feedbackToken(descriptor), self.isCurrent(token, owner: context.pluginID) {
                    throw AyuBridgeFailure("invalid_state", "Cannot change the duration of a pending or visible bulletin")
                }
                state["duration_ms"] = .integer(duration)
                return .value(.null)
            },
            "show": { state, args, context in
                guard args.isEmpty else { throw Self.invalid() }
                return .prepared(try self.prepareFeedback(&state, context: context))
            },
            "isShowing": { state, args, context in
                guard args.isEmpty else { throw Self.invalid() }
                guard let descriptor = state["token"]?.string, let token = self.feedbackToken(descriptor) else { return .value(.bool(false)) }
                return .value(.bool(self.isShowing(token, owner: context.pluginID)))
            }
        ], validateState: Self.validateFeedbackState)
        let photoViewerAdapter = AyuBridgeClassAdapter(name: Self.photoViewer,
            staticMethods: ["getInstance": { args, _ in guard args.isEmpty else { throw Self.invalid() }; throw AyuBridgeFailure.unsupported("PhotoViewer.getInstance") }])
        let toastAdapter = AyuBridgeClassAdapter(name: Self.toast,
            constants: ["LENGTH_SHORT": .integer(0), "LENGTH_LONG": .integer(1)],
            staticMethods: ["makeText": { args, context in
                guard (2...3).contains(args.count), let text = args[1].string,
                      text.utf8.count <= 4096 else { throw Self.invalid() }
                let snapshot = try context.snapshot(of: args[0])
                guard [Self.context, Self.fragment].contains(snapshot.className) else { throw Self.invalid() }
                var duration: Int64 = 2000
                if args.count == 3 {
                    guard let supplied = args[2].integer, supplied == 0 || supplied == 1 else { throw Self.invalid() }
                    duration = supplied == 0 ? 2000 : 3500
                }
                return try self.feedbackDescriptor(className: Self.toast, screenState: snapshot.state, args: [.string(text)], style: "simple", duration: duration)
            }], methods: [
                "show": { state, args, context in
                    guard args.isEmpty else { throw Self.invalid() }
                    return .prepared(try self.prepareFeedback(&state, context: context))
                }
            ], validateState: Self.validateFeedbackState)
        let androidUtilitiesAdapter = AyuBridgeClassAdapter(name: Self.androidUtilities, staticMethods: [
            "dp": { args, _ in
                guard args.count == 1, let value = args[0].number, value.isFinite, abs(value) <= 100_000 else { throw Self.invalid() }
                // Android dp(float) rounds density-scaled dimensions upward.
                // Bridge layout uses UIKit points (density 1), so preserve point
                // units and do not multiply by the physical screen pixel scale.
                return .value(.integer(Int64(ceil(value))))
            },
            "dpf2": { args, _ in
                guard args.count == 1, let value = args[0].number, value.isFinite, abs(value) <= 100_000 else { throw Self.invalid() }
                // Fractional dp is already expressed in native UIKit points.
                return .value(.number(value))
            },
            "dpRatio": { args, _ in guard args.isEmpty else { throw Self.invalid() }; return .value(.number(Self.screenScale(main: true))) },
            "getPx": { args, _ in throw AyuBridgeFailure.unsupported("AndroidUtilities.getPx") },
            "addToClipboard": { args, context in
                guard args.count == 1, let text = args[0].string, text.utf8.count <= 65_536 else { throw Self.invalid() }
                return .prepared(try self.prepareClipboard(text, owner: context.pluginID))
            },
            "runOnUIThread": { args, context in
                guard args.count == 1 || args.count == 2 else { throw Self.invalid() }
                let runnable = try context.snapshot(of: args[0])
                guard runnable.className == "java.lang.Runnable" else {
                    throw AyuBridgeFailure.unsupported("AndroidUtilities.runOnUIThread callback")
                }
                let delay: Int64
                if args.count == 2 {
                    guard let value = args[1].integer, (0...60_000).contains(value) else {
                        throw AyuBridgeFailure("invalid_arguments", "AndroidUtilities delay is out of range")
                    }
                    delay = value
                } else {
                    delay = 0
                }
                let callback = try context.callback(args[0])
                let reservation = try context.schedule(callback, delayMilliseconds: delay)
                return .prepared(AyuBridgeProviderResult(.value(.null), rollback: reservation.rollback, commit: reservation.commit))
            }
        ])
        let applicationLoaderAdapter = AyuBridgeClassAdapter(name: Self.applicationLoader,
            staticFields: ["applicationContext": { _ in
                guard let screen = self.currentScreen() else {
                    throw AyuBridgeFailure("screen_unavailable", "No visible context for applicationContext")
                }
                _ = try self.account(.integer(screen.accountIndex))
                return .instance(className: Self.context, state: screen.state)
            }])
        let browserAdapter = AyuBridgeClassAdapter(name: Self.browser, staticMethods: [
            "openUrl": { args, context in
                guard args.count == 2 else { throw Self.invalid() }
                return .prepared(try self.prepareBrowserOpenURL(args[0], urlValue: args[1], owner: context.pluginID, context: context))
            }
        ])
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
        return try .standard.adding([localeControllerAdapter, localeInfoAdapter, accountAdapter, accountInstanceAdapter, userAdapter, fragmentAdapter, contextAdapter, resourcesAdapter, configurationAdapter, displayMetricsAdapter, messagesControllerAdapter, chatAdapter, themeAdapter, typedValueAdapter, stringAdapter, bulletinFactoryAdapter, bulletinAdapter, photoViewerAdapter, toastAdapter, applicationLoaderAdapter, browserAdapter, androidUtilitiesAdapter, dialogAdapter, notificationCenter, notificationDelegate])
    }

    private static let notificationCenter = "org.telegram.messenger.NotificationCenter"
    private static let notificationDelegate = "org.telegram.messenger.NotificationCenter$NotificationCenterDelegate"
    private static let resourceManager = "android.content.res.Resources"
    private static let configuration = "android.content.res.Configuration"
    private static let displayMetrics = "android.util.DisplayMetrics"
    private static let messagesController = "org.telegram.messenger.MessagesController"
    private static let accountInstance = "org.telegram.messenger.AccountInstance"
    private static let chat = "org.telegram.tgnet.TLRPC$Chat"
    private static let theme = "org.telegram.ui.ActionBar.Theme"
    /// Theme color-key names observed in the corpus. These map explicitly to
    /// UIKit semantic colors, not Telegram's unavailable application palette.
    private static let themeKeyNames = [
        "key_dialogTextBlack", "key_dialogTextHint", "key_windowBackgroundWhiteBlackText", "key_windowBackgroundWhite",
        "key_windowBackgroundWhiteGrayText", "key_chats_name", "key_chats_message", "key_chats_date",
        "key_chats_unreadCounter", "key_chats_secretName", "key_listSelector", "key_windowBackgroundGray",
        "key_switchTrack", "key_switchThumb", "key_actionBarDefault", "key_actionBarTitle",
    ]
    private static var themeKeys: [String: AyuBridgeValue] {
        var keys: [String: AyuBridgeValue] = [:]
        for (index, name) in themeKeyNames.enumerated() { keys[name] = .integer(Int64(index + 1)) }
        return keys
    }
    private static func screenScale(main: Bool) -> Double {
        // Android dp ≈ iOS pt on 1x density; return the plain scale factor.
        return main ? DispatchQueue.main.sync { UIScreen.main.scale / 3.0 * 3.0 } : UIScreen.main.scale / 3.0 * 3.0
    }
    private func displayMetricsState(_ screen: AyuPluginScreenSnapshot) throws -> [String: AyuBridgeValue] {
        try DispatchQueue.main.sync {
            guard self.screenSource?()?.identity == screen.identity,
                  let window = self.presenterSource?()?.viewIfLoaded?.window else {
                throw AyuBridgeFailure("screen_unavailable", "No visible display context")
            }
            let display = window.screen
            let scale = display.scale
            var state = screen.state
            state["density"] = .number(Double(scale))
            state["densityDpi"] = .integer(Int64((scale * 160).rounded()))
            state["widthPixels"] = .integer(Int64((display.bounds.width * scale).rounded()))
            state["heightPixels"] = .integer(Int64((display.bounds.height * scale).rounded()))
            return state
        }
    }
    private func configurationState(_ screen: AyuPluginScreenSnapshot) throws -> [String: AyuBridgeValue] {
        try DispatchQueue.main.sync {
            guard self.screenSource?()?.identity == screen.identity,
                  let window = self.presenterSource?()?.viewIfLoaded?.window else {
                throw AyuBridgeFailure("screen_unavailable", "No visible configuration context")
            }
            let orientation: Int64
            switch window.windowScene?.interfaceOrientation ?? .unknown {
            case .portrait, .portraitUpsideDown: orientation = 1
            case .landscapeLeft, .landscapeRight: orientation = 2
            case .unknown: orientation = 0
            @unknown default: orientation = 0
            }
            var state = screen.state
            state["orientation"] = .integer(orientation)
            return state
        }
    }
    private func withPresentationTraits<T: Sendable>(_ body: @MainActor (UITraitCollection) throws -> T) throws -> T {
        precondition(!Thread.isMainThread)
        return try DispatchQueue.main.sync {
            guard self.screenSource?() != nil, let presenter = self.presenterSource?(),
                  presenter.viewIfLoaded?.window != nil else { throw AyuBridgeFailure("screen_unavailable", "No visible theme context") }
            return try body(presenter.traitCollection)
        }
    }
    private func themeColor(_ key: Int64) throws -> Int64 {
        try self.withPresentationTraits { traits in
            let color: UIColor
            switch key {
            case 1, 3, 6, 16: color = .label
            case 2, 5, 7, 8: color = .secondaryLabel
            case 4, 15: color = .systemBackground
            case 9: color = .systemBlue
            case 10: color = .systemGreen
            case 11: color = .quaternarySystemFill
            case 12: color = .systemGroupedBackground
            case 13: color = .systemGray3
            case 14: color = .white
            default: throw Self.invalid()
            }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                throw AyuBridgeFailure("data_unavailable", "Theme color cannot be represented as ARGB")
            }
            let argb = UInt32((alpha * 255).rounded()) << 24 | UInt32((red * 255).rounded()) << 16
                | UInt32((green * 255).rounded()) << 8 | UInt32((blue * 255).rounded())
            return Int64(Int32(bitPattern: argb))
        }
    }
    private static let typedValue = "android.util.TypedValue"
    private static let javaString = "java.lang.String"
    private static let bulletinFactory = "org.telegram.ui.Components.BulletinFactory"
    private static let bulletin = "org.telegram.ui.Components.Bulletin"
    private static let photoViewer = "org.telegram.ui.PhotoViewer"
    private static let toast = "android.widget.Toast"
    private static let applicationLoader = "org.telegram.messenger.ApplicationLoader"
    private static let browser = "org.telegram.messenger.browser.Browser"
    private static let localeController = "org.telegram.messenger.LocaleController"
    private static let localeInfo = "org.telegram.messenger.LocaleController$LocaleInfo"
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
    private static let androidUtilities = "org.telegram.messenger.AndroidUtilities"
    private static let user = "org.telegram.tgnet.TLRPC$User"
    private static let fragment = "org.telegram.ui.ActionBar.BaseFragment"
    private static let context = "android.content.Context"
    private static let dialog = "org.telegram.ui.ActionBar.AlertDialog"
    private static func invalid() -> AyuBridgeFailure { AyuBridgeFailure("invalid_arguments", "Unsupported application adapter arguments") }

    private func localeControllerState() -> [String: AyuBridgeValue] {
        let requestedIdentifier = DispatchQueue.main.sync { self.localeIdentifierSource?() }
        let identifier = requestedIdentifier.flatMap { $0.utf8.count <= 128 ? $0 : nil } ?? Locale.current.identifier
        let locale = Locale(identifier: identifier)
        let nativeLocale = locale as NSLocale
        return [
            "identifier": .string(identifier),
            "language": .string(nativeLocale.object(forKey: .languageCode) as? String ?? ""),
        ]
    }

    private static func validateLocaleControllerState(_ state: [String: AyuBridgeValue]) throws {
        guard Set(state.keys) == ["identifier", "language"],
              let identifier = state["identifier"]?.string, identifier.utf8.count <= 128,
              let language = state["language"]?.string, language.utf8.count <= 32 else { throw Self.invalid() }
    }

    private static func pluralLanguageCode(forLanguage language: String) -> String {
        let language = language.lowercased()
        guard !language.isEmpty, language.utf8.count <= 32,
              language.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else {
            return "en"
        }
        // LocaleController's snapshot already extracts the language subtag from
        // regional identifiers such as ru_RU, uk-UA and en_GB.
        switch language {
        case "ru": return "ru"
        case "uk": return "uk"
        case "be": return "be"
        case "en": return "en"
        default: return language
        }
    }
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
    private static func validateFeedbackState(_ state: [String: AyuBridgeValue]) throws {
        guard Set(state.keys) == ["accountIndex", "screenIdentity", "text", "style", "duration_ms", "token"],
              let text = state["text"]?.string, !text.isEmpty, text.utf8.count <= 4096,
              ["simple", "success", "error"].contains(state["style"]?.string ?? ""),
              let duration = state["duration_ms"]?.integer, (1...10_000).contains(duration),
              UUID(uuidString: state["token"]?.string ?? "") != nil else { throw Self.invalid() }
        try Self.validateIdentityState(self.feedbackScreenState(state), identity: "screenIdentity")
    }

    private static func feedbackScreenState(_ state: [String: AyuBridgeValue]) -> [String: AyuBridgeValue] {
        ["accountIndex": state["accountIndex"] ?? .null, "screenIdentity": state["screenIdentity"] ?? .null]
    }

    private func feedbackDescriptor(className: String, screenState: [String: AyuBridgeValue], args: [AyuBridgeValue], style: String, duration: Int64) throws -> AyuBridgeAdapterResult {
        guard args.count == 1, let text = args[0].string, !text.isEmpty, text.utf8.count <= 4096 else { throw Self.invalid() }
        var state = try self.screen(state: screenState).state
        state["text"] = .string(text); state["style"] = .string(style)
        state["duration_ms"] = .integer(duration); state["token"] = .string(UUID().uuidString)
        return .instance(className: className, state: state)
    }

    private func prepareFeedback(_ state: inout [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        let screen = try self.screen(state: Self.feedbackScreenState(state))
        guard let descriptor = state["token"]?.string else { throw Self.invalid() }
        if let token = self.feedbackToken(descriptor), self.isCurrent(token, owner: context.pluginID) {
            throw AyuBridgeFailure("invalid_state", "Feedback is already pending or visible")
        }
        let token = UUID().uuidString
        let arguments: [String: AyuBridgeValue] = ["kind": .string("bulletin"), "config": .object([
            "style": state["style"] ?? .null, "text": state["text"] ?? .null, "duration_ms": state["duration_ms"] ?? .null
        ])]
        let prepared = try self.preparePresentation(arguments, context: context, expectedScreen: screen.identity, token: token)
        // Showing must not grow adapter state before the host validates it.
        // This mapping is removed by reservation rollback, expiry or unload.
        self.lock.lock()
        if self.reservations[token]?.owner == context.pluginID { self.feedbackTokens[descriptor] = token }
        self.lock.unlock()
        return prepared
    }

    private func feedbackToken(_ descriptor: String) -> String? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.feedbackTokens[descriptor]
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
        let durationMilliseconds: Int64
        let button: AlertAction?
    }

    private func preparePresentation(_ arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext, expectedScreen: UUID? = nil, token suppliedToken: String? = nil) throws -> AyuBridgeProviderResult {
        guard Set(arguments.keys) == ["kind", "config"], let kind = arguments["kind"]?.string,
               let config = arguments["config"]?.object, let screen = self.currentScreen() else { throw AyuBridgeFailure("screen_unavailable", "No explicit visible presentation context") }
        guard expectedScreen == nil || expectedScreen == screen.identity else { throw AyuBridgeFailure("screen_unavailable", "Original feedback screen expired") }
        _ = try self.account(.integer(screen.accountIndex))
        let ready = DispatchQueue.main.sync { self.presenterSource?()?.viewIfLoaded?.window != nil }
        guard ready else { throw AyuBridgeFailure("screen_unavailable", "Presentation root is not visible") }
        let title: String?, text: String?, style: String
        var actions: [AlertAction] = []
        var durationMilliseconds: Int64 = 3000
        var bulletinButton: AlertAction?
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
                let sink = callback == .null ? nil : try context.callback(callback)
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
            guard Set(config.keys).isSubset(of: ["style", "text", "fragment", "duration_ms", "button"]), let supplied = config["style"]?.string, ["simple", "success", "error"].contains(supplied),
                   let value = try Self.optionalText(config["text"], limit: 4096), !value.isEmpty else { throw Self.invalid() }
            if let duration = config["duration_ms"] {
                guard let milliseconds = duration.integer, (1...10_000).contains(milliseconds) else { throw Self.invalid() }
                durationMilliseconds = milliseconds
            }
            if let button = config["button"] {
                guard let values = button.object, Set(values.keys) == ["text", "on_click"],
                      let title = try Self.optionalText(values["text"], limit: 1024), !title.isEmpty,
                      let callback = values["on_click"] else { throw Self.invalid() }
                bulletinButton = AlertAction(title: title, which: 0, callback: callback == .null ? nil : try context.callback(callback), isCancel: false)
            }
            if let reference = config["fragment"], reference != .null {
                let snapshot = try context.snapshot(of: reference)
                guard snapshot.className == Self.fragment, try self.screen(state: snapshot.state).identity == screen.identity else { throw Self.invalid() }
            }
            title = nil; text = value; style = supplied
        } else { throw AyuBridgeFailure.unsupported("presentation kind") }
        let token = suppliedToken ?? UUID().uuidString
        self.lock.lock()
        guard self.reservations[token] == nil, self.reservations.count < 16, self.reservations.values.filter({ $0.owner == context.pluginID }).count < 4 else {
            self.lock.unlock(); throw AyuBridgeFailure("resource_limit", "Presentation quota exceeded")
        }
        let generation = self.ownerGenerations[context.pluginID] ?? UUID()
        self.ownerGenerations[context.pluginID] = generation
        self.reservations[token] = Reservation(owner: context.pluginID, generation: generation)
        self.lock.unlock()
        let presentation = Presentation(token: token, owner: context.pluginID, generation: generation, screen: screen, kind: kind, title: title, text: text, style: style, actions: actions, durationMilliseconds: durationMilliseconds, button: bulletinButton)
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

    private func cancelReservation(_ token: String) {
        self.lock.lock()
        self.reservations.removeValue(forKey: token)
        self.feedbackTokens = self.feedbackTokens.filter { $0.value != token }
        self.lock.unlock()
    }
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
        return DispatchQueue.main.sync {
            guard self.isCurrent(token, owner: owner) else { return false }
            if let expected = self.bulletinScreens[token] {
                guard let screen = self.screenSource?(), screen.identity == expected.identity, screen.accountIndex == expected.accountIndex else {
                    self.cancelReservation(token); self.removePresentation(token); return false
                }
            }
            return self.dialogs[token]?.presentingViewController != nil || self.bulletins[token]?.window != nil
        }
    }

    public func reserveDialogToken(_ token: String, pluginID: String) throws {
        guard UUID(uuidString: token) != nil else { throw Self.invalid() }
        self.lock.lock()
        guard self.reservations[token] == nil,
              self.reservations.count < 16,
              self.reservations.values.filter({ $0.owner == pluginID }).count < 4 else {
            self.lock.unlock(); throw AyuBridgeFailure("resource_limit", "Presentation quota exceeded")
        }
        let generation = self.ownerGenerations[pluginID] ?? UUID()
        self.ownerGenerations[pluginID] = generation
        self.reservations[token] = Reservation(owner: pluginID, generation: generation)
        self.lock.unlock()
    }

    @MainActor public func presentBridgeDialog(_ controller: UIViewController, token: String, pluginID: String) throws {
        guard self.isCurrent(token, owner: pluginID), let presenter = self.presenterSource?(),
              presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
            throw AyuBridgeFailure("screen_unavailable", "Presentation root is not visible")
        }
        self.dialogs[token] = controller
        presenter.present(controller, animated: true)
    }

    public func dismissBridgeDialog(token: String, pluginID: String) {
        guard self.isCurrent(token, owner: pluginID) else { return }
        self.cancelReservation(token)
        DispatchQueue.main.async { self.removePresentation(token) }
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
            let button: UIButton?
            if let action = presentation.button {
                let control = UIButton(type: .system)
                control.setTitle(action.title, for: .normal)
                control.setTitleColor(.white, for: .normal)
                control.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
                control.titleLabel?.numberOfLines = 0
                control.addAction(UIAction { [weak self] _ in
                    guard let self, self.isCurrent(presentation.token, owner: presentation.owner, generation: presentation.generation) else { return }
                    // Revoke before delivery so subsequent touch releases cannot
                    // enqueue a second callback. The sender checks load generation.
                    self.cancelReservation(presentation.token)
                    self.removePresentation(presentation.token)
                    guard let screen = self.screenSource?(), screen.identity == presentation.screen.identity,
                          screen.accountIndex == presentation.screen.accountIndex else { return }
                    action.callback?.send([])
                }, for: .touchUpInside)
                container.addSubview(control)
                control.translatesAutoresizingMaskIntoConstraints = false
                button = control
            } else { button = nil }
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: presenter.view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
                container.trailingAnchor.constraint(equalTo: presenter.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
                container.bottomAnchor.constraint(equalTo: presenter.view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12), label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: button?.topAnchor ?? container.bottomAnchor, constant: -12)
            ])
            if let button {
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                    button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                    button.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
                    button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
                ])
            }
            self.bulletins[presentation.token] = container
            self.bulletinScreens[presentation.token] = presentation.screen
            UIAccessibility.post(notification: .announcement, argument: presentation.text)
            // Expiry retains only scalar identity, never the button's callback
            // or its UI tree after a tap, unload or screen invalidation.
            let token = presentation.token, owner = presentation.owner, generation = presentation.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(presentation.durationMilliseconds))) { [weak self] in
                guard let self, self.isCurrent(token, owner: owner, generation: generation) else { return }
                self.cancelReservation(token); self.removePresentation(token)
            }
        }
    }

    @MainActor private func removePresentation(_ token: String) {
        self.dialogs.removeValue(forKey: token)?.dismiss(animated: false)
        self.bulletins.removeValue(forKey: token)?.removeFromSuperview()
        self.bulletinScreens.removeValue(forKey: token)
    }
}
