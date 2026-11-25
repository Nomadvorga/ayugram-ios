"""Run the production icon selection model and its existing XCTest suite on a Swift host.

The test's app-module import is removed because the verbatim production source is
compiled directly into the temporary host target. Only unrelated application bindings
are supplied; no persistence/normalization logic is replaced.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    repo = Path(__file__).resolve().parents[2]
    temporary_root = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode" if sys.platform == "win32" else None
    with tempfile.TemporaryDirectory(prefix="extera-ui-icons-tests-", dir=temporary_root) as directory:
        output = Path(directory)
        bindings = output / "ApplicationBindings.swift"
        bindings.write_text('''import Foundation
let APP_GROUP_IDENTIFIER = "ExteraUIIconHostTests." + UUID().uuidString
let ayuSettingsDidChangeNotification = Notification.Name("ExteraUIIconHostSettingsChanged")
enum SGSimpleSettings { static let shared = 0 }
''', encoding="utf-8")
        test = output / "ExteraUIIconSettingsTests.swift"
        source = repo / "Swiftgram/SGSimpleSettings/Tests/ExteraUIIconSettingsTests.swift"
        test.write_text(source.read_text(encoding="utf-8").replace("import SGSimpleSettings\n", ""), encoding="utf-8")
        return subprocess.run([
            sys.executable, str(repo / "tools/run_extera_xctests.py"), "--warnings-as-errors",
            str(repo / "Swiftgram/SGSimpleSettings/Sources/ExteraUIIconSettings.swift"),
            str(bindings), str(test),
        ], cwd=repo).returncode


if __name__ == "__main__":
    raise SystemExit(main())
