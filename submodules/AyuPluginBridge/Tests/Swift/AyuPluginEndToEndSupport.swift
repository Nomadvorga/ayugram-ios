import Foundation
import XCTest
import AyuPluginPython
@testable import AyuPluginBridge

/// The app's plugin stack in the test process: an `AyuPluginService` composed like
/// `AyuPluginService.shared` (application bridge, menu provider, application class registry;
/// no Telegram backend bound), its host, the Objective-C runtime and the Python SDK.
/// A process can own a single interpreter, so every end-to-end test shares this instance.
/// The resource bundles come from `Build/run_swift_tests.py`; without them tests are skipped.
@MainActor
final class AyuEndToEnd {
    private static var prepared: Result<AyuEndToEnd, Error>?

    let service: AyuPluginService
    let application: AyuPluginApplicationBridge
    let defaults: UserDefaults
    private let suite: String
    private let sources: URL

    static func shared() throws -> AyuEndToEnd {
        if let prepared = self.prepared { return try prepared.get() }
        let result = Result { try AyuEndToEnd() }
        self.prepared = result
        return try result.get()
    }

    private init() throws {
        let roots = [Bundle.main, Bundle(for: AyuPluginService.self), Bundle(for: APBPythonRuntime.self)].compactMap(\.resourceURL)
        guard AyuPluginResourceLocator.locate(.pythonHome, roots: roots) != nil, AyuPluginResourceLocator.locate(.sdk, roots: roots) != nil else {
            throw XCTSkip("No embedded interpreter: AyuPythonResources.bundle and AyuPluginSDK.bundle are not next to the test code")
        }
        let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].standardizedFileURL.path
        if let home = ProcessInfo.processInfo.environment["AYU_PLUGIN_TEST_HOME"], !storage.hasPrefix(URL(fileURLWithPath: home).standardizedFileURL.path + "/") {
            throw XCTSkip("Plugin storage \(storage) is outside the test home")
        }
        self.suite = "AyuPluginBridgeTests.EndToEnd." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: self.suite) else { throw XCTSkip("No preference suite") }
        self.defaults = defaults
        self.application = .shared
        self.service = AyuPluginService(defaults: defaults, provider: AyuPluginMenuHostProvider(application: self.application), classRegistry: try self.application.classRegistry())
        self.sources = FileManager.default.temporaryDirectory.appendingPathComponent(self.suite, isDirectory: true)
        try FileManager.default.createDirectory(at: self.sources, withIntermediateDirectories: true)
        XCTestObservationCenter.shared.addTestObserver(AyuEndToEndCleanup(suite: self.suite, sources: self.sources))
    }

    /// What the app's bindings supply after login: one selected account and a visible chat screen
    /// without a view controller. Nothing here has a window.
    @discardableResult
    func bindApplication(dialogID: Int64? = 777_000_123, telegram: AyuPluginTelegramScreen? = nil) -> AyuPluginScreenSnapshot {
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0, dialogID: dialogID, telegram: telegram)
        self.application.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: Self.account, userID: 9_007_199_254_740_993, firstName: "Synthetic", lastName: "User", username: "synthetic")], selected: 0)
        self.application.bindScreen(screen: { screen }, presenter: { nil })
        return screen
    }

    /// The state before the app bound anything: no account, no screen.
    func unbindApplication() {
        self.application.bindScreen(screen: { nil }, presenter: { nil })
        self.application.updateAccounts([], selected: nil)
    }

    private static let account = UUID()

    /// A `.plugin` file with the metadata every synthetic plugin needs, followed by `body`.
    static func source(id: String, version: String = "1.0.0", metadata: String = "", _ body: String) -> String {
        """
        __id__ = "\(id)"
        __name__ = "Synthetic \(id)"
        __description__ = "AyuPluginBridge end-to-end fixture"
        __author__ = "AyuPluginBridge tests"
        __version__ = "\(version)"
        \(metadata)

        \(body)

        """
    }

    /// Python shared by the fixtures: `record(name, function)` stores the JSON form of a result,
    /// or `!ExceptionType: message`, under the plugin setting `name`, one check per setting.
    static let recorder = """
    def _plain(value, depth=0):
        if value is None or isinstance(value, (bool, int, str)):
            return value
        if isinstance(value, float):
            return value if value == value and abs(value) != float("inf") else repr(value)
        if depth < 8 and isinstance(value, (list, tuple)):
            return [_plain(item, depth + 1) for item in value]
        if depth < 8 and isinstance(value, dict):
            return {str(key): _plain(item, depth + 1) for key, item in value.items()}
        return "<" + type(value).__name__ + ">"


    class Recorder:
        def record(self, name, function, *args):
            try:
                value = _plain(function(*args))
            except BaseException as error:
                value = "!" + type(error).__name__ + ": " + str(error)
            self.set_setting(name, value)
            return value
    """

    private func file(_ source: String) throws -> URL {
        let url = self.sources.appendingPathComponent(UUID().uuidString + ".plugin")
        try Data(source.utf8).write(to: url)
        return url
    }

    /// A package file (`elyx` or `eaf`) holding the given entries; the caller removes it.
    func package(_ entries: [(name: String, text: String)], fileExtension: String = "elyx") throws -> URL {
        let url = self.sources.appendingPathComponent(UUID().uuidString + "." + fileExtension)
        try Self.archive(entries.map { ($0.name, Data($0.text.utf8)) }).write(to: url)
        return url
    }

    /// A ZIP archive with stored (uncompressed) entries.
    static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        func bytes<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func checksum(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            return ~crc
        }
        var archive = Data(), directory = Data()
        for (name, data) in entries {
            let offset = UInt32(archive.count), path = Data(name.utf8)
            // version 2.0, UTF-8 names, stored, 1980-01-01 00:00.
            let shared = bytes(UInt16(20)) + bytes(UInt16(0x0800)) + bytes(UInt16(0)) + bytes(UInt16(0)) + bytes(UInt16(33))
                + bytes(checksum(data)) + bytes(UInt32(data.count)) + bytes(UInt32(data.count)) + bytes(UInt16(path.count)) + bytes(UInt16(0))
            archive += bytes(UInt32(0x0403_4B50)) + shared + path + data
            directory += bytes(UInt32(0x0201_4B50)) + bytes(UInt16(20)) + shared + bytes(UInt16(0)) + bytes(UInt16(0)) + bytes(UInt16(0))
                + bytes(UInt32(0)) + bytes(offset) + path
        }
        let count = UInt16(entries.count)
        return archive + directory + bytes(UInt32(0x0605_4B50)) + bytes(UInt16(0)) + bytes(UInt16(0)) + bytes(count) + bytes(count)
            + bytes(UInt32(directory.count)) + bytes(UInt32(archive.count)) + bytes(UInt16(0))
    }

    /// What the import sheet shows: the preflight record with its blockers. Nothing is stored.
    func preview(_ source: String) async throws -> AyuPluginImportPreview {
        let url = try self.file(source)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await self.service.previewPlugin(from: url)
    }

    /// Imports the source; it stays disabled.
    @discardableResult
    func install(_ source: String, replacingExisting: Bool = false) async throws -> AyuInstalledPlugin {
        let url = try self.file(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = try await self.service.previewPlugin(from: url)
        try await self.service.importPlugin(from: url, replacingExisting: replacingExisting)
        return preview.plugin
    }

    /// Imports and enables, which runs the module and `on_plugin_load`.
    @discardableResult
    func start(_ source: String, file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let record = try await self.install(source)
        XCTAssertEqual(record.blockers, [], "preflight blockers", file: file, line: line)
        do { try await self.service.enable(record.id) } catch {
            let stored = self.record(record.id)
            XCTFail("enable failed: \(error); blockers \(stored?.blockers ?? []); error \(stored?.error ?? "-")", file: file, line: line)
            try? await self.service.delete(record.id)
            throw error
        }
        return record.id
    }

    /// Disables (which runs `on_plugin_unload`) and removes the plugin with its settings.
    func remove(_ id: String) async {
        try? await self.service.delete(id)
    }

    func record(_ id: String) -> AyuInstalledPlugin? { self.service.plugins.first { $0.id == id } }

    /// The plugin's persisted settings namespace, readable with or without a host session.
    func stored(_ id: String) -> [String: AyuBridgeValue] {
        guard let data = self.defaults.data(forKey: "AyuPluginBridge.v1." + id) else { return [:] }
        return (try? AyuBridgeJSON.decode(data))?.object ?? [:]
    }

    func stored(_ id: String, _ key: String) -> AyuBridgeValue { self.stored(id)[key] ?? .null }

    /// Changes one stored setting of a plugin that has no host session (a disabled one).
    func store(_ id: String, _ key: String, _ value: AyuBridgeValue) throws {
        var values = self.stored(id)
        values[key] = value
        self.defaults.set(try AyuBridgeJSON.encode(.object(values)), forKey: "AyuPluginBridge.v1." + id)
    }

    /// Waits for work that reaches the settings store asynchronously (callbacks, timers, threads).
    func waitForStored(_ id: String, _ key: String, timeout: TimeInterval = 10, where accepted: (AyuBridgeValue) -> Bool = { $0 != .null }) async -> AyuBridgeValue {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let value = self.stored(id, key)
            if accepted(value) || Date() >= deadline { return value }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// One host operation in the plugin's session, off main as the host requires.
    func host(_ id: String, _ operation: String, _ arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        try await Self.dispatch(self.service.host, owner: id, pluginID: id, operation, arguments)
    }

    /// The `runtime.capabilities` answer the SDK receives during preflight and load.
    static func capabilities(of host: AyuPluginNativeHost) async throws -> AyuBridgeValue {
        try await self.dispatch(host, owner: "inspector", pluginID: "$runtime", "runtime.capabilities", [:])
    }

    private static func dispatch(_ host: AyuPluginNativeHost, owner: String, pluginID: String, _ operation: String, _ arguments: [String: AyuBridgeValue]) async throws -> AyuBridgeValue {
        let body: AyuBridgeValue = .object(["version": .integer(1), "id": .string("1"), "plugin_id": .string(pluginID), "operation": .string(operation), "arguments": .object(arguments)])
        let request = String(decoding: try AyuBridgeJSON.encode(body), as: UTF8.self)
        let answer = await Task.detached(priority: .userInitiated) { host.dispatch(request, owner: owner) }.value
        let response = try AyuBridgeJSON.decode(Data(answer.utf8))
        if let code = response["error"]["code"].string { throw AyuBridgeFailure(code, response["error"]["message"].string ?? "") }
        return response["result"]
    }
}

/// The shared service lives until the process ends; its preferences and sources do not outlive the bundle.
private final class AyuEndToEndCleanup: NSObject, XCTestObservation {
    private let suite: String
    private let sources: URL
    init(suite: String, sources: URL) { self.suite = suite; self.sources = sources }
    func testBundleDidFinish(_ testBundle: Bundle) {
        UserDefaults(suiteName: self.suite)?.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.sources)
    }
}
