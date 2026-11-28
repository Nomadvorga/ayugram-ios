"""Parse production/test AI Swift sources; this does not replace Swift typechecking.

Windows: uv run --with tree-sitter --with tree-sitter-swift python
         Tests/ExteraAI/verify_swift_syntax.py
"""
from pathlib import Path
import subprocess
import sys

import tree_sitter
import tree_sitter_swift

ROOT = Path(__file__).resolve().parents[2]
PARSER = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
FILES = [
    *sorted((ROOT / "AyuGram/SGSettingsUI/Sources").glob("ExteraAI*.swift")),
    *sorted((ROOT / "AyuGram/SGSimpleSettings/Sources").glob("ExteraAI*.swift")),
    ROOT / "Tests/ExteraAI/ExteraAIClientTests.swift",
    ROOT / "submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift",
    ROOT / "submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ExteraAISummaryBridge.swift",
    ROOT / "submodules/TelegramUI/Sources/Chat/ChatControllerExteraAI.swift",
    ROOT / "submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift",
    ROOT / "submodules/TelegramUI/Components/TextProcessingScreen/Sources/TextProcessingScreen.swift",
    ROOT / "submodules/TelegramUI/Components/TextProcessingScreen/Sources/TextProcessingTranslateContentComponent.swift",
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
    # tree-sitter-swift misparses an existing generic cast above this invocation.
    # Pin the exact unchanged diagnostic to HEAD, without editing unrelated UI.
    if path.name == "TextProcessingScreen.swift" and len(errors) == 1:
        baseline = subprocess.check_output(["git", "show", f"HEAD:{path.relative_to(ROOT).as_posix()}"], cwd=ROOT)
        baseline_tree = PARSER.parse(baseline)
        baseline_pending = [baseline_tree.root_node]
        baseline_issues = []
        while baseline_pending:
            node = baseline_pending.pop()
            if node.type == "ERROR" or node.is_missing:
                baseline_issues.append((node.type, node.start_point, baseline.splitlines()[node.start_point.row]))
            baseline_pending.extend(reversed(node.children))
        current_pending = [tree.root_node]
        current_issues = []
        while current_pending:
            node = current_pending.pop()
            if node.type == "ERROR" or node.is_missing:
                current_issues.append((node.type, node.start_point, source.splitlines()[node.start_point.row]))
            current_pending.extend(reversed(node.children))
        if current_issues == baseline_issues and current_issues[0][0] == "!" and current_issues[0][2].strip() == b"playOnce.invoke(())":
            print(f"{path.relative_to(ROOT)}: BASELINE parser diagnostic unchanged from HEAD: {errors[0]}")
            continue
    print(f"{path.relative_to(ROOT)}: {'FAIL' if errors else 'PASS'}")
    for error in errors:
        print(f"  {error}")
    failed |= bool(errors)
sys.exit(1 if failed else 0)
