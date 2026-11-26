import Foundation
import XCTest
@testable import AyuPluginBridge

final class AyuPluginBatchTests: XCTestCase {
    private func fixture(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AyuPluginBatchTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func context(_ hashCharacter: Character = "a", blocker: AyuPluginBatchBlocker? = nil) -> AyuPluginBatchLoadContext {
        let hash = String(repeating: String(hashCharacter), count: 64)
        return AyuPluginBatchLoadContext(sourceSHA256: hash, pluginVersion: "1.0.0", blockers: blocker.map { [$0] } ?? [])
    }

    private func reportLines(at url: URL, root: URL) throws -> [[String: Any]] {
        let data = try AyuPluginBatchJournal.readReport(at: url, within: root)
        return try data.split(separator: 0x0a).map {
            let object = try JSONSerialization.jsonObject(with: Data($0))
            return try XCTUnwrap(object as? [String: Any])
        }
    }

    @MainActor
    func testRunnerPreservesOrderIsolatesFailureAndLogsOnlyLaterDuplicate() async throws {
        try await self.fixture { root in
            let journal = AyuPluginBatchJournal(root: root, sourceRoot: root, batchID: "order")
            var called: [String] = []
            var progress: [(Int, Int)] = []
            let summary = try await AyuPluginBatchRunner.run(
                ids: ["plugin1", "plugin2", "plugin1", "plugin3"], journal: journal,
                isEnabled: { _ in false }, isCancelled: { false }, pluginName: { $0 },
                diagnostic: { _ in .runtime }, progress: { progress.append(($0, $1)) },
                enable: { id, report in
                    called.append(id)
                    await report(.readSource, self.context(id == "plugin2" ? "b" : "a"))
                    if id == "plugin2" { throw AyuPluginService.Failure.runtime }
                    return AyuPluginBatchLoadResult(generation: String(repeating: "0", count: 32), context: self.context())
                })

            XCTAssertEqual(called, ["plugin1", "plugin2", "plugin3"])
            XCTAssertEqual(summary.requested, 4)
            XCTAssertEqual(summary.succeeded, 2)
            XCTAssertEqual(summary.failed, 1)
            XCTAssertEqual(summary.skipped, 1)
            XCTAssertEqual(progress.last?.0, 4)

            let lines = try self.reportLines(at: journal.url, root: root)
            XCTAssertEqual(lines.filter { $0["result"] as? String == "duplicate_skipped" }.count, 1)
            XCTAssertEqual(lines.filter { $0["result"] as? String == "failed" }.count, 1)
            let failed = try XCTUnwrap(lines.first { $0["result"] as? String == "failed" })
            XCTAssertEqual(failed["pluginID"] as? String, "plugin2")
            XCTAssertEqual(failed["sourceSHA256"] as? String, String(repeating: "b", count: 64))
        }
    }

    @MainActor
    func testRunnerCancellationDoesNotStartRemainingPlugins() async throws {
        try await self.fixture { root in
            let journal = AyuPluginBatchJournal(root: root, sourceRoot: root, batchID: "cancel")
            var called: [String] = []
            var cancelled = false
            let summary = try await AyuPluginBatchRunner.run(
                ids: ["plugin1", "plugin2", "plugin3"], journal: journal,
                isEnabled: { _ in false }, isCancelled: { cancelled }, pluginName: { $0 },
                diagnostic: { _ in .runtime }, progress: { _, _ in },
                enable: { id, _ in
                    called.append(id)
                    cancelled = true
                    return AyuPluginBatchLoadResult(generation: nil, context: self.context())
                })
            XCTAssertEqual(called, ["plugin1"])
            XCTAssertEqual(summary.succeeded, 1)
            XCTAssertEqual(summary.cancelled, 2)
        }
    }

    func testBlockerGrammarAndJournalRedaction() async throws {
        XCTAssertNotNil(AyuPluginBatchBlocker.sanitized(code: "SDK_MEMBER", identifier: "android.view.View.setAlpha"))
        XCTAssertNil(AyuPluginBatchBlocker.sanitized(code: "SDK_MEMBER", identifier: "android.View;secret"))
        XCTAssertNil(AyuPluginBatchBlocker.sanitized(code: "PLUGIN_ERROR", identifier: "safe.Token"))
        let safeCodeWithoutUnsafeIdentifier = AyuPluginBatchBlocker.sanitized(code: "SDK_MEMBER", identifier: "android.View;secret")
        XCTAssertEqual(safeCodeWithoutUnsafeIdentifier?.code, "SDK_MEMBER")
        XCTAssertNil(safeCodeWithoutUnsafeIdentifier?.identifier)

        try await self.fixture { root in
            let journal = AyuPluginBatchJournal(root: root, sourceRoot: root, batchID: "redact")
            try await journal.open()
            let raw = "raw-source-token-should-not-be-written"
            try await journal.append(pluginID: "plugin1", pluginName: "Name https://example.test token=\(raw)", phase: .inspect,
                result: "failed", diagnostic: .unsupported,
                context: AyuPluginBatchLoadContext(sourceSHA256: String(repeating: "a", count: 64), pluginVersion: "1.2.3", blockers: [
                    AyuPluginBatchBlocker(code: "SDK_MEMBER", identifier: "android.view.View.setAlpha"),
                    AyuPluginBatchBlocker(code: "SDK_MEMBER", identifier: "bad detail;\(raw)")
                ]), fileIndex: 1)
            let data = try AyuPluginBatchJournal.readReport(at: journal.url, within: root)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains(raw))
            XCTAssertTrue(text.contains("android.view.View.setAlpha"))
            XCTAssertFalse(text.contains("https://example.test"))
        }
    }

    func testFiveHundredTerminalEntriesRemainWithinBoundedReport() async throws {
        try await self.fixture { root in
            let journal = AyuPluginBatchJournal(root: root, sourceRoot: root, batchID: "large")
            try await journal.open()
            let blocker = AyuPluginBatchBlocker(code: "SDK_MEMBER", identifier: "android.view.View.setAlpha")
            for index in 0..<500 {
                let id = "plugin\(index)"
                let context = AyuPluginBatchLoadContext(sourceSHA256: String(repeating: "a", count: 64), pluginVersion: "1.0.0", blockers: [blocker])
                for phase in [AyuPluginBatchPhase.queued, .readSource, .inspect, .runtimePrepare, .runtimeLoad, .cleanup] {
                    try await journal.append(pluginID: id, pluginName: id, phase: phase, result: "started", context: context, fileIndex: index + 1)
                }
                try await journal.append(pluginID: id, pluginName: id, phase: .runtimeLoad, result: "failed", diagnostic: .unsupported,
                    durationMilliseconds: 12, context: context, fileIndex: index + 1)
            }
            let summary = AyuPluginBatchSummary(batchID: "large", requested: 500, logPath: journal.url.path)
            try await journal.append(phase: .summary, result: "completed", totals: summary)
            let data = try AyuPluginBatchJournal.readReport(at: journal.url, within: root)
            XCTAssertLessThanOrEqual(data.count, AyuPluginBatchJournal.maximumFileBytes)
            let lines = try self.reportLines(at: journal.url, root: root)
            XCTAssertEqual(lines.filter { $0["result"] as? String == "failed" }.count, 500)
        }
    }

    func testMetadataCapIsDeterministicAndAllowsExactlyFiveHundred() {
        let urls = (0..<501).map { URL(fileURLWithPath: "/tmp/metadata-\(String(format: "%03d", 500 - $0)).json") }
        let bounded = AyuPluginCapacity.boundedMetadataURLs(urls)
        XCTAssertEqual(bounded.count, 500)
        XCTAssertEqual(bounded.first?.lastPathComponent, "metadata-000.json")
        XCTAssertEqual(bounded.last?.lastPathComponent, "metadata-499.json")
    }

    func testRetentionKeepsNewestSevenBeforeNewReport() async throws {
        try await self.fixture { root in
            let now = Date()
            for index in 0..<9 {
                let url = root.appendingPathComponent("batch-old-\(index).jsonl")
                try Data("old".utf8).write(to: url)
                try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(TimeInterval(-index - 1))], ofItemAtPath: url.path)
            }
            let journal = AyuPluginBatchJournal(root: root, sourceRoot: root, batchID: "new")
            try await journal.open(now: now)
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }
            XCTAssertEqual(files.count, 8)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("batch-old-0.jsonl").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("batch-old-8.jsonl").path))
        }
    }
}
