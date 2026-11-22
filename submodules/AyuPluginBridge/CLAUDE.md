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

Run synthetic Python SDK and inspector tests with Python 3.11+; run packaging tests without downloading/compiling a runtime. Native tests require macOS/Xcode and the repository's `Make.py test --target` convention. The full app uses `Make.py build`, not standalone `swift build`. All visual work requires recorded simulator frames as described by the root AGENTS.md. Native bridge packaging and FPS must be checked on a cool device in an optimized build.

A future adapter for account deletion/logout, camera, passcodes, screen capture, message deletion or archive/export must preserve the app's current invariants and platform permissions. Python source support does not create an iOS equivalent of Android OS-only APIs.
