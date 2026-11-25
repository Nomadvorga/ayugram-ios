"""Source integration guards. These do not typecheck Apple APIs or run recognition."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "submodules/Media/LocalAudioTranscription/Sources"


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print("PASS " + message)


def main():
    entry = (RUNTIME / "ExteraSpeechRecognition.swift").read_text(encoding="utf-8")
    legacy = (RUNTIME / "LocalAudioTranscription.swift").read_text(encoding="utf-8")
    manager = (RUNTIME / "ExteraSpeechModelManager.swift").read_text(encoding="utf-8")
    adapter = (RUNTIME / "AppleSpeechAssetInventory.swift").read_text(encoding="utf-8")
    ui = (ROOT / "Swiftgram/SGSettingsUI/Sources/ExteraSpeechRecognitionController.swift").read_text(encoding="utf-8")
    consumer = (ROOT / "submodules/TelegramUI/Components/Chat/ChatMessageInteractiveFileNode/Sources/ChatMessageInteractiveFileNode.swift").read_text(encoding="utf-8")
    check(entry.index("return Signal { subscriber in") < entry.index("let configuration =") < entry.index("guard configuration.isEnabled"), "configuration and disabled check occur at subscription")
    check(entry.count("try checkSpeechConfiguration(configuration)") >= 4 and "configuration != ExteraSpeechSettings.shared.configuration { task.cancel() }" in entry, "managed lifecycle rechecks preferences and cancels on change")
    check("configuration == ExteraSpeechSettings.shared.configuration ? result : nil" in entry, "queued main delivery rejects stale configuration")
    check("assetInstallationRequest" not in entry + legacy and "downloadAndInstall" not in entry + legacy, "recognition cannot download managed assets")
    check("manager.acquire" in entry and "manager.relinquish" in entry and "analyzer.cancelAndFinishNow()" in entry and "removeItem(at: temporaryURL)" in entry, "managed recognition owns a lease, analyzer cancellation and temporary file cleanup")
    check("isFinal: false" in entry and entry.index("for try await result") < entry.index("isFinal: true"), "final phrases remain partial until the entire stream finishes")
    check("return withSpeechDeadline(signal)" in entry and "return signal |> timeout(" not in entry, "whole-file deadline survives the first partial value")
    check("request.requiresOnDeviceRecognition = onDeviceOnly" in legacy and "recognizer.supportsOnDeviceRecognition" in legacy, "legacy on-device requirement and support guard retained")
    check("guard ExteraSpeechSettings.shared.isEnabled" in consumer and consumer.index("guard ExteraSpeechSettings.shared.isEnabled") < consumer.index("return convertOpusToAAC"), "consumer rejects disabled before conversion")
    check("SpeechAnalyzer" in entry and "#available(iOS 26.0" in entry and "@available(iOS 26.0" in adapter, "new Apple APIs have iOS 26 guards")
    check("await AssetInventory.release(reservedLocale: locale)" in adapter and "request.progress.cancel()" in adapter and "self.inventory.release(localeIdentifier: locale)" in manager, "release and cancellation invoke real system operations")
    check("sgSpeechRecognitionController" in ui and "manager.install(localeIdentifier:" in ui and "manager.verifyInstalledModel" in ui and "manager.release(localeIdentifier:" in ui, "UI has explicit download, verified selection and actual release actions")
    check(all(token not in entry + legacy + manager + adapter for token in ["SGLogger", "print(", "NSLog", "URLSession", "https://"]), "speech runtime introduces no raw-content logs or independent network service")


if __name__ == "__main__":
    main()
