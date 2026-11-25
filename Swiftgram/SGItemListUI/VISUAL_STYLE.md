# Opt-in extera rows

`SGItemListArguments` accepts `visualStyle: SGItemListVisualStyle = .native`
immediately after `context:`. Only `.extera` opts existing entries into the custom
renderer; other callers continue creating the same native items as before.

```swift
let arguments = SGItemListArguments<BoolSetting, SliderSetting, OneFromManySetting, DisclosureLink, ActionType>(
    context: context,
    visualStyle: .extera,
    setBoolValue: { setting, value in /* update the setting */ },
    setExpanded: { setting, expanded in /* update controller-local expansion state */ }
)
```

The exact new entry signatures are:

```swift
case expandableToggle(
    id: Int,
    section: Section,
    settingName: BoolSetting,
    value: Bool,
    text: String,
    selectedCount: Int,
    totalCount: Int,
    isExpanded: Bool,
    enabled: Bool
)
case checkbox(
    id: Int,
    section: Section,
    settingName: BoolSetting,
    value: Bool,
    text: String,
    enabled: Bool
)
```

The parent row's label/count/chevron calls `setExpanded(setting, !isExpanded)`;
its trailing switch calls `setBoolValue(setting, !value)`. A checkbox calls
`setBoolValue(itsOwnSetting, !value)`. The controller inserts checkbox entries
immediately after the parent while expanded, with distinct stable IDs and the
same section. The row stores no expansion or persisted settings state.
`selectedCount` and `totalCount` are display inputs only. Native rendering of
the two new cases is also provided.

The renderer handles existing `header`, `toggle`, `toggleSubtitle`, `notice`,
`disclosure`, `disclosureSubtitle`, `oneFromManySelector`, and `action` entries.
`segmentedSelector` adds a discrete labelled scale in either visual style.
Avatar/chat-list appearance previews, percentage sliders, peer-color previews,
and search input retain their existing implementations. A double-tap appearance
preview uses the custom card renderer when opted in. A native item interrupts an extera card run, so mixed native
and custom content has independent rounded surfaces.

Adjacent custom card rows in the same section join without vertical gaps.
Headers and notices end card runs. The descriptor includes section, card/plain,
notice, and checkbox facts; insertion/removal of a child or a search result
therefore invalidates neighbouring corners and separator geometry through the
current `ListViewItemNeighbors` API.

Geometry follows the supplied references: 54pt minimum row height, 22pt card
corners, 22pt interior horizontal padding, indented circular checkbox rows,
separate 44pt switch targets, and accent section headings with the supplied
capitalization. At base font sizes up to 22pt, card titles (apart from checkbox
labels) truncate on one line and subtitles truncate after two lines. Headers,
notices, and checkbox labels retain wrapping; above 22pt card titles/subtitles
also wrap. Values and counts always truncate on one line. Measurement applies
the same line limits as the labels, so long truncated titles do not inflate the
row height. Row height grows with the presentation font size.
Requested exterior margins are 13pt; the renderer honours larger layout insets.
The existing `ItemListControllerNode` reserves at least 16pt on phone widths
and draws side overlays there, so this implementation uses 16pt when hosted in
that controller. Safe, folded-device, and tablet bands remain respected.

All colors come from `PresentationTheme`. In dark themes the opaque card is a
9.5% mix of primary text into the theme's list background (~#181818 for white on
black). Light themes use their opaque blocks surface. Accent values, headers,
switches and checks follow the theme accent; destructive and disabled actions
retain their semantic colors. `SGItemListVisualStyle.backgroundColor(theme:)`
and `.cardColor(theme:)` are public helpers for the host's surfaces. They do not
modify the controller theme. A black canvas requires a theme whose
`list.blocksBackgroundColor` is black; the row renderer does not force dark mode.

`SGOneFromManySourceNode` shares the selector anchor and context-highlight
callback between the native disclosure node and the custom node. Both are
discovered by the existing setting tag. `sgPresentOneFromManySelector` continues
presenting the same menu and clears highlight on dismissal.

Subtitle links use this additional entry without changing ordinary `disclosure`:

```swift
case disclosureSubtitle(
    id: Int,
    section: Section,
    link: DisclosureLink,
    text: String,
    subtitle: String,
    iconName: String
)
```

`iconName` is an SF Symbol name, for example `sparkles`, `function`, or
`bubble.left.and.bubble.right`. Symbol loading is guarded by iOS 13 availability;
an unavailable symbol produces a text row. The native fallback uses the native
disclosure item's icon and `additionalDetailLabel`. The extera item keeps an
optional icon and reuses one non-accessible `UIImageView`, tinted with the theme's
secondary text color. The icon is centred in a 24pt slot at leading 22pt; a 22pt
gap puts both title and subtitle at leading 68pt. Icon-row separators start at
the same text inset. Updating a node to a row without an icon clears and hides
the image and restores the original text/separator inset.

Subtitle links open the same `openDisclosureLink` callback and expose title and
subtitle as one accessibility label. Search matches either field and does not
index symbol names. Equality includes the link, title, subtitle and symbol name.
The shared custom node conforms to `ItemListItemNode` through
`SGOneFromManySourceNode`, so `displayHighlight()` continues working through the
same protocol used by native settings nodes. The SG settings search filters
entries rather than casting nodes to a native disclosure class.

Gesture previews extend the existing appearance entry and kind:

```swift
.appearancePreview(
    id: id,
    section: .gestures,
    kind: .doubleTap(incomingSymbol: "heart", outgoingSymbol: "arrowshape.turn.up.left"),
    settingName: nil
)
```

`AyuAppearancePreviewKind.doubleTap(incomingSymbol: String, outgoingSymbol: String)`
compares both symbol names through synthesized equality. The existing entry's
stable ID and section behavior are unchanged. Symbol names are presentation
inputs, not settings or searchable content. The preview creates no chat data,
placeholder message text, interactive gestures, or setting callbacks.

Native rendering is provided by `AyuAppearancePreviewItem`; `.extera` routes only
this new preview kind through `SGExteraItem`. Both reuse
`AyuDoubleTapPreviewView`, its two shape layers, and two icon views. On `.extera`,
the preview publishes the same card neighbour descriptor as settings rows: put
the preview directly before the incoming/outgoing selectors in the same
`.gestures` section to get a contiguous surface, a full-width preview separator,
and bottom corners only on the last selector.

The preview is 190pt high, with 150×64pt bubble bodies, up to 30pt side insets,
and top positions 14pt/94pt (an 80pt vertical offset). Incoming is upper left;
outgoing is lower right. Narrow bands reduce the inset/body width to keep the
closed paths and their tails inside the provided layout. Icon centres exclude
the tails. The outgoing path mirrors the entire incoming outline; neither shape
uses clipping to fake a tail. Fill, stroke and icon tint derive from the theme.
All layout uses the parent's bounds and supplied list insets, without screen
bounds. The view and its contents are non-interactive and hidden from VoiceOver;
the adjoining selectors expose the actual action names and remain accessible.
UIKit allocation and application stay on main, and the child never sets its own
frame. Updating symbol names or themes reuses the existing views and layers.

Discrete settings use this new entry and callback:

```swift
.segmentedSelector(
    id: id,
    section: section,
    settingName: setting,
    value: selectedIndex,
    options: optionTitles,
    enabled: true
)

// Last optional argument of SGItemListArguments.init, after setExpanded:
setSegmentedValue: { setting, index in
    // Map the zero-based index to the setting's preferred mode.
}
```

The exact case is `segmentedSelector(id: Int, section: Section,
settingName: OneFromManySetting, value: Int, options: [String], enabled: Bool)`.
`setSegmentedValue` has type `(OneFromManySetting, Int) -> Void` and defaults to a
no-op. Equality includes every field; section/stable ID work like other rows.
Search matches any option title. No model mapping or strings are embedded in
the renderer: the download caller supplies the three localized titles, in mode
order. Reference photo 02 and `docs/extera-reference-screens-01-22.md` show
«Откл.» / «Быстро» / «Ультра»; photos 03/04 show adjacent settings and the
separate avatar-corner scale.

The scale shares `SGExteraItemNode` in native and extera modes. Its reusable
`SGDiscreteSelectorControl` has a grey rounded track, dots at the unselected
stops, a narrow 26pt rounded vertical selected marker, and accent text for the
selected option. The first/last labels align to the outer edges and the middle
label is centred. Three short labels give an 80pt row; longer translations or
larger fonts grow the label area and row together. Native rendering uses theme
colors and native item-list neighbour facets; extera rendering remains opaque
and joins extera rows in the same section. For the reference composition, put
the upload switch immediately after this entry in the same section.

Taps select a label/stop, horizontal tracking selects the nearest discrete stop,
and a vertical drag cancels tracking without selecting. The callback fires only
when a user changes the selected index. Model application, repeated motion at
one stop, and increment/decrement at a boundary do not emit changes. An active
drag ignores stale model echoes until tracking finishes; changing the option
list or disabling the control still applies immediately. Input indices are
clamped for display without emitting callbacks. Empty/single-option scales are
inert. The control is one VoiceOver adjustable element, with the selected title
as its value; disabled state and index boundaries are respected. No popup or
continuous-value UISlider is used. Child allocation/application occurs on main;
labels and shape layers are reused and layout reads bounds without setting the
control's own frame. Existing double-tap/appearance previews are preserved.

## Sticker, shape and message settings illustrations

References 33–38 and 52–57 use this value-only entry in both visual styles:

```swift
case settingsPreview(
    id: Int,
    section: Section,
    kind: SGSettingsPreviewKind,
    sliderSetting: SliderSetting?,
    selectionSetting: OneFromManySetting?
)

public enum SGSettingsPreviewKind: Equatable {
    case sticker(SGStickerPreviewConfiguration)
    case stickerShapes(value: Int, options: [String])
    case message(SGMessagePreviewConfiguration)
}
```

The optional setting IDs enable only their associated controls. `sliderSetting`
routes raw `Int32` sizes through the existing `updateSliderValue` callback;
`selectionSetting` routes shape indices through `setSegmentedValue`. Pass `nil`
for a read-only scale or tile group, and both `nil` for a message illustration.
No new arguments callback or settings-model dependency is needed. Every input,
including both setting IDs, participates in entry equality. Search indexes the
sticker title/endpoint labels or shape option labels; example message strings
are intentionally not indexed.

Root integration, using its own setting IDs, strings and current values:

```swift
.settingsPreview(
    id: stickerPreviewId,
    section: .stickers,
    kind: .sticker(SGStickerPreviewConfiguration(
        size: stickerSize,                    // Int32, raw 4...20
        timeMode: stickerTimeMode,             // Int: 0 overlay, 1 side, 2 hidden
        shape: stickerShape,                   // Int: 0 original, 1 rounded, 2 bubble
        bubbleRadius: currentBubbleRadius,
        replyColors: replyColors,
        replyEmoji: replyEmoji,
        replyBackground: replyBackground,
        title: strings.stickerSize,
        smallLabel: strings.small,
        largeLabel: strings.large,
        largeBadge: strings.largeUppercase,    // Russian: «БОЛЬШОЙ»
        timeText: exampleTime,
        replyTitle: strings.exampleReplyAuthor,
        replyText: strings.exampleReplyText,
        emoji: "🐈",
        stickerLabel: strings.sticker
    )),
    sliderSetting: .stickerRawSize,
    selectionSetting: nil
)

.settingsPreview(
    id: shapePreviewId,
    section: .stickerShapes,
    kind: .stickerShapes(value: stickerShape, options: [
        strings.defaultShape, strings.roundedShape, strings.messageShape
    ]),
    sliderSetting: nil,
    selectionSetting: .stickerShape
)

.settingsPreview(
    id: messagePreviewId,
    section: .messages,
    kind: .message(SGMessagePreviewConfiguration(
        author: strings.exampleAuthor,
        text: strings.exampleMessage,
        timeText: exampleTime,
        editedText: strings.edited,
        removeTail: removeMessageTail,
        showEdited: true,
        editedIcon: editedIcon,
        onlineDot: onlineIndicator,
        showForwardCount: showForwardCount,
        forwardCount: 67,
        monospacedTime: monospacedTime,
        boldTime: boldTime,
        timeScale: timeScale
    )),
    sliderSetting: nil,
    selectionSetting: nil
)
```

These strings/IDs are illustrative integration names, not added localization
keys or model cases. Both configuration structs expose public mutable fields
and public initializers. Sticker defaults: time `0`, shape `1`, radius `20`,
all reply flags `true`, emoji/sticker label empty. Title, endpoint labels,
maximum badge, time, reply author and reply body are required strings. Message
defaults: tail shown, edited text shown, icon/dot/count off, count `0`, regular
proportional time at scale `1`. Author/body/time/edited strings are required.
`timeScale` is a multiplier, clamped to `0.7...1.8`, with nonfinite input using
`1`; root should convert a percentage setting to a multiplier first.

The current root integration uses `.stickerRawSize` for raw 4...20 slider
updates, `.stickerShape` for tile selection and `Extera.Preview.*` localized
strings. Message tail/edited/online/forward flags are already passed by root.
The preview entry, kind cases and configuration initializer labels are frozen
for the next root commit; see `PREVIEW_HANDOFF.md` for the snapshot boundary.

The sticker scale has 17 integer stops, horizontal tracking and tap selection,
and a VoiceOver adjustable value. It updates its marker, number/maximum badge
and vector illustration before emitting the changed raw size. The badge uses a
number at 4...19 and the supplied maximum string at 20. Vertical movement
cancels before changing a setting; repeated values and boundary adjustments
emit no callbacks. During tracking, stale model sizes are ignored by the view.
The host must publish the new size in the entry to remeasure the card: pending
that update, growth is capped to the existing scene bounds. Programmatic
updates never emit callbacks. Invalid sizes are clamped for display.

The three shape tiles match raw IDs `0/1/2`: square, 6pt corners and a rounded
message silhouette. They update selection locally and call `setSegmentedValue`
once per changed tile. Supply exactly three localized labels; extra labels are
ignored and missing labels disable their tiles. The sticker illustration uses
the actual supplied `bubbleRadius` for shape `2`. Side time uses the free space
beside the sticker when it fits, otherwise its safe overlay position. Reply
color, emoji prefix and quote background respond independently. The reply
author, quoted sticker label and reply body are separate text fields.

The message illustration uses a closed bubble outline with or without a tail,
an edited label or pencil, a themed online dot and a forward icon/count. Footer
items fit from the trailing edge: time has first priority, followed by edited
status and forward count. Long metadata is truncated within available width.
Body text allows two lines (four above base size 22); measurement uses the same
limit. Time font changes update both measurement and rendering. Header, quote,
reply and metadata heights follow the presentation font size.

These are synthetic settings illustrations with original reusable vector art,
not real account messages or fetched stickers. They allocate no chat objects,
perform no network fetch, and decode no images during layout. One reusable
`SGSettingsPreviewView` is owned by the shared list node. Interactive children
sit above the inert card surface, inherit its corners, and use parent-owned
frames and safe list insets. Native rows use native neighbour facets; extera
rows join matching extera sections. A full-width separator remains above the
illustration. Only the scale or tiles participate in VoiceOver; decorative
scenes are hidden. Existing appearance and double-tap previews are retained.

Nodes allocate UIKit children only in the main-thread apply pass and reuse them
on updates. Measurement is performed before apply; the parent owns the item
node's frame. There are no per-row blur views or independent scrolling stacks.
VoiceOver has one activation target for a normal toggle/checkbox and two for an
expandable toggle (expansion and bool switch). Labels, subtitles, values, badge
text, selected state, localized On/Off, and disabled state are exposed.

## Validation and remaining visual checks

The Windows workspace can run tree-sitter Swift parsing and `git diff --check`.
These checks establish syntax and diff hygiene, not Swift type checking or
runtime appearance. The iOS SDK and simulator recording are unavailable here.
No pixel or runtime parity is claimed.

The preview implementation passed parsing of all 10 module Swift files,
`git diff --check`, and whitespace checks of the new preview sources. Algebraic
frame checks covered 165,240 sticker size/time/shape/reply combinations, 270
tile layouts, 77,760 message footer/flag/font combinations, and round trips of
all 17 size stops at five track widths. Frame checks span widths 128...736pt,
base sizes 14...40pt and independent line-height envelopes; they do not execute
UIKit or verify actual UIFont metrics, Swift types, touch delivery or pixels.

Before accepting the visuals, record simulator frames per repository AGENTS.md
for light/dark, scrolling, selector open/dismiss, and group expand/collapse.
Expected frames: shared card edges remain contiguous; only the first/last row
has outer corners; the label/count tap inserts or removes checkbox rows while
the trailing bool switch changes only the bool; the count remains model-driven;
all children move with their list positions and preserve the surrounding card;
no clipped text, stale separator indentation, blur flashes, or exposed gaps.
Repeat with a long translation, large presentation font, disabled rows, search
results, and VoiceOver. Timing and motion require the actual recording.

For the settings illustrations, also record size 4→12→20→4 while dragging,
all three time modes and shapes, each reply flag independently, and message
tail/edited icon/dot/count/time font changes. Expected frames: the selected
marker and badge follow the finger without reverting to an earlier size;
sticker/reply content stays inside the remeasured card; the next settings row
follows the card's changing height without gaps; all three tiles remain within
the safe band; no metadata crosses the message edge; turning a flag off clears
its previous visual on the same node. Check long localized text and a large
presentation font in light and dark. These runtime frames remain unverified.
