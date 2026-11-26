# Pill Stack: exact AyuGram APK evidence and native parity audit

2026-11-25. Follow-up to local root commit
`9598c2c090f4a469714ae98e2c3a9c2cbda6311b`. The APK/decompilation and other agents'
sources were inspected read-only. The user subsequently unfroze Pill files and
authorized the Entry Time implementation and portable layout API. No commit/push.

## Reference provenance

The path recorded in `docs/extera-ayu-overview-links.md` exists:
`C:/Users/PC/ayugram-apk-src/sources`. Rehashed the original APK in
`C:/Users/PC/Downloads/Telegram Desktop/vanilla-AyuGram-full-20261104.apk`:

- Size: 133,795,216 bytes.
- SHA-256: `b7195bd9f3126543566acf3e1e5d3d1cc1fa163db927e85918877f7cb65cb113`.
- This matches the reference provenance in the overview-links document. The cached
  `AyuMainPreferencesActivity.java` hash also matches that document. The lite APK
  is a different file/hash; it was not used as the semantic reference.

Source SHA-256, under the decompilation's `sources/` directory:

| Source | SHA-256 |
| --- | --- |
| `com/radolyn/ayugram/preferences/AyuMainPreferencesActivity.java` | `c2df97dfe55491066441684befa990e3d0ab132c3444db48eb207a314377fb81` |
| `com/exteragram/messenger/pillstack/core/PillRegistry.java` | `4b21f0af6e2aeacaeb1bdcc9185beb57f52cc9e28ee9632df6ed6416261005ef` |
| `com/exteragram/messenger/pillstack/core/PillStackConfig.java` | `4e31f996fab3be7a3f2a574e1703583acaae46c54775d68bf99d6c812798ce5e` |
| `com/radolyn/ayugram/ui/LastSeenPill.java` | `df3ec2f5fd6b548e49624806f94582ab7908744f54bed89e902dbcb396557a23` |
| `com/radolyn/ayugram/utils/AyuWorker.java` | `b44bf3483f9808c1d9d3b095b1e0c73e832305b53637c484aec583b3045ddabe` |
| `com/radolyn/ayugram/utils/network/AyuRequestUtils.java` | `8131dc7d704df5f8ccea7cee85bfa95c078bd9721660367bf2dacb2accee07ca` |

The decompilation has not been regenerated during this audit. These are cached
source evidence and matching provenance, not a new APK runtime observation.
Frame31 inventory is recorded at `docs/extera-reference-screens-23-44.md:149`;
the matrix's Pill row is `docs/extera-reference-matrix.md:66`. Current upstream
`exteragram-reference` lacks the Ayu-specific provider and cannot establish that
the exact APK lacks it. The earlier unsupported-provider conclusion is corrected.

## Entry Time: positive evidence

All paths below are relative to the decompilation's `sources/` directory.

| Evidence | Exact behavior |
| --- | --- |
| `com/exteragram/messenger/pillstack/core/PillType.java:7` | `LAST_SEEN(100)` is distinct from six upstream types 1...6. |
| `com/exteragram/messenger/pillstack/core/PillRegistry.java:183` | Seventh registration: `PremiumPreviewLastSeen`, `menu_premium_seen`, creator `LastSeenPill`. No Premium/ghost/account-age condition wraps this registration. |
| `com/radolyn/ayugram/ui/LastSeenPill.java:171` | Requests current selected account's client user ID through `AyuWorker.requestLastSeenUpdate`. |
| `com/radolyn/ayugram/ui/LastSeenPill.java:185` | Then calls `AyuRequestUtils.requestUser(account, clientUserId, ...)`. |
| `com/radolyn/ayugram/utils/network/AyuRequestUtils.java:254` | Sends `TL_users_getUsers` with that input user. No session/authorization creation timestamp lookup. |
| `com/radolyn/ayugram/ui/LastSeenPill.java:360` | Online only for `TL_userStatusOnline` with `expires > ConnectionsManager.currentTime`. |
| `com/radolyn/ayugram/ui/LastSeenPill.java:369` | Offline uses its `expires` field (wire `was_online`); expired Online uses its expiry. Positive timestamps format as time today or date/time otherwise; missing/coarse/nonpositive status falls back to `ALongTimeAgo`. |
| `com/radolyn/ayugram/ui/LastSeenPill.java:55` | Runtime icon is `msg_view_file`, not the editor's footprint icon. Opened the cached `resources/res/drawable-xxhdpi/msg_view_file.webp`: it is an eye. |
| `com/radolyn/ayugram/ui/LastSeenPill.java:123` | Periodic mode refreshes every 60,000 ms; non-periodic mode has no refresh timer. |
| `com/radolyn/ayugram/ui/LastSeenPill.java:143` | Tap fetches; non-periodic mode ignores a tap while loading or the previous result is expanded. |
| `com/radolyn/ayugram/ui/LastSeenPill.java:158` | With periodic mode off, automatic data update hides the text instead of fetching. |
| `com/radolyn/ayugram/ui/LastSeenPill.java:239` | Manual result hides after 3,000 ms; periodic result stays expanded. |
| `com/radolyn/ayugram/ui/LastSeenPill.java:386` | Long press offers Auto-Refresh, Refresh and Pill Stack Settings. |
| `com/exteragram/messenger/pillstack/core/PillStackConfig.java:190` | `lastSeenPeriodicOnline_<account index>` defaults false for all 16 Android slots. |
| `com/radolyn/ayugram/ui/LastSeenPill.java:213` | On request failure, reuses cached status if available; it never synthesizes a new timestamp. Cache arrays are per account slot. |
| `com/radolyn/ayugram/ui/LastSeenPill.java:424` | Attach/detach/settings and account-tagged worker events govern updates. Detach clears pending UI callbacks and status expansion. |

`AyuWorker.java:62,97` first sends `account.updateStatus(offline=true)` **only**
when the account's send-offline-after-online setting is on and `needOffline`
was set by a prior online event. After completion, or when no offline is needed,
it posts a fetch event after 100 ms. `LastSeenPill.java:458` debounces external
update notifications by 250 ms and attach/dialog lifecycle by 6,500 ms.
`DialogsActivity.java:9267,9751` posts the dialog lifecycle updates.

This proves a server last-seen/status widget. Account creation time, active-session
creation time, app launch time and the current local clock are not substitutes.

## Native implementation and practical limits

New source `submodules/TelegramCore/Sources/TelegramEngine/AccountData/ExteraAccountEntryStatus.swift`
owns the TL request and conversion. Public
`exteraRequestAccountEntryStatus(account:) -> Signal<ExteraPillEntryStatus?, NoError>`
uses the authenticated account's `users.getUsers([inputUserSelf])`, checks the
response user ID, and maps the raw Online/Offline variant. Error/timeout/missing
user returns nil; a legitimate missing/coarse status maps to longAgo. Request
timeout is 15 s and disposal cancels the subscription. ChatListUI imports no
TelegramApi. Existing TelegramCore source/dependency globs cover this addition.

The ordinary self-presence cache is unsuitable: `UpdatePeers.swift:480,505`
removes self from server presence merges, and `Account.swift` seeds self with
`.present(until: Int32.max - 1)`. Reading that would report artificial Online.
`AyuGhostLastSeen.timestamp` also falls back to local current time and is global,
so this implementation does not use it.

The selected visible widget starts with an eye only when Auto-Refresh is off.
Tap requests the server and displays the result for 3 s. Long press exposes the
account's Auto-Refresh toggle (false by default), Refresh and Stack Settings.
Auto-Refresh fetches on selection/foreground and every 60 s. Switching widget,
search activation, host disappearance/background and settings changes stop its
timer/request; the production generation gate rejects late A -> B -> A results.
Failed refresh uses only that provider instance's previous raw status, formatted
again against Telegram's approximate server time; it never substitutes `Date()`
as a last-seen value. A fresh failure displays Status unavailable.

Remaining Entry Time parity limits are explicit:

- The iOS ghost presence manager and send filter already own online/offline
  side effects. This widget reads server status and does not send extra offline
  packets, which could itself move last-seen time. Android's conditional pending
  offline flush and immediate post-send/250 ms/6.5 s event synchronization have
  no equivalent public, account-scoped completion signal in the inspected iOS
  surface. An in-flight native offline update may therefore be observed on the
  next refresh, rather than immediately after that update. Coordinate such a
  signal with the ghost owner before claiming event-level 1:1 behavior; their
  Account/Network sources are concurrently modified and were not edited here.
- iOS uses native DateFormatter short date/time rather than Android's
  LocaleController formatter. Runtime values and source semantics match; exact
  typography, 12/24-hour preference and width animation require simulator frames.
- The search host retains its existing fixed allotted width. Text disappears
  after 3 s; Android also animates intrinsic pill width. No width-animation parity
  is claimed. The eye and text move together during vertical widget switching.

## Built-in catalog, native conditions and defaults audit

This audit is scoped to the Pill catalog and its native providers. It makes no
claim about all extera/Ayu settings elsewhere in the application.

| Item | Exact APK source/conditions/defaults | Native state and remaining gap |
| --- | --- | --- |
| Catalog | `PillRegistry.java:125-188`: unconditional ordered seven, Weather/GRAM/BTC/USD/Cache/Proxy/LastSeen. `PillStackConfig.java:176-209`: active empty, all registered hidden. | Exact seven IDs/order and hidden defaults preserved; no unsupported/premium exclusion. iOS stable names differ from Android numeric IDs by design. |
| Infinite/selection | `PillStackConfig.java:58,62`: infinite true; last active ID -1. `PillStackView.java:256-286`: vertical switching, wrap only when enabled. | Infinite true, nil selection, vertical wrap/finite stops are implemented. Android tracks continuous gesture progress/scale/alpha; iOS's discrete 0.2 s switch is not visually accepted as equivalent. |
| Editor conditions | `PillStackPreferencesActivity.java:124,219`: active section only if nonempty; Reset button only when active list differs from empty default; reset hides all registered widgets. | Existing iOS preview/search/HTTP section are extensions. Empty active-section layout and conditional Reset behavior are not established as 1:1; existing editor has no matching conditional Reset. Frame31's absent Reset is explained by default empty active list. Colored editor icons use native single colors instead of APK gradients. |
| Weather | `WeatherPill.java:37,76-128`: 20 min refresh; current-location permission and device services checked; tap requests location or opens options; long press offers refresh and Weather Settings. `PillStackConfig.java:55-57`: current location true, manual geo/address null. `Stories/recorder/Weather.java:108,240`: current or manual location; absent manual geo falls back to Moscow only in explicitly manual mode; configured Telegram weather bot. | Native Telegram Weather bot/current location/20 min TTL are present with explicit bot-bound consent. Manual location/address picker and device-services-specific UI are missing. Native output is always Celsius; APK `Weather.java:63,78` chooses Fahrenheit for its listed timezone IDs. Source/conditions parity is partial; no unrequested Moscow data is fabricated. |
| GRAM | `GramPill.java:16`: base TON, fallback scale 3. `RatePill.java:58`: 5 min. `PillStackConfig.java:59`: separate GRAM target AUTO. | Correct TON source, cross-rate and 5 min TTL. Native has one shared per-account target and a free ISO field. Missing separate AUTO selection and exact fallback precision. Not a wallet balance. |
| BTC | `BtcPill.java:16`: base BTC, fallback scale 2. `PillStackConfig.java:60`: independent BTC target AUTO. | Correct source/cross-rate/TTL. Same target, catalog and formatting gaps as GRAM. |
| USD | `UsdPill.java:17,26,39`: base USD, scale 2; choosing USD resolves back to AUTO and USD is excluded from the target menu. `PillStackConfig.java:61`: target AUTO. | Native can currently select USD -> USD = 1; APK excludes that explicit selection. Same shared-target gap. |
| Currency catalog/default | `PillStackCurrencies.java:64-94,120-147`: AUTO + `ExchangeRates.FIAT_CURRENCIES`, excluding USD for the USD pill. AUTO uses account billing target currency with USD fallback. `ExchangeRates.java:81`: exact Coinbase USD endpoint; parser inverts rates before cross calculation. `PillStackCurrencies.java:150`: currency minor-unit precision and symbol prefix/suffix with US grouping. | Native system-locale currency fallback differs from billing target. Free ISO input can accept unsupported codes, reported unavailable. Native Double/display digits and language-localized number formatting differ from Android BigDecimal/minor-unit/symbol output. Cross-rate math is equivalent; exact display is not. Remote consent remains required under the user's standing instruction. |
| Storage Usage | `CachePill.java:50,95-147`: 3 min refresh; calculates app media cache size plus device used-space fraction; ring icon shows device fraction, label shows cache bytes. Tap opens CacheControl; long press Storage/Refresh/Settings. | Native account storage category sum and storage route are real, but do not establish same Android all-app cache accounting. Device occupancy ring and separate long-press Refresh/Stack Settings are missing. Native ByteCountFormatter can use different units. |
| Proxy | `ProxyPill.java:74-98`: enabled/current proxy plus selected account connection state. Connected shows ping clamped 0...9999 ms if positive, otherwise Connected; disabled says Proxy; nonconnected says Connecting with loading. No refresh timer. Tap ProxyList; long press Stack Settings. | Native account connection subscription and Proxy Settings route are present. Ping is not displayed; off/no-network/issues wording and coloring differ. Long press currently follows the same native Proxy Settings route as tap, unlike the APK. |
| Entry Time | `LastSeenPill.java` and `PillStackConfig.java:190`: raw own-user server status, per-account auto off, tap/3 s, auto/60 s. | Actual provider implemented in this follow-up. Conditional ghost-worker ordering/event debounce and intrinsic width animation remain as described above. |

Hidden sources do not start requests in the native selected-provider design.
Explicit weather/rates/custom consents and bounded transport are retained user
requirements, even though the APK does not present the same consent UI. Those
consents are excluded from the portable document and must not be restored by root.

## Root-facing portable API and string handoff

`ExteraPillStackDocument` lives in the already-integrated model source, so the host
command needs no extra source argument. It validates the entire seven-plus-custom
inventory without repairing malformed input. Custom IDs must match the HTTP
document being restored; pass those specs **after** HTTP document validation.
It is pure: root can decode/validate every backup section before writing anything.
When root applies a validated layout, the existing store API is
`store.update(custom: validatedHTTP) { $0 = validatedLayout }`.
For exporting live preferences that may not yet have encountered new/imported
HTTP IDs, explicitly normalize the live snapshot before calling the strict encoder:
`ExteraPillStackDocument.encode(store.layout.normalized(custom: validatedHTTP), custom: validatedHTTP)`.
Imported portable input must go through strict decode without such normalization.

The envelope is version 1 with exactly `version` and `layout`; layout requires
`visible`, `hidden`, `infiniteScrolling`, and allows optional/null `selected`.
Maximum encoded/input size is 64 KiB and maximum custom count is the existing 24.
Duplicate/overlapping/incomplete/stale IDs, duplicate incoming custom UUIDs,
hidden selection and unknown fields are rejected. Order is preserved. This is
distinct from the existing lenient on-device migration decoder. It does not
export account-specific Auto-Refresh, target currency, grants, URLs, coordinates
or cached values. Raw duplicate JSON object-member detection and the whole-backup
transaction remain root's responsibilities; this API validates decoded schema.

No EN/RU resource files were edited. The provider/view use the existing
`exteraPillText` helper. If root centralizes them, suggested keys/values are:

| Suggested key | EN | RU |
| --- | --- | --- |
| `Extera.PillStack.EntryTime.AutoRefresh` | Auto-Refresh | Автообновление |
| `Extera.PillStack.EntryTime.Online` | Online | В сети |
| `Extera.PillStack.EntryTime.LongAgo` | A long time ago | Был(а) давно |
| `Extera.PillStack.EntryTime.Unavailable` | Status unavailable | Статус недоступен |
| `Extera.PillStack.EntryTime.Description` | Shows this account's server-reported online or last seen status. Tap to check; with Auto-Refresh off, the result is shown for 3 seconds. | Показывает статус и время последнего присутствия этого аккаунта с сервера Telegram. Нажмите для проверки; без автообновления результат виден 3 секунды. |

On/Off, Refresh, Settings, Cancel and the existing Entry Time title can reuse
existing localized equivalents. The unavailable message now describes a failed
status read, not an unsupported widget.

## Validation and frames still required

Host tests extend the production model harness with account-specific Auto-Refresh
persistence, raw Online/Offline expiry boundaries, nonpositive/coarse fallback,
portable round-trip, literal schema fixtures, bad version/types/keys/IDs/selection,
file limits, duplicate incoming UUIDs and preservation/exclusion of remote grants.
New `TelegramCore/Tests/ExteraAccountEntryStatusTests.swift` checks the actual TL
status conversion, including all coarse/hidden variants. Existing generation and
request lease tests remain. These tests were added, not executed in this Windows
environment without Swift/Xcode. The syntax checker includes both new Core files.
Executed after the implementation: tree-sitter syntax checks passed all 15 Swift
files; scoped `git diff --check` passed; the three new files passed final-newline
and trailing-whitespace checks. The original APK and evidence source hashes above
were recomputed locally. None of these checks is an iOS typecheck or runtime test.

Before recording on a permitted Mac simulator, expected Entry Time frames are:

- Auto off/first selection: eye only, no automatic network request. Tap: loading
  then actual Online/time/long-ago text; the eye stays aligned with its label.
  Three seconds after the result, text disappears and the eye remains. Repeated
  taps while loading/expanded do not restart the timeout or stack requests.
- Auto on: selection fetches and leaves text visible beyond 3 s; a subsequent
  60 s refresh updates it. Toggle off returns to icon only and cancels the timer.
- Switch both directions through Entry Time: the eye and text enter/exit together
  over the existing 0.2 s vertical transition, without stationary duplicate icons,
  clipping or a color flash. Reduce Motion changes content immediately.
- Hide/search/navigate/background while a read is pending: no late label update;
  on return, default mode stays collapsed and auto mode refreshes. Switch accounts:
  independent auto flags and no other account's timestamp/cached response.
- Disconnect: previous real status may remain on failed refresh; a host with no
  prior result shows Status unavailable. No successful timestamp equals a locally
  generated fallback. Retry after reconnect uses Telegram's actual response.

Record `entry-time.mp4` and inspect labelled `entry-time-sheet/` frames using
root AGENTS.md. Existing editor/header/source-consent recording paths remain in
`extera-pill-stack-implementation.md`. No recordings, iOS runtime success or
visual/animation acceptance are claimed here.
