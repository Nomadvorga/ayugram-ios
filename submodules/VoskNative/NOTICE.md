# Native Vosk SDK identity and attribution

The application adapter uses the C API of Vosk, Copyright 2020–2021 Alpha Cephei Inc., licensed under Apache License 2.0. The declarations in `include/vosk_api.h` are a subset of upstream `src/vosk_api.h` at `4ab9821510b488efb7740094714a130bd3545e90`.

The currently pinned binary is redistributed by Ishant / Zibal Technologies in VoskSpeechKit 0.1.2 (tag commit `2ffd17a4c3d62290e4601459e01454753d4411a7`). Its package LICENSE states Apache-2.0 and attributes Alpha Cephei. The binary ZIP itself contains no LICENSE, NOTICE or header files. This repository's C/Swift adapter does not copy that package's Swift wrapper.

Archive URL: <https://github.com/ishantve/VoskSpeechKit/releases/download/0.1.2/libvosk.xcframework.zip>

Verified archive SHA-256: `1891ad61293278363f75f2b4e5313c606183d0acd14f4b1ff1a71f5629c676f9`.

The device archive includes arm64/armv7/armv7s; the simulator archive includes arm64/x86_64. The arm64 simulator objects have iOS Simulator platform metadata, minimum 14.0, SDK 15.2; arm64 device objects have iOS minimum 10.3, SDK 15.2. Static library inspection confirms the C symbols used by the adapter. BLAS and LAPACK references are consistent with Accelerate. No CUDA/MKL/OpenBLAS runtime was found among unresolved symbols in the required arm64 slices.

Embedded source path strings identify Kaldi/OpenFST and a `vosk_source/ios-build` build tree. They do not identify immutable source revisions or prove who produced this release. **Exact native Vosk/Kaldi/OpenFST revisions, patches, build recipe and complete third-party notices remain unestablished.** No source revision or engine version is inferred from the wrapper release tag. The additional unresolved Kaldi training symbols belong to archive objects and require an ordinary application link to determine whether they are reachable; do not force-load the whole archive.

Upstream license references: [Vosk COPYING](https://github.com/alphacep/vosk-api/blob/4ab9821510b488efb7740094714a130bd3545e90/COPYING), [Kaldi](https://github.com/alphacep/kaldi), [OpenFST](https://github.com/alphacep/openfst). Package license statement: [VoskSpeechKit LICENSE](https://github.com/ishantve/VoskSpeechKit/blob/2ffd17a4c3d62290e4601459e01454753d4411a7/LICENSE).

Official iOS acquisition remains available on request at <https://alphacephei.com/vosk/install>. No unsolicited email or other message has been sent. Before distribution, replace this candidate with an official or reproducibly built artifact, or obtain its missing native build/license manifest. This is a concrete provenance limitation of the inspected candidate, not an iOS platform limitation.

Acoustic models are independent artifacts. Their exact versions, SHA-256 pins, publisher MD5 values, expansion bounds and license labels belong to `VoskVerifiedModels.swift`; models download only on an explicit user request. All catalogue models are listed as Apache-2.0 except the Czech Rhasspy model (MIT). Archive notices are retained with installed model files and captured in the ingestion evidence.
