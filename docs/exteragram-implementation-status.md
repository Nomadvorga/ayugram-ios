# exteraGram iOS implementation status

The implementation is **not a complete exteraGram port**. This document distinguishes
implemented source changes from features still missing and checks that require Apple
hardware/tooling. No runtime parity or measured performance claim follows from a source check.

Reference versions:

- iOS base: `718cc4ddd53446835d066ac658b4f76d16358b9e` from `Nomadvorga/ayugram-ios/master`.
- Android reference: `b4d852f48f2734a0bee1a74a0939be621612262a` from
  [exteraSquad/exteraGram](https://github.com/exteraSquad/exteraGram/tree/b4d852f48f2734a0bee1a74a0939be621612262a).
- The intended product reference is original **exteraGram**, with native iOS adaptations.
- Plugins, Python, method hooking, plugin SDKs and plugin settings are excluded.

## Implemented source changes

### Additional integrated source work (2026-11-25)

These additions supersede the corresponding omissions in the earlier table below.
They are reachable in the application source, but have not passed an Apple build or
recorded-frame acceptance. Plugins remain excluded.

| Area | Integrated behavior | Remaining limits |
| --- | --- | --- |
| AI | Service/model/role editors, Keychain secrets, per-account bounded history, Chat Completions/Responses, SSE, standalone chat, cancellation, optional plain-text editor processing | No on-device backends, image/rich-editor inputs, entity preservation, automatic Telegram summary replacement or complete catalogs |
| Channel feed | Ordinary TelegramEngine history, account-scoped channels/categories/archive, pagination, local read cursors, unread filter, original-message navigation and foreground suspension | Text previews; full media opens in channel. Up to 40 channels, 100 posts/channel, 1,000 displayed; unread counts cover loaded posts; no continuous polling. Parked News remains disabled |
| Inline conversion | Base conversion, all 39 Android units and 251 zone aliases, temperatures/durations/DST, independent controls, dated Coinbase rates, expiry and cancellation | No Stars pricing, arbitrary place lookup or persistent rate cache |
| Lyrics | LRCLIB/LrcMux/Better Lyrics/embedded-only, LRC/TTML word timing, line/word/plain/subtitle modes, offsets/scroll/seek, bounded cached FLAC/Ogg/Opus and AVFoundation lyric tags | No motion covers, independent pitch, rhythm, translation/romanization or persistent lyric cache |
| HTTP pills | Ordered persistent native GET/JSON settings, paths/formatting, live dashboard, bounded foreground requests, import/export and EN/RU editor; settings and Chats-tab long-press entries | No inline chat-list placement, full templates/rules, POST/headers/secrets, Android .pill import, built-in system/weather pills or persistent response cache |
| Stickers | Size 4…20 consumed by real non-premium stickers, unlimited local recents retained across cloud sync, Default/Side/Hidden timestamps, original/rounded/bubble masks and reused-node refresh | Side falls back for narrow/header/bubbleless layouts; emoji/dice/premium effects retain native geometry. Rendering unverified |
| Browser | HTTPS subscriptions, custom network filters, conservative ABP conversion, expiry/conditional requests/cache/cancellation, bounded downloads, revision checks and bundled fallback | No downloaded cosmetic rules/scriptlets/arbitrary regex/advanced modifiers, includes or conditionals; WebKit compilation unverified; no scheduled background updates |
| Cloud-chat takeout | Reachable setup/progress/share; takeout authorization, split ranges, server dialog/history pagination, chat/date selection, JSON/HTML, bounded photos/files and ZIP, cancellation/cleanup, confirmed session finish | Cloud-chat subset: no profile/contacts/sessions/stories, resume/background persistence, topic/migration merging, CDN or file-reference refresh. Content cap 2 GiB; no live account run. See [scope](extera-takeout.md) |
| Photo tools | Cached preview, explicit metadata-stripped JPEG upload to Yandex then Google Lens/Yandex/Bing/TinEye results, metadata/SHA-256/copy; protected/secret/view-once/paid/ad exclusions | No live provider upload test; endpoints may change or require verification; cached photos only. See [scope](extera-image-search.md) |
| Gestures/camera/title | Repeat double-tap with native permissions, Ask camera mode with locked recording after choice, username chat-list title preserving existing enum IDs | Other swipe/camera/navigation gaps remain |
| Poll preview | Optional preview of complete Telegram-supplied ordinary-poll counts, return to voting; preserves public voter list after vote/closure | Cannot reveal withheld results or quiz solutions; voting/layout paths need runtime checks |

The portable backup includes new sticker/player/conversion/poll/camera preferences and
the browser automatic-update toggle. Subscription URLs/custom filters/download caches,
AI secrets/history and account feed selections remain outside the allowlist. Pill
configurations have a separate confirmed import/export flow.

`.github/workflows/extera-host-checks.yml` prepares real production-model/parser tests
for conversions, lyrics, feed, pills, stickers, image-search protocol and takeout ZIP.
The workflow has not run; no CI or Swift test success is claimed.

### Earlier implementation baseline

All entries below have runtime consumers and reachable settings where applicable.
They still require a full iOS build and runtime acceptance.

| Area | Implemented | Remaining limits |
| --- | --- | --- |
| Settings navigation | Preserves master's General/Appearance/Application controls; exposes Chats, Media and Other controls, English/Russian strings, search, and original-project attribution | Android component styles/navigation modes are not all available |
| Gestures/composer | Separate incoming/outgoing double-tap actions; legacy outgoing preference migration; per-direction swipe-to-reply controls; keyboard dismissal once per drag; shared mention-comma preference across composer paths | No ordered swipe carousel, loop/reversal, or Repeat double-tap action; some non-reactable sticker nodes still gate dispatch |
| Message appearance | Channel/group/private reaction suppression; reply colors/emoji/background; tail removal; forward counts; existing edited-icon/share/greeting preferences now exposed | Tail merge-corner appearance, narrow timestamp rows and search/custom-history reaction paths need device review |
| Message menus | Cached photo copy, Saved Messages, repeat, clear cached media, author history, report visibility, metadata details and compact action grouping | No EXIF/location/platform fingerprints/bitrate tools; repeat retains explicit restrictions for paid/slowmode/closed/protected states |
| Message image export | Captures one fully visible, eligible message into an opaque bounded image and shares through the native sheet | No albums, offscreen reconstruction, stitching, metadata masking/theme designer; live video/widget capture requires device checks |
| Video/camera | Gallery double-tap intervals 5/10/15/30 seconds, original-video preference, video/voice/round background-pause controls, optional camera memory and front/rear default | No Ask camera mode, new camera backend selector, extended FPS/stabilization/mirror/wide-angle/zoom preference group |
| Music lyrics | Fixes LRCLIB array search decoding, request cancellation, stale track cleanup, duration matching, timed-line offsets and playback-clock highlighting; avoids duplicate empty labels and fighting active manual scrolling | No full enhanced player, selectable lyric providers, word/TTML/Vorbis lyrics, motion covers, rhythm visualizer or independent pitch controls |
| Translation | Corrected Microsoft signing, working request compatibility probes for Google/Microsoft/Yandex, bounded retries, status validation, Unicode-safe chunking, serialized operation batches, stale-result checks, and System queue cancellation | Alternative providers do not preserve all formatting/entities or support every poll/rich-message path; no complete shared dispatcher/cache |
| Speech | Apple locale and on-device controls, per-request lifetime, cancellation/timeout/temp cleanup, partial-result replacement, explicit synthesis language | Apple Speech is an adaptation; Vosk model management and AI post-processing remain absent |
| Profiles/archive | Adds default profile pane; retains master's ID/DC, relative presence and archive controls; live archive updates, stale swipe guard, available-pane fallback | ID/DC refresh and all profile combinations need runtime verification; DC is derived from available photo data |
| Browser | Native WebKit content rules for dedicated advertising/measurement hosts; exact-host exceptions, settings/backup integration, async compile deduplication and popup-controller ownership | Bundled conservative rules only; no subscription/scriptlet engine, full list editor or Android adblock parity |
| Settings backup | Versioned JSON, strict allowlist/type/range/duplicate-key/depth validation, native export/import/reset, confirmation before applying/resetting, original setter propagation | iOS preference format; does not import Android preferences or contain accounts, sessions, message databases, plugins or API secrets |
| Cached chat text export | Correct all-message paging, incremental JSON serialization, cancellation checks, bounded output, unique filenames, checked atomic writes, main-thread result delivery and iPad share anchoring | Exports locally cached cloud message text only; **not** account takeout/full server history/media export |

## Additional defects addressed during the audit

- `AyuSettingsStore` serializes cache and defaults writes together, suppresses redundant
  cached writes, and invokes observers outside its lock.
- Message rendering refreshes after relevant preferences change. Changes in one turn
  coalesce into one history refresh; unrelated settings do not invalidate all messages.
- Reply pattern work is disposed when no longer needed; late sticker-resolution results
  are checked against the current pattern. Transparent background transitions regenerate
  the correct asset. Gift layers track the requested file ID while loading.
- Reused chat-list rows release a hidden mini-avatar's previous peer subscription.
- Archive navigation is dispatched outside the active scroll callback.
- Browser navigation generations prevent a late rule compilation from resuming a stopped
  or replaced navigation. Shared popup content controllers share blocker installation state.
- A malformed persisted PWA UUID no longer force-unwraps and crashes the browser.
- Inline arithmetic searches only the bounded current line in large drafts. Evaluation
  has expression/token/depth/result bounds and never executes arbitrary code.
- Cached export no longer queries a tag table with an empty tag or reports an unwritten file
  as a successful export. Failure and cached-only scope are visible to the user.

## Substantial remaining port work

These are product gaps, not controls to expose without implementations:

1. On-device AI, image/rich-editor inputs, automatic summaries and remaining catalogs.
2. Full feed media rendering and continuous updates; parked News APIs stay disabled.
3. Remaining account-data takeout, resume/background persistence and unsupported media/history cases.
4. Runtime UI icon packs/editor/import, full alternate-icon catalog, inline pill placement and templates.
5. Complete swipe sequencing and remaining message presence controls.
6. Stars pricing, place lookup and persistent conversion caches.
7. Enhanced player artwork/canvas, lyric translation/romanization, pitch, rhythm and visual effects.
8. Vosk models, AI recognition post-processing, complete camera customization and
   volume-button unmute behavior.
9. Complete browser cosmetic/scriptlet engine, exteraGram account badges/supporter
   services, now-playing integrations and automatic proxy policies.
10. Android-specific navigation, Material/Glass style options, tablet overrides,
    notification policy/avatar features, utility tools and remote-service behavior.

The detailed Android inventory is in [exteragram-port-status.md](exteragram-port-status.md).
Its initial audit tables include gaps that the implementation above subsequently addresses;
use this document for the current integration state.

## Validation and required acceptance

The work environment is Windows. No Swift compiler, Xcode, Apple SDK, exposed
XcodeBuildMCP simulator tools or iOS device execution was available. Therefore:

- Full Bazel/Swift compilation and linkage are unverified.
- New arithmetic/settings stress XCTest suites are intended for a host Swift runner;
  their presence does not mean they passed.
- Source parsing, dependency/import inspection, localization checks, whitespace checks,
  conflict checks and the repository's Postbox import/access guard are feasible here.
- The existing Python build-system suite ran 48 tests: 45 passed; three encountered
  Windows filesystem restrictions (symlink privileges and temporary Git-object deletion).
- External translation probes used non-sensitive sample text and validated request
  compatibility only, not the compiled iOS request implementation.
- Camera, Apple Speech/System Translation, PiP/background audio, notification delivery,
  WebKit content-rule compilation and share-sheet flows still need Apple runtime tests.
- No FPS, memory, energy, latency or throughput improvement was measured on a device.

Build the full application with the root `CLAUDE.md` command, then run relevant existing
targets and the host tests. Confirm persistence, live refresh, multiple accounts, legacy/native
composer modes, both history backends, all enum modes, cancellation and error paths.

Before recording, expected frames should show: settings transitions with stable rows;
keyboard/composer dismissal together with continuous history; reply/tail/forward-count
layouts without clipped content; gallery seeking/PiP without overlapping surfaces;
lyrics following playback while leaving manual scrolling alone; and upright, tightly
cropped message image exports without adjacent messages. Test light/dark and each entry/exit
path. Record with `simctl io recordVideo`, generate labelled sheets with
`tools/animation_sheet.py`, and report frame/time evidence under `AGENTS.md`. None of these
visual checks is marked complete by this source audit.

Additional expectations for the new paths, written before any recording:

- Sticker Side moves incoming time right and outgoing time left with an 8 pt gap;
  the share button moves farther outward. Narrow/header/bubbleless cases retain native
  placement. Hidden removes standalone time while reactions remain in the footer.
  Thumbnail/animation/placeholder masks match, and reused rows regain their original
  mask/visibility after switching back. Check static/TGS/video and size 4/12/20.
- Poll preview returns to vote controls with Back to Vote; single/multiple-choice votes
  still submit. After voting or effective closure, public View Votes opens the voter
  list. Quizzes and withheld counts never gain invented bars or answers.
- Ask camera presents front/rear choices, cancel starts nothing, and a chosen recording
  stays locked when the initiating gesture releases. Leaving the chat prevents a late start.
- Photo Tools shows the same cached image in preview and confirmation; upload progress
  appears only after confirmation. Cancel/background closes progress without late browser
  presentation. Test failures and retry, protected content exclusions, and sheet dismissal.
- Takeout keeps setup stable while progress updates, disables conflicting controls during
  export, cancels on background/navigation, and shares only the completed archive.
  Errors expose no success sheet; iPad popovers remain anchored to the share button.
- Browser filter toggles/updates refresh the status without resuming a replaced or stopped
  navigation. Failed compilation retains bundled protection; host exceptions remain effective.
- Feed/AI/pill screens stop owned foreground work on leaving/background and reject stale
  responses after an account, configuration, track or query change. Check loading, empty,
  error, cancellation, long labels, large text and light/dark entry/exit paths.

Windows checks after this integration: 12 backup structural tests, EN/RU parity for
320 exteraGram/lyrics keys and coverage of 104 explicit UI keys, takeout wrapper/schema
audit, Postbox guard and whitespace checks pass. Changed Swift source parsing reports
only pre-existing grammar errors in PeerInfoData and TextProcessingScreen. These checks
do not establish Swift typechecking, host-test success, live provider behavior or frames.

The subsequent read-only integration audit found no verified actionable Swift API,
access-control, initialization or lifetime defect. Its reachable literal BUILD graph
contained 863 targets without a cycle, and host workflow commands matched the test
entry points. The missing workflow path trigger for SliderPercentageItem.swift was
added. This inspection remains a source audit, not a compiler or runtime result.
