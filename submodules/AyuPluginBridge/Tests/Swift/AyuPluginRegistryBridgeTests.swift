import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// `plugins.list` and `plugins.settings` through a native host: validation, ownership, bounds and
/// the main-thread effects, with synthetic records and no interpreter.
@MainActor
final class AyuPluginRegistryBridgeTests: XCTestCase {
    private struct Opened: Equatable { let pluginID: String; let alias: [String] }

    private func host(_ registry: AyuPluginRegistryBridge, base: AyuPluginHostProvider = AyuUnsupportedPluginHostProvider()) -> AyuPluginNativeHost {
        AyuPluginNativeHost(defaults: UserDefaults(suiteName: "AyuPluginRegistryBridgeTests." + UUID().uuidString)!,
            provider: AyuPluginRegistryHostProvider(base: base, registry: registry), trustedOwner: { "alpha" }, callback: { _, _, _ in })
    }

    private func call(_ host: AyuPluginNativeHost, _ operation: String, owner: String = "alpha", _ arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        let request = AyuBridgeValue.object(["version": .integer(1), "id": .string("1"), "plugin_id": .string(owner),
            "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        let response: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: host.dispatch(text, owner: owner)) }
        }
        return try JSONDecoder().decode(AyuBridgeValue.self, from: Data(response.utf8))
    }

    private func authorize(_ host: AyuPluginNativeHost, owner: String = "alpha") async throws {
        let result = try await self.call(host, "plugin.authorize", owner: owner, ["metadata": .object(["id": .string(owner)]), "classes": .array([]),
            "requirements": .array([]), "imports": .array([])])
        XCTAssertEqual(result["result"], .bool(true))
    }

    private func settings(_ host: AyuPluginNativeHost, _ action: String, _ pluginID: String, _ rest: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        var arguments = rest
        arguments["action"] = .string(action); arguments["plugin_id"] = .string(pluginID)
        return try await self.call(host, "plugins.settings", arguments)
    }

    /// Effects are queued on main after the call returned.
    private func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }

    func testListReportsEveryPluginAndTheCallerAsRunning() async throws {
        let registry = AyuPluginRegistryBridge()
        let host = self.host(registry)
        let unauthorized = try await self.call(host, "plugins.list")
        XCTAssertEqual(unauthorized["error"]["code"], .string("UNAUTHORIZED"))
        try await self.authorize(host)
        let capabilities = try await self.call(host, "runtime.capabilities")
        let operations = capabilities["result"]["operations"].array ?? []
        XCTAssertTrue(operations.contains(.string("plugins.list")) && operations.contains(.string("plugins.settings")))

        let empty = try await self.call(host, "plugins.list")
        XCTAssertEqual(empty["result"], .array([]))
        registry.update([
            AyuPluginRegistryRecord(id: "alpha", name: "Alpha", version: "1.2", isBusy: true, hasError: true),
            AyuPluginRegistryRecord(id: "beta", name: "Beta", version: "2.0", description: "About beta", author: "@beta", icon: "pack/3", isEnabled: true),
            AyuPluginRegistryRecord(id: "gamma", name: "Gamma", hasError: true),
        ])
        let listed = try await self.call(host, "plugins.list")
        XCTAssertEqual(listed["result"], .array([
            .object(["id": .string("alpha"), "name": .string("Alpha"), "version": .string("1.2"), "enabled": .bool(true)]),
            .object(["id": .string("beta"), "name": .string("Beta"), "version": .string("2.0"), "description": .string("About beta"),
                     "author": .string("@beta"), "icon": .string("pack/3"), "enabled": .bool(true)]),
            .object(["id": .string("gamma"), "name": .string("Gamma"), "enabled": .bool(false), "error": .bool(true)]),
        ]))
        let withArguments = try await self.call(host, "plugins.list", ["enabled": .bool(true)])
        XCTAssertEqual(withArguments["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testListLeavesOptionalFieldsOutBeforeItExceedsItsQuota() async throws {
        let registry = AyuPluginRegistryBridge()
        let host = self.host(registry)
        try await self.authorize(host)
        func records(_ count: Int, description: Int, author: Int, name: Int = 8) -> [AyuPluginRegistryRecord] {
            (0..<count).map {
                AyuPluginRegistryRecord(id: "plugin\($0)", name: String(repeating: "n", count: name), version: "1.0",
                    description: String(repeating: "d", count: description), author: String(repeating: "a", count: author), icon: "pack/1")
            }
        }
        func keys(_ response: AyuBridgeValue) -> Set<String> { Set(response["result"].array?.first?.object?.keys.map { $0 } ?? []) }

        registry.update(records(100, description: 1000, author: 20))
        let full = try await self.call(host, "plugins.list")
        XCTAssertEqual(keys(full), ["id", "name", "enabled", "version", "author", "icon", "description"])
        registry.update(records(100, description: 4000, author: 20))
        let withoutDescription = try await self.call(host, "plugins.list")
        XCTAssertEqual(keys(withoutDescription), ["id", "name", "enabled", "version", "author", "icon"])
        XCTAssertEqual(withoutDescription["result"].array?.count, 100)
        registry.update(records(500, description: 4000, author: 500))
        let versionOnly = try await self.call(host, "plugins.list")
        XCTAssertEqual(keys(versionOnly), ["id", "name", "enabled", "version"])
        registry.update(records(500, description: 0, author: 0, name: 1000))
        let tooLarge = try await self.call(host, "plugins.list")
        XCTAssertEqual(tooLarge["error"]["code"], .string("RESOURCE_LIMIT"))
        registry.update(records(AyuPluginRegistryBridge.maximumRecords + 1, description: 0, author: 0))
        let tooMany = try await self.call(host, "plugins.list")
        XCTAssertEqual(tooMany["error"]["code"], .string("RESOURCE_LIMIT"))
    }

    func testReloadIsLimitedToTheCallerAndRunsOnMainAfterTheCall() async throws {
        let registry = AyuPluginRegistryBridge()
        let host = self.host(registry)
        try await self.authorize(host)
        registry.update([AyuPluginRegistryRecord(id: "alpha", name: "Alpha", isEnabled: true), AyuPluginRegistryRecord(id: "beta", name: "Beta", isEnabled: true)])
        let unbound = try await self.settings(host, "reload", "alpha")
        XCTAssertEqual(unbound["error"]["code"], .string("UNSUPPORTED_API"))

        let reloaded = AyuTestBox<[String]>([])
        registry.bind(AyuPluginRegistryBridge.Screens(canOpenSettings: { false }, openSettings: { _, _ in },
            reloadSettings: { id in XCTAssertTrue(Thread.isMainThread); reloaded.update { $0.append(id) } }))
        let own = try await self.settings(host, "reload", "alpha")
        XCTAssertEqual(own["result"], .null)
        await self.settle()
        XCTAssertEqual(reloaded.value, ["alpha"])

        let foreign = try await self.settings(host, "reload", "beta")
        XCTAssertEqual(foreign["error"]["code"], .string("UNSUPPORTED_API"))
        let extra = try await self.settings(host, "reload", "alpha", ["link_alias": .string("row")])
        XCTAssertEqual(extra["error"]["code"], .string("INVALID_ARGUMENTS"))
        for arguments: [String: AyuBridgeValue] in [[:], ["action": .string("reload")], ["plugin_id": .string("alpha")],
                                                    ["action": .string("close"), "plugin_id": .string("alpha")],
                                                    ["action": .string("reload"), "plugin_id": .integer(1)],
                                                    ["action": .string("reload"), "plugin_id": .string("")]] {
            let malformed = try await self.call(host, "plugins.settings", arguments)
            XCTAssertEqual(malformed["error"]["code"], .string("INVALID_ARGUMENTS"), "\(arguments)")
        }
        await self.settle()
        XCTAssertEqual(reloaded.value, ["alpha"], "A rejected call has no effect")
    }

    func testOpenNeedsAnEnabledPluginAndAVisibleScreen() async throws {
        let registry = AyuPluginRegistryBridge()
        let host = self.host(registry)
        try await self.authorize(host)
        registry.update([
            AyuPluginRegistryRecord(id: "alpha", name: "Alpha", isEnabled: true), AyuPluginRegistryRecord(id: "beta", name: "Beta", isEnabled: true),
            AyuPluginRegistryRecord(id: "idle", name: "Idle"), AyuPluginRegistryRecord(id: "busy", name: "Busy", isEnabled: true, isBusy: true),
        ])
        let visible = AyuTestBox(false)
        let opened = AyuTestBox<[Opened]>([])
        registry.bind(AyuPluginRegistryBridge.Screens(canOpenSettings: { XCTAssertTrue(Thread.isMainThread); return visible.value },
            openSettings: { id, alias in XCTAssertTrue(Thread.isMainThread); opened.update { $0.append(Opened(pluginID: id, alias: alias)) } },
            reloadSettings: { _ in }))

        let hidden = try await self.settings(host, "open", "beta")
        XCTAssertEqual(hidden["error"]["code"], .string("SCREEN_UNAVAILABLE"))
        visible.value = true
        let unknown = try await self.settings(host, "open", "missing")
        XCTAssertEqual(unknown["error"]["code"], .string("INVALID_ARGUMENTS"))
        for id in ["idle", "busy"] {
            let inactive = try await self.settings(host, "open", id)
            XCTAssertEqual(inactive["error"]["code"], .string("INVALID_STATE"), id)
        }
        let extra = try await self.settings(host, "open", "beta", ["animated": .bool(true)])
        XCTAssertEqual(extra["error"]["code"], .string("INVALID_ARGUMENTS"))
        let aliases: [AyuBridgeValue] = [.integer(1), .string(":row"), .string("page::row"), .string("row:"),
            .string(String(repeating: "a", count: AyuPluginRegistryBridge.maximumAliasBytes + 1)),
            .string(Array(repeating: "p", count: AyuPluginRegistryBridge.maximumAliasDepth + 1).joined(separator: ":"))]
        for alias in aliases {
            let malformed = try await self.settings(host, "open", "beta", ["link_alias": alias])
            XCTAssertEqual(malformed["error"]["code"], .string("INVALID_ARGUMENTS"), "\(alias)")
        }
        await self.settle()
        XCTAssertEqual(opened.value, [], "A rejected call opens nothing")

        // Another enabled plugin's screen may be opened; the alias path reaches the screen as written.
        let plain = try await self.settings(host, "open", "beta")
        XCTAssertEqual(plain["result"], .null)
        let empty = try await self.settings(host, "open", "alpha", ["link_alias": .string("")])
        XCTAssertEqual(empty["result"], .null)
        let nested = try await self.settings(host, "open", "beta", ["link_alias": .string("page:row")])
        XCTAssertEqual(nested["result"], .null)
        await self.settle()
        XCTAssertEqual(opened.value, [Opened(pluginID: "beta", alias: []), Opened(pluginID: "alpha", alias: []), Opened(pluginID: "beta", alias: ["page", "row"])])
    }

    func testProviderInFrontKeepsTheApplicationProviderAndItsDialogs() async throws {
        let menus = AyuPluginMenuBridge()
        let registry = AyuPluginRegistryBridge()
        let provider = AyuPluginRegistryHostProvider(base: menus, registry: registry)
        XCTAssertEqual(provider.capabilities, menus.capabilities + ["plugins.list", "plugins.settings"])
        XCTAssertThrowsError(try provider.reserveDialogToken("token", pluginID: "alpha")) {
            XCTAssertEqual(($0 as? AyuBridgeFailure)?.code, "UNSUPPORTED_API")
        }
        let host = self.host(registry, base: menus)
        try await self.authorize(host)
        let activated = try await self.call(host, "plugin.activate", ["generation": .string("registry-test-generation")])
        XCTAssertEqual(activated["result"], .null)
        let registered = try await self.call(host, "menus.register", ["type": .string("MESSAGE_CONTEXT_MENU"), "text": .string("Row"),
            "priority": .integer(1), "on_click": .object(["$callback": .string("registry-test-generation:click")])])
        XCTAssertNotNil(registered["result"].string, "\(registered)")
    }

    func testInstalledRecordsMapToAndroidPluginState() {
        var plugin = AyuInstalledPlugin(id: "sample", name: "Sample", version: AyuPluginService.missingVersion, blockers: [], nativeAdapter: nil)
        plugin.author = ""; plugin.description = "About"; plugin.icon = "pack/1"
        XCTAssertEqual(AyuPluginRegistryRecord(plugin), AyuPluginRegistryRecord(id: "sample", name: "Sample", description: "About", icon: "pack/1"))
        plugin = AyuInstalledPlugin(id: "sample", name: "Sample", version: "2.1", blockers: [], nativeAdapter: nil)
        plugin.error = "load failed"
        XCTAssertEqual(AyuPluginRegistryRecord(plugin), AyuPluginRegistryRecord(id: "sample", name: "Sample", version: "2.1", hasError: true))
        // A handler error leaves the plugin running: Android has no such state, so it is not an error there.
        plugin.isEnabled = true; plugin.isBusy = true
        XCTAssertEqual(AyuPluginRegistryRecord(plugin), AyuPluginRegistryRecord(id: "sample", name: "Sample", version: "2.1", isEnabled: true, isBusy: true))
    }

    func testLinkAliasNamesTheFirstRowThatCarriesIt() {
        func row(_ alias: String?) -> AyuPluginSetting {
            var descriptor: [String: AyuBridgeValue] = ["type": .string("Text"), "text": .string("Row")]
            if let alias { descriptor["link_alias"] = .string(alias) }
            return AyuPluginSetting(descriptor: .object(descriptor), value: .null)
        }
        let rows = [row(nil), row("first"), row("target"), row("target")]
        XCTAssertEqual(AyuPluginSettingsViewController.linkAliasRow("target", in: rows), 2)
        XCTAssertNil(AyuPluginSettingsViewController.linkAliasRow("absent", in: rows))
        XCTAssertEqual(try AyuPluginRegistryBridge.aliasPath(.string("page:row")), ["page", "row"])
        XCTAssertEqual(try AyuPluginRegistryBridge.aliasPath(nil), [])
    }
}
