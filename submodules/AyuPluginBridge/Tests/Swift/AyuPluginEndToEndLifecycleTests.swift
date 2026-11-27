import Foundation
import XCTest
@testable import AyuPluginBridge

/// Metadata policy, load/unload and generations of synthetic plugins through `AyuPluginService`.
@MainActor
final class AyuPluginEndToEndLifecycleTests: XCTestCase {
    nonisolated private static let emptyPlugin = """
    from base_plugin import BasePlugin


    class EmptyPlugin(BasePlugin):
        pass
    """

    private func blockerCodes(_ stack: AyuEndToEnd, metadata: String, body: String = AyuPluginEndToEndLifecycleTests.emptyPlugin) async throws -> [String] {
        let preview = try await stack.preview(AyuEndToEnd.source(id: "e2e_policy", metadata: metadata, body))
        return preview.plugin.blockers.map { String($0.prefix(while: { $0 != ":" })) }
    }

    func testVersionPolicyFollowsTheEmulatedAndroidVersions() async throws {
        let stack = try AyuEndToEnd.shared()
        // The bridge emulates plugin SDK 1.4.6.5 and exteraGram 13.2.2.
        let satisfied = [
            "__min_version__ = \"11.12.0\"", "__min_version__ = \"13.2.2\"", "__app_version__ = \">=13.2\"",
            "__app_version__ = \"<14\"", "__sdk_version__ = \">=1.4\"", "__sdk_version__ = \"==1.4.6.5\"",
            // __min_version__ is ignored when __app_version__ is present.
            "__min_version__ = \"99.0\"\n__app_version__ = \">=13.0.0\"",
        ]
        for metadata in satisfied {
            let codes = try await self.blockerCodes(stack, metadata: metadata)
            XCTAssertEqual(codes, [], metadata)
        }
        let unmet = [
            "__min_version__ = \"13.2.3\"", "__app_version__ = \">13.2.2\"", "__app_version__ = \"13.2.2\"",
            "__sdk_version__ = \"<1.4\"", "__sdk_version__ = \">=1.5\"",
        ]
        for metadata in unmet {
            let codes = try await self.blockerCodes(stack, metadata: metadata)
            XCTAssertEqual(codes, ["VERSION_POLICY"], metadata)
        }
    }

    func testRequirementImportAndClassBlockers() async throws {
        let stack = try AyuEndToEnd.shared()
        let bundled = try await self.blockerCodes(stack, metadata: "__requirements__ = [\"requests>=2.0\", \"dataclasses\"]")
        XCTAssertEqual(bundled, [])
        let missing = try await stack.preview(AyuEndToEnd.source(id: "e2e_policy", metadata: "__requirements__ = \"numpy, Pillow>=9\"", Self.emptyPlugin))
        XCTAssertEqual(missing.plugin.blockers.count, 2, "\(missing.plugin.blockers)")
        XCTAssertTrue(missing.plugin.blockers.allSatisfy { $0.hasPrefix("REQUIREMENT: ") }, "\(missing.plugin.blockers)")
        XCTAssertEqual(missing.requirements, ["numpy", "Pillow>=9"])

        let process = try await self.blockerCodes(stack, metadata: "", body: "import subprocess\n" + Self.emptyPlugin)
        XCTAssertEqual(process, ["IMPORT"])
        let dependency = try await self.blockerCodes(stack, metadata: "", body: "import numpy\n" + Self.emptyPlugin)
        XCTAssertEqual(dependency, ["DEPENDENCY"])
        let undeclared = try await stack.preview(AyuEndToEnd.source(id: "e2e_policy", "from android.hardware.camera2 import CameraManager\n" + Self.emptyPlugin))
        XCTAssertEqual(undeclared.plugin.blockers, ["CLASS: android.hardware.camera2.CameraManager"])
        let member = try await stack.preview(AyuEndToEnd.source(id: "e2e_policy", """
        from android.net import Uri
        from base_plugin import BasePlugin


        class MemberPlugin(BasePlugin):
            def on_plugin_load(self):
                Uri.noSuchFactory("synthetic")
        """))
        XCTAssertEqual(member.plugin.blockers, ["MEMBER: android.net.Uri.noSuchFactory"])
    }

    func testBlockedPluginImportsDisabledAndNeverRuns() async throws {
        let stack = try AyuEndToEnd.shared()
        let record = try await stack.install(AyuEndToEnd.source(id: "e2e_blocked", metadata: "__min_version__ = \"99.0\"", """
        from base_plugin import BasePlugin
        import plugin_settings


        class BlockedPlugin(BasePlugin):
            def on_plugin_load(self):
                self.set_setting("ran", True)
        """))
        XCTAssertEqual(record.blockers.count, 1)
        XCTAssertEqual(stack.record("e2e_blocked")?.isEnabled, false)
        do {
            try await stack.service.enable("e2e_blocked")
            XCTFail("A blocked plugin was enabled")
        } catch {}
        XCTAssertEqual(stack.record("e2e_blocked")?.isEnabled, false)
        XCTAssertEqual(stack.stored("e2e_blocked"), [:], "No plugin code ran")
        await stack.remove("e2e_blocked")
    }

    func testMalformedSourcesAreRejectedAtImport() async throws {
        let stack = try AyuEndToEnd.shared()
        let sources = [
            "__id__ = \"e2e_syntax\"\n__name__ = \"Broken\"\nclass (:\n",
            "__name__ = \"No identifier\"\n" + Self.emptyPlugin,
            "__id__ = \"1bad\"\n__name__ = \"Bad identifier\"\n" + Self.emptyPlugin,
            "__id__ = \"e2e_dynamic\"\n__name__ = \"Computed \" + str(1)\n" + Self.emptyPlugin,
        ]
        for source in sources {
            do {
                _ = try await stack.preview(source)
                XCTFail("Accepted: \(source.prefix(60))")
            } catch {}
        }
        XCTAssertTrue(stack.service.plugins.allSatisfy { !$0.id.hasPrefix("e2e_syntax") && !$0.id.hasPrefix("e2e_dynamic") })
    }

    func testLoadUnloadCleanupsAndGenerations() async throws {
        let stack = try AyuEndToEnd.shared()
        let source = AyuEndToEnd.source(id: "e2e_lifecycle", """
        from base_plugin import BasePlugin

        MODULE_NAME = __name__


        class LifecyclePlugin(BasePlugin):
            def on_plugin_load(self):
                self.set_setting("loads", self.get_setting("loads", 0) + 1)
                self.set_setting("identity", [self.id, self.name, self.version, self.author, self.description])
                self.set_setting("module_is_private", MODULE_NAME.startswith("_ayu_plugin_"))
                self.set_setting("state_before", self.get_state("marker", "absent"))
                self.set_state("marker", "present")
                self.set_setting("state_after", self.get_state("marker", "absent"))
                self.register_cleanup(lambda: self.set_setting("cleanup", self.get_setting("loads")))
                self.set_setting("order", [])
                self.register_cleanup(lambda: self.set_setting("order", self.get_setting("order") + ["cleanup"]))

            def on_plugin_unload(self):
                self.set_setting("order", self.get_setting("order") + ["unload"])
                self.set_setting("unloads", self.get_setting("unloads", 0) + 1)
        """)
        let id = try await stack.start(source)
        XCTAssertEqual(stack.stored(id, "loads"), .integer(1))
        XCTAssertEqual(stack.stored(id, "identity"), .array([.string(id), .string("Synthetic e2e_lifecycle"), .string("1.0.0"), .string("AyuPluginBridge tests"), .string("AyuPluginBridge end-to-end fixture")]))
        XCTAssertEqual(stack.stored(id, "module_is_private"), .bool(true))
        XCTAssertEqual(stack.stored(id, "state_before"), .string("absent"))
        XCTAssertEqual(stack.stored(id, "state_after"), .string("present"))
        XCTAssertEqual(stack.stored(id, "cleanup"), .null)
        let transient = try await stack.host(id, "state.get", ["key": .string("marker")])
        XCTAssertEqual(transient, .string("present"))

        try await stack.service.disable(id)
        XCTAssertEqual(stack.stored(id, "unloads"), .integer(1))
        XCTAssertEqual(stack.stored(id, "cleanup"), .integer(1), "Registered cleanups run on unload")
        // Android stops the lifecycle scope, which runs the cleanups, before on_plugin_unload.
        XCTAssertEqual(stack.stored(id, "order"), .array([.string("cleanup"), .string("unload")]))

        try await stack.service.enable(id)
        XCTAssertEqual(stack.stored(id, "loads"), .integer(2), "Settings survive a reload")
        XCTAssertEqual(stack.stored(id, "state_before"), .string("absent"), "Transient state belongs to one generation")
        try await stack.service.disable(id)
        XCTAssertEqual(stack.stored(id, "unloads"), .integer(2))
        XCTAssertEqual(stack.stored(id, "cleanup"), .integer(2))
        await stack.remove(id)
    }

    func testFailedLoadLeavesNoSessionAndCanBeRetried() async throws {
        let stack = try AyuEndToEnd.shared()
        let source = AyuEndToEnd.source(id: "e2e_failing", """
        from base_plugin import BasePlugin
        from client_utils import run_on_queue


        class FailingPlugin(BasePlugin):
            def on_plugin_load(self):
                attempt = self.get_setting("attempts", 0) + 1
                self.set_setting("attempts", attempt)
                run_on_queue(lambda: self.set_setting("late", attempt), delay=50)
                if attempt == 1:
                    raise RuntimeError("synthetic load failure")
        """)
        let record = try await stack.install(source)
        XCTAssertEqual(record.blockers, [])
        do {
            try await stack.service.enable(record.id)
            XCTFail("A raising on_plugin_load enabled the plugin")
        } catch {}
        XCTAssertEqual(stack.record(record.id)?.isEnabled, false)
        XCTAssertNotNil(stack.record(record.id)?.error)
        XCTAssertEqual(stack.stored(record.id, "attempts"), .integer(1))
        do {
            _ = try await stack.host(record.id, "settings.all")
            XCTFail("The failed generation kept its host session")
        } catch { XCTAssertEqual((error as? AyuBridgeFailure)?.code, "UNAUTHORIZED") }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stack.stored(record.id, "late"), .null, "Work scheduled by a failed load never runs")

        try await stack.service.enable(record.id)
        XCTAssertEqual(stack.record(record.id)?.isEnabled, true)
        XCTAssertNil(stack.record(record.id)?.error)
        let late = await stack.waitForStored(record.id, "late")
        XCTAssertEqual(late, .integer(2))
        await stack.remove(record.id)
    }

    func testApplicationEventsReachOnAppEvent() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_events", """
        from base_plugin import AppEvent, BasePlugin


        class EventPlugin(BasePlugin):
            def on_app_event(self, event_type):
                seen = self.get_setting("events", [])
                seen.append([event_type.value, isinstance(event_type, AppEvent), event_type == AppEvent.START])
                self.set_setting("events", seen)
        """))
        stack.service.applicationDidChange(inForeground: true, isActive: true)
        stack.service.applicationDidChange(inForeground: true, isActive: false)
        stack.service.applicationDidChange(inForeground: false, isActive: false)
        let events = await stack.waitForStored(id, "events") { $0.array?.count == 4 }
        XCTAssertEqual(events.array?.map { $0.array?.first }, [.string("START"), .string("RESUME"), .string("PAUSE"), .string("STOP")])
        XCTAssertEqual(events.array?.first, .array([.string("START"), .bool(true), .bool(true)]))
        await stack.remove(id)
    }

    func testUpdateKeepsSettingsAndStaysDisabled() async throws {
        let stack = try AyuEndToEnd.shared()
        func source(_ version: String) -> String {
            AyuEndToEnd.source(id: "e2e_update", version: version, """
            from base_plugin import BasePlugin


            class UpdatePlugin(BasePlugin):
                def on_plugin_load(self):
                    self.set_setting("history", self.get_setting("history", []) + [self.version])
            """)
        }
        let id = try await stack.start(source("1.0.0"))
        do {
            _ = try await stack.install(source("2.0.0"), replacingExisting: true)
            XCTFail("An enabled plugin was replaced")
        } catch {}
        do {
            _ = try await stack.install(source("2.0.0"))
            XCTFail("A duplicate identifier was imported")
        } catch {}
        try await stack.service.disable(id)
        let updated = try await stack.install(source("2.0.0"), replacingExisting: true)
        XCTAssertEqual(updated.version, "2.0.0")
        XCTAssertEqual(stack.record(id)?.version, "2.0.0")
        XCTAssertEqual(stack.record(id)?.isEnabled, false)
        try await stack.service.enable(id)
        XCTAssertEqual(stack.stored(id, "history"), .array([.string("1.0.0"), .string("2.0.0")]))
        await stack.remove(id)
    }
}
