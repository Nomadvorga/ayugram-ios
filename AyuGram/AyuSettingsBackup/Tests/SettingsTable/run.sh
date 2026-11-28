#!/bin/sh
# Host check of the real settings table (AyuExteraBackupTable.swift) and the real settings classes against
# throwaway UserDefaults domains. Run from the repository root: sh AyuGram/AyuSettingsBackup/Tests/SettingsTable/run.sh
set -e
out="${TMPDIR:-/tmp}/ayu-backup-table"
tests=AyuGram/AyuSettingsBackup/Tests/SettingsTable
settings=AyuGram/SGSimpleSettings/Sources
mkdir -p "$out"
swiftc -emit-module -emit-library -module-name AyuSettingsBackup -emit-module-path "$out/AyuSettingsBackup.swiftmodule" -o "$out/libAyuSettingsBackup.dylib" AyuGram/AyuSettingsBackup/Sources/*.swift
for stub in SGAppGroupIdentifier SGLogging UIKit; do
    swiftc -emit-module -emit-library -module-name "$stub" -emit-module-path "$out/$stub.swiftmodule" -o "$out/lib$stub.dylib" "$tests/Stubs/$stub.swift"
done
# The name of the binary is the name of its standard UserDefaults domain.
swiftc -I "$out" -L "$out" -lAyuSettingsBackup -lSGAppGroupIdentifier -lSGLogging -lUIKit -o "$out/ayu-backup-table-test" "$tests"/*.swift \
    "$settings/SimpleSettings.swift" "$settings/UserDefaultsWrapper.swift" "$settings/AtomicWrapper.swift" "$settings/RWLock.swift" \
    "$settings/AyuSettingsStore.swift" "$settings/ExteraSettings.swift" "$settings/AyuExteraBackupTable.swift" \
    "$settings/AyuGhostSettings.swift" "$settings/AyuSaveSettings.swift" "$settings/AyuSendConfirmations.swift" "$settings/AyuCustomizationSettings.swift" \
    "$settings/ExteraChatSettings.swift" "$settings/ExteraMediaSettings.swift" "$settings/ExteraMessageSettings.swift" "$settings/ExteraMathSettings.swift" \
    "$settings/ExteraMenuSettings.swift" "$settings/ExteraStickerSettings.swift" "$settings/ExteraGeneralSettings.swift" "$settings/ExteraZalgoFilter.swift" \
    "$settings/ExteraBrowserSettings.swift" "$settings/ExteraAISettings.swift"
status=0
DYLD_LIBRARY_PATH="$out" "$out/ayu-backup-table-test" || status=$?
# The test empties both domains; this removes the empty files they leave in ~/Library/Preferences.
for domain in ayu-backup-table-test ayu.backup.host.test; do
    rm -f "$HOME/Library/Preferences/$domain.plist"
done
exit $status
