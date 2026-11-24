# iOS plugin API reference

The iOS AyuGram bridge runs Android AyuGram plugins (Python `BasePlugin` classes)
without a JVM: the facade classes plugins touch are explicit native adapters,
hooks are a typed registry, and unsupported Android surface fails with
`unsupported_api` instead of pretending to work. This document is the contract
for plugin authors; docs/plugin-bridge.md is the implementation ledger.

Status legend: **implemented** — code and tests exist in `submodules/AyuPluginBridge`;
**contract** — being added by in-flight work, semantics fixed here. Nothing is
claimed to "run" until the iOS test runner and the app host execute it.

## Porting model

- **Source-compatible**: plugin logic in pure Python, settings, `BasePlugin`
  lifecycle, worker threads, HTTPS calls.
- **Adapted**: hooks (typed registry instead of Xposed method hooks), Java UI
  classes (facade adapters), web content (WKWebView with a native animation
  channel).
- **Unsupported, by design**: screenshot-privacy-class OS-defeating features,
  native Android services, DEX/JVM reflection beyond the facade, Play Services.

## Lifecycle

install → inspect (manifest verdict) → enable → settings → unload/delete.
Disable preserves settings and storage; delete clears the plugin's owner
namespace entirely — nothing is kept silently.

## Hooks

Subscribe to typed hook points at enable; revocation happens on unload.

- Points: `message.send.pre` / `.post`, `message.edit.pre` / `.post`,
  `message.delete.pre`, `message.received`, `chat.did_open` / `.did_close`,
  `dialogs.changed`, `theme.changed`, `app.will_resign_active` /
  `app.did_become_active` (`AyuBridgeHooks.swift`).
- `.pre` points are mutating: a hook may replace the payload or cancel with a
  reason. Observe points (post/received/lifecycle) can neither mutate nor
  cancel; attempts are recorded as that plugin's failure and the chain
  continues.
- Ordering is priority (lower first), then subscription order. One plugin's
  thrown error never stops the chain or other plugins.
- Cancellation of a mutating point stops the chain and the host action.

Example:

```python
def on_send_pre(payload):
    if payload["text"] == "nope":
        return hook.cancel("blocked by filter")
    payload["text"] = payload["text"].upper()
    return hook.replace(payload)
```

## Capabilities (code-based checks)

Every registration and sensitive call is authorized by a predicate over the
plugin's declared capability set — **never** a hash/digest pin list. Hash
pinning remains only in the already-shipped atmospheric_snow route.

- Names: `messages.read`, `messages.send`, `messages.mutate`, `network`,
  `ui.overlay`, `ui.settings`, `media.decode`, `storage`.
- Scope: `chats` (absent = all chats; a list = allow-list of chat ids), checked
  at each call. A narrower request passes where a broader one fails.
- Denial is a typed error naming the missing capability; nothing degrades
  silently.
- Screenshot-privacy-class requests are refused by name at install, before any
  predicate runs.

## Settings

Declarative rows (switch, slider with min/max/step/format, text, multiline,
single/multi select, color, headings), typed values with JSON round-trip,
defaults, per-plugin namespacing, migration-safe access, and validation with an
explicit typed error for unsupported row kinds. Implemented in-flight
(`AyuPluginSettings.swift`, contract).

## Worker threads

- One serial queue per (plugin, thread name); `threading.current_thread()`
  identity is stable per name.
- `join` with timeout from any non-main thread; joining from the main thread is
  rejected (`mainThreadSyncWaitForbidden`), never waited.
- Callbacks marshal back to the main context asynchronously; a synchronous
  main-thread wait from a worker is the classic deadlock and does not exist in
  this model.
- Unload bumps a generation: queued work of the old generation fails with
  `pluginUnloaded`, its callbacks are never delivered.
- CPU budget per plugin: measured work is charged; exhaustion is a typed error,
  not a silent slowdown (`AyuBridgePythonWorker.swift`, implemented; host top-up
  policy beside the existing bridge limits).

## Network

Requests-style HTTPS: `get/post/put/delete/head` with headers, query, json/form/
binary bodies, timeouts, redirect policy, chunked streaming reads, cookies per
plugin, upload progress and cancellation. Per-plugin domain allow-list enforced
with a typed denial — plugins get no global internet by default. iOS ATS-grade
TLS defaults. No live network in tests (fixture transports).

## Java facade coverage

Implemented via explicit class adapters (`AyuBridgeJavaValues.swift`,
`AyuBridgeJavaRuntime.swift`):

- Values: Integer, Long, Boolean, ArrayList, HashMap, AtomicLong/Boolean,
  System, primitives.
- `android.os.Bundle` — typed put/get with defaults, keySet, isEmpty.
- `android.content.Intent` — action, extras (string/int typed access),
  categories, flags; constants for SEND/VIEW/MAIN.
- `android.view.View` — visibility (VISIBLE/INVISIBLE/GONE), enabled, alpha,
  translation/scale, padding, LayoutParams.
- `android.view.ViewGroup.LayoutParams` — width/height with MATCH_PARENT/
  WRAP_CONTENT, margins.
- `android.view.MotionEvent` — DOWN/UP/MOVE/CANCEL, x/y, pointer count.
- `android.graphics.Paint` / `Canvas` — color/alpha/stroke/style/cap model;
  circle/rect/line path ops for snow/ball-style drawing.
- `android.graphics.drawable.ColorDrawable`.
- `java.lang.Runnable` / `android.os.Handler` — post, postDelayed (bounded),
  removeCallbacks.

Anything outside the adapter surface — including reflection-style access to
unregistered classes (`Class.forName` against the static symbol table only) —
raises `unsupported_api`. A facade symbol existing is not proof that every
method is implemented; the inspector manifest is the source of truth.

## Messages

DTO with UTF-16 entity offsets (Telegram wire format; astral-plane emoji are
the classic porting bug and are covered by conversion helpers), text/caption/
media presence rules, silent ⊕ schedule exclusivity, future-only schedule,
reply/topic routing, edit semantics: nil entities keep current, empty array
clears. Pre-hooks wrap send/edit/delete around the transport
(`AyuBridgeMessageAdapter.swift`).

## Web content (SandBox-class)

Plugin HTML/JS is audited at import and served from a per-plugin namespace; the
JS↔Python bridge is structured messages with request ids, timeouts and size
caps; animation intents run natively at display rate — animation frames are
never serialized to Python; external navigation opens outside, new windows are
denied by default.

## Explicit unsupported list

Screenshot privacy and every other OS-privacy-defeating capability; native
Android services and broadcasts beyond the facade; MediaCodec/JVM DEX;
Play Services; global internet without a `network` grant; observe hooks that
try to mutate.

## Minimal plugin

```python
from base_plugin import BasePlugin, hook, setting

class UpperCase(BasePlugin):
    name = "Upper Case"
    author = "you"
    version = "1.0.0"

    capabilities = ["messages.send"]

    @setting(switch=True, title="Enabled")
    def enabled(self): ...

    @hook("message.send.pre")
    def on_send(self, payload):
        payload["text"] = payload["text"].upper()
        return hook.replace(payload)
```

## Porting checklist (Android → iOS)

1. Replace method hooks with typed hook points; check mutate vs observe.
2. Declare capabilities (narrow scopes); remove any screenshot-privacy usage.
3. Move UI work to facade classes that exist; expect `unsupported_api` for the
   rest and degrade gracefully.
4. Move blocking network calls to the requests-style adapter with timeouts.
5. Keep threads named; never wait on the main thread from a worker.
6. Validate entity offsets against UTF-16 lengths.
7. Run the corpus audit (`apk-analysis/audit_corpus.py`) against your plugin to
   see the missing facade symbols before porting.
