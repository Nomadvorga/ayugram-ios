"""Run production Swift sources and XCTest suites in a temporary SwiftPM test target."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


MANIFEST = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExteraHostTests",
    platforms: [.macOS(.v10_15)],
    targets: [.testTarget(name: "ExteraHostTests", path: "Tests")],
    swiftLanguageVersions: [.v5]
)
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitize", choices=["thread"])
    parser.add_argument("--warnings-as-errors", action="store_true")
    parser.add_argument("sources", nargs="+", type=Path, help="Production and test Swift files")
    args = parser.parse_args()
    names = set()
    for source in args.sources:
        if not source.is_file() or source.suffix != ".swift":
            parser.error(f"Expected a Swift source file: {source}")
        if source.name in names:
            parser.error(f"Duplicate Swift source filename: {source.name}")
        names.add(source.name)

    swift = ["xcrun", "--sdk", "macosx", "swift"] if sys.platform == "darwin" else ["swift"]
    if not shutil.which(swift[0]):
        parser.error(f"{swift[0]} is unavailable; XCTest requires a Swift host toolchain")
    temporary_root = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode" if sys.platform == "win32" else None
    with tempfile.TemporaryDirectory(prefix="extera-xctests-", dir=temporary_root) as directory:
        package = Path(directory)
        (package / "Package.swift").write_text(MANIFEST, encoding="utf-8")
        tests = package / "Tests"
        tests.mkdir()
        for source in args.sources:
            shutil.copyfile(source, tests / source.name)
        command = [*swift, "test", "--package-path", str(package)]
        if args.sanitize:
            command += ["--sanitize", args.sanitize]
        if args.warnings_as_errors:
            command += ["-Xswiftc", "-warnings-as-errors"]
        return subprocess.run(command).returncode


if __name__ == "__main__":
    raise SystemExit(main())
