# exteraGram local feed integration handoff

2026-11-25. This work changes the feed controller/context/settings, adds native post
and category controls, extends the existing AccountContext feed interface and its
TelegramUI implementation, and adds model tests. No commit or push. Settings root,
navigation host, localization tables, backup and BUILD files are owned by the root
integration agent and were not edited here. The host CI feed command received only
the new production history-policy source argument; other agents' changes remain.

## Implemented behavior

- `ExteraFeedPostItem` hosts the real `SharedAccountContext.makeChatMessageFeedItem`
  / `ChatMessageItemImpl`. Original photos, videos, round videos, captions, entities,
  custom emoji, reaction attributes and comment attributes reach Telegram's bubble.
  There are no URL thumbnails or placeholder media. Albums use a stable peer/group
  identity and preserve all loaded members when any member matches Unread Only.
  History/window boundaries can still yield a partial album until another page loads.
- A channel/date header opens the source post. The native bubble opens the ordinary
  media viewer, links, peers, reply targets and Instant View. The media viewer uses
  no custom zoom transition; its existing native presentation handles opening/closing.
- Interactive feed bubbles retain their native status line and use regular reaction
  placement. The old News caller has default action parameters and keeps its existing
  hidden-status layout. Photo/video media stay in the exteraGram bubble; no News API
  is enabled and News' separate media-gallery renderer is not used.
- Reaction chips toggle actual engine reactions. The plus button and chip context
  action open Telegram's `ContextController` with `topMessageReactions`, including
  channel-permitted custom emoji and the native expanded selector when necessary.
  Mutation reads the latest stored message, checks `canAddMessageReactions` and
  `peerMessageAllowedReactions`, allows removal of an existing selection, and uses
  `addMessageReactions` / `setMessageReactions`. The engine applies its normal account
  reaction-count limits and album updates. The feed subscribes to stored messages so
  pending/local/server reaction changes redraw the native chips.
- Selecting Stars opens the original post so the user can use the channel's native
  paid-reaction interface. This bridge never calls a Stars payment API and never
  silently charges a paid reaction. Opening the source is not payment confirmation.
- The native comments pill calls `ChatControllerImpl.openMessageReplies` with
  `isChannelPost: true`, using its existing discussion lookup, preload, progress and
  error handling. It opens the actual discussion thread, including on first access.
- Autodownload uses the shared current settings, `.channel`, the real channel ID and
  the account network-type signal (the chat's same none/Wi-Fi versus cellular mapping).
  Network and download-setting changes invalidate rows. Telegram's nodes retain their
  usual resource fetching, download controls, spoilers and autoplay behavior. Media
  visibility is restricted to the host row's visible rectangle and active page/app;
  push/tab disappearance, scrolling offscreen, removal and background stop playback.
- Horizontal category tabs switch the current feed controller in place. Hidden
  categories stay in the editor and retain their position/membership; hiding the
  selected category falls back to Main Feed. Eye controls toggle visibility separately
  from opening the editor. Native ItemList reorder handles persist stable category IDs;
  up/down actions remain available in the category detail screen.
- The registry enumerates **all local root/archive channels** through
  `getAllLocalChannels(count: Int.max)`, subscribes to their peer/group data, and keeps
  subscribed broadcast channels only. Activation, Refresh and root/archive chat-list
  changes re-enumerate the registry. There is no 40-channel selection/history cap or
  2,000-chat scan cap. Channels absent from the device's local chat lists cannot be
  discovered by this local API; no claim of server-wide subscription discovery is made.
- Select All uses the full current registry, including matches outside search. Empty,
  archived and category selections remain independent. History requests run with at
  most four in flight. The existing 100 messages/channel, 1,000 visible messages, manual
  Load Older/Refresh and uncertain-history retry limits remain. Counters describe
  **loaded unread messages**, not the Android total unread count. A channel frontier
  prevents known older pages being published ahead of another channel's pending page.

## Read behavior retained

Opening the original post advances the local feed cursor. Merely viewing the feed or
opening its media does not enqueue a source-channel read. Engine read counters also
remove feed unread marks after the source channel was read elsewhere.

Read All captures the eligible selection before its confirmation alert and enqueues
`togglePeersUnreadMarkInteractively(peerIds:setToValue: false)`. It includes unloaded
selected channels and excludes archive unless enabled. The engine reads to the server's
known top through the normal persistent sync path. The completion means local enqueue,
not server acknowledgement; local cursors advance only through known loaded IDs.

For peers hidden by AyuGram ghost settings, confirmation also uses the existing
`ayuReadHistoryOnServer` explicit bypass with its server-only `Int32.max - 1` sentinel.
The sentinel is never persisted as a feed cursor. **Existing limitation:** this helper
returns Void, swallows RPC failures and has no durable retry queue. Offline ghost-mode
source-read acknowledgement is not guaranteed; the UI makes no success claim.

## Root integration requirements

1. Add `//submodules/AsyncDisplayKit:AsyncDisplayKit` to **SGSettingsUI**'s BUILD deps.
   Both new `ExteraFeed*Item.swift` files import it. SGSettingsUI already depends on
   AccountContext, Display, ItemListUI, SGSimpleSettings, SGStrings, SwiftSignalKit,
   TelegramCore, TelegramPresentationData and TelegramUIPreferences. No dependency on
   TelegramUI may be added to SGSettingsUI: the three new shared-context bridge methods
   intentionally keep the existing dependency direction.
2. New `SharedAccountContextExteraFeed.swift` is picked up by TelegramUI's Sources
   glob. It uses AccountContext, ChatMessageItemCommon, ContextUI, Display,
   EntityKeyboard, ReactionSelectionNode, SwiftSignalKit, TelegramCore,
   TelegramPresentationData and TopMessageReactions. These modules are already used
   by TelegramUI's normal chat sources; verify the full Bazel build resolves the
   same module visibility. Do not register another navigation factory in this file.
3. `ExteraFeedHistoryPolicy.swift` is picked up by SGSimpleSettings' source glob.
   Its exact source is also passed to the host tests and feed CI command.
4. Public bridge additions to SharedAccountContext:
   `presentExteraFeedReactionMenu`, `updateExteraFeedReaction`, `openExteraFeedReplies`.
   Each returns a Disposable. The action object gains defaulted `availableReactions`,
   `mediaAutoDownloadNetworkType`, `updateReaction`, `openReactionMenu`, `openReplies`.
   Existing callers need no argument changes. Any independent test mock implementing
   SharedAccountContext must implement the new protocol methods.
5. Preserve the other agent's navigation host. Public entry points remain
   `exteraFeedController(context:)` and `exteraFeedSettingsController(context:)`.
   There is no `news_feed_enabled`/dev/parked-API gate on this local feed; account
   login and local subscribed channels are required. Paid stars require opening
   the original channel. Reactions/comments follow ordinary Telegram permissions.
6. Device preferences remain `ExteraFeedSettings.shared.widePosts` and
   `.showUnreadCounter`, both default true. Keys: `extera.feed.widePosts`,
   `extera.feed.showUnreadCounter`. Account JSON key/schema remains
   `extera.feed.account.<record-id>.v1`; category visibility/order use existing fields.
   The bottom-tab setting belongs to the navigation agent; no new inert flag is added.

## Localization handoff

The controller uses SGStrings `i18n` with English fallbacks. Root should merge these
new/changed keys into en/ru tables; do not retain the old cap40 or text-only descriptions.

| Key | English | Russian |
| --- | --- | --- |
| Extera.FeedFullSelectionInfo | Select All includes every subscribed channel in the local registry, including channels outside the search. | «Выбрать все» включает все подписанные каналы локального списка, в том числе вне результатов поиска. |
| Extera.FeedMediaReadBehaviorInfo | Photos and videos use Telegram's media controls and download settings. Opening the original post marks it read in this feed. Read All asks for confirmation before also marking the selected original channels as read. | Фото и видео используют элементы управления и настройки загрузки Telegram. Открытие исходного поста отмечает его прочитанным в ленте. «Прочитать все» запрашивает подтверждение перед отметкой выбранных исходных каналов прочитанными. |
| Extera.FeedCategoryHidden | Hidden | Скрыта |
| Extera.FeedCategoryVisible | Visible | Видна |

Earlier settings/read-action keys remain required: `Extera.FeedSettings`,
`FeedGeneral`, `FeedWidePosts`, `FeedUnreadCounter`, `FeedSearchChannels`,
`FeedShownChannels`, `FeedHiddenChannels`, `FeedNoMatchingChannels`,
`FeedSelectionMenu`, `FeedSelectAll`, `FeedDeselectAll`, `FeedMarkAllRead`,
`FeedConfirmMarkRead`, `FeedMarkAllReadInfo` (all under `Extera.`). Native reaction
menu/plus accessibility labels reuse generated Telegram strings.

## Validation and acceptance gates

On this Windows host, tree-sitter parses all ten production/interface/test Swift
files and `git diff --check` checks the changed tracked files. These are syntax and
whitespace checks only. Swift/Xcode/XCTest/iOS Simulator are unavailable: the full
app is **not typechecked**, the 22 host tests are **not executed** here, and visual
behavior is **not verified**. Run `Tests/ExteraFeed/README.md`'s exact host command,
then the full Make.py app build from CLAUDE.md after adding the BUILD dependency.

Before recording, expected frames per AGENTS.md:

- Photos, videos, round videos and multi-photo/mixed albums occupy their native
  bubble bounds, without clipping, mirrored content, duplicate attachments or a
  frame of zero-height content. Header and date stay above the bubble; reaction
  controls/comments stay below their own content. Wide/narrow cards keep side insets
  consistent in light/dark, portrait/landscape and iPad layouts.
- Media viewer opens and closes using its native transition. Returning leaves the
  same post in place. A video moving offscreen or a push/tab/background transition
  stops playback; returning resumes only visible eligible media. Test separately
  with autodownload/autoplay enabled and disabled, Wi-Fi and cellular settings.
- The reaction panel appears at its button/chip; expanding the allowed emoji panel
  keeps it inside safe areas. Choosing/removing an emoji updates that chip without
  replacing the whole album/card or jumping the scroll position. Test allowed,
  disallowed, custom emoji, many permitted emoji, existing selected reactions,
  disabled channel reactions and Premium/non-Premium accounts. Stars navigate to
  the source post; no payment is triggered from the feed.
- Tapping comments presents native loading/error/thread UI and opens that post's
  discussion, with back returning to the feed. Test a cold cache, a cached reopen,
  zero-comment post and a removed/inaccessible discussion group.
- Selecting a category changes the selected tab and posts within the same controller
  without stacking another feed screen. Dragging moves one row between neighbors;
  neighbors move together, no row duplicates or disappears. Eye taps never start a
  drag/open action. Hidden tabs disappear, their editor row stays at its stored
  position, and revealing restores that position. Test hidden selected categories.
- Search/select-all work beyond 40 selected channels and beyond 2,000 locally listed
  chats. Load Older adds posts below the known frontier; offline Refresh retains
  usable content and offers retry. Category/archive changes cancel obsolete work.
- Read All dims the feed with Cancel/Mark as Read; Cancel changes no read state.
  Confirm clears only the captured eligible source channels. Future posts remain
  unread. Test source reads elsewhere and offline reconnect (ghost helper caveat above).

Record each applicable open/close path in light/dark, optional content present/absent,
and real speed. Use `simctl io recordVideo`, `tools/animation_sheet.py`, inspect every
labelled frame sheet and flagged frame, and report evidence by frame index/timestamp.
No recording or frame-based acceptance claim is made in this handoff.
