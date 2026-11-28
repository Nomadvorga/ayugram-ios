"""Emit/execute a Foundation-only harness using exact production Swift model sources."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ZOOM = ROOT / "submodules/Camera/Sources/CameraZoom.swift"
SETTINGS = ROOT / "AyuGram/SGSimpleSettings/Sources/ExteraMediaSettings.swift"
TESTS = Path(__file__).with_name("MediaModelTests.swift")


def emit(directory):
    directory.mkdir(parents=True, exist_ok=True)
    # Extract the method verbatim; a replacement policy or fake settings store would
    # allow tests to pass while the production predicate differs.
    source = SETTINGS.read_text(encoding="utf-8")
    start = source.index("    public static func shouldUnmuteVideo(")
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    policy = "import Foundation\npublic enum ExteraMediaSettings {\n" + source[start:end] + "\n}\n"
    paths = [directory / "CameraZoom.swift", directory / "VolumePolicy.swift", directory / "MediaModelTests.swift"]
    paths[0].write_bytes(ZOOM.read_bytes())
    paths[1].write_text(policy, encoding="utf-8")
    paths[2].write_bytes(TESTS.read_bytes())
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--emit-only", action="store_true", help="Prepare sources without claiming an executed test run")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.output:
        directory = args.output.resolve()
    else:
        base = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode" if os.name == "nt" else Path(tempfile.gettempdir())
        base.mkdir(parents=True, exist_ok=True)
        directory = Path(tempfile.mkdtemp(prefix="extera-media-", dir=base))
    paths = emit(directory)
    print(f"Emitted exact production model + policy and tests: {directory}", flush=True)
    if args.emit_only:
        print("EMITTED ONLY: Swift assertions have not executed.")
        return
    compiler = shutil.which("swiftc")
    if compiler is None:
        raise SystemExit("BLOCKED: swiftc is unavailable; use --emit-only to prepare a Mac/Swift host run.")
    binary = directory / ("MediaModelTests.exe" if os.name == "nt" else "MediaModelTests")
    subprocess.run([compiler, "-warnings-as-errors", *map(str, paths), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
