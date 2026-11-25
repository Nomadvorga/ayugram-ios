# Handoff

## 2026-11-25 — Plugin system only

Working checkout: `plugins-test`. Changes are local and uncommitted. Parent `ayu/ghost-mode` checkout contains unrelated pre-existing changes; leave them untouched.

Implemented: plugin installation/details/update flow; portable SDK compatibility; source-bounded static inspection; account/generation callback ownership; validated outgoing hook chain; atomic settings replacement/reload; application account/context/value adapter subsets. Reports distinguish declaration inventory from native/runtime implementation.

Outstanding: build the full app with the repository's `Make.py` on macOS, run `//submodules/AyuPluginBridge:AyuPluginBridgeTests`, and record/evaluate installation/settings frames using `AGENTS.md`. Windows provides no Xcode/UIKit compiler or iOS simulator. No IPA or device compatibility result exists for these changes.

The full-port objective remains open. Most attachments need additional native controllers, exact reflection/hook targets, menus, TL request/update transport, media/graphics and a supported worker-thread model. Package source/binary inventory does not implement `.elyx`/`.eaf` installation. Version constraints remain blocked without a real application/SDK policy; 486 standalone sources declare nonempty/computed constraints. Do not remove these blockers or label plugins working on static evidence.

Final verification commands are in `.github/workflows/plugin-bridge-checks.yml`. On Windows use the uv-managed CPython executable with `-X utf8 -B`. The symlink-escape fixture skips only when Windows reports missing symlink privilege; Linux/macOS must execute it. Refresh the catalog implementation hashes only after source edits settle, using the audit script's `--refresh-implementation-hashes --plugin-dir plugins` command; this does not recalculate runtime support.
