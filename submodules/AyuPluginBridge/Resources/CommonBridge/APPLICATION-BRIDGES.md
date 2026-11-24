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
| `pull_next_chat` | Native route implemented with one finger at the newest message, using Telegram's stock overscroll control outside channels. Source target kinds, strategy and muted/pinned/other-folder/manual-unread filters are applied to root and archive dialogs. |
| `quick_stickers` | Sticker sets/media data and send services, input-panel lifecycle and native controls. |
| `sand_box` | Native route implemented as the pinned source's `GAME_HTML` in a full-screen `WKWebView`; palette and gameplay constants come from the source unchanged. |
| `screenshot_privacy` | Native route implemented as an honest shield: `capture_mode`, screen-capture observation, manual escape. No FLAG_SECURE, no deletion or sanitizing of an already saved screenshot. |
| `side_panel` | Real account/chat navigation, native side-panel surface, gestures and layout/lifecycle hooks. |
| `spekgram` | Message/TL model coverage, requests, media, lifecycle, menus, file services and native UI components; very broad Android/extera surface must be decomposed, not import-whitelisted. |
| `theme_per_account` | Account-change notification delegate, saved theme/accent management, night-mode policy and explicit theme hook; the new `UserConfig` subset alone does not enable it. |

## Device check for this phase

This build has no general `.plugin` runtime. **Импортировать проверенный .plugin**
accepts only these pinned sources:

1. `atmospheric_snow.plugin` — NewYear Interface (native, Python-free).
2. `ball.plugin` — Ball (native).
3. `pull_next_chat.plugin` — Pull to Next Chat (native).
4. `sand_box.plugin` — SandBox (native, WKWebView runs the audited `GAME_HTML`).
5. `screenshot_privacy.plugin` — Screenshot Privacy (native shield).
6. `group_mentions.plugin` — Group Mentions (the only pinned Python source).

Any other file must fail with the supported-plugin message before it is written
or executed. Previously installed unsupported plugins stay visible only so they
can be deleted; they cannot be enabled.

For the supported routes:

1. Import the exact source and enable it; the app rechecks its SHA-256.
2. Native routes show settings implemented by their iOS adapters. Group Mentions
   starts Python lazily only for its pinned source.
3. Switch account and background/foreground: native surfaces and Group Mentions
   callbacks must follow the real selected account and must stop cleanly.
4. Restart: plugins stay disabled; disabling preserves preferences; deleting a
   plugin clears only its namespace.

No device run, plugin runtime run, frame recording, visual acceptance or FPS
measurement has been performed. Build success proves compilation only.
