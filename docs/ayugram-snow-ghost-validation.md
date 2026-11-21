# Snow and ghost-send validation

This change ports AyuGram Android's snow to Core Animation and adjusts ghost sending.
Native compilation, simulator recordings and device FPS measurements have **not** been run in the iOS-hosted editing environment. Available checks passed: the project's `PostboxImportCheck.py`, syntax parsing of the five edited localization files (en/ru/cs/fi/pl), uniqueness of the new snow localization keys in en/ru, and Python-compatible syntax parsing of the four edited/new Bazel BUILD files. These checks do not type-check Swift or execute Bazel. The emulated Git command does not implement `diff --check` (it prints a diff), so it is not counted as a whitespace validation.

## Snow design and reference

Reference: `Nomadvorga/ayugram-src`, commit `d4e665ccb6b1a50fcbd05889f8bf894d26e4ca3d`:
`SnowflakesEffect.java`, `SizeNotifierFrameLayout.java`, `ActionBar.java`, and exteraGram's `AppearancePreferencesActivity.java`.

The iOS implementation uses one `CAEmitterLayer` per visible region, with a shared dot texture, no display link and no per-frame Swift particle loop. Snow stays above the wallpaper and below messages. Header particles use the navigation title's theme color. Chat emission is bounded to 60 particles/s with a maximum 5 s lifetime (up to 300 particles before area scaling); header emission is 18/s with about a 2 s lifetime. These limits are independent of 60/120 Hz refresh rates. Low Power Mode reduces emission to 35%. Reduce Motion, backgrounding, leaving the screen and disabling the switch remove the emitter. Layout only updates layer geometry when it changes.

This is a native visual adaptation, not a verified pixel-identical port: Core Animation's opacity curve differs from Android's 200 ms fade-in and late fade-out. Android Canvas pixel speeds also do not map directly to iOS points. Compare the recordings below before claiming visual parity.

## Expected frames before recording

Small dots drift down with a slight horizontal spread. Message bubbles, text and the composer remain above the snow and fully interactive. Header snow is visible in light and dark themes. Rotation and keyboard resizing must not restart all particles or leave a gap. Disabling snow or leaving a screen must immediately stop rendering it; resuming a visible screen restarts the effect without a catch-up burst.

Follow the repository's `AGENTS.md` recording/frame-sheet procedure on macOS. Record light/dark chats, keyboard show/hide, interactive back navigation, rotation, settings on/off, background/foreground and Low Power Mode. Check screenshots for particle size, density, title readability and layering. No frame evidence is available yet.

## Ghost-send matrix

- Ghost off, delayed-send preference off/on: normal immediate send; no ghost-specific online pulse.
- Ghost on, delay off, hide-online on: successful normal sends briefly go online for 0.2 s and return offline, including when the old pulse preference was saved as false and automatic-offline is disabled.
- Ghost on, delay on: use scheduled sending only for eligible chats. The input clears as soon as the send is accepted; a new draft typed immediately afterwards survives later history updates. No pulse for a request containing a schedule date.
- Toggle ghost off with delay preference still on: immediate sending resumes, and the preference remains saved for the next ghost session.
- Verify ordinary manual scheduling, Saved Messages, secret chats, replies, forwards, attachments, paid-message confirmation/cancellation, and failed validation retain their existing behavior.

## Device performance comparison

Use the same release build configuration, iPhone, refresh-rate setting, theme, wallpaper, message history and thermal state for baseline and changed builds. With Instruments (Core Animation / Animation Hitches and Time Profiler), compare snow off/on during 30 s of scrolling, typing and keyboard transitions. Record FPS, frame-time percentiles, hitch count, CPU and energy use. Repeat on a 60 Hz device and a ProMotion device. Inspect the layer count after repeatedly pushing/popping chats and after backgrounding. Device measurements are required before claiming unchanged FPS; source inspection cannot establish that claim.

## Appearance follow-up

Reference avatar implementation: `vorga2/Telegram-iOS-Ghost`, branch `ayu-theme-repair-v1`, commit `f3108c148cd611c5d7dc3bd2b0fb978c5de12f0e` (`apply_ayu_avatar_rounding_v3.py` and `payload/AyuAvatarRoundingItem.swift`). The shared iOS avatar pipeline opts in only chat-list and message avatars, retains raw cached images and uses the parent's corner radius. One weak registry and one settings observer refresh the geometry without regenerating image masks. Video and custom-letter paths use the same parent clipping; profile and unrelated avatar callers retain their stock behavior.

Settings live in exteraGram → Appearance: avatar slider/preview and Unified Corners first, then Chat List's bordered header preview, Forced Snow, Center Title and title options. Defaults follow Android: circle (28), unified off, snow off, center off, AyuGram title. Native slider persists whole 0...28 values; un-unified forums retain the iOS quarter-radius shape. The requested full-name title uses first + last name (absent last name is omitted); Android's similarly positioned option uses a public username instead. These are intentional iOS/request adaptations, not pixel-identical Android behavior.

The actual live chat-list header is `ChatListNavigationBar` in `ChatListControllerNode`, not the legacy `controller.navigationBar`. Snow is attached to the component title row and covers the full wallpaper in a chat. It is not attached to the search/stories region or message bubbles. Serious thermal state reduces density like Low Power Mode; critical thermal state removes the emitter.

Expected appearance frames: the mock avatar is square at zero, circular at 28 and smoothly rounded in between; online dot remains inside the avatar corner. Photo, video and letter avatars in chat/list all agree with the selected radius. Toggling Unified Corners changes forums without changing other chats. Header preview has an outline, the selected title, menu dots and snow when enabled. Root titles update on settings, profile-name and locale changes, while archive/forum titles, selection counts, network and ghost indicators remain meaningful. Centered titles stay on the safe-area axis without overlapping side buttons, including long names and asymmetric iPad/RTL insets. Preview particles stop when scrolled off screen. Record these paths under the repository frame procedure; no recorded visual evidence or device FPS measurements are available from this editing environment.

