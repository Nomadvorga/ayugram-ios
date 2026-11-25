"""Syntax only; run Swift host tests and the full iOS build on Mac before acceptance."""
from pathlib import Path
import sys
import tree_sitter
import tree_sitter_swift

root = Path(__file__).resolve().parents[2]
parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
files = [
    *sorted((root / "Swiftgram/SGSimpleSettings/Sources").glob("ExteraPill*.swift")),
    *sorted((root / "Swiftgram/SGSettingsUI/Sources").glob("ExteraPill*.swift")),
    *sorted((root / "submodules/ChatListUI/Sources").glob("ExteraPill*.swift")),
    root / "submodules/ChatListUI/Sources/ChatListController.swift",
    root / "submodules/ChatListUI/Sources/ChatListControllerNode.swift",
    root / "Tests/ExteraPills/ExteraPillHostTests.swift",
]
failed = False
for path in files:
    source = path.read_bytes()
    tree = parser.parse(source)
    errors = []
    pending = [tree.root_node]
    while pending:
        node = pending.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append(f"{node.type} at {node.start_point}: {source[node.start_byte:node.end_byte][:100]!r}")
        pending.extend(reversed(node.children))
    print(f"{path.relative_to(root)}: {'FAIL' if errors else 'PASS'}")
    for error in errors:
        print(f"  {error}")
    failed |= bool(errors)
sys.exit(1 if failed else 0)
