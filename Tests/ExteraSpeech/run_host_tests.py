"""Compile/run exact Foundation production settings, policy and model manager sources.

Apple frameworks and UIKit still require a separate Xcode/iOS build and device run.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    "Swiftgram/SGSimpleSettings/Sources/AyuSettingsStore.swift",
    "Swiftgram/SGSimpleSettings/Sources/ExteraTranslationSettings.swift",
    "Swiftgram/SGSimpleSettings/Sources/ExteraSpeechSettings.swift",
    "submodules/Media/LocalAudioTranscription/Sources/ExteraSpeechPolicy.swift",
    "submodules/Media/LocalAudioTranscription/Sources/ExteraSpeechModelManager.swift",
    "Tests/ExteraSpeech/SpeechTests.swift",
]
STUB = '''import Foundation
// Unique app-group suite; the production settings store itself is copied verbatim.
let APP_GROUP_IDENTIFIER = "org.ayugram.tests.speech." + UUID().uuidString
// Only the unrelated general-settings backend property is stubbed for this host run.
final class SGSimpleSettings: @unchecked Sendable {
    static let shared = SGSimpleSettings()
    enum TranscriptionBackend: String { case apple, telegram }
    var transcriptionBackend = TranscriptionBackend.telegram.rawValue
}
'''


def emit(directory):
    directory.mkdir(parents=True, exist_ok=True)
    paths = []
    for name in SOURCES:
        destination = directory / Path(name).name
        destination.write_bytes((ROOT / name).read_bytes())
        paths.append(destination)
    stub = directory / "HostEnvironment.swift"
    stub.write_text(STUB, encoding="utf-8")
    return [*paths, stub]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emit-only", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    base = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode" if os.name == "nt" else Path(tempfile.gettempdir())
    directory = args.output.resolve() if args.output else Path(tempfile.mkdtemp(prefix="extera-speech-", dir=base))
    paths = emit(directory)
    print(f"Emitted exact production sources and host environment: {directory}", flush=True)
    if args.emit_only:
        print("EMITTED ONLY: Swift tests have not executed.")
        return
    compiler = shutil.which("swiftc")
    if compiler is None:
        raise SystemExit("BLOCKED: swiftc unavailable; use --emit-only to prepare sources for a Swift host.")
    binary = directory / ("SpeechTests.exe" if os.name == "nt" else "SpeechTests")
    subprocess.run([compiler, "-swift-version", "5", "-warnings-as-errors", "-parse-as-library", *map(str, paths), "-o", str(binary)], check=True, timeout=120)
    for mode in ["fresh", "legacy", "disabled"]:
        subprocess.run([str(binary), mode], check=True, timeout=30)


if __name__ == "__main__":
    main()
