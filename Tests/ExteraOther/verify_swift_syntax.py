"""Syntax only. Does not replace Swift typecheck/XCTest or simulator frame evaluation."""
from pathlib import Path
import sys
import tree_sitter
import tree_sitter_swift

ROOT = Path(__file__).resolve().parents[2]
PARSER = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
FILES = [
    "AyuGram/SGSimpleSettings/Sources/ExteraOtherSettingsModel.swift",
    "AyuGram/SGSettingsUI/Sources/ExteraOtherSupportContext.swift",
    "AyuGram/SGSettingsUI/Sources/ExteraOtherSettingsController.swift",
    "Tests/ExteraOther/ExteraOtherSettingsModelTests.swift",
]
failed = False
for relative in FILES:
    source = (ROOT / relative).read_bytes()
    tree = PARSER.parse(source)
    errors = []
    pending = [tree.root_node]
    while pending:
        node = pending.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append(f"{node.type} at {node.start_point}")
        pending.extend(reversed(node.children))
    print(f"{relative}: {'FAIL ' + ', '.join(errors) if errors else 'PASS'}")
    failed |= bool(errors)
sys.exit(1 if failed else 0)
