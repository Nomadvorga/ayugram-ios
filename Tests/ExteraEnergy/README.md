# Energy policy checks

The eleven XCTest cases compile the unchanged production store and energy model in
an isolated app-group defaults suite. They cover the exact 2/3/7 inventory, all 128
chat child combinations, atomic group notifications, persistence, independent emoji
surfaces, threshold boundaries and invalid battery readings, Follow System, native
upper bounds, Low Power Mode at Never, accessibility, and preservation of choices.

```sh
python3 tools/run_extera_xctests.py --warnings-as-errors \
  Swiftgram/SGSimpleSettings/Sources/AyuSettingsStore.swift \
  Swiftgram/SGSimpleSettings/Sources/ExteraEnergySettings.swift \
  Tests/ExteraEnergy/ExteraEnergySettingsTests.swift
```

Runtime UIKit consumers require the full iOS build and simulator/device acceptance.
The expected recordings, inventory and root integration contract are documented in
[`docs/extera-energy-settings.md`](../../docs/extera-energy-settings.md).
Tree-sitter parsing is a syntax check; it does not establish Swift type correctness.
