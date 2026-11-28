"""Parse explicit ghost-read production and test sources (not Swift typechecking)."""
from pathlib import Path
import sys

import tree_sitter
import tree_sitter_swift

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "submodules/TelegramCore"
FILES = [
    CORE / "Sources/Network/AyuGhostRequestFilter.swift",
    CORE / "Sources/Network/AyuExplicitReadQueue.swift",
    CORE / "Sources/Network/AyuExplicitReadOperation.swift",
    CORE / "Sources/Network/ManagedAyuExplicitReadOperations.swift",
    CORE / "Sources/Account/Account.swift",
    CORE / "Sources/Account/AccountManager.swift",
    CORE / "Sources/SyncCore/SyncCore_Namespaces.swift",
    *sorted((CORE / "Tests/AyuExplicitRead").glob("*.swift")),
    ROOT / "AyuGram/SGSettingsUI/Sources/AyuReadHistoryController.swift",
    ROOT / "AyuGram/SGSettingsUI/Sources/ExteraFeedController.swift",
    ROOT / "AyuGram/SGTelegramUIExtensions/Sources/AyuEditHistoryUI.swift",
    ROOT / "submodules/TelegramUI/Sources/Chat/ChatControllerExteraGestures.swift",
    ROOT / "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift",
]
parser = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
failed = False
for path in FILES:
    source = path.read_bytes()
    pending = [parser.parse(source).root_node]
    errors = []
    while pending:
        node = pending.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append(f"{node.type} at {node.start_point}: {source[node.start_byte:node.end_byte][:100]!r}")
        pending.extend(reversed(node.children))
    print(f"{path.relative_to(ROOT)}: {'FAIL' if errors else 'PASS'}")
    for error in errors:
        print(f"  {error}")
    failed |= bool(errors)
sys.exit(1 if failed else 0)
