# Vosk implementation and root integration

Checkpoint: 2026-11-26. Independent Vosk implementation and the authorized targeted root integration are present in the workspace. The five shared files contain only the Vosk hunks/appends made for this handoff, alongside pre-existing root changes; root can now resume those files. Existing Apple speech/camera source remains unchanged. The integrated tree is now at `c56af00f`; device and simulator debug compile/link succeeded, while native recognition and release qualification remain open.

## Implementation

| Component | Responsibility |
| --- | --- |
| `submodules/VoskNative` | Immutable XCFramework identity; explicit Clang module `CVosk`; eight C ABI declarations; zlib streaming/CRC helper. Uses `objc_library` module generation consistent with this repository. |
| `submodules/Media/VoskSpeech` | Exact 24-entry Android catalogue, SHA-256 pins and ZIP expansion bounds; scoped model store; cancellable explicit download/install/use/delete; native handle ownership; transcription signals and bounded processing. |
| `submodules/Media/VoskSpeechAudio` | Original resource → opt-in strict `SoftwareAudioSource` codec/SWResample-drained mono S16/48 kHz decoder → stateful AVAudioConverter → mono S16/16 kHz. Dispatch happens before AAC conversion. |
| `AyuGram/SGSimpleSettings/Sources/ExteraVoskSettings.swift` | Separate Vosk provider/language preferences, sharing the existing global speech-enabled flag. |
| `AyuGram/SGSettingsUI/Sources/ExteraVoskRecognitionController.swift` | All 24 languages; explicit Download, Use, Delete; None and Automatic; progress/cancel and operation errors. Uses SGStrings keys provided in root's patch. |
| `submodules/Media/LocalAudioTranscription/Sources/VoskTranscriptionResult.swift` | Tiny additive result constructor in the existing module; avoids modifying the frozen Apple source or adding media/native dependencies to it. |

The language order and filenames match Android exactly. Catalogue aliases normalize `cn → zh`, `ua → uk`, `kz → kk`, `vn → vi`, and locale subtags such as `zh-Hans` and `en-US`. Explicit language selections require that exact installed model. Automatic tries the installed chat-language model, then installed app-language model; it fails if neither exists. No recognition operation downloads a model, requests Apple speech authorization or falls back to Apple/server recognition.

The settings keys are `extera.vosk.isSelected` (default false) and `extera.vosk.language` (default `none`; valid selections `none`, `auto`, or one of the exact 24 codes). `select(language:)` writes the selection and global enabled flag together through the existing notification batching API. A successful download does not select a model; the UI explicitly offers Use afterward. Removing the selected language sets None and disables local speech if Vosk is selected. Switching backend clears only the Vosk selection flag. Backup restores preferences without creating model files; its language validator allowlists exactly `none`, `auto`, and the 24 catalogue codes.

## Storage, extraction and resource ownership

Models live in `Application Support/ExteraVosk/<language>`, excluded from backup. Initialization removes only app-owned `staging-<UUID>` leftovers before operations can acquire a lease. Installation uses a new staging directory, requires free space for compressed + expanded bytes + 16 MiB, checks exact length/SHA-256, extracts, validates through `vosk_model_new`, writes a receipt and moves the directory into place. SHA failure precedes both extraction and native parsing. Cancel/error removes staging; cancellation racing publication removes the new installation. No model binaries are repository or app resources.

The ZIP32 reader rejects encryption, ZIP64 markers, links/special files, traversal, absolute/backslash/colon/NUL paths, duplicate case-insensitive paths, extra roots, unsupported methods, size/count overflow and CRC mismatch. It streams in 64 KiB blocks, checks local names/methods against the central directory and enforces measured entry and aggregate expansion limits. Stored and raw-deflate members are supported. Original README/COPYING files are retained. Portuguese/Turkish 0.3 use the inspected legacy flat layout (`final.mdl`, `mfcc.conf`, `HCLr.fst`, `Gr.fst`); the other models use `am/final.mdl` and `conf/model.conf`.

One exclusive UUID owner spans model maintenance and recognition. Deleting while native recognition or Use owns a lease returns busy. The recognizer explicitly frees recognizer then model before releasing the file lease; no native model cache survives an operation. Use validates on the file worker and compares/persists the captured settings on the main actor, so a later UI selection wins. Delete checks cancellation before unlink; once unlink starts it completes the preference update. Physical deletion verifies the directory is absent; it does not claim secure erasure or APFS snapshot reclamation.

Native processing is on a worker, with a 180-second wall-clock deadline and checks between PCM/conversion chunks. Disposal and changed speech configuration cancel delivery. PCM chunks are limited to 128 KiB; aggregate decoded audio to one hour; transcript output to 1 MiB. Resource files are bounded to 256 MiB before constructing the existing decoder, which stores file size in Int32. Converter sample buffers are bounded to ten seconds, format checked and sliced according to the converter's requested frame count. Borrowed native JSON is copied with a 1 MiB bound. Logging is suppressed before native validation and recognition.

Cancellation cannot preempt a single in-progress synchronous native model load, decode or C recognizer call. The operation keeps its lease until that call returns and resources are released. Delivery still terminates at the deadline. Vosk now uses a separate throwing sequential reader: it distinguishes demux/codec/conversion errors, drains codec then SWResample before AVAudioConverter, and enables strict POSIX read/seek checks before probing and the initial seek. Legacy playback and Apple reads keep the old API contract. An iOS fixture test pins complete AAC decoded sample counts and cancellation behavior, but it has not run here; no claim of runtime-verified drain or complete malformed-file detection is made.

## Artifact evidence

SDK ZIP: 48,290,797 bytes; SHA-256 `1891ad61293278363f75f2b4e5313c606183d0acd14f4b1ff1a71f5629c676f9`, verified before extraction. Source URL and provenance limitations are in `submodules/VoskNative/NOTICE.md`.

Actual arm64 device slice: 36,384,888 bytes / 223 Mach-O objects; iOS minimum 10.3, SDK 15.2. Actual arm64 simulator slice: 36,358,904 bytes / 223 objects; explicit Simulator platform, minimum 14.0, SDK 15.2. Device archive also includes armv7/armv7s; simulator includes x86_64. Every inspected slice contains all eight C symbols used here. The required math symbols are consistent with Accelerate BLAS/LAPACK. Additional archive objects contain unresolved Kaldi training symbols; normal static linking must establish whether they are reachable. Do not force-load this archive.

The ZIP has no headers or licenses. Community wrapper release 0.1.2 does not identify the compiled Vosk/Kaldi/OpenFST revisions or native build recipe. This candidate's incomplete native provenance/notice inventory remains unresolved; it must be qualified or replaced before distribution. The official iOS SDK is offered on request; no message was sent to its maintainers.

All 24 archives passed the publisher's pre-recorded MD5 and exact byte count, then every ZIP member CRC. SHA-256 and exact expansion/entry limits were measured and recorded in `VoskVerifiedModels.swift`. These are documented ingestion-derived pins, not publisher SHA-256 claims. Several first attempts were truncated; mismatches were quarantined and never extracted. Range continuation completed the files and whole-archive verification passed. Total compressed bytes: **1,288,393,315**; uncompressed file payload: **2,758,240,586**. All archives and SDK extraction remain under `C:\Users\PC\AppData\Local\Temp\opencode\extera-vosk-artifacts`, outside git.

Model licenses follow the official table: Czech MIT, other 23 Apache-2.0. Czech's archive README explicitly says MIT and links Rhasspy; German/Ukrainian archives include COPYING. Most other models include a README rather than full license text. Preserve those notices and include the appropriate full license/attribution texts in the distribution's acknowledgments. Wrapper Apache attribution does not establish a complete native third-party inventory.

## Root integration

The authorized targeted shared-file integration is already applied in this workspace. `docs/integration/extera-vosk-root.patch` remains the original review artifact rather than an instruction to apply it again. Root owns the commit/snapshot and may now resume the shared files. The integrated changes provide:

```sh
git diff --check
python Tests/ExteraVosk/verify_catalogue.py
```

The root patch supplies the checksum-pinned MODULE repository, settings/media BUILD deps, Vosk backend picker and settings route, pre-AAC voice-file dispatch, two backup fields, all 21 EN/RU strings and the host CI step. Current equivalents were added as targeted hunks after reviewing dirty files; no unrelated shared-file content was replaced. `docs/integration/extera-vosk-strings.json` is the identical string payload for root's localization tooling. New source files under existing source globs need no extra entries. New independent targets have their own BUILD files.

The runtime branch captures the provider at request start. A request begun with Vosk cannot cross into the Apple branch while resource lookup is pending. Existing message/resource identity guards and downstream storage remain in place. Instant-video server transcription is outside this voice-file patch's scope. `ExteraSpeechPolicy.swift` and its root-owned languageCode fix are untouched.

Review release framework export lists under `Telegram/CLAUDE.md` during the full release build; do not infer success from a host harness. The patch does not publish, deploy, run workflows or add model resources to the build.

## Executed verification

| Check | Result |
| --- | --- |
| All-model complete bytes, MD5, SHA-256, counts/sizes/layout/path policy | Passed independently against the cached archives and Swift catalogue. |
| SDK SHA-256, plist, fat archives, Mach-O/platform metadata, required C symbols | Passed binary inspection; reports are in the artifact cache. |
| Actual production `VoskInflate.c` | Compiled with WSL GCC, `-Wall -Wextra -Werror`; 168 streaming/boundary scenarios passed in this continuation, including exact 64 KiB boundaries and invalid/truncated/trailing/CRC/expansion cases. |
| Actual C inflater on real archives | All 345 deflated members passed; 2,758,240,314 deflated expanded bytes (remaining 272 bytes are stored members). |
| C smoke/stub declarations | Strict C syntax check passed; this does not run the iOS SDK. |
| Shared integration | Applied as targeted Vosk-only hunks after reviewing current dirty content; root patch remains unapplied as a whole. `git diff --check` and the catalogue/localization verifier passed. |
| Source syntax/localization consistency | The touched Swift sources and decoder test parse with tree-sitter; the 21 EN/RU keys match the screen and root patch. Syntax parsing does not typecheck Swift. |
| Swift host package | The local WSL projection compiled and linked, then timed out at 180 seconds after use/delete before the remaining cleanup checks finished; it is not a passing full suite. The exact Mac host suite is included in [host workflow 45752660441](https://github.com/Nomadvorga/ayugram-ios/actions/runs/45752660441) and its Vosk catalogue/archive/model-lifecycle step passed. |
| Decoder fixture regression | Added `submodules/MediaPlayer/Tests/SoftwareAudioTranscriptionDrainTests.swift`; independent FFmpeg reference outputs for both fixtures measured at 145,408 and 49,152 samples. The production test has not run. |
| iOS full app/typecheck/link/native recognition/performance | Device and simulator debug compile/link succeeded on `c56af00f` ([device run 45751399386](https://github.com/Nomadvorga/ayugram-ios/actions/runs/45751399386), [simulator run 45751420234](https://github.com/Nomadvorga/ayugram-ios/actions/runs/45751420234)); the simulator onboarding smoke also passed on attempt 2. Native SDK recognition, release link/export, model accuracy and device performance remain unverified. |
| Visual UI | No Vosk settings/model-management state is recorded or accepted. The CI simulator recording covers only onboarding and does not verify this UI. |

Local C verification used WSL Ubuntu with GCC/zlib development packages. Apt verified repository metadata and package checksums; its dependencies also updated Ubuntu libc/zlib packages. Nothing from that toolchain is an app dependency.

## Repeatable checks

The catalogue/native commands use local fixtures and optional cached models. On macOS the host harness uses CryptoKit; its Linux projection uses Swift Crypto (a local checkout via `SWIFT_CRYPTO_PATH`, otherwise SwiftPM resolves the pinned package).

```sh
python3 Tests/ExteraVosk/verify_catalogue.py
python3 Tests/ExteraVosk/run_native_tests.py
python3 Tests/ExteraVosk/run_host_tests.py  # macOS / Swift 5.9+
# Optional complete artifact recheck (set the cache path for the current host):
python3 Tests/ExteraVosk/verify_catalogue.py --model-cache /path/to/extera-vosk-artifacts
python3 Tests/ExteraVosk/run_native_tests.py --model-cache /path/to/extera-vosk-artifacts
```

The Mac host harness copies exact production Foundation/settings/store/ZIP/native-wrapper sources into a temporary Swift package. Only the native library implementation is replaced by `NativeHostStub.c`, so the host can test install/corruption/cancel cleanup, stale Use, lease/delete, settings/aliases, safe ZIP rejection and native wrapper ownership without trying to load an iOS archive into macOS. Linux additionally projects Darwin to Glibc, imports FoundationNetworking, and substitutes the available volume-capacity key and Crypto module. It does **not** test AVAudioConverter, UIKit, native recognition or the SwiftSignalKit delivery layer. The WSL projection compiled/linked but timed out during runtime checks; the Mac CI host suite passed, so that timeout is not treated as a product-test failure.

## Mac/device acceptance still required

1. The Vosk host workflow and integrated app debug compile/link have passed on Mac CI for arm64 simulator and device (`c56af00f`). Still validate a release link and exports. Load all 24 native models; run representative checksum-pinned language fixtures, including Portuguese/Turkish legacy layout.
2. Run the new MediaPlayer drain regression tests and test original Opus voice files, mono/stereo input, conversion sample counts, EOF tail, delayed/multiple decoder output, malformed/read errors, empty/silent files and utterance accumulation. `Tests/ExteraVosk/NativeSmoke.c` supplies a minimal actual-SDK C runner for a pinned mono S16/16 kHz fixture; it is not a performed test.
3. Install/cancel/retry/relaunch, low disk, model corruption, delete during active recognition, rapid Use/backend/None changes, timeout after partial output, node reuse and backup restore without installed files. Verify no implicit network, Apple permission or server fallback; recognize in airplane mode after explicit installation.
4. Measure peak model memory, teardown, IPA delta and cold/warm latency on supported devices, especially Ukrainian/Gujarati. No measured recognition accuracy or memory bound is claimed from an archive-size check.
5. Before recording, expect a stable 24-row catalogue, one checkmark, bounded progress text, system confirmation alerts, installed-state updates only after publication and deletion-state updates after files disappear. No custom animation is added. Record open/close, download/cancel/use/delete, None/Auto and light/dark, then inspect labelled frames using `AGENTS.md` / `tools/animation_sheet.py`. No frame evidence exists yet, so the UI remains visually unverified.

## Latest Simulator smoke investigation

On `84c0a14a` the current device Debug workflow succeeded and uploaded `AyuGram-iOS-debug_arm64-170` in [run 45838474569](https://github.com/Nomadvorga/ayugram-ios/actions/runs/45838474569). The independent native Simulator smoke in [run 45838614590](https://github.com/Nomadvorga/ayugram-ios/actions/runs/45838614590) verified and linked the arm64 Simulator archive and all eight required Vosk symbols, launched the app, but timed out without a native result or terminal status. The uploaded diagnostic report and system log contain a `libdispatch` bug record but no usable crash backtrace; this is not enough to attribute the failure to Vosk model loading or to claim the app crashed.

The follow-up smoke runner writes explicit app/worker phases, runs native recognition on a detached POSIX thread rather than a global dispatch queue, waits for a terminal app status, and unit-tests the status protocol. Only a subsequent real-SDK Simulator run that reports model load, recognizer creation, completion and nonempty text can close the recognition gate.
