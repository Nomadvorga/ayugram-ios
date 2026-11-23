# Application bridges — exact scope and remaining plugin work

All 19 inputs are pinned to `Nomadvorga/ayugram-src@a4b6bb472fd657e0f659531dae090e12c02a0aaa`.
The audit covers 40,950 lines using AST only. No supplied plugin was imported or executed.
Neither successful imports nor an IPA build establish functional compatibility.

## Implemented source paths (device/native-test execution unverified)

- `UserConfig`: live read-only `selectedAccount`; `getInstance(index)`,
  `getClientUserId()`, `isClientActivated()`, `getCurrentUser()`. Profile snapshots
  expose only `id`, `first_name`, `last_name`, `username`. Missing profile data fails
  explicitly. No phone, access hash, credentials or native account objects.
- `client_utils`: `get_selected_account`, `get_user_config`, `get_last_fragment`,
  `get_messages_controller`. The returned `BaseFragment` provides
  `getCurrentAccount`, `getDialogId` for supported cloud peer chats, and
  `getContext`/`getParentActivity` as an explicit native context descriptor, not
  an Android Activity. `MessagesController.getChat` resolves only the currently
  visible cloud group/channel and returns bounded `id`/`broadcast`/`megagroup`
  state. Secret/local IDs are not translated. Other client helpers reject with
  `UNSUPPORTED_API`; no empty controllers/results.
- `ui.alert.AlertDialogBuilder`: title/message, up to 32 items, three named
  buttons, cancelable dialogs, and plugin-owned custom view trees. Custom views
  accept the same native `LinearLayout`/`EditText` shims as mounted settings
  surfaces; undeclared options still reject. Returns an owned dialog with
  `dismiss`/`isShowing`. Callbacks receive the same owned dialog and the Android
  button/item index, asynchronously after native dismissal.
- Settings components expose `create_sub_fragment`; the settings screen invokes
  the original callback and renders the returned row list as a pushed native
  sub-page. `EditText.getText().toString()`, `Theme.getColor`,
  `TypedValue.applyDimension`, hints, single-line/min-lines flags, text colours
  and layout margins are host shims, not reimplemented plugin logic.
- Original `on_send_message_hook` callbacks run before outgoing messages are
  enqueued. `CANCEL` suppresses the send; `MODIFY`/`MODIFY_FINAL` replaces the
  mutable `message` or `caption`. Existing UTF-16 entity ranges are remapped
  after the plugin's replacement. Hooks run in priority/registration order.
- `BulletinHelper`: simple/success/error text; explicit screen-owned, accessible
  native overlay, three-second lifetime. Extra Android options reject.
- `AppEvent`: START after plugin activation, RESUME/PAUSE on native active changes,
  STOP on background transition. Every event carries the exact Python load
  generation. No main-thread wait and no Python startup just to observe lifecycle.
- Narrow `NotificationCenter` global account-change observer: only
  `activeAccountChanged`, only an owned `NotificationCenterDelegate` proxy, eight
  observers per plugin. Delivery is asynchronous on the Python queue and carries
  the event id, process-stable account slot and an empty argument array. No other
  notification ids, Android account objects or arbitrary listener subclassing are
  exposed.
- Native `TelegramUI` binding reads real account/context/profile signals and the
  authorized root controller, rejects locked/inactive/stale screens, and revokes
  bridge UI on lock/background/account changes. Slots are process-stable and never
  reassigned to another account; identity checks also reject removed/recreated accounts.
- Providers return typed native state; only the host creates handles. Schemas,
  reference validation and state/response quotas run before presentation commit.
  Failed result validation cancels the native reservation. Four concurrent
  presentations per plugin, sixteen globally. Unload revokes queued native senders.

`NotificationCenter` beyond the global `activeAccountChanged` observer, theme control,
message/request interception, menus, arbitrary Android view subclasses, graphics and
background plugin threads are **not implemented**. The supported view subset is
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

## Source-pinned native iOS routes (four, device unverified)

These routes are host-owned iOS implementations of contracts that were read
statically from the exact pinned sources. They never import, translate or run
the plugin code, GAME_HTML or Android classes. A source hash mismatch fails
closed with `UNSUPPORTED_API` and a blocker instead of enabling the route.

| Plugin | Pinned route | Preserved from source | Honest iOS deviation |
|---|---|---|---|
| `sand_box` | `Integration/AyuSandBoxAdapter.swift` | 32-element palette names/emoji, WATER default, the fixed source 150-wide grid and x1 speed, brush 1–16, empty initial scene, demo/save/load, `.sand` consumes the send | Native UIKit simulation, not the Android WebView/JS game; SVG tiles become native emoji/colour tiles |
| `ball` | `Integration/AyuBallAdapter.swift` | `counter` default true, `X<n>` combo near the ball, 1.6 s combo timeout, source gravity/radius/floor restitution, drag/tap play | Fullscreen native overlay instead of the Android decor overlay; peer avatar and gyroscope tilt are not available on this route |
| `screenshot_privacy` | `Integration/AyuScreenshotPrivacyAdapter.swift` | `capture_mode` automatic/manual, manual “Режим скриншота” toggle | No FLAG_SECURE equivalent: a window shield hides everything before capture; it cannot mask individual names/avatars or delete an already saved screenshot |
| `pull_next_chat` | `Integration/AyuPullNextChatAdapter.swift` | all source settings (`enabled`, source kinds, `target_mode`, target kinds, `strategy`, `muted`, `pinned_skip`, `other_folders`, `mark_unread`) and source texts | Two-finger upward swipe, because one-finger pull belongs to history scrolling; the real root/archive chat list applies the target/strategy/filter settings, while forum-topic rows keep stock Telegram behaviour |

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
| `profile_info` | Real peer/profile requests, image conversion and presentation; PIL/media/threading APIs need safe native services. |
| `pull_next_chat` | Native route implemented as a two-finger swipe into the real chat list. Source target kinds, strategy and muted/pinned/other-folder/manual-unread filters are applied to root and archive dialogs. |
| `quick_stickers` | Sticker sets/media data and send services, input-panel lifecycle and native controls. |
| `sand_box` | Native route implemented as a UIKit automaton. The Android WebView/JS `GAME_HTML` is not executed; palette and gameplay constants follow the source. |
| `screenshot_privacy` | Native route implemented as an honest shield: `capture_mode`, screen-capture observation, manual escape. No FLAG_SECURE, no deletion or sanitizing of an already saved screenshot. |
| `side_panel` | Real account/chat navigation, native side-panel surface, gestures and layout/lifecycle hooks. |
| `spekgram` | Message/TL model coverage, requests, media, lifecycle, menus, file services and native UI components; very broad Android/extera surface must be decomposed, not import-whitelisted. |
| `theme_per_account` | Account-change notification delegate, saved theme/accent management, night-mode policy and explicit theme hook; the new `UserConfig` subset alone does not enable it. |

## Device check for this phase

Remove an older installed **Bridge smoke test** first, then use **Тест моста** to
install bundled version 0.2.0. Enable only after trusting it. In its settings:

1. Verify load count and START/RESUME event; no Telegram message is sent.
2. Tap **Проверить аккаунт и нативный диалог**: verify the displayed selected slot
   and your account user ID, then press **Проверить callback**.
3. Expect one success bulletin after the dialog closes, no duplicate callbacks.
4. Switch account and repeat; IDs must follow the real selected account.
5. Background/foreground then reopen settings: inspect STOP/RESUME. Locking,
   disabling or changing account must remove bridge-owned UI without reviving it.
6. Restart: plugins stay disabled; disabling preserves preferences; deleting this
   synthetic plugin clears only its namespace.

Visual expectation before recording: alert uses native presentation/dismissal;
the next bulletin appears only after dismissal, above the bottom safe area, remains
about three seconds, and disappears without leaving an orphan overlay. No duplicate
overlay, off-screen text or flash during account/lock transitions. No frames have
been recorded or evaluated, and no visual/FPS/runtime acceptance is claimed.
