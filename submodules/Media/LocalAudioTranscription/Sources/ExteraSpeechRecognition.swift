import AVFoundation
import Foundation
import SGSimpleSettings
import Speech
import SwiftSignalKit

/// Resolve preferences at subscription time, not when a signal is constructed before
/// resource conversion/authorization. A disabled or missing managed model never falls
/// back to network recognition. Existing legacy Apple flags keep their old defaults.
public func transcribeAudio(path: String, appLocale: String) -> Signal<LocallyTranscribedAudio?, NoError> {
    return Signal { subscriber in
        let configuration = ExteraSpeechSettings.shared.configuration
        guard configuration.isEnabled else {
            subscriber.putNext(nil)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        let signal: Signal<LocallyTranscribedAudio?, NoError>
        if configuration.useManagedOfflineModel {
            if #available(iOS 26.0, macOS 26.0, *) {
                signal = managedTranscribeAudio(path: path, configuration: configuration)
            } else {
                signal = .single(nil)
            }
        } else {
            signal = legacyTranscribeAudio(path: path, appLocale: appLocale, configuration: configuration)
        }
        return (signal |> deliverOnMainQueue).start(next: { result in
            // Also reject a result already queued for main delivery when settings changed.
            subscriber.putNext(configuration == ExteraSpeechSettings.shared.configuration ? result : nil)
        }, completed: {
            subscriber.putCompletion()
        })
    }
}

@available(iOS 26.0, macOS 26.0, *)
private func managedTranscribeAudio(path: String, configuration: ExteraSpeechConfiguration) -> Signal<LocallyTranscribedAudio?, NoError> {
    let signal: Signal<LocallyTranscribedAudio?, NoError> = Signal { subscriber in
        let cancelled = Atomic(value: false)
        let task = Task {
            let manager = ExteraSpeechModelManager.shared
            var lease: UUID?
            var temporaryURL: URL?
            do {
                try checkSpeechConfiguration(configuration)
                // This only checks installed assets + reservations; it cannot download.
                let (token, identifier) = try await manager.acquire(localeIdentifier: configuration.localeIdentifier)
                lease = token
                try checkSpeechConfiguration(configuration)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
                temporaryURL = url
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
                let audioFile = try AVAudioFile(forReading: url)
                let transcriber = SpeechTranscriber(locale: Locale(identifier: identifier), preset: .transcription)
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                do {
                    try await withTaskCancellationHandler(operation: {
                        try checkSpeechConfiguration(configuration)
                        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
                        var transcript = ExteraSpeechTranscript()
                        for try await result in transcriber.results {
                            try checkSpeechConfiguration(configuration)
                            transcript.update(start: CMTimeGetSeconds(result.range.start), end: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)), text: String(result.text.characters))
                            if !transcript.text.isEmpty && !cancelled.with({ $0 }) {
                                // A final phrase is not a final whole-file transcript.
                                subscriber.putNext(LocallyTranscribedAudio(text: transcript.text, isFinal: false))
                            }
                        }
                        try checkSpeechConfiguration(configuration)
                        if !cancelled.with({ $0 }) {
                            subscriber.putNext(transcript.text.isEmpty ? nil : LocallyTranscribedAudio(text: transcript.text, isFinal: true))
                        }
                    }, onCancel: {
                        Task { await analyzer.cancelAndFinishNow() }
                    })
                } catch {
                    await analyzer.cancelAndFinishNow()
                    throw error
                }
            } catch {
                // Do not log audio, transcripts, paths or underlying framework errors.
                if !cancelled.with({ $0 }) { subscriber.putNext(nil) }
            }
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            if let lease { await manager.relinquish(lease) }
            if !cancelled.with({ $0 }) { subscriber.putCompletion() }
        }
        let observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { _ in
            if configuration != ExteraSpeechSettings.shared.configuration { task.cancel() }
        }
        // Close the interval between the task's initial check and observer registration.
        if configuration != ExteraSpeechSettings.shared.configuration { task.cancel() }
        return ActionDisposable {
            _ = cancelled.swap(true)
            NotificationCenter.default.removeObserver(observer)
            task.cancel()
        }
    }
    // Disposal cancels analysis and releases the lease/temp file even on a stalled stream.
    return withSpeechDeadline(signal)
}

/// SwiftSignalKit.timeout stops its timer at the first value. Phrase results must
/// not disable the whole-file deadline, so keep this timer until actual completion.
private func withSpeechDeadline(_ signal: Signal<LocallyTranscribedAudio?, NoError>) -> Signal<LocallyTranscribedAudio?, NoError> {
    return Signal { subscriber in
        let finished = Atomic(value: false)
        let disposable = MetaDisposable()
        let timer = SwiftSignalKit.Timer(timeout: 180.0, repeat: false, completion: {
            guard !finished.swap(true) else { return }
            disposable.dispose()
            subscriber.putNext(nil)
            subscriber.putCompletion()
        }, queue: .mainQueue())
        timer.start()
        disposable.set(signal.start(next: { result in
            if !finished.with({ $0 }) { subscriber.putNext(result) }
        }, completed: {
            guard !finished.swap(true) else { return }
            timer.invalidate()
            subscriber.putCompletion()
        }))
        return ActionDisposable {
            _ = finished.swap(true)
            timer.invalidate()
            disposable.dispose()
        }
    }
}

private func checkSpeechConfiguration(_ configuration: ExteraSpeechConfiguration) throws {
    try Task.checkCancellation()
    guard configuration.isEnabled, configuration == ExteraSpeechSettings.shared.configuration else { throw CancellationError() }
}
