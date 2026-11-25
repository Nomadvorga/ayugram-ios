# Native sticker geometry and settings checks

From the repository root on macOS with Swift:

```sh
OUT="$(mktemp -d)"
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  Swiftgram/SGSimpleSettings/Sources/AyuSettingsStore.swift \
  Swiftgram/SGSimpleSettings/Sources/ExteraStickerSettings.swift \
  Tests/ExteraStickers/ExteraStickerHostTests.swift \
  -o "$OUT/ExteraStickerHostTests"
"$OUT/ExteraStickerHostTests"
```

This compiles the production preference store, sticker settings, and geometry. Only the app-group
identifier and legacy Swiftgram settings facade are replaced. It uses a random UserDefaults suite
and removes it on normal completion. Tests pin legacy timestamp migration, explicit mode priority,
persisted Android-compatible enum ids, shape/default fallback, size bounds and legacy mapping,
recent-sticker limits, side layout for incoming/outgoing, share-button spacing, safe-column overflow
fallback, header collision, preserved vertical anchors, and corner-radius bounds.

The implementation session syntax-checked these sources on Windows. No Swift compiler was present,
so the executable **has not been run**, and UIKit rendering has not been accepted visually.

Parent integration:

- `ExteraStickerSettings.shared.timeMode`: `.default = 0`, `.side = 1`, `.hidden = 2`.
- `ExteraStickerSettings.shared.shape`: `.original = 0`, `.rounded = 1`, `.bubble = 2`.
- Add `//Swiftgram/SGSimpleSettings:SGSimpleSettings` to both sticker-node BUILD dependencies.
- Include `timeMode.rawValue` and `shape.rawValue` in `ChatHistoryListNode`'s settings snapshot to
  trigger visible-row updates on changes, alongside the already included size.
- Back up the new enum values; an unset time-mode sentinel inherits `stickerTimestamp`. An explicit
  enum selection owns visibility and updates the legacy boolean for older app versions. Restore
  the legacy boolean before an explicit enum value when both are present.

Manual simulator checks must follow root AGENTS.md with recordings and labelled frames. Expected
before recording: Default matches native status placement; Side moves incoming time right/outgoing
time left with an 8pt gap while the share button moves farther outward; rows with insufficient room,
reply/forward/via-bot panels, or bubbleless presentation retain native placement. Hidden removes the
standalone status and bubbleless-header time; inline reactions move to the existing reaction footer
in both Side and Hidden so they remain usable. Shapes clip the image, animation, and placeholder
surfaces at matching content bounds without clipping controls or effects. Switching back restores
visibility and removes obsolete masks on every layout/reuse. There should be no clipped controls,
status/share overlap, one-frame mismatched masks, or unintended changes to emoji/dice/premium effects.

Exercise incoming/outgoing static, TGS, and video stickers; all time and shape modes; sizes 4/12/20;
light/dark; group avatars; reactions and reaction taps; long timestamp labels; narrow landscape and
safe side insets; reply/forward/via-bot headers; share/comment buttons; sending/failed/read states;
context previews; scrolling offscreen and back; bubble mode on/off. Use large emoji, custom emoji,
dice, and premium stickers/effects as controls: shape and scaling should remain native. Premium
sticker timestamp modes still apply to the ordinary status node, without changing effect geometry.

Reference grounding: Android `ExteraConfig.kt` defines modes DEFAULT(0), SIDE(1), HIDDEN(2), shape
default 1 and the old `hideStickerTime` migration. `StickerTime.java` uses an 8dp side gap and native
fallback when the timestamp plus side button will not fit. `ChatMessageCell.java` assigns no radius
for shape 0, 6dp for shape 1, and current bubble corners for shape 2. This native port conservatively
falls back for any side header instead of duplicating Android's header-overlap geometry. It does not
claim full Android sticker rendering or animation parity.
