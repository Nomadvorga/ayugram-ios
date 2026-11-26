# Pill next wave: APK ordering, native modules and review patch

2026-11-26. **User-authorized next wave applied to the working tree.** The frozen
Pill checkpoint was accepted and the patch applied; follow-up renderer, point
selection, cache-accounting and Postbox-import refinements are also applied.
Root's backup/CI/deps and broad unrelated WIP are preserved. The
`NSLocale.object(forKey: .currencyCode)` fallback remains verbatim. No branch
operations, commit or push.

`pill-next-wave.patch` is the retained unified patch against the inspected
pre-application working contents, including accepted uncommitted Entry Time work.
`base-sha256.json` records LF-normalized source hashes. `review/` contains the
pre-application reconstructed sources. Do not rerun its generator or apply it a
second time; the actual destinations are now active production sources. Detailed
current checks and limitations are in [`VALIDATION.md`](VALIDATION.md).

The source is not yet compile- or visual-accepted. Remaining Mac/CI checks and
known API boundaries are tracked below and in `VALIDATION.md`.

## Exact reference and reproducibility

Reference is the full APK, SHA-256
`b7195bd9f3126543566acf3e1e5d3d1cc1fa163db927e85918877f7cb65cb113`, at
`C:/Users/PC/Downloads/Telegram Desktop/vanilla-AyuGram-full-20261104.apk`.
Cached decompilation is `C:/Users/PC/ayugram-apk-src`; provenance/source hashes
are in `docs/extera-pill-stack-apk-audit.md`. Evidence paths below are relative
to that decompilation's `sources/`. No fresh APK runtime observation is claimed.

```powershell
uv run python docs/integration/pill-next-wave/prepare_patch.py
git apply --check docs/integration/pill-next-wave/pill-next-wave.patch
uv run --with tree-sitter --with tree-sitter-swift python docs/integration/pill-next-wave/verify_review.py
```

The generator reads production/APK files and writes **only its own directory**.
It fails on nonunique/missing anchors and existing new destinations. Do not rerun
it after applying its patch: its inputs intentionally represent the pre-wave
baseline. The patch was checked without applying it. Mac commands below are for
after root's commit and an authorized source integration.

## Exact ghost/offline/worker ordering

1. `org/telegram/tgnet/ConnectionsManager.java:619-647` unwraps bypass requests;
   ordinary Online status is changed to Offline if send-online is disabled.
   Read/typing/story suppression/exclusion and mark-read-after-action are distinct
   branches (`:631-683`). `:684-690` wraps an *existing* request's callback if
   send-offline-after-online is on and `AyuRequestUtils.isOnlineRequest` says it
   can reveal activity. Bypass requests skip this wrapping.
2. The wrapped callback (`ConnectionsManager.java:779-784`) invokes the original
   callback first, then `AyuWorker.setOnline(account, true)`. It does this even
   when the callback contains an error. That is APK behavior, not proof that the
   server set Online. Native success-only bookkeeping can intentionally stay
   narrower; don't start marking failed sends as activity merely for UI parity.
3. `AyuRequestUtils.java:983-1018` includes sends, reads, edits, conditionally
   reactions/votes, create/leave/topic/pin/call/story actions in `isOnlineRequest`.
   This classifies requests already made elsewhere. It **does not authorize a
   new read**. The Pill port must not call those request builders to imitate the
   classification. iOS currently classifies five cloud send methods only.
   The unconditional non-send/read/edit names are exactly `messages.createChat`,
   `channels.createChannel`, `messages.createForumTopic`, `channels.leaveChannel`,
   `messages.deleteTopicHistory`, `messages.editForumTopic`,
   `messages.updatePinnedMessage`, `phone.requestCall`, `phone.acceptCall`,
   `phone.confirmCall`, `stories.sendStory`, `stories.sendReaction`,
   `stories.readStories`. Conditional reaction/vote names are
   `messages.sendReaction`, `messages.sendPaidReaction`, `messages.sendVote`.
4. `MessagesController.java:29468` also calls `setOnline` on a real own-user status
   update, passing `status.expires >= serverNow`. Note `>=` here versus `>` in
   LastSeenPill's displayed Online test. `AyuGhostConfig.java:129-154` can seed
   pending activity when ghost is enabled, or explicitly send Online when disabled.
5. `AyuWorker.java:112-121` stores `needOffline[account] = value`; if the account
   setting permits offline-after-online it restarts the worker with 1,500 ms
   initial delay / 3,000 ms fixed delay (`:32-43`). Every `setOnline` posts
   `LAST_SEEN_PILL_UPDATE(account, false)` on UI, whether the value is true or false.
6. A worker tick (`:49-64`) visits activated accounts only. It tests the setting
   **before** `getAndSet(false)`. Setting off does not consume pending activity.
   Once consumed, one `account.updateStatus(offline=true)` is sent (`:67-81`).
   Its callback invokes the continuation on success **or error**, with no rearm.
7. `LastSeenPill.requestStatus` (`:171-182`) sets waiting/loading and calls
   `AyuWorker.requestLastSeenUpdate`. That function (`AyuWorker.java:97-109`)
   consumes and flushes pending offline only if the setting is on. Otherwise it
   schedules FETCH directly. Callback then schedules FETCH after **100 ms**, not
   immediately (`:88-95`). A tick's offline callback uses the same FETCH path.
8. `LastSeenPill.java:490-504` handles account-matched FETCH: a waiting manual
   request resolves even when auto is off. An unsolicited FETCH resolves only if
   auto is on and no self-user request is in flight. It does not call the worker
   again before that resolved request. Then `users.getUsers(self)` is issued.
9. `LastSeenPill.java:467-485` handles account-matched UPDATE only in auto mode,
   cancels the previous external callback and schedules a request after **250 ms**.
   That request goes through step 7. UPDATE with lifecycle flag true first skips
   if already waiting/loading; otherwise a cached status younger than **6,500 ms**
   is shown instead of a new request.
10. Dialog creation/resume at `DialogsActivity.java:9267,9751` records monotonic
    lifecycle time then posts UPDATE(account, true). Attach (`LastSeenPill:351-357,
    424-435`) skips refetch only when both lifecycle and successful cached status
    are younger than 6,500 ms. Detach removes listeners and callbacks (`:438-454`).
11. Raw `User.status` controls display (`LastSeenPill:360-383`). Callback clears
    waiting/inflight/loading first, then only attached compatible mode publishes
    (`:213-235`). Manual result hides 3,000 ms after publication; auto remains.

There is an APK race to avoid carrying over: tick/manual flush atomically consumes
the pending flag but does not expose an in-flight offline flag. A second reader
can see no pending flag and fetch before the first flush callback. The proposed
native barrier joins all already-running presence operations instead.

## Comparison with AyuGhostRequestFilter and minimal native change

Current iOS `AyuGhostRequestFilter.swift:40-61` drops disallowed Online; it does
not rewrite it into Offline. Dropped Bool requests can get a synthetic success
but bypass the real request success callback. `:166-194` acts only on successful,
unscheduled cloud sends while suppress-online is enabled: optional Online pulse,
then Offline 0.2 s later, or direct automatic Offline. It launches those signals
without waiting for callback and records local ghost UI time immediately.
`ManagedAccountPresence.swift:72-118` owns foreground/background/settings presence;
its own disposable and queue govern completion. Entry Time currently reads raw
self immediately, independently of both paths.

Proposed native adaptation is deliberately small in packet policy:

- New TelegramCore `ExteraPresenceBarrier.swift` is owned by each `Network` via an
  associated object; state does not use a global account slot. `ayuTrackedPresence`
  wraps only existing presence operations. It releases waiting readers exactly
  once on success, failure or cancellation. Completion/failure publishes FETCH;
  cancellation just releases the barrier. `exteraPresenceBarrier` waits for idle
  and 100 ms; a new operation restarts the settle interval. Existing 15 s Entry
  Time timeout bounds the whole wait+read.
- The send pulse still starts Online immediately, starts Offline after 0.2 s
  using the existing suppress-online guard, and keeps local ghost UI bookkeeping.
  The entire pulse counts as pending, including its scheduled delay. A failed
  Online callback does not accidentally suppress the preexisting Offline attempt.
- Direct automatic Offline and presence-manager requests use the same wrapper.
  No new worker timer, unconditional offline flush or request retry is introduced.
  Existing presence-manager requests retain their cancellation/queue semantics.
- `UpdatePeers.swift` emits an account-tagged UI UPDATE before the self-presence
  entry is removed. It leaves cache merge rules and State/Sync code unchanged.
  Send success also emits UPDATE. The provider debounces those by 250 ms and
  listens only while selected/auto; a manual request listens through its barrier.
- The Core snapshot stores only raw server status and monotonic freshness per
  Network. The host marks a fresh appearance; a nonforced auto attach can use the
  cached raw status under both 6.5 s checks. Text is formatted again, so cached
  Online can expire. No new last-seen value comes from `recordNow` or `Date()`.
  An already pending presence operation also prevents the recent-cache shortcut.

This is a native ordering adaptation, not a verbatim Android worker replacement:
the existing iOS send policy remains immediate/0.2 s rather than acquiring the
Android 1.5/3 s worker schedule. The barrier makes observation follow the owner.
If exact worker cadence is required, the ghost owner must replace that policy as
one separate change, using the proven pending-bit algorithm above; installing a
second worker in Pill code would duplicate Offline and move last seen again.

**Receipt invariant:** the generated diff does not change request dropping,
exclusions, explicit read outbox, read-state synchronization, mark-read-after-action
or the scheduled-send guard. Entry Time initiates only `users.getUsers(self)`.
No `messages.read*`, `channels.read*`, story read or view-count request is added.
Tests use synthetic presence signals so they cannot send receipts. No broad
`ayuBypassGhost` helper is exposed to ChatListUI.

## Concrete modules for remaining built-ins

| Gap | Exact evidence | Staged implementation and next acceptance work |
| --- | --- | --- |
| Independent AUTO targets | `PillStackConfig.java:59-61`; `UsdPill.java:26-40`; `PillStackCurrencies.java:120-147`; `RatePill.java:139-167` | `ExteraPillParity.swift` + settings accessors: one target per pill/account, default AUTO, pinned AUTO/USD/EUR then exact ordered fiat list, USD excluded for USD pill, explicit USD setter coerces AUTO. Old explicitly stored shared target is retained until each pill gets an override; old implicit locale default is not migrated. Real provider consumes the new target and menu. |
| AUTO account source | **Correction:** `BillingController.java:138-181` resolves from **account phone**; it does not use Play billing price currency. `PhoneFormat.java:181-191,359-379` picks first matching calling code then locale-country candidate/first country. | Generator extracts the exact ordered calling-code/country header from `PhoneFormats.dat`; production resolver accepts only account phone and local region, then maps region to currency and validates against APK allowed set. The phone stays local. Unknown/empty -> USD. StoreKit/locale-only currency is not substituted. Verify +1/+7 shared codes on Mac; country-currency metadata can change with OS updates. |
| Rate formatting | `ExchangeRates.java:217-224,326-339`: reciprocal at scale **16**, cross division scale **12**, HALF_UP. `PillStackCurrencies.java:150-185`: exponent from APK `currencies.json` (unknown -> 0), US grouping and symbol policy. | Generator extracts exact exponents; new Decimal parser follows both rounding stages and prefix/suffix overrides, including RUB suffix/CNY CN¥. Existing bounded/consented transport stays. Decimal has finite precision; add extreme but accepted source fixtures before claiming arbitrary BigDecimal equivalence. Java/iOS fallback currency symbols need golden fixture comparison. No fake wallet balance. |
| Manual weather | `WeatherSettingsActivity.java:270-305,324-404`; `Weather.java:108-128` | New MapKit settings controller, account-scoped current/manual coordinate+address model, coordinate validation, current-location default, Moscow only after explicit manual selection. Provider uses existing public `Weather.requestWeatherData(context:location:)` for manual and existing device location pipeline for current. Manual does not ask device permission; both require bot-bound remote consent. System location-services-disabled state is explicit; cache signature includes mode/coordinates/source/timezone. |
| Fahrenheit | `Weather.java:63-88` | Literal timezone rule implemented, including `US/` aliases and four named exceptions; Java `floor(x+0.5)` rounding. **America/New_York is Celsius under this literal APK rule.** Don't widen to a region heuristic. Tests pin this surprising case. |
| Storage label/ring | `CacheControlActivity.java:214-229`; `CachePill.java:120-145,232-272` | New `TelegramEngine.Resources.collectCacheUsageSummary()` exposes native unique resource-ID bytes, cache-path bytes and temporary-directory bytes without Postbox IDs. ChatListUI sums resource/cache per active account and shared temporary usage once; immutable DB/log size and backup/export files stay excluded. A pure host policy fixture covers multiple accounts, single-count shared temp and overflow. Device occupied fraction is separate from cache-byte label. New ring uses 16 pt bounds/2 pt round stroke, track alpha 50/255, starts at -90°, clamps minimum .05 and animates .65 s with quint cubic. Provider/view carry fraction together with cached label. Native iOS accounting is not byte-for-byte Android directory parity; preserve the explicit scope above. |
| Proxy ping | `ProxyPill.java:74-98,135-153`; native `ProxyServersStatuses.swift:6-24`; `ProxyListSettingsController.swift:326-327` confirms seconds -> ms. | Selected account's network + shared effective active server + native proxy ping subscription. Monitor only active proxy, dispose on switch/hide. Disabled -> Proxy; connected/updating -> clamped 0...9999 ms if positive, otherwise Connected; remaining states -> Connecting. Tap opens proxy list; hold opens Stack Settings. Native WEB proxy has no ping value, so Connected fallback is implemented; this is a missing measurement source to implement in its transport owner if parity requires a real WEB ping, not an unavailable widget. |
| Conditional Reset | `PillStackPreferencesActivity.java:219-235` | Existing editor gains Reset iff visible inventory nonempty; hides all/rebuilds hidden order from registered seven+custom, clears selection, preserves infinite setting, endpoints and grants. Empty active section header hidden. Fixed section IDs remain for reorder into an empty section. Remaining editor geometry check: UITableView empty-section spacing and header gradient/icons need actual frame comparison. Stale Entry Time unsupported subtitle is removed in patch. |
| Interactive gesture | `PillStackView.java:252-319,322-353,421-428`; `CubicBezierInterpolator.java:20` | New pure frame/commit policy plus pan integration: up=next, down=previous; only commit over .25H; progress clamps at 1 with a neighbor; outgoing y=sign·H·p, alpha=1-p, scale=1-.2p; incoming y=-sign·H·(1-p), alpha=p, scale=.8+.2p. Finite boundary y=sign·H·(1-1/(1+.18p)), alpha=1. Commit .25 s cubic(.23,1,.32,1); cancel .20 s Android default cosine interpolator. A weak display-link proxy avoids retaining an abandoned host. Data-only neighbor preview includes remembered text/title plus Entry Time eye or Storage ring; provider starts only after commit. |

The applied gesture renderer now supplies a data-only neighbor view with the
same label, Entry Time eye and Storage Usage ring composition. It uses remembered
output or a title fallback and acquires no provider lease before selection commits.
Frame acceptance, including intrinsic-width Entry Time behavior and clipping,
still requires simulator recordings; preserve search expansion geometry until
those frames are checked.

Manual map search presents selectable result names and pins the selected result's
own coordinate. iOS 26+ uses `MKMapItem.location`; the older supported path is
isolated through an availability-guarded legacy coordinate helper. The Xcode 27
warnings-as-errors build must still confirm the deprecation boundary. Long-press
map selection remains available for exact manual refinement.

Cache accounting now consumes TelegramCore's narrow `EngineCacheUsageSummary`,
which uses the native collector's unique resource-ID byte total, separate
media-cache bytes and shared temporary-directory bytes. Account resource/cache
totals are summed; shared temporary usage is included once. Database/log bytes
remain excluded. No Postbox imports or allowlist exceptions are needed in the
Pill UI files. The host aggregation fixtures cover multi-account summation,
single-count shared temp and overflow saturation; the integrated Core/UI API still
requires the Apple build.

## Integration order after root commit notice

1. Rebase this patch against the named committed snapshot. Keep root's backup,
   strict JSON, CI/deps and currency deprecation fix. The generator has exact
   anchors instead of whole-file replacement and never modifies root sources.
2. Ghost owner reviews the Core wrapper, cancellation, self-status notification
   and pulse preservation first. No Network.swift engine/telemetry/authorization
   changes are required. The UpdatePeers hook posts UI only; if owner requires a
   post-transaction event, route the same owner-tagged event through the existing
   replay-completion seam and update `docs/state-sync.md` as required by State
   notes. Never reorder State/Sync operations to synchronize this widget.
3. Review the applied currency/weather/storage/proxy modules and corresponding
   provider/UI hunks as one coherent Pill wave. Existing ChatListUI/TelegramCore/
   SGSimpleSettings globs cover sources. Root needs to verify MapKit linking and
   add new parity source to the explicit host command; no new InAppPurchaseManager
   dependency.
4. Run model/Core and full-app checks, then record and evaluate the simulator
   frames for Stack gestures and map/settings UI. No commit message should claim completed parity
   until those concrete tasks and frames are accepted. Keep Feed and root-owned
   Chats-menu/nav integration outside this patch.
5. Keep new weather coordinates, per-account target overrides and Entry Time auto
   out of `ExteraPillStackDocument` v1. They are local account settings. No remote
   grant is exported/migrated. Root owns any future account-settings backup policy.

## Tests and expected frames

New `ParityHostTests.swift` compiles the proposed **production** settings/parity
models, not a translated Python policy. It pins phone AUTO (+1/+7/empty), catalog,
currency/precision, timezone/negative-half rounding, gesture threshold/formulas,
finite resistance and settings isolation. On Mac after integration:

```sh
OUT="$(mktemp -d)"
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  Swiftgram/SGSimpleSettings/Sources/ExteraPillSettings.swift \
  Swiftgram/SGSimpleSettings/Sources/ExteraPillStrings.swift \
  Swiftgram/SGSimpleSettings/Sources/ExteraPillStackSettings.swift \
  Swiftgram/SGSimpleSettings/Sources/ExteraPillParity.swift \
  Tests/ExteraPills/ParityHostTests.swift -o "$OUT/ParityHostTests"
"$OUT/ParityHostTests"
```

Run the existing host suite with the additional parity source too. Core patch
adds `ExteraPresenceBarrierTests.swift` to existing globbed TelegramCoreTests:
it holds two real wrapper subscriptions, verifies one completion isn't enough,
checks 100 ms settle after final completion, and checks cancellation releases the
reader. It uses the existing Network test fixture and never sends packets.
Run with root CLAUDE.md's Make.py `test --target //submodules/TelegramCore:TelegramCoreTests`,
then the supported full Make.py app build. Add scripted-engine packet assertions
for pulse 0.2 s, offline callback error, scheduled sends and a self-status update;
assert no new read/story request names and no remote-grant changes. Run existing
receipt/outbox regressions unchanged.

Before recording (dedicated permitted K-sim; follow AGENTS.md), expected frames:

- `pill-pan.mp4` / `pill-pan-sheet/`: at .25 drag, old/new y=-.25H/+ .75H,
  alpha .75/.25, scale .95/.85; release at exactly .25 cancels, above commits;
  finite edge resists and returns; reversal/interrupt doesn't jump. Eye/ring/text
  must share the same transform every frame. Full-speed first, light/dark,
  Reduce Motion, both wrap directions, background mid-drag.
- `pill-storage.mp4`: ring grows to device occupancy over .65 s with no color
  flash or clipping; label is cache bytes, not device used bytes. Change account
  inventory and verify aggregation; refresh while hiding gives no late ring.
- `pill-weather.mp4`: current/manual switch, denied/services-off, map search/pin,
  Save/Cancel, source revoke, Fahrenheit aliases. Manual mode never shows the
  device authorization prompt. No bot request before remote consent.
- `pill-rates.mp4`: each pill retains independent target; AUTO resolves from the
  active account phone; USD menu omits USD. Loading/failure never shows another
  target's cached quote. No requests after revoke/hide.
- `entry-order.mp4`: while existing Offline callback is held, manual Entry Time
  remains loading; it reads after completion+100 ms. Auto gets UPDATE debounce,
  manual expanded result still hides at 3 s. Recent Chats return uses 6.5 s cache;
  second account never receives the first account's UPDATE/FETCH.
- `pill-reset.mp4`: default empty active list has no Reset; exposing one pill
  adds Reset; resetting hides everything in registry order without changing
  infinite/HTTP configuration/permissions. Existing reorder remains usable.

Use `tools/animation_sheet.py`, ffprobe timestamps and per-element tracks.
Syntax and `git apply --check` are the local checks available here. No Swift
execution, app build, screenshot, recording or visual acceptance was performed.
