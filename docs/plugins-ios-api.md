# iOS plugin bridge: current implementation and limitations

This experimental branch imports Android AyuGram `.plugin` Python sources
without a JVM. It is not an Android runtime or a sandbox: enabling a plugin is
explicitly trusting application code. An API name in an SDK shim or a clean
static inspection does not establish that the iOS host implements that call.
Consult [`plugin-bridge.md`](plugin-bridge.md),
[`plugins-corpus-compatibility.md`](plugins-corpus-compatibility.md), and
[`APPLICATION-BRIDGES.md`](../submodules/AyuPluginBridge/Resources/CommonBridge/APPLICATION-BRIDGES.md)
for implemented subsets and pending host work. Source-level support, native
implementation, and device verification are separate claims.

Status on 2026-11-26: the Python SDK grew a version policy, plugin threads,
Python-local Java classes, a Telegram object/request layer and package loading
(contracts: [`protocol.md`](../submodules/AyuPluginBridge/Python/protocol.md),
[`protocol-telegram.md`](../submodules/AyuPluginBridge/Python/protocol-telegram.md)).
All of it is tested against a synthetic host only. Nothing was compiled into the
app or run on a device, the related Swift edits are uncompiled, and a clean
static preflight is not proof that a plugin works. Where this document says
"Python side", read it with that caveat.

## Porting model

- `.plugin` attachments are size-bounded, statically inspected without running
  their code, and opened in an install/details screen. Install and enable are
  separate user actions. Enabled Python is entered on one native-owned serial
  queue; it is trusted code, not isolated code.
- The SDK preserves portions of `BasePlugin`, settings, callbacks, formatting,
  helpers and the virtual Java facade. Native classes and methods are explicit
  adapters; unimplemented calls fail rather than returning fake success.
- A small set of exact-source plugins has host-owned native iOS adapters.
  Those implementations are not general Android API emulation.
- Android services, arbitrary DEX/JVM reflection, Xposed interception,
  Android-only media stacks and Play Services are not generally available.
  Native equivalents need specific host integrations. Plugin-created threads
  are supported on the Python side (see Scheduling and execution).

## Lifecycle

install → inspect (manifest verdict) → enable → settings → unload/delete.
Disable preserves settings and storage; delete clears the plugin's owner
namespace entirely — nothing is kept silently.

## Hooks and events

The host currently wires the legacy `BasePlugin.add_on_send_message_hook()`
callback into the outgoing text/caption path. Its mutable payload is limited to
`peer`, `message`, and `caption`; the iOS host retains ownership of account and
destination. `CANCEL`, `MODIFY`, and `MODIFY_FINAL` are handled by the outgoing
hook chain, with generation checks after asynchronous Python callbacks. This is
not arbitrary Java method hooking.

Some lifecycle callbacks are generation-bound. Request hooks, edit/delete
interception, message-received events, menu types other than
`MESSAGE_CONTEXT_MENU`, and arbitrary `hook_method` targets must not be inferred
from the presence of SDK wrapper types; they require a corresponding host
implementation and may be unavailable. On the Python side these entry points
are now gated on typed host operations (`telegram.hooks.set`,
`telegram.hooks.send_message`, `menus.add`, ...) specified in
`protocol-telegram.md`. The Swift host implements none of the 19 operations, so
preflight reports each use as an `OPERATION` blocker and the call raises
`UNSUPPORTED_API`. Xposed-style `hook_method`, `hook_all_methods` and
`hook_all_constructors` have no target mapping at all. A legacy send hook that
touches fields beyond `peer`, `message` and `caption` is also an `OPERATION`
blocker (`telegram.hooks.send_message`).

`BasePlugin.add_menu_item` supports a narrow `MESSAGE_CONTEXT_MENU` subset. A
condition and click callback receive only `account`, `dialog_id`, and
`message_id` in one metadata object; no Android `MessageObject` or fragment is
created. Rows have bounded text, optional supported icon, item id and priority.
The existing native menu is published without waiting for Python; eligible plugin
rows are appended asynchronously only while the same chat/menu is still current.
The host orders and caps rows, and revokes tokens at unload. Other menu types,
string/MVEL conditions, subtext and long-click callbacks are unsupported.

## Authorization and source-specific routes

Generic plugin activation requires a separate explicit user action and repeats
preflight on the installed bytes. The Python runtime checks declared host
operations, native classes, imports and source constraints, but this is not a
security sandbox or a complete static proof. Android version constraints
(`__min_version__`, `__app_version__`, `__sdk_version__`) are evaluated in
Python against an emulated plugin SDK 1.4.6.5 / exteraGram 13.2.2; an unmet or
invalid constraint is a `VERSION_POLICY` blocker. `__requirements__` entries
are satisfied only by bundled modules and are otherwise `REQUIREMENT` blockers;
nothing is installed. The Swift change that lets the host defer to this Python
result is not compiled, and whether to keep the emulated versions is an open
owner decision.

Preflight checks classes, SDK members and host operations, not individual Java
members. A curated list of 21 host members that nothing provides (`getWindow`,
`getDecorView`, `getDeclaredField`, ...) is reported under the reserved
`sdk.unprovided_member` operation. An independent review found 12 of the 20
corpus plugins that then passed preflight to be false passes; they are now
blocked, but without member-level preflight false passes may remain. The iOS port does not yet provide
the general caller-declared capability-grant and chat-scope system described by
some future API proposals. Do not claim such a grant exists unless a concrete
host adapter enforces it.

Several native plugin routes are selected only for their exact audited source
bytes. A changed source with the same plugin ID is not trusted as that native
implementation. Each adapter has explicit iOS limitations; screenshot shields,
for example, cannot make iOS screenshots equivalent to Android's secure-window
flag. See the compatibility ledger for the current route list.

## Settings

Settings are namespaced per plugin and persisted as bounded JSON values. The
bridge supports the row types implemented in `Python/ui/settings.py` and the
native settings controller; unsupported row types/options must remain explicit
errors. Importing settings validates the full payload before replacing an
owner's values. Do not infer support for every Android row widget or arbitrary
custom settings fragment. The Python side now reads rows as Android does
(invalid rows are dropped) and can send `icon`, `on_long_click` and
`link_alias`, which the native settings screen ignores. An `EditText` row with a
`mask` or a `max_length` other than Android's default 256 raises
`UNSUPPORTED_API`, as do `Custom` rows. In alerts, cancel/back listeners raise
`UNSUPPORTED_API` and `make_button_red` is a logged visual degradation: the
button keeps its default colour.

## Scheduling and execution

There is one serial interpreter queue; every host call and every host-delivered
callback runs on it. The SDK's `run_on_queue` helper schedules generation-owned
callbacks on the supported native queue names; it does not execute Python on the
UIKit main thread. The host revokes callbacks and pending work when a plugin is
unloaded.

Plugin-created threads are supported on the Python side when the host declares
`scheduler.schedule` and `scheduler.cancel`: `threading`, `queue` and
`concurrent.futures.ThreadPoolExecutor`, plus Python-local `java.lang.Thread`,
`java.util.concurrent.*`, `java.util.Timer` and `android.os`
`Looper`/`Handler`/`HandlerThread`/`AsyncTask`. They are real Python threads
owned by the plugin generation; a bridge call made on one is marshalled onto the
serial queue while the thread waits. Limits are 64 threads per plugin and 256 in
the interpreter. Known gaps: a C-level wait on the queue thread (`time.sleep`,
a socket read, an asyncio loop) does not serve workers, which then fail with
`QUEUE_TIMEOUT` after 30 s; worker threads are outside the CPU budget; thread
priorities have no effect; a thread that ignores the unload stop event runs
until it returns, without bridge access. None of this has been run on a device.
`_thread`, `multiprocessing`, `subprocess` and `ctypes` are still rejected
rather than emulated. Execution budgets are cooperative limits, not containment
against blocking native calls or malicious code.

## Network

The bundled `requests.py` module implements a bounded synchronous HTTPS subset:
common verbs, headers, query/form/JSON/byte bodies, per-session cookies,
redirects, timeouts, TLS verification and buffered responses. It is not upstream
`requests`; streaming iterators, multipart uploads, per-plugin host allow-lists,
hard cancellation, and async transport are not implemented. On iOS, TLS setup
requires the packaged trust roots and fails closed if they are absent. HTTP
fixture tests do not establish iOS network reachability, TLS packaging, or
application-level permission policy. A generic domain allow-list or “no network
by default” grant model is not currently enforced by the host.

## Java facade coverage

A Java class is served either by a Swift adapter or by a Python-local class
(`Python/_ayu_javalib/`). The Python side has 346 pure-logic classes in 14
provider modules (among them `java.lang`, `java.util`, `java.io`, `java.nio`,
`java.net`, `java.text`, `java.time`, `org.json`, `android.os`, `android.text`,
`android.util`, `android.content`, `android.graphics`), plus concurrency,
Telegram and exteraGram facades. A class the host declares wins, except for 28
names where the local class explicitly overrides a weaker adapter (for example
`Integer`, `Long`, `ArrayList`, `HashMap`, `Bundle`, `Rect`, `URL`, `Handler`).
Local classes that need a host operation stay blockers until the host declares
it. Classes that need host pixels or UI (`Bitmap`, `BitmapFactory`, most
drawables, shaders) or an OS service were left out of the Python side and need
host work; `javax.crypto`, reflection proxies and DEX class loading are not
provided.

Implemented on the Swift side via explicit class adapters
(`AyuBridgeJavaValues.swift`, `AyuBridgeJavaRuntime.swift`):

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
  circle/rect/line path operations; not a general Android Canvas renderer for
  arbitrary plugin surfaces.
- `android.graphics.drawable.ColorDrawable`.
- `java.lang.Runnable` / `android.os.Handler` — post, postDelayed (bounded),
  removeCallbacks. The Python-local `Handler` now replaces this adapter; it
  adds Looper constructors and cancels through `scheduler.cancel`.

Anything outside the adapter surface and the Python-local classes — including
reflection-style access to unregistered classes (`Class.forName` against the
static symbol table only) — raises `unsupported_api`. A facade symbol existing is not proof that every
method is implemented; the inspector manifest is the source of truth.

## Messages

The SDK has bounded text/entity conversion helpers and typed message adapter
models. Exact UTF-16 offsets matter. These declarations alone do not mean generic
plugins can send media, edit/delete arbitrary messages, issue Telegram TL
requests, or use account-scoped request callbacks: those actions need the real
application transport and exact field validation. The currently connected
outgoing text hook is described above. Unsupported application calls fail
explicitly.

Python side versus Swift side: the SDK now has a TL object model (3028 classes
generated for layer 233, sent as base64 binary TL), `MessageObject`,
`MessagesController`, `SendMessagesHelper`, `FileLoader` and similar facades,
and typed `send_request` / `send_message` / edit / file / player entry points.
Each depends on one of the 19 host operations in `protocol-telegram.md`
(`R` resource ids depend on `resources.resolve`). The
Swift host implements none of them, so no generic plugin can issue a TL request
or send through these paths today. 96 TL classes missing from the iOS scheme
use a layout parsed heuristically from Android Java; only one of them is
byte-tested.

## Web content (SandBox-class)

Web-content support is limited to the documented exact-source SandBox adapter;
it is not a general Android WebView facade for arbitrary plugins. Native
animation, navigation and source-hash requirements are specific to that route.

## Explicit unsupported list

General Android system services/broadcasts, arbitrary Java/Xposed hooks,
process/`ctypes` APIs, arbitrary DEX/JVM execution, unrestricted native
reflection, generic media upload/recording pipelines, a host-side TL request
transport, broad Android Canvas/WebView equivalence, and OS-level screenshot
protection are not implemented as universal APIs. Plugin packages (`.elyx`,
`.eaf`) can be inspected and loaded by the Python SDK, but the Swift importer
does not accept them yet. Specific native routes may
cover a constrained behavior without implementing the corresponding Android
class or service.

## Minimal plugin

```python
from base_plugin import BasePlugin, HookResult, HookStrategy

class UpperCase(BasePlugin):
    name = "Upper Case"
    author = "you"
    version = "1.0.0"

    def on_plugin_load(self):
        self.add_on_send_message_hook()
        self.set_setting("example.enabled", True)

    def on_send_message_hook(self, account, params):
        if params.message:
            params.message = params.message.upper()
        return HookResult(HookStrategy.MODIFY, params=params)
```

## Porting checklist (Android to iOS)

1. Inspect the plugin against the current compatibility inventory; static
   inspection is not runtime proof.
2. Do not rely on arbitrary Xposed hooks, Android services or Android-only
   media APIs. Python threads work only under the limits in Scheduling and
   execution, and never block the queue thread in `time.sleep` or a socket
   while a worker needs the bridge.
3. Use only explicitly implemented facade methods and settings rows; unsupported
   calls fail rather than silently degrade.
4. Treat blocking HTTPS as synchronous work on the single Python queue. The
   `requests` facade has no universal host allow-list or cancellation guarantee.
5. Validate text entities against UTF-16 offsets and preserve signed 64-bit IDs.
6. Use a source-pinned native iOS adapter only when the exact source matches its
   audited implementation and documented limitations.
