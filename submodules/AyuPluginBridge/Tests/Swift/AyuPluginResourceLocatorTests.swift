import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Synthetic filesystem fixtures only; these tests never initialize Python.
final class AyuPluginResourceLocatorTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ path: String, root: URL) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic resource, not executable code".utf8).write(to: target)
    }

    private func sdk(_ root: URL) throws {
        for name in ["ayu_bridge.py", "_ayu_inspection.py", "base_plugin.py"] {
            try self.write("AyuPluginSDK.bundle/Python/" + name, root: root)
        }
    }

    func testDataOnlyBundlesDoNotRequireInfoPlist() throws {
        try self.fixture { root in
            try self.sdk(root)
            try self.write("AyuPythonResources.bundle/python/lib/python3.15/encodings/__init__.py", root: root)
            try self.write("AyuPluginSDK.bundle/Resources/bridge_smoke.plugin", root: root)
            for payload in [AyuPluginResourceLocator.Payload.sdk, .pythonHome, .smoke] {
                XCTAssertEqual(AyuPluginResourceLocator.locate(payload, roots: [root])?.path, root.appendingPathComponent(payload.bundleName).appendingPathComponent(payload.relativePath).path)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("AyuPluginSDK.bundle/Info.plist").path))
        }
    }

    func testCodeOwnerRootCanSupplySDKWhenAppRootCannot() throws {
        try self.fixture { root in
            let framework = root.appendingPathComponent("Frameworks/TelegramUIFramework.framework", isDirectory: true)
            try self.sdk(framework)
            XCTAssertNotNil(AyuPluginResourceLocator.locate(.sdk, roots: [root, framework]))
            XCTAssertNil(AyuPluginResourceLocator.locate(.sdk, roots: [root]))
        }
    }

    func testMissingOrIncompletePayloadIsRejectedAndNotCached() throws {
        try self.fixture { root in
            XCTAssertNil(AyuPluginResourceLocator.locate(.sdk, roots: [root]))
            try self.write("AyuPluginSDK.bundle/Python/ayu_bridge.py", root: root)
            XCTAssertNil(AyuPluginResourceLocator.locate(.sdk, roots: [root]))
            try self.sdk(root)
            XCTAssertNotNil(AyuPluginResourceLocator.locate(.sdk, roots: [root]))
            XCTAssertNil(AyuPluginResourceLocator.locate(.pythonHome, roots: [root]))
        }
    }

    func testAFileCannotStandInForADirectoryOrRequiredSource() throws {
        try self.fixture { root in
            try self.write("AyuPluginSDK.bundle/Python", root: root)
            XCTAssertNil(AyuPluginResourceLocator.locate(.sdk, roots: [root]))
        }
        try self.fixture { root in
            try self.sdk(root)
            let file = root.appendingPathComponent("AyuPluginSDK.bundle/Python/ayu_bridge.py")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            XCTAssertNil(AyuPluginResourceLocator.locate(.sdk, roots: [root]))
        }
    }

    func testSymlinkCannotRedirectSDKOutsideItsBundle() throws {
        try self.fixture { root in
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try self.sdk(outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("AyuPluginSDK.bundle"), withDestinationURL: outside.appendingPathComponent("AyuPluginSDK.bundle"))
            XCTAssertNil(AyuPluginResourceLocator.locate(.sdk, roots: [root]))
        }
    }

    func testNativeFailureDiagnosticsDoNotExposeErrorText() {
        let secret = "must-not-appear-in-diagnostics"
        for (code, starting, expected) in [(1, true, "Не удалось запустить"), (2, true, "не смог загрузить SDK"), (2, false, "Python отклонил"), (3, false, "UTF-8"), (4, false, "Очередь Python")] {
            let error = NSError(domain: "AyuPluginPython", code: code, userInfo: [NSLocalizedDescriptionKey: secret])
            let message = AyuPluginService.runtimeFailure(error, starting: starting).localizedDescription
            XCTAssertTrue(message.contains(expected))
            XCTAssertFalse(message.contains(secret))
        }
        let untrusted = NSError(domain: "untrusted", code: 4, userInfo: [NSLocalizedDescriptionKey: secret])
        XCTAssertTrue(AyuPluginService.runtimeFailure(untrusted, starting: false).localizedDescription.contains("Python отклонил"))
    }
}
