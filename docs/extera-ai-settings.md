# AI settings, frames 39–40

See `extera-ai-roles-reference-audit.md` for the source audit and migration, and
`extera-ai-user-agent.md` for the per-service HTTP client identifier selector.

Reference audited: exteraGram Android `b4d852f48f2734a0bee1a74a0939be621612262a`,
`AiPreferencesActivity.kt`, `AiConfig.kt`, `AiResponseAlert.java`, and the
service/role/history activities under `com/exteragram/messenger/ai`.

The iOS home has a robot hero, General / Telegram AI / Generation / Temperature
cards, and explicit chat/text-processing entry points. It uses standalone UIKit
views; the shared SGItemListUI renderer is unchanged by this work. Existing
service, role and history editors remain the destination of the General rows.

## Preference inventory

| Android preference | iOS storage and consumer | Default / parity |
| --- | --- | --- |
| `ENDPOINT` | `services`, `selectedServiceId`; service editor, model lookup, client generation | Configured REST services work. iOS starts with no configured service; Android falls back to a Gemini service. iOS shows the service name instead of the Android host label. |
| `ROLE` | Custom `roles`, immutable `ExteraAIRole.suggestions`, `selectedRoleId`; chat sends the selected system instruction | Exact Android Assistant/Summarizer/Proofreader suggestions; preview/select/copy, independent custom create/edit/save/use/delete, duplicate/stale checks and 64/1024 UTF-16 limits. Legacy edited roles and no-role selection are preserved. Explicit text actions retain their own instructions. |
| `HISTORY` | `saveHistory`; account-specific history editor and `requestHistory` | `true`, matching Android. Disabled history is neither sent nor appended. Existing saved history remains available. iOS has stricter account isolation and bounded retention. |
| `REPLACE_TELEGRAM_EDITOR` | Optional `useForTextProcessing`, resolved by `replacesTelegramEditor(isPremium:)`; TextProcessingScreen and native composer | Missing/null defaults to `!isPremium`; explicit legacy bool is preserved. All four routing consumers use the current account. Editor requests consume temperature/streaming, exclude chat history, reject structured rich input and defer to separate translation backends. Composer retains typed Apply. |
| `REPLACE_TELEGRAM_SUMMARIES` | New `replaceTelegramSummaries: Bool?`; `ChatMessageBubbleItemNode.toggleSummarization` and `ExteraAISummaryBridge` | Missing/null resolves to `!isPremium`, matching Android. The native summary button routes to the configured custom provider or Telegram using `replacesTelegramSummaries(isPremium:)`; errors never fall back to another provider. |
| `RESPONSE_STREAMING` | `responseStreaming`; chat/client and existing editor path | `true`, matching Android. SSE/JSON handling, stop/cancel and error boundaries remain in the client. |
| `SHOW_RESPONSE_ONLY` | New `showResponseOnly`; transcript, copy and explicit Apply | `false`, matching Android. Hides prompt/context presentation and excludes the prompt from copied/inserted output. Never rewrites the provider prompt or history payload. |
| `INSERT_AS_QUOTE` | New `insertAsQuote`; explicit Apply | `true`, matching Android. Typed callback emits `.plain(text:entities:)` with a UTF-16 `.BlockQuote` entity. Legacy string callback uses Markdown quote prefixes. Copy remains unquoted. |
| `TEMPERATURE` | Existing `temperature`; native slider and generation payload | `1.0`, matching Android's integer `10 / 10`. Range `0...2`, step `0.1`; touch commits at gesture completion, VoiceOver increments/decrements by `0.1`. Models may reject temperature; only an explicit provider error permits the existing retry without it. |

Service configuration retains HTTPS/custom endpoints, API Keychain storage,
manual/fetched models, per-service reasoning, test/cancel, selection and deletion.
Android's clipboard service triplet import shortcut is not reproduced: iOS uses
native text-field paste. Combined Test and Save now saves only the exact draft
that passed the request; separate Test and Save remain available. Provider preset
URLs/models match Android. There is no network request when opening settings or changing
the new generation controls.

Android's on-device service (`Gemini Nano`) and its reasoning/preview/fast-model
preferences have no iOS execution backend in this REST implementation. There are
no placeholder switches claiming to enable those features.

Existing `showEditor`, `showSummaries`, and `showInstantViewSummaries` are feature
visibility controls, independent of provider replacement. Their defaults remain
`true`. The Instant View action opens explicit AI text processing. Native bubble
summaries use the policy-selected backend. Custom summaries are additionally
offered on eligible incoming cloud text of at least 800 characters, so availability
does not require Telegram to have supplied a summarization attribute.

## Root integration contract

Configuration remains one Codable document at `extera.ai.configuration.v1`.
The new exact JSON keys are `showResponseOnly`, `insertAsQuote`, and
`replaceTelegramSummaries`. `cachedConfiguration` and successful
validation/encoding → cache publication → store write ordering are preserved.
No new path writes the raw configuration store key.

Root owns `ExteraSettingsBackup.swift`. The current shared tree includes these
explicit allowlist entries; the AI screen/consumer work does not edit that file:

| Backup key | Value and reset behavior |
| --- | --- |
| `extera.ai.showResponseOnly` | Strict bool; reset `false`. |
| `extera.ai.insertAsQuote` | Strict bool; reset `true`. |
| `extera.ai.replaceTelegramSummaries` | Strict string enum `automatic`, `enabled`, `disabled`. Reset restores `nil` (`automatic`), retaining the account-dependent default. |
| `extera.ai.temperatureTenths` | Integer `0...20`, default `10`, mapped to/from temperature by `Double / 10`. |

Integration of `extera.ai.replaceTelegramEditor` uses strict
automatic/enabled/disabled encoding and nil reset through the same AI transaction;
the shared backup changes are tracked separately from the service editor.

Endpoints, API keys, roles, prompts and conversation content are excluded from
these generation flag entries. Root's separate cache/backup validation harness
remains the source of checks for that orchestration.

Public entry points:

```swift
exteraAISettingsController(context:)
exteraAIChatController(context:initialPrompt:)
exteraAITextProcessingController(context:text:action:apply:)
exteraAITextProcessingController(context:text:action:applyResult:)
ExteraAIConfiguration.replacesTelegramSummaries(isPremium:)
```

The labelled `applyResult:` overload takes a throwing `(ComposedRichMessage)
throws -> Void` callback, invoked only after successful generation and explicit
Apply. `ChatControllerExteraAI.openExteraAIComposeIfEnabled` intercepts the native
composer AI action when custom editing is selected. Opening it sends nothing.
Apply rechecks chat location, edit target, structural draft equality, current
policy, text-send permission, frozen/inaccessible/premium/closed-topic state and
edit length limits. It uses `chatTextInputState(fromComposedRichMessage:)` and
`withUpdatedEffectiveInputState`, retaining UTF-16 quote entities. Changed drafts
and rich drafts containing media or structured blocks are kept intact. Failed
insertion throws a visible error and leaves the result available to copy. The
legacy labelled `apply:` callback continues to accept `String`.

`ChatMessageBubbleItemNode.toggleSummarization` resolves the summary policy and
checks service/model/endpoint/Keychain readiness. Custom generation starts only
after the user confirms sending this message to the named service and host.
`ExteraAISummaryPlan` sends the exact source text with isolated summarization
instructions, requested language, temperature and streaming preference, without
conversation history or the selected chat role. Secret, protected, paid, expired
and structured rich messages are excluded from this external path.

The bubble owns the request through transport and the local Postbox write.
Cancel, loss of visibility, reuse, source/language changes and provider-policy
changes dispose work and close progress. The transaction rechecks source and
content eligibility; a lock serializes cancellation against the write body.
Successful custom output is stored in `SummarizationMessageAttribute` for the
existing inline renderer with a per-language `DerivedDataMessageAttribute`
provenance marker (`extera.ai.summary.custom.<language|original>`). Custom
expansion always regenerates after consent, preventing reuse across services.
The Telegram path rejects marked custom cache entries and clears that language's
marker only after successful Telegram generation. Both paths expose errors and
cancellation without silent provider fallback.

All new files are included by existing source globs and use dependencies already
declared by SGSettingsUI, TelegramUI and ChatMessageBubbleItemNode. No additional
Bazel dependencies or BUILD edits are required for these AI consumers.

Localization keys have prefix `Extera.AISettings.`; the exact English-to-suffix
map is `ExteraAIStrings.keys` in `ExteraAISettingsViews.swift`. Suffixes:
`Title`, `HeroInfo`, `General`, `Services`, `Roles`, `History`, `None`, `Off`,
`HistoryInfo`, `TelegramAI`, `Editor`, `Summaries`, `EditorInfo`, `SummariesInfo`,
`ReplacementInfo`, `Generation`, `Streaming`, `StreamingInfo`,
`ShowResponseOnly`, `InsertAsQuote`, `Temperature`, `TemperatureInfo`, `TryAI`,
`Improve`, `Summarize`, `SendInfo`, `SaveHistory`, `Copied`.
The additional role/service/error and User-Agent suffixes are in the same map.
All AI keys are included in both English and Russian localization resources;
each lookup also retains an English/Russian fallback.

## Validation and remaining checks

On the Windows authoring host, tree-sitter parses eleven AI production/test and
native consumer Swift files without errors. The twelfth, TextProcessingScreen,
has one missing-`!` parser diagnostic at `playOnce.invoke(())` that is reproduced
unchanged in HEAD; the checker pins that exact baseline diagnostic.
`git diff --check` passes. The host XCTest command
in `Tests/ExteraAI/README.md` was attempted through `uv run python`; it cannot
execute because Swift is unavailable. Syntax parsing does not establish Swift
type correctness or passing request tests.

The XCTest cases target the exact production store/settings/client sources
on a Swift host and use URLProtocol fixtures, without live provider requests.
They cover backward Codable defaults/round-trip, presentation and UTF-16 quote
ranges, transcript completion/cleared history/error states, chat and Responses
payloads, distinct temperature values, reasoning options, SSE terminal events,
redacted authentication errors without retry, rejected-temperature retry,
cancellation, invalid input/endpoints, legacy User-Agent decoding, every explicit
header on both generation and model lookup, and invalid custom-header rejection.
Native-summary fixtures additionally
cover automatic/explicit routing, readiness and policy invalidation, exact source
text and isolated instructions for both Chat Completions and Responses APIs.
These tests remain unexecuted here; UIKit, Postbox and native composer integration
are outside this Foundation host suite.

iOS typechecking/build and recorded-frame verification remain required. Per
`AGENTS.md`, record open/back, scroll/header transition, slider dragging and
VoiceOver, long service/role names, large Dynamic Type, light/dark themes, and
chat stream/stop/error/copy/apply paths, summary consent/progress/cancel/error and
inline expansion, and composer insertion with quote on/off, emoji, changed drafts,
rich drafts and revoked write permissions. Expected frames: the hero scrolls with
the cards; the navigation title appears after its hero title leaves view; labels
and thumb stay together while dragging; controls stay inside cards; response
updates do not duplicate saved turns or make the current prompt disappear when
history is disabled; summary progress closes before errors appear; explicit Apply
produces a native quote and returns to the composer while rejected insertion
keeps both draft and AI result. There is no custom animation. This Windows session has no
iOS Simulator/Xcode tools and supplies no recorded-frame evidence.
