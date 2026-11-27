import CryptoKit
import Foundation
import XCTest
@testable import AyuPluginBridge

/// `.elyx`/`.eaf` packages through `AyuPluginService`, the Objective-C runtime and the Python SDK:
/// stored without execution, preflighted on import, inspected again on enable, removed with
/// their unpacked files. The archives are written here; no corpus package is used.
@MainActor
final class AyuPluginPackageEndToEndTests: XCTestCase {
    nonisolated private static let main = """
    from base_plugin import BasePlugin
    import helper


    class PackagePlugin(BasePlugin):
        def on_plugin_load(self):
            self.set_setting("helper", helper.VALUE)
            self.set_setting("file", __file__)

    """

    private var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    private var store: URL { self.support.appendingPathComponent("AyuPlugins", isDirectory: true) }
    private func unpacked(_ id: String) -> URL { self.support.appendingPathComponent("AyuPluginFiles/plugins/ElyxPlugins/" + id, isDirectory: true) }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A ZIP archive of stored (uncompressed) entries.
    nonisolated private static func archive(_ files: [(name: String, text: String)]) -> Data {
        func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
            }
            return ~crc
        }
        func le16(_ value: Int) -> Data { Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }
        func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }) }
        var body = Data(), directory = Data()
        for (name, text) in files {
            let nameBytes = Data(name.utf8), content = Data(text.utf8)
            // Version 20, no flags, stored, 1980-01-01, then CRC and both sizes.
            let shared = le16(20) + le16(0) + le16(0) + le16(0) + le16(33) + le32(crc32(content)) + le32(UInt32(content.count)) + le32(UInt32(content.count))
                + le16(nameBytes.count) + le16(0)
            let offset = UInt32(body.count)
            body += le32(0x0403_4B50) + shared + nameBytes + content
            directory += le32(0x0201_4B50) + le16(20) + shared + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + nameBytes
        }
        let end = le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(UInt32(directory.count)) + le32(UInt32(body.count)) + le16(0)
        return body + directory + end
    }

    nonisolated private static func package(id: String, version: String = "1.0.0", main: String = main, helper: String = "first") -> Data {
        self.archive([
            ("metainfo.json", "{\"id\": \"\(id)\", \"name\": \"Synthetic \(id)\", \"version\": \"\(version)\", \"author\": \"AyuPluginBridge tests\", \"icon\": \"pack/7\"}"),
            ("main.py", main), ("helper.py", "VALUE = \"\(helper)\"\n"),
        ])
    }

    private func file(_ data: Data, _ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AyuPluginPackageTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func staged() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: self.store.appendingPathComponent("Staging").path)) ?? []
    }

    /// A discarded archive is removed off main.
    private func waitForEmptyStaging() async {
        let deadline = Date().addingTimeInterval(5)
        while !self.staged().isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(self.staged(), [])
    }

    func testPackageIsStoredInspectedLoadedAndRemovedWithItsUnpackedFiles() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = "e2e_package"
        let data = Self.package(id: id)
        let url = try self.file(data, "synthetic.elyx")
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let preview = try await stack.service.previewPlugin(from: url)
        XCTAssertEqual(preview.plugin.id, id)
        XCTAssertEqual(preview.plugin.name, "Synthetic " + id)
        XCTAssertEqual(preview.plugin.version, "1.0.0")
        XCTAssertEqual(preview.plugin.packageExtension, "elyx")
        XCTAssertEqual(preview.plugin.icon, "pack/7")
        XCTAssertEqual(preview.plugin.blockers, [])
        XCTAssertEqual(preview.sourceSHA256, digest)
        XCTAssertNil(stack.record(id), "A preview stores nothing")
        await self.waitForEmptyStaging()

        do {
            try await stack.service.importPlugin(from: url, expectedSHA256: String(repeating: "0", count: 64))
            XCTFail("An archive that changed after the preview")
        } catch { XCTAssertEqual("\(error)", "\(AyuPluginService.Failure.sourceChanged)") }
        try await stack.service.importPlugin(from: url, expectedSHA256: digest)
        self.addTeardownBlock { await stack.remove(id) }
        let archive = self.store.appendingPathComponent(id + ".elyx")
        XCTAssertEqual(try Data(contentsOf: archive), data, "The stored archive is the inspected one")
        XCTAssertTrue(self.exists(self.store.appendingPathComponent(id + ".json")))
        XCTAssertEqual(stack.record(id)?.isEnabled, false)
        XCTAssertFalse(self.exists(self.unpacked(id)), "Importing neither unpacks nor executes")
        XCTAssertEqual(stack.stored(id), [:])
        await self.waitForEmptyStaging()

        try await stack.service.enable(id)
        XCTAssertEqual(stack.record(id)?.isEnabled, true)
        XCTAssertEqual(stack.stored(id, "helper"), .string("first"))
        let moduleFile = try XCTUnwrap(stack.stored(id, "file").string)
        XCTAssertEqual(URL(fileURLWithPath: moduleFile).standardizedFileURL.path, self.unpacked(id).appendingPathComponent("main.py").standardizedFileURL.path)
        XCTAssertTrue(self.exists(self.unpacked(id).appendingPathComponent("helper.py")))

        try await stack.service.disable(id)
        XCTAssertEqual(stack.record(id)?.isEnabled, false)
        XCTAssertTrue(self.exists(self.unpacked(id)), "Disabling keeps the unpacked files")

        // Enabling inspects the stored bytes again: an archive replaced behind the service is what runs or is refused.
        try Self.package(id: id, helper: "second").write(to: archive)
        try await stack.service.enable(id)
        XCTAssertEqual(stack.stored(id, "helper"), .string("second"))
        try await stack.service.disable(id)
        try Self.package(id: "e2e_other_id").write(to: archive)
        do {
            try await stack.service.enable(id)
            XCTFail("A stored archive of another plugin")
        } catch { XCTAssertEqual("\(error)", "\(AyuPluginService.Failure.identity)") }
        XCTAssertEqual(stack.record(id)?.isEnabled, false)

        try await stack.service.delete(id)
        XCTAssertNil(stack.record(id))
        XCTAssertFalse(self.exists(archive))
        XCTAssertFalse(self.exists(self.store.appendingPathComponent(id + ".json")))
        XCTAssertFalse(self.exists(self.unpacked(id)), "Deleting removes the unpacked package")
        XCTAssertEqual(stack.stored(id), [:])
    }

    func testBlockedAndMalformedPackagesAreNotLoaded() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = "e2e_blocked"
        let blocked = Self.package(id: id, main: """
        from base_plugin import BasePlugin
        from synthetic.undeclared import Widget
        import helper


        class PackagePlugin(BasePlugin):
            def on_plugin_load(self):
                self.set_setting("loaded", True)

        """)
        let url = try self.file(blocked, "blocked.eaf")
        let preview = try await stack.service.previewPlugin(from: url)
        XCTAssertEqual(preview.plugin.packageExtension, "eaf")
        XCTAssertFalse(preview.plugin.blockers.isEmpty)
        XCTAssertFalse(preview.batchBlockers.isEmpty)
        try await stack.service.importPlugin(from: url, expectedSHA256: preview.sourceSHA256)
        self.addTeardownBlock { await stack.remove(id) }
        XCTAssertTrue(self.exists(self.store.appendingPathComponent(id + ".eaf")))
        do {
            try await stack.service.enable(id)
            XCTFail("A blocked package")
        } catch { XCTAssertEqual("\(error)", "\(AyuPluginService.Failure.operation("UNSUPPORTED_API"))") }
        XCTAssertEqual(stack.record(id)?.isEnabled, false)
        XCTAssertEqual(stack.stored(id), [:])
        XCTAssertFalse(self.exists(self.unpacked(id)))

        for (name, data) in [("text.elyx", Data("not an archive".utf8)), ("empty.elyx", Data()),
                             ("nameless.elyx", Self.archive([("main.py", Self.main)]))] {
            let malformed = try self.file(data, name)
            do {
                _ = try await stack.service.previewPlugin(from: malformed)
                XCTFail("A malformed package: " + name)
            } catch {}
            do {
                try await stack.service.importPlugin(from: malformed)
                XCTFail("A malformed package: " + name)
            } catch {}
        }
        // An archive is a package only by its extension.
        do {
            _ = try await stack.service.previewPlugin(from: try self.file(Self.package(id: "e2e_zip"), "package.zip"))
            XCTFail("An extension the importer does not accept")
        } catch { XCTAssertEqual("\(error)", "\(AyuPluginService.Failure.source)") }
        await self.waitForEmptyStaging()
    }

    func testUpdateReplacesTheStoredKindAndKeepsThePreviousVersionOnFailure() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = "e2e_swap"
        let source = AyuEndToEnd.source(id: id, """
        from base_plugin import BasePlugin


        class SourcePlugin(BasePlugin):
            def on_plugin_load(self):
                self.set_setting("kind", "source")
        """)
        try await stack.install(source)
        self.addTeardownBlock { await stack.remove(id) }
        let plain = self.store.appendingPathComponent(id + ".plugin"), archive = self.store.appendingPathComponent(id + ".elyx")
        XCTAssertTrue(self.exists(plain))
        XCTAssertNil(stack.record(id)?.packageExtension)

        let package = try self.file(Self.package(id: id, version: "2.0.0"), "swap.elyx")
        do {
            try await stack.service.importPlugin(from: package)
            XCTFail("An installed id without replacement")
        } catch { XCTAssertEqual("\(error)", "\(AyuPluginService.Failure.duplicate)") }
        XCTAssertTrue(self.exists(plain))
        XCTAssertFalse(self.exists(archive))

        try await stack.service.importPlugin(from: package, replacingExisting: true)
        XCTAssertFalse(self.exists(plain), "One plugin has one stored form")
        XCTAssertTrue(self.exists(archive))
        XCTAssertEqual(stack.record(id)?.packageExtension, "elyx")
        XCTAssertEqual(stack.record(id)?.version, "2.0.0")
        try await stack.service.enable(id)
        XCTAssertEqual(stack.stored(id, "helper"), .string("first"))
        try await stack.service.disable(id)

        // And back: a `.plugin` update replaces the archive.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".plugin")
        try Data(source.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await stack.service.importPlugin(from: url, replacingExisting: true)
        XCTAssertTrue(self.exists(plain))
        XCTAssertFalse(self.exists(archive))
        XCTAssertNil(stack.record(id)?.packageExtension)
        try await stack.service.enable(id)
        XCTAssertEqual(stack.stored(id, "kind"), .string("source"))
        await self.waitForEmptyStaging()
    }
}
