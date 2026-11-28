import Foundation
import UIKit

/// What `plugins.list` reports about one installed plugin.
public struct AyuPluginRegistryRecord: Sendable, Equatable {
    public let id: String
    public let name: String
    public var version: String?
    public var description: String?
    public var author: String?
    public var icon: String?
    public var isEnabled: Bool
    public var isBusy: Bool
    /// Android's `Plugin.hasError`: the plugin failed and is not running.
    public var hasError: Bool

    public init(id: String, name: String, version: String? = nil, description: String? = nil, author: String? = nil,
                icon: String? = nil, isEnabled: Bool = false, isBusy: Bool = false, hasError: Bool = false) {
        self.id = id; self.name = name; self.version = version; self.description = description; self.author = author
        self.icon = icon; self.isEnabled = isEnabled; self.isBusy = isBusy; self.hasError = hasError
    }
}

/// `plugins.list` and `plugins.settings`. Calls arrive on the host worker and read a snapshot the
/// plugin service replaces on main; screens change on main after the call has returned, so main
/// never waits for Python.
public final class AyuPluginRegistryBridge: AyuPluginHostProvider, @unchecked Sendable {
    /// Main-thread effects supplied by the plugin service.
    public struct Screens: Sendable {
        public let canOpenSettings: @MainActor @Sendable () -> Bool
        /// `linkAlias` is the alias path of the row to show; empty for the page itself.
        public let openSettings: @MainActor @Sendable (_ pluginID: String, _ linkAlias: [String]) -> Void
        public let reloadSettings: @MainActor @Sendable (_ pluginID: String) -> Void
        public init(canOpenSettings: @escaping @MainActor @Sendable () -> Bool,
                    openSettings: @escaping @MainActor @Sendable (_ pluginID: String, _ linkAlias: [String]) -> Void,
                    reloadSettings: @escaping @MainActor @Sendable (_ pluginID: String) -> Void) {
            self.canOpenSettings = canOpenSettings; self.openSettings = openSettings; self.reloadSettings = reloadSettings
        }
    }

    public let capabilities = ["plugins.list", "plugins.settings"]
    static let maximumRecords = 1024
    /// Leaves room for the response envelope inside the host's 256 KiB response quota.
    static let maximumListBytes = 196_608
    static let maximumAliasBytes = 512
    /// Sub-page callbacks stay registered for the eight most recently opened pages.
    static let maximumAliasDepth = 8
    private let lock = NSLock()
    private var records: [AyuPluginRegistryRecord] = []
    private var screens: Screens?

    public init() {}

    public func update(_ records: [AyuPluginRegistryRecord]) {
        self.lock.lock(); self.records = records; self.lock.unlock()
    }

    public func bind(_ screens: Screens?) {
        self.lock.lock(); self.screens = screens; self.lock.unlock()
    }

    public func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
        guard operation == "plugins.list" else { throw AyuBridgeFailure.unsupported(operation) }
        guard arguments.isEmpty else { throw Self.invalid("plugins.list takes no arguments") }
        self.lock.lock(); let records = self.records; self.lock.unlock()
        guard records.count <= Self.maximumRecords else { throw AyuBridgeFailure("resource_limit", "Too many installed plugins") }
        // Optional fields are left out of every record, never shortened, when the list would not fit.
        for detail in [Detail.full, .withoutDescription, .versionOnly] {
            let list = AyuBridgeValue.array(records.map { Self.wire($0, caller: pluginID, detail: detail) })
            if let data = try? JSONEncoder().encode(list), data.count <= Self.maximumListBytes { return list }
        }
        throw AyuBridgeFailure("resource_limit", "Plugin list exceeds the response quota")
    }

    public func prepareCall(pluginID: String, operation: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        guard operation == "plugins.settings" else {
            return AyuBridgeProviderResult(.value(try self.call(pluginID: pluginID, operation: operation, arguments: arguments)))
        }
        guard let action = arguments["action"]?.string, let target = arguments["plugin_id"]?.string,
              !target.isEmpty, target.utf8.count <= 64 else { throw Self.invalid("plugins.settings needs an action and a plugin id") }
        self.lock.lock(); let screens = self.screens; let record = self.records.first { $0.id == target }; self.lock.unlock()
        switch action {
        case "reload":
            guard Set(arguments.keys) == ["action", "plugin_id"] else { throw Self.invalid("Unknown plugins.settings argument") }
            guard target == pluginID else { throw AyuBridgeFailure.unsupported("reloading the settings of another plugin") }
            guard let screens else { throw AyuBridgeFailure.unsupported(operation) }
            return AyuBridgeProviderResult(.value(.null), commit: { _ in Task { @MainActor in screens.reloadSettings(target) } })
        case "open":
            guard Set(arguments.keys).isSubset(of: ["action", "plugin_id", "link_alias"]) else { throw Self.invalid("Unknown plugins.settings argument") }
            let alias = try Self.aliasPath(arguments["link_alias"])
            guard let record else { throw Self.invalid("No installed plugin has this id") }
            guard record.isEnabled, !record.isBusy else { throw AyuBridgeFailure("invalid_state", "Plugin is not enabled") }
            guard let screens else { throw AyuBridgeFailure.unsupported(operation) }
            guard !Thread.isMainThread else { throw AyuBridgeFailure("wrong_thread", "Bridge dispatch cannot run on main") }
            guard DispatchQueue.main.sync(execute: { screens.canOpenSettings() }) else {
                throw AyuBridgeFailure("screen_unavailable", "No visible screen can show plugin settings")
            }
            return AyuBridgeProviderResult(.value(.null), commit: { _ in Task { @MainActor in screens.openSettings(target, alias) } })
        default:
            throw Self.invalid("plugins.settings action must be reload or open")
        }
    }

    public func detach(pluginID: String) {}

    /// Android's alias path: `a:b` is row `b` on the sub-page of row `a`. An empty alias names no row.
    static func aliasPath(_ value: AyuBridgeValue?) throws -> [String] {
        guard let value else { return [] }
        guard let alias = value.string, alias.utf8.count <= self.maximumAliasBytes else { throw self.invalid("Invalid link alias") }
        if alias.isEmpty { return [] }
        let path = alias.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard path.count <= self.maximumAliasDepth, !path.contains("") else { throw self.invalid("Invalid link alias") }
        return path
    }

    private enum Detail { case full, withoutDescription, versionOnly }

    /// The calling plugin is running, whatever the manager's row says while it loads.
    private static func wire(_ record: AyuPluginRegistryRecord, caller: String, detail: Detail) -> AyuBridgeValue {
        let isCaller = record.id == caller
        var fields: [String: AyuBridgeValue] = ["id": .string(record.id), "name": .string(record.name), "enabled": .bool(record.isEnabled || isCaller)]
        if record.hasError && !isCaller { fields["error"] = .bool(true) }
        if let version = record.version { fields["version"] = .string(version) }
        if detail != .versionOnly {
            if let author = record.author { fields["author"] = .string(author) }
            if let icon = record.icon { fields["icon"] = .string(icon) }
        }
        if detail == .full, let description = record.description { fields["description"] = .string(description) }
        return .object(fields)
    }

    private static func invalid(_ message: String) -> AyuBridgeFailure { AyuBridgeFailure("invalid_arguments", message) }
}

/// Puts the registry operations in front of the application's provider.
final class AyuPluginRegistryHostProvider: AyuPluginHostProvider, AyuPluginDialogHost, @unchecked Sendable {
    private let base: AyuPluginHostProvider
    private let registry: AyuPluginRegistryBridge

    init(base: AyuPluginHostProvider, registry: AyuPluginRegistryBridge) { self.base = base; self.registry = registry }

    var capabilities: [String] { self.base.capabilities + self.registry.capabilities }
    func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
        try self.provider(operation).call(pluginID: pluginID, operation: operation, arguments: arguments)
    }
    func prepareCall(pluginID: String, operation: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        try self.provider(operation).prepareCall(pluginID: pluginID, operation: operation, arguments: arguments, context: context)
    }
    func detach(pluginID: String) { self.registry.detach(pluginID: pluginID); self.base.detach(pluginID: pluginID) }

    func reserveDialogToken(_ token: String, pluginID: String) throws {
        try self.dialogHost().reserveDialogToken(token, pluginID: pluginID)
    }
    @MainActor func presentBridgeDialog(_ controller: UIViewController, token: String, pluginID: String) throws {
        try self.dialogHost().presentBridgeDialog(controller, token: token, pluginID: pluginID)
    }
    func dismissBridgeDialog(token: String, pluginID: String) {
        (self.base as? AyuPluginDialogHost)?.dismissBridgeDialog(token: token, pluginID: pluginID)
    }

    private func provider(_ operation: String) -> AyuPluginHostProvider {
        self.registry.capabilities.contains(operation) ? self.registry : self.base
    }
    private func dialogHost() throws -> AyuPluginDialogHost {
        guard let host = self.base as? AyuPluginDialogHost else { throw AyuBridgeFailure.unsupported("dialog host") }
        return host
    }
}

extension AyuPluginRegistryRecord {
    init(_ plugin: AyuInstalledPlugin) {
        func text(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        self.init(id: plugin.id, name: plugin.name, version: plugin.version == AyuPluginService.missingVersion ? nil : plugin.version,
                  description: text(plugin.description), author: text(plugin.author), icon: text(plugin.icon),
                  isEnabled: plugin.isEnabled, isBusy: plugin.isBusy, hasError: plugin.error != nil && !plugin.isEnabled)
    }
}

extension AyuPluginService {
    func registryScreens() -> AyuPluginRegistryBridge.Screens {
        AyuPluginRegistryBridge.Screens(
            canOpenSettings: { Self.settingsPresenter() != nil },
            openSettings: { [weak self] pluginID, linkAlias in self?.openSettings(pluginID: pluginID, linkAlias: linkAlias) },
            reloadSettings: { [weak self] pluginID in self?.reloadSettings(pluginID: pluginID) })
    }

    /// The plugin manager's top screen while it is visible, otherwise the application's visible
    /// controller. Both are the explicit presenters the application registered.
    static func settingsPresenter() -> UIViewController? {
        for source in [AyuNativePluginRuntime.shared.feedbackPresenter, AyuNativePluginRuntime.shared.presenter] {
            if let controller = source?(), controller.viewIfLoaded?.window != nil, controller.presentedViewController == nil { return controller }
        }
        return nil
    }

    /// The screen appears without its rows; they are serialized afterwards, as for a screen the user opens.
    func openSettings(pluginID: String, linkAlias: [String]) {
        guard let plugin = self.plugins.first(where: { $0.id == pluginID && $0.isEnabled && !$0.isBusy }),
              let presenter = Self.settingsPresenter() else { return }
        let controller = AyuPluginSettingsViewController(service: self, plugin: plugin, linkAlias: linkAlias)
        // Only a stack of plugin screens is a UIKit stack; the application's own navigation is not.
        if let navigation = presenter.navigationController, navigation.viewControllers.contains(where: {
            $0 is AyuPluginManagerViewController || $0 is AyuPluginDetailViewController || $0 is AyuPluginSettingsViewController
        }) {
            navigation.pushViewController(controller, animated: true)
        } else {
            let navigation = UINavigationController(rootViewController: controller)
            navigation.overrideUserInterfaceStyle = presenter.overrideUserInterfaceStyle
            presenter.present(navigation, animated: true)
        }
    }
}
