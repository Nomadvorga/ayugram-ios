# AyuPluginBridge Telegram host contract

Operations the Python SDK uses to reach Telegram itself: API requests, request/update/send hooks, sending and
editing, cached peers and messages, the visible screen, files, the audio player, menus and the plugin list.
Everything here extends `protocol.md` (transport, ownership, generations, limits) and nothing replaces it.

**No operation of this document is declared by the Swift host yet.** The SDK side exists and is tested against a
synthetic host (`Tests/Python/test_telegram_*.py`). The Swift bridge side of the `telegram.*` operations exists
(`Integration/AyuPluginTelegramBridge.swift`: validation, ownership, quotas, hook chains) and is tested against a fake
backend; it reaches Telegram through `AyuPluginTelegramBackend`, which the app implements for every `telegram.*`
operation of this document (`Resources/CommonBridge/TELEGRAM-BACKEND.md` lists the differences from this
contract; none of it has run on a device). `menus.add` has its Swift side (`Integration/AyuPluginMenus.swift`)
and is declared only while that backend serves `telegram.peer` and `telegram.messages`; `resources.resolve` is
implemented and declared (`Integration/AyuPluginResources.swift`); `plugins.list`, `plugins.settings` and
`ui.layout_params` are implemented and always declared (`Integration/AyuPluginRegistryBridge.swift`,
`Sources/AyuBridgeLayoutParams.swift`). A host declares an operation in `runtime.capabilities.operations` only when it implements it
exactly as written; until then the SDK reports the dependent classes and entry points as preflight blockers and
raises `UNSUPPORTED_API` at call time.

## Conventions

- **Threading.** Every operation is dispatched on the Python queue thread and returns on it. The host may block that
  thread briefly to read state (a Postbox transaction, a main-thread snapshot); it must never make main wait for
  Python. Callbacks are delivered later through `invoke_callback_json`, never inside the dispatch that registered them.
- **Ownership.** Tokens, request ids, hook sets and menu items belong to the calling plugin generation.
  `plugin.deactivate` cancels in-flight requests (their callbacks never fire), clears the hook set and removes
  send hooks and menu items.
- **Accounts.** `account` is the bridge's account index (the value of `UserConfig.selectedAccount`), a nonnegative
  integer. An unknown or inactive index fails with `account_unavailable`.
- **Ids.** Dialog ids are Android dialog ids as signed 64-bit integers: user id for a private chat, the negated chat
  or channel id for groups and channels. Message ids are 32-bit; constructor ids are unsigned 32-bit integers.
- **Errors.** `invalid_arguments` for a malformed call (unknown key, wrong type, out of range), `UNSUPPORTED_API` for
  a well-formed request the host does not serve, `resource_limit` for a quota, `account_unavailable`,
  `screen_unavailable`, `timeout` when the app did not answer a state read or queue an action within 5 seconds. A
  host never answers a request it cannot serve with an empty or default result.
- **Unknown keys.** Arguments are closed objects: the host rejects a key this document does not list.
- **Existing operations.** The account, user-config and fragment adapters behind `client.call` stay as they are;
  the Python-local `AccountInstance`, `LaunchActivity` and fragment classes compose them.

### TL values

A TL object crosses the bridge as `{"tl": "<base64>"}`: the standard-alphabet, padded base64 of its *boxed* binary
TL serialization (constructor id first), exactly what `Api.parse(Buffer)` reads and `serialize(buffer, true)` writes.
The SDK serializes with the Android class table generated for **layer 233** (`_ayu_javalib/_telegram_tl_schema.py`,
`LAYER`), which is the layer of `submodules/TelegramApi/swift_scheme.tl`. A host built for another layer must not
declare any operation that carries TL values until the table is regenerated
(`Build/generate_tl_schema.py`). Bounds: 1 MiB (1,048,576 bytes) decoded for a value the SDK sends, 4 MiB
(4,194,304 bytes) for a value the host sends. The SDK refuses to encode a larger value (`ValueError`) and the host
answers one with `invalid_arguments`; a larger response is replaced by a `TL_error` with code 500 and text
`RESPONSE_TOO_LARGE`. The SDK raises `PROTOCOL_ERROR` for bytes it cannot decode, including a constructor outside
its table and trailing bytes.

These bound one value. A value also has to fit the envelope that carries it (`protocol.md`, "Limits and
validation"), and the envelopes are sized so that the two paths plugins depend on carry a full value:

| Envelope | Bound | TL it carries |
|---|---|---|
| Request of a `telegram.*` operation | 1,572,864 bytes of JSON | one 1 MiB value (1,398,104 base64 characters) and 170 KiB of other arguments; several values share it |
| Arguments of a `telegram.request` callback | 5,900,000 bytes of JSON | one 4 MiB response |
| Arguments of a hook callback | 5,900,000 bytes of JSON | the hooked object up to 4 MiB; a request and its response together must fit |
| Result of a `telegram.*` operation (`telegram.peer`, `telegram.messages`) | 1,048,576 bytes of JSON | about 767 KiB in total |
| Answer of a hook callback | 1,048,576 bytes of JSON | a modified object of about 767 KiB |

The host does not escape `/` in JSON, so a value costs four characters per three bytes whatever its content. A
response that does not fit its callback is replaced by `RESPONSE_TOO_LARGE`
as above, a dispatch result that does not fit fails with `resource_limit`, a hook answer that does not fit fails
(`RESOURCE_LIMIT`) and counts as strategy 0, and an object too large to show a hook
passes that hook unchanged.

A function response that is a bare TL vector (`Vector<int>`, `Vector<User>`, ...) is sent as the vector's own
serialization (`0x1cb5c415`, count, items). A `Bool` is `boolTrue`/`boolFalse`. An RPC error is the TL object
`error#c4b9f9bb code:int text:string`.

### Other value shapes

- A **message reference** (the wire form of an SDK `MessageObject`): `{"dialog_id": int64, "id": int32,
  "message": {tl}}`. The host identifies the message by `dialog_id` and `id`; `message` is the SDK's copy.
- A **resource id** (`R.drawable.msg_x`, `R.raw.x`): `{"resource": "<kind>", "name": "<name>"}`.
  Android resource integers do not exist on iOS. The class `R` exists only on a host that declares
  `resources.resolve` (below); such a host accepts this object in the members that section lists, resolves the
  name against its own icon table, and rejects a name it does not map. Menu icons are sent as the bare drawable
  name string, as Android's `MenuItemData.icon` is.

## Requests

### `telegram.request`

Backs `client_utils.send_request`, `AccountClient.send_request`, `ConnectionsManager.sendRequest`.

| | |
|---|---|
| Arguments | `{account:int, request:{tl}, flags:int, callback:$callback}`. `request` is an API function. `flags` is Android's `ConnectionsManager.RequestFlag*` bit set (0..2^31-1); the host honours `RequestFlagFailOnServerErrors` (2) and may ignore the others |
| Result | request id: integer in `1..2^31-1`, unique among the generation's in-flight requests |
| Callback | exactly once, `(response, error)`: `({tl}, null)` on success, `(null, {tl error})` on an RPC or transport failure (transport failures use code -1 and a short text), `(null, null)` when a pre-request hook of any plugin cancelled the request. The callbacks of one generation arrive in the order the responses did. A burst of responses is queued, never dropped (`protocol.md`, "Delivery queue"): each generation has a slot for all 64 callbacks and 8 MiB for their bytes, and a response that arrives when those bytes are taken is delivered as the transport failure `CALLBACK_QUEUE_FULL` |
| Bounds | 64 in-flight requests per generation (`resource_limit`); request and response sizes as in *TL values* |
| Errors | `invalid_arguments` for bytes that are not a function of the host's layer; `UNSUPPORTED_API` for functions the host refuses to send for plugins. The host must refuse `auth.*`, `account.deleteAccount`, `account.resetAuthorization`, `account.resetPassword`, `account.updatePasswordSettings` and wrapped requests (every generic function that carries another query: `invokeAfterMsg`, `invokeAfterMsgs`, `invokeWith*`, `initConnection`); it may refuse more, never silently |

The request goes through the account's normal network stack, after the request hooks below. The host does not
apply the response to its own state unless the function's normal handling does (a returned `Updates` is processed as
if the app had sent the request). The callback's result is ignored.

### `telegram.request.cancel`

Backs `ConnectionsManager.cancelRequest`. Arguments `{account:int, request_id:int}`; result `null`. Cancels an
in-flight request of the calling generation; its callback is not invoked. An unknown or finished id is not an error.

### `telegram.connection`

Backs `ConnectionsManager.getCurrentTime`, `getCurrentTimeMillis`, `getTimeDifference`, `getConnectionState`,
`getCurrentDatacenterId`, and the `date` of `client_utils._prepare_document`.

Arguments `{account:int}`. Result `{time_ms:int, time_difference:int, state:int, datacenter_id:int}`: server-corrected
Unix time in milliseconds, server minus local clock in seconds, Android's connection state (1 connecting, 2 waiting
for network, 3 connected, 4 connecting to proxy, 5 updating) and the main datacenter id.

## Hooks

Hook callbacks return a JSON object that the host must wait for before continuing with the request, update or
message. The wait is asynchronous (the network or state queue continues with other work) and bounded: after
2 seconds, or when the callback fails, the host continues as if the plugin had returned strategy 0. Strategies are
Android's: `0` DEFAULT (no change), `1` CANCEL, `2` MODIFY (use the returned object, continue with the next plugin),
`3` MODIFY_FINAL (use it and call no further plugin). A MODIFY result whose object is `null`, or is not a valid
value for the hook, changes nothing; MODIFY_FINAL still ends the chain. An answer that is not an object of the
listed keys is a failed callback. Plugins are called in descending priority, ties in ascending plugin id; one plugin
is called once per event. A host bounds the events that wait for hook answers (256) and passes further ones
unchanged.

### `telegram.hooks.set`

Backs `BasePlugin.add_hook`/`remove_hook` and the `pre_request_hook`, `post_request_hook`, `on_update_hook`,
`on_updates_hook` methods. Android matches hooks by the Java simple class name; the SDK resolves names to
constructor ids, so the host matches ids only.

| | |
|---|---|
| Arguments | `{requests:[[constructor, priority]], updates:[[constructor, priority]], containers:[[constructor, priority]], on_request:$callback, on_response:$callback, on_update:$callback, on_updates:$callback}`. Each list is sorted by constructor, has no duplicate constructor, and the three together hold at most 4096 entries; `priority` is a signed 32-bit integer |
| Result | `null`. The call replaces the generation's whole hook set atomically; three empty lists clear it. The four callback references stay the same across calls of one generation |

- `requests`: functions. Before any outgoing API request (the app's own and plugins') whose constructor is listed is
  sent, the host calls `on_request(account, {tl request})` → `{strategy, request:{tl}|null}`. CANCEL drops the
  request: a plugin that sent it gets the `(null, null)` callback, and an app caller is never answered, as on
  Android. A modified request replaces the original and must be a function that `telegram.request` does not
  refuse. A plugin's own request may become any such function and its callback receives the response of what was
  sent. A request of the app keeps its typed caller: it may be replaced by the same function with other arguments,
  or by a function with the same result type; any other replacement is ignored and the original is sent.
- Scope of `requests`: the account's main session, which carries every API call of the app and of plugins. File
  parts (`upload.getFile`, `upload.saveFilePart`, `upload.saveBigFilePart`, `upload.getCdnFile`,
  `upload.getWebFile` and the other requests of the download and upload sessions) are never shown, and neither is
  a function `telegram.request` refuses (`auth.*`, the password and deletion functions, wrappers): a hook cannot
  read what a plugin may not send. While a hooked request waits, later requests that the app orders after it
  (messages to one chat) wait behind it; unrelated requests are not delayed.
- When the response of such a request arrives, before it is delivered, the host calls
  `on_response(account, constructor, {tl response}|null, {tl error}|null)` (`constructor` is the id of the request
  that was sent) → `{strategy, response:{tl}|null, error:{tl}|null}`. Strategy 1 is never returned. With MODIFY a
  non-null `response` replaces the response and a non-null `error` replaces the error.
- `updates`: constructors of type `Update`. For each listed update inside a processed `updates`, `updatesCombined`
  or `updateShort` container, and inside the `other_updates` of `updates.getDifference` and
  `updates.getChannelDifference`, the host calls `on_update(account, {tl update})` → `{strategy, update:{tl}|null}`;
  CANCEL drops that update. The updates of one container are asked about together, in order, and the container
  continues when all are answered. An update keeps its place in the update sequence: a replacement must carry the
  same `pts`/`pts_count` (and channel) or `qts` as the original, else it is ignored; a cancelled update of a
  container that carries `pts` is processed as a deletion of no messages with that `pts`, so it is neither
  applied nor fetched again, and one that carries `qts` (secret chat messages, bot updates) cannot be dropped and
  is processed unchanged; a cancelled update of a difference is left out. The messages of a difference (`new_messages`) are not updates and are not shown, as on
  Android; neither are the messages of `updateShortMessage` and `updateShortChatMessage`, which are containers.
- `containers`: constructors of type `Updates` (`updates`, `updatesCombined`, `updateShort`, `updateShortMessage`,
  `updateShortChatMessage`, `updateShortSentMessage`, `updatesTooLong`). Before a listed container is processed the
  host calls `on_updates(account, {tl updates})` → `{strategy, updates:{tl}|null}`; CANCEL drops the container
  (the app then sees a gap and fetches the difference, as Android does). This covers containers the server
  pushes, `Updates` responses of requests and containers passed to `telegram.action.process_updates`. Containers of
  one account are processed in the order they arrived: while one waits for a plugin, later ones wait behind it.

A host that cannot intercept one of the four streams must not declare the operation. Cost: the host serializes and
parses only objects whose constructor is listed.

### `telegram.hooks.send_message`

Backs `BasePlugin.add_on_send_message_hook` and `on_send_message_hook` with Android's `SendMessageParams` fields.
When it is not declared the SDK uses the existing `hooks.register` kind `send_message` (peer, message, caption only).

| | |
|---|---|
| Arguments | `{priority:int32, callback:$callback}` |
| Result | nonempty token; `hooks.unregister {token}` removes the hook. At most one per generation is registered by the SDK; the host allows 16 |
| Callback | `(account, params)` → `{strategy, params:object|null}`, called before an outgoing message is enqueued (text, media, forwards excluded) |

`params` to the plugin, all keys optional except `peer`: `peer` (dialog id), `message` (text of a text message),
`caption` (caption of a media message), `entities` (`[{tl MessageEntity}]`, UTF-16 offsets into message or caption),
`replyToMsg` and `replyToTopMsg` (`{tl Message}` of the replied message and of the thread's top message), `path`
(local file being sent), `document`/`photo` (`{tl}` when the media already is a Telegram document or photo),
`notify` (bool, false = silent), `scheduleDate`, `scheduleRepeatPeriod`, `searchLinks`, `invert_media`, `effect_id`,
`hasMediaSpoilers`, `monoForumPeer`, `quick_reply_shortcut_id`, `payStars`. A key the host omits has Android's Java
default in the plugin's object (`notify` true).

`params` from the plugin (MODIFY/MODIFY_FINAL): `peer`, `message`, `caption`, `entities` (`[{tl}]` or `null` for
none), `replyToMsg`, `replyToTopMsg` (message id or `null`), `notify`, `scheduleDate`, `scheduleRepeatPeriod`,
`searchLinks`, `invert_media`, `effect_id`, `hasMediaSpoilers`. The host applies text, caption and entities as given
(it does not remap its own entities), and validates everything: an invalid result, or a changed `peer`, reply
target or other field the host cannot honour, discards that plugin's modification as a whole. Text can be rewritten
but not removed, emptied or moved between `message` and `caption`. CANCEL suppresses the send.

Hooks registered here and three-field hooks registered through `hooks.register` run as one chain in the order
above; a plugin that registered both ways is called through this hook only.

## Sending and editing

### `telegram.send_message`

Backs `client_utils.send_message`, `send_text`, `send_photo`, `send_document`, `send_video`, `send_audio`, the
`AccountClient` forms and `SendMessagesHelper.sendMessage(SendMessageParams)`.

Arguments `{account:int, params:object}`; result `null` once the message is queued for sending (delivery is
asynchronous, as on Android). `params` holds only the `SendMessageParams` fields that differ from the Android SDK
defaults; the host rejects (`UNSUPPORTED_API`, naming the key) any key it cannot honour rather than dropping it:

| Key | Value |
|---|---|
| `peer` | dialog id, required |
| `message` / `caption` | text of a text message / caption of an attachment, at most 65,536 UTF-8 bytes |
| `entities` | `[{tl MessageEntity}]` for the message, else the caption |
| `replyToMsg`, `replyToTopMsg` | message reference; reply target and thread top message |
| `notify` | `false` sends silently (absent means notify) |
| `scheduleDate`, `scheduleRepeatPeriod`, `ttl`, `effect_id`, `quick_reply_shortcut_id`, `monoForumPeer`, `payStars`, `stars`, `dice_stake` | integers |
| `searchLinks` | `false` disables link preview |
| `invert_media`, `hasMediaSpoilers`, `updateStickersOrder`, `sendingHighQuality` | booleans |
| `params` | `{string: string}`, Android's message params map |
| `path` + `attach:{kind}` | a local file to send as `photo`, `document`, `video` or `audio`; the host reads the file (which must lie inside the app container), detects the MIME type and prepares sizes, thumbnail, dimensions and duration itself. `attach` needs `path`; `path` needs `attach`, or a `document` or `photo` that describes the file |
| `document`, `photo`, `location`, `poll`, `game`, `invoice`, `mediaWebPage`, `webPage`, `replyMarkup`, `user`, `todo`, `cover`, `richMessage` | `{tl}`; with `path` a `document` describes the upload (MIME type, attributes), without `path` it must reference an existing document |

### `telegram.edit_message`

Backs `client_utils.edit_message`. Arguments `{account:int, dialog_id:int64, message_id:int, text?:string,
entities?:[{tl}], attach?:{kind, path, spoiler:bool}, params?:{string:string}}` with at least `text` or `attach`;
`kind` is `photo`, `video`, `audio` or `document`. Result `null` once the edit is queued. `invalid_arguments` when
the message is not editable by the account.

## Menus

### `menus.add`

Backs `BasePlugin.add_menu_item` for all five Android menu types; `menus.unregister {token}` removes the item.
When it is not declared the SDK uses `menus.register` (message context menu only).

| | |
|---|---|
| Arguments | `{type, item_id:string, text:string, priority:int32, on_click:$callback, icon?:string, subtext?:string, on_long_click?:$callback, condition?:$callback}`; `type` is `message_context_menu`, `chat_action_menu`, `profile_action_menu`, `drawer_menu` or `main_menu`; `icon` is an Android drawable name the host maps to its own icon or shows no icon for |
| Result | nonempty token |
| Bounds | 64 items per generation; `text`/`subtext` 256 UTF-8 bytes; `item_id` 128 bytes, unique per generation (the SDK unregisters a replaced id first) |

Items of one menu are ordered by descending priority, then by registration; one menu shows at most 64 plugin
items. Before showing an item with a `condition` the host calls `condition(context)` and shows the item only for
`true` (bounded like hooks: no answer in 2 seconds hides it); the menu itself must not wait on main: the native
rows appear at once and the plugin rows are added when the answers arrive. `on_click(context)` and
`on_long_click(context)` (a long press on the row) run after the tap with the context the menu was opened with;
their results are ignored, and nothing is delivered when the item was removed or the visible screen or account
changed meanwhile. The item's callbacks count toward the generation's callback quota (`resource_limit`). A string
`condition` is refused with `UNSUPPORTED_API`, a second item of an `item_id` with `invalid_arguments`. `context` is `{account:int, dialog_id?:int64, message?:{tl Message}, user?:{tl User},
chat?:{tl Chat}, user_full?:{tl UserFull}, chat_full?:{tl ChatFull}, encrypted_chat?:{tl EncryptedChat}}`:

- `message_context_menu`: `dialog_id`, `message` (the pressed message), and `user` or `chat` of the dialog;
- `chat_action_menu` (the chat's header menu): `dialog_id` and `user` or `chat`, plus `user_full`/`chat_full` when cached;
- `profile_action_menu`: the same for the profile's peer;
- `drawer_menu` and `main_menu` (the app's main/side menu, where iOS has one): `account` only.

A menu whose promised values cannot be rebuilt from the cache (the dialog's `user` or `chat`, the pressed
`message`) shows no plugin items instead of a partial context; a `user_full`/`chat_full` too large for one
callback is left out. `encrypted_chat` is never sent by the iOS host: a secret chat has no Android dialog id, so
its menus show no plugin items.

Where the iOS host shows them: the message context menu; the context menu of the chat header's avatar (iOS has no
"⋮" button there; this menu holds the same kind of chat actions); the profile's "More" menu; and, for
`drawer_menu` and `main_menu` together (Android's main menu lists the drawer items too), a "Plugin menu" section
of the plugin manager screen, because iOS Telegram has neither a drawer nor a global main menu. An `icon` name is
looked up in the host's drawable table (see `resources.resolve`); a name it lacks shows no icon.

Android's MVEL condition strings are not evaluated; the SDK refuses them before calling the host.

## State

### `telegram.peer`

Backs `MessagesController.getUser`, `getChat`, `getUserFull`, `getChatFull`, `getUserOrChat`, the input-peer builders
(`getInputPeer`, `getInputUser`, `getInputChannel`, `getPeer`), `ChatActivity.getCurrentUser`/`getCurrentChat` and the
account overloads of `ChatObject`.

Arguments `{account:int, kind:"user"|"chat"|"user_full"|"chat_full", id:int64}` (`id` is the positive user, chat or
channel id). Result `{tl}` of type `User`, `Chat` (`chat`, `channel`, `chatForbidden`, `channelForbidden`),
`UserFull` or `ChatFull` rebuilt from the local cache, or `null` when the peer is not cached; no network request is
made. The object must carry the access hash and the flags the cache knows (`self`, `bot`, `deleted`, `megagroup`,
`broadcast`, `forum`, `left`, `creator`, admin and banned rights, usernames).

`ChatObject` and `UserObject` exist only with this operation: without it the only users and chats a plugin can get
are the host's `TLRPC$User`/`TLRPC$Chat` snapshots (four and three fields), which those predicates cannot judge.
Such a snapshot handle is never mistaken for a TL object. `isinstance` answers for the snapshot's own class and its
bases and raises `UNSUPPORTED_API` for a concrete subclass (`TL_channel`); the static helpers of `ChatObject`,
`UserObject`, `DialogObject`, `MessageObject` and `FileLoader` raise for any host object; the input-peer builders
replace a snapshot by the cached object of their own account, or raise when it is not cached.

### `telegram.messages`

Backs `MessagesStorage.getMessage`. Arguments `{account:int, dialog_id:int64, ids:[int]}` with 1 to 100 ids. Result:
a list of the same length, each `{tl Message}` rebuilt from the local store or `null` when it is not stored.
`null` is also the answer for a stored message the host cannot rebuild as a `message` (a service message): a
wrong object is never returned in its place.

### `telegram.screen`

Backs `client_utils.get_last_fragment` and the fragment classes (`BaseFragment`, `ChatActivity`, `ProfileActivity`,
`DialogsActivity`), which wrap the fragment adapter of `client.call get_last_fragment`.

Arguments `{}`. Result `null` when no screen is visible, else `{kind, account:int, dialog_id?:int64, topic_id?:int,
chat_mode?:int}`: `kind` is `chat`, `profile`, `dialogs` or `other`; `dialog_id` is present for `chat` and `profile`;
`topic_id` is the forum topic or thread id of a chat (0 or absent for none); `chat_mode` is Android's
`ChatActivity.MODE_*` (0 default, 1 scheduled, 2 pinned, 3 saved, 5 quick replies). The snapshot and the fragment
adapter must describe the same screen.

### `telegram.navigation.open`

Backs `presentFragment(ChatActivity(args))`, `ChatActivity.of(dialogId[, messageId])`,
`presentFragment(ProfileActivity(args))` and `MessagesController.openByUserName`.

Arguments `{account:int, dialog_id:int64, screen:"chat"|"profile", message_id?:int}` or `{account:int,
username:string, type:int32}`. Result `null` once navigation is queued on main. `invalid_arguments` for a peer the
account does not know; a username is resolved through the app's own resolver and failures are shown by the app.
`type` is Android's `openByUserName` argument: `0` opens the profile of a user that is not a bot and the chat of a
bot, group or channel; any other value opens the chat. The SDK sends the call only for a fragment that is on screen
and raises for a `Browser.Progress` argument.

### `telegram.files.path`

Backs `FileLoader.getPathToMessage` and `getPathToAttach`. Arguments `{account:int, target:{tl}, cache:bool}` where
`target` is a `Message`, `Document`, `PhotoSize`, `VideoSize` or `Photo`. Result: an absolute path string. When the
file is completely downloaded it is the path of the local copy; otherwise it is a path inside the app's cache
directory at which no file exists, so `File.exists()` answers as on Android. A `PhotoSize` or `VideoSize` carries
no file identity in this layer's TL; a host that cannot resolve one fails with `UNSUPPORTED_API`.

### `telegram.files.load`

Backs `FileLoader.loadFile` and `cancelLoadFile`. Arguments `{account:int, target:{tl}, priority:int, cache_type:int,
parent?:{tl}}` to start a download (`priority` is Android's 0..3; `parent` is the message that owns the file and
supplies the file reference), or `{account:int, target:{tl}, cancel:true}`. Result `null`. Completion is observed by
polling `telegram.files.path`; no notification is delivered.

### `telegram.player`

Backs `MediaController.getPlayingMessageObject`, `isMessagePaused`, `isPlayingMessage`, `pauseMessage`,
`playMessage` (resume of the current message), `playNextMessage`, `playPreviousMessage`, `cleanupPlayer`,
`seekToProgress`.

Arguments `{action}` with `action` one of `state`, `pause`, `resume`, `next`, `previous`, `stop`, or
`{action:"seek", progress:number}` (0..1). Result, always the state after the action: `{account:int, paused:bool,
message?:{tl Message}, progress?:number, position_ms?:int, duration_ms?:int}`; `message` and the three numbers are
absent when nothing is loaded in the shared audio player, and `account` is then the selected account. The state
is read once the player shows the action, or after one second; nothing is reported as loaded while the player
switches items, or while it plays something that is not a cloud message (the actions still apply to it). The
SDK also derives `getProgressMs` and `getDuration` from this state. The playlist (`getPlaylist`, `setPlaylist`,
`getPlayingMessageObjectNum`), starting a message that is not loaded, playback speed and waveforms are not
part of the operation.

## State changes

Backs the `MessagesController` members that change state. Each action is its own operation, so a host declares
exactly the ones it carries out; there is no generic "call a controller method". Every action takes `account`,
returns `null` once the change is applied locally or queued for the server (delivery is asynchronous, as on
Android), and goes through the same code as the app's own user action, so the app's rules apply (ghost mode,
what a deletion removes for whom, how cached peers are merged).

| Operation | Arguments | Backs | Effect |
|---|---|---|---|
| `telegram.action.delete_messages` | `{account, dialog_id:int64, ids:[int], revoke:bool}`; 1 to 100 distinct positive ids | `deleteMessages` (every overload) | Deletes the cloud messages `ids` of the dialog, for this account only or, with `revoke` (Android's `forAll`), for everyone; in a channel always for everyone. Ids that are not stored are ignored |
| `telegram.action.read_dialog` | `{account, dialog_id:int64, max_id:int}` | `markDialogAsRead` | Marks incoming messages up to the stored message `max_id` as read; `invalid_arguments` when that message is not stored |
| `telegram.action.process_updates` | `{account, updates:{tl Updates}}` | `processUpdates` | Processes the container as if the server had sent it, update hooks included |
| `telegram.action.store_peers` | `{account, users:[{tl User}], chats:[{tl Chat}]}`; at most 200 each, not both empty | `putUser`, `putUsers`, `putChat`, `putChats` | Merges the objects into the peer cache as the users and chats of a response are merged (a `min` object does not replace a full one); `fromCache` has no meaning here |
| `telegram.action.load_full_peer` | `{account, kind:"user"|"chat", id:int64}` | `loadFullUser`, `loadFullChat` | Starts the request that refreshes the cached `UserFull`/`ChatFull`, which `telegram.peer` then returns; `invalid_arguments` for a peer the account does not know |

`invalid_arguments` also answers a `dialog_id` the account does not know and bytes that are not an object of the
named type. The SDK splits longer lists into several calls, and raises `UNSUPPORTED_API` for what no action
covers: a secret chat, scheduled or quick-reply messages, a cache-only deletion, reading a thread, a
`loadFullUser` callback. `addDialogToFolder`, `deleteDialog`, `pinMessage`, `forwardMessages`, `sendTyping`,
`blockPeer`, `markReactionsAsRead` and the dialog list (`getDialogs`, `getAllDialogs`, `dialogs_dict`) have no
operation.

## Plugins and layout

### `plugins.list`

Backs `PluginsController.getInstance().plugins` and `isPluginActive`. Arguments `{}`. Result: at most 1024 records
`{id:string, name:string, enabled:bool, version?:string, description?:string, author?:string, icon?:string,
error?:bool}` for every installed plugin, the caller included.

`enabled` is true for a plugin that is running and for the caller itself, which is running even while the manager
still shows it as loading. `error` is sent, as `true`, only for a plugin that failed and is not running (Android's
`Plugin.hasError`). `version` is absent when the metadata declares none, `icon` is the `__icon__` text. Optional
fields are never shortened: when the encoded list would exceed 192 KiB the host leaves `description` out of every
record, then `author` and `icon` as well, and fails with `resource_limit` if the list still does not fit.

### `plugins.settings`

Backs `PluginsController.loadPluginSettings`, `openPluginSettings` and `presentFragment(PluginSettingsActivity)`.
Arguments `{action:"reload", plugin_id}` (re-serialize and redraw the settings rows; only the caller's own id is
accepted) or `{action:"open", plugin_id, link_alias?:string}` (push the settings screen of an enabled plugin).
Result `null`.

- `reload`: another plugin's id is `UNSUPPORTED_API`. The plugin's settings screens that are on screen serialize
  their rows again (the root page through `serialize_settings`, a sub-page through its `create_sub_fragment`
  callback), coalesced like a `reload_settings` write. Rows are serialized whenever a screen opens, so with no
  screen open there is nothing to redraw.
- `open`: `plugin_id` must name an installed plugin (`invalid_arguments`) that is enabled and not being loaded or
  unloaded (`invalid_state`; this includes the caller inside its own `on_plugin_load`). Without a visible screen
  to show it from, the plugin manager's top screen or the application's visible controller, the call fails with
  `screen_unavailable`. The screen is pushed onto the manager's stack or presented over the application after the
  call returned, and loads its rows then; main never waits for Python.
- `link_alias` is Android's `targetSettingName`: row aliases joined with `:`, at most 512 bytes and 8 aliases,
  none empty (`invalid_arguments`); an empty string names no row. Each leading alias opens the sub-page of the
  first row that carries it, and the row carrying the last alias is scrolled to and highlighted. An alias no row
  carries is reported to the user on the screen; the call has returned `null` by then, as Android's does.

### `ui.layout_params`

Backs `LayoutHelper.createFrame*` and `createLinear*`. The existing `LayoutParams` adapters take width and height
only; this operation builds the params in one call.

Arguments `{kind:"frame"|"linear", width:number, height:number, weight?:number, gravity?:int, margins?:[4 numbers],
relative?:true, margins_in_pixels?:true}`. `width`/`height` are `-1` (MATCH_PARENT), `-2` (WRAP_CONTENT) or dp;
`margins` are left, top, right, bottom in dp (physical pixels with `margins_in_pixels`); with `relative` the first
and third margins are start and end and `gravity` may use `Gravity.START`/`END`, resolved for the interface
direction. Result: an owned reference of class `android.widget.FrameLayout$LayoutParams` or
`android.widget.LinearLayout$LayoutParams` that `ViewGroup.addView` and `View.setLayoutParams` accept.

- Bounds: sizes are `-1`, `-2` or 0…100000; `weight` is 0…100000 and belongs to `linear` only; margins are within
  ±100000; the two flags are `true` or absent. Anything else is `invalid_arguments`.
- Units: the host stores native points. A dp value is rounded up, as `AndroidUtilities.dp` rounds at this host's
  density of 1; pixel margins are divided by the screen scale and not rounded.
- `gravity` is `-1` (Android's unspecified value, nothing is stored) or `Gravity` flags within `0x00800077` whose
  horizontal part is none, left, right, center or fill and whose vertical part is none, top, bottom, center or
  fill (`invalid_arguments` otherwise). The clip flags are valid Android gravity the layout does not apply:
  `UNSUPPORTED_API`.
- `relative` is resolved once, when the parameters are created, as `createFrameRelatively` does: the margins
  become left and right and the gravity goes through `Gravity.getAbsoluteGravity` for the interface direction
  (`UIView.userInterfaceLayoutDirection`). Without `relative` a `START`/`END` gravity is kept as given and laid
  out as left/right, which is what Android does for Telegram's always left-to-right views.
- Layout: a `FrameLayout` child, and the single child of a scroll view, is placed as `FrameLayout.layoutChildren`
  places it (centering adds the leading margin and subtracts the trailing one; fill and an unspecified gravity are
  top-left; along its scroll axis a scroll view applies gravity only while the child is shorter than the
  viewport). In a `LinearLayout` the child's gravity replaces the container's on the cross axis, including
  Android's rule that a horizontal layout drops the top margin of a child whose gravity has no vertical part;
  positive weights share the remaining main-axis space.
- The object exposes `width`, `height`, `gravity` (`-1` when unset), `leftMargin`, `topMargin`, `rightMargin`,
  `bottomMargin` and, for `linear`, `weight` as readable and writable fields, and `setMargins`; a write reaches
  the views the parameters are attached to. `createLinearRelatively` sends its absolute gravity as `weight` and
  no `gravity`, because Android's helper passes it to the `(width, height, weight)` constructor.

### `resources.resolve`

Backs `org.telegram.messenger.R` for icons: `R.drawable.<name>` and `R.raw.<name>`. The SDK offers `R` only when
this operation is declared and reports it as a preflight blocker otherwise.

Arguments `{resource:string, name:string}`: a resource kind and an Android resource name (ASCII letters, digits
and `_`, at most 128 bytes each; anything else is `invalid_arguments`). Result `true` when the host maps that
name to one of its own icons, `false` when it does not (always `false` for a kind other than `drawable` and
`raw`). The SDK does not call the operation itself; it only checks that it is declared.

Android names do not exist on iOS. The host keeps an explicit table from the Android names the plugin corpus uses
to icons it really has: Telegram-iOS context-menu image sets, else SF Symbols available on iOS 15. An exteraGram
icon-pack or size variant (`_solar`, `_remix`, `_hw`, `_ny`, `_art`, `_old`, `_14`, `_24`) maps as its base
name. A `raw` name (an Android Lottie animation) maps to a still icon; the animation is not played.

Declaring the operation commits the host to accept the resource-id object of *Other value shapes* in exactly
these places, and to fail with `invalid_arguments` for a name it does not map rather than show nothing:

- `ImageView.setImageResource` / `ImageButton.setImageResource` (`drawable`): the icon is set as a template image,
  so `setColorFilter` tints it;
- the `icon` of a `ui.present` bulletin, which backs `BulletinHelper.show_simple`, `show_two_line` and
  `show_with_button` (`raw` or `drawable`). A bulletin shown over a plugin's own dialog takes no icon
  (`UNSUPPORTED_API`, as for its other options).

Nothing else takes a resource id: the host has no `getDrawable`, `getString`, `BulletinFactory.createSimpleBulletin`
or action-bar menu members, and an alert's top image or animation raises in the SDK. Other kinds are not served:
`R.string` is gated on `resources.strings` and every other kind (`style`, `id`, `color`, `dimen`, `attr`,
`layout`, ...) on `resources.android`, both reserved below. Preflight reports their use (`MEMBER
org.telegram.messenger.R.string`, `CLASS org.telegram.messenger.R$string`), and reading a name of such a kind
inside a plugin raises `UNSUPPORTED_API`.

## Images

Implemented in `Sources/AyuBridgeImages.swift` (`AyuBridgeImageService`, with `AyuBridgeImageOps.swift` and
`AyuBridgeImageDrawing.swift`) and declared by the host. The SDK client is `_ayu_images.py`; `PIL` and the
`android.graphics` bitmap classes (`_ayu_javalib/android_bitmap.py`) are built on it. Pixels stay in the host: an
image is an opaque string handle owned by one plugin generation and dropped with it. An image has a `mode` (`L`,
`LA`, `RGB`, `RGBA`), eight bits per band, straight (non-premultiplied) alpha, rows top to bottom. Every operation
that returns an image returns `{image, mode, width, height}`; a color is a list with one value 0...255 per band.
Unknown argument keys fail with `invalid_arguments`, an unknown handle with `invalid_handle`, an unknown mode,
filter, format or kind with `UNSUPPORTED_API`.

Limits per plugin generation: 64 images, 134,217,728 pixel bytes, 32 fonts; one image at most 16,384 pixels a side
and 16,777,216 pixels; a file read by the host at most 67,108,864 bytes; one pixel transfer at most 131,072 raw
bytes; 256 draw commands a call; 16,384 bytes of text; 4,096 path segments. Exceeding one fails with
`resource_limit`. A path is absolute, at most 4,096 bytes, and names a regular file.

| Operation | Arguments | Result and rules |
|---|---|---|
| `image.create` | `mode`, `width`, `height`, `color?` | New image filled with `color` (zeros by default) |
| `image.decode` | `path` or `data` (base64), `bounds?` | First frame of a JPEG, PNG, GIF, WebP, BMP or TIFF, decoded by ImageIO without color management; the result adds `format`, `orientation` (EXIF 1...8, not applied) and `frames`. Mode comes from the file: gray or color, with alpha when the file has it. With `bounds: true` only the header is read: no `image` key, nothing is stored. An unreadable file fails with `io_error`, an unidentified one with `image_format` |
| `image.encode` | `image`, `format` (`PNG`, `JPEG`, `WEBP`), `path`, `quality?` (0...100, default 75) | Writes the file atomically and returns `{bytes}`. PNG ignores `quality`. JPEG refuses an image with alpha (`invalid_arguments`). `WEBP` fails with `UNSUPPORTED_API` where ImageIO has no WebP encoder |
| `image.release` | `images?`, `fonts?` (lists of at most 256 handles) | Frees them; unknown handles are ignored |
| `image.copy` | `image` | A copy |
| `image.convert` | `image`, `mode` | Pillow's `convert`: gray from color by ITU-R 601 luma, alpha added as 255 or dropped (color bands are kept as stored, not composited) |
| `image.band` | `image`, `band` | One band as an `L` image |
| `image.merge` | `mode`, `bands` | One `L` image of the same size per band of `mode` |
| `image.putalpha` | `image`, `alpha` (an `L` image handle of the same size, or 0...255) | In place; `L` becomes `LA` and `RGB` becomes `RGBA`. Returns the new description |
| `image.pixels.get` | `image`, `box` `[left, top, right, bottom]` | `{data}`: base64 of the interleaved bytes of the box, which lies inside the image and holds at most 131,072 bytes |
| `image.pixels.put` | `image`, `box`, `data` | Replaces the bytes of the box in place |
| `image.point` | `image`, `table` (256 values per band) | New image through the lookup table |
| `image.stats` | `image`, `kind`, `max?` | `histogram`: 256 counts per band; `extrema`: `[low, high]` per band; `bbox`: the box of non-zero pixels (alpha only when the mode has alpha) or null; `colors`: at most `max` (default 256, bound 4,096) distinct colors with counts, null beyond that |
| `image.crop` | `image`, `box` | New image of the box; the part outside the source is zero |
| `image.resize` | `image`, `width`, `height`, `filter` (`nearest`, `box`, `bilinear`, `hamming`, `bicubic`, `lanczos`), `box?` | Pillow's resampling of the source box (the whole image by default) |
| `image.transpose` | `image`, `method` (`flip_left_right`, `flip_top_bottom`, `rotate_90`, `rotate_180`, `rotate_270`, `transpose`, `transverse`) | New image |
| `image.transform` | `image`, `width`, `height`, `matrix` (six numbers, output pixel to source pixel), `filter` (`nearest`, `bilinear`, `bicubic`), `fill?` | Affine transform; uncovered pixels take `fill` (zeros by default) |
| `image.paste` | `image`, `box` `[x, y]`, `source` or `color`, `mask?` | In place. `source` has the image's mode; a `color` needs a `mask`; the mask (`L`, `LA` or `RGBA`, the size of the source) weighs the paste by its last band |
| `image.alpha_composite` | `image`, `source` | Two `RGBA` images of one size; a new image with `source` over `image`, with Pillow's rounding |
| `image.blend` | `image`, `source`, `alpha` | Same mode and size; `image * (1 - alpha) + source * alpha`, clipped |
| `image.chop` | `image`, `kind` (`difference`, `multiply`, `add`, `subtract`, `offset`), `source?`, `scale?`, `offset?`, `dx?`, `dy?` | Pillow's `ImageChops`; the result has the common size |
| `image.filter` | `image`, `kind` (`gaussian_blur`, `box_blur` with `radius`; `kernel` with `size` 3 or 5, `kernel`, `scale`, `offset?`; `rank` with odd `size` up to 15 and `rank`; `unsharp` with `radius`, `percent`, `threshold`) | New image; every band is filtered on its own with Pillow's kernels and borders |
| `image.draw` | `image`, `commands` | In place; the whole list is validated before the first pixel changes. A command has `op`: `rect`, `round_rect`, `ellipse` (`box`, `radius` or `radii`, `ring?`), `arc` (`box`, `start`, `sweep`, `center?`), `line` (`points`), `path` (`segments` of `M`, `L`, `Q`, `C`, `Z`), `fill` (the whole image), `text` (`text`, `origin` on the baseline, `font` handle or `size`, `stroke_width?`, `stroke_ink?`) or `image` (`source`, `dst`, `src?`, `alpha?`, `filter?`). Shared keys: `fill` and `stroke` inks, `width`, `cap`, `join`, `antialias`, `blend` (`replace`, Pillow's default, or `over`, source-over), `matrix` (six numbers) and `clips` (at most 32 of `{matrix, rect}`). `paint` and `path` may instead be references to an `android.graphics.Paint` and `Path` the plugin owns in the host; the paint then supplies color, style, stroke, text size and filtering and the command blends `over` |
| `image.font.load` | `size` (1...2048), `path?`, `index?` | `{font, size, ascent, descent, family, style}`: a font file, or the system font without `path` |
| `image.font.measure` | `font`, `text`, `stroke_width?` | `{advance, ink, ascent, descent}`; `ink` is the outline box relative to the pen on the baseline |

An image reaches a view only through `ImageView.setImageBitmap`/`setImageDrawable` with `{image}`: the host copies
the pixels for that view, and the copy counts against the plugin's decoded-image quota.

## Reserved names

The SDK names these operations in preflight blockers. They have no contract and a host must not declare them.

| Operation | Android feature | Status |
|---|---|---|
| `hooks.java_method` | `hook_method`, `hook_all_methods`, `hook_all_constructors` (Xposed) | Patching arbitrary Java methods has no iOS counterpart. The corpus hooks 369 distinct methods, none in more than 7 plugins, so no target mapping is defined |
| `hooks.partial` | `hook_call_site`, `hook_field_read`/`write`, `hook_string_constant`, `hook_return_value` | Bytecode patching; the SDK always raises |
| `telegram.stickers` | `get_media_data_controller` | not designed |
| `telegram.contacts`, `telegram.location`, `telegram.notifications`, `telegram.secret_chats`, `telegram.downloads` | the matching `client_utils.get_*` controller getters | not designed |
| `resources.strings` | `R.string.<name>` (`LocaleController.getString(R.string.x)`) | Android string names have no iOS table; the corpus uses 59 names and the host has no `getString` member |
| `resources.android` | `R.style`, `R.id`, `R.color`, `R.dimen`, `R.attr`, `R.layout` and the other Android-only kinds | No iOS counterpart |
| `sdk.unprovided_member` | A call, on any receiver, of a member listed in `_ayu_operations.UNPROVIDED_MEMBERS` (`addDialogToFolder`, `readAllDialogs`, `MessageObject.applyNewText`, `getWindow().getDecorView()`, ...) | Neither a host adapter nor a Python-local class provides the member, so the call fails wherever it is made. The list comes from auditing plugins that otherwise pass preflight; it is not complete (see *Member coverage*) |

### Member coverage

Preflight checks classes and SDK entry points, not the members a plugin uses on the objects it gets. A plugin can
therefore pass and still fail on a member that its host adapter or local class lacks. `runtime.capabilities` lists
class names only, and the host's member names are spread over adapter dictionaries and `switch` cases, so the SDK
has no member list to check against. Closing this needs the host to publish each class's members in
`runtime.capabilities`, the SDK to accept that key, and static inspection to resolve the class of a receiver
(`x = Class.getInstance(...)`, `get_messages_controller()`); until then only the names above are reported.
