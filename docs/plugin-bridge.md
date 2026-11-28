# Android plugin bridge: implementation and validation ledger

## 2026-11-25 compatibility checkpoint

The current local change set adds a shared installation/detail window for chat
attachments and document-picker imports, disabled-plugin updates with settings
preservation and preview-source SHA-256 verification, persistent generic metadata,
and a coordinated 4 MiB source limit. Installation does not activate Python code.

Portable SDK work covers Android settings/metadata/hook constructors, account-bound
client helpers and callbacks, generation-owned cleanup, text formatting with UTF-16
entities, basic alert builder callback/return semantics, log/file/URI helpers, and
explicit native lookup instead of fabricated TL constructor objects. Atomic
`settings.replace` and generation-checked settings refresh extend the transport.
Outgoing send hooks use a validated chain with CANCEL/MODIFY_FINAL semantics and
reject stale callback results after disable/reload. Application account/context,
theme-value, display-metrics, bounded clipboard-write and one message-context-menu
adapter remain documented subsets; all other menu types still require host work.

The [corpus report](plugins-corpus-compatibility.md) supersedes the former
19-file inventory as the scope assessment: 493 `.plugin` attachments and 21
archives, 737 source units. Archive inspection is not archive installation.
Native method interception, complete controllers/requests, menu types beyond
`MESSAGE_CONTEXT_MENU` and Android graphics/media remain independent missing
work on the Swift host. Since 2026-11-26 version policy, worker threads and
package loading are implemented on the Python side only (portable tests against
a synthetic host; nothing compiled or run on a device, and the Swift importer
does not accept packages). See [`plugins-ios-api.md`](plugins-ios-api.md) and
the bridge preflight numbers in the corpus report; a static preflight pass is
not proof that a plugin works.

Validation available here is portable Python contracts, static source wiring,
offline packaging fixtures and corpus analysis. Native compilation, native tests,
device execution and the [recorded visual acceptance](plugins-installation-validation.md)
remain pending on macOS/Xcode. Earlier counts below describe historical
checkpoints, not the result of the current change set. The complete API port and
the goal that almost all supplied plugins work are **not established**.

Branch: `plugins-test`, based on `85d6da613f08e0a8a95ce3539c0e0d3a56b51243`.

This branch is implementing a compatibility bridge for the supplied Android Python plugins. The objective is source compatibility through explicit SDK/Java/UIKit adapters. The current checkpoint is the runtime/SDK/manager foundation; it is not a claim that the nineteen original plugins execute unchanged or that Android FPS has been matched.

## Implemented checkpoint

- AST-only plugin inspector with explicit implementation manifests and line evidence. No plugin source executes during inspection. All nineteen supplied files parsed successfully; user sources are not committed.
- Embedded CPython facade on a dedicated OS thread, native-owned dispatch context and asynchronous main-thread completions.
- Python SDK lifecycle, settings, declarative settings rows, callback/token lifetime, virtual Java class/member/array/proxy facade and explicit unsupported-API errors.
- Native owner-scoped host and bounded UIKit view registry; partial FrameLayout/LinearLayout/TextView/ImageView adaptation and native animation/batch entry points. The layout model is intentionally documented as partial.
- Plugin manager reachable from AyuGram settings: import, inspection, user-driven enable/disable/delete, settings and a preview surface. Plugins do not automatically execute at startup. Its list follows exteraGram's `PluginsActivity` (one card per plugin with switch, share, pin, settings and delete; pinned first, then by name; name search; empty state; compact view switch; an icon slot for `__icon__ = "Pack/N"`, 56 pt above the name or 49 pt beside it in the compact view); the catalog, the engine switch and the info screen are not ported, the app does not yet supply the sticker pictures for the icon slot (`AyuPluginManagerViewController.iconProvider` is unset, so no card shows one), and the layout has only been rendered off-device.
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

## Atmospheric Snow: focused native compatibility route

The current focused extension concerns **only** `atmospheric_snow` / NewYear Interface 1.0.1 by `@coshize`, with source SHA-256 `bbda8727d253e02542c1c1f51dca1d39d235e2a310b4ba096e5e6305472a6763`. The user attachment is not bundled or committed. Its source inventory and exact settings catalogue are in [`../apk-analysis/atmospheric-spec.md`](../apk-analysis/atmospheric-spec.md) and [`../apk-analysis/atmospheric-settings.json`](../apk-analysis/atmospheric-settings.json).

- The plugin manager recognizes the verified bytes at import, rechecks them at enable, and selects an explicit native adapter. A claimed plugin ID/version alone is insufficient. The attachment is not executed by Python and Android hook/Canvas compatibility is not falsely advertised.
- All 15 original settings remain in `AyuPluginBridge.v1.atmospheric_snow`. The v1 migration resets the original seven snow selectors when its marker is absent/invalid/<1. Defaults are 50 mixed particles, 45% drawing size, 135% alpha, normal vertical speed and light breeze. There are no invented glass/profile-style or intensity settings.
- The native settings route does not require starting the interpreter. Typed UI attachments use `AyuAtmosphericHost`; native dynamics/materials use `AyuAtmosphericSnow`. Neither drawing nor display clocks wait on Python or serialize settings per frame.
- Native surface registration, user enable, settings update, generation revoke and disable/delete form one application path, not an isolated preview. Navbar pre-content wash/selection and post-content decorations are separate draw passes.
- Concrete owners: root navigation snowfall/page/theme events; modern tab-bar lens/selected-tab target; navigation and heading glass; folders; search placeholder, close and the actual legacy/modern active-field background; composer; profile avatar/upload-overlay, action buttons, pane tabs, and grouped regular/editing sections. Glass/inline search uses its existing placeholder-glass owner, not an invented background. Profile visibility follows controller/tab selection, search, scrolling and live-view lending to expansion; removed buttons/sections detach immediately. Grouped cards exclude header/comment rows, preserve UIKit's 26-point corners, and only draw viewport-visible ends.
- Ordinary disable preserves settings; deletion clears only this plugin's owner namespace. A native reset row is clearly marked as an iOS addition rather than attributed to the Android source.

**Verification:** native test sources have been added but are not evidence of a passing run. Compilation is to be checked by the authorized GitHub IPA workflow; no local native build is run in this Android environment. Recorded-frame checks on iPhone/simulator remain required for the real layout, all styles/palettes, selected tabs, avatar/action transitions, card clipping and touch pass-through. Byte-identical Android/iOS raster output and measured FPS are not claimed.
