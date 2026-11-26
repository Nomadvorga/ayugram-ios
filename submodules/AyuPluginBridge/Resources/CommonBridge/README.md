# Common bridge: pinned 20-plugin compatibility audit

Source: `Nomadvorga/ayugram-src@a4b6bb472fd657e0f659531dae090e12c02a0aaa` for 19 inputs, plus a separately
SHA-256-pinned Premium Dialog Cards 2.1.1 source. **Not a claim that all 20 work.**

42,600 lines inspected as AST only. No supplied plugin execution; no device/native-test verification.

| Plugin | Path status | Value subsets | Application subsets | Unadapted classes | Missing SDK symbols |
|---|---|---:|---:|---:|---:|
| `atmospheric_snow.plugin` | Pinned native adapter; device unverified | 2 | 2 | 13 | 0 |
| `ball.plugin` | Pinned native adapter; device unverified | 0 | 1 | 5 | 0 |
| `fish_audio_integration.plugin` | Blocked (Python path) | 0 | 6 | 8 | 0 |
| `group_mentions.plugin` | Python bridge source; device unverified | 0 | 6 | 0 | 0 |
| `local_chat_archive.plugin` | Blocked (Python path) | 6 | 8 | 40 | 0 |
| `md3_loader.plugin` | Blocked (Python path) | 2 | 2 | 1 | 0 |
| `message_cleaner.plugin` | Blocked (Python path) | 4 | 6 | 18 | 0 |
| `music_bridge.plugin` | Blocked (Python path) | 0 | 3 | 0 | 0 |
| `music_tab.plugin` | Blocked (Python path) | 2 | 2 | 6 | 0 |
| `passguard.plugin` | Blocked (Python path) | 5 | 5 | 10 | 0 |
| `player_below.plugin` | Blocked (Python path) | 7 | 2 | 10 | 0 |
| `premium_dialog_cards.plugin` | Pinned native adapter; device unverified | 3 | 2 | 7 | 0 |
| `profile_info.plugin` | Blocked (Python path) | 5 | 2 | 14 | 0 |
| `pull_next_chat.plugin` | Pinned native adapter; device unverified | 5 | 4 | 9 | 0 |
| `quick_stickers.plugin` | Blocked (Python path) | 2 | 2 | 7 | 0 |
| `sand_box.plugin` | Pinned native adapter; device unverified | 0 | 0 | 6 | 0 |
| `screenshot_privacy.plugin` | Pinned native adapter; device unverified | 10 | 9 | 31 | 0 |
| `side_panel.plugin` | Blocked (Python path) | 7 | 6 | 40 | 0 |
| `spekgram.plugin` | Blocked (Python path) | 4 | 6 | 17 | 0 |
| `theme_per_account.plugin` | Blocked (Python path) | 0 | 3 | 1 | 0 |

See `compatibility.json` for each source hash, required API, hook/event form and missing class/symbol.

Atmospheric Snow, SandBox, Ball, Screenshot Privacy, Pull to Next Chat and Premium Dialog Cards bypass Python only for their exact pinned SHA-256. They are host-owned native routes and remain device-unverified.
Group Mentions is deliberately routed through the original Python source with narrow host shims; it is not a native reimplementation. The remaining 13 plugins stay blocked. Narrow app adapters are not a substitute for their remaining Telegram/iOS services.
See `APPLICATION-BRIDGES.md` for exact implemented members, per-plugin work packages and device checks.

The common Java value subset also includes bounded typed object arrays and a
UTF-16 `SpannableString`/`SpannableStringBuilder` model with a small value-only
set of standard style spans. `TextView`/`EditText` also expose bounded
`TextWatcher` registration and asynchronous callbacks with UTF-16 edit indices.
`java.lang.reflect.Array` operates only on owned one-dimensional arrays of
declared components, with exact primitive typed access and per-plugin element/byte
quotas; this does not enable arbitrary Java reflection. Bounded `Byte` and `Short`
value wrappers provide signed parsing, narrowing and constants without implying
the rest of those Java classes.
`AndroidUtilities.dp` and `dpf2` convert bounded values using native UIKit point
units (density 1); `dp` applies `ceil`, while `dpf2` preserves the fraction. They do
not emulate Android device density or multiply by the physical screen scale.
`View` content descriptions map to bounded native accessibility labels.
`EditText` focus queries and requests follow native first-responder availability.
View parent/child queries preserve the owned container order and native padding
and attachment accessors return bounded snapshots. Explicitly assigned view
layout parameters can be read back as owned values. Bounded tags, root and ID lookup,
clickability and transform accessors, view IDs, minimum sizes, visibility,
asynchronous Runnable posting, and redraw/layout invalidation map to the virtual
UIKit view tree; layout dimensions remain native points rather than Android
density-scaled pixels. Bounded elevation maps only to native z-order, and
Frame/Linear child clipping and supported drawable-outline clipping are explicit;
neither supplies Android shadow or arbitrary Drawable parity. Only the background
outline provider is supported; custom providers reject. The bounded `ScrollView`
and `HorizontalScrollView` subsets include native single-axis scrolling,
fill-viewport sizing, matching-axis scrollbar visibility, clipped padding and
`OVER_SCROLL_NEVER`; nested/two-axis scrolling, Android fling physics and scroll
callbacks remain unsupported. `View.setFocusable` and `setSelected` preserve
boolean state only, without UIKit focus or Android drawable-selector parity.
`setBackgroundDrawable` aliases the same bounded drawable subset as `setBackground`.
`View.getBackground()`
returns a retained supported drawable or validated snapshot. ImageView tint is
limited to `SRC_IN`, `MATRIX` is identity-only, ImageButton has no Android button
chrome, and image-clearing calls are supported without an Android resource resolver.
The audited ProgressBar constructors map to an activity indicator or bounded
horizontal progress view; CheckBox exposes only checked state, basic text/padding,
single-color tint and the asynchronous checked-change listener subset.
`ViewConfiguration` supplies fixed native-point/timeout values, and view haptics
are limited to the audited long-press and clock-tick requests through UIKit.
`View.MeasureSpec` implements only bounded integer packing/unpacking; it does not
provide Android measurement traversal.
`SystemClock.uptimeMillis()` exposes only an iOS monotonic uptime reading for
short intervals; Android boot origin and deep-sleep semantics are not guaranteed.
It does not render Android styled text or Paint state; Telegram span classes and app UI/graphics
dependencies remain blockers. See the protocol and application bridge contract
for exact limits.
