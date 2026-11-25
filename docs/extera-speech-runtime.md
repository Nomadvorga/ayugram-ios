# Apple speech/offline models: root checkpoint

This checkpoint implements the Apple adaptation for reference photos **58, 60,
61 and 62**. The original photos and `extera-translation-speech-audit.md` /
`extera-reference-screens-45-66.md` were inspected. The Android picker has None +
24 Vosk languages and a physical model deletion action. This implementation uses
**Apple Speech**, a dynamic device/OS catalogue and actual AssetInventory release;
it does not claim Vosk packaging, those 24 languages, or immediate physical deletion.

## Mutation boundary / integration

Speech sources are a single checkpoint: **six new source files**, plus two existing
source edits. Include them together; no incomplete symbol references are intended.

- `Swiftgram/SGSimpleSettings/Sources/ExteraSpeechSettings.swift`
- `Swiftgram/SGSettingsUI/Sources/ExteraSpeechRecognitionController.swift`
- `submodules/Media/LocalAudioTranscription/Sources/ExteraSpeechPolicy.swift`
- `submodules/Media/LocalAudioTranscription/Sources/ExteraSpeechModelManager.swift`
- `submodules/Media/LocalAudioTranscription/Sources/AppleSpeechAssetInventory.swift`
- `submodules/Media/LocalAudioTranscription/Sources/ExteraSpeechRecognition.swift`
- Existing `LocalAudioTranscription.swift`: legacy recognition delegates through the
  new public entry point, cancels on settings changes, removes runtime logging.
- Existing `ChatMessageInteractiveFileNode.swift`: checks disabled before conversion.

Root owns BUILD, settings entry wiring, strings and backup. They were not edited by
this worker. **Required dependency:** add
`//submodules/Media/LocalAudioTranscription:LocalAudioTranscription` to
`Swiftgram/SGSettingsUI/BUILD` because the new controller imports that module. Both
source modules already use `Sources/**/*.swift` globs. No external binary/library,
model archive, credentials, checksum entry, or new build target is required.
LocalAudioTranscription already depends on SGSimpleSettings and SwiftSignalKit.
The new runtime uses public `Speech`, `AVFoundation` and Foundation APIs.

Push `sgSpeechRecognitionController(context: AccountContext) -> ViewController`
from the root speech row. It contains None/Automatic, legacy locale/on-device
preferences and managed-model install/use/release/cancel UI, with owned English /
Russian text. Retain the independent Telegram/Apple backend selector. If the old
root locale selector remains reachable, replace its direct locale writes with
`ExteraSpeechSettings.shared.languageSelection = .automatic / .locale(identifier)`;
direct legacy key writes intentionally do not clear the disabled or managed flags.
Root's summary should read `languageSelection`, so None is not shown as Automatic.

`versions.json` pins **Xcode 27.1** (build and deploy), macOS 27. That SDK includes
the iOS 26 Speech APIs. SpeechAnalyzer/SpeechTranscriber/AssetInventory references
are under iOS 26 availability annotations/checks; older OSes retain the legacy
recognizer and show an honest model-management-unavailable message. An SDK older
than iOS 26 cannot typecheck these symbols: runtime availability alone does not
provide old-SDK compilation. The Windows workspace cannot verify CI's installed
SDK; root must confirm the pinned Xcode is actually selected by its runner.

## Keys, defaults, migration and backup

| Persistent key | Type / default | Meaning |
| --- | --- | --- |
| `extera.speech.isEnabled` | Bool / **true** | False is None; retains prior locale/offline choices. |
| `extera.speech.useManagedOfflineModel` | Bool / **false** | Explicit installed/reserved SpeechAnalyzer model; fail without fallback. |
| `extera.appleSpeechLocaleIdentifier` | String / **""** (existing) | Empty is Automatic: predicted chat language, then app language. Explicit locale otherwise. |
| `extera.appleSpeechOnDeviceOnly` | Bool / **false** (existing) | Legacy recognizer's `requiresOnDeviceRecognition`; true fails if unsupported. |

No destructive migration is needed: absent new keys preserve existing recognition,
the old locale and offline flag. A persisted false enabled key remains false.
None never overwrites the old locale with an empty string. Automatic or a legacy
locale choice re-enables recognition and exits managed mode, while preserving the
old on-device flag. Verified managed selection stores its locale, enables speech,
sets both offline flags true, and selects the existing Apple backend.

Public settings API: `ExteraSpeechSettings.shared.isEnabled`,
`.useManagedOfflineModel`, `.configuration`, `.languageSelection`;
`ExteraSpeechLanguageSelection` is `.disabled / .automatic / .locale(String)`.
`selectManagedOfflineModel(localeIdentifier:)` is for the controller **after**
manager verification, not a substitute for verifying/installing a model.

Root backup allowlist additions, using the existing `boolean` entry helper:

```swift
boolean("extera.speech.isEnabled", read: { ExteraSpeechSettings.shared.isEnabled }, write: { ExteraSpeechSettings.shared.isEnabled = $0 }),
boolean("extera.speech.useManagedOfflineModel", read: { ExteraSpeechSettings.shared.useManagedOfflineModel }, write: { ExteraSpeechSettings.shared.useManagedOfflineModel = $0 }),
```

Keep the two existing legacy locale/offline entries and the backend entry. An old
backup missing new fields follows existing missing-field restore semantics. Backup
restores preferences only: **never** reserve/install assets on restore. A restored
managed selection lacking an installed app reservation fails locally until an
explicit download/retain action. Do not export model files or an invented installed
flag. AyuSettingsStore registration/cache/change notifications remain authoritative.

## Actual runtime and resource semantics

`transcribeAudio(path:appLocale:)` remains the public consumer API and reads settings
inside subscription. It rejects None before authorization. The voice-file consumer
also checks before Opus→AAC conversion. Further checks follow authorization/file
preparation, precede analysis, run for each result and run before main-queue delivery.
Changes cancel pending recognition. Exact unavailable regional locales fail rather
than silently switching regional models; bare predicted/app codes resolve among
supported locales using device preferences. Existing node-reuse identity guards
remain in place. Instant-video's existing transcription consumer uses the Telegram
engine server path; it does not call the Apple runtime and is not a model consumer.

Legacy mode uses SFSpeechRecognizer authorization and its on-device flag. With false
(the unchanged default), Apple may use its server. Managed mode instead uses
SpeechAnalyzer + SpeechTranscriber with `.transcription`, on device, after checking
an installed app-reserved model. It never calls install/reserve, never falls back
to SFSpeechRecognizer or Telegram, and requires an explicit locale. Apple documents
that SpeechAnalyzer transcriber modules do not send voice audio to Apple servers
and do not use the legacy recognition permission workflow.

Analyzer phrase ranges replace overlapping hypotheses and retain earlier phrases;
the original text spacing is preserved, including CJK. Phrase-final is not emitted
as whole-file final: final output follows successful end of the result sequence.
Both paths reject empty final output, deliver on main, own temporary files and cancel
tasks on disposal. Managed processing has an absolute 180-second deadline that
survives partial results (SwiftSignalKit's ordinary timeout stops on first next).

The manager actor serializes maintenance against one active managed recognition.
Opaque leases prevent stale cleanup from freeing another analysis. A second managed
analysis or maintenance while in use reports busy. Catalogue queries read actual
system status/reservations and do not acquire a model. Device-wide storage and model
reservation limits belong to Apple; sizes/progress percentages are not invented.

Only the explicit Download/Keep action invokes reserve + assetInstallationRequest
+ downloadAndInstall. Already installed shared assets can be reserved without a new
download. Use Model verifies installed + reserved status without downloading, then
sets preferences; download alone never enables recognition. Failed/cancelled first
installs release their new reservation; previous reservations remain. Task
cancellation calls the request's public `Progress.cancel()` and checks cancellation
after the OS returns. Apple consolidates requests and may schedule retries after a
network failure; this code cannot guarantee cancellation of global system work.

Release calls `AssetInventory.release(reservedLocale:)` for the actual reservation
identifier, then verifies its removal. Canonical locale matching handles Apple's
reservation variants; obsolete reservations remain visible/releasable. Installed
status can remain true after release because assets are shared. The UI says
**Release / Освободить**, and explains that iOS chooses physical deletion time.
Releasing a selected model leaves the explicit choice intact so subsequent starts
fail, without uploading or changing the language. No audio, transcript, path or
framework error payload is logged by this runtime.

Public model API: `ExteraSpeechModelManager.shared` (iOS 26), `.catalogue()`,
`.install(localeIdentifier:)`, `.verifyInstalledModel(localeIdentifier:)`,
`.release(localeIdentifier:)`; model fields are locale identifier, status and actual
app reservation. Status is unsupported/notInstalled/downloading/installed. Errors
are unavailable/unsupportedLocale/busy/notInstalled/releaseFailed/installationFailed,
plus Apple installation errors mapped to a generic, redacted UI message.

Apple references checked: [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory),
[reserve](https://developer.apple.com/documentation/speech/assetinventory/reserve(locale:)),
[release](https://developer.apple.com/documentation/speech/assetinventory/release(reservedlocale:)),
[downloadAndInstall](https://developer.apple.com/documentation/speech/assetinstallationrequest/downloadandinstall()),
[file analysis](https://developer.apple.com/documentation/speech/speechanalyzer/start(inputaudiofile:finishafterfile:)),
[permission scope](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition).
Their public DocC declarations were checked; that is not a compiler result.

## Verification and remaining checks

Windows checks: **13 source integration guards PASS**; tree-sitter parses all 11
listed production/test Swift files and emitted host sources. `git diff --check`
is run only on owned speech paths. This validates syntax/source relationships,
**not Swift typechecking, linking or executed recognition**.

`Tests/ExteraSpeech/run_host_tests.py` emits/executes exact Foundation production
settings/policy/manager sources, with an injected inventory. Three fresh executable
processes cover fresh/legacy/disabled persistence; async tests cover install/retain,
no implicit download, real release checks, leases, rollback, cancellation after a
late successful install and obsolete reservations. See its README. Swift assertions
were **emitted only**, not executed: no swiftc/Xcode/iOS simulator exists here.

Root: add dependency + entry wiring + backup keys; run the host tests and supported
full Bazel/Make.py iOS build on the selected Xcode 27.1 SDK. On a supported device,
exercise install, explicit selection, airplane-mode transcription, release, missing
model failure, cancellation, no-space/reservation-limit/network failures, None during
authorization/conversion/recognition, node reuse and timeout after a partial. Also
exercise an older iOS device's unavailable-management state and legacy on-device
failure/permission denial. Confirm the system-reported language/reservation variants.

Recorded-frame verification remains pending under AGENTS.md. Expected frames:
opening/closing this native list uses the existing navigation transition with no
duplicate sheet, clipping or uncovered background; None/Auto/locale/managed selection
has one checkmark for the active mode; status updates do not animate row movement
(`animateChanges: false`); operation text and Cancel remain reachable; confirmation
alerts respect safe areas, text wrapping, Dynamic Type and dark/light theme. Record
open/close, install/cancel/use/release/error and long-language-list paths in English
and Russian; inspect labelled timestamped frames before calling appearance verified.
