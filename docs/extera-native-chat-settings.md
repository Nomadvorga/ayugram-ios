# Native chat settings: frames 48/49/50/73/74/78/79

## Checkpoint and ownership

Base: local root energy commit `9598c2c090f4a469714ae98e2c3a9c2cbda6311b`.
This is an uncommitted source checkpoint. No commit, push, simulator installation,
or modification of root-owned localization, backup, app BUILD/workflow or
`SGSettingsController` was performed. This wave adds only the direct `Emoji` dependency
to `submodules/SettingsUI/BUILD` for the inline native theme carousel.

The owned composition is `Swiftgram/SGSettingsUI/Sources/ExteraChatAppearanceSettingsController.swift`.
The complete 19-file Swift inventory and integration metadata are in
[`Tests/ExteraNativeChat/owned-files.json`](../Tests/ExteraNativeChat/owned-files.json).
`ManagedAudioSession.swift` has a playback-only hook alongside the previously committed
microphone implementation. `ChatMessageBubbleImages.swift` has a square action-background
fix needed to expose radius zero safely. Neither is in the energy manifest. Other
shared renderer/energy consumers and unrelated parallel-agent edits were left alone.

## Exact evidence and control matrix

All seven exact JPGs were inspected before implementation, under
`C:/Users/PC/Downloads/Telegram Desktop/photo_{48,49,50,73,74,78,79}_2026-11-25_21-26-04.jpg`.
The APK evidence is `C:/Users/PC/ayugram-apk-src/sources/org/telegram/ui/ThemeActivity.java`,
`StickersActivity.java`, and `messenger/{SharedConfig,MediaController}.java`.
An existing iOS route is counted below only for its audited controls; it does not
establish screenshot equivalence. Every row still needs native visual verification.

| Frame / exact Android control | Audited iOS implementation and this checkpoint | Difference / acceptance status |
| --- | --- | --- |
| 48: font slider at 16 | New inline discrete slider writes native `PresentationThemeSettings.fontSize`; ordered native sizes are 14, 15, 16, 17, 19, 23, 26 pt. | iOS native choices replace Android's integer font range. 16 is available. System font remains the native default and disables custom adjustment until turned off. |
| 48: incoming reply and outgoing message preview | New `ExteraNativeChatPreview` bridges the existing `ThemeSettingsChatPreviewItem` and real message renderer. It consumes effective theme, wallpaper, chat font, corners, name color and reply emoji. | Native localized sample messages replace Android sample text. No painted imitation of a chat. Source wired; appearance unverified. |
| 48: Change Wallpaper | Direct `ThemeGridController(context:)` bridge. Hidden with native bubble-free mode, as in the audited appearance screen. | Existing wallpaper selection, download and apply flow retained. |
| 49: gallery, color, search, wallpaper grid | Native wallpaper grid keeps its gallery/color flows and adaptive layout. Generic wallpaper mode now opens a native search controller backed by the configured image bot, `#wallpaper`/`#color…` query, debounce, pagination and result-id deduplication. Results use the native `WallpaperGalleryController` `.contextResult` preview and existing wallpaper upload/apply path. | Peer/premium wallpaper mode is unchanged. Search does not create parallel wallpaper storage or use a hardcoded bot. Native layout adapts to size and insets; no unconditional three-column promise. Personal photos/cats and wallpaper inventory belong to the account. |
| 48: name color | Direct `UserAppearanceScreen(context:)` bridge; account peer supplies the summary and preview styling. | Native premium/capability handling retained. |
| 48: theme carousel, day/night, theme settings | The composed page now embeds the actual `ThemeCarouselThemeItem`, current chat-theme inventory and animated-emoji data. Selection delegates to the same native theme-selection pipeline as the Themes page. Bubble-free selection uses native per-mode themes; auto-night selection retains its active-theme semantics. | Accent colors, per-theme wallpapers, cloud themes, bubble-free preservation and auto-night handling remain native. Other theme/accent controls and full theme settings remain on the native Themes page. Frame-level appearance is open. |
| 48/50: radius 17 / 0 | New inline slider writes main radius 0…17 and adjacent radius `radius / 2`. Adjacent-corner switch writes its own existing field. | Extends native editor's 8…16 UI. Theme/font/bubble-free choices are preserved. Radius 0 includes a nonzero square action-button canvas fix and native raster regression case. Rounded/tail/media/action rendering still needs recordings. |
| 50: two/three chat-list lines | Previously committed local preview and `SGSimpleSettings.chatListLines` consumer retained. | Existing one-line value is preserved until the user chooses another value. |
| 73/74: night row body opens configuration; switch enables automatic night | New native mode selector: Disabled, System, Scheduled, Automatic brightness; separate Configure Night Theme route opens native schedule/location/threshold/theme editor. | Android's switch enables its last/default auto mode; iOS exposes explicit modes. Selecting Scheduled from another mode initializes 22:00–09:00; existing active schedule is retained. Brightness initializes 0.2. Native force-night is a separate control, not the auto-mode indicator. |
| 73/74: browser row body and switch | Audited `webBrowserSettingsController` selects Telegram, in-app Safari, external browsers, per-account exceptions, cookies and cache. Existing direct route retained. | No duplicate local browser Boolean. Android quick switch is represented by native browser selection inside this page; the composed page has a disclosure only. |
| 73/74: Animations | Opens the accepted energy controller. | Existing accepted energy checkpoint; not reimplemented here. |
| 73/74 → 78: Stickers and Emoji | Native general installed-sticker page retained after auditing its entries and callbacks. | Account counts and pack contents remain dynamic. |
| 78: trending 231 / emoji 35 | Native featured and emoji pack routes, counts derived from account collections. | 231 and 35 are reference account data, never constants. |
| 78: quick reaction ribbon | Native quick-reaction preview/setup route and reaction data. | Native layout, current reaction and entitlements retained. |
| 78: suggestions All | Native `StickerSettings.emojiStickerSuggestionMode` supports none/all/installed. | Same applicable behavior; native selector layout. |
| 78: large emoji on | Native installed-sticker switch → `PresentationThemeSettings.largeEmoji`. | Actual native presentation consumer; no extra setting. |
| 78: dynamic recent order off; installed packs | Native dynamic pack order switch → `StickerSettings`; native reorder/remove/add pack actions. | Existing defaults and account data retained; screenshot state can be selected. |
| 74/79: tap next media on + explanatory text | Native `MediaDisplaySettings.showNextMediaOnTap` plus its existing localized subtitle now shown inline. | Consumed by `GalleryController.disableTapNavigation`. |
| 74/79: raise to listen off | Native `MediaInputSettings.enableRaiseToSpeak`. | iOS uses one native proximity/raise policy; APK's separately conditional raise-to-speak switch is not fabricated. |
| 74/79: pause music while recording off | Existing native `pauseMusicOnRecording` and recording session policy retained. | Independent from the new playback policy. |
| 79: pause music on media off | New explicit iOS control, “Pause Other Audio During Playback”, backed by `ExteraChatMediaSettings.pauseOtherAudio`; actual `AVAudioSession` mixing consumer. | Deliberately narrower than Android's audio-focus/player policy: affects other apps' audio mixing, not simultaneous Telegram players. Defaults true to preserve existing iOS playback. Off matches applicable mixing behavior. |
| 79: microphone headset | Previously committed available-port picker and recording-input consumer retained. | Headset must exist; unplug/system-managed input falls back according to native routing policy. |
| 79: Direct Share on | Native `IntentsSettings` route retained; composed row now reports whether any chat category is enabled. | iOS has categories/account/only-shared/reset, no master Boolean. Category and account choices are preserved. OS may retain old suggestions until native reset. |
| 79: sensitive 18+ on | New thin route adapter focuses native Data & Storage sensitive-content row. | Actual row exists only when `canAdjustSensitiveContent` and native configuration/verification policy allow it. Native confirmation/age verification and server update remain authoritative; no local bypass. Unavailable accounts still see the native Data & Storage page. |
| 79: Send by Enter off | Native Command-Enter setting retained, labeled with the existing iOS string, on iOS 13.4+. | Android plain Enter is not equivalent to hardware Command-Enter; no unsupported plain-Enter toggle is added. |
| 79: automatic distance | Previously committed automatic/km/miles adapter and formatter consumers retained. | Existing native locale behavior for automatic. |

## Storage, consumers and mutations

| Owner / storage | Writes and actual consumers | Defaults / preservation |
| --- | --- | --- |
| Native account-manager theme settings | Font slider and system-font switch; presentation-data emission updates native preview and actual chat typography. Advanced text route retains independent chat/list font and serif controls. | `useSystemFont = true`, font `.regular`, list `.regular`; slider writes only chat size. |
| Native chat bubble settings | Corner slider and merge switch → `PresentationChatBubbleCorners` → native message images and media layouts. | Main 16, auxiliary 8, merge true. Slider changes only main/auxiliary radius; all theme, bubble mode, serif and merge fields survive. |
| Native automatic theme settings | Mode selector updates trigger; night toggle updates force; native configuration route edits schedule/location/brightness/theme. | Always mutate via `currentModeAutomaticThemeSwitchSetting`, preserving per-mode theme references and legacy storage invariants. Trigger and force are independent. Switching away from a mode does not introduce shadow storage of its previous configuration. |
| Native wallpaper/name color/themes | Existing native controllers and engine/account settings. | No second persistence layer, copied wallpaper assets or hardcoded peer colors. |
| Native media/chat settings | Tap-next, raise-to-listen, pause-recording and Command-Enter write their existing interactive preference transactions. | Existing iOS defaults retained. |
| Native `IntentsSettings` | Read live summary; edits remain in `intentsSettingsController`; `TelegramIntents` checks account/category/only-shared when donating suggestions. | Defaults: contacts and Saved Messages true; private chats/groups false; account nil; onlyShared false. No summary write touches these fields. |
| Native sensitive-content setting | `dataAndStorageController(...focusOnItemTag: .sensitiveContent)` owns capability, enable confirmation, verification and `updateRemoteContentSettingsConfiguration`. | Server-owned account preference, no UserDefaults Boolean and no new backup entry. |
| New app-group playback Boolean | `extera.chatMedia.pauseOtherAudio` → `ManagedAudioSessionType.exteraMixesPlaybackWithOtherAudio` → category `.mixWithOthers`. | Default true. Explicit native `play(mixWithOthers: true)` always wins. Calls, recording and ambient return nil and keep existing options. |

Playback settings notifications are handled on the existing audio queue. A currently
active playback holder refreshes category options even if its type/output tuple did
not change. With no active holder, the next normal setup reads the new setting, so
notification delivery cannot cancel a pending empty-session deactivation. The new
observer is removed on deinit. No player arbitration, recording input selection,
call category, Bluetooth selection or microphone preference logic was changed.
Turning mixing on cannot automatically resume another app that iOS already paused;
the localized explanation states this limitation.

The discrete UIKit slider tracks a local displayed index during a gesture so delayed
preference publications do not reset the thumb/label. Height reserves the largest
value label; VoiceOver increments/decrements exactly one step. These are source-level
measures; touch, accessibility, typography and frame stability need native inspection.

## Root integration handoff

1. Include all Swift and support files from the manifest. Existing source and native
   test globs include them. `submodules/SettingsUI/BUILD` adds the direct
   `//submodules/Emoji:Emoji` edge for `ExteraInlineChatThemes.swift`; the wallpaper
   controller uses dependencies already present in `WallpaperGridScreen/BUILD`.
   SettingsUI already depends on LocalizedPeerData, PeerNameColorScreen and
   WallpaperGridScreen; SGSettingsUI already depends on SettingsUI and
   TelegramUIPreferences; TelegramAudio already depends on SGSimpleSettings.
2. Merge the six exact EN/RU pairs from
   [`integration/extera-native-chat-strings.json`](integration/extera-native-chat-strings.json)
   into root-owned localization. The source calls these keys now; runtime text is
   incomplete until root integrates them. All other new titles reuse native strings.
3. Add one strict Boolean backup/reset descriptor for
   `extera.chatMedia.pauseOtherAudio`, default **true**, through
   `ExteraChatMediaSettings.shared.pauseOtherAudio`. Accept only a JSON Boolean;
   preserve existing backup validation/batching and use the setter so audio/UI observe
   restore/reset. Do not add duplicate backup keys for native theme, Intents or
   sensitive-content storage.
4. Existing root category route continues to call
   `exteraChatAppearanceSettingsController(context:)`. Optional root search entries
   may index the new native controls; no root route signature changed.
5. Host CI command and the two explicit native test targets are in
   [`Tests/ExteraNativeChat/README.md`](../Tests/ExteraNativeChat/README.md).
   The native suites are picked up by existing test globs. Add the three-case host
   fixture to CI alongside accepted energy tests if that is root's intended coverage.
6. Build the full app with the supported `Make.py build` command from CLAUDE.md and
   run both explicit native targets. Review full native compiler diagnostics; the
   Windows syntax parser is not a Swift typechecker.

## Expected recordings and frame acceptance

Before recording, establish these expected states. Use a dedicated permitted K-sim,
the current build, EN and RU, light and dark, regular and large text, and a narrow
phone layout. Follow AGENTS.md: `simctl io recordVideo`, then `animation_sheet.py`;
timestamps come from ffprobe. Save clip, frame sheets and frames.tsv outside the repo.
Record normal speed first, with still time at both ends; inspect every flagged gap
and jump, and report actual frame indices/timestamps before accepting visuals.

| Clip | Trigger and expected frames |
| --- | --- |
| `48-font-preview` | Open composed page, turn off System Font, drag 14→16→26→14. Thumb and numeric label must stay together under the finger; native text/reply bubble must reflow to the same stored size without a stale-thumb snap, clipping, overlapping rows or doubled message content. Turn System Font back on; slider disables and effective preview follows the native system setting. Reopen and check persistence. |
| `48-50-radius` | In bubble mode drag 17→0→17, test merge on/off. Both preview bubbles and a real chat reflect main radius. At zero all text/media/reply/inline action backgrounds must render and scrolling must not crash; action backgrounds have square nonempty corners. Inspect tails and merged messages; do not infer Android shape parity from the scalar value. Return to chat and reopen settings. |
| `49-wallpapers` | Enter directly, open gallery then cancel, open colors then cancel, then search a term, toggle a color, scroll through another page, select a result, inspect native preview, apply and return. Query changes must cancel stale pages; duplicate ids must not duplicate cells; peer/premium wallpaper semantics must remain unchanged. Selected wallpaper must appear in preview and actual chat. Repeat with bubble-free mode: direct row is absent and unrelated choices survive. |
| `48-themes-color` | Open the composed page and change the inline carousel choice; verify effective preview/actual chat update. Test bubble mode and bubble-free day/night selections independently, including auto-night while the selected theme is a chat theme. Open the native Themes page and name color then cancel/apply as permitted; native settings must remain intact. |
| `73-74-night-browser` | Open/close each selector and route; select Disabled/System/Scheduled/Brightness, edit schedule/threshold, return, toggle force-night where enabled. Colors must update consistently across preview, rows and navigation with no stale dark/light surface. Browser selection/exception edits survive return; the main browser row remains a disclosure. |
| `78-stickers` | Enter native general page; visit featured, emoji, quick reaction and suggestions; change large emoji and dynamic order, then return/reopen. Counts come from the test account and must not jump to reference constants. Record installed packs and optional empty/nonempty states. |
| `79-media-audio` | Record explanatory rows at EN/RU large text and mic picker with/without a headset. Separately play music in another app, then start audible Telegram playback with pause-other-audio on/off. Verify live option change while playing and the next-play path while idle. Verify recording pause preference both ways, calls, ambient effects and native mixing requests remain independent. A device audio test is required; silent simulator frames cannot prove audio mixing. |
| `79-share-sensitive` | Enter native Share Sheet settings, change one category/account, return/reopen; other category choices must persist. Enter sensitive content with adjustable and nonadjustable accounts. Record native row focus, enable confirmation cancellation, successful confirmation, required age-verification cancellation/completion, disable and reopen/server refresh. No unsupported local switch should appear. |
| `50-79-regressions` | Select two/three chat-list lines, each swipe option, km/miles/automatic, Command-Enter with hardware keyboard; return to actual consumers. Preserve one-line compatibility until changed. Record open and close paths for option sheets. |

Expected navigation uses existing iOS push/pop and selector motion; this checkpoint
adds no custom spring or overshoot. During slider updates the control remains at rest
and only its value/preview contents change. Dynamic font reflow may move subsequent
rows coherently; a stationary overlay, disappearing thumb, stale value, transient
overlap or unexplained color flash is a defect. Provide frame citations and inspect
the sheets end to end, even if motion metrics look clean.

## Verification and remaining gates

- Tree-sitter parsed all **19 manifest Swift files**, with **0 syntax errors** and no trailing whitespace in untracked sources.
- Scoped `git diff --check` passed. A Python manifest check confirmed all manifest files exist, there are no duplicate paths, the inventory contains 19 Swift files and 18 XCTest cases, and `//submodules/Emoji:Emoji` exists in `submodules/SettingsUI/BUILD`.
- Added **18 XCTest cases**: three host storage/mixing cases, three native audio-policy
  cases, six native font/corner/preservation/raster cases and six wallpaper-search-state
  cases. They are **unexecuted** here.
- The scoped `tools/run_extera_xctests.py --warnings-as-errors` host command was attempted,
  but did not compile or execute tests: it reports `swift is unavailable; XCTest requires
  a Swift host toolchain`.
- No Swift host toolchain is available in WSL and no Xcode/iOS SDK/simulator or native
  recording tools are available on this Windows host. Full debug build, native type
  correctness, XCTest results, live image-bot/gallery behavior, device audio behavior
  and visual/animation acceptance are **open**; root CI is the next compile gate.

The result is ready for source integration review. It is not a completed native or
visual parity acceptance; the root localization/backup integration and the above
native checks remain necessary.
