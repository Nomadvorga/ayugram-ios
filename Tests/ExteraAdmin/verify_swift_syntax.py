"""Parse quick-admin sources; Swift type checking and XCTest require the host toolchain."""
from pathlib import Path
import sys
import tree_sitter
import tree_sitter_swift

ROOT = Path(__file__).resolve().parents[2]
PARSER = tree_sitter.Parser(tree_sitter.Language(tree_sitter_swift.language()))
FILES = [
    "Swiftgram/SGSimpleSettings/Sources/ExteraAdminSettings.swift",
    "Swiftgram/SGSimpleSettings/Sources/ExteraAdminHeaderPolicy.swift",
    "Swiftgram/SGSimpleSettings/Sources/ExteraAdminShortcutPolicy.swift",
    "submodules/TelegramUI/Sources/ChatControllerExteraAdminShortcuts.swift",
    "submodules/TelegramUI/Sources/ChatControllerExteraAdminHeader.swift",
    "Tests/ExteraAdmin/ExteraAdminSettingsTests.swift",
    "Tests/ExteraAdmin/ExteraAdminShortcutPolicyTests.swift",
    "Tests/ExteraAdmin/ExteraAdminHeaderPolicyTests.swift",
]

failed = False
for relative in FILES:
    source = (ROOT / relative).read_bytes()
    pending = [PARSER.parse(source).root_node]
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
