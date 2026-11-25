# Preview snapshot handoff — 2026-11-25

Status: implementation, parsing, diff hygiene and algebraic geometry checks
complete. The preview API and its implementation are frozen until root reports
the next code-wave commit. No commit or push was performed by this worker.

## Public contract (unchanged)

```swift
case settingsPreview(
    id: Int,
    section: Section,
    kind: SGSettingsPreviewKind,
    sliderSetting: SliderSetting?,
    selectionSetting: OneFromManySetting?
)

public enum SGSettingsPreviewKind: Equatable {
    case sticker(SGStickerPreviewConfiguration)
    case stickerShapes(value: Int, options: [String])
    case message(SGMessagePreviewConfiguration)
}
```

- Size callback: existing `updateSliderValue`, raw `Int32` 4...20. Root uses
  `.stickerRawSize`; this scale does not convert sizes to percentages.
- Shape callback: existing `setSegmentedValue`, raw `Int` 0/1/2. Root uses
  `.stickerShape`; options are original / rounded / message shape.
- Sticker time IDs: 0 overlay, 1 side with overlay fallback, 2 hidden.
- Root supplies localized strings, including `Extera.Preview.LargeBadge` for
  «БОЛЬШОЙ» at size 20 and the author/body/quoted sticker label.
- Message inputs: `removeTail`, `showEdited`, `editedIcon`, `onlineDot`,
  `showForwardCount`, `forwardCount`, `monospacedTime`, `boldTime`, `timeScale`.
  The time scale is a multiplier, bounded to 0.7...1.8; default is 1.
- A nil setting ID makes its control read-only. Model application emits no
  callbacks. The host publishes changed size/configuration to remeasure the row.

Root's current preview calls were read without editing the controller:
`SGSettingsController.swift` uses `.stickerRawSize`, `.stickerShape`, the
`Extera.Preview.*` strings and the message appearance flags with these exact
initializer labels. The three kind cases and both struct initializers remain
compatible with those calls.

## Files in the snapshot

| File | Role |
| --- | --- |
| `Sources/SGSettingsPreviewTypes.swift` | Public value configurations/kinds; measurement and closed bubble paths |
| `Sources/SGSettingsPreviewView.swift` | Raw size scale, badge, three shape tiles and local interaction updates |
| `Sources/SGSettingsIllustrationView.swift` | Reusable vector sticker, quoted reply and reactive message scene |
| `Sources/SGItemListUI.swift` | Entry, callbacks, equality, stable ID, section and search integration |
| `Sources/SGExteraItem.swift` | Native/extera shared node, height, reuse, corners, accessibility and separator |
| `VISUAL_STYLE.md` | Full initializers/defaults, integration examples and expected simulator frames |

Earlier gesture/segmented work also remains in this module's existing code-wave
changes: `AyuAppearancePreviewItem.swift`, `AyuDoubleTapPreviewView.swift` and
`SGDiscreteSelectorControl.swift`. Preserve these alongside the shared node.

Dependencies: new preview sources import only UIKit, Display and
TelegramPresentationData. The latter two already appear in this module's
`BUILD`; UIKit is supplied by the iOS SDK. No new Bazel dependency, asset,
network request or settings-model dependency was introduced. `BUILD` already
globs `Sources/**/*.swift`, so the three new sources are included automatically.
The shared node continues using its existing AsyncDisplayKit/ItemListUI/
Markdown/SwiftSignalKit dependencies.

## Validation receipt

Final checks after removing the unfinished style wave from the module:

- All 10 module Swift sources passed tree-sitter Swift parsing.
- `git diff --check -- Swiftgram/SGItemListUI` passed.
- New preview sources passed trailing-whitespace and final-newline checks.
- Algebraic checks passed for 165,240 sticker frame combinations (sizes,
  time/shape/reply settings), 270 tile layouts and 77,760 message footer/font/
  flag combinations. All 17 raw scale stops round-tripped at five track widths.
- Widths span 128...736pt and base font sizes 14...40pt, with independent
  line-height envelopes. These checks exercise layout equations; they do not
  execute UIKit or establish actual UIFont metrics.

The reproducible Windows validation script is scratch material outside the
repository: `C:\Users\PC\AppData\Local\Temp\opencode\validate-settings-previews.py`.
It uses the existing tree-sitter packages in `extera-validation-py312` and the
Python 3.12 executable installed by uv. Root independently reports 89 Swift files
without new parser errors; this worker's scoped receipt covers the 10 module
sources only.

iOS build/typecheck, touch delivery, VoiceOver traversal and recorded simulator
frames remain unverified here. Expected recording paths and visual invariants
are listed in `VISUAL_STYLE.md`; no runtime or pixel parity is claimed.

## Mutation boundary and next wave

The unfinished style work was removed from shared module files and relocated
outside every repository/Bazel source glob to:
`C:\Users\PC\AppData\Local\Temp\opencode\sg-style-wave\`.
No `SGExteraAppearance`, `appearanceStyle` or `valueSlider` reference remains
in this snapshot. The scratch drafts are not a completed API or build input.

References 6/7/21/32 were read. The subsequent wave will prepare actual opt-in
renderer consumers for style, section radius/header separation/dividers, and a
reusable host-level glass surface. It resumes after root's commit notification,
without waiting for the build. Root routes, SGSettingsUI, localization and
backup remain root-owned.
