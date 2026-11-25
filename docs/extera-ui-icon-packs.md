# UI icon packs: implementation and root handoff

2026-11-25. This is the separate interface-glyph feature. Accepted app icons, overview images, AppDelegate, Telegram/BUILD, root-owned settings controllers, localization, backup and workflows were not edited by this change. No commit or push was performed.

## References and Android inventory

Read the full 87-state matrix and audit entries, then opened original frames 18, 21 and 30. Frame **18** shows the entry “Наборы иконок / Настройка иконок во всём приложении”. Frame **21** is sections and blur; it does not show an icon picker. Frame **30** is the actual picker: three base-pack rows, four-icon previews, author labels, Solar selected, explanatory footer and a custom-pack add button. Selection on that screenshot is not a default.

`InterfacePreferencesActivity` and `IconsPicker` do not exist by those names in this cached APK/current upstream tree. Their relevant current implementations are `preferences/appearance/AppearancePreferencesActivity`, `icons/ui/IconPacksActivity`, `icons/BaseIconPacks`, `icons/IconManager` and `icons/ui/components/IconPackPreviewView`.

| Pack ID | Visible name | Author | Android replacement entries | Pack-specific artwork entries | Unique pack vectors |
|---|---|---|---:|---:|---:|
| `base.default` | localized Default | Telegram | 3 popup-background remaps | 0 | 0 |
| `base.solar` | Solar Icon Set | @Design480 | 631 | 628 | 496 |
| `base.remix` | Remix Icon | Remix-Design | 634 | 631 | 497 |

Solar/Remix totals include three common `popup_fixed_alert* → popup_fixed_alert4` mappings, which are Android surfaces rather than iOS glyphs. Complete maps are in `submodules/TelegramPresentationData/UIIconSources/android-inventory.json`, backed by the preserved `BaseIconPacks.kt` and a hash of APK `BaseIconPacks.java`. Only 37 semantic roles per pack (74 original XMLs, 222 PNGs) are imported for the current iOS consumers; this is not a claim of app-wide coverage of all Android drawables.

Android's current picker immediately replaces the base entry in `ExteraConfig.iconPacksLayout`, saves it and calls `IconManager.initialize(true)` (`IconPacksActivity.java:221–249`). It separately stores custom-pack order and hidden packs, handles archive import/export/editor flows and layered overrides. iOS currently implements the three built-in base choices only. Custom-pack add/import/edit/export and override layering are open functionality, not declared incompatible with iOS.

## Model and provider API

`ExteraUIIconPack` in `SGSimpleSettings` has stable IDs `base.default`, `base.solar`, `base.remix`. `normalized(_:)` maps missing/unknown values to native. `ExteraUIIconSettings(defaults:)` permits isolated storage tests; `.shared.pack` reads app-group preferences, and `.select(_:)` writes `extera.uiIcons.basePack`. A changed selection posts `ExteraUIIconSettings.didChange` and the existing `ayuSettingsDidChangeNotification`. It does not change alternate app-icon state. Default is native iOS artwork.

`TelegramPresentationData.ExteraUIIconProvider` is an Equatable **value** containing the pack selection. Its public API:

```swift
let provider = ExteraUIIconProvider(pack: ExteraUIIconSettings.shared.pack)
provider.assetName(for: .copy) // nil for native
provider.image(for: .copy, fallback: originalImage)
provider.navigationImage(id: "savedMessages", fallback: originalImage)
```

`.current` is a convenience for host consumers; a renderer should receive the provider snapshot explicitly from its controller, then call `image(for:fallback:)`. The renderer does not need to import SGSimpleSettings or read persisted preferences. Missing resources return the caller's native fallback unchanged. Converted resources are template images; callers retain control over theme/destructive tint. No theme-image cache stores pack results.

37 roles: settings, contacts, calls, chats, archive, saved, groups, channel, profile, ghost, wallet, browser, qrCode, notifications, privacy, data, devices, folders, appearance, language, stickers, bots, copy, forward, reply, delete, edit, select, report, pin, unpin, link, photo, info, search, add, menu. The single authoritative role-to-Android-resource switch is in `ExteraUIIconProvider.swift`; the importer and checker consume it.

## Consumers and root integration

Implemented consumers:

- `ExteraRootTabController`: the navigation menu button, fallback button and mapped drawer actions use the provider; a selection notification updates buttons and closes an existing drawer so it is rebuilt with the new pack. Unmapped actions retain their original SF Symbol.
- `PresentationResourcesSettings`: 12 computed public resources (Saved Messages, Calls, Contacts, Devices, Folders, Stickers, Notifications, Privacy, Data, Appearance, Language, Profile) render the selected original glyph while keeping existing tile backgrounds. Native tiles remain cached unchanged. The resource is re-evaluated when a settings list rebuilds.
- `ChatInterfaceStateContextMenus`: all 20 existing Copy/Forward/Reply/Delete/Edit/Select/Report/Pin/Unpin/Link image lookups use the provider and retain the original per-action theme/destructive colors and handlers. A newly opened message menu uses the current pack.

These are actual drawing paths, not only picker previews. Remaining coverage: tab-bar glyphs, most other native resources, overview category glyphs, and renderer-provided preview/settings symbols. A currently visible native settings list is not forcibly rebuilt by this patch; live refresh should be integrated by the owner of that host. Message menus take effect when next opened.

New public picker entry: **`exteraUIIconPacksController(context:) -> ViewController`**, in `Swiftgram/SGSettingsUI/Sources/ExteraUIIconPacksController.swift`. It renders the three rows, static four-glyph previews, authors, selected indicator, adaptive row height/theme/insets and persisted immediate selection. Root connected the appearance-page “Icon Packs” disclosure to this function. No custom-pack add button is shown before a working import flow exists.

Snapshot integration note: commit `136a2a1bf0cff0517ca49e677d028e6d9b601c0b` already contains the ExteraRootTabController provider hooks, while the new model/provider/assets remain in the working tree. Include them together before building the next commit; do not revert the accepted snapshot.

## Dependencies and localizations for root

No BUILD edits are necessary for production files: SGSimpleSettings, SGSettingsUI and TelegramPresentationData already glob `Sources/**/*.swift`; TelegramUIAssets already globs `Images.xcassets/**`. SGSettingsUI/TelegramUI/SGItemListUI already depend on TelegramPresentationData, and TelegramPresentationData already depends on SGSimpleSettings and Display. No new module, Postbox access or consumer dependency is introduced.

Root localization handoff; the controller currently has en/ru fallback strings:

| Key | English | Russian |
|---|---|---|
| `Extera.UIIcons.Title` | Icon Packs | Наборы иконок |
| `Extera.UIIcons.BasePacks` | Base Packs | Базовые наборы |
| `Extera.UIIcons.Default` | Default | По умолчанию |
| `Extera.UIIcons.Info` | Used for supported icons throughout the app. Other icons keep their original appearance. | Используется для поддерживаемых значков в приложении. Остальные значки сохраняют исходный вид. |

Solar Icon Set, Remix Icon and author names remain original proper names. Root added all four EN/RU keys and strict backup/reset support for `extera.uiIcons.basePack`, using the public setter and native default.

## Provenance, licenses and verification

Original vectors/notices and exact checksums are under `submodules/TelegramPresentationData/UIIconSources`; see its `NOTICE.md`. Each imported git vector's full XML geometry, paint, dimensions and order matches the APK's decoded XML after normalizing color hex case. Stroke-only paths retain `fill=none`, round caps/joins and width; `evenOdd` fills and untransformed groups are retained. Unknown vector structures fail the importer. Source-local `.gitattributes` preserves all original byte hashes without editing root attributes.

Solar attribution/license evidence: original 480-Design README plus preserved Iconify CC BY 4.0 metadata and license text. The original README does not itself contain a license file. Remix's retrieved original license is **Remix Icon License v1.0 (January 2026)**; do not label these current notices Apache/MIT. All downloaded notice bytes have SHA-256 records; the two original-project files also have immutable git blob IDs. exteraGram LICENSE/additional terms remain separate and do not replace third-party terms.

Reproduce import with Pillow, node and the pinned external `@resvg/resvg-js@2.6.2` installation:

```powershell
py tools/import_extera_ui_icons.py --android C:/Users/PC/ayugram-apk-src --apk "C:/Users/PC/Downloads/Telegram Desktop/vanilla-AyuGram-full-20261104.apk" --extera C:/Users/PC/exteragram-reference --renderer C:/Users/PC/AppData/Local/Temp/opencode/app-icon-renderer/node_modules/@resvg/resvg-js
py tools/check_extera_ui_icons.py
py -m unittest discover -s tools -p test_extera_ui_icon_import.py
```

Host verification: 74 vector hashes/geometry comparisons, 222 generated PNG checksums/dimensions/alpha, full inventory checksum, role/catalog registration and explicit consumer-source checks pass. Four conversion regression tests pass. Tree-sitter parses all eight new/changed Swift source/test files without errors; Postbox guard and focused whitespace checks pass. A contact sheet of every imported glyph was opened for source-art inspection; this is not simulator evidence.

Added Swift tests: `TelegramPresentationData/Tests/ExteraUIIconProviderTests.swift` (native image identity, catalog naming and unmapped action fallback) is included by the existing test glob. `Swiftgram/SGSimpleSettings/Tests/ExteraUIIconSettingsTests.swift` covers normalization, malformed preferences, persistence across instances and native reset; root added `python3 Tests/ExteraUIIcons/run_host_tests.py` to CI to compile the production model and this suite directly, supplying only unrelated application bindings. These tests were **not run** on Windows, which has neither Swift/UIKit nor an iOS simulator. They must not be reported as passing Swift tests.

## Pending build and recorded frames

Run the full supported Make.py build on macOS, register/run the model test target and run `//submodules/TelegramPresentationData:TelegramPresentationDataTests`. Complete the root disclosure/localizations before runtime checks.

Expected frame evidence, written before recording: native → Solar → Remix → native changes the selected radio immediately, keeps the three row positions stable, and introduces no wrong-color flash/clipped icon. Opening a drawer or a new message menu uses that selection and keeps tint/destructive colors. Rebuilding Settings updates its 12 glyphs without losing the existing colored tiles. Relaunch preserves the selection; invalid stored IDs show native. Verify light/dark, large text, narrow landscape and Reduce Motion. Record picker open/back/selection and affected consumers with `simctl io recordVideo`, extract timestamped frames with `tools/animation_sheet.py`, and inspect them as required by AGENTS.md. No runtime, animation or frame-parity pass is claimed here.

Ayu overview exact link proof is separate: `docs/extera-ayu-overview-links.md`; translation uses `https://translate.ayugram.one` and documentation uses `https://docs.ayugram.one`, decoded locally from the APK.
