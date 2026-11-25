"""Parse the exact production/test sources; this does not replace Swift typechecking.

Windows: uv run --with tree-sitter --with tree-sitter-swift python
         Tests/ExteraMath/verify_swift_syntax.py
"""
from pathlib import Path
import sys

import tree_sitter
import tree_sitter_swift

ROOT = Path(__file__).resolve().parents[2]
PARSER = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
FILES = [
    *sorted((ROOT / "submodules/TelegramUI/Sources").glob("ExteraMath*.swift")),
    ROOT / "submodules/TelegramUI/Sources/ChatInterfaceInputContextPanels.swift",
    ROOT / "Swiftgram/SGSimpleSettings/Sources/ExteraMathSettings.swift",
    ROOT / "Swiftgram/SGSettingsUI/Sources/ExteraInlineSettingsController.swift",
    ROOT / "Swiftgram/SGMath/Sources/ExteraMathPreferences.swift",
    ROOT / "Tests/ExteraMath/ExteraMathEngineTests.swift",
    ROOT / "Tests/ExteraMath/ExteraMathSettingsTests.swift",
]
failed = False
for path in FILES:
    source = path.read_bytes()
    tree = PARSER.parse(source)
    errors = []
    pending = [tree.root_node]
    while pending:
        node = pending.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append(f"{node.type} at {node.start_point}: {source[node.start_byte:node.end_byte][:120]!r}")
        pending.extend(reversed(node.children))
    print(f"{path.relative_to(ROOT)}: {'FAIL' if errors else 'PASS'}")
    for error in errors:
        print(f"  {error}")
    failed |= bool(errors)
sys.exit(1 if failed else 0)
