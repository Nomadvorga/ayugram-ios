# Handoff

## 2026-11-26 — Plugin bridge: Python-side port (rounds 2–3, after review fixes)

Working tree: `/Users/toby/work/ayugram-ios` (macOS), branch `plugins-test`, module `submodules/AyuPluginBridge`. Every change below is uncommitted in that working tree. This Mac has Command Line Tools only: no Swift was compiled, nothing ran on a device or simulator, and a static preflight pass is not proof that a plugin works. Suite totals and corpus numbers were re-measured by the lead after the review fixes; the per-area items are as reported by the agents and were not reviewed line by line.

Review outcome: an independent read-only review found 12 of the 20 plugins that then passed preflight to be false passes (they use members or operations the host does not provide). This was fixed by gating, not by adding functionality: package preflight reports `OPERATION` blockers; 21 audited host members (`getWindow`, `getDecorView`, `getDeclaredField`, `addDialogToFolder`, ...) are blocked under the reserved operation `sdk.unprovided_member`; `R` is gated on the new operation `resources.resolve`; `ChatObject`/`UserObject` are gated on `telegram.peer`; send hooks that touch fields beyond peer/message/caption require `telegram.hooks.send_message`; zwylib `Requests`/`HookUtils` and `AccountClient` getters are gated. `sdk.unprovided_member` is a curated list. There is still no member-level preflight (it needs `runtime.capabilities` to publish per-class members), so false passes may remain; the 9 current passes were audited by member name only.

Implemented in Python and tested against a synthetic host only (contracts: `Python/protocol.md`, `Python/protocol-telegram.md`):

- Metadata policy (`Python/_ayu_policy.py`): Android version constraints are evaluated against the emulated plugin SDK 1.4.6.5 / exteraGram 13.2.2; unmet ones are `VERSION_POLICY` blockers (479 plugins declare a version key, 1 is unmet: `==13.1.1`). `__requirements__` is satisfied only by bundled modules; 14 plugins are blocked as `REQUIREMENT`.
- Python-local Java classes (`Python/_ayu_javalib/`): 14 provider modules, 346 classes (`java.lang/util/io/nio/net/text/time`, `org.json`, `android.os/text/util/content/graphics`). A host-declared class wins unless the local class sets `__ayu_overrides_host__`; 58 names exist on both sides, 28 are overridden, 30 stay host-first. Chaquopy import shapes are mirrored; `java.chaquopy` is an SDK module.
- Threads (`Python/_ayu_threads.py`, `_ayu_javalib/concurrency.py`): plugin threads are real Python threads whose bridge calls are marshalled onto the serial Python queue; gated on `scheduler.schedule`/`scheduler.cancel`; 64 threads per plugin, 256 total. `IMPORT` blockers fell from 157 to 12 plugins (`ctypes` 9, `subprocess` 3). No native edits. Known gaps: C-level waits on the queue thread (`time.sleep`, sockets, an asyncio loop) do not serve workers (`QUEUE_TIMEOUT` after 30 s); workers are outside the CPU budget.
- Telegram plane: 3028 TL classes generated for layer 233 (`Build/generate_tl_schema.py`), crossing the bridge as base64 binary TL; 47 messenger, 6 UI and 11 exteraGram facade classes; SDK entry points gated per host operation (`_ayu_operations.py`, `_ayu_hooks.py`) with the new preflight blocker kind `OPERATION`. `Python/protocol-telegram.md` specifies 19 host operations (the 18 Telegram/menu/plugin/layout ones plus `resources.resolve`); **none is implemented in Swift**.
- SDK port: `ui/settings.py`, `ui/alert.py`, `ui/bulletin.py`, `extera_utils/lifecycle.py`, `android_utils.py`, `zwylib.py` rewritten to Android behaviour; `elyx`, `elyxcore`, `_sdk_version` added; `SDK_MEMBER` blockers 20 → 14 plugins. UI degradations are explicit: alert cancel/back listeners raise `UnsupportedAPI`, `make_button_red` is a logged visual degradation (red buttons are not rendered), and an `EditText` row with `mask` or `max_length` other than 256 raises.
- Packages (`Python/_ayu_packages.py`): `.elyx`/`.eaf` inspection, preflight and loading exist in Python (21/21 inspectable, 0 pass preflight, 19 blocked by `OPERATION`, 3 by `.pyc` bytecode; unpacking streams in 64 KiB chunks with a 32 MiB per-entry cap); loading is covered by synthetic tests only and the Swift side does not call it.
- Corpus meter: `tools/plugin_inspector/preflight.py` (see its README).

Corpus numbers, reproducible with `python3 -X utf8 -B -m tools.plugin_inspector preflight-corpus --plugin-dir plugins --top 15` (always `-B`): 485 plugins, **pass 9, blocked 476, rejected 0**, against capabilities scraped from Swift literals (37 operations, 125 host classes, 33 modules; 3419 Python-local classes). Plugins blocked per kind: `OPERATION` 425 (65 distinct), `CLASS` 404 (624 distinct), `DEPENDENCY` 47, `REQUIREMENT` 14, `SDK_MEMBER` 14, `IMPORT` 12, `VERSION_POLICY` 1. Packages: 21 inspectable, 0 pass (`OPERATION` 19, `CLASS` 18, `PACKAGE` 3, `SDK_MEMBER` 3, `DEPENDENCY` 2, `IMPORT` 1).

Pass-count history: 24 (baseline) → 39 (class seam + `java.*` preflight fix) → 56 (threads + javalib) → 20 once honest `OPERATION` blockers were added (44 of the earlier passes called SDK functions whose host operation does not exist) → **9** after the review's false passes were gated. Each drop came from making preflight honest, not from lost functionality. 47 plugins would pass if the Swift host declared every operation of `protocol-telegram.md` (66 before the review fixes); that is a target, not current support.

Xposed: 277 of 485 plugins call `hook_method*` (369 distinct targets, none in more than 7 plugins). Before the review fixes 48 plugins were blocked by that alone with all operations declared; that figure was not re-measured. No hook-target mapping exists; the calls raise `UnsupportedAPI`.

Owner decisions pending (see `OPEN_QUESTIONS.md`): the emulated version policy, `add_autoupdater_task` as a logged no-op, and `Build.VERSION.SDK_INT` = 36.

Swift edits, **never compiled** (`swiftc -frontend -parse` syntax check only; no Swift test covers the new authorize branch):

- `Sources/AyuPluginNativeHost.swift`: `plugin.authorize` rejects version-constrained metadata only when the `version_policy` argument is absent.
- `Sources/AyuPluginNativeHost.swift`: `modules` gained `java.chaquopy`, `_sdk_version`, `elyx`, `elyxcore` and its four submodules.
- `Integration/AyuPluginService.swift`: the blanket `VERSION_POLICY` blocker loop was removed; the blocker now comes from Python preflight.

Must be done on a Mac with full Xcode: build with `Make.py`; run `//submodules/AyuPluginBridge:AyuPluginBridgeTests`; compile-check the Swift edits above; implement the 19 operations of `protocol-telegram.md`, publish per-class members in `runtime.capabilities` so preflight can check members, package import (call `preflight_package_json` / `load_package`, accept `.elyx`/`.eaf`, delete `AyuPluginFiles/plugins/ElyxPlugins/<id>` on removal), view/bitmap adapters and any Xposed target mappings; verify the thread model on device; record install/settings frames per `AGENTS.md`.

Tests, from the repository root (current totals: 606 / 71 / 44, all OK):

```sh
python3 -X utf8 -B -m unittest discover -s submodules/AyuPluginBridge/Tests/Python
python3 -X utf8 -B -m unittest tools.plugin_inspector.tests tools.plugin_inspector.corpus_tests tools.plugin_inspector.audit_tests tools.plugin_inspector.preflight_tests
python3 -X utf8 -B -m unittest submodules.AyuPluginBridge.Build.prepare_test submodules.AyuPluginBridge.Build.verify_ipa_test
```

After any bridge source edit (`Python/**/*.py`, Swift, Objective-C, headers), refresh the catalog hashes last, or `test_catalog_sdk_hashes_match_current_sources` fails: `python3 -B submodules/AyuPluginBridge/Build/audit-plugin-requirements.py --refresh-implementation-hashes --plugin-dir plugins`.

## 2026-11-25 — Plugin system only

Working checkout: `plugins-test`, now the Mac working tree `/Users/toby/work/ayugram-ios`; these changes are still uncommitted there. Parent `ayu/ghost-mode` checkout contains unrelated pre-existing changes; leave them untouched.

Implemented: plugin installation/details/update flow; portable SDK compatibility; source-bounded static inspection; account/generation callback ownership; validated outgoing hook chain; atomic settings replacement/reload; application account/context/value adapter subsets. Reports distinguish declaration inventory from native/runtime implementation.

Outstanding: build the full app with the repository's `Make.py` on macOS, run `//submodules/AyuPluginBridge:AyuPluginBridgeTests`, and record/evaluate installation/settings frames using `AGENTS.md`. Neither the original Windows environment nor this Mac (Command Line Tools only) provides an Xcode/UIKit compiler or iOS simulator. No IPA or device compatibility result exists for these changes.

The full-port objective remains open. Most attachments need additional native controllers, exact reflection/hook targets, menus, TL request/update transport and media/graphics on the Swift side. As of 2026-11-26 (section above) the worker-thread model, the version policy and `.elyx`/`.eaf` loading exist in Python only: threads are unverified on device, the Swift change that defers version policy to Python is not compiled, and the Swift importer still does not accept packages. Do not remove the remaining blockers or label plugins working on static evidence.

Verification commands are listed in the 2026-11-26 section; `.github/workflows/plugin-bridge-checks.yml` runs the same suites except `tools.plugin_inspector.preflight_tests`, which it does not list yet. On Windows use the uv-managed CPython executable with `-X utf8 -B`. The symlink-escape fixture skips only when Windows reports missing symlink privilege; Linux/macOS must execute it. Refresh the catalog implementation hashes only after source edits settle, using the audit script's `--refresh-implementation-hashes --plugin-dir plugins` command; this does not recalculate runtime support.
