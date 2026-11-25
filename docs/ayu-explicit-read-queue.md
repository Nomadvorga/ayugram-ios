# Durable explicit ghost reads

`ayuReadHistoryOnServer(account:peerId:maxId:completion:)` now commits an explicit
read intent to that account's Postbox before a managed runner sends a request.
The context-menu Read Message action, Extera double-tap `.read`, confirmed Feed
Read All and the existing `markReadAfterAction` gate all use this entry point.
Their existing calls remain source compatible. Ordinary ghost reads still use
the existing local read-state path and cannot create an explicit intent.

## Storage and delivery

`OperationLogTags.AyuExplicitRead` reserves tag **28**. Its single merged row uses
`PeerId(0)` as an outbox key inside the account's database; the actual recipients
are packed peer ids inside `AyuExplicitReadQueue`. The row also records the
authorized owner id. `AyuExplicitReadOperation` is registered with the other
Postbox encodables in `AccountManager.swift`.

There are at most 1,024 unresolved slots (pending intents plus permanent server
errors). Repeated intents coalesce transactionally
to the highest maxId for the same peer. A full queue rejects a new peer and keeps
every already accepted intent. It still accepts a higher maxId for a pending
peer. No accepted intent expires or is evicted because of age, retry count or
capacity. Requests in flight carry the intent's identity and sent maxId; an
older completion cannot consume a replacement intent or a higher pending maxId.
Persisted revisions prevent an older transaction result from replacing a newer
operation-log view snapshot.

Read-all callers still pass their existing sentinel, but enqueue resolves it to
the highest finite cloud id in the cached history/read state, in the same
transaction. It ignores artificial non-member read-state sentinels. A replay
after offline/relaunch therefore does not mark later arrivals read. When no
finite upper bound is known, enqueue returns `.invalidInput` and records
`LOCAL_READ_BOUND_UNAVAILABLE`. This deliberately makes the cached known top
the authorization boundary; it does not fetch an unknown later server top.
An explicit message id remains bounded to the selected message.

Each main-app `Account` owns one runner subscription in its existing managed
operations disposable. The runner watches only its account's row, logout and
connection status, sends at most four peers concurrently and does not capture
`Account` or a UI controller. Extensions/cleanup accounts do not run it. Offline
cancels active requests without removing persisted intents; reconnect resumes
them while honoring existing deadlines. Disposing the account/runner leaves
work for the next launch. Delivery is at least once: a process can die after the
server accepts a read but before the success transaction commits. Repeating the
same bounded history read is idempotent.

Failures/timeouts use persisted per-peer exponential delays of 1, 2, 4, …, 300
seconds with no retry-count limit. Each attempt has a 45-second timeout.
`FLOOD_WAIT_n` and `FLOOD_PREMIUM_WAIT_n` persist at least the server's wait;
enqueue/coalescing cannot reset that deadline. Wall-clock deadlines survive
process restarts. Missing local peers/access hashes, a false channel result,
empty transport completion, unknown errors and 5xx outcomes all remain pending.

Only these exact constants with RPC code 400/403 terminate an intent:
`PEER_ID_INVALID`, `CHAT_ID_INVALID`, `CHANNEL_INVALID`, `CHANNEL_PRIVATE`,
`MSG_ID_INVALID`, `INPUT_USER_DEACTIVATED`. Authentication/logout decisions stay
with the existing Network/Account implementation. Neither engine nor telemetry
is changed. Successful `messages.readHistory` still forwards its pts update to
the state manager.

Logout cancels active work and closes/clears the persisted row, rejecting later
enqueue/completion callbacks. Account-record removal and `.loggedOut` attributes
are observed as well as the account's remote-logout signal. The existing cleanup
path closes the row before its `auth.logOut` request, covering an inactive account
without a main-app runner. This adds no new logout verdict or auth-key policy.

## UI integration and frozen boundary

The queue and real UI callers are implemented and frozen for root's checkpoint.
The exact source/artifact inventory is
[`changed-manifest.json`](../Tests/AyuExplicitRead/changed-manifest.json).
Core, registration, lifecycle and all three new Network files must land together.
The existing TelegramCore, SGSettingsUI and TelegramUI source globs/dependencies
cover the code. No BUILD/dependency change is needed.

`completion` runs on the main queue **after enqueue commits**. `.queued` and
`.coalesced` mean accepted for eventual delivery, not server success. `.queueFull`,
`.invalidInput` and `.loggedOut` reject the action. Accepted intents remain
authorized after later ghost-setting changes; the existing `markReadAfterAction`
setting is checked before creating an intent, as before.

`ayuReadHistoryState(account:)` observes pending requests, saved retry deadlines,
unresolved errors and the latest 64 confirmed/cancelled results. It never enqueues
or retries. Only a successful RPC records a confirmed result; disappearance of a
pending row is not evidence of success. Old rows decode without receipts, never
inventing server confirmations. Cancelled results explicitly say delivery may
have occurred. The bounded recent-results list is not a permanent audit log.

Permanent server errors now retain their unresolved slot until explicit
Retry/Dismiss, instead of being evicted after 32 errors. This keeps accepted work
reachable after relaunch while bounding storage. The latest 32 local enqueue
rejections are retained separately; these were never accepted for delivery.
`ayuReadHistoryFailures` and `ayuAcknowledgeReadHistoryFailures` remain compatible,
but the new screen uses selective transactional controls and never automatically
acknowledges errors merely because they became visible.

The local codes are `LOCAL_QUEUE_FULL`, `LOCAL_INVALID_MESSAGE`,
`LOCAL_UNSUPPORTED_PEER` and `LOCAL_READ_BOUND_UNAVAILABLE`. Server constants above
can share an inaccessible/invalid-chat error presentation. A rejected logout
enqueue is reported through the completion only, since logout clears errors.

`ayuReadHistoryController(context:peerId:requests:onAccepted:)` in SGSettingsUI is
the shared screen. Feed Read All, double-tap `.read` and menu Read Message pass
their explicit requests and show enqueue outcomes plus live pending/errors/results.
The callbacks say accepted, never success. Existing `markReadAfterAction` remains
setting-gated; its errors/pending are reachable through the same account-wide screen.

Opening `ayuReadHistoryController(context: context)` with default arguments is
**observation only**. This is the ready route for root's Settings entry (import
SGSettingsUI; push the returned ViewController using the existing navigation).
Use `Ayu.ReadStatus.Title` as its title. The screen is already reachable through
Feed's always-present Read Receipts action, even with no configured channels, and
through the cloud-message context menu regardless of the current ghost setting.
A peer-filtered screen offers All Chats for the rest of the same account.
No subscription is stored globally; screen destruction disposes its observation
and control subscriptions. A closed/logged-out account disables actions and hides
the stored selection. Switching accounts never retargets a captured context.

`ayuControlReadHistory(account:action:)` supports Cancel, Retry Pending, Retry
Failure and Dismiss Failure. Pending controls compare the exact persisted id AND
maxId; stale dialogs cannot cancel or retry a higher coalesced read. Failure
controls compare id and reject selections already retried/dismissed. Every
transaction checks authorized owner/closed state. Retry rotates pending identity
to reject old completions, keeps the exact finite maxId and cannot bypass a saved
retry/flood deadline. Unknown bounds/unsupported inputs require a new explicit
Read action in the chat. Cancel persists removal before the runner observes and
disposes transport; it cannot retract a request already delivered/in flight.
No view appearance, status subscription, relaunch or UI refresh creates a read.
Previously accepted pending requests continue their authorized automatic retries.

Feed Read All captures eligible channel ids and finite known bounds before its
confirmation. Selection/arrival changes while the dialog is open do not expand
that scope. All confirmed channels, including those without ghost suppression,
use this same observable bounded queue. The old engine chat-list read-to-top path
was removed from this action because it could read an uncaptured newer server top.
An unknown bound becomes an invalid-input error, never a retryable sentinel.
Only accepted requests advance the captured loaded feed cursor, bounded by that
request; no server success is claimed. Local original-chat unread state follows
Telegram's normal updates rather than the previous interactive read-to-top action.

Root integration artifacts:

- [`strings-handoff.json`](../Tests/AyuExplicitRead/strings-handoff.json): exact
  33 keys in each of `en` and `ru`. Keep named `{accepted}`, `{total}`, `{date}`,
  `{id}`, `{pending}`, `{errors}` placeholders. They are replaced by the callers,
  not printf formats. No SG strings files were edited. English fallbacks work
  before root adds the keys (the i18n variadic argument is not a fallback API).
- [`root-menu-hook.patch`](../Tests/AyuExplicitRead/root-menu-hook.patch): the
  exact menu hook delta against the pre-integration helper call. Its actual target
  is `ChatInterfaceStateContextMenus.swift`, not `ChatController.swift`. It was
  already present in root HEAD `f33d6382` during handoff; do not apply twice. No
  ChatController hunk is needed, and that shared admin/root file was not edited.
- Root integrated the observation-only route in Ayu ghost settings and extera
  gesture settings, all 33 EN/RU keys, and the 21-case production queue host CI
  command. The read agent left root Settings, backup, strings, workflows and
  frozen AI files unchanged; the later integration is root-owned.

## Validation

The 21 Foundation queue tests and 18 Postbox/runner/transport tests are under
`submodules/TelegramCore/Tests/AyuExplicitRead` and are included in the existing
`//submodules/TelegramCore:TelegramCoreTests` target. See
[`Tests/AyuExplicitRead/README.md`](../Tests/AyuExplicitRead/README.md) for commands
and coverage. No State sync implementation or frozen AI consumer files changed.

On the Windows implementation host, tree-sitter parsed all 14 relevant Swift
production/test files and `git diff --check` passed. The host XCTest attempt
stopped because `swift` is unavailable. These are syntax/whitespace results,
not a Swift typecheck, test execution or iOS build. Run the host queue suite and
TelegramCore iOS suite on the Mac before accepting runtime behavior. Also verify
the three explicit UI callers under ghost mode, offline/relaunch/reconnect, and
logout with pending work on two accounts; check that ordinary hidden reads still
produce no history-read RPC. Neither XcodeBuildMCP nor an iOS simulator is exposed
on this host. Visual verification remains outstanding under AGENTS.md's recorded
frame rule; no UI/runtime acceptance is claimed. The expected-frame/check matrix
is in the test README.
