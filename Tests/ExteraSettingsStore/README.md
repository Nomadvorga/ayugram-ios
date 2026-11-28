# UserDefaults wrapper concurrency checks

These host XCTest tests compile the exact production `UserDefaultsWrapper.swift` and
`RWLock.swift` with Foundation and XCTest. No app, simulator, settings singleton,
codesigning, or Bazel dependency changes are needed.

Run from the repository root on macOS with Xcode's Swift toolchain:

```sh
OUT="$(mktemp -d)"
xcrun swiftc -parse-as-library -warnings-as-errors -g -sanitize=thread \
  AyuGram/SGSimpleSettings/Sources/RWLock.swift \
  AyuGram/SGSimpleSettings/Sources/UserDefaultsWrapper.swift \
  Tests/ExteraSettingsStore/ExteraSettingsStoreTests.swift \
  -o "$OUT/ExteraSettingsStoreTests"
TSAN_OPTIONS=halt_on_error=1 "$OUT/ExteraSettingsStoreTests"
```

The tests use a fresh UUID-named UserDefaults suite per test and remove only that
suite's persistent domain afterward. They never touch standard or app-group
preferences. Thread Sanitizer is enabled to detect cache/collection accesses
that happen to return the correct value while still racing.

Two controlled interleaving tests pause a defaults read or write and let a
competing operation run. Their final assertions compare cache and persisted
values after all operations finish, without a final serial setter masking an
ordering bug. A bounded 100 ms wait gives the original implementation an
opportunity to finish the competing write while the fixed implementation blocks
it on its cache lock; no assertion depends on that timing result.

Additional stress coverage exercises scalar/string readers and writers, first
concurrent dictionary reads, atomic dictionary mutations, absent dictionaries,
repeated drop, restoration of registered defaults, and the existing lazy read for
non-thread-safe dictionaries. Existing supported scalar conversions are also
checked; unsupported types and incompatible stored dictionary types retain
their original failure behavior.

A synchronous defaults callback reads and sets the same preference again,
checking that notification reentry neither deadlocks nor lets the outer setter
overwrite the nested setter. A second test observes Foundation's actual
`UserDefaults.didChangeNotification` with `queue: nil` and checks reentrant reads
when the host emits it synchronously. Some hosts defer or omit notifications for
isolated suites, so the controlled callback supplies unconditional coverage.

A further controlled callback dispatches its read to another queue and waits for
acknowledgement before returning from `UserDefaults.set`, reproducing the
wait-for relationship of MediaPicker's `queue: .main` defaults observer. Its wait
is bounded so a cache-lock regression fails instead of hanging the main test
thread. Getters use only the cache lock; setters hold a separate recursive write
lock and release the cache lock before calling Foundation. Same-thread nested
setters are supported. An observer synchronously dispatched to another queue
must not write the same preference: cross-queue nested writes still wait for the
outer serialized write. The reviewed MediaPicker observer only reads settings.

Added on Windows, where Swift and macOS XCTest are unavailable. These tests have
not been compiled or run here.
