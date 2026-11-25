# Feed settings and explicit channel read action

2026-11-25. Implementation confined to `ExteraFeedController.swift`, `ExteraFeedSettings.swift`, `Tests/ExteraFeed`, and this document. Root-owned settings, localization, navigation, and the feed loader are unchanged by this work.

## Reference and behavior

Read screenshots 09, 10, 11, 13 directly and the existing 01–22 inventory. Read root CLAUDE/AGENTS and TelegramCore State/Messages guides. Android behavior was inspected with `git show HEAD:…` in `C:\Users\PC\exteragram-reference`: `feed/ui/FeedChannelsActivity.kt`, `feed/FeedUnreadTracker.java`, and `ExteraConfig.kt` (the feed directory is not checked out by the sparse checkout). Android defaults confirm wide posts and unread counter default to true; bottom tab defaults to false.

- Feed settings now contain working persisted wide-post and unread-counter toggles. Wide posts use the existing plain/full-width item-list presentation instead of grouped post cards. The counter remains explicitly labelled **loaded unread posts**; this work does not claim the Android total-unread-counter implementation.
- The channel picker has a native editable search row with a clear button and Search return key. Search trims whitespace and matches channel titles case-insensitively. Selected and unselected matches appear in separate sections, with real peer avatars. Selection uses a right-hand checkmark supported by the existing item; it does not reproduce Android's left circular checkbox.
- The selection action sheet has Select All / Deselect All and an iPad popover anchor. Select All replaces membership with all **loaded** channels, including those outside the search. Deselect All clears the entire main/category selection, including unavailable channels. Main/category membership remains independent. The selection is no longer silently constrained to 40; the unchanged history loader still limits loading to 40 and displays its limit notice. Load More Channels retains the existing scan limits.
- Main settings list categories and the create-category action directly. Existing category editing, hide, and up/down actions remain available. Drag reorder and category tabs are not implemented here.
- Read All captures the selected category/main-feed scope before showing confirmation. Cancel has no handler and mutates no state. Confirmation calls `togglePeersUnreadMarkInteractively(peerIds:setToValue: false)` for only selected, currently subscribed eligible channels, excluding archive unless enabled. Its scope includes channels without loaded posts and channels beyond the history loader's 40-channel cap, within the channel registry's existing scan window. It never calls the account-wide `markAllChatsAsRead`.
- That engine method uses the same persisted interactive read operation as the chat-list Mark as Read, including the server-known top ID and ordinary synchronization/retries. The callback means the local operation has been enqueued, not that a server acknowledgement arrived. It is started with `startStandalone` so navigation does not cancel the enqueue. Known loaded IDs advance local feed cursors monotonically after that transaction completes. No `Int32.max` sentinel is persisted to suppress future posts.
- For channels whose read state is hidden by AyuGram, ordinary synchronization deliberately skips the request. The confirmed action therefore also calls the existing public `ayuReadHistoryOnServer(account:peerId:maxId:)` for those peers only. This is the same explicit ghost bypass as Read Message. Its server-only max ID (`Int32.max - 1`) means read through the server's current top; it is never stored in feed settings. **Existing helper limitation:** it returns Void, catches RPC errors internally, and does not persist/retry a failed bypass. Source-channel acknowledgement/offline retry under ghost mode cannot be guaranteed within these permitted files. A durable explicit-read queue would need TelegramCore work. The UI does not display a server-success acknowledgement.
- The feed subscribes to TelegramEngine read counters for peers represented in the loaded post window, so source-channel reads also suppress unread badges/filter matches for posts loaded later. Channel-selection/category settings install no such subscription. Reading a feed page alone does not enqueue source-channel reads.

## API for the root agent

```swift
ExteraFeedSettings.shared.widePosts = value
let wide = ExteraFeedSettings.shared.widePosts
ExteraFeedSettings.shared.showUnreadCounter = value
```

`shared` is a `PresentationSettings` singleton, intentionally distinct from the existing `ExteraFeedSettings(accountId:)` account-state object. Both bools live in the app-group-backed `AyuSettingsStore`, post its normal notification, and default to true. Keys are `extera.feed.widePosts` and `extera.feed.showUnreadCounter`. No account JSON schema change or fake singleton account ID is introduced. The root's feed-wide setting should use this API rather than `ExteraSettings.shared.wideChannelPosts`.

The bottom-tab toggle is **not exposed**: replacing Contacts requires a real navigation host/consumer outside the permitted files. Adding a stored flag without that consumer would create an inert setting. Inline media, download buttons, reaction/comment controls, wallpaper, and floating headers from screenshot 08 remain a renderer integration task; this change does not draw dummy previews.

## Root-owned localization handoff

New keys use English fallbacks until root adds these entries to SGStrings. Existing keys are reused for archive/categories/etc.

| Key | English | Russian |
| --- | --- | --- |
| Extera.FeedSettings | Feed Settings | Настройки ленты |
| Extera.FeedGeneral | General | Основные |
| Extera.FeedWidePosts | Wide Posts in Feed | Широкие посты в ленте |
| Extera.FeedUnreadCounter | Unread Post Counter | Счётчик непрочитанных постов |
| Extera.FeedSearchChannels | Search Channels | Поиск каналов |
| Extera.FeedShownChannels | Shown in Feed | Показаны в ленте |
| Extera.FeedHiddenChannels | Hidden from Feed | Скрыты из ленты |
| Extera.FeedNoMatchingChannels | No matching channels. | Каналы не найдены. |
| Extera.FeedSelectionMenu | Selection | Выбор каналов |
| Extera.FeedSelectAll | Select All | Выбрать все |
| Extera.FeedDeselectAll | Deselect All | Снять выделение |
| Extera.FeedMarkAllRead | Read All | Прочитать все |
| Extera.FeedConfirmMarkRead | Mark as Read | Пометить прочитанным |
| Extera.FeedMarkAllReadInfo | Mark all posts in the feed's channels as read? They will also be marked as read in the original channels. | Отметить все посты в каналах ленты прочитанными? Они также будут отмечены прочитанными в исходных каналах. |
| Extera.FeedBulkSelectionInfo | Select All includes every loaded channel, including channels outside the search. A feed loads up to 40 channels at a time; use categories for larger selections. | «Выбрать все» включает все загруженные каналы, в том числе вне результатов поиска. Лента загружает до 40 каналов; для большего числа используйте категории. |
| Extera.FeedReadBehaviorInfo | Opening a post marks it and earlier posts in that channel as read in the feed. Read All asks for confirmation, then also marks the selected original channels as read. Use Refresh to fetch new posts. Photos, videos, and the full post open in the original channel. | Открытие поста отмечает его и более ранние посты канала прочитанными в ленте. «Прочитать все» запрашивает подтверждение, затем отмечает прочитанными и выбранные исходные каналы. Нажмите «Обновить» для загрузки новых постов. Фото, видео и полный текст открываются в исходном канале. |

## Validation and remaining Mac checks

Tree-sitter Swift parses the production model, controller, and XCTest file without errors; `git diff --check` passes. Swift/Xcode and an iOS simulator are unavailable on this Windows host. These checks are syntax/whitespace checks, not compilation, network testing, or visual validation. Run the existing Mac/CI command in `Tests/ExteraFeed/README.md`; six added model tests cover persistence/isolation of presentation flags, bulk membership above 40, stale categories, archive/category read scope with unloaded channels, and monotonic bounded read cursors.

Before recording on Mac, expected frames: typing filters channel rows while preserving selection; clearing restores both sections; checking a channel moves it between sections without losing the query; category creation/edit/back returns consistently; wide changes the grouped/full-width post presentation; disabling counter removes only the counter; Read All dims the feed and shows Cancel/Mark as Read; Cancel leaves badges and source channels unchanged; confirm clears the selected source channels while excluded/archive channels remain unread. Record these paths in light/dark and narrow/wide layouts per AGENTS.md, inspect labelled frames, and check iPad action-sheet anchoring and keyboard insets. With ghost suppression off, verify offline confirmation queues read sync and reconnect sends it. With ghost suppression on, verify an online confirmed read sends the explicit bypass and Cancel sends none; offline bypass retains the existing helper limitation above. Mark a channel read elsewhere then load older posts and verify they remain read; a later new post must remain unread. No runtime/visual parity claim is made here.
