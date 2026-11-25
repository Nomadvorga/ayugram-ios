# Speech checkpoint tests

Run from the repository root:

```sh
python3 Tests/ExteraSpeech/verify_integration.py
python3 Tests/ExteraSpeech/verify_swift_syntax.py
python3 Tests/ExteraSpeech/run_host_tests.py
```

The first command checks source integration; the second requires `tree_sitter` and
`tree_sitter_swift` and only parses syntax. Neither typechecks Apple APIs.

The host runner compiles **verbatim production** `AyuSettingsStore`,
`ExteraTranslationSettings`, `ExteraSpeechSettings`, locale/transcript policy and
model manager together with `SpeechTests.swift`. It uses a unique disposable
UserDefaults suite and stubs only the unrelated general settings backend property.
It runs separate processes for fresh defaults, persisted legacy locale/offline
preferences and persisted disabled state. The async fake inventory verifies real
manager operations: explicit installation, installed-only selection, leases,
release verification, obsolete reservations, failure rollback, retaining existing
reservations, and cancellation while a deliberately non-cooperative install ends
late. Tests use continuations, without timing sleeps or live asset downloads.

No Swift compiler is available in the Windows workspace. Prepare sources without
claiming execution:

```powershell
py Tests/ExteraSpeech/run_host_tests.py --emit-only --output C:\Users\PC\AppData\Local\Temp\opencode\extera-speech-host
```

The emitted sources are also syntax parsed. On a Swift host, run the third command
above, which invokes `swiftc -swift-version 5 -warnings-as-errors -parse-as-library`.
Each executable invocation has a 30-second process limit to detect deadlocks.

Xcode 26+ API typechecking/full iOS build, Speech authorization, offline asset
download/cancellation/release and actual transcription remain device checks. The
project currently pins Xcode **27.1**, which includes iOS 26 APIs; availability is
also guarded at runtime. Refer to `docs/extera-speech-runtime.md` for root integration
and the required recorded-frame checks. Do not report emitted Swift tests as PASS.
