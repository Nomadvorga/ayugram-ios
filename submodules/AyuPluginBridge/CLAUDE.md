# AyuPluginBridge

Experimental Android Python plugin compatibility layer for the `plugins-test` branch.

## Ownership and boundaries

- `ObjC/` and `PublicHeaders/`: one embedded CPython interpreter whose native entry points and host dispatch run on one dedicated OS thread. Main never waits for Python. `_ayu_host` receives its owner from native thread context rather than a plugin JSON field, so a plugin-created Python thread cannot dispatch to the host itself (see Plugin threads below).
- `Python/`: explicit SDK modules, scoped lifecycle/settings/callbacks, virtual Java facade. Read `Python/protocol.md` before changing either side of the transport. This is **not a security sandbox**: enabled Python is trusted application code.
- `Sources/`: native host registry and UIKit adapters. Never resolve app symbols/selectors dynamically; adapters are explicit code. Unknown APIs return errors, never empty success stubs. UI runs on main, Python callbacks return asynchronously to the interpreter thread.
- `Integration/`: imported plugin store, user-driven enable/disable and manager UI. Importing must not execute a plugin. No automatic execution on process startup in this experimental version.
- `Build/` and `third-party/ayu-python`: checksum-pinned Python packaging; binary extensions belong in signed frameworks, not loose executable resources.
- `tools/plugin_inspector`: static AST inventory, not proof of runtime support. Never execute user attachments to inspect them or commit their source to this repo.

## Performance invariants

Native animations should run in Core Animation/UIKit. Do not add synchronous main→Python calls, a main-thread semaphore wait, per-frame JSON round trips, or an unconditional display-link interpreter callback. Bound queues, references and source size; cancel/revoke work by plugin generation on unload. Host-to-Python callbacks and events go through `Integration/AyuPluginDeliveryQueue.swift`, never straight to `APBPythonRuntime`: it keeps per-plugin order, bounds what is pending and gives every delivery an explicit outcome ("Delivery queue" in `Python/protocol.md`). Keep Int64 account/chat/message IDs exact on the wire. Metrics are diagnostic counters until validated on a real iPhone; they are not an FPS guarantee.

## General Python route

`AyuPluginService.inspect` recognizes source-pinned native routes first without starting Python. Other sources pass `preflight_plugin_json` on the interpreter worker: AST metadata, SDK members, imports, native classes, dependencies and declared operations are checked without executing or authorizing plugin code. Valid records with unsupported requirements can be imported disabled with blockers. Each enable repeats inspection against the stored bytes, then loads only after explicit trust consent. Native adapter IDs with mismatched source hashes remain blocked; generic Python must never fall into an ID-selected native adapter.

Restoring installed metadata never loads plugins or starts Python; generic records are checked again at explicit enable. Python is trusted application code, not a sandbox. Static preflight is not a runtime compatibility guarantee.

Version policy: Python (`Python/_ayu_policy.py`) evaluates `__min_version__`, `__app_version__` and `__sdk_version__` with Android comparison semantics against the emulated plugin SDK 1.4.6.5 / exteraGram 13.2.2 and reports each unmet or invalid constraint as a `VERSION_POLICY` blocker, in preflight and again in `load_plugin`; do not silently ignore them. The Swift change that defers to this result (`plugin.authorize` accepts version-constrained metadata when the `version_policy` argument is present; the blanket blocker loop in `Integration/AyuPluginService.swift` is removed) has only been syntax-parsed, never compiled, and has no Swift test. `__requirements__` is satisfied only by bundled modules; everything else is a `REQUIREMENT` blocker and nothing is installed.

The notes below describe Python-side work that is tested against a synthetic host only. None of it was compiled into the app or run on a device, and a clean static preflight is not proof that a plugin works. The contracts are in `Python/protocol.md` and `Python/protocol-telegram.md`; do not duplicate them here.

- Plugin threads: `threading` and `concurrent.futures` are supported when the host declares `scheduler.schedule` and `scheduler.cancel` (otherwise they stay `IMPORT` blockers). Threads are real Python threads owned by the plugin generation; their bridge calls are marshalled onto the serial Python queue (`Python/_ayu_threads.py`, `Python/_ayu_javalib/concurrency.py`). `_thread`, `multiprocessing`, `subprocess` and `ctypes` remain rejected. See "Worker threads" in `Python/protocol.md` for bounds, unload and the known gaps; device behaviour is unverified.
- Python-local class seam: Java classes that are pure logic live in `Python/_ayu_javalib/` provider modules (`CLASSES`). A host-declared class wins unless the local class sets `__ayu_overrides_host__ = True` in its own body; `__ayu_requires__` gates a class on host operations; the host never sees or declares local classes. See "Python-local Java classes" in `Python/protocol.md`.
- `OPERATION` blocker: SDK entry points and facade classes are gated on the host operation behind them (`Python/_ayu_operations.py`, `Python/_ayu_hooks.py`). Preflight reports an undeclared one as `OPERATION` and the call raises `UNSUPPORTED_API`. `Python/protocol-telegram.md` specifies 19 such operations (including `resources.resolve`, which gates `R`); the Swift host declares none of them, and Xposed `hook_method*` has no target mapping. The bridge side of the 14 `telegram.*` operations exists (`Integration/AyuPluginTelegram{Backend,Bridge,Hooks}.swift`, tested against a fake backend) but serves and declares an operation only while the app has bound an `AyuPluginTelegramBackend` that lists it; the app's backend (`submodules/AyuPluginTelegramAdapter` over `TelegramCore/Sources/AyuPlugins`) lists all of them and the five `telegram.action.*` state changes (`Integration/AyuPluginTelegramActions.swift`), and has never run on a device (`Resources/CommonBridge/TELEGRAM-BACKEND.md`). Declare an operation in Swift only when it is implemented exactly as specified, and never declare a reserved name (`hooks.java_method`, `sdk.unprovided_member`, ...).
- Member coverage: preflight is member-aware where it can resolve the receiver class statically (`_ayu_inspection.member_inventory`): a missing method, field or constructor of a host class (table published in `runtime.capabilities` `members`) or of a Python-local class (`_ayu_members`, a definition that only raises is not provided) is a `MEMBER` blocker. Unknown receivers (parameters, results of calls without a declared result class, classes without a table) are counted, never blocked; the curated `_ayu_operations.UNPROVIDED_MEMBERS` list under the reserved `sdk.unprovided_member` is the net for them. A host adapter member returns a known class only when the adapter declares it in `results`, which the host enforces. Members of host classes that are pure data or composed over what the host answers are served by the SDK (`HOST_MEMBERS` in the providers: `Context` directories, `getSharedPreferences`, `getPackageName`, `getClassLoader`, Android constants, `AndroidUtilities.density`/`displaySize`); a member the host's table lists stays the host's, and a member only a gated overriding local class provides is an `OPERATION` blocker. `java.lang.Class` member lookups (`getDeclaredField`, `getMethod`, ...) and `java.lang.reflect.Field`/`Method` work over the same member model (`_ayu_javalib/java_reflect.py`): a member outside it throws Java's `NoSuchFieldException`/`NoSuchMethodException`, a literal lookup on a resolved class is checked by preflight, and the curated `getDeclaredField` blocker stays for every other lookup. See "Class members" in `Python/protocol.md`. Never report a preflight pass as a working plugin.
- Explicit UI degradations: alert cancel/back listeners raise `UNSUPPORTED_API`; `make_button_red` only logs (red buttons are not rendered); an `EditText` row with `mask` or `max_length` other than 256 raises. Do not turn these into silent no-ops. `org.telegram.ui.ActionBar.AlertDialog` and its `Builder` are a Python-local facade over the same builder (`_ayu_javalib/telegram_ui.py`) with the same refusals; progress dialogs (`ALERT_TYPE_LOADING`/`ALERT_TYPE_SPINNER`, `AlertDialog(context, 3)`) have no host presentation and are preflight blockers.
- Package loading: `.elyx`/`.eaf` inspection, preflight and loading exist in Python (`Python/_ayu_packages.py`: `inspect_package_json`, `preflight_package_json`, `load_package`, all taking the stored archive path). `AyuPluginService` imports, enables and deletes them through `APBPythonRuntime.preflightPackage`/`loadPackage`: the archive is stored without unpacking or execution, hashed and preflighted again on every enable, and its `ElyxPlugins/<id>` directory is removed with the plugin. See "Plugin packages" in `Python/protocol.md`.
- `plugins.list`, `plugins.settings` and `ui.layout_params` are served by every `AyuPluginService` host (`Integration/AyuPluginRegistryBridge.swift`, `Sources/AyuBridgeLayoutParams.swift`). Dp values become points at density 1; `relative` and pixel margins are resolved when the parameters are created, not at layout.

After any edit to bridge sources, refresh the catalog hashes last: `python3 -B submodules/AyuPluginBridge/Build/audit-plugin-requirements.py --refresh-implementation-hashes --plugin-dir plugins` (run from the repository root).

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
full plugin support. Notification observers, the outgoing text hook, clipboard
writes and one message-context-menu subset are provided; Telegram requests and
media are not provided by the Swift host (the Python SDK side of them exists
behind undeclared operations, see `Python/protocol-telegram.md`). `menus.register`
supports `MESSAGE_CONTEXT_MENU` rows with Python conditions/clicks and bounded
metadata only. `menus.add` (`Integration/AyuPluginMenus.swift`: all five menu
types, long clicks, a `context` with TL objects) is declared only while a bound
Telegram backend serves `telegram.peer` and `telegram.messages`; keep it out of
the `operations` literal the corpus meter scrapes. Its app-side rows are built by
`PeerInfoScreen/Sources/AyuPluginContextMenu.swift` (chat header avatar menu,
profile "More" menu, message menu); main and drawer items are rows of the plugin
manager. `resources.resolve` (`Integration/AyuPluginResources.swift`) maps
Android drawable and Lottie names to Telegram-iOS image sets and SF Symbols for
menu icons, `ImageView.setImageResource` and bulletin icons only; add a name to
its tables only with a target that exists (`Tests/Python/test_menus_resources.py`).
MVEL strings are unsupported by the host. See
`Resources/CommonBridge/APPLICATION-BRIDGES.md`.

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
