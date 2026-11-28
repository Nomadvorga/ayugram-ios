# Chat appearance preferences and distance formatting tests

The model suite compiles the exact production `AyuSettingsStore.swift` and
`ExteraChatAppearanceSettings.swift`, substituting only a UUID-named app-group suite.
It covers all persisted choices, invalid-value defaults, consumer notifications,
available/unavailable full-swipe ordering, inverse native action keys, idempotence
over all subsets of actions, automatic/explicit distance policy across regions, microphone
availability/selection, disconnect/reconnect fallback, multiple input candidates and the
existing system-microphone override. There are thirteen host model tests.

Run from the repository root with a Swift host toolchain:

```sh
python3 tools/run_extera_xctests.py --warnings-as-errors \
  AyuGram/SGSimpleSettings/Sources/AyuSettingsStore.swift \
  AyuGram/SGSimpleSettings/Sources/ExteraChatAppearanceSettings.swift \
  Tests/ExteraChatAppearance/ExteraChatAppearanceSettingsTests.swift
```

The separate formatter suite requires macOS with Xcode and real MapKit:

```sh
python3 Tests/ExteraChatAppearance/run_distance_tests.py --sanitize=thread
```

That runner copies the unchanged production store, preference model, `Geo.swift`
and `Locale.swift` into temporary SwiftPM modules. Only the build-time app-group
identifier and the app-bundle-dependent `PresentationStrings` language holder are
fixtures. It tests both actual cached formatters against fresh MapKit formatters,
including repeated km/miles/automatic changes, proximity preference consumption,
and concurrent calls in different languages. It does not simulate formatting or
copy production formatting functions into test implementations. The tests use an
isolated defaults domain and never read account data or real app-group settings.

Both host suites were attempted on the Windows/WSL host. Execution stopped at the
toolchain checks: Swift is absent and macOS MapKit is unavailable. Their ten Swift
implementation/test sources plus the three microphone runtime/native-test sources
passed a separate tree-sitter syntax parse; this
does not establish type correctness or an XCTest pass.

Five additional microphone snapshot/ownership tests live in
`submodules/TelegramAudio/Tests/RecordingMicrophoneInputTests.swift`, included by the
existing native target `//submodules/TelegramAudio:TelegramAudioTests`. Run that target
with the Make.py test invocation in the root `CLAUDE.md`; it also guards existing call
holder precedence and output classification. These tests never activate AVAudioSession.
They require Xcode/iOS and were not runnable here. The settings UI's new direct
TelegramAudio dependency is handed to root for its BUILD integration.

For UI/runtime acceptance, follow the expectations and exclusions in
[`docs/extera-chat-appearance-settings.md`](../../docs/extera-chat-appearance-settings.md).
The full iOS build and simulator frame recording remain required under
[`AGENTS.md`](../../AGENTS.md).
Microphone frame expectations, hardware acceptance and root-owned keys/backup/dependency
handoff are in [`docs/extera-recording-microphone.md`](../../docs/extera-recording-microphone.md).
