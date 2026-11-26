# Pinned native SDK: binary evidence and provenance remedies

2026-11-26. Read-only qualification. No SDK/model pin or existing manifest changed. Binary identity and platform data below were read from the checksum-verified release ZIP. No notices were inferred or added to the frozen NOTICE file.

## Exact artifact

- URL: <https://github.com/ishantve/VoskSpeechKit/releases/download/0.1.2/libvosk.xcframework.zip>
- ZIP: **48,290,797 bytes**, SHA-256 `1891ad61293278363f75f2b4e5313c606183d0acd14f4b1ff1a71f5629c676f9`.
- Wrapper release source: [`2ffd17a4c3d62290e4601459e01454753d4411a7`](https://github.com/ishantve/VoskSpeechKit/tree/2ffd17a4c3d62290e4601459e01454753d4411a7).
- The source-pinned [`Package.swift`](https://github.com/ishantve/VoskSpeechKit/blob/2ffd17a4c3d62290e4601459e01454753d4411a7/Package.swift) names this exact URL/checksum as a binary target. It proves wrapper-to-asset identity, not native source origin.
- `Info.plist`: device `ios-arm64_armv7_armv7s`; simulator `ios-arm64_x86_64-simulator`. XCFramework metadata contains only two static libraries and their platform/architecture declaration; it does not supply a native source revision, recipe or license manifest. No headers/license/NOTICE payload is present in the ZIP.

| Static library inside `libvosk.xcframework` | Fat file bytes | SHA-256 |
| --- | ---: | --- |
| `ios-arm64_armv7_armv7s/libvosk.a` | 98,579,576 | `a6705b01390ec42a33f4f3b83ac4f2d760d74bf15e5a82cf7ea1710aca1115f9` |
| `ios-arm64_x86_64-simulator/libvosk.a` | 73,146,600 | `7933cf4794fad8f066de78ed1b6f70797b41ce3f43b5944e151c6a1f6c08d76c` |

Each FAT record contains a BSD archive with **223 Mach-O objects**. Offsets are decimal from the beginning of that fat `.a`; hashes cover the exact thin archive bytes, without rebuilding or stripping.

| Platform declaration | Architecture (CPU type/subtype) | Offset | Thin bytes | Object load command / minimum / SDK | Thin SHA-256 |
| --- | --- | ---: | ---: | --- | --- |
| Device | armv7 (`0x0000000c` / 9) | 68 | 31,029,208 | `LC_VERSION_MIN_IPHONEOS` / 10.3.0 / 15.2.0 | `58ef54445171e8296bb447ce8278b6fecc8f2610db9d256c5f15c6d12ea52e69` |
| Device | armv7s (`0x0000000c` / 11) | 31,029,276 | 31,165,408 | `LC_VERSION_MIN_IPHONEOS` / 10.3.0 / 15.2.0 | `ef15e3e1f4e6ddfed9c90716c02eb6f9fe2a434262f68aab6302d6a716a29c5a` |
| Device | arm64 (`0x0100000c` / 0) | 62,194,688 | 36,384,888 | `LC_VERSION_MIN_IPHONEOS` / 10.3.0 / 15.2.0 | `ee6e8c195ca009a2729cca8812754bf04d906e8c0847509e6f47586d6b486bcb` |
| Simulator | x86_64 (`0x01000007` / 3) | 48 | 36,787,648 | `LC_VERSION_MIN_IPHONEOS` / 10.3.0 / 15.2.0 | `86c47a5c99d23c79b8bd922ccffc12d4896a68f86ffe248ad587d176f7ca580b` |
| Simulator | arm64 (`0x0100000c` / 0) | 36,787,696 | 36,358,904 | `LC_BUILD_VERSION`, platform 7 (iOS Simulator) / 14.0.0 / 15.2.0 | `873ec6ce80f1462909a3ba5441a26ef75614729c768a0e878ff88e1907a22e6d` |

Every object in a given slice carries the same platform/minimum/SDK tuple shown. Legacy `LC_VERSION_MIN_IPHONEOS` does **not** encode the modern device/simulator distinction: x86_64 simulator classification also relies on the containing Info.plist and architecture. Do not label that x86_64 load command as explicit Simulator platform. Device arm64 versus simulator arm64 is established by separate fat libraries and the latter's explicit platform 7.

All five slices define all eight used C functions: `vosk_model_new`, `vosk_model_free`, `vosk_recognizer_new`, `vosk_recognizer_accept_waveform`, `vosk_recognizer_result`, `vosk_recognizer_final_result`, `vosk_recognizer_free`, `vosk_set_log_level`. This proves symbol availability, not ABI/behavior correctness or a successful app link. The current `Vosk.BUILD` imports the XCFramework normally and declares libc++ and Accelerate; it does not force-load every object. Archive-wide undefined symbols include Kaldi training functions and system math functions. Only an ordinary final link/map can determine the reachable closure.

All 223 simulator arm64 objects contain an `LC_BUILD_VERSION` tool entry: tool **3**, packed version `0x02c70000` = **711.0.0**. LLVM's [MachO.h definition](https://github.com/llvm/llvm-project/blob/llvmorg-13.0.0/llvm/include/llvm/BinaryFormat/MachO.h#L505) identifies tool 3 as **LD** (linker), not clang. Thus an LD version is recorded; no clang or Swift tool entry is recorded. The other slices have only the legacy deployment command. A scan found embedded Kaldi source assertion paths under `.../vosk_source/ios-build/ios/kaldi_dev_embed/kaldi/...`; that is a path string, not a commit or authenticated builder identity. No exact compiler/Xcode version, native source SHAs or build invocation was established. Neither SDK 15.2 nor LD 711.0.0 is sufficient evidence to identify an exact complete Xcode/compiler toolchain.

Reproduce the binary report without network/extraction:

```sh
python3 docs/integration/extera-vosk-sdk-evidence.py /path/to/extera-vosk-artifacts
```

The script verifies the pinned ZIP size and SHA-256 before ZIP inspection, checks all member CRCs, then parses each archive/object and emits hashes/platforms/symbol coverage. Its captured output is `extera-vosk-sdk-evidence.json`. The original SDK and model manifest remain unchanged.

## Remedies with verified links

**Official SDK/source distribution is the strongest available route.** The current [official iOS install section](https://alphacephei.com/vosk/install#ios-build) says “Available on request” and directs requests to `contact@alphacephei.com`. An upstream maintainer repeats the requirement in [issue 1679, comment 2552355733](https://github.com/alphacep/vosk-api/issues/1679#issuecomment-2552355733); [issue 45, comment 618687809](https://github.com/alphacep/vosk-api/issues/45#issuecomment-618687809) explicitly refers to distributing the iOS **code** on request. These links establish a remedy channel; they do not prove the materials will include all missing provenance. No email or issue was sent.

Root's concrete request should identify the required arm64 device + arm64 simulator platforms and request: downloadable artifact with SHA-256; exact Vosk, Kaldi, OpenFST and other included dependency commits/submodule SHAs; every patch; build scripts; exact Xcode/Apple clang/SDK versions, target triples, deployment minima and compiler/linker flags; archive-combination commands; full licenses/NOTICE/attributions for code actually linked. If offering a private artifact, request permission/terms for redistribution. Then verify it independently, perform the ordinary final link and actual-model tests, and submit a separately reviewed manifest change. Current pins stay frozen until root authorizes replacement.

**Ask the current repackager for the native artifact's origin.** Use the [VoskSpeechKit issue tracker](https://github.com/ishantve/VoskSpeechKit/issues) with the precise ZIP/fat/thin hashes above. Ask whether the `.a` files were built by that project or obtained elsewhere, and ask for the original upstream artifact plus the same revision/toolchain/notice evidence. The pinned [`scripts/build-ffi-xcframework.sh`](https://github.com/ishantve/VoskSpeechKit/blob/2ffd17a4c3d62290e4601459e01454753d4411a7/scripts/build-ffi-xcframework.sh) builds **VoskSpeechFFI** through SwiftPM/Xcode, not native Vosk/Kaldi/OpenFST. Its [CI workflow](https://github.com/ishantve/VoskSpeechKit/blob/2ffd17a4c3d62290e4601459e01454753d4411a7/.github/workflows/ci.yml) builds wrapper/FFI simulator schemes, not the native archive. Neither is a native reproduction recipe. No issue/comment was published.

**A fresh source build is possible work, but an executed reproducible iOS build is not established.** The independently inspected Vosk revision [`4ab9821510b488efb7740094714a130bd3545e90`](https://github.com/alphacep/vosk-api/tree/4ab9821510b488efb7740094714a130bd3545e90) is a concrete replacement-source candidate, not the source identity of the pinned binary. Its [`src/Makefile`](https://github.com/alphacep/vosk-api/blob/4ab9821510b488efb7740094714a130bd3545e90/src/Makefile) lists six C++ sources and the Kaldi/OpenFST library closure, exposes Accelerate selection, but its final rule still invokes `$(CXX) --shared`; setting `EXT=a` would only rename a shared output, not create a valid iOS static archive. A real source route must compile target-specific objects and create/merge actual archives, then package separate device/simulator libraries.

That Vosk tree's [Linux recipe](https://github.com/alphacep/vosk-api/blob/4ab9821510b488efb7740094714a130bd3545e90/travis/Dockerfile.manylinux) clones Kaldi's mutable `vosk` branch and OpenFST's mutable default branch; it is not a pinned iOS recipe. At this inspection those resolve to Kaldi [`bc5baf14231660bd50b7d05788865b4ac6c34481`](https://github.com/alphacep/kaldi/tree/bc5baf14231660bd50b7d05788865b4ac6c34481) and OpenFST [`18e94e63870ebcf79ebb42b7035cd3cb626ec090`](https://github.com/alphacep/openfst/tree/18e94e63870ebcf79ebb42b7035cd3cb626ec090). Kaldi default branch revision `a670447e047331150753fb42cc926a6d4faa2606` was also inspected; it is **different** from the `vosk` branch selected by the recipe and must not be silently substituted. These are observed source candidates, not a tested compatible iOS revision set. Kaldi's [configure](https://github.com/alphacep/kaldi/blob/bc5baf14231660bd50b7d05788865b4ac6c34481/src/configure) contains Darwin/Accelerate configuration but that alone does not prove cross-compilation to iOS simulator/device.

The corresponding source [Vosk COPYING](https://github.com/alphacep/vosk-api/blob/4ab9821510b488efb7740094714a130bd3545e90/COPYING), [Kaldi COPYING](https://github.com/alphacep/kaldi/blob/bc5baf14231660bd50b7d05788865b4ac6c34481/COPYING) and [OpenFST COPYING](https://github.com/alphacep/openfst/blob/18e94e63870ebcf79ebb42b7035cd3cb626ec090/COPYING) are source-specific evidence only. They do not establish the full component/notice inventory of the current SDK. Wrapper Apache licensing cannot supply missing native notices; no guessed copyright/NOTICE payload has been generated.

For root's next Mac build, pin the selected source trees and all patches/tool versions; record `xcodebuild -version`, `xcrun --sdk iphoneos --show-sdk-version`, the simulator equivalent, clang version and exact target flags in the build receipt. Build with separate arm64 iOS and arm64 iOS-simulator target triples/sysroots, inspect every output's `LC_BUILD_VERSION`, hash the finished thin/fat/XCFramework ZIP, and qualify actual model load/PCM fixtures. This is the acceptance needed for a replacement, not a claim that such a build ran on this Windows host. Until it executes, the remedy is the verified official/repackager acquisition path plus the explicit source-build gaps above.
