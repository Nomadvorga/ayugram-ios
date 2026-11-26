# Applied next-wave validation — 2026-11-26

The user-authorized patch is applied to the working tree and its renderer, map
selection, cache-accounting and Postbox-import details have been refined in place.
No commit or push was made. No unrelated/root-owned edits were reverted or staged.

| Check | Result |
| --- | --- |
| `py -3 build-system/Make/PostboxImportCheck.py` | PASS; no allowlist exception added. |
| `wsl -d Ubuntu -- python3 build-system/Make/PostboxImportCheck.py` | PASS. |
| `uv run --with tree-sitter --with tree-sitter-swift python Tests/ExteraPills/verify_swift_syntax.py` | PASS for all files listed by the checker; it now also includes the two edited TelegramCore resource files. Syntax only, not typecheck. |
| Scoped `git diff --check` (Pill/UI/Core/parity/test files) | PASS. |
| Postbox-import scan of `ExteraPillBuiltinProvider.swift` and `ExteraPillStorageUsage.swift` | PASS; neither imports Postbox. Storage totals now flow through `EngineCacheUsageSummary`, and cache UI aggregates typed summary values. |
| Root-owned `.github/workflows/extera-host-checks.yml` source list | Updated to compile `ExteraPillParity.swift` with the production Pill host executable. |
| `ParityHostTests.swift` production-model executable via Ubuntu WSL Swift 6.1.3 | PASS: `PASS: next-wave production model fixtures`. |
| `ExteraPillHostTests.swift` production-model executable via Ubuntu WSL Swift 6.1.3 | PASS: `PASS: 224 production pill path/format/validation/import/persistence/localization/stack/provider assertions`. |
| iOS debug app build / Xcode 27 typecheck | NOT RUN; host is Windows/WSL with no Apple SDK or Xcode. |
| Simulator visual recordings/frame evaluation | NOT RUN; no simulator/XcodeBuildMCP on this host. |

Implementation refinements:

- Pan neighbor content now has a data-only view with the same label/Entry Time eye/
  Storage Usage ring composition. It uses remembered output or a title fallback
  and does not start/lease a provider before selection commits.
- Map search now presents selectable results and pins the chosen result's own
  coordinate. iOS 26+ uses `MKMapItem.location`; the older `placemark` access is
  isolated behind an availability-guarded legacy helper. Deprecated API diagnostics
  still require the Xcode 27 warnings-as-errors build.
- TelegramCore exposes a narrow `EngineCacheUsageSummary` with native
  resource/cache/temp byte counts. Resource bytes reuse the collector's unique
  resource-ID total; the UI sums account-scoped resource/cache bytes and uses
  the largest temporary snapshot once because the iOS temporary directory is
  shared. Immutable DB/log sizes and backup data remain excluded. Host fixtures
  cover aggregation, overlapping temp snapshots and saturation policy.
- Rate conversion retains APK semantics: reciprocal currency rates at scale 16,
  cross-rate division at scale 12, both HALF_UP. The Foundation host fixtures pin
  TON/USD and BTC/RUB values.

These results are source checks only. They do not establish API type correctness,
linking, successful app build, or visual acceptance. Root owns the integrated CI/
Mac build and final coherent commit.
