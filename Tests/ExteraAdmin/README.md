# Quick-admin checks

Current port: `ExteraAdminHeaderPolicyTests.swift` adds 10 tests for Android's four chat-header destinations, routing and live-role revalidation policy. Together with the 7 settings tests this is the mandatory 17-test wave. Author moderation is deferred; its 14 tests remain available but do not count as the Android port.

`ExteraAdminShortcutPolicyTests.swift` contains 14 tests for the policy actually consumed by the author menu. They cover separate admin rights, owner/self/administrator/removed/unknown target protection, ordinary viewers, disabled settings, legacy-group limitations, and invalidating an offered action after rights/target changes.

`ExteraAdminSettingsTests.swift` contains 7 persistence tests: Android's `true` default, no eager defaults writes, false/true round trips, strict stored booleans, reset, notifications, reentrant reads and concurrent writes. Every test uses an isolated defaults suite.

Run on a Swift host (macOS recommended):

```sh
python3 tools/run_extera_xctests.py --warnings-as-errors \
  AyuGram/SGSimpleSettings/Sources/ExteraAdminSettings.swift \
  AyuGram/SGSimpleSettings/Sources/ExteraAdminHeaderPolicy.swift \
  Tests/ExteraAdmin/ExteraAdminSettingsTests.swift \
  Tests/ExteraAdmin/ExteraAdminHeaderPolicyTests.swift
```

The same command accepts `--sanitize thread`. The tests compile the actual production sources; only the app-group identifier and notification name receive host-only bindings. Do not combine this direct-source invocation with navigation's app-binding stubs in the same target.

Syntax check on the current Windows host:

```powershell
C:\Users\PC\.local\bin\uv.exe run --with tree-sitter --with tree-sitter-swift python Tests/ExteraAdmin/verify_swift_syntax.py
```

To run all 31 tests, add `ExteraAdminShortcutPolicy.swift` and `ExteraAdminShortcutPolicyTests.swift` to the source list above. XCTest cannot execute on this host: the runner reports `swift is unavailable`. Parsing is not a Swift typecheck or an executed test result.

Root applied **`docs/integration/extera-admin-header-menu.patch`**, making the four header routes reachable, and added the mandatory 17-test command to CI. The deferred `extera-admin-author-menu.patch` remains unapplied. See `docs/extera-admin-shortcuts.md` for exact routes, host hooks, role gates and expected recordings. The mandatory patch touches only ChatController header Info/More and the forum side-list More host.
