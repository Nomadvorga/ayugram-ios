# Pill Stack integration handoff

2026-11-25. Resumed on root snapshot `136a2a1bf0cff0517ca49e677d028e6d9b601c0b`.
Feed/nav/swipe baseline hooks are preserved. The source handoff left root-owned
SGSettingsController, EN/RU tables, backup, BUILD and workflow unchanged. Root then
added the Weather dependency, expanded the production host command and renamed the
existing Chats-tab entry to Pill Stack. The snapshot is not yet build-verified.
Source edits are frozen at this handoff pending root integration/Mac acceptance.
This is a source handoff, not verified iOS build or visual acceptance.

## Files for the next root manifest

New files:

- `Swiftgram/SGSimpleSettings/Sources/ExteraPillStackSettings.swift`
- `submodules/ChatListUI/Sources/ExteraPillBuiltinProvider.swift`
- `submodules/ChatListUI/Sources/ExteraPillStackView.swift`
- `submodules/ChatListUI/Sources/ExteraPillStackController.swift`
- `submodules/ChatListUI/Sources/ExteraPillSearchAccessibilityElement.swift`
- `Tests/ExteraPills/verify_swift_syntax.py`
- `docs/extera-pill-stack-implementation.md`

Modified files:

- `Swiftgram/SGSimpleSettings/Sources/ExteraPillRuntime.swift`
- `submodules/ChatListUI/Sources/ExteraPillDashboardController.swift`
- `submodules/ChatListUI/Sources/ChatListController.swift` (two lifecycle lines)
- `submodules/ChatListUI/Sources/ChatListControllerNode.swift` (Pill-only hunks)
- `Tests/ExteraPills/ExteraPillHostTests.swift`
- `Tests/ExteraPills/README.md`

The unchanged `ExteraPillSettingsController.swift` wrapper and existing HTTP model/
strings remain in place. No full saved ChatList snapshot was copied back; the
archived own-hunks patch was reapplied to the committed baseline and fields were
moved to their correct owner before any new syntax run.

## Root integration required before building

1. Add `//submodules/Weather:Weather` to `submodules/ChatListUI/BUILD` deps.
   The new provider imports Weather and Apple's CoreLocation. CoreLocation is
   autolinked by the Swift import, as in the existing Weather module; no new
   location entitlement or location usage string is introduced by this work.
   Existing location usage descriptions and Weather dependencies remain required.
2. Add `Swiftgram/SGSimpleSettings/Sources/ExteraPillStackSettings.swift` to the
   Swift compiler arguments in `.github/workflows/extera-host-checks.yml`'s pill
   step. The exact standalone commands are in `Tests/ExteraPills/README.md`.
3. Source globs already include all new files. Keep the model helper in
   SGSimpleSettings and the four UI/provider helpers in ChatListUI. There is no
   new cross-module AccountContext protocol method or TelegramCore API.
4. Existing `Extera.DataPills` remains the settings route key (currently Information
   Pills / Информационные плашки). It invokes the unchanged settings factory and
   now opens Stack. If relabelling to Pill Stack, root owns the EN/RU table edit.
   The baseline Chats-tab menu action still says HTTP Pills / HTTP-плашки and
   invokes `exteraPillDashboardController`; it now opens Stack. Root/nav owner can
   relabel that existing action. This change adds no second menu injection.
5. No generated PresentationStrings IDs are required. New UI strings use the
   existing `exteraPillText` EN/RU helper and current account presentation language;
   other languages fall back to EN. Provider values and user labels are preserved.

## Inventory and actual providers

The frame31 order is exactly Weather, GRAM, BTC, USD, Storage Usage, Proxy, Entry
Time. `docs/extera-reference-screens-23-44.md` records the original frame. Cached
Android source was inspected with `git show HEAD:<path>` in
`C:/Users/PC/exteragram-reference`, under
`TMessagesProj/src/main/java/com/exteragram/messenger/pillstack/` and
`TMessagesProj/src/main/java/com/exteragram/messenger/utils/network/ExchangeRates.java`.
Its registry has the first six providers, but no Entry Time provider or timestamp
definition. Entry Time is included as explicitly unavailable; no local clock,
session timestamp, fabricated value or undocumented network API is substituted.

| Stable ID | Source and behavior |
| --- | --- |
| `builtin.weather` | `Weather.getWeatherData(context:load: true)`. Authorized current coordinate from the existing location manager; account engine resolves the configured `weather_search_username` bot, default `izweatherbot`, and requests inline weather results. Source is disclosed before consent. Finite temperature bounded to −150…100 °C; emoji output bounded. No location/provider cache is shared between account hosts. |
| `builtin.gram` | TON exchange rate, not a wallet balance. Coinbase `https://api.coinbase.com/v2/exchange-rates?currency=USD`, `TON` base. |
| `builtin.btc` | Same Coinbase response, `BTC` base. |
| `builtin.usd` | Same Coinbase response, `USD` base. Target currency comes from this account's setting. |
| `builtin.storage` | Current `context.engine.resources.collectStorageUsageStats()`, sum of `totalStats.categories` byte sizes. This is account media/cache usage, not system disk capacity or RAM. Tap opens native storage usage. |
| `builtin.proxy` | Current `context.account.networkState`: Off, Connecting, Connected, Connection issues, or No network. No proxy address/credential display. Tap opens native proxy settings. |
| `builtin.entryTime` | Unavailable with explanation: no supported data provider. Missing Android semantics are documented above. |
| `custom.<lowercase UUID>` | Existing custom HTTP spec and formatter/runtime. Hidden by default; its search grant binds exact URL and account. The explicit HTTP dashboard retains its prior all-enabled mode. |

Rates use `target units per USD / base units per USD`, require a USD envelope,
positive finite numbers, and a finite positive cross-rate. Unsupported currencies
show Rate unavailable. The ephemeral request accepts HTTP 200 only, blocks all
redirects, disables cookies/credential/cache stores, caps streaming and parsed
bodies at 512 KiB, and times out after 15/20 seconds. No Telegram account IDs or
location are attached. Requests happen only while a permitted widget is selected
in a visible, active host. There is no launch-time rates preload.

## Defaults, migration and persistence keys

The layout is independent of `extera.customHTTPPills.v1`. The old HTTP document,
credentials, validation, import/export version and enabled flags are unchanged.
An existing HTTP document gains no visible search widget or new remote permission
on upgrade. Missing, corrupt or stale layout identities normalize to the current
seven built-ins plus known custom IDs without duplicates.

| Key | Value and default |
| --- | --- |
| `extera.pillStack.layout.v1` | JSON Data: `visible: [String]`, `hidden: [String]`, `infiniteScrolling: Bool`, optional `selected: String`. All hidden; seven built-ins in reference order followed by custom HTTP IDs; infinite enabled; no persisted selection. Missing optional fields receive these defaults. |
| `extera.pillStack.<account Int64>.allow.weather` | Bool, false. Necessary together with matching weatherSource. |
| `extera.pillStack.<account Int64>.weatherSource` | Exact consented bot username, absent by default; a changed configured bot requires fresh consent. |
| `extera.pillStack.<account Int64>.allow.rates` | Bool, false. One source consent for GRAM/BTC/USD. |
| `extera.pillStack.<account Int64>.customURL.<UUID.uuidString>` | Exact URL String, absent by default; revoke removes it. Replacing URL under the same UUID requires consent again. This is a copy of potentially sensitive configured URL data: do not include it in diagnostic logs. |
| `extera.pillStack.<account Int64>.currency` | Uppercase three-letter code. Defaults to the system locale currency, then USD. Invalid codes are ignored; unsupported but well-formed codes remain selected and produce unavailable rates. |

Layout/order/selection are shared preferences across account hosts; all remote
grants and target currencies are account-specific. A disabled custom HTTP item
retains its layout position but is skipped by the renderer. Deleted IDs disappear
on normalization; a later reimport starts hidden after the deletion was persisted.
HTTP export remains endpoints-only and does not export Stack consent or layout.

Root owns backup policy. Recommend restoring layout/currency only after normalizing
against restored HTTP specs, and excluding remote consent keys from backup restore
so another install cannot silently inherit location/endpoint permissions. There is
no claim that the existing backup system already includes these new keys.

## Public model and controller API

- `ExteraBuiltinPill`: exact seven-case inventory; stable `id`, symbol, localized
  `title`, and `from(id:)`.
- `ExteraPillStackLayout`: Codable/Equatable layout; `normalized(custom:)`,
  `setVisible`, stable-identity `move(_:visible:before:)`, `renderedIds(custom:)`,
  and `next(from:direction:ids:)`. Missing selection falls back to the first
  rendered ID. Infinite wraps last/first; finite stops at either boundary.
- `ExteraPillStackSettings.shared`: `layout`, normalized `update(custom:_:)`,
  account grants (`allowed/allow`, `allowsWeather/allowWeather`,
  `allowsCustom/allowCustom`), account currency, `didChange`, and injectable
  `init(userDefaults:)`. Default initializer uses existing AyuSettingsStore.
- `ExteraPillProviderGeneration`: `begin` returns a ticket, `cancel` invalidates
  it, and `accepts` rejects late completions including A → B → A. Used by the
  actual built-in provider, not just a fixture.
- `ExteraPillRequestLeases`: exact-configuration search leases versus unrestricted
  explicit dashboard leases. `acquire(approved:)`, `release`, `permits`, `isEmpty`.
  Used by `ExteraPillRuntime` scheduling, refresh and pending-request cancellation.
- `ExteraPillRuntime.acquire(ids: Set<UUID>? = nil)` replaces parameterless
  `acquire()` with a defaulted parameter, so existing callers remain source
  compatible. `nil` observes all enabled specs; a provided set snapshots the
  current configurations. `release` immediately cancels unobserved pending work;
  imported/replaced/disabled configs invalidate their previous scope.
- `exteraPillDashboardController(context:edit:transfer:)` keeps its public
  signature and opens Stack. `exteraHTTPPillDashboardController` opens the original
  HTTP dashboard. Existing settings wrapper supplies endpoint editor and transfer
  callbacks; display-only entry has no callbacks. No root settings edits needed
  to preserve routing.

## Real host hooks and lifecycle

`ChatListControllerNode`, not `ChatListContainerNode`, owns `exteraPillHostVisible`,
the lazy Stack view, inventory check and independent Search accessibility element.
`ChatListController.viewDidAppear/viewWillDisappear` only toggle its host flag.
The root chat list's existing `ChatListNavigationBar.searchContentNode.placeholderNode`
hosts the real selected widget. Search text uses the existing left alignment and
maximum width APIs; it remains independently tappable and accessible. There is
no second search bar or detached row and no edit to ChatListHeaderComponent.

The parent controls widget frame, reading the existing search expansion geometry
(60 pt row, 44 pt field) and its 0.77…1 placeholder fade. Normal header layout,
scroll changes and scroll-to-top update visibility/frame with the same transition.
Search activation immediately stops the widget. Hidden search preference, nested
chat lists, width below 180 pt, no rendered widgets, closed controller, removed
window and background suppress work. The helper does not override parent visibility
when a queued settings reload arrives. Search keeps its own VoiceOver button;
the widget exposes adjustable increment/decrement and source/options activation.

Stack editor provides preview, live title search, infinite toggle, visible/hidden
sections, colored icon tiles, native reorder handles and cross-section moves.
Tap toggles visibility; VoiceOver has move up/down actions. Reorder is disabled
while filtering; movement persists by ID. The table's backing model updates
synchronously inside its reorder callback; row reload waits until after the
UIKit transaction. Selection-only changes preserve the preview cell/animation.

Each selected built-in owns one disposable/request and cancellation generation.
Only its source runs; weather/rates permissions are checked before memory cache.
Cache TTLs: weather 1,200 s, storage 180 s, rates 300 s; keyed by currency/language
and weather bot where relevant. Proxy subscribes live. A foreground 60 s timer
rechecks TTLs; explicit Refresh bypasses cache. Disappearance/background/selection
change/revocation stop timers and dispose/cancel provider subscriptions/requests;
generation checks reject any late result even if underlying engine work continues.
Location authorization is
requested only after source acceptance and its timer is suspended while pending.
Its callback cannot restart a hidden host. HTTP uses existing three-request
concurrency and generation tokens in addition to the new scope policy.

## Validation and remaining acceptance

The implementation environment is Windows with Ubuntu WSL and no Swift compiler,
Apple SDK, XcodeBuildMCP or iOS simulator. The standalone host harness and full
iOS typecheck/build have **not run**. Tree-sitter parsing is a syntax check only;
it cannot establish access control, overload resolution, SDK availability or a
successful link. Root must add the dependency and run the host command and full
supported Make.py app build before accepting the source as compile-verified.

Host fixtures/tests cover old-v1 compatibility, persistence, normalization,
ordering including cross-section moves, both infinite/finite boundaries,
disabled/deleted/reimported custom IDs, account isolation, bot/URL replacement
consent, revocation, currency, invalid rate data, provider cancellation/A-B-A and
multiple HTTP host scope changes. These execute production pure model/policy
code; they do not claim URLSession/UIKit integration coverage.

Executed here: `uv run --with tree-sitter --with tree-sitter-swift python
Tests/ExteraPills/verify_swift_syntax.py` passed all 13 Swift sources/tests after
field ownership and lifecycle fixes. Scoped `git diff --check` passed; source
API signatures for weather, storage, proxy, native settings actions, search
placeholder and transition helpers were checked against this repository.

### Expected frames, written before recording

On a permitted Mac simulator, record with `simctl io recordVideo`, then generate
labelled sheets using `tools/animation_sheet.py` as required by root AGENTS.md.
Use an external scratch directory such as `$TMPDIR/extera-pill-stack-acceptance`.
Expected artifact paths below are a recording plan, **not existing recordings**.

- `frame31-editor.mp4`, `frame31-editor-sheet/`: enter settings and tab-menu
  routes, search/clear, show/hide and move upward/downward/across both sections,
  including an empty destination. The section and handles remain coherent,
  rows do not overlap or duplicate, and reopen preserves order and infinite flag.
- `frame18-6-search-switch.mp4`, `frame18-6-search-switch-sheet/`: in actual Chats
  search, swipe up/down through first/last. Old label exits up while next enters
  from below for forward motion; reverse motion reverses direction. Both move
  over 0.2 s with ease-out, without overshoot, gaps, duplicated stationary labels,
  horizontal drift or clipping outside the rounded widget. Infinite wraps exactly
  once; finite boundaries and a single widget remain still. Reduce Motion swaps
  immediately. Search loupe/text remain stationary during widget switching.
- `header-search-lifecycle.mp4`, `header-search-lifecycle-sheet/`: collapse/expand
  header, open/close search, navigate away/back, hide/unhide search preference,
  background/foreground and narrow/rotate layout. Widget follows the field's
  position/fade and does not linger over active search or restart work while
  hidden. The search tap opens Search; widget tap opens its own source/options.
- `source-consent.mp4`, `source-consent-sheet/`: denied/not-determined/allowed
  location, source grant/revoke, bot/URL replacement, target currency and account
  switch. No successful value appears from the wrong account/source; unavailable
  and reason text are visible. Proxy/storage open their native pages.

Run these paths in EN/RU, light/dark, normal/larger text and with/without custom
widgets. Inspect every sheet and flagged gap/jump; report index and ffprobe time
for findings. Until then no visual or animation parity with frame31/18/6 is claimed.

With a controllable HTTP endpoint, verify hidden providers issue no requests;
delay an A completion, switch A → B → A and revoke/navigate/background; replace
URL under the same UUID while search is alive; disable/delete/import during a
request; open/close multiple dashboard/search hosts. No unapproved endpoint may
start and cancelled completions may not update the selected widget. Confirm rates
512 KiB streaming cap, no redirects and errors; verify actual configured weather
bot and location denial. Existing HTTP manual refresh/import/export remain covered
by the README acceptance paths.

These Pill files are now frozen for root integration. Tests, app build and frame
inspection remain required before runtime/visual acceptance. No commit or push
is performed by this agent.
