# Author moderation: deferred next wave

**Deferred: do not apply the author patch in the current quick-admin port.** The mandatory Android-equivalent chat-header implementation and root instructions are in `extera-admin-shortcuts.md`. The material below records the earlier author-only work for a future optional wave; it does not satisfy Android's four shortcuts and is not enabled by the current header patch.

Status: settings, rights policy, native-flow helper and 21 host tests are implemented in separate files. The author-menu hook is supplied as a patch for root; it has not been applied to the shared `ChatController.swift`. Until that patch and the settings row/strings are integrated, this feature is not reachable in the app. No commits or pushes were made.

## Reference and adaptation

Android `ExteraConfig.kt` declares `quickAdminShortcuts by BooleanPref(true)`. `ChatsPreferencesActivity.kt` exposes `ChatsItem.ADMIN_SHORTCUTS`. The actual `ChatActivity.java` consumer adds Permissions, Administrators, Members and Recent Actions to the chat-header menu, then `onAdminShortcutsClick` opens their native screens.

This implementation follows the assigned iOS adaptation: moderation shortcuts for a group-message author's avatar menu. It does not claim that Android frames 51/86 show this author menu. Those settings frames should gain the quick-admin switch in the corresponding Chats section.

## Setting and backup contract

| Item | Contract |
| --- | --- |
| API | `ExteraAdminSettings.shared.quickAdminShortcuts: Bool` (read/write) |
| UserDefaults key | `extera.chat.quickAdminShortcuts` |
| Key constant | `ExteraAdminSettings.quickAdminShortcutsKey` |
| Default and reset | `true`; `ExteraAdminSettings.shared.reset()` |
| Storage | App-group defaults, matching the surrounding settings |
| Change notification | `ayuSettingsDidChangeNotification`, posted after the write |
| Backup JSON value | Strict Boolean only; add to root's Boolean allowlist |
| Restore/reset integration | Set the public property; raw defaults writes bypass its cache |

The first explicit write of `true` persists even when the preference was absent. Only genuine stored CFBoolean values are accepted; invalid local storage falls back to Android's default. Backup validation must reject invalid JSON types rather than coercing them. Cache access and persistence share a recursive lock, and the cache is published before `UserDefaults.set` so synchronous defaults observers see the new value.

Root adds the settings switch with `Extera.Admin.QuickShortcuts` and optional explanatory text `Extera.Admin.QuickShortcutsInfo`, using the property above. Disabling the preference immediately blocks future actions, including an already-open destructive confirmation. No account permissions are changed by the preference.

## Shared-file hook

The existing entry point is `ChatController.swift`, `controllerInteraction.openPeerContextMenu` (around line 4837). The existing avatar source in `Components/Chat/ChatMessageItemImpl/Sources/ChatMessageDateHeader.swift` already calls this interaction, so that component needs no edits.

Root applies:

```sh
git apply --check docs/integration/extera-admin-author-menu.patch
git apply docs/integration/extera-admin-author-menu.patch
```

The patch combines the existing author/message signal with `strongSelf.exteraAdminShortcutItems(authorId: peer.id)` and appends the returned menu items after the standard profile/message/mention/search items. The helper supplies its own separator only when at least one action exists. It waits at most three seconds for fresh server data, then falls back to the ordinary menu. It has no additional gesture or custom animation.

This hooks the avatar entry point. A separate author-name long-press gesture is not added: the occupied bubble component's name path does not currently call `openPeerContextMenu`. If root/that component's owner later connects such a gesture to the same interaction, it will receive exactly the same rights policy and actions. Ordinary taps retain their current behavior.

Navigation files, `SGSettingsController.swift`, EN/RU strings, backup sources, BUILD files and workflows have not been edited for quick-admin. The two occupied date-header/bubble components have not been edited.

## Native actions and rights

| Action | Supergroup | Basic group |
| --- | --- | --- |
| Promote | Owner or `canAddAdmins`; opens `channelAdminController` | Owner only; opens the same native editor |
| Restrict | Owner or `canBanUsers`; opens `channelBannedMemberController` | Hidden |
| Ban | Owner or `canBanUsers`; native alert, then the existing member categories manager with `banReadMessages` | Hidden |
| Remove member | Hidden (Ban is the explicit permanent operation) | Owner or `canBanUsers`; native alert, then `engine.peers.removePeerMember` |
| Delete all author's messages | Owner or `canDeleteMessages`; native alert, then `engine.messages.clearAuthorHistory` | Hidden |

All shortcuts exclude self, owner, other administrators, removed participants and unknown participant state. This is deliberately more conservative than the full profile's editable-admin hierarchy. Deleted users, channel identities, broadcasts, private chats, custom chat contents, monoforums, inaccessible chats and frozen accounts are excluded. The existing profile actions remain the place for admin hierarchy changes.

Supergroups fetch both actor and target using `engine.peers.fetchChannelParticipant`; permissions come from the returned actor participant, not cached channel admin rights. Basic groups require a successful `fetchAndUpdateCachedPeerData`, then read the fresh peer and participant list together. Unknown or failed server results produce no actions. The initial cached admin gate saves requests for ordinary viewers but never grants authority.

The helper fetches again when a menu action is selected. For Ban/Remove/Delete it shows a native `textAlertController` with explicit target and group, then fetches a third time after the destructive confirmation. If actor rights were revoked, the target became an administrator/owner, the setting was disabled, or the chat changed, it does not issue the mutation. API-level permission enforcement still applies to races after the final response.

Promote/restrict hand off to the normal native editors after the execution-time fetch; their explicit Save/Done actions and engine/server checks remain in force. The basic-group admin editor can convert the group when the user chooses custom rights/rank, just as its existing native path does. The provided upgrade callback navigates to the resulting group. Ban and history removal never perform a conversion.

History clearing is for the entire supergroup, including other topics, and for everyone; the confirmation states this explicitly. Only `clearAuthorHistory` is called: it performs its local deletion after server success. There is no preceding optimistic `deleteAllMessagesWithAuthor`, automatic action, undo timer or success toast. The reused mutation APIs expose `NoError` and can complete silently on server rejection; this helper therefore does not claim a successful mutation on completion.

## Localization for root

Existing Telegram strings provide all menu titles, Cancel and OK. Add the following SGStrings entries; `%1$@` is the author name, `%2$@` the group title. Use the same placeholders in EN/RU.

| Key | English | Russian |
| --- | --- | --- |
| `Extera.Admin.QuickShortcuts` | Quick admin actions | Быстрые действия администратора |
| `Extera.Admin.QuickShortcutsInfo` | Show moderation actions when you hold a member's avatar in a group you manage. | Показывать действия модерации при удержании аватара участника в группе, которой вы управляете. |
| `Extera.Admin.Unavailable` | This action is no longer available. Your permissions or this member's status may have changed. | Это действие больше недоступно. Возможно, изменились ваши права или статус участника. |
| `Extera.Admin.ConfirmBan` | Ban %1$@ from “%2$@”? They will not be able to rejoin until an administrator unbans them. | Заблокировать %1$@ в группе «%2$@»? Участник не сможет вернуться, пока администратор не снимет блокировку. |
| `Extera.Admin.ConfirmRemove` | Remove %1$@ from “%2$@”? | Удалить %1$@ из группы «%2$@»? |
| `Extera.Admin.ConfirmDeleteMessages` | Delete all messages from %1$@ in “%2$@” for everyone, across all topics? This cannot be undone. | Удалить все сообщения от %1$@ в группе «%2$@» для всех участников и во всех темах? Это действие нельзя отменить. |

## Dependencies and checks

The existing `SGSimpleSettings` and `TelegramUI` BUILD rules glob `Sources/**/*.swift`. The helper uses existing TelegramUI dependencies: AccountContext, ChatInterfaceState, ChatPresentationInterfaceState, ContextUI, Display, PeerInfoUI, SGSimpleSettings, SGStrings, SwiftSignalKit, TelegramCore and TelegramPresentationData; UIKit/Foundation are system imports. No new dependency edge is needed. Root should still run the full supported iOS build to typecheck the helper against module interfaces.

There are 14 policy and 7 settings XCTest methods. Policy tests cover independent permissions, owner/self/administrator protection, unknown server state, revoked rights and legacy limitations. Settings tests cover default/persistence/reset, strict Boolean storage, notification deduplication, reentrant reads and concurrent writes. Exact host commands are in `Tests/ExteraAdmin/README.md`.

Local Windows verification: tree-sitter Swift parsing passes for all five new Swift production/test files. `git apply --check` passes for both integration hunks, and parsing the hypothetical patched `ChatController.swift` in memory also passes without writing the shared file. Whitespace checks pass for the eight new source/test/documentation files. XCTest was attempted and stopped because `swift` is unavailable. No XCTest pass, Swift typecheck, iOS build or simulator verification is claimed. Root must add this test group to its workflow if desired; the workflow is root-owned.

## Expected recorded frames, before runtime verification

Per `AGENTS.md`, record the real native open/close paths with `simctl io recordVideo`, then inspect timestamped sheets from `tools/animation_sheet.py`. These are expectations, not measured frames:

1. EN/RU Chats settings corresponding to Android frames 51/86: a default-enabled quick-admin switch uses the existing row style. Turning it off removes the moderation section on the next author-menu open.
2. Authorized supergroup owner holding an ordinary member avatar: the normal avatar/profile preview and normal menu animation remain; one separator precedes Promote, Restrict, Ban and Delete all messages. Ban and Delete use native destructive coloring. The entire list appears as one menu; no late inserted rows, duplicate previews or intermediate empty menu.
3. An admin with only delete permission sees only the history action; one with only ban permission sees Restrict and Ban; an ordinary viewer sees the existing menu with no admin separator.
4. Self, owner, another admin, anonymous/channel author, private chat, broadcast, unavailable participant fetch and monoforum: no moderation section. Normal profile/message actions still appear.
5. Basic group owner sees Promote and Remove; a permitted admin sees Remove. Restrict, Ban and history deletion are absent.
6. Selecting Ban/Remove/Delete closes the context menu fully before the native confirmation appears. Target and group are legible in EN/RU, light/dark and large text. Cancel produces no mutation. History text explicitly covers everyone and all topics.
7. Revoke permissions, promote the target or disable the setting while confirmation is open; confirm afterward. No mutation occurs. An unavailable-rights alert may appear; disabling the setting exits without a mutation.
8. Promote/Restrict opens the native editor with the correct target and current participant state. Back/Cancel does not save. Test basic-group promotion's default save and the native custom-rights conversion callback separately.
9. Repeat avatar-menu opening with/without a profile photo and in a forum topic; inspect both menu dismissal and editor/alert presentation for overlapping sheets, clipping, duplicate frames or incorrect anchor geometry.

Simulator recording and destructive end-to-end actions require an authorized test group/account on macOS. They remain pending; no actual participant was changed during this implementation.
