import AVFoundation
import Foundation

/// One utterance in the synthesizer's own units, already bounded.
public struct AyuPluginSpeechUtterance: Sendable, Equatable {
    public let text: String
    /// The tag of an installed voice, a bare language code, or nil for the voice of the device language.
    public let voice: String?
    /// `AVSpeechUtterance.rate`.
    public let rate: Float
    /// `AVSpeechUtterance.pitchMultiplier`.
    public let pitch: Float

    public init(text: String, voice: String?, rate: Float, pitch: Float) {
        self.text = text; self.voice = voice; self.rate = rate; self.pitch = pitch
    }
}

/// One plugin's synthesizer. Tests supply a fake.
@MainActor public protocol AyuPluginSpeechEngine: AnyObject {
    /// Appends an utterance. `finished` runs at most once, when the utterance ended; one that
    /// `stop` dropped need not report.
    func speak(_ utterance: AyuPluginSpeechUtterance, finished: @escaping @MainActor @Sendable () -> Void)
    /// Stops speaking and drops the queue.
    func stop()
}

/// `speech.*` (`Python/protocol.md`, "Speech"): one synthesizer per plugin. Calls arrive on the
/// host worker and only validate and record; the synthesizer is driven on main after the call
/// returned, so main never waits for Python and the worker never waits for main.
public final class AyuPluginSpeechBridge: @unchecked Sendable {
    public static let shared = AyuPluginSpeechBridge()
    public static let operations = ["speech.speak", "speech.stop", "speech.language", "speech.speaking"]

    public struct Environment: Sendable {
        /// Worker: the language tags of the installed voices (`en-US`).
        public let voices: @Sendable () -> [String]
        /// Main: a new synthesizer for one plugin.
        public let makeEngine: @MainActor @Sendable () -> AyuPluginSpeechEngine

        public init(voices: @escaping @Sendable () -> [String], makeEngine: @escaping @MainActor @Sendable () -> AyuPluginSpeechEngine) {
            self.voices = voices; self.makeEngine = makeEngine
        }

        public static let system = Environment(voices: { AVSpeechSynthesisVoice.speechVoices().map(\.language) },
                                               makeEngine: { AyuPluginSystemSpeechEngine() })
    }

    /// `TextToSpeech.getMaxSpeechInputLength()`, in UTF-16 units.
    static let maximumTextUnits = 4000
    static let maximumLanguageBytes = 35
    /// Utterances one plugin may have waiting; `QUEUE_FLUSH` starts over.
    static let maximumQueued = 32

    private let environment: Environment
    private let lock = NSLock()
    private var pending: [String: Set<UInt64>] = [:]
    private var nextUtterance: UInt64 = 0
    @MainActor private var engines: [String: AyuPluginSpeechEngine] = [:]

    public init(environment: Environment = .system) { self.environment = environment }

    public var capabilities: [String] { Self.operations }

    // MARK: Worker

    func prepareCall(pluginID owner: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeProviderResult {
        guard !Thread.isMainThread else { throw AyuBridgeFailure("wrong_thread", "Bridge dispatch cannot run on main") }
        switch operation {
        case "speech.speak":
            guard Set(arguments.keys) == ["text", "flush", "language", "rate", "pitch"],
                  let text = arguments["text"]?.string, text.utf16.count <= Self.maximumTextUnits,
                  let flush = arguments["flush"]?.bool,
                  let rate = arguments["rate"]?.number, rate.isFinite, rate > 0,
                  let pitch = arguments["pitch"]?.number, pitch.isFinite, pitch > 0 else { throw Self.invalid("Invalid speech.speak arguments") }
            var voice: String?
            if let language = arguments["language"], language != .null {
                guard let tag = language.string, let parts = Self.parts(tag) else { throw Self.invalid("Invalid speech language") }
                voice = Self.match(parts, voices: self.environment.voices()).voice
            }
            let spoken = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !flush && spoken {
                self.lock.lock()
                let queued = self.pending[owner]?.count ?? 0
                self.lock.unlock()
                guard queued < Self.maximumQueued else { throw AyuBridgeFailure("resource_limit", "Too many utterances are queued") }
            }
            let utterance = AyuPluginSpeechUtterance(text: text, voice: voice, rate: Self.rate(rate), pitch: Self.pitch(pitch))
            return AyuBridgeProviderResult(.value(.null), commit: { _ in self.queue(utterance, owner: owner, flush: flush, spoken: spoken) })
        case "speech.stop":
            guard arguments.isEmpty else { throw Self.invalid("speech.stop takes no arguments") }
            return AyuBridgeProviderResult(.value(.null), commit: { _ in self.silence(owner) })
        case "speech.language":
            guard Set(arguments.keys) == ["language"], let tag = arguments["language"]?.string, let parts = Self.parts(tag) else {
                throw Self.invalid("Invalid speech language")
            }
            return AyuBridgeProviderResult(.value(.integer(Self.match(parts, voices: self.environment.voices()).availability)))
        case "speech.speaking":
            guard arguments.isEmpty else { throw Self.invalid("speech.speaking takes no arguments") }
            self.lock.lock(); defer { self.lock.unlock() }
            return AyuBridgeProviderResult(.value(.bool(!(self.pending[owner] ?? []).isEmpty)))
        default:
            throw AyuBridgeFailure.unsupported(operation)
        }
    }

    /// Unload: the plugin's speech stops and its synthesizer is released.
    func detach(pluginID owner: String) {
        self.lock.lock()
        self.pending.removeValue(forKey: owner)
        self.lock.unlock()
        DispatchQueue.main.async { self.engines.removeValue(forKey: owner)?.stop() }
    }

    private func queue(_ utterance: AyuPluginSpeechUtterance, owner: String, flush: Bool, spoken: Bool) {
        self.lock.lock()
        self.nextUtterance &+= 1
        let id = self.nextUtterance
        if flush { self.pending[owner] = [] }
        if spoken { self.pending[owner, default: []].insert(id) }
        self.lock.unlock()
        DispatchQueue.main.async {
            if flush { self.engines[owner]?.stop() }
            // Stopped, flushed by a later utterance or unloaded before main got here.
            guard spoken, self.isPending(id, owner: owner) else { return }
            let engine = self.engines[owner] ?? self.environment.makeEngine()
            self.engines[owner] = engine
            engine.speak(utterance) { self.finish(id, owner: owner) }
        }
    }

    private func silence(_ owner: String) {
        self.lock.lock()
        self.pending[owner] = []
        self.lock.unlock()
        DispatchQueue.main.async { self.engines[owner]?.stop() }
    }

    private func isPending(_ id: UInt64, owner: String) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.pending[owner]?.contains(id) ?? false
    }

    private func finish(_ id: UInt64, owner: String) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.pending[owner]?.remove(id)
    }

    // MARK: Mapping

    /// Language and region of an Android locale tag or a voice tag (`en`, `en-US`, `zh-Hans-CN`,
    /// `es-419`); nil for anything that is not such a tag.
    static func parts(_ tag: String) -> (language: String, region: String?)? {
        guard !tag.isEmpty, tag.utf8.count <= Self.maximumLanguageBytes,
              tag.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }) else { return nil }
        let components = tag.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        func letters(_ text: String) -> Bool { text.allSatisfy { $0.isLetter } }
        func digits(_ text: String) -> Bool { text.allSatisfy { $0.isNumber } }
        guard let first = components.first, (2...8).contains(first.count), letters(first),
              !components.contains(where: { $0.isEmpty }) else { return nil }
        let language = first.lowercased()
        let region: String? = components.dropFirst().last { component in
            (component.count == 2 && letters(component)) || (component.count == 3 && digits(component))
        }
        // `java.util.Locale` still answers the codes ISO 639 retired.
        let retired = ["iw": "he", "in": "id", "ji": "yi"]
        return (retired[language] ?? language, region?.uppercased())
    }

    /// Android's answer for a locale, and the voice an utterance in it asks for: the installed
    /// voice of that language and country, else the bare language for the system to choose from.
    static func match(_ wanted: (language: String, region: String?), voices: [String]) -> (availability: Int64, voice: String?) {
        let candidates = voices.filter { Self.parts($0)?.language == wanted.language }
        guard !candidates.isEmpty else { return (-2, nil) }
        if let region = wanted.region, let exact = candidates.first(where: { Self.parts($0)?.region == region }) { return (1, exact) }
        return (0, wanted.language)
    }

    /// Android's rate factor (1 is normal) on the synthesizer's scale, where the default rate is
    /// normal: slower factors scale it down, 2 and more is the fastest the synthesizer speaks.
    static func rate(_ factor: Double) -> Float {
        let normal = Double(AVSpeechUtteranceDefaultSpeechRate), lowest = Double(AVSpeechUtteranceMinimumSpeechRate)
        let highest = Double(AVSpeechUtteranceMaximumSpeechRate)
        let value = factor <= 1 ? normal * factor : normal + (highest - normal) * (factor - 1)
        return Float(min(max(value, lowest), highest))
    }

    /// Android's pitch factor inside what `AVSpeechUtterance.pitchMultiplier` accepts.
    static func pitch(_ factor: Double) -> Float { Float(min(max(factor, 0.5), 2)) }

    private static func invalid(_ message: String) -> AyuBridgeFailure { AyuBridgeFailure("invalid_arguments", message) }
}

/// The system synthesizer, on the application's audio session as the app's own Speak action.
@MainActor final class AyuPluginSystemSpeechEngine: NSObject, AyuPluginSpeechEngine, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var waiting: [ObjectIdentifier: (utterance: AVSpeechUtterance, finished: @MainActor @Sendable () -> Void)] = [:]

    override init() {
        super.init()
        self.synthesizer.delegate = self
    }

    func speak(_ utterance: AyuPluginSpeechUtterance, finished: @escaping @MainActor @Sendable () -> Void) {
        let spoken = AVSpeechUtterance(string: utterance.text)
        if let tag = utterance.voice {
            // Nil leaves the voice of the device language.
            spoken.voice = AVSpeechSynthesisVoice(language: tag)
                ?? AVSpeechSynthesisVoice.speechVoices().first { AyuPluginSpeechBridge.parts($0.language)?.language == tag }
        }
        spoken.rate = utterance.rate
        spoken.pitchMultiplier = utterance.pitch
        self.waiting[ObjectIdentifier(spoken)] = (spoken, finished)
        self.synthesizer.speak(spoken)
    }

    func stop() {
        self.waiting.removeAll()
        self.synthesizer.stopSpeaking(at: .immediate)
    }

    private func ended(_ key: ObjectIdentifier) { self.waiting.removeValue(forKey: key)?.finished() }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        DispatchQueue.main.async { self.ended(key) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        DispatchQueue.main.async { self.ended(key) }
    }
}
