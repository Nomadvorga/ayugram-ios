"""Tree-sitter Swift parsing only: no Apple API typecheck or executed Swift tests."""
from pathlib import Path
import os
import sys
import tempfile

import tree_sitter
import tree_sitter_swift

from run_host_tests import ROOT, SOURCES, emit

FILES = SOURCES + [
    "submodules/Media/LocalAudioTranscription/Sources/AppleSpeechAssetInventory.swift",
    "submodules/Media/LocalAudioTranscription/Sources/ExteraSpeechRecognition.swift",
    "submodules/Media/LocalAudioTranscription/Sources/LocalAudioTranscription.swift",
    "Swiftgram/SGSettingsUI/Sources/ExteraSpeechRecognitionController.swift",
    "submodules/TelegramUI/Components/Chat/ChatMessageInteractiveFileNode/Sources/ChatMessageInteractiveFileNode.swift",
]
PARSER = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))


def errors(source):
    pending = [PARSER.parse(source).root_node]
    result = []
    while pending:
        node = pending.pop()
        if node.type == "ERROR" or node.is_missing:
            result.append((node.type, node.start_point.row + 1, node.start_point.column + 1))
        pending.extend(reversed(node.children))
    return result


def main():
    failed = False
    for name in FILES:
        found = errors((ROOT / name).read_bytes())
        print(f"{'FAIL' if found else 'PASS'} {name}" + (f": {found}" if found else ""))
        failed |= bool(found)
    base = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode" if os.name == "nt" else None
    with tempfile.TemporaryDirectory(prefix="extera-speech-syntax-", dir=base) as temporary:
        for path in emit(Path(temporary)):
            found = errors(path.read_bytes())
            if found:
                failed = True
                print(f"FAIL emitted {path.name}: {found}")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
