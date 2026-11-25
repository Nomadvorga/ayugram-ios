import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

@MainActor
final class AyuPluginMenuBridgeTests: XCTestCase {
    private func host(_ menus: AyuPluginMenuBridge, limits: AyuPluginBridgeLimits = AyuPluginBridgeLimits()) -> AyuPluginNativeHost {
        AyuPluginNativeHost(defaults: UserDefaults(suiteName: "AyuPluginMenuBridgeTests." + UUID().uuidString)!,
            provider: menus, limits: limits, trustedOwner: { "alpha" }, callback: { _, _, _ in })
    }

    private func call(_ host: AyuPluginNativeHost, _ operation: String, _ arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        let request = AyuBridgeValue.object(["version": .integer(1), "id": .string("1"), "plugin_id": .string("alpha"),
            "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        let response: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: host.dispatch(text, owner: "alpha")) }
        }
        return try JSONDecoder().decode(AyuBridgeValue.self, from: Data(response.utf8))
    }

    private func activate(_ host: AyuPluginNativeHost) async throws {
        let authorized = try await self.call(host, "plugin.authorize", ["metadata": .object([:]), "classes": .array([]),
            "requirements": .array([]), "imports": .array([])])
        XCTAssertEqual(authorized["result"], .bool(true))
        let active = try await self.call(host, "plugin.activate", ["generation": .string("menu-test-generation")])
        XCTAssertEqual(active["result"], .null)
    }

    private func registration(_ host: AyuPluginNativeHost, text: String = "Copy metadata", priority: Int64 = 7, itemID: String? = "copy_metadata", icon: String? = "msg_copy", condition: AyuBridgeValue? = nil) async throws -> AyuBridgeValue {
        var arguments: [String: AyuBridgeValue] = ["type": .string("MESSAGE_CONTEXT_MENU"), "text": .string(text),
            "priority": .integer(priority),
            "on_click": .object(["$callback": .string("menu-test-generation:click")])]
        if let itemID { arguments["item_id"] = .string(itemID) }
        if let icon { arguments["icon"] = .string(icon) }
        if let condition { arguments["condition"] = condition }
        return try await self.call(host, "menus.register", arguments)
    }

    func testMenuRegistrationIsOrderedBoundAndInvokesOnlyCurrentCallback() async throws {
        let menus = AyuPluginMenuBridge()
        let host = self.host(menus)
        try await self.activate(host)
        let conditionID = "menu-test-generation:condition"
        let registered = try await self.registration(host, condition: .object(["$callback": .string(conditionID)]))
        let token = try XCTUnwrap(registered["result"].string)
        var calls: [(String, [AyuBridgeValue])] = []
        menus.invokeCallback = { _, callbackID, arguments in
            calls.append((callbackID, arguments))
            return .bool(true)
        }
        let context = AyuPluginMenuContext(screenIdentity: UUID(), accountIdentity: UUID(), accountIndex: 3, dialogID: -91, messageID: Int64.max - 8)
        XCTAssertEqual(context.arguments, [.object(["account": .integer(3), "dialog_id": .integer(-91), "message_id": .integer(Int64.max - 8)])])
        let items = await menus.items(context: context, isCurrent: { true })
        XCTAssertEqual(items.map(\.token), [token])
        XCTAssertEqual(items.first?.itemID, "alpha:copy_metadata")
        XCTAssertEqual(items.first?.symbolName, "doc.on.doc")
        XCTAssertEqual(calls.map { $0.0 }, [conditionID])
        XCTAssertEqual(calls.first?.1, context.arguments)

        await menus.perform(token: token, context: context, isCurrent: { true })
        XCTAssertEqual(calls.map { $0.0 }, [conditionID, conditionID, "menu-test-generation:click"])
        XCTAssertEqual(calls.last?.1, context.arguments)
    }

    func testMvelConditionsUnsupportedTypesAndUnknownIconsFailExplicitly() async throws {
        let menus = AyuPluginMenuBridge()
        let host = self.host(menus)
        try await self.activate(host)
        let mvel = try await self.call(host, "menus.register", ["type": .string("MESSAGE_CONTEXT_MENU"), "text": .string("Bad condition"),
            "priority": .integer(0), "on_click": .object(["$callback": .string("menu-test-generation:click")]), "condition": .string("message != null")])
        XCTAssertEqual(mvel["error"]["code"], .string("UNSUPPORTED_API"))
        let unsupportedType = try await self.call(host, "menus.register", ["type": .string("CHAT_ACTION_MENU"), "text": .string("Chat"),
            "priority": .integer(0), "on_click": .object(["$callback": .string("menu-test-generation:click")])])
        XCTAssertEqual(unsupportedType["error"]["code"], .string("UNSUPPORTED_API"))
        let unknownIcon = try await self.call(host, "menus.register", ["type": .string("MESSAGE_CONTEXT_MENU"), "text": .string("Bad icon"),
            "priority": .integer(0), "on_click": .object(["$callback": .string("menu-test-generation:click")]), "icon": .string("not_an_icon")])
        XCTAssertEqual(unknownIcon["error"]["code"], .string("UNSUPPORTED_API"))
        let malformed = try await self.call(host, "menus.register", ["type": .string("MESSAGE_CONTEXT_MENU"), "text": .string("No click"),
            "priority": .integer(0)])
        XCTAssertEqual(malformed["error"]["code"], .string("INVALID_ARGUMENTS"))
        let upstreamSpelling = try await self.call(host, "menus.register", ["menu_type": .string("message_context_menu"),
            "text": .string("Reference SDK shape"), "priority": .integer(0),
            "on_click": .object(["$callback": .string("menu-test-generation:click")])])
        XCTAssertNotNil(upstreamSpelling["result"].string)
    }

    func testUnregisterAndDeactivateRevokeItems() async throws {
        let menus = AyuPluginMenuBridge()
        let host = self.host(menus)
        try await self.activate(host)
        let registered = try await self.registration(host)
        let token = try XCTUnwrap(registered["result"].string)
        let context = AyuPluginMenuContext(screenIdentity: UUID(), accountIdentity: UUID(), accountIndex: 0, dialogID: 99, messageID: 1)
        menus.invokeCallback = { _, _, _ in .null }
        let beforeUnregister = await menus.items(context: context, isCurrent: { true })
        XCTAssertEqual(beforeUnregister.count, 1)
        let removed = try await self.call(host, "menus.unregister", ["token": .string(token)])
        XCTAssertEqual(removed["result"], .null)
        let afterUnregister = await menus.items(context: context, isCurrent: { true })
        XCTAssertTrue(afterUnregister.isEmpty)

        let second = try await self.registration(host)
        XCTAssertNotNil(second["result"].string)
        let unloaded = try await self.call(host, "plugin.deactivate", ["generation": .string("menu-test-generation")])
        XCTAssertEqual(unloaded["result"], .null)
        let afterDeactivate = await menus.items(context: context, isCurrent: { true })
        XCTAssertTrue(afterDeactivate.isEmpty)
    }

    func testPriorityOrderAndPerPluginQuotaAreBounded() async throws {
        let menus = AyuPluginMenuBridge()
        let host = self.host(menus)
        try await self.activate(host)
        _ = try await self.registration(host, text: "low", priority: -4, itemID: nil, icon: nil)
        _ = try await self.registration(host, text: "high", priority: 99, itemID: nil, icon: nil)
        _ = try await self.registration(host, text: "middle", priority: 1, itemID: nil, icon: nil)
        let context = AyuPluginMenuContext(screenIdentity: UUID(), accountIdentity: UUID(), accountIndex: 0, dialogID: 20, messageID: 1)
        menus.invokeCallback = { _, _, _ in .null }
        let ordered = await menus.items(context: context, isCurrent: { true })
        XCTAssertEqual(ordered.map(\.text), ["high", "middle", "low"])

        let quotaMenus = AyuPluginMenuBridge()
        let quotaHost = self.host(quotaMenus)
        try await self.activate(quotaHost)
        for index in 0..<16 {
            let response = try await self.registration(quotaHost, text: "row \(index)", priority: Int64(index), itemID: nil, icon: nil)
            XCTAssertNotNil(response["result"].string)
        }
        let overQuota = try await self.registration(quotaHost, text: "overflow", itemID: nil, icon: nil)
        XCTAssertEqual(overQuota["error"]["code"], .string("RESOURCE_LIMIT"))
        quotaMenus.invokeCallback = { _, _, _ in .null }
        let bounded = await quotaMenus.items(context: context, isCurrent: { true })
        XCTAssertEqual(bounded.count, 16)
    }

    func testPreparedMenuRollsBackIfHostCannotReturnItsToken() async throws {
        var limits = AyuPluginBridgeLimits()
        limits.responseBytes = 48 // enough for authorize/activate but not a UUID token response
        let menus = AyuPluginMenuBridge()
        let host = self.host(menus, limits: limits)
        try await self.activate(host)
        let failed = try await self.registration(host)
        XCTAssertEqual(failed["error"]["code"], .string("RESOURCE_LIMIT"))
        let context = AyuPluginMenuContext(screenIdentity: UUID(), accountIdentity: UUID(), accountIndex: 0, dialogID: 20, messageID: 1)
        menus.invokeCallback = { _, _, _ in .null }
        let visible = await menus.items(context: context, isCurrent: { true })
        XCTAssertTrue(visible.isEmpty)
    }

    func testConditionSuspensionAfterUnloadCannotPublishOrInvokeClick() async throws {
        let menus = AyuPluginMenuBridge()
        let host = self.host(menus)
        try await self.activate(host)
        let conditionID = "menu-test-generation:condition"
        let registration = try await self.registration(host, itemID: nil, icon: nil, condition: .object(["$callback": .string(conditionID)]))
        let token = try XCTUnwrap(registration["result"].string)
        var conditionContinuation: CheckedContinuation<AyuBridgeValue?, Never>?
        var invoked: [String] = []
        menus.invokeCallback = { _, callbackID, _ in
            invoked.append(callbackID)
            if callbackID == conditionID {
                return await withCheckedContinuation { conditionContinuation = $0 }
            }
            return .null
        }
        let context = AyuPluginMenuContext(screenIdentity: UUID(), accountIdentity: UUID(), accountIndex: 0, dialogID: 20, messageID: 1)
        let task = Task { @MainActor in
            await menus.perform(token: token, context: context, isCurrent: { true })
        }
        await Task.yield()
        XCTAssertNotNil(conditionContinuation)
        menus.detach(pluginID: "alpha")
        conditionContinuation?.resume(returning: .bool(true))
        await task.value
        XCTAssertEqual(invoked, [conditionID])
    }

    func testStaleScreenAfterConditionSuspensionDoesNotPublishMenu() async throws {
        let menus = AyuPluginMenuBridge()
        let host = self.host(menus)
        try await self.activate(host)
        let conditionID = "menu-test-generation:condition"
        _ = try await self.registration(host, itemID: nil, icon: nil, condition: .object(["$callback": .string(conditionID)]))
        var conditionContinuation: CheckedContinuation<AyuBridgeValue?, Never>?
        menus.invokeCallback = { _, callbackID, _ in
            guard callbackID == conditionID else { return .null }
            return await withCheckedContinuation { conditionContinuation = $0 }
        }
        let context = AyuPluginMenuContext(screenIdentity: UUID(), accountIdentity: UUID(), accountIndex: 0, dialogID: 20, messageID: 1)
        var current = true
        let task = Task { @MainActor in
            await menus.items(context: context, isCurrent: { current })
        }
        await Task.yield()
        XCTAssertNotNil(conditionContinuation)
        current = false
        conditionContinuation?.resume(returning: .bool(true))
        let visible = await task.value
        XCTAssertTrue(visible.isEmpty)
    }

    func testOwnDismissalDoesNotRevokeActionButReplacementDoes() async throws {
        let menus = AyuPluginMenuBridge()
        let host = self.host(menus)
        try await self.activate(host)
        let conditionID = "menu-test-generation:condition"
        let registration = try await self.registration(host, itemID: nil, icon: nil, condition: .object(["$callback": .string(conditionID)]))
        let token = try XCTUnwrap(registration["result"].string)
        let context = AyuPluginMenuContext(screenIdentity: UUID(), accountIdentity: UUID(), accountIndex: 0, dialogID: 20, messageID: 1)
        var currentMenu: String? = nil // UI marks the action started before dismiss(.dismissWithoutContent).
        let startedAction = true
        var clicks = 0
        menus.invokeCallback = { _, callbackID, _ in
            if callbackID == conditionID { return .bool(true) }
            clicks += 1
            return .null
        }
        // Nil after the action's own dismiss is accepted while the screen remains
        // current; a newly installed different context controller is not.
        await menus.perform(token: token, context: context, isCurrent: {
            startedAction && (currentMenu == "original" || currentMenu == nil)
        })
        XCTAssertEqual(clicks, 1)
        currentMenu = "replacement"
        await menus.perform(token: token, context: context, isCurrent: {
            startedAction && (currentMenu == "original" || currentMenu == nil)
        })
        XCTAssertEqual(clicks, 1)
    }
}
