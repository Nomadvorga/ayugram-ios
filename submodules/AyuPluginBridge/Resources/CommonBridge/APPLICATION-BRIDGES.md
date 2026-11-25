# Application bridges — exact scope and remaining plugin work

All 19 inputs are pinned to `Nomadvorga/ayugram-src@a4b6bb472fd657e0f659531dae090e12c02a0aaa`;
Premium Dialog Cards 2.1.1 is a separately supplied source with its own SHA-256 pin.
The audit covers 42,600 lines using AST only. No supplied plugin was imported or executed.
Neither successful imports nor an IPA build establish functional compatibility.

## Implemented source paths (device/native-test execution unverified)

- `UserConfig`: live read-only `selectedAccount`; `getInstance(index)`,
  `getClientUserId()`, `isClientActivated()`, `getCurrentUser()`. Profile snapshots
  expose only `id`, `first_name`, `last_name`, `username`. Missing profile data fails
  explicitly. No phone, access hash, credentials or native account objects.
- `client_utils`: `get_selected_account`, `get_user_config`, `get_last_fragment`,
  `get_messages_controller`, `get_account_instance`. `AccountInstance` provides
  `getInstance(index)`, `getCurrentAccount()`, `getUserConfig()` and
  `getMessagesController()`; child handles retain the requested account identity,
  including after switching the selected account, and expire on account removal
  or replacement. The returned `BaseFragment` provides
  `getCurrentAccount`, `getDialogId` for supported cloud peer chats, and
  `getContext`/`getParentActivity` as an explicit native context descriptor, not
  an Android Activity. It also supplies `getAccountInstance`, `getUserConfig` and
  `getMessagesController`, after checking the visible screen identity.
  `MessagesController.getInstance(index)` and `getUser(id)` expose only the active
  account's own public profile; other user ids return a cache miss (`null`).
  `MessagesController.getChat` resolves only the currently
  visible cloud group/channel and returns bounded `id`/`broadcast`/`megagroup`
  state. Secret/local IDs are not translated. Other client helpers reject with
  `UNSUPPORTED_API`; no empty controllers/results.
- `ui.alert.AlertDialogBuilder`: title/message, up to 32 items, three named
  buttons and cancelable dialogs. Returns an owned dialog with `dismiss` and
  `isShowing`. Callbacks receive the same owned dialog and the Android
  button/item index, asynchronously after native dismissal. Custom Android views,
  progress/spinner dialogs and Android resource providers reject explicitly.
- Settings components expose `create_sub_fragment`; the settings screen invokes
  the original callback and renders the returned row list as a pushed native
  sub-page. `EditText.getText().toString()`, `Theme.getColor`,
  `TypedValue.applyDimension`, hints, single-line/min-lines flags, text colours
  and layout margins are host shims, not reimplemented plugin logic.
- The virtual view tree supports a bounded `android.view.Gravity` subset for
  `TextView.setGravity` and `LinearLayout.setGravity`: horizontal left/right,
  start/end, center, and vertical top/center/bottom. `LinearLayout` aligns the
  child group on its main axis and children on the cross axis. Fill/clip flags,
  per-child gravity and scrollable backing remain unsupported. Relative start/end
  follow the native view's layout direction. `EditText` supports horizontal
  gravity and center/unspecified vertical gravity.
- `View.setBackground` accepts an owned `ColorDrawable`, a solid rectangle/oval
  `GradientDrawable` with one corner radius and optional uniform stroke, or
  `null`, mapped to UIKit background/layer styling. Gradients, per-corner
  radii, ripple/layer/resource/image drawables and Android Canvas rendering
  remain unsupported.
- `LinearLayout.LayoutParams` accepts bounded width/height and an optional
  nonnegative weight. Positive weights divide only the remaining main-axis space
  after base child sizes and margins; this is not full Android measurement parity.
- `ScrollView` accepts one direct child and uses a native vertical `UIScrollView`
  with bounded content-size calculation. Horizontal scrolling, nested scrolling,
  fling physics and Android scroll callbacks are unsupported.
- `Bundle` and `Intent` provide bounded owner-scoped Java value objects only;
  no Android activity launch or system intent interception is performed.
  `MotionEvent` constructors provide bounded synthetic snapshots, not live UIKit
  touch objects. `Handler.post`/`postDelayed` dispatch declared callbacks through
  the generation-revocable host callback path; Android Loopers, queue selection
  and callback cancellation are not implemented.
- `Context.getResources().getDisplayMetrics()` snapshots the explicit presentation
  window's display scale and dimensions as read-only `density`, `densityDpi`,
  `widthPixels`, `heightPixels`. Density uses 160 Android dpi per iOS display scale;
  it is a compatibility conversion, not the panel's physical dpi. `TypedValue`
  supports PX and DIP only, requires an owned metrics handle from a still-visible
  screen, and scales DIP using that snapshot. No Android font-scale emulation.
- `AndroidUtilities.runOnUIThread(Runnable[, delayMs])` accepts the owned
  `java.lang.Runnable` proxy and an optional 0–60,000 ms delay. It schedules a
  one-shot, generation-revocable callback onto the serial Python queue; it does
  not execute plugin Python on UIKit's main thread. `cancelRunOnUIThread` and
  arbitrary Android queue/Looper semantics remain unsupported.
- `Resources.getConfiguration()` returns an owner-held, read-only
  `Configuration.orientation` snapshot derived from the bound scene's interface
  orientation. Only `ORIENTATION_UNDEFINED`, `ORIENTATION_PORTRAIT`, and
  `ORIENTATION_LANDSCAPE` are exposed; stale screen snapshots and writes reject.
- `Theme.getColor` accepts exactly the 16 declared, one-based keys and returns
  signed Android ARGB values from an explicit UIKit semantic-color mapping;
  `isDarkThemeEnabled` reads the authorized presenter's traits on main. Both fail
  when no visible presentation context is bound. This is the iOS system-color
  subset, not Telegram theme/accent management; the last declared key is valid and
  zero/unknown keys reject.
- Original `on_send_message_hook` callbacks run before outgoing messages are
  enqueued. `CANCEL` suppresses the send; `MODIFY`/`MODIFY_FINAL` replaces the
  mutable `message` or `caption`. Existing UTF-16 entity ranges are remapped
  after the plugin's replacement. Hooks run in priority/registration order.
  Registration reserves quota before returning a token (16 per plugin, 256
  globally, including pending results); failed result validation rolls back the
  reservation and unload revokes pending commits.
- `BulletinHelper`: simple/success/error text, copy feedback, and a bounded
  text-button bulletin with one-shot callback and 1–10,000 ms lifetime; explicit
  screen-owned, accessible native overlays. `show_copied_to_clipboard` displays
  feedback only and does not access the clipboard. Android icons and undo
  semantics remain unsupported.
- `android_utils.copy_to_clipboard(text)`: writes a bounded UTF-8 string to the
  iOS pasteboard only while the captured account/screen is still visible, then
  presents native copied-to-clipboard feedback. Values over 65,536 bytes and
  calls without a visible screen reject. This is a clipboard write, not an
  Android clipboard-manager or clipboard-read API.
- `BasePlugin.add_menu_item` for `MESSAGE_CONTEXT_MENU`: bounded native rows
  appear in the chat message context menu. Existing Telegram rows are published
  immediately; plugin rows are appended after asynchronous Python conditions
  finish, only while that same chat/menu remains current. Conditions receive
  only the current account slot, dialog id and message id; click callbacks
  receive the same values. Rows are ordered by priority then registration order
  and capped at 16 visible items (32 condition evaluations per query, 4 concurrent Python
  evaluations, 16 rows per plugin and 256 registrations total). A fixed set of
  Android icon names maps to SF Symbols. `subtext`, long-click callbacks,
  Android MVEL condition strings, Java message/fragment objects and the other
  menu types are explicitly unsupported. Tokens are owner/generation checked
  and revoked on unregister, disable or unload.
- `AppEvent`: START after plugin activation, RESUME/PAUSE on native active changes,
  STOP on background transition. Every event carries the exact Python load
  generation. No main-thread wait and no Python startup just to observe lifecycle.
- Narrow `NotificationCenter` global account-change observer: only
  `activeAccountChanged`, only an owned `NotificationCenterDelegate` proxy, eight
  observers per plugin. Delivery is asynchronous on the Python queue and carries
  the event id, process-stable account slot and an empty argument array. No other
  notification ids, Android account objects or arbitrary listener subclassing are
  exposed.
  `get_notification_center(account=None)` accepts the SDK's default argument and
  returns this global center; a concrete account still rejects because account-
  scoped notification streams have no native binding.
- Native `TelegramUI` binding reads real account/context/profile signals and the
  authorized root controller, rejects locked/inactive/stale screens, and revokes
  bridge UI on lock/background/account changes. Slots are process-stable and never
  reassigned to another account; identity checks also reject removed/recreated accounts.
- Providers return typed native state; only the host creates handles. Schemas,
  reference validation and state/response quotas run before presentation commit.
  Failed result validation cancels the native reservation. Four concurrent
  presentations per plugin, sixteen globally. Unload revokes queued native senders.

`NotificationCenter` beyond the global `activeAccountChanged` observer, theme control,
message/request interception, other menu types, arbitrary Android view subclasses,
graphics and background plugin threads are **not implemented**. The supported view subset is
`View`, `FrameLayout`, `LinearLayout`, `TextView`, `EditText` and `ImageView`.
START is per Python activation, not a fabricated replay of process launch. STOP is
not guaranteed at OS termination. Basic UIKit dialogs/bulletins are iOS equivalents,
not pixel-identical Android widgets. Screen handles refer to the sampled visible
controller/account; they are not unrestricted access to UIKit.

## Group Mentions bridge route (device unverified)

`group_mentions` is deliberately **not** in `AyuNativePluginCatalog`. Its pinned
original source runs through the Python bridge, so `create_settings`,
`_build_settings_page`, `_show_info_dialog`, `_show_group_dialog`,
`_resolve_chat_type` and `on_send_message_hook` are the plugin's own code. The host
only supplies the Android/Telegram shims listed above. The observable contract is
the source's 5 groups / 7 usernames, username validation, case/chat-type switches,
60-second per-chat cooldown, and one-pass mention expansion. Channels are skipped as
in the source. Normal cooldown feedback uses the adapted `BulletinFactory`; the
`android_utils.get_context`, `Toast.makeText().show()` and
`ApplicationLoader.applicationContext` are bounded host shims: the context is the
visible fragment descriptor, never an Android Application copy, and a Toast becomes a
native bulletin. No device, visual, FPS or runtime acceptance is claimed.

The legacy `AyuGroupMentionsAdapter.swift` file remains in the tree but is not
referenced by the native catalog or by the send path. It must not be expanded; the
bridge route is authoritative for this plugin.

## Source-pinned native iOS routes (six including Atmospheric Snow, device unverified)

These routes are host-owned iOS implementations of contracts that were read
statically from the exact pinned sources. They never import or run plugin Python
or Android classes; SandBox alone renders the pinned source's own `GAME_HTML`
in a `WKWebView`, as Android does. A source hash mismatch fails
closed with `UNSUPPORTED_API` and a blocker instead of enabling the route.

| Plugin | Pinned route | Preserved from source | Honest iOS deviation |
|---|---|---|---|
| `sand_box` | `Integration/AyuSandBoxAdapter.swift` | 32-element palette names/emoji, WATER default, the fixed source 150-wide grid and x1 speed, brush 1–16, empty initial scene, demo/save/load, `.sand` consumes the send | The pinned source's own `GAME_HTML` runs unchanged in a full-screen `WKWebView` with the same base URL and polling; iOS replaces the Android WebView and settings screen |
| `ball` | `Integration/AyuBallAdapter.swift` | `counter` default true, `X<n>` combo near the ball, 1.6 s combo timeout, source gravity/radius/floor restitution, drag/tap play | Fullscreen native overlay instead of the Android decor overlay; peer avatar and gyroscope tilt are not available on this route |
| `screenshot_privacy` | `Integration/AyuScreenshotPrivacyAdapter.swift` | `capture_mode` automatic/manual, manual “Режим скриншота” toggle | No FLAG_SECURE equivalent: a window shield hides everything before capture; it cannot mask individual names/avatars or delete an already saved screenshot |
| `pull_next_chat` | `Integration/AyuPullNextChatAdapter.swift` | all source settings (`enabled`, source kinds, `target_mode`, target kinds, `strategy`, `muted`, `pinned_skip`, `other_folders`, `mark_unread`) and source texts | One-finger pull up at the newest message reuses Telegram's stock next-chat overscroll pill; the real root/archive chat list applies target/strategy/filter settings, channels keep stock behaviour, and forum topics stay stock |
| `premium_dialog_cards` | `Integration/AyuPremiumDialogCardsAdapter.swift` | all 11 `rcards.*` settings unchanged (enable, rounding 0–30, blur 1–25, darken 55 %, stroke 0.5 dp/24 %, muted dim/opacity/stroke, online badge/border), 6/5 pt card margins, 90 px blurred avatar, dark tint, vertical white stroke gradient, Saved Messages and Telegram-service gradients, dark theme only | Chat rows draw the card with native `UIView`/`CALayer` and a cached Core Image blur; the source's 0.75 avatar scale is not reproduced because it would relayout the real row. No Android Canvas and no plugin Python |

Atmospheric Snow remains on its separate exact-hash route and was not changed:
4,237 lines, all 15 settings/migrations, lifecycle/reset, surface bindings,
navbar passes and the bounded 12-point overhang.

## Per-plugin functional work packages

These are implementation requirements, not enablement promises. Exact missing
classes, SDK symbols, source hashes and hook/event forms remain in `compatibility.json`.
API identifiers are safe audit data; plugin source and configuration are not bundled.

| Plugin | Required native work beyond the common subsets |
|---|---|
| `atmospheric_snow` | Preserve the separate exact-hash, Python-free adapter: 4,237-line inventory, all 15 settings/migrations, lifecycle/reset, surface bindings, separate navbar passes and bounded 12-point overhang. No changes in this phase. |
| `ball` | Native route implemented (combo counter, source physics, drag/tap). Remaining Android-specific gap: peer avatar as the ball and gyroscope tilt. |
| `fish_audio_integration` | Asynchronous send-message transformation, voice/audio encoding/upload and cancellable HTTP with quotas; do not run its Android threads or forward secrets in diagnostics. |
| `group_mentions` | Bridge route: run the original source through the Python host shims (settings sub-page, custom-view group editor, chat lookup, send hook). Do not expand the frozen native adapter file. |
| `local_chat_archive` | History/storage/export APIs, attachment/media decoding and context menus; map Android filesystem paths to user-consented iOS document operations. |
| `md3_loader` | Native drawing/loading surfaces and explicit state-change hooks; cannot transplant Android Canvas/Drawable execution. |
| `message_cleaner` | Real history/deletion requests, cancellation and scoped menus; preserve selection and server permission behavior. |
| `music_bridge` | Cancellable HTTP, media lookup/download/upload, playback services, send hooks and menus; external dependency import is not service support. |
| `music_tab` | Real music-browser/tab/player integration and native navigation/state seams. |
| `passguard` | Explicit private-data/storage and UI lifecycle boundaries, platform security equivalents and media services; Android subclasses/file helpers cannot be silently emulated. |
| `player_below` | Native player/composer placement and lifecycle hooks, gesture and layout ownership, animation acceptance from recorded frames. |
| `premium_dialog_cards` | Native chat-list route implemented: 6/5 pt card geometry, configurable rounding, 90 px blurred avatar with dark tint, vertical stroke gradient, muted and online overlays, Saved Messages/service gradients, and all 11 source settings. Remaining honest gap: the source's 0.75 avatar scale and Android Canvas painting; no device/FPS acceptance. |
| `profile_info` | Real peer/profile requests, image conversion and presentation; PIL/media/threading APIs need safe native services. |
| `pull_next_chat` | Native route implemented with one finger at the newest message, using Telegram's stock overscroll control outside channels. Source target kinds, strategy and muted/pinned/other-folder/manual-unread filters are applied to root and archive dialogs. |
| `quick_stickers` | Sticker sets/media data and send services, input-panel lifecycle and native controls. |
| `sand_box` | Native route implemented as the pinned source's `GAME_HTML` in a full-screen `WKWebView`; palette and gameplay constants come from the source unchanged. |
| `screenshot_privacy` | Native route implemented as an honest shield: `capture_mode`, screen-capture observation, manual escape. No FLAG_SECURE, no deletion or sanitizing of an already saved screenshot. |
| `side_panel` | Real account/chat navigation, native side-panel surface, gestures and layout/lifecycle hooks. |
| `spekgram` | Message/TL model coverage, requests, media, lifecycle, menus, file services and native UI components; very broad Android/extera surface must be decomposed, not import-whitelisted. |
| `theme_per_account` | Account-change notification delegate, saved theme/accent management, night-mode policy and explicit theme hook; the new `UserConfig` subset alone does not enable it. |

## Device check for this phase

**Импортировать .plugin** recognizes these audited sources before the general
Python preflight:

1. `atmospheric_snow.plugin` — NewYear Interface (native, Python-free).
2. `ball.plugin` — Ball (native).
3. `premium_dialog_cards.plugin` — Premium Dialog Cards (native chat-list route).
4. `pull_next_chat.plugin` — Pull to Next Chat (native).
5. `sand_box.plugin` — SandBox (native, WKWebView runs the audited `GAME_HTML`).
6. `screenshot_privacy.plugin` — Screenshot Privacy (native shield).
7. `group_mentions.plugin` — Group Mentions (known Python source).

Other sources are inspected on the Python worker without executing their code.
Valid records can be imported disabled with explicit blockers for unavailable
imports, SDK members, native classes, requirements, declared operations or
unimplemented version policy. A clean preflight is not proof of compatibility:
dynamic API usage is checked at runtime. A mismatched source claiming a native
adapter's ID remains blocked. Enabling Python requires explicit trust because
it runs with application privileges, not in a security sandbox.

For the native and general routes:

1. Import and enable; the app inspects the stored bytes again. Native adapters
   require their exact source hashes and never start Python.
2. Native routes show their iOS adapter settings. General Python starts lazily
   for preflight, but plugin code runs only after explicit enable and host authorization.
3. Import a source with a missing API and verify its blockers without executing it.
   Test load failure, disable and re-enable for callback and generation cleanup.
4. Switch account and background/foreground: native surfaces and Python
   callbacks must follow the real selected account and must stop cleanly.
5. Restart: plugins stay disabled; restoring metadata does not start Python;
   enabling repeats validation. Disabling preserves preferences; deleting a
   plugin clears only its namespace.

No device run, plugin runtime run, frame recording, visual acceptance or FPS
measurement has been performed. Build success proves compilation only.
