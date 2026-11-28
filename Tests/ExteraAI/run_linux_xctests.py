"""Run the AI XCTest source projection with Swift on Linux/WSL.

This is a secondary host check, not a replacement for the macOS runner in
tools/run_extera_xctests.py. Linux has no Apple Security framework, so the
temporary projection replaces only the production import with compile-time
Keychain bindings that always report errSecNotAvailable. No Keychain test is
claimed by this runner; configuration, Codable, request construction and
URLProtocol-backed transport tests still execute against the unchanged
production declarations.

Example from WSL (after a Swift 6.1 toolchain is available):

    python3 Tests/ExteraAI/run_linux_xctests.py --warnings-as-errors
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    ROOT / "AyuGram/SGSimpleSettings/Sources/AyuSettingsStore.swift",
    ROOT / "AyuGram/SGSimpleSettings/Sources/ExteraAISettings.swift",
    ROOT / "AyuGram/SGSimpleSettings/Sources/ExteraAIClient.swift",
    ROOT / "Tests/ExteraAI/ExteraAIClientTests.swift",
]

MANIFEST = """// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExteraLinuxHostTests",
    targets: [.testTarget(name: "ExteraLinuxHostTests", path: "Tests")],
    swiftLanguageModes: [.v5]
)
"""

SECURITY_PROJECTION = """
// Linux host-test projection only. This is not production behavior.
// Linux Foundation does not bridge [String: Any] to CoreFoundation's
// CFDictionary the way Apple Foundation does, so the projection aliases the
// unavailable Security parameter types to the exact native dictionary shape.
typealias CFDictionary = [String: Any]
typealias CFTypeRef = Any

typealias OSStatus = Int32
let errSecSuccess: OSStatus = 0
let errSecItemNotFound: OSStatus = -25300
let errSecNotAvailable: OSStatus = -25291
let kSecClass = "class"
let kSecClassGenericPassword = "generic-password"
let kSecAttrService = "service"
let kSecAttrAccount = "account"
let kSecReturnData = "return-data"
let kSecMatchLimit = "match-limit"
let kSecMatchLimitOne = "one"
let kSecValueData = "value-data"
let kSecAttrAccessible = "accessible"
let kSecAttrAccessibleWhenUnlockedThisDeviceOnly = "when-unlocked-this-device-only"

func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    return errSecNotAvailable
}

func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    return errSecNotAvailable
}

func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    return errSecNotAvailable
}

func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    return errSecNotAvailable
}
"""


def projected_settings(source: str) -> str:
    import_line = "import Security\n"
    if source.count(import_line) != 1:
        raise RuntimeError("ExteraAISettings.swift must contain exactly one Security import")
    return source.replace(import_line, SECURITY_PROJECTION + "\n", 1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift", help="Swift executable or path")
    parser.add_argument("--warnings-as-errors", action="store_true")
    args = parser.parse_args()

    if sys.platform != "linux":
        parser.error("run this support runner inside Linux/WSL; macOS uses tools/run_extera_xctests.py")
    for source in SOURCES:
        if not source.is_file():
            parser.error(f"missing Swift source: {source}")
    swift = shutil.which(args.swift) or args.swift
    if not Path(swift).exists() and shutil.which(swift) is None:
        parser.error(f"Swift is unavailable: {args.swift}")
    temporary_root = Path(os.environ["TMPDIR"]) if os.environ.get("TMPDIR") else None
    with tempfile.TemporaryDirectory(prefix="extera-linux-xctests-", dir=temporary_root) as directory:
        package = Path(directory)
        (package / "Package.swift").write_text(MANIFEST, encoding="utf-8")
        tests = package / "Tests"
        tests.mkdir()
        for source in SOURCES:
            destination = tests / source.name
            text = source.read_text(encoding="utf-8")
            if source.name == "ExteraAISettings.swift":
                text = projected_settings(text)
            destination.write_text(text, encoding="utf-8", newline="\n")
        command = [swift, "test", "--package-path", str(package)]
        if args.warnings_as_errors:
            command += ["-Xswiftc", "-warnings-as-errors"]
        print("Linux projection: Security/Keychain tests unsupported; all other XCTest cases run against projected production sources.", flush=True)
        print("Swift command: " + " ".join(command), flush=True)
        return subprocess.run(command).returncode


if __name__ == "__main__":
    raise SystemExit(main())
