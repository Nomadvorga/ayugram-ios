#!/usr/bin/env python3
"""Type-check the AyuPluginBridge Swift module against the iOS SDK with swiftc.

This is not a build: no Bazel, no linking, no app or IPA. It emits the three small
Swift dependency modules into a temporary directory, exposes the Objective-C runtime
header through a generated module map and compiles the module to an unlinked object
file with the same `-warnings-as-errors` flag the Bazel target uses. `--tests` also
compiles `Tests/Swift` against the module. Nothing is executed.

Run from anywhere on a Mac with full Xcode (xcode-select does not have to point at it):
    python3 -B submodules/AyuPluginBridge/Build/typecheck_swift.py [--tests]
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BRIDGE = Path(__file__).resolve().parents[1]
SUBMODULES = BRIDGE.parent
TARGET = "arm64-apple-ios15.0"
DEPENDENCIES = ("AyuAtmosphericHost", "AyuAtmosphericSnow", "AyuDialogCards")


def developer_dir() -> Path:
    candidates = []
    if os.environ.get("DEVELOPER_DIR"):
        candidates.append(Path(os.environ["DEVELOPER_DIR"]))
    candidates += sorted(Path("/Applications").glob("Xcode*.app/Contents/Developer"))
    for candidate in candidates:
        if (candidate / "Platforms" / "iPhoneOS.platform").is_dir():
            return candidate
    raise SystemExit("No Xcode with the iPhoneOS platform found; set DEVELOPER_DIR.")


def run(developer: Path, arguments: list[str]) -> subprocess.CompletedProcess:
    environment = dict(os.environ, DEVELOPER_DIR=str(developer))
    return subprocess.run(["xcrun", *arguments], env=environment, text=True, capture_output=True)


def swift_sources(*directories: Path) -> list[str]:
    return [str(path) for directory in directories for path in sorted(directory.rglob("*.swift"))]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tests", action="store_true", help="also type-check Tests/Swift")
    options = parser.parse_args()

    developer = developer_dir()
    sdk = run(developer, ["--sdk", "iphoneos", "--show-sdk-path"]).stdout.strip()
    platform = developer / "Platforms" / "iPhoneOS.platform" / "Developer"
    common = ["-sdk", sdk, "-target", TARGET, "-parse-as-library", "-swift-version", "5"]
    failed = False

    def report(label: str, result: subprocess.CompletedProcess) -> bool:
        output = (result.stdout + result.stderr).strip()
        if output:
            print(output)
        print(f"{label}: {'ok' if result.returncode == 0 else 'FAILED'}")
        return result.returncode == 0

    with tempfile.TemporaryDirectory(prefix="apb-typecheck-") as scratch:
        modules = Path(scratch) / "modules"
        modules.mkdir()
        clang = Path(scratch) / "AyuPluginPython"
        clang.mkdir()
        header = BRIDGE / "PublicHeaders" / "AyuPluginPython" / "APBPythonRuntime.h"
        (clang / "module.modulemap").write_text(
            f'module AyuPluginPython {{\n    header "{header}"\n    export *\n}}\n', encoding="utf-8")
        search = ["-I", str(modules), "-I", str(clang)]

        for name in DEPENDENCIES:
            result = run(developer, [
                "swiftc", "-emit-module", "-module-name", name, *common, "-warnings-as-errors",
                "-emit-module-path", str(modules / f"{name}.swiftmodule"),
                *swift_sources(SUBMODULES / name / "Sources"),
            ])
            if not report(name, result):
                return 1

        # Compiling to an object file (never linked) also runs the SIL diagnostics that
        # `-typecheck` skips: definite initialization, exclusivity, closure captures.
        bridge_sources = swift_sources(BRIDGE / "Sources", BRIDGE / "Integration")
        result = run(developer, [
            "swiftc", "-emit-module", "-emit-object", "-wmo", "-Onone", "-enable-testing",
            "-continue-building-after-errors", "-module-name", "AyuPluginBridge",
            *common, "-warnings-as-errors", *search,
            "-emit-module-path", str(modules / "AyuPluginBridge.swiftmodule"),
            "-o", str(Path(scratch) / "AyuPluginBridge.o"), *bridge_sources,
        ])
        failed = not report("AyuPluginBridge", result)

        if options.tests and not failed:
            result = run(developer, [
                "swiftc", "-emit-object", "-wmo", "-Onone", "-continue-building-after-errors",
                "-module-name", "AyuPluginBridgeTestsLib",
                *common, *search, "-F", str(platform / "Library" / "Frameworks"),
                "-I", str(platform / "usr" / "lib"),
                "-o", str(Path(scratch) / "AyuPluginBridgeTestsLib.o"),
                *swift_sources(BRIDGE / "Tests" / "Swift"),
            ])
            failed = not report("Tests/Swift", result)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
