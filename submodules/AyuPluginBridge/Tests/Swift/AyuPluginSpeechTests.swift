import AVFoundation
import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// `speech.*` through a native host and the application's composite provider, with a stand-in
/// synthesizer: nothing is spoken and no interpreter runs.
@MainActor
final class AyuPluginSpeechTests: XCTestCase {
    private final class Engine: AyuPluginSpeechEngine {
        var spoken: [AyuPluginSpeechUtterance] = []
        var waiting: [@MainActor @Sendable () -> Void] = []
        var stops = 0
        /// Texts in the order they were handed over, with `stop` for each stop.
        var events: [String] = []
        func speak(_ utterance: AyuPluginSpeechUtterance, finished: @escaping @MainActor @Sendable () -> Void) {
            self.spoken.append(utterance); self.waiting.append(finished); self.events.append(utterance.text)
        }
        func stop() { self.stops += 1; self.waiting.removeAll(); self.events.append("stop") }
        func finishFirst() { self.waiting.removeFirst()() }
    }

    private var engines: [Engine] = []
    private let voices = ["en-US", "en-GB", "ru-RU", "zh-CN", "he-IL", "es-419"]

    private func host() -> AyuPluginNativeHost {
        let voices = self.voices
        let speech = AyuPluginSpeechBridge(environment: .init(voices: { voices }, makeEngine: { [weak self] in
            let engine = Engine()
            self?.engines.append(engine)
            return engine
        }))
        let provider = AyuPluginMenuHostProvider(application: AyuPluginApplicationBridge(), menus: AyuPluginMenuBridge(), telegram: AyuPluginTelegramBridge(), speech: speech)
        return AyuPluginNativeHost(defaults: UserDefaults(suiteName: "AyuPluginSpeechTests." + UUID().uuidString)!,
                                   provider: provider, trustedOwner: { "alpha" }, callback: { _, _, _ in })
    }

    private func call(_ host: AyuPluginNativeHost, _ operation: String, owner: String = "alpha", _ arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        let request = AyuBridgeValue.object(["version": .integer(1), "id": .string("1"), "plugin_id": .string(owner),
            "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        let response: String = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: host.dispatch(text, owner: owner)) }
        }
        return try JSONDecoder().decode(AyuBridgeValue.self, from: Data(response.utf8))
    }

    private func authorize(_ host: AyuPluginNativeHost, owner: String = "alpha") async throws {
        let result = try await self.call(host, "plugin.authorize", owner: owner, ["metadata": .object(["id": .string(owner)]), "classes": .array([]),
            "requirements": .array([]), "imports": .array([])])
        XCTAssertEqual(result["result"], .bool(true))
    }

    private func speak(_ host: AyuPluginNativeHost, _ text: String, owner: String = "alpha", flush: Bool = false, language: String? = nil,
                       rate: Double = 1, pitch: Double = 1) async throws -> AyuBridgeValue {
        try await self.call(host, "speech.speak", owner: owner, ["text": .string(text), "flush": .bool(flush),
            "language": language.map(AyuBridgeValue.string) ?? .null, "rate": .number(rate), "pitch": .number(pitch)])
    }

    private func speaking(_ host: AyuPluginNativeHost, owner: String = "alpha") async throws -> AyuBridgeValue {
        try await self.call(host, "speech.speaking", owner: owner)["result"]
    }

    /// The synthesizer is driven on main after the call returned.
    private func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }

    func testUtterancesQueueFlushAndReportSpeaking() async throws {
        let host = self.host()
        let unauthorized = try await self.speaking(host)
        XCTAssertEqual(unauthorized, .null)
        try await self.authorize(host)
        let operations = try await self.call(host, "runtime.capabilities")["result"]["operations"].array ?? []
        for operation in AyuPluginSpeechBridge.operations { XCTAssertTrue(operations.contains(.string(operation)), operation) }

        var state = try await self.speaking(host)
        XCTAssertEqual(state, .bool(false))
        var answer = try await self.speak(host, "first")
        XCTAssertEqual(answer["result"], .null); XCTAssertEqual(answer["error"], .null)
        // Known to the plugin before main has started the synthesizer.
        state = try await self.speaking(host)
        XCTAssertEqual(state, .bool(true))
        answer = try await self.speak(host, "second")
        XCTAssertEqual(answer["error"], .null)
        await self.settle()
        XCTAssertEqual(self.engines.count, 1)
        let engine = try XCTUnwrap(self.engines.first)
        XCTAssertEqual(engine.spoken.map(\.text), ["first", "second"])
        XCTAssertEqual(engine.stops, 0)
        XCTAssertEqual(engine.spoken[0], AyuPluginSpeechUtterance(text: "first", voice: nil, rate: AVSpeechUtteranceDefaultSpeechRate, pitch: 1))

        engine.finishFirst()
        state = try await self.speaking(host)
        XCTAssertEqual(state, .bool(true))
        engine.finishFirst()
        state = try await self.speaking(host)
        XCTAssertEqual(state, .bool(false))

        // QUEUE_FLUSH drops what is queued before the new utterance starts.
        _ = try await self.speak(host, "third")
        _ = try await self.speak(host, "fourth", flush: true)
        await self.settle()
        XCTAssertEqual(Array(engine.events.suffix(2)), ["stop", "fourth"])
        XCTAssertEqual(engine.waiting.count, 1)
        state = try await self.speaking(host)
        XCTAssertEqual(state, .bool(true))

        let stops = engine.stops
        answer = try await self.call(host, "speech.stop")
        XCTAssertEqual(answer["error"], .null)
        state = try await self.speaking(host)
        XCTAssertEqual(state, .bool(false))
        await self.settle()
        XCTAssertEqual(engine.stops, stops + 1)

        // An empty text is a success that says nothing; with a flush it still silences the plugin.
        _ = try await self.speak(host, "fifth")
        answer = try await self.speak(host, " \n", flush: true)
        XCTAssertEqual(answer["error"], .null)
        state = try await self.speaking(host)
        XCTAssertEqual(state, .bool(false))
        await self.settle()
        XCTAssertEqual(engine.events.last, "stop")
        XCTAssertFalse(engine.events.contains(" \n"))
        XCTAssertTrue(engine.waiting.isEmpty)
    }

    func testLanguagesFollowTheInstalledVoices() async throws {
        let host = self.host()
        try await self.authorize(host)
        let expected: [(String, Int64)] = [("en-US", 1), ("en", 0), ("en-ZZ", 0), ("ru-RU", 1), ("ru_RU", 1), ("de-DE", -2), ("de", -2),
                                           ("iw-IL", 1), ("zh-Hans-CN", 1), ("es-MX", 0), ("EN-us", 1)]
        for (tag, availability) in expected {
            let answer = try await self.call(host, "speech.language", ["language": .string(tag)])
            XCTAssertEqual(answer["result"], .integer(availability), tag)
        }
        for tag in ["", "e", "en-", "en US", "русский", "12-US", String(repeating: "a", count: 8) + "-" + String(repeating: "b", count: 30)] {
            let answer = try await self.call(host, "speech.language", ["language": .string(tag)])
            XCTAssertEqual(answer["error"]["code"], .string("INVALID_ARGUMENTS"), tag)
        }
        let extra = try await self.call(host, "speech.language", ["language": .string("en"), "variant": .string("x")])
        XCTAssertEqual(extra["error"]["code"], .string("INVALID_ARGUMENTS"))

        // The installed voice of the country, else the bare language, else the device voice.
        _ = try await self.speak(host, "a", language: "en-GB", rate: 0.5, pitch: 0.1)
        _ = try await self.speak(host, "b", language: "en-AU", rate: 2, pitch: 5)
        _ = try await self.speak(host, "c", language: "de-DE", rate: 30, pitch: 1.5)
        await self.settle()
        let engine = try XCTUnwrap(self.engines.first)
        XCTAssertEqual(engine.spoken.map(\.voice), ["en-GB", "en", nil])
        XCTAssertEqual(engine.spoken.map(\.rate), [AVSpeechUtteranceDefaultSpeechRate / 2, AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceMaximumSpeechRate])
        XCTAssertEqual(engine.spoken.map(\.pitch), [0.5, 2, 1.5])
    }

    func testInvalidUtterancesAndTheQueueBoundAreRefused() async throws {
        let host = self.host()
        try await self.authorize(host)
        let long = try await self.speak(host, String(repeating: "a", count: AyuPluginSpeechBridge.maximumTextUnits + 1))
        XCTAssertEqual(long["error"]["code"], .string("INVALID_ARGUMENTS"))
        // Counted in UTF-16 units, as `TextToSpeech.getMaxSpeechInputLength()`.
        let pairs = try await self.speak(host, String(repeating: "😀", count: AyuPluginSpeechBridge.maximumTextUnits / 2 + 1))
        XCTAssertEqual(pairs["error"]["code"], .string("INVALID_ARGUMENTS"))
        for (rate, pitch) in [(0.0, 1.0), (-1.0, 1.0), (1.0, 0.0)] {
            let answer = try await self.speak(host, "a", rate: rate, pitch: pitch)
            XCTAssertEqual(answer["error"]["code"], .string("INVALID_ARGUMENTS"))
        }
        let language = try await self.speak(host, "a", language: "en US")
        XCTAssertEqual(language["error"]["code"], .string("INVALID_ARGUMENTS"))
        let missing = try await self.call(host, "speech.speak", ["text": .string("a"), "flush": .bool(true)])
        XCTAssertEqual(missing["error"]["code"], .string("INVALID_ARGUMENTS"))
        for operation in ["speech.stop", "speech.speaking"] {
            let answer = try await self.call(host, operation, ["all": .bool(true)])
            XCTAssertEqual(answer["error"]["code"], .string("INVALID_ARGUMENTS"), operation)
        }
        let unknown = try await self.call(host, "speech.voices")
        XCTAssertEqual(unknown["error"]["code"], .string("UNSUPPORTED_API"))
        await self.settle()
        XCTAssertTrue(self.engines.isEmpty)

        for index in 0..<AyuPluginSpeechBridge.maximumQueued {
            let answer = try await self.speak(host, "queued \(index)")
            XCTAssertEqual(answer["error"], .null)
        }
        let full = try await self.speak(host, "one too many")
        XCTAssertEqual(full["error"]["code"], .string("RESOURCE_LIMIT"))
        let flushed = try await self.speak(host, "start over", flush: true)
        XCTAssertEqual(flushed["error"], .null)
        await self.settle()
        XCTAssertEqual(self.engines.first?.waiting.count, 1)
    }

    func testEveryPluginHasItsOwnSynthesizerAndUnloadStopsIt() async throws {
        let host = self.host()
        try await self.authorize(host)
        try await self.authorize(host, owner: "beta")
        _ = try await self.speak(host, "from alpha")
        await self.settle()
        _ = try await self.speak(host, "from beta", owner: "beta")
        await self.settle()
        XCTAssertEqual(self.engines.map { $0.spoken.map(\.text) }, [["from alpha"], ["from beta"]])

        // Stopping one plugin leaves the other speaking.
        _ = try await self.call(host, "speech.stop", owner: "beta")
        await self.settle()
        XCTAssertEqual(self.engines.map(\.stops), [0, 1])
        var state = try await self.speaking(host)
        XCTAssertEqual(state, .bool(true))

        _ = try await self.speak(host, "never started")
        await withCheckedContinuation { continuation in host.detach(pluginID: "alpha") { continuation.resume() } }
        await self.settle()
        XCTAssertEqual(self.engines.map(\.stops), [1, 1])
        // A reload starts silent, with a new synthesizer.
        try await self.authorize(host)
        state = try await self.speaking(host)
        XCTAssertEqual(state, .bool(false))
        _ = try await self.speak(host, "again")
        await self.settle()
        XCTAssertEqual(self.engines.count, 3)
        XCTAssertEqual(self.engines.last?.spoken.map(\.text), ["again"])
    }

    func testRatesAndPitchesStayInsideTheSynthesizerRange() {
        XCTAssertEqual(AyuPluginSpeechBridge.rate(1), AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertEqual(AyuPluginSpeechBridge.rate(0.0001), AVSpeechUtteranceDefaultSpeechRate * 0.0001, accuracy: 0.0001)
        XCTAssertEqual(AyuPluginSpeechBridge.rate(1.5), (AVSpeechUtteranceDefaultSpeechRate + AVSpeechUtteranceMaximumSpeechRate) / 2, accuracy: 0.0001)
        XCTAssertEqual(AyuPluginSpeechBridge.rate(1e9), AVSpeechUtteranceMaximumSpeechRate)
        XCTAssertEqual(AyuPluginSpeechBridge.pitch(1), 1)
        XCTAssertEqual(AyuPluginSpeechBridge.pitch(0.01), 0.5)
        XCTAssertEqual(AyuPluginSpeechBridge.pitch(9), 2)
    }
}
