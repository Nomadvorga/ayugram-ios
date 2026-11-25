# Local inline calculator checks

The SwiftPM test target compiles the exact production engine with Foundation and XCTest,
without the iOS app, Telegram presentation strings, a simulator, or codesigning.
Run from the repository root on a macOS host with Xcode's Swift toolchain:

```sh
python3 tools/run_extera_xctests.py \
  submodules/TelegramUI/Sources/ExteraMathEngine.swift \
  submodules/TelegramUI/Sources/ExteraMathUnits.swift \
  submodules/TelegramUI/Sources/ExteraMathTimeZones.swift \
  submodules/TelegramUI/Sources/ExteraMathCurrencyRates.swift \
  Swiftgram/SGSimpleSettings/Sources/AyuSettingsStore.swift \
  Swiftgram/SGSimpleSettings/Sources/ExteraMathSettings.swift \
  Swiftgram/SGMath/Sources/ExteraMathPreferences.swift \
  Tests/ExteraMath/ExteraMathEngineTests.swift \
  Tests/ExteraMath/ExteraMathSettingsTests.swift
```

The runner copies these sources unchanged into a temporary Swift 5.9 package and runs
`swift test` in Swift 5 language mode. SwiftPM discovers every XCTest method and supplies
Xcode's XCTest paths; the standalone `XCTMain` entry point is excluded in package builds
because macOS XCTest does not provide it. Build or test failures fail the runner, and
the temporary package is removed when it exits.

The tests cover precedence, relative percentages, angle units, functions, formatting,
base conversion and exact-integer limits, dimension-aware units, temperature offsets,
duration breakdown, real-response currency parsing/cross rates/expiry, pending results,
time-zone DST/offsets/day shifts, independent feature switches, parser limits, and
UTF-16 suggestion positions. URLProtocol tests exercise the real request's endpoint,
response delivery, transport cancellation, and suppressed callbacks. They were added
on Windows where Swift is unavailable and have not been executed there.

The settings tests also pin old `inlineImperial` migration (including explicit
false), automatic metric/imperial resolution, legacy setter compatibility,
persisted new/old keys, independent runtime feature flags, and help previews of
disabled features. They provide only a UUID test app-group identifier; production
store/settings/engine sources are unchanged. The preferences extension conditionally
imports SGSimpleSettings, so this direct-source host target needs neither SGMath
nor SGSimpleSettings as an installed module. Engine-only tests can still run with
the original four engine files and `ExteraMathEngineTests.swift` alone.

The application compiles those same four engine files once in `//Swiftgram/SGMath`;
TelegramUI and SGSettingsUI import that static library. The source filegroup does
not introduce a dependency from SGMath back to TelegramUI. No UI/presentation type
is imported into SGMath. It is linked inside the existing TelegramUIFramework,
so it adds no external framework client or provided framework to its release
export rules.

For the standalone settings screen, verify these paths on an iOS host:

- Toggle the master off/on: its subordinate preferences retain their values and
  help remains expandable. Turn each feature off: its help shows the off badge.
- Expand arithmetic, percentages, currencies, units and zones at the same time;
  collapse one without closing the others. Tap an example: clipboard contains the
  expression including `=`, with no result or stale rate value.
- Change angles, grouping, measurement system and currency: examples recompute
  using the composer engine. Currency results use dated real rates; unavailable
  rates and unsupported account-specific Stars prices never show invented values.
- Search the currency list by code/localized name. Confirm selection, Back,
  keyboard dismissal, light/dark themes and large Dynamic Type.

Expected frames before recording: rounded cards and their text stay inside the
scroll viewport; expansion immediately lays out the inserted examples and moves
later sections together with no clipping, overlay or independent spring. This
implementation adds no custom animation. Record expanding/collapsing each group,
master off/on, theme changes and scrolling as required by AGENTS.md. iOS build,
XCTest execution and recorded-frame verification are pending on this Windows host.

On an iOS host, also build the full app and verify these composer interactions:

- Type `(120 + 80) / 4 =`: one result row displays `= 50` above the input.
- Tap its value: only ` 50` is inserted after `=`; rich blocks elsewhere stay intact.
- Tap copy: the clipboard receives only `50` and VoiceOver announces the copy.
- Move the caret, select text, type an invalid expression, or disable either inline
  switch: the row disappears; an old row cannot insert into changed input.
- Try light/dark mode, large text, narrow layouts, multiline rich drafts, and emoji
  before the expression on a previous line.
- Degrees/radians changes alter `sin(30) =`; digit grouping alters `1000+2000 =`.

Expected visual behavior: the row stays wholly above the composer, its value and copy
button move together with the parent input-context surface, neither overlaps the input,
and no new independent animation is introduced. Record the app's appearance and
disappearance paths and inspect timestamped frames as required by the root AGENTS.md.
No visual or animation verification has been performed on Windows.

The Windows syntax check parses all production math files and tests with tree-sitter:

```powershell
C:\Users\PC\.local\bin\uv.exe run --with tree-sitter --with tree-sitter-swift python Tests/ExteraMath/verify_swift_syntax.py
```

This is syntax validation only; it does not execute XCTest or check Swift types.
See `docs/extera-inline-conversions.md` for integration points and remaining parity gaps.

The Python reference check reads Android sources with `git show` (works with its
sparse checkout), extracts the actual Swift catalog, and compares all 39 unit
definitions plus all 251 built-in time-zone aliases. It also checks 11 numerical
conversion regressions using the production scales and offsets:

```powershell
C:\Users\PC\.local\bin\python3.12.exe Tests/ExteraMath/verify_reference_parity.py
```

This reference check passed on Windows. It verifies production conversion data;
the Swift parser, formatter, URLSession and XCTest behaviors still need execution
on the macOS/iOS host.
