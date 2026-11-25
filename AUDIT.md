# Plugin audit

## 2026-11-25

- B-001 — Code fix pending native verification: `.plugin` opened directly into installation/toasts. It now opens a preview/detail window and persists only after explicit install/update.
- B-002 — Code fix pending native verification: updates required deleting the old plugin/settings. Disabled-plugin replacement now preserves the owner settings and checks the preview source hash.
- B-003 — Code fix pending native verification: send hooks continued after `MODIFY_FINAL` and accepted malformed replacement dictionaries. A typed chain preserves account/destination and previous valid text; generation checks run across callback suspension.
- B-004 — Portable tests cover settings signatures and atomic namespace replacement. Native atomicity/reload tests are added but must run with Xcode.
- B-005 — Portable tests cover nested SDK import inventories, callback account/lifetime, Android constructor signatures and UTF-16 formatting. These tests do not establish native API availability.
- B-006 — Unresolved acceptance: no native compilation, device startup, recorded-frame comparison or working-plugin percentage for the supplied corpus. The full port remains incomplete.
