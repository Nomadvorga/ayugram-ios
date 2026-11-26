import Foundation
import SGSimpleSettings
import SwiftSignalKit

public struct VoskTranscript {
    public let text: String
    public let isFinal: Bool
}

/// Implementations return packed mono S16 and must be used on one worker only.
public protocol VoskPCMSource: AnyObject {
    var sampleRate: Float { get }
    func next(checkCancellation: @escaping () throws -> Void) throws -> Data?
}

private final class VoskRecognitionDelivery {
    private let lock = NSRecursiveLock()
    private var finished = false
    private var disposed = false
    private let current: () -> Bool
    private let output: (VoskTranscript?) -> Void
    private let complete: () -> Void
    private var observer: NSObjectProtocol?
    private var deadline: DispatchWorkItem?

    init(current: @escaping () -> Bool, output: @escaping (VoskTranscript?) -> Void, complete: @escaping () -> Void) {
        self.current = current
        self.output = output
        self.complete = complete
    }

    func start(cancellation: VoskCancellation) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self, !self.current() else { return }
            cancellation.cancel()
            self.send(nil, final: true)
        }
        let deadline = DispatchWorkItem { [weak self] in
            cancellation.cancel()
            self?.send(nil, final: true)
        }
        self.deadline = deadline
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180, execute: deadline)
    }

    func send(_ transcript: VoskTranscript?, final: Bool) {
        DispatchQueue.main.async { [self] in
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.finished, !self.disposed else { return }
            let current = self.current()
            if !current || final {
                self.finished = true
                self.cleanup()
                self.output(current ? transcript : nil)
                self.complete()
            } else { self.output(transcript) }
        }
    }

    func dispose() {
        self.lock.lock()
        self.disposed = true
        self.cleanup()
        self.lock.unlock()
    }

    private func cleanup() {
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
        self.observer = nil
        self.deadline?.cancel()
        self.deadline = nil
    }
}

/// Never downloads, asks for Apple permission, or falls back to a server.
/// Automatic tries installed chat language then installed app language.
public func recognizeVoskAudio(chatLocale: String?, appLocale: String,
                               makeSource: @escaping () throws -> VoskPCMSource) -> Signal<VoskTranscript?, NoError> {
    Signal { subscriber in
        let configuration = ExteraVoskSettings.shared.configuration
        let cancellation = VoskCancellation(timeout: 180)
        let current = { configuration == ExteraVoskSettings.shared.configuration && configuration.isSelected && configuration.isEnabled && configuration.language != "none" }
        let delivery = VoskRecognitionDelivery(current: current, output: { subscriber.putNext($0) }, complete: { subscriber.putCompletion() })
        delivery.start(cancellation: cancellation)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try cancellation.check()
                guard current() else { throw VoskSpeechError.disabled }
                let installed = Set(VoskModelStore.shared.catalogue().filter(\.isInstalled).map { $0.model.language })
                guard let language = VoskModelCatalogue.resolve(selection: configuration.language, chatLocale: chatLocale, appLocale: appLocale, installed: installed) else { throw VoskSpeechError.notInstalled }
                let lease = try VoskModelStore.shared.lease(language: language)
                defer { withExtendedLifetime(lease) {} }
                try cancellation.check()
                // Set once per native operation under the store's exclusive lease;
                // suppress Kaldi path/model/audio diagnostics in release and debug.
                VoskNativeLogging.disable()
                let source = try makeSource()
                guard source.sampleRate == 16000 else { throw VoskSpeechError.recognitionFailed }
                let recognizer = try VoskRecognizer(path: lease.url.path, sampleRate: source.sampleRate)
                defer { recognizer.close() }
                var phrases: [String] = []
                var audioBytes = 0
                var textBytes = 0
                while true {
                    try cancellation.check()
                    guard current() else { throw VoskSpeechError.cancelled }
                    guard let pcm = try source.next(checkCancellation: cancellation.check) else { break }
                    try cancellation.check()
                    // Bound work even for a custom source that never reaches EOF.
                    guard !pcm.isEmpty, pcm.count <= 128 * 1024 else { throw VoskSpeechError.recognitionFailed }
                    audioBytes += pcm.count
                    guard audioBytes <= 16000 * 2 * 3600 else { throw VoskSpeechError.recognitionFailed }
                    if let text = try recognizer.accept(pcm), !text.isEmpty {
                        textBytes += text.utf8.count
                        guard textBytes <= 1024 * 1024 else { throw VoskSpeechError.recognitionFailed }
                        phrases.append(text)
                        delivery.send(VoskTranscript(text: phrases.joined(separator: " "), isFinal: false), final: false)
                    }
                }
                try cancellation.check()
                let tail = try recognizer.finish()
                guard textBytes + tail.utf8.count <= 1024 * 1024 else { throw VoskSpeechError.recognitionFailed }
                if !tail.isEmpty { phrases.append(tail) }
                guard !phrases.isEmpty, current() else { throw VoskSpeechError.recognitionFailed }
                delivery.send(VoskTranscript(text: phrases.joined(separator: " "), isFinal: true), final: true)
            } catch { delivery.send(nil, final: true) }
        }
        return ActionDisposable {
            cancellation.cancel()
            delivery.dispose()
        }
    }
}
