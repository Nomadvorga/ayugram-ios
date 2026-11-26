import CVosk
import Darwin
import Foundation

/// Owns C handles on one worker. Never share a recognizer between threads.
final class VoskRecognizer {
    private var model: OpaquePointer?
    private var recognizer: OpaquePointer?

    init(path: String, sampleRate: Float) throws {
        VoskNativeLogging.disable()
        guard let model = path.withCString({ vosk_model_new($0) }) else { throw VoskSpeechError.invalidModel }
        guard let recognizer = vosk_recognizer_new(model, sampleRate) else {
            vosk_model_free(model)
            throw VoskSpeechError.recognitionFailed
        }
        self.model = model
        self.recognizer = recognizer
    }

    deinit { self.close() }

    /// Explicit release keeps native teardown inside the model-file lease.
    func close() {
        if let recognizer = self.recognizer { vosk_recognizer_free(recognizer) }
        self.recognizer = nil
        if let model = self.model { vosk_model_free(model) }
        self.model = nil
    }

    /// Raw, packed, signed Int16 mono; sample rate must match the initializer.
    func accept(_ pcm: Data) throws -> String? {
        guard let recognizer = self.recognizer, !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 128 * 1024 else { throw VoskSpeechError.recognitionFailed }
        let status = pcm.withUnsafeBytes { buffer in
            vosk_recognizer_accept_waveform(recognizer, buffer.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(buffer.count))
        }
        guard status >= 0 else { throw VoskSpeechError.recognitionFailed }
        return status == 1 ? try self.text(vosk_recognizer_result(recognizer)) : nil
    }

    func finish() throws -> String {
        guard let recognizer = self.recognizer else { throw VoskSpeechError.recognitionFailed }
        return try self.text(vosk_recognizer_final_result(recognizer))
    }

    private func text(_ pointer: UnsafePointer<CChar>?) throws -> String {
        guard let pointer else { throw VoskSpeechError.recognitionFailed }
        // Copy the borrowed C string before another recognizer method invalidates it.
        let count = strnlen(pointer, 1024 * 1024)
        guard count < 1024 * 1024 else { throw VoskSpeechError.recognitionFailed }
        let data = Data(bytes: pointer, count: count)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = json["text"] as? String else { throw VoskSpeechError.recognitionFailed }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func validate(path: String) throws {
        VoskNativeLogging.disable()
        guard let model = path.withCString({ vosk_model_new($0) }) else { throw VoskSpeechError.invalidModel }
        vosk_model_free(model)
    }
}
