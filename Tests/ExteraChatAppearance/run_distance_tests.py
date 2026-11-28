"""Test the unchanged production Geo.swift with macOS MapKit and isolated settings."""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid


MANIFEST = '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ExteraDistanceTests",
    platforms: [.macOS(.v10_15)],
    targets: [
        .target(name: "SGSimpleSettings"),
        .target(name: "TelegramPresentationData"),
        .target(name: "TelegramStringFormatting", dependencies: ["SGSimpleSettings", "TelegramPresentationData"]),
        .testTarget(name: "DistanceTests", dependencies: ["SGSimpleSettings", "TelegramPresentationData", "TelegramStringFormatting"])
    ],
    swiftLanguageVersions: [.v5]
)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitize", choices=["thread"])
    args = parser.parse_args()
    if sys.platform != "darwin" or not shutil.which("xcrun"):
        parser.error("macOS with Xcode is required for the real MapKit formatter tests")
    root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory(prefix="extera-distance-tests-") as directory:
        package = Path(directory)
        (package / "Package.swift").write_text(MANIFEST, encoding="utf-8")
        settings = package / "Sources/SGSimpleSettings"
        presentation = package / "Sources/TelegramPresentationData"
        formatting = package / "Sources/TelegramStringFormatting"
        tests = package / "Tests/DistanceTests"
        for destination in [settings, presentation, formatting, tests]:
            destination.mkdir(parents=True)
        for filename in ["AyuSettingsStore.swift", "ExteraChatAppearanceSettings.swift"]:
            shutil.copyfile(root / "AyuGram/SGSimpleSettings/Sources" / filename, settings / filename)
        (settings / "AppGroup.swift").write_text(
            f'public let APP_GROUP_IDENTIFIER = "ExteraDistanceTests.{uuid.uuid4()}"\n', encoding="utf-8"
        )
        # The actual PresentationStrings requires the app's generated resource bundle.
        # Geo/Locale only read this language code; all distance behavior stays in production code.
        (presentation / "PresentationStrings.swift").write_text(
            'public struct PresentationStrings {\n'
            '    public let baseLanguageCode: String\n'
            '    public init(baseLanguageCode: String) { self.baseLanguageCode = baseLanguageCode }\n'
            '}\n', encoding="utf-8"
        )
        for filename in ["Geo.swift", "Locale.swift"]:
            shutil.copyfile(root / "submodules/TelegramStringFormatting/Sources" / filename, formatting / filename)
        shutil.copyfile(Path(__file__).with_name("DistanceFormattingTests.swift"), tests / "DistanceFormattingTests.swift")
        command = ["xcrun", "--sdk", "macosx", "swift", "test", "--package-path", str(package), "-Xswiftc", "-warnings-as-errors"]
        if args.sanitize:
            command += ["--sanitize", args.sanitize]
        return subprocess.run(command).returncode


if __name__ == "__main__":
    raise SystemExit(main())
