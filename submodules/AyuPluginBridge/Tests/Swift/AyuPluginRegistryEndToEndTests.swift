import Foundation
import UIKit
import XCTest
@testable import AyuPluginBridge

/// `PluginsController`, `PluginSettingsActivity` and `LayoutHelper` of the Python SDK against the
/// operations the Swift host serves for them, through the real runtime.
@MainActor
final class AyuPluginRegistryEndToEndTests: XCTestCase {
    func testSDKFacadesReachTheHostOperations() async throws {
        let stack = try AyuEndToEnd.shared()
        let neighbour = try await stack.install(AyuEndToEnd.source(id: "e2e_neighbour", version: "3.4", metadata: "__icon__ = \"pack/2\"", """
        from base_plugin import BasePlugin


        class Neighbour(BasePlugin):
            pass
        """))
        self.addTeardownBlock { await stack.remove(neighbour.id) }

        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_registry", version: "1.5", """
        from android.view import Gravity
        from base_plugin import BasePlugin
        from com.exteragram.messenger.plugins import PluginsController
        from org.telegram.ui.Components import LayoutHelper
        from ui.settings import Header


        def code(action):
            try:
                action()
            except Exception as error:
                return getattr(error, "code", type(error).__name__)
            return "ok"


        class RegistryPlugin(BasePlugin):
            def on_plugin_load(self):
                controller = PluginsController.getInstance()
                plugins = controller.plugins
                me, other = plugins.get(self.id), plugins.get("e2e_neighbour")
                self.set_setting("self", [me.getName(), me.getVersion(), me.isEnabled(), me.hasError(), controller.isPluginActive(self.id)])
                self.set_setting("other", [other.getName(), other.getVersion(), other.getIcon(), other.isEnabled(), controller.isPluginActive(other)])
                self.set_setting("absent", plugins.get("e2e_absent") is None)
                self.set_setting("reload", code(lambda: controller.loadPluginSettings(self.id)))
                self.set_setting("reload_other", code(lambda: controller.loadPluginSettings("e2e_neighbour")))
                self.set_setting("open_disabled", code(lambda: PluginsController.openPluginSettings("e2e_neighbour")))
                self.set_setting("open_unknown", code(lambda: PluginsController.openPluginSettings("e2e_absent")))

                frame = LayoutHelper.createFrame(-1, 47.5, Gravity.CENTER, 8, 0.5, 8, 4)
                self.set_setting("frame", [frame.width, frame.height, frame.gravity, frame.leftMargin, frame.topMargin, frame.bottomMargin])
                frame.gravity = Gravity.BOTTOM | Gravity.RIGHT
                frame.topMargin = 12
                self.set_setting("frame_written", [frame.gravity, frame.topMargin])
                linear = LayoutHelper.createLinear(0, -2, 1.0, Gravity.CENTER_VERTICAL)
                self.set_setting("linear", [linear.width, linear.height, linear.weight, linear.gravity, linear.leftMargin])
                self.set_setting("plain", LayoutHelper.createLinear(-1, -2).gravity)
                self.set_setting("clip", code(lambda: LayoutHelper.createFrame(-1, -1, 0x88)))
                relative = LayoutHelper.createFrameRelatively(40, 40, Gravity.START | Gravity.TOP, 1, 2, 3, 4)
                self.set_setting("relative", [relative.gravity, relative.leftMargin, relative.rightMargin])
                pixels = LayoutHelper.createFrameMarginPx(-1, -2, Gravity.END, 6, 0, 0, 0)
                self.set_setting("pixels", [pixels.gravity, pixels.leftMargin > 0, pixels.leftMargin <= 6])

            def create_settings(self):
                return [Header(text="Registry")]
        """))
        self.addTeardownBlock { await stack.remove(id) }

        // The caller is listed as running while it loads; the neighbour is installed and disabled.
        XCTAssertEqual(stack.stored(id, "self"), .array([.string("Synthetic e2e_registry"), .string("1.5"), .bool(true), .bool(false), .bool(true)]))
        XCTAssertEqual(stack.stored(id, "other"), .array([.string("Synthetic e2e_neighbour"), .string("3.4"), .string("pack/2"), .bool(false), .bool(false)]))
        XCTAssertEqual(stack.stored(id, "absent"), .bool(true))
        XCTAssertEqual(stack.stored(id, "reload"), .string("ok"))
        XCTAssertEqual(stack.stored(id, "reload_other"), .string("UNSUPPORTED_API"))
        XCTAssertEqual(stack.stored(id, "open_disabled"), .string("INVALID_STATE"))
        XCTAssertEqual(stack.stored(id, "open_unknown"), .string("INVALID_ARGUMENTS"))

        XCTAssertEqual(stack.stored(id, "frame"), .array([.integer(-1), .integer(48), .integer(17), .integer(8), .integer(1), .integer(4)]))
        XCTAssertEqual(stack.stored(id, "frame_written"), .array([.integer(0x55), .integer(12)]))
        XCTAssertEqual(stack.stored(id, "linear"), .array([.integer(0), .integer(-2), .number(1), .integer(16), .integer(0)]))
        XCTAssertEqual(stack.stored(id, "plain"), .integer(-1))
        XCTAssertEqual(stack.stored(id, "clip"), .string("UNSUPPORTED_API"))
        // Resolved when created, for the interface direction and the screen of the process.
        let rightToLeft = UIView.userInterfaceLayoutDirection(for: .unspecified) == .rightToLeft
        XCTAssertEqual(stack.stored(id, "relative"), .array([.integer(rightToLeft ? 0x35 : 0x33), .integer(rightToLeft ? 3 : 1), .integer(rightToLeft ? 1 : 3)]))
        XCTAssertEqual(stack.stored(id, "pixels"), .array([.integer(0x0080_0005), .bool(true), .bool(true)]))

        // Once loaded, a reload reaches the settings screens as the notification `reload_settings` posts.
        let generation = AyuTestBox<String?>(nil)
        let reloaded = self.expectation(forNotification: AyuPluginNativeHost.settingsDidChange, object: stack.service.host) { notification in
            guard notification.userInfo?["pluginID"] as? String == id else { return false }
            generation.value = notification.userInfo?["generation"] as? String
            return true
        }
        let reload = try await stack.host(id, "plugins.settings", ["action": .string("reload"), "plugin_id": .string(id)])
        XCTAssertEqual(reload, .null)
        await self.fulfillment(of: [reloaded], timeout: 5)
        XCTAssertTrue(stack.service.shouldReloadSettings(pluginID: id, generation: generation.value ?? ""), "The settings screen accepts the reload")

        // No application screen is bound in the test process, so nothing can be shown.
        do {
            _ = try await stack.host(id, "plugins.settings", ["action": .string("open"), "plugin_id": .string(id)])
            XCTFail("A settings screen without a presenter")
        } catch { XCTAssertEqual((error as? AyuBridgeFailure)?.code, "SCREEN_UNAVAILABLE") }
        let listed = try await stack.host(id, "plugins.list")
        let ids = Set(listed.array?.compactMap { $0["id"].string } ?? [])
        XCTAssertTrue(ids.isSuperset(of: [id, "e2e_neighbour"]))
        XCTAssertEqual(ids.count, stack.service.plugins.count)
    }
}
