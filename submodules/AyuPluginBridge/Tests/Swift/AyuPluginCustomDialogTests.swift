import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// `ui.present` of an alert with a custom view, against a dialog host that records what it is asked to present.
@MainActor final class AyuPluginCustomDialogTests: XCTestCase {
    private final class DialogProvider: AyuPluginHostProvider, AyuPluginDialogHost, @unchecked Sendable {
        let reserved = AyuTestBox<[String]>([])
        let dismissed = AyuTestBox<[String]>([])
        let presented = AyuTestBox<[UIViewController]>([])
        var capabilities: [String] { ["ui.present"] }
        func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
            throw AyuBridgeFailure.unsupported(operation)
        }
        func detach(pluginID: String) {}
        func reserveDialogToken(_ token: String, pluginID: String) throws { self.reserved.update { $0.append(token) } }
        @MainActor func presentBridgeDialog(_ controller: UIViewController, token: String, pluginID: String) throws {
            self.presented.update { $0.append(controller) }
        }
        func dismissBridgeDialog(token: String, pluginID: String) { self.dismissed.update { $0.append(token) } }
    }

    private func call(_ host: AyuPluginNativeHost, _ operation: String, _ arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        let request: AyuBridgeValue = .object(["version": .integer(1), "id": .string("5"), "plugin_id": .string("alpha"), "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(decoding: try AyuBridgeJSON.encode(request), as: UTF8.self)
        let response = await Task.detached { host.dispatch(text, owner: "alpha") }.value
        return try AyuBridgeJSON.decode(Data(response.utf8))
    }

    private func layout(_ host: AyuPluginNativeHost) async throws -> AyuBridgeValue {
        let layout = try await self.call(host, "java.construct", ["class_name": .string("android.widget.LinearLayout"), "args": .array([])])
        let label = try await self.call(host, "java.construct", ["class_name": .string("android.widget.TextView"), "args": .array([])])
        let added = try await self.call(host, "java.invoke", ["target": layout["result"], "name": .string("addView"), "args": .array([label["result"]])])
        XCTAssertEqual(added["error"], .null, "\(added)")
        return layout["result"]
    }

    private func views<Kind: UIView>(of kind: Kind.Type, in view: UIView) -> [Kind] {
        ((view as? Kind).map { [$0] } ?? []) + view.subviews.flatMap { self.views(of: kind, in: $0) }
    }

    func testAViewOnlyDialogIsPresentedWithoutButtons() async throws {
        let provider = DialogProvider()
        let host = AyuPluginNativeHost(defaults: UserDefaults(suiteName: "AyuCustomDialogTests." + UUID().uuidString)!, provider: provider,
                                       classRegistry: .standard, trustedOwner: { "alpha" }, callback: { _, _, _ in })
        let authorized = try await self.call(host, "plugin.authorize", ["metadata": .object(["id": .string("alpha")]), "classes": .array([]), "requirements": .array([]), "imports": .array([])])
        XCTAssertEqual(authorized["result"], .bool(true), "\(authorized)")

        // Android shows a dialog whose only content is the view; its own controls or an outside tap close it.
        let viewOnly = try await self.call(host, "ui.present", ["kind": .string("alert"), "config": .object(["view": try await self.layout(host)])])
        XCTAssertEqual(viewOnly["result"]["$class"], .string("org.telegram.ui.ActionBar.AlertDialog"), "\(viewOnly)")
        XCTAssertEqual(provider.presented.value.count, 1)
        XCTAssertEqual(provider.dismissed.value, [], "The reservation of a presented dialog stays")
        let dialog = try XCTUnwrap(provider.presented.value.first as? AyuBridgeDialogViewController)
        dialog.loadViewIfNeeded()
        XCTAssertEqual(self.views(of: UIButton.self, in: dialog.view).count, 0)
        XCTAssertEqual(self.views(of: AyuBridgeView.self, in: dialog.view).count, 2, "The layout and its label are the dialog's content")
        XCTAssertEqual(dialog.view.gestureRecognizers?.count, 1, "A cancelable dialog closes on a tap outside")

        let locked = try await self.call(host, "ui.present", ["kind": .string("alert"), "config": .object([
            "title": .string("Title"), "view": try await self.layout(host), "cancelable": .bool(false),
        ])])
        XCTAssertEqual(locked["error"], .null, "\(locked)")
        let lockedDialog = try XCTUnwrap(provider.presented.value.last as? AyuBridgeDialogViewController)
        lockedDialog.loadViewIfNeeded()
        XCTAssertEqual(self.views(of: UIButton.self, in: lockedDialog.view).count, 0)
        XCTAssertNil(lockedDialog.view.gestureRecognizers, "Only the plugin dismisses a dialog that is not cancelable")
        XCTAssertEqual(self.views(of: UILabel.self, in: lockedDialog.view).compactMap(\.text).contains("Title"), true)

        let withButton = try await self.call(host, "ui.present", ["kind": .string("alert"), "config": .object([
            "view": try await self.layout(host), "positive_button": .object(["text": .string("OK"), "on_click": .null]),
        ])])
        XCTAssertEqual(withButton["error"], .null, "\(withButton)")
        let buttonDialog = try XCTUnwrap(provider.presented.value.last as? AyuBridgeDialogViewController)
        buttonDialog.loadViewIfNeeded()
        XCTAssertEqual(self.views(of: UIButton.self, in: buttonDialog.view).compactMap { $0.title(for: .normal) }, ["OK"])

        let reused = try await self.call(host, "ui.present", ["kind": .string("alert"), "config": .object(["view": .string("not a view")])])
        XCTAssertEqual(reused["error"]["code"], .string("INVALID_HANDLE"), "\(reused)")
        XCTAssertEqual(provider.presented.value.count, 3)
        _ = try await self.call(host, "plugin.deactivate")
    }
}
