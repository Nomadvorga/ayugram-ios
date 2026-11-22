# AyuPluginBridge

Experimental Android Python plugin compatibility layer for the `plugins-test` branch.

## Ownership and boundaries

- `ObjC/` and `PublicHeaders/`: one embedded CPython interpreter on one dedicated OS thread. Main never waits for Python. `_ayu_host` receives its owner from native thread context rather than a plugin JSON field.
- `Python/`: explicit SDK modules, scoped lifecycle/settings/callbacks, virtual Java facade. Read `Python/protocol.md` before changing either side of the transport. This is **not a security sandbox**: enabled Python is trusted application code.
- `Sources/`: native host registry and UIKit adapters. Never resolve app symbols/selectors dynamically; adapters are explicit code. Unknown APIs return errors, never empty success stubs. UI runs on main, Python callbacks return asynchronously to the interpreter thread.
- `Integration/`: imported plugin store, user-driven enable/disable and manager UI. Importing must not execute a plugin. No automatic execution on process startup in this experimental version.
- `Build/` and `third-party/ayu-python`: checksum-pinned Python packaging; binary extensions belong in signed frameworks, not loose executable resources.
- `tools/plugin_inspector`: static AST inventory, not proof of runtime support. Never execute user attachments to inspect them or commit their source to this repo.

## Performance invariants

Native animations should run in Core Animation/UIKit. Do not add synchronous main→Python calls, a main-thread semaphore wait, per-frame JSON round trips, or an unconditional display-link interpreter callback. Bound queues, references and source size; cancel/revoke work by plugin generation on unload. Keep Int64 account/chat/message IDs exact on the wire. Metrics are diagnostic counters until validated on a real iPhone; they are not an FPS guarantee.

## Source-pinned Atmospheric Snow route

`Integration/AyuAtmosphericPluginAdapter.swift` recognizes only Atmospheric Snow 1.0.1 by SHA-256, not by a user-controlled ID/version field. Reverify the stored UTF-8 source on every enable and when restoring installed metadata. Do not execute this attachment or advertise Android Canvas/method-hook APIs as implemented merely because its native adapter exists.

The native route imports without starting Python, keeps the original 15 setting keys and `snow_defaults_v` migration marker in the existing owner namespace, and updates a native typed configuration only on settings events. `AyuAtmosphericHost` owns weak typed surface attachments and generation cleanup; `AyuAtmosphericSnow` owns simulation/materials. User enable/disable is process-local, with no startup auto-enable. Disable removes both navbar draw passes and stops all animation clocks, but preserves preferences; delete clears only this plugin namespace.

The manager states that this is a native compatibility adapter, not literal Android code execution. Its reset row is an explicit iOS host addition, absent from the source plugin. Unsupported source bytes must remain blocked rather than be run through a stale adapter selection.

Native compilation and app-side visibility/z-order/touch/animation parity must be verified independently. Source inventory and registered surfaces alone are not a visual acceptance result.

## Verification

### Application adapters

`AyuPluginService.shared` installs `AyuPluginApplicationBridge` with its compiled
class registry. `TelegramUI/Sources/AyuPluginApplicationBinding.swift` feeds real
account/profile/application signals and the explicitly authorized root controller;
unbound, locked, inactive or stale contexts fail closed. Consult
`Resources/CommonBridge/APPLICATION-BRIDGES.md` for exact members and remaining work
for all 19 plugins. Do not equate a declared class or shared feature subset with
full plugin support. Notification observers, hooks, requests, menus and media are
not provided by this phase.

Provider `prepareCall` returns typed results and deferred native effects. Validate
state/references/response quotas and allocate the host-owned result before commit;
on failure, invoke rollback to cancel the native reservation. Never let providers
manufacture handles. `staticFields` are explicit read-only readers, not reflection.
Resolve callbacks on the host worker and retain only their revocable native sender,
never an adapter context. Main never waits for Python. Lifecycle events include
the exact SDK generation, and stale event/callback errors cannot mark a newer
plugin load as failing. Lock/background/account transitions remove bridge-owned UI.

### Lazy Python resource discovery

`Integration/AyuPluginResourceLocator.swift` searches only the main app and the
compiled bridge/runtime code-owner resource roots. The `.bundle` directories
contain data and may have no `Info.plist`; do not gate their use on
`Bundle(url:)`. Verify the exact Python home/SDK paths and bootstrap files,
reject symlink escapes, and do not fall back to imported plugin storage or an
unbounded recursive search. Declare resource bundle targets in `swift_library`
`data`, not its compile/link `deps`.

Resolve resources before caching `runtimePreparation`. A lookup failure has not
started Python and may be retried. After a native startup attempt, a failed task
stays cached until process exit: CPython may already own the process even if SDK
import failed. Never create another interpreter to retry this condition. Native
failures are reported with fixed messages based on native domain/codes, without
tracebacks, source, exception text, or `NSError.userInfo`.

The final IPA verifier checks both resource payloads, every bundled SDK Python
source against the checked-out inventory/SHA-256, and the existing FAT-aware
dyld/`.fwork` graph. A green packaging check still is not a device Python startup
or compatibility result. Keep the exact-hash Atmospheric path Python-free and
all extensions lazily embedded/signed with `bundle_only = True`.

Run synthetic Python SDK and inspector tests with Python 3.11+; run packaging tests without downloading/compiling a runtime. Native tests require macOS/Xcode and the repository's `Make.py test --target` convention. The full app uses `Make.py build`, not standalone `swift build`. All visual work requires recorded simulator frames as described by the root AGENTS.md. Native bridge packaging and FPS must be checked on a cool device in an optimized build.

A future adapter for account deletion/logout, camera, passcodes, screen capture, message deletion or archive/export must preserve the app's current invariants and platform permissions. Python source support does not create an iOS equivalent of Android OS-only APIs.
