import Foundation
import XCTest
@testable import AyuPluginBridge

/// `BasePlugin.add_menu_item` through the real SDK and `menus.add`, with a fake Telegram cache.
@MainActor
final class AyuPluginEndToEndMenusTests: XCTestCase {
    /// `userEmpty#d3bc4b7a id:long` for user 77 and `messageEmpty#90a6ca84 flags:# id:int` for message 12.
    private static let user = Data([122, 75, 188, 211, 77, 0, 0, 0, 0, 0, 0, 0])
    private static let message = Data([132, 202, 166, 144, 0, 0, 0, 0, 12, 0, 0, 0])

    private static let plugin = """
    from base_plugin import BasePlugin, MenuItemData, MenuItemType
    \(AyuEndToEnd.recorder)

    class MenuPlugin(Recorder, BasePlugin):
        def on_plugin_load(self):
            self.record("chat", lambda: self.add_menu_item(MenuItemData(
                menu_type=MenuItemType.CHAT_ACTION_MENU, text="Chat row", item_id="chat", icon="msg_settings",
                subtext="Synthetic", priority=3, on_click=self.clicked, on_long_click=self.pressed, condition=self.shown)))
            self.record("hidden", lambda: self.add_menu_item(MenuItemData(
                menu_type=MenuItemType.CHAT_ACTION_MENU, text="Hidden row", item_id="hidden",
                on_click=self.clicked, condition=lambda context: False)))
            self.record("message", lambda: self.add_menu_item(MenuItemData(
                menu_type=MenuItemType.MESSAGE_CONTEXT_MENU, text="Message row", item_id="message", on_click=self.message_clicked)))
            self.record("drawer", lambda: self.add_menu_item(MenuItemData(
                menu_type=MenuItemType.DRAWER_MENU, text="Drawer row", item_id="drawer", on_click=self.drawer_clicked)))
            self.record("mvel", lambda: self.add_menu_item(MenuItemData(
                menu_type=MenuItemType.CHAT_ACTION_MENU, text="MVEL", item_id="mvel", on_click=self.clicked, condition="user != null")))

        def shown(self, context):
            self.set_setting("condition", sorted(context))
            return context["user"].id == 77

        def clicked(self, context):
            self.set_setting("clicked", [context["account"], context["dialog_id"], type(context["user"]).__name__, context["userId"]])

        def pressed(self, context):
            self.set_setting("pressed", context["userId"])

        def message_clicked(self, context):
            message = context["message"]
            self.set_setting("message_clicked", [context["dialog_id"], type(message).__name__, message.getId()])

        def drawer_clicked(self, context):
            self.set_setting("drawer_clicked", sorted(key for key in context if key not in ("fragment", "context")))
    """

    func testAddMenuItemServesEveryMenuWithTLContext() async throws {
        let stack = try AyuEndToEnd.shared()
        let screen = stack.bindApplication(dialogID: 77)
        let account = UUID()
        let menus = AyuPluginMenuBridge.shared
        let user = Self.user, message = Self.message
        menus.typed.setTLSource {
            AyuPluginTypedMenus.TLSource(account: { index in
                index == 0 ? AyuPluginTelegramAccount(index: 0, identity: account, userID: 1) : nil
            }, peer: { _, kind, id, completion in
                completion(.success(kind == .user && id == 77 ? user : nil))
            }, messages: { _, _, ids, completion in
                completion(.success(ids.map { $0 == 12 ? message : nil }))
            })
        }
        menus.bindLocations(resolve: { request in
            AyuPluginMenuLocation(kind: request.kind, screen: screen, accountIdentity: account,
                                  dialogID: request.kind.needsDialog ? 77 : nil, messageID: request.messageID)
        }, isCurrent: { location, _ in location.isCurrent(screen: screen, accountIdentity: account) })
        defer {
            menus.unbindLocations()
            menus.typed.setTLSource { AyuPluginTelegramBridge.shared.menuContextSource() }
            stack.unbindApplication()
        }
        let capabilities = try await AyuEndToEnd.capabilities(of: stack.service.host)
        XCTAssertTrue(capabilities["operations"].array?.contains(.string("menus.add")) == true)

        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_menus", Self.plugin))
        XCTAssertEqual(stack.stored(id, "chat"), .string("chat"))
        XCTAssertEqual(stack.stored(id, "message"), .string("message"))
        XCTAssertEqual(stack.stored(id, "drawer"), .string("drawer"))
        XCTAssertTrue(stack.stored(id, "mvel").string?.hasPrefix("!UnsupportedAPI") == true, "\(stack.stored(id, "mvel"))")

        let chat = await menus.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: nil), isPresented: { true })
        XCTAssertEqual(chat.entries.map(\.identifier), ["e2e_menus:chat"])
        let row = try XCTUnwrap(chat.entries.first)
        XCTAssertEqual(row.text, "Chat row")
        XCTAssertEqual(row.subtext, "Synthetic")
        XCTAssertEqual(row.icon, .asset("Chat/Context Menu/Settings"))
        XCTAssertTrue(row.hasLongClick)
        let condition = stack.stored(id, "condition").array?.compactMap(\.string) ?? []
        XCTAssertTrue(Set(condition).isSuperset(of: ["account", "dialog_id", "user", "userId"]), "\(condition)")
        chat.activate(row)
        let clicked = await stack.waitForStored(id, "clicked")
        XCTAssertEqual(clicked, .array([.integer(0), .integer(77), .string("TL_userEmpty"), .integer(77)]))
        chat.activate(row, longClick: true)
        let pressed = await stack.waitForStored(id, "pressed")
        XCTAssertEqual(pressed, .integer(77))

        let messageMenu = await menus.open(AyuPluginMenuRequest(kind: .messageContextMenu, accountKey: nil, messageID: 12), isPresented: { true })
        XCTAssertEqual(messageMenu.entries.map(\.identifier), ["e2e_menus:message"])
        messageMenu.activate(try XCTUnwrap(messageMenu.entries.first))
        let messageClicked = await stack.waitForStored(id, "message_clicked")
        XCTAssertEqual(messageClicked, .array([.integer(77), .string("MessageObject"), .integer(12)]))

        let main = await menus.open(AyuPluginMenuRequest(kind: .mainMenu, accountKey: nil), isPresented: { true })
        XCTAssertEqual(main.entries.map(\.identifier), ["e2e_menus:drawer"])
        main.activate(try XCTUnwrap(main.entries.first))
        let drawerClicked = await stack.waitForStored(id, "drawer_clicked")
        XCTAssertEqual(drawerClicked, .array([.string("account")]))

        await stack.remove(id)
        let afterUnload = await menus.open(AyuPluginMenuRequest(kind: .chatActionMenu, accountKey: nil), isPresented: { true })
        XCTAssertTrue(afterUnload.entries.isEmpty)
    }
}
