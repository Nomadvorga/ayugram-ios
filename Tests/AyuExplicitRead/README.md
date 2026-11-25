# Explicit ghost-read queue checks

The source is in `submodules/TelegramCore/Sources/Network/AyuExplicitRead*.swift`
and `ManagedAyuExplicitReadOperations.swift`. The contract and root integration
handoff are in [`docs/ayu-explicit-read-queue.md`](../../docs/ayu-explicit-read-queue.md).

The 21 Foundation XCTest cases cover monotonic coalescing, capacity without
eviction, bounded ids, an older success/rejection racing a higher maxId,
replacement-intent identity, JSON persistence, flood/backoff deadlines, unlimited
transient retries, exact terminal error policy, persisted/acknowledged errors and
logout's rejection of late callbacks, backwards decoding without invented
confirmations, server-only receipts, stale Cancel, persisted cancellation,
explicit retries respecting flood waits, failure retry bounds, non-retryable
unknown ranges and permanent-error retention beyond the local history limit.

Run that production policy and its actual Swift tests with a Swift host toolchain:

```sh
python3 tools/run_extera_xctests.py --warnings-as-errors \
  submodules/TelegramCore/Sources/Network/AyuExplicitReadQueue.swift \
  submodules/TelegramCore/Tests/AyuExplicitRead/AyuExplicitReadQueueTests.swift
```

The 18 integration cases use the existing StateSyncFixture's real Postbox and
the production runner. They cover transactional upper-bound freezing,
unsupported inputs, no-intent isolation, offline cancellation, coalescing during
an active request, runner restart, persisted flood waits, empty completion,
terminal failure persistence, timeout/backoff, logout cleanup, owner mismatch,
real `channels.readHistory` result/error mapping, the transport's persisted-intent
guard, cancellation of the runner, stale/mismatched-owner controls, explicit
failure retry, read-only preparation/observation, confirmation-bound freezing,
stale failure dialogs and actual database close/reopen with pending/error/receipt
status. The test target also checks Postbox
release during teardown.

They are picked up by the existing TelegramCore test glob; on a configured Mac,
run `Make.py test --target //submodules/TelegramCore:TelegramCoreTests` using the
repository's codesigning/configuration arguments in `CLAUDE.md`. No new target
or dependency is needed.

Cross-platform syntax parsing:

```sh
uv run --with tree-sitter --with tree-sitter-swift python Tests/AyuExplicitRead/verify_swift_syntax.py
git diff --check
```

Implementation-host result: all 14 Swift files parsed and whitespace checks passed.
Swift/Xcode are unavailable on Windows here; neither XCTest suite, Swift
typechecking nor the iOS build has run. Parsing does not establish compilation.
UI error presentation is implemented; root owns localization insertion, an
optional Settings route and CI wiring. No visual verification is claimed.

For root's host CI, use the exact Python command above with `python3`. This suite
has no iOS imports and compiles the production policy beside its tests; no new
BUILD target is required. The syntax/import checks are:

```sh
python3 build-system/Make/PostboxImportCheck.py
uv run --with tree-sitter --with tree-sitter-swift python Tests/AyuExplicitRead/verify_swift_syntax.py
```

Before recording on the Mac, expected frames are: one account-labelled status
page pushed from each caller; accepted requests labelled pending; offline and
retry-delay notices; a confirmed result only after successful server response;
an error row retained until an explicit action; Cancel/Retry alerts above the
same account's page, without clipped text or duplicate page transitions. No
custom animation was introduced; the existing push/alert transition should move
as one and settle without a duplicate overlay.

Record each real caller in light/dark, open/close the action alert, and inspect
labelled frames under AGENTS.md. Also verify offline enqueue → terminate/relaunch
→ observe without a new request → reconnect, cancellation while in flight,
permanent error after relaunch → explicit Retry/Dismiss, a stale dialog after a
higher maxId coalesces, repeated actions on one peer, a changed Feed selection
while its confirmation is open, and logout/account switch while an alert is open.
Use two accounts with the same target peer and check independent queues. Keep a
ghost local-only read control case with no read RPC. Closing the screen must not
cancel accepted work; closing the account runner must leave it for next launch.
