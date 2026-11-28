import Foundation
import XCTest
@testable import AyuPluginBridge

/// What the Swift host declares against what the Python SDK accepts.
@MainActor
final class AyuPluginEndToEndCapabilitiesTests: XCTestCase {
    /// The capabilities of the app's composition, written to AYU_PLUGIN_TEST_CAPABILITIES_OUT
    /// for the corpus meter (`run_swift_tests.py --capabilities FILE`).
    func testApplicationHostCapabilitiesAreCompleteAndCanBeWritten() async throws {
        let stack = try AyuEndToEnd.shared()
        let capabilities = try await AyuEndToEnd.capabilities(of: stack.service.host)
        let operations = Set(capabilities["operations"].array?.compactMap(\.string) ?? [])
        let classes = Set(capabilities["classes"].array?.compactMap(\.string) ?? [])
        XCTAssertTrue(operations.isSuperset(of: ["runtime.capabilities", "scheduler.schedule", "menus.register", "hooks.register"]))
        XCTAssertTrue(classes.isSuperset(of: ["android.net.Uri", "org.telegram.messenger.NotificationCenter", "org.telegram.messenger.NotificationCenter$NotificationCenterDelegate"]))
        XCTAssertNotNil(capabilities["proxy_interfaces"].object?["org.telegram.messenger.NotificationCenter$NotificationCenterDelegate"])
        XCTAssertEqual(Set(capabilities["members"]["classes"].object?.keys.map { $0 } ?? []), classes, "The member table covers every declared class")
        if let path = ProcessInfo.processInfo.environment["AYU_PLUGIN_TEST_CAPABILITIES_OUT"] {
            // The app always binds its theme and language, and members that need them are
            // declared only while they are bound: the dump is of the app's state.
            stack.application.presentation.bind(palette: { AyuPluginThemePalette(isDark: false, isNight: false, colors: [:]) },
                                                language: { AyuPluginLanguage(code: "en", baseCode: nil) })
            defer { stack.application.presentation.bind(palette: nil, language: nil) }
            let bound = try await AyuEndToEnd.capabilities(of: stack.service.host)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(bound).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Every registry and provider the app can combine into a host must answer
    /// `runtime.capabilities` with something `Runtime._capabilities` accepts: a rejected
    /// answer fails every preflight and every load of that host.
    func testEveryHostCompositionDeclaresCapabilitiesTheSDKAccepts() async throws {
        let stack = try AyuEndToEnd.shared()
        let suite = "AyuPluginBridgeTests.Capabilities." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let application = AyuPluginApplicationBridge()
        let registries: [(String, AyuBridgeClassRegistry)] = [("standard", .standard), ("application", try application.classRegistry())]
        let providers: [(String, AyuPluginHostProvider)] = [
            ("unsupported", AyuUnsupportedPluginHostProvider()), ("application", application),
            ("menus", AyuPluginMenuHostProvider(application: application, menus: AyuPluginMenuBridge(), telegram: AyuPluginTelegramBridge())),
        ]
        var declared: [(String, AyuBridgeValue)] = []
        for (registryName, registry) in registries {
            for (providerName, provider) in providers {
                let host = AyuPluginNativeHost(defaults: defaults, provider: provider, classRegistry: registry, trustedOwner: { nil }, callback: { _, _, _ in })
                declared.append((registryName + "_" + providerName, try await AyuEndToEnd.capabilities(of: host)))
            }
        }
        // The default host of `AyuPluginService()` and the one of `AyuPluginService.shared`.
        declared.append(("service", try await AyuEndToEnd.capabilities(of: stack.service.host)))

        // Control: the probe must refuse what the SDK refuses.
        var broken = try XCTUnwrap(declared[0].1.object)
        broken["proxy_interfaces"] = .object(["synthetic.Undeclared$Listener": .array([.string("onEvent")])])
        declared.append(("control", .object(broken)))

        let payloads = try declared.map { name, value in
            "    \"\(name)\": \"\(try JSONEncoder().encode(value).base64EncodedString())\","
        }.joined(separator: "\n")
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_capabilities", """
        import base64
        import ayu_bridge
        from base_plugin import BasePlugin

        PAYLOADS = {
        \(payloads)
        }


        class Probe(ayu_bridge.Runtime):
            def __init__(self, payload):
                super().__init__()
                self.thread_id = ayu_bridge.runtime.thread_id
                self.payload = payload

            def _dispatch(self, plugin_id, operation, arguments):
                assert operation == "runtime.capabilities"
                return ayu_bridge.parse_json(self.payload)


        class CapabilitiesPlugin(BasePlugin):
            def on_plugin_load(self):
                for name, payload in PAYLOADS.items():
                    try:
                        accepted = Probe(base64.b64decode(payload).decode("utf-8"))._capabilities()
                        verdict = "accepted %d classes" % len(accepted["classes"])
                    except ayu_bridge.BridgeError as error:
                        verdict = "%s: %s" % (error.code, error)
                    self.set_setting(name, verdict)
        """))
        for (name, value) in declared where name != "control" {
            let classes = value["classes"].array?.count ?? -1
            XCTAssertEqual(stack.stored(id, name), .string("accepted \(classes) classes"), name)
        }
        XCTAssertEqual(stack.stored(id, "control").string?.hasPrefix("PROTOCOL_ERROR"), true, "\(stack.stored(id, "control"))")
        await stack.remove(id)
    }
}
