# AI preferences and request checks

Run on a macOS host with Xcode's Swift toolchain:

```sh
python3 tools/run_extera_xctests.py --warnings-as-errors \
  Swiftgram/SGSimpleSettings/Sources/AyuSettingsStore.swift \
  Swiftgram/SGSimpleSettings/Sources/ExteraAISettings.swift \
  Swiftgram/SGSimpleSettings/Sources/ExteraAIClient.swift \
  Tests/ExteraAI/ExteraAIClientTests.swift
```

This compiles production files unchanged, with an isolated app-group identifier.
URLProtocol supplies all responses; no API key, user text or request leaves the
process. Tests pin Android generation defaults and backward Codable decoding,
all response-only/quote formatting with UTF-16 ranges, actual chat/Responses
request payloads and temperature values, SSE reasoning filtering and completion,
an explicit unsupported-temperature retry, cancellation, and endpoint rejection.
The transcript fixtures cover unsaved prompts, saved-response deduplication,
cleared history and separate partial-response/status display. Provider fixtures
also pin reasoning options and authentication-error redaction without retry.
Native-summary fixtures cover readiness, account-dependent routing, invalidation
after policy/service changes, and isolated instructions with the exact source
text for Chat Completions and Responses. The thirteen tests do not exercise UIKit,
Postbox writes or composer insertion; those require the iOS host below.
The existing AI cache/backup harness remains in
`docs/validation/run_extera_ai_backup_validation.py`; its owner controls backup
allowlist integration for the new flags.

The settings home uses a robot hero and rounded General / Telegram AI / Generation /
Temperature groups. The slider spans 0.0...2.0 in 0.1 steps, labels update while
dragging, and preference persistence happens when the gesture finishes. Service,
role and account-specific history editors remain available, including presets,
manual/fetched model choice, API Keychain storage, reasoning, explicit service
testing/cancellation, history opt-out/edit/copy/delete and clear.
The full Android inventory, defaults, native summary/composer integration and
root's backup/localization contract are in `docs/extera-ai-settings.md`.

Syntax-only check (also works on Windows):

```sh
uv run --with tree-sitter --with tree-sitter-swift python Tests/ExteraAI/verify_swift_syntax.py
```

UI verification on iOS must cover light/dark themes, long names, large Dynamic
Type, slider touch/VoiceOver, return from service/role/history editing, and the
generation stream/stop/error/apply paths. Before recording, expect controls to
stay inside rounded cards, the slider labels to remain aligned while dragging,
and scroll/header changes to keep content together without clipping. No custom
animation is added. Record and evaluate frames as described in AGENTS.md.

For native summaries, record the external-service disclosure, success into the
existing inline renderer, cancellation and errors for both custom and Telegram
routes. Change policy/service or source text during a request: no stale result
should expand, progress must close, and custom failure must not call Telegram.
For composer Apply, record quote on/off with emoji and multiple lines; expect a
native quote with intact text and caret at its end. Change the draft, edit target
or write permission while AI is open: Apply must keep the draft and show an error
while preserving the answer for Copy. Rich/media drafts must remain unchanged.

On the Windows authoring host there is no Swift/Xcode or iOS simulator. Syntax
parsing is available; Swift compilation, XCTest execution and recorded-frame
verification must still run on the macOS/iOS host.
