import Foundation
import UIKit
import XCTest
@testable import AyuPluginBridge

/// `intents.launch` without Python and without a window: the presentation is a stand-in that
/// records what would be shown and lets the test answer for the user.
@MainActor
final class AyuPluginIntentsTests: XCTestCase {
    private final class Stage: @unchecked Sendable {
        let screen = AyuTestBox<AyuPluginScreenSnapshot?>(AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0))
        let picks = AyuTestBox<[(AyuPluginPickRequest, @Sendable ([AyuPluginPickedSource]) -> Void)]>([])
        let shares = AyuTestBox<[([AyuPluginShareItem], @Sendable () -> Void)]>([])
        let dismissed = AyuTestBox(0)
        let opened = AyuTestBox<[URL]>([])
        let notices = AyuTestBox<[String]>([])
        let results = AyuTestBox<[AyuBridgeValue]>([])
        let released = AyuTestBox(0)
        let canPresent = AyuTestBox(true)
        let hasRoute = AyuTestBox(true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AyuPluginIntentsTests-" + UUID().uuidString, isDirectory: true)

        var presentation: AyuPluginIntentPresentation {
            AyuPluginIntentPresentation(canPresent: { _ in self.canPresent.value }, pick: { _, request, completion in
                self.picks.update { $0.append((request, completion)) }
                return { self.dismissed.update { $0 += 1 } }
            }, share: { _, items, completion in
                self.shares.update { $0.append((items, completion)) }
                return { self.dismissed.update { $0 += 1 } }
            })
        }

        var environment: AyuPluginIntentBridge.Environment {
            AyuPluginIntentBridge.Environment(screen: { state in
                guard let screen = self.screen.value, state["screenIdentity"]?.string == screen.identity.uuidString else {
                    throw AyuBridgeFailure("screen_unavailable", "Screen context expired or is not visible")
                }
                return screen
            }, visible: { (self.screen.value, nil) }, hasURLRoute: { self.hasRoute.value },
               openURL: { _, url in self.opened.update { $0.append(url) } }, notify: { text in self.notices.update { $0.append(text) } })
        }

        func context(_ owner: String, className: String = "android.content.Context") -> AyuBridgeAdapterContext {
            let state: [String: AyuBridgeValue] = ["screenIdentity": .string(self.screen.value?.identity.uuidString ?? UUID().uuidString), "accountIndex": .integer(0)]
            return AyuBridgeAdapterContext(pluginID: owner, resolveCallback: { reference in
                guard reference["$callback"].string != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected a declared callback reference") }
                return AyuBridgeNativeCallback(id: "callback", sink: { arguments in self.results.update { $0.append(contentsOf: arguments) } },
                                               guaranteed: { arguments, _ in self.results.update { $0.append(contentsOf: arguments) } },
                                               release: { self.released.update { $0 += 1 } })
            }, resolve: { _ in AyuBridgeAdapterSnapshot(className: className, state: state) })
        }

        func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
            let directory = self.root.appendingPathComponent("sources-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            return url
        }
    }

    private static let reference: AyuBridgeValue = .object(["$handle": .string("context"), "$class": .string("android.content.Context")])
    private static let callback: AyuBridgeValue = .object(["$callback": .string("callback")])

    private func make(_ limits: AyuPluginIntentBridge.Limits = .init()) -> (AyuPluginIntentBridge, Stage) {
        let stage = Stage()
        let bridge = AyuPluginIntentBridge(limits: limits, root: stage.root.appendingPathComponent("picked", isDirectory: true))
        bridge.presentation = stage.presentation
        self.addTeardownBlock { try? FileManager.default.removeItem(at: stage.root) }
        return (bridge, stage)
    }

    private static func pick(types: [AyuBridgeValue] = [.string("*/*")], multiple: Bool = false) -> [String: AyuBridgeValue] {
        ["kind": .string("pick"), "context": self.reference, "types": .array(types), "multiple": .bool(multiple), "callback": self.callback]
    }

    /// Prepares on a background thread, as the host worker does, and commits a success.
    @discardableResult
    private func launch(_ bridge: AyuPluginIntentBridge, _ stage: Stage, _ arguments: [String: AyuBridgeValue], owner: String = "alpha",
                        className: String = "android.content.Context", commit: Bool = true) async throws -> String {
        let context = stage.context(owner, className: className), environment = stage.environment
        let prepared = try await Task.detached { try bridge.prepareLaunch(arguments, context: context, environment: environment) }.value
        guard case let .value(.string(token)) = prepared.result else { XCTFail("intents.launch must return a token"); return "" }
        if commit { prepared.commit(.string(token)) } else { prepared.rollback() }
        return token
    }

    private func failure(_ bridge: AyuPluginIntentBridge, _ stage: Stage, _ arguments: [String: AyuBridgeValue], owner: String = "alpha",
                         className: String = "android.content.Context") async -> String {
        do { try await self.launch(bridge, stage, arguments, owner: owner, className: className); return "" }
        catch { return (error as? AyuBridgeFailure)?.code ?? "?" }
    }

    private func wait(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Every file operation queued so far has run.
    private func settle(_ bridge: AyuPluginIntentBridge) async {
        await withCheckedContinuation { continuation in bridge.afterFileWork { continuation.resume() } }
    }

    func testPickCopiesTheDocumentsAndDeliversOneResult() async throws {
        let (bridge, stage) = self.make()
        let token = try await self.launch(bridge, stage, Self.pick(types: [.string("audio/*"), .string("application/zip")], multiple: true))
        XCTAssertNotNil(UUID(uuidString: token))
        await self.wait { !stage.picks.value.isEmpty }
        XCTAssertEqual(stage.picks.value.first?.0, AyuPluginPickRequest(types: ["audio/*", "application/zip"], multiple: true, limit: 32))
        XCTAssertEqual(stage.results.value, [])
        let first = try stage.file("song one.mp3", [1, 2, 3]), second = try stage.file("notes", Array("second".utf8))
        stage.picks.value[0].1([.file(first, securityScoped: false), AyuPluginPickedSource.file(second, securityScoped: false)])
        await self.wait { !stage.results.value.isEmpty }
        let result = try XCTUnwrap(stage.results.value.first)
        XCTAssertEqual(stage.results.value.count, 1)
        XCTAssertEqual(stage.released.value, 1)
        XCTAssertEqual(result["token"], .string(token))
        XCTAssertEqual(result["result_code"], .integer(-1))
        XCTAssertNil(result.object?["error"])
        let documents = try XCTUnwrap(result["documents"].array)
        XCTAssertEqual(documents.map { $0["name"] }, [.string("song one.mp3"), .string("notes")])
        XCTAssertEqual(documents.map { $0["size"] }, [.integer(3), .integer(6)])
        XCTAssertEqual(documents.map { $0["mime_type"] }, [.string("audio/mpeg"), .string("application/octet-stream")])
        XCTAssertEqual(documents.map { Set($0.object?.keys.map { $0 } ?? []) }, Array(repeating: ["path", "name", "size", "mime_type"], count: 2))
        let paths = documents.compactMap { $0["path"].string }
        XCTAssertEqual(paths, [bridge.root.appendingPathComponent("alpha/\(token)/0/song one.mp3").path, bridge.root.appendingPathComponent("alpha/\(token)/1/notes").path])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths[0])), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths[1])), Data("second".utf8))
        XCTAssertTrue(bridge.heldDocuments(pluginID: "alpha") == (9, 2))
        // The picker is closed: another one may open, and the first callback is not used again.
        try await self.launch(bridge, stage, Self.pick())
        await self.wait { stage.picks.value.count == 2 }
        stage.picks.value[0].1([.file(first, securityScoped: false)])
        stage.picks.value[1].1([])
        await self.wait { stage.results.value.count == 2 }
        await self.settle(bridge)
        XCTAssertEqual(stage.results.value.count, 2)
        XCTAssertEqual(stage.results.value[1]["result_code"], .integer(0))
        XCTAssertEqual(stage.results.value[1]["documents"], .array([]))
        XCTAssertNil(stage.results.value[1].object?["error"])
        XCTAssertEqual(stage.notices.value, [])
        // Unload removes every copy the plugin held.
        bridge.detach(pluginID: "alpha")
        await self.settle(bridge)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.root.appendingPathComponent("alpha").path))
        XCTAssertTrue(bridge.heldDocuments(pluginID: "alpha") == (0, 0))
    }

    func testOversizedDocumentsAndQuotasCancelThePickWithoutLeftovers() async throws {
        var limits = AyuPluginIntentBridge.Limits()
        limits.documentBytes = 8; limits.heldBytesPerPlugin = 12; limits.heldDocumentsPerPlugin = 3
        let (bridge, stage) = self.make(limits)
        func pick(_ files: [URL], multiple: Bool = true) async throws -> AyuBridgeValue {
            let count = stage.results.value.count, picks = stage.picks.value.count
            try await self.launch(bridge, stage, Self.pick(multiple: multiple))
            await self.wait { stage.picks.value.count == picks + 1 }
            stage.picks.value[picks].1(files.map { .file($0, securityScoped: false) })
            await self.wait { stage.results.value.count == count + 1 }
            return stage.results.value[count]
        }
        let small = try stage.file("small.bin", Array(repeating: 7, count: 8)), large = try stage.file("large.bin", Array(repeating: 7, count: 9))
        // One byte over the document bound: nothing is kept, the second file included.
        var result = try await pick([small, large])
        XCTAssertEqual(result["result_code"], .integer(0))
        XCTAssertEqual(result["error"], .string("RESOURCE_LIMIT"))
        XCTAssertEqual(result["documents"], .array([]))
        await self.settle(bridge)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: bridge.root.appendingPathComponent("alpha").path)) ?? [], [])
        XCTAssertTrue(bridge.heldDocuments(pluginID: "alpha") == (0, 0))
        await self.wait { stage.notices.value.count == 1 }
        // 8 of 12 bytes are held; the next 8 exceed what the plugin may hold.
        result = try await pick([small])
        XCTAssertEqual(result["result_code"], .integer(-1))
        result = try await pick([small])
        XCTAssertEqual(result["error"], .string("RESOURCE_LIMIT"))
        XCTAssertTrue(bridge.heldDocuments(pluginID: "alpha") == (8, 1))
        // More documents than the pick allows, and more than the plugin may hold.
        let tiny = try stage.file("tiny", [1])
        result = try await pick([tiny, tiny], multiple: false)
        XCTAssertEqual(result["error"], .string("RESOURCE_LIMIT"))
        result = try await pick([tiny, tiny, tiny])
        XCTAssertEqual(result["error"], .string("RESOURCE_LIMIT"))
        result = try await pick([tiny, tiny])
        XCTAssertEqual(result["result_code"], .integer(-1))
        XCTAssertTrue(bridge.heldDocuments(pluginID: "alpha") == (10, 3))
        result = try await pick([tiny])
        XCTAssertEqual(result["error"], .string("RESOURCE_LIMIT"))
        // Unload returns the quota. A directory is not a document.
        bridge.detach(pluginID: "alpha")
        result = try await pick([stage.root])
        XCTAssertEqual(result["error"], .string("IO_ERROR"))
        XCTAssertEqual(stage.released.value, stage.results.value.count)
    }

    func testInvalidationUnloadAndStaleScreens() async throws {
        let (bridge, stage) = self.make()
        // Lock or background: the picker is closed and the plugin gets a cancelled result once.
        try await self.launch(bridge, stage, Self.pick())
        await self.wait { stage.picks.value.count == 1 }
        bridge.invalidate()
        XCTAssertEqual(stage.dismissed.value, 1)
        XCTAssertEqual(stage.results.value.map { $0["error"] }, [.string("SCREEN_UNAVAILABLE")])
        XCTAssertEqual(stage.results.value[0]["result_code"], .integer(0))
        stage.picks.value[0].1([.file(try stage.file("late", [1]), securityScoped: false)])
        await self.settle(bridge)
        XCTAssertEqual(stage.results.value.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.root.path))
        // Unload while the picker is open: closed, and nothing is delivered to the dead generation.
        try await self.launch(bridge, stage, Self.pick())
        await self.wait { stage.picks.value.count == 2 }
        bridge.detach(pluginID: "alpha")
        await self.wait { stage.dismissed.value == 2 }
        stage.picks.value[1].1([.file(try stage.file("late", [1]), securityScoped: false)])
        await self.settle(bridge)
        XCTAssertEqual(stage.results.value.count, 1)
        // Unload while a document is being copied: the copy is dropped.
        try await self.launch(bridge, stage, Self.pick())
        await self.wait { stage.picks.value.count == 3 }
        let copying = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        stage.picks.value[2].1([AyuPluginPickedSource(name: "slow.bin", mimeType: nil) { destination, _ in
            copying.signal(); proceed.wait()
            try Data([1, 2]).write(to: destination)
            return 2
        }])
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { copying.wait(); continuation.resume() }
        }
        bridge.detach(pluginID: "alpha")
        proceed.signal()
        await self.settle(bridge)
        XCTAssertEqual(stage.results.value.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.root.appendingPathComponent("alpha").path))
        XCTAssertTrue(bridge.heldDocuments(pluginID: "alpha") == (0, 0))
        // The screen changed between the call and main: nothing is shown, the picker reports nothing.
        let context = stage.context("alpha"), environment = stage.environment, arguments = Self.pick()
        let prepared = try await Task.detached { try bridge.prepareLaunch(arguments, context: context, environment: environment) }.value
        stage.screen.value = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        prepared.commit(.null)
        await self.wait { stage.results.value.count == 2 }
        XCTAssertEqual(stage.results.value[1]["error"], .string("SCREEN_UNAVAILABLE"))
        XCTAssertEqual(stage.picks.value.count, 3)
        // A context of a screen that is no longer visible is refused at the call.
        stage.screen.value = nil
        let code = await self.failure(bridge, stage, Self.pick())
        XCTAssertEqual(code, "SCREEN_UNAVAILABLE")
    }

    func testArgumentsAreClosedAndBounded() async throws {
        let (bridge, stage) = self.make()
        var arguments = Self.pick()
        arguments["title"] = .string("Pick")
        var codes: [String] = []
        codes.append(await self.failure(bridge, stage, arguments))
        codes.append(await self.failure(bridge, stage, Self.pick(types: [])))
        codes.append(await self.failure(bridge, stage, Self.pick(types: [.string("Image/*")])))
        codes.append(await self.failure(bridge, stage, Self.pick(types: [.string("image")])))
        codes.append(await self.failure(bridge, stage, Self.pick(types: [.string("a/b"), .string("a/b")])))
        codes.append(await self.failure(bridge, stage, Self.pick(types: (0..<17).map { .string("a/b\($0)") })))
        arguments = Self.pick(); arguments["callback"] = .string("callback")
        codes.append(await self.failure(bridge, stage, arguments))
        arguments = Self.pick(); arguments["multiple"] = .integer(1)
        codes.append(await self.failure(bridge, stage, arguments))
        codes.append(await self.failure(bridge, stage, ["kind": .string("pick")]))
        codes.append(await self.failure(bridge, stage, Self.pick(), className: "android.net.Uri"))
        codes.append(await self.failure(bridge, stage, Self.pick(), owner: "../escape"))
        XCTAssertEqual(codes, Array(repeating: "INVALID_ARGUMENTS", count: 11))
        let unsupported = await self.failure(bridge, stage, ["kind": .string("install"), "context": Self.reference])
        XCTAssertEqual(unsupported, "UNSUPPORTED_API")
        XCTAssertEqual(stage.picks.value.count, 0)
        // A fragment is a context too. One picker or sheet at a time; a rolled back call frees the slot.
        try await self.launch(bridge, stage, Self.pick(), className: "org.telegram.ui.ActionBar.BaseFragment", commit: false)
        try await self.launch(bridge, stage, Self.pick(), className: "org.telegram.ui.ActionBar.BaseFragment")
        var code = await self.failure(bridge, stage, Self.pick(), owner: "beta")
        XCTAssertEqual(code, "RESOURCE_LIMIT")
        code = await self.failure(bridge, stage, ["kind": .string("share"), "context": Self.reference, "text": .string("hello")])
        XCTAssertEqual(code, "RESOURCE_LIMIT")
        await self.wait { stage.picks.value.count == 1 }
        stage.picks.value[0].1([])
        await self.wait { stage.results.value.count == 1 }
        // Nothing can be shown without a visible presenter.
        stage.canPresent.value = false
        code = await self.failure(bridge, stage, Self.pick())
        XCTAssertEqual(code, "SCREEN_UNAVAILABLE")
    }

    func testSharingTextAndFilesOfThePluginStorage() async throws {
        let (bridge, stage) = self.make()
        func share(_ fields: [String: AyuBridgeValue]) -> [String: AyuBridgeValue] {
            fields.merging(["kind": .string("share"), "context": Self.reference]) { first, _ in first }
        }
        try await self.launch(bridge, stage, share(["text": .string("hello")]))
        await self.wait { stage.shares.value.count == 1 }
        XCTAssertEqual(stage.shares.value[0].0, [.text("hello")])
        // The sheet is still open.
        var code = await self.failure(bridge, stage, share(["text": .string("again")]))
        XCTAssertEqual(code, "RESOURCE_LIMIT")
        stage.shares.value[0].1()
        var codes: [String] = []
        codes.append(await self.failure(bridge, stage, share([:])))
        codes.append(await self.failure(bridge, stage, share(["text": .string("")])))
        codes.append(await self.failure(bridge, stage, share(["text": .string(String(repeating: "a", count: 65_537))])))
        codes.append(await self.failure(bridge, stage, share(["files": .array([])])))
        codes.append(await self.failure(bridge, stage, share(["files": .array([.string("relative/path")])])))
        codes.append(await self.failure(bridge, stage, share(["files": .array([.string("/nonexistent/ayu/file")])])))
        codes.append(await self.failure(bridge, stage, share(["text": .string("a"), "subject": .string("b")])))
        XCTAssertEqual(codes, Array(repeating: "INVALID_ARGUMENTS", count: 7))
        // A file outside the plugin storage is not handed to another application.
        let outside = try stage.file("outside.txt", [1])
        code = await self.failure(bridge, stage, share(["files": .array([.string(outside.path)])]))
        XCTAssertEqual(code, "UNSUPPORTED_API")
        let storage = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AyuPluginFiles/intents-tests-" + UUID().uuidString, isDirectory: true)
        guard let home = ProcessInfo.processInfo.environment["AYU_PLUGIN_TEST_HOME"],
              storage.standardizedFileURL.path.hasPrefix(URL(fileURLWithPath: home).standardizedFileURL.path + "/") else {
            throw XCTSkip("Plugin storage is outside the test home")
        }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let inside = storage.appendingPathComponent("export.json")
        try Data("{}".utf8).write(to: inside)
        try FileManager.default.createSymbolicLink(at: storage.appendingPathComponent("link"), withDestinationURL: outside)
        code = await self.failure(bridge, stage, share(["files": .array([.string(storage.appendingPathComponent("link").path)])]))
        XCTAssertEqual(code, "UNSUPPORTED_API")
        code = await self.failure(bridge, stage, share(["files": .array([.string(storage.path)])]))
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        try await self.launch(bridge, stage, share(["text": .string("note"), "files": .array([.string(inside.path)])]))
        await self.wait { stage.shares.value.count == 2 }
        guard case let .file(url)? = stage.shares.value[1].0.last else { return XCTFail("Expected a shared file") }
        XCTAssertEqual(stage.shares.value[1].0.first, .text("note"))
        XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8))
        bridge.invalidate()
        XCTAssertEqual(stage.dismissed.value, 1)
        XCTAssertEqual(stage.results.value, [])
    }

    func testLinksUseTheApplicationRoute() async throws {
        let (bridge, stage) = self.make()
        func view(_ url: String) -> [String: AyuBridgeValue] { ["kind": .string("view"), "context": Self.reference, "url": .string(url)] }
        try await self.launch(bridge, stage, view("https://example.org/a?b=c"))
        try await self.launch(bridge, stage, view("tg://resolve?domain=example"))
        await self.wait { stage.opened.value.count == 2 }
        XCTAssertEqual(stage.opened.value.map(\.absoluteString), ["https://example.org/a?b=c", "tg://resolve?domain=example"])
        // A link needs no presenter, but it needs the screen the plugin called from.
        stage.canPresent.value = false
        try await self.launch(bridge, stage, view("http://example.org"))
        await self.wait { stage.opened.value.count == 3 }
        var codes: [String] = []
        for url in ["", " https://example.org", "https://", "https://user:secret@example.org", "/relative", String(repeating: "a", count: 8_193)] {
            codes.append(await self.failure(bridge, stage, view(url)))
        }
        XCTAssertEqual(codes, Array(repeating: "INVALID_ARGUMENTS", count: 6))
        for url in ["file:///etc/hosts", "market://details?id=a", "javascript:alert(1)", "content://a/b"] {
            let code = await self.failure(bridge, stage, view(url))
            XCTAssertEqual(code, "UNSUPPORTED_API", url)
        }
        var arguments = view("https://example.org"); arguments["callback"] = Self.callback
        var code = await self.failure(bridge, stage, arguments)
        XCTAssertEqual(code, "INVALID_ARGUMENTS")
        stage.hasRoute.value = false
        code = await self.failure(bridge, stage, view("https://example.org"))
        XCTAssertEqual(code, "SCREEN_UNAVAILABLE")
        XCTAssertEqual(stage.opened.value.count, 3)
    }

    func testNamesTypesAndBoundedCopy() throws {
        XCTAssertEqual(AyuPluginIntentBridge.fileName("/a/b/report.pdf"), "report.pdf")
        XCTAssertEqual(AyuPluginIntentBridge.fileName(".."), "document")
        XCTAssertEqual(AyuPluginIntentBridge.fileName(""), "document")
        XCTAssertEqual(AyuPluginIntentBridge.fileName("a\u{0}b\nc"), "abc")
        XCTAssertEqual(AyuPluginIntentBridge.fileName(String(repeating: "я", count: 200)).utf8.count, 254)
        for type in ["*/*", "image/*", "application/vnd.ms-excel", "text/x-c++"] { XCTAssertTrue(AyuPluginIntentBridge.isMIMEType(type), type) }
        for type in ["", "*", "*/png", "image", "image/", "Image/png", "a/b/c", "a b/c", String(repeating: "a", count: 64) + "/b"] {
            XCTAssertFalse(AyuPluginIntentBridge.isMIMEType(type), type)
        }
        let stage = Stage()
        defer { try? FileManager.default.removeItem(at: stage.root) }
        let source = try stage.file("source", Array(repeating: 5, count: 100_000))
        let destination = stage.root.appendingPathComponent("copy")
        XCTAssertEqual(try AyuPluginIntentBridge.boundedCopy(from: source, to: destination, maximumBytes: 100_000), 100_000)
        XCTAssertEqual(try Data(contentsOf: destination).count, 100_000)
        let second = stage.root.appendingPathComponent("second")
        XCTAssertThrowsError(try AyuPluginIntentBridge.boundedCopy(from: source, to: second, maximumBytes: 99_999)) {
            XCTAssertEqual(($0 as? AyuBridgeFailure)?.code, "RESOURCE_LIMIT")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertThrowsError(try AyuPluginIntentBridge.boundedCopy(from: stage.root, to: second, maximumBytes: 10))
    }
}
