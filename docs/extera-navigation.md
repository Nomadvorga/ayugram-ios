# exteraGram navigation: integration and validation

Scope: Android reference frames 23, 25–29, visually read from the original Downloads
images; Android `AppNavigationPreferencesActivity.kt` and `config/BottomNavigationBar.kt`
read using `git show HEAD:…` in `C:\Users\PC\exteragram-reference`.

## Implemented consumers

- `exteraNavigationSettingsController(context:) -> ViewController` in SGSettingsUI is
  the public editor. It persists immediately and supports native drag handles for
  tab/menu order, tap-to-hide/show, multiple uniquely identified dividers and reset.
- `TelegramRootController` consumes the ordered tab IDs; Contacts, Calls, News and
  Feed are optional. Chats and Settings are permanent escape routes and can be
  reordered. Removing a selected optional tab selects Chats; controller identity is
  retained across reorder and Feed visibility changes. Server News remains gated by
  `newsFeedApiIsAvailable`: the editor does not offer it while the API is parked and
  even restored/customized IDs cannot bypass that gate. Feed stays independent.
- Feed is a separate local channel-history screen, **off by default**. The host uses
  `SharedAccountContext.makeExteraFeedController(context:) -> ViewController?`.
  `SharedAccountContextImpl` implements this in a separate file importing SGSettingsUI;
  AccountContext's default implementation returns nil for lightweight test hosts.
  No ExteraFeed implementation files were edited and News is not substituted for Feed.
- The actual ChatListHeader gets an additional `exteraNavigation` action through
  `ChatListControllerImpl.exteraOpenNavigationMenu`; Compose/Story/Proxy stay intact.
  UIKit navigation items on other root pages also receive a menu action. With the bar
  hidden, a bottom menu button remains available on other root pages, including pages
  that draw custom headers. A fixed Chats action is included while the bar is hidden;
  it is a host escape route and does not add an ID to the persisted menu schema.
- The menu consumes visible order and visibility, including actual sidebar separators.
  Profile, ghost, archived chats, group creation (participant selection first), Saved Messages, Settings, Feed,
  Contacts, channel creation, Calls, browser preferences and QR scanner route to real
  app functions. Wallet is enabled only when the account has a wallet context, to
  avoid the existing wallet factory's fatalError on unsupported accounts.
- Sidebar uses a left-edge swipe on the **root tab host**, a dimmed scrollable drawer,
  tap-outside/left-swipe dismissal and VoiceOver modal containment. Pushed chats retain
  their Back gesture. Immersive mode selects a longer damped spring; Reduce Motion
  suppresses the added drawer animation.
- Show/Hide/Floating affect the real tab host. Show docks a full-width glass bar above
  the home indicator with a continuous background to the bottom; Floating uses the
  existing inset glass capsule. Vertical iPhone Duo tab placement remains adaptive.
  `showsLabels`/`fillsAvailableWidth` are explicit TabBarComponent inputs, included in
  equality, so live changes cannot be suppressed by component caching.
  ChatList, Contacts, PeerInfo, filter-tab controls and News restore this configured
  visibility after their temporary search/edit hiding; they no longer consult the
  retired `hideTabBar` flag for runtime layout decisions.
- Tablet Auto preserves the window's width class; Off supplies compact layout to the
  real root navigation container; On enables its regular two-column layout at an
  actual available width of at least 700pt. Size, safe areas, reserved corners and
  windowSize are preserved. The setting updates layout live and does not scale a phone
  UI down to pretend to be a tablet.

## API and storage contract for root integration

Model: `AyuGram/SGSimpleSettings/Sources/ExteraNavigationSettings.swift`.

```swift
ExteraNavigationSettings.shared.configuration
ExteraNavigationSettings.shared.update { configuration in /* compound edit */ }
ExteraNavigationSettings.shared.configurationJSON
ExteraNavigationSettings.isValidConfigurationJSON(json) // pure, strict
ExteraNavigationSettings.shared.restoreConfigurationJSON(json) // Bool
ExteraNavigationSettings.shared.reset()
```

Storage key: **`extera.navigation.configuration`**, JSON string in the existing app
group defaults. Add one backup descriptor with the strict validator and restore setter.
The descriptor must call `restoreConfigurationJSON`; direct defaults writes bypass the
model cache. The root owner integrates ExteraSettingsBackup and localization catalogs.

The exact nine JSON fields are `barMode`, `tabletMode`, `hideLabels`, `sidebar`,
`immersiveSidebar`, `tabsCustomized`, `tabs`, `menu`, `hiddenMenu`. Bar raw values are
0 Show / 1 Hide / 2 Floating; tablet values are 0 Auto / 1 On / 2 Off. Tab IDs are
`contacts`, `calls`, `news`, `chats`, `feed`, `settings`. Menu IDs are `profile`, `ghost`,
`archive`, `newGroup`, `savedMessages`, `settings`, `feed`, `wallet`, `contacts`,
`newChannel`, `calls`, `browser`, `qrCode`. Dividers use `divider:<stable suffix>`.

Strict backup validation rejects missing/extra fields, wrong types, unknown enums/IDs,
duplicate IDs, missing Chats/Settings tabs, missing supported menu items across both
lists, dividers in the hidden list, hidden Settings while the bar is hidden, strings
over 32KiB, more than 6 tabs/100 menu entries/13 hidden entries, and divider suffixes
outside 1–64 ASCII letters/digits/hyphen/underscore. It performs **no repair**. The
legacy on-disk decoder separately supplies missing-field defaults and normalizes old
layouts; this permissive path is never used by backup validation/restoration.

Configuration is decoded at most once per model instance, cached under NSRecursiveLock,
and published to that cache **before** UserDefaults.set, allowing synchronous reentrant
readers. Compound writes post one `ayuSettingsDidChangeNotification` after unlocking.
The root skips unrelated setting notifications and preserves temporary screen-driven
tab hiding when the configured bar mode did not change.

Migration: SGSimpleSettings' existing one-time reset runs before shared navigation
initialization. Legacy `hideTabBar` / `showTabNames` are read from **standard** defaults
only when there is no navigation configuration. Existing account-level Contacts/Calls/
News visibility seeds the editor until the first explicit tab edit (`tabsCustomized`).
After that, the new model owns order and visibility and old account emissions do not
overwrite the customized list. Reset returns to following the existing account flags.

## Dependencies and localization keys

SGSettingsUI already depends
on AccountContext, SGSimpleSettings, SGStrings, Display and TelegramPresentationData;
TelegramUI already depends on SGSettingsUI, ChatListUI, SettingsUI, QrCodeUI and
TabBarUI. One new explicit edge was added to **NewsScreen/BUILD**:
`//AyuGram/SGSimpleSettings:SGSimpleSettings`, for search-dismissal visibility restoration.
No SGSettingsUI/BUILD edits were made. AccountContext never imports SGSettingsUI or TelegramUI. New source files
are picked up by the existing source globs.

Every key below uses prefix **`Extera.Navigation.`**. English/Russian fallbacks are
present in the source until the root adds catalog entries. Existing Telegram catalog
strings provide Contacts, Calls, Chats, Settings, More, Cancel and Close.

| Suffix | English | Russian |
| --- | --- | --- |
| Title | App Navigation | Навигация в приложении |
| Menu | Navigation Menu | Меню навигации |
| Reset | Reset | Сбросить |
| ResetInfo | Reset navigation and menu layout? | Сбросить навигацию и расположение меню? |
| General | General | Основные |
| VisibleTabs | Visible Tabs | Видимые вкладки |
| HiddenTabs | Hidden Tabs | Скрытые вкладки |
| MenuItems | Menu Items | Элементы меню |
| HiddenItems | Hidden Items | Скрытые элементы |
| TabletMode | Tablet Mode | Планшетный режим |
| Auto | Auto | Автоматически |
| On | On | Вкл. |
| Off | Off | Выкл. |
| BottomBar | Bottom Navigation Bar | Нижняя панель навигации |
| Show | Show | Показывать |
| Hide | Hide | Скрывать |
| Floating | Floating | Плавающая |
| HideLabels | Hide Labels | Скрыть подписи |
| Sidebar | Sidebar | Боковое меню |
| Immersive | Immersive Animation | Иммерсивная анимация |
| Feed | Feed | Лента |
| News | News | Новости |
| Profile | My Profile | Мой профиль |
| Ghost | Ghost Mode | Режим призрака |
| EnableGhost | Enable Ghost Mode | Включить призрака |
| DisableGhost | Disable Ghost Mode | Выключить призрака |
| Archive | Archived Chats | Архив чатов |
| NewGroup | New Group | Создать группу |
| SavedMessages | Saved Messages | Избранное |
| Wallet | Wallet | Кошелёк |
| NewChannel | New Channel | Создать канал |
| Browser | Browser | Браузер |
| QRCode | Scan QR Code | Сканировать QR-код |
| Divider | Divider | Разделитель |
| AddDivider | Add Divider | Добавить разделитель |
| TabletInfo | On enables two columns where at least 700 points are available. Off uses one column. Auto follows the window layout. | Вкл. включает две колонки при доступной ширине от 700 точек. Выкл. использует одну колонку. Авто следует размеру окна. |
| TabsInfo | Tap to hide or show a tab; drag its handle to reorder. Chats and Settings always remain available. Feed is off by default. | Нажмите, чтобы скрыть или показать вкладку; перетащите ручку для изменения порядка. Чаты и Настройки всегда доступны. Лента по умолчанию выключена. |
| SidebarInfo | Open the menu using the menu button. With Sidebar enabled, a swipe from the left edge also opens it. | Откройте меню кнопкой меню. Если включено боковое меню, оно также открывается свайпом от левого края. |
| MenuInfo | Tap to hide or show an item; drag its handle to reorder. Tap a divider to remove it. Changes apply to the menu and sidebar. | Нажмите, чтобы скрыть или показать пункт; перетащите ручку для изменения порядка. Нажмите на разделитель, чтобы удалить его. Изменения применяются к меню и боковой панели. |

## Validation and remaining limits

`Tests/ExteraNavigation/ExteraNavigationSettingsTests.swift` covers defaults and Feed
opt-in, legacy-account compatibility, stable custom order, escape routes, menu
show/hide/dividers, duplicate/unknown-ID sanitation, tablet width policy, persisted
round trips, strict backup rejection, cache behavior, publish-before-write reentrancy,
legacy standard-to-group migration, concurrent compound writes and compound notification count.

Run these **exact** production/model sources on a Swift host:

```sh
python3 tools/run_extera_xctests.py --warnings-as-errors \
  AyuGram/SGSimpleSettings/Sources/ExteraNavigationSettings.swift \
  Tests/ExteraNavigation/ExteraNavigationSettingsTests.swift
```

The test file supplies only app-group/notification/SG initialization bindings for this
direct-source target; it imports SGSimpleSettings instead when that module is available.
No alternate implementation of model/order/persistence is tested.

Windows syntax verification:

```powershell
C:\Users\PC\.local\bin\uv.exe run --with tree-sitter --with tree-sitter-swift python Tests/ExteraNavigation/verify_swift_syntax.py
```

All 16 covered Swift files parse; scoped `git diff --check` passes. Swift typechecking,
XCTest execution, full application build and recorded simulator frames are **pending**
on macOS/root CI. There is no Swift toolchain, XcodeBuildMCP or iOS simulator here.

Expected frames before recording: Show draws a full-width dock, Floating an inset
capsule, Hide removes the bar and its content inset while preserving a visible menu
escape. Labels disappear together with their layout height and VoiceOver keeps the
titles. Reorder changes positions without recreating the selected controller; hiding
the selected Feed selects Chats. Drawer panel and dimming move together (0.35s damped
spring with Immersive, 0.22s otherwise), never expose an interactive undimmed layer
above the drawer, and return focus after dismissal; Reduce Motion changes immediately.

Record open/close, all bar modes and label changes, selected-tab removal, Feed opt-in/
reorder/relaunch, editor scrolling/dragging, sidebar on/off, light/dark, large text,
VoiceOver, narrow phone, iPad/split-window and iPhone Duo orientation/fold paths as
required by root AGENTS.md. No visual parity or animation smoothness is claimed yet.

Platform/scope limits: AOSP and Android predictive Back are not offered as iOS switches;
the app retains its existing native navigation transitions. Immersive is adapted to
the drawer spring and does not reproduce Android's window choreography. Sidebar swipe
starts the drawer animation, rather than tracking an arbitrary continuous finger drag.
The native top action sheet preserves action visibility/order but does not draw custom
divider rows; the sidebar renders them. Wallet availability follows the account. The
editor uses native iOS table drag handles and alert choices; it is not an Android
pixel clone. Chats/Settings cannot be hidden. Feed presentation/unread counters belong
to the Feed agent. Plugins and arbitrary process termination are excluded.
