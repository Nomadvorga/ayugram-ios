"""Parse exact navigation production/test sources; Swift typechecking remains a macOS CI check."""
from pathlib import Path
import sys
import tree_sitter
import tree_sitter_swift

ROOT = Path(__file__).resolve().parents[2]
PARSER = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
FILES = [
    "Swiftgram/SGSimpleSettings/Sources/ExteraNavigationSettings.swift",
    "Swiftgram/SGSettingsUI/Sources/ExteraNavigationSettingsController.swift",
    "submodules/AccountContext/Sources/AccountContext.swift",
    "submodules/AccountContext/Sources/ExteraNavigationBridge.swift",
    "submodules/TelegramUI/Sources/SharedAccountContextExteraNavigation.swift",
    "submodules/TelegramUI/Sources/TelegramRootController.swift",
    "submodules/TelegramUI/Sources/ExteraRootTabController.swift",
    "submodules/ChatListUI/Sources/ChatListController.swift",
    "submodules/ContactListUI/Sources/ContactsController.swift",
    "submodules/TelegramUI/Components/ChatList/ChatListFilterTabContainerNode/Sources/ChatListFilterTabContainerNode.swift",
    "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift",
    "submodules/TelegramUI/Components/News/NewsScreen/Sources/NewsScreen.swift",
    "submodules/TabBarUI/Sources/TabBarController.swift",
    "submodules/TabBarUI/Sources/TabBarContollerNode.swift",
    "submodules/TelegramUI/Components/TabBarComponent/Sources/TabBarComponent.swift",
    "Tests/ExteraNavigation/ExteraNavigationSettingsTests.swift",
]
failed = False
for relative in FILES:
    source = (ROOT / relative).read_bytes()
    tree = PARSER.parse(source)
    pending = [tree.root_node]
    errors = []
    while pending:
        node = pending.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append(f"{node.type} at {node.start_point}: {source[node.start_byte:node.end_byte][:100]!r}")
        pending.extend(reversed(node.children))
    print(f"{relative}: {'FAIL' if errors else 'PASS'}")
    for error in errors:
        print("  " + error)
    failed |= bool(errors)
sys.exit(int(failed))
