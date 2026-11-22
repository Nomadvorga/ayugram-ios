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

## Verification

Run synthetic Python SDK and inspector tests with Python 3.11+; run packaging tests without downloading/compiling a runtime. Native tests require macOS/Xcode and the repository's `Make.py test --target` convention. The full app uses `Make.py build`, not standalone `swift build`. All visual work requires recorded simulator frames as described by the root AGENTS.md. Native bridge packaging and FPS must be checked on a cool device in an optimized build.

A future adapter for account deletion/logout, camera, passcodes, screen capture, message deletion or archive/export must preserve the app's current invariants and platform permissions. Python source support does not create an iOS equivalent of Android OS-only APIs.
