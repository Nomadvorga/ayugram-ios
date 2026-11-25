# exteraGram settings backup and validation

Push `exteraBackupController(context: context)` from SGSettingsUI. Existing BUILD source globs and dependencies cover both backup files. The versioned iOS JSON format has `format: "exteragram-ios-settings"` and `version: 1`; it does not import Android raw-preference archives.

The explicit allowlist covers exteraGram preferences and their retained Swiftgram counterparts, plus the Contacts/Calls visibility and folders-at-bottom values exposed in the exteraGram UI. Account/auth data, messages, caches, unrelated Ayu settings and all plugin preferences are excluded. The two extera reaction controls intentionally alias Ayu `hideChannelReactions`/`hideGroupReactions` storage and are within scope.

The AI allowlist contains five strict booleans: `extera.ai.showEditor`, `extera.ai.showSummaries`, `extera.ai.showInstantViewSummaries`, and `extera.ai.insertAsQuote` default to `true`; `extera.ai.showResponseOnly` defaults to `false`. Temperature uses integer `extera.ai.temperatureTenths` in `0...20` with default `10`. Summary replacement uses `extera.ai.replaceTelegramSummaries` with `automatic` / `enabled` / `disabled`; reset restores `automatic` (`nil`) independently of the current account's premium status. All present AI preferences serialize together before other writes. Configuration blobs, services/endpoints/models, roles/prompts, API keys and conversation history remain excluded. Reset preserves those private fields and the separate text-processing routing/history settings.

`validate(data:)` validates the entire document before any settings singleton is initialized or any preference is written. It rejects unknown keys, duplicate JSON keys (including escaped duplicates), invalid UTF-8/JSON grammar, nesting beyond 16 containers, incorrect types, invalid ranges/enum values and files larger than 256 KiB. Browser exceptions must be unique normalized exact hosts. Export applies the same validation and file-size bound.

`apply(_:)` and `reset()` are throwing APIs and run on the main thread. Both use `AyuSettingsStore.performBatchUpdates`, write through the original preference setters, and call `synchronizeShared()` once on success before the batch ends. Present AI flags are persisted together in one configuration update before any other preference write. A configuration validation/encoding failure propagates to the UI and leaves local preferences and shared transactions unapplied; it emits no AI success notification. The store still emits its usual final batch notification, including for an empty/failed batch or one that changes only Swiftgram settings. An import without AI flags does not load or rewrite AI configuration. Telegram shared-data/network updates run separately through the existing transactions, only after local application succeeds. A partial import changes the download transport only if it includes `simple.downloadSpeedBoost`. Shared transactions continue to completion after the backup screen is popped.

`ExteraAISettings.configuration` caches its decoded value, including the default for missing/malformed JSON, under the existing recursive AI lock. Repeated layout reads do not reload/decode the services and roles. Configuration mutations keep the existing store-batch → AI-lock nesting and publish the new cache only after validation and serialization succeed, before the nonthrowing store write so synchronous readers see the new value. AI notifications remain outside the mutation lock. All configuration writes must continue to use `ExteraAISettings.update`; direct writes to its raw store key would bypass this cache.

The store tracks keys explicitly written during the process so a registered default cannot suppress a migration-sensitive first write. Its recursive lock serializes cache/defaults writes and permits synchronous Foundation callbacks to read the updated cache. The nonthrowing batch closure executes without a new lock acquisition held across it. Batching coalesces notifications; it does not make all settings across UserDefaults, caches and Telegram transactions one atomic snapshot. Overlapping batches on different threads are coalesced until the last batch ends. Foundation's own defaults notifications and browser-specific notifications are separate from the custom Ayu notification.

Store audit edge case: a setter called reentrantly by a synchronous Foundation callback can post its custom notification while an outer setter still owns a recursive lock level. Backup batching suppresses setter notifications throughout its local updates. A general guarantee that observers never run under any recursive lock level would need write-depth tracking; this remains a root-owned follow-up and is not claimed by these tests.

## Checks available in this repository

Run from the repository root on Windows:

```powershell
py docs/validation/check_extera_backup.py
py docs/validation/run_extera_backup_validation.py --emit-only
py docs/validation/run_ayu_settings_store_validation.py --emit-only
py docs/validation/run_extera_ai_backup_validation.py --emit-only
```

The first command performs structural source checks against the actual allowlist, current settings declarations, native file-flow safeguards, partial-import behavior and batching integration. These checks do not execute Swift.

On a Mac with a Swift toolchain:

```sh
python3 docs/validation/run_extera_backup_validation.py
python3 docs/validation/run_ayu_settings_store_validation.py
python3 docs/validation/run_extera_ai_backup_validation.py
```

The backup driver extracts the production Swift grammar/type-rule declarations verbatim, supplies independently authored and generated fixtures, and compiles/runs a Foundation-only executable. It does not reimplement the validator in Python. The store driver compiles the actual production `AyuSettingsStore.swift` into a host harness with a unique temporary defaults suite. Generated Swift and executables go into a temporary directory. `--emit-only` prepares these harnesses without claiming runtime success. Both drivers return a failure status when invoked to run without `swiftc`.

The targeted AI driver extracts the production AI model/cache/update/history code and backup validation/export/apply/reset code. It omits Keychain methods, opens the AI initializer/singleton for isolated fixtures, substitutes an instrumented store, and retains the three production AI allowlist entries alongside one ordinary bool fixture. It checks legacy/default caching, repeated reads, failed-update cache preservation, strict boolean validation, private-key rejection, partial imports, one AI write for multiple flags, reset preserving private AI configuration/history, failures before ordinary writes/synchronization, and AI observers reading from another thread outside the mutation lock. The credential sentinel check establishes that backup never touches the sentinel; it does not execute real Keychain operations. This harness also requires `swiftc`; emission and syntax parsing do not establish runtime success.

**Validation status:** all 14 backup source checks pass after math, chat-appearance and media integration. The AI harness includes strict generation booleans, temperature limits, three-state summary-policy round-trips, mixed scalar/flag single writes, and preservation of private fields. Swift harness execution, the full iOS build, and simulator/UI frame evaluation remain pending for the current tree.

## Remaining runtime and UI cases

1. Export known values on main, validate the bytes, mutate settings, then apply and verify every allowlisted setting round-trips. Include cached Ayu getters, Swiftgram property wrappers, shared photo-quality mirrors, browser hosts, and the three Telegram shared preferences.
2. Snapshot both defaults domains and notification counts around every malformed import. `validate(data:)` must not initialize settings singletons, write defaults or post notifications. A valid local value followed by one invalid shared field must produce zero writes.
3. Starting from an export, reject wrong format, unknown fields, missing required fields, unsupported/non-integer versions, nulls, numeric/string booleans, fractional/overflow integers, out-of-range percentages/avatar corners, invalid enum strings, double-tap ID 7, seek duration 20, camera 2 and plugin preference keys.
4. Reject duplicate keys at all levels, escaped duplicates such as `"version"`/`"\u0076ersion"`, truncation, trailing garbage/commas, malformed escapes, invalid UTF-8, excessive nesting and oversized files. Preserve valid UTF-8 album names and escaped string contents.
5. Reject control characters, leading/trailing whitespace, overlong album names/locales, album path separators and invalid locale characters. Browser arrays accept normalized exact hosts, including 513+ entries if the document remains within 256 KiB; reject duplicate hosts, URLs, wildcards, credentials, ports, paths, queries, uppercase/non-normalized hosts, invalid labels and non-string entries. Oversized export must fail rather than produce an unimportable file.
6. A partial import updates only present preferences. An absent shared object leaves Contacts/Calls/folders unchanged; a present shared object requires exactly all three boolean fields. An import without `simple.downloadSpeedBoost` must leave the transport flag unchanged. A local-only import must still finish and display success (`combineLatest([])` does not complete in this SwiftSignalKit version).
7. Seed sentinel account/auth data, chat content, `lastAccountFolders`, `outgoingLanguageTranslation`, `regDateCache`, unrelated Ayu settings and plugin preferences. Export must omit them; import/reset must preserve them. Account for the two intentionally shared reaction preferences above.
8. Import/reset cancellation must leave preferences unchanged. Confirmed reset must restore the allowlist and Telegram shared defaults. Count exactly one custom Ayu notification after the final local setter and shared-defaults synchronization. A Swiftgram-only import must also emit one. Browser-specific/Foundation notifications are outside that count.
9. Exercise the store's first registered-default write, repeated equal writes, nested/empty/external-only batches, concurrent writers, observers that read/write preferences, and synchronous Foundation/KVO readers. Final cached and persisted values must agree. A worker write inside a batch must complete while the outer closure is active, proving the closure is not run under the store lock.
10. On iPhone/iPad, exercise share completion/cancellation and import from local/iCloud files. Verify bounded stream reads, recoverable I/O errors, security-scope cleanup, picker dismissal before confirmation, useful error alerts, and iPad popover placement. Export files must be removed after completion/cancellation or activity-controller deallocation. Popping the backup screen after confirmation must not cancel transactions or show an alert on another screen.
11. Before recording UI flows, expect normal list navigation, one native picker/share sheet at a time, import/reset confirmation before writes, and a result alert after transaction completion. Record light/dark, iPhone/iPad, cancel/confirm and malformed imports under AGENTS.md. Inspect labelled frame sheets before claiming visual verification.
