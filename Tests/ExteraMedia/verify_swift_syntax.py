"""Windows tree-sitter check; explicitly distinguishes the two baseline Neo grammar errors.

This parses Swift syntax only. It does not typecheck APIs or execute model tests.
"""
from pathlib import Path
import subprocess
import sys

import tree_sitter
import tree_sitter_swift

from run_model_tests import emit

ROOT = Path(__file__).resolve().parents[2]
PARSER = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
NEO = "submodules/Camera/CameraNeo/Sources/CameraNeo.swift"
FILES = [
    "AyuGram/SGSimpleSettings/Sources/ExteraMediaSettings.swift",
    "submodules/Camera/Sources/CameraZoom.swift",
    "submodules/Camera/Sources/Camera.swift",
    "submodules/Camera/CameraLegacy/Sources/CameraDevice.swift",
    "submodules/Camera/CameraLegacy/Sources/LegacyCamera.swift",
    NEO,
    "submodules/TelegramUI/Components/VideoMessageCameraScreen/Sources/VideoMessageCameraScreen.swift",
    "submodules/GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift",
    "Tests/ExteraMedia/MediaModelTests.swift",
]


def errors(source):
    pending = [PARSER.parse(source).root_node]
    result = []
    while pending:
        node = pending.pop()
        if node.type == "ERROR" or node.is_missing:
            result.append((node.type, node.start_point.row, node.start_point.column))
        pending.extend(reversed(node.children))
    return result


def main():
    failed = False
    for name in FILES:
        source = (ROOT / name).read_bytes()
        found = errors(source)
        if name == NEO:
            baseline = subprocess.check_output(["git", "show", f"HEAD:{NEO}"], cwd=ROOT)
            expected = [("!", 106, 73), ("!", 107, 69)]
            if found == expected and errors(baseline) == expected:
                # Verify the complete file too, replacing only the grammar's known
                # Void-literal problem in memory. Production remains untouched.
                found = errors(source.replace(b"value: ()", b"value: Void()"))
                print("BASELINE: Neo has the same two Void-literal grammar errors as HEAD")
        if found:
            failed = True
            print(f"FAIL {name}: {found}")
        else:
            print(f"PASS {name}")
    # Also parse the emitted policy wrapper, to catch extraction/harness mistakes.
    import tempfile
    with tempfile.TemporaryDirectory(prefix="extera-media-syntax-") as temporary:
        for path in emit(Path(temporary)):
            found = errors(path.read_bytes())
            if found:
                failed = True
                print(f"FAIL emitted {path.name}: {found}")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
