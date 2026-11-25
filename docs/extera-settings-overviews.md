# Branded settings entry pages — frames 15 and 16

`ExteraSettingsOverviewController.swift` renders the two entry pages. The default
`sgSettingsController(context:)` and `ayuSettingsController(context:)` routes open
their respective overview. Category calls open the existing preference consumers.

Both original JPEGs were opened before implementation. The page has a centered
bundled brand icon, name, actual iOS bundle version/build, four category rows, and
four working links. The extera plugin row is excluded by user instruction. The
extera search button keeps the existing complete settings index reachable.
Media and feed entries remain reachable under Other; AI and calculator remain
under Chats. Ayu's four routes partition all six pre-existing settings sections:
Ghost (two sections), Spy, Filters (useful/filter preferences), Customization
(appearance and send confirmations). No existing switch or consumer is removed.

Assets are supplied by the app-icon integration. The version is read from this
app's bundle; Android's historical version/date is never used as the iOS version.
Rows use the current Telegram theme, scale fonts with Dynamic Type, calculate
height from wrapping labels, and expose titles/values as accessible buttons.
Cards stay opaque and constrain width on iPad. No new custom animation is added.
The icon silhouettes currently use SF Symbols; exact Android contour artwork is
still an open visual difference, not a visual parity pass.

Expected frames before recording: scrolling moves the hero, sections and cards
together; the back/search controls remain at their safe-area positions. A row
press only fades that row, then opens the corresponding working destination.
Back returns to the same scroll offset. Light/dark and Dynamic Type update labels
and card heights without overlap or clipping. Record both entry/return paths,
scrolling, each category/link, theme changes, and large text using
`simctl io recordVideo`, then inspect timestamped sheets from
`tools/animation_sheet.py` as required by `AGENTS.md`.

Windows parsing does not establish typecheck, link, runtime, or visual correctness.
No accepted recordings of these pages exist yet. Device performance is unmeasured.
