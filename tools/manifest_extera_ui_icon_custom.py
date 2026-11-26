"""Emit exact owned paths/hashes and localization fallbacks for the custom-pack checkpoint."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/extera-ui-icon-custom-manifest.json"
SOURCES = ROOT / "submodules/TelegramPresentationData/UIIconSources"


def main():
    paths = [
        "Swiftgram/SGSimpleSettings/Sources/ExteraUIIconArchive.swift",
        "Swiftgram/SGSimpleSettings/Sources/ExteraUIIconPackStore.swift",
        "Swiftgram/SGSimpleSettings/Sources/ExteraUIIconVector.swift",
        "Swiftgram/SGSimpleSettings/Sources/ExteraUIIconCatalog.swift",
        "Swiftgram/SGSettingsUI/Sources/ExteraUIIconPackActions.swift",
        "Swiftgram/SGSettingsUI/Sources/ExteraUIIconPackEditorController.swift",
        "Swiftgram/SGSettingsUI/Sources/ExteraUIIconPacksController.swift",
        "submodules/TelegramPresentationData/Sources/ExteraUIIconProvider.swift",
        "submodules/TelegramPresentationData/Sources/ExteraUIIconRendering.swift",
        "submodules/TelegramPresentationData/Sources/ExteraUIIconUpdates.swift",
        "submodules/TelegramPresentationData/Sources/Resources/PresentationResourcesSettings.swift",
        "submodules/TelegramPresentationData/Tests/ExteraUIIconProviderTests.swift",
        "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift",
        "submodules/CallListUI/Sources/CallListController.swift",
        "submodules/ContactListUI/Sources/ContactsController.swift",
        "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift",
        "Tests/ExteraUIIcons/run_host_tests.py",
        "Tests/ExteraUIIcons/ExteraUIIconPackStoreTests.swift",
        "tools/check_extera_ui_icons.py",
        "tools/import_extera_ui_icons.py",
        "tools/manifest_extera_ui_icon_custom.py",
        "tools/generate_extera_ui_icon_catalog.py",
        "docs/extera-ui-icon-custom-handoff.md",
        "docs/integration/extera-ui-icons-chatlist.patch",
    ]
    provenance = json.loads((SOURCES / "provenance.json").read_text())
    paths.append(str((SOURCES / "provenance.json").relative_to(ROOT)).replace("\\", "/"))
    for record in provenance["records"]:
        paths.append(str((SOURCES / record["source"]).relative_to(ROOT)).replace("\\", "/"))
        for filename in record["generated"]:
            paths.append(f'submodules/TelegramUI/Images.xcassets/{record["asset"]}.imageset/{filename}')
    strings = {}
    literal = r'"((?:[^"\\]|\\.)*)"'
    for name in paths:
        if name.startswith("Swiftgram/SGSettingsUI/"):
            source = (ROOT / name).read_text(encoding="utf-8")
            for key, en, ru in re.findall(r'\btext\(' + literal + r',\s*' + literal + r',\s*' + literal + r'\)', source):
                strings["Extera.UIIcons." + key] = {"en": en, "ru": ru}
    result = {
        "schemaVersion": 1,
        "status": "source checkpoint; host-tested; iOS build and recorded frames pending",
        "files": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in sorted(set(paths))},
        "sharedFileHunksOnly": {"submodules/ChatListUI/Sources/ChatListController.swift": "docs/integration/extera-ui-icons-chatlist.patch"},
        "strings": dict(sorted(strings.items())),
        "rootOwnedExcluded": ["SGSettingsController.swift", "en/ru catalogs", "backup implementation", "BUILD", "workflows", "ExteraDoubleTapActionPicker.swift"],
    }
    OUTPUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(result['files'])} owned file hashes and {len(strings)} localization keys; ChatList is hunk-only.")


if __name__ == "__main__":
    main()
