import Foundation
import SGSimpleSettings
import Speech
import SwiftSignalKit

public struct LocallyTranscribedAudio {
    public var text: String
    public var isFinal: Bool
}

/// Locale identifiers supported by Apple's Speech framework on this OS.
/// Availability and on-device model support are checked when recognition starts.
public func supportedTranscriptionLanguages() -> [String] {
    return SFSpeechRecognizer.supportedLocales().map { $0.identifier }.sorted()
}

private func transcriptionLocale(_ identifier: String) -> Locale? {
    guard let identifier = ExteraSpeechLocalePolicy.resolve(identifier, supported: supportedTranscriptionLanguages(), preferred: Locale.preferredLanguages) else { return nil }
    return Locale(identifier: identifier)
}

/// Transcribe a voice message using the selected Apple speech language, or the app language.
/// Each subscription owns its recognizer, task and temporary file, and can be cancelled
/// while the authorization prompt is visible without starting recognition afterwards.
func legacyTranscribeAudio(path: String, appLocale: String, configuration: ExteraSpeechConfiguration) -> Signal<LocallyTranscribedAudio?, NoError> {
    let identifier = configuration.localeIdentifier.isEmpty ? appLocale : configuration.localeIdentifier
    let onDeviceOnly = configuration.onDeviceOnly
    return Signal { subscriber in
        let cancelled = Atomic(value: false)
        let finished = Atomic(value: false)
        let disposable = MetaDisposable()
        let isCurrent = { configuration.isEnabled && configuration == ExteraSpeechSettings.shared.configuration }
        let fail = {
            guard !finished.swap(true), !cancelled.with({ $0 }) else { return }
            disposable.dispose()
            subscriber.putNext(nil)
            subscriber.putCompletion()
        }
        guard #available(iOS 13.0, *), isCurrent(), let locale = transcriptionLocale(identifier) else {
            fail()
            return EmptyDisposable
        }
        let observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { _ in
            if !isCurrent() { fail() }
        }
        guard isCurrent(), !finished.with({ $0 }) else {
            NotificationCenter.default.removeObserver(observer)
            fail()
            return EmptyDisposable
        }
        SFSpeechRecognizer.requestAuthorization { status in
            // Preparing a long voice message can involve substantial disk I/O.
            // Each subscription owns its recognizer, so preparation need not block UI.
            Queue.concurrentDefaultQueue().async {
                guard !cancelled.with({ $0 }), !finished.with({ $0 }), isCurrent() else {
                    fail()
                    return
                }
                guard status == .authorized,
                      let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
                      !onDeviceOnly || recognizer.supportsOnDeviceRecognition else {
                    fail()
                    return
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
                do {
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    fail()
                    return
                }
                guard !cancelled.with({ $0 }), !finished.with({ $0 }), isCurrent() else {
                    try? FileManager.default.removeItem(at: url)
                    fail()
                    return
                }
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.taskHint = .dictation
                request.shouldReportPartialResults = true
                request.requiresOnDeviceRecognition = onDeviceOnly
                if #available(iOS 16.0, *) {
                    request.addsPunctuation = true
                }
                let timeoutTimer = SwiftSignalKit.Timer(timeout: 180.0, repeat: false, completion: {
                    fail()
                }, queue: .mainQueue())
                timeoutTimer.start()
                let task = recognizer.recognitionTask(with: request) { result, error in
                    guard !cancelled.with({ $0 }), !finished.with({ $0 }), isCurrent() else {
                        fail()
                        return
                    }
                    if let result, !result.bestTranscription.formattedString.isEmpty {
                        // Speech results replace the previous hypothesis; appending them
                        // duplicates words and entire sentences in the final transcript.
                        subscriber.putNext(LocallyTranscribedAudio(text: result.bestTranscription.formattedString, isFinal: result.isFinal))
                        if result.isFinal {
                            _ = finished.swap(true)
                            timeoutTimer.invalidate()
                            try? FileManager.default.removeItem(at: url)
                            disposable.dispose()
                            subscriber.putCompletion()
                            return
                        }
                    }
                    if error != nil || result?.isFinal == true {
                        timeoutTimer.invalidate()
                        try? FileManager.default.removeItem(at: url)
                        fail()
                    }
                }
                disposable.set(ActionDisposable {
                    _ = finished.swap(true)
                    timeoutTimer.invalidate()
                    // Retain the recognizer for the duration of its task.
                    withExtendedLifetime(recognizer) {
                        task.cancel()
                    }
                    try? FileManager.default.removeItem(at: url)
                })
            }
        }
        return ActionDisposable {
            _ = cancelled.swap(true)
            NotificationCenter.default.removeObserver(observer)
            disposable.dispose()
        }
    }
    |> runOn(.concurrentDefaultQueue())
    |> deliverOnMainQueue
}
