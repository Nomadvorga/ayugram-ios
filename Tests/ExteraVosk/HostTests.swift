import Foundation
import SGSimpleSettings
@testable import VoskCore

private struct Fixture: Decodable {
    let fixture: String
    let path: String
    let name: String
    let sha256: String
    let archiveBytes: Int64
    let expandedBytes: Int
    let largestEntryBytes: Int
    let entryCount: Int
    var model: VoskModelDescriptor {
        VoskModelDescriptor(language: "en", name: self.name, archiveBytes: self.archiveBytes, sha256: self.sha256, md5: "",
            expandedBytes: self.expandedBytes, largestEntryBytes: self.largestEntryBytes, entryCount: self.entryCount, license: "test")
    }
}

private func expectFailure(_ action: () throws -> Void) {
    do { try action(); preconditionFailure("Expected rejection") } catch {}
}

private func logStage(_ value: String) {
    FileHandle.standardError.write(Data(("Vosk host: " + value + "\n").utf8))
}

@main
private enum HostTests {
    static func main() async throws {
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        logStage("fixtures loaded")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("vosk-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fm = FileManager.default
        for fixture in fixtures {
            let destination = temporary.appendingPathComponent(fixture.fixture)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            let extract = { try VoskSafeArchive.extract(archive: URL(fileURLWithPath: fixture.path), destination: destination, model: fixture.model, cancellation: VoskCancellation()) }
            if fixture.fixture == "valid" {
                try extract()
                let bytes = try Data(contentsOf: destination.appendingPathComponent("am/final.mdl"))
                precondition(bytes == Data(String(repeating: "test-model\n", count: 300000).utf8))
            } else { expectFailure(extract) }
        }
        let valid = fixtures.first { $0.fixture == "valid" }!
        logStage("archive fixtures passed")
        let cancellation = VoskCancellation()
        cancellation.cancel()
        expectFailure { try VoskSafeArchive.extract(archive: URL(fileURLWithPath: valid.path), destination: temporary, model: valid.model, cancellation: cancellation) }
        let deadline = VoskCancellation(timeout: -1)
        expectFailure { try deadline.check() }
        precondition(VoskModelCatalogue.all.count == 24)
        precondition(Set(VoskModelCatalogue.all.map(\.language)).count == 24)
        precondition(VoskModelCatalogue.resolve(selection: "auto", chatLocale: "zh-Hans", appLocale: "ru", installed: ["zh", "ru"]) == "zh")
        precondition(VoskModelCatalogue.resolve(selection: "auto", chatLocale: "ja", appLocale: "ru-RU", installed: ["ru"]) == "ru")
        precondition(VoskModelCatalogue.resolve(selection: "en", chatLocale: "ru", appLocale: "ru", installed: ["ru"]) == nil)
        precondition(VoskModelCatalogue.resolve(selection: "none", chatLocale: "en", appLocale: "en", installed: ["en"]) == nil)
        precondition(VoskModelCatalogue.normalize("kz_KZ") == "kk")
        precondition(VoskModelCatalogue.normalize("ua") == "uk")
        precondition(VoskModelCatalogue.normalize("vn") == "vi")
        logStage("catalogue and cancellation passed")

        let settings = ExteraVoskSettings.shared
        precondition(!settings.isSelected && settings.language == "none")
        settings.select(language: "auto")
        precondition(settings.configuration.isEnabled && settings.isSelected)
        settings.select(language: "none")
        precondition(!settings.configuration.isEnabled)
        settings.select(language: "en")
        settings.clearDeletedSelection(language: "ru")
        precondition(settings.language == "en")
        logStage("selection settings passed")

        let recognizer = try VoskRecognizer(path: temporary.path, sampleRate: 16000)
        let utterance = try recognizer.accept(Data([0, 0]))
        let finalText = try recognizer.finish()
        precondition(utterance == "hello" && finalText == "world")
        expectFailure { _ = try recognizer.accept(Data([0])) }
        recognizer.close()
        recognizer.close()
        expectFailure { _ = try recognizer.finish() }
        logStage("recognizer stub passed")

        let root = temporary.appendingPathComponent("store")
        let store = VoskModelStore(root: root, models: [valid.model], validate: { path in
            precondition(fm.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("am/final.mdl").path))
        }, download: { _, destination, cancellation, progress in
            try cancellation.check()
            try fm.copyItem(at: URL(fileURLWithPath: valid.path), to: destination)
            progress(1)
        })
        precondition(!store.catalogue()[0].isInstalled)
        expectFailure { _ = try store.lease(language: "en") }
        try await store.install(language: "en", progress: { _ in })
        logStage("install passed")
        precondition(store.catalogue()[0].isInstalled)
        // Downloading a model leaves the existing preference unchanged.
        precondition(settings.language == "en")
        var lease: VoskModelLease? = try store.lease(language: "en")
        do { try await store.delete(language: "en"); preconditionFailure("Deleted leased model") }
        catch { precondition(error as? VoskSpeechError == .busy) }
        withExtendedLifetime(lease) {}
        lease = nil
        let useStarted = DispatchSemaphore(value: 0)
        let useResume = DispatchSemaphore(value: 0)
        let racingStore = VoskModelStore(root: root, models: [valid.model], validate: { _ in
            useStarted.signal()
            useResume.wait()
        })
        let useOperation = Task { try await racingStore.use(language: "en") }
        await Task.detached { useStarted.wait() }.value
        // A newer user choice while native loading runs must win.
        await MainActor.run { settings.select(language: "auto") }
        useResume.signal()
        do { try await useOperation.value; preconditionFailure("Stale Use succeeded") }
        catch { precondition(error as? VoskSpeechError == .cancelled) }
        precondition(settings.language == "auto")
        logStage("stale Use race passed")
        try await store.use(language: "en")
        try await store.delete(language: "en")
        precondition(!store.catalogue()[0].isInstalled)
        precondition(!fm.fileExists(atPath: root.appendingPathComponent("en").path))
        precondition(settings.language == "none" && !settings.configuration.isEnabled)
        logStage("use/delete passed")
        let corrupt = VoskModelStore(root: temporary.appendingPathComponent("corrupt"), models: [valid.model], validate: { _ in
            preconditionFailure("Parsed a corrupt archive")
        }, download: { _, destination, _, _ in
            // Preserve exact length so the SHA-256 check, rather than the
            // downloader/size gate, must reject this archive before extraction.
            var bytes = try Data(contentsOf: URL(fileURLWithPath: valid.path))
            bytes[0] ^= 1
            try bytes.write(to: destination)
        })
        do { try await corrupt.install(language: "en", progress: { _ in }); preconditionFailure("Installed corruption") }
        catch { precondition(error as? VoskSpeechError == .integrityFailed) }
        precondition(!corrupt.catalogue()[0].isInstalled)
        let leftovers = try fm.contentsOfDirectory(atPath: temporary.appendingPathComponent("corrupt").path)
        precondition(leftovers.isEmpty)
        let cancelRoot = temporary.appendingPathComponent("cancel")
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let cancelStore = VoskModelStore(root: cancelRoot, models: [valid.model], validate: { _ in
            preconditionFailure("Loaded cancelled installation")
        }, download: { _, destination, _, _ in
            // Deliberately emulate a transport completing after cancellation.
            try fm.copyItem(at: URL(fileURLWithPath: valid.path), to: destination)
            started.signal()
            resume.wait()
        })
        let operation = Task { try await cancelStore.install(language: "en", progress: { _ in }) }
        await Task.detached { started.wait() }.value
        operation.cancel()
        resume.signal()
        do { try await operation.value; preconditionFailure("Cancelled install succeeded") }
        catch {}
        precondition(!cancelStore.catalogue()[0].isInstalled)
        let cancelledLeftovers = try fm.contentsOfDirectory(atPath: cancelRoot.path)
        precondition(cancelledLeftovers.isEmpty)
        logStage("cancellation rollback passed")
        let orphan = cancelRoot.appendingPathComponent("staging-" + UUID().uuidString)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: false)
        let unrelated = cancelRoot.appendingPathComponent("preserve-me")
        try Data([1]).write(to: unrelated)
        try await cancelStore.removeInterruptedDownloads()
        precondition(!fm.fileExists(atPath: orphan.path) && fm.fileExists(atPath: unrelated.path))
        print("PASS: safe extraction, traversal/link/duplicate rejection, cancellation/deadline, catalogue/aliases, settings, install/use/lease/delete and failed-install cleanup")
    }
}
