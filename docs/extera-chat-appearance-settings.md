# Chat appearance settings: frames 68–81

Public entry point in `AyuGram/SGSettingsUI/Sources/ExteraChatAppearanceSettingsController.swift`:

```swift
(controller.navigationController as? NavigationController)?.pushViewController(
    exteraChatAppearanceSettingsController(context: context)
)
```

The category/root controller owns the `.chatSettings` link. New UI and settings sources are included by the existing `Sources/**/*.swift` BUILD globs. TelegramStringFormatting already depends on SGSimpleSettings, and LocationUI already depends on TelegramStringFormatting. The microphone continuation adds a direct UI import of TelegramAudio: root must add `//submodules/TelegramAudio:TelegramAudio` to SGSettingsUI's dependencies. This task does not edit BUILD files.

Each reference image 68–81 was opened individually, alongside `extera-reference-screens-67-87.md`, root `CLAUDE.md` / `AGENTS.md`, and `TelegramUIPreferences/CLAUDE.md`.

## Working controls and persistence

| Reference | Implementation and existing consumer |
| --- | --- |
| 68–74, two/three lines | Side-by-side selectable previews write `SGSimpleSettings.shared.chatListLines` (`"2"` / `"3"`). ChatListUI consumes the existing setting. An existing one-line value is preserved, with neither preview selected, until an explicit selection. No preference migration or backup changes. |
| 68, partially visible text-size slider | Working native text-size entry through `themeSettingsController(context:focusOnItemTag: .fontSize)`; the native screen owns its font-size controls. |
| 68–74, application icon | `exteraAppIconController(context:)` opens the existing extera icon screen. |
| 68–72, swipe choice | Local `ExteraChatSwipePreviewItem` combines a real six-row `UIPickerView` with a preview of the selected action. Writes `ExteraChatAppearanceSettings.shared.swipeAction`; ordinary ChatListItem rows consume it when constructing their reveal options. |
| 73–74, automatic night theme | `themeAutoNightSettingsController(context:)`; displayed mode uses `currentModeAutomaticThemeSwitchSetting.trigger`, respecting the bubble-mode guide. |
| 73–74, browser | `webBrowserSettingsController(context:)` owns the real account browser setting and exceptions. A disclosure is used because current iOS behavior includes account-side `AccountWebBrowserSettings.openExternalBrowser`, local browser choice and exceptions; a single local boolean would not represent it. |
| 75–77, animations | `energySavingSettingsScreen(context:)` owns actual iOS effects, thresholds and grouped controls. No Android-only effect switches. |
| 78, stickers and emoji | `sharedContext.makeInstalledStickerPacksController(context:mode: .general, forceTheme: nil)` exposes real account packs, quick reactions and native sticker settings. |
| 74, 79, tap at media edges | `updateMediaDisplaySettingsInteractively`, `withUpdatedShowNextMediaOnTap`; consumed by the native gallery. |
| 74, 79, raise to listen | `updateMediaInputSettingsInteractively`, `withUpdatedEnableRaiseToSpeak`; same model and label as native Data and Storage. |
| 74, 79, pause while recording | `updateMediaInputSettingsInteractively`, `withUpdatedPauseMusicOnRecording`; consumed by voice recording, legacy media recording and VideoMessageCameraScreen. |
| 79, 81, microphone | Persisted automatic/builtin/headset selector reads actual `AVAudioSession.availableInputs`; active recording sessions apply `setPreferredInput`, reapply on route changes, and fall back to automatic when unavailable. A separate application-settings link manages permission. See [recording microphone policy and acceptance](extera-recording-microphone.md). |
| 79, Direct Share | iOS 13+ `intentsSettingsController(context:)`: suggested chats, chat categories, account choice and suggestion reset for the system Share interface. |
| 79, Enter | Native `ChatSettings.sendWithCmdEnter`, updated with `withUpdatedSendWithCmdEnter`, exposed with the native **Command-Enter** label on iOS 13.4+. This is the existing hardware-keyboard behavior. |
| 80, distance units | Native one-from-many sheet persists automatic/kilometers/miles. Both shared distance formatters in `TelegramStringFormatting/Geo.swift` apply the selection on every call; `LocationDistancePickerScreen` uses the same preference for its radius controls. Engine distances remain in meters. |

Media/chat preferences are observed through account-manager shared data. Presentation data drives light/dark theme and language updates. Returning from linked settings refreshes the page. The preview publishes the standard `ItemListNeighborFacet` through `ItemListItem`, respects both side insets, measures multiline labels, and exposes both alternatives as selected-state accessibility buttons.

## Swipe runtime and stored preferences

The new model `AyuGram/SGSimpleSettings/Sources/ExteraChatAppearanceSettings.swift` uses the existing cached app-group `AyuSettingsStore`:

| Key | Values | Default |
| --- | --- | --- |
| `extera.chatAppearance.swipeAction` | `folder`, `pin`, `read`, `archive`, `mute`, `delete` | `archive` |
| `extera.chatAppearance.distanceUnit` | `automatic`, `kilometers`, `miles` | `automatic` |
| `extera.chatAppearance.microphone` | `automatic`, `builtin`, `headset` | `automatic` |

Unknown stored values fall back to these defaults. All setters publish the existing settings notification. Root owns backup integration; the additional microphone handoff is `ExteraChatAppearanceSettings.microphoneKey` with the three values above.

`ItemListRevealOptionsItemView.handleRevealGesture` executes the last right-edge option on a full leftward swipe. `ChatListItem` moves the selected **available** native action to that position, removing its duplicate on the left. It retains the original option, including its title, icon, destructive flag and callback key. Read/unread, pin/unpin, archive/unarchive, mute/unmute and delete therefore use the existing engine callbacks, pin limits, confirmation/undo flows and availability checks. If the chosen action is unavailable, both native option lists are preserved; for example, disabled delete or disabled unarchive is never synthesized. Archives offer only their existing native actions, so choosing read or mute there can fall back to the native full-swipe action.

Customization applies to nonediting `.auto` chat-list rows, including ordinary rows inside filters and the archive. It excludes community containers, forum-topic lists, Saved Messages sublists, promoted/custom-message rows and explicit custom-action rows. Inline navigation retains its existing suppression of reveal actions. A Saved Messages peer appearing in the main list retains its native action availability.

Folder means **switch the displayed chat-list folder**, as in reference frame 72. On root chat-list rows its action opens an action sheet of available filters and calls `switchToFilter`; it does not change the swiped chat's folder membership. The picker respects the container's folder limit and rechecks availability when tapped. Without user folders it opens the native folder settings screen. `ChatListControllerNode` installs the callback on its active item node and clears it from the previous node. Folder option construction is independent of callback installation, allowing preloaded rows to retain the action after switching filters.

`ChatListNode` observes swipe changes through its existing local-settings signal and forces updated entries even if the chat data itself has not changed. The wheel keeps the saved selection on reopen and updates its drawn action immediately.

## Distance runtime

Each call to `stringForDistance` and `shortStringForDistance` updates the cached `MKDistanceFormatter.units` to `.default`, `.metric` or `.imperial`. Locale still controls language and number spelling. A shared lock protects the cached formatter's locale, unit selection and formatting as one operation. Proximity controls use explicit metric/imperial overrides and preserve their native automatic-region rule, including miles for Great Britain. Labels already rendered by other screens update at their next normal render or reopening; this change does not add a global screen refresh. The current proximity picker initializes its step/radius presentation on opening, so reopen it after changing the preference.

## Translation keys for the root integration agent

No language files are edited by this task. Existing `Extera.ChatSettings`, `Extera.ListOfChats`, `Settings.ChatList.Lines.2`, `Settings.ChatList.Lines.3`, and native Telegram presentation strings are reused. The first four keys below are already present from root integration; the seven swipe/distance keys still need root integration in both languages:

| Key | English | Russian |
| --- | --- | --- |
| `Extera.ChatAppearance.MediaAndSound` | Media and Sound | Медиафайлы и звук |
| `Extera.ChatAppearance.Microphone` | Microphone | Микрофон |
| `Extera.ChatAppearance.MicrophoneInfo` | Manage microphone permission in iOS Settings. | Разрешение на микрофон в настройках iOS. |
| `Extera.ChatAppearance.ShareInfo` | Suggested chats in the iOS Share menu. | Предложения чатов в меню «Поделиться» iOS. |
| `Extera.ChatAppearance.SwipeTitle` | Swipe Left | Свайп влево |
| `Extera.ChatAppearance.SwipeFolder` | Switch Folder | Сменить папку |
| `Extera.ChatAppearance.SwipeInfo` | A full swipe performs the selected action when available. Otherwise the chat's standard actions apply. | Полный свайп выполняет выбранное действие, если оно доступно. Иначе используются стандартные действия чата. |
| `Extera.ChatAppearance.DistanceUnits` | Distance Units | Мера расстояния |
| `Extera.ChatAppearance.Distance.automatic` | Automatic | Автоматически |
| `Extera.ChatAppearance.Distance.kilometers` | Kilometers | Километры |
| `Extera.ChatAppearance.Distance.miles` | Miles | Мили |

The microphone continuation's eight additional keys are listed in [its integration handoff](extera-recording-microphone.md#root-integration).

## Explicit differences and gaps

- **75–77: exact effect taxonomy.** The native energy screen is a working iOS equivalent. Android-specific group totals, transitions, deletion animation and side-menu effect names are not claimed to match that screen.
- **79: pause music when launching media.** No matching toggle/model was found in `TelegramUIPreferences` or existing extera media settings. Recording pause is not relabeled as playback pause. No unused boolean is introduced.
- **81: microphone hardware limits.** The selector is implemented, but only inputs actually reported by iOS are selectable. Inactive playback categories can report no inputs; settings do not start a session to discover them. Bluetooth microphone profiles can change output and recording quality. The existing system-microphone debug override remains authoritative and is explained when enabled. No independent Bluetooth input/output or Android noise-processing equivalence is promised.
- **79: sensitive content.** No local “18+” switch is added: visibility is an account/server capability and needs a dedicated settings flow with capability/loading/error handling. No bypass is implied.
- **79: sending on Enter.** Command-Enter keeps the native semantics; this page does not alter the software keyboard's Return key.

## Validation and visual acceptance

`web-tree-sitter` with the Swift grammar parsed all ten implementation files and three XCTest sources with zero ERROR or missing nodes. Scoped `git diff --check` reported no whitespace errors. Native method signatures and preference consumers were checked against this checkout. The host XCTest commands in `Tests/ExteraChatAppearance/README.md` were attempted: the model suite is blocked by the missing Swift host toolchain, and the formatter suite requires macOS MapKit. TelegramAudio's native tests also require the unavailable iOS toolchain. No XCTest pass is claimed. Windows has no Xcode, iOS SDK or simulator, so the full Bazel iOS build, API typecheck, accessory tests and recorded-frame review remain unverified. The syntax-tree parse is a limited syntax check, not a substitute for these checks.

Before a simulator recording, expected frames are: two equal-width chat-list preview buttons with two/three strokes; exactly one selected radio for a two/three-line value; no selected radio for an existing one-line value. The swipe wheel scrolls vertically and settles on one saved action; its preview changes to that action while the card and neighboring rows stay still, with no wheel reset or clipping. The distance sheet highlights the saved unit and dismisses after selection. The icon, browser, auto-night, energy, sticker and Share entries must push their actual screens and return to the same scroll position. Verify light and dark themes, Russian and English, large text, asymmetric safe insets and VoiceOver selected state. Follow `AGENTS.md` for recording and indexed frame-sheet evidence; no pixel/animation equivalence is asserted without it.

Runtime acceptance must also exercise all six actions, inverse native states, existing/disabled actions, pin-limit and delete confirmation, archive/filter/Saved Messages/community/forum/editing exclusions, filter preloading and returning to a cached list. Verify a metric and imperial device region, returning to automatic, both long/short map labels, and a reopened proximity picker. Model tests cover ordering/persistence/locale policy; they cannot establish that the app's native callbacks or visual transitions run correctly.
