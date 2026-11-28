import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// `ui.present` of a full-screen custom-view dialog (`android.app.Dialog` with a black full-screen theme).
@MainActor final class AyuWave7DialogsTests: XCTestCase {
    private final class DialogProvider: AyuPluginHostProvider, AyuPluginDialogHost, @unchecked Sendable {
        let presented = AyuTestBox<[UIViewController]>([])
        var capabilities: [String] { ["ui.present"] }
        func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
            throw AyuBridgeFailure.unsupported(operation)
        }
        func detach(pluginID: String) {}
        func reserveDialogToken(_ token: String, pluginID: String) throws {}
        @MainActor func presentBridgeDialog(_ controller: UIViewController, token: String, pluginID: String) throws {
            self.presented.update { $0.append(controller) }
        }
        func dismissBridgeDialog(token: String, pluginID: String) {}
    }

    private func call(_ host: AyuPluginNativeHost, _ operation: String, _ arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        let request: AyuBridgeValue = .object(["version": .integer(1), "id": .string("5"), "plugin_id": .string("alpha"), "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(decoding: try AyuBridgeJSON.encode(request), as: UTF8.self)
        let response = await Task.detached { host.dispatch(text, owner: "alpha") }.value
        return try AyuBridgeJSON.decode(Data(response.utf8))
    }

    private func frame(_ host: AyuPluginNativeHost) async throws -> AyuBridgeValue {
        try await self.call(host, "java.construct", ["class_name": .string("android.widget.FrameLayout"), "args": .array([])])["result"]
    }

    func testAFullscreenDialogShowsOnlyItsContentOverTheWholeScreen() async throws {
        let provider = DialogProvider()
        let host = AyuPluginNativeHost(defaults: UserDefaults(suiteName: "AyuWave7DialogsTests." + UUID().uuidString)!, provider: provider,
                                       classRegistry: .standard, trustedOwner: { "alpha" }, callback: { _, _, _ in })
        let authorized = try await self.call(host, "plugin.authorize", ["metadata": .object(["id": .string("alpha")]), "classes": .array([]), "requirements": .array([]), "imports": .array([])])
        XCTAssertEqual(authorized["result"], .bool(true), "\(authorized)")

        let shown = try await self.call(host, "ui.present", ["kind": .string("alert"), "config": .object(["view": try await self.frame(host), "fullscreen": .bool(true)])])
        XCTAssertEqual(shown["error"], .null, "\(shown)")
        let dialog = try XCTUnwrap(provider.presented.value.first as? AyuBridgeDialogViewController)
        XCTAssertTrue(dialog.isFullscreen)
        dialog.loadViewIfNeeded()
        dialog.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        dialog.view.layoutIfNeeded()
        XCTAssertEqual(dialog.view.backgroundColor, .black)
        XCTAssertEqual(dialog.view.subviews.count, 1)
        XCTAssertTrue(dialog.view.subviews.first is AyuBridgeView)
        XCTAssertEqual(dialog.view.subviews.first?.frame, dialog.view.bounds, "The content covers the screen")
        XCTAssertNil(dialog.view.gestureRecognizers, "Only the plugin closes a full-screen dialog")

        // A full-screen dialog has no title, buttons or cancel switch.
        for extra in ["title": AyuBridgeValue.string("Title"), "cancelable": .bool(true), "fullscreen": .bool(false)] {
            var config: [String: AyuBridgeValue] = ["view": try await self.frame(host), "fullscreen": .bool(true)]
            config[extra.key] = extra.value
            let refused = try await self.call(host, "ui.present", ["kind": .string("alert"), "config": .object(config)])
            XCTAssertEqual(refused["error"]["code"], .string("INVALID_ARGUMENTS"), "\(refused)")
        }
        XCTAssertEqual(provider.presented.value.count, 1)
        _ = try await self.call(host, "plugin.deactivate")
    }
}
