# Quick-admin: original four chat-header destinations

The mandatory consumer now opens Android's four administrative destinations from the **chat header**. `ChatControllerExteraAdminHeader.swift` supplies native menu items and routing; `ExteraAdminHeaderPolicy.swift` defines their actual visibility/destination policy. Root applied the three host hooks and integrated the default-true Chats switch, strict Boolean backup/reset, three EN/RU strings and the 17-test CI command. Full compilation and runtime/frame acceptance remain pending.

The previous author-only handoff did not cover this feature. The message-author menu remains deferred: **do not apply `extera-admin-author-menu.patch` in this wave**. Its retained helper, 14 policy tests and previous notes are recorded in `extera-admin-author-next-wave.md`; they are not counted as completion of the Android port.

## Reference, destinations and roles

Targeted cached Android reads: `ExteraConfig.kt` declares `quickAdminShortcuts by BooleanPref(true)`; `ChatsPreferencesActivity.kt` exposes `ADMIN_SHORTCUTS`; `ChatActivity.java` adds the four-item row when the current chat is a channel/megagroup/gigagroup, the account is creator/admin, and the chat is not a monoforum. `onAdminShortcutsClick` selects TYPE_KICKED for ordinary supergroups' Permissions and TYPE_BANNED for broadcast/gigagroup; the other three paths open admin/member lists and the admin log.

| Android slot | iOS native destination | Native title |
| --- | --- | --- |
| Permissions — supergroup, including forums | `channelPermissionsController` | `GroupInfo_Permissions` |
| Permissions — broadcast or gigagroup | `channelBlacklistController` | `GroupInfo_Permissions_Removed` |
| Administrators | `channelAdminsController` | `GroupInfo_Administrators` |
| Members | `channelMembersController` | `Channel_Info_Subscribers` for broadcast, `Group_Info_Members` otherwise |
| Recent Actions | `sharedContext.makeChatRecentActionsController(context:peer:adminPeerId:nil, starsState:nil)` | `Group_Info_AdminLog` |

The four slots stay in Android order: Permissions, Administrators, Members, Recent Actions. iOS uses native action rows, rather than Android's horizontal icon row. For broadcast/gigagroup, the first row is explicitly titled Removed Users to match its destination rather than suggesting editable supergroup permissions.

These are **section-view routes**, not ban/promote/delete operations. The native PeerInfo policy exposes them to owners and admins, including admins without `canAddAdmins` or `canBanUsers`. The header applies the same role gate; it does not invent an add-admin right requirement for viewing the administrator list. Granular changes remain in the native controllers and require the user's own explicit interactions and server authorization. No header action performs a mutation.

Native sources inspected: `PeerInfoProfileItems.swift` around 1384–1432 (broadcast sections) and 1682–1732 (supergroup sections); `PeerInfoScreen.swift` around 4481–4533 (members/admins/banned/permissions routes); `PeerInfoScreenOpenChat.swift` around 265 (admin log). `ChannelMembersController` gates member editing with ban rights and adding with invite rights; `ChannelAdminsController` gates adding/editing with native admin hierarchy rules; the permissions screen enables individual rights according to `hasPermission`. The existing blacklist screen relies on server authorization for its removal/unban operations; this patch does not change that screen's UI policy.

## Host patch: existing Info and More entry points

```sh
git apply --check docs/integration/extera-admin-header-menu.patch
git apply docs/integration/extera-admin-header-menu.patch
```

There are three small hooks:

1. **Header Info/avatar context menu** in `ChatController.swift` around 6540: merge the four items into the existing `items` signal. This is the avatar of the chat in the navigation header, not a message author's avatar. Native profile/gallery anchoring, Search, Statistics and existing dismissal/read-state handling remain in that host.
2. **Header More** in `ChatController.swift` around 6571: for an eligible admin, show the four native actions and a native More row that opens the existing forum More menu. This retains its topic/message view switches, profile, invite, search, create-topic and cached-export actions without modifying frozen ChatListUI. Disabled/member/unavailable-server paths use the existing menu directly. This deliberate extra level for the old forum actions is the only More-menu layout adaptation.
3. **Forum side-list More** in `Chat/ChatControllerSideList.swift` around 407: append the same four items to its existing native menu signal. This covers forum chats whose navigation header uses the sidebar button instead of the Info avatar. Existing topic/mute/invite/select actions remain in place.

No new buttons or gestures are added. Ordinary header taps still open the native profile. Menu rows appear together after the first server result; no late-inserted admin section is used. Calls wait at most three seconds, then the existing base menu wins. Root can integrate this patch independently of the deferred author patch.

The source handoff kept root-owned files unchanged. Root subsequently applied the three header hooks and the settings/localization/backup/workflow integration. The deferred author patch remains unapplied.

## Live authorization

The cached owner/admin gate only avoids network traffic for ordinary viewers. Before exposing sections, the helper runs `fetchAndUpdateCachedPeerData` and `fetchChannelParticipant` for the current account, then reads the refreshed channel metadata used by the native screens. Both requests must succeed; cached creator/admin flags cannot grant access.

Unknown participant, member/nonmember/removed actor, unsupported/private/basic group, monoforum, inaccessible chat, frozen account, selection mode, mismatched current peer and disabled switch produce no header items. Basic groups are excluded because Android's actual consumer excludes them, even though native iOS has some basic-group management screens.

When a row is selected, the context menu fully dismisses, metadata and the account's server role are fetched again, and the selected **action plus destination** must still be present. Revoked rights, disabled preference, peer changes and a supergroup-to-gigagroup conversion invalidate a stale selection. The native destination receives the correct current peer ID; the admin log also receives its refreshed EnginePeer. There is no new engine mutation or automatic confirmation bypass.

## Settings and backup contract for root

| Item | Contract |
| --- | --- |
| API | `ExteraAdminSettings.shared.quickAdminShortcuts: Bool` |
| Key | `extera.chat.quickAdminShortcuts` |
| Key constant | `ExteraAdminSettings.quickAdminShortcutsKey` |
| Default/reset | **true**, matching Android; `ExteraAdminSettings.shared.reset()` |
| Notification | `ayuSettingsDidChangeNotification` after the explicit write |
| Backup type | Strict JSON Boolean |
| Restore | Set the property; raw defaults writes bypass its cache |

The first explicit default write persists; identical subsequent writes are suppressed. The recursive lock protects cache and persistence, with the cache published before `UserDefaults.set`. Invalid local storage falls back to the Android default; backup validation must reject invalid JSON types. Root adds the switch after accepting this actual consumer.

Only three SGStrings keys are needed in this wave; all destination titles and More/OK already come from Telegram strings:

| Key | EN | RU |
| --- | --- | --- |
| `Extera.Admin.QuickShortcuts` | Quick admin actions | Быстрые действия администратора |
| `Extera.Admin.QuickShortcutsInfo` | Open permissions, administrators, members and recent actions from the chat header menu. | Открывайте разрешения, списки администраторов и участников, а также недавние действия из меню заголовка чата. |
| `Extera.Admin.Unavailable` | This section is no longer available. Your permissions or the chat type may have changed. | Этот раздел больше недоступен. Возможно, изменились ваши права или тип чата. |

The earlier author-confirmation keys are **not required** for this wave.

## Dependencies and checks

Existing `SGSimpleSettings` and `TelegramUI` source globs include the new Swift files. All helper imports already exist as TelegramUI dependencies: AccountContext, ChatPresentationInterfaceState, ContextUI, Display, PeerInfoUI, SGSimpleSettings, SGStrings, SwiftSignalKit, TelegramCore and TelegramPresentationData, plus system Foundation/UIKit. Recent Actions uses the existing SharedAccountContext factory; no framework API/dependency edge was added.

Current-wave tests: **10 header policy + 7 settings tests**. The retained author policy adds 14, for **31 total** if root runs the complete directory. The header tests cover all four slots/order, supergroup vs broadcast/gigagroup routing, owner/admin visibility, unknown/member/removed/monoforum/basic-group denial, switch disabling, revoked role, and stale destination after conversion. Commands are in `Tests/ExteraAdmin/README.md`.

Windows verification: all **eight** production/test Swift files pass tree-sitter parsing; `git apply --check` passes for the three-hunk header patch; both hypothetical patched host files parse in memory without writing either source. All five menu assets exist and current-wave whitespace checks pass. The mandatory 17-test host command was attempted and stopped with `swift is unavailable`. Swift/Xcode is absent, so XCTest execution, Swift typecheck, the full supported iOS build and actual runtime/simulator recordings remain pending. Do not report prepared XCTest methods as passed tests.

## Expected frames before recording

Follow `AGENTS.md`: record real-speed open, dismiss and navigation paths with `simctl io recordVideo`, produce timestamped sheets with `tools/animation_sheet.py`, and inspect the frames. Expectations:

1. EN/RU Chats settings corresponding to Android 51/86 show the existing-style switch enabled by default. Its explanation names the header sections, not author moderation.
2. Supergroup owner/admin opens header Info: existing profile/search/statistics items remain, followed by one separator and the four actions in Android order. The chat avatar preview stays anchored; no intermediate empty menu or late row insertion appears.
3. Broadcast/gigagroup opens the same section: Removed Users replaces Permissions; Members uses the broadcast subscriber label where appropriate. Each row opens its exact native screen, not generic PeerInfo.
4. Forum sidebar More includes the four rows after its current actions. Legacy header More shows the four rows followed by More; selecting More dismisses the first menu, then opens the existing native forum menu without overlapping sheets. Test both forum presentations and a topic.
5. Disabled switch, ordinary member, unknown/failed server role, private/basic group, monoforum and inaccessible chat show no admin section. No dangling separator remains.
6. Revoke admin role or disable the switch while a menu is open; selecting a stale row must not push an admin section. Convert the supergroup to gigagroup before selecting Permissions; the stale selection must not silently open a different destination.
7. Validate all four destinations as owner and restricted admin. Opening a destination changes nothing. Back/Cancel changes nothing. Any later moderation follows the existing native user interaction and server permission checks.
8. Check EN/RU, light/dark, large text, with/without chat photo, normal group/broadcast/gigagroup/forum, and both opening and closing. No clipping, duplicate preview, anchor jumps or menu/editor overlap is acceptable.

No actual account/group moderation has been performed. There are no recorded frame references yet; visual completion remains unverified until macOS capture.
