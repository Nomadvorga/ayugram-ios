import Foundation

private enum TestFailure: Error { case failed(String) }
private func expect(_ value: Bool, _ message: String) throws {
    if !value { throw TestFailure.failed(message) }
}

private actor Inventory: ExteraSpeechAssetInventory {
    var supported = ["en-US", "ru-RU"]
    var reserved: Set<String> = []
    var installed: Set<String> = []
    var downloads = 0
    var reservations = 0
    var releases = 0
    var failDownload = false
    var failRelease = false
    var pauseDownload = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var pending: CheckedContinuation<Void, Never>?

    init(reserved: Set<String> = [], installed: Set<String> = [], failDownload: Bool = false, failRelease: Bool = false, pauseDownload: Bool = false) {
        self.reserved = reserved
        self.installed = installed
        self.failDownload = failDownload
        self.failRelease = failRelease
        self.pauseDownload = pauseDownload
    }

    func supportedLocales() async -> [String] { return self.supported }
    func reservedLocales() async -> [String] { return self.reserved.sorted() }
    func status(localeIdentifier: String) async -> ExteraSpeechModelStatus {
        return !self.supported.contains(localeIdentifier) ? .unsupported : (self.installed.contains(localeIdentifier) ? .installed : .notInstalled)
    }
    func reserve(localeIdentifier: String) async throws {
        self.reservations += 1
        self.reserved.insert(localeIdentifier)
    }
    func install(localeIdentifier: String) async throws {
        self.downloads += 1
        if self.pauseDownload {
            self.pauseDownload = false
            self.entered = true
            for waiter in self.waiters { waiter.resume() }
            self.waiters.removeAll()
            // Deliberately non-cooperative: verifies manager checks cancellation after
            // the OS returns, even if an install completes after Cancel was pressed.
            await withCheckedContinuation { self.pending = $0 }
        }
        if self.failDownload { throw TestFailure.failed("simulated install failure") }
        self.installed.insert(localeIdentifier)
    }
    func release(localeIdentifier: String) async {
        self.releases += 1
        if !self.failRelease { self.reserved.remove(localeIdentifier) }
    }
    func waitForInstall() async {
        if !self.entered { await withCheckedContinuation { self.waiters.append($0) } }
    }
    func finishInstall() { self.pending?.resume(); self.pending = nil }
    func counts() -> (Int, Int, Int) { return (self.downloads, self.reservations, self.releases) }
}

@main
private struct SpeechTests {
    static func main() async throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "fresh"
        let defaults = UserDefaults(suiteName: APP_GROUP_IDENTIFIER)!
        defaults.removePersistentDomain(forName: APP_GROUP_IDENTIFIER)
        defer { defaults.removePersistentDomain(forName: APP_GROUP_IDENTIFIER) }
        if mode == "legacy" {
            defaults.set("ru-RU", forKey: "extera.appleSpeechLocaleIdentifier")
            defaults.set(true, forKey: "extera.appleSpeechOnDeviceOnly")
        } else if mode == "disabled" {
            defaults.set(false, forKey: "extera.speech.isEnabled")
            defaults.set("en-US", forKey: "extera.appleSpeechLocaleIdentifier")
        }
        try self.settings(mode: mode)
        try self.policy()
        try await self.management()
        print("PASS ExteraSpeech settings (\(mode)), locale/transcript policy, real manager with injected inventory")
    }

    static func settings(mode: String) throws {
        let settings = ExteraSpeechSettings.shared
        let initial = settings.configuration
        try expect(!initial.useManagedOfflineModel, "upgrade must not opt into managed models")
        if mode == "legacy" {
            try expect(initial.isEnabled && initial.localeIdentifier == "ru-RU" && initial.onDeviceOnly, "preserve legacy locale + offline flag")
        } else if mode == "disabled" {
            try expect(initial.selection == .disabled && initial.localeIdentifier == "en-US", "explicit disabled persists across launch")
        } else {
            try expect(initial.selection == .automatic && !initial.onDeviceOnly, "fresh defaults preserve previous automatic behavior")
        }
        settings.languageSelection = .locale("  en-US  ")
        try expect(settings.languageSelection == .locale("en-US"), "locale normalization")
        settings.languageSelection = .disabled
        try expect(settings.languageSelection == .disabled && settings.configuration.localeIdentifier == "en-US", "None is distinct and retains prior locale")
        settings.languageSelection = .automatic
        try expect(settings.languageSelection == .automatic && settings.configuration.localeIdentifier.isEmpty, "automatic re-enables without inventing locale")
        settings.selectManagedOfflineModel(localeIdentifier: "ru-RU")
        let managed = settings.configuration
        try expect(managed.isEnabled && managed.onDeviceOnly && managed.useManagedOfflineModel && managed.localeIdentifier == "ru-RU", "managed selection explicitly enables offline runtime")
        try expect(SGSimpleSettings.shared.transcriptionBackend == "apple", "model selection selects Apple backend")
        settings.languageSelection = .disabled
        try expect(settings.configuration.useManagedOfflineModel && settings.configuration.localeIdentifier == "ru-RU", "disabled preserves installed model preference")
        try expect(settings.configuration != managed, "queued configuration must become stale on disable")
        settings.languageSelection = .automatic
        try expect(!settings.configuration.useManagedOfflineModel && settings.configuration.onDeviceOnly, "auto returns to legacy without relaxing on-device flag")
        settings.selectManagedOfflineModel(localeIdentifier: "ru-RU")
        settings.languageSelection = .locale("en-US")
        try expect(!settings.configuration.useManagedOfflineModel, "legacy language choice exits managed mode")
        let before = settings.configuration
        settings.languageSelection = .locale("  ")
        try expect(settings.configuration == before, "empty locale is not disabled or a new selection")
    }

    static func policy() throws {
        let resolve = ExteraSpeechLocalePolicy.resolve
        try expect(resolve("en_US", ["en-US", "en-GB"], []) == "en-US", "underscore normalization")
        try expect(resolve("en-raw", ["en-US", "en-GB"], ["en-US"]) == "en-US", "language pack suffix and regional preference")
        try expect(resolve("en-AU", ["en-US", "en-GB"], ["en-US"]) == nil, "explicit unavailable region must fail")
        try expect(resolve("eo", ["en-US", "ru-RU"], ["en-US"]) == nil, "Vosk language is not invented in Apple catalogue")
        try expect(resolve("", ["en-US"], ["en-US"]) == nil, "empty locale is not arbitrary fallback")
        var transcript = ExteraSpeechTranscript()
        transcript.update(start: 0, end: 1, text: "Hello")
        transcript.update(start: 0, end: 1, text: "Hello!")
        transcript.update(start: 1, end: 2, text: " World")
        try expect(transcript.text == "Hello! World", "replace phrase hypotheses and retain prior phrases")
        transcript.update(start: 0, end: 2, text: "Revised.")
        try expect(transcript.text == "Revised.", "merged range replaces all overlapping hypotheses")
        transcript.update(start: .nan, end: 3, text: "invalid")
        transcript.update(start: 3, end: 2, text: "invalid")
        transcript.update(start: 2, end: 3, text: "   ")
        try expect(transcript.text == "Revised.", "reject invalid/empty segments")
        var cjk = ExteraSpeechTranscript()
        cjk.update(start: 1, end: 2, text: "世界")
        cjk.update(start: 0, end: 1, text: "你好")
        try expect(cjk.text == "你好世界", "sort time ranges without inserting Latin spaces")
        var access = ExteraSpeechModelAccess()
        let lease = access.beginRecognition()!
        try expect(!access.beginMaintenance() && access.beginRecognition() == nil, "lease excludes maintenance and duplicate analysis")
        access.endRecognition(UUID())
        try expect(!access.beginMaintenance(), "stale callback cannot end another lease")
        access.endRecognition(lease)
        try expect(access.beginMaintenance() && access.beginRecognition() == nil, "maintenance excludes recognition")
        access.endMaintenance()
        try expect(access.beginRecognition() != nil, "maintenance unlocks")
    }

    static func management() async throws {
        let inventory = Inventory()
        let manager = ExteraSpeechModelManager(inventory: inventory)
        let catalogue = await manager.catalogue()
        try expect(catalogue.count == 2 && catalogue.allSatisfy { !$0.isReserved && $0.status == .notInstalled }, "query real inventory statuses")
        do { try await manager.verifyInstalledModel(localeIdentifier: "en-US"); throw TestFailure.failed("missing model accepted") }
        catch ExteraSpeechModelError.notInstalled { }
        let initialCounts = await inventory.counts()
        try expect(initialCounts == (0, 0, 0), "catalogue and selection may never download/reserve")
        try await manager.install(localeIdentifier: "en_US")
        let installedCounts = await inventory.counts()
        try expect(installedCounts == (1, 1, 0), "explicit install reserves and downloads once")
        try await manager.install(localeIdentifier: "en-US")
        let retainedCounts = await inventory.counts()
        try expect(retainedCounts.0 == 1, "installed assets are not downloaded again")
        try await manager.verifyInstalledModel(localeIdentifier: "en-US")
        let (lease, _) = try await manager.acquire(localeIdentifier: "en-US")
        do { try await manager.release(localeIdentifier: "en-US"); throw TestFailure.failed("released active analysis") }
        catch ExteraSpeechModelError.busy { }
        await manager.relinquish(UUID())
        do { try await manager.install(localeIdentifier: "ru-RU"); throw TestFailure.failed("installed during active lease") }
        catch ExteraSpeechModelError.busy { }
        await manager.relinquish(lease)
        try await manager.release(localeIdentifier: "en-US")
        let released = await manager.catalogue().first { $0.localeIdentifier == "en-US" }
        try expect(released?.isReserved == false && released?.status == .installed, "release removes reservation, shared installed files can remain")
        do { try await manager.verifyInstalledModel(localeIdentifier: "en-US"); throw TestFailure.failed("released asset accepted") }
        catch ExteraSpeechModelError.notInstalled { }
        do { try await manager.install(localeIdentifier: "eo"); throw TestFailure.failed("unsupported locale installed") }
        catch ExteraSpeechModelError.unsupportedLocale { }

        let failedInventory = Inventory(failDownload: true)
        let failedManager = ExteraSpeechModelManager(inventory: failedInventory)
        do { try await failedManager.install(localeIdentifier: "en-US"); throw TestFailure.failed("expected install failure") }
        catch TestFailure.failed(let message) { try expect(message == "simulated install failure", "propagate original installation failure") }
        let failedReserved = await failedInventory.reservedLocales()
        try expect(failedReserved.isEmpty, "failed first install releases real reservation")

        let previousInventory = Inventory(reserved: ["en-US"], failDownload: true)
        let previousManager = ExteraSpeechModelManager(inventory: previousInventory)
        do { try await previousManager.install(localeIdentifier: "en-US"); throw TestFailure.failed("expected retained install failure") }
        catch TestFailure.failed(let message) { try expect(message == "simulated install failure", "failed retained installation") }
        let previousReserved = await previousInventory.reservedLocales()
        try expect(previousReserved == ["en-US"], "failure must preserve pre-existing reservation")

        let blockedInventory = Inventory(reserved: ["en-US"], failRelease: true)
        let blockedManager = ExteraSpeechModelManager(inventory: blockedInventory)
        do { try await blockedManager.release(localeIdentifier: "en-US"); throw TestFailure.failed("false release success") }
        catch ExteraSpeechModelError.releaseFailed { }
        let obsoleteInventory = Inventory(reserved: ["eo"])
        let obsoleteManager = ExteraSpeechModelManager(inventory: obsoleteInventory)
        let obsolete = await obsoleteManager.catalogue().first { $0.localeIdentifier == "eo" }
        try expect(obsolete?.status == .unsupported && obsolete?.isReserved == true, "obsolete reservations remain visible")
        try await obsoleteManager.release(localeIdentifier: "eo")

        let slowInventory = Inventory(pauseDownload: true)
        let slowManager = ExteraSpeechModelManager(inventory: slowInventory)
        let request = Task { try await slowManager.install(localeIdentifier: "en-US") }
        await slowInventory.waitForInstall()
        do { try await slowManager.release(localeIdentifier: "en-US"); throw TestFailure.failed("concurrent release allowed during install") }
        catch ExteraSpeechModelError.busy { }
        request.cancel()
        await slowInventory.finishInstall()
        do { try await request.value; throw TestFailure.failed("cancel ignored after OS install returned") }
        catch is CancellationError { }
        let cancelledReserved = await slowInventory.reservedLocales()
        try expect(cancelledReserved.isEmpty, "late completed cancelled install must release reservation")
        // A failed/cancelled operation must not leave the actor stuck in maintenance.
        try await slowManager.install(localeIdentifier: "ru-RU")
    }
}
