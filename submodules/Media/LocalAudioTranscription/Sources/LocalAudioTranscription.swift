import Foundation
import SGLogging
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
    let identifier = identifier.replacingOccurrences(of: "_", with: "-")
    let supported = SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
    if let exact = supported.first(where: { $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == identifier.lowercased() }) {
        return exact
    }
    // Telegram language packs have a -raw suffix; bare language codes need a real
    // recognizer locale, preferably the same regional variant as the device.
    let code = identifier.hasSuffix("-raw") ? String(identifier.dropLast(4)) : identifier
    let language = Locale(identifier: code).languageCode
    guard let language else {
        return nil
    }
    for preferred in Locale.preferredLanguages + [code] {
        if Locale(identifier: preferred).languageCode == language,
           let match = supported.first(where: { $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == preferred.replacingOccurrences(of: "_", with: "-").lowercased() }) {
            return match
        }
    }
    return supported.first { $0.languageCode == language }
}

/// Transcribe a voice message using the selected Apple speech language, or the app language.
/// Each subscription owns its recognizer, task and temporary file, and can be cancelled
/// while the authorization prompt is visible without starting recognition afterwards.
public func transcribeAudio(path: String, appLocale: String) -> Signal<LocallyTranscribedAudio?, NoError> {
    let settings = ExteraTranslationSettings.shared
    let identifier = settings.appleSpeechLocaleIdentifier.isEmpty ? appLocale : settings.appleSpeechLocaleIdentifier
    let onDeviceOnly = settings.appleSpeechOnDeviceOnly
    return Signal { subscriber in
        let cancelled = Atomic(value: false)
        let disposable = MetaDisposable()
        guard #available(iOS 13.0, *), let locale = transcriptionLocale(identifier) else {
            subscriber.putNext(nil)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        SFSpeechRecognizer.requestAuthorization { status in
            // Preparing a long voice message can involve substantial disk I/O.
            // Each subscription owns its recognizer, so preparation need not block UI.
            Queue.concurrentDefaultQueue().async {
                guard !cancelled.with({ $0 }) else {
                    return
                }
                guard status == .authorized,
                      let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
                      !onDeviceOnly || recognizer.supportsOnDeviceRecognition else {
                    SGLogger.shared.log("LocalTranscription", "Recognition unavailable for \(locale.identifier), authorization: \(status.rawValue)")
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
                do {
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: url)
                } catch {
                    SGLogger.shared.log("LocalTranscription", "Unable to prepare audio for recognition")
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                guard !cancelled.with({ $0 }) else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.taskHint = .dictation
                request.shouldReportPartialResults = true
                request.requiresOnDeviceRecognition = onDeviceOnly
                if #available(iOS 16.0, *) {
                    request.addsPunctuation = true
                }
                let finished = Atomic(value: false)
                let timeoutTimer = SwiftSignalKit.Timer(timeout: 180.0, repeat: false, completion: {
                    guard !finished.swap(true), !cancelled.with({ $0 }) else {
                        return
                    }
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                }, queue: .mainQueue())
                timeoutTimer.start()
                let task = recognizer.recognitionTask(with: request) { result, error in
                    guard !cancelled.with({ $0 }), !finished.with({ $0 }) else {
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
                            subscriber.putCompletion()
                            return
                        }
                    }
                    if error != nil || result?.isFinal == true {
                        _ = finished.swap(true)
                        timeoutTimer.invalidate()
                        SGLogger.shared.log("LocalTranscription", "Recognition ended without a final transcript for \(locale.identifier)")
                        try? FileManager.default.removeItem(at: url)
                        subscriber.putNext(nil)
                        subscriber.putCompletion()
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
            disposable.dispose()
        }
    }
    |> runOn(.concurrentDefaultQueue())
    |> deliverOnMainQueue
}
