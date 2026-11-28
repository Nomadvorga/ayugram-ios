# Energy settings: frames 75–77

## Scope and ownership

Energy checkpoint based on root commit `136a2a1bf0cff0517ca49e677d028e6d9b601c0b`.
The aggregate ownership list is [`Tests/ExteraEnergy/owned-files.json`](../Tests/ExteraEnergy/owned-files.json):
43 Swift files including one test suite, plus four support files. It includes Display
navigation background/expansion, PresentationData, GlassBackgroundComponent/LegacyGlassView,
WallpaperBackgroundNode and InvisibleInkDustNode. The renderer/style agent must keep
these shared modules read-only until this checkpoint is handed over.

The chat appearance Animations link now opens `exteraEnergySettingsController(context:)`.
The committed microphone, swipe and distance implementation is otherwise unchanged.
Root owns SGSettingsController/search registration, EN/RU localization, backup, all BUILD
files and workflow wiring. ChatMessageBubbleItemNode and SharedAccountContext are untouched.
No commit or push is performed by the energy agent. Root integrated 28 EN/RU pairs,
15 strict Boolean backup/reset descriptors, six BUILD dependency edges, the missing
PresentationData model import and the 11-case host CI command. The root appearance
category also links directly to this controller, making its title searchable.

## Exact Android evidence and iOS policy

Reference: `ayugram-apk-src/sources/org/telegram/messenger/LiteMode.java` and
`org/telegram/ui/LiteModeSettingsActivity.java`, compared against photos 75/76/77.
The local upstream reference revision is documented in `exteragram-port-status.md`;
the APK source is the evidence for these exact additional flags.

| Group | Android masks and order | iOS choice names |
| --- | --- | --- |
| Stickers | keyboard 1, chat 2; mask 3 | stickerKeyboard, stickerChat |
| Emoji | keyboard 16388, reactions 8200, chat 4112; mask 28700 | emojiKeyboard, emojiReactions, emojiChat |
| Chat | wallpaper 32, sidebar 64, spoilers 128, blur 256, liquid glass 262144, scale 32768, deletion 65536; mask 360928 | wallpaper, topicSidebar, spoilers, blur, liquidGlass, scale, deletion |
| Separate | calls 512, video 1024, GIF 2048, particles 131072 | calls; native autoplayVideo/autoplayGif; particles |

Android splits each emoji surface into Premium/non-Premium bits internally. iOS uses
one choice per actual surface, without changing entitlement or content availability.
Android's group switch is on if any child is selected; the chat group therefore stays
on at 6/7. Expanding a group changes only UI state. A group write updates all its children
in a single settings notification. Saved counts use configured native settings, never
the temporary all-off power-saving settings.

Android defaults depend on performance class: low 198684, medium 204383, high 262143;
the initial battery threshold is 10 and Follow System is false. Its liquid-glass bit
is absent from all those masks, and migration from lite_mode5 clears it. Android's
Follow System replaces the battery trigger, with a stored threshold of 0…100.
The iOS port preserves existing native defaults/capability ceilings instead of applying
Android hardware classes: native threshold 15, <=4 Never, >=96 Always, sticker looping
true, emoji looping/fullTranslucency conditional on CPU count. All additional child
preferences default true and Follow System defaults false. This avoids silently changing
existing iOS appearance, including native glass. Native thresholds are not duplicated
in UserDefaults. Unknown/non-finite/out-of-range battery readings are not treated as zero.

Follow System temporarily ignores the stored threshold and disables the slider.
Switching it off restores that threshold. iOS System Low Power Mode is always an
upper bound, including Never; this is an intentional iOS safety rule. Motion effects
also respect app Reduce Motion and system Reduce Motion. Blur/glass respect system
Reduce Transparency. Smooth Transitions writes the existing inverse
`PresentationThemeSettings.reduceMotion`, with no second persisted switch.

`automaticEnergyUsageShouldBeOnNow/ShouldBeOn` now use the same resolver. Never and
Always remain subscribed to Low Power Mode, foreground and preference changes, so
SharedAccountContext's existing video/GIF and background-work consumers receive the
effective native power-saving configuration. Children further restrict their surfaces;
they cannot override an applicable native/device/accessibility ceiling.

## Actual consumers

| Child | Existing iOS implementation and resulting behavior |
| --- | --- |
| stickerKeyboard | EmojiPagerContentComponent, GroupEmbeddedView, StickerPaneSearchContentNode and ChatMediaInputStickerGridItem gate visible animation playback. |
| stickerChat | ChatMessageAnimatedStickerItemNode retains upstream once/still behavior when looping is disabled. Dice/slot outcomes keep their existing special playback rules. |
| emojiKeyboard | Keyboard pager, embedded groups, top panel and empty search results gate loops. |
| emojiReactions | ReactionContextNode gates idle loops; its expanded EmojiPager explicitly marks the interaction holder as a reaction selection, including custom emoji whose animation data does not have isReaction set. |
| emojiChat | Animated emoji messages, ChatMessageTextBubbleContentNode, TextNodeWithEntities, InteractiveTextNodeWithEntities, EmojiTextAttachmentView and inline ReactionButtonListComponent gate loops. |
| wallpaper | WallpaperBackgroundNode gates gradient rotation/events/loop continuation and motion parallax. Preference/system changes refresh parallax and restart an eligible loop. An in-flight gradient event can finish its existing cycle before stopping. |
| topicSidebar | ChatSideListKindForState uses the same policy for forum, bot forum, monoforum and applicable Saved Messages sub-chats. Header/floating topic panel factories use the same gate, restoring the upper topic strip when a side strip is unavailable. Existing peer/permission/native sidebar checks remain. |
| spoilers | InvisibleInkDustNode/View and MediaDustNode choose the existing static concealed fallback. TextNodeWithEntities also passes the granular flag. Existing animated emitter layers pause in place on policy changes, preserving concealment and reveal interaction. A node created with static dust remains static until its normal reconstruction; enabling effects does not replace concealed content in place. |
| blur | Display NavigationBackgroundNode/BlurredBackgroundView remove the actual UIVisualEffectView and use an opaque background, with live observation even for identical color/geometry. Chat loading, empty state and date/status backgrounds additionally preserve their native fullTranslucency ceiling. |
| liquidGlass | GlassBackgroundView/LegacyGlassView disable actual UIGlassEffect/backdrop rendering and use the existing clipped solid shape/content. Native glass is restored when allowed without changing geometry. Blur off also suppresses glass, whose backdrop requires blur. No simulated glass effect is added on older iOS. |
| scale | Display NavigationExpansion selects the established slide fallback. ChatMessageTransitionNode gates all four paired squash/anchor-compensation animations together; vertical/horizontal send travel and list timing stay intact. The optional spring preset is not enabled by this preference. |
| deletion | ChatHistoryListNode gates dust deletion together with the existing user setting/server killswitch. Standard deletion remains available; no list backend, rotation, item identity or geometry contract changes. |
| calls | CallControllerNodeV2, CallStatusBarNode, voice-chat stage/participant/fullscreen nodes and GroupCallNavigationAccessoryPanel gate their existing background/audio-level effects. Call media, audio routing and microphone ownership are unchanged. |
| particles | Existing AyuSnowView emission and StarsButtonEffectLayer in inline paid reactions are gated. Paid-reaction actions/counters are unaffected. Snow is not enabled by this setting; it still requires forceSnow and its scene/foreground/thermal checks. |

Animation loops sampled by existing node layout/visibility callbacks change at those
callbacks; this does not introduce an application-wide forced chat reload. Live blur,
glass, wallpaper parallax, snow and existing spoiler emitters have explicit observation.
Sidebar layout and static spoiler renderer selection are reevaluated on normal
layout/reconstruction. The empty standalone SavedMessagesScreen stub is not modified;
the live Saved Messages paths are the shared chat history/sidebar paths above.

## Renderer/style handoff

`ExteraStyleSettings` is being implemented separately. Its appearance choices must
remain separate persisted flags. The combination contract is an intersection:

```swift
effectiveBlur = nativeSurfaceRequestsBlur && styleSurfaceEnablesBlur
    && ExteraEnergyRuntime.allows(.blur)
effectiveGlass = nativeGlassIsSupported && styleSurfaceEnablesGlass
    && ExteraEnergyRuntime.allows(.liquidGlass)
    && ExteraEnergyRuntime.allows(.blur)
```

Style changes must not write `extera.energy.*`, threshold, or native fullTranslucency.
Energy changes must not rewrite style choices. Use an existing solid/opaque fallback
when the intersection is false. Preserve tint, clipping, hit targets, visibility and
accessibility rather than hiding controls or introducing fake blur/glass. The shared
background implementations retain the caller's requested enableBlur separately from
the energy result, so returning from saving does not turn a style-disabled blur on.
The style owner should include its notifications in the refresh path after handoff.

## Root API, localization, backup and dependencies

- Entry: `public func exteraEnergySettingsController(context: AccountContext,
  focusOnFeature: ExteraEnergySettings.Feature? = nil) -> ViewController`. A focused
  feature expands its group in the first transaction; it does not implement scrolling
  to a search hit. The existing chat appearance entry is connected. Root may use the
  same controller for its own Energy/Animations navigation and search registration.
- Model: `ExteraEnergySettings.shared`, `.Feature`, `.Group`, `setEnabled`, `setGroup`,
  `selectedFeatures`, `GroupState`, `booleanKeys`, `key(for:)`, `followSystemKey`.
- Backup: 15 strict booleans: `extera.energy.followSystem` default false, and
  `extera.energy.<feature.rawValue>` default true for the 14 names in the tables above.
  Do not accept numeric or string coercion. Native threshold, autoplay and inverse
  Reduce Motion use existing native preference storage; do not invent parallel keys.
- Localization: 28 EN/RU pairs are ready in
  [`integration/extera-energy-strings.json`](integration/extera-energy-strings.json).
  Existing native title/options/video/GIF/back labels are reused.
- Add `//AyuGram/SGSimpleSettings:SGSimpleSettings` as a direct dependency to
  InvisibleInkDustNode, EmojiTextAttachmentView and GlassBackgroundComponent.
- Add `//submodules/TelegramPresentationData:TelegramPresentationData` as a direct
  dependency to ChatMessageTextBubbleContentNode, InteractiveTextComponent and
  TextNodeWithEntities. Exact target labels are in the owned-files manifest.
- Display, WallpaperBackgroundNode, TelegramPresentationData, TelegramUI and SGSettingsUI
  already have the required SGSimpleSettings dependencies. New production sources use
  existing Sources globs. Root owns any workflow registration for the host test command.

## Expected recordings, before visual acceptance

Record with simctl and evaluate timestamped frames with `tools/animation_sheet.py`
as required by AGENTS.md. Use each path in light/dark, EN/RU, normal/large text,
with and without system Reduce Motion/Reduce Transparency. Expectations:

1. Open Animations: threshold/status, Follow System, collapsed 2/2, 3/3 and 7/7 groups,
   calls/video/GIF/particles and Smooth Transitions are present. The slider/title/card
   must not clip or overlap, including at accessibility text sizes.
2. Expand/collapse each group: children move vertically together with their neighboring
   rows; no duplicate separators, clipped text or gaps. Counts and switches do not
   change. With Reduce Motion, the rows change without decorative motion.
3. Disable only scale: chat becomes 6/7 with its group switch on, reproducing frame 77.
   Keyboard/chat/reaction children stay independent. A group switch off/on changes
   exactly that group's children. Reopen and verify persisted choices.
4. Follow System on: slider is visibly disabled and cannot change the saved threshold.
   Toggle it off: the original value returns. Exercise Never/Always and both sides of
   an ordinary threshold; counts keep saved values while effects are temporarily off.
5. Trigger Low Power Mode while Never is selected: status and disabled options update,
   video/GIF native saving takes effect; restoring power mode restores saved choices.
   Repeat while the settings page is not visible.
6. Same-size/same-color blur/glass off/on: real blur/glass disappears and returns;
   controls retain shape, tint and hit targets. No full-screen opacity flash, disappearing
   text or stale UIGlassEffect. On pre-26 iOS, the existing legacy fallback is used.
   Repeat with future style blur flags off and confirm energy cannot re-enable them.
7. In a normal chat and Saved Messages sub-chat, test keyboard stickers, chat stickers,
   inline/custom emoji, collapsed and expanded reaction menus independently. Spoilers
   must remain concealed when static/paused and reveal only on the existing interaction.
   Compare already-visible nodes and newly constructed nodes.
8. Wallpaper off stops future rotations and parallax; off during a rotation may finish
   that cycle, then stays still. Forum/sidebar off preserves access through its existing
   normal navigation/upper strip. Repeat Saved Messages with real saved sub-chats.
9. Scale off: no navigation expansion or optional bubble squash; ordinary slide/send
   travel stays coherent with the list, with no one-frame 90% bubble. Delete off: no
   dust burst, standard deletion still completes. Calls/particles off suppress existing
   decorative effects without disabling audio, reactions or their counters.

## Validation status

Eleven production-model XCTest cases are in `Tests/ExteraEnergy`; their README gives
the host command. The exact command passed in the Mac host workflow at `c56af00f`
(`45752660441`). There is no Swift/Xcode, iOS SDK or simulator on this Windows host.
Native UIKit runtime and recorded-frame/device acceptance remain unverified; no
animation frame claim is made.
All 43 owned Swift files passed tree-sitter parsing with zero ERROR/missing nodes and
an explicit import-presence check for the added EnergyUsageSettings extension calls.
Scoped `git diff --check` passed. These checks do not substitute for the full build.
