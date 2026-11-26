import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

final class AyuBridgeTypefaceRuntimeTests: XCTestCase {
    private var adapter: AyuBridgeClassAdapter!

    override func setUpWithError() throws {
        self.adapter = try XCTUnwrap(AyuBridgeClassRegistry.standard.adapters["android.graphics.Typeface"])
    }

    func testOnlyTheFourBoundedTypefacePresetsAreExposed() throws {
        XCTAssertNil(self.adapter.constructor)
        XCTAssertTrue(self.adapter.staticMethods.isEmpty)
        XCTAssertTrue(self.adapter.methods.isEmpty)
        XCTAssertEqual(Set(self.adapter.constants.keys), Set(["NORMAL", "BOLD", "ITALIC", "BOLD_ITALIC"]))
        XCTAssertEqual(Set(self.adapter.staticFields.keys), Set(["DEFAULT", "DEFAULT_BOLD", "DEFAULT_ITALIC", "DEFAULT_BOLD_ITALIC"]))

        let expected: [String: Int64] = [
            "DEFAULT": 0,
            "DEFAULT_BOLD": 1,
            "DEFAULT_ITALIC": 2,
            "DEFAULT_BOLD_ITALIC": 3,
        ]
        for (name, style) in expected {
            let reader = try XCTUnwrap(self.adapter.staticFields[name])
            guard case let .instance(className, state) = try reader(self.context()) else {
                return XCTFail("Typeface preset did not return a bounded instance")
            }
            XCTAssertEqual(className, "android.graphics.Typeface")
            XCTAssertEqual(state, ["style": .integer(style)])
            XCTAssertNoThrow(try self.adapter.validateState(state))
        }
        XCTAssertThrowsError(try self.adapter.validateState(["style": .integer(4)]))
        XCTAssertThrowsError(try self.adapter.validateState(["family": .string("sans-serif")]))
    }

    private func context() -> AyuBridgeAdapterContext {
        AyuBridgeAdapterContext(pluginID: "tests", resolveCallback: { _ in throw AyuBridgeFailure.unsupported("callback") },
            resolve: { reference in AyuBridgeAdapterSnapshot(className: reference.object?["$class"]?.string ?? "unknown", state: reference.object ?? [:]) })
    }
}

@MainActor
final class AyuBridgeTypefaceNativeHostTests: XCTestCase {
    private func host() -> AyuPluginNativeHost {
        let defaults = UserDefaults(suiteName: "AyuPluginBridgeTypefaceTests." + UUID().uuidString)!
        return AyuPluginNativeHost(defaults: defaults, classRegistry: .standard, trustedOwner: { "alpha" }, callback: { _, _, _ in })
    }

    private func call(_ host: AyuPluginNativeHost, _ operation: String, arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        let request: AyuBridgeValue = .object([
            "version": .integer(1), "id": .string("18"), "plugin_id": .string("alpha"),
            "operation": .string(operation), "arguments": .object(arguments),
        ])
        let text = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        let response: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: host.dispatch(text, owner: "alpha"))
            }
        }
        return try JSONDecoder().decode(AyuBridgeValue.self, from: Data(response.utf8))
    }

    private func authorize(_ host: AyuPluginNativeHost) async throws {
        let result = try await self.call(host, "plugin.authorize", arguments: [
            "metadata": .object(["id": .string("alpha")]), "classes": .array([]),
            "requirements": .array([]), "imports": .array([]),
        ])
        XCTAssertEqual(result["result"], .bool(true))
    }

    private func construct(_ host: AyuPluginNativeHost, _ name: String, _ args: [AyuBridgeValue] = []) async throws -> AyuBridgeValue {
        try await self.call(host, "java.construct", arguments: ["class_name": .string(name), "args": .array(args)])
    }

    private func invoke(_ host: AyuPluginNativeHost, _ target: AyuBridgeValue, _ name: String, _ args: [AyuBridgeValue] = []) async throws -> AyuBridgeValue {
        try await self.call(host, "java.invoke", arguments: ["target": target, "name": .string(name), "args": .array(args)])
    }

    private func classTarget(_ name: String) -> AyuBridgeValue {
        .object(["class_name": .string(name)])
    }

    private func preset(_ host: AyuPluginNativeHost, _ name: String) async throws -> AyuBridgeValue {
        let member = try await self.call(host, "java.member", arguments: ["target": self.classTarget("android.graphics.Typeface"), "name": .string(name)])
        XCTAssertEqual(member["result"]["kind"], .string("field"))
        return member["result"]["value"]
    }

    func testSupportedPresetAndStyleOverloadsPreserveFontSizeAndTraits() async throws {
        let host = self.host()
        try await self.authorize(host)
        let textView = try await self.construct(host, "android.widget.TextView")
        let appliedSize = try await self.invoke(host, textView["result"], "setTextSize", [.number(22.5)])
        XCTAssertEqual(appliedSize["result"], .null)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 40))
        let attached = XCTestExpectation(description: "Typeface test container attached")
        host.setMountContainer(container, pluginID: "alpha") { attached.fulfill() }
        let attachResult = await XCTWaiter.fulfillment(of: [attached], timeout: 1)
        XCTAssertEqual(attachResult, .completed)
        let mounted = try await self.call(host, "ui.mount", arguments: ["target": textView["result"]])
        XCTAssertEqual(mounted["result"], .null)
        _ = try await self.invoke(host, textView["result"], "getWidth")

        let nativeView = try XCTUnwrap(container.subviews.first)
        let label = try XCTUnwrap(nativeView.subviews.first as? UILabel)
        let presets: [(String, Int64)] = [
            ("DEFAULT", 0), ("DEFAULT_BOLD", 1), ("DEFAULT_ITALIC", 2), ("DEFAULT_BOLD_ITALIC", 3),
        ]
        for (name, style) in presets {
            let typeface = try await self.preset(host, name)
            let applied = try await self.invoke(host, textView["result"], "setTypeface", [typeface])
            XCTAssertEqual(applied["result"], .null)
            _ = try await self.invoke(host, textView["result"], "getWidth")
            let traits = label.font.fontDescriptor.symbolicTraits
            XCTAssertEqual(label.font.pointSize, 22.5, accuracy: 0.001)
            XCTAssertEqual(traits.contains(.traitBold), style == 1 || style == 3)
            XCTAssertEqual(traits.contains(.traitItalic), style == 2 || style == 3)
        }

        let styles: [(String, Int64)] = [("NORMAL", 0), ("BOLD", 1), ("ITALIC", 2), ("BOLD_ITALIC", 3)]
        for (name, style) in styles {
            let constant = try await self.call(host, "java.member", arguments: [
                "target": self.classTarget("android.graphics.Typeface"), "name": .string(name),
            ])
            XCTAssertEqual(constant["result"]["value"], .integer(style))
            let applied = try await self.invoke(host, textView["result"], "setTypeface", [.null, constant["result"]["value"]])
            XCTAssertEqual(applied["result"], .null)
            _ = try await self.invoke(host, textView["result"], "getWidth")
            let traits = label.font.fontDescriptor.symbolicTraits
            XCTAssertEqual(label.font.pointSize, 22.5, accuracy: 0.001)
            XCTAssertEqual(traits.contains(.traitBold), style == 1 || style == 3)
            XCTAssertEqual(traits.contains(.traitItalic), style == 2 || style == 3)
        }

        let boldItalic = try await self.preset(host, "DEFAULT_BOLD_ITALIC")
        let applyBoldItalic = try await self.invoke(host, textView["result"], "setTypeface", [boldItalic, .integer(3)])
        XCTAssertEqual(applyBoldItalic["result"], .null)
        _ = try await self.invoke(host, textView["result"], "getWidth")
        XCTAssertEqual(label.font.pointSize, 22.5, accuracy: 0.001)
        XCTAssertTrue(label.font.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(label.font.fontDescriptor.symbolicTraits.contains(.traitItalic))

        let changeSize = try await self.invoke(host, textView["result"], "setTextSize", [.number(18.25)])
        XCTAssertEqual(changeSize["result"], .null)
        _ = try await self.invoke(host, textView["result"], "getWidth")
        XCTAssertEqual(label.font.pointSize, 18.25, accuracy: 0.001)
        XCTAssertTrue(label.font.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(label.font.fontDescriptor.symbolicTraits.contains(.traitItalic))

        let editText = try await self.construct(host, "android.widget.EditText")
        let editTextTypeface = try await self.preset(host, "DEFAULT_BOLD")
        let editTypefaceResult = try await self.invoke(host, editText["result"], "setTypeface", [editTextTypeface])
        XCTAssertEqual(editTypefaceResult["error"], .null)
    }

    func testTypefaceConstructorsFamiliesReferencesArityAndGetAreRejected() async throws {
        let host = self.host()
        try await self.authorize(host)
        let textView = try await self.construct(host, "android.widget.TextView")
        let typefaceClass = self.classTarget("android.graphics.Typeface")
        let constructor = try await self.construct(host, "android.graphics.Typeface", [.string("sans-serif")])
        XCTAssertEqual(constructor["error"]["code"], .string("UNSUPPORTED_API"))
        let family = try await self.invoke(host, typefaceClass, "create", [.string("sans-serif"), .integer(1)])
        XCTAssertEqual(family["error"]["code"], .string("UNSUPPORTED_API"))

        let noArguments = try await self.invoke(host, textView["result"], "setTypeface")
        XCTAssertEqual(noArguments["error"]["code"], .string("INVALID_ARGUMENTS"))
        let nullOneArgument = try await self.invoke(host, textView["result"], "setTypeface", [.null])
        XCTAssertEqual(nullOneArgument["error"]["code"], .string("UNSUPPORTED_API"))
        let integerReference = try await self.invoke(host, textView["result"], "setTypeface", [.integer(1)])
        XCTAssertEqual(integerReference["error"]["code"], .string("UNSUPPORTED_API"))
        let wrongArity = try await self.invoke(host, textView["result"], "setTypeface", [.null, .integer(1), .integer(2)])
        XCTAssertEqual(wrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
        let invalidStyle = try await self.invoke(host, textView["result"], "setTypeface", [.null, .integer(4)])
        XCTAssertEqual(invalidStyle["error"]["code"], .string("INVALID_ARGUMENTS"))
        let wrongStyleType = try await self.invoke(host, textView["result"], "setTypeface", [.null, .string("bold")])
        XCTAssertEqual(wrongStyleType["error"]["code"], .string("INVALID_ARGUMENTS"))
        let noGetter = try await self.invoke(host, textView["result"], "getTypeface")
        XCTAssertEqual(noGetter["error"]["code"], .string("UNSUPPORTED_API"))

        let intent = try await self.construct(host, "android.content.Intent")
        let foreignReference = try await self.invoke(host, textView["result"], "setTypeface", [intent["result"]])
        XCTAssertEqual(foreignReference["error"]["code"], .string("UNSUPPORTED_API"))
    }
}
