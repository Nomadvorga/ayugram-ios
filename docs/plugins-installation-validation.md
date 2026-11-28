# Plugin installation acceptance

The native installation flow is implemented in
`submodules/AyuPluginBridge/Integration/AyuPluginDetailViewController.swift`.
Chat attachments and the manager document picker both open it. Opening inspects
metadata; installation saves disabled code; enabling remains a separate explicit
trust action. Update requires an idle, disabled installed plugin, preserves its
preferences, and verifies that its bytes match the preview SHA-256.

Source attachments have a 4 MiB (4,194,304-byte) limit, shared with the service
through `AyuPluginService.maximumSourceBytes`. Staging reads at most that limit
plus one byte so it can reject oversized input before saving a preview copy.
The bridge's JSON wire limit remains 1 MiB; the larger quota applies only to
source loading and inspection. Include a valid UTF-8 source above 1 MiB, a source
at the 4 MiB boundary, and one byte above it in native acceptance checks. Only
the oversized source should fail staging; preview must never execute any source.

## Current verification status

Windows source checks cannot compile UIKit or show an iOS simulator. No recorded
frames or visual acceptance result are available from this environment. The
Python wiring tests read Swift sources only; they never import or execute a
`.plugin` attachment and do not establish runtime compatibility.

Run the focused source guards from the repository root:

```sh
python3 -m unittest discover -s submodules/AyuPluginBridge/Tests/Python -p test_installation_wiring.py -v
```

On macOS, build the full app with the root `CLAUDE.md` command and run the existing
`//submodules/AyuPluginBridge:AyuPluginBridgeTests` target using `Make.py test`.
Follow the repository's simulator installation restrictions and use XcodeBuildMCP
for interaction. Record with `simctl io recordVideo`, then generate labelled frame
sheets with `tools/animation_sheet.py`, as required by `AGENTS.md`.

## Expected frames and behavior before recording

Use light and dark themes, default and accessibility text sizes, and both short
and long names/descriptions/requirements. Exercise an ordinary Python plugin and
a source-verified native adapter. Metadata without optional fields must remain
readable and must not show placeholder author/description rows.

| Recording | Expected behavior and frame acceptance |
| --- | --- |
| Tap a downloaded `.plugin` attachment; close and reopen | One native sheet enters from below. Its bar and contents move together with the system sheet transition and settle without clipping, duplicate bars, color flashes, or a detached header. Name/version/author appear in the header; Install appears directly beneath it. Closing returns to the same chat without importing or enabling. |
| Tap an attachment that needs downloading | The sheet opens immediately with a loading row and spinner. Metadata appears only after complete bytes arrive. Download failure shows an inline error and a usable close action. Dismiss during download and verify no late sheet or alert appears. |
| Import through Settings → Plugins | Selecting one document opens the same detail screen after the picker dismisses. There is no install or enable before the user chooses Install. Back/Close returns to the manager without overlapping navigation bars. |
| Install valid code | One tap starts the save; actions and dismissal are disabled during the operation. Completion shows installed/disabled state, then an explicit Enable action. There is no transient enabled state. |
| Inspect unsupported requirements | Exact declared requirement rows and compatibility blockers wrap at readable width. Blockers remain visible after installation and prevent enabling. Long rows must not truncate or overlap the accessory/icon. |
| Replace installed disabled code | The screen shows both versions and Update/Reinstall. Cancel changes nothing. Confirm preserves settings and leaves the replacement disabled. A changed staged source is rejected with an inline error. |
| Open replacement while installed code is enabled or busy | Update/Reinstall is disabled. Disable is available for enabled code; after it completes, replacement becomes available. No automatic disable or enable occurs. |
| Enable; open settings; return | Cancel trust confirmation leaves the plugin disabled. Confirm updates status. Settings pushes once, controls remain legible, and Back returns to current details. At rest, no duplicate navigation bar or clipped first row is visible. |
| Reopen from installed manager list; restart app | Persisted author, description and declared requirements remain visible. After restart, the plugin is disabled and requires explicit enable again. |
| Delete or fail an operation | Delete requires confirmation. Successful deletion returns to the manager or restores the attachment's Install action. Failures are shown near the top without exposing source, traceback, or preference values. |

Use the system transition's observed duration as the baseline; the implementation
adds no custom spring or separate content animation. Judge the recorded frames
for content moving together and settling, rather than assuming a fixed duration.
Check the whole sheet and a crop around its header/install rows. For each flagged
jump or gap, inspect neighboring frames. Record the frame indices and timestamps
of any defect, or explicitly state which recordings passed; a build alone does
not satisfy this acceptance plan.
