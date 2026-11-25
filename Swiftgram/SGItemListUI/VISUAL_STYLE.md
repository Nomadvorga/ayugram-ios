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
`disclosure`, `disclosureSubtitle`, `oneFromManySelector`, and `action` entries. Appearance previews,
percentage sliders, peer-color previews, and search input retain their existing
implementations. In particular, neither the avatar nor chat-list appearance
preview is changed. A native item interrupts an extera card run, so mixed native
and custom content has independent rounded surfaces.

Adjacent custom card rows in the same section join without vertical gaps.
Headers and notices end card runs. The descriptor includes section, card/plain,
notice, and checkbox facts; insertion/removal of a child or a search result
therefore invalidates neighbouring corners and separator geometry through the
current `ListViewItemNeighbors` API.

Geometry follows the supplied references: 54pt minimum row height, 22pt card
corners, 22pt interior horizontal padding, indented circular checkbox rows,
separate 44pt switch targets, and accent section headings with the supplied
capitalization. Text wraps and row height grows with the presentation font size.
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

Before accepting the visuals, record simulator frames per repository AGENTS.md
for light/dark, scrolling, selector open/dismiss, and group expand/collapse.
Expected frames: shared card edges remain contiguous; only the first/last row
has outer corners; the label/count tap inserts or removes checkbox rows while
the trailing bool switch changes only the bool; the count remains model-driven;
all children move with their list positions and preserve the surrounding card;
no clipped text, stale separator indentation, blur flashes, or exposed gaps.
Repeat with a long translation, large presentation font, disabled rows, search
results, and VoiceOver. Timing and motion require the actual recording.
