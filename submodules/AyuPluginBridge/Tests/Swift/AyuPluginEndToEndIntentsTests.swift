import Foundation
import UIKit
import XCTest
@testable import AyuPluginBridge

/// Intents through the real interpreter, SDK and host. No window exists here, so the UIKit step
/// of `intents.launch` is a stand-in that records the picker or sheet and lets the test answer.
@MainActor
final class AyuPluginEndToEndIntentsTests: XCTestCase {
    private typealias Pick = (request: AyuPluginPickRequest, answer: @Sendable ([AyuPluginPickedSource]) -> Void)

    private struct Stage {
        let stack: AyuEndToEnd
        let picks = AyuTestBox<[Pick]>([])
        let shares = AyuTestBox<[[AyuPluginShareItem]]>([])
        let opened = AyuTestBox<[URL]>([])
        let sources: URL
    }

    /// A bound account and screen with a link route, and a presentation that shows nothing.
    private func stage() throws -> Stage {
        let stack = try AyuEndToEnd.shared()
        let stage = Stage(stack: stack, sources: FileManager.default.temporaryDirectory.appendingPathComponent("AyuIntentsEndToEnd-" + UUID().uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: stage.sources, withIntermediateDirectories: true)
        let screen = stack.bindApplication()
        let opened = stage.opened, picks = stage.picks, shares = stage.shares
        stack.application.bindScreen(screen: { screen }, presenter: { nil }, openURL: { _, url in opened.update { $0.append(url) } })
        stack.application.intents.presentation = AyuPluginIntentPresentation(canPresent: { _ in true }, pick: { _, request, answer in
            picks.update { $0.append((request, answer)) }
            return {}
        }, share: { _, items, completion in
            shares.update { $0.append(items) }
            completion()
            return {}
        })
        let sources = stage.sources
        self.addTeardownBlock { @MainActor in
            stack.application.intents.presentation = .uiKit
            stack.unbindApplication()
            try? FileManager.default.removeItem(at: sources)
        }
        return stage
    }

    private func file(_ stage: Stage, _ name: String, _ bytes: [UInt8]) throws -> AyuPluginPickedSource {
        let directory = stage.sources.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return .file(url, securityScoped: false)
    }

    private func waitForPick(_ stage: Stage, _ count: Int) async -> Pick? {
        let deadline = Date().addingTimeInterval(10)
        while stage.picks.value.count < count, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return stage.picks.value.count >= count ? stage.picks.value[count - 1] : nil
    }

    private func expect(_ stack: AyuEndToEnd, _ id: String, _ key: String, _ expected: AyuBridgeValue, file: StaticString = #filePath, line: UInt = #line) async {
        let value = await stack.waitForStored(id, key)
        XCTAssertEqual(value, expected, key, file: file, line: line)
    }

    private static let plugin = """
    from android.app import Activity
    from android.content import Intent
    from android.net import Uri
    from android.provider import OpenableColumns
    from androidx.core.content import FileProvider
    from base_plugin import BasePlugin, MethodHook
    from client_utils import get_last_fragment
    from hook_utils import find_class
    from java.io import File
    from java.lang import Integer

    \(AyuEndToEnd.recorder)


    class ResultHook(MethodHook):
        def __init__(self, plugin):
            self.plugin = plugin

        def before_hooked_method(self, param):
            self.plugin.order.append("before")
            self.plugin.on_result(param)
            param.setResult(None)


    class IntentPlugin(Recorder, BasePlugin):
        def on_plugin_load(self):
            self.order = []
            activity = get_last_fragment().getParentActivity()
            self.activity = activity

            def hook():
                method = activity.getClass().getDeclaredMethod("onActivityResult", Integer.TYPE, Integer.TYPE, Intent)
                self.unhook = self.hook_method(method, ResultHook(self))
                others = self.hook_all_methods(find_class("org.telegram.ui.LaunchActivity"), "onActivityResult", after=self.after, priority=90)
                listed = [item.getName() for item in activity.getClass().getDeclaredMethods() if item.getName() == "onActivityResult"]
                return [type(self.unhook).__name__, len(others), method.getName(), method.getDeclaringClass().getName(), listed]
            self.record("hooked", hook)

            def package():
                manager = activity.getPackageManager()
                info = manager.getPackageInfo(activity.getPackageName(), 0)
                try:
                    manager.getPackageInfo("org.example.absent", 0)
                    missing = None
                except Exception as error:
                    missing = type(error).__name__
                launch = manager.getLaunchIntentForPackage(activity.getPackageName())
                return [info.versionName, info.versionCode, missing, manager.getLaunchIntentForPackage("org.example.absent") is None,
                        launch.getComponent().getClassName(), launch.resolveActivity(manager) is None]
            self.record("package", package)

            self.record("view", lambda: [activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://example.org/page?x=1")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))])
            self.record("view_own_package", lambda: [activity.startActivity(Intent(Intent.ACTION_VIEW).setData(Uri.parse("tg://resolve?domain=example")).setPackage(activity.getPackageName()))])
            self.record("view_other_package", lambda: activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://example.org")).setPackage("org.example." + "browser")))
            self.record("view_market", lambda: activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=example"))))
            self.record("launch_component", lambda: activity.startActivity(activity.getPackageManager().getLaunchIntentForPackage(activity.getPackageName())))
            self.record("pick_without_result", lambda: activity.startActivity(Intent(Intent.ACTION_GET_CONTENT).setType("*/*")))

            def share():
                intent = Intent(Intent.ACTION_SEND)
                intent.setType("text/plain")
                intent.putExtra(Intent.EXTRA_TEXT, "shared text")
                activity.startActivity(Intent.createChooser(intent, "Share"))
                return True
            self.record("share_text", share)

            def share_file():
                exported = File(activity.getFilesDir(), "e2e_intents_export.json")
                with open(exported.getPath(), "w") as stream:
                    stream.write("[1, 2]")
                uri = FileProvider.getUriForFile(activity, activity.getPackageName() + ".provider", exported)
                intent = Intent(Intent.ACTION_SEND).setType("application/json").putExtra(Intent.EXTRA_STREAM, uri)
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                activity.startActivity(Intent.createChooser(intent, None))
                resolver = activity.getContentResolver()
                with resolver.openInputStream(uri) as stream:
                    content = bytes(stream.readAllBytes()).decode()
                return [uri.toString(), content, resolver.getType(uri)]
            self.record("share_file", share_file)

            def view_file():
                opened = File(activity.getFilesDir(), "e2e_intents_open.json")
                with open(opened.getPath(), "w") as stream:
                    stream.write("[3]")
                uri = FileProvider.getUriForFile(activity, activity.getPackageName() + ".provider", opened)
                intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/json").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                activity.startActivity(Intent.createChooser(intent, "Open with"))
                return True
            self.record("view_file", view_file)
            self.record("share_outside", lambda: activity.startActivity(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, Uri.parse("file:///etc/hosts"))))
            self.record("started", lambda: self.pick(4242))

        def pick(self, code, multiple=False):
            intent = Intent(Intent.ACTION_GET_CONTENT)
            intent.setType("*/*")
            intent.addCategory(Intent.CATEGORY_OPENABLE)
            if multiple:
                intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, True)
            self.activity.startActivityForResult(Intent.createChooser(intent, "Pick"), code)
            return True

        def after(self, param):
            self.order.append("after")
            self.set_setting("after_%d" % param.args[0], [param.args[1], param.args[2] is None, list(self.order)])
            self.order = []
            if param.args[0] == 4245:
                self.record("next_4246", lambda: self.pick(4246))

        def on_result(self, param):
            request, result, data = param.args

            def read():
                if result != Activity.RESULT_OK:
                    return [result, data is None]
                clip = data.getClipData()
                uris = [data.getData()] if clip is None else [clip.getItemAt(index).getUri() for index in range(clip.getItemCount())]
                resolver = param.thisObject.getContentResolver()
                found = []
                for uri in uris:
                    stream = resolver.openInputStream(uri)
                    content = []
                    while True:
                        value = stream.read()
                        if value < 0:
                            break
                        content.append(value)
                    stream.close()
                    cursor = resolver.query(uri, None, None, None, None)
                    cursor.moveToFirst()
                    name = cursor.getString(cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME))
                    size = cursor.getLong(cursor.getColumnIndex(OpenableColumns.SIZE))
                    cursor.close()
                    found.append([uri.getScheme(), uri.getAuthority(), uri.getLastPathSegment(), content, name, size, resolver.getType(uri)])
                return [result, data.getFlags(), data.getData() is None, found]
            self.record("result_%d" % request, read)
            if request == 4242:
                self.record("next_4243", lambda: self.pick(4243, True))
            elif request == 4243:
                self.record("next_4244", lambda: self.pick(4244))
            elif request == 4244:
                # Without the first hook only the after hook remains.
                self.unhook_method(self.unhook)
                self.record("next_4245", lambda: self.pick(4245))
    """

    func testPickerResultsReachTheHookedActivityResultAndTheContentResolver() async throws {
        let stage = try self.stage()
        let stack = stage.stack
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_intents", Self.plugin))
        var removed = false
        defer { if !removed { Task { @MainActor in await stack.remove(id) } } }

        XCTAssertEqual(stack.stored(id, "hooked"), .array([.string("Unhook"), .integer(1), .string("onActivityResult"), .string("org.telegram.ui.LaunchActivity"),
                                                           .array([.string("onActivityResult")])]))
        // The emulated client: exteraGram 13.2.2, arm64 version code; no other package exists.
        XCTAssertEqual(stack.stored(id, "package"), .array([.string("13.2.2"), .integer(73035), .string("NameNotFoundException"), .bool(true),
                                                            .string("org.telegram.ui.LaunchActivity"), .bool(true)]))
        XCTAssertEqual(stack.stored(id, "started"), .bool(true))

        // Links go to the application's route; everything Android-only is refused by name.
        XCTAssertEqual(stack.stored(id, "view"), .array([.null]))
        XCTAssertEqual(stack.stored(id, "view_own_package"), .array([.null]))
        let deadline = Date().addingTimeInterval(5)
        while stage.opened.value.count < 2, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(stage.opened.value.map(\.absoluteString), ["https://example.org/page?x=1", "tg://resolve?domain=example"])
        for (key, expected) in [("view_other_package", "Intent android.intent.action.VIEW for the Android package org.example.browser"),
                                ("view_market", "Intent android.intent.action.VIEW of a market: URI"),
                                ("launch_component", "Intent android.intent.action.MAIN for the Android component"),
                                ("pick_without_result", "Intent android.intent.action.GET_CONTENT needs startActivityForResult"),
                                ("share_outside", "EXTRA_STREAM names a file outside the plugin storage")] {
            let value = stack.stored(id, key).string ?? ""
            XCTAssertTrue(value.hasPrefix("!UnsupportedAPI: UNSUPPORTED_API: ") && value.contains(expected), "\(key): \(value)")
        }

        // The share sheet got the text, then the exported file of the plugin storage.
        XCTAssertEqual(stack.stored(id, "share_text"), .bool(true))
        XCTAssertEqual(stack.stored(id, "share_file"), .array([.string("content://com.exteragram.messenger.provider/files/e2e_intents_export.json"),
                                                               .string("[1, 2]"), .string("application/json")]))
        while stage.shares.value.count < 3, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(stage.shares.value.first, [.text("shared text")])
        guard stage.shares.value.count == 3, case let .file(shared)? = stage.shares.value[1].first,
              case let .file(viewed)? = stage.shares.value[2].first else { return XCTFail("Expected two shared files: \(stage.shares.value)") }
        XCTAssertEqual(try String(contentsOf: shared, encoding: .utf8), "[1, 2]")
        try? FileManager.default.removeItem(at: shared)
        // ACTION_VIEW of a file of the plugin storage asks for the same sheet, where the user picks what opens it.
        XCTAssertEqual(stack.stored(id, "view_file"), .bool(true))
        XCTAssertEqual(try String(contentsOf: viewed, encoding: .utf8), "[3]")
        try? FileManager.default.removeItem(at: viewed)

        // One document: startActivityForResult -> picker -> copy -> hooked onActivityResult -> openInputStream.
        let firstPick = await self.waitForPick(stage, 1)
        let first = try XCTUnwrap(firstPick)
        XCTAssertEqual(first.request, AyuPluginPickRequest(types: ["*/*"], multiple: false, limit: 1))
        first.answer([try self.file(stage, "note one.txt", [0, 255, 10, 65])])
        await self.expect(stack, id, "result_4242", .array([.integer(-1), .integer(1), .bool(false), .array([
            .array([.string("content"), .string("com.exteragram.messenger.bridge.documents"), .string("note one.txt"),
                    .array([.integer(0), .integer(255), .integer(10), .integer(65)]), .string("note one.txt"), .integer(4), .string("text/plain")])])]))
        // The before hook set a result, so the after hook of higher priority still runs, last.
        await self.expect(stack, id, "after_4242", .array([.integer(-1), .bool(false), .array([.string("before"), .string("after")])]))
        let copies = stack.application.intents.root.appendingPathComponent(id, isDirectory: true)
        XCTAssertTrue(stack.application.intents.heldDocuments(pluginID: id) == (4, 1))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: copies.path))?.count, 1)

        // Several documents arrive as ClipData.
        await self.expect(stack, id, "next_4243", .bool(true))
        let secondPick = await self.waitForPick(stage, 2)
        let second = try XCTUnwrap(secondPick)
        XCTAssertEqual(second.request, AyuPluginPickRequest(types: ["*/*"], multiple: true, limit: 32))
        second.answer([try self.file(stage, "a.json", Array("{}".utf8)), try self.file(stage, "b", [7])])
        await self.expect(stack, id, "result_4243", .array([.integer(-1), .integer(1), .bool(true), .array([
            .array([.string("content"), .string("com.exteragram.messenger.bridge.documents"), .string("a.json"),
                    .array([.integer(123), .integer(125)]), .string("a.json"), .integer(2), .string("application/json")]),
            .array([.string("content"), .string("com.exteragram.messenger.bridge.documents"), .string("b"),
                    .array([.integer(7)]), .string("b"), .integer(1), .string("application/octet-stream")])])]))
        XCTAssertTrue(stack.application.intents.heldDocuments(pluginID: id) == (7, 3))

        // Cancelled: RESULT_CANCELED and no data.
        await self.expect(stack, id, "next_4244", .bool(true))
        let thirdPick = await self.waitForPick(stage, 3)
        try XCTUnwrap(thirdPick).answer([])
        await self.expect(stack, id, "result_4244", .array([.integer(0), .bool(true)]))

        // The first hook was removed: only the after hook sees the next result. A locked or
        // backgrounded application closes the picker, which is a cancelled result too.
        await self.expect(stack, id, "next_4245", .bool(true))
        let fourthPick = await self.waitForPick(stage, 4)
        XCTAssertNotNil(fourthPick)
        stack.application.invalidatePresentations()
        await self.expect(stack, id, "after_4245", .array([.integer(0), .bool(true), .array([.string("after")])]))
        XCTAssertEqual(stack.stored(id, "result_4245"), .null)

        // Unload while a picker is open: its late answer goes nowhere and every copy is removed.
        await self.expect(stack, id, "next_4246", .bool(true))
        let lastPick = await self.waitForPick(stage, 5)
        let last = try XCTUnwrap(lastPick)
        await stack.remove(id)
        removed = true
        last.answer([try self.file(stage, "late.txt", [1])])
        await withCheckedContinuation { continuation in stack.application.intents.afterFileWork { continuation.resume() } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copies.path))
        XCTAssertTrue(stack.application.intents.heldDocuments(pluginID: id) == (0, 0))
    }

    func testAndroidOnlyIntentsAndUnmappedHooksAreBlockedBeforeTheyRun() async throws {
        let stage = try self.stage()
        let preview = try await stage.stack.preview(AyuEndToEnd.source(id: "e2e_intents_blocked", """
        from android.content import Intent
        from base_plugin import BasePlugin
        from client_utils import get_last_fragment
        from hook_utils import find_class
        from java.lang import Integer
        from org.telegram.messenger import ApplicationLoader


        class BlockedPlugin(BasePlugin):
            def on_plugin_load(self):
                activity = get_last_fragment().getParentActivity()
                method = activity.getClass().getDeclaredMethod("onActivityResult", Integer.TYPE, Integer.TYPE, Intent)
                self.hook_method(method, after=self.done)
                self.hook_all_methods(find_class("org.telegram.ui.LaunchActivity"), "onResume", after=self.done)
                intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
                intent.setType("application/json")
                activity.startActivityForResult(intent, 7)
                # Preflight resolves this receiver; the result class of get_last_fragment() is unknown to it.
                ApplicationLoader.applicationContext.getContentResolver().delete(None, None, None)

            def done(self, param):
                pass
        """))
        // The mapped target is served; the unmapped one, the Android-only action and the provider write are named.
        XCTAssertEqual(Set(preview.plugin.blockers), ["OPERATION: hooks.java_method (hook_all_methods())",
                                                      "OPERATION: intents.android_only (Intent android.intent.action.CREATE_DOCUMENT)",
                                                      "MEMBER: android.content.ContentResolver.delete"])
    }
}
