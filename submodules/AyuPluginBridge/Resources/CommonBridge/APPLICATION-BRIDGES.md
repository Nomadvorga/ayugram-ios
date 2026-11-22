# Application bridges — exact scope and remaining plugin work

All 19 inputs are pinned to `Nomadvorga/ayugram-src@a4b6bb472fd657e0f659531dae090e12c02a0aaa`.
The audit covers 40,950 lines using AST only. No supplied plugin was imported or executed.
Neither successful imports nor an IPA build establish functional compatibility.

## Implemented source paths (device/native-test execution unverified)

- `UserConfig`: live read-only `selectedAccount`; `getInstance(index)`,
  `getClientUserId()`, `isClientActivated()`, `getCurrentUser()`. Profile snapshots
  expose only `id`, `first_name`, `last_name`, `username`. Missing profile data fails
  explicitly. No phone, access hash, credentials or native account objects.
- `client_utils`: `get_selected_account`, `get_user_config`, `get_last_fragment`.
  The returned `BaseFragment` provides `getCurrentAccount`, `getDialogId` for supported
  cloud peer chats, and `getContext`/`getParentActivity` as an explicit native context
  descriptor, not an Android Activity. Secret/local IDs are not translated.
  Other client helpers reject with `UNSUPPORTED_API`; no empty controllers/results.
- Basic `ui.alert.AlertDialogBuilder`: title/message, up to 32 items, three named
  buttons, cancelable dialogs; returns an owned dialog with `dismiss`/`isShowing`.
  Custom views and undeclared options reject. Callbacks receive the same owned
  dialog and the Android button/item index, asynchronously after native dismissal.
- `BulletinHelper`: simple/success/error text; explicit screen-owned, accessible
  native overlay, three-second lifetime. Extra Android options reject.
- `AppEvent`: START after plugin activation, RESUME/PAUSE on native active changes,
  STOP on background transition. Every event carries the exact Python load
  generation. No main-thread wait and no Python startup just to observe lifecycle.
- Native `TelegramUI` binding reads real account/context/profile signals and the
  authorized root controller, rejects locked/inactive/stale screens, and revokes
  bridge UI on lock/background/account changes. Slots are process-stable and never
  reassigned to another account; identity checks also reject removed/recreated accounts.
- Providers return typed native state; only the host creates handles. Schemas,
  reference validation and state/response quotas run before presentation commit.
  Failed result validation cancels the native reservation. Four concurrent
  presentations per plugin, sixteen globally. Unload revokes queued native senders.

`NotificationCenter` observers, theme control, message/request interception, menus,
Android view subclasses, graphics and background plugin threads are **not implemented**.
START is per Python activation, not a fabricated replay of process launch. STOP is
not guaranteed at OS termination. Basic UIKit dialogs/bulletins are iOS equivalents,
not pixel-identical Android widgets. Screen handles refer to the sampled visible
controller/account; they are not unrestricted access to UIKit.

## Per-plugin functional work packages

These are implementation requirements, not enablement promises. Exact missing
classes, SDK symbols, source hashes and hook/event forms remain in `compatibility.json`.
API identifiers are safe audit data; plugin source and configuration are not bundled.

| Plugin | Required native work beyond the common subsets |
|---|---|
| `atmospheric_snow` | Preserve the separate exact-hash, Python-free adapter: 4,237-line inventory, all 15 settings/migrations, lifecycle/reset, surface bindings, separate navbar passes and bounded 12-point overhang. No changes in this phase. |
| `ball` | Message/menu integration plus actual media/camera processing and image/drawing conversion; inspect per-call semantics, not just classes. |
| `fish_audio_integration` | Asynchronous send-message transformation, voice/audio encoding/upload and cancellable HTTP with quotas; do not run its Android threads or forward secrets in diagnostics. |
| `group_mentions` | Group participant resolution, TL/user/message conversion and explicit send-message hook semantics. |
| `local_chat_archive` | History/storage/export APIs, attachment/media decoding and context menus; map Android filesystem paths to user-consented iOS document operations. |
| `md3_loader` | Native drawing/loading surfaces and explicit state-change hooks; cannot transplant Android Canvas/Drawable execution. |
| `message_cleaner` | Real history/deletion requests, cancellation and scoped menus; preserve selection and server permission behavior. |
| `music_bridge` | Cancellable HTTP, media lookup/download/upload, playback services, send hooks and menus; external dependency import is not service support. |
| `music_tab` | Real music-browser/tab/player integration and native navigation/state seams. |
| `passguard` | Explicit private-data/storage and UI lifecycle boundaries, platform security equivalents and media services; Android subclasses/file helpers cannot be silently emulated. |
| `player_below` | Native player/composer placement and lifecycle hooks, gesture and layout ownership, animation acceptance from recorded frames. |
| `profile_info` | Real peer/profile requests, image conversion and presentation; PIL/media/threading APIs need safe native services. |
| `pull_next_chat` | Actual chat-list navigation/gesture state and explicit bounded hooks; avoid altering the existing chat history backend invariants. |
| `quick_stickers` | Sticker sets/media data and send services, input-panel lifecycle and native controls. |
| `sand_box` | Canvas/interaction surface, menus and explicitly named hooks/events; no generic arbitrary Java execution or subclassing. |
| `screenshot_privacy` | Public iOS capture-state/screenshot events and per-screen presentation policy. Android secure-window guarantees have no universal iOS equivalent; cannot promise screenshot blocking. |
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
