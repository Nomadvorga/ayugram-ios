# AyuPluginBridge Python ↔ native protocol v1

## Extensible class adapters (common bridge, first stage)

`AyuBridgeClassRegistry.standard.adding(...)` supplies explicit compiled native
classes to `AyuPluginService`/`AyuPluginNativeHost`. It cannot replace built-in
view, layout, array or proxy classes. Duplicate names, ambiguous members, reserved
reflection names, invalid constants and undeclared writable fields are rejected
when constructing the registry. No Java/JVM, private selector resolution, Java
subclassing or automatic Android API emulation is introduced.

Adapters declare constructors, static/instance methods, constants, readable and
writable fields, and `validateState`. Only declared members are exposed. Hidden
JSON state is not accessible through the private-field helpers. Constructors,
mutations, field writes and factory-created instances all run schema validation,
owned-reference checks and the aggregate `adapterStateBytesPerPlugin` quota
(default 1 MiB). Results additionally obey the response quota. Failed instance
calls roll back state and newly allocated handles. Adapters must be bounded,
side-effect-free synchronous transformations; irreversible app/UI effects belong
in a real application provider, not these closures.

`AyuBridgeAdapterContext` gives typed, read-only snapshots of current-owner
references. It is host-worker-only and generation-scoped; do not retain it or
start threads. Handles/callback tokens remain host-owned. Adapters cannot invent
callback tokens. Atomic classes below provide serial value operations, not plugin
thread support or a Java memory-model guarantee.

Implemented **subsets**, not complete Java classes:

| Class | Implemented surface |
|---|---|
| Integer / Long | bounded constructor/valueOf, decimal parseInt/parseLong, toString, intValue, longValue, MIN_VALUE, MAX_VALUE, TYPE |
| Boolean | bool/string constructor/valueOf, parseBoolean, booleanValue, TYPE |
| ArrayList | empty/capacity/array/list constructor, size, isEmpty, clear, get, set, add, addAll, remove, contains, indexOf, toArray; Python length/indexing |
| HashMap | empty constructor, size, isEmpty, clear, containsKey, get, put, remove; typed JSON key/value pairs |
| AtomicLong | empty/value constructor, get, set, getAndSet, incrementAndGet, compareAndSet |
| AtomicBoolean | empty/value constructor, get, set, compareAndSet |
| System | currentTimeMillis, monotonic nanoTime |

Primitive descriptors: byte, short, int, long, char, boolean, float, double, void.
Arrays support the eight non-void primitives, bounded by the existing transaction
element limit; object arrays remain unsupported. ArrayList `toArray` returns a
JSON/Python list, not a Java Object[] instance. Collection equality is typed JSON
value/reference equality, not arbitrary Java `equals`/`hashCode`; `remove(integer)`
is the index overload. Non-listed methods/overloads must fail explicitly.

Static SDK inspection now records aliased/qualified class lookups, imported SDK
symbols, missing SDK symbols and computed class-lookup locations before source
activation. This is conservative AST inventory, not full Python name/scope or
runtime compatibility analysis. `android_utils.OnClickListener` forwards through
the declared generation-owned click proxy; `get_static_private_field` exposes
only declared constants; `get_client` forwards to an owned AccountClient and
does not manufacture a Telegram provider.

The hash-pinned 19-plugin requirements table lives in
`Resources/CommonBridge/compatibility.json` and its README. It records zero
runtime-verified plugins. Atmospheric Snow retains its exact-hash native route;
the other 18 remain blocked. The default provider still lacks actual Telegram
objects/requests, application/message events, method hooks, menus and alert/
bulletin presentation. Camera, passcode, screen-capture and destructive-message
features require real iOS adapters respecting platform and account invariants.

Regenerate the static table with `Build/audit-plugin-requirements.py`, supplying
the pinned source manifest and read-only source directory. Never commit the
reference `.plugin` files. Synthetic SDK tests may execute only test-authored
fixtures, never these supplied plugins. Swift test sources are independent of
Python/offline checks and require the authorized native test environment.

This file describes the implemented Python API contract. An adapter not explicitly implemented by the host must fail with `UNSUPPORTED_API`; registration or member lookup must never pretend success. This SDK is not a sandbox for untrusted Python. One interpreter and one native-owned serial Python queue are required; no plugin Python threads may call bridge APIs. UI effects are enqueued on main; main must never synchronously wait for Python. Native callbacks must return to the Python queue after dispatch returns, never re-enter Python inside `_ayu_host.dispatch`.

## Transport and ownership

Injected extension module: `_ayu_host.dispatch(request_json: str) -> response_json: str`.

Request: `{"version":1,"id":"17","plugin_id":"example","operation":"settings.get","arguments":{"key":"enabled","default":false}}`.

Success: `{"version":1,"id":"17","result":false}`.

Failure: `{"version":1,"id":"17","error":{"code":"UNSUPPORTED_API","message":"Adapter is unavailable"}}`.

Response must contain exactly version/id/result or version/id/error. Unknown fields, duplicate JSON keys, mismatched IDs, nonfinite values and malformed reference tags fail. IDs are decimal strings, correlation only. Host MUST use its externally established trusted owner (native TLS), compare request plugin_id with it, and check ownership/generation on every native handle, token and callback. Request plugin_id is not authority. The host must not leak credentials into errors.

`runtime.capabilities` is requested before code execution with request plugin_id `$runtime`; the host may special-case this read-only bootstrap operation when invoked from a native load with a trusted plugin owner. All other operations require exact owner match. Alternatively return the same capability payload under the trusted owner; the Python implementation currently uses the explicit `$runtime` bootstrap ID.

Wire values: null/bool/string/signed-int64/finite-double, arrays, string-keyed objects. Native reference: `{"$handle":"opaque-id","$class":"declared.class.Name"}`. Python callback: `{"$callback":"opaque-generation-bound-id"}`. Java class reference passed as a value: `{"$java_class":"declared.class.Name"}`. Tags are created by SDK objects only. Host return references must name a declared class. Ordinary dictionaries with reserved `$` keys are rejected by the encoder. No raw pointers, native symbol names, arbitrary selectors or dlsym.

## Native-facing Python entry points (ayu_bridge module)

- `inspect_plugin_json(source, filename="plugin.plugin") -> str`: JSON object containing `metadata`, `imports`, `classes`, `requirements`, `warnings`, `sdk_modules`, `python_stdlib_candidates`, `unsupported_imports`. `sdk_modules` lists this SDK's built-in entry modules. `python_stdlib_candidates` is only CPython's potential stdlib inventory, not evidence that an iOS build ships/supports every entry. `unsupported_imports` maps statically observed disallowed imports to explicit reasons (threading/_thread/concurrent/multiprocessing/subprocess/ctypes). Host-declared extra dependencies remain opt-in. AST only; no plugin execution and no host calls. Known threading imports are rejected by load/preflight because plugin threads are not a supported execution model.
- `load_plugin(source, filename="plugin.plugin", expected_id=None) -> dict`: parses literals, verifies expected ID, obtains capabilities, preflights classes/imports/threading, obtains explicit host authorization, then activates the owned host generation, compiles/executes source in a unique module, constructs exactly one BasePlugin subclass, and calls on_plugin_load. Raises BridgeError on failure and revokes partially registered work.
- `unload_plugin(plugin_id) -> bool`: calls on_plugin_unload then always atomically deactivates native scope and drops callbacks/module. on_plugin_unload may call native APIs, but cannot schedule/register new work. Old callbacks are invalid before unload code starts.
- `serialize_settings(plugin_id) -> str`: JSON array of component descriptors. Callback tags in the current generation remain live until unload (or component callbacks are replaced by a later settings serialization).
- `invoke_callback_json(text) -> str`: accepts `{"version":1,"plugin_id":"example","callback_id":"...","arguments":[...]}`. Returns JSON-encoded callback result (not an RPC response envelope). Host must authenticate owner and callback registration before entry. Inactive/unknown callbacks raise CALLBACK_EXPIRED.
- `emit_event_json(text) -> bool`: accepts `{"version":1,"plugin_id":"example","name":"app","arguments":["RESUME"]}`. Only app events START/RESUME/PAUSE/STOP are accepted. Hooks use registered callback IDs instead.

All entry points run on the same queue/thread. WRONG_QUEUE is raised on another thread. Main interpreter execution is not a security isolation boundary; this layer only scopes bridge state, references and callbacks.

Execution module identity is always the unique `_ayu_plugin_<generation>` name registered in sys.modules. The loader rewrites only the top-level literal `__name__` display-metadata assignment (including annotated/chained assignment targets) to `__ayu_display_name__` in the in-memory AST. Parsed metadata and BasePlugin.name retain the original human-readable title. At runtime `__name__` means Python module identity, not display title; this preserves decorators such as dataclass with forward annotations. No sys.modules alias is registered by display title, so two plugins may share a title safely. Subsequent dynamic mutation of runtime __name__ is unsupported and load-rejected when detected.

## Bootstrap, lifecycle, settings and state

| Operation | Arguments | Result |
|---|---|---|
| runtime.capabilities | `{}` | Exact object `{operations:[str], classes:[str], modules:[str], proxy_interfaces:{className:[methodName]}}`; names are explicit supported classes/import dependencies, not arbitrary prefixes |
| plugin.authorize | `{metadata:object, imports:[str], classes:[str], requirements:[str]}` | literal `true` only on approval, otherwise error; MUST validate available dependencies and SDK/app constraints before execution |
| plugin.activate | `{metadata:object, generation:str}` | null on success; native establishes generation before lifecycle registrations |
| plugin.deactivate | `{generation:str}` | null; atomic cleanup barrier: cancel all jobs; unregister hooks, menus, proxies/UI listeners; revoke all handles and callbacks for this owner/generation. Must work even after a failed load before activate |
| settings.get | `{key:str, default:JSON}` | stored value or default; always owner-scoped |
| settings.set | `{key:str, value:JSON, reload_settings:bool}` | null |
| settings.all | `{}` | ordinary JSON dictionary of this owner's settings |
| state.get | `{key:str, default:JSON}` | transient state value or default, owner-scoped |
| state.set | `{key:str, value:JSON}` | null |
| log.write | `{level:str,message:str}` | null |

Persistent settings belong to plugin ID, transient native state/handles/jobs belong to plugin ID AND generation. Host handles storage type and size limits. Metadata literals are parsed without exec. Importing threading or `_thread` is load-rejected: original Music Bridge/Fish files requiring Python threads are therefore not fully compatible yet. No silent thread emulation is implemented.

## Scheduling and callbacks

`scheduler.schedule`: `{queue:str,delay_ms:number,callback:{$callback:str}}` → nonempty opaque token string. Queue `main` means schedule a callback back onto the Python serial queue after main scheduling/host prerequisites, NOT execute Python code on main. UI calls made by that callback go to main asynchronously. Other conventional queue names are pluginsQueue/globalQueue/stageQueue/cacheClearQueue/searchQueue/phoneBookQueue/themeQueue/externalNetworkQueue. Host must reject unsupported queues, not run a Python callback on an arbitrary thread. Jobs are one-shot; a callback cannot fire synchronously inside schedule. `scheduler.cancel`: `{token:str}` → null; cancellation must prevent callback entry if it has not begun.

`hooks.register`: `{kind:str,...config}` → opaque token string. Kinds used by SDK: `send_message`, `request` (name,priority), `java_method` (method native ref, before/after callback tags,priority), `java_all_methods` / `java_all_constructors` (class native value, optional name, before/after tags,priority). Unsupported hook kind/target must error before registering. Hook callback receives host-adapted JSON arguments/native refs. `hooks.unregister`: `{token:str}` → null.

`menus.register`: `{type:str,text:str,on_click:callback,...config}` → opaque token. Config may include icon,priority,condition. `menus.unregister`: `{token:str}` → null.

Tokens cannot be shared across owners. Host must not invoke retained callback IDs after cancel/deactivate. Python also checks generation and drops one-shot callbacks on invocation.

## Java facade

`jclass(name)` performs an exact Python-side lookup in capabilities.classes and returns a class facade; it does NOT call `java.class` or load a JVM class. Native reflection objects are ordinary owned references returned by supported methods such as getClass/getDeclaredMethod. Arbitrary reflection targets remain unsupported.

Target formats: static class target `{"class_name":"android.view.View"}` or owned object reference `{"$handle":"...","$class":"..."}`. A Java class used in an argument is the separate `$java_class` tag.

| Operation | Exact arguments | Result |
|---|---|---|
| java.member | `{target:target,name:str}` | `{kind:"method"}`, `{kind:"field",value:wireValue}`, or `{kind:"class",class_name:str}`. Missing/unsupported member → error; never guessed as a method |
| java.construct | `{class_name:str,args:[wireValue],kwargs:object}` | owned native reference; adapter may reject overload/kwargs |
| java.invoke | `{target:target,name:str,args:[wireValue],kwargs:object}` | wireValue; supported explicit methods only |
| java.set_field | `{target:target,name:str,value:wireValue}` | null; readonly/unsupported field → error |
| java.length | `{target:objectRef}` | nonnegative int |
| java.get_item | `{target:objectRef,index:int}` | wireValue |
| java.set_item | `{target:objectRef,index:int,value:wireValue}` | null |
| java.array | `{component:str,values:[wireValue]}` | owned array reference with declared class; component is primitive name or declared Java class |
| java.cast | `{class_name:str,value:wireValue}` | type-checked native reference/value; incompatible type → error |
| java.proxy | `{interfaces:[str],callbacks:{methodName:callbackTag}}` | owned listener reference. Interfaces/method names must come from capabilities.proxy_interfaces |
| java.get_private_field | `{target:objectRef,name:str}` | wireValue, explicitly adapted fields only |
| java.set_private_field | `{target:objectRef,name:str,value:wireValue}` | null, explicitly adapted fields only |

`org.telegram.*`, `android.*`, and `java.*` package imports are provided only if a declared class exists below the package; class access still requires exact registration. Nested classes are returned via `java.member` kind=class, e.g. View.OnClickListener. Native import namespaces may be cached by Python, but class/handle lookup always uses current owner. `jint/jlong/jfloat/jdouble/jboolean/jbyte/jshort/jchar` validate/coerce primitive Python values; arrays are host-owned, not placeholder Python lists. dynamic_proxy only supports explicitly declared interfaces and verifies all required methods when exporting the listener.

## Higher-level helpers

`client.call`: `{name:str,args:[wireValue],kwargs:object}` → wireValue. Implemented Python entry helpers: get_last_fragment, get_messages_controller, get_user_config, get_connections_manager, get_send_messages_helper, get_media_data_controller, get_notification_center, get_account_instance, get_selected_account, send_message, edit_message, send_request. Native host must explicitly implement each name, preserve account/reply/topic/schedule context and error otherwise. AccountClient adds account to kwargs; no plugin-global mutable current account is stored by the SDK.

`ui.present`: `{kind:"alert"|"bulletin",config:object}` → owned native UI reference or null for a fire-and-forget bulletin. Alert config contains builder setters including on_click callback tags; fluent setters are local descriptor construction, show performs presentation. Only supported options may be accepted by host. Components: `{type:"Header"|"Divider"|"Text"|"Input"|"Switch"|"Selector",...config}` with callbacks encoded as `$callback` values. Host renders native rows, validates setting keys and dispatches changes/clicks through registered callbacks.

## Optional HTTPS requests subset

`requests.py` is bundled compatibility code, not upstream requests or a pip installation. It is deliberately NOT in SDK_MODULES: the host must advertise `requests` in capabilities.modules only when this file, Python ssl/socket/native dependencies and valid trust roots are actually packaged. On iOS the opener explicitly loads checksum-pinned packaged `certifi.where()` through `ssl.create_default_context(cafile=...)`; a missing/invalid trust store fails closed, without disabling verification. Other platforms use system default verification. This compatibility layer is not a network sandbox.

Supported: `request/get/post`, per-instance `Session` with headers and CookieJar, context manager/close; HTTPS-only absolute URLs without embedded userinfo; params, form/text/bytes data or JSON; headers; positive scalar timeout (default 15 seconds, maximum 60 seconds); allow_redirects bool; stream=False; verify=True. Response exposes status_code, content, text, json(), case-insensitive headers, url, ok and raise_for_status(). urllib HTTP status errors become Response objects; only raise_for_status raises HTTPError for 4xx/5xx. Exceptions namespace includes RequestException, ConnectionError, Timeout, SSLError, HTTPError, InvalidURL, TooManyRedirects, ContentTooLarge, ContentDecodingError, UnsupportedOption, JSONDecodeError. Error messages omit URLs, response bodies and credential values.

Redirects resolve relative paths through urllib; HTTPS→HTTP/nonweb destinations are rejected. Authorization/Proxy-Authorization/Cookie headers are stripped when scheme/host/port origin changes. 307/308 preserve method/body; 301/302/303 use the explicitly implemented requests-style method change. Maximum redirects is five. Transport-controlled Host/Content-Length/Transfer-Encoding overrides are rejected. Bodies are fully buffered with limits of 8 MiB outbound and 16 MiB inbound/decompressed; gzip decoding is bounded, unsupported content encodings error. Accept-Encoding defaults to identity.

Not implemented: streaming/iter_content, multipart/files, auth helpers, custom certificates/verify paths, proxies overrides, retries, per-connect/read tuple timeouts, hooks/adapters, arbitrary requests subpackages or asynchronous cancellation. The shim also checks a monotonic elapsed deadline between redirects and before/after bounded reads. A blocking socket read/open cannot be interrupted by these checks, so this is not a hard total wall timeout. urllib blocks the interpreter queue until completion; UI main must never wait for it. The SDK does not simulate Python threads. This only addresses a dependency import/API subset; supplied Fish/Music plugins still fail the independent threading preflight and other native adapters may be unavailable. SDK callback/load budgets count interpreter-thread CPU time via time.thread_time, so I/O waiting does not consume the 250 ms callback CPU budget. This does not add asynchronous execution or a native watchdog.

## Limits and validation

Python bounds: source 2 MB UTF-8, JSON input 4 million characters, nesting 64, 32 loaded scopes, 4096 callbacks and 1024 registrations per plugin. Native host must separately bound its handles/queues and preserve signed Int64 values. A cooperative `sys.settrace` CPU-time budget uses `time.thread_time` and checks every 64 original-source line events: load 2 CPU seconds, callback/event 250 CPU ms, settings/unload 500 CPU ms. The previous trace is restored. Elapsed wall time and I/O waits are not the budget. This interrupts ordinary Python loops but is catchable and cannot interrupt blocking native/stdlib calls; it is not a hostile-code watchdog or sandbox, and no native watchdog is implemented by this SDK.

No upstream requests/pip installation, Android emulator, arbitrary Java class/member, arbitrary Swift selector, Python native extension loader, unrestricted method hooking, Canvas/layout renderer, or background-thread compatibility is supplied in these Python files. The optional requests facade above is only its documented subset. Host capabilities must advertise only adapters really implemented. A plugin may pass static inspection and later request a dynamically computed unsupported API: it must then receive an explicit failure. Static inspection is a preflight, not proof of full compatibility or a security sandbox.

Tests in Tests/Python use a fake injected host and synthetic source strings only. They cover owner isolation, response validation, remote reference round trips, callback lifetime, unload cleanup, enums, undeclared classes and pre-execution rejection. The latest explicitly authorized short synthetic run, `python3 -B -m unittest discover -s submodules/AyuPluginBridge/Tests/Python -v`, passed all 33 tests in 0.094 seconds: 21 SDK/runtime tests and 12 offline HTTPS tests. The runtime regressions include annotated display metadata and two same-title plugins using dataclass with forward annotations, unique module identity and independent unload cleanup. HTTPS fixtures use a fake urllib opener and fake clock; no live service is contacted. No supplied plugin was executed. Native integration still requires a cool development machine and real iOS verification.
