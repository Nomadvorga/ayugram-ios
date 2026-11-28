# Telegram backend for the plugin bridge

Status: a real backend exists for the 14 `telegram.*` operations and the 5 `telegram.action.*` state changes.
Account-scoped notification events (`NotificationCenter.getInstance(account)`) have no operation yet. Nothing here was run on a device or in a
linked app; what was executed and what was only type-checked is listed under *Verification*. The app declares an
operation only while `AyuPluginTelegramAdapter` lists it.

| Operation | State |
|---|---|
| `telegram.request`, `telegram.request.cancel`, `telegram.connection` | served |
| `telegram.send_message`, `telegram.edit_message` | served; keys the send queue cannot honour are refused by name |
| `telegram.peer`, `telegram.messages` | served from the local store (lossy, see *What the rebuilt TL lacks*) |
| `telegram.dialogs` | served from the local chat list (see below); type-checked only |
| `telegram.files.path`, `telegram.files.load` | served for `Message`, `Document`, `Photo`; `PhotoSize`/`VideoSize` are `UNSUPPORTED_API` |
| `telegram.screen` | served from the binding's screen snapshot |
| `telegram.hooks.send_message` | served for messages sent from the chat screen |
| `telegram.navigation.open` | served through a closure the application binding injects |
| `telegram.hooks.set` | served: main-session requests and responses, pushed containers, their updates, difference `other_updates` (see *Request and update hooks*); type-checked only |
| `telegram.player` | served through a closure the application binding injects over the shared media player; type-checked only |
| `telegram.action.delete_messages`, `.read_dialog`, `.read_all_dialogs`, `.process_updates`, `.store_peers`, `.load_full_peer`, `.add_dialogs_to_folder` | served through the engine call of the same user action (`TelegramCore/Sources/AyuPlugins/AyuPluginActions.swift`); type-checked only |

## Layers

- **Bridge** (`Integration/AyuPluginTelegram{Backend,Bridge,Hooks}.swift`). Closed-argument validation, account
  slots, TL size bounds, the refusal table, request ids, quotas, per-generation cleanup, callback delivery, hook
  chains. It never sees a Telegram type.
- **Backend decisions** (`Integration/AyuPluginTelegramBackendSupport.swift`, same module, so they are executed by
  `Tests/Swift/AyuPluginTelegramBackendSupportTests.swift`). `AyuPluginTelegramDialog` (which peer an Android dialog
  id names; encrypted-chat and folder ids are refused), `AyuPluginTelegramSendPlan` and `AyuPluginTelegramEditPlan`
  (what a send or an edit asks for, or the refusal), the Android connection state.
- **TelegramCore** (`submodules/TelegramCore/Sources/AyuPlugins/`, the only code that imports TelegramApi, and no
  dependency on this module). A `Data`-based public surface: `ayuPluginSendRawRequest`, `ayuPluginEnqueueMessage`,
  `ayuPluginRequestEditMessage`, `ayuPluginPeerTL`, `ayuPluginMessagesTL`, `ayuPluginFilePath`,
  `ayuPluginLoadFile`/`ayuPluginCancelFileLoad`, `ayuPluginDescribeOutgoingMessages`/`ayuPluginApplySendHook`,
  `ayuPluginCachedPeer`, `ayuPluginSetHookInterceptor`. `AyuPluginTLBuilders.swift` builds every TL object through
  the generated `Api` constructors and computes each flag word from the values that are present (the serializer
  aborts the process on a flag bit without its value); `AyuPluginTLFromPostbox.swift` only maps stored models to
  the builders' plain values. `submodules/TelegramApi/Sources/RawFunction.swift` adds the one lookup the generated
  module lacked: a function of the layer by constructor id.
- **Adapter** (`submodules/AyuPluginTelegramAdapter`, depends on TelegramCore, SwiftSignalKit and this module; no
  Postbox import or `.postbox` access). `AyuPluginTelegramAdapter` conforms to `AyuPluginTelegramBackend`, maps slots
  to `Account`s and forwards; `AyuPluginLocalMedia` prepares a local file (ImageIO, AVFoundation).
- **App wiring** (`TelegramUI/Sources/AyuPluginApplicationBinding.swift`, `ChatController.swift`). The binding
  registers accounts with the adapter before it publishes them to the bridge, binds the adapter, fills
  `AyuPluginScreenSnapshot.telegram`, and injects the navigator. `ChatControllerImpl.sendMessages` asks
  `AyuPluginTelegramAdapter.shared.hasSendMessageHooks` and routes the batch through `applySendHooks`.

Threading: backend methods are called on the bridge's host worker and return at once. File preparation runs on the
adapter's own queue, Postbox work in transactions, file copies on a concurrent queue, UI on main. For everything
except `sendRequest` the worker waits 5 s and then reports `timeout`; a completion after that is ignored, so an
action that completes late still happens.

## What each operation does

**`telegram.request`.** The bytes are sent unchanged through the account's main session
(`NetworkEngineRequest` on `network.requestService`), with the same log and telemetry metadata as a generated
builder. The constructor must be a function of the layer (`invalid_arguments` otherwise, which also stops ids of
other layers); the arguments are not decoded. Besides the bridge's table, TelegramCore refuses by name every
`auth.*` and `invokeWith*` function, the wrappers and the four account functions, so a function a later layer adds
to `auth.` is refused without a table update. `RequestFlagFailOnServerErrors` ends the request on a server error
or a flood wait; without it both are retried, as Android does. A response whose function returns `Updates` is
handed to `AccountStateManager.addUpdates` before the callback (decided by the function's result type in the
schema table, then `Api.parse`); no other per-function handling is reproduced (`messages.affectedMessages` pts,
...), so such requests leave the state to the next difference. A session that is gone reports transport failure
`SESSION_CLOSED`; a dropped connection does not fail a request, the engine resends it.

Ghost mode applies to plugin requests by function name with the global setting: a function it suppresses
(read receipts, typing, story views, sponsored messages) completes with RPC error `400 AYU_GHOST_DROPPED`, as it
fails for the app's own callers. Per-chat exclusions are not consulted, because they need the decoded arguments.

**`telegram.connection`.** `Network.globalTime`, `globalTimeDifference`, `datacenterId` and the first value of
`Account.networkState` (which includes "fetching missed updates" as Android's `updating`).

**`telegram.send_message`.** `enqueueMessages`, exactly as the chat screen sends. Honoured keys
(`AyuPluginTelegramSendPlan.supportedParameters`): `peer`, `message`, `caption`, `entities`, `replyToMsg` (also a
message of another chat), `replyToTopMsg`, `notify`, `scheduleDate`, `scheduleRepeatPeriod`, `searchLinks`,
`invert_media`, `effect_id`, `hasMediaSpoilers`, `sendingHighQuality`, `path` + `attach`, `document`, `photo`.
Refused by name: `ttl`, `quick_reply_shortcut_id`, `monoForumPeer`, `payStars`, `stars`, `dice_stake`,
`updateStickersOrder`, `params`, `location`, `poll`, `game`, `invoice`, `mediaWebPage`, `webPage`, `replyMarkup`,
`user`, `todo`, `cover`, `richMessage`. Contradictory requests are `invalid_arguments`, not guessed: `message`
with an attachment, `caption` without one, an empty text message, `hasMediaSpoilers` without a photo or video,
`scheduleRepeatPeriod` without a date, entities outside the text or of a type the app does not send.

A local file is copied into the media store before the call returns (an APFS clone), so the plugin may delete it.
Photo: decoded with ImageIO, oriented, scaled to 1280 px (2560 with `sendingHighQuality`), JPEG. Video: dimensions
and duration from AVFoundation, a 320 px thumbnail, no streaming flag. Audio: duration, title and performer.
Document: MIME type from the extension. A `document` sent with `path` supplies MIME type and attributes instead.
A `document`/`photo` without `path` is sent as an existing file and fails later if its file reference expired
(there is no message to refresh it from).

Plugin-sent messages do **not** pass the send-message hooks (Android runs them): the hook answers need the Python
thread that is blocked in this very call.

**`telegram.edit_message`.** The chat screen's rules for "Edit" are ported (`ayuPluginCanEditMessage`, including
the time limit); then `requestEditMessage` is started and the call returns. `params` and a spoiler on a replaced
attachment are refused by name.

**`telegram.peer`, `telegram.messages`.** One Postbox transaction, no request. A negative dialog id, or a `chat`
id, names the channel with that id if it is cached, else the basic group. A service message is `null` in the
result of `telegram.messages` (`messageService` and its actions are not rebuilt); it is never returned as a wrong
object.

**`telegram.dialogs`.** One Postbox transaction, no request (`ayuPluginDialogsTL`): the top 2,000 entries of the
main list and of the archive, cut to the 2,000 pinned and most recent dialogs. A `dialog` carries the peer, the
pinned and marked-unread bits, the newest cloud message id, the cloud read state (read maxima, unread count), the
unseen mention, reaction and poll-vote counts, the notify settings (`mute_until`, `show_previews`), a channel's
`pts` and `folder_id` 1 in the archive. Not rebuilt: `draft`, `ttl_period`, `view_forum_as_messages`; a forum's
`unread_count` is what the store keeps for the channel itself, not the sum of its topics. The archive's
`dialogFolder` has the fixed title "Archived Chats" (Android's is localized), the peer and top message of its
newest dialog, and unread counters summed over the listed archived dialogs, where a dialog with default
notification settings counts as unmuted. A promoted chat that is not in the chat list is not listed (Android puts
it first). Secret chats are left out.

**`telegram.player`.** `AyuPluginApplicationBinding.installPluginPlayer` reads
`mediaManager.globalMediaPlayerState` (voice messages and music) on main, issues `playlistControl` (`stop` clears
the playlist of the active player type; `seek` multiplies the progress by the duration) and answers with the
first state that shows the action, or the state after one second. The playing item is rebuilt with
`ayuPluginMessageTL`; an item that is not a cloud message (Instant View audio, saved music), or a player that is
switching items, is reported as nothing loaded. The position is extrapolated from the status timestamp while
playing.

**`telegram.action.*`.** `deleteMessagesInteractively` (for everyone in channels, or with `revoke`),
`applyMaxReadIndexInteractively` at the stored message's index, `stateManager.addUpdates`, `updatePeers` with
`AccumulatedPeers` (the app's min and access-hash rules), `fetchAndUpdateCachedPeerData`. Ghost mode therefore
suppresses the read request of `read_dialog` exactly as it does for the chat screen.

**`telegram.files.*`.** The target is parsed with the app's own converters, so the resource id is the one the app
uses: the path is `mediaBox.completedResourcePath` or, before the download ends, the store's path for the complete
file (no file there, no extension ever). `load` starts `fetchedMediaResource` with a message reference when the
target or `parent` is a stored message; at most 64 plugin downloads run at once; `cancel` stops only a download a
plugin started. `priority`, `cache_type` and `cache` have no counterpart.

**`telegram.screen`.** `chat` (dialog id, topic id of a thread, mode 1 scheduled / 2 pinned / 0 otherwise),
`profile`, `dialogs`, `other`. Secret chats and custom chat contents are `other`. Modes 3 (saved) and 5 (quick
replies) are not detected.

**`telegram.navigation.open`.** Only on the account whose root is visible, unlocked and active
(`screen_unavailable` otherwise). A dialog must be cached. A username returns at once; it is resolved by
`engine.peers.resolvePeerByName`, and an unknown name shows the app's "not found" text.

**`telegram.hooks.send_message`.** `ayuPluginDescribeOutgoingMessages` turns each queued `EnqueueMessage` into the
hook value (entities, reply and thread messages as TL when stored, local path or the existing document/photo,
silent, schedule, link preview, invert, effect, spoiler); the bridge runs the typed and the three-field hooks as
one chain; `ayuPluginApplySendHook` writes back what changed. Mutable fields: `message`, `caption`, `entities`,
`replyToMsg` (a message of the same chat, or none), `notify`, `scheduleDate`, `scheduleRepeatPeriod`,
`searchLinks`, `invert_media`, `effect_id`, `hasMediaSpoilers`; a changed `peer` or `replyToTopMsg` discards that
plugin's result in the bridge. Differences from the contract: forwards, messages sent by plugins, by other screens
(share sheet, quick replies) and chats without an Android dialog id (secret chats) are not shown; a cancelling
hook drops the whole batch, as before; a final result whose entities are invalid is discarded as a whole (with
several plugins that loses every plugin's change to that message); entities a plugin returned unchanged with a
text they no longer fit are moved across the changed span instead.

## What the rebuilt TL lacks

The stored models keep less than the server sent. Fields without a stored value are absent; in particular:

- `User`: `bot_info_version` is 0 for a bot (mandatory, not stored); `deleted` is "no bot info and no name"; `status`
  splits the one stored "present until" into online/offline by the local clock; `lang_code`, `stories_max_id`,
  `send_paid_messages_stars`, `apply_min_photo`, `attach_menu_enabled` are never set; a collectible emoji status or
  name colour becomes the plain one.
- `Chat`: a removed group is `chatForbidden`, a banned channel `channelForbidden` (when its access hash is stored).
  In banned rights the app stores only the granular bits; `send_messages` and `send_media` are set when every right
  they cover is banned. `participants_count` of a channel, `stories_max_id` and `pinned_msg_id` are absent.
- `Message`: text, entities, ids, dates, flags (`out`, `mentioned`, `media_unread`, `silent`, `post`,
  `from_scheduled`, `edit_hide`, `pinned`, `noforwards`, `invert_media`), forward and reply headers (with quote),
  via-bot, counters, edit date, signature, group id, TTL, effect. Media: `messageMediaPhoto`,
  `messageMediaDocument` (documents and photos have date 0); a link preview is `messageMediaWebPage` with
  `webPageEmpty`; everything else (poll, geo, contact, dice, game, invoice, story, ...) is
  `messageMediaUnsupported`. Never rebuilt: `reply_markup`, `reactions`, `replies`, `saved_peer_id`, fact checks,
  `from_id` of a channel post. `from_id` is always set otherwise, also in private chats.
- `UserFull`, `ChatFull`: about, counters, pins, call and schedule flags, notify settings (mute and previews),
  peer settings bars, photos, group participants (`chatParticipantsForbidden` when not cached), channel read
  markers, unread count and pts from the dialog state. `bot_info`, invites, reactions, stickersets, wallpapers,
  business and star fields are absent; `channelFull.chat_photo` is `photoEmpty` when not cached.

## Request and update hooks (`telegram.hooks.set`)

The adapter turns the bridge's filter into an `AyuPluginHookInterceptor` (`ayuPluginSetHookInterceptor`) and maps
networks and account peer ids to slots. While no plugin hooks anything every hook point costs one unfair-lock read
(`ayuPluginHookState`). Every wait is asynchronous: no engine, state or main queue is held, and the bridge bounds
each answer at 2 s.

- **Requests and responses** (`AyuPluginHookedRequestService`, installed as `Network.requestService`): the
  request service of the main session, so `Network.request`, `requestWithAdditionalInfo` and plugin requests pass
  one point, after the Ghost filter. A hooked request is rebuilt with the accepted payload; its `parse` keeps the
  raw response next to the caller's parsed value, and the response hook's result goes through the caller's own
  parser again (an answer it cannot parse is ignored). An app request accepts a replacement with the same
  constructor or the same result type, a plugin request any sendable function; a replacement by a function Ghost
  mode suppresses ends with `400 AYU_GHOST_DROPPED`. Functions `ayuPluginRefusesFunction` names are never shown.
  Requests with a dependency tag keep their order through an `AyuPluginOrderedGate`. A cancelled app request is
  never answered (Android's behaviour); its subscriber stays until it is disposed. Not hooked: the six
  `NetworkEngineRequest` constructions of `Download.swift` (file parts, other datacenters).
- **Containers and updates** (`ayuPluginDefersUpdates` at the top of `UpdateMessageService.addUpdates`): pushed
  containers and `Updates` responses, behind a per-account gate so a waiting container is not overtaken. The
  listed updates of one container are asked about concurrently. A cancelled update that carries pts is replaced
  by `updateDeleteMessages`/`updateDeleteChannelMessages` with no ids and the same pts; one with qts is kept; a
  replacement must have the same sequence.
- **Differences**: `other_updates` of `updates.getDifference` (`finalStateWithDifference`) and of
  `updates.getChannelDifference` (`pollChannel`) pass `ayuPluginHookedDifferenceUpdates` before they are applied.

Risks that only a device run can settle: hooks on hot functions (`messages.getHistory`, `updates.getDifference`)
add a Python round trip to each call; a plugin that never answers costs 2 s per hooked event, and for update
containers that delay holds the account's later containers; `Network`'s telemetry sees the rebuilt request, not
the original one.

Unchanged limits of the transport: an event waits at most 2 s per plugin; a response and an error cannot both be
cleared (the error wins). A request carries the contract's 1 MiB of TL and a request or hook callback its 4 MiB;
a dispatch result and a hook answer carry about 767 KiB (`protocol-telegram.md`, "TL values"). Callbacks pass a
bounded per-plugin queue in front of the interpreter (`protocol.md`, "Delivery queue"), so a burst of responses
is delivered in order; a request callback that finds the plugin's 8 MiB taken arrives as `CALLBACK_QUEUE_FULL`.

## Verification

- Executed on this Mac: `Build/run_swift_tests.py` (bridge and backend-decision tests, including the
  `telegram.action.*` validation in `AyuPluginTelegramActionsTests`); the ordering gate of the hook points
  (`AyuPluginOrderedGate`, the `gate` line of the TL tool);
  `Build/run_telegram_tl_tests.py`, which compiles TelegramApi and `AyuPluginTLBuilders.swift` for macOS, runs
  `Tests/TelegramTL/main.swift` (every builder with nothing and with everything set) through the real serializer
  and decodes each vector strictly with the SDK's parser (`Python/_ayu_javalib/telegram_tl.py`).
- Type-checked only (`Build/typecheck_telegram.py --ayu-app`, all bodies, warnings as errors): everything else in
  TelegramCore, the adapter and TelegramUI, including the mapping from stored models to the builders, the request
  path, sending, editing, files, navigation, the request and update hook points, the player and the actions.
- Not verified: the Bazel BUILD files (`AyuPluginTelegramAdapter/BUILD`, the dependency in `TelegramUI/BUILD`),
  linking, and all behaviour on a device.

## Refused functions

`telegram.request` never sends, and a request hook can never substitute, the 45 functions of
`AyuPluginTelegramRefusedFunctions.table`:

- every `auth.*` function (30);
- `account.deleteAccount` `0xa2c0cf74`, `account.resetAuthorization` `0xdf77f3bc`, `account.resetPassword`
  `0x9308ce1b`, `account.updatePasswordSettings` `0xa59b102f`;
- every generic wrapper, because the bridge cannot inspect the wrapped query: `invokeAfterMsg` `0xcb9f372d`,
  `invokeAfterMsgs` `0x3dc4b4f0`, `initConnection` `0xc1cd5ea9`, `invokeWithLayer` `0xda9b0d0d`,
  `invokeWithoutUpdates` `0xbf9459b7`, `invokeWithMessagesRange` `0x365275f2`, `invokeWithTakeout` `0xaca9fd2e`,
  `invokeWithBusinessConnection` `0xdd289f8e`, `invokeWithGooglePlayIntegrity` `0x1df92984`,
  `invokeWithApnsSecret` `0x0dae54f8`, `invokeWithReCaptcha` `0xadbb0f94`.

Derivation: `Build/telegram_refused_functions.py` reads the `---functions---` section of
`submodules/TelegramApi/swift_scheme.tl` as text and selects names starting with `auth.`, the four account names,
and every declaration with a `{X:Type}` parameter; run it to print the Swift literal.
`Tests/Python/test_telegram_refusals.py` recomputes the table and compares it with the literal, so a layer update
that adds an `auth.*` function fails the suite until the literal is regenerated. The table covers this layer only:
TelegramCore's function lookup (`ayuPluginSendableFunction`) is what refuses ids of other layers, and its name
rule refuses `auth.*` and `invokeWith*` functions the table does not know yet.
