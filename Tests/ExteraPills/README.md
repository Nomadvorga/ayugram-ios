# Pill Stack and HTTP pill host checks

This executable compiles the actual production configuration, JSON-path, formatting, document
validation, persistence, Stack ordering/selection, provider generation, request lease policy, rate
conversion, and EN/RU helper code. Only `AyuSettingsStore` is replaced by an adapter to a
random, isolated `UserDefaults` suite. It never accesses the app group, Telegram accounts, or network.
The suite is removed when the test executable exits normally, including a thrown test failure.

Run from the repository root on a host with Swift and Foundation (macOS recommended):

```sh
OUT="$(mktemp -d)"
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  Swiftgram/SGSimpleSettings/Sources/ExteraPillSettings.swift \
  Swiftgram/SGSimpleSettings/Sources/ExteraPillStrings.swift \
  Swiftgram/SGSimpleSettings/Sources/ExteraPillStackSettings.swift \
  Tests/ExteraPills/ExteraPillHostTests.swift \
  -o "$OUT/ExteraPillHostTests"
"$OUT/ExteraPillHostTests"
```

Windows PowerShell, if a Swift toolchain is installed:

```powershell
$pillTestBinary = Join-Path $env:TEMP "ExteraPillHostTests-$([guid]::NewGuid()).exe"
swiftc -swift-version 5 -warnings-as-errors -parse-as-library `
  Swiftgram/SGSimpleSettings/Sources/ExteraPillSettings.swift `
  Swiftgram/SGSimpleSettings/Sources/ExteraPillStrings.swift `
  Swiftgram/SGSimpleSettings/Sources/ExteraPillStackSettings.swift `
  Tests/ExteraPills/ExteraPillHostTests.swift -o $pillTestBinary
if ($LASTEXITCODE -eq 0) { & $pillTestBinary }
```

Success prints `PASS: ... assertions`; failure throws a descriptive error and exits nonzero. No Bazel
or iOS SDK is needed for this harness. The implementation session had no Swift compiler in Windows
or its Ubuntu WSL distribution, so the harness was syntax-checked but **has not been executed**.

Coverage includes quoted/escaped keys, root values and arrays, negative indices, Int boundary values,
path length/depth limits, malformed paths, null/missing values, scalar formatting, booleans versus
numbers, percent fractions, locale-specific decimals, byte conversion bounds, non-finite numbers,
Unicode output limits, URL validation, refresh/precision limits, ordered enabled persistence,
transactional invalid updates, import/export round-trip, file/version/count validation, and language
fallbacks. Stack coverage includes literal old-v1 migration, persisted order/visibility/selection,
disabled/deleted/reimported HTTP IDs, malformed/stale layout normalization, missing layout fields,
same/cross-section moves, both wrap boundaries and finite boundaries, empty/single stacks,
account isolation, bot-bound weather grants, URL-bound custom grants, revocation, currency isolation,
A → B → A and cancellation completion rejection, multiple search/dashboard request scopes,
replacement endpoint rejection, valid TON/BTC/USD conversions, malformed/non-finite/oversized rates.
The JSON fixtures are literal strings in the harness to avoid a working-directory dependency.
The gates and lease policy are used directly by the production provider and scheduler. This does
not execute UIKit, Telegram providers, timers, URLSession transport, or their integration.

Syntax-only fallback (does not typecheck Swift APIs or replace the executable above):

```sh
uv run --with tree-sitter --with tree-sitter-swift python Tests/ExteraPills/verify_swift_syntax.py
```

Stack UI and integration acceptance is specified in
[`docs/extera-pill-stack-implementation.md`](../../docs/extera-pill-stack-implementation.md),
including expected frames **before** recording and output paths. Record both Stack entry points:
the existing settings wrapper and baseline Chats-tab menu entry now open Stack; its HTTP row opens
the original dashboard. The settings entry supplies endpoint editing/import/export callbacks;
the Chats entry remains display-only for custom endpoint configuration.

After the full iOS build, verify the UI on a permitted simulator and record the paths required by root
`AGENTS.md`. Expected behavior before recording: dashboard pushes/pops with the native navigation
transition; cells and their content remain together with no clipping; value changes resize rows
without a spring; opening/dismissing the editor uses the standard sheet transition. Check English
and Russian, light/dark themes, larger text, empty/populated lists, reorder/delete/toggle, valid and
invalid editor saves, import cancel/replace, and export share/cancel. Open HTTP through the Stack
row for the corresponding display-only/settings entry.
For network checks use a controllable JSON endpoint: test success, malformed JSON, missing path,
non-2xx, a chunked body exceeding 512 KB, slow responses, same-origin redirect, cross-origin redirect,
backgrounding and navigation away during a request, then returning. Confirm no more than three
requests run at once and that edited/disabled/deleted pills reject obsolete completions.
