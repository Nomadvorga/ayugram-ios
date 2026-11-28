# Supplied plugin corpus: static compatibility inventory

All **493 standalone `.plugin` attachments**, **15 `.elyx` packages**, and **6 `.eaf` packages** were inspected as static data. All 737 available Python source units parsed successfully: 688,577 standalone lines and 108,667 archive-source lines, totaling **797,244 lines**. No supplied code was imported or executed. `execution_verified` remains **false** and `runtime_validation_required` remains **true**.

The bounded machine-readable [API inventory](../tools/plugin_inspector/corpus-api-inventory.json) contains the exact statistics, SDK fingerprints, ranked requirements, and truncation counts. The [inspector documentation](../tools/plugin_inspector/README.md#corpus-inventory-and-sdk-comparison) describes the reproducible CLI and limits. Reports omit attachment names, archive member names, input paths, arbitrary literals, configuration, credentials, and source excerpts.

This inventory and its checked-in JSON predate the 2026-11-26 bridge changes and were not regenerated: the counts below describe the 493-attachment snapshot and the earlier SDK declaration snapshot. The `plugins/` directory now holds 485 `.plugin` files, and the bridge's own preflight over them is reported in [Bridge preflight over the corpus](#bridge-preflight-over-the-corpus-2026-11-26).

## Corpus and provenance

The filename-independent fingerprint of the sorted attachment multiset is `ebfb1b41c27a42dac13794dfe4fc8dfff63a505a2c3a37db9d87b4a24c56881a`. It hashes each attachment's extension, SHA-256 and byte length; renaming attachments does not change it. All 493 standalone sources have distinct byte hashes. Across standalone and archived files, there are 727 distinct source hashes among 737 source units. These are byte identities, not unique plugin identities or versions.

The Android comparison reads the 32 Python SDK sources from exteraGram reference revision `b4d852f48f2734a0bee1a74a0939be621612262a`, with SDK fingerprint `fa38963a972e89e2e64090ce80026e1150f4bad4045c3aa482b1266cba4c7eee`. The bridge fingerprint in the JSON identifies the particular working-tree SDK snapshot used for declaration comparison. Regenerate the report after bridge changes. A declaration can be a wrapper, stub, guarded import or re-export; its presence does not establish native implementation or semantic parity. Chaquopy provides Android's `java` namespace outside this Python SDK tree, so its absence from that tree is expected.

| Attachment kind | Attachments | Available Python source units | Parsed source lines |
| --- | ---: | ---: | ---: |
| `.plugin` | 493 | 493 | 688,577 |
| `.elyx` | 15 | 143 | 63,031 |
| `.eaf` | 6 | 101 | 45,636 |
| Total | 514 | 737 | 797,244 |

513 attachments contain parseable source. One archive has no Python source to inspect. All 21 archives are ZIP containers; their source members were read in memory without extraction. The inventory read 70,510,904 bytes, including archive source reads, with no reported source or archive errors. Four source units contain explicit external-process requirements and receive static `unsupported`; the remaining 733 are `unknown` against the deliberately unconfigured default support manifest. These counts apply to source units, and neither value counts working plugins.

Six standalone sources exceed 1 MiB and five exceed the former 2 MiB source bound; the largest is 3,503,627 bytes. Inspection and the coordinated application service, embedded runtime, Python loader and manager now use a 4 MiB source quota. All 493 standalone sources fit this size bound. Passing the source quota does not establish API compatibility, package support, trusted enable consent or runtime success.

486 of the 493 standalone plugins declare at least one nonempty or computed version field: `__min_version__` in 321, `__app_version__` in 209 and `__sdk_version__` in 158. These overlapping counts include direct top-level assignments and annotated assignments; expressions and constraint values are not evaluated or reproduced. A declaration is not evidence that the host satisfies it. Empty literal fields do not contribute. Since 2026-11-26 the Python SDK evaluates these constraints with Android comparison semantics against an emulated plugin SDK 1.4.6.5 / exteraGram 13.2.2 (`Python/_ayu_policy.py`): of the 479 plugins in the current 485-plugin corpus that declare a version key, 478 are satisfied and one (`==13.1.1`) is a `VERSION_POLICY` blocker. The Swift change that defers to this result is not compiled.

## Requirements ranked by attachment reach

`files` in the JSON counts attachments, including packages; `unique_sources` deduplicates source bytes. Several source files in one package can use the same API, so distinct-source reach can exceed attachment reach. All branches and function bodies contribute. The rankings measure possible requirements, not execution frequency or compatible plugins.

The corpus uses 952 distinct Java classes, 3,556 distinct Java members, 235 imported SDK symbols and 351 import-module targets. Each ranking displays at most 50 entries in the checked-in JSON and records its omitted-target count. The declaration-gap ranking uses all identified SDK targets before display truncation. Dynamic Java return types, computed reflection, class generation, inherited members and arbitrary interprocedural flow remain unresolved.

| Requirement family | Attachments | Practical native work |
| --- | ---: | --- |
| Telegram messenger controllers | 427 | Explicit account, peer, application and message-service adapters |
| Unresolved Java members/returned objects | 425 | Typed return values and exact virtual member inventories |
| Reflection | 358 | Explicit virtual class/member registry; overload and field semantics |
| Telegram Android UI | 304 | Native screen, theme, navigation and presentation mappings |
| Method hooks | 294 | Defined host interception points, cancellation and unload semantics |
| Android view/widget classes | 254 | Native layout, view properties, listeners and lifecycle |
| Java callback proxies | 195 | Revocable callbacks with asynchronous interpreter dispatch |
| Android graphics | 190 | Native drawing and resource mappings; animation on native clocks |
| Plugin-created threading imports | 175 | Cancellation, generation ownership, bounded queues and unload behavior |
| Telegram TL objects | 145 | Typed requests, responses, updates and exact integer identifiers |
| Restricted Android system/VM APIs | 111 | Explicit platform policy; unsupported cases remain visible |
| Android media | 59 | Media and recorder/player mappings with platform permissions |
| Java subclass declaration/override calls | 20 | Native inheritance points and callback contracts |

Other uncertainty is substantial: conditional API bindings appear in 440 attachments, dynamic attributes in 314, unresolved hook targets in 201, computed reflection in 175, enumerated reflection in 168 and computed hook selection in 93. Supporting a broad reflection/hook capability cannot resolve those exact targets automatically.

The table lists requirements, not what is implemented. As of 2026-11-26 the threading row has a Python-side implementation (real Python threads with bridge calls marshalled onto the serial queue, gated on `scheduler.schedule`/`scheduler.cancel`); in the bridge preflight `IMPORT` blockers fell from 157 to 12 plugins (`ctypes` 9, `subprocess` 3). The TL-object and messenger-controller rows have Python-side models that depend on 19 host operations the Swift host does not implement. Method hooks have no target mapping. None of this was run on a device.

## Highest-impact SDK and host work

The direct-call inventory gives concrete priorities beyond broad import coverage:

| API or override | Attachments | Required behavior |
| --- | ---: | --- |
| `create_settings` override | 397 | Correct row models, setting changes and native manager presentation |
| `ui.settings.Header` call | 343 | Native settings sections |
| `BasePlugin.get_setting` call | 337 | Owner-scoped defaults, serialization and lifecycle |
| `android_utils.run_on_ui_thread` call | 315 | Main-thread scheduling without waiting on Python |
| `client_utils.get_last_fragment` call | 299 | Authorized live screen context with stale-reference rejection |
| `BasePlugin.set_setting` call | 211 | Persistence and requested settings reload semantics |
| `BulletinHelper.show_error` call | 189 | Native error presentation with context and lifecycle checks |
| `BasePlugin.hook_method` call | 175 | Exact host interception; no arbitrary Swift method patching |
| `BulletinHelper.show_info` call | 169 | Informational bulletin spelling and native presentation |
| `AlertDialogBuilder` call | 162 | Native dialog construction, listeners, dismissal and ownership |
| `BasePlugin.add_menu_item` call | 147 | Menu insertion and message/chat/profile context callbacks |
| `BasePlugin.hook_all_methods` call | 138 | Explicit supported targets, overload semantics and revocation |
| `on_send_message_hook` override | 132 | Outgoing-message decision, modification and cancellation semantics |
| `BasePlugin.add_on_send_message_hook` call | 126 | Registration connected to the real message pipeline |
| `client_utils.run_on_queue` call | 100 | Bounded work scheduling with scope cancellation |
| `client_utils.send_request` call | 60 | Account-aware typed request completion and error callbacks |
| `client_utils.send_message` call | 48 | Correct peer/message payload handling and send behavior |

The checked-in report, which predates the 2026-11-26 SDK port (agents report that `ui.settings`, `ui.alert`, `ui.bulletin`, `lifecycle`, `file_utils`, `intents`, `log_utils` and `text_formatting` were brought close to Android parity, including `show_undo`), lists **7 distinct observed APIs** present in the Android SDK but absent from the bridge declaration snapshot. The largest remaining entries are `BulletinHelper.show_undo` (4 attachments), `PluginsController` and `BulletinHelper.show_file_saved_to_downloads` (2 each), plus four one-attachment symbols. `show_with_button`, `RequestCallback`, `NotificationCenterDelegate` and `show_copied_to_clipboard` now exist in the SDK declaration snapshot, but that is not end-to-end coverage: the host implements a bounded bulletin button and copy-feedback path, while Telegram request delegates remain unwired and notification delivery is limited to global `activeAccountChanged`. Copy feedback does not itself read or write the clipboard. The JSON is authoritative for the current inventory and SDK fingerprint; regenerate it after SDK changes. Declaration presence alone does not establish native behavior.

Bulletin work should preserve Android SDK argument order and optional fragment behavior. Button bulletins carry a callback and duration; undo bulletins distinguish immediate undo from deferred action. A wrapper that accepts these arguments but ignores them would produce incorrect behavior. Request delegates must preserve account identity, response/error delivery, callback lifetime and unload cancellation. Hook filters need their actual predicate semantics at supported interception points.

The largest native class/member requirements are concrete enough to guide adapter sequencing:

| API | Attachments |
| --- | ---: |
| `org.telegram.messenger.ApplicationLoader` | 238 |
| `org.telegram.messenger.AndroidUtilities` | 229 |
| `ApplicationLoader.applicationContext` | 220 |
| `AndroidUtilities.dp` | 177 |
| `org.telegram.ui.ActionBar.Theme` | 160 |
| `android.widget.LinearLayout` | 158 |
| `android.widget.TextView` | 155 |
| `android.view.View` | 153 |
| `org.telegram.messenger.UserConfig` | 143 |
| `LinearLayout.setOrientation` | 142 |
| `LinearLayout.addView` | 140 |
| `TextView.setTextSize` | 134 |
| `Theme.getColor` | 131 |
| `TextView.setText` | 127 |
| `TextView.setTextColor` | 125 |

The virtual view tree now implements a bounded observed `Gravity` alignment subset, basic `LinearLayout.LayoutParams` weight distribution for remaining main-axis space, and one-child vertical `ScrollView` backing. Horizontal scrolling, nested scrolling, fling physics and Android scroll callbacks remain unsupported. The built-in Java registry also wires bounded local `Bundle`/`Intent` values, synthetic `MotionEvent` snapshots and revocable main-queue `Handler.post` callbacks; these Swift adapters do not launch Android activities, expose live touch objects or emulate Android loopers (a Python-local `Looper`/`Handler` model now exists in `Python/_ayu_javalib/concurrency.py` and replaces the `Handler` adapter). The current app bindings already provide narrow message-context menus, an outgoing text/caption hook and global account-change notification, but no Telegram request transport or media adapter; the Python SDK side of requests, sending, files and menus exists behind host operations that are specified in `Python/protocol-telegram.md` and not implemented in Swift. Preserve typed IDs and native thread ownership throughout. Android draw hooks and per-frame callbacks should become native drawing/animation adapters with settings-driven updates. Static API reach cannot establish visual fidelity, smoothness or device performance; those require the repository's native build and recorded-frame checks.

## Packages, dependencies and binary payloads

| Archive payload kind | Members | Archives containing it |
| --- | ---: | ---: |
| Python source | 244 | 20 |
| Python bytecode | 99 | 3 |
| Android DEX | 6 | 5 |
| Native binary extension | 2 | 2 |
| Images | 54 | 7 |
| Fonts | 11 | 1 |
| JSON data | 26 | 7 |
| Web content | 3 | 1 |

Archive import support requires package metadata/entry points, namespaced local modules, bounded resources and lifecycle cleanup. Fourteen attachments import `elyx`; one imports `elyxcore`. These generated/package APIs need explicit handling beyond treating a package as a single `.plugin` file. Since 2026-11-26 the Python SDK has that handling (`Python/_ayu_packages.py`, `elyx`, `elyxcore`): all 21 packages are inspectable, none passes preflight (19 have `OPERATION` blockers) and three are blocked by compiled bytecode. Loading is covered by synthetic tests only, and the Swift importer neither accepts `.elyx`/`.eaf` nor calls these entry points. Relative imports appear in ten attachments and 162 distinct source units. Package-local imports are inventoried, but no imported file is resolved or executed to infer behavior.

The 99 bytecode files, six DEX members and two native binaries were classified by member extension only. No bytecode was disassembled or loaded, no DEX was run, no binary was linked and no nested archive was opened. Their Android availability says nothing about signed iOS packaging or interpreter/ABI compatibility. A source-empty package cannot receive source-level coverage from this audit.

`requests` is imported by 74 attachments; `PIL` by 19, `mutagen` by four, `yaml` by four, and `packaging.version` by three. These import counts can include bundled helpers. `requests` submodules and optional/guarded imports are retained; a bridge module with the same root name does not imply those submodules or HTTP semantics exist. Pillow is a native dependency needing a supported signed iOS build or an explicit native image-service mapping. `audioop` is imported by six attachments and is absent from the Python 3.14 host standard-library list; target-runtime availability must be established separately. Dynamic declared dependencies appear in ten attachments and are not evaluated.

In the bridge preflight of the current corpus (2026-11-26), imports without a bundled module are `DEPENDENCY` blockers in 47 plugins: `PIL` 17, `audioop` 6, `mutagen` 4, `yaml` 3, `bs4`, `cachetools`, `packaging.version` and `plugins_manager` 2 each. Unbundled `__requirements__` entries block 14 plugins as `REQUIREMENT`: mutagen 5; cachetools, tinydb, websocket-client, yt-dlp 2 each; babel, certifi, exteragram-alib, humanize, mpmath, nowfy, pysocks, yandex-music, yt-dlp-ejs 1 each. Nothing is installed at runtime; a requirement is satisfied only by a bundled module.

## Bridge preflight over the corpus (2026-11-26)

Unlike the inventory above, this runs the bridge's own `preflight_plugin_json` over every `.plugin` in `plugins/` with host capabilities scraped from Swift literals (37 operations, 125 host classes, 33 modules; the class set is an upper bound) and 3419 Python-local classes. The numbers are those after the review fixes described below. Nothing is imported or executed. A pass is the absence of static blockers, not evidence that the plugin runs; nothing was compiled or run on a device.

```sh
python3 -X utf8 -B -m tools.plugin_inspector preflight-corpus --plugin-dir plugins --top 15
```

485 plugins: **pass 9, blocked 476, rejected 0**.

| Blocker kind | Plugins | Distinct | Largest entries (plugins) |
| --- | ---: | ---: | --- |
| `OPERATION` | 425 | 65 | `hooks.java_method` via `hook_method()` 177, `hook_all_methods()` 134, `hook_all_constructors()` 23; `sdk.unprovided_member` via `getDeclaredField()` 95, `getWindow()` 65, `getDecorView()` 51, `getFilesDir()` 34, `setMessage()` 30; `menus.add` `CHAT_ACTION_MENU` 93, `DRAWER_MENU` 44; `telegram.request` 60; `telegram.send_message` via `send_message` 47; `telegram.hooks.set` 27; `telegram.hooks.send_message` 25 |
| `CLASS` | 404 | 624 | `R` 70, `ChatActivity` 68, `InMemoryDexClassLoader` 63, `FileLoader` 62, `PluginsController` 54, `Bitmap` 52, `BitmapFactory` 44, `LayoutHelper` 44, `MediaController` 42 |
| `DEPENDENCY` | 47 | 40 | `PIL` 17, `audioop` 6, `mutagen` 4, `yaml` 3 |
| `REQUIREMENT` | 14 | 14 | mutagen 5 |
| `SDK_MEMBER` | 14 | 17 | `base_plugin.PluginsController`, `client_utils._prepare_document`, `zwylib.DialogPicker` 2 each |
| `IMPORT` | 12 | 2 | `ctypes` 9, `subprocess` 3 |
| `VERSION_POLICY` | 1 | 1 | `app_version==13.1.1` |

A plugin counts once per kind and usually has several kinds. The pass count moved 24 (baseline) → 39 (class seam and `java.*` preflight fix) → 56 (threads and Python-local Java classes) → 20 → 9. Neither fall is a regression in support; each came from making preflight honest. First the `OPERATION` kind was added: 44 of the earlier passes called SDK functions whose host operation does not exist. Then an independent read-only review found 12 of the 20 remaining passes to be false, and they were gated: 21 audited host members that nothing provides are reported under the reserved `sdk.unprovided_member`, `R` requires the new `resources.resolve` operation, `ChatObject`/`UserObject` require `telegram.peer`, and send hooks that touch fields beyond peer/message/caption require `telegram.hooks.send_message`. With all 19 operations of `Python/protocol-telegram.md` declared, 47 would pass (66 before the review fixes); that is a target for Swift work, not current support.

`sdk.unprovided_member` is a curated list, not member-level preflight, which would need `runtime.capabilities` to publish per-class members. False passes may therefore remain among the 47, and the 9 current passes were audited by member name only.

277 of the 485 plugins call Xposed `hook_method*` on 369 distinct targets, none used by more than 7 plugins. Before the review fixes 48 plugins were blocked by that alone with all operations declared; the figure was not re-measured. No hook-target mapping exists.

Packages are reported separately: 21 `.elyx`/`.eaf`, 21 inspectable, 0 pass, 21 blocked (`OPERATION` 19, `CLASS` 18, `PACKAGE` 3 for compiled bytecode, `SDK_MEMBER` 3, `DEPENDENCY` 2, `IMPORT` 1).

## Changes and verification

The inspector now supports flat corpus inventory, bounded in-memory ZIP source inspection, payload counts, deduplication, SDK declaration comparison and deterministic JSON/Markdown rankings. It recognizes additional SDK/native namespaces and Java subclass declarations. Plugin-owned `self` methods and assigned attributes are excluded from inherited SDK call requirements. Parser warnings are suppressed to keep source-derived diagnostic text out of stderr. The existing build audit script exposes corpus mode while retaining its pinned 19-plugin mode.

The default manifest remains unconfigured. No declaration, generated inventory or added inspector feature grants runtime support. App source quotas, trusted enable consent, runtime build provenance, native API support, package loading and device verification remain independent checks.

The synthetic inspector/audit suite passed **40 tests** using the requested CPython 3.14 interpreter. It covers non-execution, source/literal/path omission, deterministic renamed/duplicate inputs, archive parsing without extraction, unsafe members, invalid sources/archives, SDK declaration gaps and re-exports, ranking bounds, output protection, source warning redaction, plugin-owned helper classification, exact pinned-source provenance and hash-only refresh behavior. The full real corpus completed without parse/archive errors. Native application execution, iOS builds, visual checks and plugin functionality were not verified by this static task. As of 2026-11-26 the inspector suites, now including `tools.plugin_inspector.preflight_tests`, total 71 tests; the bridge SDK suite has 606 and the build suite 44, all passing on CPython on macOS.

## Refreshing the extended pinned catalog

The legacy CommonBridge catalog contains the original 19 upstream sources plus one separately supplied source. Full original-19 regeneration and implementation-hash refresh are distinct operations. The original generator's source manifest is not present in this checkout; all 20 exact original source files are available in the existing source directory. A hash refresh needs no reconstructed manifest and never regenerates or fabricates requirements.

After all Python/native edits settle, run from the repository root:

```sh
python3 -B submodules/AyuPluginBridge/Build/audit-plugin-requirements.py --refresh-implementation-hashes --plugin-dir plugins
```

Add `--check-refresh` for a dry run. The command compares the existing catalog's source identity records against `git show HEAD:submodules/AyuPluginBridge/Resources/CommonBridge/compatibility.json`, then verifies every referenced file's SHA-256, Git blob SHA-1, byte length and line count. It retains explicit external-source provenance and rejects changed source identities or runtime-verification claims. Only `sdk_sha256` changes; requirements, statuses, route metadata, source provenance and limitations remain untouched.

Implementation hashes cover every `Python/**/*.py` and every current Swift, Objective-C and header implementation under the bridge's `Sources`, `Integration`, `ObjC` and `PublicHeaders` directories. Tests and generated reports are excluded. Application bindings outside this bridge are not included in this bridge-relative hash inventory. Adding a nested SDK file changes the required key set, so the CommonBridge catalog test checks both completeness and byte hashes. The default catalog path can be overridden with `--catalog` for a reviewable temporary copy; the committed catalog remains the provenance anchor.

The legacy full-regeneration path reads `ayu_bridge.SDK_MODULES` as a bounded AST literal, never imports the SDK or attachments, and compares SDK declarations statically. Its application-class subset names the explicit current native registry classes; those class names remain partial declaration evidence. Full original-19 output cannot overwrite the extended 20-source catalog because the pinned source sets differ. Use hash-only refresh for the extended catalog, and re-run corpus inventory separately when a new declaration-gap snapshot is wanted.
