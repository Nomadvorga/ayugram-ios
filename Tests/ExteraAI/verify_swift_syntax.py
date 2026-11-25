"""Parse production/test AI Swift sources; this does not replace Swift typechecking.

Windows: uv run --with tree-sitter --with tree-sitter-swift python
         Tests/ExteraAI/verify_swift_syntax.py
"""
from pathlib import Path
import sys

import tree_sitter
import tree_sitter_swift

ROOT = Path(__file__).resolve().parents[2]
PARSER = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
FILES = [
    *sorted((ROOT / "Swiftgram/SGSettingsUI/Sources").glob("ExteraAI*.swift")),
    *sorted((ROOT / "Swiftgram/SGSimpleSettings/Sources").glob("ExteraAI*.swift")),
    ROOT / "Tests/ExteraAI/ExteraAIClientTests.swift",
    ROOT / "submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift",
    ROOT / "submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ExteraAISummaryBridge.swift",
    ROOT / "submodules/TelegramUI/Sources/Chat/ChatControllerExteraAI.swift",
    ROOT / "submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift",
]
failed = False
for path in FILES:
    source = path.read_bytes()
    tree = PARSER.parse(source)
    pending = [tree.root_node]
    errors = []
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
