# Vosk iOS feasibility and Android model parity

Research and implementation checkpoint: 2026-11-25. The original metadata-only audit has now been followed by authorized SDK and all-model ingestion, binary inspection and independent Vosk source implementation. The accepted Apple speech and camera sources remain unchanged; shared-file integration is supplied as a root-owned patch. No commit or push was made. See [implementation, evidence and remaining checks](extera-vosk-runtime.md).

## Finding

**A genuine Vosk iOS backend with Android's exact 24-model catalogue, explicit download, offline recognition and physical removal of app-owned model files is feasible.** Upstream contains a Swift/C iOS demo; its Xcode project links `libvosk.a`, `Accelerate.framework` and `libc++.tbd`. The native C API loads a model from a filesystem path and accepts mono PCM. No platform incompatibility preventing this feature was established.

Official iOS distribution is documented as available on request. The public community XCFramework has now been downloaded, hash-verified and inspected: actual device/simulator slices and all eight used C symbols are present. Its native source revisions, build recipe and complete third-party license inventory remain unestablished. iOS linking and recognition have not run on this Windows host. The accepted Apple Speech/AssetInventory checkpoint remains separate from this Vosk backend.

## Evidence and source identities

| Evidence | Identity / observation |
| --- | --- |
| Cached Android reference | `C:\Users\PC\exteragram-reference`, HEAD `b4d852f48f2734a0bee1a74a0939be621612262a`; inspected with read-only `git show` / `git ls-tree`. |
| Android implementation | `TMessagesProj/src/main/java/com/exteragram/messenger/speech/recognizers/VoskRecognizer.java`; `VoiceRecognitionController.java`; `ui/RecognitionModelDialogs.java`; `utils/FormatConverter.java`. |
| Android library | `TMessagesProj/build.gradle` declares `com.alphacephei:vosk-android:0.3.75`. That Android artifact is not an iOS library. |
| Upstream native API/demo | [`alphacep/vosk-api`](https://github.com/alphacep/vosk-api/tree/4ab9821510b488efb7740094714a130bd3545e90), inspected commit `4ab9821510b488efb7740094714a130bd3545e90`. |
| Official iOS distribution | [Install page](https://alphacephei.com/vosk/install) says iOS is available on request; pinned [`ios/README`](https://github.com/alphacep/vosk-api/blob/4ab9821510b488efb7740094714a130bd3545e90/ios/README) requires a library build and directs enquiries to Alpha Cephei. No enquiry was sent. |
| Official Swift integration | [`Vosk.swift`](https://github.com/alphacep/vosk-api/blob/4ab9821510b488efb7740094714a130bd3545e90/ios/VoskApiTest/Vosk.swift), `VoskModel.swift`, and [`project.pbxproj`](https://github.com/alphacep/vosk-api/blob/4ab9821510b488efb7740094714a130bd3545e90/ios/VoskApiTest.xcodeproj/project.pbxproj). These prove an intended iOS integration, not successful compilation in this workspace. |
| Model catalogue | [Official JSON](https://alphacephei.com/vosk/models/model-list.json): exact filenames, URLs, byte sizes, MD5, language aliases, versions and obsolete flags. The reviewed schema has no SHA-256 or license field. |
| Model licenses / resource guidance | [Official model table](https://alphacephei.com/vosk/models): per-model license column; typical small-model memory around 300 MB. Table size labels are rounded and sometimes differ from exact JSON sizes. |
| Community package | [`ishantve/VoskSpeechKit` 0.1.2](https://github.com/ishantve/VoskSpeechKit/releases/tag/0.1.2), published 2026-08-10. Annotated tag object `ad00cf52e0c3d738af9b61485da9ed8e851a9ade` resolves to commit `2ffd17a4c3d62290e4601459e01454753d4411a7`. |

The latest five upstream release records inspected did not advertise an iOS archive. Some older records include macOS assets; a macOS archive is not interchangeable with an iPhone or iOS Simulator archive. This limited release inspection does not establish that no other iOS distribution exists.

## Native SDK candidate, provenance and licenses

The community release publishes:

```text
URL: https://github.com/ishantve/VoskSpeechKit/releases/download/0.1.2/libvosk.xcframework.zip
Archive size: 48,290,797 bytes (46.05 MiB)
SHA-256: 1891ad61293278363f75f2b4e5313c606183d0acd14f4b1ff1a71f5629c676f9
```

Both the tag-pinned [`Package.swift`](https://github.com/ishantve/VoskSpeechKit/blob/2ffd17a4c3d62290e4601459e01454753d4411a7/Package.swift) and GitHub Release asset `digest` publish that hash. The full downloaded 48,290,797-byte ZIP passed SHA-256 **before extraction**. The package declares iOS 13 minimum, Swift tools 5.9, a static native library, `c++`, `Accelerate`, and wrapper use of `AVFoundation`. Actual arm64 device/simulator Mach-O metadata was inspected independently, as recorded below. The ZIP contains two static archives and Info.plist, without headers or license/NOTICE files. A checksum does not establish engine version or source origin.

The community Apache-2.0 LICENSE identifies its wrapper author and Alpha Cephei's Vosk library. Upstream Vosk's pinned `COPYING` and C header specify Apache-2.0. The public native Makefile also depends on Kaldi and OpenFST (`libfst` and `libfstngram`), with alternative math-library configurations. The reviewed community tree/CI and `scripts/build-ffi-xcframework.sh` do not supply the recipe and source revisions used to build **libvosk itself**: the script builds a wrapper/Unity FFI from an existing library. Its simulator CI is not evidence of an independently reproduced native build or a successful device run.

Before adopting this binary, obtain a native build manifest or reproduce it: Vosk revision, Kaldi/OpenFST revisions, patches, compiler/SDK/deployment target, math backend, archive commands, and license/NOTICE files for every included component. Verify that the actual library uses the expected Accelerate configuration and whether any other math dependency is embedded. The wrapper's Apache statement alone is not a complete inventory of a static archive's contents. Community CocoaPods `prepare_command` inspected at the main snapshot fetches and unzips the library without a checksum check; do not copy that download path into this repository.

Two practical acquisition routes remain:

1. Obtain an Alpha Cephei iOS SDK distribution with a version, checksum, architecture list and redistribution/license manifest. Public instructions describe contact availability, not price, delivery time or exact slices.
2. Build an internally pinned XCFramework from source on Mac, or qualify the public candidate after establishing equivalent provenance. The upstream `src/Makefile` defaults to a shared-library link; setting `EXT=a` does not turn that recipe into a reproducible iOS static build. Cross-compile its dependencies for each target and explicitly assemble the static archive/XCFramework.

Source builds need a C++17 toolchain, Vosk, Kaldi's CPU recognition libraries, OpenFST and a selected BLAS/LAPACK backend. For an Apple Accelerate build, disable CUDA/MKL and the alternate OpenBLAS/CLAPACK path consistently throughout the dependency build. A checked monolithic XCFramework can hide those compiled dependencies behind the C ABI; the app does not need Java/JNA, Android services, CocoaPods, React Native, Unity or the community Swift wrapper.

## Architectures to qualify

| Destination | Required coverage | Present evidence |
| --- | --- | --- |
| iPhone/iPad | `arm64-apple-ios` | Actual 36,384,888-byte arm64 slice, 223 Mach-O objects; iOS minimum 10.3 / SDK 15.2. Device fat archive also contains armv7/armv7s. |
| Apple Silicon simulator | `arm64-apple-ios-simulator` | Actual 36,358,904-byte arm64 slice, 223 Mach-O objects; explicit iOS Simulator platform, minimum 14.0 / SDK 15.2. |
| Intel simulator | `x86_64-apple-ios-simulator` | x86_64 slice exists in the separate simulator fat archive. No simulator link has run. |

Device arm64 and simulator arm64 need separate XCFramework platform variants. `lipo -archs` alone cannot distinguish them. On Mac, verify ZIP SHA-256 before extraction, inspect the XCFramework `Info.plist` and every selected Mach-O object's platform/minimum-OS metadata, inspect undefined symbols, and perform device and simulator links. An advertised iOS 13 package minimum does not prove its embedded library's minimum or require raising the app's minimum. No arm64e-only, watchOS, macOS or Catalyst slice is required for the requested iPhone feature.

## Exact Android 24-model inventory

Every row below matches the cached Android URL and byte size and an entry in the official JSON. All matched entries report `obsolete: "false"` at inspection time. Each model link is the full download URL. Sizes are **compressed ZIP bytes**, not installed footprints. All 24 complete archives now match these publisher MD5 values and have separately measured SHA-256 pins in `VoskVerifiedModels.swift`. Every ZIP member CRC passed. License labels are from the official HTML table; archive README/COPYING notices were inspected and retained in ingestion metadata and installed files.

| Android language | Exact model / URL | ZIP bytes | Published MD5 | Listed license |
| --- | --- | ---: | --- | --- |
| English `en` | [vosk-model-small-en-us-0.15](https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip) | 41205931 | `09ab50ccd62b674cbaa231b825f9c1cb` | Apache-2.0 |
| Spanish `es` | [vosk-model-small-es-0.42](https://alphacephei.com/vosk/models/vosk-model-small-es-0.42.zip) | 39817833 | `2d5c94f9859a84881a0ef744738ebd31` | Apache-2.0 |
| Chinese `zh` | [vosk-model-small-cn-0.22](https://alphacephei.com/vosk/models/vosk-model-small-cn-0.22.zip) | 43898754 | `d1a8e82933dcc7632667c036b0bb3dbb` | Apache-2.0 |
| Hindi `hi` | [vosk-model-small-hi-0.22](https://alphacephei.com/vosk/models/vosk-model-small-hi-0.22.zip) | 44458845 | `80f1265262c9a8a515f2707498e1b485` | Apache-2.0 |
| Persian `fa` | [vosk-model-small-fa-0.42](https://alphacephei.com/vosk/models/vosk-model-small-fa-0.42.zip) | 53431220 | `cc2b18af256ffab2c44055f6a02ecb3d` | Apache-2.0 |
| French `fr` | [vosk-model-small-fr-0.22](https://alphacephei.com/vosk/models/vosk-model-small-fr-0.22.zip) | 42233323 | `8873b1234503f6edd55f54bfff31cf3e` | Apache-2.0 |
| Russian `ru` | [vosk-model-small-ru-0.22](https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip) | 46236750 | `d1759dc83eb8fd87850129afbd9f4b7b` | Apache-2.0 |
| Portuguese `pt` | [vosk-model-small-pt-0.3](https://alphacephei.com/vosk/models/vosk-model-small-pt-0.3.zip) | 32453112 | `458c69371c5a0b9ab6ee8fa417bf89da` | Apache-2.0 |
| German `de` | [vosk-model-small-de-0.15](https://alphacephei.com/vosk/models/vosk-model-small-de-0.15.zip) | 46499967 | `4f21f92c0897b48287ef8839420608eb` | Apache-2.0 |
| Japanese `ja` | [vosk-model-small-ja-0.22](https://alphacephei.com/vosk/models/vosk-model-small-ja-0.22.zip) | 49704573 | `0e3163dd62dfb0d823353718ac3cbf79` | Apache-2.0 |
| Korean `ko` | [vosk-model-small-ko-0.22](https://alphacephei.com/vosk/models/vosk-model-small-ko-0.22.zip) | 86914329 | `fa8029a173787a159e0e72fe6135f890` | Apache-2.0 |
| Italian `it` | [vosk-model-small-it-0.22](https://alphacephei.com/vosk/models/vosk-model-small-it-0.22.zip) | 49665141 | `fbd8f9c72cbb8c3dfa3e4581bd3585f4` | Apache-2.0 |
| Ukrainian `uk` | [vosk-model-small-uk-v3-small](https://alphacephei.com/vosk/models/vosk-model-small-uk-v3-small.zip) | 143914407 | `3188e41b4a38369d8b9527d0149616ab` | Apache-2.0 |
| Gujarati `gu` | [vosk-model-small-gu-0.42](https://alphacephei.com/vosk/models/vosk-model-small-gu-0.42.zip) | 108054987 | `4595a6f0cc0c88fee6eec7d80496fc10` | Apache-2.0 |
| Polish `pl` | [vosk-model-small-pl-0.22](https://alphacephei.com/vosk/models/vosk-model-small-pl-0.22.zip) | 52979372 | `91cbbd6231320467da672be31827b6ac` | Apache-2.0 |
| Dutch `nl` | [vosk-model-small-nl-0.22](https://alphacephei.com/vosk/models/vosk-model-small-nl-0.22.zip) | 40441176 | `4582e1f20d6849099da08511f9797017` | Apache-2.0 |
| Turkish `tr` | [vosk-model-small-tr-0.3](https://alphacephei.com/vosk/models/vosk-model-small-tr-0.3.zip) | 36855784 | `198511631860597639a0ebf779263fcf` | Apache-2.0 |
| Vietnamese `vi` | [vosk-model-small-vn-0.4](https://alphacephei.com/vosk/models/vosk-model-small-vn-0.4.zip) | 33656337 | `b31b474a1ef75488c5fa575f8e2a1269` | Apache-2.0 |
| Czech `cs` | [vosk-model-small-cs-0.4-rhasspy](https://alphacephei.com/vosk/models/vosk-model-small-cs-0.4-rhasspy.zip) | 46088666 | `df5ddac5ee8632f6b46a6fc751953286` | MIT |
| Uzbek `uz` | [vosk-model-small-uz-0.22](https://alphacephei.com/vosk/models/vosk-model-small-uz-0.22.zip) | 51061189 | `4d75acfef76fe919c8fb68cd1179c182` | Apache-2.0 |
| Esperanto `eo` | [vosk-model-small-eo-0.42](https://alphacephei.com/vosk/models/vosk-model-small-eo-0.42.zip) | 43839401 | `3e9319ca789fa06fd3efa68d51c85d6b` | Apache-2.0 |
| Kazakh `kk` | [vosk-model-small-kz-0.42](https://alphacephei.com/vosk/models/vosk-model-small-kz-0.42.zip) | 59697294 | `1c7dc487ac5e0c24acfa7566c106ba2d` | Apache-2.0 |
| Tajik `tg` | [vosk-model-small-tg-0.22](https://alphacephei.com/vosk/models/vosk-model-small-tg-0.22.zip) | 51879043 | `fca4e40de915a5bd2f30e32d60af45c0` | Apache-2.0 |
| Catalan `ca` | [vosk-model-small-ca-0.4](https://alphacephei.com/vosk/models/vosk-model-small-ca-0.4.zip) | 43405881 | `5dc7901815fef3dc8b784b31f309385c` | Apache-2.0 |

Catalogue aliases differ from Android/user-facing language codes: `en` → `en-us`, `zh` → `cn`, `uk` → `ua` in JSON, `kk` → `kz`, `vi` → `vn`. Ukrainian's filename and JSON version also differ (`uk-v3-small`, version `0.3`); pin the filename/URL rather than synthesizing it from version and language fields.

Total compressed payload for all 24: **1,288,393,315 bytes = 1,228.71 MiB = 1.20 GiB**. Individual downloads range from 30.95 MiB (Portuguese) to 137.25 MiB (Ukrainian). Gujarati is 103.05 MiB and Korean 82.89 MiB. The complete archive payloads total **2,758,240,586 uncompressed bytes** (before filesystem allocation, receipts and temporary staging). Portuguese/Turkish 0.3 have the legacy flat Vosk layout; the store explicitly supports it.

The official model catalogue establishes MD5 values, not SHA-256 values. The user explicitly authorized ingestion of all 24 exact archives into Temp. `tools/ingest_extera_vosk.py` checks HTTPS origin, published size and publisher MD5 before ZIP inspection, verifies every CRC and records SHA-256 and expansion bounds. Truncated downloads were quarantined; HTTP Range continuation completed the six remaining archives without bypassing any pin. Runtime uses the resulting SHA-256 manifest before extraction. These are measured, checksum-gated ingestion pins, not falsely attributed publisher SHA-256 metadata.

## Android behavior to preserve

Android enumerates a fixed catalogue and considers a language installed when its app-owned language directory exists, is nonempty, and no `model.zip` remains. Download reports stream progress, extracts the ZIP's top directory into the language directory and removes the ZIP. The UI selects a requested language after successful installation. Recognition refuses unsupported or missing models, opens a model by path, decodes audio to PCM, accumulates utterance results and appends the final result. Deleting unloads a cached model and recursively removes its directory. The cached `ChatsPreferencesActivity.kt` delete flow sets the selected recognition language to `none` when that model is removed.

iOS can implement those user-visible semantics using app-owned data in Application Support, excluded from backup. Physical removal means unlinking the owned files and confirming their absence; it does not imply secure erasure of APFS blocks or immediate reclamation of snapshots. It is more direct than releasing Apple's shared model reservation. Model files must stay outside the signed app bundle to support installation/removal.

Use stronger installation bookkeeping than Android's nonempty-directory heuristic: download to staging, verify the pinned checksum, reject unsafe ZIP paths/symlinks and expansion limits, validate expected model structure/loadability, write a completion manifest, then atomically publish the model directory. On error, cancellation or process termination, do not report staging data as installed. Use a cancellable URLSession task with measured byte progress. Check disk capacity using an expansion bound derived during artifact ingestion, rather than asserting a ZIP's compressed size is its installed footprint.

Serialize recognition/model maintenance with leases. Deletion must cancel or wait for active recognition, release recognizers and cached native models, remove the language directory, verify absence, and only then clear the selected Vosk model to None. Report file-removal failures. The C API reference-counts models: freeing the model handle while a recognizer still owns it does not release all native resources. Avoid caching 24 loaded models; unload on memory pressure and idle time.

Vosk is local recognition and needs no Apple Speech authorization for an already downloaded voice file. Download requires network access; recognition must not trigger an implicit download or server fallback. iOS suspension still constrains long-running/background work; no always-running Android service needs to be reproduced. Settings backup can preserve backend/language preferences, but cannot imply that models exist after restore.

## Existing audio path and integration choices

Current voice-file route in `submodules/TelegramUI/Components/Chat/ChatMessageInteractiveFileNode/Sources/ChatMessageInteractiveFileNode.swift:443` obtains the complete Telegram resource, calls `convertOpusToAAC`, then `transcribeAudio(path:appLocale:)`. The accepted None guard runs before conversion; callback identity checks protect reused message nodes. Instant-video currently uses the Telegram server transcription route and is a separate integration consumer.

`submodules/Media/ConvertOpusToAAC/Sources/ConvertOpusToAAC.swift:13` reads `SoftwareAudioSource` and writes AAC in an m4a container, mono, 48 kHz, 32 kbps. **AAC/m4a bytes cannot be passed to `vosk_recognizer_accept_waveform`.**

`submodules/MediaPlayer/Sources/SoftwareVideoSource.swift:443` exposes `SoftwareAudioSource(path:)`, `readSampleBuffer()` and `readFrame()`. Its normal initializer configures the decoder for mono/48 kHz. `FFMpegAudioFrameDecoder.swift:28` resamples to packed signed 16-bit native-endian PCM. The existing dependencies already decode Opus; no additional codec package is inherently required.

Preferred future route: dispatch the Vosk branch before AAC conversion, read the original resource through `SoftwareAudioSource`, feed bounded PCM chunks through a tested converter to mono Int16 at 16 kHz, then call `vosk_recognizer_new(model, 16000)` and `vosk_recognizer_accept_waveform`. Reuse the existing FFmpeg resampler with an explicit output-rate API, or bridge CMSampleBuffers to AVAudioConverter. Drain decoder/converter output at EOF and test delayed/multiple-frame output. `readFrame()` returning nil can also mean decoder non-output/error; a naive `while let` loop is not a demonstrated lossless EOF protocol. `readSampleBuffer()` loops internally but still needs EOF/drain qualification for the intended files.

An alternative avoids changes to the consumer's AAC preparation initially: decode its m4a using AVAudioFile, resample using AVAudioConverter, and stream PCM to Vosk. It adds an AAC encode/decode step and temporary storage but uses public APIs and can establish an initial native smoke test. A third option is feeding the existing 48 kHz PCM with a recognizer configured for 48000: inspected upstream `model.cc`, including tag v0.3.45, enables MFCC/fbank downsampling. Confirm this behavior in the selected binary/models before choosing it; never label 48 kHz samples as 16 kHz.

The byte-buffer C API length is in bytes; the short/float variants consume sample counts. Check `accept_waveform` for `-1` errors, collect utterance JSON when it returns `1`, and append `final_result` at EOF. Copy borrowed result strings before subsequent recognizer calls. Use a serial worker queue, bounded memory, disposal/settings cancellation and an absolute deadline. Preserve existing consumer delivery and node identity guards; avoid audio/transcript logging. Do not require a speaker-identification model for ordinary transcription merely because the upstream example constructs one.

## Minimum Bazel integration

The workspace already declares rules_cc, rules_swift, rules_apple and Apple toolchains in `MODULE.bazel`. `rules_apple` is a local-path override; its checkout directory is empty on this Windows workspace. Its recorded gitlink is `485016eb5b0948cc17307064e7977a6d68e94046` from `ali-fareed/rules_apple`. The public [`apple/apple.bzl`](https://github.com/ali-fareed/rules_apple/blob/485016eb5b0948cc17307064e7977a6d68e94046/apple/apple.bzl) at that pin exports `apple_static_xcframework_import`; its implementation declares `sdk_dylibs`, `sdk_frameworks` and `xcframework_imports`. Thus an XCFramework import is supported by the pinned rule source, although no Bazel evaluation was run here.

The concrete next integration is a small native target, a C header/module, a Swift adapter and an app-owned model store:

```starlark
# Design sketch for an extracted, checksum-verified native archive.
load("@build_bazel_rules_apple//apple:apple.bzl", "apple_static_xcframework_import")

apple_static_xcframework_import(
    name = "VoskNative",
    xcframework_imports = glob(["libvosk.xcframework/**"]),
    sdk_dylibs = ["c++"],
    sdk_frameworks = ["Accelerate"],
    visibility = ["//visibility:public"],
)
```

Use a checksum-bearing `http_archive` or the repository's established checked artifact mechanism for the native SDK; retain its license/NOTICE bundle. Expose the exact matching `vosk_api.h` through a Clang module, with header/module packaging adjusted to the inspected XCFramework layout. If slices are supplied as separate `.a` archives instead, use platform-aware imports/selects for device versus simulator; a CPU-only arm64 select is insufficient. Keep `alwayslink` off unless actual linking proves it necessary.

The Swift runtime adapter needs Foundation, SwiftSignalKit and the C module. Its audio preparation needs AVFoundation/CoreMedia and either UniversalMediaPlayer's existing decoder or an injected PCM producer. Prefer a separate Vosk backend adapter so the current small LocalAudioTranscription target does not acquire the whole media-player dependency graph unnecessarily. `MediaPlayer/BUILD` names that module `UniversalMediaPlayer`; inspect the full graph for cycles before adding a dependency. Neither its current BUILD nor LocalAudioTranscription's current BUILD directly references the other.

Model installation additionally needs URLSession, streaming digest verification and ZIP extraction. A ZipArchive target is already referenced by `submodules/ChatImportUI/BUILD` as `//third-party/ZipArchive:ZipArchive`; that checkout is absent locally, so inspect its pinned extractor's traversal/symlink behavior before reuse. No new ZIP dependency can be claimed necessary yet. The speech settings/controller needs a provider-aware Vosk catalogue and installed-state UI, separate from Apple AssetInventory. Add a Vosk backend setting and language/model identifier with restore semantics; do not reinterpret an existing Apple locale/reservation as an installed Vosk model.

Native models should download on demand rather than entering the IPA or Bazel runtime resources. Ship metadata and license text with the app; keep model files and installation state in the app's data container. Validate release symbol exports under `Telegram/CLAUDE.md` when adding targets to the app's framework boundary. CI should verify SDK checksums and slices, build both destinations, and exercise a small explicit model fixture only after its artifact pin is established.

## Size, memory and effort

| Quantity | Evidence / planning implication |
| --- | --- |
| Community multi-slice SDK ZIP | Exact published size 48,290,797 B / 46.05 MiB. This is a download size, not incremental IPA size. |
| App binary increase | Unmeasured: selected device slice, static dead stripping, debug symbols and compression determine it. Measure matching release IPAs/link maps before and after. No exact installed SDK size is defensible from a multi-slice ZIP's length. |
| Model download per language | 32,453,112–143,914,407 B; complete pinned catalogue 1,288,393,315 B. No model download is needed for users who do not select Vosk. |
| Installed model storage | Exact uncompressed payload total 2,758,240,586 B; per-model bounds are pinned. Peak installation includes compressed staging plus extracted content and any previous version. Filesystem allocation overhead and device free-space behavior remain unmeasured. |
| Recognition memory | Official guidance: typical small model about 300 MB at runtime; this is not a measurement for each of these 24 models or for Telegram plus Vosk. Qualify especially Ukrainian/Gujarati and the oldest supported device. |
| PCM working set | At 16 kHz mono S16, 32,000 B/s: a fully buffered 180-second input would be 5,760,000 B. At 48 kHz it is 17,280,000 B. Stream chunks instead. Native model/decoder working memory dominates this buffer. |

Planning estimate for one engineer familiar with this codebase, assuming a qualified SDK is available: **13–23 engineering days (roughly 3–5 working weeks)**, not elapsed vendor delivery time.

| Work | Estimate |
| --- | ---: |
| SDK qualification, Bazel header/import and device/simulator smoke links | 2–4 days |
| PCM bridge, native recognizer ownership, results, cancellation and deadline | 3–5 days |
| Pinned catalogue, installation/cancellation/recovery, extraction and real deletion | 3–5 days |
| Settings/provider selection, None behavior, migration and backup wiring | 2–3 days |
| Device/resource tests, all-language smoke fixtures and recorded UI verification | 3–6 days |

If the native SDK must be built reproducibly, budget an additional **5–10 engineering days** for the Kaldi/OpenFST/Accelerate cross-build and multi-platform artifact pipeline, with wider uncertainty for undocumented patches. SHA-256/model-license acquisition and access to reliable language fixtures are schedule dependencies. These are estimates, not completed work or promised recognition accuracy. A native library loading English successfully does not qualify the other 23 models.

## Next implementation boundary and acceptance

Independent Vosk modules, native wrapper, PCM adapter, model store, settings and model-management UI are now implemented. Root receives precise dependency/backend/runtime/backup/string/CI hunks in `docs/integration/extera-vosk-root.patch`; frozen Apple source files remain intact. Device/simulator linking and real native model loading are the next external validation boundary. The candidate SDK's missing source/license manifest remains explicit in `submodules/VoskNative/NOTICE.md`.

After the native proof, implement the fixed manifest/store and Vosk adapter, then wire settings and consumers. Acceptance must include all 24 entries and alias mapping; success and cancel/retry/relaunch during install; corrupt checksum/ZIP and low disk; utterance accumulation/EOF/empty input; stereo and sample-rate conversion; deadline after partial output; settings changes/node reuse; airplane-mode recognition; deletion during use and confirmed file removal; selected-model deletion to None; backup restore with missing files; memory-pressure/idle unloading; and device/simulator release links. Test model loading across the catalogue plus representative language audio for each entry, documenting fixture provenance and accuracy limits.

No Swift/Xcode/iOS simulator is available on this Windows host. Binary slice inspection, all-model checksum/CRC/footprint checks and production C inflater compilation/tests **have executed**. The compiled C helper also drained all 345 deflated members across the 24 archives. Swift host tests were prepared but not run; iOS typechecking/linking, real recognition, device performance and recorded UI frames remain **unexecuted**. Under AGENTS.md the new visual UI requires simulator recordings and labelled frame evaluation before visual acceptance. See the runtime document for exact commands and the remaining acceptance matrix.
