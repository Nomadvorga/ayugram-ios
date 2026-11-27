import Foundation
import XCTest
@testable import AyuPluginBridge

/// Import, enable, settings and disable of one synthetic plugin through `AyuPluginService`.
@MainActor
final class AyuPluginPythonEndToEndTests: XCTestCase {
    func testSyntheticPluginPreflightsLoadsCallsTheHostAndUnloads() async throws {
        let stack = try AyuEndToEnd.shared()
        let source = AyuEndToEnd.source(id: "e2e_smoke", metadata: "__min_version__ = \"11.12.0\"", """
        from android.net import Uri
        from base_plugin import BasePlugin
        from ui.settings import Header, Switch


        class SyntheticPlugin(BasePlugin):
            def on_plugin_load(self):
                uri = Uri.parse("https://example.org/a/b?item=first&item=second")
                self.set_setting("uri_item", uri.getQueryParameter("item"))
                self.set_setting("uri_host", uri.getHost())
                self.log("synthetic plugin loaded")

            def create_settings(self):
                return [Header(text="Synthetic"), Switch(key="enabled", text="Enabled", default=True)]
        """)

        let preview = try await stack.preview(source)
        XCTAssertEqual(preview.plugin.id, "e2e_smoke")
        XCTAssertEqual(preview.plugin.name, "Synthetic e2e_smoke")
        XCTAssertEqual(preview.plugin.version, "1.0.0")
        XCTAssertEqual(preview.plugin.blockers, [])
        XCTAssertFalse(preview.isUpdate)
        XCTAssertNil(stack.record("e2e_smoke"), "A preview stores nothing")

        let id = try await stack.start(source)
        XCTAssertEqual(stack.record(id)?.isEnabled, true)
        // Written by on_plugin_load from the answers of the Swift Uri adapter.
        XCTAssertEqual(stack.stored(id, "uri_item"), .string("first"))
        XCTAssertEqual(stack.stored(id, "uri_host"), .string("example.org"))
        let fromHost = try await stack.host(id, "settings.get", ["key": .string("uri_item")])
        XCTAssertEqual(fromHost, .string("first"))

        let rows = try await stack.service.settings(id)
        XCTAssertEqual(rows.map(\.type), ["Header", "Switch"])
        XCTAssertEqual(rows.last?.key, "enabled")
        XCTAssertEqual(rows.last?.value, .bool(true))

        try await stack.service.disable(id)
        XCTAssertEqual(stack.record(id)?.isEnabled, false)
        do {
            _ = try await stack.service.settings(id)
            XCTFail("Settings of a disabled plugin")
        } catch {}
        do {
            _ = try await stack.host(id, "settings.get", ["key": .string("uri_item")])
            XCTFail("The host session ends with the plugin")
        } catch { XCTAssertEqual((error as? AyuBridgeFailure)?.code, "UNAUTHORIZED") }
        XCTAssertEqual(stack.stored(id, "uri_item"), .string("first"), "Disabling keeps the settings")

        await stack.remove(id)
        XCTAssertNil(stack.record(id))
        XCTAssertEqual(stack.stored(id), [:], "Deleting clears the settings namespace")
    }
}
