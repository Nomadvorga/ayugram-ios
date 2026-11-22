# Android plugin bridge: implementation and validation ledger

Branch: `plugins-test`, based on `85d6da613f08e0a8a95ce3539c0e0d3a56b51243`.

This branch is implementing a compatibility bridge for the supplied Android Python plugins. The objective is source compatibility through explicit SDK/Java/UIKit adapters. The current checkpoint is the runtime/SDK/manager foundation; it is not a claim that the nineteen original plugins execute unchanged or that Android FPS has been matched.

## Implemented checkpoint

- AST-only plugin inspector with explicit implementation manifests and line evidence. No plugin source executes during inspection. All nineteen supplied files parsed successfully; user sources are not committed.
- Embedded CPython facade on a dedicated OS thread, native-owned dispatch context and asynchronous main-thread completions.
- Python SDK lifecycle, settings, declarative settings rows, callback/token lifetime, virtual Java class/member/array/proxy facade and explicit unsupported-API errors.
- Native owner-scoped host and bounded UIKit view registry; partial FrameLayout/LinearLayout/TextView/ImageView adaptation and native animation/batch entry points. The layout model is intentionally documented as partial.
- Plugin manager reachable from AyuGram settings: import, inspection, user-driven enable/disable/delete, settings and a preview surface. Plugins do not automatically execute at startup.
- Bundled synthetic smoke plugin without Telegram/network actions.
- Checksum-pinned iOS Python packaging and CI test/build wiring are being integrated.

## Compatibility work remaining

| Area | Required by examples | Remaining work |
| --- | --- | --- |
| Telegram accounts, themes, dialogs, navigation | Theme per Account, Chats Menu, Music Tab | Actual context/provider adapters and supported virtual Java objects |
| Send hooks and message DTOs | Group Mentions, Fish Audio, Music Bridge, Profile Info | Exact text/entities/caption/reply/topic/account/silent/schedule semantics and lifecycle subscriptions |
| Telegram network TL objects and requests | Local Chat Archive, Message Cleaner, Music Tab, Profile Info | Supported TL schema objects, cancellation, flood waits and exact Int64 identities |
| Android UI/reflection | QuickStickers, Chats Menu, Player+, MD3 Loader | More views/layout overloads/drawables/Canvas, scoped hooks and native gesture arbitration |
| Python worker threads | Music Bridge, Fish Audio and several newer files | A supported execution/ownership model; currently rejected explicitly, not emulated by a successful stub |
| Multimedia/DSP | SpekGram, Player+ | iOS decoding/artwork/audio-state adapters; SpekGram includes JVM DEX and Android MediaCodec, so translating Python calls alone is insufficient |
| Browser content | SandBox | WKWebView adapter and explicit message/callback bridge; do not route every animation frame through Python |
| Device/security features | Security Manager, Screenshot Privacy, Ball | Camera/motion/screen-capture semantics and actual iOS permission/availability handling; no blanket Android OS equivalence |

A class or SDK symbol present in the facade is not proof that all of its methods are implemented. The host capability registry and the inspector manifest must reflect actual adapters. Defaults must fail on unsupported operations, especially account logout, deletion, message sending and camera access.

## Verification ledger

- Inspector: 24 synthetic tests passed locally with Python; source execution and network calls are not used.
- SDK: 33 synthetic tests passed (21 lifecycle/SDK tests and 12 HTTPS tests without live network). Dataclass/module identity, CPU budgets and generation cleanup are covered.
- Runtime packaging: 8 offline fixture tests passed, including the complete preparation path with native tooling replaced by explicit test fixtures. Real XCFramework packaging/signing is still unverified.
- Static corpus: 19/19 source files parsed; this verifies syntax/inventory only, not runtime compatibility.
- Native Swift/Objective-C/Bazel compilation: not yet verified in this iOS session. It requires macOS/Xcode.
- Visual validation, app-side integration, real plugin execution and frame-rate comparisons: pending.

## Performance acceptance

Use an optimized release build on a cool iPhone, low power mode off. Record device/OS/display refresh rate, active plugin set and corpus hashes. Compare the same chat, scrolling, keyboard, touch and animation scenarios with the bridge disabled/enabled; separately compare each plugin's Android reference behavior. Collect frame intervals (median/p95/p99), missed display deadlines, main-thread CPU, interpreter/adapter work, object/queue counts and memory. A configured refresh rate is not a measured frame rate.

Main must not synchronously wait for Python. Prefer native animations and display-server interpolation. Avoid a synchronous JSON request per element per frame; batch mutations, coalesce obsolete work, limit queues and revoke callbacks on unload. A blocking native/Python library call cannot be made preemptible merely by placing a cooperative trace around Python source.

Follow the repository's full `Make.py build` convention, pinned iOS unit test runner and recorded-frame visual verification rules. The existing IPA workflow now accepts pushes to `plugins-test`; that is a verification mechanism, not a build result.
