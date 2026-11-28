import Foundation
import UIKit
import XCTest
@testable import AyuPluginBridge

/// Dialogs, bulletins, the send-message hook, menu items and packages, as far as they run without the app.
@MainActor
final class AyuPluginEndToEndApplicationTests: XCTestCase {
    private func send(_ stack: AyuEndToEnd, _ message: String?, caption: String? = nil) async -> [AyuBridgeValue] {
        await withCheckedContinuation { continuation in
            stack.service.applySendHooks(message: message, caption: caption, peerID: -1_001_234_567_890, accountIndex: 0) { message, caption, cancelled in
                continuation.resume(returning: [message.map(AyuBridgeValue.string) ?? .null, caption.map(AyuBridgeValue.string) ?? .null, .bool(cancelled)])
            }
        }
    }

    func testDialogsBulletinsHooksAndMenusWithoutAWindow() async throws {
        let stack = try AyuEndToEnd.shared()
        let screen = stack.bindApplication()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_ui", """
        from android.widget import LinearLayout, TextView
        from android_utils import copy_to_clipboard
        from base_plugin import BasePlugin, HookResult, HookStrategy, MenuItemData, MenuItemType
        from client_utils import get_last_fragment
        from org.telegram.messenger import ApplicationLoader
        from ui.alert import AlertDialogBuilder
        from ui.bulletin import BulletinHelper

        \(AyuEndToEnd.recorder)


        class UIPlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                context = ApplicationLoader.applicationContext
                fragment = get_last_fragment()
                def alert():
                    builder = AlertDialogBuilder(context)
                    builder.set_title("Title").set_message("Message")
                    builder.set_positive_button("OK", lambda dialog, which: self.set_setting("alert_clicked", which))
                    builder.set_negative_button("Cancel", None)
                    return builder.show() is builder
                self.record("alert", alert)
                def custom_alert():
                    builder = AlertDialogBuilder(context)
                    layout = LinearLayout(context)
                    layout.addView(TextView(context))
                    builder.set_view(layout)
                    return builder.show() is builder
                self.record("custom_alert", custom_alert)
                self.record("alert_cancel_listener", lambda: AlertDialogBuilder(context).set_title("T").set_on_cancel_listener(lambda dialog: None).show())
                self.record("alert_progress", lambda: AlertDialogBuilder(context, getattr(AlertDialogBuilder, "ALERT_TYPE_" + "SPINNER")).show())
                self.record("bulletin_info", lambda: BulletinHelper.show_info("Info"))
                self.record("bulletin_fragment", lambda: BulletinHelper.show_error("Error", fragment))
                self.record("bulletin_button", lambda: BulletinHelper.show_with_button("Text", 0, "Undo", lambda: None))
                self.record("bulletin_icon", lambda: BulletinHelper.show_simple("Text", 7))
                self.record("clipboard", lambda: copy_to_clipboard("copied"))

                self.record("send_hook", lambda: type(self.add_on_send_message_hook()).__name__)
                self.record("request_hook", lambda: getattr(self, "add_" + "hook")("TL_messages_sendMessage"))
                self.record("second_send_hook", lambda: type(self.add_on_send_message_hook()).__name__)
                self.record("menu", lambda: type(self.add_menu_item(MenuItemData(menu_type=MenuItemType.MESSAGE_CONTEXT_MENU, text="Quote", item_id="quote",
                                                                                   icon="msg_quote", priority=5, condition=self.menu_condition, on_click=self.menu_click))).__name__)
                self.record("menu_plain", lambda: type(self.add_menu_item(MenuItemData(menu_type=MenuItemType.MESSAGE_CONTEXT_MENU, text="Always", on_click=self.menu_click))).__name__)
                self.record("menu_drawer", lambda: self.add_menu_item(MenuItemData(menu_type=getattr(MenuItemType, "DRAWER" + "_MENU"), text="Drawer", on_click=self.menu_click)))
                self.record("menu_subtext", lambda: self.add_menu_item(MenuItemData(menu_type=MenuItemType.MESSAGE_CONTEXT_MENU, text="Sub", subtext="text", on_click=self.menu_click)))
                self.record("menu_mvel", lambda: self.add_menu_item(MenuItemData(menu_type=MenuItemType.MESSAGE_CONTEXT_MENU, text="Mvel", condition="message != null", on_click=self.menu_click)))

            def menu_condition(self, context):
                self.set_setting("condition_context", context)
                return context["message_id"] % 2 == 0

            def menu_click(self, context):
                self.set_setting("clicked_context", context)

            def on_send_message_hook(self, account, params):
                self.set_setting("hook_seen", [account, params.peer, params.message, params.caption])
                if params.message == "cancel me":
                    return HookResult(strategy=HookStrategy.CANCEL)
                if params.message == "wrong":
                    return "not a hook result"
                if params.message == "caption":
                    params.caption = "new caption"
                    return HookResult(strategy=HookStrategy.MODIFY, params=params)
                if params.message == "raise":
                    raise RuntimeError("synthetic hook failure")
                if params.message and params.message.startswith("edit"):
                    params.message = params.message.upper()
                    return HookResult(strategy=HookStrategy.MODIFY, params=params)
                return HookResult()
        """))
        func stored(_ key: String) -> AyuBridgeValue { stack.stored(id, key) }
        func refusal(_ key: String, _ prefix: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(stored(key).string?.hasPrefix(prefix), true, "\(key): \(stored(key))", file: file, line: line)
        }
        // No view controller is bound, so nothing can be presented: every presentation fails closed.
        refusal("alert", "!BridgeError: SCREEN_UNAVAILABLE")
        refusal("bulletin_info", "!BridgeError: SCREEN_UNAVAILABLE")
        refusal("bulletin_fragment", "!BridgeError: SCREEN_UNAVAILABLE")
        refusal("bulletin_button", "!BridgeError: SCREEN_UNAVAILABLE")
        refusal("alert_cancel_listener", "!BridgeError: SCREEN_UNAVAILABLE")
        refusal("alert_progress", "!BridgeError: SCREEN_UNAVAILABLE")
        refusal("bulletin_icon", "!UnsupportedAPI: UNSUPPORTED_API")
        XCTAssertEqual(stored("clipboard"), .null)
        refusal("custom_alert", "!BridgeError: SCREEN_UNAVAILABLE")

        // Send-message hook, driven the way the composer drives it.
        XCTAssertEqual(stored("send_hook"), .string("Registration"))
        refusal("request_hook", "!BridgeError: UNSUPPORTED_API")
        XCTAssertTrue(stack.service.hasSendHooks)
        let plain = await self.send(stack, "plain")
        XCTAssertEqual(plain, [.string("plain"), .null, .bool(false)])
        XCTAssertEqual(stored("hook_seen"), .array([.integer(0), .integer(-1_001_234_567_890), .string("plain"), .null]))
        let edited = await self.send(stack, "edit me")
        XCTAssertEqual(edited, [.string("EDIT ME"), .null, .bool(false)])
        let cancelled = await self.send(stack, "cancel me")
        XCTAssertEqual(cancelled.last, .bool(true))
        let caption = await self.send(stack, "caption", caption: "old caption")
        XCTAssertEqual(caption, [.string("caption"), .string("new caption"), .bool(false)])
        let wrong = await self.send(stack, "wrong")
        XCTAssertEqual(wrong, [.string("wrong"), .null, .bool(false)], "A result of the wrong class leaves the message unchanged")
        let raised = await self.send(stack, "raise")
        XCTAssertEqual(raised, [.string("raise"), .null, .bool(false)], "A raising hook leaves the message unchanged")
        XCTAssertEqual(stack.record(id)?.isEnabled, true)

        // A second plugin with a higher priority runs first; MODIFY_FINAL ends the chain.
        let first = try await stack.start(AyuEndToEnd.source(id: "e2e_hook_first", """
        from base_plugin import BasePlugin, HookResult, HookStrategy


        class FirstHookPlugin(BasePlugin):
            def on_plugin_load(self):
                self.add_on_send_message_hook(priority=10)

            def on_send_message_hook(self, account, params):
                if params.message.startswith("edit"):
                    params.message = params.message + " first"
                    return HookResult(strategy=HookStrategy.MODIFY, params=params)
                if params.message.startswith("final"):
                    params.message = "final by first"
                    return HookResult(strategy=HookStrategy.MODIFY_FINAL, params=params)
                return HookResult()
        """))
        let chained = await self.send(stack, "edit me")
        XCTAssertEqual(chained.first, .string("EDIT ME FIRST"))
        let final = await self.send(stack, "final edit")
        XCTAssertEqual(final.first, .string("final by first"))
        XCTAssertEqual(stored("hook_seen").array?[2], .string("edit me first"), "The final result does not reach the next hook")
        await stack.remove(first)

        // Message context menu, driven the way the chat controller drives it.
        XCTAssertEqual(stored("menu"), .string("Registration"))
        refusal("menu_drawer", "!BridgeError: UNSUPPORTED_API")
        refusal("menu_subtext", "!BridgeError: UNSUPPORTED_API")
        refusal("menu_mvel", "!BridgeError: UNSUPPORTED_API")
        func context(_ message: Int64) -> AyuPluginMenuContext {
            AyuPluginMenuContext(screenIdentity: screen.identity, accountIdentity: UUID(), accountIndex: 0, dialogID: -1_001_234_567_890, messageID: message)
        }
        let even = await AyuPluginMenuBridge.shared.items(context: context(9_007_199_254_740_994), isCurrent: { true })
        XCTAssertEqual(even.map(\.text), ["Quote", "Always"], "Higher priority first; the condition accepted an even message id")
        XCTAssertEqual(even.first?.itemID, id + ":quote")
        XCTAssertEqual(even.first?.symbolName, "quote.bubble")
        let expected: AyuBridgeValue = .object(["account": .integer(0), "dialog_id": .integer(-1_001_234_567_890), "message_id": .integer(9_007_199_254_740_994)])
        XCTAssertEqual(stored("condition_context"), expected, "Int64 identifiers stay exact")
        let odd = await AyuPluginMenuBridge.shared.items(context: context(41), isCurrent: { true })
        XCTAssertEqual(odd.map(\.text), ["Always"])
        let stale = await AyuPluginMenuBridge.shared.items(context: context(42), isCurrent: { false })
        XCTAssertEqual(stale.count, 0)
        await AyuPluginMenuBridge.shared.perform(token: try XCTUnwrap(even.first?.token), context: context(9_007_199_254_740_994), isCurrent: { true })
        XCTAssertEqual(stored("clicked_context"), expected)
        try stack.store(id, "clicked_context", .null)
        await AyuPluginMenuBridge.shared.perform(token: try XCTUnwrap(even.first?.token), context: context(41), isCurrent: { true })
        XCTAssertEqual(stored("clicked_context"), .null, "A click is refused when the condition no longer holds")

        try await stack.service.disable(id)
        XCTAssertFalse(stack.service.hasSendHooks)
        let afterDisable = await self.send(stack, "edit me")
        XCTAssertEqual(afterDisable, [.string("edit me"), .null, .bool(false)])
        let none = await AyuPluginMenuBridge.shared.items(context: context(42), isCurrent: { true })
        XCTAssertEqual(none.count, 0, "Unload removes the plugin's menu items")
        await stack.remove(id)
        stack.unbindApplication()
    }

    func testOperationsOfTheUnboundTelegramBackendAreBlockers() async throws {
        let stack = try AyuEndToEnd.shared()
        let preview = try await stack.preview(AyuEndToEnd.source(id: "e2e_telegram", """
        from base_plugin import BasePlugin, MenuItemData, MenuItemType
        from client_utils import send_message


        class TelegramPlugin(BasePlugin):
            def on_plugin_load(self):
                self.add_hook("TL_messages_sendMessage")
                self.add_menu_item(MenuItemData(menu_type=MenuItemType.DRAWER_MENU, text="Drawer", on_click=lambda context: None))
                send_message({"peer": 1, "message": "text"})
        """))
        XCTAssertEqual(Set(preview.plugin.blockers), ["OPERATION: telegram.hooks.set (add_hook())", "OPERATION: menus.add (base_plugin.MenuItemType.DRAWER_MENU)",
                                                      "OPERATION: telegram.send_message (client_utils.send_message)"])
    }

    func testPresentedDialogReportsItsButton() throws {
        throw XCTSkip("Presenting an alert, a bulletin or a custom-view dialog needs an application-owned UIWindowScene; this runner has no host application")
    }

    func testPackageIsInspectedLoadedAndUnloaded() async throws {
        let stack = try AyuEndToEnd.shared()
        let entries: [(name: String, text: String)] = [
            ("metainfo.json", #"{"id": "e2e_package", "name": "Synthetic Package", "version": "1.2", "author": "tests", "description": "package fixture"}"#),
            ("main.py", """
            from base_plugin import BasePlugin
            import helpers
            from elyx import assets, metainfo, strings


            class PackagePlugin(BasePlugin):
                def on_plugin_load(self):
                    self.set_setting("loaded", [helpers.VALUE, metainfo["id"], strings.greeting, assets.get("note.txt").content_string(),
                                                __name__, __file__.endswith("/ElyxPlugins/e2e_package/main.py")])

                def create_settings(self):
                    from ui.settings import Header
                    return [Header(strings.greeting)]

                def on_plugin_unload(self):
                    self.set_setting("unloaded", True)

            """),
            ("helpers.py", "VALUE = 'helper module'\n"),
            ("strings/strings_en.yml", "greeting: Hello\n"),
            ("assets/note.txt", "asset text"),
        ]
        let url = try stack.package(entries)
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = try await stack.service.previewPlugin(from: url)
        XCTAssertEqual(preview.plugin.id, "e2e_package")
        XCTAssertEqual(preview.plugin.name, "Synthetic Package")
        XCTAssertEqual(preview.plugin.version, "1.2")
        XCTAssertEqual(preview.plugin.blockers, [])
        XCTAssertNil(stack.record("e2e_package"), "A preview stores nothing")
        try await stack.service.importPlugin(from: url)
        XCTAssertEqual(stack.record("e2e_package")?.isEnabled, false)
        XCTAssertEqual(stack.stored("e2e_package"), [:], "Importing a package runs none of its code")
        try await stack.service.enable("e2e_package")
        XCTAssertEqual(stack.stored("e2e_package", "loaded"), .array([.string("helper module"), .string("e2e_package"), .string("Hello"), .string("asset text"),
            .string("ElyxPlugins.e2e_package.main"), .bool(true)]))
        let rows = try await stack.service.settings("e2e_package")
        XCTAssertEqual(rows.map(\.text), ["Hello"])
        try await stack.service.disable("e2e_package")
        XCTAssertEqual(stack.stored("e2e_package", "unloaded"), .bool(true))
        try await stack.service.enable("e2e_package")
        XCTAssertEqual(stack.record("e2e_package")?.isEnabled, true, "A package loads again after an unload")
        await stack.remove("e2e_package")
        XCTAssertNil(stack.record("e2e_package"))
    }

    func testPackagesWithBlockersOrBrokenArchivesDoNotLoad() async throws {
        let stack = try AyuEndToEnd.shared()
        let main = "from base_plugin import BasePlugin\n\n\nclass BlockedPackage(BasePlugin):\n    def on_plugin_load(self):\n        self.set_setting('ran', True)\n"
        let blocked = try stack.package([
            ("metainfo.json", #"{"id": "e2e_package_blocked", "name": "Blocked Package", "version": "1.0"}"#),
            ("main.py", "import subprocess\n" + main), ("cached.pyc", "bytecode"),
        ], fileExtension: "eaf")
        defer { try? FileManager.default.removeItem(at: blocked) }
        let preview = try await stack.service.previewPlugin(from: blocked)
        XCTAssertEqual(Set(preview.plugin.blockers.map { String($0.prefix(while: { $0 != ":" })) }), ["IMPORT", "PACKAGE"], "\(preview.plugin.blockers)")
        try await stack.service.importPlugin(from: blocked)
        do {
            try await stack.service.enable("e2e_package_blocked")
            XCTFail("A blocked package was enabled")
        } catch {}
        XCTAssertEqual(stack.stored("e2e_package_blocked"), [:])
        await stack.remove("e2e_package_blocked")

        let broken = try stack.package([("metainfo.json", #"{"id": "e2e_package_broken", "name": "Broken"}"#), ("main.py", main)])
        defer { try? FileManager.default.removeItem(at: broken) }
        var bytes = try Data(contentsOf: broken)
        bytes.removeLast(30)
        try bytes.write(to: broken)
        do {
            _ = try await stack.service.previewPlugin(from: broken)
            XCTFail("A truncated archive was accepted")
        } catch {}
        let unnamed = try stack.package([("main.py", main)])
        defer { try? FileManager.default.removeItem(at: unnamed) }
        do {
            _ = try await stack.service.previewPlugin(from: unnamed)
            XCTFail("A package without a manifest was accepted")
        } catch {}
        XCTAssertTrue(stack.service.plugins.allSatisfy { !$0.id.hasPrefix("e2e_package") })
    }
}
